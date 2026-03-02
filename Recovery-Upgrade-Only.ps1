param(
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$outDir = Join-Path $dir "Recovery_$ts"
New-Item -Path $outDir -ItemType Directory -Force | Out-Null
$logFile = Join-Path $outDir "recovery.log"

function WL { 
    param([string]$M,[string]$C="White")
    $stamp = Get-Date -Format 'HH:mm:ss'
    "[$stamp] $M" | Out-File -FilePath $logFile -Append -Encoding UTF8
    Write-Host "[$stamp] $M" -ForegroundColor $C 
}

$tenant = "8ef3d734-3ca5-4493-8d8b-52b2c54eab04"

# ================================================================
#  PROTECTED - Robert already fixed these - DO NOT TOUCH
# ================================================================

$protectedServers = @("mycareloop")

$protectedDbs = @(
    "sqldb-aetna-prod","sqldb-healthchoice-prod","sqldb-uhc-prod",
    "sqldb-parkland-prod","sqldb-partners-qa","sqldb-pyx-central-ana",
    "sqldb-healthchoice-ana","sqldb-pyx-central-prod","sqldb-mbpr-ana",
    "sqldb-nbpr-ana","sqldb-lakeland-ana","sqldb-pyx-uhc-qa"
)

# ================================================================
#  THRESHOLDS - UPGRADE if DTU is high
# ================================================================

$UPGRADE_THRESHOLD = 60   # If max DTU > 60%, upgrade it

# ================================================================
#  PRICING
# ================================================================

$pricing = @{
    "Basic"=@{D=5;P=4.99;E="Basic";O="Basic";MaxGB=2}
    "S0"=@{D=10;P=15.03;E="Standard";O="S0";MaxGB=250}
    "S1"=@{D=20;P=30.05;E="Standard";O="S1";MaxGB=250}
    "S2"=@{D=50;P=75.13;E="Standard";O="S2";MaxGB=250}
    "S3"=@{D=100;P=150.26;E="Standard";O="S3";MaxGB=1024}
    "S4"=@{D=200;P=300.52;E="Standard";O="S4";MaxGB=1024}
    "S6"=@{D=400;P=601.03;E="Standard";O="S6";MaxGB=1024}
    "S7"=@{D=800;P=1202.06;E="Standard";O="S7";MaxGB=1024}
    "S9"=@{D=1600;P=2404.13;E="Standard";O="S9";MaxGB=1024}
    "S12"=@{D=3000;P=4507.74;E="Standard";O="S12";MaxGB=1024}
}

$tierUp = @{
    "Basic"="S0";"S0"="S1";"S1"="S2";"S2"="S3"
    "S3"="S4";"S4"="S6";"S6"="S7";"S7"="S9";"S9"="S12";"S12"="S12"
}

function Test-Protected {
    param([string]$Server, [string]$DbName)
    foreach ($ps in $protectedServers) { if ($Server -like "*$ps*") { return $true } }
    if ($protectedDbs -contains $DbName) { return $true }
    return $false
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Red
Write-Host "  EMERGENCY RECOVERY - UPGRADE ONLY MODE" -ForegroundColor Red
Write-Host "  NO DOWNGRADES | Only fixes struggling databases" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""
Write-Host "  MODE: UPGRADE ONLY (no downgrades, no cost savings)" -ForegroundColor Yellow
Write-Host "  THRESHOLD: Upgrade if DTU > $UPGRADE_THRESHOLD%" -ForegroundColor Yellow
Write-Host "  PROTECTED: $($protectedServers -join ', ') + $($protectedDbs.Count) specific DBs" -ForegroundColor Blue
Write-Host ""
if ($DryRun) { Write-Host "  *** DRY RUN - No changes ***" -ForegroundColor Magenta; Write-Host "" }

# ================================================================
#  AZURE LOGIN
# ================================================================

Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  STEP 1: AZURE LOGIN" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow

$needLogin = $true
try {
    $raw = az account show 2>$null
    if ($raw) {
        $a = $raw | ConvertFrom-Json
        if ($a.tenantId -eq $tenant) { WL "Logged in: $($a.user.name)" "Green"; $needLogin = $false }
    }
} catch {}

if ($needLogin) {
    az logout 2>$null
    Write-Host "  BROWSER - Sign in + MFA" -ForegroundColor Cyan
    az login --tenant $tenant 2>$null | Out-Null
    $raw = az account show 2>$null
    if ($raw) {
        $a = $raw | ConvertFrom-Json
        if ($a.tenantId -eq $tenant) { WL "Login OK" "Green" }
        else { WL "FATAL: Wrong tenant" "Red"; exit 1 }
    } else { WL "FATAL: Login failed" "Red"; exit 1 }
}

# ================================================================
#  STEP 2: SCAN ALL DATABASES
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  STEP 2: SCAN ALL DATABASES + DTU" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$allSubs = @()
$rawSubs = az account list --query "[?tenantId=='$tenant' && state=='Enabled']" 2>$null
if ($rawSubs) { try { $allSubs = $rawSubs | ConvertFrom-Json } catch {} }

$allDbs = @()
$sysDbs = @("master","tempdb","model","msdb")

foreach ($sub in $allSubs) {
    Write-Host "  $($sub.name)..." -ForegroundColor Gray -NoNewline
    az account set --subscription $sub.id 2>$null
    
    $servers = @()
    $srvRaw = az sql server list --subscription $sub.id 2>$null
    if ($srvRaw -and $srvRaw.Trim().Length -gt 2) { try { $servers = $srvRaw | ConvertFrom-Json } catch {} }
    
    $dbCount = 0
    foreach ($srv in $servers) {
        $dbs = @()
        $dbRaw = az sql db list --server $srv.name --resource-group $srv.resourceGroup --subscription $sub.id 2>$null
        if ($dbRaw -and $dbRaw.Trim().Length -gt 2) { try { $dbs = $dbRaw | ConvertFrom-Json } catch {} }
        
        foreach ($db in $dbs) {
            if ($sysDbs -contains $db.name) { continue }
            $dbCount++
            
            $protected = Test-Protected -Server $srv.name -DbName $db.name
            $maxGB = [math]::Round($db.maxSizeBytes / 1073741824, 2)
            $avgDTU = 0; $maxDTU = 0
            
            # Get DTU
            try {
                $endT = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                $startT = (Get-Date).AddHours(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                $resId = "/subscriptions/$($sub.id)/resourceGroups/$($srv.resourceGroup)/providers/Microsoft.Sql/servers/$($srv.name)/databases/$($db.name)"
                $mRaw = az monitor metrics list --resource $resId --metric "dtu_consumption_percent" --start-time $startT --end-time $endT --interval PT5M 2>$null
                if ($mRaw) {
                    $m = $mRaw | ConvertFrom-Json
                    if ($m.value -and $m.value[0].timeseries -and $m.value[0].timeseries[0].data) {
                        $pts = @($m.value[0].timeseries[0].data | Where-Object { $_.average -ne $null })
                        if ($pts.Count -gt 0) {
                            $avgDTU = [math]::Round(($pts | Measure-Object -Property average -Average).Average, 1)
                            $maxDTU = [math]::Round(($pts | Measure-Object -Property average -Maximum).Maximum, 1)
                        }
                    }
                }
            } catch {}
            
            # Determine action - ONLY UPGRADE, never downgrade
            $action = "NONE"
            $status = "OK"
            $recTier = $db.currentServiceObjectiveName
            
            if ($protected) {
                $status = "PROTECTED"
                $action = "SKIP"
            } elseif ($maxDTU -ge $UPGRADE_THRESHOLD) {
                $status = "NEEDS UPGRADE"
                $action = "UPGRADE"
                $recTier = $tierUp[$db.currentServiceObjectiveName]
                if (-not $recTier) { $recTier = "S2" }  # Default to S2 if unknown
            }
            
            $curCost = if ($pricing[$db.currentServiceObjectiveName]) { $pricing[$db.currentServiceObjectiveName].P } else { 0 }
            $newCost = if ($pricing[$recTier]) { $pricing[$recTier].P } else { $curCost }
            
            $allDbs += [PSCustomObject]@{
                Sub=$sub.name; SubId=$sub.id; Server=$srv.name; RG=$srv.resourceGroup
                DB=$db.name; SKU=$db.currentServiceObjectiveName; MaxSizeGB=$maxGB
                AvgDTU=$avgDTU; MaxDTU=$maxDTU; Status=$status; Action=$action
                RecTier=$recTier; CurCost=$curCost; NewCost=$newCost
                Protected=$protected; DbStatus=$db.status
            }
        }
    }
    Write-Host " $dbCount DBs" -ForegroundColor Green
}

WL "Scanned $($allDbs.Count) databases" "Green"

# Categorize
$needsUpgrade = @($allDbs | Where-Object { $_.Action -eq "UPGRADE" })
$protectedList = @($allDbs | Where-Object { $_.Status -eq "PROTECTED" })
$okList = @($allDbs | Where-Object { $_.Status -eq "OK" })

Write-Host ""
Write-Host "  RESULTS:" -ForegroundColor Cyan
Write-Host "    NEEDS UPGRADE (DTU>$UPGRADE_THRESHOLD%): $($needsUpgrade.Count)" -ForegroundColor Red
Write-Host "    PROTECTED (Robert fixed):       $($protectedList.Count)" -ForegroundColor Blue
Write-Host "    OK (no action needed):          $($okList.Count)" -ForegroundColor Green
Write-Host ""

# Export scan
$scanCsv = Join-Path $outDir "Scan_Results.csv"
$allDbs | Export-Csv -Path $scanCsv -NoTypeInformation -Encoding UTF8

# ================================================================
#  STEP 3: UPGRADE STRUGGLING DATABASES
# ================================================================

Write-Host "================================================================" -ForegroundColor Red
Write-Host "  STEP 3: UPGRADE STRUGGLING DATABASES" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""

$results = @()
$upgraded = 0
$failed = 0
$skipped = 0
$currentSub = ""

if ($needsUpgrade.Count -eq 0) {
    Write-Host "  No databases need upgrading!" -ForegroundColor Green
} else {
    Write-Host "  Upgrading $($needsUpgrade.Count) databases..." -ForegroundColor Yellow
    Write-Host ""
    
    $counter = 0
    foreach ($db in $needsUpgrade) {
        $counter++
        $key = "$($db.Server)/$($db.DB)"
        
        Write-Host "  [$counter/$($needsUpgrade.Count)] $key " -ForegroundColor Gray -NoNewline
        Write-Host "[$($db.SKU) $($db.MaxDTU)% DTU] " -ForegroundColor Yellow -NoNewline
        
        if ($db.Protected) {
            Write-Host "PROTECTED" -ForegroundColor Blue
            $skipped++
            $results += [PSCustomObject]@{Server=$db.Server;DB=$db.DB;From=$db.SKU;To="N/A";MaxDTU=$db.MaxDTU;Status="PROTECTED";Error=""}
            continue
        }
        
        if ($DryRun) {
            Write-Host "-> $($db.RecTier) (DRY RUN)" -ForegroundColor Yellow
            $skipped++
            $results += [PSCustomObject]@{Server=$db.Server;DB=$db.DB;From=$db.SKU;To=$db.RecTier;MaxDTU=$db.MaxDTU;Status="DRY RUN";Error=""}
            continue
        }
        
        if ($currentSub -ne $db.SubId) {
            az account set --subscription $db.SubId 2>$null
            $currentSub = $db.SubId
        }
        
        $t = $pricing[$db.RecTier]
        if (-not $t) {
            Write-Host "SKIP - unknown tier" -ForegroundColor Gray
            $skipped++
            continue
        }
        
        # Apply upgrade
        $updResult = az sql db update --server $db.Server --name $db.DB --resource-group $db.RG --subscription $db.SubId --edition $t.E --service-objective $t.O 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "-> $($db.RecTier) UPGRADED" -ForegroundColor Green
            $upgraded++
            WL "UPGRADED: ${key} $($db.SKU) -> $($db.RecTier)" "Green"
            $results += [PSCustomObject]@{Server=$db.Server;DB=$db.DB;From=$db.SKU;To=$db.RecTier;MaxDTU=$db.MaxDTU;Status="UPGRADED";Error=""}
        } else {
            $errMsg = ($updResult | Out-String).Trim()
            $shortErr = if ($errMsg.Length -gt 80) { $errMsg.Substring(0,80) } else { $errMsg }
            Write-Host "FAILED" -ForegroundColor Red
            $failed++
            WL "FAILED: ${key} - $shortErr" "Red"
            $results += [PSCustomObject]@{Server=$db.Server;DB=$db.DB;From=$db.SKU;To=$db.RecTier;MaxDTU=$db.MaxDTU;Status="FAILED";Error=$shortErr}
        }
    }
}

# Export results
$resultsCsv = Join-Path $outDir "Upgrade_Results.csv"
$results | Export-Csv -Path $resultsCsv -NoTypeInformation -Encoding UTF8

# ================================================================
#  STEP 4: HTML REPORT
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  STEP 4: GENERATE REPORT" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green

$daysLeft = [math]::Max(0, (([datetime]"2026-02-09") - (Get-Date)).Days)

# Build upgrade rows
$upgradeRows = ""
foreach ($r in $results) {
    $sc = switch ($r.Status) { "UPGRADED" { "#22c55e" } "FAILED" { "#ef4444" } "PROTECTED" { "#3b82f6" } default { "#f59e0b" } }
    $bg = if ($r.Status -eq "FAILED") { "background:#450a0a;" } elseif ($r.Status -eq "UPGRADED") { "background:#052e16;" } else { "" }
    $errCol = if ($r.Error) { "<td style='color:#ef4444;font-size:10px'>$($r.Error)</td>" } else { "<td></td>" }
    $upgradeRows += "<tr style='$bg'><td>$($r.Server)</td><td style='font-weight:bold'>$($r.DB)</td><td>$($r.From)</td><td style='color:#22c55e;font-weight:bold'>$($r.To)</td><td style='color:#f59e0b'>$($r.MaxDTU)%</td><td style='color:$sc;font-weight:bold'>$($r.Status)</td>$errCol</tr>"
}

# Build needs upgrade rows (all DBs that were identified)
$needsRows = ""
foreach ($db in ($needsUpgrade | Sort-Object MaxDTU -Descending)) {
    $needsRows += "<tr><td>$($db.Server)</td><td style='font-weight:bold;color:#fca5a5'>$($db.DB)</td><td>$($db.SKU)</td><td style='color:#ef4444;font-weight:bold'>$($db.MaxDTU)%</td><td>$($db.AvgDTU)%</td><td style='color:#22c55e'>$($db.RecTier)</td></tr>"
}

# Build protected rows
$protRows = ""
foreach ($db in $protectedList) {
    $protRows += "<tr style='background:#172554;'><td>$($db.Server)</td><td style='font-weight:bold;color:#60a5fa'>$($db.DB)</td><td>$($db.SKU)</td><td>$($db.MaxDTU)%</td><td>$($db.AvgDTU)%</td><td>Robert fixed - PyxIQ</td></tr>"
}

# Build all DBs rows
$allRows = ""
foreach ($db in ($allDbs | Sort-Object MaxDTU -Descending)) {
    $sc = switch ($db.Status) { "NEEDS UPGRADE" { "#ef4444" } "PROTECTED" { "#3b82f6" } default { "#64748b" } }
    $bg = switch ($db.Status) { "NEEDS UPGRADE" { "background:#450a0a;" } "PROTECTED" { "background:#172554;" } default { "" } }
    $allRows += "<tr style='$bg'><td>$($db.Sub)</td><td>$($db.Server)</td><td>$($db.DB)</td><td>$($db.SKU)</td><td>$($db.MaxDTU)%</td><td>$($db.AvgDTU)%</td><td style='color:$sc'>$($db.Status)</td></tr>"
}

$modeText = if ($DryRun) { "DRY RUN" } else { "EXECUTED" }
$statusText = if ($failed -eq 0 -and $upgraded -gt 0) { "SUCCESS" } elseif ($failed -gt 0) { "PARTIAL" } else { "NO CHANGES" }
$statusColor = if ($failed -eq 0) { "#22c55e" } else { "#f59e0b" }

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>RECOVERY Report - $(Get-Date -Format 'yyyy-MM-dd')</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',sans-serif;background:#0f172a;color:#e2e8f0;padding:20px}
.ctr{max-width:1500px;margin:0 auto}
.hdr{background:linear-gradient(135deg,#7f1d1d,#991b1b);border-radius:12px;padding:25px;margin-bottom:15px;border:2px solid #ef4444}
h1{font-size:24px;color:#fff;margin-bottom:4px}
.sub{color:#fca5a5;font-size:12px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin-bottom:15px}
.card{background:#1e293b;border-radius:10px;padding:14px;border:1px solid #334155;text-align:center}
.card h3{font-size:10px;color:#94a3b8;text-transform:uppercase;margin-bottom:5px}
.card .v{font-size:26px;font-weight:700}
.card .s{font-size:10px;color:#64748b;margin-top:2px}
.sec{background:#1e293b;border-radius:10px;padding:16px;margin-bottom:12px;border:1px solid #334155}
.sec h2{font-size:15px;color:#f1f5f9;margin-bottom:10px;padding-bottom:8px;border-bottom:1px solid #334155}
table{width:100%;border-collapse:collapse;font-size:11px}
th{background:#0f172a;color:#94a3b8;padding:8px;text-align:left;font-weight:600;text-transform:uppercase;font-size:9px;position:sticky;top:0}
td{padding:6px 8px;border-bottom:1px solid #1e293b}
tr:hover{background:#334155}
.warn{background:#7f1d1d;border:2px solid #ef4444;border-radius:12px;padding:16px;margin-bottom:12px}
.info{background:#172554;border:2px solid #3b82f6;border-radius:12px;padding:16px;margin-bottom:12px}
.ft{text-align:center;color:#475569;font-size:10px;margin-top:15px}
</style>
</head>
<body>
<div class="ctr">

<div class="hdr">
<h1>EMERGENCY RECOVERY REPORT - UPGRADE ONLY</h1>
<p class="sub">Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | Mode: $modeText | Status: <span style="color:$statusColor">$statusText</span></p>
<p style="margin-top:8px;color:#fef2f2">NO DOWNGRADES - Only upgrading databases that are struggling with high DTU</p>
</div>

<div class="warn">
<h2 style="color:#fca5a5;margin-bottom:8px">OUTAGE RECOVERY MODE</h2>
<p style="color:#fef2f2;font-size:12px">Previous changes caused an outage. This script ONLY upgrades struggling databases. No downgrades. No cost savings. Stability first.</p>
</div>

<div class="grid">
<div class="card"><h3>Total DBs</h3><div class="v" style="color:#60a5fa">$($allDbs.Count)</div></div>
<div class="card"><h3>Needed Upgrade</h3><div class="v" style="color:#ef4444">$($needsUpgrade.Count)</div><div class="s">>$UPGRADE_THRESHOLD% DTU</div></div>
<div class="card"><h3>Upgraded</h3><div class="v" style="color:#22c55e">$upgraded</div><div class="s">this run</div></div>
<div class="card"><h3>Failed</h3><div class="v" style="color:$(if($failed -gt 0){'#ef4444'}else{'#22c55e'})">$failed</div></div>
<div class="card"><h3>Protected</h3><div class="v" style="color:#3b82f6">$($protectedList.Count)</div><div class="s">Robert fixed</div></div>
<div class="card"><h3>OK</h3><div class="v" style="color:#64748b">$($okList.Count)</div><div class="s">no action</div></div>
<div class="card"><h3>MFA Deadline</h3><div class="v" style="color:#f59e0b">$daysLeft</div><div class="s">days left</div></div>
</div>

<div class="info">
<h2 style="color:#93c5fd;margin-bottom:8px">PROTECTED DATABASES - Robert's PyxIQ Fixes</h2>
<p style="color:#bfdbfe;font-size:11px;margin-bottom:10px">These were fixed by Robert for the PyxIQ outage. Script does NOT touch them.</p>
$(if ($protectedList.Count -gt 0) {
"<div style='max-height:200px;overflow-y:auto'>
<table>
<tr><th>Server</th><th>Database</th><th>SKU</th><th>Max DTU</th><th>Avg DTU</th><th>Note</th></tr>
$protRows
</table>
</div>"
} else { "<p style='color:#64748b'>No protected databases found in scan.</p>" })
</div>

$(if ($results.Count -gt 0) {
"<div class='sec' style='border:2px solid #22c55e'>
<h2 style='color:#22c55e'>UPGRADES APPLIED ($($results.Count) databases)</h2>
<div style='max-height:300px;overflow-y:auto'>
<table>
<tr><th>Server</th><th>Database</th><th>From</th><th>To</th><th>Max DTU</th><th>Status</th><th>Error</th></tr>
$upgradeRows
</table>
</div>
</div>"
})

$(if ($needsUpgrade.Count -gt 0) {
"<div class='sec' style='border:2px solid #ef4444'>
<h2 style='color:#ef4444'>HIGH DTU DATABASES ($($needsUpgrade.Count) identified)</h2>
<p style='color:#fca5a5;font-size:11px;margin-bottom:10px'>These databases had DTU > $UPGRADE_THRESHOLD% and needed more compute resources.</p>
<div style='max-height:300px;overflow-y:auto'>
<table>
<tr><th>Server</th><th>Database</th><th>Current SKU</th><th>Max DTU</th><th>Avg DTU</th><th>Recommended</th></tr>
$needsRows
</table>
</div>
</div>"
})

<div class="sec">
<h2>All Databases ($($allDbs.Count))</h2>
<div style="max-height:400px;overflow-y:auto">
<table>
<tr><th>Subscription</th><th>Server</th><th>Database</th><th>SKU</th><th>Max DTU</th><th>Avg DTU</th><th>Status</th></tr>
$allRows
</table>
</div>
</div>

<div class="sec">
<h2>Next Steps</h2>
<table>
<tr><th>#</th><th>Action</th><th>Priority</th></tr>
<tr><td>1</td><td><strong>Monitor upgraded databases</strong> - Watch for next 2 hours to confirm stability</td><td style="color:#ef4444;font-weight:bold">CRITICAL</td></tr>
<tr><td>2</td><td>Inform Tony/Robert that recovery script has run - $upgraded databases upgraded</td><td style="color:#ef4444;font-weight:bold">CRITICAL</td></tr>
$(if ($failed -gt 0) { "<tr><td>3</td><td>Review $failed failed upgrades - may need manual intervention</td><td style='color:#f59e0b;font-weight:bold'>HIGH</td></tr>" })
<tr><td>$(if($failed -gt 0){4}else{3})</td><td>DO NOT run any downgrade scripts until outage is fully resolved</td><td style="color:#f59e0b;font-weight:bold">HIGH</td></tr>
<tr><td>$(if($failed -gt 0){5}else{4})</td><td>MFA script - $daysLeft days until Feb 9 deadline</td><td style="color:#f59e0b">PENDING</td></tr>
</table>
</div>

<div class="ft">
<p>Emergency Recovery Report | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Mode: UPGRADE ONLY</p>
<p>Upgraded: $upgraded | Failed: $failed | Protected: $($protectedList.Count) | Total: $($allDbs.Count)</p>
</div>

</div>
</body>
</html>
"@

$reportFile = Join-Path $outDir "Recovery-Report.html"
$html | Out-File -FilePath $reportFile -Encoding UTF8
WL "Report: $reportFile" "Green"

# ================================================================
#  SUMMARY
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  RECOVERY COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  SCANNED:    $($allDbs.Count) databases" -ForegroundColor Cyan
Write-Host "  UPGRADED:   $upgraded" -ForegroundColor Green
Write-Host "  FAILED:     $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "  PROTECTED:  $($protectedList.Count) (Robert's fixes)" -ForegroundColor Blue
Write-Host "  SKIPPED:    $skipped" -ForegroundColor Gray
Write-Host ""
Write-Host "  REPORT: $reportFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "  IMPORTANT: NO downgrades were performed." -ForegroundColor Yellow
Write-Host "  IMPORTANT: Monitor upgraded DBs for stability." -ForegroundColor Yellow
Write-Host ""

try { Start-Process $reportFile } catch {}
