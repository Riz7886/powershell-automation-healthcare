###############################################################################
# Fix-Databricks-Warehouses.ps1
# 
# Fixes ALL 3 SQL Warehouses: salesforce, Starter Endpoint, Warehouse
# - Starts stopped warehouses
# - If permission error: deletes and recreates under YOUR identity
# - Waits and verifies all are RUNNING
#
# Usage:  .\Fix-Databricks-Warehouses.ps1
###############################################################################

param(
    [string]$WorkspaceUrl = "https://adb-3248848193480666.6.azuredatabricks.net"
)

$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  DATABRICKS SQL WAREHOUSE - FIX ALL 3 WAREHOUSES" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Get Azure AD Token
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[STEP 1] Getting Azure AD token..." -ForegroundColor Yellow

try {
    $account = az account show 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Not logged into Azure. Running az login..." -ForegroundColor Red
        az login
    }

    $currentUser = az account show --query "user.name" -o tsv
    Write-Host "  Logged in as: $currentUser" -ForegroundColor Green

    $token = az account get-access-token --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv

    if (-not $token) {
        Write-Host "  ERROR: Could not get Databricks token. Run: az login" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Token acquired!" -ForegroundColor Green
}
catch {
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Run: az login    then re-run this script" -ForegroundColor Yellow
    exit 1
}

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Get all warehouses
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[STEP 2] Getting all SQL Warehouses..." -ForegroundColor Yellow

try {
    $response = Invoke-RestMethod -Uri "$WorkspaceUrl/api/2.0/sql/warehouses" -Method Get -Headers $headers
    $warehouses = $response.warehouses
    Write-Host "  Found $($warehouses.Count) warehouses" -ForegroundColor Green
}
catch {
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

foreach ($wh in $warehouses) {
    $color = if ($wh.state -eq "RUNNING") { "Green" } elseif ($wh.state -eq "STARTING") { "Yellow" } else { "Red" }
    Write-Host "    [$($wh.state)] $($wh.name) | Size: $($wh.cluster_size) | ID: $($wh.id)" -ForegroundColor $color
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Fix and start each warehouse
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[STEP 3] Fixing and starting all warehouses..." -ForegroundColor Yellow
Write-Host ""

function Fix-And-Start-Warehouse {
    param($wh)

    $whName = $wh.name
    $whId   = $wh.id
    $whSize = if ($wh.cluster_size) { $wh.cluster_size } else { "2X-Small" }
    $whType = if ($wh.warehouse_type -eq "CLASSIC") { "CLASSIC" } else { "PRO" }
    $autoStop = if ($wh.auto_stop_mins) { $wh.auto_stop_mins } else { 15 }
    $maxClusters = if ($wh.max_num_clusters) { $wh.max_num_clusters } else { 1 }

    Write-Host "  ── $whName ──────────────────────────────────" -ForegroundColor Cyan

    # Already running? Skip.
    if ($wh.state -eq "RUNNING") {
        Write-Host "    ALREADY RUNNING - No action needed" -ForegroundColor Green
        return
    }

    # Already starting? Just wait.
    if ($wh.state -eq "STARTING") {
        Write-Host "    ALREADY STARTING - Will monitor in Step 4" -ForegroundColor Yellow
        return
    }

    # ── ATTEMPT 1: Try to start as-is ──
    Write-Host "    Attempt 1: Starting warehouse..." -ForegroundColor Yellow
    $startFailed = $false
    $permissionError = $false

    try {
        $result = Invoke-WebRequest -Uri "$WorkspaceUrl/api/2.0/sql/warehouses/$whId/start" `
            -Method Post -Headers $headers -UseBasicParsing -ErrorAction Stop
        
        Write-Host "    Start command accepted!" -ForegroundColor Green
        Start-Sleep -Seconds 5

        # Check if it actually started
        $check = Invoke-RestMethod -Uri "$WorkspaceUrl/api/2.0/sql/warehouses/$whId" -Method Get -Headers $headers
        if ($check.state -eq "RUNNING" -or $check.state -eq "STARTING") {
            Write-Host "    Status: $($check.state) - Looking good!" -ForegroundColor Green
            return
        }
        else {
            Write-Host "    Status: $($check.state) - May have failed" -ForegroundColor Yellow
            # Check health for errors
            if ($check.health -and $check.health.message) {
                Write-Host "    Health: $($check.health.message)" -ForegroundColor Red
                if ($check.health.message -match "PERMISSION" -or $check.health.message -match "not part of org") {
                    $permissionError = $true
                }
            }
            $startFailed = $true
        }
    }
    catch {
        $errorBody = ""
        try {
            if ($_.Exception.Response) {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $errorBody = $reader.ReadToEnd()
                $reader.Close()
            }
        } catch {}

        $fullError = "$($_.Exception.Message) $errorBody"
        Write-Host "    Start failed: $fullError" -ForegroundColor Red

        if ($fullError -match "PERMISSION_DENIED" -or $fullError -match "not part of org" -or $fullError -match "403") {
            $permissionError = $true
        }
        $startFailed = $true
    }

    # ── ATTEMPT 2: If permission error, delete and recreate ──
    if ($permissionError) {
        Write-Host ""
        Write-Host "    PERMISSION ERROR - Recreating warehouse under YOUR identity..." -ForegroundColor Yellow
        Write-Host ""

        # Delete the broken warehouse
        Write-Host "    Deleting old $whName..." -ForegroundColor Yellow
        try {
            # Stop first if needed
            try {
                Invoke-RestMethod -Uri "$WorkspaceUrl/api/2.0/sql/warehouses/$whId/stop" `
                    -Method Post -Headers $headers -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            } catch {}

            Invoke-RestMethod -Uri "$WorkspaceUrl/api/2.0/sql/warehouses/$whId" `
                -Method Delete -Headers $headers -ErrorAction Stop
            Write-Host "    Deleted!" -ForegroundColor Green
            Start-Sleep -Seconds 5
        }
        catch {
            Write-Host "    Delete warning: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "    Continuing anyway..." -ForegroundColor Yellow
            Start-Sleep -Seconds 3
        }

        # Recreate
        Write-Host "    Creating new $whName (Size: $whSize, Type: $whType)..." -ForegroundColor Yellow

        $body = @{
            name                 = $whName
            cluster_size         = $whSize
            max_num_clusters     = $maxClusters
            auto_stop_mins       = $autoStop
            warehouse_type       = $whType
            enable_photon        = $true
            spot_instance_policy = "COST_OPTIMIZED"
        } | ConvertTo-Json

        try {
            $newWh = Invoke-RestMethod -Uri "$WorkspaceUrl/api/2.0/sql/warehouses" `
                -Method Post -Headers $headers -Body $body -ErrorAction Stop

            Write-Host "    Created! New ID: $($newWh.id)" -ForegroundColor Green

            # Start the new warehouse
            Start-Sleep -Seconds 3
            Write-Host "    Starting new $whName..." -ForegroundColor Yellow
            Invoke-RestMethod -Uri "$WorkspaceUrl/api/2.0/sql/warehouses/$($newWh.id)/start" `
                -Method Post -Headers $headers -ErrorAction Stop
            Write-Host "    Start command sent!" -ForegroundColor Green
        }
        catch {
            Write-Host "    RECREATE FAILED: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    You may need to create this one manually in the UI" -ForegroundColor Yellow
        }
    }
    elseif ($startFailed) {
        # Not permission — could be quota or other issue
        Write-Host "    Non-permission error. Trying one more time..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        try {
            Invoke-RestMethod -Uri "$WorkspaceUrl/api/2.0/sql/warehouses/$whId/start" `
                -Method Post -Headers $headers -ErrorAction Stop
            Write-Host "    Retry start command sent!" -ForegroundColor Green
        }
        catch {
            Write-Host "    Retry also failed. May need Azure quota increase." -ForegroundColor Red
        }
    }
}

# Process each warehouse
foreach ($wh in $warehouses) {
    Fix-And-Start-Warehouse -wh $wh
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Monitor until all running (up to 6 minutes)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "========================================================" -ForegroundColor Yellow
Write-Host "[STEP 4] Monitoring warehouse startup (up to 6 min)..." -ForegroundColor Yellow
Write-Host "========================================================" -ForegroundColor Yellow
Write-Host ""

$maxWait = 360
$elapsed = 0
$interval = 15

while ($elapsed -lt $maxWait) {
    Start-Sleep -Seconds $interval
    $elapsed += $interval

    try {
        $response = Invoke-RestMethod -Uri "$WorkspaceUrl/api/2.0/sql/warehouses" -Method Get -Headers $headers
        $current = $response.warehouses
    }
    catch {
        Write-Host "  [$elapsed s] Error checking: $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    $allRunning = $true
    Write-Host "  [$elapsed s] " -NoNewline

    foreach ($wh in $current) {
        $icon = switch ($wh.state) {
            "RUNNING"  { "GREEN" }
            "STARTING" { "STARTING" }
            "STOPPED"  { "STOPPED" }
            default    { $wh.state }
        }
        $color = switch ($wh.state) {
            "RUNNING"  { "Green" }
            "STARTING" { "Yellow" }
            default    { "Red" }
        }
        Write-Host "[$icon] $($wh.name)  " -ForegroundColor $color -NoNewline

        if ($wh.state -ne "RUNNING") { $allRunning = $false }
    }
    Write-Host ""

    if ($allRunning) {
        Write-Host ""
        Write-Host "========================================================" -ForegroundColor Green
        Write-Host "" -ForegroundColor Green
        Write-Host "     ALL 3 WAREHOUSES ARE RUNNING!!" -ForegroundColor Green
        Write-Host "" -ForegroundColor Green
        Write-Host "========================================================" -ForegroundColor Green
        Write-Host ""
        foreach ($wh in $current) {
            Write-Host "  [RUNNING] $($wh.name) | $($wh.cluster_size) | $($wh.warehouse_type)" -ForegroundColor Green
        }
        Write-Host ""
        Write-Host "  Everything is fixed. You're good." -ForegroundColor Green
        Write-Host ""
        exit 0
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: Timeout — show final status and troubleshooting
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================================" -ForegroundColor Yellow
Write-Host "  TIMEOUT - Some warehouses may not have started" -ForegroundColor Yellow
Write-Host "========================================================" -ForegroundColor Yellow
Write-Host ""

try {
    $response = Invoke-RestMethod -Uri "$WorkspaceUrl/api/2.0/sql/warehouses" -Method Get -Headers $headers
    foreach ($wh in $response.warehouses) {
        $color = if ($wh.state -eq "RUNNING") { "Green" } else { "Red" }
        Write-Host "  [$($wh.state)] $($wh.name)" -ForegroundColor $color

        if ($wh.state -ne "RUNNING" -and $wh.state -ne "STARTING") {
            try {
                $detail = Invoke-RestMethod -Uri "$WorkspaceUrl/api/2.0/sql/warehouses/$($wh.id)" `
                    -Method Get -Headers $headers
                if ($detail.health -and $detail.health.message) {
                    Write-Host "    Error: $($detail.health.message)" -ForegroundColor Red
                }
            } catch {}
        }
    }
}
catch {
    Write-Host "  Could not get final status" -ForegroundColor Red
}

Write-Host ""
Write-Host "  TROUBLESHOOTING:" -ForegroundColor Yellow
Write-Host "  1. Azure Portal > Subscriptions > Usage + quotas" -ForegroundColor White
Write-Host "     Search 'Standard EDSv4' - need at least 32 cores" -ForegroundColor White
Write-Host "  2. If quota is low: Request increase to 64 cores" -ForegroundColor White
Write-Host "  3. Or reduce warehouse size to 2X-Small in Databricks UI" -ForegroundColor White
Write-Host "  4. Check Databricks Admin Console > Settings > Identity" -ForegroundColor White
Write-Host ""
