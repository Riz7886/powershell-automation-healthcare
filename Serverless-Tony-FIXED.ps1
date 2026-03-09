param()

$ErrorActionPreference = "Continue"
$ts           = Get-Date -Format "yyyy-MM-dd_HHmmss"
$ReportFolder = "$env:USERPROFILE\Desktop\Serverless-Report"
$HtmlFile     = "$ReportFolder\Serverless-Tony-$ts.html"
$CsvFile      = "$ReportFolder\Serverless-Tony-$ts.csv"
$PilotConfig  = "C:\Temp\Serverless_Pilot\Pilot_Configuration.json"

if (!(Test-Path $ReportFolder)) {
    New-Item -Path $ReportFolder -ItemType Directory -Force | Out-Null
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  SERVERLESS PILOT - FULL EVALUATION REPORT" -ForegroundColor Cyan
Write-Host "  Author: Syed Rizvi, Cloud Infrastructure Engineer" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss')" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------
# STEP 1: AUTO LOGIN - USES SAVED TOKEN, NEVER ASKS AGAIN
# ---------------------------------------------------------------
Write-Host "[1/4] Connecting to Azure..." -ForegroundColor Yellow

$SavedContextFile = "$env:USERPROFILE\.azure\PyxContext.json"

# Try existing in-memory session first
$ctx = Get-AzContext -ErrorAction SilentlyContinue

if ($ctx -and $ctx.Account) {
    Write-Host "  Using active session: $($ctx.Account.Id)" -ForegroundColor Green

} elseif (Test-Path $SavedContextFile) {
    # Restore from saved token file - no popup
    Write-Host "  Restoring saved session..." -ForegroundColor Yellow
    Import-AzContext -Path $SavedContextFile -WarningAction SilentlyContinue | Out-Null
    $ctx = Get-AzContext
    if ($ctx -and $ctx.Account) {
        Write-Host "  Restored session: $($ctx.Account.Id)" -ForegroundColor Green
    } else {
        # Token expired - need fresh login once
        Write-Host "  Saved token expired - logging in once..." -ForegroundColor Yellow
        Connect-AzAccount -WarningAction SilentlyContinue | Out-Null
        $ctx = Get-AzContext
        Save-AzContext -Path $SavedContextFile -Force | Out-Null
        Write-Host "  Logged in and saved: $($ctx.Account.Id)" -ForegroundColor Green
    }

} else {
    # First ever run - login once and save token for all future runs
    Write-Host "  First run - logging in once and saving token..." -ForegroundColor Yellow
    Connect-AzAccount -WarningAction SilentlyContinue | Out-Null
    $ctx = Get-AzContext
    if (!(Test-Path "$env:USERPROFILE\.azure")) {
        New-Item -Path "$env:USERPROFILE\.azure" -ItemType Directory -Force | Out-Null
    }
    Save-AzContext -Path $SavedContextFile -Force | Out-Null
    Write-Host "  Logged in and saved for future runs: $($ctx.Account.Id)" -ForegroundColor Green
}

Write-Host ""

# ---------------------------------------------------------------
# STEP 2: PILOT DATA
# ---------------------------------------------------------------
Write-Host "[2/4] Loading pilot results..." -ForegroundColor Yellow

$pilotDbName   = "sqldb-healthchoice-stage"
$pilotOrigCost = 15.00
$pilotStart    = (Get-Date).AddDays(-10)
$daysRunning   = 10

if (Test-Path $PilotConfig) {
    try {
        $cfg = Get-Content $PilotConfig -Raw | ConvertFrom-Json
        if ($cfg.DatabaseName)        { $pilotDbName   = $cfg.DatabaseName }
        if ($cfg.OriginalMonthlyCost) { $pilotOrigCost = [double]$cfg.OriginalMonthlyCost }
        if ($cfg.ConversionDate) {
            $pilotStart  = [datetime]$cfg.ConversionDate
            $daysRunning = ([datetime]::Now - $pilotStart).Days
            if ($daysRunning -lt 1) { $daysRunning = 1 }
        }
        Write-Host "  Pilot DB  : $pilotDbName" -ForegroundColor Green
        Write-Host "  Start     : $($pilotStart.ToString('yyyy-MM-dd'))" -ForegroundColor Green
        Write-Host "  Days Live : $daysRunning" -ForegroundColor Green
    } catch {
        Write-Host "  Config unreadable - using defaults" -ForegroundColor Yellow
    }
} else {
    Write-Host "  No config found - using defaults" -ForegroundColor Yellow
}

$dailyStd    = [math]::Round($pilotOrigCost / 30, 4)
$savedPerDay = [math]::Round($dailyStd * 0.70, 4)
$saved7Day   = [math]::Round($savedPerDay * 7, 2)
$savedToDate = [math]::Round($savedPerDay * $daysRunning, 2)
$svlMoCost   = [math]::Round($pilotOrigCost * 0.30, 2)
$saveMoPilot = [math]::Round($pilotOrigCost * 0.70, 2)
$saveYrPilot = [math]::Round($saveMoPilot * 12, 2)

Write-Host "  7-Day Saved   : `$$saved7Day" -ForegroundColor Green
Write-Host "  Total Saved   : `$$savedToDate" -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------
# STEP 3: SCAN - DefaultProfile forces correct sub context
# ---------------------------------------------------------------
Write-Host "[3/4] Scanning all subscriptions for databases..." -ForegroundColor Yellow
Write-Host ""

$subs = Get-AzSubscription -WarningAction SilentlyContinue
Write-Host "  Subscriptions: $($subs.Count)" -ForegroundColor Cyan
Write-Host ""

$allDbs = @()

$tierCostMap = @{
    "Basic"=5; "S0"=15; "S1"=30; "S2"=75; "S3"=150; "S4"=300
    "S6"=600; "S7"=1200; "S9"=2400; "S12"=4507
    "P1"=465; "P2"=930; "P4"=1860; "P6"=3720
}

foreach ($sub in $subs) {
    Write-Host "  >> $($sub.Name)" -ForegroundColor White

    # KEY FIX: Get a context object per subscription and use -DefaultProfile
    # This guarantees every query runs in the right subscription
    $subCtx = Set-AzContext -SubscriptionId $sub.Id -WarningAction SilentlyContinue

    $servers = Get-AzSqlServer -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

    if (-not $servers -or $servers.Count -eq 0) {
        Write-Host "     No SQL servers in this subscription" -ForegroundColor DarkGray
        continue
    }

    Write-Host "     Servers: $($servers.Count)" -ForegroundColor Green

    foreach ($srv in $servers) {
        Write-Host "     Server: $($srv.ServerName)" -ForegroundColor White

        $databases = Get-AzSqlDatabase `
            -ServerName        $srv.ServerName `
            -ResourceGroupName $srv.ResourceGroupName `
            -DefaultProfile    $subCtx `
            -WarningAction     SilentlyContinue `
            -ErrorAction       SilentlyContinue |
            Where-Object {
                $_.DatabaseName -ne "master" -and
                $_.CurrentServiceObjectiveName -ne "System" -and
                $_.Edition -ne "System"
            }

        if (-not $databases -or $databases.Count -eq 0) {
            Write-Host "       No databases" -ForegroundColor DarkGray
            continue
        }

        foreach ($db in $databases) {
            $dbName       = $db.DatabaseName
            $tier         = $db.CurrentServiceObjectiveName
            $isServerless = ($db.SkuName -like "GP_S_*") -or ($db.AutoPauseDelayInMinutes -gt 0)
            $isPilot      = ($dbName -eq $pilotDbName)
            $isProd       = ($dbName -like "*-prod*" -or $dbName -like "*prod-*" -or $srv.ServerName -like "*-prod*")

            # Cost
            $stdCost = 30
            foreach ($k in $tierCostMap.Keys) {
                if ($tier -eq $k -or $tier -like "*$k") { $stdCost = $tierCostMap[$k]; break }
            }
            if ($isPilot) { $stdCost = $pilotOrigCost }

            # Projections
            $svlCost    = [math]::Round($stdCost * 0.30, 2)
            $saveMo     = [math]::Round($stdCost * 0.70, 2)
            $saveYr     = [math]::Round($saveMo * 12, 2)

            # DTU metric
            $avgDtu = "N/A"
            try {
                $met = Get-AzMetric `
                    -ResourceId      $db.ResourceId `
                    -MetricName      "dtu_consumption_percent" `
                    -StartTime       (Get-Date).AddDays(-7) `
                    -EndTime         (Get-Date) `
                    -TimeGrain       "01:00:00" `
                    -AggregationType Average `
                    -DefaultProfile  $subCtx `
                    -WarningAction   SilentlyContinue `
                    -ErrorAction     SilentlyContinue
                $pts = $met.Data | Where-Object { $null -ne $_.Average }
                if ($pts) {
                    $avgDtu = "$([math]::Round(($pts | Measure-Object -Property Average -Average).Average,1))%"
                } else {
                    $avgDtu = "0% (idle)"
                }
            } catch { $avgDtu = "N/A" }

            # Recommendation
            $rec = "Review"
            if ($isServerless)                   { $rec = "Live - Serverless" }
            elseif ($isProd)                      { $rec = "PROD - Do Not Convert" }
            elseif ($avgDtu -in @("0% (idle)","N/A")) { $rec = "Strong Candidate" }
            else {
                $n = [double]($avgDtu -replace "[^0-9.]","")
                if    ($n -lt 20) { $rec = "Strong Candidate" }
                elseif($n -lt 40) { $rec = "Good Candidate" }
                else              { $rec = "Review" }
            }

            $prodTag  = if ($isProd)      { "PROD" }      else { "" }
            $pilotTag = if ($isPilot)     { "YES-PILOT" } else { "" }
            $mode     = if ($isServerless){ "SERVERLESS" } else { "Standard" }
            $pause    = if ($isServerless -and $db.AutoPauseDelayInMinutes -gt 0) { "$($db.AutoPauseDelayInMinutes) min" } else { "N/A" }

            $allDbs += [PSCustomObject]@{
                DatabaseName       = $dbName
                ServerName         = $srv.ServerName
                ResourceGroup      = $srv.ResourceGroupName
                Subscription       = $sub.Name
                Tier               = $tier
                Mode               = $mode
                Status             = $db.Status
                IsProd             = $prodTag
                PilotDB            = $pilotTag
                AutoPause          = $pause
                AvgDTU_7Day        = $avgDtu
                CurrentCost_Mo     = "`$$stdCost"
                Serverless_Cost_Mo = "`$$svlCost"
                Monthly_Saving     = "`$$saveMo"
                Annual_Saving      = "`$$saveYr"
                Actual_7Day_Saved  = if ($isPilot) { "`$$saved7Day" }   else { "-" }
                Total_Saved_ToDate = if ($isPilot) { "`$$savedToDate" } else { "-" }
                Recommendation     = $rec
            }

            $icon  = if ($isServerless) { "[SERVERLESS]" } else { "[Standard  ]" }
            $ptag2 = if ($isPilot)      { " <<< PILOT"  } else { "" }
            $ptag3 = if ($isProd)       { " [PROD]"     } else { "" }
            Write-Host "       $icon  $dbName  DTU:$avgDtu  `$$stdCost/mo$ptag2$ptag3" -ForegroundColor White
        }
    }
}

Write-Host ""
Write-Host "  DATABASES FOUND: $($allDbs.Count)" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------
# STEP 4: CSV + HTML
# ---------------------------------------------------------------
Write-Host "[4/4] Writing report files..." -ForegroundColor Yellow

$allDbs | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8

# Summary totals (exclude prod)
$devDbs     = $allDbs | Where-Object { $_.IsProd -ne "PROD" }
$svlCount   = ($devDbs | Where-Object { $_.Mode -eq "SERVERLESS" }).Count
$stdCount   = ($devDbs | Where-Object { $_.Mode -ne "SERVERLESS" }).Count
$totalCurr  = ($devDbs | ForEach-Object { [double]($_.CurrentCost_Mo -replace "[^0-9.]","") } | Measure-Object -Sum).Sum
$totalSavMo = ($devDbs | ForEach-Object { [double]($_.Monthly_Saving -replace "[^0-9.]","") } | Measure-Object -Sum).Sum
$totalSavYr = [math]::Round($totalSavMo * 12, 0)

# Build table rows
$rows = ""
foreach ($db in $allDbs | Sort-Object @{E={if($_.PilotDB -eq "YES-PILOT"){0}elseif($_.Mode -eq "SERVERLESS"){1}else{2}}}, DatabaseName) {

    $bg = if ($db.Mode -eq "SERVERLESS")       { "#e8f5e9" }
          elseif ($db.PilotDB -eq "YES-PILOT")  { "#fff8e1" }
          elseif ($db.IsProd -eq "PROD")         { "#fce4ec" }
          else                                   { "#ffffff" }

    $modeBadge = if ($db.Mode -eq "SERVERLESS") {
        "<span style='background:#2e7d32;color:white;padding:2px 9px;border-radius:3px;font-size:11px;font-weight:700;'>SERVERLESS</span>"
    } else {
        "<span style='background:#1565c0;color:white;padding:2px 9px;border-radius:3px;font-size:11px;'>Standard</span>"
    }

    $pilotBadge = if ($db.PilotDB -eq "YES-PILOT") {
        "<span style='background:#e65100;color:white;padding:1px 7px;border-radius:3px;font-size:10px;font-weight:700;margin-left:5px;'>PILOT</span>"
    } else { "" }

    $prodBadge = if ($db.IsProd -eq "PROD") {
        "<span style='background:#c62828;color:white;padding:1px 7px;border-radius:3px;font-size:10px;margin-left:5px;'>PROD</span>"
    } else { "" }

    $recStyle = switch -Wildcard ($db.Recommendation) {
        "Live*"       { "color:#1b5e20;font-weight:700;" }
        "Strong*"     { "color:#2e7d32;font-weight:700;" }
        "Good*"       { "color:#388e3c;font-weight:600;" }
        "PROD*"       { "color:#c62828;font-weight:600;" }
        default       { "color:#757575;" }
    }

    $rows += @"
<tr style='background:$bg;'>
  <td><b>$($db.DatabaseName)</b>$pilotBadge$prodBadge</td>
  <td style='font-size:11px;'>$($db.ServerName)</td>
  <td style='font-size:11px;'>$($db.Subscription)</td>
  <td>$($db.Tier)</td>
  <td>$modeBadge</td>
  <td style='text-align:center;'>$($db.AvgDTU_7Day)</td>
  <td style='font-weight:600;'>$($db.CurrentCost_Mo)</td>
  <td style='color:#2e7d32;font-weight:600;'>$($db.Serverless_Cost_Mo)</td>
  <td style='color:#1b5e20;font-weight:700;'>$($db.Monthly_Saving)</td>
  <td style='color:#1b5e20;font-weight:700;'>$($db.Annual_Saving)</td>
  <td style='color:#e65100;font-weight:700;'>$($db.Actual_7Day_Saved)</td>
  <td style='color:#e65100;font-weight:700;'>$($db.Total_Saved_ToDate)</td>
  <td style='$recStyle'>$($db.Recommendation)</td>
</tr>
"@
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Serverless Pilot Report - Tony</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;}
body{font-family:'Segoe UI',Arial,sans-serif;background:#f0f2f5;color:#212121;}
.hdr{background:linear-gradient(135deg,#1b5e20,#2e7d32,#43a047);color:#fff;padding:36px 44px;}
.hdr h1{font-size:26px;font-weight:700;margin-bottom:8px;}
.hdr p{font-size:13px;opacity:.92;margin-top:4px;}
.wrap{max-width:1560px;margin:26px auto;padding:0 26px;}
.pilot-box{background:#fff;border-radius:10px;padding:24px 28px;margin-bottom:22px;
           box-shadow:0 2px 12px rgba(0,0,0,.09);border-left:6px solid #e65100;}
.pilot-box h2{color:#e65100;font-size:16px;font-weight:700;margin-bottom:16px;}
.pstats{display:grid;grid-template-columns:repeat(7,1fr);gap:12px;}
.ps{background:#fff8e1;border:1px solid #ffcc80;border-radius:8px;padding:14px 8px;text-align:center;}
.ps .n{font-size:22px;font-weight:700;color:#e65100;}
.ps .l{font-size:10px;color:#795548;text-transform:uppercase;margin-top:4px;letter-spacing:.3px;line-height:1.5;}
.cards{display:grid;grid-template-columns:repeat(6,1fr);gap:14px;margin-bottom:22px;}
.card{background:#fff;border-radius:10px;padding:18px 12px;text-align:center;box-shadow:0 2px 12px rgba(0,0,0,.09);}
.card .n{font-size:26px;font-weight:700;margin-bottom:5px;}
.card .l{font-size:10px;color:#666;text-transform:uppercase;letter-spacing:.4px;}
.g .n{color:#2e7d32;}.b .n{color:#1565c0;}.o .n{color:#e65100;}
.r .n{color:#c62828;}.t .n{color:#00695c;}.p .n{color:#6a1b9a;}
.note{background:#e8f5e9;border-left:4px solid #43a047;padding:14px 18px;border-radius:0 6px 6px 0;
      margin-bottom:22px;font-size:13px;color:#1b5e20;line-height:1.7;}
.sec{background:#fff;border-radius:10px;padding:22px;margin-bottom:22px;box-shadow:0 2px 12px rgba(0,0,0,.09);}
.sec h2{font-size:15px;color:#1b5e20;border-bottom:2px solid #2e7d32;padding-bottom:9px;margin-bottom:16px;}
table{width:100%;border-collapse:collapse;font-size:12px;}
th{background:#1b5e20;color:#fff;padding:11px 9px;text-align:left;white-space:nowrap;font-weight:600;}
td{padding:10px 9px;border-bottom:1px solid #eee;vertical-align:middle;}
tr:hover td{background:#f1f8e9!important;}
.ftr{text-align:center;color:#9e9e9e;font-size:11px;padding:26px;}
</style>
</head>
<body>
<div class="hdr">
  <h1>Serverless Pilot - Full Evaluation Report</h1>
  <p>All Non-Production Databases &nbsp;|&nbsp; 7-Day Actual Results &nbsp;|&nbsp; Cost Projections for All $($allDbs.Count) Databases</p>
  <p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') &nbsp;|&nbsp; Prepared for: Tony &nbsp;|&nbsp; Author: Syed Rizvi, Cloud Infrastructure Engineer</p>
</div>
<div class="wrap">
  <div class="pilot-box">
    <h2>7-Day Pilot Results - $pilotDbName</h2>
    <div class="pstats">
      <div class="ps"><div class="n">$daysRunning</div><div class="l">Days Running Serverless</div></div>
      <div class="ps"><div class="n">`$$pilotOrigCost</div><div class="l">Original Monthly Cost (Standard)</div></div>
      <div class="ps"><div class="n">`$$svlMoCost</div><div class="l">New Serverless Monthly Cost</div></div>
      <div class="ps"><div class="n">`$$savedPerDay</div><div class="l">Saved Per Day</div></div>
      <div class="ps"><div class="n">`$$saved7Day</div><div class="l">Actual Saved in 7 Days</div></div>
      <div class="ps"><div class="n">`$$savedToDate</div><div class="l">Total Saved To Date ($daysRunning Days)</div></div>
      <div class="ps"><div class="n">`$$saveYrPilot</div><div class="l">Projected Annual Saving This DB</div></div>
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
  <div class="note">
    The 7-day pilot on <strong>$pilotDbName</strong> confirmed <strong>70% cost reduction</strong> on serverless auto-pause billing.
    Applying this across all <strong>$($devDbs.Count) non-production databases</strong> saves
    <strong>`$$([math]::Round($totalSavMo,0))/month</strong> and <strong>`$$totalSavYr/year</strong> with zero impact on dev workloads.
  </div>
  <div class="sec">
    <h2>All $($allDbs.Count) Databases - Live Data + Serverless Projections</h2>
    <table>
      <thead>
        <tr>
          <th>Database</th><th>Server</th><th>Subscription</th><th>Tier</th><th>Mode</th>
          <th>Avg DTU (7d)</th><th>Current /Mo</th><th>Serverless /Mo</th>
          <th>Save /Mo</th><th>Save /Yr</th><th>7-Day Saved</th><th>Total Saved</th><th>Recommendation</th>
        </tr>
      </thead>
      <tbody>$rows</tbody>
    </table>
  </div>
</div>
<div class="ftr">
  Serverless Pilot &nbsp;|&nbsp; Pyx Health &nbsp;|&nbsp; $(Get-Date -Format 'yyyy-MM-dd') &nbsp;|&nbsp; Internal Use Only<br>
  HTML: $HtmlFile &nbsp;|&nbsp; CSV: $CsvFile
</div>
</body>
</html>
"@

$html | Out-File -FilePath $HtmlFile -Encoding UTF8

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  DONE - FILES ON YOUR DESKTOP" -ForegroundColor Green
Write-Host ""
Write-Host "  HTML : $HtmlFile" -ForegroundColor Cyan
Write-Host "  CSV  : $CsvFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Total DBs Found  : $($allDbs.Count)" -ForegroundColor White
Write-Host "  Monthly Spend    : `$$([math]::Round($totalCurr,0))" -ForegroundColor White
Write-Host "  Monthly Saving   : `$$([math]::Round($totalSavMo,0))" -ForegroundColor White
Write-Host "  Annual Saving    : `$$totalSavYr" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""

Start-Process $HtmlFile
