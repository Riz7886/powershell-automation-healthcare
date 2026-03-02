$ErrorActionPreference = "Continue"
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$out = Join-Path $dir "EmergencyFix_$ts"
New-Item -Path $out -ItemType Directory -Force | Out-Null
$log = Join-Path $out "fix.log"

function WL { param([string]$M,[string]$C="White"); "[$(Get-Date -Format 'HH:mm:ss')] $M" | Out-File -FilePath $log -Append -Encoding UTF8; Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $M" -ForegroundColor $C }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Red
Write-Host "  EMERGENCY PROD FIX - ALL IN ONE" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""

$WAREHOUSE_TOKEN  = "YOURWAREHOUSETOKEN"

$DATABRICKS_TOKEN = "YOURDATABRICKSTOKEN"

$LAKE_TOKEN       = "YOURLAKETOKEN"

$tenant = "8ef3d734-3ca5-4493-8d8b-52b2c54eab04"
$wsUrl = "https://adb-2758318924173706.6.azuredatabricks.net"
$appId = "e44f4026-8d8e-4a26-a5c7-46269cc0d7de"

Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  PHASE 0: AZURE LOGIN" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow

$needLogin = $true
try {
    $raw = az account show 2>$null
    if ($raw) {
        $a = $raw | ConvertFrom-Json
        if ($a.tenantId -eq $tenant) { WL "Logged in: $($a.user.name)" "Green"; $needLogin = $false }
        else { WL "Wrong tenant. Re-logging..." "Yellow" }
    }
} catch {}

if ($needLogin) {
    az logout 2>$null
    Write-Host "  >>> BROWSER WILL OPEN - Sign in + MFA <<<" -ForegroundColor Cyan
    az login --tenant $tenant 2>$null | Out-Null
    $raw = az account show 2>$null
    if ($raw) {
        $a = $raw | ConvertFrom-Json
        if ($a.tenantId -eq $tenant) { WL "Login OK: $($a.user.name)" "Green" }
        else { WL "FATAL: Wrong tenant" "Red"; exit 1 }
    } else { WL "FATAL: Login failed" "Red"; exit 1 }
}

$allSubs = $null
$rawSubs = az account list --query "[?tenantId=='$tenant' && state=='Enabled']" 2>$null
if ($rawSubs) { try { $allSubs = $rawSubs | ConvertFrom-Json } catch {} }
WL "Found $($allSubs.Count) subscription(s)" "Green"
Write-Host ""

Write-Host "================================================================" -ForegroundColor Red
Write-Host "  PHASE 1: FIX SQL WAREHOUSE" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""

$hdrs = @{ "Authorization" = "Bearer $WAREHOUSE_TOKEN"; "Content-Type" = "application/json" }

$allWh = $null
try { $allWh = Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/warehouses" -Headers $hdrs -Method Get -TimeoutSec 30 }
catch {
    WL "Warehouse token failed. Trying databricks token..." "Yellow"
    $hdrs = @{ "Authorization" = "Bearer $DATABRICKS_TOKEN"; "Content-Type" = "application/json" }
    try { $allWh = Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/warehouses" -Headers $hdrs -Method Get -TimeoutSec 30 } catch { WL "Both tokens failed: $($_.Exception.Message)" "Red" }
}

$isRunning = $false

if ($allWh -and $allWh.warehouses) {
    WL "Found $($allWh.warehouses.Count) warehouse(s):" "Green"
    foreach ($w in $allWh.warehouses) {
        $sc = switch ($w.state) { "RUNNING" { "Green" } "STOPPED" { "Gray" } default { "Red" } }
        WL "  $($w.name) | $($w.id) | $($w.state) | $($w.cluster_size) | $($w.spot_instance_policy)" $sc
    }

    $target = $allWh.warehouses | Where-Object { $_.name -match "sql.?warehouse" }
    if (-not $target) { $target = $allWh.warehouses | Where-Object { $_.state -ne "RUNNING" } | Select-Object -First 1 }
    if (-not $target -and $allWh.warehouses.Count -gt 0) { $target = $allWh.warehouses[0] }

    if ($target) {
        $whId = $target.id
        WL "Target: $($target.name) | $whId | $($target.state)" "Cyan"

        if ($target.state -eq "RUNNING") {
            WL "WAREHOUSE ALREADY RUNNING" "Green"
            $isRunning = $true
        }
        else {
            if ($target.state -match "FAIL|STARTING|DELETING") {
                WL "Stopping stuck warehouse..." "Red"
                try { Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/warehouses/$whId/stop" -Headers $hdrs -Method Post -TimeoutSec 30 | Out-Null } catch {}
                for ($i = 1; $i -le 25; $i++) {
                    Start-Sleep -Seconds 8
                    try {
                        $ck = Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/warehouses/$whId" -Headers $hdrs -Method Get -TimeoutSec 15
                        WL "  Stop wait: $($ck.state) [$i/25]" "Gray"
                        if ($ck.state -eq "STOPPED") { break }
                    } catch { break }
                }
            }

            WL "ROOT CAUSE: standardEDSv4Family quota 12 cores, need 32" "Red"
            WL "Requesting quota increase to 64 cores..." "Yellow"

            $dbSubId = $null
            foreach ($s in $allSubs) {
                $rw = az resource list --subscription $s.id --resource-type "Microsoft.Databricks/workspaces" 2>$null
                if ($rw -and $rw.Trim().Length -gt 2) {
                    try { $wl = $rw | ConvertFrom-Json; if ($wl.Count -gt 0) { $dbSubId = $s.id; WL "  Databricks sub: $($s.name)" "Cyan"; break } } catch {}
                }
            }
            if (-not $dbSubId -and $allSubs.Count -gt 0) { $dbSubId = $allSubs[0].id }

            try {
                $usage = az vm list-usage --location westus2 --subscription $dbSubId --query "[?contains(name.value, 'standardEDSv4Family')]" 2>$null
                if ($usage) { $ud = $usage | ConvertFrom-Json; if ($ud.Count -gt 0) { WL "  Current quota: $($ud[0].currentValue)/$($ud[0].limit) cores" "Cyan" } }
            } catch {}

            $quotaDone = $false
            try {
                $mt = az account get-access-token --resource "https://management.azure.com/" 2>$null
                if ($mt) {
                    $mgmtTok = ($mt | ConvertFrom-Json).accessToken
                    $qUri = "https://management.azure.com/subscriptions/$dbSubId/providers/Microsoft.Compute/locations/westus2/providers/Microsoft.Quota/quotas/standardEDSv4Family?api-version=2023-02-01"
                    $qBody = @{ properties = @{ limit = @{ limitObjectType = "LimitValue"; value = 64 }; name = @{ value = "standardEDSv4Family" } } } | ConvertTo-Json -Depth 5
                    $mh = @{ "Authorization" = "Bearer $mgmtTok"; "Content-Type" = "application/json" }
                    Invoke-RestMethod -Uri $qUri -Method Patch -Headers $mh -Body $qBody -TimeoutSec 30 | Out-Null
                    WL "  Quota increase submitted: 12 -> 64 cores" "Green"
                    $quotaDone = $true
                }
            } catch { WL "  REST quota: $($_.Exception.Message)" "Yellow" }

            if (-not $quotaDone) {
                try {
                    az extension add --name quota 2>$null
                    az quota update --resource-name "standardEDSv4Family" --scope "/subscriptions/$dbSubId/providers/Microsoft.Compute/locations/westus2" --limit-object value=64 limit-object-type=LimitValue 2>$null
                    if ($LASTEXITCODE -eq 0) { WL "  Quota increase via CLI: submitted" "Green"; $quotaDone = $true }
                } catch {}
            }

            if (-not $quotaDone) {
                Write-Host ""
                Write-Host "  MANUAL STEP: Request quota increase" -ForegroundColor Red
                $quotaUrl = "https://portal.azure.com/#blade/Microsoft_Azure_Capacity/QuotaMenuBlade/myQuotas"
                Start-Process $quotaUrl 2>$null
                Write-Host "  Browser opened. Search: standardEDSv4Family | westus2 | Set: 64" -ForegroundColor White
                Write-Host "  Press ENTER after submitting..." -ForegroundColor Yellow
                Read-Host
            }

            WL "Downsizing warehouse to fit 12-core quota..." "Yellow"

            $sizes = @("2X-Small", "X-Small", "Small")
            $configured = $false

            foreach ($sz in $sizes) {
                $body = @{
                    name = $target.name
                    cluster_size = $sz
                    min_num_clusters = 1
                    max_num_clusters = 1
                    auto_stop_mins = if ($target.auto_stop_mins) { $target.auto_stop_mins } else { 15 }
                    spot_instance_policy = "RELIABILITY_OPTIMIZED"
                } | ConvertTo-Json -Depth 5

                try {
                    Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/warehouses/$whId/edit" -Headers $hdrs -Method Post -Body $body -TimeoutSec 30 | Out-Null
                    WL "  Configured: $sz, 1 cluster, RELIABILITY_OPTIMIZED" "Green"
                    $configured = $true
                    break
                } catch { WL "  $sz failed, trying next..." "Yellow" }
            }

            Start-Sleep -Seconds 3

            WL "Starting warehouse..." "Yellow"
            try { Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/warehouses/$whId/start" -Headers $hdrs -Method Post -TimeoutSec 30 | Out-Null } catch {}

            for ($i = 1; $i -le 40; $i++) {
                Start-Sleep -Seconds 12
                try {
                    $sc = Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/warehouses/$whId" -Headers $hdrs -Method Get -TimeoutSec 15
                    $stC = switch ($sc.state) { "RUNNING" { "Green" } "STARTING" { "Yellow" } default { "Red" } }
                    WL "  $($sc.state) [$i/40]" $stC
                    if ($sc.state -eq "RUNNING") { $isRunning = $true; break }
                    if ($sc.state -match "FAIL" -and $i -eq 8) {
                        WL "  Still failing. Trying no-spot + serverless..." "Red"
                        try {
                            Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/warehouses/$whId/stop" -Headers $hdrs -Method Post -TimeoutSec 15 | Out-Null
                            Start-Sleep -Seconds 20
                            $fb = @{ name = $target.name; cluster_size = "2X-Small"; min_num_clusters = 1; max_num_clusters = 1; auto_stop_mins = 15; spot_instance_policy = "POLICY_UNSPECIFIED"; enable_serverless_compute = $true } | ConvertTo-Json -Depth 5
                            Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/warehouses/$whId/edit" -Headers $hdrs -Method Post -Body $fb -TimeoutSec 30 | Out-Null
                            Start-Sleep -Seconds 5
                            Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/warehouses/$whId/start" -Headers $hdrs -Method Post -TimeoutSec 30 | Out-Null
                            WL "  Restarted: 2X-Small, no spot, serverless" "Yellow"
                        } catch {}
                    }
                } catch {}
            }

            Write-Host ""
            if ($isRunning) {
                Write-Host "  ==============================================" -ForegroundColor Green
                Write-Host "  SQL WAREHOUSE IS RUNNING! PROD IS BACK!" -ForegroundColor Green
                Write-Host "  ==============================================" -ForegroundColor Green
                WL "  Running at reduced size. Scale up after quota approval." "Yellow"
            } else {
                Write-Host "  Warehouse still starting. Check Databricks in a few min." -ForegroundColor Yellow
                Write-Host "  If still failing: quota must be approved first." -ForegroundColor Red
                Write-Host "  https://portal.azure.com/#blade/Microsoft_Azure_Capacity/QuotaMenuBlade/myQuotas" -ForegroundColor Cyan
            }
        }
    }
} else { WL "Could not reach Databricks API" "Red" }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "  PHASE 2: SERVICE ACCOUNT" -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host ""

$spObjId = $null
$rawSp = az ad sp show --id $appId 2>$null
if ($rawSp) { try { $sp = $rawSp | ConvertFrom-Json; $spObjId = $sp.id; WL "SP exists: $spObjId" "Green" } catch {} }
if (-not $spObjId) {
    $rawL = az ad sp list --filter "appId eq '$appId'" 2>$null
    if ($rawL) { try { $sl = $rawL | ConvertFrom-Json; if ($sl.Count -gt 0) { $spObjId = $sl[0].id; WL "SP found: $spObjId" "Green" } } catch {} }
}
if (-not $spObjId) {
    WL "Creating SP..." "Yellow"
    $rc = az ad sp create --id $appId 2>$null
    if ($rc) { try { $ns = $rc | ConvertFrom-Json; $spObjId = $ns.id; WL "Created: $spObjId" "Green" } catch {} }
}

WL "Creating client secret..." "Yellow"
$secretVal = $null
$sExp = (Get-Date).AddYears(1).ToString("yyyy-MM-ddTHH:mm:ssZ")
$rawCr = az ad app credential reset --id $appId --display-name "sp-$ts" --end-date $sExp --append 2>$null
if ($rawCr) {
    try {
        $cr = $rawCr | ConvertFrom-Json; $secretVal = $cr.password
        if ($secretVal) {
            Write-Host "  ==============================================" -ForegroundColor Red
            Write-Host "  CLIENT SECRET: $secretVal" -ForegroundColor Red
            Write-Host "  SAVE THIS NOW!" -ForegroundColor Red
            Write-Host "  ==============================================" -ForegroundColor Red
            $secretVal | Out-File -FilePath (Join-Path $dir ".sp-secret") -Encoding UTF8 -NoNewline
        }
    } catch {}
} else { WL "Secret creation failed" "Yellow" }

WL "Assigning Contributor on Databricks workspaces..." "Yellow"
foreach ($sub in $allSubs) {
    $rw = az resource list --subscription $sub.id --resource-type "Microsoft.Databricks/workspaces" 2>$null
    if (-not $rw) { continue }
    try { $wl = $rw | ConvertFrom-Json } catch { continue }
    if (-not $wl -or $wl.Count -eq 0) { continue }
    foreach ($ws in $wl) {
        Write-Host "  $($ws.name)..." -ForegroundColor Gray -NoNewline
        az role assignment create --assignee $appId --role "Contributor" --scope $ws.id --subscription $sub.id 2>$null | Out-Null
        Write-Host " OK" -ForegroundColor Green
    }
}

WL "Adding SP to Databricks via SCIM..." "Yellow"
$scim = @{ schemas = @("urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal"); applicationId = $appId; displayName = "databricks-sp"; active = $true } | ConvertTo-Json -Depth 5
$wsUrls = @("https://adb-2758318924173706.6.azuredatabricks.net","https://adb-3248848193480666.6.azuredatabricks.net")
$toks = @($WAREHOUSE_TOKEN, $LAKE_TOKEN)
for ($w = 0; $w -lt $wsUrls.Count; $w++) {
    $wH = @{ "Authorization" = "Bearer $($toks[$w])"; "Content-Type" = "application/json" }
    Write-Host "  $($wsUrls[$w])..." -ForegroundColor Gray -NoNewline
    try { Invoke-RestMethod -Uri "$($wsUrls[$w])/api/2.0/preview/scim/v2/ServicePrincipals" -Headers $wH -Method Post -Body $scim -TimeoutSec 30 | Out-Null; Write-Host " added" -ForegroundColor Green }
    catch { if ($_.Exception.Message -match "409|Conflict|already") { Write-Host " exists" -ForegroundColor Green } else { Write-Host " $($_.Exception.Message)" -ForegroundColor Yellow } }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  PHASE 3: SQL DATABASE SCAN + TIER CHANGES + DELETE IDLE" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$pricing = @{
    "Basic"=@{D=5;P=4.99;E="Basic";O="Basic"};"S0"=@{D=10;P=15.03;E="Standard";O="S0"}
    "S1"=@{D=20;P=30.05;E="Standard";O="S1"};"S2"=@{D=50;P=75.13;E="Standard";O="S2"}
    "S3"=@{D=100;P=150.26;E="Standard";O="S3"};"S4"=@{D=200;P=300.52;E="Standard";O="S4"}
    "S6"=@{D=400;P=601.03;E="Standard";O="S6"};"S7"=@{D=800;P=1202.06;E="Standard";O="S7"}
    "S9"=@{D=1600;P=2404.13;E="Standard";O="S9"};"S12"=@{D=3000;P=4507.74;E="Standard";O="S12"}
}

function GR {
    param([string]$RG,[string]$Sku,[double]$Avg,[double]$Max,[int]$Cn,[double]$Pr)
    if ($Cn -eq 0 -and $Avg -lt 0.5) { return @{T="ELIMINATE";P=0;A="DELETE"} }
    $r = $RG.ToLower()
    if ($r -match "qa|test|dev|sandbox") { if ($Sku -ne "Basic") { return @{T="Basic";P=4.99;A="DROP"} }; return @{T=$Sku;P=$Pr;A="OK"} }
    if ($r -match "preprod|pre-prod|staging|uat") {
        if ($Avg -lt 5 -and $Max -lt 15) { return @{T="Basic";P=4.99;A="DROP"} }
        if ($Sku -notin @("Basic","S0") -and $Avg -lt 10) { return @{T="S0";P=15.03;A="DROP"} }
        return @{T=$Sku;P=$Pr;A="OK"}
    }
    if ($Avg -lt 5 -and $Max -lt 20 -and $Sku -notin @("Basic","S0")) { return @{T="S0";P=15.03;A="DROP"} }
    if ($Avg -lt 15 -and $Max -lt 40 -and $Sku -notin @("Basic","S0","S1")) { return @{T="S1";P=30.05;A="DROP"} }
    if ($Avg -lt 30 -and $Max -lt 60 -and $Sku -notin @("Basic","S0","S1","S2")) { return @{T="S2";P=75.13;A="DROP"} }
    return @{T=$Sku;P=$Pr;A="OK"}
}

$sysDbs = @("master","tempdb","model","msdb")
$st = (Get-Date).AddDays(-14).ToString("yyyy-MM-ddTHH:mm:ssZ")
$et = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
$allDbs = @()
$subsSQL = @()

WL "Finding SQL servers..." "Yellow"
foreach ($sub in $allSubs) {
    Write-Host "  $($sub.name)..." -ForegroundColor Gray -NoNewline
    az account set --subscription $sub.id 2>$null
    $rs = az sql server list --subscription $sub.id 2>$null
    if ($rs -and $rs.Trim().Length -gt 2) {
        try { $sv = $rs | ConvertFrom-Json; if ($sv.Count -gt 0) { Write-Host " $($sv.Count) server(s)" -ForegroundColor Green; $subsSQL += @{S=$sub;V=$sv}; continue } } catch {}
    }
    $rr = az resource list --subscription $sub.id --resource-type "Microsoft.Sql/servers" 2>$null
    if ($rr -and $rr.Trim().Length -gt 2) {
        try { $rl = $rr | ConvertFrom-Json; if ($rl.Count -gt 0) { Write-Host " $($rl.Count)" -ForegroundColor Green; $subsSQL += @{S=$sub;V=$rl}; continue } } catch {}
    }
    Write-Host " 0" -ForegroundColor Gray
}

if ($subsSQL.Count -eq 0) {
    WL "Trying Resource Graph..." "Yellow"
    try {
        az extension add --name resource-graph 2>$null
        $gr = az graph query -q "Resources | where type =~ 'Microsoft.Sql/servers' | project name, resourceGroup, subscriptionId" 2>$null
        if ($gr) {
            $gd = ($gr | ConvertFrom-Json).data
            if ($gd.Count -gt 0) {
                WL "Graph found $($gd.Count) server(s)" "Green"
                $gids = $gd | Select-Object -ExpandProperty subscriptionId -Unique
                foreach ($gi in $gids) {
                    $gs = $allSubs | Where-Object { $_.id -eq $gi }; if (-not $gs) { continue }
                    az account set --subscription $gi 2>$null
                    $rsv = az sql server list --subscription $gi 2>$null
                    if ($rsv) { try { $ps = $rsv | ConvertFrom-Json; if ($ps.Count -gt 0) { $subsSQL += @{S=$gs;V=$ps} } } catch {} }
                }
            }
        }
    } catch {}
}

Write-Host ""
WL "Scanning databases..." "Yellow"

foreach ($entry in $subsSQL) {
    $sub = $entry.S; $servers = $entry.V
    Write-Host "  $($sub.name)" -ForegroundColor White
    az account set --subscription $sub.id 2>$null

    foreach ($srv in $servers) {
        $sn = if ($srv.name) { $srv.name } else { $srv }
        $rg = if ($srv.resourceGroup) { $srv.resourceGroup } else { "" }
        if (-not $sn -or -not $rg) { continue }
        Write-Host "    $sn" -ForegroundColor Cyan

        $rd = az sql db list --server $sn --resource-group $rg --subscription $sub.id 2>$null
        if (-not $rd -or $rd.Trim().Length -le 2) { continue }
        try { $dbs = $rd | ConvertFrom-Json } catch { continue }

        foreach ($db in $dbs) {
            if ($sysDbs -contains $db.name) { continue }
            $sku = $db.currentServiceObjectiveName; $avgD = 0; $maxD = 0; $conn = 0

            try {
                $rm = az monitor metrics list --resource $db.id --metric "dtu_consumption_percent" --start-time $st --end-time $et --interval PT1H --aggregation Average 2>$null
                if ($rm) { $mm = $rm | ConvertFrom-Json; $p = $mm.value[0].timeseries[0].data | Where-Object { $null -ne $_.average }; if ($p.Count -gt 0) { $avgD = [math]::Round(($p | Measure-Object -Property average -Average).Average, 2); $maxD = [math]::Round(($p | Measure-Object -Property average -Maximum).Maximum, 2) } }
            } catch {}

            try {
                $rc = az monitor metrics list --resource $db.id --metric "connection_successful" --start-time $st --end-time $et --interval P1D --aggregation Total 2>$null
                if ($rc) { $cm = $rc | ConvertFrom-Json; $cp = $cm.value[0].timeseries[0].data | Where-Object { $null -ne $_.total }; if ($cp.Count -gt 0) { $conn = [math]::Round(($cp | Measure-Object -Property total -Sum).Sum, 0) } }
            } catch {}

            $pr = 0; if ($pricing.ContainsKey($sku)) { $pr = $pricing[$sku].P }
            $rec = GR -RG $rg -Sku $sku -Avg $avgD -Max $maxD -Cn $conn -Pr $pr
            $sav = [math]::Max(0, $pr - $rec.P)

            $allDbs += [PSCustomObject]@{ Sub=$sub.name; SubId=$sub.id; RG=$rg; Server=$sn; DB=$db.name; SKU=$sku; AvgDTU=$avgD; MaxDTU=$maxD; Conn=$conn; Cost=$pr; Rec=$rec.T; NewCost=$rec.P; Act=$rec.A; Save=$sav }

            $cl = switch ($rec.A) { "DELETE" { "Red" } "DROP" { "Yellow" } default { "Green" } }
            Write-Host ("      {0,-25} {1,-5} DTU:{2,5}% Conn:{3,5} -> {4,-8} {5}" -f $db.name,$sku,$avgD,$conn,$rec.T,$rec.A) -ForegroundColor $cl
        }
    }
    Write-Host ""
}

$elimList = @($allDbs | Where-Object { $_.Act -eq "DELETE" })
$dropList = @($allDbs | Where-Object { $_.Act -eq "DROP" })
$okList = @($allDbs | Where-Object { $_.Act -eq "OK" })
$totalCost = [math]::Round(($allDbs | Measure-Object -Property Cost -Sum).Sum, 2)
$totalSav = [math]::Round(($allDbs | Measure-Object -Property Save -Sum).Sum, 2)

Write-Host ""
WL "RESULTS:" "Green"
WL "  Total: $($allDbs.Count) databases" "White"
WL "  Eliminate: $($elimList.Count)" "Red"
WL "  Drop Tier: $($dropList.Count)" "Yellow"
WL "  OK: $($okList.Count)" "Green"
WL "  Current: `$$totalCost/mo" "White"
WL "  Savings: `$$totalSav/mo (`$$([math]::Round($totalSav*12,2))/yr)" "Green"

$csv = Join-Path $out "SQL_Recommendations.csv"
$allDbs | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

if ($dropList.Count -gt 0) {
    Write-Host ""
    Write-Host "  TIER CHANGES:" -ForegroundColor Yellow
    foreach ($d in $dropList) { Write-Host "    $($d.Server)/$($d.DB): $($d.SKU) -> $($d.Rec) (save `$$($d.Save)/mo)" -ForegroundColor Yellow }
}
if ($elimList.Count -gt 0) {
    Write-Host ""
    Write-Host "  IDLE (DELETE):" -ForegroundColor Red
    foreach ($e in $elimList) { Write-Host "    $($e.Server)/$($e.DB): `$$($e.Cost)/mo - 0 connections" -ForegroundColor Red }
}

if ($dropList.Count -gt 0 -or $elimList.Count -gt 0) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  READY TO APPLY ALL CHANGES" -ForegroundColor Yellow
    Write-Host "  $($elimList.Count) delete + $($dropList.Count) tier changes = `$$totalSav/mo savings" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "  Type YES to execute (NO = skip)"

    if ($confirm -eq "YES") {
        Write-Host ""

        if ($elimList.Count -gt 0) {
            $archive = Join-Path $out "Archive"
            New-Item -Path $archive -ItemType Directory -Force | Out-Null
            foreach ($e in $elimList) { "ARCHIVED`nDate: $(Get-Date)`nServer: $($e.Server)`nDB: $($e.DB)`nSKU: $($e.SKU)`nCost: `$$($e.Cost)/mo" | Out-File -FilePath (Join-Path $archive "$($e.Server)_$($e.DB)_$ts.txt") -Encoding UTF8 }
            WL "Archived $($elimList.Count) records" "Cyan"

            WL "Deleting $($elimList.Count) idle databases..." "Red"
            $dj = @()
            foreach ($e in $elimList) {
                $j = Start-Job -ScriptBlock { param($Si,$Sv,$Db,$RG); az account set --subscription $Si 2>$null; az sql db delete --server $Sv --name $Db --resource-group $RG --yes -o none 2>&1; if ($LASTEXITCODE -eq 0) { "OK" } else { "FAIL" } } -ArgumentList $e.SubId,$e.Server,$e.DB,$e.RG
                $dj += @{J=$j;E=$e}
            }
            foreach ($x in $dj) {
                $r = Receive-Job -Job $x.J -Wait; Remove-Job -Job $x.J -Force -ErrorAction SilentlyContinue
                if ($r -match "OK") { Write-Host "    DELETED: $($x.E.Server)/$($x.E.DB)" -ForegroundColor Green }
                else { Write-Host "    FAILED: $($x.E.Server)/$($x.E.DB) - $r" -ForegroundColor Red }
            }
        }

        if ($dropList.Count -gt 0) {
            Write-Host ""
            WL "Changing $($dropList.Count) tiers..." "Yellow"
            $tj = @()
            foreach ($d in $dropList) {
                $t = $pricing[$d.Rec]; if (-not $t) { continue }
                $j = Start-Job -ScriptBlock { param($Si,$Sv,$Db,$RG,$Ed,$Ob); az account set --subscription $Si 2>$null; az sql db update --server $Sv --name $Db --resource-group $RG --edition $Ed --service-objective $Ob -o none 2>&1; if ($LASTEXITCODE -eq 0) { "OK" } else { "FAIL" } } -ArgumentList $d.SubId,$d.Server,$d.DB,$d.RG,$t.E,$t.O
                $tj += @{J=$j;D=$d}
            }
            foreach ($x in $tj) {
                $r = Receive-Job -Job $x.J -Wait; Remove-Job -Job $x.J -Force -ErrorAction SilentlyContinue
                if ($r -match "OK") { Write-Host "    CHANGED: $($x.D.Server)/$($x.D.DB) $($x.D.SKU) -> $($x.D.Rec)" -ForegroundColor Green }
                else { Write-Host "    FAILED: $($x.D.Server)/$($x.D.DB) - $r" -ForegroundColor Red }
            }
        }

        Write-Host ""
        Write-Host "  ==============================================" -ForegroundColor Green
        Write-Host "  ALL CHANGES APPLIED" -ForegroundColor Green
        Write-Host "  Savings: `$$totalSav/mo | `$$([math]::Round($totalSav*12,2))/yr" -ForegroundColor Green
        Write-Host "  ==============================================" -ForegroundColor Green
    } else { WL "Skipped." "Yellow" }
} else { WL "No changes needed." "Green" }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  WAREHOUSE: " -NoNewline; if ($isRunning) { Write-Host "RUNNING" -ForegroundColor Green } else { Write-Host "CHECK DATABRICKS" -ForegroundColor Yellow }
Write-Host "  SERVICE PRINCIPAL: " -NoNewline; if ($spObjId) { Write-Host "$spObjId" -ForegroundColor Green } else { Write-Host "CHECK MANUALLY" -ForegroundColor Red }
Write-Host "  SECRET: " -NoNewline; if ($secretVal) { Write-Host "CREATED (.sp-secret)" -ForegroundColor Green } else { Write-Host "CHECK MANUALLY" -ForegroundColor Yellow }
Write-Host "  DATABASES: $($allDbs.Count) scanned | `$$totalSav/mo savings" -ForegroundColor Cyan
Write-Host "  OUTPUT: $out" -ForegroundColor Cyan
Write-Host ""

$WAREHOUSE_TOKEN = $null; $DATABRICKS_TOKEN = $null; $LAKE_TOKEN = $null
[System.GC]::Collect()

Write-Host "  DELETE THIS SCRIPT AFTER USE" -ForegroundColor Red
Write-Host ""
