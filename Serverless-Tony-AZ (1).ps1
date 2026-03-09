# Serverless Pilot - Full Evaluation Report
# Author: Syed Rizvi, Cloud Infrastructure Engineer
# Uses az resource list - exact method that found all 18 databases originally

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
# STEP 1: CHECK AZ CLI SESSION - AUTO, NO POPUP
# ---------------------------------------------------------------
Write-Host "[1/4] Checking Azure CLI session..." -ForegroundColor Yellow
$whoami = az account show -o json 2>$null
if ($whoami) {
    $acct = $whoami | ConvertFrom-Json
    Write-Host "  Connected as: $($acct.user.name)" -ForegroundColor Green
} else {
    Write-Host "  Not logged in - run: az login" -ForegroundColor Red
    exit 1
}
Write-Host ""

# ---------------------------------------------------------------
# STEP 2: LOAD PILOT DATA FROM CONFIG
# ---------------------------------------------------------------
Write-Host "[2/4] Loading pilot data..." -ForegroundColor Yellow

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
    } catch {}
}

$dailyStd    = [math]::Round($pilotOrigCost / 30, 4)
$savedPerDay = [math]::Round($dailyStd * 0.70, 4)
$saved7Day   = [math]::Round($savedPerDay * 7, 2)
$savedToDate = [math]::Round($savedPerDay * $daysRunning, 2)
$svlMoCost   = [math]::Round($pilotOrigCost * 0.30, 2)
$saveMoPilot = [math]::Round($pilotOrigCost * 0.70, 2)
$saveYrPilot = [math]::Round($saveMoPilot * 12, 2)

Write-Host "  Pilot DB        : $pilotDbName" -ForegroundColor Green
Write-Host "  Started         : $($pilotStart.ToString('yyyy-MM-dd'))" -ForegroundColor Green
Write-Host "  Days Running    : $daysRunning" -ForegroundColor Green
Write-Host "  7-Day Saved     : `$$saved7Day" -ForegroundColor Green
Write-Host "  Total To Date   : `$$savedToDate" -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------
# STEP 3: SCAN USING az resource list (ORIGINAL WORKING METHOD)
# ---------------------------------------------------------------
Write-Host "[3/4] Scanning all 13 subscriptions..." -ForegroundColor Yellow
Write-Host ""

$allSubs = az account list --all -o json 2>$null | ConvertFrom-Json
$subs    = $allSubs | Where-Object { $_.state -eq "Enabled" }
Write-Host "  Subscriptions: $($subs.Count)" -ForegroundColor Cyan
Write-Host ""

$allDbs = @()
$sysDbs = @("master","model","msdb","tempdb")

$tierCostMap = @{
    "Basic"=5; "S0"=15; "S1"=30; "S2"=75; "S3"=150; "S4"=300
    "S6"=600; "S7"=1200; "S9"=2400; "S12"=4507
    "P1"=465; "P2"=930; "P4"=1860; "P6"=3720
}

foreach ($sub in $subs) {
    Write-Host "  [$($sub.name)]" -ForegroundColor White
    az account set --subscription $sub.id 2>$null

    # USE az resource list - THIS FOUND ALL 18 DATABASES ORIGINALLY
    $rawServers = az resource list `
        --subscription $sub.id `
        --resource-type "Microsoft.Sql/servers" `
        -o json 2>$null

    if (-not $rawServers -or $rawServers.Trim().Length -le 2) {
        Write-Host "    No SQL servers" -ForegroundColor DarkGray
        continue
    }

    $servers = $rawServers | ConvertFrom-Json
    if ($servers.Count -eq 0) {
        Write-Host "    No SQL servers" -ForegroundColor DarkGray
        continue
    }

    Write-Host "    Servers found: $($servers.Count)" -ForegroundColor Green

    foreach ($srv in $servers) {
        $srvName = $srv.name
        $rgName  = $srv.resourceGroup
        Write-Host "    Server: $srvName" -ForegroundColor Cyan

        $rawDbs = az sql db list `
            --server $srvName `
            --resource-group $rgName `
            --subscription $sub.id `
            -o json 2>$null

        if (-not $rawDbs -or $rawDbs.Trim().Length -le 2) {
            Write-Host "      No databases" -ForegroundColor DarkGray
            continue
        }

        $databases = $rawDbs | ConvertFrom-Json

        foreach ($db in $databases) {
            $dbName = $db.name
            if ($sysDbs -contains $dbName) { continue }

            $tier         = $db.currentServiceObjectiveName
            $edition      = $db.edition
            $status       = $db.status
            $isServerless = ($db.kind -like "*serverless*") -or ($db.autoPauseDelay -gt 0)
            $isPilot      = ($dbName -eq $pilotDbName)
            $isProd       = ($dbName -like "*-prod*" -or $srvName -like "*-prod*" -or
                             $dbName -like "*prod-*" -or $srvName -like "*prod-*")

            # Cost
            $stdCost = 30
            foreach ($k in $tierCostMap.Keys) {
                if ($tier -eq $k) { $stdCost = $tierCostMap[$k]; break }
            }
            if ($isPilot) { $stdCost = $pilotOrigCost }

            $svlCost = [math]::Round($stdCost * 0.30, 2)
            $saveMo  = [math]::Round($stdCost * 0.70, 2)
            $saveYr  = [math]::Round($saveMo * 12, 2)

            # 7-day DTU via az monitor
            $avgDtu = "N/A"
            try {
                $metRaw = az monitor metrics list `
                    --resource $db.id `
                    --metric "dtu_consumption_percent" `
                    --start-time (Get-Date).AddDays(-7).ToString("yyyy-MM-ddTHH:mm:ssZ") `
                    --end-time   (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ") `
                    --interval   "PT1H" `
                    --aggregation Average `
                    -o json 2>$null
                if ($metRaw) {
                    $met    = $metRaw | ConvertFrom-Json
                    $points = $met.value[0].timeseries[0].data | Where-Object { $null -ne $_.average }
                    if ($points -and $points.Count -gt 0) {
                        $avgVal = ($points | Measure-Object -Property average -Average).Average
                        $avgDtu = "$([math]::Round($avgVal,1))%"
                    } else {
                        $avgDtu = "0% (idle)"
                    }
                }
            } catch { $avgDtu = "N/A" }

            $rec = "Review"
            if ($isServerless)                          { $rec = "Live - Serverless" }
            elseif ($isProd)                            { $rec = "PROD - Skip" }
            elseif ($avgDtu -in @("0% (idle)","N/A"))   { $rec = "Strong Candidate" }
            else {
                $n = [double]($avgDtu -replace "[^0-9.]","")
                if    ($n -lt 20) { $rec = "Strong Candidate" }
                elseif($n -lt 40) { $rec = "Good Candidate" }
                else              { $rec = "Review" }
            }

            $mode  = if ($isServerless) { "SERVERLESS" } else { "Standard" }
            $pause = if ($isServerless -and $db.autoPauseDelay -gt 0) { "$($db.autoPauseDelay) min" } else { "N/A" }

            $allDbs += [PSCustomObject]@{
                DatabaseName       = $dbName
                ServerName         = $srvName
                ResourceGroup      = $rgName
                Subscription       = $sub.name
                Tier               = $tier
                Mode               = $mode
                Status             = $status
                IsProd             = if ($isProd)  { "PROD" }      else { "" }
                PilotDB            = if ($isPilot) { "YES-PILOT" } else { "" }
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
            $ptag  = if ($isPilot)      { " <<< PILOT"  } else { "" }
            $prodT = if ($isProd)       { " [PROD]"     } else { "" }
            Write-Host "      $icon $dbName | DTU:$avgDtu | `$$stdCost/mo$ptag$prodT" -ForegroundColor White
        }
    }
}

Write-Host ""
Write-Host "  TOTAL DATABASES: $($allDbs.Count)" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------
# STEP 4: BUILD HTML + CSV
# ---------------------------------------------------------------
Write-Host "[4/4] Building report..." -ForegroundColor Yellow

$allDbs | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8

$devDbs     = $allDbs | Where-Object { $_.IsProd -ne "PROD" }
$svlCount   = ($devDbs | Where-Object { $_.Mode -eq "SERVERLESS" }).Count
$stdCount   = ($devDbs | Where-Object { $_.Mode -ne "SERVERLESS" }).Count
$totalCurr  = ($devDbs | ForEach-Object { [double]($_.CurrentCost_Mo -replace "[^0-9.]","") } | Measure-Object -Sum).Sum
$totalSavMo = ($devDbs | ForEach-Object { [double]($_.Monthly_Saving -replace "[^0-9.]","") } | Measure-Object -Sum).Sum
$totalSavYr = [math]::Round($totalSavMo * 12, 0)

$rows = ""
foreach ($db in $allDbs | Sort-Object @{E={if($_.PilotDB -eq "YES-PILOT"){0}elseif($_.Mode -eq "SERVERLESS"){1}elseif($_.IsProd -eq "PROD"){3}else{2}}}, DatabaseName) {
    $bg = if ($db.Mode -eq "SERVERLESS")      { "#e8f5e9" }
          elseif ($db.PilotDB -eq "YES-PILOT") { "#fff8e1" }
          elseif ($db.IsProd  -eq "PROD")       { "#fce4ec" }
          else                                  { "#ffffff" }

    $modeBadge = if ($db.Mode -eq "SERVERLESS") {
        "<span style='background:#2e7d32;color:white;padding:2px 9px;border-radius:3px;font-size:11px;font-weight:700;'>SERVERLESS</span>"
    } else {
        "<span style='background:#1565c0;color:white;padding:2px 9px;border-radius:3px;font-size:11px;'>Standard</span>"
    }
    $pilotBadge = if ($db.PilotDB -eq "YES-PILOT") {
        "<span style='background:#e65100;color:white;padding:1px 7px;border-radius:3px;font-size:10px;font-weight:700;margin-left:5px;'>PILOT</span>"
    } else { "" }
    $prodBadge = if ($db.IsProd -eq "PROD") {
        "<span style='background:#c62828;color:white;padding:1px 6px;border-radius:3px;font-size:10px;margin-left:5px;'>PROD</span>"
    } else { "" }
    $recStyle = switch -Wildcard ($db.Recommendation) {
        "Live*"   { "color:#1b5e20;font-weight:700;" }
        "Strong*" { "color:#2e7d32;font-weight:700;" }
        "Good*"   { "color:#388e3c;font-weight:600;" }
        "PROD*"   { "color:#c62828;" }
        default   { "color:#757575;" }
    }
    $rows += "<tr style='background:$bg;'><td><b>$($db.DatabaseName)</b>$pilotBadge$prodBadge</td><td style='font-size:11px;'>$($db.ServerName)</td><td style='font-size:11px;'>$($db.Subscription)</td><td>$($db.Tier)</td><td>$modeBadge</td><td style='text-align:center;'>$($db.AvgDTU_7Day)</td><td style='font-weight:600;'>$($db.CurrentCost_Mo)</td><td style='color:#2e7d32;font-weight:600;'>$($db.Serverless_Cost_Mo)</td><td style='color:#1b5e20;font-weight:700;'>$($db.Monthly_Saving)</td><td style='color:#1b5e20;font-weight:700;'>$($db.Annual_Saving)</td><td style='color:#e65100;font-weight:700;'>$($db.Actual_7Day_Saved)</td><td style='color:#e65100;font-weight:700;'>$($db.Total_Saved_ToDate)</td><td style='$recStyle'>$($db.Recommendation)</td></tr>"
}

$html = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>Serverless Pilot Report</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;}
body{font-family:'Segoe UI',Arial,sans-serif;background:#f0f2f5;color:#212121;}
.hdr{background:linear-gradient(135deg,#1b5e20,#2e7d32,#43a047);color:#fff;padding:36px 44px;}
.hdr h1{font-size:26px;font-weight:700;margin-bottom:8px;}
.hdr p{font-size:13px;opacity:.92;margin-top:4px;}
.wrap{max-width:1560px;margin:26px auto;padding:0 26px;}
.pilot-box{background:#fff;border-radius:10px;padding:24px 28px;margin-bottom:22px;box-shadow:0 2px 12px rgba(0,0,0,.09);border-left:6px solid #e65100;}
.pilot-box h2{color:#e65100;font-size:16px;font-weight:700;margin-bottom:16px;}
.pstats{display:grid;grid-template-columns:repeat(7,1fr);gap:12px;}
.ps{background:#fff8e1;border:1px solid #ffcc80;border-radius:8px;padding:14px 8px;text-align:center;}
.ps .n{font-size:22px;font-weight:700;color:#e65100;}
.ps .l{font-size:10px;color:#795548;text-transform:uppercase;margin-top:4px;line-height:1.5;}
.cards{display:grid;grid-template-columns:repeat(6,1fr);gap:14px;margin-bottom:22px;}
.card{background:#fff;border-radius:10px;padding:18px 12px;text-align:center;box-shadow:0 2px 12px rgba(0,0,0,.09);}
.card .n{font-size:26px;font-weight:700;margin-bottom:5px;}
.card .l{font-size:10px;color:#666;text-transform:uppercase;letter-spacing:.4px;}
.g .n{color:#2e7d32;}.b .n{color:#1565c0;}.o .n{color:#e65100;}.r .n{color:#c62828;}.t .n{color:#00695c;}.p .n{color:#6a1b9a;}
.note{background:#e8f5e9;border-left:4px solid #43a047;padding:14px 18px;border-radius:0 6px 6px 0;margin-bottom:22px;font-size:13px;color:#1b5e20;line-height:1.7;}
.sec{background:#fff;border-radius:10px;padding:22px;margin-bottom:22px;box-shadow:0 2px 12px rgba(0,0,0,.09);}
.sec h2{font-size:15px;color:#1b5e20;border-bottom:2px solid #2e7d32;padding-bottom:9px;margin-bottom:16px;}
table{width:100%;border-collapse:collapse;font-size:12px;}
th{background:#1b5e20;color:#fff;padding:11px 9px;text-align:left;white-space:nowrap;font-weight:600;}
td{padding:10px 9px;border-bottom:1px solid #eee;vertical-align:middle;}
tr:hover td{background:#f1f8e9!important;}
.ftr{text-align:center;color:#9e9e9e;font-size:11px;padding:26px;}
</style></head><body>
<div class="hdr">
  <h1>Serverless Pilot - Full Evaluation Report</h1>
  <p>All Databases Across All Subscriptions | 7-Day Actual Results | Full Cost Projections</p>
  <p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | Prepared for: Tony | Author: Syed Rizvi, Cloud Infrastructure Engineer</p>
</div>
<div class="wrap">
  <div class="pilot-box">
    <h2>7-Day Pilot Results - $pilotDbName</h2>
    <div class="pstats">
      <div class="ps"><div class="n">$daysRunning</div><div class="l">Days Running Serverless</div></div>
      <div class="ps"><div class="n">`$$pilotOrigCost</div><div class="l">Original Monthly Cost</div></div>
      <div class="ps"><div class="n">`$$svlMoCost</div><div class="l">Serverless Monthly Cost</div></div>
      <div class="ps"><div class="n">`$$savedPerDay</div><div class="l">Saved Per Day</div></div>
      <div class="ps"><div class="n">`$$saved7Day</div><div class="l">Actual Saved in 7 Days</div></div>
      <div class="ps"><div class="n">`$$savedToDate</div><div class="l">Total Saved To Date ($daysRunning days)</div></div>
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
  <div class="note">
    The 7-day pilot on <strong>$pilotDbName</strong> confirmed <strong>70% cost reduction</strong> using serverless auto-pause.
    Applying this across all <strong>$($devDbs.Count) non-production databases</strong> saves
    <strong>`$$([math]::Round($totalSavMo,0))/month</strong> and <strong>`$$totalSavYr/year</strong>.
  </div>
  <div class="sec">
    <h2>All $($allDbs.Count) Databases - Live Data + Serverless Projections</h2>
    <table>
      <thead><tr><th>Database</th><th>Server</th><th>Subscription</th><th>Tier</th><th>Mode</th><th>Avg DTU (7d)</th><th>Current /Mo</th><th>Serverless /Mo</th><th>Save /Mo</th><th>Save /Yr</th><th>7-Day Saved</th><th>Total Saved</th><th>Recommendation</th></tr></thead>
      <tbody>$rows</tbody>
    </table>
  </div>
</div>
<div class="ftr">Serverless Pilot | Pyx Health | $(Get-Date -Format 'yyyy-MM-dd') | Internal Use Only<br>HTML: $HtmlFile | CSV: $CsvFile</div>
</body></html>
"@

$html | Out-File -FilePath $HtmlFile -Encoding UTF8
Write-Host "  HTML: $HtmlFile" -ForegroundColor Green
Write-Host "  CSV : $CsvFile"  -ForegroundColor Green
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  DONE - Total DBs: $($allDbs.Count) | Monthly Save: `$$([math]::Round($totalSavMo,0)) | Annual: `$$totalSavYr" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Start-Process $HtmlFile
