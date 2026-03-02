<#
.SYNOPSIS
    SQL Database DTU Audit Report - Shows ALL waste and savings opportunities

.DESCRIPTION
    Analyzes Azure SQL Databases and creates comprehensive audit report
    READ-ONLY - Makes NO changes, just shows you the money you're wasting

.PARAMETER SubscriptionId
    Azure Subscription ID (optional - will prompt if not provided)

.PARAMETER OutputPath
    Path where reports will be saved (default: current directory)

.EXAMPLE
    .\SQL_Database_DTU_Audit_FINAL.ps1
    
.EXAMPLE
    .\SQL_Database_DTU_Audit_FINAL.ps1 -SubscriptionId "your-sub-id" -OutputPath "C:\Reports"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "."
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportPath = Join-Path $OutputPath "SQL_DTU_AUDIT_REPORT_$timestamp.html"
$csvPath = Join-Path $OutputPath "SQL_DTU_AUDIT_DATA_$timestamp.csv"

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "    SQL DATABASE DTU AUDIT - FIND THE WASTE!" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""

# Import required modules
Write-Host "[STEP 1] Loading Azure modules..." -ForegroundColor Yellow
try {
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Sql -ErrorAction Stop
    Import-Module Az.Monitor -ErrorAction Stop
    Write-Host "         Modules loaded successfully" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to load Azure modules. Install with: Install-Module -Name Az" -ForegroundColor Red
    exit
}

# Connect to Azure
Write-Host ""
Write-Host "[STEP 2] Connecting to Azure..." -ForegroundColor Yellow
try {
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount | Out-Null
    }
    Write-Host "         Connected successfully" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to connect to Azure" -ForegroundColor Red
    exit
}

# Select subscription
Write-Host ""
Write-Host "[STEP 3] Selecting subscription..." -ForegroundColor Yellow

if (-not $SubscriptionId) {
    $subscriptions = Get-AzSubscription
    
    if ($subscriptions.Count -eq 0) {
        Write-Host "ERROR: No subscriptions found" -ForegroundColor Red
        exit
    }
    
    if ($subscriptions.Count -eq 1) {
        $SubscriptionId = $subscriptions[0].Id
        Write-Host "         Auto-selected: $($subscriptions[0].Name)" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "Available Subscriptions:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $subscriptions.Count; $i++) {
            Write-Host "  [$($i+1)] $($subscriptions[$i].Name)" -ForegroundColor White
        }
        Write-Host ""
        $selection = Read-Host "Select subscription number"
        $SubscriptionId = $subscriptions[[int]$selection - 1].Id
    }
}

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
$subName = (Get-AzContext).Subscription.Name
Write-Host "         Using: $subName" -ForegroundColor Green

# Get SQL Servers
Write-Host ""
Write-Host "[STEP 4] Discovering SQL Servers..." -ForegroundColor Yellow
$servers = Get-AzSqlServer
Write-Host "         Found $($servers.Count) SQL Server(s)" -ForegroundColor Green

if ($servers.Count -eq 0) {
    Write-Host "ERROR: No SQL Servers found in this subscription" -ForegroundColor Red
    exit
}

# Analyze databases
Write-Host ""
Write-Host "[STEP 5] Analyzing databases (this may take a few minutes)..." -ForegroundColor Yellow

$analysisResults = @()
$totalCurrentCost = 0
$totalOptimizedCost = 0
$serverCount = 0

foreach ($server in $servers) {
    $serverCount++
    $serverName = $server.ServerName
    $resourceGroup = $server.ResourceGroupName
    
    Write-Host ""
    Write-Host "  Server $serverCount/$($servers.Count): $serverName" -ForegroundColor Cyan
    
    $databases = Get-AzSqlDatabase -ServerName $serverName -ResourceGroupName $resourceGroup | 
                 Where-Object { $_.DatabaseName -ne "master" }
    
    Write-Host "    Found $($databases.Count) database(s)" -ForegroundColor Gray
    
    $dbCount = 0
    foreach ($db in $databases) {
        $dbCount++
        $dbName = $db.DatabaseName
        Write-Host "      [$dbCount/$($databases.Count)] Analyzing: $dbName..." -ForegroundColor Gray
        
        $currentTier = $db.SkuName
        $currentCapacity = $db.Capacity
        $maxSizeBytes = $db.MaxSizeBytes
        $maxSizeGB = [math]::Round($maxSizeBytes / 1GB, 2)
        
        # Get metrics
        $endTime = Get-Date
        $startTime = $endTime.AddDays(-7)
        
        $dtuMetric = Get-AzMetric -ResourceId $db.ResourceId -MetricName "dtu_consumption_percent" -StartTime $startTime -EndTime $endTime -TimeGrain (New-TimeSpan -Hours 1) -AggregationType Average -ErrorAction SilentlyContinue
        $storageMetric = Get-AzMetric -ResourceId $db.ResourceId -MetricName "storage_percent" -StartTime $startTime -EndTime $endTime -TimeGrain (New-TimeSpan -Hours 1) -AggregationType Average -ErrorAction SilentlyContinue
        $connectionMetric = Get-AzMetric -ResourceId $db.ResourceId -MetricName "connection_successful" -StartTime $startTime -EndTime $endTime -TimeGrain (New-TimeSpan -Hours 1) -AggregationType Total -ErrorAction SilentlyContinue
        
        $dtuData = if ($dtuMetric.Data) { $dtuMetric.Data.Average } else { @() }
        $storageData = if ($storageMetric.Data) { $storageMetric.Data.Average } else { @() }
        $connectionData = if ($connectionMetric.Data) { $connectionMetric.Data.Total } else { @() }
        
        $avgDTU = if ($dtuData.Count -gt 0) { ($dtuData | Where-Object { $null -ne $_ } | Measure-Object -Average).Average } else { 0 }
        $maxDTU = if ($dtuData.Count -gt 0) { ($dtuData | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum } else { 0 }
        $avgStorage = if ($storageData.Count -gt 0) { ($storageData | Where-Object { $null -ne $_ } | Measure-Object -Average).Average } else { 0 }
        $totalConnections = if ($connectionData.Count -gt 0) { ($connectionData | Where-Object { $null -ne $_ } | Measure-Object -Sum).Sum } else { 0 }
        
        # Calculate costs
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
        
        # Determine recommendations
        $recommendedTier = $currentTier
        $recommendedCapacity = $currentCapacity
        $recommendation = "No change recommended"
        $savingsOpportunity = 0
        $priority = "Low"
        
        if ($avgDTU -lt 10 -and $maxDTU -lt 25 -and $totalConnections -lt 1000) {
            if ($currentTier -ne "Basic") {
                $recommendedTier = "Basic"
                $recommendedCapacity = 5
                $recommendation = "Massively underutilized - downgrade to Basic tier"
                $savingsOpportunity = $currentMonthlyCost - 5
                $priority = "High"
            }
        }
        elseif ($avgDTU -lt 20 -and $maxDTU -lt 40) {
            if ($currentTier -notin @("Basic", "S0", "S1")) {
                $recommendedTier = "S1"
                $recommendedCapacity = 20
                $recommendation = "Low utilization - downgrade to S1"
                $savingsOpportunity = $currentMonthlyCost - 30
                $priority = "High"
            }
        }
        elseif ($avgDTU -lt 40 -and $maxDTU -lt 60) {
            if ($currentTier -notin @("Basic", "S0", "S1", "S2")) {
                $recommendedTier = "S2"
                $recommendedCapacity = 50
                $recommendation = "Moderate utilization - downgrade to S2"
                $savingsOpportunity = $currentMonthlyCost - 75
                $priority = "Medium"
            }
        }
        elseif ($avgDTU -gt 80 -or $maxDTU -gt 95) {
            $recommendation = "High utilization - consider upgrading to prevent performance issues"
            $priority = "High"
            $recommendedTier = switch -Wildcard ($currentTier) {
                "Basic" { "S1" }
                "S0" { "S1" }
                "S1" { "S2" }
                "S2" { "S3" }
                "S3" { "S4" }
                default { $currentTier }
            }
        }
        
        if ($totalConnections -eq 0 -and $avgDTU -eq 0) {
            $recommendation = "UNUSED DATABASE - Candidate for immediate decommission"
            $savingsOpportunity = $currentMonthlyCost
            $priority = "Critical"
        }
        
        $optimizedMonthlyCost = $currentMonthlyCost - $savingsOpportunity
        $totalCurrentCost += $currentMonthlyCost
        $totalOptimizedCost += $optimizedMonthlyCost
        
        $analysisResults += [PSCustomObject]@{
            ServerName = $serverName
            ResourceGroup = $resourceGroup
            DatabaseName = $dbName
            CurrentTier = $currentTier
            CurrentCapacity = $currentCapacity
            SizeGB = $maxSizeGB
            AvgDTUPercent = [math]::Round($avgDTU, 2)
            MaxDTUPercent = [math]::Round($maxDTU, 2)
            AvgStoragePercent = [math]::Round($avgStorage, 2)
            TotalConnections = $totalConnections
            CurrentMonthlyCost = [math]::Round($currentMonthlyCost, 2)
            RecommendedTier = $recommendedTier
            RecommendedCapacity = $recommendedCapacity
            OptimizedMonthlyCost = [math]::Round($optimizedMonthlyCost, 2)
            MonthlySavings = [math]::Round($savingsOpportunity, 2)
            AnnualSavings = [math]::Round($savingsOpportunity * 12, 2)
            Recommendation = $recommendation
            Priority = $priority
        }
    }
}

# Generate report
Write-Host ""
Write-Host "[STEP 6] Generating audit report..." -ForegroundColor Yellow

$totalSavings = $totalCurrentCost - $totalOptimizedCost
$annualSavings = $totalSavings * 12

$htmlReport = @"
<!DOCTYPE html>
<html>
<head>
    <title>SQL Database DTU Audit Report - $timestamp</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background-color: #f5f5f5; }
        .header { background-color: #d13438; color: white; padding: 30px; border-radius: 5px; margin-bottom: 20px; }
        .header h1 { margin: 0; font-size: 32px; }
        .header p { margin: 5px 0 0 0; font-size: 16px; }
        .alert { background-color: #fff4ce; border-left: 4px solid #ff8c00; padding: 15px; margin-bottom: 20px; }
        .alert h2 { margin: 0 0 10px 0; color: #ff8c00; }
        .summary { background-color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .summary h2 { margin-top: 0; color: #0078d4; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        .metric { display: inline-block; margin: 10px 20px 10px 0; padding: 15px; background-color: #f5f5f5; border-radius: 5px; }
        .metric-label { font-size: 12px; color: #666; text-transform: uppercase; }
        .metric-value { font-size: 28px; font-weight: bold; color: #0078d4; }
        .savings { color: #107c10; }
        .waste { color: #d13438; }
        table { width: 100%; border-collapse: collapse; background-color: white; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin-bottom: 20px; font-size: 13px; }
        th { background-color: #0078d4; color: white; padding: 12px; text-align: left; font-weight: 600; position: sticky; top: 0; }
        td { padding: 10px 12px; border-bottom: 1px solid #e0e0e0; }
        tr:hover { background-color: #f5f5f5; }
        .priority-critical { background-color: #fde7e9; color: #d13438; font-weight: bold; }
        .priority-high { color: #d13438; font-weight: bold; }
        .priority-medium { color: #ff8c00; font-weight: bold; }
        .priority-low { color: #107c10; }
        .section { background-color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .section h2 { margin-top: 0; color: #0078d4; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        .footer { text-align: center; color: #666; font-size: 12px; margin-top: 30px; padding-top: 20px; border-top: 1px solid #e0e0e0; }
        .highlight { background-color: #fff4ce; padding: 2px 5px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>🚨 SQL DATABASE DTU AUDIT REPORT</h1>
        <p>Generated: $timestamp</p>
        <p>Subscription: $subName</p>
    </div>
    
    <div class="alert">
        <h2>⚠️ ATTENTION REQUIRED</h2>
        <p>This audit has identified <strong>$([math]::Round($annualSavings, 0))</strong> in potential annual savings from SQL Database optimization.</p>
    </div>
    
    <div class="summary">
        <h2>Executive Summary</h2>
        <div class="metric">
            <div class="metric-label">Total Databases</div>
            <div class="metric-value">$($analysisResults.Count)</div>
        </div>
        <div class="metric">
            <div class="metric-label waste">Current Monthly Waste</div>
            <div class="metric-value waste">`$$([math]::Round($totalCurrentCost, 0))</div>
        </div>
        <div class="metric">
            <div class="metric-label savings">Optimized Monthly Cost</div>
            <div class="metric-value savings">`$$([math]::Round($totalOptimizedCost, 0))</div>
        </div>
        <div class="metric">
            <div class="metric-label savings">Monthly Savings</div>
            <div class="metric-value savings">`$$([math]::Round($totalSavings, 0))</div>
        </div>
        <div class="metric">
            <div class="metric-label savings">Annual Savings</div>
            <div class="metric-value savings">`$$([math]::Round($annualSavings, 0))</div>
        </div>
    </div>
    
    <div class="section">
        <h2>Database Analysis and Recommendations</h2>
        <table>
            <tr>
                <th>Priority</th>
                <th>Server</th>
                <th>Database</th>
                <th>Current Tier</th>
                <th>Avg DTU%</th>
                <th>Max DTU%</th>
                <th>Connections</th>
                <th>Current Cost</th>
                <th>Recommended</th>
                <th>New Cost</th>
                <th>Monthly Savings</th>
                <th>Annual Savings</th>
                <th>Recommendation</th>
            </tr>
"@

foreach ($result in $analysisResults | Sort-Object -Property MonthlySavings -Descending) {
    $priorityClass = "priority-$($result.Priority.ToLower())"
    $htmlReport += @"
            <tr>
                <td class="$priorityClass">$($result.Priority)</td>
                <td>$($result.ServerName)</td>
                <td>$($result.DatabaseName)</td>
                <td>$($result.CurrentTier)</td>
                <td>$($result.AvgDTUPercent)%</td>
                <td>$($result.MaxDTUPercent)%</td>
                <td>$($result.TotalConnections)</td>
                <td>`$$($result.CurrentMonthlyCost)</td>
                <td>$($result.RecommendedTier)</td>
                <td>`$$($result.OptimizedMonthlyCost)</td>
                <td class="savings">`$$($result.MonthlySavings)</td>
                <td class="savings">`$$($result.AnnualSavings)</td>
                <td>$($result.Recommendation)</td>
            </tr>
"@
}

$underutilized = ($analysisResults | Where-Object { $_.AvgDTUPercent -lt 20 }).Count
$overutilized = ($analysisResults | Where-Object { $_.MaxDTUPercent -gt 80 }).Count
$unused = ($analysisResults | Where-Object { $_.TotalConnections -eq 0 }).Count
$critical = ($analysisResults | Where-Object { $_.Priority -eq 'Critical' }).Count
$high = ($analysisResults | Where-Object { $_.Priority -eq 'High' }).Count

$htmlReport += @"
        </table>
    </div>
    
    <div class="section">
        <h2>💰 Money Left on the Table</h2>
        <ul>
            <li><strong class="waste">$($analysisResults.Count)</strong> databases analyzed</li>
            <li><strong class="waste">$underutilized</strong> databases using less than 20% of capacity</li>
            <li><strong class="waste">$unused</strong> databases with ZERO connections (completely unused)</li>
            <li><strong class="waste">$overutilized</strong> databases at risk of performance issues</li>
            <li><strong class="waste">$critical</strong> critical priority issues requiring immediate action</li>
            <li><strong class="waste">$high</strong> high priority optimization opportunities</li>
            <li><strong class="savings">Potential annual savings: `$$([math]::Round($annualSavings, 0))</strong></li>
        </ul>
    </div>
    
    <div class="section">
        <h2>✅ Immediate Action Items</h2>
        <ol>
            <li><strong>Decommission unused databases</strong> - $unused database(s) with zero activity</li>
            <li><strong>Downgrade underutilized databases</strong> - $underutilized database(s) wasting capacity</li>
            <li><strong>Upgrade overutilized databases</strong> - $overutilized database(s) at performance risk</li>
            <li><strong>Review high-priority recommendations</strong> - Focus on red/critical items first</li>
            <li><strong>Implement monthly review process</strong> - Prevent future waste</li>
        </ol>
    </div>
    
    <div class="footer">
        <p><strong>This is an AUDIT REPORT ONLY - No changes have been made to your environment</strong></p>
        <p>Analysis based on 7-day historical data</p>
        <p>For implementation assistance, contact the Infrastructure Team</p>
    </div>
</body>
</html>
"@

$htmlReport | Out-File -FilePath $reportPath -Encoding UTF8
$analysisResults | Export-Csv -Path $csvPath -NoTypeInformation

Write-Host "         Report generated successfully" -ForegroundColor Green

# Display summary
Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "                    AUDIT COMPLETE!" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "📊 RESULTS:" -ForegroundColor Yellow
Write-Host "   Total Databases:          $($analysisResults.Count)" -ForegroundColor White
Write-Host "   Current Monthly Cost:     `$$([math]::Round($totalCurrentCost, 0))" -ForegroundColor Red
Write-Host "   Optimized Monthly Cost:   `$$([math]::Round($totalOptimizedCost, 0))" -ForegroundColor Green
Write-Host "   Monthly Savings:          `$$([math]::Round($totalSavings, 0))" -ForegroundColor Green
Write-Host "   ANNUAL SAVINGS:           `$$([math]::Round($annualSavings, 0))" -ForegroundColor Green -BackgroundColor Black
Write-Host ""
Write-Host "📁 REPORTS SAVED:" -ForegroundColor Yellow
Write-Host "   HTML Report: $reportPath" -ForegroundColor Cyan
Write-Host "   CSV Data:    $csvPath" -ForegroundColor Cyan
Write-Host ""
Write-Host "👉 NEXT STEP: Open the HTML report and prepare to be amazed!" -ForegroundColor Yellow
Write-Host ""