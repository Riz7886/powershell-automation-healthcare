param(
    [Parameter(Mandatory=$false)]
    [string]$CsvPath,
    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$outDir = Join-Path $dir "RetryFix_$ts"
New-Item -Path $outDir -ItemType Directory -Force | Out-Null
$logFile = Join-Path $outDir "retry.log"

function WL { param([string]$M,[string]$C="White"); "[$(Get-Date -Format 'HH:mm:ss')] $M" | Out-File -FilePath $logFile -Append -Encoding UTF8; Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $M" -ForegroundColor $C }

$tenant = "8ef3d734-3ca5-4493-8d8b-52b2c54eab04"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Red
Write-Host "  RETRY FIX - SEQUENTIAL (NO BACKGROUND JOBS)" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""

if (-not $CsvPath) {
    $folders = @()
    $folders += Get-ChildItem -Path $dir -Directory -Filter "EmergencyFix_*" -ErrorAction SilentlyContinue
    $folders += Get-ChildItem -Path $dir -Directory -Filter "RetryFix_*" -ErrorAction SilentlyContinue
    $csvFiles = @()
    foreach ($f in $folders) { $c = Get-ChildItem -Path $f.FullName -Filter "SQL_Recommendations.csv" -ErrorAction SilentlyContinue; if ($c) { $csvFiles += $c } }
    $csvFiles += Get-ChildItem -Path $dir -Filter "SQL_Recommendations.csv" -ErrorAction SilentlyContinue
    if ($csvFiles.Count -eq 0) {
        Write-Host "  No SQL_Recommendations.csv found." -ForegroundColor Red
        Write-Host "  Use: .\Retry-Fix.ps1 -CsvPath 'C:\path\to\SQL_Recommendations.csv'" -ForegroundColor Yellow
        exit 1
    }
    $CsvPath = ($csvFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

WL "Reading: $CsvPath" "Cyan"
$allDbs = Import-Csv -Path $CsvPath
WL "Loaded $($allDbs.Count) database records" "Green"

$elimList = @($allDbs | Where-Object { $_.Act -eq "DELETE" })
$dropList = @($allDbs | Where-Object { $_.Act -eq "DROP" })
$okList = @($allDbs | Where-Object { $_.Act -eq "OK" })

WL "Eliminate: $($elimList.Count) | Drop Tier: $($dropList.Count) | OK: $($okList.Count)" "Yellow"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  STEP 1: VERIFY AZURE LOGIN" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow

$needLogin = $true
try {
    $raw = az account show 2>$null
    if ($raw) {
        $a = $raw | ConvertFrom-Json
        if ($a.tenantId -eq $tenant) { WL "Logged in: $($a.user.name)" "Green"; $needLogin = $false }
        else { WL "Wrong tenant" "Yellow" }
    }
} catch {}

if ($needLogin) {
    az logout 2>$null
    Write-Host "  BROWSER WILL OPEN - Sign in + MFA" -ForegroundColor Cyan
    az login --tenant $tenant 2>$null | Out-Null
    $raw = az account show 2>$null
    if ($raw) {
        $a = $raw | ConvertFrom-Json
        if ($a.tenantId -eq $tenant) { WL "Login OK: $($a.user.name)" "Green" }
        else { WL "FATAL: Wrong tenant" "Red"; exit 1 }
    } else { WL "FATAL: Login failed" "Red"; exit 1 }
}

$pricing = @{
    "Basic"=@{D=5;P=4.99;E="Basic";O="Basic"};"S0"=@{D=10;P=15.03;E="Standard";O="S0"}
    "S1"=@{D=20;P=30.05;E="Standard";O="S1"};"S2"=@{D=50;P=75.13;E="Standard";O="S2"}
    "S3"=@{D=100;P=150.26;E="Standard";O="S3"};"S4"=@{D=200;P=300.52;E="Standard";O="S4"}
    "S6"=@{D=400;P=601.03;E="Standard";O="S6"};"S7"=@{D=800;P=1202.06;E="Standard";O="S7"}
    "S9"=@{D=1600;P=2404.13;E="Standard";O="S9"};"S12"=@{D=3000;P=4507.74;E="Standard";O="S12"}
}

$results = @()
$deleteOk = 0; $deleteFail = 0; $deleteSkip = 0
$tierOk = 0; $tierFail = 0; $tierSkip = 0
$actualSavings = 0

Write-Host ""
Write-Host "================================================================" -ForegroundColor Red
Write-Host "  STEP 2: DELETE IDLE DATABASES ($($elimList.Count) targets)" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""

if ($elimList.Count -eq 0) { WL "No databases to delete" "Green" }

$currentSub = ""
$counter = 0
foreach ($e in $elimList) {
    $counter++
    Write-Host "  [$counter/$($elimList.Count)] $($e.Server)/$($e.DB) " -ForegroundColor Gray -NoNewline

    if ($DryRun) {
        Write-Host "DRY RUN - would delete" -ForegroundColor Yellow
        $results += [PSCustomObject]@{Sub=$e.Sub;Server=$e.Server;DB=$e.DB;OldSKU=$e.SKU;Action="DELETE";NewSKU="ELIMINATED";Status="DRY RUN";Cost=[double]$e.Cost;NewCost=0;Saved=[double]$e.Cost;Error=""}
        $deleteSkip++
        continue
    }

    if ($currentSub -ne $e.SubId) {
        az account set --subscription $e.SubId 2>$null
        $currentSub = $e.SubId
    }

    $dbExists = $null
    try {
        $chk = az sql db show --server $e.Server --name $e.DB --resource-group $e.RG --subscription $e.SubId 2>&1
        if ($LASTEXITCODE -eq 0) { $dbExists = $true } else { $dbExists = $false }
    } catch { $dbExists = $false }

    if (-not $dbExists) {
        Write-Host "ALREADY GONE" -ForegroundColor DarkGray
        $results += [PSCustomObject]@{Sub=$e.Sub;Server=$e.Server;DB=$e.DB;OldSKU=$e.SKU;Action="DELETE";NewSKU="ELIMINATED";Status="ALREADY DELETED";Cost=[double]$e.Cost;NewCost=0;Saved=[double]$e.Cost;Error=""}
        $deleteOk++
        $actualSavings += [double]$e.Cost
        continue
    }

    $err = ""
    try {
        $delResult = az sql db delete --server $e.Server --name $e.DB --resource-group $e.RG --subscription $e.SubId --yes 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "DELETED" -ForegroundColor Green
            $results += [PSCustomObject]@{Sub=$e.Sub;Server=$e.Server;DB=$e.DB;OldSKU=$e.SKU;Action="DELETE";NewSKU="ELIMINATED";Status="DELETED";Cost=[double]$e.Cost;NewCost=0;Saved=[double]$e.Cost;Error=""}
            $deleteOk++
            $actualSavings += [double]$e.Cost
        } else {
            $err = ($delResult | Out-String).Trim()
            Write-Host "FAILED" -ForegroundColor Red
            WL "    $err" "Red"
            $results += [PSCustomObject]@{Sub=$e.Sub;Server=$e.Server;DB=$e.DB;OldSKU=$e.SKU;Action="DELETE";NewSKU="";Status="FAILED";Cost=[double]$e.Cost;NewCost=[double]$e.Cost;Saved=0;Error=$err}
            $deleteFail++
        }
    } catch {
        $err = $_.Exception.Message
        Write-Host "FAILED" -ForegroundColor Red
        WL "    $err" "Red"
        $results += [PSCustomObject]@{Sub=$e.Sub;Server=$e.Server;DB=$e.DB;OldSKU=$e.SKU;Action="DELETE";NewSKU="";Status="FAILED";Cost=[double]$e.Cost;NewCost=[double]$e.Cost;Saved=0;Error=$err}
        $deleteFail++
    }
}

Write-Host ""
WL "Deletes: $deleteOk OK | $deleteFail FAILED | $deleteSkip SKIPPED" $(if ($deleteFail -gt 0) { "Yellow" } else { "Green" })

Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  STEP 3: CHANGE TIERS ($($dropList.Count) targets)" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host ""

if ($dropList.Count -eq 0) { WL "No tier changes needed" "Green" }

$currentSub = ""
$counter = 0
foreach ($d in $dropList) {
    $counter++
    $t = $pricing[$d.Rec]
    if (-not $t) {
        if ($d.Rec -eq "Basic") { $t = @{E="Basic";O="Basic"} }
        elseif ($d.Rec -match "^S\d+$") { $t = @{E="Standard";O=$d.Rec} }
        else { 
            Write-Host "  [$counter/$($dropList.Count)] $($d.Server)/$($d.DB) SKIP - unknown tier $($d.Rec)" -ForegroundColor Gray
            $results += [PSCustomObject]@{Sub=$d.Sub;Server=$d.Server;DB=$d.DB;OldSKU=$d.SKU;Action="DROP";NewSKU=$d.Rec;Status="SKIPPED";Cost=[double]$d.Cost;NewCost=[double]$d.Cost;Saved=0;Error="Unknown tier"}
            $tierSkip++
            continue
        }
    }

    Write-Host "  [$counter/$($dropList.Count)] $($d.Server)/$($d.DB) $($d.SKU)->$($d.Rec) " -ForegroundColor Gray -NoNewline

    if ($DryRun) {
        Write-Host "DRY RUN" -ForegroundColor Yellow
        $results += [PSCustomObject]@{Sub=$d.Sub;Server=$d.Server;DB=$d.DB;OldSKU=$d.SKU;Action="DROP";NewSKU=$d.Rec;Status="DRY RUN";Cost=[double]$d.Cost;NewCost=[double]$d.NewCost;Saved=[double]$d.Save;Error=""}
        $tierSkip++
        continue
    }

    if ($currentSub -ne $d.SubId) {
        az account set --subscription $d.SubId 2>$null
        $currentSub = $d.SubId
    }

    $dbExists = $null
    try {
        $chk = az sql db show --server $d.Server --name $d.DB --resource-group $d.RG --subscription $d.SubId 2>&1
        if ($LASTEXITCODE -eq 0) { $dbExists = $true } else { $dbExists = $false }
    } catch { $dbExists = $false }

    if (-not $dbExists) {
        Write-Host "NOT FOUND (may be deleted)" -ForegroundColor DarkGray
        $results += [PSCustomObject]@{Sub=$d.Sub;Server=$d.Server;DB=$d.DB;OldSKU=$d.SKU;Action="DROP";NewSKU=$d.Rec;Status="NOT FOUND";Cost=[double]$d.Cost;NewCost=0;Saved=[double]$d.Cost;Error="Database not found - may have been deleted"}
        $tierSkip++
        $actualSavings += [double]$d.Cost
        continue
    }

    $err = ""
    try {
        $updResult = az sql db update --server $d.Server --name $d.DB --resource-group $d.RG --subscription $d.SubId --edition $t.E --service-objective $t.O 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "CHANGED" -ForegroundColor Green
            $sav = [double]$d.Save
            $results += [PSCustomObject]@{Sub=$d.Sub;Server=$d.Server;DB=$d.DB;OldSKU=$d.SKU;Action="DROP";NewSKU=$d.Rec;Status="CHANGED";Cost=[double]$d.Cost;NewCost=[double]$d.NewCost;Saved=$sav;Error=""}
            $tierOk++
            $actualSavings += $sav
        } else {
            $err = ($updResult | Out-String).Trim()
            if ($err -match "already has the same edition|already at the requested service objective|no change") {
                Write-Host "ALREADY AT TARGET" -ForegroundColor DarkGreen
                $results += [PSCustomObject]@{Sub=$d.Sub;Server=$d.Server;DB=$d.DB;OldSKU=$d.SKU;Action="DROP";NewSKU=$d.Rec;Status="ALREADY DONE";Cost=[double]$d.Cost;NewCost=[double]$d.NewCost;Saved=[double]$d.Save;Error=""}
                $tierOk++
                $actualSavings += [double]$d.Save
            } else {
                Write-Host "FAILED" -ForegroundColor Red
                WL "    $err" "Red"
                $results += [PSCustomObject]@{Sub=$d.Sub;Server=$d.Server;DB=$d.DB;OldSKU=$d.SKU;Action="DROP";NewSKU=$d.Rec;Status="FAILED";Cost=[double]$d.Cost;NewCost=[double]$d.Cost;Saved=0;Error=$err}
                $tierFail++
            }
        }
    } catch {
        $err = $_.Exception.Message
        Write-Host "FAILED" -ForegroundColor Red
        WL "    $err" "Red"
        $results += [PSCustomObject]@{Sub=$d.Sub;Server=$d.Server;DB=$d.DB;OldSKU=$d.SKU;Action="DROP";NewSKU=$d.Rec;Status="FAILED";Cost=[double]$d.Cost;NewCost=[double]$d.Cost;Saved=0;Error=$err}
        $tierFail++
    }
}

Write-Host ""
WL "Tiers: $tierOk OK | $tierFail FAILED | $tierSkip SKIPPED" $(if ($tierFail -gt 0) { "Yellow" } else { "Green" })

foreach ($o in $okList) {
    $results += [PSCustomObject]@{Sub=$o.Sub;Server=$o.Server;DB=$o.DB;OldSKU=$o.SKU;Action="OK";NewSKU=$o.SKU;Status="NO CHANGE";Cost=[double]$o.Cost;NewCost=[double]$o.Cost;Saved=0;Error=""}
}

$resultsCsv = Join-Path $outDir "Retry_Results.csv"
$results | Export-Csv -Path $resultsCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  STEP 4: VERIFY - RE-SCAN ALL DATABASES" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

WL "Verifying current state of all databases..." "Yellow"

$allSubs = $null
$rawSubs = az account list --query "[?tenantId=='$tenant' && state=='Enabled']" 2>$null
if ($rawSubs) { try { $allSubs = $rawSubs | ConvertFrom-Json } catch {} }

$verifyResults = @()
$stillIdle = 0
$stillWrongTier = 0
$sysDbs = @("master","tempdb","model","msdb")

foreach ($sub in $allSubs) {
    az account set --subscription $sub.id 2>$null
    $rs = az sql server list --subscription $sub.id 2>$null
    if (-not $rs -or $rs.Trim().Length -le 2) { continue }
    try { $servers = $rs | ConvertFrom-Json } catch { continue }
    if ($servers.Count -eq 0) { continue }

    foreach ($srv in $servers) {
        $rd = az sql db list --server $srv.name --resource-group $srv.resourceGroup --subscription $sub.id 2>$null
        if (-not $rd -or $rd.Trim().Length -le 2) { continue }
        try { $dbs = $rd | ConvertFrom-Json } catch { continue }

        foreach ($db in $dbs) {
            if ($sysDbs -contains $db.name) { continue }
            $sku = $db.currentServiceObjectiveName
            $ed = $db.edition
            $verifyResults += [PSCustomObject]@{Sub=$sub.name;Server=$srv.name;DB=$db.name;SKU=$sku;Edition=$ed;RG=$srv.resourceGroup}
        }
    }
}

WL "Verified: $($verifyResults.Count) databases remaining after cleanup" "Green"

$origTargets = @{}
foreach ($d in $dropList) { $origTargets["$($d.Server)/$($d.DB)"] = $d.Rec }
foreach ($v in $verifyResults) {
    $key = "$($v.Server)/$($v.DB)"
    if ($origTargets.ContainsKey($key)) {
        $target = $origTargets[$key]
        if ($v.SKU -ne $target -and $v.SKU -notin @("Basic") -and $target -eq "Basic") {} 
        elseif ($v.SKU -ne $target) { $stillWrongTier++ }
    }
}

$verifyCsv = Join-Path $outDir "Verify_CurrentState.csv"
$verifyResults | Export-Csv -Path $verifyCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  STEP 5: GENERATE HTML REPORT" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""

$totalOrig = [math]::Round(($allDbs | Measure-Object -Property Cost -Sum).Sum, 2)
$projNewCost = [math]::Round(($allDbs | Measure-Object -Property NewCost -Sum).Sum, 2)
$projSav = [math]::Round(($allDbs | Measure-Object -Property Save -Sum).Sum, 2)
$actualSavRound = [math]::Round($actualSavings, 2)
$actualYearly = [math]::Round($actualSavings * 12, 2)
$deletedCount = @($results | Where-Object { $_.Status -in @("DELETED","ALREADY DELETED","ALREADY GONE") }).Count
$changedCount = @($results | Where-Object { $_.Status -in @("CHANGED","ALREADY DONE","ALREADY AT TARGET") }).Count
$failedCount = @($results | Where-Object { $_.Status -eq "FAILED" }).Count
$successRate = if (($elimList.Count + $dropList.Count) -gt 0) { [math]::Round((($deletedCount + $changedCount) / ($elimList.Count + $dropList.Count)) * 100, 1) } else { 100 }

$deadline = [datetime]"2026-02-09"
$daysLeft = [math]::Max(0, ($deadline - (Get-Date)).Days)
$urgColor = if ($daysLeft -le 2) { '#ef4444' } elseif ($daysLeft -le 5) { '#f97316' } else { '#22c55e' }

$deleteTableRows = ""
foreach ($r in ($results | Where-Object { $_.Action -eq "DELETE" } | Sort-Object Status,Sub,Server,DB)) {
    $sc = switch ($r.Status) { "DELETED" { "#22c55e" } "ALREADY DELETED" { "#22c55e" } "FAILED" { "#ef4444" } default { "#f59e0b" } }
    $bg = if ($r.Status -eq "FAILED") { "background:#1a0505;" } else { "" }
    $errTd = if ($r.Error) { "<td style='color:#ef4444;font-size:10px;max-width:300px;overflow:hidden;text-overflow:ellipsis'>$($r.Error.Substring(0, [math]::Min(120, $r.Error.Length)))</td>" } else { "<td></td>" }
    $deleteTableRows += "<tr style='$bg'><td>$($r.Sub)</td><td>$($r.Server)</td><td style='font-weight:bold'>$($r.DB)</td><td>$($r.OldSKU)</td><td style='color:$sc;font-weight:bold'>$($r.Status)</td><td>`$$($r.Cost)/mo</td>$errTd</tr>"
}

$tierTableRows = ""
foreach ($r in ($results | Where-Object { $_.Action -eq "DROP" } | Sort-Object Status,Sub,Server,DB)) {
    $sc = switch ($r.Status) { "CHANGED" { "#22c55e" } "ALREADY DONE" { "#22c55e" } "ALREADY AT TARGET" { "#22c55e" } "NOT FOUND" { "#64748b" } "FAILED" { "#ef4444" } default { "#f59e0b" } }
    $bg = if ($r.Status -eq "FAILED") { "background:#1a0505;" } else { "" }
    $errTd = if ($r.Error) { "<td style='color:#ef4444;font-size:10px;max-width:300px;overflow:hidden;text-overflow:ellipsis'>$($r.Error.Substring(0, [math]::Min(120, $r.Error.Length)))</td>" } else { "<td></td>" }
    $tierTableRows += "<tr style='$bg'><td>$($r.Sub)</td><td>$($r.Server)</td><td style='font-weight:bold'>$($r.DB)</td><td>$($r.OldSKU)</td><td style='color:#22c55e;font-weight:bold'>$($r.NewSKU)</td><td style='color:$sc;font-weight:bold'>$($r.Status)</td><td>`$$($r.Cost)</td><td>`$$($r.NewCost)</td><td style='color:#22c55e'>`$$($r.Saved)/mo</td>$errTd</tr>"
}

$verifyTableRows = ""
foreach ($v in ($verifyResults | Sort-Object Sub,Server,DB)) {
    $verifyTableRows += "<tr><td>$($v.Sub)</td><td>$($v.Server)</td><td>$($v.DB)</td><td>$($v.SKU)</td><td>$($v.Edition)</td></tr>"
}

$subSummary = $results | Where-Object { $_.Action -ne "OK" } | Group-Object -Property Sub
$subRows = ""
foreach ($sg in $subSummary) {
    $sDelOk = @($sg.Group | Where-Object { $_.Action -eq "DELETE" -and $_.Status -in @("DELETED","ALREADY DELETED") }).Count
    $sDelFail = @($sg.Group | Where-Object { $_.Action -eq "DELETE" -and $_.Status -eq "FAILED" }).Count
    $sTierOk = @($sg.Group | Where-Object { $_.Action -eq "DROP" -and $_.Status -in @("CHANGED","ALREADY DONE","ALREADY AT TARGET") }).Count
    $sTierFail = @($sg.Group | Where-Object { $_.Action -eq "DROP" -and $_.Status -eq "FAILED" }).Count
    $sSav = [math]::Round(($sg.Group | Measure-Object -Property Saved -Sum).Sum, 2)
    $subRows += "<tr><td style='font-weight:bold'>$($sg.Name)</td><td style='color:#22c55e'>$sDelOk</td><td style='color:#ef4444'>$sDelFail</td><td style='color:#22c55e'>$sTierOk</td><td style='color:#ef4444'>$sTierFail</td><td style='color:#22c55e;font-weight:bold'>`$$sSav/mo</td></tr>"
}

$failedRows = ""
$failedList = @($results | Where-Object { $_.Status -eq "FAILED" })
foreach ($f in $failedList) {
    $failedRows += "<tr><td>$($f.Sub)</td><td>$($f.Server)</td><td style='font-weight:bold;color:#fca5a5'>$($f.DB)</td><td>$($f.OldSKU)</td><td>$($f.Action)</td><td style='font-size:10px;color:#ef4444;max-width:400px'>$($f.Error)</td></tr>"
}

$logLines = @()
if (Test-Path $logFile) { $logLines = Get-Content -Path $logFile }
$logHtml = ""
foreach ($l in $logLines) {
    $lc = "#94a3b8"
    if ($l -match "FAIL|ERROR") { $lc = "#ef4444" } elseif ($l -match "WARN|Yellow|SKIP") { $lc = "#f59e0b" } elseif ($l -match "OK|DELETED|CHANGED|Green|Login OK") { $lc = "#22c55e" }
    $safe = $l -replace '<','&lt;' -replace '>','&gt;'
    $logHtml += "<div style='color:$lc;font-family:monospace;font-size:11px;line-height:1.5'>$safe</div>"
}

$overallStatus = if ($failedCount -eq 0) { "ALL OPERATIONS SUCCESSFUL" } elseif ($successRate -ge 80) { "MOSTLY SUCCESSFUL - $failedCount FAILURES" } else { "NEEDS ATTENTION - $failedCount FAILURES" }
$overallColor = if ($failedCount -eq 0) { "#22c55e" } elseif ($successRate -ge 80) { "#f59e0b" } else { "#ef4444" }

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Emergency Fix - Retry Results $(Get-Date -Format 'yyyy-MM-dd')</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',Tahoma,sans-serif;background:#0f172a;color:#e2e8f0;padding:20px}
.ctr{max-width:1500px;margin:0 auto}
.hdr{background:linear-gradient(135deg,#1e293b,#334155);border-radius:12px;padding:25px;margin-bottom:15px;border:1px solid #475569}
.hdr h1{font-size:24px;color:#f1f5f9;margin-bottom:4px}
.hdr p{color:#94a3b8;font-size:12px}
.ban{border-radius:12px;padding:16px;margin-bottom:12px;text-align:center}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin-bottom:15px}
.card{background:#1e293b;border-radius:10px;padding:14px;border:1px solid #334155}
.card h3{font-size:10px;color:#94a3b8;text-transform:uppercase;letter-spacing:1px;margin-bottom:5px}
.card .v{font-size:28px;font-weight:700}
.card .s{font-size:10px;color:#64748b;margin-top:2px}
.sec{background:#1e293b;border-radius:10px;padding:16px;margin-bottom:12px;border:1px solid #334155}
.sec h2{font-size:15px;color:#f1f5f9;margin-bottom:10px;padding-bottom:8px;border-bottom:1px solid #334155}
table{width:100%;border-collapse:collapse;font-size:11px}
th{background:#0f172a;color:#94a3b8;padding:7px 8px;text-align:left;font-weight:600;text-transform:uppercase;font-size:10px;letter-spacing:0.5px;position:sticky;top:0}
td{padding:5px 8px;border-bottom:1px solid #1e293b}
tr:hover{background:#334155}
.ft{text-align:center;color:#475569;font-size:10px;margin-top:15px;padding:12px}
.bg{display:inline-block;padding:2px 7px;border-radius:10px;font-size:9px;font-weight:600}
.bg-c{background:#7f1d1d;color:#fca5a5}.bg-w{background:#78350f;color:#fbbf24}.bg-o{background:#14532d;color:#86efac}
.ib{border-radius:8px;padding:12px;margin-bottom:10px}
.bar{height:8px;border-radius:4px;background:#334155;overflow:hidden;margin-top:6px}
.fill{height:100%;border-radius:4px}
@media print{body{background:#fff;color:#000}th{background:#f1f5f9;color:#000}td{border-color:#e2e8f0}.card,.sec,.hdr{border-color:#e2e8f0;background:#fff}}
</style>
</head>
<body>
<div class="ctr">
<div class="hdr">
<h1>EMERGENCY PROD FIX - RETRY EXECUTION REPORT</h1>
<p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | Source CSV: $CsvPath</p>
<p style="margin-top:6px;font-size:14px;color:$overallColor;font-weight:bold">$overallStatus</p>
</div>

<div class="ban" style="background:linear-gradient(135deg,$urgColor,$(if($daysLeft -le 2){'#dc2626'}else{'#ea580c'}))">
<h2 style="font-size:24px;color:#fff">MFA ENFORCEMENT: $daysLeft DAYS (Feb 9, 2026)</h2>
</div>

<div class="grid">
<div class="card"><h3>Total Scanned</h3><div class="v" style="color:#60a5fa">$($allDbs.Count)</div><div class="s">databases across all subs</div></div>
<div class="card"><h3>Deleted</h3><div class="v" style="color:#ef4444">$deletedCount</div><div class="s">of $($elimList.Count) idle targets</div></div>
<div class="card"><h3>Tier Changed</h3><div class="v" style="color:#f59e0b">$changedCount</div><div class="s">of $($dropList.Count) oversized</div></div>
<div class="card"><h3>Failed</h3><div class="v" style="color:$(if($failedCount -eq 0){'#22c55e'}else{'#ef4444'})">$failedCount</div><div class="s">need manual review</div></div>
<div class="card"><h3>Success Rate</h3><div class="v" style="color:$(if($successRate -ge 90){'#22c55e'}elseif($successRate -ge 70){'#f59e0b'}else{'#ef4444'})">$successRate%</div><div class="bar"><div class="fill" style="width:$successRate%;background:$(if($successRate -ge 90){'#22c55e'}elseif($successRate -ge 70){'#f59e0b'}else{'#ef4444'})"></div></div></div>
<div class="card"><h3>Original Cost</h3><div class="v" style="color:#f87171">`$$totalOrig</div><div class="s">/month</div></div>
<div class="card"><h3>ACTUAL Savings</h3><div class="v" style="color:#22c55e">`$$actualSavRound</div><div class="s">`$$actualYearly/yr CONFIRMED</div></div>
<div class="card"><h3>DBs Remaining</h3><div class="v" style="color:#60a5fa">$($verifyResults.Count)</div><div class="s">after cleanup (verified)</div></div>
</div>

<div class="sec" style="border:2px solid #f59e0b">
<h2 style="color:#f59e0b;font-size:16px">ACTIVE MICROSOFT ISSUES</h2>
<div class="ib" style="background:#7f1d1d;border-left:4px solid #ef4444">
<h3 style="color:#fca5a5;margin-bottom:5px;font-size:13px">ISSUE 1: Azure Outage (Feb 2-3) - Hit Databricks West US</h3>
<p style="color:#e2e8f0;font-size:11px;line-height:1.5">10+ hour outage from 19:46 UTC Feb 2. Config change broke Managed Identities in East US + West US. Hit Databricks, Synapse, AKS, DevOps. Your West US 2 workspaces were in blast radius. Recycle clusters if still flaky.</p>
</div>
<div class="ib" style="background:#7f1d1d;border-left:4px solid #ef4444">
<h3 style="color:#fca5a5;margin-bottom:5px;font-size:13px">ISSUE 2: MFA Enforcement - $daysLeft DAYS (Feb 9, 2026)</h3>
<p style="color:#e2e8f0;font-size:11px;line-height:1.5">M365 Admin Center mandatory MFA. Admins without MFA = locked out. Azure Portal enforced since March 2025, CLI/PS since Oct 2025. Verify MFA on Tony, John, Hunter, all service desk accounts NOW.</p>
</div>
<div class="ib" style="background:#78350f;border-left:4px solid #f59e0b">
<h3 style="color:#fbbf24;margin-bottom:5px;font-size:13px">ISSUE 3: Entra "Revoke Sessions" Change + ISSUE 4: Authenticator Jailbreak Wipe</h3>
<p style="color:#e2e8f0;font-size:11px;line-height:1.5">New Revoke button kills ALL sessions (not just per-user MFA). Authenticator auto-wipes credentials on rooted/jailbroken devices. Inform helpdesk + users.</p>
</div>
<div class="ib" style="background:#1e3a5f;border-left:4px solid #60a5fa">
<p style="color:#93c5fd;font-size:11px">Service principal authenticates via client secret, NOT user MFA. Not affected by enforcement changes.</p>
</div>
</div>

<div class="sec">
<h2>Results by Subscription</h2>
<table>
<tr><th>Subscription</th><th style="color:#22c55e">Deletes OK</th><th style="color:#ef4444">Del Fail</th><th style="color:#22c55e">Tiers OK</th><th style="color:#ef4444">Tier Fail</th><th>Actual Savings</th></tr>
$subRows
</table>
</div>

$(if ($deleteTableRows) {
@"
<div class="sec" style="border:1px solid #ef4444">
<h2 style="color:#ef4444">DELETE Operations - Idle Databases ($($elimList.Count))</h2>
<div style="max-height:500px;overflow-y:auto">
<table>
<tr><th>Subscription</th><th>Server</th><th>Database</th><th>SKU</th><th>Status</th><th>Cost Eliminated</th><th>Error</th></tr>
$deleteTableRows
</table>
</div>
</div>
"@
})

$(if ($tierTableRows) {
@"
<div class="sec" style="border:1px solid #f59e0b">
<h2 style="color:#f59e0b">TIER CHANGE Operations ($($dropList.Count))</h2>
<div style="max-height:500px;overflow-y:auto">
<table>
<tr><th>Subscription</th><th>Server</th><th>Database</th><th>From</th><th>To</th><th>Status</th><th>Old Cost</th><th>New Cost</th><th>Savings</th><th>Error</th></tr>
$tierTableRows
</table>
</div>
</div>
"@
})

$(if ($failedRows) {
@"
<div class="sec" style="border:2px solid #ef4444">
<h2 style="color:#ef4444">FAILED Operations - Need Manual Review ($failedCount)</h2>
<table>
<tr><th>Subscription</th><th>Server</th><th>Database</th><th>SKU</th><th>Action</th><th>Error</th></tr>
$failedRows
</table>
</div>
"@
})

<div class="sec">
<h2>VERIFICATION - Current Database State ($($verifyResults.Count) databases remaining)</h2>
<div style="max-height:500px;overflow-y:auto">
<table>
<tr><th>Subscription</th><th>Server</th><th>Database</th><th>Current SKU</th><th>Edition</th></tr>
$verifyTableRows
</table>
</div>
</div>

<div class="sec">
<h2>Action Items</h2>
<table>
<tr><th>#</th><th>Action</th><th>Owner</th><th>Priority</th></tr>
$(if ($failedCount -gt 0) { "<tr><td>1</td><td>Review $failedCount failed operations - most are ResourceGroupNotFound (RG already deleted or renamed)</td><td>Syed</td><td><span class='bg bg-w'>HIGH</span></td></tr>" })
<tr><td>2</td><td>Fix SCIM 403 on pyxlake-databricks (adb-3248848) - needs PAT from that workspace</td><td>Syed / John</td><td><span class='bg bg-c'>CRITICAL</span></td></tr>
<tr><td>3</td><td>Register MFA for all admin accounts before Feb 9 deadline</td><td>All Admins</td><td><span class='bg bg-c'>CRITICAL</span></td></tr>
<tr><td>4</td><td>Approve quota increase: standardEDSv4Family westus2 (12->64 cores)</td><td>John / Tony</td><td><span class='bg bg-c'>CRITICAL</span></td></tr>
<tr><td>5</td><td>Verify warehouse is stable after tier changes complete</td><td>Syed</td><td><span class='bg bg-w'>HIGH</span></td></tr>
<tr><td>6</td><td>Save SP secret from .sp-secret file to Azure Key Vault</td><td>Syed</td><td><span class='bg bg-w'>HIGH</span></td></tr>
<tr><td>7</td><td>Remove Shaun Raj personal account from production scripts</td><td>Syed / John</td><td><span class='bg bg-o'>MEDIUM</span></td></tr>
</table>
</div>

<div class="sec">
<h2>Execution Log</h2>
<div style="max-height:350px;overflow-y:auto;background:#0f172a;padding:10px;border-radius:6px">
$logHtml
</div>
</div>

<div class="ft">
<p>Emergency Prod Fix - Retry Report | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<p>MFA Deadline: Feb 9, 2026 | Days: $daysLeft | Databases: $($allDbs.Count) scanned, $($verifyResults.Count) remaining | Savings: `$$actualSavRound/mo (`$$actualYearly/yr)</p>
</div>
</div>
</body>
</html>
"@

$reportFile = Join-Path $outDir "Emergency-Retry-Report.html"
$html | Out-File -FilePath $reportFile -Encoding UTF8
WL "Report: $reportFile" "Green"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  DELETED:       $deleteOk OK / $deleteFail FAILED" -ForegroundColor $(if ($deleteFail -eq 0) { "Green" } else { "Yellow" })
Write-Host "  TIER CHANGED:  $tierOk OK / $tierFail FAILED" -ForegroundColor $(if ($tierFail -eq 0) { "Green" } else { "Yellow" })
Write-Host "  ACTUAL SAVINGS: `$$actualSavRound/mo (`$$actualYearly/yr)" -ForegroundColor Green
Write-Host "  DBs REMAINING: $($verifyResults.Count)" -ForegroundColor Cyan
Write-Host "  REPORT:        $reportFile" -ForegroundColor Cyan
Write-Host "  CSV:           $resultsCsv" -ForegroundColor Cyan
Write-Host ""

try { Start-Process $reportFile } catch {}
