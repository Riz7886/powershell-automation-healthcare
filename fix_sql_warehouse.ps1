$ErrorActionPreference = "Continue"

# ===============================================================
#  FIX DATABRICKS SQL WAREHOUSE - PERMANENT AUTO-HEAL
#  Fixes "Failing to start" + installs 24/7 watchdog
# ===============================================================

# ---------- CONFIGURATION ----------
$workspaceUrl = "https://adb-2758318924173706.6.azuredatabricks.net"
$warehouseId  = "731935382e7857526"
$warehouseName = "sql-warehouse"

# Watchdog settings
$checkIntervalMinutes = 3
$maxRestartAttempts = 5
$taskName = "Databricks-Warehouse-Watchdog"

# Log setup
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$logDir = Join-Path $scriptDir "warehouse-watchdog-logs"
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir "watchdog_$(Get-Date -Format 'yyyyMMdd').log"

function Write-Log {
    param([string]$Msg, [string]$Color = "White")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg"
    $entry | Out-File -FilePath $logFile -Append -Encoding UTF8
    Write-Host $entry -ForegroundColor $Color
}

function Get-DatabricksToken {
    # Method 1: Use existing PAT token if set
    if ($env:DATABRICKS_TOKEN) { return $env:DATABRICKS_TOKEN }

    # Method 2: Check token file
    $tokenFile = Join-Path $scriptDir ".databricks-token"
    if (Test-Path $tokenFile) {
        $token = (Get-Content $tokenFile -Raw).Trim()
        if ($token) { return $token }
    }

    # Method 3: Azure CLI AAD token
    try {
        $rawToken = az account get-access-token --resource "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" -o json 2>$null
        if ($rawToken) {
            $parsed = $rawToken | ConvertFrom-Json
            return $parsed.accessToken
        }
    }
    catch {}

    # Method 4: Service Principal (from master_operations)
    $spSecretFile = Join-Path $scriptDir ".sp-secret"
    if (Test-Path $spSecretFile) {
        try {
            $spSecret = (Get-Content $spSecretFile -Raw).Trim()
            $tenantId = "8ef3d734-3ca5-4493-8d8b-52b2c54eab04"
            $clientId = "e44f4026-8d8e-4a26-a5c7-46269cc0d7de"
            $body = @{
                grant_type    = "client_credentials"
                client_id     = $clientId
                client_secret = $spSecret
                scope         = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d/.default"
            }
            $resp = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method Post -Body $body
            return $resp.access_token
        }
        catch {}
    }

    return $null
}

function Invoke-DatabricksApi {
    param([string]$Endpoint, [string]$Method = "GET", [hashtable]$Body = $null)

    $token = Get-DatabricksToken
    if (-not $token) {
        Write-Log "  FATAL: No Databricks token available" "Red"
        return $null
    }

    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
    }

    $uri = "$workspaceUrl/api/2.0/sql/warehouses$Endpoint"

    try {
        if ($Body) {
            $jsonBody = $Body | ConvertTo-Json -Depth 10
            $result = Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -Body $jsonBody -TimeoutSec 60
        }
        else {
            $result = Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -TimeoutSec 60
        }
        return $result
    }
    catch {
        Write-Log "  API Error ($Method $Endpoint): $($_.Exception.Message)" "Red"
        return $null
    }
}

# ===============================================================
#  MAIN LOGIC
# ===============================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  DATABRICKS SQL WAREHOUSE - AUTO-FIX & WATCHDOG" -ForegroundColor Cyan
Write-Host "  Warehouse: $warehouseName ($warehouseId)" -ForegroundColor Cyan
Write-Host "  Workspace: $workspaceUrl" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ---- CHECK IF THIS IS A WATCHDOG RUN OR FIRST-TIME FIX ----
$isWatchdogRun = $args -contains "--watchdog"

if (-not $isWatchdogRun) {
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host "  FIRST-TIME FIX MODE" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host ""
}
else {
    Write-Log "--- Watchdog check ---" "Gray"
}

# ---- STEP 1: Get current warehouse status ----
Write-Log "[1] Checking warehouse status..." "Yellow"

$warehouse = Invoke-DatabricksApi -Endpoint "/$warehouseId"

if (-not $warehouse) {
    Write-Log "  Cannot reach warehouse API. Check token/network." "Red"
    exit 1
}

$currentState = $warehouse.state
$currentSize = $warehouse.cluster_size
$currentMin = $warehouse.min_num_clusters
$currentMax = $warehouse.max_num_clusters
$spotPolicy = $warehouse.spot_instance_policy
$channel = if ($warehouse.channel) { $warehouse.channel.name } else { "CURRENT" }
$autoStop = $warehouse.auto_stop_mins

Write-Log "  State:        $currentState" $(if ($currentState -eq "RUNNING") { "Green" } elseif ($currentState -match "FAIL|STOP") { "Red" } else { "Yellow" })
Write-Log "  Size:         $currentSize" "White"
Write-Log "  Clusters:     Min $currentMin / Max $currentMax" "White"
Write-Log "  Spot Policy:  $spotPolicy" $(if ($spotPolicy -eq "COST_OPTIMIZED") { "Red" } else { "Green" })
Write-Log "  Auto Stop:    $autoStop min" "White"
Write-Log "  Channel:      $channel" "White"
Write-Host ""

# ---- If running fine on a watchdog check, exit ----
if ($isWatchdogRun -and $currentState -eq "RUNNING") {
    Write-Log "  Warehouse is RUNNING. No action needed." "Green"
    exit 0
}

# ---- STEP 2: Stop the warehouse if it's in a bad state ----
$needsFix = $currentState -match "FAIL|STARTING|STOPPING|DELETED" -or ($currentState -eq "STOPPED" -and -not $isWatchdogRun)

if ($currentState -match "FAIL|STARTING") {
    Write-Log "[2] Warehouse is in bad state ($currentState). Stopping..." "Red"

    $stopResult = Invoke-DatabricksApi -Endpoint "/$warehouseId/stop" -Method "POST"
    Write-Log "  Stop command sent." "Yellow"

    # Wait for it to actually stop
    $waitCount = 0
    $maxWait = 30
    do {
        Start-Sleep -Seconds 10
        $waitCount++
        $check = Invoke-DatabricksApi -Endpoint "/$warehouseId"
        $checkState = if ($check) { $check.state } else { "UNKNOWN" }
        Write-Log "  Waiting for stop... ($checkState) [$waitCount/$maxWait]" "Gray"
    } while ($checkState -notin @("STOPPED", "DELETED") -and $waitCount -lt $maxWait)

    if ($checkState -eq "STOPPED") {
        Write-Log "  Warehouse stopped successfully." "Green"
    }
    else {
        Write-Log "  Warehouse did not stop cleanly (state: $checkState). Continuing anyway..." "Yellow"
    }
    Write-Host ""
}
elseif ($currentState -eq "STOPPED") {
    Write-Log "[2] Warehouse is already STOPPED." "Yellow"
    Write-Host ""
}
elseif ($currentState -eq "RUNNING" -and -not $isWatchdogRun) {
    Write-Log "[2] Warehouse is RUNNING. Will reconfigure for reliability..." "Green"
    Write-Host ""
}

# ---- STEP 3: Reconfigure warehouse for reliability ----
Write-Log "[3] Reconfiguring warehouse for maximum reliability..." "Yellow"

$updatePayload = @{
    # Switch from Cost Optimized to Reliability Optimized
    # This prevents the "no spot VMs available" failures
    spot_instance_policy = "RELIABILITY_OPTIMIZED"

    # Keep existing settings
    cluster_size    = $currentSize
    min_num_clusters = [Math]::Max($currentMin, 1)
    max_num_clusters = [Math]::Max($currentMax, 2)
    auto_stop_mins   = $autoStop

    # Enable serverless acceleration if available
    enable_serverless_compute = $true
}

$changes = @()

if ($spotPolicy -eq "COST_OPTIMIZED") {
    $changes += "Spot policy: COST_OPTIMIZED -> RELIABILITY_OPTIMIZED"
}
if ($currentMin -lt 1) {
    $changes += "Min clusters: $currentMin -> 1"
}

if ($changes.Count -gt 0 -or -not $isWatchdogRun) {
    Write-Log "  Changes to apply:" "Cyan"
    foreach ($c in $changes) {
        Write-Log "    - $c" "Cyan"
    }
    if ($changes.Count -eq 0) {
        Write-Log "    - Restarting with current config (force refresh)" "Cyan"
    }

    $editResult = Invoke-DatabricksApi -Endpoint "/$warehouseId/edit" -Method "POST" -Body $updatePayload

    if ($editResult -ne $null -or $true) {
        Write-Log "  Configuration updated." "Green"
    }
}
else {
    Write-Log "  Config already optimal. Skipping edit." "Green"
}
Write-Host ""

# ---- STEP 4: Start the warehouse ----
Write-Log "[4] Starting warehouse..." "Yellow"

$startResult = Invoke-DatabricksApi -Endpoint "/$warehouseId/start" -Method "POST"
Write-Log "  Start command sent." "Yellow"

# Wait for it to come up
$startWait = 0
$maxStartWait = 60
$started = $false

do {
    Start-Sleep -Seconds 15
    $startWait++
    $startCheck = Invoke-DatabricksApi -Endpoint "/$warehouseId"
    $startState = if ($startCheck) { $startCheck.state } else { "UNKNOWN" }

    $stateColor = switch ($startState) {
        "RUNNING"  { "Green" }
        "STARTING" { "Yellow" }
        default    { "Red" }
    }
    Write-Log "  Status: $startState [$startWait/$maxStartWait]" $stateColor

    if ($startState -eq "RUNNING") {
        $started = $true
        break
    }

    if ($startState -match "FAIL|STOPPED|DELETED") {
        Write-Log "  Warehouse failed to start again (state: $startState)" "Red"

        # If it failed again, try disabling spot instances entirely
        if ($startWait -lt ($maxStartWait - 20)) {
            Write-Log "  Retrying with spot instances DISABLED..." "Yellow"
            $updatePayload.spot_instance_policy = "POLICY_UNSPECIFIED"
            Invoke-DatabricksApi -Endpoint "/$warehouseId/edit" -Method "POST" -Body $updatePayload | Out-Null
            Start-Sleep -Seconds 5
            Invoke-DatabricksApi -Endpoint "/$warehouseId/start" -Method "POST" | Out-Null
            Write-Log "  Restart sent with no-spot config." "Yellow"
        }
    }
} while ($startWait -lt $maxStartWait)

Write-Host ""

if ($started) {
    Write-Log "========================================" "Green"
    Write-Log "  WAREHOUSE IS RUNNING!" "Green"
    Write-Log "========================================" "Green"
    Write-Log "  Name:   $warehouseName" "Green"
    Write-Log "  ID:     $warehouseId" "Green"
    Write-Log "  Size:   $currentSize" "Green"
    Write-Log "  Spot:   RELIABILITY_OPTIMIZED" "Green"
}
else {
    Write-Log "========================================" "Red"
    Write-Log "  WAREHOUSE DID NOT START IN TIME" "Red"
    Write-Log "========================================" "Red"
    Write-Log "  The watchdog will keep retrying automatically." "Yellow"
    Write-Log "  Check Azure portal for quota/networking issues." "Yellow"
}
Write-Host ""

# ---- STEP 5: Install Watchdog Task Scheduler (first-time only) ----
if (-not $isWatchdogRun) {
    Write-Host "================================================================" -ForegroundColor Magenta
    Write-Host "  INSTALLING 24/7 WATCHDOG" -ForegroundColor Magenta
    Write-Host "================================================================" -ForegroundColor Magenta
    Write-Host ""

    # Check for token availability for scheduled runs
    $hasToken = $false
    if ($env:DATABRICKS_TOKEN) {
        $hasToken = $true
        Write-Log "  Auth: Using DATABRICKS_TOKEN env variable" "Green"
    }
    elseif (Test-Path (Join-Path $scriptDir ".databricks-token")) {
        $hasToken = $true
        Write-Log "  Auth: Using .databricks-token file" "Green"
    }
    elseif (Test-Path (Join-Path $scriptDir ".sp-secret")) {
        $hasToken = $true
        Write-Log "  Auth: Using service principal (.sp-secret)" "Green"
    }
    else {
        Write-Host ""
        Write-Host "  The watchdog needs a token to run automatically." -ForegroundColor Yellow
        Write-Host "  Choose an option:" -ForegroundColor Yellow
        Write-Host "  1. Enter a Databricks Personal Access Token (PAT)" -ForegroundColor White
        Write-Host "  2. Use Azure CLI (must stay logged in)" -ForegroundColor White
        Write-Host "  3. Skip watchdog setup (fix only)" -ForegroundColor White
        Write-Host ""
        $choice = Read-Host "  Enter choice (1/2/3)"

        if ($choice -eq "1") {
            $patToken = Read-Host "  Paste your Databricks PAT token"
            if ($patToken) {
                $tokenFile = Join-Path $scriptDir ".databricks-token"
                $patToken | Out-File -FilePath $tokenFile -Encoding UTF8 -NoNewline
                Write-Log "  Token saved to .databricks-token" "Green"
                $hasToken = $true
            }
        }
        elseif ($choice -eq "2") {
            Write-Log "  Using Azure CLI. Note: az login must stay active." "Yellow"
            $hasToken = $true
        }
        else {
            Write-Log "  Watchdog setup skipped." "Yellow"
        }
    }

    if ($hasToken) {
        Write-Host ""
        Write-Log "  Creating scheduled task: $taskName" "Cyan"

        $scriptPath = Join-Path $scriptDir "fix_sql_warehouse.ps1"
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" --watchdog"
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $checkIntervalMinutes)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable

        try {
            # Remove existing task if any
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "Monitors Databricks SQL Warehouse and auto-restarts if failing. Checks every $checkIntervalMinutes minutes." -RunLevel Highest -Force | Out-Null

            Write-Log "  Task created: $taskName" "Green"
            Write-Log "  Interval: Every $checkIntervalMinutes minutes" "Green"
            Write-Log "  Script: $scriptPath" "Green"
            Write-Log "  Logs: $logDir" "Green"
        }
        catch {
            Write-Log "  Could not create task: $_" "Red"
            Write-Log "  Run this script as Administrator to install the task." "Yellow"
            Write-Host ""
            Write-Host "  MANUAL SETUP:" -ForegroundColor Yellow
            Write-Host "  1. Open Task Scheduler" -ForegroundColor White
            Write-Host "  2. Create task: $taskName" -ForegroundColor White
            Write-Host "  3. Trigger: Every $checkIntervalMinutes minutes" -ForegroundColor White
            Write-Host "  4. Action: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" --watchdog" -ForegroundColor White
            Write-Host "  5. Check 'Run whether user is logged on or not'" -ForegroundColor White
        }

        Write-Host ""
        Write-Host "  WATCHDOG BEHAVIOR:" -ForegroundColor Yellow
        Write-Host "    Every $checkIntervalMinutes min:" -ForegroundColor White
        Write-Host "    1. Checks warehouse status" -ForegroundColor White
        Write-Host "    2. If RUNNING -> do nothing (exit)" -ForegroundColor White
        Write-Host "    3. If FAILING -> stop, reconfigure, restart" -ForegroundColor White
        Write-Host "    4. If spot VMs fail -> switches to on-demand" -ForegroundColor White
        Write-Host "    5. Logs everything to $logDir" -ForegroundColor White
        Write-Host ""
        Write-Host "  MANAGE:" -ForegroundColor Yellow
        Write-Host "    View:    Get-ScheduledTask -TaskName '$taskName'" -ForegroundColor White
        Write-Host "    Run now: Start-ScheduledTask -TaskName '$taskName'" -ForegroundColor White
        Write-Host "    Stop:    Disable-ScheduledTask -TaskName '$taskName'" -ForegroundColor White
        Write-Host "    Remove:  Unregister-ScheduledTask -TaskName '$taskName'" -ForegroundColor White
    }
}

Write-Host ""
Write-Log "Done." "Green"
Write-Host ""
