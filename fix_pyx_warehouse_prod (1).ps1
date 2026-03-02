$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  FIX pyx-warehouse-prod ONLY" -ForegroundColor Cyan
Write-Host "  URL: adb-2756318932417370.6.azuredatabricks.net" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

$wsHost = "https://adb-2756318932417370.6.azuredatabricks.net"

Write-Host "  Target: pyx-warehouse-prod" -ForegroundColor Green
Write-Host "  URL: $wsHost" -ForegroundColor Green
Write-Host ""
Write-Host "  Generate a PAT from THIS workspace:" -ForegroundColor Yellow
Write-Host "  1. Open $wsHost" -ForegroundColor Yellow
Write-Host "  2. User icon (top right) > Settings > Developer" -ForegroundColor Yellow
Write-Host "  3. Access tokens > Generate new token" -ForegroundColor Yellow
Write-Host "  4. Paste below" -ForegroundColor Yellow
Write-Host ""

$token = Read-Host "Paste PAT here"
$token = $token.Trim()

Write-Host ""
Write-Host "Connecting to pyx-warehouse-prod..." -ForegroundColor Green

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

Write-Host ""
Write-Host "[1/3] Listing SQL warehouses on pyx-warehouse-prod..." -ForegroundColor Yellow

try {
    $whResponse = Invoke-RestMethod -Uri "$wsHost/api/2.0/sql/warehouses" -Headers $headers -Method Get
}
catch {
    Write-Host ""
    Write-Host "  FAILED to connect to pyx-warehouse-prod" -ForegroundColor Red
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Make sure:" -ForegroundColor Yellow
    Write-Host "  - The PAT was generated from pyx-warehouse-prod (NOT pyxlake-databricks)"
    Write-Host "  - Open $wsHost in browser first, THEN generate the token there"
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
        $flag = " << WILL FIX"
        $brokenWarehouses += $wh
    }
    else {
        $typeLabel = $wh.warehouse_type -replace "TYPE_", ""
        $flag = " (OK)"
    }

    $color = if ($isServerless) { "Red" } else { "Green" }
    Write-Host ("  {0,-25} {1,-12} {2,-14} {3,-12}{4}" -f $wh.name, $wh.cluster_size, $typeLabel, $wh.state, $flag) -ForegroundColor $color
}

Write-Host ""

if ($brokenWarehouses.Count -eq 0) {
    Write-Host "  Nothing to fix. All warehouses are already Classic or Pro." -ForegroundColor Green
    exit 0
}

Write-Host "  $($brokenWarehouses.Count) serverless warehouse(s) to convert." -ForegroundColor Yellow
Write-Host ""

Write-Host "[2/3] Converting Serverless to Pro..." -ForegroundColor Yellow
Write-Host "  Only changing type. Nothing else touched." -ForegroundColor Yellow
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
        Write-Host "  FAILED: Could not read $whName" -ForegroundColor Red
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
        Invoke-RestMethod -Uri "$wsHost/api/2.0/sql/warehouses/$whId/edit" -Headers $headers -Method Post -Body $editJson | Out-Null
        Write-Host "  FIXED: $whName" -ForegroundColor Green
        Write-Host "    Serverless -> PRO"
        Write-Host "    Name: $($currentWh.name) (unchanged)"
        Write-Host "    Size: $($currentWh.cluster_size) (unchanged)"
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

Write-Host "[3/3] Verifying..." -ForegroundColor Yellow
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
        Write-Host "  ALL VERIFIED. No serverless warehouses remaining." -ForegroundColor Green
    }
}
catch {
    Write-Host "  Could not verify. Check Databricks UI." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  DONE - pyx-warehouse-prod" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Fixed: $fixed" -ForegroundColor Green
Write-Host "  Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($fixed -gt 0 -and $failed -eq 0) {
    Write-Host "  SUCCESS. Go start the warehouses now." -ForegroundColor Green
}
Write-Host ""
