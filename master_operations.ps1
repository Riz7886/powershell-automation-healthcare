$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
$outputDir = Join-Path $scriptDir "MasterOps_$timestamp"
$archiveDir = Join-Path $outputDir "Archive"
$reportHtml = Join-Path $outputDir "Master_Operations_Report.html"
$reportCsv = Join-Path $outputDir "Master_Operations_Data.csv"
$logFile = Join-Path $outputDir "master_operations.log"

New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
New-Item -Path $archiveDir -ItemType Directory -Force | Out-Null

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  MASTER OPERATIONS SCRIPT" -ForegroundColor Cyan
Write-Host "  1. Databricks Service Account Setup" -ForegroundColor Cyan
Write-Host "  2. Scan All SQL Databases (All Subscriptions)" -ForegroundColor Cyan
Write-Host "  3. Find and Delete Idle Databases" -ForegroundColor Cyan
Write-Host "  4. Drop Tier Per Brian Recommendations" -ForegroundColor Cyan
Write-Host "  5. Generate HTML Report + CSV Export" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "  Output: $outputDir"
Write-Host ""

$spName = "databricks-service-principal"
$appId = "e44f4026-8d8e-4a26-a5c7-46269cc0d7de"
$dbResource = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

$idleDaysThreshold = 14
$dryRun = $true

$dtuPricing = @{
    "Basic" = @{ DTU = 5;    Price = 4.99;    Edition = "Basic";    Objective = "Basic" }
    "S0"    = @{ DTU = 10;   Price = 15.03;   Edition = "Standard"; Objective = "S0" }
    "S1"    = @{ DTU = 20;   Price = 30.05;   Edition = "Standard"; Objective = "S1" }
    "S2"    = @{ DTU = 50;   Price = 75.13;   Edition = "Standard"; Objective = "S2" }
    "S3"    = @{ DTU = 100;  Price = 150.26;  Edition = "Standard"; Objective = "S3" }
    "S4"    = @{ DTU = 200;  Price = 300.52;  Edition = "Standard"; Objective = "S4" }
    "S6"    = @{ DTU = 400;  Price = 601.03;  Edition = "Standard"; Objective = "S6" }
    "S7"    = @{ DTU = 800;  Price = 1202.06; Edition = "Standard"; Objective = "S7" }
    "S9"    = @{ DTU = 1600; Price = 2404.13; Edition = "Standard"; Objective = "S9" }
    "S12"   = @{ DTU = 3000; Price = 4507.74; Edition = "Standard"; Objective = "S12" }
}

function Get-RecommendedTier {
    param(
        [string]$ResourceGroup,
        [string]$CurrentSku,
        [string]$Edition,
        [double]$AvgDtu,
        [double]$MaxDtu,
        [int]$Connections,
        [double]$CurrentPrice
    )

    if ($Connections -eq 0 -and $AvgDtu -lt 0.5) {
        return @{ Tier = "ELIMINATE"; Price = 0; Action = "DELETE"; Priority = "Critical" }
    }

    $rgLower = $ResourceGroup.ToLower()
    $isQA = $rgLower -match "qa|test|dev|sandbox"
    $isPreProd = $rgLower -match "preprod|pre-prod|staging|uat"

    if ($isQA) {
        if ($CurrentSku -ne "Basic") {
            return @{ Tier = "Basic"; Price = 4.99; Action = "DROP"; Priority = "High" }
        }
        return @{ Tier = $CurrentSku; Price = $CurrentPrice; Action = "OK"; Priority = "Low" }
    }

    if ($isPreProd) {
        if ($AvgDtu -lt 5 -and $MaxDtu -lt 15) {
            return @{ Tier = "Basic"; Price = 4.99; Action = "DROP"; Priority = "High" }
        }
        if ($CurrentSku -notin @("Basic", "S0") -and $AvgDtu -lt 10) {
            return @{ Tier = "S0"; Price = 15.03; Action = "DROP"; Priority = "High" }
        }
        return @{ Tier = $CurrentSku; Price = $CurrentPrice; Action = "OK"; Priority = "Low" }
    }

    if ($AvgDtu -lt 2 -and $MaxDtu -lt 10 -and $Connections -lt 50) {
        if ($CurrentSku -notin @("Basic", "S0")) {
            return @{ Tier = "S0"; Price = 15.03; Action = "DROP"; Priority = "High" }
        }
    }
    elseif ($AvgDtu -lt 5 -and $MaxDtu -lt 20) {
        if ($CurrentSku -notin @("Basic", "S0")) {
            return @{ Tier = "S0"; Price = 15.03; Action = "DROP"; Priority = "High" }
        }
    }
    elseif ($AvgDtu -lt 15 -and $MaxDtu -lt 40) {
        if ($CurrentSku -notin @("Basic", "S0", "S1")) {
            return @{ Tier = "S1"; Price = 30.05; Action = "DROP"; Priority = "Medium" }
        }
    }
    elseif ($AvgDtu -lt 30 -and $MaxDtu -lt 60) {
        if ($CurrentSku -notin @("Basic", "S0", "S1", "S2")) {
            return @{ Tier = "S2"; Price = 75.13; Action = "DROP"; Priority = "Medium" }
        }
    }
    elseif ($AvgDtu -lt 50 -and $MaxDtu -lt 80) {
        if ($CurrentSku -notin @("Basic", "S0", "S1", "S2", "S3")) {
            return @{ Tier = "S3"; Price = 150.26; Action = "DROP"; Priority = "Medium" }
        }
    }

    return @{ Tier = $CurrentSku; Price = $CurrentPrice; Action = "OK"; Priority = "Low" }
}

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    $entry | Out-File -FilePath $logFile -Append -Encoding UTF8
    Write-Host $entry -ForegroundColor $Color
}

if ($dryRun) {
    Write-Host "  MODE: DRY RUN (no changes will be made)" -ForegroundColor Yellow
    Write-Host "  Set `$dryRun = `$false on line 23 to execute" -ForegroundColor Yellow
}
else {
    Write-Host "  MODE: LIVE (changes WILL be applied)" -ForegroundColor Red
}
Write-Host ""

$allResults = @{
    sp = @{}
    databases = @()
    eliminateList = @()
    dropTierList = @()
    okList = @()
    errors = @()
    deletedDbs = @()
    changedDbs = @()
}

Write-Host "################################################################" -ForegroundColor Magenta
Write-Host "  PART 1: DATABRICKS SERVICE ACCOUNT SETUP" -ForegroundColor Magenta
Write-Host "################################################################" -ForegroundColor Magenta
Write-Host ""

Write-Log "[1.1] Checking Azure login..." "Yellow"
try {
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) { throw "not logged in" }
}
catch {
    Write-Log "  Logging in..." "Yellow"
    az login -o json 2>$null | Out-Null
    $acct = az account show -o json 2>$null | ConvertFrom-Json
}
Write-Log "  Logged in: $($acct.user.name)" "Green"
Write-Log "  Tenant: $($acct.tenantId)" "Green"
$allResults.sp.tenantId = $acct.tenantId
$allResults.sp.userName = $acct.user.name
Write-Host ""

Write-Log "[1.2] Verifying app registration ($appId)..." "Yellow"
try {
    $appCheck = az ad app show --id $appId -o json 2>$null | ConvertFrom-Json
    if ($appCheck) {
        Write-Log "  App found: $($appCheck.displayName)" "Green"
    }
}
catch {
    Write-Log "  WARNING: Cannot verify app registration" "Yellow"
}
Write-Host ""

Write-Log "[1.3] Creating/verifying Service Principal..." "Yellow"
$spObjectId = $null

$rawSp = az ad sp show --id $appId -o json 2>$null
if ($rawSp) {
    try {
        $existingSp = $rawSp | ConvertFrom-Json
        $spObjectId = $existingSp.id
        Write-Log "  SP already exists: $spObjectId" "Green"
    }
    catch {
        Write-Log "  SP lookup returned non-JSON, trying list..." "Yellow"
    }
}

if (-not $spObjectId) {
    $rawList = az ad sp list --filter "appId eq '$appId'" -o json 2>$null
    if ($rawList) {
        try {
            $spList = $rawList | ConvertFrom-Json
            if ($spList -and $spList.Count -gt 0) {
                $spObjectId = $spList[0].id
                Write-Log "  SP found via list: $spObjectId" "Green"
            }
        }
        catch {}
    }
}

if (-not $spObjectId) {
    Write-Log "  SP not found, creating..." "Yellow"
    $rawCreate = az ad sp create --id $appId -o json 2>$null
    if ($rawCreate) {
        try {
            $newSp = $rawCreate | ConvertFrom-Json
            $spObjectId = $newSp.id
            Write-Log "  Created SP: $spObjectId" "Green"
        }
        catch {
            Write-Log "  SP create returned non-JSON: $rawCreate" "Red"
            $allResults.errors += "SP create parse error: $rawCreate"
        }
    }
    else {
        $rawErr = az ad sp create --id $appId 2>&1
        Write-Log "  FAILED to create SP: $rawErr" "Red"
        $allResults.errors += "SP creation failed: $rawErr"
    }
}
$allResults.sp.objectId = $spObjectId
Write-Host ""

Write-Log "[1.4] Creating client secret (1-year expiry)..." "Yellow"
$secretValue = $null
$secretExpiry = (Get-Date).AddYears(1).ToString("yyyy-MM-ddTHH:mm:ssZ")
$secretName = "databricks-sp-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

try {
    $rawCred = az ad app credential reset --id $appId --display-name $secretName --end-date $secretExpiry --append -o json 2>$null
    if ($rawCred) {
        $credResult = $rawCred | ConvertFrom-Json
        $secretValue = $credResult.password

        if ($secretValue) {
            Write-Log "  Secret created: $secretName" "Green"
            Write-Log "  Expires: $secretExpiry" "Green"
            Write-Host ""
            Write-Host "  ============================================" -ForegroundColor Red
            Write-Host "  CLIENT SECRET: $secretValue" -ForegroundColor Red
            Write-Host "  SAVE THIS NOW - will not be shown again!" -ForegroundColor Red
            Write-Host "  ============================================" -ForegroundColor Red
            $allResults.sp.secret = $secretValue
            $allResults.sp.secretExpiry = $secretExpiry
            $allResults.sp.secretName = $secretName
        }
        else {
            Write-Log "  Secret created but password field empty" "Yellow"
            $allResults.sp.secret = "EMPTY"
        }
    }
    else {
        $rawErr = az ad app credential reset --id $appId --display-name $secretName --end-date $secretExpiry --append 2>&1
        Write-Log "  FAILED to create secret: $rawErr" "Red"
        $allResults.errors += "Secret creation failed: $rawErr"
        $allResults.sp.secret = "FAILED"
    }
}
catch {
    Write-Log "  FAILED to create secret: $_" "Red"
    $allResults.errors += "Secret creation failed: $_"
    $allResults.sp.secret = "FAILED"
}
Write-Host ""

Write-Log "[1.5] Assigning Contributor role on Databricks workspaces..." "Yellow"
$allSubs = az account list --query "[?state=='Enabled']" -o json 2>$null | ConvertFrom-Json
$allResults.sp.workspaces = @()

foreach ($sub in $allSubs) {
    $dbWorkspaces = az resource list --subscription $sub.id --resource-type "Microsoft.Databricks/workspaces" -o json 2>$null | ConvertFrom-Json
    if (-not $dbWorkspaces -or $dbWorkspaces.Count -eq 0) { continue }

    foreach ($ws in $dbWorkspaces) {
        Write-Host "  $($ws.name) ($($sub.name))..." -ForegroundColor Gray -NoNewline
        try {
            az role assignment create --assignee $appId --role "Contributor" --scope $ws.id --subscription $sub.id -o none 2>$null
            Write-Host " Contributor assigned" -ForegroundColor Green
            $allResults.sp.workspaces += @{ name = $ws.name; sub = $sub.name; status = "Assigned" }
        }
        catch {
            try {
                $existing = az role assignment list --assignee $appId --scope $ws.id --subscription $sub.id -o json 2>$null | ConvertFrom-Json
                if ($existing.Count -gt 0) {
                    Write-Host " already assigned" -ForegroundColor Green
                    $allResults.sp.workspaces += @{ name = $ws.name; sub = $sub.name; status = "Already Assigned" }
                }
                else {
                    Write-Host " FAILED" -ForegroundColor Yellow
                    $allResults.sp.workspaces += @{ name = $ws.name; sub = $sub.name; status = "Failed" }
                }
            }
            catch {
                Write-Host " FAILED" -ForegroundColor Yellow
                $allResults.sp.workspaces += @{ name = $ws.name; sub = $sub.name; status = "Failed" }
            }
        }
    }
}
Write-Host ""

Write-Log "[1.6] Adding SP to Databricks workspaces via SCIM API..." "Yellow"
foreach ($sub in $allSubs) {
    $dbWorkspaces = az resource list --subscription $sub.id --resource-type "Microsoft.Databricks/workspaces" -o json 2>$null | ConvertFrom-Json
    if (-not $dbWorkspaces -or $dbWorkspaces.Count -eq 0) { continue }

    az account set --subscription $sub.id 2>$null
    $token = $null
    try {
        $tokenRaw = az account get-access-token --resource $dbResource --query accessToken -o tsv 2>$null
        if ($tokenRaw) { $token = $tokenRaw.Trim() }
    }
    catch {}

    if (-not $token) { continue }

    $headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }

    foreach ($ws in $dbWorkspaces) {
        try {
            $detail = az resource show --ids $ws.id -o json 2>$null | ConvertFrom-Json
            $wsUrl = "https://$($detail.properties.workspaceUrl)"
        }
        catch { continue }

        Write-Host "  $($ws.name)..." -ForegroundColor Gray -NoNewline

        $wsSpId = $null
        try {
            $filter = [System.Uri]::EscapeDataString("applicationId eq `"$appId`"")
            $check = Invoke-RestMethod -Uri "$wsUrl/api/2.0/preview/scim/v2/ServicePrincipals?filter=$filter" -Headers $headers -Method Get -TimeoutSec 30
            if ($check.Resources -and $check.Resources.Count -gt 0) {
                $wsSpId = $check.Resources[0].id
                Write-Host " exists" -ForegroundColor Green
            }
        }
        catch {}

        if (-not $wsSpId) {
            try {
                $body = @{ schemas=@("urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal"); applicationId=$appId; displayName=$spName; active=$true } | ConvertTo-Json -Depth 5
                $result = Invoke-RestMethod -Uri "$wsUrl/api/2.0/preview/scim/v2/ServicePrincipals" -Headers $headers -Method Post -Body $body -TimeoutSec 30
                $wsSpId = $result.id
                Write-Host " added" -ForegroundColor Green
            }
            catch {
                Write-Host " failed" -ForegroundColor Yellow
            }
        }

        if ($wsSpId) {
            try {
                $grp = Invoke-RestMethod -Uri "$wsUrl/api/2.0/preview/scim/v2/Groups?filter=displayName%20eq%20%22admins%22" -Headers $headers -Method Get -TimeoutSec 30
                if ($grp.Resources.Count -gt 0) {
                    $patch = @{ schemas=@("urn:ietf:params:scim:api:messages:2.0:PatchOp"); Operations=@(@{ op="add"; value=@{ members=@(@{ value=$wsSpId }) } }) } | ConvertTo-Json -Depth 10
                    Invoke-RestMethod -Uri "$wsUrl/api/2.0/preview/scim/v2/Groups/$($grp.Resources[0].id)" -Headers $headers -Method Patch -Body $patch -TimeoutSec 30 | Out-Null
                }
            }
            catch {}
        }
    }
}

Write-Host ""
Write-Log "  PART 1 COMPLETE" "Green"
Write-Host ""

Write-Host "################################################################" -ForegroundColor Magenta
Write-Host "  PART 2: SCAN ALL SQL DATABASES" -ForegroundColor Magenta
Write-Host "################################################################" -ForegroundColor Magenta
Write-Host ""

$systemDbs = @("master", "tempdb", "model", "msdb")
$startTime = (Get-Date).AddDays(-$idleDaysThreshold).ToString("yyyy-MM-ddTHH:mm:ssZ")
$endTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")

# ---------------------------------------------------------------
# STEP 2.0: Pre-scan - find which subs have SQL servers
#   Skips cross-tenant subs that throw MFA errors
# ---------------------------------------------------------------
Write-Log "[2.0] Pre-scan: finding subscriptions with SQL servers..." "Yellow"
Write-Host "  Your tenant: $($acct.tenantId)" -ForegroundColor Gray
Write-Host ""

$subsWithSql = @()
$skippedSubs = @()
foreach ($sub in $allSubs) {
    # Skip subscriptions in different tenants (these cause the MFA errors)
    if ($sub.tenantId -and $sub.tenantId -ne $acct.tenantId) {
        Write-Host "  SKIP: $($sub.name) (different tenant: $($sub.tenantId))" -ForegroundColor DarkGray
        $skippedSubs += $sub.name
        continue
    }

    Write-Host "  Checking: $($sub.name)..." -ForegroundColor Gray -NoNewline

    az account set --subscription $sub.id 2>$null

    # Method 1: az sql server list
    $rawServers = $null
    $rawServers = az sql server list --subscription $sub.id -o json 2>$null
    if ($rawServers -and $rawServers.Trim().Length -gt 2) {
        try {
            $parsedServers = $rawServers | ConvertFrom-Json
            if ($parsedServers -and $parsedServers.Count -gt 0) {
                Write-Host " $($parsedServers.Count) SQL server(s)" -ForegroundColor Green
                $subsWithSql += @{ Sub = $sub; Servers = $parsedServers }
                continue
            }
        }
        catch {}
    }

    # Method 2: az resource list (fallback)
    $rawResources = az resource list --subscription $sub.id --resource-type "Microsoft.Sql/servers" -o json 2>$null
    if ($rawResources -and $rawResources.Trim().Length -gt 2) {
        try {
            $resourceServers = $rawResources | ConvertFrom-Json
            if ($resourceServers -and $resourceServers.Count -gt 0) {
                Write-Host " $($resourceServers.Count) SQL server(s) via resource list" -ForegroundColor Green
                $subsWithSql += @{ Sub = $sub; Servers = $resourceServers }
                continue
            }
        }
        catch {}
    }

    Write-Host " 0 servers" -ForegroundColor Gray
}

Write-Host ""
if ($skippedSubs.Count -gt 0) {
    Write-Log "  Skipped $($skippedSubs.Count) cross-tenant sub(s): $($skippedSubs -join ', ')" "DarkGray"
}

if ($subsWithSql.Count -eq 0) {
    Write-Log "  WARNING: No SQL servers found in any subscription!" "Red"
    Write-Host ""
    Write-Host "  DIAGNOSTIC INFO:" -ForegroundColor Yellow
    Write-Host "  Subscriptions in your tenant: $(($allSubs | Where-Object { $_.tenantId -eq $acct.tenantId }).Count)" -ForegroundColor White
    Write-Host "  Total subscriptions: $($allSubs.Count)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Trying Azure Resource Graph query..." -ForegroundColor Yellow

    $graphRaw = az graph query -q "Resources | where type =~ 'Microsoft.Sql/servers' | project name, resourceGroup, subscriptionId" --first 100 -o json 2>$null
    if ($graphRaw) {
        try {
            $graphData = ($graphRaw | ConvertFrom-Json).data
            if ($graphData -and $graphData.Count -gt 0) {
                Write-Host "  FOUND $($graphData.Count) SQL server(s) via Resource Graph:" -ForegroundColor Green
                foreach ($gr in $graphData) {
                    Write-Host "    $($gr.name) | RG: $($gr.resourceGroup) | Sub: $($gr.subscriptionId)" -ForegroundColor Cyan
                }
                Write-Host ""
                Write-Host "  Re-scanning those subscriptions..." -ForegroundColor Yellow
                $graphSubIds = $graphData | Select-Object -ExpandProperty subscriptionId -Unique
                foreach ($gsid in $graphSubIds) {
                    $gSub = $allSubs | Where-Object { $_.id -eq $gsid }
                    if (-not $gSub) {
                        Write-Host "    Sub $gsid not in your account list - skipped" -ForegroundColor Yellow
                        continue
                    }
                    az account set --subscription $gsid 2>$null
                    $rawSrv = az sql server list --subscription $gsid -o json 2>$null
                    if ($rawSrv -and $rawSrv.Trim().Length -gt 2) {
                        try {
                            $parsedSrv = $rawSrv | ConvertFrom-Json
                            if ($parsedSrv.Count -gt 0) {
                                $subsWithSql += @{ Sub = $gSub; Servers = $parsedSrv }
                                Write-Host "    $($gSub.name): $($parsedSrv.Count) server(s)" -ForegroundColor Green
                            }
                        }
                        catch {}
                    }
                }
            }
            else {
                Write-Host "  Resource Graph found 0 SQL servers." -ForegroundColor Red
            }
        }
        catch {
            Write-Host "  Resource Graph parse error: $_" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  Resource Graph not available (install: az extension add --name resource-graph)" -ForegroundColor Yellow
    }
    Write-Host ""
    if ($subsWithSql.Count -eq 0) {
        Write-Host "  MANUAL CHECK: Run this in your terminal:" -ForegroundColor Yellow
        Write-Host '  az sql server list --subscription "<your-sub-id>" -o table' -ForegroundColor White
        Write-Host ""
    }
}
else {
    Write-Log "  Found SQL servers in $($subsWithSql.Count) subscription(s)" "Green"
}

# ---------------------------------------------------------------
# STEP 2.1: Scan databases on subscriptions that have SQL servers
# ---------------------------------------------------------------
Write-Host ""
Write-Log "[2.1] Scanning databases across $($subsWithSql.Count) subscription(s)..." "Yellow"
Write-Host ""

$dbIndex = 0
foreach ($entry in $subsWithSql) {
    $sub = $entry.Sub
    $servers = $entry.Servers

    Write-Host "  Subscription: $($sub.name)" -ForegroundColor White
    az account set --subscription $sub.id 2>$null

    foreach ($srv in $servers) {
        $serverName = if ($srv.name) { $srv.name } else { $srv }
        $rg = if ($srv.resourceGroup) { $srv.resourceGroup } else { "" }
        if (-not $serverName -or -not $rg) { continue }

        Write-Host "    Server: $serverName (RG: $rg)" -ForegroundColor Cyan

        $databases = $null
        $rawDbs = az sql db list --server $serverName --resource-group $rg --subscription $sub.id -o json 2>$null
        if ($rawDbs -and $rawDbs.Trim().Length -gt 2) {
            try { $databases = $rawDbs | ConvertFrom-Json } catch {}
        }
        if (-not $databases) {
            Write-Host "      No databases or access denied" -ForegroundColor Yellow
            continue
        }

        foreach ($db in $databases) {
            if ($systemDbs -contains $db.name) { continue }

            $dbIndex++
            $dbName = $db.name
            $edition = $db.edition
            $sku = $db.currentServiceObjectiveName
            $status = $db.status
            $maxSizeGB = [math]::Round($db.maxSizeBytes / 1GB, 2)

            $currentSizeGB = 0
            try {
                $usageRaw = az sql db list-usages --server $serverName --name $dbName --resource-group $rg --subscription $sub.id -o json 2>$null
                if ($usageRaw) {
                    $usageJson = $usageRaw | ConvertFrom-Json
                    $storageUsage = $usageJson | Where-Object { $_.name -eq "database_size" -or $_.resourceName -eq "database_size" }
                    if ($storageUsage) {
                        $currentSizeGB = [math]::Round($storageUsage.currentValue / 1GB, 2)
                    }
                }
            }
            catch {}

            $avgDtu = 0
            $maxDtu = 0
            try {
                $dtuRaw = az monitor metrics list --resource $db.id --metric "dtu_consumption_percent" --start-time $startTime --end-time $endTime --interval PT1H --aggregation Average -o json 2>$null
                if ($dtuRaw) {
                    $dtuMetrics = $dtuRaw | ConvertFrom-Json
                    if ($dtuMetrics.value -and $dtuMetrics.value[0].timeseries -and $dtuMetrics.value[0].timeseries[0].data) {
                        $dataPoints = $dtuMetrics.value[0].timeseries[0].data | Where-Object { $null -ne $_.average }
                        if ($dataPoints.Count -gt 0) {
                            $avgDtu = [math]::Round(($dataPoints | Measure-Object -Property average -Average).Average, 2)
                            $maxDtu = [math]::Round(($dataPoints | Measure-Object -Property average -Maximum).Maximum, 2)
                        }
                    }
                }
            }
            catch {}

            $totalConnections = 0
            try {
                $connRaw = az monitor metrics list --resource $db.id --metric "connection_successful" --start-time $startTime --end-time $endTime --interval P1D --aggregation Total -o json 2>$null
                if ($connRaw) {
                    $connMetrics = $connRaw | ConvertFrom-Json
                    if ($connMetrics.value -and $connMetrics.value[0].timeseries -and $connMetrics.value[0].timeseries[0].data) {
                        $connPoints = $connMetrics.value[0].timeseries[0].data | Where-Object { $null -ne $_.total }
                        if ($connPoints.Count -gt 0) {
                            $totalConnections = [math]::Round(($connPoints | Measure-Object -Property total -Sum).Sum, 0)
                        }
                    }
                }
            }
            catch {}

            $currentPrice = 0
            if ($dtuPricing.ContainsKey($sku)) { $currentPrice = $dtuPricing[$sku].Price }

            $rec = Get-RecommendedTier -ResourceGroup $rg -CurrentSku $sku -Edition $edition -AvgDtu $avgDtu -MaxDtu $maxDtu -Connections $totalConnections -CurrentPrice $currentPrice

            $savings = $currentPrice - $rec.Price
            if ($savings -lt 0) { $savings = 0 }

            $dbInfo = [PSCustomObject]@{
                Index = $dbIndex
                Subscription = $sub.name
                SubscriptionId = $sub.id
                ResourceGroup = $rg
                Server = $serverName
                Database = $dbName
                Edition = $edition
                CurrentSku = $sku
                Status = $status
                CurrentSizeGB = $currentSizeGB
                MaxSizeGB = $maxSizeGB
                AvgDtuPercent = $avgDtu
                MaxDtuPercent = $maxDtu
                Connections7Days = $totalConnections
                CurrentPrice = $currentPrice
                RecommendedTier = $rec.Tier
                RecommendedPrice = $rec.Price
                Action = $rec.Action
                Priority = $rec.Priority
                MonthlySavings = $savings
                AnnualSavings = [math]::Round($savings * 12, 2)
                Deleted = $false
                TierChanged = $false
            }

            $recColor = switch ($rec.Action) {
                "DELETE"  { "Red" }
                "DROP"    { "Yellow" }
                "OK"      { "Green" }
                default   { "Gray" }
            }

            Write-Host ("      {0,-30} {1,-8} {2,-5} AvgDTU:{3,6}% Conn:{4,6} -> {5,-10} {6}" -f $dbName, $edition, $sku, $avgDtu, $totalConnections, $rec.Tier, $rec.Action) -ForegroundColor $recColor

            $allResults.databases += $dbInfo

            if ($rec.Action -eq "DELETE") { $allResults.eliminateList += $dbInfo }
            elseif ($rec.Action -eq "DROP") { $allResults.dropTierList += $dbInfo }
            else { $allResults.okList += $dbInfo }
        }
    }
    Write-Host ""
}

Write-Host ""
Write-Log "  Scan complete: $($allResults.databases.Count) databases found" "Green"
Write-Log "  ELIMINATE: $($allResults.eliminateList.Count)" "Red"
Write-Log "  DROP TIER: $($allResults.dropTierList.Count)" "Yellow"
Write-Log "  OK: $($allResults.okList.Count)" "Green"
Write-Host ""

Write-Host "################################################################" -ForegroundColor Magenta
Write-Host "  PART 3: DELETE IDLE DATABASES" -ForegroundColor Magenta
Write-Host "################################################################" -ForegroundColor Magenta
Write-Host ""

if ($allResults.eliminateList.Count -gt 0) {
    $elimCost = ($allResults.eliminateList | Measure-Object -Property CurrentPrice -Sum).Sum
    Write-Log "[3.1] Found $($allResults.eliminateList.Count) IDLE databases (cost: `$$elimCost/mo)" "Red"
    Write-Host ""

    foreach ($idb in $allResults.eliminateList) {
        Write-Host "  $($idb.Server)/$($idb.Database) | $($idb.CurrentSku) | `$$($idb.CurrentPrice)/mo | 0 connections" -ForegroundColor Red
    }
    Write-Host ""

    if ($dryRun) {
        Write-Log "  DRY RUN - No deletions. Set `$dryRun = `$false to execute." "Yellow"
    }
    else {
        Write-Log "[3.2] Archiving all idle databases before deletion..." "Yellow"

        foreach ($idb in $allResults.eliminateList) {
            $archFile = Join-Path $archiveDir "$($idb.Database)_$timestamp.txt"
            @"
DELETED DATABASE ARCHIVE
========================
Database:     $($idb.Database)
Server:       $($idb.Server)
Subscription: $($idb.Subscription)
ResourceGroup: $($idb.ResourceGroup)
Edition:      $($idb.Edition)
SKU:          $($idb.CurrentSku)
Size:         $($idb.CurrentSizeGB) GB
Avg DTU:      $($idb.AvgDtuPercent)%
Connections:  $($idb.Connections7Days)
Monthly Cost: `$$($idb.CurrentPrice)
Deleted By:   $($acct.user.name)
Deleted At:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Archive Expires: $(Get-Date (Get-Date).AddDays(60) -Format 'yyyy-MM-dd')
"@ | Out-File -FilePath $archFile -Encoding UTF8
            Write-Log "  Archived: $($idb.Database)" "Gray"
        }

        Write-Host ""
        Write-Log "[3.3] BATCH DELETING $($allResults.eliminateList.Count) idle databases (ALL AT ONCE)..." "Red"
        Write-Host ""

        $deleteJobs = @()
        foreach ($idb in $allResults.eliminateList) {
            Write-Host "  Launching delete: $($idb.Server)/$($idb.Database)..." -ForegroundColor Red
            $job = Start-Job -ScriptBlock {
                param($SubId, $Server, $DbName, $RG)
                az account set --subscription $SubId 2>$null
                az sql db delete --server $Server --name $DbName --resource-group $RG --yes -o none 2>&1
                if ($LASTEXITCODE -eq 0) { return "SUCCESS" } else { return "FAILED" }
            } -ArgumentList $idb.SubscriptionId, $idb.Server, $idb.Database, $idb.ResourceGroup
            $deleteJobs += @{ Job = $job; Db = $idb }
        }

        Write-Host ""
        Write-Log "  All $($deleteJobs.Count) delete jobs launched. Waiting for completion..." "Yellow"
        Write-Host ""

        $deleteJobs | ForEach-Object {
            $result = Receive-Job -Job $_.Job -Wait
            $dbRef = $_.Db
            Remove-Job -Job $_.Job -Force -ErrorAction SilentlyContinue

            if ($result -match "SUCCESS") {
                $dbRef.Deleted = $true
                $allResults.deletedDbs += $dbRef
                Write-Host "  $($dbRef.Server)/$($dbRef.Database) - DELETED" -ForegroundColor Green
            }
            else {
                Write-Host "  $($dbRef.Server)/$($dbRef.Database) - FAILED: $result" -ForegroundColor Yellow
                $allResults.errors += "Delete failed: $($dbRef.Server)/$($dbRef.Database) - $result"
            }
        }

        Write-Log "  Batch delete complete: $($allResults.deletedDbs.Count)/$($allResults.eliminateList.Count) succeeded" "Green"
    }
}
else {
    Write-Log "[3.1] No idle databases found." "Green"
}

Write-Host ""

Write-Host "################################################################" -ForegroundColor Magenta
Write-Host "  PART 4: DROP TIERS (Per Brian Recommendations)" -ForegroundColor Magenta
Write-Host "################################################################" -ForegroundColor Magenta
Write-Host ""

if ($allResults.dropTierList.Count -gt 0) {
    $dropSavings = ($allResults.dropTierList | Measure-Object -Property MonthlySavings -Sum).Sum
    Write-Log "[4.1] $($allResults.dropTierList.Count) databases to drop tier (savings: `$$([math]::Round($dropSavings, 2))/mo)" "Yellow"
    Write-Host ""

    Write-Host ("  {0,-20} {1,-30} {2,-6} {3,-6} {4,10} {5,10} {6,10}" -f "SERVER", "DATABASE", "FROM", "TO", "OLD COST", "NEW COST", "SAVINGS") -ForegroundColor White
    Write-Host "  $('-' * 120)" -ForegroundColor Gray

    foreach ($d in $allResults.dropTierList) {
        $savColor = if ($d.MonthlySavings -gt 0) { "Green" } else { "Gray" }
        Write-Host ("  {0,-20} {1,-30} {2,-6} {3,-6} `${4,9:N2} `${5,9:N2} `${6,9:N2}" -f $d.Server, $d.Database, $d.CurrentSku, $d.RecommendedTier, $d.CurrentPrice, $d.RecommendedPrice, $d.MonthlySavings) -ForegroundColor $savColor
    }
    Write-Host ""

    if ($dryRun) {
        Write-Log "  DRY RUN - No tier changes. Set `$dryRun = `$false to execute." "Yellow"
    }
    else {
        Write-Log "[4.2] BATCH CHANGING ALL $($allResults.dropTierList.Count) database tiers (ALL AT ONCE)..." "Cyan"
        Write-Host ""

        $tierJobs = @()
        foreach ($d in $allResults.dropTierList) {
            $targetInfo = $dtuPricing[$d.RecommendedTier]
            if (-not $targetInfo) { continue }

            Write-Host "  Launching tier change: $($d.Server)/$($d.Database) ($($d.CurrentSku) -> $($d.RecommendedTier))..." -ForegroundColor Cyan

            $job = Start-Job -ScriptBlock {
                param($SubId, $Server, $DbName, $RG, $Edition, $Objective)
                az account set --subscription $SubId 2>$null
                az sql db update --server $Server --name $DbName --resource-group $RG --edition $Edition --service-objective $Objective -o none 2>&1
                if ($LASTEXITCODE -eq 0) { return "SUCCESS" } else { return "FAILED" }
            } -ArgumentList $d.SubscriptionId, $d.Server, $d.Database, $d.ResourceGroup, $targetInfo.Edition, $targetInfo.Objective

            $tierJobs += @{ Job = $job; Db = $d }
        }

        Write-Host ""
        Write-Log "  All $($tierJobs.Count) tier change jobs launched. Waiting for completion..." "Yellow"
        Write-Host ""

        $tierJobs | ForEach-Object {
            $result = Receive-Job -Job $_.Job -Wait
            $dbRef = $_.Db
            Remove-Job -Job $_.Job -Force -ErrorAction SilentlyContinue

            if ($result -match "SUCCESS") {
                $dbRef.TierChanged = $true
                $allResults.changedDbs += $dbRef
                Write-Host "  $($dbRef.Server)/$($dbRef.Database): $($dbRef.CurrentSku) -> $($dbRef.RecommendedTier) - DONE" -ForegroundColor Green
            }
            else {
                Write-Host "  $($dbRef.Server)/$($dbRef.Database): $($dbRef.CurrentSku) -> $($dbRef.RecommendedTier) - FAILED: $result" -ForegroundColor Red
                $allResults.errors += "Tier change failed: $($dbRef.Server)/$($dbRef.Database) - $result"
            }
        }

        Write-Log "  Batch tier change complete: $($allResults.changedDbs.Count)/$($allResults.dropTierList.Count) succeeded" "Green"
    }
}
else {
    Write-Log "[4.1] All databases already at recommended tiers." "Green"
}

Write-Host ""

Write-Host "################################################################" -ForegroundColor Magenta
Write-Host "  PART 5: CSV EXPORT" -ForegroundColor Magenta
Write-Host "################################################################" -ForegroundColor Magenta
Write-Host ""

$allResults.databases | Select-Object `
    Subscription, ResourceGroup, Server, Database, Edition, CurrentSku, Status, `
    CurrentSizeGB, MaxSizeGB, AvgDtuPercent, MaxDtuPercent, Connections7Days, `
    CurrentPrice, RecommendedTier, RecommendedPrice, Action, Priority, `
    MonthlySavings, AnnualSavings, Deleted, TierChanged |
    Export-Csv -Path $reportCsv -NoTypeInformation -Encoding UTF8

Write-Log "  CSV exported: $reportCsv" "Green"
Write-Host ""

Write-Host "################################################################" -ForegroundColor Magenta
Write-Host "  PART 6: HTML REPORT" -ForegroundColor Magenta
Write-Host "################################################################" -ForegroundColor Magenta
Write-Host ""

$totalDbs = $allResults.databases.Count
$totalCurrentCost = [math]::Round(($allResults.databases | Measure-Object -Property CurrentPrice -Sum).Sum, 2)
$totalRecommendedCost = [math]::Round(($allResults.databases | Measure-Object -Property RecommendedPrice -Sum).Sum, 2)
$totalMonthlySavings = [math]::Round($totalCurrentCost - $totalRecommendedCost, 2)
$totalAnnualSavings = [math]::Round($totalMonthlySavings * 12, 2)
$elimCount = $allResults.eliminateList.Count
$elimCostTotal = [math]::Round(($allResults.eliminateList | Measure-Object -Property CurrentPrice -Sum).Sum, 2)
$dropCount = $allResults.dropTierList.Count
$dropSavingsTotal = [math]::Round(($allResults.dropTierList | Measure-Object -Property MonthlySavings -Sum).Sum, 2)
$okCount = $allResults.okList.Count
$modeLabel = if ($dryRun) { "DRY RUN" } else { "LIVE" }
$modeCss = if ($dryRun) { "background:#854d0e;color:#fde68a;border:1px solid #fbbf24" } else { "background:#991b1b;color:#fecaca;border:1px solid #f87171" }
$spSecret = if ($allResults.sp.secret -and $allResults.sp.secret -ne "FAILED") { $allResults.sp.secret } else { "FAILED" }

$subGroups = $allResults.databases | Group-Object -Property Subscription

$masterRows = ""
foreach ($db in $allResults.databases) {
    $actionColor = switch ($db.Action) {
        "DELETE" { "#f87171" }
        "DROP"   { "#fbbf24" }
        "OK"     { "#4ade80" }
        default  { "#94a3b8" }
    }
    $statusCol = ""
    if ($db.Deleted) { $statusCol = "<span style='color:#f87171;font-weight:bold'>DELETED</span>" }
    elseif ($db.TierChanged) { $statusCol = "<span style='color:#4ade80;font-weight:bold'>CHANGED</span>" }
    elseif ($dryRun -and $db.Action -ne "OK") { $statusCol = "<span style='color:#fbbf24'>DRY RUN</span>" }
    else { $statusCol = "-" }

    $masterRows += @"
<tr>
<td>$($db.Subscription)</td>
<td>$($db.Server)</td>
<td>$($db.Database)</td>
<td>$($db.Edition)</td>
<td>$($db.CurrentSku)</td>
<td>$($db.CurrentSizeGB) GB</td>
<td>$($db.AvgDtuPercent)%</td>
<td>$($db.MaxDtuPercent)%</td>
<td>$($db.Connections7Days)</td>
<td>`$$($db.CurrentPrice)</td>
<td style='color:$actionColor;font-weight:bold'>$($db.RecommendedTier)</td>
<td>`$$($db.RecommendedPrice)</td>
<td style='color:$actionColor;font-weight:bold'>$($db.Action)</td>
<td>`$$($db.MonthlySavings)</td>
<td>$statusCol</td>
</tr>
"@
}

$elimRows = ""
foreach ($db in $allResults.eliminateList) {
    $delStatus = if ($db.Deleted) { "<span style='color:#f87171'>DELETED</span>" } elseif ($dryRun) { "<span style='color:#fbbf24'>PENDING</span>" } else { "-" }
    $elimRows += @"
<tr>
<td>$($db.Subscription)</td>
<td>$($db.Server)</td>
<td>$($db.Database)</td>
<td>$($db.CurrentSku)</td>
<td>$($db.AvgDtuPercent)%</td>
<td>$($db.Connections7Days)</td>
<td>`$$($db.CurrentPrice)</td>
<td>`$$([math]::Round($db.CurrentPrice * 12, 2))</td>
<td>$delStatus</td>
</tr>
"@
}

$dropRows = ""
foreach ($db in $allResults.dropTierList) {
    $chgStatus = if ($db.TierChanged) { "<span style='color:#4ade80'>CHANGED</span>" } elseif ($dryRun) { "<span style='color:#fbbf24'>PENDING</span>" } else { "-" }
    $dropRows += @"
<tr>
<td>$($db.Subscription)</td>
<td>$($db.Server)</td>
<td>$($db.Database)</td>
<td>$($db.CurrentSku)</td>
<td>$($db.RecommendedTier)</td>
<td>$($db.AvgDtuPercent)%</td>
<td>$($db.Connections7Days)</td>
<td>`$$($db.CurrentPrice)</td>
<td>`$$($db.RecommendedPrice)</td>
<td>`$$($db.MonthlySavings)</td>
<td>$chgStatus</td>
</tr>
"@
}

$subSummaryRows = ""
foreach ($grp in $subGroups) {
    $grpCurrent = [math]::Round(($grp.Group | Measure-Object -Property CurrentPrice -Sum).Sum, 2)
    $grpRec = [math]::Round(($grp.Group | Measure-Object -Property RecommendedPrice -Sum).Sum, 2)
    $grpSave = [math]::Round($grpCurrent - $grpRec, 2)
    $grpElim = ($grp.Group | Where-Object { $_.Action -eq "DELETE" }).Count
    $grpDrop = ($grp.Group | Where-Object { $_.Action -eq "DROP" }).Count
    $subSummaryRows += @"
<tr>
<td>$($grp.Name)</td>
<td>$($grp.Count)</td>
<td>$grpElim</td>
<td>$grpDrop</td>
<td>`$$grpCurrent</td>
<td>`$$grpRec</td>
<td style='color:#4ade80;font-weight:bold'>`$$grpSave</td>
</tr>
"@
}

$wsRows = ""
foreach ($w in $allResults.sp.workspaces) {
    $wsColor = if ($w.status -match "Assign") { "#4ade80" } else { "#f87171" }
    $wsRows += "<tr><td>$($w.name)</td><td>$($w.sub)</td><td style='color:$wsColor'>$($w.status)</td></tr>`n"
}

$errorItems = ""
foreach ($e in $allResults.errors) {
    $errorItems += "<li>$e</li>`n"
}
$errorSection = ""
if ($allResults.errors.Count -gt 0) {
    $errorSection = @"
<div class="section">
<h2>Errors ($($allResults.errors.Count))</h2>
<ul style="color:#f87171">$errorItems</ul>
</div>
"@
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Master Operations Report</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',Tahoma,sans-serif;background:#0f172a;color:#e2e8f0;padding:20px}
.container{max-width:1600px;margin:0 auto}
.header{background:linear-gradient(135deg,#1e3a5f,#0f172a);border:1px solid #334155;border-radius:12px;padding:24px;margin-bottom:20px;text-align:center}
.header h1{font-size:28px;color:#60a5fa;margin-bottom:4px}
.header p{color:#94a3b8;font-size:13px}
.mode-badge{display:inline-block;padding:4px 16px;border-radius:20px;font-size:13px;font-weight:bold;margin-top:8px;$modeCss}
.summary-grid{display:grid;grid-template-columns:repeat(6,1fr);gap:10px;margin-bottom:16px}
.summary-card{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:14px;text-align:center}
.summary-card .num{font-size:30px;font-weight:bold;color:#60a5fa}
.summary-card .lbl{font-size:10px;color:#94a3b8;text-transform:uppercase;margin-top:4px}
.section{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:18px;margin-bottom:14px}
.section h2{color:#60a5fa;font-size:16px;margin-bottom:10px;border-bottom:1px solid #334155;padding-bottom:6px}
.cred-grid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px}
.cred-item{background:#0f172a;border:1px solid #334155;border-radius:6px;padding:10px}
.cred-item .label{font-size:9px;color:#94a3b8;text-transform:uppercase}
.cred-item .value{font-size:12px;color:#f1f5f9;font-family:Consolas,monospace;word-break:break-all}
.secret-box{background:#7f1d1d;border:2px solid #dc2626;border-radius:8px;padding:14px;margin-top:10px}
.secret-box .label{color:#fca5a5;font-size:12px;font-weight:bold}
.secret-box .value{color:#fef2f2;font-size:13px;font-family:Consolas,monospace;word-break:break-all}
table{width:100%;border-collapse:collapse}
th{background:#334155;color:#e2e8f0;padding:7px;text-align:left;font-size:10px;position:sticky;top:0}
td{padding:6px 7px;border-bottom:1px solid #1e293b;font-size:10px}
tr:nth-child(even){background:#1a2332}
tr:hover{background:#334155}
.tab-container{margin-bottom:14px}
.tabs{display:flex;gap:4px;margin-bottom:0}
.tab{padding:8px 18px;background:#1e293b;border:1px solid #334155;border-bottom:none;border-radius:8px 8px 0 0;cursor:pointer;color:#94a3b8;font-size:12px;font-weight:bold}
.tab.active{background:#334155;color:#60a5fa}
.tab-content{display:none;background:#1e293b;border:1px solid #334155;border-radius:0 8px 8px 8px;padding:16px}
.tab-content.active{display:block}
.footer{text-align:center;color:#64748b;font-size:10px;margin-top:16px;padding:10px}
.savings-highlight{background:linear-gradient(135deg,#064e3b,#0f172a);border:2px solid #10b981;border-radius:10px;padding:16px;margin-bottom:16px;text-align:center}
.savings-highlight .amount{font-size:36px;font-weight:bold;color:#10b981}
.savings-highlight .label{font-size:12px;color:#6ee7b7}
</style>
</head>
<body>
<div class="container">

<div class="header">
<h1>Master Operations Report</h1>
<p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | By: $($acct.user.name) | Tenant: $($acct.tenantId)</p>
<div class="mode-badge">$modeLabel</div>
</div>

<div class="savings-highlight">
<div class="label">TOTAL POTENTIAL MONTHLY SAVINGS</div>
<div class="amount">`$$totalMonthlySavings</div>
<div class="label">`$$totalAnnualSavings / YEAR</div>
</div>

<div class="summary-grid">
<div class="summary-card"><div class="num">$totalDbs</div><div class="lbl">Total Databases</div></div>
<div class="summary-card"><div class="num" style="color:#f87171">$elimCount</div><div class="lbl">Eliminate (Idle)</div></div>
<div class="summary-card"><div class="num" style="color:#fbbf24">$dropCount</div><div class="lbl">Drop Tier</div></div>
<div class="summary-card"><div class="num" style="color:#4ade80">$okCount</div><div class="lbl">OK (No Change)</div></div>
<div class="summary-card"><div class="num">`$$totalCurrentCost</div><div class="lbl">Current Monthly</div></div>
<div class="summary-card"><div class="num" style="color:#4ade80">`$$totalRecommendedCost</div><div class="lbl">Recommended Monthly</div></div>
</div>

<div class="section">
<h2>Service Principal Credentials</h2>
<div class="cred-grid">
<div class="cred-item"><div class="label">App (Client) ID</div><div class="value">$appId</div></div>
<div class="cred-item"><div class="label">SP Object ID</div><div class="value">$spObjectId</div></div>
<div class="cred-item"><div class="label">Tenant ID</div><div class="value">$($acct.tenantId)</div></div>
</div>
<div class="secret-box">
<div class="label">CLIENT SECRET (Save immediately)</div>
<div class="value">$spSecret</div>
</div>
$(if ($allResults.sp.workspaces.Count -gt 0) {
@"
<br>
<h3 style="color:#60a5fa;font-size:13px;margin-top:10px">Databricks Workspace Assignments</h3>
<table>
<thead><tr><th>Workspace</th><th>Subscription</th><th>Status</th></tr></thead>
<tbody>$wsRows</tbody>
</table>
"@
})
</div>

<div class="section">
<h2>Cost by Subscription</h2>
<table>
<thead><tr><th>Subscription</th><th>Total DBs</th><th>Eliminate</th><th>Drop Tier</th><th>Current Cost/mo</th><th>Recommended/mo</th><th>Savings/mo</th></tr></thead>
<tbody>$subSummaryRows</tbody>
</table>
</div>

<div class="tab-container">
<div class="tabs">
<div class="tab active" onclick="showTab('master')">Master ($totalDbs)</div>
<div class="tab" onclick="showTab('eliminate')">Eliminate ($elimCount)</div>
<div class="tab" onclick="showTab('droptier')">Drop Tier ($dropCount)</div>
</div>

<div id="master" class="tab-content active">
<table>
<thead><tr>
<th>Subscription</th><th>Server</th><th>Database</th><th>Edition</th><th>SKU</th><th>Size</th><th>Avg DTU%</th><th>Max DTU%</th><th>Connections</th><th>Current Cost</th><th>Recommended</th><th>Rec Cost</th><th>Action</th><th>Savings/mo</th><th>Status</th>
</tr></thead>
<tbody>$masterRows</tbody>
</table>
</div>

<div id="eliminate" class="tab-content">
<table>
<thead><tr>
<th>Subscription</th><th>Server</th><th>Database</th><th>SKU</th><th>Avg DTU%</th><th>Connections</th><th>Monthly Cost</th><th>Annual Cost</th><th>Status</th>
</tr></thead>
<tbody>$elimRows</tbody>
</table>
</div>

<div id="droptier" class="tab-content">
<table>
<thead><tr>
<th>Subscription</th><th>Server</th><th>Database</th><th>Current SKU</th><th>Recommended</th><th>Avg DTU%</th><th>Connections</th><th>Current Cost</th><th>New Cost</th><th>Savings/mo</th><th>Status</th>
</tr></thead>
<tbody>$dropRows</tbody>
</table>
</div>
</div>

$errorSection

<div class="footer">
<p>Master Operations Report | Databricks Service Account + Idle DB Elimination + DTU Tier Optimization</p>
<p>Author: $($acct.user.name) | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
</div>

</div>

<script>
function showTab(name) {
    document.querySelectorAll('.tab-content').forEach(function(el) { el.classList.remove('active'); });
    document.querySelectorAll('.tab').forEach(function(el) { el.classList.remove('active'); });
    document.getElementById(name).classList.add('active');
    event.target.classList.add('active');
}
</script>

</body>
</html>
"@

$html | Out-File -FilePath $reportHtml -Encoding UTF8
Write-Log "  HTML report: $reportHtml" "Green"

try { Start-Process $reportHtml } catch {}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  ALL OPERATIONS COMPLETE" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  SERVICE ACCOUNT:" -ForegroundColor White
Write-Host "    App ID:     $appId" -ForegroundColor Green
Write-Host "    SP ID:      $spObjectId" -ForegroundColor Green
if ($secretValue) {
    Write-Host "    Secret:     $secretValue" -ForegroundColor Red
    Write-Host "    SAVE THIS NOW!" -ForegroundColor Red
}
Write-Host ""
Write-Host "  SQL DATABASE SUMMARY:" -ForegroundColor White
Write-Host "    Total scanned:   $totalDbs" -ForegroundColor Green
Write-Host "    Eliminate (idle): $elimCount (`$$elimCostTotal/mo)" -ForegroundColor Red
Write-Host "    Drop Tier:       $dropCount (`$$dropSavingsTotal/mo savings)" -ForegroundColor Yellow
Write-Host "    OK (no change):  $okCount" -ForegroundColor Green
Write-Host ""
Write-Host "  COST IMPACT:" -ForegroundColor White
Write-Host "    Current monthly:     `$$totalCurrentCost" -ForegroundColor Red
Write-Host "    Recommended monthly: `$$totalRecommendedCost" -ForegroundColor Green
Write-Host "    Monthly savings:     `$$totalMonthlySavings" -ForegroundColor Green
Write-Host "    Annual savings:      `$$totalAnnualSavings" -ForegroundColor Green
Write-Host ""

if ($dryRun) {
    Write-Host "  THIS WAS A DRY RUN - No changes were made!" -ForegroundColor Yellow
    Write-Host "  Review the report, then set `$dryRun = `$false on line 23" -ForegroundColor Yellow
}
else {
    Write-Host "  LIVE RUN COMPLETE:" -ForegroundColor Green
    Write-Host "    Databases deleted: $($allResults.deletedDbs.Count)" -ForegroundColor Red
    Write-Host "    Tiers changed:     $($allResults.changedDbs.Count)" -ForegroundColor Yellow
    Write-Host "    Archives saved:    $archiveDir" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "  OUTPUT FILES:" -ForegroundColor White
Write-Host "    HTML Report: $reportHtml" -ForegroundColor Cyan
Write-Host "    CSV Export:  $reportCsv" -ForegroundColor Cyan
Write-Host "    Log File:    $logFile" -ForegroundColor Cyan
Write-Host "    Archives:    $archiveDir" -ForegroundColor Cyan
Write-Host ""
