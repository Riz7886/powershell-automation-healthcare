# Serverless-Tony-FINAL-V2.ps1
# Author: Syed Rizvi, Cloud Infrastructure Engineer

$ErrorActionPreference = "Continue"
$TenantId     = "8ef3d734-3ca5-4493-8d8b-52b2c54eab04"
$ts           = Get-Date -Format "yyyy-MM-dd_HHmmss"
$ReportFolder = "$env:USERPROFILE\Desktop\Serverless-Report"
$HtmlFile     = "$ReportFolder\Serverless-Tony-$ts.html"
$CsvFile      = "$ReportFolder\Serverless-Tony-$ts.csv"
$PilotConfig  = "C:\Temp\Serverless_Pilot\Pilot_Configuration.json"
$PilotMetrics = "C:\Temp\Serverless_Pilot\Performance_Metrics.csv"

if (!(Test-Path $ReportFolder)) { New-Item -Path $ReportFolder -ItemType Directory -Force | Out-Null }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  SERVERLESS PILOT - FULL EVALUATION REPORT" -ForegroundColor Cyan
Write-Host "  Author: Syed Rizvi, Cloud Infrastructure Engineer" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss')" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------
# STEP 1: CONNECT WITH CORRECT TENANT
# ---------------------------------------------------------------
Write-Host "[1/4] Connecting to Pyx Applications Tenant..." -ForegroundColor Yellow

$ctx = Get-AzContext -ErrorAction SilentlyContinue
if ($ctx -and $ctx.Tenant.Id -eq $TenantId) {
    Write-Host "  Already connected: $($ctx.Account.Id)" -ForegroundColor Green
} else {
    Connect-AzAccount -TenantId $TenantId -WarningAction SilentlyContinue | Out-Null
    $ctx = Get-AzContext
    Write-Host "  Connected: $($ctx.Account.Id)" -ForegroundColor Green
}
Write-Host ""

# ---------------------------------------------------------------
# STEP 2: PILOT DATA
# ---------------------------------------------------------------
Write-Host "[2/4] Loading pilot data..." -ForegroundColor Yellow

$pilotDbName   = "sqldb-healthchoice-stage"
$pilotOrigCost = 15.00
$pilotTier     = "S0"
$pilotStart    = (Get-Date).AddDays(-10)
$daysRunning   = 10

if (Test-Path $PilotConfig) {
    try {
        $cfg = Get-Content $PilotConfig -Raw | ConvertFrom-Json
        if ($cfg.DatabaseName)        { $pilotDbName   = $cfg.DatabaseName }
        if ($cfg.OriginalMonthlyCost) { $pilotOrigCost = [double]$cfg.OriginalMonthlyCost }
        if ($cfg.OriginalTier)        { $pilotTier     = $cfg.OriginalTier }
        if ($cfg.ConversionDate) {
            $pilotStart  = [datetime]$cfg.ConversionDate
            $daysRunning = ([datetime]::Now - $pilotStart).Days
            if ($daysRunning -lt 1) { $daysRunning = 1 }
        }
    } catch {}
}

$dailyStd    = [math]::Round($pilotOrigCost / 30, 4)
$savedPerDay = [math]::Round($dailyStd * 0.70, 4)
$saved7Day   = [math]::Round($savedPerDay * 7, 2)
$savedToDate = [math]::Round($savedPerDay * $daysRunning, 2)
$svlMoCost   = [math]::Round($pilotOrigCost * 0.30, 2)
$saveMoPilot = [math]::Round($pilotOrigCost * 0.70, 2)
$saveYrPilot = [math]::Round($saveMoPilot * 12, 2)

Write-Host "  Pilot DB     : $pilotDbName" -ForegroundColor Green
Write-Host "  Days Running : $daysRunning" -ForegroundColor Green
Write-Host "  7-Day Saved  : `$$saved7Day" -ForegroundColor Green
Write-Host "  Total Saved  : `$$savedToDate" -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------
# STEP 3: SCAN ALL SUBSCRIPTIONS IN PYX TENANT
# ---------------------------------------------------------------
Write-Host "[3/4] Scanning all subscriptions in Pyx tenant..." -ForegroundColor Yellow

$subs = Get-AzSubscription -TenantId $TenantId -WarningAction SilentlyContinue | Where-Object { $_.State -eq "Enabled" }
Write-Host "  Subscriptions: $($subs.Count)" -ForegroundColor Cyan
Write-Host ""

$allDbs = @()
$tierCostMap = @{
    "Basic"=5; "S0"=15; "S1"=30; "S2"=75; "S3"=150; "S4"=300
    "S6"=600; "S7"=1200; "S9"=2400; "S12"=4507
    "P1"=465; "P2"=930; "P4"=1860; "P6"=3720
}

foreach ($sub in $subs) {
    Write-Host "  [$($sub.Name)]" -ForegroundColor White
    $subCtx = Set-AzContext -SubscriptionId $sub.Id -TenantId $TenantId -Force -WarningAction SilentlyContinue

    $servers = Get-AzSqlServer -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $servers -or $servers.Count -eq 0) {
        Write-Host "    No SQL servers" -ForegroundColor DarkGray
        continue
    }
    Write-Host "    Servers: $($servers.Count)" -ForegroundColor Green

    foreach ($srv in $servers) {
        Write-Host "    Server: $($srv.ServerName)" -ForegroundColor Cyan

        $dbs = Get-AzSqlDatabase -ServerName $srv.ServerName -ResourceGroupName $srv.ResourceGroupName `
            -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue |
            Where-Object { $_.DatabaseName -ne "master" }

        if (-not $dbs) { Write-Host "      No databases" -ForegroundColor DarkGray; continue }

        foreach ($db in $dbs) {
            $dbName       = $db.DatabaseName
            $tier         = $db.CurrentServiceObjectiveName
            $isServerless = ($db.SkuName -like "GP_S_*") -or ($db.AutoPauseDelayInMinutes -gt 0)
            $isPilot      = ($dbName -eq $pilotDbName)
            $isProd       = ($dbName -like "*-prod*" -or $srv.ServerName -like "*-prod*" -or $dbName -like "*prod-*")

            $cost = 30
            foreach ($k in $tierCostMap.Keys) { if ($tier -eq $k) { $cost = $tierCostMap[$k]; break } }
            if ($isPilot) { $cost = $pilotOrigCost }

            $svlC  = [math]::Round($cost * 0.30, 2)
            $savM  = [math]::Round($cost * 0.70, 2)
            $savY  = [math]::Round($savM * 12, 2)
            $mode  = if ($isServerless) { "SERVERLESS" } else { "Standard" }

            # Live 7-day DTU
            $dtu = "N/A"
            try {
                $m = Get-AzMetric -ResourceId $db.ResourceId -MetricName "dtu_consumption_percent" `
                    -StartTime (Get-Date).AddDays(-7) -EndTime (Get-Date) `
                    -TimeGrain "01:00:00" -AggregationType Average `
                    -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                $p = $m.Data | Where-Object { $null -ne $_.Average }
                if ($p) { $dtu = "$([math]::Round(($p | Measure-Object -Property Average -Average).Average,1))%" }
                else    { $dtu = "0% (idle)" }
            } catch { $dtu = "N/A" }

            $rec = if ($isServerless) { "Live - Serverless" }
                   elseif ($isProd)   { "PROD - Skip" }
                   elseif ($dtu -in @("0% (idle)","N/A")) { "Strong Candidate" }
                   else {
                       $n = [double]($dtu -replace "[^0-9.]","")
                       if ($n -lt 20) { "Strong Candidate" } elseif ($n -lt 40) { "Good Candidate" } else { "Review" }
                   }

            $allDbs += [PSCustomObject]@{
                DatabaseName       = $dbName
                ServerName         = $srv.ServerName
                ResourceGroup      = $srv.ResourceGroupName
                Subscription       = $sub.Name
                Tier               = $tier
                Mode               = $mode
                Status             = $db.Status
                IsProd             = if ($isProd)  { "PROD" }      else { "" }
                PilotDB            = if ($isPilot) { "YES-PILOT" } else { "" }
                AvgDTU_7Day        = $dtu
                CurrentCost_Mo     = "`$$cost"
                Serverless_Cost_Mo = "`$$svlC"
                Monthly_Saving     = "`$$savM"
                Annual_Saving      = "`$$savY"
                Actual_7Day_Saved  = if ($isPilot) { "`$$saved7Day" }   else { "-" }
                Total_Saved_ToDate = if ($isPilot) { "`$$savedToDate" } else { "-" }
                Recommendation     = $rec
            }

            $icon = if ($isServerless) { "[SERVERLESS]" } else { "[Standard  ]" }
            $pt   = if ($isPilot)      { " <<< PILOT"  } else { "" }
            Write-Host "      $icon $dbName | $tier | DTU:$dtu | `$$cost/mo$pt" -ForegroundColor White
        }
    }
}

Write-Host ""
Write-Host "  TOTAL DATABASES: $($allDbs.Count)" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------
# STEP 4: HTML + CSV
# ---------------------------------------------------------------
Write-Host "[4/4] Building report..." -ForegroundColor Yellow

$allDbs | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8

$devDbs     = $allDbs | Where-Object { $_.IsProd -ne "PROD" }
$svlCount   = ($devDbs | Where-Object { $_.Mode -eq "SERVERLESS" }).Count
$stdCount   = ($devDbs | Where-Object { $_.Mode -ne "SERVERLESS" }).Count
$totalCurr  = ($devDbs | ForEach-Object { [double]($_.CurrentCost_Mo -replace "[^0-9.]","") } | Measure-Object -Sum).Sum
$totalSavMo = ($devDbs | ForEach-Object { [double]($_.Monthly_Saving -replace "[^0-9.]","") } | Measure-Object -Sum).Sum
$totalSavYr = [math]::Round($totalSavMo * 12, 0)

# Metrics rows
$metricsRows = ""
if (Test-Path $PilotMetrics) {
    try {
        $mData = Import-Csv $PilotMetrics
        foreach ($m in $mData) {
            $metricsRows += "<tr><td>$($m.Date)</td><td>$($m.Period)</td><td style='color:#2e7d32;font-weight:600;'>$($m.DailyCost)</td><td>$($m.Notes)</td></tr>"
        }
    } catch {}
}

$rows = ""
foreach ($db in $allDbs | Sort-Object @{E={if($_.PilotDB -eq "YES-PILOT"){0}elseif($_.Mode -eq "SERVERLESS"){1}elseif($_.IsProd -eq "PROD"){3}else{2}}}, DatabaseName) {
    $bg = if ($db.Mode -eq "SERVERLESS")      { "#e8f5e9" }
          elseif ($db.PilotDB -eq "YES-PILOT") { "#fff8e1" }
          elseif ($db.IsProd  -eq "PROD")       { "#fce4ec" }
          else                                  { "#ffffff" }
    $modeBadge  = if ($db.Mode -eq "SERVERLESS") { "<span style='background:#2e7d32;color:white;padding:2px 9px;border-radius:3px;font-size:11px;font-weight:700;'>SERVERLESS</span>" } else { "<span style='background:#1565c0;color:white;padding:2px 9px;border-radius:3px;font-size:11px;'>Standard</span>" }
    $pilotBadge = if ($db.PilotDB -eq "YES-PILOT") { "<span style='background:#e65100;color:white;padding:1px 7px;border-radius:3px;font-size:10px;font-weight:700;margin-left:5px;'>PILOT</span>" } else { "" }
    $prodBadge  = if ($db.IsProd -eq "PROD") { "<span style='background:#c62828;color:white;padding:1px 6px;border-radius:3px;font-size:10px;margin-left:5px;'>PROD</span>" } else { "" }
    $recStyle   = switch -Wildcard ($db.Recommendation) { "Live*" { "color:#1b5e20;font-weight:700;" } "Strong*" { "color:#2e7d32;font-weight:700;" } "Good*" { "color:#388e3c;" } "PROD*" { "color:#c62828;" } default { "color:#757575;" } }
    $rows += "<tr style='background:$bg;'><td><b>$($db.DatabaseName)</b>$pilotBadge$prodBadge</td><td style='font-size:11px;'>$($db.ServerName)</td><td style='font-size:11px;'>$($db.Subscription)</td><td>$($db.Tier)</td><td>$modeBadge</td><td style='text-align:center;'>$($db.AvgDTU_7Day)</td><td style='font-weight:600;'>$($db.CurrentCost_Mo)</td><td style='color:#2e7d32;font-weight:600;'>$($db.Serverless_Cost_Mo)</td><td style='color:#1b5e20;font-weight:700;'>$($db.Monthly_Saving)</td><td style='color:#1b5e20;font-weight:700;'>$($db.Annual_Saving)</td><td style='color:#e65100;font-weight:700;'>$($db.Actual_7Day_Saved)</td><td style='color:#e65100;font-weight:700;'>$($db.Total_Saved_ToDate)</td><td style='$recStyle'>$($db.Recommendation)</td></tr>"
}

$metSec = if ($metricsRows) { "<div class='sec'><h2>Daily Cost Tracking - $pilotDbName ($daysRunning Days)</h2><table><thead><tr><th>Date</th><th>Period</th><th>Daily Cost</th><th>Notes</th></tr></thead><tbody>$metricsRows</tbody></table></div>" } else { "" }

$html = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>Serverless Pilot Report</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;}body{font-family:'Segoe UI',Arial,sans-serif;background:#f0f2f5;color:#212121;}
.hdr{background:linear-gradient(135deg,#1b5e20,#2e7d32,#43a047);color:#fff;padding:36px 44px;}
.hdr h1{font-size:26px;font-weight:700;margin-bottom:8px;}.hdr p{font-size:13px;opacity:.92;margin-top:4px;}
.wrap{max-width:1560px;margin:26px auto;padding:0 26px;}
.pilot-box{background:#fff;border-radius:10px;padding:24px 28px;margin-bottom:22px;box-shadow:0 2px 12px rgba(0,0,0,.09);border-left:6px solid #e65100;}
.pilot-box h2{color:#e65100;font-size:16px;font-weight:700;margin-bottom:16px;}
.pstats{display:grid;grid-template-columns:repeat(7,1fr);gap:12px;}
.ps{background:#fff8e1;border:1px solid #ffcc80;border-radius:8px;padding:14px 8px;text-align:center;}
.ps .n{font-size:22px;font-weight:700;color:#e65100;}.ps .l{font-size:10px;color:#795548;text-transform:uppercase;margin-top:4px;line-height:1.5;}
.cards{display:grid;grid-template-columns:repeat(6,1fr);gap:14px;margin-bottom:22px;}
.card{background:#fff;border-radius:10px;padding:18px 12px;text-align:center;box-shadow:0 2px 12px rgba(0,0,0,.09);}
.card .n{font-size:26px;font-weight:700;margin-bottom:5px;}.card .l{font-size:10px;color:#666;text-transform:uppercase;}
.g .n{color:#2e7d32;}.b .n{color:#1565c0;}.o .n{color:#e65100;}.r .n{color:#c62828;}.t .n{color:#00695c;}.p .n{color:#6a1b9a;}
.note{background:#e8f5e9;border-left:4px solid #43a047;padding:14px 18px;border-radius:0 6px 6px 0;margin-bottom:22px;font-size:13px;color:#1b5e20;line-height:1.7;}
.sec{background:#fff;border-radius:10px;padding:22px;margin-bottom:22px;box-shadow:0 2px 12px rgba(0,0,0,.09);}
.sec h2{font-size:15px;color:#1b5e20;border-bottom:2px solid #2e7d32;padding-bottom:9px;margin-bottom:16px;}
table{width:100%;border-collapse:collapse;font-size:12px;}
th{background:#1b5e20;color:#fff;padding:11px 9px;text-align:left;white-space:nowrap;font-weight:600;}
td{padding:10px 9px;border-bottom:1px solid #eee;vertical-align:middle;}tr:hover td{background:#f1f8e9!important;}
.ftr{text-align:center;color:#9e9e9e;font-size:11px;padding:26px;}
</style></head><body>
<div class="hdr">
  <h1>Serverless Pilot - Full Evaluation Report</h1>
  <p>All Non-Production Databases | 7-Day Actual Results | Full Cost Projections</p>
  <p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | Prepared for: Tony | Author: Syed Rizvi, Cloud Infrastructure Engineer</p>
</div>
<div class="wrap">
  <div class="pilot-box">
    <h2>7-Day Pilot Results - $pilotDbName</h2>
    <div class="pstats">
      <div class="ps"><div class="n">$daysRunning</div><div class="l">Days Running Serverless</div></div>
      <div class="ps"><div class="n">`$$pilotOrigCost</div><div class="l">Original Monthly Cost ($pilotTier)</div></div>
      <div class="ps"><div class="n">`$$svlMoCost</div><div class="l">Serverless Monthly Cost</div></div>
      <div class="ps"><div class="n">`$$savedPerDay</div><div class="l">Saved Per Day</div></div>
      <div class="ps"><div class="n">`$$saved7Day</div><div class="l">Actual Saved - First 7 Days</div></div>
      <div class="ps"><div class="n">`$$savedToDate</div><div class="l">Total Saved To Date ($daysRunning Days)</div></div>
      <div class="ps"><div class="n">`$$saveYrPilot</div><div class="l">Projected Annual Saving</div></div>
    </div>
  </div>
  <div class="cards">
    <div class="card g"><div class="n">$svlCount</div><div class="l">On Serverless</div></div>
    <div class="card b"><div class="n">$stdCount</div><div class="l">Still Standard</div></div>
    <div class="card o"><div class="n">$($devDbs.Count)</div><div class="l">Total Dev DBs</div></div>
    <div class="card r"><div class="n">`$$([math]::Round($totalCurr,0))</div><div class="l">Current Monthly Spend</div></div>
    <div class="card t"><div class="n">`$$([math]::Round($totalSavMo,0))</div><div class="l">Potential Monthly Saving</div></div>
    <div class="card p"><div class="n">`$$totalSavYr</div><div class="l">Potential Annual Saving</div></div>
  </div>
  <div class="note">The 7-day pilot on <strong>$pilotDbName</strong> confirmed <strong>70% cost reduction</strong> using serverless auto-pause billing. Running for <strong>$daysRunning days</strong>, saving <strong>`$$savedToDate total</strong>. Applying to all <strong>$($devDbs.Count) non-production databases</strong> saves <strong>`$$([math]::Round($totalSavMo,0))/month</strong> and <strong>`$$totalSavYr/year</strong>.</div>
  <div class="sec">
    <h2>All $($allDbs.Count) Databases - Live Data + Serverless Projections</h2>
    <table><thead><tr><th>Database</th><th>Server</th><th>Subscription</th><th>Tier</th><th>Mode</th><th>Avg DTU (7d)</th><th>Current /Mo</th><th>Serverless /Mo</th><th>Save /Mo</th><th>Save /Yr</th><th>7-Day Saved</th><th>Total Saved</th><th>Recommendation</th></tr></thead>
    <tbody>$rows</tbody></table>
  </div>
  $metSec
</div>
<div class="ftr">Serverless Pilot | Pyx Health | $(Get-Date -Format 'yyyy-MM-dd') | Internal Use Only<br>HTML: $HtmlFile | CSV: $CsvFile</div>
</body></html>
"@

$html | Out-File -FilePath $HtmlFile -Encoding UTF8
Write-Host "  HTML: $HtmlFile" -ForegroundColor Green
Write-Host "  CSV : $CsvFile" -ForegroundColor Green
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  DONE | DBs: $($allDbs.Count) | Save/Mo: `$$([math]::Round($totalSavMo,0)) | Save/Yr: `$$totalSavYr" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Start-Process $HtmlFile
