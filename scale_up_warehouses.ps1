$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  DATABRICKS WAREHOUSE SCALE-UP" -ForegroundColor Cyan
Write-Host "  Increase compute + restart services" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

$dbResource = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

# Both workspace URLs
$workspaces = @(
    @{ name = "pyxlake-databricks"; url = "https://adb-3248848193480666.6.azuredatabricks.net" },
    @{ name = "pyx-warehouse-prod"; url = "https://adb-2758318924173706.6.azuredatabricks.net" }
)

# ---------------------------------------------------------------
# SCALING CONFIG - what to set each warehouse to
# ---------------------------------------------------------------
# Size options: 2X-Small, X-Small, Small, Medium, Large, X-Large, 2X-Large
$targetSize = "Small"          # Bump from 2X-Small to Small
$targetMaxClusters = 2         # Allow 2 clusters for auto-scaling
$autoStopMinutes = 15          # Auto-stop after 15 min idle

Write-Host "  Target size: $targetSize" -ForegroundColor Yellow
Write-Host "  Target max clusters: $targetMaxClusters" -ForegroundColor Yellow
Write-Host ""

# ---------------------------------------------------------------
# AUTH - Try Azure CLI first, then ask for PAT
# ---------------------------------------------------------------
Write-Host "[1/3] Getting authentication..." -ForegroundColor Yellow

$useAzCli = $false
$globalToken = $null

try {
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if ($acct) {
        Write-Host "  Azure CLI: logged in as $($acct.user.name)" -ForegroundColor Green
        $tokenRaw = az account get-access-token --resource $dbResource --query accessToken -o tsv 2>$null
        if ($tokenRaw) {
            $globalToken = $tokenRaw.Trim()
            $useAzCli = $true
            Write-Host "  Token: OK" -ForegroundColor Green
        }
    }
}
catch {}

if (-not $useAzCli) {
    Write-Host "  Azure CLI not available. Will prompt for PATs per workspace." -ForegroundColor Yellow
}
Write-Host ""

# ---------------------------------------------------------------
# PROCESS EACH WORKSPACE
# ---------------------------------------------------------------
$allResults = @()

foreach ($ws in $workspaces) {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Workspace: $($ws.name)" -ForegroundColor Cyan
    Write-Host "  URL: $($ws.url)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    $token = $globalToken

    if (-not $token) {
        $token = Read-Host "  Enter PAT for $($ws.name)"
        $token = $token.Trim()
    }

    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
    }

    # List warehouses
    Write-Host ""
    Write-Host "[2/3] Listing warehouses..." -ForegroundColor Yellow

    try {
        $resp = Invoke-RestMethod -Uri "$($ws.url)/api/2.0/sql/warehouses" -Headers $headers -Method Get -TimeoutSec 30
    }
    catch {
        Write-Host "  ERROR: Cannot connect to $($ws.name): $_" -ForegroundColor Red
        Write-Host "  If using PAT, make sure it's for this workspace." -ForegroundColor Yellow
        continue
    }

    if (-not $resp.warehouses -or $resp.warehouses.Count -eq 0) {
        Write-Host "  No warehouses found." -ForegroundColor Yellow
        continue
    }

    Write-Host ""
    Write-Host "  CURRENT STATE:" -ForegroundColor White
    Write-Host "  ---------------------------------------------------------------" -ForegroundColor Gray
    Write-Host ("  {0,-25} {1,-12} {2,-10} {3,-6} {4,-10}" -f "NAME", "SIZE", "TYPE", "MAX", "STATE") -ForegroundColor Gray
    Write-Host "  ---------------------------------------------------------------" -ForegroundColor Gray

    foreach ($wh in $resp.warehouses) {
        $maxC = 1
        if ($wh.max_num_clusters) { $maxC = $wh.max_num_clusters }
        $stateColor = switch ($wh.state) {
            "RUNNING" { "Green" }
            "STOPPED" { "Yellow" }
            "STARTING" { "Cyan" }
            default { "Gray" }
        }
        Write-Host ("  {0,-25} {1,-12} {2,-10} {3,-6} {4,-10}" -f $wh.name, $wh.cluster_size, $wh.warehouse_type, $maxC, $wh.state) -ForegroundColor $stateColor
    }

    Write-Host ""

    # Scale up each warehouse
    Write-Host "[3/3] Scaling up warehouses..." -ForegroundColor Yellow
    Write-Host ""

    foreach ($wh in $resp.warehouses) {
        $currentSize = $wh.cluster_size
        $currentMax = 1
        if ($wh.max_num_clusters) { $currentMax = $wh.max_num_clusters }
        $currentType = $wh.warehouse_type

        $needsChange = $false
        $newSize = $targetSize
        $newMax = $targetMaxClusters

        # Check if already at or above target
        $sizeLadder = @("2X-Small", "X-Small", "Small", "Medium", "Large", "X-Large", "2X-Large", "3X-Large", "4X-Large")
        $currentIdx = $sizeLadder.IndexOf($currentSize)
        $targetIdx = $sizeLadder.IndexOf($targetSize)

        if ($currentIdx -lt $targetIdx) {
            $needsChange = $true
        }
        elseif ($currentIdx -ge $targetIdx) {
            # Already at or above target size, keep current
            $newSize = $currentSize
        }

        if ($currentMax -lt $targetMaxClusters) {
            $needsChange = $true
        }
        else {
            $newMax = $currentMax
        }

        if (-not $needsChange) {
            Write-Host "  $($wh.name): Already at $currentSize / ${currentMax}x - no change needed" -ForegroundColor Green
            $allResults += @{
                workspace = $ws.name
                warehouse = $wh.name
                before = "$currentSize / ${currentMax}x"
                after = "$currentSize / ${currentMax}x"
                action = "NO CHANGE"
                state = $wh.state
            }
            continue
        }

        Write-Host "  $($wh.name): $currentSize/${currentMax}x -> $newSize/${newMax}x" -ForegroundColor Yellow -NoNewline

        try {
            $editBody = @{
                id = $wh.id
                name = $wh.name
                cluster_size = $newSize
                max_num_clusters = $newMax
                min_num_clusters = 1
                auto_stop_mins = $autoStopMinutes
                warehouse_type = $currentType
                enable_serverless_compute = $false
            } | ConvertTo-Json -Depth 5

            Invoke-RestMethod -Uri "$($ws.url)/api/2.0/sql/warehouses/$($wh.id)/edit" -Headers $headers -Method Post -Body $editBody -TimeoutSec 30 | Out-Null

            Write-Host " DONE" -ForegroundColor Green

            # Restart if running (to apply new size)
            if ($wh.state -eq "RUNNING") {
                Write-Host "    Restarting to apply new size..." -ForegroundColor Yellow -NoNewline
                try {
                    Invoke-RestMethod -Uri "$($ws.url)/api/2.0/sql/warehouses/$($wh.id)/stop" -Headers $headers -Method Post -TimeoutSec 30 | Out-Null
                    Start-Sleep -Seconds 3
                    Invoke-RestMethod -Uri "$($ws.url)/api/2.0/sql/warehouses/$($wh.id)/start" -Headers $headers -Method Post -TimeoutSec 30 | Out-Null
                    Write-Host " restarting" -ForegroundColor Green
                }
                catch {
                    Write-Host " restart failed (may need manual start): $_" -ForegroundColor Yellow
                }
            }
            elseif ($wh.state -eq "STOPPED") {
                # Start it
                Write-Host "    Starting warehouse..." -ForegroundColor Yellow -NoNewline
                try {
                    Invoke-RestMethod -Uri "$($ws.url)/api/2.0/sql/warehouses/$($wh.id)/start" -Headers $headers -Method Post -TimeoutSec 30 | Out-Null
                    Write-Host " starting" -ForegroundColor Green
                }
                catch {
                    Write-Host " start failed: $_" -ForegroundColor Yellow
                }
            }

            $allResults += @{
                workspace = $ws.name
                warehouse = $wh.name
                before = "$currentSize / ${currentMax}x"
                after = "$newSize / ${newMax}x"
                action = "SCALED UP"
                state = "RESTARTING"
            }
        }
        catch {
            Write-Host " FAILED: $_" -ForegroundColor Red
            $allResults += @{
                workspace = $ws.name
                warehouse = $wh.name
                before = "$currentSize / ${currentMax}x"
                after = "FAILED"
                action = "ERROR"
                state = $wh.state
            }
        }
    }

    Write-Host ""
}

# ---------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  SCALE-UP COMPLETE" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  {0,-20} {1,-25} {2,-18} {3,-18} {4,-12}" -f "WORKSPACE", "WAREHOUSE", "BEFORE", "AFTER", "ACTION") -ForegroundColor White
Write-Host "  -----------------------------------------------------------------------------------------" -ForegroundColor Gray

foreach ($r in $allResults) {
    $actionColor = switch ($r.action) {
        "SCALED UP" { "Green" }
        "NO CHANGE" { "Gray" }
        "ERROR"     { "Red" }
        default     { "Yellow" }
    }
    Write-Host ("  {0,-20} {1,-25} {2,-18} {3,-18} {4,-12}" -f $r.workspace, $r.warehouse, $r.before, $r.after, $r.action) -ForegroundColor $actionColor
}

Write-Host ""

$scaledCount = ($allResults | Where-Object { $_.action -eq "SCALED UP" }).Count
if ($scaledCount -gt 0) {
    Write-Host "  $scaledCount warehouse(s) scaled up and restarting." -ForegroundColor Green
    Write-Host "  They will be back online in 1-3 minutes." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Tell the team:" -ForegroundColor Yellow
    Write-Host "  'Scaled up warehouses from 2X-Small to Small with 2x auto-scaling." -ForegroundColor White
    Write-Host "   Services are restarting now, back online in 1-3 min.'" -ForegroundColor White
}
else {
    Write-Host "  All warehouses already at target size." -ForegroundColor Green
}

Write-Host ""
