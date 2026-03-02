<#
.SYNOPSIS
    Databricks Health Check & Quota Fix - Auto Discovery
.DESCRIPTION
    Auto-finds your Databricks workspace, connects, diagnoses issues.
    No configuration needed. Just run it.
.EXAMPLE
    .\DB-HealthCheck.ps1 -Mode diagnose
    .\DB-HealthCheck.ps1 -Mode fix -WhatIf
    .\DB-HealthCheck.ps1 -Mode all
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("diagnose", "fix", "alerts", "quota", "all")]
    [string]$Mode,

    [int]$AutoTermMinutes = 30,
    [int]$MaxWorkers = 10
)

# ============================================================================
# GLOBALS
# ============================================================================
$script:WorkspaceUrl = ""
$script:Token = ""
$script:SubId = ""
$script:RG = ""
$script:Loc = ""
$script:Issues = @()
$script:Fixes = @()
$LogFile = ".\DB-HealthCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Log {
    param([string]$Msg, [string]$Lvl = "INFO")
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Lvl] $Msg"
    switch ($Lvl) {
        "ERR"  { Write-Host $line -ForegroundColor Red }
        "WARN" { Write-Host $line -ForegroundColor Yellow }
        "OK"   { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    $line | Out-File -Append -FilePath $LogFile -ErrorAction SilentlyContinue
}

function Banner([string]$Title) {
    Log ("=" * 60)
    Log $Title
    Log ("=" * 60)
}

# ============================================================================
# STEP 1: CHECK PREREQUISITES
# ============================================================================
function Test-Setup {
    Banner "STEP 1: CHECKING PREREQUISITES"

    # Check Az module
    $azMod = Get-Module -ListAvailable -Name Az.Accounts -ErrorAction SilentlyContinue
    if (-not $azMod) {
        Log "Az module not found. Installing..." "WARN"
        try {
            Install-Module Az.Accounts -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
            Install-Module Az.Resources -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
            Install-Module Az.Compute -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
            Log "Az modules installed." "OK"
        }
        catch {
            Log "Could not install Az module: $($_.Exception.Message)" "ERR"
            Log "Run this manually first: Install-Module Az -Force -Scope CurrentUser" "ERR"
            return $false
        }
    }
    else {
        Log "Az module found." "OK"
    }

    # Import modules
    try {
        Import-Module Az.Accounts -Force -ErrorAction Stop
        Log "Az.Accounts loaded." "OK"
    }
    catch {
        Log "Cannot load Az.Accounts: $($_.Exception.Message)" "ERR"
        return $false
    }

    try { Import-Module Az.Resources -Force -ErrorAction SilentlyContinue } catch {}
    try { Import-Module Az.Compute -Force -ErrorAction SilentlyContinue } catch {}
    try { Import-Module Az.Monitor -Force -ErrorAction SilentlyContinue } catch {}

    return $true
}

# ============================================================================
# STEP 2: AZURE LOGIN
# ============================================================================
function Connect-Azure {
    Banner "STEP 2: AZURE LOGIN"

    $ctx = $null
    try {
        $ctx = Get-AzContext -ErrorAction Stop
    }
    catch {
        $ctx = $null
    }

    if (-not $ctx -or -not $ctx.Account) {
        Log "Not logged in. Opening Azure login..." "WARN"
        try {
            Connect-AzAccount -ErrorAction Stop | Out-Null
            $ctx = Get-AzContext -ErrorAction Stop
        }
        catch {
            Log "Azure login failed: $($_.Exception.Message)" "ERR"
            return $false
        }
    }

    $script:SubId = $ctx.Subscription.Id
    Log "Logged in as: $($ctx.Account.Id)" "OK"
    Log "Subscription: $($ctx.Subscription.Name)" "OK"
    return $true
}

# ============================================================================
# STEP 3: FIND DATABRICKS WORKSPACE
# ============================================================================
function Find-Workspace {
    Banner "STEP 3: FINDING DATABRICKS WORKSPACE"

    $workspaces = $null
    try {
        $workspaces = Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" -ErrorAction Stop
    }
    catch {
        Log "Error searching for workspaces: $($_.Exception.Message)" "ERR"
        return $false
    }

    if (-not $workspaces -or @($workspaces).Count -eq 0) {
        Log "No Databricks workspaces in this subscription." "WARN"
        Log "Checking other subscriptions..." "WARN"

        try {
            $subs = Get-AzSubscription -ErrorAction Stop
            foreach ($s in $subs) {
                try {
                    Set-AzContext -SubscriptionId $s.Id -ErrorAction Stop | Out-Null
                    $workspaces = Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" -ErrorAction Stop
                    if ($workspaces -and @($workspaces).Count -gt 0) {
                        $script:SubId = $s.Id
                        Log "Found in subscription: $($s.Name)" "OK"
                        break
                    }
                }
                catch { continue }
            }
        }
        catch {
            Log "Error checking subscriptions: $($_.Exception.Message)" "ERR"
        }
    }

    if (-not $workspaces -or @($workspaces).Count -eq 0) {
        Log "No Databricks workspaces found anywhere." "ERR"
        return $false
    }

    # Force array
    $workspaces = @($workspaces)

    $ws = $null
    if ($workspaces.Count -eq 1) {
        $ws = $workspaces[0]
        Log "Found workspace: $($ws.Name)" "OK"
    }
    else {
        Log "Found $($workspaces.Count) workspaces:" "INFO"
        for ($i = 0; $i -lt $workspaces.Count; $i++) {
            Write-Host "  [$($i+1)] $($workspaces[$i].Name)  (RG: $($workspaces[$i].ResourceGroupName))" -ForegroundColor Cyan
        }
        Write-Host ""
        $pick = Read-Host "Pick a number (1-$($workspaces.Count))"
        $idx = [int]$pick - 1
        if ($idx -lt 0 -or $idx -ge $workspaces.Count) { $idx = 0 }
        $ws = $workspaces[$idx]
    }

    $script:RG = $ws.ResourceGroupName
    $script:Loc = $ws.Location

    # Get URL
    try {
        $detail = Get-AzResource -ResourceId $ws.ResourceId -ExpandProperties -ErrorAction Stop
        $url = $detail.Properties.workspaceUrl
        if ($url) {
            $script:WorkspaceUrl = "https://$url"
        }
        else {
            $wid = $detail.Properties.workspaceId
            $script:WorkspaceUrl = "https://adb-$wid.azuredatabricks.net"
        }
    }
    catch {
        Log "Could not get workspace URL: $($_.Exception.Message)" "ERR"
        return $false
    }

    Log "Workspace:  $($ws.Name)" "OK"
    Log "URL:        $($script:WorkspaceUrl)" "OK"
    Log "RG:         $($script:RG)" "OK"
    Log "Location:   $($script:Loc)" "OK"

    return $true
}

# ============================================================================
# STEP 4: GET TOKEN
# ============================================================================
function Get-Token {
    Banner "STEP 4: GETTING DATABRICKS API TOKEN"

    $dbAppId = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

    # Try method 1: Az PowerShell
    Log "Trying Azure AD token..."
    try {
        $result = Get-AzAccessToken -ResourceUrl $dbAppId -ErrorAction Stop
        if ($result -and $result.Token) {
            $script:Token = $result.Token
            Log "Got token via Azure AD." "OK"
            return $true
        }
    }
    catch {
        Log "Azure AD method failed: $($_.Exception.Message)" "WARN"
    }

    # Try method 2: Az CLI
    Log "Trying Azure CLI..."
    try {
        $check = Get-Command az -ErrorAction SilentlyContinue
        if ($check) {
            $t = & az account get-access-token --resource $dbAppId --query accessToken -o tsv 2>$null
            if ($t -and $t.Length -gt 20) {
                $script:Token = $t
                Log "Got token via Azure CLI." "OK"
                return $true
            }
        }
    }
    catch {
        Log "Azure CLI method failed." "WARN"
    }

    # Method 3: Ask user
    Log "Auto-token failed. Need manual PAT token." "WARN"
    Write-Host ""
    Write-Host "  ================================================" -ForegroundColor Yellow
    Write-Host "  HOW TO GET YOUR TOKEN (takes 30 seconds):" -ForegroundColor Yellow
    Write-Host "  ================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Open: $($script:WorkspaceUrl)" -ForegroundColor Cyan
    Write-Host "  2. Click your name (top-right corner)" -ForegroundColor Cyan
    Write-Host "  3. Click 'User Settings'" -ForegroundColor Cyan
    Write-Host "  4. Click 'Developer' tab" -ForegroundColor Cyan
    Write-Host "  5. Click 'Access Tokens'" -ForegroundColor Cyan
    Write-Host "  6. Click 'Generate New Token'" -ForegroundColor Cyan
    Write-Host "  7. Set lifetime to 1 day, click Generate" -ForegroundColor Cyan
    Write-Host "  8. Copy the token and paste below" -ForegroundColor Cyan
    Write-Host ""
    $manual = Read-Host "  Paste token here"

    if ($manual -and $manual.Length -gt 5) {
        $script:Token = $manual.Trim()
        Log "Manual token entered." "OK"
        return $true
    }

    Log "No token provided." "ERR"
    return $false
}

# ============================================================================
# STEP 5: TEST CONNECTION
# ============================================================================
function Test-Connection {
    Banner "STEP 5: TESTING CONNECTION"

    try {
        $headers = @{
            "Authorization" = "Bearer $($script:Token)"
            "Content-Type"  = "application/json"
        }
        $resp = Invoke-RestMethod -Uri "$($script:WorkspaceUrl)/api/2.0/clusters/list" -Headers $headers -Method Get -ErrorAction Stop
        $count = if ($resp.clusters) { @($resp.clusters).Count } else { 0 }
        Log "Connected! Found $count cluster(s)." "OK"
        return $true
    }
    catch {
        Log "Connection failed: $($_.Exception.Message)" "ERR"
        Log "Token may be expired or workspace URL incorrect." "ERR"
        return $false
    }
}

# ============================================================================
# API HELPER
# ============================================================================
function Call-DB {
    param([string]$Path, [string]$Method = "GET", [hashtable]$Body = $null, [string]$ApiVer = "2.0")

    $headers = @{
        "Authorization" = "Bearer $($script:Token)"
        "Content-Type"  = "application/json"
    }
    $uri = "$($script:WorkspaceUrl)/api/$ApiVer$Path"
    $params = @{ Uri = $uri; Headers = $headers; Method = $Method; ErrorAction = "Stop" }

    if ($Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10)
    }

    return Invoke-RestMethod @params
}

# ============================================================================
# DIAGNOSE
# ============================================================================
function Run-Diagnose {
    Banner "DIAGNOSING DATABRICKS CLUSTERS"

    # --- Clusters ---
    Log ""
    Log "--- CLUSTERS ---"
    try {
        $data = Call-DB -Path "/clusters/list"
        $clusters = @()
        if ($data.clusters) { $clusters = @($data.clusters) }
    }
    catch {
        Log "Could not list clusters: $($_.Exception.Message)" "ERR"
        return
    }

    if ($clusters.Count -eq 0) {
        Log "No clusters found." "WARN"
        return
    }

    Log "Found $($clusters.Count) cluster(s)"
    Log ""

    foreach ($c in $clusters) {
        $name  = $c.cluster_name
        $state = $c.state
        $id    = $c.cluster_id

        Log "  CLUSTER: $name"
        Log "    ID:      $id"
        Log "    State:   $state"
        Log "    Driver:  $($c.driver_node_type_id)"
        Log "    Worker:  $($c.node_type_id)"

        # Autoscale check
        if ($c.autoscale) {
            $min = $c.autoscale.min_workers
            $max = $c.autoscale.max_workers
            Log "    Scale:   Autoscale $min - $max workers" "OK"
            if ($max -lt 4 -and $state -eq "RUNNING") {
                $script:Issues += "[CLUSTER] '$name' max workers only $max — may bottleneck."
            }
        }
        else {
            $w = if ($c.num_workers) { $c.num_workers } else { 0 }
            Log "    Scale:   FIXED $w workers" "WARN"
            if ($state -eq "RUNNING") {
                $script:Issues += "[CLUSTER] '$name' uses FIXED sizing ($w workers). Cannot scale."
            }
        }

        # Auto-terminate check
        $at = $c.autotermination_minutes
        if (-not $at -or $at -eq 0) {
            Log "    AutoOff: DISABLED" "WARN"
            if ($state -eq "RUNNING") {
                $script:Issues += "[CLUSTER] '$name' has NO auto-termination. Wastes quota when idle."
            }
        }
        else {
            Log "    AutoOff: $at min"
        }

        # Spark config check
        if ($c.spark_conf) {
            $aqe = $c.spark_conf."spark.sql.adaptive.enabled"
            if ($aqe -eq "true") {
                Log "    AQE:     Enabled" "OK"
            }
            else {
                Log "    AQE:     Not enabled" "WARN"
                $script:Issues += "[CLUSTER] '$name' missing Adaptive Query Execution."
            }
        }
        else {
            Log "    Configs: None set" "WARN"
            $script:Issues += "[CLUSTER] '$name' has no Spark optimization configs."
        }

        Log ""
    }

    # --- Job Failures ---
    Log "--- JOB FAILURES (last 48h) ---"
    try {
        $nowMs = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        $agoMs = [long]([DateTimeOffset]::UtcNow.AddHours(-48).ToUnixTimeMilliseconds())

        $runs = Call-DB -Path "/jobs/runs/list?start_time_from=$agoMs&start_time_to=$nowMs&limit=100" -ApiVer "2.1"

        if ($runs.runs) {
            $allRuns = @($runs.runs)
            $failed = @($allRuns | Where-Object { $_.state.result_state -in @("FAILED","TIMEDOUT","CANCELED") })
            $slow   = @($allRuns | Where-Object { $_.setup_duration -and ($_.setup_duration / 1000) -gt 300 })

            if ($failed.Count -gt 0) {
                Log "$($failed.Count) failed/timedout runs!" "WARN"
                foreach ($f in ($failed | Select-Object -First 5)) {
                    $msg = if ($f.state.state_message) { $f.state.state_message } else { "no details" }
                    if ($msg.Length -gt 100) { $msg = $msg.Substring(0, 100) + "..." }
                    Log "  - $($f.run_name): $msg" "WARN"
                    if ($msg -match "quota|limit|capacity|resource") {
                        $script:Issues += "[JOB] '$($f.run_name)' failed with quota/resource error."
                    }
                }
            }
            else {
                Log "No failed runs. All good." "OK"
            }

            if ($slow.Count -gt 0) {
                Log "$($slow.Count) runs had setup > 5 min (contention)" "WARN"
                $script:Issues += "[JOB] $($slow.Count) runs had slow cluster setup — resource contention."
            }
        }
        else {
            Log "No runs found in last 48h."
        }
    }
    catch {
        Log "Could not check jobs: $($_.Exception.Message)" "WARN"
    }

    # --- Azure vCPU Quota ---
    Log ""
    Log "--- AZURE vCPU QUOTA ($($script:Loc)) ---"
    try {
        $usages = Get-AzVMUsage -Location $script:Loc -ErrorAction Stop
        $hot = @($usages | Where-Object {
            $_.Limit -gt 0 -and $_.CurrentValue -gt 0
        } | Sort-Object { $_.CurrentValue / $_.Limit } -Descending | Select-Object -First 10)

        if ($hot.Count -gt 0) {
            Log ("{0,-45} {1,6} {2,6} {3,7}" -f "VM Family", "Used", "Limit", "Pct")
            Log ("-" * 68)
            foreach ($u in $hot) {
                $pct = [math]::Round(($u.CurrentValue / $u.Limit) * 100, 1)
                $lvl = if ($pct -gt 85) { "ERR" } elseif ($pct -gt 70) { "WARN" } else { "INFO" }
                Log ("{0,-45} {1,6} {2,6} {3,6}%" -f $u.Name.LocalizedValue, $u.CurrentValue, $u.Limit, $pct) $lvl
                if ($pct -gt 80) {
                    $script:Issues += "[QUOTA] $($u.Name.LocalizedValue) at $pct% — likely throttling Databricks."
                }
            }
        }
        else {
            Log "All quotas healthy." "OK"
        }
    }
    catch {
        Log "Could not check vCPU quota: $($_.Exception.Message)" "WARN"
        Log "You can check manually: az vm list-usage --location $($script:Loc) -o table" "INFO"
    }

    # --- Summary ---
    Log ""
    Banner "DIAGNOSIS RESULTS"
    if ($script:Issues.Count -gt 0) {
        Log "$($script:Issues.Count) ISSUE(S) FOUND:" "WARN"
        Log ""
        for ($i = 0; $i -lt $script:Issues.Count; $i++) {
            Log "  $($i+1). $($script:Issues[$i])" "WARN"
        }
    }
    else {
        Log "No issues found. Everything looks healthy." "OK"
    }
}

# ============================================================================
# FIX
# ============================================================================
function Run-Fix {
    Banner "APPLYING FIXES TO RUNNING CLUSTERS"
    Log ""
    Log "NOTE: Editing a RUNNING cluster will RESTART it!" "WARN"
    Log "Use -WhatIf to preview without changing anything." "WARN"
    Log ""

    try {
        $data = Call-DB -Path "/clusters/list"
        $clusters = @()
        if ($data.clusters) { $clusters = @($data.clusters) }
    }
    catch {
        Log "Could not list clusters: $($_.Exception.Message)" "ERR"
        return
    }

    foreach ($c in $clusters) {
        $name  = $c.cluster_name
        $id    = $c.cluster_id
        $state = $c.state

        if ($state -notin @("RUNNING", "PENDING", "RESIZING")) {
            Log "Skip '$name' (state: $state)"
            continue
        }

        Log "Processing: $name ($id)"

        $changes = @()
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
            $curr = if ($c.num_workers) { $c.num_workers } else { 2 }
            $minW = [Math]::Max(1, [Math]::Floor($curr / 2))
            $maxW = [Math]::Min($MaxWorkers, $curr * 2)
            $edit["autoscale"] = @{ min_workers = $minW; max_workers = $maxW }
            $changes += "Enable autoscale ($minW-$maxW, was fixed $curr)"
        }
        else {
            $edit["autoscale"] = @{
                min_workers = $c.autoscale.min_workers
                max_workers = $c.autoscale.max_workers
            }
            if ($c.autoscale.max_workers -lt 4) {
                $edit["autoscale"]["max_workers"] = 8
                $changes += "Bumped autoscale max to 8 (was $($c.autoscale.max_workers))"
            }
        }

        # Fix 2: Auto-terminate
        if (-not $c.autotermination_minutes -or $c.autotermination_minutes -eq 0) {
            $edit["autotermination_minutes"] = $AutoTermMinutes
            $changes += "Set auto-terminate to $AutoTermMinutes min"
        }
        else {
            $edit["autotermination_minutes"] = $c.autotermination_minutes
        }

        # Fix 3: Spark configs
        $conf = @{}
        if ($c.spark_conf) {
            try {
                $c.spark_conf.PSObject.Properties | ForEach-Object { $conf[$_.Name] = $_.Value }
            }
            catch {}
        }

        $recs = @{
            "spark.sql.adaptive.enabled"                            = "true"
            "spark.sql.adaptive.coalescePartitions.enabled"         = "true"
            "spark.sql.adaptive.skewJoin.enabled"                   = "true"
            "spark.databricks.adaptive.autoOptimizeShuffle.enabled" = "true"
            "spark.databricks.delta.optimizeWrite.enabled"          = "true"
            "spark.databricks.delta.autoCompact.enabled"            = "true"
            "spark.sql.shuffle.partitions"                          = "auto"
            "spark.databricks.io.cache.enabled"                     = "true"
        }

        $added = 0
        foreach ($k in $recs.Keys) {
            if (-not $conf.ContainsKey($k)) {
                $conf[$k] = $recs[$k]
                $added++
            }
        }
        if ($added -gt 0) { $changes += "Added $added Spark optimizations" }
        $edit["spark_conf"] = $conf

        if ($changes.Count -gt 0) {
            foreach ($ch in $changes) { Log "  + $ch" "OK" }

            if ($PSCmdlet.ShouldProcess($name, "Apply cluster fixes (will restart cluster)")) {
                try {
                    Call-DB -Path "/clusters/edit" -Method "POST" -Body $edit | Out-Null
                    Log "  UPDATED '$name'" "OK"
                    $script:Fixes += "Cluster '$name': $($changes -join '; ')"
                }
                catch {
                    Log "  FAILED '$name': $($_.Exception.Message)" "ERR"
                }
            }
        }
        else {
            Log "  Already optimized." "OK"
        }
        Log ""
    }

    # Cluster Policy
    Log "--- CREATING CLUSTER POLICY ---"
    $policyDef = @{
        "autoscale.min_workers"       = @{ type = "range"; minValue = 1; maxValue = 4; defaultValue = 1 }
        "autoscale.max_workers"       = @{ type = "range"; minValue = 2; maxValue = 20; defaultValue = 8 }
        "autotermination_minutes"     = @{ type = "range"; minValue = 10; maxValue = 120; defaultValue = 30 }
        "spark_conf.spark.sql.adaptive.enabled" = @{ type = "fixed"; value = "true"; hidden = $true }
        "spark_conf.spark.databricks.delta.optimizeWrite.enabled" = @{ type = "fixed"; value = "true"; hidden = $true }
        "spark_conf.spark.databricks.delta.autoCompact.enabled" = @{ type = "fixed"; value = "true"; hidden = $true }
        "spark_conf.spark.databricks.io.cache.enabled" = @{ type = "fixed"; value = "true"; hidden = $true }
    }

    if ($PSCmdlet.ShouldProcess("Quota-Safe Policy", "Create cluster policy")) {
        try {
            $pol = Call-DB -Path "/policies/clusters/create" -Method "POST" -Body @{
                name                  = "Quota-Safe Production Policy"
                definition            = ($policyDef | ConvertTo-Json -Depth 5 -Compress)
                max_clusters_per_user = 3
            }
            Log "Created policy: $($pol.policy_id)" "OK"
            $script:Fixes += "Created cluster policy: $($pol.policy_id)"
        }
        catch {
            if ($_.Exception.Message -match "already exists") {
                Log "Policy already exists." "OK"
            }
            else {
                Log "Policy creation failed: $($_.Exception.Message)" "ERR"
            }
        }
    }
}

# ============================================================================
# ALERTS
# ============================================================================
function Run-Alerts {
    Banner "SETTING UP AZURE MONITOR ALERTS"

    # Find func-memberimport-prod
    Log "Finding func-memberimport-prod..."
    try {
        $func = Get-AzResource -ResourceType "Microsoft.Web/sites" -Name "func-memberimport-prod" -ErrorAction Stop
        if ($func) {
            Log "Found: $($func.Name) in $($func.ResourceGroupName)" "OK"

            if ($PSCmdlet.ShouldProcess("func-memberimport-prod alert", "Create metric alert")) {
                $cond = New-AzMetricAlertRuleV2Criteria -MetricName "HttpResponseTime" -MetricNamespace "Microsoft.Web/sites" -TimeAggregation Average -Operator GreaterThan -Threshold 2.0
                Add-AzMetricAlertRuleV2 -Name "func-memberimport-slow" -ResourceGroupName $func.ResourceGroupName -TargetResourceId $func.ResourceId -Condition $cond -WindowSize (New-TimeSpan -Minutes 5) -Frequency (New-TimeSpan -Minutes 1) -Severity 2 -Description "Response > 2s"
                Log "Alert created: func-memberimport-slow" "OK"
                $script:Fixes += "Alert: func-memberimport-slow"
            }
        }
    }
    catch {
        Log "func-memberimport-prod: $($_.Exception.Message)" "WARN"
    }

    # Find pyx-qa
    Log "Finding pyx-qa..."
    try {
        $pyx = Get-AzResource -ResourceType "Microsoft.Insights/components" -Name "pyx-qa" -ErrorAction Stop
        if ($pyx) {
            Log "Found: $($pyx.Name) in $($pyx.ResourceGroupName)" "OK"

            if ($PSCmdlet.ShouldProcess("pyx-qa alert", "Create metric alert")) {
                $cond2 = New-AzMetricAlertRuleV2Criteria -MetricName "dependencies/duration" -MetricNamespace "Microsoft.Insights/components" -TimeAggregation Average -Operator GreaterThan -Threshold 500
                Add-AzMetricAlertRuleV2 -Name "pyx-qa-sql-slow" -ResourceGroupName $pyx.ResourceGroupName -TargetResourceId $pyx.ResourceId -Condition $cond2 -WindowSize (New-TimeSpan -Minutes 5) -Frequency (New-TimeSpan -Minutes 1) -Severity 2 -Description "SQL > 500ms"
                Log "Alert created: pyx-qa-sql-slow" "OK"
                $script:Fixes += "Alert: pyx-qa-sql-slow"
            }
        }
    }
    catch {
        Log "pyx-qa: $($_.Exception.Message)" "WARN"
    }
}

# ============================================================================
# QUOTA
# ============================================================================
function Run-Quota {
    Banner "AZURE vCPU QUOTA ANALYSIS"

    try {
        $usages = Get-AzVMUsage -Location $script:Loc -ErrorAction Stop
        $all = @($usages | Where-Object { $_.Limit -gt 0 -and $_.CurrentValue -gt 0 } |
            Sort-Object { $_.CurrentValue / $_.Limit } -Descending |
            Select-Object -First 20)

        Log ("{0,-45} {1,6} {2,6} {3,7}" -f "VM Family", "Used", "Limit", "Pct")
        Log ("-" * 68)

        foreach ($u in $all) {
            $pct = [math]::Round(($u.CurrentValue / $u.Limit) * 100, 1)
            $lvl = if ($pct -gt 85) { "ERR" } elseif ($pct -gt 70) { "WARN" } else { "INFO" }
            Log ("{0,-45} {1,6} {2,6} {3,6}%" -f $u.Name.LocalizedValue, $u.CurrentValue, $u.Limit, $pct) $lvl
        }

        $over = @($all | Where-Object { ($_.CurrentValue / $_.Limit) -gt 0.80 })
        if ($over.Count -gt 0) {
            Log ""
            Log "INCREASE THESE:" "WARN"
            foreach ($o in $over) {
                $new = [int]([Math]::Max($o.Limit * 2, $o.CurrentValue * 2.5))
                Log "  $($o.Name.LocalizedValue): $($o.Limit) -> $new" "WARN"
            }
            Log ""
            Log "  Portal: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" "INFO"
        }
        else {
            Log ""
            Log "All quotas healthy. Issue may be at Databricks workspace level." "OK"
        }
    }
    catch {
        Log "Could not check quota: $($_.Exception.Message)" "ERR"
        Log "Try: az vm list-usage --location $($script:Loc) -o table" "INFO"
    }
}

# ============================================================================
# SUMMARY
# ============================================================================
function Show-Summary {
    Banner "SUMMARY"

    if ($script:Issues.Count -gt 0) {
        Log "Issues: $($script:Issues.Count)" "WARN"
        $script:Issues | ForEach-Object { Log "  - $_" "WARN" }
    }

    if ($script:Fixes.Count -gt 0) {
        Log ""
        Log "Fixes Applied: $($script:Fixes.Count)" "OK"
        $script:Fixes | ForEach-Object { Log "  - $_" "OK" }
    }

    Log ""
    Log "NEXT STEPS:" "INFO"
    Log "  1. Reply to Databricks Support ticket 500Vp00000IrEJdIAM"
    Log "  2. If any quota > 80%, request increase in Azure Portal"
    Log "  3. Monitor 24-48h for new Smart Detection alerts"
    Log "  4. Assign 'Quota-Safe Production Policy' to job clusters"
    Log ""
    Log "Log file: $LogFile" "OK"
}

# ============================================================================
# MAIN — JUST RUN IT
# ============================================================================

# Step 1: Prerequisites
$ok = Test-Setup
if (-not $ok) { exit 1 }

# Step 2: Azure login
$ok = Connect-Azure
if (-not $ok) { exit 1 }

# Step 3: Find workspace
$ok = Find-Workspace
if (-not $ok) { exit 1 }

# Step 4: Get token
$ok = Get-Token
if (-not $ok) { exit 1 }

# Step 5: Test connection
$ok = Test-Connection
if (-not $ok) { exit 1 }

# Step 6: Run the mode
Log ""
switch ($Mode) {
    "diagnose" { Run-Diagnose }
    "fix"      { Run-Fix }
    "alerts"   { Run-Alerts }
    "quota"    { Run-Quota }
    "all" {
        Run-Diagnose
        Run-Fix
        Run-Alerts
        Run-Quota
    }
}

Show-Summary
