#Requires -Version 5.1
<#
.SYNOPSIS
    Databricks Quota & Performance Degradation - Auto-Discover, Diagnose & Fix
.DESCRIPTION
    Automatically finds your Databricks workspace(s), subscription, resource group,
    and generates a token — then diagnoses and fixes quota/performance issues.

    NO MANUAL CONFIGURATION NEEDED. Just run it.

.PARAMETER Mode
    diagnose     - Check clusters, jobs, and Azure vCPU quota
    fix          - Apply autoscale, auto-termination, Spark configs
    alerts       - Create Azure Monitor metric alerts
    quota        - Request Azure vCPU quota increase
    all          - Run everything

.EXAMPLE
    .\DatabricksQuotaFix.ps1 -Mode diagnose
    .\DatabricksQuotaFix.ps1 -Mode fix -WhatIf
    .\DatabricksQuotaFix.ps1 -Mode all
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("diagnose", "fix", "alerts", "quota", "all")]
    [string]$Mode,

    [Parameter()]
    [int]$AutoTerminationMinutes = 30,

    [Parameter()]
    [int]$MaxWorkersDefault = 10,

    [Parameter()]
    [string]$LogPath = ".\DatabricksQuotaFix_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
)

# ============================================================================
# SETUP
# ============================================================================

$ErrorActionPreference = "Stop"
$script:IssuesFound = [System.Collections.ArrayList]::new()
$script:FixesApplied = [System.Collections.ArrayList]::new()
$script:DatabricksHost = ""
$script:DatabricksToken = ""
$script:SubscriptionId = ""
$script:ResourceGroup = ""
$script:Location = ""
$script:UseAadAuth = $false
$script:MgmtToken = ""
$script:AadToken = ""

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

# ============================================================================
# AUTO-DISCOVERY — FINDS EVERYTHING AUTOMATICALLY
# ============================================================================

function Initialize-AutoDiscovery {
    Write-Banner "AUTO-DISCOVERING AZURE & DATABRICKS RESOURCES"

    # --- Step 1: Ensure Az module is loaded ---
    Write-Log "Checking Az PowerShell module..."
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Log "Az module not installed. Installing now..." "WARN"
        Install-Module Az -Force -AllowClobber -Scope CurrentUser
    }
    Import-Module Az.Accounts -ErrorAction SilentlyContinue
    Import-Module Az.Resources -ErrorAction SilentlyContinue
    Import-Module Az.Compute -ErrorAction SilentlyContinue

    # --- Step 2: Ensure logged into Azure ---
    Write-Log "Checking Azure login..."
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        Write-Log "Not logged into Azure. Launching login..." "WARN"
        Connect-AzAccount | Out-Null
        $context = Get-AzContext
    }
    Write-Log "Logged in as: $($context.Account.Id)" "SUCCESS"
    $script:SubscriptionId = $context.Subscription.Id
    Write-Log "Subscription: $($context.Subscription.Name) ($($script:SubscriptionId))" "SUCCESS"

    # --- Step 3: Find all Databricks workspaces ---
    Write-Log "`nSearching for Databricks workspaces..."
    $databricksResources = Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" -ErrorAction SilentlyContinue

    if (-not $databricksResources -or $databricksResources.Count -eq 0) {
        Write-Log "None found in current subscription. Checking all subscriptions..." "WARN"
        $allSubs = Get-AzSubscription
        foreach ($sub in $allSubs) {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
            $databricksResources = Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" -ErrorAction SilentlyContinue
            if ($databricksResources -and $databricksResources.Count -gt 0) {
                $script:SubscriptionId = $sub.Id
                Write-Log "Found workspaces in subscription: $($sub.Name)" "SUCCESS"
                break
            }
        }
    }

    if (-not $databricksResources -or $databricksResources.Count -eq 0) {
        Write-Log "No Databricks workspaces found in any subscription!" "ERROR"
        exit 1
    }

    # --- Step 4: Pick workspace if multiple ---
    $selectedWorkspace = $null
    if ($databricksResources.Count -eq 1) {
        $selectedWorkspace = $databricksResources[0]
        Write-Log "Found 1 workspace: $($selectedWorkspace.Name)" "SUCCESS"
    }
    else {
        Write-Log "`nFound $($databricksResources.Count) Databricks workspaces:" "INFO"
        for ($i = 0; $i -lt $databricksResources.Count; $i++) {
            $ws = $databricksResources[$i]
            Write-Host "  [$($i + 1)] $($ws.Name) (RG: $($ws.ResourceGroupName), Location: $($ws.Location))" -ForegroundColor Cyan
        }
        Write-Host ""
        do {
            $selection = Read-Host "Select workspace number (1-$($databricksResources.Count))"
        } while ([int]$selection -lt 1 -or [int]$selection -gt $databricksResources.Count)

        $selectedWorkspace = $databricksResources[[int]$selection - 1]
    }

    $script:ResourceGroup = $selectedWorkspace.ResourceGroupName
    $script:Location = $selectedWorkspace.Location
    Write-Log "Workspace:      $($selectedWorkspace.Name)" "SUCCESS"
    Write-Log "Resource Group: $($script:ResourceGroup)" "SUCCESS"
    Write-Log "Location:       $($script:Location)" "SUCCESS"

    # --- Step 5: Get workspace URL ---
    Write-Log "`nGetting workspace URL..."
    $workspaceDetails = Get-AzResource -ResourceId $selectedWorkspace.ResourceId -ExpandProperties
    $workspaceUrl = $workspaceDetails.Properties.workspaceUrl

    if ($workspaceUrl) {
        $script:DatabricksHost = "https://$workspaceUrl"
    }
    else {
        $workspaceId = $workspaceDetails.Properties.workspaceId
        $script:DatabricksHost = "https://adb-$workspaceId.azuredatabricks.net"
    }
    Write-Log "Workspace URL: $($script:DatabricksHost)" "SUCCESS"

    # --- Step 6: Auto-generate token ---
    Write-Log "`nGenerating Databricks access token..."
    $script:DatabricksToken = Get-DatabricksTokenAuto

    if ([string]::IsNullOrWhiteSpace($script:DatabricksToken)) {
        Write-Log "Could not auto-generate token." "ERROR"
        exit 1
    }
    Write-Log "Token acquired." "SUCCESS"

    # --- Step 7: Test connection ---
    Write-Log "`nTesting Databricks API connection..."
    try {
        $testResult = Invoke-DatabricksApi -Endpoint "/clusters/list"
        $clusterCount = if ($testResult.clusters) { $testResult.clusters.Count } else { 0 }
        Write-Log "Connected! Found $clusterCount cluster(s).`n" "SUCCESS"
    }
    catch {
        Write-Log "Connection failed with AAD token. Trying fallback..." "WARN"
        $script:DatabricksToken = Get-DatabricksTokenFallback
        try {
            $testResult = Invoke-DatabricksApi -Endpoint "/clusters/list"
            $clusterCount = if ($testResult.clusters) { $testResult.clusters.Count } else { 0 }
            Write-Log "Fallback connected! Found $clusterCount cluster(s).`n" "SUCCESS"
        }
        catch {
            Write-Log "All auto-token methods failed." "ERROR"
            Write-Log "Falling back to manual PAT token entry..." "WARN"
            $script:DatabricksToken = Get-DatabricksTokenManual
            $testResult = Invoke-DatabricksApi -Endpoint "/clusters/list"
            Write-Log "Manual token worked.`n" "SUCCESS"
        }
    }
}

function Get-DatabricksTokenAuto {
    # Method 1: Azure AD token for Databricks resource
    try {
        $databricksAppId = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
        $tokenResult = Get-AzAccessToken -ResourceUrl $databricksAppId -ErrorAction Stop
        $token = $tokenResult.Token
        if ($token) {
            Write-Log "  Got Azure AD token for Databricks." "SUCCESS"
            return $token
        }
    }
    catch {
        Write-Log "  AAD token method failed: $($_.Exception.Message)" "WARN"
    }

    # Method 2: Azure CLI
    try {
        $cliCheck = Get-Command az -ErrorAction SilentlyContinue
        if ($cliCheck) {
            $cliToken = az account get-access-token --resource "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" --query accessToken -o tsv 2>$null
            if ($cliToken) {
                Write-Log "  Got token via Azure CLI." "SUCCESS"
                return $cliToken
            }
        }
    }
    catch {
        Write-Log "  Azure CLI method failed." "WARN"
    }

    return $null
}

function Get-DatabricksTokenFallback {
    try {
        $mgmtToken = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/" -ErrorAction Stop).Token
        $aadToken = (Get-AzAccessToken -ResourceUrl "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" -ErrorAction Stop).Token

        $script:UseAadAuth = $true
        $script:AadToken = $aadToken
        $script:MgmtToken = $mgmtToken

        Write-Log "  Got AAD + Management tokens for fallback auth." "SUCCESS"
        return $aadToken
    }
    catch {
        Write-Log "  Fallback token failed: $($_.Exception.Message)" "WARN"
        return Get-DatabricksTokenManual
    }
}

function Get-DatabricksTokenManual {
    Write-Host ""
    Write-Host "  =============================================" -ForegroundColor Yellow
    Write-Host "  AUTO-TOKEN FAILED — Manual PAT token needed" -ForegroundColor Yellow
    Write-Host "  =============================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Open: $($script:DatabricksHost)" -ForegroundColor Cyan
    Write-Host "  2. Click your username (top-right)" -ForegroundColor Cyan
    Write-Host "  3. User Settings -> Developer -> Access Tokens" -ForegroundColor Cyan
    Write-Host "  4. Generate New Token -> Copy it" -ForegroundColor Cyan
    Write-Host ""
    $manualToken = Read-Host "  Paste your PAT token here"
    return $manualToken
}

# ============================================================================
# API HELPERS
# ============================================================================

function Get-DatabricksHeaders {
    $headers = @{
        "Authorization" = "Bearer $($script:DatabricksToken)"
        "Content-Type"  = "application/json"
    }

    if ($script:UseAadAuth -and $script:MgmtToken) {
        $wsResourceId = (Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" -ResourceGroupName $script:ResourceGroup -ErrorAction SilentlyContinue | Select-Object -First 1).ResourceId
        if ($wsResourceId) {
            $headers["X-Databricks-Azure-SP-Management-Token"] = $script:MgmtToken
            $headers["X-Databricks-Azure-Workspace-Resource-Id"] = $wsResourceId
        }
    }

    return $headers
}

function Invoke-DatabricksApi {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [hashtable]$Body = $null
    )
    $uri = "$($script:DatabricksHost)/api/2.0$Endpoint"
    $params = @{
        Uri     = $uri
        Method  = $Method
        Headers = Get-DatabricksHeaders
    }
    if ($Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10)
    }
    $response = Invoke-RestMethod @params
    return $response
}

function Invoke-DatabricksApi21 {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [hashtable]$Body = $null,
        [hashtable]$QueryParams = @{}
    )
    $uri = "$($script:DatabricksHost)/api/2.1$Endpoint"
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
# PART 1: DIAGNOSE
# ============================================================================

function Invoke-Diagnose {
    Write-Banner "DATABRICKS CLUSTER DIAGNOSTICS"

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
                [void]$script:IssuesFound.Add("[CLUSTER] '$name' autoscale max is only $($autoscale.max_workers). May bottleneck.")
            }
        }
        else {
            Write-Log "    Fixed size: $numW workers" "WARN"
            if ($state -eq "RUNNING") {
                [void]$script:IssuesFound.Add("[CLUSTER] '$name' uses FIXED sizing ($numW workers). Cannot scale.")
            }
        }

        if ($autoTerm -eq 0 -and $state -eq "RUNNING") {
            Write-Log "    Auto-terminate: DISABLED" "WARN"
            [void]$script:IssuesFound.Add("[CLUSTER] '$name' has NO auto-termination. Wastes quota when idle.")
        }
        elseif ($autoTerm) {
            Write-Log "    Auto-terminate: $autoTerm min"
        }

        $sparkConf = $c.spark_conf
        if ($sparkConf) {
            $adaptive = $sparkConf."spark.sql.adaptive.enabled"
            if ($adaptive -ne "true") {
                [void]$script:IssuesFound.Add("[CLUSTER] '$name' missing Adaptive Query Execution.")
            }
        }
        else {
            [void]$script:IssuesFound.Add("[CLUSTER] '$name' has no Spark optimization configs.")
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
                $msg = if ($fr.state.state_message) { $fr.state.state_message } else { "No message" }
                $truncMsg = $msg.Substring(0, [Math]::Min(150, $msg.Length))
                Write-Log "    - $($fr.run_name): $truncMsg" "WARN"
                if ($msg -match "quota|limit|capacity|resource") {
                    [void]$script:IssuesFound.Add("[JOB] '$($fr.run_name)' failed with resource/quota error.")
                }
            }
        }
        else {
            Write-Log "  No failed runs in last 48h." "SUCCESS"
        }

        if ($slowSetup -and $slowSetup.Count -gt 0) {
            Write-Log "$($slowSetup.Count) runs had cluster setup > 5 min (contention)" "WARN"
            [void]$script:IssuesFound.Add("[JOB] $($slowSetup.Count) runs had setup > 5 min — provisioning contention.")
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
        Write-Log "No obvious quota issues detected." "SUCCESS"
        Write-Log "Check Azure portal for workspace-level throttling."
    }
}

function Invoke-AzureQuotaCheck {
    Write-Log "`n--- Azure vCPU Quota Usage ($($script:Location)) ---"

    try {
        Import-Module Az.Compute -ErrorAction SilentlyContinue
        $usages = Get-AzVMUsage -Location $script:Location -ErrorAction Stop
        $highUsage = $usages | Where-Object {
            $_.Name.Value -match "vCPU|core|Standard" -and
            $_.Limit -gt 0 -and
            $_.CurrentValue -gt 0
        } | Sort-Object { if ($_.Limit -gt 0) { $_.CurrentValue / $_.Limit } else { 0 } } -Descending | Select-Object -First 15

        if ($highUsage) {
            Write-Log ("{0,-50} {1,8} {2,8} {3,8}" -f "VM Family", "Used", "Limit", "Usage%")
            Write-Log ("-" * 80)

            foreach ($u in $highUsage) {
                $pct = [math]::Round(($u.CurrentValue / $u.Limit) * 100, 1)
                $severity = if ($pct -gt 85) { "ERROR" } elseif ($pct -gt 70) { "WARN" } else { "INFO" }
                Write-Log ("{0,-50} {1,8} {2,8} {3,7}%" -f $u.Name.LocalizedValue, $u.CurrentValue, $u.Limit, $pct) $severity

                if ($pct -gt 80) {
                    [void]$script:IssuesFound.Add("[AZURE QUOTA] $($u.Name.LocalizedValue) at $pct% in $($script:Location).")
                }
            }
        }
        else {
            Write-Log "  All vCPU quotas are low usage." "SUCCESS"
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

        $edit = @{
            cluster_id    = $id
            cluster_name  = $name
            spark_version = $c.spark_version
            node_type_id  = $c.node_type_id
        }

        if ($c.driver_node_type_id) { $edit["driver_node_type_id"] = $c.driver_node_type_id }
        if ($c.azure_attributes)    { $edit["azure_attributes"] = $c.azure_attributes }
        if ($c.custom_tags)         { $edit["custom_tags"] = $c.custom_tags }

        # Fix 1: Autoscale
        if (-not $c.autoscale) {
            $currentWorkers = if ($c.num_workers) { $c.num_workers } else { 2 }
            $minW = [Math]::Max(1, [Math]::Floor($currentWorkers / 2))
            $maxW = [Math]::Min($MaxWorkersDefault, $currentWorkers * 2)
            $edit["autoscale"] = @{ min_workers = $minW; max_workers = $maxW }
            [void]$changes.Add("Enable autoscale: $minW-$maxW workers (was fixed $currentWorkers)")
        }
        else {
            $edit["autoscale"] = $c.autoscale
            if ($c.autoscale.max_workers -lt 4) {
                $newMax = [Math]::Max($c.autoscale.max_workers, 8)
                $edit["autoscale"] = @{ min_workers = $c.autoscale.min_workers; max_workers = $newMax }
                [void]$changes.Add("Increased autoscale max: $($c.autoscale.max_workers) -> $newMax")
            }
        }

        # Fix 2: Auto-termination
        if (-not $c.autotermination_minutes -or $c.autotermination_minutes -eq 0) {
            $edit["autotermination_minutes"] = $AutoTerminationMinutes
            [void]$changes.Add("Set auto-termination to $AutoTerminationMinutes min")
        }
        else {
            $edit["autotermination_minutes"] = $c.autotermination_minutes
        }

        # Fix 3: Spark configs
        $existingConf = @{}
        if ($c.spark_conf) {
            $c.spark_conf.PSObject.Properties | ForEach-Object { $existingConf[$_.Name] = $_.Value }
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
            [void]$changes.Add("Added $addedConfigs Spark optimization configs")
        }
        $edit["spark_conf"] = $existingConf

        # Apply
        if ($changes.Count -gt 0) {
            Write-Log "  Changes:"
            foreach ($ch in $changes) { Write-Log "    + $ch" "SUCCESS" }

            if ($PSCmdlet.ShouldProcess($name, "Apply cluster optimizations")) {
                try {
                    Invoke-DatabricksApi -Endpoint "/clusters/edit" -Method "POST" -Body $edit | Out-Null
                    Write-Log "  [OK] Updated '$name'" "SUCCESS"
                    [void]$script:FixesApplied.Add("Cluster '$name': $($changes -join '; ')")
                }
                catch {
                    Write-Log "  [FAIL] '$name': $($_.Exception.Message)" "ERROR"
                }
            }
        }
        else {
            Write-Log "  No changes needed." "SUCCESS"
        }
    }

    Invoke-CreateClusterPolicy
}

function Invoke-CreateClusterPolicy {
    Write-Banner "CREATING QUOTA-SAFE CLUSTER POLICY"

    $policyDef = @{
        "autoscale.min_workers" = @{ type = "range"; minValue = 1; maxValue = 4; defaultValue = 1 }
        "autoscale.max_workers" = @{ type = "range"; minValue = 2; maxValue = 20; defaultValue = 8 }
        "autotermination_minutes" = @{ type = "range"; minValue = 10; maxValue = 120; defaultValue = 30 }
        "spark_conf.spark.sql.adaptive.enabled" = @{ type = "fixed"; value = "true"; hidden = $true }
        "spark_conf.spark.databricks.adaptive.autoOptimizeShuffle.enabled" = @{ type = "fixed"; value = "true"; hidden = $true }
        "spark_conf.spark.databricks.delta.optimizeWrite.enabled" = @{ type = "fixed"; value = "true"; hidden = $true }
        "spark_conf.spark.databricks.delta.autoCompact.enabled" = @{ type = "fixed"; value = "true"; hidden = $true }
        "spark_conf.spark.databricks.io.cache.enabled" = @{ type = "fixed"; value = "true"; hidden = $true }
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
                [void]$script:FixesApplied.Add("Created cluster policy ($($result.policy_id))")
            }
        }
        catch {
            if ($_.Exception.Message -match "already exists") {
                Write-Log "Policy already exists. Skipping." "INFO"
            }
            else {
                Write-Log "Failed: $($_.Exception.Message)" "ERROR"
            }
        }
    }
}

# ============================================================================
# PART 3: ALERTS
# ============================================================================

function Invoke-SetupAlerts {
    Write-Banner "SETTING UP AZURE MONITOR ALERTS"

    Import-Module Az.Monitor -ErrorAction SilentlyContinue

    # Auto-find func-memberimport-prod
    Write-Log "Searching for func-memberimport-prod..."
    $funcApp = Get-AzResource -ResourceType "Microsoft.Web/sites" -Name "func-memberimport-prod" -ErrorAction SilentlyContinue

    if ($funcApp) {
        Write-Log "Found: $($funcApp.ResourceId)" "SUCCESS"
        try {
            $condition1 = New-AzMetricAlertRuleV2Criteria `
                -MetricName "HttpResponseTime" `
                -MetricNamespace "Microsoft.Web/sites" `
                -TimeAggregation Average `
                -Operator GreaterThan `
                -Threshold 2.0

            if ($PSCmdlet.ShouldProcess("func-memberimport-response-time-alert", "Create alert")) {
                Add-AzMetricAlertRuleV2 `
                    -Name "func-memberimport-response-time-alert" `
                    -ResourceGroupName $funcApp.ResourceGroupName `
                    -TargetResourceId $funcApp.ResourceId `
                    -Condition $condition1 `
                    -WindowSize (New-TimeSpan -Minutes 5) `
                    -Frequency (New-TimeSpan -Minutes 1) `
                    -Severity 2 `
                    -Description "Response time > 2s (normal: 1.24s)"
                Write-Log "[OK] Created alert: func-memberimport-response-time-alert" "SUCCESS"
                [void]$script:FixesApplied.Add("Alert: func-memberimport-response-time")
            }
        }
        catch {
            Write-Log "Failed: $($_.Exception.Message)" "ERROR"
        }
    }
    else {
        Write-Log "func-memberimport-prod not found in subscription." "WARN"
    }

    # Auto-find pyx-qa
    Write-Log "`nSearching for pyx-qa..."
    $pyxApp = Get-AzResource -ResourceType "Microsoft.Insights/components" -Name "pyx-qa" -ErrorAction SilentlyContinue

    if ($pyxApp) {
        Write-Log "Found: $($pyxApp.ResourceId)" "SUCCESS"
        try {
            $condition2 = New-AzMetricAlertRuleV2Criteria `
                -MetricName "dependencies/duration" `
                -MetricNamespace "Microsoft.Insights/components" `
                -TimeAggregation Average `
                -Operator GreaterThan `
                -Threshold 500

            if ($PSCmdlet.ShouldProcess("pyx-qa-dependency-duration-alert", "Create alert")) {
                Add-AzMetricAlertRuleV2 `
                    -Name "pyx-qa-dependency-duration-alert" `
                    -ResourceGroupName $pyxApp.ResourceGroupName `
                    -TargetResourceId $pyxApp.ResourceId `
                    -Condition $condition2 `
                    -WindowSize (New-TimeSpan -Minutes 5) `
                    -Frequency (New-TimeSpan -Minutes 1) `
                    -Severity 2 `
                    -Description "SQL dependency > 500ms (normal: ~0ms)"
                Write-Log "[OK] Created alert: pyx-qa-dependency-duration-alert" "SUCCESS"
                [void]$script:FixesApplied.Add("Alert: pyx-qa-dependency-duration")
            }
        }
        catch {
            Write-Log "Failed: $($_.Exception.Message)" "ERROR"
        }
    }
    else {
        Write-Log "pyx-qa not found in subscription." "WARN"
    }
}

# ============================================================================
# PART 4: QUOTA
# ============================================================================

function Invoke-QuotaRequest {
    Write-Banner "AZURE VCPU QUOTA ANALYSIS"

    try {
        Import-Module Az.Compute -ErrorAction SilentlyContinue
        $usages = Get-AzVMUsage -Location $script:Location -ErrorAction Stop

        $all = $usages | Where-Object {
            $_.Limit -gt 0 -and $_.CurrentValue -gt 0
        } | Sort-Object { $_.CurrentValue / $_.Limit } -Descending | Select-Object -First 20

        Write-Log ("{0,-50} {1,8} {2,8} {3,8}" -f "VM Family", "Used", "Limit", "Usage%")
        Write-Log ("-" * 80)

        foreach ($u in $all) {
            $pct = [math]::Round(($u.CurrentValue / $u.Limit) * 100, 1)
            $severity = if ($pct -gt 85) { "ERROR" } elseif ($pct -gt 70) { "WARN" } else { "INFO" }
            Write-Log ("{0,-50} {1,8} {2,8} {3,7}%" -f $u.Name.LocalizedValue, $u.CurrentValue, $u.Limit, $pct) $severity
        }

        $overloaded = $all | Where-Object { ($_.CurrentValue / $_.Limit) -gt 0.80 }
        if ($overloaded) {
            Write-Log "`nQUOTA INCREASE NEEDED:" "WARN"
            foreach ($o in $overloaded) {
                $newLimit = [Math]::Max($o.Limit * 2, $o.CurrentValue * 2.5)
                Write-Log "  $($o.Name.LocalizedValue): $($o.Limit) -> $([int]$newLimit)" "WARN"
            }
            Write-Log "`n  Portal: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" "INFO"
        }
        else {
            Write-Log "`nvCPU quota is healthy. Check Databricks workspace limits." "SUCCESS"
        }
    }
    catch {
        Write-Log "Quota check failed: $($_.Exception.Message)" "ERROR"
    }
}

# ============================================================================
# SUMMARY
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

  1. DATABRICKS SUPPORT (Ticket 500Vp00000IrEJdIAM):
     Reply to Rolando — confirm fix status, ask about throttling

  2. AZURE QUOTA (if any showed > 80%):
     Portal -> Subscriptions -> Usage + Quotas -> Request Increase

  3. MONITOR 24-48h for new Smart Detection alerts

  4. ASSIGN CLUSTER POLICY in Databricks UI:
     Compute -> Policies -> "Quota-Safe Production Policy"

  5. LOG: $LogPath

"@
}

# ============================================================================
# MAIN — JUST RUN IT
# ============================================================================

Initialize-AutoDiscovery

switch ($Mode) {
    "diagnose" { Invoke-Diagnose }
    "fix"      { Invoke-Fix }
    "alerts"   { Invoke-SetupAlerts }
    "quota"    { Invoke-QuotaRequest }
    "all" {
        Invoke-Diagnose
        Invoke-Fix
        Invoke-SetupAlerts
        Invoke-QuotaRequest
    }
}

Write-Summary
Write-Log "`nDone. Log saved to: $LogPath" "SUCCESS"
