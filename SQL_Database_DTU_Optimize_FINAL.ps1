<#
.SYNOPSIS
    SQL Database DTU Optimization - Actually makes the changes

.DESCRIPTION
    This script IMPLEMENTS the recommended optimizations from the audit report
    WARNING: This will modify database tiers and incur changes

.PARAMETER SubscriptionId
    Azure Subscription ID (optional - will prompt)

.PARAMETER AutoApprove
    Skip confirmation prompts and apply all high-priority changes

.PARAMETER OutputPath
    Path where reports will be saved

.EXAMPLE
    .\SQL_Database_DTU_Optimize_FINAL.ps1
    
.EXAMPLE
    .\SQL_Database_DTU_Optimize_FINAL.ps1 -SubscriptionId "your-sub-id" -AutoApprove
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [switch]$AutoApprove,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "."
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$changeLogPath = Join-Path $OutputPath "SQL_DTU_CHANGES_$timestamp.log"
$reportPath = Join-Path $OutputPath "SQL_DTU_OPTIMIZATION_RESULTS_$timestamp.html"

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Red
Write-Host "    SQL DATABASE DTU OPTIMIZATION - MAKE CHANGES" -ForegroundColor Yellow
Write-Host "=============================================================" -ForegroundColor Red
Write-Host ""
Write-Host "⚠️  WARNING: This script will modify your databases!" -ForegroundColor Red
Write-Host ""

if (-not $AutoApprove) {
    $confirm = Read-Host "Type 'YES' to continue"
    if ($confirm -ne "YES") {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        exit
    }
}

# Import modules
Write-Host ""
Write-Host "[STEP 1] Loading Azure modules..." -ForegroundColor Yellow
try {
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Sql -ErrorAction Stop
    Import-Module Az.Monitor -ErrorAction Stop
    Write-Host "         Modules loaded successfully" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to load Azure modules" -ForegroundColor Red
    exit
}

# Connect
Write-Host ""
Write-Host "[STEP 2] Connecting to Azure..." -ForegroundColor Yellow
try {
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount | Out-Null
    }
    Write-Host "         Connected successfully" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to connect" -ForegroundColor Red
    exit
}

# Select subscription
Write-Host ""
Write-Host "[STEP 3] Selecting subscription..." -ForegroundColor Yellow

if (-not $SubscriptionId) {
    $subscriptions = Get-AzSubscription
    
    if ($subscriptions.Count -eq 1) {
        $SubscriptionId = $subscriptions[0].Id
        Write-Host "         Auto-selected: $($subscriptions[0].Name)" -ForegroundColor Green
    } else {
        Write-Host ""
        for ($i = 0; $i -lt $subscriptions.Count; $i++) {
            Write-Host "  [$($i+1)] $($subscriptions[$i].Name)" -ForegroundColor White
        }
        Write-Host ""
        $selection = Read-Host "Select subscription"
        $SubscriptionId = $subscriptions[[int]$selection - 1].Id
    }
}

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
$subName = (Get-AzContext).Subscription.Name
Write-Host "         Using: $subName" -ForegroundColor Green

# Get servers
Write-Host ""
Write-Host "[STEP 4] Discovering SQL Servers..." -ForegroundColor Yellow
$servers = Get-AzSqlServer
Write-Host "         Found $($servers.Count) SQL Server(s)" -ForegroundColor Green

# Analyze and optimize
Write-Host ""
Write-Host "[STEP 5] Analyzing and optimizing databases..." -ForegroundColor Yellow

$changesApplied = 0
$changesFailed = 0
$totalSavings = 0
$changes = @()

foreach ($server in $servers) {
    $serverName = $server.ServerName
    $resourceGroup = $server.ResourceGroupName
    
    Write-Host ""
    Write-Host "  Server: $serverName" -ForegroundColor Cyan
    
    $databases = Get-AzSqlDatabase -ServerName $serverName -ResourceGroupName $resourceGroup | 
                 Where-Object { $_.DatabaseName -ne "master" }
    
    foreach ($db in $databases) {
        $dbName = $db.DatabaseName
        $currentTier = $db.SkuName
        
        # Get metrics
        $endTime = Get-Date
        $startTime = $endTime.AddDays(-7)
        
        $dtuMetric = Get-AzMetric -ResourceId $db.ResourceId -MetricName "dtu_consumption_percent" -StartTime $startTime -EndTime $endTime -TimeGrain (New-TimeSpan -Hours 1) -AggregationType Average -ErrorAction SilentlyContinue
        $connectionMetric = Get-AzMetric -ResourceId $db.ResourceId -MetricName "connection_successful" -StartTime $startTime -EndTime $endTime -TimeGrain (New-TimeSpan -Hours 1) -AggregationType Total -ErrorAction SilentlyContinue
        
        $dtuData = if ($dtuMetric.Data) { $dtuMetric.Data.Average } else { @() }
        $connectionData = if ($connectionMetric.Data) { $connectionMetric.Data.Total } else { @() }
        
        $avgDTU = if ($dtuData.Count -gt 0) { ($dtuData | Where-Object { $null -ne $_ } | Measure-Object -Average).Average } else { 0 }
        $maxDTU = if ($dtuData.Count -gt 0) { ($dtuData | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum } else { 0 }
        $totalConnections = if ($connectionData.Count -gt 0) { ($connectionData | Where-Object { $null -ne $_ } | Measure-Object -Sum).Sum } else { 0 }
        
        # Calculate current cost
        $currentMonthlyCost = switch -Wildcard ($currentTier) {
            "Basic" { 5 }
            "S0" { 15 }
            "S1" { 30 }
            "S2" { 75 }
            "S3" { 150 }
            "S4" { 300 }
            "S6" { 600 }
            "S7" { 1200 }
            "S9" { 2400 }
            "S12" { 4800 }
            "P1" { 465 }
            "P2" { 930 }
            "P4" { 1860 }
            "P6" { 3720 }
            "P11" { 7440 }
            "P15" { 14880 }
            default { 100 }
        }
        
        # Determine action
        $recommendedTier = $null
        $savingsOpportunity = 0
        $reason = ""
        
        if ($avgDTU -lt 10 -and $maxDTU -lt 25 -and $totalConnections -lt 1000) {
            if ($currentTier -ne "Basic") {
                $recommendedTier = "Basic"
                $savingsOpportunity = $currentMonthlyCost - 5
                $reason = "Underutilized - downgrade to Basic"
            }
        }
        elseif ($avgDTU -lt 20 -and $maxDTU -lt 40) {
            if ($currentTier -notin @("Basic", "S0", "S1")) {
                $recommendedTier = "S1"
                $savingsOpportunity = $currentMonthlyCost - 30
                $reason = "Low utilization - downgrade to S1"
            }
        }
        elseif ($avgDTU -lt 40 -and $maxDTU -lt 60) {
            if ($currentTier -notin @("Basic", "S0", "S1", "S2")) {
                $recommendedTier = "S2"
                $savingsOpportunity = $currentMonthlyCost - 75
                $reason = "Moderate utilization - downgrade to S2"
            }
        }
        
        # Apply change if recommended
        if ($recommendedTier -and $savingsOpportunity -gt 0) {
            Write-Host "    📊 $dbName : $currentTier -> $recommendedTier (Save `$$savingsOpportunity/mo)" -ForegroundColor Yellow
            
            try {
                Set-AzSqlDatabase -ResourceGroupName $resourceGroup -ServerName $serverName -DatabaseName $dbName -RequestedServiceObjectiveName $recommendedTier -ErrorAction Stop | Out-Null
                
                $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | SUCCESS | $serverName | $dbName | $currentTier -> $recommendedTier | `$$savingsOpportunity/mo | $reason"
                $logEntry | Out-File -FilePath $changeLogPath -Append
                
                $changes += [PSCustomObject]@{
                    Server = $serverName
                    Database = $dbName
                    OldTier = $currentTier
                    NewTier = $recommendedTier
                    MonthlySavings = $savingsOpportunity
                    Status = "SUCCESS"
                    Reason = $reason
                }
                
                $changesApplied++
                $totalSavings += $savingsOpportunity
                Write-Host "       ✅ Successfully optimized" -ForegroundColor Green
            }
            catch {
                $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | FAILED | $serverName | $dbName | Error: $_"
                $logEntry | Out-File -FilePath $changeLogPath -Append
                
                $changes += [PSCustomObject]@{
                    Server = $serverName
                    Database = $dbName
                    OldTier = $currentTier
                    NewTier = $recommendedTier
                    MonthlySavings = 0
                    Status = "FAILED"
                    Reason = $_.Exception.Message
                }
                
                $changesFailed++
                Write-Host "       ❌ Failed: $_" -ForegroundColor Red
            }
        }
    }
}

# Generate results report
Write-Host ""
Write-Host "[STEP 6] Generating results report..." -ForegroundColor Yellow

$htmlResults = @"
<!DOCTYPE html>
<html>
<head>
    <title>SQL Database Optimization Results - $timestamp</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background-color: #f5f5f5; }
        .header { background-color: #107c10; color: white; padding: 30px; border-radius: 5px; margin-bottom: 20px; }
        .header h1 { margin: 0; font-size: 32px; }
        .summary { background-color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .metric { display: inline-block; margin: 10px 20px 10px 0; padding: 15px; background-color: #f5f5f5; border-radius: 5px; }
        .metric-label { font-size: 12px; color: #666; text-transform: uppercase; }
        .metric-value { font-size: 28px; font-weight: bold; color: #107c10; }
        table { width: 100%; border-collapse: collapse; background-color: white; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin-bottom: 20px; }
        th { background-color: #0078d4; color: white; padding: 12px; text-align: left; }
        td { padding: 10px 12px; border-bottom: 1px solid #e0e0e0; }
        .success { color: #107c10; font-weight: bold; }
        .failed { color: #d13438; font-weight: bold; }
    </style>
</head>
<body>
    <div class="header">
        <h1>✅ SQL Database Optimization Results</h1>
        <p>Completed: $timestamp</p>
        <p>Subscription: $subName</p>
    </div>
    
    <div class="summary">
        <h2>Results Summary</h2>
        <div class="metric">
            <div class="metric-label">Changes Applied</div>
            <div class="metric-value">$changesApplied</div>
        </div>
        <div class="metric">
            <div class="metric-label">Changes Failed</div>
            <div class="metric-value" style="color: #d13438;">$changesFailed</div>
        </div>
        <div class="metric">
            <div class="metric-label">Monthly Savings</div>
            <div class="metric-value">`$$([math]::Round($totalSavings, 0))</div>
        </div>
        <div class="metric">
            <div class="metric-label">Annual Savings</div>
            <div class="metric-value">`$$([math]::Round($totalSavings * 12, 0))</div>
        </div>
    </div>
    
    <div class="summary">
        <h2>Changes Applied</h2>
        <table>
            <tr>
                <th>Server</th>
                <th>Database</th>
                <th>Old Tier</th>
                <th>New Tier</th>
                <th>Monthly Savings</th>
                <th>Status</th>
                <th>Reason</th>
            </tr>
"@

foreach ($change in $changes) {
    $statusClass = if ($change.Status -eq "SUCCESS") { "success" } else { "failed" }
    $htmlResults += @"
            <tr>
                <td>$($change.Server)</td>
                <td>$($change.Database)</td>
                <td>$($change.OldTier)</td>
                <td>$($change.NewTier)</td>
                <td>`$$($change.MonthlySavings)</td>
                <td class="$statusClass">$($change.Status)</td>
                <td>$($change.Reason)</td>
            </tr>
"@
}

$htmlResults += @"
        </table>
    </div>
</body>
</html>
"@

$htmlResults | Out-File -FilePath $reportPath -Encoding UTF8

# Display summary
Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "            OPTIMIZATION COMPLETE!" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "✅ RESULTS:" -ForegroundColor Yellow
Write-Host "   Changes Applied:    $changesApplied" -ForegroundColor Green
Write-Host "   Changes Failed:     $changesFailed" -ForegroundColor $(if ($changesFailed -gt 0) { "Red" } else { "Green" })
Write-Host "   Monthly Savings:    `$$([math]::Round($totalSavings, 0))" -ForegroundColor Green
Write-Host "   Annual Savings:     `$$([math]::Round($totalSavings * 12, 0))" -ForegroundColor Green
Write-Host ""
Write-Host "📁 REPORTS:" -ForegroundColor Yellow
Write-Host "   Change Log:    $changeLogPath" -ForegroundColor Cyan
Write-Host "   Results Report: $reportPath" -ForegroundColor Cyan
Write-Host ""