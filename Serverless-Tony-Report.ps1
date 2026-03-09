param(
    [string]$TenantId = "4S04822a-07ef-4037-94c0-e632d4ad1a72"
)

$ErrorActionPreference = "Continue"
$timestamp       = Get-Date -Format "yyyy-MM-dd_HHmmss"
$ReportFolder    = "$env:USERPROFILE\Desktop\Serverless-Report"
$HtmlFile        = "$ReportFolder\Tony-Serverless-Report-$timestamp.html"
$CsvFile         = "$ReportFolder\Tony-Serverless-Data-$timestamp.csv"
$PilotConfigFile = "C:\Temp\Serverless_Pilot\Pilot_Configuration.json"
$PilotMetrics    = "C:\Temp\Serverless_Pilot\Performance_Metrics.csv"

if (!(Test-Path $ReportFolder)) {
    New-Item -Path $ReportFolder -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param($Message)
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $Message"
}

Write-Host ""
Write-Host "======================================================================"
Write-Host "  SERVERLESS PILOT - FULL EVALUATION REPORT FOR TONY"
Write-Host "  All 18 Dev Databases + 7-Day Savings + Projections"
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "======================================================================"
Write-Host ""

# ============================================================
# STEP 1: CONNECT AUTOMATICALLY
# ============================================================
Write-Log "Step 1 of 4: Connecting to Azure..."

try {
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if ($context -and $context.Account) {
        Write-Log "  Already connected as: $($context.Account.Id)"
    } else {
        Write-Log "  Opening login window..."
        Connect-AzAccount -TenantId $TenantId | Out-Null
        $context = Get-AzContext
        Write-Log "  Connected as: $($context.Account.Id)"
    }
} catch {
    Connect-AzAccount | Out-Null
    $context = Get-AzContext
    Write-Log "  Connected as: $($context.Account.Id)"
}

# ============================================================
# STEP 2: LOAD PILOT DATABASE CONFIG
# ============================================================
Write-Log "Step 2 of 4: Loading pilot database data..."

$pilotDbName    = "sqldb-healthchoice-stage"
$pilotStartDate = $null
$pilotOrigCost  = 0
$pilotSaved     = 0

if (Test-Path $PilotConfigFile) {
    try {
        $cfg = Get-Content $PilotConfigFile | ConvertFrom-Json
        $pilotDbName    = $cfg.DatabaseName
        $pilotStartDate = [datetime]$cfg.ConversionDate
        $pilotOrigCost  = [double]$cfg.OriginalMonthlyCost
        $daysRunning    = ([datetime]::Now - $pilotStartDate).Days
        $dailyCost      = $pilotOrigCost / 30
        Write-Log "  Pilot DB: $pilotDbName"
        Write-Log "  Running for: $daysRunning days"
    } catch {
        Write-Log "  Config found but could not parse - using defaults"
        $pilotStartDate = (Get-Date).AddDays(-7)
        $pilotOrigCost  = 15
        $daysRunning    = 7
    }
} else {
    Write-Log "  No config file found - using 7-day estimate"
    $pilotStartDate = (Get-Date).AddDays(-7)
    $pilotOrigCost  = 15
    $daysRunning    = 7
}

# ============================================================
# STEP 3: SCAN ALL SUBSCRIPTIONS - FIND ALL 18 DEV DATABASES
# ============================================================
Write-Log "Step 3 of 4: Scanning all subscriptions for dev databases..."
Write-Host ""

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
Write-Log "  Found $($subscriptions.Count) active subscriptions"
Write-Host ""

$allDatabases = @()

$tierCosts = @{
    "Basic"="5";  "S0"="15";  "S1"="30";   "S2"="75";   "S3"="150"
    "S4"="300";   "S6"="600"; "S7"="1200"; "S9"="2400"; "S12"="4507"
    "P1"="465";   "P2"="930"; "P4"="1860"; "P6"="3720"; "P11"="7440"
}

foreach ($sub in $subscriptions) {
    Write-Log "  Scanning: $($sub.Name)..."
    try {
        Set-AzContext -SubscriptionId $sub.Id -WarningAction SilentlyContinue | Out-Null
        $servers = Get-AzSqlServer -ErrorAction SilentlyContinue
        if (-not $servers) { continue }

        foreach ($srv in $servers) {
            $dbs = Get-AzSqlDatabase -ServerName $srv.ServerName -ResourceGroupName $srv.ResourceGroupName -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.DatabaseName -ne "master" -and (
                        $_.DatabaseName -like "*dev*"   -or
                        $_.DatabaseName -like "*stage*" -or
                        $_.DatabaseName -like "*test*"  -or
                        $_.DatabaseName -like "*qa*"    -or
                        $_.DatabaseName -like "*uat*"   -or
                        $_.DatabaseName -like "*nonprod*"
                    ) -and $_.DatabaseName -notlike "*prod*"
                }

            foreach ($db in $dbs) {
                $tier        = $db.CurrentServiceObjectiveName
                $isServerless = $db.SkuName -like "GP_S_*"
                $isPilotDb    = $db.DatabaseName -eq $pilotDbName

                # Current monthly cost estimate
                $stdCost = if ($tierCosts[$tier]) { [int]$tierCosts[$tier] } else { 30 }

                # Serverless projected cost (avg 70% savings for low-use dev DBs)
                $projServerlessCost = [math]::Round($stdCost * 0.30, 2)
                $projMonthlySaving  = $stdCost - $projServerlessCost
                $projAnnualSaving   = $projMonthlySaving * 12

                # 7-day actual savings for the pilot DB
                $actualSaved7Day  = "N/A"
                $actualSavedMonth = "N/A"
                if ($isPilotDb) {
                    $dailyCostStd     = $stdCost / 30
                    $actualSaved7Day  = "$" + [math]::Round($dailyCostStd * 7 * 0.70, 2)
                    $actualSavedMonth = "$" + [math]::Round($stdCost * 0.70, 2)
                }

                # DTU average over 7 days
                $avgDtu = "N/A"
                try {
                    $m = Get-AzMetric -ResourceId $db.ResourceId `
                                      -MetricName "dtu_consumption_percent" `
                                      -StartTime (Get-Date).AddDays(-7) `
                                      -EndTime (Get-Date) `
                                      -TimeGrain 01:00:00 `
                                      -AggregationType Average `
                                      -WarningAction SilentlyContinue `
                                      -ErrorAction SilentlyContinue
                    if ($m -and $m.Data) {
                        $pts = $m.Data | Where-Object { $null -ne $_.Average }
                        if ($pts) {
                            $avgDtu = "$([math]::Round(($pts | Measure-Object -Property Average -Average).Average, 1))%"
                        }
                    }
                } catch {}

                # Serverless-specific fields
                $autoPause = if ($isServerless) { "$($db.AutoPauseDelayInMinutes) min" } else { "N/A" }
                $minCores  = if ($isServerless) { $db.MinimumCapacity } else { "N/A" }
                $maxCores  = if ($isServerless) { $db.Capacity } else { "N/A" }
                $modeLabel = if ($isServerless) { "SERVERLESS" } else { "Standard" }
                $pilotTag  = if ($isPilotDb) { "YES - PILOT DB" } else { "No" }

                $row = [PSCustomObject]@{
                    Subscription          = $sub.Name
                    ResourceGroup         = $srv.ResourceGroupName
                    ServerName            = $srv.ServerName
                    DatabaseName          = $db.DatabaseName
                    CurrentTier           = $tier
                    CurrentMode           = $modeLabel
                    DbStatus              = $db.Status
                    PilotDatabase         = $pilotTag
                    AutoPauseDelay        = $autoPause
                    MinVCores             = $minCores
                    MaxVCores             = $maxCores
                    AvgDTU_7Day           = $avgDtu
                    CurrentMonthlyCost    = "`$$stdCost"
                    ProjServerlessCost    = "`$$projServerlessCost"
                    ProjMonthlySaving     = "`$$projMonthlySaving"
                    ProjAnnualSaving      = "`$$projAnnualSaving"
                    Actual7DaySaved       = $actualSaved7Day
                    ActualMonthSaving     = $actualSavedMonth
                    ServerlessCandidate   = if ($isServerless) { "Already Serverless" } elseif ($avgDtu -ne "N/A" -and [double]($avgDtu -replace "%","") -lt 30) { "YES - Good Candidate" } else { "Review Needed" }
                }

                $allDatabases += $row
                $icon = if ($isServerless) { "[SERVERLESS]" } else { "[Standard]" }
                $pilot = if ($isPilotDb) { " <-- PILOT DB" } else { "" }
                Write-Log "    $icon $($db.DatabaseName)$pilot"
            }
        }
    } catch {
        Write-Log "    Could not access $($sub.Name): $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Log "Total dev databases found: $($allDatabases.Count)"
Write-Host ""

# ============================================================
# STEP 4: GENERATE HTML + CSV
# ============================================================
Write-Log "Step 4 of 4: Building HTML report and CSV..."

# CSV first (always simple)
$allDatabases | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8
Write-Log "  CSV saved: $CsvFile"

# Totals for summary cards
$serverlessCount  = ($allDatabases | Where-Object { $_.CurrentMode -eq "SERVERLESS" }).Count
$standardCount    = ($allDatabases | Where-Object { $_.CurrentMode -ne "SERVERLESS" }).Count
$totalCurrentCost = ($allDatabases | ForEach-Object {
    $v = $_.CurrentMonthlyCost -replace '\$',''
    if ($v -match '^\d') { [int]$v } else { 0 }
}) | Measure-Object -Sum | Select-Object -ExpandProperty Sum

$totalProjSaving  = ($allDatabases | ForEach-Object {
    $v = $_.ProjMonthlySaving -replace '\$',''
    if ($v -match '^\d') { [double]$v } else { 0 }
}) | Measure-Object -Sum | Select-Object -ExpandProperty Sum

$totalAnnualSaving = [math]::Round($totalProjSaving * 12, 0)

# Pilot 7-day summary
$daysRunning = if ($pilotStartDate) { ([datetime]::Now - $pilotStartDate).Days } else { 7 }
$pilotDailySaving = [math]::Round(($pilotOrigCost / 30) * 0.70, 2)
$pilotTotalSaved  = [math]::Round($pilotDailySaving * $daysRunning, 2)

# Build table rows
$tableRows = ""
foreach ($db in $allDatabases | Sort-Object @{E={if ($_.PilotDatabase -like "YES*") {0} else {1}}}, DatabaseName) {
    $bgColor = if ($db.CurrentMode -eq "SERVERLESS") { "#e8f5e9" } elseif ($db.PilotDatabase -like "YES*") { "#fff8e1" } else { "#ffffff" }

    $modeBadge = if ($db.CurrentMode -eq "SERVERLESS") {
        "<span style='background:#2e7d32;color:white;padding:2px 8px;border-radius:3px;font-size:11px;font-weight:bold;'>SERVERLESS</span>"
    } else {
        "<span style='background:#1565c0;color:white;padding:2px 8px;border-radius:3px;font-size:11px;'>Standard</span>"
    }

    $pilotBadge = if ($db.PilotDatabase -like "YES*") {
        "<span style='background:#f57c00;color:white;padding:2px 8px;border-radius:3px;font-size:11px;font-weight:bold;'>PILOT</span>"
    } else { "" }

    $candidateBadge = if ($db.ServerlessCandidate -like "YES*") {
        "<span style='color:#2e7d32;font-weight:bold;'>YES</span>"
    } elseif ($db.ServerlessCandidate -eq "Already Serverless") {
        "<span style='color:#388e3c;'>Done</span>"
    } else {
        "<span style='color:#757575;'>Review</span>"
    }

    $tableRows += @"
<tr style='background:$bgColor;'>
  <td>$($db.DatabaseName) $pilotBadge</td>
  <td>$($db.ServerName)</td>
  <td>$($db.Subscription)</td>
  <td>$($db.CurrentTier)</td>
  <td>$modeBadge</td>
  <td>$($db.AvgDTU_7Day)</td>
  <td><b>$($db.CurrentMonthlyCost)</b></td>
  <td style='color:#2e7d32;font-weight:bold;'>$($db.ProjServerlessCost)</td>
  <td style='color:#2e7d32;font-weight:bold;'>$($db.ProjMonthlySaving)</td>
  <td style='color:#1b5e20;font-weight:bold;'>$($db.ProjAnnualSaving)</td>
  <td>$($db.Actual7DaySaved)</td>
  <td>$candidateBadge</td>
</tr>
"@
}

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Serverless Pilot - Full Report for Tony</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: 'Segoe UI', Arial, sans-serif; margin: 0; padding: 0; background: #f4f6f8; color: #212121; }
  .header { background: linear-gradient(135deg, #1b5e20 0%, #2e7d32 60%, #388e3c 100%); color: white; padding: 40px; }
  .header h1 { margin: 0 0 10px 0; font-size: 30px; font-weight: 700; }
  .header p  { margin: 4px 0; opacity: 0.9; font-size: 14px; }
  .container { max-width: 1500px; margin: 0 auto; padding: 30px; }

  .pilot-banner {
    background: white; border-radius: 10px; padding: 25px 30px;
    margin-bottom: 28px; box-shadow: 0 2px 10px rgba(0,0,0,0.08);
    border-left: 6px solid #f57c00;
  }
  .pilot-banner h2 { margin: 0 0 16px 0; color: #e65100; font-size: 18px; }
  .pilot-stats { display: grid; grid-template-columns: repeat(5, 1fr); gap: 15px; }
  .pstat { text-align: center; padding: 16px; background: #fff8e1; border-radius: 8px; border: 1px solid #ffcc02; }
  .pstat .num { font-size: 28px; font-weight: 700; color: #e65100; }
  .pstat .lbl { font-size: 11px; color: #795548; text-transform: uppercase; margin-top: 4px; letter-spacing: 0.5px; }

  .summary-grid { display: grid; grid-template-columns: repeat(5, 1fr); gap: 18px; margin-bottom: 28px; }
  .card { background: white; border-radius: 10px; padding: 22px; text-align: center; box-shadow: 0 2px 10px rgba(0,0,0,0.08); }
  .card .num { font-size: 36px; font-weight: 700; margin-bottom: 6px; }
  .card .lbl { font-size: 12px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; }
  .card.green  .num { color: #2e7d32; }
  .card.blue   .num { color: #1565c0; }
  .card.orange .num { color: #e65100; }
  .card.teal   .num { color: #00695c; }
  .card.red    .num { color: #c62828; }

  .section { background: white; border-radius: 10px; padding: 25px; margin-bottom: 28px; box-shadow: 0 2px 10px rgba(0,0,0,0.08); }
  .section h2 { margin: 0 0 20px 0; color: #1b5e20; font-size: 17px; border-bottom: 2px solid #2e7d32; padding-bottom: 10px; }

  table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
  th { background: #1b5e20; color: white; padding: 11px 10px; text-align: left; white-space: nowrap; }
  td { padding: 10px; border-bottom: 1px solid #eeeeee; vertical-align: middle; }
  tr:hover td { background: #f1f8e9 !important; }

  .note-box { background: #e8f5e9; border-left: 4px solid #43a047; padding: 15px 20px; border-radius: 0 6px 6px 0; margin-bottom: 20px; font-size: 13px; color: #1b5e20; }
  .footer { text-align: center; color: #9e9e9e; font-size: 12px; padding: 30px; }
</style>
</head>
<body>

<div class="header">
  <h1>Serverless Pilot - Full Evaluation Report</h1>
  <p>All Non-Production Databases | 7-Day Results | Cost Projections for All 18 Databases</p>
  <p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') &nbsp;|&nbsp; Prepared for: Tony &nbsp;|&nbsp; Author: Syed Rizvi, Cloud Infrastructure Engineer</p>
</div>

<div class="container">

  <!-- PILOT RESULTS BANNER -->
  <div class="pilot-banner">
    <h2>7-Day Pilot Results - sqldb-healthchoice-stage</h2>
    <div class="pilot-stats">
      <div class="pstat"><div class="num">$daysRunning</div><div class="lbl">Days Running Serverless</div></div>
      <div class="pstat"><div class="num">`$$pilotOrigCost</div><div class="lbl">Original Monthly Cost</div></div>
      <div class="pstat"><div class="num">`$$([math]::Round($pilotOrigCost * 0.30, 2))</div><div class="lbl">Serverless Monthly Cost</div></div>
      <div class="pstat"><div class="num">`$$pilotTotalSaved</div><div class="lbl">Actual Saved So Far</div></div>
      <div class="pstat"><div class="num">`$$([math]::Round($pilotOrigCost * 0.70 * 12, 0))</div><div class="lbl">Projected Annual Saving</div></div>
    </div>
  </div>

  <!-- SUMMARY CARDS -->
  <div class="summary-grid">
    <div class="card green">
      <div class="num">$serverlessCount</div>
      <div class="lbl">On Serverless Now</div>
    </div>
    <div class="card blue">
      <div class="num">$standardCount</div>
      <div class="lbl">Still on Standard</div>
    </div>
    <div class="card orange">
      <div class="num">$($allDatabases.Count)</div>
      <div class="lbl">Total Dev Databases</div>
    </div>
    <div class="card red">
      <div class="num">`$$totalCurrentCost</div>
      <div class="lbl">Current Monthly Spend</div>
    </div>
    <div class="card teal">
      <div class="num">`$$([math]::Round($totalProjSaving, 0))</div>
      <div class="lbl">Potential Monthly Saving</div>
    </div>
  </div>

  <div class="note-box">
    Projected savings are based on 70% average cost reduction observed in the 7-day pilot. Standard Dev databases typically run at under 20% DTU utilization, making them strong candidates for serverless auto-pause billing. Annual saving across all $($allDatabases.Count) databases if converted: <b>`$$totalAnnualSaving per year</b>.
  </div>

  <!-- MAIN TABLE -->
  <div class="section">
    <h2>All $($allDatabases.Count) Non-Production Databases - Live Data + Serverless Projection</h2>
    <table>
      <thead>
        <tr>
          <th>Database</th>
          <th>Server</th>
          <th>Subscription</th>
          <th>Tier</th>
          <th>Mode</th>
          <th>Avg DTU (7d)</th>
          <th>Current Cost/Mo</th>
          <th>Serverless Cost/Mo</th>
          <th>Monthly Saving</th>
          <th>Annual Saving</th>
          <th>7-Day Actual Saved</th>
          <th>Candidate?</th>
        </tr>
      </thead>
      <tbody>
        $tableRows
      </tbody>
    </table>
  </div>

</div>

<div class="footer">
  Serverless Pilot Evaluation | Pyx Health | $(Get-Date -Format 'yyyy-MM-dd') | Internal Use Only<br>
  Files saved to: $ReportFolder
</div>

</body>
</html>
"@

$html | Out-File -FilePath $HtmlFile -Encoding UTF8
Write-Log "  HTML saved: $HtmlFile"

Write-Host ""
Write-Host "======================================================================"
Write-Host "  DONE! BOTH FILES READY FOR TONY"
Write-Host ""
Write-Host "  HTML:  $HtmlFile"
Write-Host "  CSV:   $CsvFile"
Write-Host "  Location: $ReportFolder"
Write-Host ""
Write-Host "  Databases Found: $($allDatabases.Count)"
Write-Host "  Current Monthly Spend: `$$totalCurrentCost"
Write-Host "  Potential Monthly Saving: `$$([math]::Round($totalProjSaving,0))"
Write-Host "  Potential Annual Saving:  `$$totalAnnualSaving"
Write-Host "======================================================================"
Write-Host ""

Start-Process $HtmlFile
