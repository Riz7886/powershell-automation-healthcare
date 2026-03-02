$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "DATABRICKS SERVERLESS SQL WAREHOUSE AUTO-FIX (FULL SCAN)" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""
Write-Host "This script will automatically:" -ForegroundColor White
Write-Host "  - Scan ALL Azure subscriptions" -ForegroundColor White
Write-Host "  - Find ALL Databricks workspaces" -ForegroundColor White
Write-Host "  - Detect broken serverless warehouses" -ForegroundColor White
Write-Host "  - Convert them to PRO automatically" -ForegroundColor White
Write-Host ""

# ---------------------------------------------------------------
# STEP 1: Check Azure CLI and login
# ---------------------------------------------------------------
Write-Host "[1/6] Checking Azure CLI and login..." -ForegroundColor Yellow

try {
    $null = az version 2>$null | ConvertFrom-Json
}
catch {
    Write-Host "  FAILED: Azure CLI not installed." -ForegroundColor Red
    Write-Host "  Install from https://aka.ms/install-azure-cli"
    exit 1
}

$accountRaw = az account show -o json 2>$null
if (-not $accountRaw) {
    Write-Host "  Not logged in. Opening Azure login..." -ForegroundColor Yellow
    az login
}
Write-Host "  Logged in." -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------
# STEP 2: Get all subscriptions
# ---------------------------------------------------------------
Write-Host "[2/6] Scanning all Azure subscriptions..." -ForegroundColor Yellow

$subsRaw = az account list --query "[?state=='Enabled']" -o json 2>$null
$subs = $subsRaw | ConvertFrom-Json

Write-Host "  Found $($subs.Count) active subscription(s):" -ForegroundColor Green
foreach ($sub in $subs) {
    Write-Host "    - $($sub.name) ($($sub.id))" -ForegroundColor White
}
Write-Host ""

# ---------------------------------------------------------------
# STEP 3: Find ALL Databricks workspaces across all subscriptions
# ---------------------------------------------------------------
Write-Host "[3/6] Finding ALL Databricks workspaces (this may take a minute)..." -ForegroundColor Yellow
Write-Host ""

$allWorkspaces = @()

foreach ($sub in $subs) {
    Write-Host "  Scanning subscription: $($sub.name)..." -ForegroundColor White

    try {
        az account set --subscription $sub.id 2>$null
        $wsRaw = az databricks workspace list -o json 2>$null
        if ($wsRaw) {
            $wsList = $wsRaw | ConvertFrom-Json
            foreach ($ws in $wsList) {
                $allWorkspaces += @{
                    name           = $ws.name
                    url            = $ws.workspaceUrl
                    sku            = $ws.sku.name
                    resourceGroup  = $ws.resourceGroup
                    subscription   = $sub.name
                    subscriptionId = $sub.id
                    state          = $ws.provisioningState
                }
            }
            if ($wsList.Count -gt 0) {
                Write-Host "    Found $($wsList.Count) workspace(s)" -ForegroundColor Green
            }
            else {
                Write-Host "    No workspaces" -ForegroundColor Gray
            }
        }
    }
    catch {
        Write-Host "    Could not scan (may need provider registration)" -ForegroundColor Gray
    }
}

Write-Host ""

if ($allWorkspaces.Count -eq 0) {
    Write-Host "  No Databricks workspaces found in any subscription." -ForegroundColor Red
    exit 1
}

Write-Host "  Total workspaces found: $($allWorkspaces.Count)" -ForegroundColor Green
Write-Host ""

foreach ($ws in $allWorkspaces) {
    Write-Host "    $($ws.name)" -ForegroundColor Cyan
    Write-Host "      URL: $($ws.url)"
    Write-Host "      SKU: $($ws.sku)"
    Write-Host "      Subscription: $($ws.subscription)"
    Write-Host ""
}

# ---------------------------------------------------------------
# STEP 4: Scan each workspace for broken serverless warehouses
# ---------------------------------------------------------------
Write-Host "[4/6] Scanning each workspace for broken serverless warehouses..." -ForegroundColor Yellow
Write-Host ""

$dbResourceId = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
$totalFixed = 0
$totalFailed = 0
$workspacesWithIssues = @()

foreach ($ws in $allWorkspaces) {
    $wsHost = "https://$($ws.url)"
    $wsName = $ws.name

    Write-Host "  [$wsName] Checking..." -ForegroundColor White

    # Switch to correct subscription for this workspace
    try {
        az account set --subscription $ws.subscriptionId 2>$null
    }
    catch {
        Write-Host "  [$wsName] Could not switch subscription. Skipping." -ForegroundColor Yellow
        continue
    }

    # Try to get token
    $token = $null
    try {
        $tokenRaw = az account get-access-token --resource $dbResourceId --query accessToken -o tsv 2>$null
        if ($tokenRaw) {
            $token = $tokenRaw.Trim()
        }
    }
    catch {}

    if (-not $token) {
        Write-Host "  [$wsName] Could not get token automatically. Skipping." -ForegroundColor Yellow
        Write-Host "  [$wsName] To fix manually, generate a PAT from: $wsHost" -ForegroundColor Yellow
        Write-Host ""
        continue
    }

    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
    }

    # List warehouses
    try {
        $whResponse = Invoke-RestMethod -Uri "$wsHost/api/2.0/sql/warehouses" -Headers $headers -Method Get
    }
    catch {
        $errCode = ""
        try { $errCode = $_.Exception.Response.StatusCode.value__ } catch {}
        if ($errCode -eq 403) {
            Write-Host "  [$wsName] Access denied (403). Your account may not have access." -ForegroundColor Yellow
            Write-Host "  [$wsName] To fix manually, generate a PAT from: $wsHost" -ForegroundColor Yellow
        }
        else {
            Write-Host "  [$wsName] Could not connect to API. Skipping." -ForegroundColor Yellow
        }
        Write-Host ""
        continue
    }

    $warehouses = $whResponse.warehouses

    if (-not $warehouses -or $warehouses.Count -eq 0) {
        Write-Host "  [$wsName] No SQL warehouses. Skipping." -ForegroundColor Gray
        Write-Host ""
        continue
    }

    # Find broken serverless warehouses
    $broken = @()
    foreach ($wh in $warehouses) {
        $isServerless = ($wh.warehouse_type -eq "TYPE_SERVERLESS") -or ($wh.enable_serverless_compute -eq $true)
        if ($isServerless) {
            $broken += $wh
        }
    }

    if ($broken.Count -eq 0) {
        Write-Host "  [$wsName] $($warehouses.Count) warehouse(s), all OK (no serverless)." -ForegroundColor Green
        Write-Host ""
        continue
    }

    Write-Host "  [$wsName] FOUND $($broken.Count) BROKEN SERVERLESS WAREHOUSE(S):" -ForegroundColor Red
    foreach ($wh in $broken) {
        Write-Host "    - $($wh.name) ($($wh.cluster_size), $($wh.state))" -ForegroundColor Red
    }
    Write-Host ""

    $workspacesWithIssues += $wsName

    # ---------------------------------------------------------------
    # FIX: Convert each broken warehouse to PRO
    # ---------------------------------------------------------------
    foreach ($wh in $broken) {
        $whId = $wh.id
        $whName = $wh.name

        Write-Host "  [$wsName] Fixing: $whName..." -ForegroundColor Yellow

        try {
            $currentWh = Invoke-RestMethod -Uri "$wsHost/api/2.0/sql/warehouses/$whId" -Headers $headers -Method Get
        }
        catch {
            Write-Host "  [$wsName] FAILED to read $whName. Skipping." -ForegroundColor Red
            $totalFailed++
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
            Write-Host "  [$wsName] FIXED: $whName" -ForegroundColor Green
            Write-Host "    Changed: warehouse_type -> PRO, enable_serverless_compute -> false" -ForegroundColor Green
            Write-Host "    Kept: name, size, auto_stop, clusters, tags (unchanged)" -ForegroundColor Green
            $totalFixed++
        }
        catch {
            $errMsg = $_.Exception.Message
            try { $errMsg = ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch {}
            Write-Host "  [$wsName] FAILED: $whName" -ForegroundColor Red
            Write-Host "    Error: $errMsg" -ForegroundColor Red
            $totalFailed++
        }
        Write-Host ""
    }
}

# ---------------------------------------------------------------
# STEP 5: Verify fixes
# ---------------------------------------------------------------
Write-Host "[5/6] Verifying fixes..." -ForegroundColor Yellow
Write-Host ""

foreach ($ws in $allWorkspaces) {
    $wsHost = "https://$($ws.url)"
    $wsName = $ws.name

    if ($workspacesWithIssues -notcontains $wsName) { continue }

    try {
        az account set --subscription $ws.subscriptionId 2>$null
        $tokenRaw = az account get-access-token --resource $dbResourceId --query accessToken -o tsv 2>$null
        if (-not $tokenRaw) { continue }
        $token = $tokenRaw.Trim()

        $headers = @{
            "Authorization" = "Bearer $token"
            "Content-Type"  = "application/json"
        }

        $verify = Invoke-RestMethod -Uri "$wsHost/api/2.0/sql/warehouses" -Headers $headers -Method Get

        Write-Host "  [$wsName] Current warehouse status:" -ForegroundColor White
        Write-Host ("    {0,-25} {1,-12} {2,-14} {3,-12}" -f "Name", "Size", "Type", "State")
        Write-Host ("    {0,-25} {1,-12} {2,-14} {3,-12}" -f "-------------------------", "------------", "--------------", "------------")

        $stillBroken = 0
        foreach ($wh in $verify.warehouses) {
            $isServerless = ($wh.warehouse_type -eq "TYPE_SERVERLESS") -or ($wh.enable_serverless_compute -eq $true)
            if ($isServerless) { $typeLabel = "SERVERLESS"; $stillBroken++ } else { $typeLabel = $wh.warehouse_type -replace "TYPE_", "" }
            $color = if ($isServerless) { "Red" } else { "Green" }
            Write-Host ("    {0,-25} {1,-12} {2,-14} {3,-12}" -f $wh.name, $wh.cluster_size, $typeLabel, $wh.state) -ForegroundColor $color
        }

        if ($stillBroken -eq 0) {
            Write-Host "    VERIFIED: All warehouses fixed." -ForegroundColor Green
        }
        else {
            Write-Host "    WARNING: $stillBroken still serverless." -ForegroundColor Yellow
        }
        Write-Host ""
    }
    catch {
        Write-Host "  [$wsName] Could not verify. Check Databricks UI." -ForegroundColor Yellow
        Write-Host ""
    }
}

# ---------------------------------------------------------------
# STEP 6: Summary
# ---------------------------------------------------------------
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  Subscriptions scanned: $($subs.Count)"
Write-Host "  Workspaces scanned: $($allWorkspaces.Count)"
Write-Host "  Workspaces with issues: $($workspacesWithIssues.Count)"
Write-Host "  Warehouses fixed: $totalFixed" -ForegroundColor Green
Write-Host "  Warehouses failed: $totalFailed" -ForegroundColor $(if ($totalFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($totalFixed -gt 0 -and $totalFailed -eq 0) {
    Write-Host "SUCCESS: All broken serverless warehouses converted to Pro." -ForegroundColor Green
    Write-Host "Go start them in the Databricks SQL Warehouses page." -ForegroundColor Green
}
elseif ($totalFailed -gt 0) {
    Write-Host "PARTIAL: $totalFixed fixed, $totalFailed failed." -ForegroundColor Yellow
    Write-Host "For failed ones, generate a PAT from that workspace and run again." -ForegroundColor Yellow
}
elseif ($totalFixed -eq 0 -and $workspacesWithIssues.Count -eq 0) {
    Write-Host "NO ISSUES FOUND: All warehouses across all workspaces are OK." -ForegroundColor Green
}
Write-Host ""
Write-Host "Completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""
