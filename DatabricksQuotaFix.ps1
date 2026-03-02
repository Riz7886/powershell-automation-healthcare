#Requires -Version 5.1
<#
.SYNOPSIS
    Databricks Quota & Performance Degradation - Diagnose & Fix
.DESCRIPTION
    Diagnoses quota issues, applies auto-scaling fixes, creates cluster policies,
    sets up Azure Monitor alerts, and requests quota increases.
    
    Addresses cascading degradation:
      - func-memberimport-prod (151% slower, 43% requests affected)
      - pyx-qa SQL dependency (39750% slower)
      - Databricks cluster resource contention

.PARAMETER Mode
    diagnose     - Check clusters, jobs, and Azure vCPU quota
    fix          - Apply autoscale, auto-termination, Spark configs
    alerts       - Create Azure Monitor metric alerts
    quota        - Request Azure vCPU quota increase
    all          - Run everything

.EXAMPLE
    .\DatabricksQuotaFix.ps1 -Mode diagnose
    .\DatabricksQuotaFix.ps1 -Mode fix
    .\DatabricksQuotaFix.ps1 -Mode all
    .\DatabricksQuotaFix.ps1 -Mode fix -WhatIf

.NOTES
    Prerequisites:
      - Az PowerShell module: Install-Module Az -Force
      - Databricks PAT token
      - Azure subscription access
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("diagnose", "fix", "alerts", "quota", "all")]
    [string]$Mode,

    [Parameter()]
    [string]$DatabricksHost = $env:DATABRICKS_HOST,

    [Parameter()]
    [string]$DatabricksToken = $env:DATABRICKS_TOKEN,

    [Parameter()]
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,

    [Parameter()]
    [string]$ResourceGroup = $env:AZURE_RESOURCE_GROUP,

    [Parameter()]
    [string]$Location = "eastus",

    [Parameter()]
    [int]$AutoTerminationMinutes = 30,

    [Parameter()]
    [int]$MaxWorkersDefault = 10,

    [Parameter()]
    [string]$ActionGroupName = "",

    [Parameter()]
    [string]$LogPath = ".\DatabricksQuotaFix_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
)

# ============================================================================
# SETUP
# ============================================================================

$ErrorActionPreference = "Stop"
$script:IssuesFound = [System.Collections.ArrayList]::new()
$script:FixesApplied = [System.Collections.ArrayList]::new()

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    switch ($Level) {
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line }
    }
    Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
}

function Write-Banner {
    param([string]$Title)
    $sep = "=" * 70
    Write-Log $sep
    Write-Log $Title
    Write-Log $sep
}

function Get-DatabricksHeaders {
    @{
        "Authorization" = "Bearer $DatabricksToken"
        "Content-Type"  = "application/json"
    }
}

function Invoke-DatabricksApi {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [hashtable]$Body = $null
    )
    $uri = "$DatabricksHost/api/2.0$Endpoint"
    $params = @{
        Uri     = $uri
        Method  = $Method
        Headers = Get-DatabricksHeaders
    }
    if ($Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10)
    }
    try {
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        Write-Log "API call failed: $Endpoint - $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Invoke-DatabricksApi21 {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [hashtable]$Body = $null,
        [hashtable]$QueryParams = @{}
    )
    $uri = "$DatabricksHost/api/2.1$Endpoint"
    if ($QueryParams.Count -gt 0) {
        $qs = ($QueryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
        $uri = "$uri`?$qs"
    }
    $params = @{
        Uri     = $uri
        Method  = $Method
        Headers = Get-DatabricksHeaders
    }
    if ($Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10)
    }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        Write-Log "API call failed: $Endpoint - $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# ============================================================================
# VALIDATE INPUTS
# ============================================================================

function Test-Prerequisites {
    Write-Banner "VALIDATING PREREQUISITES"

    $valid = $true

    if ([string]::IsNullOrWhiteSpace($DatabricksHost)) {
        Write-Log "DATABRICKS_HOST not set. Use -DatabricksHost or set env var." "ERROR"
        Write-Log "  Example: https://adb-1234567890.12.azuredatabricks.net" "ERROR"
        $valid = $false
    }
    else {
        # Strip trailing slash
        $script:DatabricksHost = $DatabricksHost.TrimEnd("/")
        Write-Log "Databricks Host: $DatabricksHost" "SUCCESS"
    }

    if ([string]::IsNullOrWhiteSpace($DatabricksToken)) {
        Write-Log "DATABRICKS_TOKEN not set. Use -DatabricksToken or set env var." "ERROR"
        $valid = $false
    }
    else {
        Write-Log "Databricks Token: ****$(($DatabricksToken)[-8..-1] -join '')" "SUCCESS"
    }

    if ($Mode -in @("alerts", "quota", "all")) {
        if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
            Write-Log "AZURE_SUBSCRIPTION_ID needed for alerts/quota mode." "WARN"
        }
        # Check Az module
        if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
            Write-Log "Az PowerShell module not found. Install with: Install-Module Az -Force" "WARN"
        }
    }

    if (-not $valid) {
        Write-Log "Prerequisites not met. Exiting." "ERROR"
        exit 1
    }
}

# ============================================================================
# PART 1: DIAGNOSE
# ============================================================================

function Invoke-Diagnose {
    Write-Banner "DATABRICKS CLUSTER DIAGNOSTICS"

    # --- List Clusters ---
    Write-Log "`n--- Active Clusters ---"
    $clusterData = Invoke-DatabricksApi -Endpoint "/clusters/list"
    $clusters = $clusterData.clusters

    if (-not $clusters -or $clusters.Count -eq 0) {
        Write-Log "No clusters found in workspace." "WARN"
        return
    }

    Write-Log "Found $($clusters.Count) cluster(s)`n"

    foreach ($c in $clusters) {
        $name      = $c.cluster_name
        $id        = $c.cluster_id
        $state     = $c.state
        $driver    = $c.driver_node_type_id
        $worker    = $c.node_type_id
        $numW      = $c.num_workers
        $autoscale = $c.autoscale
        $autoTerm  = $c.autotermination_minutes

        Write-Log "  Cluster: $name ($id)"
        Write-Log "    State: $state"
        Write-Log "    Driver: $driver | Worker: $worker"

        if ($autoscale) {
            Write-Log "    Autoscale: $($autoscale.min_workers) - $($autoscale.max_workers) workers"
            if ($autoscale.max_workers -lt 4 -and $state -eq "RUNNING") {
                [void]$script:IssuesFound.Add(
                    "[CLUSTER] '$name' autoscale max is only $($autoscale.max_workers). May bottleneck under load."
                )
            }
        }
        else {
            Write-Log "    Fixed size: $numW workers" "WARN"
            if ($state -eq "RUNNING") {
                [void]$script:IssuesFound.Add(
                    "[CLUSTER] '$name' uses FIXED sizing ($numW workers). No ability to scale with demand."
                )
            }
        }

        if ($autoTerm -eq 0 -and $state -eq "RUNNING") {
            Write-Log "    Auto-terminate: DISABLED" "WARN"
            [void]$script:IssuesFound.Add(
                "[CLUSTER] '$name' has NO auto-termination. Wastes quota/DBUs when idle."
            )
        }
        elseif ($autoTerm) {
            Write-Log "    Auto-terminate: $autoTerm min"
        }

        # Check Spark configs
        $sparkConf = $c.spark_conf
        if ($sparkConf) {
            $adaptive = $sparkConf."spark.sql.adaptive.enabled"
            if ($adaptive -ne "true") {
                [void]$script:IssuesFound.Add(
                    "[CLUSTER] '$name' does not have Adaptive Query Execution enabled."
                )
            }
        }
        else {
            [void]$script:IssuesFound.Add(
                "[CLUSTER] '$name' has no custom Spark configs. Missing performance optimizations."
            )
        }

        Write-Log ""
    }

    # --- Job Failures ---
    Write-Log "`n--- Recent Job Failures (last 48h) ---"
    $nowMs = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    $twoDaysAgoMs = [long]([DateTimeOffset]::UtcNow.AddHours(-48).ToUnixTimeMilliseconds())

    $runsData = Invoke-DatabricksApi21 -Endpoint "/jobs/runs/list" -QueryParams @{
        start_time_from = $twoDaysAgoMs
        start_time_to   = $nowMs
        limit            = 100
    }

    $runs = $runsData.runs
    if ($runs) {
        $failedRuns = $runs | Where-Object { $_.state.result_state -in @("FAILED", "TIMEDOUT", "CANCELED") }
        $slowSetup  = $runs | Where-Object { ($_.setup_duration / 1000) -gt 300 }

        if ($failedRuns -and $failedRuns.Count -gt 0) {
            Write-Log "$($failedRuns.Count) FAILED/TIMEDOUT runs in last 48h!" "WARN"
            foreach ($fr in ($failedRuns | Select-Object -First 10)) {
                $msg = $fr.state.state_message
                Write-Log "    - $($fr.run_name): $($msg.Substring(0, [Math]::Min(150, $msg.Length)))" "WARN"
                if ($msg -match "quota|limit|capacity|resource") {
                    [void]$script:IssuesFound.Add(
                        "[JOB] '$($fr.run_name)' failed with resource/quota error: $($msg.Substring(0, [Math]::Min(200, $msg.Length)))"
                    )
                }
            }
        }
        else {
            Write-Log "  No failed runs in last 48h." "SUCCESS"
        }

        if ($slowSetup -and $slowSetup.Count -gt 0) {
            Write-Log "$($slowSetup.Count) runs had cluster setup > 5 min (resource contention)" "WARN"
            [void]$script:IssuesFound.Add(
                "[JOB] $($slowSetup.Count) runs had setup > 5 min, indicating cluster provisioning contention."
            )
        }
    }
    else {
        Write-Log "  No runs found in the last 48h."
    }

    # --- Azure vCPU Quota ---
    Invoke-AzureQuotaCheck

    # --- Summary ---
    Write-Banner "DIAGNOSIS SUMMARY"
    if ($script:IssuesFound.Count -gt 0) {
        Write-Log "$($script:IssuesFound.Count) issue(s) found:`n" "WARN"
        for ($i = 0; $i -lt $script:IssuesFound.Count; $i++) {
            Write-Log "  $($i + 1). $($script:IssuesFound[$i])" "WARN"
        }
    }
    else {
        Write-Log "No obvious issues detected from Databricks API." "SUCCESS"
        Write-Log "Check Azure Portal for subscription-level vCPU limits."
    }
}

function Invoke-AzureQuotaCheck {
    Write-Log "`n--- Azure vCPU Quota Usage ---"

    if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
        Write-Log "  Az.Compute module not available. Skipping Azure quota check." "WARN"
        Write-Log "  Install with: Install-Module Az -Force" "WARN"

        Write-Log "`n  Manual check via Azure CLI:" "INFO"
        Write-Log "  az vm list-usage --location $Location --output table | findstr /i `"vCPU`"" "INFO"
        return
    }

    try {
        if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
            Write-Log "  Not logged in to Azure. Run: Connect-AzAccount" "WARN"
            return
        }

        $usages = Get-AzVMUsage -Location $Location
        $highUsage = $usages | Where-Object {
            $_.Name.Value -match "vCPU|core" -and
            $_.Limit -gt 0 -and
            (($_.CurrentValue / $_.Limit) * 100) -gt 60
        }

        if ($highUsage) {
            foreach ($u in $highUsage) {
                $pct = [math]::Round(($u.CurrentValue / $u.Limit) * 100, 1)
                $severity = if ($pct -gt 85) { "ERROR" } elseif ($pct -gt 70) { "WARN" } else { "INFO" }
                Write-Log "  [$Location] $($u.Name.LocalizedValue): $($u.CurrentValue)/$($u.Limit) ($pct%)" $severity

                if ($pct -gt 80) {
                    [void]$script:IssuesFound.Add(
                        "[AZURE QUOTA] $($u.Name.LocalizedValue) at $pct% in $Location. This is likely throttling Databricks cluster provisioning."
                    )
                }
            }
        }
        else {
            Write-Log "  All vCPU quotas below 60% in $Location." "SUCCESS"
        }
    }
    catch {
        Write-Log "  Azure quota check failed: $($_.Exception.Message)" "WARN"
    }
}

# ============================================================================
# PART 2: FIX CLUSTERS
# ============================================================================

function Invoke-Fix {
    Write-Banner "APPLYING CLUSTER FIXES"

    $clusterData = Invoke-DatabricksApi -Endpoint "/clusters/list"
    $clusters = $clusterData.clusters

    if (-not $clusters) {
        Write-Log "No clusters found." "WARN"
        return
    }

    foreach ($c in $clusters) {
        $name  = $c.cluster_name
        $id    = $c.cluster_id
        $state = $c.state

        if ($state -notin @("RUNNING", "PENDING", "RESIZING")) {
            Write-Log "Skipping '$name' (state: $state)"
            continue
        }

        Write-Log "`nProcessing: $name ($id)"

        $changes = [System.Collections.ArrayList]::new()

        # Build the edit payload preserving existing settings
        $edit = @{
            cluster_id            = $id
            cluster_name          = $name
            spark_version         = $c.spark_version
            node_type_id          = $c.node_type_id
        }

        # Preserve driver type
        if ($c.driver_node_type_id) {
            $edit["driver_node_type_id"] = $c.driver_node_type_id
        }

        # Preserve Azure attributes
        if ($c.azure_attributes) {
            $edit["azure_attributes"] = $c.azure_attributes
        }

        # Preserve custom tags
        if ($c.custom_tags) {
            $edit["custom_tags"] = $c.custom_tags
        }

        # --- Fix 1: Enable autoscale ---
        if (-not $c.autoscale) {
            $currentWorkers = if ($c.num_workers) { $c.num_workers } else { 2 }
            $minW = [Math]::Max(1, [Math]::Floor($currentWorkers / 2))
            $maxW = [Math]::Min($MaxWorkersDefault, $currentWorkers * 2)
            $edit["autoscale"] = @{
                min_workers = $minW
                max_workers = $maxW
            }
            [void]$changes.Add("Enable autoscale: $minW - $maxW workers (was fixed $currentWorkers)")
        }
        else {
            $edit["autoscale"] = $c.autoscale

            # Bump max if too low
            if ($c.autoscale.max_workers -lt 4) {
                $edit["autoscale"] = @{
                    min_workers = $c.autoscale.min_workers
                    max_workers = [Math]::Max($c.autoscale.max_workers, 8)
                }
                [void]$changes.Add("Increased autoscale max from $($c.autoscale.max_workers) to $($edit.autoscale.max_workers)")
            }
        }

        # --- Fix 2: Auto-termination ---
        if (-not $c.autotermination_minutes -or $c.autotermination_minutes -eq 0) {
            $edit["autotermination_minutes"] = $AutoTerminationMinutes
            [void]$changes.Add("Set auto-termination to $AutoTerminationMinutes min (was disabled)")
        }
        else {
            $edit["autotermination_minutes"] = $c.autotermination_minutes
        }

        # --- Fix 3: Spark performance configs ---
        $existingConf = @{}
        if ($c.spark_conf) {
            # Convert PSCustomObject to hashtable
            $c.spark_conf.PSObject.Properties | ForEach-Object {
                $existingConf[$_.Name] = $_.Value
            }
        }

        $recommended = @{
            "spark.sql.adaptive.enabled"                                    = "true"
            "spark.sql.adaptive.coalescePartitions.enabled"                 = "true"
            "spark.sql.adaptive.skewJoin.enabled"                           = "true"
            "spark.databricks.adaptive.autoOptimizeShuffle.enabled"         = "true"
            "spark.databricks.delta.optimizeWrite.enabled"                  = "true"
            "spark.databricks.delta.autoCompact.enabled"                    = "true"
            "spark.sql.shuffle.partitions"                                  = "auto"
            "spark.databricks.io.cache.enabled"                             = "true"
        }

        $addedConfigs = 0
        foreach ($key in $recommended.Keys) {
            if (-not $existingConf.ContainsKey($key)) {
                $existingConf[$key] = $recommended[$key]
                $addedConfigs++
            }
        }

        if ($addedConfigs -gt 0) {
            [void]$changes.Add("Added $addedConfigs Spark optimization configs (AQE, Delta optimize, IO cache)")
        }

        $edit["spark_conf"] = $existingConf

        # --- Apply ---
        if ($changes.Count -gt 0) {
            Write-Log "  Changes:"
            foreach ($ch in $changes) {
                Write-Log "    + $ch" "SUCCESS"
            }

            if ($PSCmdlet.ShouldProcess($name, "Apply cluster optimizations")) {
                try {
                    $result = Invoke-DatabricksApi -Endpoint "/clusters/edit" -Method "POST" -Body $edit
                    Write-Log "  [OK] Successfully updated '$name'" "SUCCESS"
                    [void]$script:FixesApplied.Add("Cluster '$name': $($changes -join '; ')")
                }
                catch {
                    Write-Log "  [FAIL] Could not update '$name': $($_.Exception.Message)" "ERROR"
                }
            }
        }
        else {
            Write-Log "  No changes needed for '$name'" "SUCCESS"
        }
    }

    # --- Create Cluster Policy ---
    Invoke-CreateClusterPolicy
}

function Invoke-CreateClusterPolicy {
    Write-Banner "CREATING QUOTA-SAFE CLUSTER POLICY"

    $policyDef = @{
        "autoscale.min_workers" = @{
            type         = "range"
            minValue     = 1
            maxValue     = 4
            defaultValue = 1
        }
        "autoscale.max_workers" = @{
            type         = "range"
            minValue     = 2
            maxValue     = 20
            defaultValue = 8
        }
        "autotermination_minutes" = @{
            type         = "range"
            minValue     = 10
            maxValue     = 120
            defaultValue = 30
        }
        "spark_conf.spark.sql.adaptive.enabled" = @{
            type   = "fixed"
            value  = "true"
            hidden = $true
        }
        "spark_conf.spark.databricks.adaptive.autoOptimizeShuffle.enabled" = @{
            type   = "fixed"
            value  = "true"
            hidden = $true
        }
        "spark_conf.spark.databricks.delta.optimizeWrite.enabled" = @{
            type   = "fixed"
            value  = "true"
            hidden = $true
        }
        "spark_conf.spark.databricks.delta.autoCompact.enabled" = @{
            type   = "fixed"
            value  = "true"
            hidden = $true
        }
        "spark_conf.spark.databricks.io.cache.enabled" = @{
            type   = "fixed"
            value  = "true"
            hidden = $true
        }
    }

    $policy = @{
        name                  = "Quota-Safe Production Policy"
        definition            = ($policyDef | ConvertTo-Json -Depth 5)
        max_clusters_per_user = 3
    }

    if ($PSCmdlet.ShouldProcess("Quota-Safe Production Policy", "Create cluster policy")) {
        try {
            $result = Invoke-DatabricksApi -Endpoint "/policies/clusters/create" -Method "POST" -Body $policy
            if ($result.policy_id) {
                Write-Log "Created policy ID: $($result.policy_id)" "SUCCESS"
                Write-Log "Assign this policy to job clusters to enforce quota limits."
                [void]$script:FixesApplied.Add("Created cluster policy: Quota-Safe Production Policy ($($result.policy_id))")
            }
        }
        catch {
            if ($_.Exception.Message -match "already exists") {
                Write-Log "Policy already exists. Skipping." "INFO"
            }
            else {
                Write-Log "Failed to create policy: $($_.Exception.Message)" "ERROR"
            }
        }
    }
}

# ============================================================================
# PART 3: AZURE MONITOR ALERTS
# ============================================================================

function Invoke-SetupAlerts {
    Write-Banner "SETTING UP AZURE MONITOR ALERTS"

    if ([string]::IsNullOrWhiteSpace($SubscriptionId) -or [string]::IsNullOrWhiteSpace($ResourceGroup)) {
        Write-Log "SubscriptionId and ResourceGroup required for alert setup." "ERROR"
        Write-Log "Generating Azure CLI commands instead...`n"
        Write-AzureCliAlertCommands
        return
    }

    # Try Az PowerShell first
    $useAzModule = $false
    if (Get-Module -ListAvailable -Name Az.Monitor) {
        try {
            if (Get-AzContext -ErrorAction SilentlyContinue) {
                $useAzModule = $true
            }
        }
        catch { }
    }

    if ($useAzModule) {
        Invoke-SetupAlertsAzModule
    }
    else {
        Write-Log "Az.Monitor not available or not logged in. Generating CLI commands.`n" "WARN"
        Write-AzureCliAlertCommands
    }
}

function Invoke-SetupAlertsAzModule {
    Write-Log "Creating alerts via Az PowerShell module...`n"

    # Alert 1: func-memberimport-prod response time
    $funcResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/func-memberimport-prod"

    try {
        $condition1 = New-AzMetricAlertRuleV2Criteria `
            -MetricName "HttpResponseTime" `
            -MetricNamespace "Microsoft.Web/sites" `
            -TimeAggregation Average `
            -Operator GreaterThan `
            -Threshold 2.0

        if ($PSCmdlet.ShouldProcess("func-memberimport-response-time-alert", "Create metric alert")) {
            $alertParams = @{
                Name              = "func-memberimport-response-time-alert"
                ResourceGroupName = $ResourceGroup
                TargetResourceId  = $funcResourceId
                Condition         = $condition1
                WindowSize        = (New-TimeSpan -Minutes 5)
                Frequency         = (New-TimeSpan -Minutes 1)
                Severity          = 2
                Description       = "Alert: func-memberimport-prod avg response time > 2s (normal: 1.24s)"
            }

            if ($ActionGroupName) {
                $ag = Get-AzActionGroup -ResourceGroupName $ResourceGroup -Name $ActionGroupName
                $alertParams["ActionGroupId"] = $ag.Id
            }

            Add-AzMetricAlertRuleV2 @alertParams
            Write-Log "[OK] Created alert: func-memberimport-response-time-alert" "SUCCESS"
        }
    }
    catch {
        Write-Log "Failed to create func-memberimport alert: $($_.Exception.Message)" "ERROR"
    }

    # Alert 2: pyx-qa dependency duration
    $pyxResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/components/pyx-qa"

    try {
        $condition2 = New-AzMetricAlertRuleV2Criteria `
            -MetricName "dependencies/duration" `
            -MetricNamespace "Microsoft.Insights/components" `
            -TimeAggregation Average `
            -Operator GreaterThan `
            -Threshold 500

        if ($PSCmdlet.ShouldProcess("pyx-qa-dependency-duration-alert", "Create metric alert")) {
            $alertParams2 = @{
                Name              = "pyx-qa-dependency-duration-alert"
                ResourceGroupName = $ResourceGroup
                TargetResourceId  = $pyxResourceId
                Condition         = $condition2
                WindowSize        = (New-TimeSpan -Minutes 5)
                Frequency         = (New-TimeSpan -Minutes 1)
                Severity          = 2
                Description       = "Alert: pyx-qa SQL dependency duration > 500ms (normal: ~0ms)"
            }

            if ($ActionGroupName) {
                $ag = Get-AzActionGroup -ResourceGroupName $ResourceGroup -Name $ActionGroupName
                $alertParams2["ActionGroupId"] = $ag.Id
            }

            Add-AzMetricAlertRuleV2 @alertParams2
            Write-Log "[OK] Created alert: pyx-qa-dependency-duration-alert" "SUCCESS"
        }
    }
    catch {
        Write-Log "Failed to create pyx-qa alert: $($_.Exception.Message)" "ERROR"
    }

    # Alert 3: Databricks cluster provisioning failures (via Activity Log)
    Write-Log "`n  Note: For Databricks-specific alerts, also set up alerts in the" "INFO"
    Write-Log "  Databricks workspace: Workspace Settings > Notifications" "INFO"
}

function Write-AzureCliAlertCommands {
    Write-Log "Copy and run these Azure CLI commands:`n"

    $sub = if ($SubscriptionId) { $SubscriptionId } else { "<your-subscription-id>" }
    $rg  = if ($ResourceGroup)  { $ResourceGroup }  else { "<your-resource-group>" }

    $commands = @"

# -------------------------------------------------------
# 1. Alert: func-memberimport-prod response time > 2s
# -------------------------------------------------------
az monitor metrics alert create ``
  --name "func-memberimport-response-time-alert" ``
  --resource-group "$rg" ``
  --scopes "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/sites/func-memberimport-prod" ``
  --condition "avg HttpResponseTime > 2" ``
  --window-size 5m ``
  --evaluation-frequency 1m ``
  --severity 2 ``
  --description "Response time exceeded 2s (normal: 1.24s)"

# -------------------------------------------------------
# 2. Alert: pyx-qa SQL dependency > 500ms
# -------------------------------------------------------
az monitor metrics alert create ``
  --name "pyx-qa-dependency-duration-alert" ``
  --resource-group "$rg" ``
  --scopes "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Insights/components/pyx-qa" ``
  --condition "avg dependencies/duration > 500" ``
  --window-size 5m ``
  --evaluation-frequency 1m ``
  --severity 2 ``
  --description "SQL dependency duration exceeded 500ms (normal: ~0ms)"

# -------------------------------------------------------
# 3. Check current vCPU quota usage
# -------------------------------------------------------
az vm list-usage --location "$Location" --output table | Select-String -Pattern "vCPU|Core"

# -------------------------------------------------------
# 4. Request quota increase (update family name as needed)
# -------------------------------------------------------
az quota create ``
  --resource-name "StandardDSv3Family" ``
  --scope "/subscriptions/$sub/providers/Microsoft.Compute/locations/$Location" ``
  --limit-object value=200 limit-object-type=LimitValue ``
  --resource-type dedicated

"@

    Write-Host $commands
    
    # Also save to file
    $cliPath = Join-Path (Split-Path $LogPath) "azure_alert_commands.ps1"
    Set-Content -Path $cliPath -Value $commands
    Write-Log "`nCommands saved to: $cliPath" "SUCCESS"
}

# ============================================================================
# PART 4: QUOTA INCREASE REQUEST
# ============================================================================

function Invoke-QuotaRequest {
    Write-Banner "AZURE VCPU QUOTA CHECK & INCREASE"

    if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
        Write-Log "Az.Compute module not available." "WARN"
        Write-Log "`nManual steps to request quota increase:" "INFO"
        Write-Log "  1. Go to: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" "INFO"
        Write-Log "  2. Filter by: Provider = Microsoft.Compute, Location = $Location" "INFO"
        Write-Log "  3. Find the VM family used by your Databricks clusters" "INFO"
        Write-Log "  4. Click 'Request Increase' and set to 2x your current peak" "INFO"
        Write-Log "`n  Or via CLI:"
        Write-Log "  az vm list-usage --location $Location --output table"
        return
    }

    try {
        if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
            Write-Log "Run Connect-AzAccount first." "WARN"
            return
        }

        Write-Log "Checking vCPU usage in $Location...`n"
        $usages = Get-AzVMUsage -Location $Location

        $critical = $usages | Where-Object {
            $_.Name.Value -match "vCPU|core|Standard" -and
            $_.Limit -gt 0 -and
            $_.CurrentValue -gt 0
        } | Sort-Object { $_.CurrentValue / $_.Limit } -Descending | Select-Object -First 15

        Write-Log ("{0,-50} {1,8} {2,8} {3,8}" -f "Family", "Used", "Limit", "Usage%")
        Write-Log ("-" * 80)

        foreach ($u in $critical) {
            $pct = [math]::Round(($u.CurrentValue / $u.Limit) * 100, 1)
            $color = if ($pct -gt 85) { "ERROR" } elseif ($pct -gt 70) { "WARN" } else { "INFO" }
            Write-Log ("{0,-50} {1,8} {2,8} {3,7}%" -f $u.Name.LocalizedValue, $u.CurrentValue, $u.Limit, $pct) $color
        }

        $overloaded = $critical | Where-Object { ($_.CurrentValue / $_.Limit) -gt 0.80 }
        if ($overloaded) {
            Write-Log "`nRECOMMENDATION: Request quota increase for the above high-usage families." "WARN"
            Write-Log "Target: 2x current peak usage.`n" "WARN"

            foreach ($o in $overloaded) {
                $newLimit = [Math]::Max($o.Limit * 2, $o.CurrentValue * 2.5)
                Write-Log "  $($o.Name.LocalizedValue): Current limit $($o.Limit) -> Recommended $([int]$newLimit)" "WARN"
            }
        }
        else {
            Write-Log "`nvCPU quota is not the bottleneck. Check Databricks workspace limits." "SUCCESS"
        }
    }
    catch {
        Write-Log "Quota check failed: $($_.Exception.Message)" "ERROR"
    }
}

# ============================================================================
# SUMMARY & NEXT STEPS
# ============================================================================

function Write-Summary {
    Write-Banner "EXECUTION SUMMARY"

    if ($script:IssuesFound.Count -gt 0) {
        Write-Log "Issues Found: $($script:IssuesFound.Count)" "WARN"
        $script:IssuesFound | ForEach-Object { Write-Log "  - $_" "WARN" }
    }

    if ($script:FixesApplied.Count -gt 0) {
        Write-Log "`nFixes Applied: $($script:FixesApplied.Count)" "SUCCESS"
        $script:FixesApplied | ForEach-Object { Write-Log "  - $_" "SUCCESS" }
    }

    Write-Banner "NEXT STEPS"
    Write-Log @"

  1. REPLY TO DATABRICKS SUPPORT (Ticket 500Vp00000IrEJdIAM):
     - Confirm whether the original fix resolved the issue
     - Ask Rolando to check workspace-level throttling
     - Open separate ticket for billing as recommended

  2. AZURE QUOTA (if vCPU > 80%):
     Portal -> Subscriptions -> Usage + Quotas -> Request Increase
     Target: 2x your current peak for the VM family Databricks uses

  3. MONITOR for 24-48 hours:
     - Watch Azure Smart Detection for new alerts on:
       * func-memberimport-prod (should stay under 2s)
       * pyx-qa SQL dependency (should stay under 500ms)
     - Check Databricks cluster Events tab for provisioning errors

  4. ASSIGN CLUSTER POLICY:
     - Go to Databricks -> Compute -> Policies
     - Assign "Quota-Safe Production Policy" to all job clusters
     - This prevents future quota exhaustion from uncontrolled scaling

  5. LOG FILE: $LogPath

"@
}

# ============================================================================
# MAIN
# ============================================================================

Test-Prerequisites

switch ($Mode) {
    "diagnose" {
        Invoke-Diagnose
    }
    "fix" {
        Invoke-Fix
    }
    "alerts" {
        Invoke-SetupAlerts
    }
    "quota" {
        Invoke-QuotaRequest
    }
    "all" {
        Invoke-Diagnose
        Invoke-Fix
        Invoke-SetupAlerts
        Invoke-QuotaRequest
    }
}

Write-Summary

Write-Log "`nDone. Log saved to: $LogPath" "SUCCESS"
