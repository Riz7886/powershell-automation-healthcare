param(
    [switch]$DryRun,
    [switch]$ScanOnly
)

$ErrorActionPreference = "Continue"
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$outDir = Join-Path $dir "SmartFix_$ts"
New-Item -Path $outDir -ItemType Directory -Force | Out-Null
$logFile = Join-Path $outDir "smartfix.log"

function WL { 
    param([string]$M,[string]$C="White")
    $stamp = Get-Date -Format 'HH:mm:ss'
    "[$stamp] $M" | Out-File -FilePath $logFile -Append -Encoding UTF8
    Write-Host "[$stamp] $M" -ForegroundColor $C 
}

$tenant = "8ef3d734-3ca5-4493-8d8b-52b2c54eab04"

# ================================================================
#  PROTECTED - Robert fixed these - DO NOT TOUCH
# ================================================================

$protectedServers = @("mycareloop")
$protectedDbs = @(
    "sqldb-aetna-prod","sqldb-healthchoice-prod","sqldb-uhc-prod",
    "sqldb-parkland-prod","sqldb-partners-qa","sqldb-pyx-central-ana",
    "sqldb-healthchoice-ana","sqldb-pyx-central-prod","sqldb-mbpr-ana",
    "sqldb-nbpr-ana","sqldb-lakeland-ana","sqldb-pyx-uhc-qa","Pyx-Health"
)

# ================================================================
#  SMART THRESHOLDS - Based on ACTUAL usage patterns
# ================================================================

# UPGRADE if: MaxDTU is high (database is struggling)
$UPGRADE_IF_MAX_DTU = 65      # Max DTU > 65% = needs more power

# DOWNGRADE only if: BOTH avg AND max are very low (truly unused)
$DOWNGRADE_IF_AVG_DTU = 15    # Avg DTU < 15%
$DOWNGRADE_IF_MAX_DTU = 35    # AND Max DTU < 35% (no spikes)

# CRITICAL = emergency upgrade needed
$CRITICAL_DTU = 90

# ================================================================
#  PRICING + TIERS
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

$tierOrder = @("Basic","S0","S1","S2","S3","S4","S6","S7","S9","S12")

function Get-TierIndex { param([string]$T); return [array]::IndexOf($tierOrder, $T) }

function Get-TierUp {
    param([string]$Current, [int]$Levels = 1)
    $idx = Get-TierIndex $Current
    if ($idx -lt 0) { return "S2" }
    $newIdx = [math]::Min($idx + $Levels, $tierOrder.Count - 1)
    return $tierOrder[$newIdx]
}

function Get-TierDown {
    param([string]$Current, [int]$Levels = 1)
    $idx = Get-TierIndex $Current
    if ($idx -le 0) { return "Basic" }
    $newIdx = [math]::Max($idx - $Levels, 0)
    return $tierOrder[$newIdx]
}

function Test-Protected {
    param([string]$Server, [string]$DbName)
    foreach ($ps in $protectedServers) { if ($Server -like "*$ps*") { return $true } }
    if ($protectedDbs -contains $DbName) { return $true }
    return $false
}

# ================================================================
#  SMART DECISION LOGIC
# ================================================================

function Get-SmartRecommendation {
    param(
        [string]$CurrentSKU,
        [double]$AvgDTU,
        [double]$MaxDTU,
        [double]$MaxSizeGB
    )
    
    $action = "NONE"
    $reason = "OK - within normal range"
    $recTier = $CurrentSKU
    
    # CRITICAL - Emergency upgrade
    if ($MaxDTU -ge $CRITICAL_DTU) {
        $action = "UPGRADE"
        $recTier = Get-TierUp -Current $CurrentSKU -Levels 2  # Jump 2 levels
        $reason = "CRITICAL: MaxDTU ${MaxDTU}% - database maxed out, needs immediate upgrade"
        return @{Action=$action; RecTier=$recTier; Reason=$reason; Priority="CRITICAL"}
    }
    
    # HIGH DTU - Needs upgrade
    if ($MaxDTU -ge $UPGRADE_IF_MAX_DTU) {
        $action = "UPGRADE"
        $recTier = Get-TierUp -Current $CurrentSKU -Levels 1
        $reason = "HIGH: MaxDTU ${MaxDTU}% - hitting limits during peak, needs more DTU"
        return @{Action=$action; RecTier=$recTier; Reason=$reason; Priority="HIGH"}
    }
    
    # LOW DTU - Can downgrade ONLY if BOTH avg AND max are low
    if ($AvgDTU -le $DOWNGRADE_IF_AVG_DTU -and $MaxDTU -le $DOWNGRADE_IF_MAX_DTU -and $AvgDTU -gt 0) {
        # Check if current tier is already Basic - can't go lower
        if ($CurrentSKU -eq "Basic") {
            $action = "NONE"
            $reason = "Already at Basic tier"
            return @{Action=$action; RecTier=$CurrentSKU; Reason=$reason; Priority="OK"}
        }
        
        # Check max size compatibility before recommending downgrade
        $downTier = Get-TierDown -Current $CurrentSKU -Levels 1
        $downInfo = $pricing[$downTier]
        
        if ($downInfo -and $MaxSizeGB -le $downInfo.MaxGB) {
            $action = "DOWNGRADE"
            $recTier = $downTier
            $reason = "LOW: AvgDTU ${AvgDTU}% MaxDTU ${MaxDTU}% - truly underutilized, safe to downgrade"
            return @{Action=$action; RecTier=$recTier; Reason=$reason; Priority="SAVINGS"}
        } else {
            $action = "NONE"
            $reason = "Low DTU but MaxSize ${MaxSizeGB}GB exceeds lower tier limit"
            return @{Action=$action; RecTier=$CurrentSKU; Reason=$reason; Priority="OK"}
        }
    }
    
    # MEDIUM - Leave alone (has spikes even if avg is low)
    if ($AvgDTU -le $DOWNGRADE_IF_AVG_DTU -and $MaxDTU -gt $DOWNGRADE_IF_MAX_DTU) {
        $action = "NONE"
        $reason = "KEEP: AvgDTU ${AvgDTU}% but MaxDTU ${MaxDTU}% - has usage spikes, don't downgrade"
        return @{Action=$action; RecTier=$CurrentSKU; Reason=$reason; Priority="CAUTION"}
    }
    
    return @{Action=$action; RecTier=$recTier; Reason=$reason; Priority="OK"}
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  SMART AUTO-FIX - Intelligent DTU Optimization" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  LOGIC:" -ForegroundColor Yellow
Write-Host "    UPGRADE if MaxDTU > $UPGRADE_IF_MAX_DTU% (database struggling)" -ForegroundColor Red
Write-Host "    DOWNGRADE only if AvgDTU < $DOWNGRADE_IF_AVG_DTU% AND MaxDTU < $DOWNGRADE_IF_MAX_DTU% (truly unused)" -ForegroundColor Green
Write-Host "    KEEP if low avg but high spikes (needs headroom)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  PROTECTED: $($protectedServers -join ', ') + $($protectedDbs.Count) specific DBs" -ForegroundColor Blue
Write-Host ""
if ($DryRun) { Write-Host "  *** DRY RUN - No changes ***" -ForegroundColor Magenta; Write-Host "" }
if ($ScanOnly) { Write-Host "  *** SCAN ONLY - Report only ***" -ForegroundColor Yellow; Write-Host "" }

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
#  STEP 2: SCAN ALL DATABASES + DTU METRICS
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  STEP 2: SCAN ALL DATABASES + ANALYZE DTU" -ForegroundColor Cyan
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
            
            # Get DTU metrics (last 1 hour)
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
            
            # Get smart recommendation
            $rec = Get-SmartRecommendation -CurrentSKU $db.currentServiceObjectiveName -AvgDTU $avgDTU -MaxDTU $maxDTU -MaxSizeGB $maxGB
            
            if ($protected) {
                $rec = @{Action="SKIP"; RecTier=$db.currentServiceObjectiveName; Reason="PROTECTED - Robert fixed"; Priority="PROTECTED"}
            }
            
            $curCost = if ($pricing[$db.currentServiceObjectiveName]) { $pricing[$db.currentServiceObjectiveName].P } else { 0 }
            $newCost = if ($pricing[$rec.RecTier]) { $pricing[$rec.RecTier].P } else { $curCost }
            $savings = [math]::Round($curCost - $newCost, 2)
            
            $allDbs += [PSCustomObject]@{
                Sub=$sub.name; SubId=$sub.id; Server=$srv.name; RG=$srv.resourceGroup
                DB=$db.name; SKU=$db.currentServiceObjectiveName; MaxSizeGB=$maxGB
                AvgDTU=$avgDTU; MaxDTU=$maxDTU
                Action=$rec.Action; RecTier=$rec.RecTier; Reason=$rec.Reason; Priority=$rec.Priority
                CurCost=$curCost; NewCost=$newCost; Savings=$savings
                Protected=$protected; DbStatus=$db.status
            }
        }
    }
    Write-Host " $dbCount DBs" -ForegroundColor Green
}

WL "Scanned $($allDbs.Count) databases" "Green"

# ================================================================
#  CATEGORIZE RESULTS
# ================================================================

$criticalDbs = @($allDbs | Where-Object { $_.Priority -eq "CRITICAL" })
$upgradeDbs = @($allDbs | Where-Object { $_.Action -eq "UPGRADE" })
$downgradeDbs = @($allDbs | Where-Object { $_.Action -eq "DOWNGRADE" })
$keepDbs = @($allDbs | Where-Object { $_.Priority -eq "CAUTION" })
$protectedList = @($allDbs | Where-Object { $_.Priority -eq "PROTECTED" })
$okDbs = @($allDbs | Where-Object { $_.Action -eq "NONE" -and $_.Priority -eq "OK" })

$potentialSavings = [math]::Round(($downgradeDbs | Measure-Object -Property Savings -Sum).Sum, 2)
$upgradesCost = [math]::Round(($upgradeDbs | ForEach-Object { $_.NewCost - $_.CurCost } | Measure-Object -Sum).Sum, 2)

Write-Host ""
Write-Host "  SMART ANALYSIS RESULTS:" -ForegroundColor Cyan
Write-Host "    CRITICAL (>$CRITICAL_DTU% max):    $($criticalDbs.Count)" -ForegroundColor Red
Write-Host "    NEED UPGRADE (>$UPGRADE_IF_MAX_DTU% max): $($upgradeDbs.Count)" -ForegroundColor Yellow
Write-Host "    KEEP AS-IS (has spikes):    $($keepDbs.Count)" -ForegroundColor DarkYellow
Write-Host "    CAN DOWNGRADE (truly low):  $($downgradeDbs.Count)" -ForegroundColor Green
Write-Host "    PROTECTED (Robert fixed):   $($protectedList.Count)" -ForegroundColor Blue
Write-Host "    OK (no change needed):      $($okDbs.Count)" -ForegroundColor Gray
Write-Host ""
Write-Host "    Potential savings from downgrades: `$$potentialSavings/mo" -ForegroundColor Green
Write-Host "    Cost increase from upgrades:       `$$upgradesCost/mo" -ForegroundColor Yellow
Write-Host ""

# Export scan
$scanCsv = Join-Path $outDir "SmartAnalysis.csv"
$allDbs | Export-Csv -Path $scanCsv -NoTypeInformation -Encoding UTF8
WL "Analysis CSV: $scanCsv" "Cyan"

# ================================================================
#  STEP 3: APPLY CHANGES (Upgrades first, then downgrades)
# ================================================================

$results = @()
$totalUpgraded = 0
$totalDowngraded = 0
$totalFailed = 0
$totalSkipped = 0
$actualSavings = 0
$actualCostIncrease = 0

if (-not $ScanOnly) {
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "  STEP 3: APPLY SMART CHANGES" -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host ""
    
    # UPGRADES FIRST (critical/high DTU databases)
    if ($upgradeDbs.Count -gt 0) {
        Write-Host "  === UPGRADES ($($upgradeDbs.Count)) - Priority: Fix struggling DBs ===" -ForegroundColor Yellow
        Write-Host ""
        
        $currentSub = ""
        $counter = 0
        
        foreach ($db in ($upgradeDbs | Sort-Object MaxDTU -Descending)) {
            $counter++
            $key = "$($db.Server)/$($db.DB)"
            
            Write-Host "  [$counter/$($upgradeDbs.Count)] $key " -ForegroundColor Gray -NoNewline
            Write-Host "[$($db.SKU) Avg:$($db.AvgDTU)% Max:$($db.MaxDTU)%] " -ForegroundColor Yellow -NoNewline
            
            if ($DryRun) {
                Write-Host "-> $($db.RecTier) (DRY RUN)" -ForegroundColor Cyan
                $results += [PSCustomObject]@{Server=$db.Server;DB=$db.DB;From=$db.SKU;To=$db.RecTier;AvgDTU=$db.AvgDTU;MaxDTU=$db.MaxDTU;Action="UPGRADE";Status="DRY RUN";Reason=$db.Reason;Savings=$db.Savings;Error=""}
                $totalSkipped++
                continue
            }
            
            if ($currentSub -ne $db.SubId) {
                az account set --subscription $db.SubId 2>$null
                $currentSub = $db.SubId
            }
            
            $t = $pricing[$db.RecTier]
            if (-not $t) { Write-Host "SKIP" -ForegroundColor Gray; $totalSkipped++; continue }
            
            $updResult = az sql db update --server $db.Server --name $db.DB --resource-group $db.RG --subscription $db.SubId --edition $t.E --service-objective $t.O 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "-> $($db.RecTier) UPGRADED" -ForegroundColor Green
                $totalUpgraded++
                $actualCostIncrease += ($t.P - $db.CurCost)
                WL "UPGRADED: ${key} $($db.SKU) -> $($db.RecTier)" "Green"
                $results += [PSCustomObject]@{Server=$db.Server;DB=$db.DB;From=$db.SKU;To=$db.RecTier;AvgDTU=$db.AvgDTU;MaxDTU=$db.MaxDTU;Action="UPGRADE";Status="OK";Reason=$db.Reason;Savings=$db.Savings;Error=""}
            } else {
                $errMsg = ($updResult | Out-String).Trim()
                $shortErr = if ($errMsg.Length -gt 80) { $errMsg.Substring(0,80) } else { $errMsg }
                Write-Host "FAILED" -ForegroundColor Red
                $totalFailed++
                WL "FAILED: ${key} - $shortErr" "Red"
                $results += [PSCustomObject]@{Server=$db.Server;DB=$db.DB;From=$db.SKU;To=$db.RecTier;AvgDTU=$db.AvgDTU;MaxDTU=$db.MaxDTU;Action="UPGRADE";Status="FAILED";Reason=$db.Reason;Savings=0;Error=$shortErr}
            }
        }
        Write-Host ""
    }
    
    # DOWNGRADES (only truly underutilized)
    if ($downgradeDbs.Count -gt 0) {
        Write-Host "  === DOWNGRADES ($($downgradeDbs.Count)) - Safe cost savings ===" -ForegroundColor Green
        Write-Host ""
        
        $currentSub = ""
        $counter = 0
        
        foreach ($db in ($downgradeDbs | Sort-Object AvgDTU)) {
            $counter++
            $key = "$($db.Server)/$($db.DB)"
            
            Write-Host "  [$counter/$($downgradeDbs.Count)] $key " -ForegroundColor Gray -NoNewline
            Write-Host "[$($db.SKU) Avg:$($db.AvgDTU)% Max:$($db.MaxDTU)%] " -ForegroundColor Green -NoNewline
            
            if ($DryRun) {
                Write-Host "-> $($db.RecTier) (DRY RUN)" -ForegroundColor Cyan
                $results += [PSCustomObject]@{Server=$db.Server;DB=$db.DB;From=$db.SKU;To=$db.RecTier;AvgDTU=$db.AvgDTU;MaxDTU=$db.MaxDTU;Action="DOWNGRADE";Status="DRY RUN";Reason=$db.Reason;Savings=$db.Savings;Error=""}
                $totalSkipped++
                continue
            }
            
            if ($currentSub -ne $db.SubId) {
                az account set --subscription $db.SubId 2>$null
                $currentSub = $db.SubId
            }
            
            $t = $pricing[$db.RecTier]
            if (-not $t) { Write-Host "SKIP" -ForegroundColor Gray; $totalSkipped++; continue }
            
            # Shrink max size if needed
            if ($db.MaxSizeGB -gt $t.MaxGB) {
                Write-Host "SHRINK " -ForegroundColor Cyan -NoNewline
                az sql db update --server $db.Server --name $db.DB --resource-group $db.RG --subscription $db.SubId --max-size "$($t.MaxGB)GB" 2>$null
            }
            
            $updResult = az sql db update --server $db.Server --name $db.DB --resource-group $db.RG --subscription $db.SubId --edition $t.E --service-objective $t.O 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "-> $($db.RecTier) SAVED `$$($db.Savings)/mo" -ForegroundColor Green
                $totalDowngraded++
                $actualSavings += $db.Savings
                WL "DOWNGRADED: ${key} $($db.SKU) -> $($db.RecTier) saved `$$($db.Savings)" "Green"
                $results += [PSCustomObject]@{Server=$db.Server;DB=$db.DB;From=$db.SKU;To=$db.RecTier;AvgDTU=$db.AvgDTU;MaxDTU=$db.MaxDTU;Action="DOWNGRADE";Status="OK";Reason=$db.Reason;Savings=$db.Savings;Error=""}
            } else {
                $errMsg = ($updResult | Out-String).Trim()
                $shortErr = if ($errMsg.Length -gt 80) { $errMsg.Substring(0,80) } else { $errMsg }
                Write-Host "FAILED" -ForegroundColor Red
                $totalFailed++
                WL "FAILED: ${key} - $shortErr" "Red"
                $results += [PSCustomObject]@{Server=$db.Server;DB=$db.DB;From=$db.SKU;To=$db.RecTier;AvgDTU=$db.AvgDTU;MaxDTU=$db.MaxDTU;Action="DOWNGRADE";Status="FAILED";Reason=$db.Reason;Savings=0;Error=$shortErr}
            }
        }
    }
}

# Export results
if ($results.Count -gt 0) {
    $resultsCsv = Join-Path $outDir "SmartFix_Results.csv"
    $results | Export-Csv -Path $resultsCsv -NoTypeInformation -Encoding UTF8
}

# ================================================================
#  STEP 4: HTML REPORT
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  STEP 4: GENERATE REPORT" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green

$daysLeft = [math]::Max(0, (([datetime]"2026-02-09") - (Get-Date)).Days)
$netSavings = [math]::Round($actualSavings - $actualCostIncrease, 2)

# Build critical/upgrade rows
$upgradeRows = ""
foreach ($db in ($upgradeDbs | Sort-Object MaxDTU -Descending)) {
    $bg = if ($db.Priority -eq "CRITICAL") { "background:#450a0a;" } else { "background:#451a03;" }
    $sc = if ($db.Priority -eq "CRITICAL") { "#ef4444" } else { "#f59e0b" }
    $upgradeRows += "<tr style='$bg'><td>$($db.Server)</td><td style='font-weight:bold'>$($db.DB)</td><td>$($db.SKU)</td><td style='color:$sc;font-weight:bold'>$($db.MaxDTU)%</td><td>$($db.AvgDTU)%</td><td style='color:#22c55e;font-weight:bold'>$($db.RecTier)</td><td style='font-size:10px'>$($db.Reason)</td></tr>"
}

# Build keep rows (has spikes)
$keepRows = ""
foreach ($db in ($keepDbs | Sort-Object MaxDTU -Descending)) {
    $keepRows += "<tr style='background:#422006;'><td>$($db.Server)</td><td style='font-weight:bold'>$($db.DB)</td><td>$($db.SKU)</td><td style='color:#f59e0b'>$($db.MaxDTU)%</td><td style='color:#22c55e'>$($db.AvgDTU)%</td><td style='font-size:10px'>$($db.Reason)</td></tr>"
}

# Build downgrade rows
$downRows = ""
foreach ($db in ($downgradeDbs | Sort-Object AvgDTU)) {
    $downRows += "<tr><td>$($db.Server)</td><td>$($db.DB)</td><td>$($db.SKU)</td><td>$($db.MaxDTU)%</td><td style='color:#22c55e'>$($db.AvgDTU)%</td><td style='color:#22c55e'>$($db.RecTier)</td><td style='color:#22c55e'>-`$$($db.Savings)/mo</td></tr>"
}

# Build protected rows
$protRows = ""
foreach ($db in $protectedList) {
    $protRows += "<tr style='background:#172554;'><td>$($db.Server)</td><td style='font-weight:bold;color:#60a5fa'>$($db.DB)</td><td>$($db.SKU)</td><td>$($db.MaxDTU)%</td><td>$($db.AvgDTU)%</td><td colspan='2'>Robert fixed - PyxIQ outage</td></tr>"
}

# Build results rows
$resultsRows = ""
foreach ($r in $results) {
    $sc = switch ($r.Status) { "OK" { "#22c55e" } "FAILED" { "#ef4444" } default { "#f59e0b" } }
    $bg = switch ($r.Status) { "OK" { if ($r.Action -eq "UPGRADE") { "background:#052e16;" } else { "" } } "FAILED" { "background:#450a0a;" } default { "" } }
    $errCol = if ($r.Error) { "<td style='color:#ef4444;font-size:9px'>$($r.Error)</td>" } else { "<td></td>" }
    $savCol = if ($r.Action -eq "DOWNGRADE" -and $r.Status -eq "OK") { "<td style='color:#22c55e'>-`$$($r.Savings)</td>" } elseif ($r.Action -eq "UPGRADE") { "<td style='color:#f59e0b'>+cost</td>" } else { "<td></td>" }
    $resultsRows += "<tr style='$bg'><td>$($r.Server)</td><td style='font-weight:bold'>$($r.DB)</td><td>$($r.From)</td><td style='color:#22c55e'>$($r.To)</td><td>$($r.MaxDTU)%</td><td>$($r.Action)</td><td style='color:$sc;font-weight:bold'>$($r.Status)</td>$savCol$errCol</tr>"
}

$modeText = if ($ScanOnly) { "SCAN ONLY" } elseif ($DryRun) { "DRY RUN" } else { "EXECUTED" }

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Smart Fix Report - $(Get-Date -Format 'yyyy-MM-dd')</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',sans-serif;background:#0f172a;color:#e2e8f0;padding:20px}
.ctr{max-width:1600px;margin:0 auto}
.hdr{background:linear-gradient(135deg,#1e3a5f,#1e40af);border-radius:12px;padding:25px;margin-bottom:15px;border:2px solid #3b82f6}
h1{font-size:24px;color:#fff}
.sub{color:#93c5fd;font-size:12px;margin-top:4px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:10px;margin-bottom:15px}
.card{background:#1e293b;border-radius:10px;padding:14px;border:1px solid #334155;text-align:center}
.card h3{font-size:9px;color:#94a3b8;text-transform:uppercase;margin-bottom:5px}
.card .v{font-size:24px;font-weight:700}
.card .s{font-size:9px;color:#64748b;margin-top:2px}
.sec{background:#1e293b;border-radius:10px;padding:16px;margin-bottom:12px;border:1px solid #334155}
.sec h2{font-size:14px;color:#f1f5f9;margin-bottom:10px;padding-bottom:8px;border-bottom:1px solid #334155}
table{width:100%;border-collapse:collapse;font-size:11px}
th{background:#0f172a;color:#94a3b8;padding:8px;text-align:left;font-weight:600;text-transform:uppercase;font-size:9px;position:sticky;top:0}
td{padding:5px 8px;border-bottom:1px solid #1e293b}
tr:hover{background:#334155}
.logic{background:#172554;border:2px solid #3b82f6;border-radius:12px;padding:16px;margin-bottom:12px}
.ban{border-radius:12px;padding:14px;margin-bottom:12px;text-align:center}
.ft{text-align:center;color:#475569;font-size:10px;margin-top:15px}
</style>
</head>
<body>
<div class="ctr">

<div class="hdr">
<h1>SMART AUTO-FIX REPORT</h1>
<p class="sub">Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | Mode: $modeText | Scanned: $($allDbs.Count) databases</p>
<p style="margin-top:8px;color:#86efac;font-weight:bold">Upgraded: $totalUpgraded | Downgraded: $totalDowngraded | Failed: $totalFailed | Protected: $($protectedList.Count)</p>
</div>

<div class="ban" style="background:linear-gradient(135deg,#dc2626,#ea580c)">
<h2 style="color:#fff;font-size:18px">MFA ENFORCEMENT: $daysLeft DAYS (Feb 9, 2026)</h2>
</div>

<div class="logic">
<h2 style="color:#93c5fd;margin-bottom:10px">SMART DECISION LOGIC</h2>
<table>
<tr><th>Condition</th><th>Action</th><th>Why</th></tr>
<tr><td style="color:#ef4444">MaxDTU > $CRITICAL_DTU%</td><td style="color:#ef4444;font-weight:bold">UPGRADE +2 tiers</td><td>Database maxed out - emergency upgrade</td></tr>
<tr><td style="color:#f59e0b">MaxDTU > $UPGRADE_IF_MAX_DTU%</td><td style="color:#f59e0b;font-weight:bold">UPGRADE +1 tier</td><td>Hitting limits during peaks - needs more headroom</td></tr>
<tr><td style="color:#fbbf24">AvgDTU < $DOWNGRADE_IF_AVG_DTU% but MaxDTU > $DOWNGRADE_IF_MAX_DTU%</td><td style="color:#fbbf24;font-weight:bold">KEEP AS-IS</td><td>Low average but has spikes - needs the headroom</td></tr>
<tr><td style="color:#22c55e">AvgDTU < $DOWNGRADE_IF_AVG_DTU% AND MaxDTU < $DOWNGRADE_IF_MAX_DTU%</td><td style="color:#22c55e;font-weight:bold">DOWNGRADE</td><td>Truly underutilized - safe to lower</td></tr>
</table>
</div>

<div class="grid">
<div class="card"><h3>Total DBs</h3><div class="v" style="color:#60a5fa">$($allDbs.Count)</div></div>
<div class="card"><h3>Critical</h3><div class="v" style="color:#ef4444">$($criticalDbs.Count)</div><div class="s">>$CRITICAL_DTU%</div></div>
<div class="card"><h3>Need Upgrade</h3><div class="v" style="color:#f59e0b">$($upgradeDbs.Count)</div><div class="s">>$UPGRADE_IF_MAX_DTU%</div></div>
<div class="card"><h3>Keep (Spikes)</h3><div class="v" style="color:#fbbf24">$($keepDbs.Count)</div><div class="s">has peaks</div></div>
<div class="card"><h3>Can Downgrade</h3><div class="v" style="color:#22c55e">$($downgradeDbs.Count)</div><div class="s">truly low</div></div>
<div class="card"><h3>Protected</h3><div class="v" style="color:#3b82f6">$($protectedList.Count)</div><div class="s">Robert</div></div>
<div class="card"><h3>Upgraded</h3><div class="v" style="color:#a855f7">$totalUpgraded</div></div>
<div class="card"><h3>Downgraded</h3><div class="v" style="color:#22c55e">$totalDowngraded</div></div>
<div class="card"><h3>Net Savings</h3><div class="v" style="color:$(if($netSavings -ge 0){'#22c55e'}else{'#f59e0b'})">`$$netSavings</div><div class="s">/mo</div></div>
</div>

$(if ($upgradeDbs.Count -gt 0) {
"<div class='sec' style='border:2px solid #ef4444'>
<h2 style='color:#ef4444'>NEED UPGRADE - High DTU ($($upgradeDbs.Count) databases)</h2>
<p style='color:#fca5a5;font-size:11px;margin-bottom:10px'>These databases are hitting their DTU limits and need more compute power to prevent timeouts.</p>
<div style='max-height:300px;overflow-y:auto'>
<table>
<tr><th>Server</th><th>Database</th><th>Current</th><th>Max DTU</th><th>Avg DTU</th><th>Upgrade To</th><th>Reason</th></tr>
$upgradeRows
</table>
</div>
</div>"
})

$(if ($keepDbs.Count -gt 0) {
"<div class='sec' style='border:2px solid #f59e0b'>
<h2 style='color:#f59e0b'>KEEP AS-IS - Has Spikes ($($keepDbs.Count) databases)</h2>
<p style='color:#fbbf24;font-size:11px;margin-bottom:10px'>These have low AVERAGE but high PEAK usage. They need the headroom for spikes - DO NOT downgrade.</p>
<div style='max-height:250px;overflow-y:auto'>
<table>
<tr><th>Server</th><th>Database</th><th>Current</th><th>Max DTU</th><th>Avg DTU</th><th>Reason</th></tr>
$keepRows
</table>
</div>
</div>"
})

$(if ($protectedList.Count -gt 0) {
"<div class='sec' style='border:2px solid #3b82f6'>
<h2 style='color:#3b82f6'>PROTECTED - Robert's Fixes ($($protectedList.Count) databases)</h2>
<p style='color:#93c5fd;font-size:11px;margin-bottom:10px'>These were fixed by Robert for the PyxIQ outage. Script does NOT touch them.</p>
<div style='max-height:200px;overflow-y:auto'>
<table>
<tr><th>Server</th><th>Database</th><th>SKU</th><th>Max DTU</th><th>Avg DTU</th><th colspan='2'>Note</th></tr>
$protRows
</table>
</div>
</div>"
})

$(if ($downgradeDbs.Count -gt 0) {
"<div class='sec' style='border:2px solid #22c55e'>
<h2 style='color:#22c55e'>SAFE TO DOWNGRADE - Truly Underutilized ($($downgradeDbs.Count) databases)</h2>
<p style='color:#86efac;font-size:11px;margin-bottom:10px'>These have BOTH low average AND low peak DTU. They are truly underutilized and safe to downgrade.</p>
<div style='max-height:300px;overflow-y:auto'>
<table>
<tr><th>Server</th><th>Database</th><th>Current</th><th>Max DTU</th><th>Avg DTU</th><th>Downgrade To</th><th>Savings</th></tr>
$downRows
</table>
</div>
</div>"
})

$(if ($results.Count -gt 0) {
"<div class='sec'>
<h2>Changes Applied This Run ($($results.Count) operations)</h2>
<div style='max-height:300px;overflow-y:auto'>
<table>
<tr><th>Server</th><th>Database</th><th>From</th><th>To</th><th>Max DTU</th><th>Action</th><th>Status</th><th>Savings</th><th>Error</th></tr>
$resultsRows
</table>
</div>
</div>"
})

<div class="sec">
<h2>Summary</h2>
<table>
<tr><th>Metric</th><th>Count/Value</th><th>Note</th></tr>
<tr><td>Total Databases</td><td style="font-weight:bold">$($allDbs.Count)</td><td>Scanned across all subscriptions</td></tr>
<tr><td>Upgraded (more DTU)</td><td style="color:#a855f7;font-weight:bold">$totalUpgraded</td><td>Fixed struggling databases</td></tr>
<tr><td>Downgraded (savings)</td><td style="color:#22c55e;font-weight:bold">$totalDowngraded</td><td>Truly underutilized only</td></tr>
<tr><td>Protected (untouched)</td><td style="color:#3b82f6;font-weight:bold">$($protectedList.Count)</td><td>Robert's PyxIQ fixes</td></tr>
<tr><td>Kept as-is (spikes)</td><td style="color:#fbbf24;font-weight:bold">$($keepDbs.Count)</td><td>Low avg but high peaks</td></tr>
<tr><td>Failed</td><td style="color:$(if($totalFailed -gt 0){'#ef4444'}else{'#22c55e'});font-weight:bold">$totalFailed</td><td>$(if($totalFailed -gt 0){'Need manual review'}else{'None!'})</td></tr>
<tr><td>Net Monthly Savings</td><td style="color:$(if($netSavings -ge 0){'#22c55e'}else{'#f59e0b'});font-weight:bold">`$$netSavings/mo</td><td>`$$([math]::Round($netSavings * 12, 2))/yr</td></tr>
</table>
</div>

<div class="ft">
<p>Smart Auto-Fix Report | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Mode: $modeText</p>
<p>Upgraded: $totalUpgraded | Downgraded: $totalDowngraded | Protected: $($protectedList.Count) | Net: `$$netSavings/mo</p>
</div>

</div>
</body>
</html>
"@

$reportFile = Join-Path $outDir "SmartFix-Report.html"
$html | Out-File -FilePath $reportFile -Encoding UTF8
WL "Report: $reportFile" "Green"

# ================================================================
#  SUMMARY
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  SMART FIX COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  SCANNED:     $($allDbs.Count) databases" -ForegroundColor Cyan
Write-Host "  UPGRADED:    $totalUpgraded (needed more DTU)" -ForegroundColor Magenta
Write-Host "  DOWNGRADED:  $totalDowngraded (truly underutilized)" -ForegroundColor Green
Write-Host "  KEPT AS-IS:  $($keepDbs.Count) (has spikes - needs headroom)" -ForegroundColor Yellow
Write-Host "  PROTECTED:   $($protectedList.Count) (Robert's fixes)" -ForegroundColor Blue
Write-Host "  FAILED:      $totalFailed" -ForegroundColor $(if ($totalFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""
Write-Host "  NET SAVINGS: `$$netSavings/mo (`$$([math]::Round($netSavings * 12, 2))/yr)" -ForegroundColor $(if ($netSavings -ge 0) { "Green" } else { "Yellow" })
Write-Host ""
Write-Host "  REPORT: $reportFile" -ForegroundColor Cyan
Write-Host ""

try { Start-Process $reportFile } catch {}
