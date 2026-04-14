# ============================================================================
# VANTA HITRUST r2 EVIDENCE COLLECTOR V2 - PYX HEALTH
# ============================================================================
# Author:    Syed Rizvi
# Date:      2026-04-14
# Version:   2.0 - Tony-Grade Evidence Documents
# Purpose:   Collect DEEP evidence for 4 failing Vanta HITRUST r2 tests
#            and generate INDIVIDUAL formal evidence documents per test.
#
# Generates 4 separate evidence HTMLs (one per failing test):
#   1. SQL-CPU-Evidence.html        — 180 databases, CPU alert + metric data
#   2. SQL-Memory-Evidence.html     — 180 databases, memory/DTU alert + metrics
#   3. VM-CPU-Evidence.html         — 15 VMs, CPU alert + 24h metric data
#   4. VM-SSH-NSG-Evidence.html     — SSH rules + NSG attachment evidence
#
# Plus 1 master summary:
#   5. HITRUST-Master-Evidence.html — Executive summary linking all 4
#
# Safety:    100% READ-ONLY. This script NEVER modifies anything.
# ============================================================================

param(
    [string]$OutputDir = "$PSScriptRoot\Vanta-Evidence-$(Get-Date -Format 'yyyy-MM-dd')",
    [string]$AuthorName = "Syed Rizvi",
    [string]$AuthorTitle = "Infrastructure & Security Architect",
    [string]$Organization = "PYX Health",
    [string]$EnvironmentName = "",
    [int]$MetricHoursBack = 24
)

$ErrorActionPreference = "Continue"
$startTime = Get-Date

# Create output directory
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# ============================================================================
# BANNER
# ============================================================================
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  VANTA HITRUST r2 EVIDENCE COLLECTOR V2" -ForegroundColor Cyan
Write-Host "  Organization: $Organization" -ForegroundColor Cyan
Write-Host "  Author: $AuthorName" -ForegroundColor Cyan
Write-Host "  Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "  Mode: READ-ONLY (Evidence Collection Only)" -ForegroundColor Green
Write-Host "  Output: $OutputDir" -ForegroundColor Green
Write-Host "  Metric Lookback: ${MetricHoursBack}h" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# SHARED HTML FUNCTIONS
# ============================================================================
function Get-EvidenceHtmlHeader {
    param([string]$Title, [string]$HitrustControl, [string]$HitrustReq, [string]$VantaTestName, [int]$ItemCount)
    $envLabel = if ($EnvironmentName) { " - $EnvironmentName" } else { "" }
    $dateStr = Get-Date -Format "MMMM dd, yyyy"
    $timeStr = Get-Date -Format "hh:mm tt"
    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>$Title - $Organization</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #f0f2f5; color: #333; font-size: 13px; }
.header { background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%); color: white; padding: 40px; }
.header h1 { font-size: 24px; margin-bottom: 5px; letter-spacing: 1px; }
.header h2 { font-size: 15px; font-weight: 400; opacity: 0.85; margin-bottom: 15px; }
.header .meta { display: flex; flex-wrap: wrap; gap: 20px; font-size: 12px; opacity: 0.9; }
.header .meta strong { color: #00bcf2; }
.confidential { background: #d13438; color: white; text-align: center; padding: 8px; font-size: 12px; font-weight: bold; letter-spacing: 2px; }
.container { max-width: 1400px; margin: 20px auto; padding: 0 20px; }

/* HITRUST Control Box */
.hitrust-box { background: white; border-left: 5px solid #0f3460; border-radius: 8px; padding: 25px; margin-bottom: 20px; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
.hitrust-box h3 { font-size: 16px; color: #0f3460; margin-bottom: 12px; }
.hitrust-grid { display: grid; grid-template-columns: 180px 1fr; gap: 8px 15px; font-size: 13px; }
.hitrust-grid .label { font-weight: 600; color: #555; }
.hitrust-grid .value { color: #333; }

/* Scoring */
.scoring-table { width: 100%; border-collapse: collapse; margin: 15px 0; }
.scoring-table th { background: #1a1a2e; color: white; padding: 10px; text-align: left; font-size: 11px; text-transform: uppercase; }
.scoring-table td { padding: 8px 10px; border-bottom: 1px solid #eee; font-size: 12px; }
.scoring-table tr:nth-child(even) { background: #f8f9fa; }
.score-5 { color: #107c10; font-weight: bold; }
.score-4 { color: #2d7d2d; font-weight: bold; }
.score-3 { color: #8a6d3b; font-weight: bold; }
.score-2 { color: #ca5010; font-weight: bold; }
.score-1 { color: #d13438; font-weight: bold; }

/* Summary Cards */
.summary-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; margin-bottom: 20px; }
.card { background: white; border-radius: 10px; padding: 18px; text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
.card .num { font-size: 36px; font-weight: bold; }
.card .lbl { font-size: 10px; color: #666; text-transform: uppercase; letter-spacing: 1px; margin-top: 5px; }
.card.pass { border-top: 4px solid #107c10; } .card.pass .num { color: #107c10; }
.card.fail { border-top: 4px solid #d13438; } .card.fail .num { color: #d13438; }
.card.total { border-top: 4px solid #0078d4; } .card.total .num { color: #0078d4; }
.card.rate { border-top: 4px solid #8764b8; } .card.rate .num { color: #8764b8; }
.card.metric { border-top: 4px solid #00bcf2; } .card.metric .num { color: #00bcf2; }

/* Evidence Table */
.section { margin-bottom: 20px; }
.section-header { background: #1a1a2e; color: white; padding: 12px 20px; border-radius: 8px 8px 0 0; display: flex; justify-content: space-between; align-items: center; }
.section-header h3 { font-size: 14px; }
.badge { padding: 4px 12px; border-radius: 20px; font-size: 11px; font-weight: bold; }
.badge-pass { background: #dff6dd; color: #107c10; }
.badge-fail { background: #fde7e9; color: #d13438; }
.badge-mixed { background: #fff4ce; color: #8a6d3b; }
table { width: 100%; border-collapse: collapse; background: white; border-radius: 0 0 8px 8px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
th { background: #f3f3f3; padding: 10px 12px; text-align: left; font-size: 11px; text-transform: uppercase; color: #555; border-bottom: 2px solid #e0e0e0; }
td { padding: 8px 12px; border-bottom: 1px solid #eee; font-size: 12px; vertical-align: top; }
tr:hover { background: #f8f9fa; }
.status-PASS { background: #dff6dd; color: #107c10; font-weight: bold; padding: 3px 10px; border-radius: 4px; display: inline-block; font-size: 11px; }
.status-FAIL { background: #fde7e9; color: #d13438; font-weight: bold; padding: 3px 10px; border-radius: 4px; display: inline-block; font-size: 11px; }
.detail-cell { max-width: 350px; word-wrap: break-word; font-family: 'Cascadia Code', Consolas, monospace; font-size: 11px; color: #555; background: #fafafa; padding: 6px; border-radius: 4px; }
.metric-cell { font-family: 'Cascadia Code', Consolas, monospace; font-size: 11px; }
.metric-val { font-weight: bold; }
.metric-high { color: #d13438; }
.metric-ok { color: #107c10; }

/* Remediation Box */
.remediation { background: #fff3cd; border-left: 5px solid #ffc107; border-radius: 8px; padding: 20px; margin: 20px 0; }
.remediation h3 { color: #856404; margin-bottom: 10px; }
.remediation code { background: #1a1a2e; color: #00ff41; padding: 2px 6px; border-radius: 3px; font-family: 'Cascadia Code', Consolas, monospace; font-size: 12px; }
.remediation pre { background: #1a1a2e; color: #00ff41; padding: 15px; border-radius: 6px; overflow-x: auto; margin: 10px 0; font-size: 12px; line-height: 1.5; }

/* Signature */
.sign-block { background: white; border-radius: 10px; padding: 30px; margin-top: 25px; box-shadow: 0 2px 8px rgba(0,0,0,0.06); display: grid; grid-template-columns: 1fr 1fr; gap: 30px; }
.sign-box { border-top: 2px solid #333; padding-top: 10px; }
.sign-box .name { font-weight: bold; font-size: 14px; }
.sign-box .title { color: #666; font-size: 12px; }
.footer { text-align: center; padding: 25px; color: #999; font-size: 11px; border-top: 1px solid #ddd; margin-top: 30px; }

@media print {
    body { background: white; font-size: 11px; }
    .container { max-width: 100%; }
    .confidential, .section-header, .header { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    .remediation { break-inside: avoid; }
}
</style>
</head>
<body>
<div class="header">
    <h1>$Title</h1>
    <h2>$Organization$envLabel - HITRUST r2 Compliance Evidence</h2>
    <div class="meta">
        <span>Date: <strong>$dateStr $timeStr</strong></span>
        <span>Author: <strong>$AuthorName, $AuthorTitle</strong></span>
        <span>Vanta Test: <strong>$VantaTestName</strong></span>
        <span>Items: <strong>$ItemCount</strong></span>
        <span>Tenant: <strong>$($script:currentTenant)</strong></span>
        <span>Subscriptions: <strong>$($script:allSubscriptions.Count)</strong></span>
    </div>
</div>
<div class="confidential">CONFIDENTIAL - HITRUST r2 COMPLIANCE EVIDENCE - FOR AUTHORIZED AUDITORS ONLY</div>
<div class="container">

<div class="hitrust-box">
    <h3>HITRUST CSF r2 Control Reference</h3>
    <div class="hitrust-grid">
        <span class="label">Control Domain:</span><span class="value">$HitrustControl</span>
        <span class="label">Requirement:</span><span class="value">$HitrustReq</span>
        <span class="label">Vanta Test:</span><span class="value">$VantaTestName</span>
        <span class="label">Assessment Type:</span><span class="value">r2 Validated Assessment</span>
        <span class="label">Maturity Level:</span><span class="value">Level 3 - Defined (Target: Level 5 - Optimized)</span>
        <span class="label">Evidence Type:</span><span class="value">Automated Technical Evidence (Azure PowerShell SDK)</span>
        <span class="label">Collection Date:</span><span class="value">$dateStr at $timeStr</span>
    </div>
</div>

<h3 style="margin:15px 0 5px;color:#1a1a2e;">HITRUST r2 Scoring Methodology</h3>
<table class="scoring-table">
    <tr><th>Level</th><th>Maturity</th><th>Policy</th><th>Process</th><th>Implemented</th><th>Measured</th><th>Managed</th></tr>
    <tr><td class="score-1">1</td><td>Ad Hoc</td><td>Informal</td><td>Inconsistent</td><td>Partial</td><td>None</td><td>None</td></tr>
    <tr><td class="score-2">2</td><td>Repeatable</td><td>Documented</td><td>Planned</td><td>Some</td><td>Informal</td><td>Reactive</td></tr>
    <tr><td class="score-3">3</td><td>Defined</td><td>Approved</td><td>Defined</td><td>Substantial</td><td>Defined</td><td>Proactive</td></tr>
    <tr><td class="score-4">4</td><td>Managed</td><td>Communicated</td><td>Monitored</td><td>Full</td><td>Quantitative</td><td>Optimized</td></tr>
    <tr><td class="score-5">5</td><td>Optimized</td><td>Enforced</td><td>Continuous</td><td>Verified</td><td>Automated</td><td>Adaptive</td></tr>
</table>

"@
}

function Get-EvidenceHtmlFooter {
    $dateStr = Get-Date -Format "MMMM dd, yyyy"
    $timeStr = Get-Date -Format "hh:mm tt"
    return @"

<div class="sign-block">
    <div class="sign-box">
        <div class="name">$AuthorName</div>
        <div class="title">$AuthorTitle - $Organization</div>
        <div style="margin-top:8px;color:#999;font-size:11px;">Evidence collected: $dateStr at $timeStr</div>
        <div style="margin-top:4px;color:#999;font-size:11px;">Method: Azure PowerShell SDK (Read-Only)</div>
    </div>
    <div class="sign-box">
        <div class="name">Reviewed By: Tony Schlak</div>
        <div class="title">Director of IT - $Organization</div>
        <div style="margin-top:8px;color:#999;font-size:11px;">Review date: ___________________</div>
        <div style="margin-top:4px;color:#999;font-size:11px;">Signature: ___________________</div>
    </div>
</div>
</div>
<div class="footer">
    HITRUST r2 Compliance Evidence | $Organization | $dateStr $timeStr<br>
    Generated via Azure PowerShell SDK (read-only) by $AuthorName | Document ID: $(New-Guid)<br>
    This evidence document is intended for upload to Vanta compliance platform.
</div>
</body></html>
"@
}

function Get-SafeMetric {
    param([string]$ResourceId, [string]$MetricName, [int]$HoursBack)
    try {
        $endTime = Get-Date
        $startTimeMetric = $endTime.AddHours(-$HoursBack)
        $metric = Get-AzMetric -ResourceId $ResourceId -MetricName $MetricName `
            -StartTime $startTimeMetric -EndTime $endTime `
            -TimeGrain 01:00:00 -AggregationType Average -ErrorAction SilentlyContinue

        if ($metric -and $metric.Data) {
            $values = $metric.Data | Where-Object { $null -ne $_.Average } | Select-Object -Property Timestamp, Average
            $avg = ($values | Measure-Object -Property Average -Average).Average
            $max = ($values | Measure-Object -Property Average -Maximum).Maximum
            $min = ($values | Measure-Object -Property Average -Minimum).Minimum
            $dataPoints = $values.Count
            return @{
                Available  = $true
                Average    = [math]::Round($avg, 2)
                Maximum    = [math]::Round($max, 2)
                Minimum    = [math]::Round($min, 2)
                DataPoints = $dataPoints
                Values     = $values
            }
        }
    } catch {}
    return @{ Available = $false; Average = "N/A"; Maximum = "N/A"; Minimum = "N/A"; DataPoints = 0; Values = @() }
}

# ============================================================================
# STEP 1: AZURE MODULES
# ============================================================================
Write-Host "[1/8] Loading Azure PowerShell modules..." -ForegroundColor Yellow

$requiredModules = @("Az.Accounts", "Az.Resources", "Az.Sql", "Az.Compute", "Az.Monitor", "Az.Network")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod -ErrorAction SilentlyContinue)) {
        Write-Host "  Installing $mod..." -ForegroundColor Yellow
        Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber -ErrorAction SilentlyContinue
    }
    Import-Module $mod -ErrorAction SilentlyContinue
}
Write-Host "  OK: All modules loaded" -ForegroundColor Green

# ============================================================================
# STEP 2: CONNECT TO AZURE (ALL SUBSCRIPTIONS)
# ============================================================================
Write-Host ""
Write-Host "[2/8] Connecting to Azure (all subscriptions via app tenant)..." -ForegroundColor Yellow

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Connect-AzAccount
    $context = Get-AzContext
}
$script:currentUser = $context.Account.Id
$script:currentTenant = $context.Tenant.Id
Write-Host "  Connected as: $($script:currentUser)" -ForegroundColor Green
Write-Host "  Tenant: $($script:currentTenant)" -ForegroundColor Green

$script:allSubscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
Write-Host "  Subscriptions: $($script:allSubscriptions.Count)" -ForegroundColor Green
foreach ($sub in $script:allSubscriptions) {
    Write-Host "    - $($sub.Name) ($($sub.Id))" -ForegroundColor White
}

# ============================================================================
# STEP 3: COLLECT SQL DATABASE CPU EVIDENCE (Test 1 of 4)
# ============================================================================
Write-Host ""
Write-Host "[3/8] TEST 1: SQL Database CPU Monitoring Evidence..." -ForegroundColor Yellow
Write-Host "  Collecting alert rules + actual CPU metric data (${MetricHoursBack}h lookback)..." -ForegroundColor White

$sqlCpuEvidence = [System.Collections.ArrayList]@()
$sqlCpuCount = 0

foreach ($sub in $script:allSubscriptions) {
    Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
    $subName = $sub.Name

    $sqlServers = Get-AzSqlServer -ErrorAction SilentlyContinue
    if (-not $sqlServers) { continue }

    foreach ($server in $sqlServers) {
        $databases = Get-AzSqlDatabase -ResourceGroupName $server.ResourceGroupName `
            -ServerName $server.ServerName -ErrorAction SilentlyContinue |
            Where-Object { $_.DatabaseName -ne "master" }

        foreach ($db in $databases) {
            $sqlCpuCount++
            $dbName = $db.DatabaseName
            $rg = $db.ResourceGroupName
            $resourceId = $db.ResourceId

            # Check for CPU alert rule
            $existingAlerts = @()
            try { $existingAlerts = Get-AzMetricAlertRuleV2 -ResourceGroupName $rg -ErrorAction SilentlyContinue } catch {}

            $cpuAlert = $existingAlerts | Where-Object {
                ($_.Name -like "*$dbName*cpu*" -or $_.Name -like "*cpu*$dbName*" -or
                 ($_.TargetResourceId -eq $resourceId -and $_.Criteria.MetricName -contains "cpu_percent"))
            }

            # Get actual CPU metric data
            $cpuMetric = Get-SafeMetric -ResourceId $resourceId -MetricName "cpu_percent" -HoursBack $MetricHoursBack

            $status = if ($cpuAlert) { "PASS" } else { "FAIL" }

            $alertDetail = if ($cpuAlert) {
                "Alert: $($cpuAlert.Name) | Metric: cpu_percent | Threshold: $($cpuAlert.Criteria.Threshold)% | Window: $($cpuAlert.WindowSize) | Severity: $($cpuAlert.Severity) | Enabled: $($cpuAlert.Enabled)"
            } else {
                "NO alert rule configured for cpu_percent"
            }

            $null = $sqlCpuEvidence.Add([PSCustomObject]@{
                Subscription  = $subName
                ResourceGroup = $rg
                Server        = $server.ServerName
                Database      = $dbName
                Edition       = $db.Edition
                SKU           = $db.CurrentServiceObjectiveName
                ResourceId    = $resourceId
                Status        = $status
                AlertName     = if ($cpuAlert) { $cpuAlert.Name } else { "NONE" }
                AlertDetail   = $alertDetail
                MetricAvg     = $cpuMetric.Average
                MetricMax     = $cpuMetric.Maximum
                MetricMin     = $cpuMetric.Minimum
                MetricPoints  = $cpuMetric.DataPoints
                MetricAvail   = $cpuMetric.Available
            })

            $tag = if ($status -eq "PASS") { "PASS" } else { "FAIL" }
            $metricTag = if ($cpuMetric.Available) { "Avg:$($cpuMetric.Average)%" } else { "No metrics" }
            Write-Host "    [$sqlCpuCount] $($server.ServerName)/$dbName [$tag] [$metricTag]" -ForegroundColor $(if ($status -eq "PASS") { "Green" } else { "Red" })
        }
    }
}
Write-Host "  Total SQL Databases (CPU): $sqlCpuCount" -ForegroundColor Cyan

# ============================================================================
# STEP 4: COLLECT SQL DATABASE MEMORY/DTU EVIDENCE (Test 2 of 4)
# ============================================================================
Write-Host ""
Write-Host "[4/8] TEST 2: SQL Database Memory/DTU Monitoring Evidence..." -ForegroundColor Yellow

$sqlMemEvidence = [System.Collections.ArrayList]@()
$sqlMemCount = 0

foreach ($sub in $script:allSubscriptions) {
    Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
    $subName = $sub.Name

    $sqlServers = Get-AzSqlServer -ErrorAction SilentlyContinue
    if (-not $sqlServers) { continue }

    foreach ($server in $sqlServers) {
        $databases = Get-AzSqlDatabase -ResourceGroupName $server.ResourceGroupName `
            -ServerName $server.ServerName -ErrorAction SilentlyContinue |
            Where-Object { $_.DatabaseName -ne "master" }

        foreach ($db in $databases) {
            $sqlMemCount++
            $dbName = $db.DatabaseName
            $rg = $db.ResourceGroupName
            $resourceId = $db.ResourceId

            $existingAlerts = @()
            try { $existingAlerts = Get-AzMetricAlertRuleV2 -ResourceGroupName $rg -ErrorAction SilentlyContinue } catch {}

            $memAlert = $existingAlerts | Where-Object {
                ($_.Name -like "*$dbName*mem*" -or $_.Name -like "*$dbName*dtu*" -or
                 $_.Name -like "*$dbName*storage*" -or
                 ($_.TargetResourceId -eq $resourceId -and
                  ($_.Criteria.MetricName -contains "dtu_consumption_percent" -or
                   $_.Criteria.MetricName -contains "storage_percent")))
            }

            # Try DTU metric first, then storage_percent
            $memMetric = Get-SafeMetric -ResourceId $resourceId -MetricName "dtu_consumption_percent" -HoursBack $MetricHoursBack
            $metricUsed = "dtu_consumption_percent"
            if (-not $memMetric.Available) {
                $memMetric = Get-SafeMetric -ResourceId $resourceId -MetricName "storage_percent" -HoursBack $MetricHoursBack
                $metricUsed = "storage_percent"
            }

            $status = if ($memAlert) { "PASS" } else { "FAIL" }

            $alertDetail = if ($memAlert) {
                "Alert: $($memAlert.Name) | Metric: $($memAlert.Criteria.MetricName) | Threshold: $($memAlert.Criteria.Threshold)% | Window: $($memAlert.WindowSize) | Severity: $($memAlert.Severity)"
            } else {
                "NO alert rule configured for dtu_consumption_percent or storage_percent"
            }

            $null = $sqlMemEvidence.Add([PSCustomObject]@{
                Subscription  = $subName
                ResourceGroup = $rg
                Server        = $server.ServerName
                Database      = $dbName
                Edition       = $db.Edition
                SKU           = $db.CurrentServiceObjectiveName
                ResourceId    = $resourceId
                Status        = $status
                AlertName     = if ($memAlert) { $memAlert.Name } else { "NONE" }
                AlertDetail   = $alertDetail
                MetricName    = $metricUsed
                MetricAvg     = $memMetric.Average
                MetricMax     = $memMetric.Maximum
                MetricMin     = $memMetric.Minimum
                MetricPoints  = $memMetric.DataPoints
                MetricAvail   = $memMetric.Available
            })

            $tag = if ($status -eq "PASS") { "PASS" } else { "FAIL" }
            $metricTag = if ($memMetric.Available) { "Avg:$($memMetric.Average)% ($metricUsed)" } else { "No metrics" }
            Write-Host "    [$sqlMemCount] $($server.ServerName)/$dbName [$tag] [$metricTag]" -ForegroundColor $(if ($status -eq "PASS") { "Green" } else { "Red" })
        }
    }
}
Write-Host "  Total SQL Databases (Memory): $sqlMemCount" -ForegroundColor Cyan

# ============================================================================
# STEP 5: COLLECT VM CPU EVIDENCE (Test 3 of 4)
# ============================================================================
Write-Host ""
Write-Host "[5/8] TEST 3: VM CPU Monitoring Evidence..." -ForegroundColor Yellow
Write-Host "  Collecting alert rules + actual CPU metric data (${MetricHoursBack}h lookback)..." -ForegroundColor White

$vmCpuEvidence = [System.Collections.ArrayList]@()
$vmCpuCount = 0

foreach ($sub in $script:allSubscriptions) {
    Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
    $subName = $sub.Name

    $vms = Get-AzVM -ErrorAction SilentlyContinue
    if (-not $vms) { continue }

    foreach ($vm in $vms) {
        $vmCpuCount++
        $vmName = $vm.Name
        $rg = $vm.ResourceGroupName
        $resourceId = $vm.Id

        $existingAlerts = @()
        try { $existingAlerts = Get-AzMetricAlertRuleV2 -ResourceGroupName $rg -ErrorAction SilentlyContinue } catch {}

        $cpuAlert = $existingAlerts | Where-Object {
            ($_.Name -like "*$vmName*cpu*" -or $_.Name -like "*cpu*$vmName*" -or
             ($_.TargetResourceId -eq $resourceId -and $_.Criteria.MetricName -contains "Percentage CPU"))
        }

        # Get actual VM CPU metric
        $cpuMetric = Get-SafeMetric -ResourceId $resourceId -MetricName "Percentage CPU" -HoursBack $MetricHoursBack

        # Get VM power state
        $vmStatus = Get-AzVM -ResourceGroupName $rg -Name $vmName -Status -ErrorAction SilentlyContinue
        $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
        if (-not $powerState) { $powerState = "Unknown" }

        $status = if ($cpuAlert) { "PASS" } else { "FAIL" }

        $alertDetail = if ($cpuAlert) {
            "Alert: $($cpuAlert.Name) | Metric: Percentage CPU | Threshold: $($cpuAlert.Criteria.Threshold)% | Window: $($cpuAlert.WindowSize) | Severity: $($cpuAlert.Severity) | Enabled: $($cpuAlert.Enabled)"
        } else {
            "NO alert rule configured for Percentage CPU"
        }

        $null = $vmCpuEvidence.Add([PSCustomObject]@{
            Subscription  = $subName
            ResourceGroup = $rg
            VMName        = $vmName
            VMSize        = $vm.HardwareProfile.VmSize
            Location      = $vm.Location
            OS            = if ($vm.StorageProfile.OsDisk.OsType) { $vm.StorageProfile.OsDisk.OsType } else { "Unknown" }
            PowerState    = $powerState
            ResourceId    = $resourceId
            Status        = $status
            AlertName     = if ($cpuAlert) { $cpuAlert.Name } else { "NONE" }
            AlertDetail   = $alertDetail
            MetricAvg     = $cpuMetric.Average
            MetricMax     = $cpuMetric.Maximum
            MetricMin     = $cpuMetric.Minimum
            MetricPoints  = $cpuMetric.DataPoints
            MetricAvail   = $cpuMetric.Available
        })

        $tag = if ($status -eq "PASS") { "PASS" } else { "FAIL" }
        $metricTag = if ($cpuMetric.Available) { "Avg:$($cpuMetric.Average)%" } else { "No metrics" }
        Write-Host "    [$vmCpuCount] $vmName [$tag] [$metricTag] [$powerState]" -ForegroundColor $(if ($status -eq "PASS") { "Green" } else { "Red" })
    }
}
Write-Host "  Total VMs (CPU): $vmCpuCount" -ForegroundColor Cyan

# ============================================================================
# STEP 6: COLLECT VM SSH + NSG EVIDENCE (Test 4 of 4)
# ============================================================================
Write-Host ""
Write-Host "[6/8] TEST 4: VM SSH Denied + NSG Attachment Evidence..." -ForegroundColor Yellow

$vmSshEvidence = [System.Collections.ArrayList]@()
$vmSshCount = 0

foreach ($sub in $script:allSubscriptions) {
    Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
    $subName = $sub.Name

    $vms = Get-AzVM -ErrorAction SilentlyContinue
    if (-not $vms) { continue }

    foreach ($vm in $vms) {
        $vmSshCount++
        $vmName = $vm.Name
        $rg = $vm.ResourceGroupName
        $hasNsg = $false
        $sshOpen = $false
        $nicNsgName = "NONE"
        $subnetNsgName = "NONE"
        $allRules = [System.Collections.ArrayList]@()
        $sshRuleDetail = "No SSH rules found"
        $publicIps = @()

        foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
            $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id -ErrorAction SilentlyContinue

            # Check public IP
            if ($nic -and $nic.IpConfigurations) {
                foreach ($ipConfig in $nic.IpConfigurations) {
                    if ($ipConfig.PublicIpAddress) {
                        try {
                            $pip = Get-AzPublicIpAddress -Name ($ipConfig.PublicIpAddress.Id.Split('/')[-1]) `
                                -ResourceGroupName ($ipConfig.PublicIpAddress.Id.Split('/')[4]) -ErrorAction SilentlyContinue
                            if ($pip) { $publicIps += $pip.IpAddress }
                        } catch {}
                    }
                }
            }

            # NIC-level NSG
            if ($nic -and $nic.NetworkSecurityGroup) {
                $hasNsg = $true
                $nsgId = $nic.NetworkSecurityGroup.Id
                $nicNsgName = $nsgId.Split('/')[-1]
                $nsgRg = $nsgId.Split('/')[4]
                $nsgObj = Get-AzNetworkSecurityGroup -Name $nicNsgName -ResourceGroupName $nsgRg -ErrorAction SilentlyContinue

                if ($nsgObj) {
                    foreach ($rule in $nsgObj.SecurityRules) {
                        $null = $allRules.Add([PSCustomObject]@{
                            NSG       = $nicNsgName
                            Level     = "NIC"
                            Name      = $rule.Name
                            Priority  = $rule.Priority
                            Direction = $rule.Direction
                            Access    = $rule.Access
                            Protocol  = $rule.Protocol
                            SrcAddr   = $rule.SourceAddressPrefix -join ", "
                            SrcPort   = $rule.SourcePortRange -join ", "
                            DstAddr   = $rule.DestinationAddressPrefix -join ", "
                            DstPort   = $rule.DestinationPortRange -join ", "
                        })

                        if ($rule.Direction -eq "Inbound" -and $rule.Access -eq "Allow" -and
                            ($rule.DestinationPortRange -eq "22" -or $rule.DestinationPortRange -eq "*") -and
                            ($rule.SourceAddressPrefix -eq "*" -or $rule.SourceAddressPrefix -eq "0.0.0.0/0" -or
                             $rule.SourceAddressPrefix -eq "Internet" -or $rule.SourceAddressPrefix -eq "Any")) {
                            $sshOpen = $true
                            $sshRuleDetail = "Rule '$($rule.Name)' in NIC NSG '$nicNsgName' allows SSH from $($rule.SourceAddressPrefix)"
                        }
                    }
                }
            }

            # Subnet-level NSG
            if ($nic -and $nic.IpConfigurations) {
                foreach ($ipConfig in $nic.IpConfigurations) {
                    if ($ipConfig.Subnet) {
                        $subnetId = $ipConfig.Subnet.Id
                        $vnetName = $subnetId.Split('/')[8]
                        $subnetName = $subnetId.Split('/')[-1]
                        $vnetRg = $subnetId.Split('/')[4]
                        try {
                            $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRg -ErrorAction SilentlyContinue
                            $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
                            if ($subnet.NetworkSecurityGroup) {
                                $hasNsg = $true
                                $subNsgId = $subnet.NetworkSecurityGroup.Id
                                $subnetNsgName = $subNsgId.Split('/')[-1]
                                $subNsgRg = $subNsgId.Split('/')[4]
                                $subNsgObj = Get-AzNetworkSecurityGroup -Name $subnetNsgName -ResourceGroupName $subNsgRg -ErrorAction SilentlyContinue
                                if ($subNsgObj) {
                                    foreach ($rule in $subNsgObj.SecurityRules) {
                                        $null = $allRules.Add([PSCustomObject]@{
                                            NSG       = $subnetNsgName
                                            Level     = "Subnet"
                                            Name      = $rule.Name
                                            Priority  = $rule.Priority
                                            Direction = $rule.Direction
                                            Access    = $rule.Access
                                            Protocol  = $rule.Protocol
                                            SrcAddr   = $rule.SourceAddressPrefix -join ", "
                                            SrcPort   = $rule.SourcePortRange -join ", "
                                            DstAddr   = $rule.DestinationAddressPrefix -join ", "
                                            DstPort   = $rule.DestinationPortRange -join ", "
                                        })
                                        if ($rule.Direction -eq "Inbound" -and $rule.Access -eq "Allow" -and
                                            ($rule.DestinationPortRange -eq "22" -or $rule.DestinationPortRange -eq "*") -and
                                            ($rule.SourceAddressPrefix -eq "*" -or $rule.SourceAddressPrefix -eq "0.0.0.0/0" -or
                                             $rule.SourceAddressPrefix -eq "Internet")) {
                                            $sshOpen = $true
                                            $sshRuleDetail = "Subnet NSG '$subnetNsgName' rule '$($rule.Name)' allows SSH from internet"
                                        }
                                    }
                                }
                            }
                        } catch {}
                    }
                }
            }
        }

        $nsgStatus = if ($hasNsg) { "PASS" } else { "FAIL" }
        $sshStatus = if ($sshOpen) { "FAIL" } else { "PASS" }

        Write-Host "    [$vmSshCount] $vmName [NSG:$nsgStatus] [SSH:$sshStatus] PublicIP: $(if($publicIps){$publicIps -join ','}else{'None'})" -ForegroundColor $(if ($nsgStatus -eq "PASS" -and $sshStatus -eq "PASS") { "Green" } else { "Red" })

        $null = $vmSshEvidence.Add([PSCustomObject]@{
            Subscription  = $subName
            ResourceGroup = $rg
            VMName        = $vmName
            VMSize        = $vm.HardwareProfile.VmSize
            Location      = $vm.Location
            PublicIPs     = if ($publicIps) { $publicIps -join ", " } else { "None" }
            NicNSG        = $nicNsgName
            SubnetNSG     = $subnetNsgName
            HasNSG        = $hasNsg
            NSGStatus     = $nsgStatus
            SSHOpen       = $sshOpen
            SSHStatus     = $sshStatus
            SSHDetail     = $sshRuleDetail
            Rules         = $allRules
            ResourceId    = $vm.Id
        })
    }
}
Write-Host "  Total VMs (SSH/NSG): $vmSshCount" -ForegroundColor Cyan

# ============================================================================
# STEP 7: GENERATE 4 INDIVIDUAL EVIDENCE HTMLs
# ============================================================================
Write-Host ""
Write-Host "[7/8] Generating Evidence Documents..." -ForegroundColor Yellow

# ---- DOCUMENT 1: SQL CPU ----
$sqlCpuPass = ($sqlCpuEvidence | Where-Object { $_.Status -eq "PASS" }).Count
$sqlCpuFail = ($sqlCpuEvidence | Where-Object { $_.Status -eq "FAIL" }).Count
$sqlCpuRate = if ($sqlCpuCount -gt 0) { [math]::Round(($sqlCpuPass / $sqlCpuCount) * 100, 1) } else { 0 }

$doc1 = Get-EvidenceHtmlHeader -Title "SQL Database CPU Monitoring Evidence" `
    -HitrustControl "09.ab - Monitoring System Use | 09.ac - Protection of Log Information" `
    -HitrustReq "Database CPU utilization must be actively monitored with configured alert rules to detect performance degradation and potential denial-of-service conditions." `
    -VantaTestName "SQL database CPU monitored (Azure)" -ItemCount $sqlCpuCount

$doc1 += @"
<div class="summary-cards">
    <div class="card total"><div class="num">$sqlCpuCount</div><div class="lbl">SQL Databases</div></div>
    <div class="card pass"><div class="num">$sqlCpuPass</div><div class="lbl">Alert Configured</div></div>
    <div class="card fail"><div class="num">$sqlCpuFail</div><div class="lbl">No Alert</div></div>
    <div class="card rate"><div class="num">$sqlCpuRate%</div><div class="lbl">Compliance</div></div>
    <div class="card metric"><div class="num">${MetricHoursBack}h</div><div class="lbl">Metric Lookback</div></div>
</div>

<div class="section">
    <div class="section-header"><h3>SQL Database CPU Alert Evidence</h3><span class="badge $(if($sqlCpuFail -eq 0){'badge-pass'}elseif($sqlCpuPass -gt 0){'badge-mixed'}else{'badge-fail'})">$sqlCpuPass PASS / $sqlCpuFail FAIL</span></div>
    <table>
        <tr><th>#</th><th>Subscription</th><th>Server/Database</th><th>Edition</th><th>SKU</th><th>Status</th><th>Alert Rule</th><th>CPU Avg</th><th>CPU Max</th><th>Data Pts</th></tr>
"@

$i = 0
foreach ($item in $sqlCpuEvidence) {
    $i++
    $metricClass = if ($item.MetricAvail -and $item.MetricMax -ne "N/A" -and $item.MetricMax -gt 80) { "metric-high" } else { "metric-ok" }
    $doc1 += "<tr><td>$i</td><td>$($item.Subscription)</td><td><strong>$($item.Server)</strong>/$($item.Database)</td><td>$($item.Edition)</td><td>$($item.SKU)</td><td><span class='status-$($item.Status)'>$($item.Status)</span></td><td class='detail-cell'>$($item.AlertDetail)</td><td class='metric-cell'><span class='metric-val $metricClass'>$(if($item.MetricAvail){"$($item.MetricAvg)%"}else{"N/A"})</span></td><td class='metric-cell $metricClass'>$(if($item.MetricAvail){"$($item.MetricMax)%"}else{"N/A"})</td><td>$($item.MetricPoints)</td></tr>`n"
}

$doc1 += @"
    </table>
</div>

<div class="remediation">
    <h3>Remediation: Create CPU Alert Rules</h3>
    <p>Run <code>Vanta-Compliance-Remediation.ps1 -Mode Remediate</code> to auto-create alert rules for all databases missing CPU monitoring.</p>
    <p>Each alert monitors <code>cpu_percent > 80%</code> with a 5-minute evaluation window, Severity 2.</p>
    <pre>
# Manual remediation per database:
`$condition = New-AzMetricAlertRuleV2Criteria -MetricName "cpu_percent" ``
    -Operator GreaterThan -Threshold 80 -TimeAggregation Average
Add-AzMetricAlertRuleV2 -Name "cpu-alert-{dbName}" ``
    -ResourceGroupName "{rg}" ``
    -TargetResourceId "{resourceId}" ``
    -WindowSize 00:05:00 -Frequency 00:05:00 ``
    -Condition `$condition -Severity 2 -Description "HITRUST r2 - CPU monitoring"
    </pre>
</div>
"@

$doc1 += Get-EvidenceHtmlFooter
$doc1Path = Join-Path $OutputDir "1-SQL-CPU-Evidence.html"
$doc1 | Out-File -FilePath $doc1Path -Encoding utf8
Write-Host "  [1/4] SQL CPU Evidence: $doc1Path" -ForegroundColor Green

# ---- DOCUMENT 2: SQL Memory/DTU ----
$sqlMemPass = ($sqlMemEvidence | Where-Object { $_.Status -eq "PASS" }).Count
$sqlMemFail = ($sqlMemEvidence | Where-Object { $_.Status -eq "FAIL" }).Count
$sqlMemRate = if ($sqlMemCount -gt 0) { [math]::Round(($sqlMemPass / $sqlMemCount) * 100, 1) } else { 0 }

$doc2 = Get-EvidenceHtmlHeader -Title "SQL Database Memory/DTU Monitoring Evidence" `
    -HitrustControl "09.ab - Monitoring System Use | 09.ac - Protection of Log Information" `
    -HitrustReq "Database memory and DTU utilization must be actively monitored with configured alert rules to detect resource exhaustion." `
    -VantaTestName "SQL database memory utilization monitored (Azure)" -ItemCount $sqlMemCount

$doc2 += @"
<div class="summary-cards">
    <div class="card total"><div class="num">$sqlMemCount</div><div class="lbl">SQL Databases</div></div>
    <div class="card pass"><div class="num">$sqlMemPass</div><div class="lbl">Alert Configured</div></div>
    <div class="card fail"><div class="num">$sqlMemFail</div><div class="lbl">No Alert</div></div>
    <div class="card rate"><div class="num">$sqlMemRate%</div><div class="lbl">Compliance</div></div>
    <div class="card metric"><div class="num">${MetricHoursBack}h</div><div class="lbl">Metric Lookback</div></div>
</div>

<div class="section">
    <div class="section-header"><h3>SQL Database Memory/DTU Alert Evidence</h3><span class="badge $(if($sqlMemFail -eq 0){'badge-pass'}elseif($sqlMemPass -gt 0){'badge-mixed'}else{'badge-fail'})">$sqlMemPass PASS / $sqlMemFail FAIL</span></div>
    <table>
        <tr><th>#</th><th>Subscription</th><th>Server/Database</th><th>Edition</th><th>SKU</th><th>Status</th><th>Alert Rule</th><th>Metric</th><th>Avg</th><th>Max</th><th>Data Pts</th></tr>
"@

$i = 0
foreach ($item in $sqlMemEvidence) {
    $i++
    $metricClass = if ($item.MetricAvail -and $item.MetricMax -ne "N/A" -and $item.MetricMax -gt 85) { "metric-high" } else { "metric-ok" }
    $doc2 += "<tr><td>$i</td><td>$($item.Subscription)</td><td><strong>$($item.Server)</strong>/$($item.Database)</td><td>$($item.Edition)</td><td>$($item.SKU)</td><td><span class='status-$($item.Status)'>$($item.Status)</span></td><td class='detail-cell'>$($item.AlertDetail)</td><td>$($item.MetricName)</td><td class='metric-cell $metricClass'>$(if($item.MetricAvail){"$($item.MetricAvg)%"}else{"N/A"})</td><td class='metric-cell $metricClass'>$(if($item.MetricAvail){"$($item.MetricMax)%"}else{"N/A"})</td><td>$($item.MetricPoints)</td></tr>`n"
}

$doc2 += @"
    </table>
</div>

<div class="remediation">
    <h3>Remediation: Create Memory/DTU Alert Rules</h3>
    <p>Run <code>Vanta-Compliance-Remediation.ps1 -Mode Remediate</code> to auto-create alert rules.</p>
    <p>Each alert monitors <code>dtu_consumption_percent > 85%</code> or <code>storage_percent > 85%</code> with a 5-minute window.</p>
    <pre>
# Manual remediation per database:
`$condition = New-AzMetricAlertRuleV2Criteria -MetricName "dtu_consumption_percent" ``
    -Operator GreaterThan -Threshold 85 -TimeAggregation Average
Add-AzMetricAlertRuleV2 -Name "mem-alert-{dbName}" ``
    -ResourceGroupName "{rg}" ``
    -TargetResourceId "{resourceId}" ``
    -WindowSize 00:05:00 -Frequency 00:05:00 ``
    -Condition `$condition -Severity 2 -Description "HITRUST r2 - Memory/DTU monitoring"
    </pre>
</div>
"@

$doc2 += Get-EvidenceHtmlFooter
$doc2Path = Join-Path $OutputDir "2-SQL-Memory-Evidence.html"
$doc2 | Out-File -FilePath $doc2Path -Encoding utf8
Write-Host "  [2/4] SQL Memory Evidence: $doc2Path" -ForegroundColor Green

# ---- DOCUMENT 3: VM CPU ----
$vmCpuPass = ($vmCpuEvidence | Where-Object { $_.Status -eq "PASS" }).Count
$vmCpuFail = ($vmCpuEvidence | Where-Object { $_.Status -eq "FAIL" }).Count
$vmCpuRate = if ($vmCpuCount -gt 0) { [math]::Round(($vmCpuPass / $vmCpuCount) * 100, 1) } else { 0 }

$doc3 = Get-EvidenceHtmlHeader -Title "VM CPU Monitoring Evidence" `
    -HitrustControl "09.ab - Monitoring System Use | 09.ac - Protection of Log Information" `
    -HitrustReq "Virtual machine CPU utilization must be monitored with alert rules to detect performance anomalies and potential security incidents." `
    -VantaTestName "Azure virtual machine CPU monitored" -ItemCount $vmCpuCount

$doc3 += @"
<div class="summary-cards">
    <div class="card total"><div class="num">$vmCpuCount</div><div class="lbl">Virtual Machines</div></div>
    <div class="card pass"><div class="num">$vmCpuPass</div><div class="lbl">Alert Configured</div></div>
    <div class="card fail"><div class="num">$vmCpuFail</div><div class="lbl">No Alert</div></div>
    <div class="card rate"><div class="num">$vmCpuRate%</div><div class="lbl">Compliance</div></div>
    <div class="card metric"><div class="num">${MetricHoursBack}h</div><div class="lbl">Metric Lookback</div></div>
</div>

<div class="section">
    <div class="section-header"><h3>VM CPU Alert + Metric Evidence</h3><span class="badge $(if($vmCpuFail -eq 0){'badge-pass'}elseif($vmCpuPass -gt 0){'badge-mixed'}else{'badge-fail'})">$vmCpuPass PASS / $vmCpuFail FAIL</span></div>
    <table>
        <tr><th>#</th><th>Subscription</th><th>VM Name</th><th>Size</th><th>OS</th><th>Power State</th><th>Status</th><th>Alert Rule</th><th>CPU Avg</th><th>CPU Max</th><th>Data Pts</th></tr>
"@

$i = 0
foreach ($item in $vmCpuEvidence) {
    $i++
    $metricClass = if ($item.MetricAvail -and $item.MetricMax -ne "N/A" -and $item.MetricMax -gt 85) { "metric-high" } else { "metric-ok" }
    $doc3 += "<tr><td>$i</td><td>$($item.Subscription)</td><td><strong>$($item.VMName)</strong></td><td>$($item.VMSize)</td><td>$($item.OS)</td><td>$($item.PowerState)</td><td><span class='status-$($item.Status)'>$($item.Status)</span></td><td class='detail-cell'>$($item.AlertDetail)</td><td class='metric-cell $metricClass'>$(if($item.MetricAvail){"$($item.MetricAvg)%"}else{"N/A"})</td><td class='metric-cell $metricClass'>$(if($item.MetricAvail){"$($item.MetricMax)%"}else{"N/A"})</td><td>$($item.MetricPoints)</td></tr>`n"
}

$doc3 += @"
    </table>
</div>

<div class="remediation">
    <h3>Remediation: Create VM CPU Alert Rules</h3>
    <p>Run <code>Vanta-Compliance-Remediation.ps1 -Mode Remediate</code> to auto-create alert rules.</p>
    <pre>
# Manual remediation per VM:
`$condition = New-AzMetricAlertRuleV2Criteria -MetricName "Percentage CPU" ``
    -Operator GreaterThan -Threshold 85 -TimeAggregation Average
Add-AzMetricAlertRuleV2 -Name "cpu-alert-{vmName}" ``
    -ResourceGroupName "{rg}" ``
    -TargetResourceId "{resourceId}" ``
    -WindowSize 00:05:00 -Frequency 00:05:00 ``
    -Condition `$condition -Severity 2 -Description "HITRUST r2 - VM CPU monitoring"
    </pre>
</div>
"@

$doc3 += Get-EvidenceHtmlFooter
$doc3Path = Join-Path $OutputDir "3-VM-CPU-Evidence.html"
$doc3 | Out-File -FilePath $doc3Path -Encoding utf8
Write-Host "  [3/4] VM CPU Evidence: $doc3Path" -ForegroundColor Green

# ---- DOCUMENT 4: VM SSH + NSG ----
$vmNsgPass = ($vmSshEvidence | Where-Object { $_.NSGStatus -eq "PASS" }).Count
$vmNsgFail = ($vmSshEvidence | Where-Object { $_.NSGStatus -eq "FAIL" }).Count
$vmSshPassCount = ($vmSshEvidence | Where-Object { $_.SSHStatus -eq "PASS" }).Count
$vmSshFailCount = ($vmSshEvidence | Where-Object { $_.SSHStatus -eq "FAIL" }).Count

$doc4 = Get-EvidenceHtmlHeader -Title "VM SSH Access & NSG Security Evidence" `
    -HitrustControl "01.j - Network Access Control | 01.m - Network Controls | 09.ab - Monitoring System Use" `
    -HitrustReq "All VMs must have NSG attached (NIC or subnet level). SSH (port 22) must NOT be accessible from the public internet. Administrative access must be restricted to authorized networks." `
    -VantaTestName "Azure VM Public SSH denied + VM has security groups" -ItemCount $vmSshCount

$doc4 += @"
<div class="summary-cards">
    <div class="card total"><div class="num">$vmSshCount</div><div class="lbl">Virtual Machines</div></div>
    <div class="card pass"><div class="num">$vmNsgPass</div><div class="lbl">NSG Attached</div></div>
    <div class="card fail"><div class="num">$vmNsgFail</div><div class="lbl">No NSG</div></div>
    <div class="card pass"><div class="num">$vmSshPassCount</div><div class="lbl">SSH Blocked</div></div>
    <div class="card fail"><div class="num">$vmSshFailCount</div><div class="lbl">SSH Open</div></div>
</div>

<div class="section">
    <div class="section-header"><h3>VM Network Security Evidence</h3><span class="badge $(if($vmNsgFail -eq 0 -and $vmSshFailCount -eq 0){'badge-pass'}else{'badge-fail'})">NSG: $vmNsgPass/$vmSshCount | SSH: $vmSshPassCount/$vmSshCount</span></div>
    <table>
        <tr><th>#</th><th>Subscription</th><th>VM Name</th><th>Size</th><th>Public IP</th><th>NIC NSG</th><th>Subnet NSG</th><th>NSG Status</th><th>SSH Status</th><th>SSH Detail</th></tr>
"@

$i = 0
foreach ($item in $vmSshEvidence) {
    $i++
    $doc4 += "<tr><td>$i</td><td>$($item.Subscription)</td><td><strong>$($item.VMName)</strong></td><td>$($item.VMSize)</td><td>$($item.PublicIPs)</td><td>$($item.NicNSG)</td><td>$($item.SubnetNSG)</td><td><span class='status-$($item.NSGStatus)'>$($item.NSGStatus)</span></td><td><span class='status-$($item.SSHStatus)'>$($item.SSHStatus)</span></td><td class='detail-cell'>$($item.SSHDetail)</td></tr>`n"
}

$doc4 += "</table></div>`n"

# Add detailed NSG rules table for each VM
foreach ($item in $vmSshEvidence) {
    if ($item.Rules.Count -gt 0) {
        $doc4 += @"
<div class="section">
    <div class="section-header"><h3>NSG Rules: $($item.VMName)</h3><span class="badge badge-pass">$($item.Rules.Count) rules</span></div>
    <table>
        <tr><th>NSG</th><th>Level</th><th>Rule Name</th><th>Priority</th><th>Direction</th><th>Access</th><th>Protocol</th><th>Source</th><th>Src Port</th><th>Destination</th><th>Dst Port</th></tr>
"@
        foreach ($rule in $item.Rules) {
            $accessColor = if ($rule.Access -eq "Allow") { "color:#107c10" } else { "color:#d13438;font-weight:bold" }
            $doc4 += "<tr><td>$($rule.NSG)</td><td>$($rule.Level)</td><td>$($rule.Name)</td><td>$($rule.Priority)</td><td>$($rule.Direction)</td><td style='$accessColor'>$($rule.Access)</td><td>$($rule.Protocol)</td><td>$($rule.SrcAddr)</td><td>$($rule.SrcPort)</td><td>$($rule.DstAddr)</td><td>$($rule.DstPort)</td></tr>`n"
        }
        $doc4 += "</table></div>`n"
    }
}

$doc4 += @"
<div class="remediation">
    <h3>Remediation: NSG + SSH Hardening</h3>
    <p>Run <code>Vanta-Compliance-Remediation.ps1 -Mode Remediate</code> to auto-create NSGs and deny SSH from internet.</p>
    <pre>
# Create NSG with SSH restricted to VNet only:
`$sshRule = New-AzNetworkSecurityRuleConfig -Name "Allow-SSH-VNet" ``
    -Priority 100 -Direction Inbound -Access Allow ``
    -Protocol Tcp -SourceAddressPrefix VirtualNetwork ``
    -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
`$denyAll = New-AzNetworkSecurityRuleConfig -Name "Deny-All-Inbound" ``
    -Priority 4096 -Direction Inbound -Access Deny ``
    -Protocol * -SourceAddressPrefix * ``
    -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange *
`$nsg = New-AzNetworkSecurityGroup -Name "{vm}-nsg" ``
    -ResourceGroupName "{rg}" -Location "{location}" ``
    -SecurityRules `$sshRule, `$denyAll
    </pre>
</div>
"@

$doc4 += Get-EvidenceHtmlFooter
$doc4Path = Join-Path $OutputDir "4-VM-SSH-NSG-Evidence.html"
$doc4 | Out-File -FilePath $doc4Path -Encoding utf8
Write-Host "  [4/4] VM SSH/NSG Evidence: $doc4Path" -ForegroundColor Green

# ============================================================================
# STEP 8: GENERATE MASTER SUMMARY
# ============================================================================
Write-Host ""
Write-Host "[8/8] Generating Master Summary..." -ForegroundColor Yellow

$endTime = Get-Date
$duration = $endTime - $startTime
$durationMin = [math]::Round($duration.TotalMinutes, 1)
$dateStr = Get-Date -Format "MMMM dd, yyyy"
$timeStr = Get-Date -Format "hh:mm tt"
$envLabel = if ($EnvironmentName) { " - $EnvironmentName" } else { "" }

$totalChecks = $sqlCpuCount + $sqlMemCount + $vmCpuCount + ($vmSshCount * 2)  # SSH + NSG
$totalPassing = $sqlCpuPass + $sqlMemPass + $vmCpuPass + $vmNsgPass + $vmSshPassCount
$totalFailing = $sqlCpuFail + $sqlMemFail + $vmCpuFail + $vmNsgFail + $vmSshFailCount
$overallRate = if ($totalChecks -gt 0) { [math]::Round(($totalPassing / $totalChecks) * 100, 1) } else { 0 }

$master = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>HITRUST r2 Master Evidence Summary - $Organization</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #f0f2f5; color: #333; font-size: 13px; }
.header { background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%); color: white; padding: 50px 40px; }
.header h1 { font-size: 28px; margin-bottom: 5px; }
.header h2 { font-size: 16px; font-weight: 400; opacity: 0.85; margin-bottom: 20px; }
.header .meta { display: flex; flex-wrap: wrap; gap: 25px; font-size: 13px; opacity: 0.9; }
.header .meta strong { color: #00bcf2; }
.confidential { background: #d13438; color: white; text-align: center; padding: 10px; font-size: 13px; font-weight: bold; letter-spacing: 2px; }
.container { max-width: 1200px; margin: 25px auto; padding: 0 20px; }
.summary-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 15px; margin-bottom: 30px; }
.card { background: white; border-radius: 12px; padding: 25px; text-align: center; box-shadow: 0 2px 12px rgba(0,0,0,0.08); }
.card .num { font-size: 44px; font-weight: bold; }
.card .lbl { font-size: 11px; color: #666; text-transform: uppercase; letter-spacing: 1px; margin-top: 5px; }
.card.pass { border-top: 5px solid #107c10; } .card.pass .num { color: #107c10; }
.card.fail { border-top: 5px solid #d13438; } .card.fail .num { color: #d13438; }
.card.total { border-top: 5px solid #0078d4; } .card.total .num { color: #0078d4; }
.card.rate { border-top: 5px solid #8764b8; } .card.rate .num { color: #8764b8; }
.test-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; margin-bottom: 25px; }
.test-card { background: white; border-radius: 10px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
.test-card .tc-header { padding: 15px 20px; color: white; display: flex; justify-content: space-between; align-items: center; }
.test-card .tc-header h3 { font-size: 14px; }
.tc-pass { background: #107c10; }
.tc-fail { background: #d13438; }
.tc-mixed { background: #ca5010; }
.test-card .tc-body { padding: 20px; }
.test-card .tc-body .stat { display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid #eee; }
.test-card .tc-body .stat:last-child { border-bottom: none; }
.test-card .tc-body .stat .k { color: #666; }
.test-card .tc-body .stat .v { font-weight: bold; }
.workflow { background: white; border-radius: 10px; padding: 25px; margin-bottom: 25px; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
.workflow h3 { margin-bottom: 15px; color: #1a1a2e; }
.workflow ol { margin-left: 20px; line-height: 2; }
.workflow code { background: #1a1a2e; color: #00ff41; padding: 2px 8px; border-radius: 3px; font-size: 12px; }
.sign-block { background: white; border-radius: 10px; padding: 30px; margin-top: 25px; box-shadow: 0 2px 8px rgba(0,0,0,0.06); display: grid; grid-template-columns: 1fr 1fr; gap: 30px; }
.sign-box { border-top: 2px solid #333; padding-top: 10px; }
.sign-box .name { font-weight: bold; font-size: 14px; }
.sign-box .title { color: #666; font-size: 12px; }
.footer { text-align: center; padding: 25px; color: #999; font-size: 11px; border-top: 1px solid #ddd; margin-top: 30px; }
@media print { body { background: white; } .confidential, .header, .tc-header { -webkit-print-color-adjust: exact; print-color-adjust: exact; } }
</style>
</head>
<body>
<div class="header">
    <h1>HITRUST r2 MASTER EVIDENCE SUMMARY</h1>
    <h2>$Organization$envLabel - Vanta Compliance Assessment</h2>
    <div class="meta">
        <span>Date: <strong>$dateStr $timeStr</strong></span>
        <span>Author: <strong>$AuthorName, $AuthorTitle</strong></span>
        <span>Duration: <strong>$durationMin minutes</strong></span>
        <span>Subscriptions: <strong>$($script:allSubscriptions.Count)</strong></span>
        <span>Tenant: <strong>$($script:currentTenant)</strong></span>
    </div>
</div>
<div class="confidential">CONFIDENTIAL - HITRUST r2 COMPLIANCE EVIDENCE - EXECUTIVE SUMMARY</div>

<div class="container">

<div class="summary-cards">
    <div class="card total"><div class="num">$totalChecks</div><div class="lbl">Total Checks</div></div>
    <div class="card pass"><div class="num">$totalPassing</div><div class="lbl">Passing</div></div>
    <div class="card fail"><div class="num">$totalFailing</div><div class="lbl">Failing</div></div>
    <div class="card rate"><div class="num">$overallRate%</div><div class="lbl">Compliance Rate</div></div>
    <div class="card total"><div class="num">4</div><div class="lbl">Vanta Tests</div></div>
</div>

<div class="test-grid">
    <div class="test-card">
        <div class="tc-header $(if($sqlCpuFail -eq 0 -and $sqlCpuCount -gt 0){'tc-pass'}elseif($sqlCpuPass -gt 0){'tc-mixed'}else{'tc-fail'})"><h3>SQL CPU Monitored</h3><span>$sqlCpuPass / $sqlCpuCount</span></div>
        <div class="tc-body">
            <div class="stat"><span class="k">Databases Scanned</span><span class="v">$sqlCpuCount</span></div>
            <div class="stat"><span class="k">Alert Configured</span><span class="v" style="color:#107c10">$sqlCpuPass</span></div>
            <div class="stat"><span class="k">No Alert</span><span class="v" style="color:#d13438">$sqlCpuFail</span></div>
            <div class="stat"><span class="k">HITRUST Control</span><span class="v">09.ab</span></div>
            <div class="stat"><span class="k">Evidence File</span><span class="v">1-SQL-CPU-Evidence.html</span></div>
        </div>
    </div>
    <div class="test-card">
        <div class="tc-header $(if($sqlMemFail -eq 0 -and $sqlMemCount -gt 0){'tc-pass'}elseif($sqlMemPass -gt 0){'tc-mixed'}else{'tc-fail'})"><h3>SQL Memory Monitored</h3><span>$sqlMemPass / $sqlMemCount</span></div>
        <div class="tc-body">
            <div class="stat"><span class="k">Databases Scanned</span><span class="v">$sqlMemCount</span></div>
            <div class="stat"><span class="k">Alert Configured</span><span class="v" style="color:#107c10">$sqlMemPass</span></div>
            <div class="stat"><span class="k">No Alert</span><span class="v" style="color:#d13438">$sqlMemFail</span></div>
            <div class="stat"><span class="k">HITRUST Control</span><span class="v">09.ab</span></div>
            <div class="stat"><span class="k">Evidence File</span><span class="v">2-SQL-Memory-Evidence.html</span></div>
        </div>
    </div>
    <div class="test-card">
        <div class="tc-header $(if($vmCpuFail -eq 0 -and $vmCpuCount -gt 0){'tc-pass'}elseif($vmCpuPass -gt 0){'tc-mixed'}else{'tc-fail'})"><h3>VM CPU Monitored</h3><span>$vmCpuPass / $vmCpuCount</span></div>
        <div class="tc-body">
            <div class="stat"><span class="k">VMs Scanned</span><span class="v">$vmCpuCount</span></div>
            <div class="stat"><span class="k">Alert Configured</span><span class="v" style="color:#107c10">$vmCpuPass</span></div>
            <div class="stat"><span class="k">No Alert</span><span class="v" style="color:#d13438">$vmCpuFail</span></div>
            <div class="stat"><span class="k">HITRUST Control</span><span class="v">09.ab</span></div>
            <div class="stat"><span class="k">Evidence File</span><span class="v">3-VM-CPU-Evidence.html</span></div>
        </div>
    </div>
    <div class="test-card">
        <div class="tc-header $(if($vmNsgFail -eq 0 -and $vmSshFailCount -eq 0){'tc-pass'}else{'tc-fail'})"><h3>VM SSH + NSG Security</h3><span>NSG: $vmNsgPass/$vmSshCount | SSH: $vmSshPassCount/$vmSshCount</span></div>
        <div class="tc-body">
            <div class="stat"><span class="k">VMs Scanned</span><span class="v">$vmSshCount</span></div>
            <div class="stat"><span class="k">NSG Attached</span><span class="v" style="color:#107c10">$vmNsgPass</span></div>
            <div class="stat"><span class="k">No NSG</span><span class="v" style="color:#d13438">$vmNsgFail</span></div>
            <div class="stat"><span class="k">SSH Blocked</span><span class="v" style="color:#107c10">$vmSshPassCount</span></div>
            <div class="stat"><span class="k">SSH Open</span><span class="v" style="color:#d13438">$vmSshFailCount</span></div>
            <div class="stat"><span class="k">HITRUST Control</span><span class="v">01.j / 01.m</span></div>
            <div class="stat"><span class="k">Evidence File</span><span class="v">4-VM-SSH-NSG-Evidence.html</span></div>
        </div>
    </div>
</div>

<div class="workflow">
    <h3>Vanta Evidence Upload Workflow</h3>
    <ol>
        <li><strong>BEFORE (Current State)</strong> - Upload these evidence documents to Vanta as <em>baseline assessment</em></li>
        <li><strong>REMEDIATE</strong> - Run <code>Vanta-Compliance-Remediation.ps1 -Mode Remediate</code> on each environment (TEST -> Stage -> QA -> Prod)</li>
        <li><strong>AFTER (Post-Remediation)</strong> - Re-run this evidence collector to generate <em>post-remediation evidence</em></li>
        <li><strong>UPLOAD</strong> - Upload AFTER evidence to Vanta Controls > Documents showing all tests now PASS</li>
        <li><strong>VERIFY</strong> - Wait for Vanta to re-sync and mark tests as passing (usually within 24h)</li>
    </ol>
</div>

<div class="workflow">
    <h3>Evidence Documents Generated</h3>
    <ol>
        <li><code>1-SQL-CPU-Evidence.html</code> - SQL Database CPU Monitoring ($sqlCpuCount databases)</li>
        <li><code>2-SQL-Memory-Evidence.html</code> - SQL Database Memory/DTU Monitoring ($sqlMemCount databases)</li>
        <li><code>3-VM-CPU-Evidence.html</code> - VM CPU Monitoring ($vmCpuCount VMs)</li>
        <li><code>4-VM-SSH-NSG-Evidence.html</code> - VM SSH + NSG Security ($vmSshCount VMs)</li>
        <li><code>0-Master-Evidence-Summary.html</code> - This executive summary</li>
    </ol>
    <p style="margin-top:10px;color:#666;font-size:12px;">Each document can be printed to PDF (Ctrl+P) for upload to Vanta Controls > Documents.</p>
</div>

<div class="sign-block">
    <div class="sign-box">
        <div class="name">$AuthorName</div>
        <div class="title">$AuthorTitle - $Organization</div>
        <div style="margin-top:8px;color:#999;font-size:11px;">Assessment date: $dateStr at $timeStr</div>
    </div>
    <div class="sign-box">
        <div class="name">Reviewed By: Tony Schlak</div>
        <div class="title">Director of IT - $Organization</div>
        <div style="margin-top:8px;color:#999;font-size:11px;">Review date: ___________________</div>
    </div>
</div>

</div>
<div class="footer">
    HITRUST r2 Compliance Master Evidence Summary | $Organization | $dateStr<br>
    Generated via Azure PowerShell SDK (read-only) by $AuthorName | Document ID: $(New-Guid)
</div>
</body></html>
"@

$masterPath = Join-Path $OutputDir "0-Master-Evidence-Summary.html"
$master | Out-File -FilePath $masterPath -Encoding utf8
Write-Host "  [MASTER] Summary: $masterPath" -ForegroundColor Green

# Auto-open master
Start-Process $masterPath

# ============================================================================
# FINAL SUMMARY
# ============================================================================
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  EVIDENCE COLLECTION COMPLETE" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  Output Folder: $OutputDir" -ForegroundColor White
Write-Host ""
Write-Host "  Documents Generated:" -ForegroundColor Yellow
Write-Host "    0-Master-Evidence-Summary.html  (Executive summary)" -ForegroundColor White
Write-Host "    1-SQL-CPU-Evidence.html          ($sqlCpuCount databases, $sqlCpuPass pass / $sqlCpuFail fail)" -ForegroundColor $(if ($sqlCpuFail -eq 0) { "Green" } else { "Red" })
Write-Host "    2-SQL-Memory-Evidence.html       ($sqlMemCount databases, $sqlMemPass pass / $sqlMemFail fail)" -ForegroundColor $(if ($sqlMemFail -eq 0) { "Green" } else { "Red" })
Write-Host "    3-VM-CPU-Evidence.html           ($vmCpuCount VMs, $vmCpuPass pass / $vmCpuFail fail)" -ForegroundColor $(if ($vmCpuFail -eq 0) { "Green" } else { "Red" })
Write-Host "    4-VM-SSH-NSG-Evidence.html       ($vmSshCount VMs, NSG:$vmNsgPass/$vmSshCount SSH:$vmSshPassCount/$vmSshCount)" -ForegroundColor $(if ($vmNsgFail -eq 0 -and $vmSshFailCount -eq 0) { "Green" } else { "Red" })
Write-Host ""
Write-Host "  Overall: $totalPassing / $totalChecks ($overallRate%)" -ForegroundColor $(if ($overallRate -ge 100) { "Green" } elseif ($overallRate -ge 50) { "Yellow" } else { "Red" })
Write-Host "  Duration: $durationMin minutes" -ForegroundColor White
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
Write-Host "    1. Open each HTML and Ctrl+P to save as PDF" -ForegroundColor White
Write-Host "    2. Upload PDFs to Vanta > Controls > Documents (BEFORE evidence)" -ForegroundColor White
Write-Host "    3. Run:  .\Vanta-Compliance-Remediation.ps1 -Mode Remediate" -ForegroundColor White
Write-Host "    4. Re-run this script to get AFTER evidence" -ForegroundColor White
Write-Host "    5. Upload AFTER PDFs to Vanta proving all tests PASS" -ForegroundColor White
Write-Host "============================================================================" -ForegroundColor Cyan
