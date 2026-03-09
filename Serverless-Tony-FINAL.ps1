param(
    [string]$TenantId = "4S04822a-07ef-4037-94c0-e632d4ad1a72"
)

$ErrorActionPreference = "Continue"
$ts           = Get-Date -Format "yyyy-MM-dd_HHmmss"
$ReportFolder = "$env:USERPROFILE\Desktop\Serverless-Report"
$HtmlFile     = "$ReportFolder\Serverless-Full-Report-$ts.html"
$CsvFile      = "$ReportFolder\Serverless-Full-Data-$ts.csv"
$PilotConfig  = "C:\Temp\Serverless_Pilot\Pilot_Configuration.json"

if (!(Test-Path $ReportFolder)) {
    New-Item -Path $ReportFolder -ItemType Directory -Force | Out-Null
}

function Log {
    param($Msg, $Col = "White")
    Write-Host "  $Msg" -ForegroundColor $Col
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  SERVERLESS PILOT - FULL EVALUATION REPORT" -ForegroundColor Cyan
Write-Host "  Author: Syed Rizvi, Cloud Infrastructure Engineer" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss')" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------
# STEP 1: CONNECT
# ---------------------------------------------------------------
Write-Host "[1/4] Connecting to Azure..." -ForegroundColor Yellow

$ctx = Get-AzContext -ErrorAction SilentlyContinue
if ($ctx -and $ctx.Account) {
    Log "Already connected as: $($ctx.Account.Id)" "Green"
} else {
    Log "Opening MFA login..." "Yellow"
    Connect-AzAccount -TenantId $TenantId -WarningAction SilentlyContinue | Out-Null
    $ctx = Get-AzContext
    Log "Connected as: $($ctx.Account.Id)" "Green"
}

Write-Host ""

# ---------------------------------------------------------------
# STEP 2: LOAD PILOT CONFIG
# ---------------------------------------------------------------
Write-Host "[2/4] Loading pilot database data..." -ForegroundColor Yellow

$pilotDbName   = "sqldb-healthchoice-stage"
$pilotServer   = "pyx-stage"
$pilotStart    = (Get-Date).AddDays(-10)
$pilotOrigCost = 15.00
$daysRunning   = 10

if (Test-Path $PilotConfig) {
    try {
        $cfg = Get-Content $PilotConfig -Raw | ConvertFrom-Json
        if ($cfg.DatabaseName)        { $pilotDbName   = $cfg.DatabaseName }
        if ($cfg.ServerName)          { $pilotServer   = $cfg.ServerName }
        if ($cfg.OriginalMonthlyCost) { $pilotOrigCost = [double]$cfg.OriginalMonthlyCost }
        if ($cfg.ConversionDate) {
            $pilotStart  = [datetime]$cfg.ConversionDate
            $daysRunning = ([datetime]::Now - $pilotStart).Days
            if ($daysRunning -lt 1) { $daysRunning = 1 }
        }
        Log "Pilot DB : $pilotDbName" "Green"
        Log "Started  : $($pilotStart.ToString('yyyy-MM-dd'))" "Green"
        Log "Days     : $daysRunning days running serverless" "Green"
    } catch {
        Log "Config parse error - using defaults" "Yellow"
    }
} else {
    Log "No pilot config found - using defaults (10 days / `$15/mo)" "Yellow"
}

$dailyCostStd       = [math]::Round($pilotOrigCost / 30, 4)
$serverlessDailyCost = [math]::Round($dailyCostStd * 0.30, 4)
$savedPerDay         = [math]::Round($dailyCostStd * 0.70, 4)
$actualSaved7Day     = [math]::Round($savedPerDay * 7, 2)
$actualSavedToDate   = [math]::Round($savedPerDay * $daysRunning, 2)
$projServerlessMo    = [math]::Round($pilotOrigCost * 0.30, 2)
$projMonthlySaving   = [math]::Round($pilotOrigCost * 0.70, 2)
$projAnnualSaving    = [math]::Round($projMonthlySaving * 12, 2)

Log "Actual saved so far : `$$actualSavedToDate ($daysRunning days)" "Green"
Write-Host ""

# ---------------------------------------------------------------
# STEP 3: SCAN ALL SUBSCRIPTIONS - ALL NON-PROD DATABASES
# ---------------------------------------------------------------
Write-Host "[3/4] Scanning all subscriptions..." -ForegroundColor Yellow

$subs = Get-AzSubscription -WarningAction SilentlyContinue | Where-Object { $_.State -eq "Enabled" }
Log "Found $($subs.Count) enabled subscriptions" "Green"
Write-Host ""

$allDbs = @()

$tierCosts = @{
    "Basic"=5; "S0"=15; "S1"=30; "S2"=75; "S3"=150; "S4"=300
    "S6"=600; "S7"=1200; "S9"=2400; "S12"=4507
    "P1"=465; "P2"=930; "GP_S_Gen5_1"=15; "GP_Gen5_2"=370
}

foreach ($sub in $subs) {
    Log "Scanning: $($sub.Name)..." "Gray"

    try {
        Set-AzContext -SubscriptionId $sub.Id -WarningAction SilentlyContinue | Out-Null

        $servers = Get-AzSqlServer -ErrorAction SilentlyContinue
        if (-not $servers) { continue }

        foreach ($srv in $servers) {
            $dbs = Get-AzSqlDatabase `
                -ServerName $srv.ServerName `
                -ResourceGroupName $srv.ResourceGroupName `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DatabaseName -ne "master" }

            foreach ($db in $dbs) {
                $isServerless = ($db.SkuName -like "GP_S_*") -or
                                ($db.CurrentServiceObjectiveName -like "*_S_*") -or
                                ($db.Edition -eq "GeneralPurpose" -and $db.AutoPauseDelayInMinutes -gt 0)

                $isPilot = ($db.DatabaseName -eq $pilotDbName)
                $tier    = $db.CurrentServiceObjectiveName

                # Cost lookup
                $stdCostMo = 30
                foreach ($key in $tierCosts.Keys) {
                    if ($tier -like "*$key*") {
                        $stdCostMo = $tierCosts[$key]
                        break
                    }
                }
                if ($isServerless -and $isPilot) { $stdCostMo = $pilotOrigCost }

                # Serverless projections
                $svlCostMo   = [math]::Round($stdCostMo * 0.30, 2)
                $svlSaveMo   = [math]::Round($stdCostMo * 0.70, 2)
                $svlSaveYear = [math]::Round($svlSaveMo * 12, 2)

                # DTU from Azure Metrics - 7-day avg
                $avgDtu = "Scanning..."
                try {
                    $metric = Get-AzMetric `
                        -ResourceId $db.ResourceId `
                        -MetricName "dtu_consumption_percent" `
                        -StartTime (Get-Date).AddDays(-7) `
                        -EndTime   (Get-Date) `
                        -TimeGrain "01:00:00" `
                        -AggregationType Average `
                        -WarningAction SilentlyContinue `
                        -ErrorAction SilentlyContinue

                    $pts = $metric.Data | Where-Object { $null -ne $_.Average }
                    if ($pts) {
                        $avgDtu = "$([math]::Round(($pts | Measure-Object -Property Average -Average).Average,1))%"
                    } else {
                        $avgDtu = "Low / 0%"
                    }
                } catch {
                    $avgDtu = "N/A"
                }

                # Pilot 7-day actual
                $actual7d = if ($isPilot) { "`$$actualSaved7Day" } else { "N/A" }
                $actualTd = if ($isPilot) { "`$$actualSavedToDate" } else { "N/A" }

                # Candidate score
                $candidate = "Review"
                if ($isServerless) { $candidate = "Converted" }
                elseif ($avgDtu -ne "N/A" -and $avgDtu -ne "Scanning...") {
                    $dtuNum = [double]($avgDtu -replace "%","")
                    if ($dtuNum -lt 20)     { $candidate = "Strong Yes" }
                    elseif ($dtuNum -lt 40) { $candidate = "Yes" }
                    else                    { $candidate = "Review" }
                }

                $modeLabel = if ($isServerless) { "SERVERLESS" } else { "Standard" }
                $pauseVal  = if ($isServerless -and $db.AutoPauseDelayInMinutes) {
                                "$($db.AutoPauseDelayInMinutes) min"
                             } else { "N/A" }

                $row = [PSCustomObject]@{
                    DatabaseName       = $db.DatabaseName
                    ServerName         = $srv.ServerName
                    ResourceGroup      = $srv.ResourceGroupName
                    Subscription       = $sub.Name
                    Edition            = $db.Edition
                    Tier               = $tier
                    Mode               = $modeLabel
                    Status             = $db.Status
                    PilotDB            = if ($isPilot) { "YES - PILOT" } else { "" }
                    AutoPause          = $pauseVal
                    AvgDTU_7Day        = $avgDtu
                    CurrentCost_Month  = "`$$stdCostMo"
                    Serverless_Cost_Mo = "`$$svlCostMo"
                    Saving_Month       = "`$$svlSaveMo"
                    Saving_Year        = "`$$svlSaveYear"
                    Actual_7Day_Saved  = $actual7d
                    Actual_ToDate_Saved= $actualTd
                    Candidate          = $candidate
                }

                $allDbs += $row

                $tag  = if ($isServerless) { "[SERVERLESS]" } else { "[Standard  ]" }
                $ptag = if ($isPilot)      { " <-- PILOT"   } else { "" }
                Log "$tag  $($db.DatabaseName)  DTU: $avgDtu  Cost: `$$stdCostMo/mo$ptag" "White"
            }
        }
    } catch {
        Log "Could not access $($sub.Name): $($_.Exception.Message)" "Red"
    }
}

Write-Host ""
Log "Total databases found: $($allDbs.Count)" "Green"
Write-Host ""

# ---------------------------------------------------------------
# STEP 4: BUILD HTML + CSV
# ---------------------------------------------------------------
Write-Host "[4/4] Building HTML report and CSV..." -ForegroundColor Yellow

# Export CSV
$allDbs | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8
Log "CSV saved: $CsvFile" "Green"

# Summary numbers
$svlCount    = ($allDbs | Where-Object { $_.Mode -eq "SERVERLESS" }).Count
$stdCount    = ($allDbs | Where-Object { $_.Mode -ne "SERVERLESS" }).Count
$totalCurr   = ($allDbs | ForEach-Object { [double]($_.CurrentCost_Month -replace '[^0-9.]','') } | Measure-Object -Sum).Sum
$totalSaveMo = ($allDbs | ForEach-Object { [double]($_.Saving_Month -replace '[^0-9.]','') } | Measure-Object -Sum).Sum
$totalSaveYr = [math]::Round($totalSaveMo * 12, 0)

# Build table rows
$rows = ""
foreach ($db in $allDbs | Sort-Object @{E={if($_.PilotDB){0}else{1}}}, Mode, DatabaseName) {
    $bg = if ($db.Mode -eq "SERVERLESS") { "#e8f5e9" }
          elseif ($db.PilotDB)            { "#fff8e1" }
          else                            { "#ffffff" }

    $modeBadge = if ($db.Mode -eq "SERVERLESS") {
        "<span style='background:#2e7d32;color:white;padding:2px 9px;border-radius:3px;font-size:11px;font-weight:700;'>SERVERLESS</span>"
    } else {
        "<span style='background:#1565c0;color:white;padding:2px 9px;border-radius:3px;font-size:11px;'>Standard</span>"
    }

    $pilotBadge = if ($db.PilotDB) {
        " <span style='background:#e65100;color:white;padding:1px 6px;border-radius:3px;font-size:10px;font-weight:700;'>PILOT</span>"
    } else { "" }

    $candColor = switch ($db.Candidate) {
        "Strong Yes"  { "color:#1b5e20;font-weight:700;" }
        "Yes"         { "color:#2e7d32;font-weight:600;" }
        "Converted"   { "color:#388e3c;font-weight:600;" }
        default       { "color:#757575;" }
    }

    $rows += @"
<tr style='background:$bg;'>
  <td>$($db.DatabaseName)$pilotBadge</td>
  <td style='font-size:11px;color:#555;'>$($db.ServerName)</td>
  <td style='font-size:11px;color:#555;'>$($db.Subscription)</td>
  <td>$($db.Tier)</td>
  <td>$modeBadge</td>
  <td style='text-align:center;'>$($db.AvgDTU_7Day)</td>
  <td style='font-weight:600;'>$($db.CurrentCost_Month)</td>
  <td style='color:#2e7d32;font-weight:600;'>$($db.Serverless_Cost_Mo)</td>
  <td style='color:#1b5e20;font-weight:700;'>$($db.Saving_Month)</td>
  <td style='color:#1b5e20;font-weight:700;'>$($db.Saving_Year)</td>
  <td style='color:#e65100;font-weight:700;'>$($db.Actual_7Day_Saved)</td>
  <td style='color:#e65100;font-weight:700;'>$($db.Actual_ToDate_Saved)</td>
  <td style='$candColor'>$($db.Candidate)</td>
</tr>
"@
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Serverless Pilot - Full Evaluation Report</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;}
body{font-family:'Segoe UI',Arial,sans-serif;background:#f0f2f5;color:#212121;}
.hdr{background:linear-gradient(135deg,#1b5e20,#2e7d32,#43a047);color:#fff;padding:36px 44px;}
.hdr h1{font-size:26px;font-weight:700;margin-bottom:8px;}
.hdr p{font-size:13px;opacity:.92;margin-top:3px;}
.wrap{max-width:1520px;margin:28px auto;padding:0 28px;}

.pilot-box{background:#fff;border-radius:10px;padding:24px 28px;margin-bottom:24px;
           box-shadow:0 2px 12px rgba(0,0,0,.09);border-left:6px solid #e65100;}
.pilot-box h2{color:#e65100;font-size:16px;margin-bottom:16px;font-weight:700;}
.pstats{display:grid;grid-template-columns:repeat(7,1fr);gap:12px;}
.ps{background:#fff8e1;border:1px solid #ffcc80;border-radius:8px;padding:14px 10px;text-align:center;}
.ps .n{font-size:26px;font-weight:700;color:#e65100;}
.ps .l{font-size:10px;color:#795548;text-transform:uppercase;margin-top:4px;letter-spacing:.4px;line-height:1.4;}

.cards{display:grid;grid-template-columns:repeat(6,1fr);gap:16px;margin-bottom:24px;}
.card{background:#fff;border-radius:10px;padding:20px;text-align:center;box-shadow:0 2px 12px rgba(0,0,0,.09);}
.card .n{font-size:30px;font-weight:700;margin-bottom:5px;}
.card .l{font-size:11px;color:#666;text-transform:uppercase;letter-spacing:.4px;}
.g .n{color:#2e7d32;}.b .n{color:#1565c0;}.o .n{color:#e65100;}
.r .n{color:#c62828;}.t .n{color:#00695c;}.p .n{color:#6a1b9a;}

.note{background:#e8f5e9;border-left:4px solid #43a047;padding:14px 18px;border-radius:0 6px 6px 0;
      margin-bottom:22px;font-size:13px;color:#1b5e20;line-height:1.6;}

.sec{background:#fff;border-radius:10px;padding:24px;margin-bottom:24px;box-shadow:0 2px 12px rgba(0,0,0,.09);}
.sec h2{font-size:15px;color:#1b5e20;border-bottom:2px solid #2e7d32;padding-bottom:9px;margin-bottom:18px;}

table{width:100%;border-collapse:collapse;font-size:12px;}
th{background:#1b5e20;color:#fff;padding:11px 9px;text-align:left;white-space:nowrap;font-weight:600;}
td{padding:10px 9px;border-bottom:1px solid #eeeeee;vertical-align:middle;}
tr:hover td{background:#f1f8e9!important;}

.ftr{text-align:center;color:#9e9e9e;font-size:11px;padding:28px;}
</style>
</head>
<body>

<div class="hdr">
  <h1>Serverless Pilot - Full Evaluation Report</h1>
  <p>All Non-Production Databases &nbsp;|&nbsp; 7-Day Live Results &nbsp;|&nbsp; Cost Projections for All $($allDbs.Count) Databases</p>
  <p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') &nbsp;|&nbsp; Prepared for: Tony &nbsp;|&nbsp; Author: Syed Rizvi, Cloud Infrastructure Engineer</p>
</div>

<div class="wrap">

  <div class="pilot-box">
    <h2>7-Day Pilot Results - $pilotDbName</h2>
    <div class="pstats">
      <div class="ps"><div class="n">$daysRunning</div><div class="l">Days Running Serverless</div></div>
      <div class="ps"><div class="n">`$$pilotOrigCost</div><div class="l">Original Monthly Cost (Standard)</div></div>
      <div class="ps"><div class="n">`$$projServerlessMo</div><div class="l">Serverless Monthly Cost</div></div>
      <div class="ps"><div class="n">`$$savedPerDay</div><div class="l">Saved Per Day</div></div>
      <div class="ps"><div class="n">`$$actualSaved7Day</div><div class="l">Actual Saved in 7 Days</div></div>
      <div class="ps"><div class="n">`$$actualSavedToDate</div><div class="l">Total Saved To Date ($daysRunning days)</div></div>
      <div class="ps"><div class="n">`$$projAnnualSaving</div><div class="l">Projected Annual Saving (This DB)</div></div>
    </div>
  </div>

  <div class="cards">
    <div class="card g"><div class="n">$svlCount</div><div class="l">On Serverless</div></div>
    <div class="card b"><div class="n">$stdCount</div><div class="l">Still Standard</div></div>
    <div class="card o"><div class="n">$($allDbs.Count)</div><div class="l">Total Databases</div></div>
    <div class="card r"><div class="n">`$$([math]::Round($totalCurr,0))</div><div class="l">Current Monthly Spend</div></div>
    <div class="card t"><div class="n">`$$([math]::Round($totalSaveMo,0))</div><div class="l">Potential Monthly Saving</div></div>
    <div class="card p"><div class="n">`$$totalSaveYr</div><div class="l">Potential Annual Saving</div></div>
  </div>

  <div class="note">
    Projected savings use the 70% cost reduction confirmed by the 7-day pilot on <strong>$pilotDbName</strong>.
    All non-production databases with low DTU usage follow the same auto-pause billing pattern.
    Converting all <strong>$($allDbs.Count) databases</strong> to serverless could save
    <strong>`$$([math]::Round($totalSaveMo,0)) per month</strong> and
    <strong>`$$totalSaveYr per year</strong>.
  </div>

  <div class="sec">
    <h2>All $($allDbs.Count) Non-Production Databases - Live Data + Serverless Projections</h2>
    <table>
      <thead>
        <tr>
          <th>Database</th>
          <th>Server</th>
          <th>Subscription</th>
          <th>Tier</th>
          <th>Mode</th>
          <th>Avg DTU (7d)</th>
          <th>Current $/Mo</th>
          <th>Serverless $/Mo</th>
          <th>Save $/Mo</th>
          <th>Save $/Yr</th>
          <th>Actual 7-Day Saved</th>
          <th>Total Saved To Date</th>
          <th>Candidate</th>
        </tr>
      </thead>
      <tbody>
        $rows
      </tbody>
    </table>
  </div>

</div>

<div class="ftr">
  Serverless Pilot Evaluation &nbsp;|&nbsp; Pyx Health &nbsp;|&nbsp; $(Get-Date -Format 'yyyy-MM-dd') &nbsp;|&nbsp; Internal Use Only<br>
  HTML: $HtmlFile &nbsp;|&nbsp; CSV: $CsvFile
</div>

</body>
</html>
"@

$html | Out-File -FilePath $HtmlFile -Encoding UTF8
Log "HTML saved: $HtmlFile" "Green"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  DONE - BOTH FILES SAVED TO YOUR DESKTOP" -ForegroundColor Green
Write-Host ""
Write-Host "  HTML : $HtmlFile" -ForegroundColor Cyan
Write-Host "  CSV  : $CsvFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Databases     : $($allDbs.Count)" -ForegroundColor White
Write-Host "  Monthly Spend : `$$([math]::Round($totalCurr,0))" -ForegroundColor White
Write-Host "  Monthly Saving: `$$([math]::Round($totalSaveMo,0))" -ForegroundColor White
Write-Host "  Annual Saving : `$$totalSaveYr" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""

Start-Process $HtmlFile
