<#
.SYNOPSIS
    Automated SQL Database DTU analysis and optimization script

.DESCRIPTION
    This script audits Azure SQL Databases, analyzes DTU consumption patterns,
    and automatically optimizes database tiers based on actual usage

.PARAMETER SubscriptionId
    Azure Subscription ID

.PARAMETER ResourceGroupName
    Resource Group name (optional)

.PARAMETER ServerName
    SQL Server name (optional)

.PARAMETER AnalyzeOnly
    If specified, only analyzes and reports without making changes

.PARAMETER AutoOptimize
    If specified, automatically applies recommended tier changes

.PARAMETER OutputPath
    Path where reports will be saved

.EXAMPLE
    .\SQL_Database_DTU_Optimization.ps1 -SubscriptionId "sub-id" -AnalyzeOnly -OutputPath "C:\Reports"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$false)]
    [string]$ServerName,
    
    [Parameter(Mandatory=$false)]
    [switch]$AnalyzeOnly,
    
    [Parameter(Mandatory=$false)]
    [switch]$AutoOptimize,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "."
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportPath = Join-Path $OutputPath "SQL_DTU_Optimization_Report_$timestamp.html"
$csvPath = Join-Path $OutputPath "SQL_DTU_Optimization_Data_$timestamp.csv"
$changeLogPath = Join-Path $OutputPath "SQL_DTU_Changes_$timestamp.log"

Write-Host "SQL Database DTU Optimization Script" -ForegroundColor Green
Write-Host "Subscription: $SubscriptionId" -ForegroundColor Cyan
Write-Host "Mode: $(if ($AutoOptimize) { 'Auto-Optimize' } else { 'Analyze Only' })" -ForegroundColor Cyan

Import-Module Az.Sql -ErrorAction Stop
Import-Module Az.Monitor -ErrorAction Stop

Write-Host "Connecting to Azure..." -ForegroundColor Yellow
Connect-AzAccount -SubscriptionId $SubscriptionId

Write-Host "Retrieving SQL Servers..." -ForegroundColor Yellow

$servers = if ($ResourceGroupName -and $ServerName) {
    Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName
} elseif ($ResourceGroupName) {
    Get-AzSqlServer -ResourceGroupName $ResourceGroupName
} else {
    Get-AzSqlServer
}

Write-Host "Found $($servers.Count) SQL Server(s)" -ForegroundColor Cyan

$analysisResults = @()
$totalCurrentCost = 0
$totalOptimizedCost = 0
$changesApplied = 0

foreach ($server in $servers) {
    $serverName = $server.ServerName
    $resourceGroup = $server.ResourceGroupName
    
    Write-Host "Processing server: $serverName" -ForegroundColor Yellow
    
    $databases = Get-AzSqlDatabase -ServerName $serverName -ResourceGroupName $resourceGroup | 
                 Where-Object { $_.DatabaseName -ne "master" }
    
    foreach ($db in $databases) {
        $dbName = $db.DatabaseName
        Write-Host "  Analyzing database: $dbName" -ForegroundColor Gray
        
        $currentTier = $db. SkuName
        $currentCapacity = $db. Capacity
        $maxSizeBytes = $db.MaxSizeBytes
        $maxSizeGB = [math]::Round($maxSizeBytes / 1GB, 2)
        
        $endTime = Get-Date
        $startTime = $endTime. AddDays(-7)
        
        $dtuMetric = Get-AzMetric -ResourceId $db.ResourceId -MetricName "dtu_consumption_percent" -StartTime $startTime -EndTime $endTime -TimeGrain 01: 00:00 -AggregationType Average -ErrorAction SilentlyContinue
        $storageMetric = Get-AzMetric -ResourceId $db. ResourceId -MetricName "storage_percent" -StartTime $startTime -EndTime $endTime -TimeGrain 01:00:00 -AggregationType Average -ErrorAction SilentlyContinue
        $connectionMetric = Get-AzMetric -ResourceId $db.ResourceId -MetricName "connection_successful" -StartTime $startTime -EndTime $endTime -TimeGrain 01:00:00 -AggregationType Total -ErrorAction SilentlyContinue
        
        $dtuData = if ($dtuMetric. Data) { $dtuMetric.Data. Average } else { @() }
        $storageData = if ($storageMetric. Data) { $storageMetric.Data.Average } else { @() }
        $connectionData = if ($connectionMetric.Data) { $connectionMetric.Data. Total } else { @() }
        
        $avgDTU = if ($dtuData. Count -gt 0) { ($dtuData | Where-Object { $null -ne $_ } | Measure-Object -Average).Average } else { 0 }
        $maxDTU = if ($dtuData.Count -gt 0) { ($dtuData | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum } else { 0 }
        $avgStorage = if ($storageData. Count -gt 0) { ($storageData | Where-Object { $null -ne $_ } | Measure-Object -Average).Average } else { 0 }
        $totalConnections = if ($connectionData.Count -gt 0) { ($connectionData | Where-Object { $null -ne $_ } | Measure-Object -Sum).Sum } else { 0 }
        
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
        
        $recommendedTier = $currentTier
        $recommendedCapacity = $currentCapacity
        $recommendation = "No change recommended"
        $savingsOpportunity = 0
        $priority = "Low"
        
        if ($avgDTU -lt 10 -and $maxDTU -lt 25 -and $totalConnections -lt 1000) {
            if ($currentTier -ne "Basic") {
                $recommendedTier = "Basic"
                $recommendedCapacity = 5
                $recommendation = "Database is underutilized - downgrade to Basic tier"
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
            $recommendation = "High utilization - consider upgrading tier to prevent performance issues"
            $priority = "High"
            $recommendedTier = switch -Wildcard ($currentTier) {
                "Basic" { "S1"; break }
                "S0" { "S1"; break }
                "S1" { "S2"; break }
                "S2" { "S3"; break }
                "S3" { "S4"; break }
                default { $currentTier }
            }
        }
        
        if ($totalConnections -eq 0 -and $avgDTU -eq 0) {
            $recommendation = "Database appears unused - candidate for archival or decommissioning"
            $savingsOpportunity = $currentMonthlyCost
            $priority = "High"
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
            AvgStoragePercent = [math]:: Round($avgStorage, 2)
            TotalConnections = $totalConnections
            CurrentMonthlyCost = [math]::Round($currentMonthlyCost, 2)
            RecommendedTier = $recommendedTier
            RecommendedCapacity = $recommendedCapacity
            OptimizedMonthlyCost = [math]::Round($optimizedMonthlyCost, 2)
            MonthlySavings = [math]::Round($savingsOpportunity, 2)
            AnnualSavings = [math]::Round($savingsOpportunity * 12, 2)
            Recommendation = $recommendation
            Priority = $priority
            Applied = "No"
        }
        
        if ($AutoOptimize -and $savingsOpportunity -gt 0 -and $recommendedTier -ne $currentTier) {
            try {
                Write-Host "    Applying optimization: $currentTier -> $recommendedTier" -ForegroundColor Green
                $change = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $resourceGroup | $serverName | $dbName | $currentTier -> $recommendedTier | Savings: $([math]::Round($savingsOpportunity, 2))/month"
                $change | Out-File -FilePath $changeLogPath -Append
                Set-AzSqlDatabase -ResourceGroupName $resourceGroup -ServerName $serverName -DatabaseName $dbName -RequestedServiceObjectiveName $recommendedTier -ErrorAction Stop
                $analysisResults[-1].Applied = "Yes"
                $changesApplied++
                Write-Host "    Successfully optimized $dbName" -ForegroundColor Green
            }
            catch {
                Write-Warning "    Failed to optimize $dbName: $_"
                $change = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $resourceGroup | $serverName | $dbName | FAILED:  $_"
                $change | Out-File -FilePath $changeLogPath -Append
            }
        }
    }
}

Write-Host "Generating HTML report..." -ForegroundColor Yellow
$totalSavings = $totalCurrentCost - $totalOptimizedCost

$htmlReport = @"
<! DOCTYPE html>
<html>
<head>
    <title>SQL Database DTU Optimization Report - $timestamp</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background-color: #f5f5f5; }
        .header { background-color: #0078d4; color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; }
        .header h1 { margin: 0; font-size: 28px; }
        .header p { margin: 5px 0 0 0; font-size: 14px; }
        .summary { background-color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .summary h2 { margin-top: 0; color: #0078d4; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        .metric { display: inline-block; margin: 10px 20px 10px 0; }
        .metric-label { font-size: 12px; color: #666; text-transform:  uppercase; }
        .metric-value { font-size: 24px; font-weight: bold; color: #0078d4; }
        .savings { color: #107c10; }
        .warning { color: #ff8c00; }
        table { width: 100%; border-collapse: collapse; background-color: white; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin-bottom: 20px; font-size: 13px; }
        th { background-color: #0078d4; color: white; padding:  12px; text-align:  left; font-weight: 600; }
        td { padding: 10px 12px; border-bottom: 1px solid #e0e0e0; }
        tr:hover { background-color: #f5f5f5; }
        .priority-high { color: #d13438; font-weight: bold; }
        . priority-medium { color: #ff8c00; font-weight:  bold; }
        .priority-low { color: #107c10; }
        .section { background-color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .section h2 { margin-top:  0; color: #0078d4; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        .footer { text-align: center; color: #666; font-size: 12px; margin-top: 30px; padding-top: 20px; border-top: 1px solid #e0e0e0; }
        .applied { color: #107c10; font-weight: bold; }
    </style>
</head>
<body>
    <div class="header">
        <h1>SQL Database DTU Optimization Report</h1>
        <p>Generated: $timestamp</p>
        <p>Subscription: $SubscriptionId</p>
        <p>Mode:  $(if ($AutoOptimize) { 'Auto-Optimize' } else { 'Analysis Only' })</p>
    </div>
    
    <div class="summary">
        <h2>Executive Summary</h2>
        <div class="metric">
            <div class="metric-label">Total Databases</div>
            <div class="metric-value">$($analysisResults. Count)</div>
        </div>
        <div class="metric">
            <div class="metric-label">Current Monthly Cost</div>
            <div class="metric-value">$([math]::Round($totalCurrentCost, 2))</div>
        </div>
        <div class="metric">
            <div class="metric-label savings">Optimized Monthly Cost</div>
            <div class="metric-value savings">$([math]::Round($totalOptimizedCost, 2))</div>
        </div>
        <div class="metric">
            <div class="metric-label savings">Monthly Savings</div>
            <div class="metric-value savings">$([math]::Round($totalSavings, 2))</div>
        </div>
        <div class="metric">
            <div class="metric-label savings">Annual Savings</div>
            <div class="metric-value savings">$([math]::Round($totalSavings * 12, 2))</div>
        </div>
        $(if ($AutoOptimize) { "<div class='metric'><div class='metric-label warning'>Changes Applied</div><div class='metric-value warning'>$changesApplied</div></div>" })
    </div>
    
    <div class="section">
        <h2>Database Analysis and Recommendations</h2>
        <table>
            <tr>
                <th>Server</th>
                <th>Database</th>
                <th>Current Tier</th>
                <th>Size GB</th>
                <th>Avg DTU</th>
                <th>Max DTU</th>
                <th>Connections</th>
                <th>Current Cost</th>
                <th>Recommended Tier</th>
                <th>New Cost</th>
                <th>Monthly Savings</th>
                <th>Priority</th>
                <th>Recommendation</th>
                $(if ($AutoOptimize) { "<th>Applied</th>" })
            </tr>
"@

foreach ($result in $analysisResults | Sort-Object -Property MonthlySavings -Descending) {
    $priorityClass = "priority-$($result.Priority. ToLower())"
    $appliedClass = if ($result.Applied -eq "Yes") { "applied" } else { "" }
    $htmlReport += "<tr><td>$($result.ServerName)</td><td>$($result.DatabaseName)</td><td>$($result.CurrentTier)</td><td>$($result.SizeGB)</td><td>$($result.AvgDTUPercent)</td><td>$($result.MaxDTUPercent)</td><td>$($result.TotalConnections)</td><td>$($result.CurrentMonthlyCost)</td><td>$($result.RecommendedTier)</td><td>$($result.OptimizedMonthlyCost)</td><td class='savings'>$($result.MonthlySavings)</td><td class='$priorityClass'>$($result. Priority)</td><td>$($result.Recommendation)</td>$(if ($AutoOptimize) { "<td class='$appliedClass'>$($result.Applied)</td>" })</tr>"
}

$htmlReport += @"
        </table>
    </div>
    
    <div class="section">
        <h2>Key Findings</h2>
        <ul>
            <li>Total databases analyzed: $($analysisResults.Count)</li>
            <li>Underutilized databases: $(($analysisResults | Where-Object { $_. AvgDTUPercent -lt 20 }).Count)</li>
            <li>Overutilized databases: $(($analysisResults | Where-Object { $_.MaxDTUPercent -gt 80 }).Count)</li>
            <li>Unused databases: $(($analysisResults | Where-Object { $_.TotalConnections -eq 0 }).Count)</li>
            <li>High priority optimizations:  $(($analysisResults | Where-Object { $_.Priority -eq 'High' }).Count)</li>
            <li>Total potential monthly savings: $([math]::Round($totalSavings, 2))</li>
            <li>Total potential annual savings: $([math]:: Round($totalSavings * 12, 2))</li>
            $(if ($AutoOptimize) { "<li>Changes applied: $changesApplied</li>" })
        </ul>
    </div>
    
    <div class="section">
        <h2>Recommended Actions</h2>
        <ol>
            <li>Review and approve recommended tier changes for high-priority databases</li>
            <li>Investigate unused databases for potential archival or decommissioning</li>
            <li>Consider upgrading overutilized databases to prevent performance degradation</li>
            <li>Implement monitoring alerts for DTU consumption thresholds</li>
            <li>Establish regular review process for database tier optimization</li>
            <li>Consider migrating low-usage databases to Elastic Pools for cost efficiency</li>
            <li>Evaluate serverless tier for databases with sporadic usage patterns</li>
        </ol>
    </div>
    
    <div class="footer">
        <p>This report is generated automatically based on 7-day historical data. </p>
        <p>$(if ($AnalyzeOnly) { "Analysis mode - no changes were applied." } else { "Auto-optimize mode - changes were applied automatically." })</p>
        <p>For questions or concerns, contact the Database Administration Team.</p>
    </div>
</body>
</html>
"@

$htmlReport | Out-File -FilePath $reportPath -Encoding UTF8
$analysisResults | Export-Csv -Path $csvPath -NoTypeInformation

Write-Host ""
Write-Host "Optimization Complete!" -ForegroundColor Green
Write-Host "HTML Report: $reportPath" -ForegroundColor Cyan
Write-Host "CSV Data: $csvPath" -ForegroundColor Cyan
if ($AutoOptimize) { Write-Host "Change Log: $changeLogPath" -ForegroundColor Cyan }
Write-Host ""
Write-Host "Summary:" -ForegroundColor Yellow
Write-Host "  Total Databases: $($analysisResults. Count)" -ForegroundColor White
Write-Host "  Current Monthly Cost: $([math]:: Round($totalCurrentCost, 2))" -ForegroundColor White
Write-Host "  Optimized Monthly Cost: $([math]::Round($totalOptimizedCost, 2))" -ForegroundColor White
Write-Host "  Potential Monthly Savings: $([math]::Round($totalSavings, 2))" -ForegroundColor Green
Write-Host "  Potential Annual Savings: $([math]::Round($totalSavings * 12, 2))" -ForegroundColor Green