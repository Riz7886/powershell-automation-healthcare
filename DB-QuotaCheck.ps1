param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("diagnose","fix","all")]
    [string]$Mode
)

$ErrorActionPreference = "Continue"
$script:WsUrl = ""
$script:Tok = ""
$script:Sub = ""
$script:RG = ""
$script:Loc = ""
$script:Problems = New-Object System.Collections.ArrayList
$script:Fixed = New-Object System.Collections.ArrayList
$LogFile = ".\DBCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Log($Msg, $Lvl) {
    if (-not $Lvl) { $Lvl = "INFO" }
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Lvl] $Msg"
    if ($Lvl -eq "ERR")  { Write-Host $line -ForegroundColor Red }
    elseif ($Lvl -eq "WARN") { Write-Host $line -ForegroundColor Yellow }
    elseif ($Lvl -eq "OK")   { Write-Host $line -ForegroundColor Green }
    else { Write-Host $line }
    $line | Out-File -Append -FilePath $LogFile -ErrorAction SilentlyContinue
}

function Banner($Title) {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ""
}

# ---- STEP 1: MODULES ----
Banner "STEP 1 - CHECKING MODULES"

$mod = Get-Module -ListAvailable -Name Az.Accounts -ErrorAction SilentlyContinue
if (-not $mod) {
    Log "Az module not found. Installing..." "WARN"
    try {
        Install-Module Az.Accounts -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
        Install-Module Az.Resources -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
        Install-Module Az.Compute -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
        Log "Installed." "OK"
    }
    catch {
        Log "Cannot install Az module. Run manually: Install-Module Az -Force -Scope CurrentUser" "ERR"
        exit
    }
}
else {
    Log "Az module found." "OK"
}

try { Import-Module Az.Accounts -Force -ErrorAction Stop } catch { Log "Cannot load Az.Accounts" "ERR"; exit }
try { Import-Module Az.Resources -Force -ErrorAction SilentlyContinue } catch {}
try { Import-Module Az.Compute -Force -ErrorAction SilentlyContinue } catch {}

# ---- STEP 2: LOGIN ----
Banner "STEP 2 - AZURE LOGIN"

$ctx = $null
try { $ctx = Get-AzContext -ErrorAction Stop } catch { $ctx = $null }

if ((-not $ctx) -or (-not $ctx.Account)) {
    Log "Not logged in. Opening login window..." "WARN"
    try {
        Connect-AzAccount -ErrorAction Stop | Out-Null
        $ctx = Get-AzContext -ErrorAction Stop
    }
    catch {
        Log "Login failed. Try running Connect-AzAccount first." "ERR"
        exit
    }
}

$script:Sub = $ctx.Subscription.Id
Log "Logged in: $($ctx.Account.Id)" "OK"
Log "Subscription: $($ctx.Subscription.Name)" "OK"

# ---- STEP 3: FIND DATABRICKS ----
Banner "STEP 3 - FINDING DATABRICKS WORKSPACE"

$wsList = $null
try {
    $wsList = Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" -ErrorAction Stop
}
catch {
    Log "Error finding workspaces: $_" "ERR"
    exit
}

if ((-not $wsList) -or (@($wsList).Count -eq 0)) {
    Log "No workspaces in current sub. Checking others..." "WARN"
    try {
        $allSubs = Get-AzSubscription -ErrorAction Stop
        foreach ($s in $allSubs) {
            try {
                Set-AzContext -SubscriptionId $s.Id -ErrorAction Stop | Out-Null
                $wsList = Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" -ErrorAction Stop
                if ($wsList -and (@($wsList).Count -gt 0)) {
                    $script:Sub = $s.Id
                    Log "Found in: $($s.Name)" "OK"
                    break
                }
            }
            catch { continue }
        }
    }
    catch {
        Log "Error: $_" "ERR"
    }
}

if ((-not $wsList) -or (@($wsList).Count -eq 0)) {
    Log "No Databricks workspaces found." "ERR"
    exit
}

$wsList = @($wsList)

$picked = $null
if ($wsList.Count -eq 1) {
    $picked = $wsList[0]
    Log "Found: $($picked.Name)" "OK"
}
else {
    Log "Found $($wsList.Count) workspaces:"
    for ($i = 0; $i -lt $wsList.Count; $i++) {
        Write-Host "  [$($i+1)] $($wsList[$i].Name) - RG: $($wsList[$i].ResourceGroupName)" -ForegroundColor Cyan
    }
    Write-Host ""
    $pick = Read-Host "Pick number"
    $idx = [int]$pick - 1
    if ($idx -lt 0 -or $idx -ge $wsList.Count) { $idx = 0 }
    $picked = $wsList[$idx]
}

$script:RG = $picked.ResourceGroupName
$script:Loc = $picked.Location

try {
    $detail = Get-AzResource -ResourceId $picked.ResourceId -ExpandProperties -ErrorAction Stop
    $wsurl = $detail.Properties.workspaceUrl
    if ($wsurl) {
        $script:WsUrl = "https://" + $wsurl
    }
    else {
        $wid = $detail.Properties.workspaceId
        $script:WsUrl = "https://adb-" + $wid + ".azuredatabricks.net"
    }
}
catch {
    Log "Cannot get workspace URL: $_" "ERR"
    exit
}

Log "URL: $($script:WsUrl)" "OK"
Log "RG:  $($script:RG)" "OK"
Log "Loc: $($script:Loc)" "OK"

# ---- STEP 4: TOKEN ----
Banner "STEP 4 - GETTING API TOKEN"

$dbAppId = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
$gotToken = $false

# Try Azure AD - handle both old and new Az module versions
Log "Trying Azure AD token..."
try {
    $tokenObj = Get-AzAccessToken -ResourceUrl $dbAppId -ErrorAction Stop
    # New Az.Accounts 3.x uses .Token, older uses .AccessToken, some use both
    $tokenStr = $null
    if ($tokenObj.Token) { $tokenStr = $tokenObj.Token }
    elseif ($tokenObj.AccessToken) { $tokenStr = $tokenObj.AccessToken }

    if ($tokenStr -and $tokenStr.Length -gt 20) {
        $script:Tok = $tokenStr
        Log "Got Azure AD token." "OK"
        $gotToken = $true
    }
}
catch {
    Log "Azure AD failed: $_" "WARN"
    # Try alternate parameter name
    try {
        $tokenObj = Get-AzAccessToken -Resource $dbAppId -ErrorAction Stop
        $tokenStr = $null
        if ($tokenObj.Token) { $tokenStr = $tokenObj.Token }
        elseif ($tokenObj.AccessToken) { $tokenStr = $tokenObj.AccessToken }

        if ($tokenStr -and $tokenStr.Length -gt 20) {
            $script:Tok = $tokenStr
            Log "Got Azure AD token (alt method)." "OK"
            $gotToken = $true
        }
    }
    catch {
        Log "Azure AD alt method also failed: $_" "WARN"
    }
}

# Try CLI
if (-not $gotToken) {
    Log "Trying Azure CLI..."
    try {
        $cliExists = Get-Command az -ErrorAction SilentlyContinue
        if ($cliExists) {
            $cliTok = & az account get-access-token --resource $dbAppId --query accessToken -o tsv 2>$null
            if ($cliTok -and $cliTok.Length -gt 20) {
                $script:Tok = $cliTok
                Log "Got CLI token." "OK"
                $gotToken = $true
            }
        }
        else {
            Log "Azure CLI not installed." "WARN"
        }
    }
    catch {
        Log "CLI failed." "WARN"
    }
}

# Manual fallback
if (-not $gotToken) {
    Write-Host ""
    Write-Host "  AUTO-TOKEN FAILED - Need manual token" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Open: $($script:WsUrl)" -ForegroundColor Cyan
    Write-Host "  2. Click your name top-right" -ForegroundColor Cyan
    Write-Host "  3. User Settings > Developer > Access Tokens" -ForegroundColor Cyan
    Write-Host "  4. Generate New Token > Copy it" -ForegroundColor Cyan
    Write-Host ""
    $manual = Read-Host "  Paste token here"
    if ($manual -and $manual.Length -gt 5) {
        $script:Tok = $manual.Trim()
        $gotToken = $true
        Log "Manual token set." "OK"
    }
}

if (-not $gotToken) {
    Log "No token. Cannot continue." "ERR"
    exit
}

# ---- STEP 5: TEST ----
Banner "STEP 5 - TESTING CONNECTION"

$headers = @{
    "Authorization" = "Bearer " + $script:Tok
    "Content-Type" = "application/json"
}

try {
    $test = Invoke-RestMethod -Uri ($script:WsUrl + "/api/2.0/clusters/list") -Headers $headers -Method Get -ErrorAction Stop
    $cnt = 0
    if ($test.clusters) { $cnt = @($test.clusters).Count }
    Log "Connected! Found $cnt cluster(s)." "OK"
}
catch {
    Log "Connection failed: $_" "ERR"
    Log "Token may be expired or wrong. Try manual token." "ERR"
    Write-Host ""
    Write-Host "  1. Open: $($script:WsUrl)" -ForegroundColor Cyan
    Write-Host "  2. User Settings > Developer > Access Tokens" -ForegroundColor Cyan
    Write-Host "  3. Generate New Token > Copy it" -ForegroundColor Cyan
    Write-Host ""
    $retry = Read-Host "  Paste token here (or press Enter to quit)"
    if ($retry -and $retry.Length -gt 5) {
        $script:Tok = $retry.Trim()
        $headers["Authorization"] = "Bearer " + $script:Tok
        try {
            $test = Invoke-RestMethod -Uri ($script:WsUrl + "/api/2.0/clusters/list") -Headers $headers -Method Get -ErrorAction Stop
            $cnt = 0
            if ($test.clusters) { $cnt = @($test.clusters).Count }
            Log "Connected with manual token! Found $cnt cluster(s)." "OK"
        }
        catch {
            Log "Still failing: $_" "ERR"
            exit
        }
    }
    else {
        exit
    }
}

# ============================================================================
# DIAGNOSE
# ============================================================================
function Run-Diagnose {
    Banner "DIAGNOSING CLUSTERS"

    $headers = @{
        "Authorization" = "Bearer " + $script:Tok
        "Content-Type" = "application/json"
    }

    try {
        $resp = Invoke-RestMethod -Uri ($script:WsUrl + "/api/2.0/clusters/list") -Headers $headers -Method Get -ErrorAction Stop
    }
    catch {
        Log "Cannot list clusters: $_" "ERR"
        return
    }

    $clusters = @()
    if ($resp.clusters) { $clusters = @($resp.clusters) }

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
        Log "    ID:     $id"
        Log "    State:  $state"
        Log "    Driver: $($c.driver_node_type_id)"
        Log "    Worker: $($c.node_type_id)"

        if ($c.autoscale) {
            $mn = $c.autoscale.min_workers
            $mx = $c.autoscale.max_workers
            Log "    Scale:  Autoscale $mn - $mx" "OK"
            if ($mx -lt 4 -and $state -eq "RUNNING") {
                $null = $script:Problems.Add("[CLUSTER] $name - max workers only $mx")
            }
        }
        else {
            $w = 0
            if ($c.num_workers) { $w = $c.num_workers }
            Log "    Scale:  FIXED $w workers" "WARN"
            if ($state -eq "RUNNING") {
                $null = $script:Problems.Add("[CLUSTER] $name - FIXED sizing ($w workers), cannot scale")
            }
        }

        $at = $c.autotermination_minutes
        if ((-not $at) -or ($at -eq 0)) {
            Log "    AutoOff: DISABLED" "WARN"
            if ($state -eq "RUNNING") {
                $null = $script:Problems.Add("[CLUSTER] $name - no auto-termination, wasting quota")
            }
        }
        else {
            Log "    AutoOff: $at min"
        }

        if ($c.spark_conf) {
            $aqe = $c.spark_conf."spark.sql.adaptive.enabled"
            if ($aqe -eq "true") { Log "    AQE:    Enabled" "OK" }
            else {
                Log "    AQE:    Not enabled" "WARN"
                $null = $script:Problems.Add("[CLUSTER] $name - missing Adaptive Query Execution")
            }
        }
        else {
            Log "    Config: No spark optimizations" "WARN"
            $null = $script:Problems.Add("[CLUSTER] $name - no Spark configs set")
        }

        Log ""
    }

    # Job failures
    Log "--- JOB FAILURES (48h) ---"
    try {
        $nowMs = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        $agoMs = [long]([DateTimeOffset]::UtcNow.AddHours(-48).ToUnixTimeMilliseconds())
        $jobUrl = $script:WsUrl + "/api/2.1/jobs/runs/list?start_time_from=" + $agoMs + "&start_time_to=" + $nowMs + "&limit=100"
        $jobResp = Invoke-RestMethod -Uri $jobUrl -Headers $headers -Method Get -ErrorAction Stop

        if ($jobResp.runs) {
            $allRuns = @($jobResp.runs)
            $bad = @($allRuns | Where-Object { $_.state.result_state -eq "FAILED" -or $_.state.result_state -eq "TIMEDOUT" })

            if ($bad.Count -gt 0) {
                Log "$($bad.Count) failed runs!" "WARN"
                foreach ($b in ($bad | Select-Object -First 5)) {
                    $msg = "no details"
                    if ($b.state.state_message) { $msg = $b.state.state_message }
                    if ($msg.Length -gt 80) { $msg = $msg.Substring(0, 80) + "..." }
                    Log "  - $($b.run_name): $msg" "WARN"
                }
            }
            else {
                Log "No failed runs." "OK"
            }
        }
        else {
            Log "No runs in last 48h."
        }
    }
    catch {
        Log "Could not check jobs: $_" "WARN"
    }

    # Azure quota
    Log ""
    Log "--- AZURE vCPU QUOTA ---"
    try {
        $usages = Get-AzVMUsage -Location $script:Loc -ErrorAction Stop
        $hot = @($usages | Where-Object { $_.Limit -gt 0 -and $_.CurrentValue -gt 0 })
        $hot = @($hot | Sort-Object { $_.CurrentValue / $_.Limit } -Descending | Select-Object -First 10)

        if ($hot.Count -gt 0) {
            foreach ($u in $hot) {
                $pct = [math]::Round(($u.CurrentValue / $u.Limit) * 100, 1)
                $lvl = "INFO"
                if ($pct -gt 85) { $lvl = "ERR" }
                elseif ($pct -gt 70) { $lvl = "WARN" }
                Log ("  {0,-40} {1}/{2} ({3}%)" -f $u.Name.LocalizedValue, $u.CurrentValue, $u.Limit, $pct) $lvl
                if ($pct -gt 80) {
                    $null = $script:Problems.Add("[QUOTA] $($u.Name.LocalizedValue) at $pct%")
                }
            }
        }
        else {
            Log "All quotas healthy." "OK"
        }
    }
    catch {
        Log "Quota check failed: $_" "WARN"
        Log "Try manually: az vm list-usage --location $($script:Loc) -o table"
    }

    # Summary
    Banner "DIAGNOSIS RESULTS"
    if ($script:Problems.Count -gt 0) {
        Log "$($script:Problems.Count) ISSUES FOUND:" "WARN"
        for ($i = 0; $i -lt $script:Problems.Count; $i++) {
            Log "  $($i+1). $($script:Problems[$i])" "WARN"
        }
    }
    else {
        Log "No issues found." "OK"
    }
}

# ============================================================================
# FIX
# ============================================================================
function Run-Fix {
    Banner "FIXING CLUSTERS"
    Log "WARNING: Editing RUNNING clusters will RESTART them!" "WARN"
    Write-Host ""
    $confirm = Read-Host "Type YES to continue, anything else to cancel"
    if ($confirm -ne "YES") {
        Log "Cancelled by user." "WARN"
        return
    }
    Log ""

    $headers = @{
        "Authorization" = "Bearer " + $script:Tok
        "Content-Type" = "application/json"
    }

    try {
        $resp = Invoke-RestMethod -Uri ($script:WsUrl + "/api/2.0/clusters/list") -Headers $headers -Method Get -ErrorAction Stop
    }
    catch {
        Log "Cannot list clusters: $_" "ERR"
        return
    }

    $clusters = @()
    if ($resp.clusters) { $clusters = @($resp.clusters) }

    foreach ($c in $clusters) {
        $name  = $c.cluster_name
        $id    = $c.cluster_id
        $state = $c.state

        if ($state -ne "RUNNING" -and $state -ne "PENDING" -and $state -ne "RESIZING") {
            Log "Skip $name (state: $state)"
            continue
        }

        Log "Processing: $name"
        $changes = @()

        $edit = @{}
        $edit["cluster_id"] = $id
        $edit["cluster_name"] = $name
        $edit["spark_version"] = $c.spark_version
        $edit["node_type_id"] = $c.node_type_id

        if ($c.driver_node_type_id) { $edit["driver_node_type_id"] = $c.driver_node_type_id }
        if ($c.azure_attributes) { $edit["azure_attributes"] = $c.azure_attributes }
        if ($c.custom_tags) { $edit["custom_tags"] = $c.custom_tags }

        # Autoscale
        if (-not $c.autoscale) {
            $curr = 2
            if ($c.num_workers) { $curr = $c.num_workers }
            $minW = [Math]::Max(1, [Math]::Floor($curr / 2))
            $maxW = [Math]::Min(10, $curr * 2)
            $edit["autoscale"] = @{ min_workers = $minW; max_workers = $maxW }
            $changes += "Enable autoscale $minW-$maxW (was fixed $curr)"
        }
        else {
            $edit["autoscale"] = @{
                min_workers = $c.autoscale.min_workers
                max_workers = $c.autoscale.max_workers
            }
            if ($c.autoscale.max_workers -lt 4) {
                $edit["autoscale"]["max_workers"] = 8
                $changes += "Bump max workers to 8"
            }
        }

        # Auto-terminate
        $at = $c.autotermination_minutes
        if ((-not $at) -or ($at -eq 0)) {
            $edit["autotermination_minutes"] = 30
            $changes += "Set auto-terminate 30 min"
        }
        else {
            $edit["autotermination_minutes"] = $at
        }

        # Spark configs
        $conf = @{}
        if ($c.spark_conf) {
            try {
                $c.spark_conf.PSObject.Properties | ForEach-Object { $conf[$_.Name] = $_.Value }
            }
            catch {}
        }

        $recs = @{}
        $recs["spark.sql.adaptive.enabled"] = "true"
        $recs["spark.sql.adaptive.coalescePartitions.enabled"] = "true"
        $recs["spark.sql.adaptive.skewJoin.enabled"] = "true"
        $recs["spark.databricks.adaptive.autoOptimizeShuffle.enabled"] = "true"
        $recs["spark.databricks.delta.optimizeWrite.enabled"] = "true"
        $recs["spark.databricks.delta.autoCompact.enabled"] = "true"
        $recs["spark.databricks.io.cache.enabled"] = "true"

        $added = 0
        foreach ($k in $recs.Keys) {
            if (-not $conf.ContainsKey($k)) {
                $conf[$k] = $recs[$k]
                $added++
            }
        }
        if ($added -gt 0) { $changes += "Added $added Spark configs" }
        $edit["spark_conf"] = $conf

        if ($changes.Count -gt 0) {
            foreach ($ch in $changes) { Log "  + $ch" "OK" }

            Write-Host ""
            $go = Read-Host "  Apply these changes to $name ? (y/n)"
            if ($go -eq "y" -or $go -eq "Y") {
                try {
                    $body = $edit | ConvertTo-Json -Depth 10
                    Invoke-RestMethod -Uri ($script:WsUrl + "/api/2.0/clusters/edit") -Headers $headers -Method Post -Body $body -ErrorAction Stop | Out-Null
                    Log "  UPDATED $name" "OK"
                    $null = $script:Fixed.Add("$name : $($changes -join ', ')")
                }
                catch {
                    Log "  FAILED $name : $_" "ERR"
                }
            }
            else {
                Log "  Skipped $name" "WARN"
            }
        }
        else {
            Log "  Already optimized." "OK"
        }
        Log ""
    }

    # Policy
    Log "--- CREATING CLUSTER POLICY ---"
    $polDef = @{}
    $polDef["autoscale.min_workers"] = @{ type = "range"; minValue = 1; maxValue = 4; defaultValue = 1 }
    $polDef["autoscale.max_workers"] = @{ type = "range"; minValue = 2; maxValue = 20; defaultValue = 8 }
    $polDef["autotermination_minutes"] = @{ type = "range"; minValue = 10; maxValue = 120; defaultValue = 30 }

    $polBody = @{
        name = "Quota-Safe Production Policy"
        definition = ($polDef | ConvertTo-Json -Depth 5 -Compress)
        max_clusters_per_user = 3
    }

    try {
        $body = $polBody | ConvertTo-Json -Depth 5
        $polResult = Invoke-RestMethod -Uri ($script:WsUrl + "/api/2.0/policies/clusters/create") -Headers $headers -Method Post -Body $body -ErrorAction Stop
        Log "Policy created: $($polResult.policy_id)" "OK"
        $null = $script:Fixed.Add("Cluster policy created")
    }
    catch {
        $errMsg = "$_"
        if ($errMsg -match "already exists") {
            Log "Policy already exists." "OK"
        }
        else {
            Log "Policy failed: $errMsg" "ERR"
        }
    }
}

# ============================================================================
# RUN
# ============================================================================

switch ($Mode) {
    "diagnose" { Run-Diagnose }
    "fix"      { Run-Fix }
    "all"      { Run-Diagnose; Run-Fix }
}

# Summary
Banner "DONE"
if ($script:Problems.Count -gt 0) {
    Log "Issues: $($script:Problems.Count)" "WARN"
    foreach ($p in $script:Problems) { Log "  - $p" "WARN" }
}
if ($script:Fixed.Count -gt 0) {
    Log ""
    Log "Fixes: $($script:Fixed.Count)" "OK"
    foreach ($f in $script:Fixed) { Log "  - $f" "OK" }
}
Log ""
Log "Next steps:"
Log "  1. Reply to Databricks ticket 500Vp00000IrEJdIAM"
Log "  2. Check quota: az vm list-usage --location $($script:Loc) -o table"
Log "  3. Monitor Smart Detection alerts 24-48h"
Log "  4. Assign Quota-Safe Policy to job clusters in Databricks UI"
Log ""
Log "Log: $LogFile" "OK"
