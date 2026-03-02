$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "DATABRICKS SERVERLESS SQL WAREHOUSE AUTO-FIX" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

# ---------------------------------------------------------------
# STEP 1: Set workspace URL
# ---------------------------------------------------------------
Write-Host "[1/5] Setting workspace..." -ForegroundColor Yellow

$wsHost = "https://adb-3248848193480666.6.azuredatabricks.net"
Write-Host "  Workspace: $wsHost" -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------
# STEP 2: Get API token
# ---------------------------------------------------------------
Write-Host "[2/5] Getting Databricks API token..." -ForegroundColor Yellow

$dbResourceId = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

try {
    $tokenRaw = az account get-access-token --resource $dbResourceId --query accessToken -o tsv 2>$null
    if (-not $tokenRaw) { throw "Empty token" }
    $token = $tokenRaw.Trim()
    Write-Host "  Token obtained via Azure CLI." -ForegroundColor Green
}
catch {
    Write-Host "  Could not get token automatically." -ForegroundColor Yellow
    $token = Read-Host "  Enter Databricks Personal Access Token (dapi...)"
}
Write-Host ""

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# ---------------------------------------------------------------
# STEP 3: List SQL warehouses
# ---------------------------------------------------------------
Write-Host "[3/5] Listing SQL warehouses..." -ForegroundColor Yellow

try {
    $whResponse = Invoke-RestMethod -Uri "$wsHost/api/2.0/sql/warehouses" -Headers $headers -Method Get
}
catch {
    Write-Host "  FAILED: Could not connect to Databricks SQL API" -ForegroundColor Red
    Write-Host "  Error: $($_.Exception.Message)"
    Write-Host ""
    Write-Host "  If the token expired, run this to get a new one:" -ForegroundColor Yellow
    Write-Host "  az account get-access-token --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv"
    exit 1
}

$warehouses = $whResponse.warehouses

if (-not $warehouses -or $warehouses.Count -eq 0) {
    Write-Host "  No SQL warehouses found." -ForegroundColor Yellow
    exit 0
}

Write-Host "  Found $($warehouses.Count) warehouse(s):" -ForegroundColor Green
Write-Host ""
Write-Host ("  {0,-25} {1,-12} {2,-14} {3,-12}" -f "Name", "Size", "Type", "State")
Write-Host ("  {0,-25} {1,-12} {2,-14} {3,-12}" -f "-------------------------", "------------", "--------------", "------------")

$brokenWarehouses = @()

foreach ($wh in $warehouses) {
    $isServerless = ($wh.warehouse_type -eq "TYPE_SERVERLESS") -or ($wh.enable_serverless_compute -eq $true)

    if ($isServerless) {
        $typeLabel = "SERVERLESS"
        $flag = " << BROKEN"
        $brokenWarehouses += $wh
    }
    else {
        $typeLabel = $wh.warehouse_type -replace "TYPE_", ""
        $flag = ""
    }

    $color = if ($isServerless) { "Red" } else { "White" }
    Write-Host ("  {0,-25} {1,-12} {2,-14} {3,-12}{4}" -f $wh.name, $wh.cluster_size, $typeLabel, $wh.state, $flag) -ForegroundColor $color
}

Write-Host ""

if ($brokenWarehouses.Count -eq 0) {
    Write-Host "  No serverless warehouses found. Nothing to fix." -ForegroundColor Green
    Write-Host "  All warehouses are already Classic or Pro." -ForegroundColor Green
    exit 0
}

Write-Host "  Found $($brokenWarehouses.Count) serverless warehouse(s) to fix." -ForegroundColor Yellow
Write-Host ""

# ---------------------------------------------------------------
# STEP 4: Convert serverless to PRO
# ---------------------------------------------------------------
Write-Host "[4/5] Converting serverless warehouses to Pro..." -ForegroundColor Yellow
Write-Host "  ONLY changing the type. All other settings stay the same." -ForegroundColor Yellow
Write-Host ""

$fixed = 0
$failed = 0

foreach ($wh in $brokenWarehouses) {
    $whId = $wh.id
    $whName = $wh.name

    try {
        $currentWh = Invoke-RestMethod -Uri "$wsHost/api/2.0/sql/warehouses/$whId" -Headers $headers -Method Get
    }
    catch {
        Write-Host "  FAILED: Could not read warehouse $whName" -ForegroundColor Red
        $failed++
        continue
    }

    $editPayload = @{
        id                        = $whId
        name                      = $currentWh.name
        cluster_size              = $currentWh.cluster_size
        warehouse_type            = "PRO"
        enable_serverless_compute = $false
    }

    if ($null -ne $currentWh.auto_stop_mins) { $editPayload.auto_stop_mins = $currentWh.auto_stop_mins }
    if ($null -ne $currentWh.min_num_clusters) { $editPayload.min_num_clusters = $currentWh.min_num_clusters }
    if ($null -ne $currentWh.max_num_clusters) { $editPayload.max_num_clusters = $currentWh.max_num_clusters }
    if ($null -ne $currentWh.spot_instance_policy) { $editPayload.spot_instance_policy = $currentWh.spot_instance_policy }
    if ($null -ne $currentWh.tags) { $editPayload.tags = $currentWh.tags }
    if ($null -ne $currentWh.channel) { $editPayload.channel = $currentWh.channel }

    $editJson = $editPayload | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri "$wsHost/api/2.0/sql/warehouses/$whId/edit" -Headers $headers -Method Post -Body $editJson
        Write-Host "  FIXED: $whName" -ForegroundColor Green
        Write-Host "    ID: $whId"
        Write-Host "    Changed: warehouse_type -> PRO, enable_serverless_compute -> false"
        Write-Host "    Kept: name, size, auto_stop, clusters, tags (all unchanged)"
        $fixed++
    }
    catch {
        $errMsg = $_.Exception.Message
        try { $errMsg = ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch {}
        Write-Host "  FAILED: $whName" -ForegroundColor Red
        Write-Host "    Error: $errMsg"
        $failed++
    }
    Write-Host ""
}

# ---------------------------------------------------------------
# STEP 5: Verify
# ---------------------------------------------------------------
Write-Host "[5/5] Verifying fix..." -ForegroundColor Yellow
Write-Host ""

try {
    $verify = Invoke-RestMethod -Uri "$wsHost/api/2.0/sql/warehouses" -Headers $headers -Method Get

    Write-Host ("  {0,-25} {1,-12} {2,-14} {3,-12}" -f "Name", "Size", "Type", "State")
    Write-Host ("  {0,-25} {1,-12} {2,-14} {3,-12}" -f "-------------------------", "------------", "--------------", "------------")

    $stillBroken = 0
    foreach ($wh in $verify.warehouses) {
        $isServerless = ($wh.warehouse_type -eq "TYPE_SERVERLESS") -or ($wh.enable_serverless_compute -eq $true)
        if ($isServerless) { $typeLabel = "SERVERLESS"; $stillBroken++ } else { $typeLabel = $wh.warehouse_type -replace "TYPE_", "" }
        $color = if ($isServerless) { "Red" } else { "Green" }
        Write-Host ("  {0,-25} {1,-12} {2,-14} {3,-12}" -f $wh.name, $wh.cluster_size, $typeLabel, $wh.state) -ForegroundColor $color
    }

    Write-Host ""
    if ($stillBroken -eq 0) {
        Write-Host "  VERIFIED: All warehouses are now Classic or Pro." -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: $stillBroken serverless warehouse(s) still remain." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "  Could not verify. Check the Databricks UI." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Workspace: $wsHost"
Write-Host "  Warehouses fixed: $fixed" -ForegroundColor Green
Write-Host "  Warehouses failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($fixed -gt 0 -and $failed -eq 0) {
    Write-Host "SUCCESS: All serverless warehouses converted to Pro." -ForegroundColor Green
    Write-Host "Go start them in the Databricks SQL Warehouses page now." -ForegroundColor Green
}
elseif ($failed -gt 0) {
    Write-Host "PARTIAL: $fixed fixed, $failed failed." -ForegroundColor Yellow
}
Write-Host ""
