<#
.SYNOPSIS
    SQL Database DTU Audit - Shows CURRENT TIER and Recommendations
    Author: Syed Rizvi

.DESCRIPTION
    READ-ONLY audit script that shows:
    - CURRENT tier (S0, S1, S2, Basic, etc.)
    - CURRENT DTU limit
    - Actual DTU usage (Avg, Max)
    - RECOMMENDED tier
    - Potential savings

.EXAMPLE
    .\SQL_Database_DTU_Audit.ps1
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "$env:USERPROFILE\Desktop"
)

$ErrorActionPreference = "SilentlyContinue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "    SQL DATABASE DTU AUDIT - READ ONLY" -ForegroundColor Cyan
Write-Host "    Author: Syed Rizvi" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script is READ-ONLY - No changes will be made" -ForegroundColor Green
Write-Host ""

# Import modules
Write-Host "[1/5] Loading Azure modules..." -ForegroundColor Yellow
try {
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Sql -ErrorAction Stop
    Import-Module Az.Monitor -ErrorAction Stop
    Write-Host "      Modules loaded" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Install Az modules first: Install-Module Az -Force" -ForegroundColor Red
    exit
}

# Connect
Write-Host "[2/5] Connecting to Azure..." -ForegroundColor Yellow
try {
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount | Out-Null
    }
    Write-Host "      Connected" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to connect" -ForegroundColor Red
    exit
}

# Select subscription
Write-Host "[3/5] Selecting subscription..." -ForegroundColor Yellow
if (-not $SubscriptionId) {
    $subscriptions = Get-AzSubscription
    if ($subscriptions.Count -eq 1) {
        $SubscriptionId = $subscriptions[0].Id
        Write-Host "      Auto-selected: $($subscriptions[0].Name)" -ForegroundColor Green
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
Write-Host "      Using: $subName" -ForegroundColor Green

# Get servers
Write-Host "[4/5] Discovering SQL Servers and Databases..." -ForegroundColor Yellow
$servers = Get-AzSqlServer
Write-Host "      Found $($servers.Count) SQL Server(s)" -ForegroundColor Green

# DTU Pricing Table
$dtuPricing = @{
    "Basic" = @{ DTU = 5; Cost = 5 }
    "S0" = @{ DTU = 10; Cost = 15 }
    "S1" = @{ DTU = 20; Cost = 30 }
    "S2" = @{ DTU = 50; Cost = 75 }
    "S3" = @{ DTU = 100; Cost = 150 }
    "S4" = @{ DTU = 200; Cost = 300 }
    "S6" = @{ DTU = 400; Cost = 600 }
    "S7" = @{ DTU = 800; Cost = 1200 }
    "S9" = @{ DTU = 1600; Cost = 2400 }
    "S12" = @{ DTU = 3000; Cost = 4800 }
    "P1" = @{ DTU = 125; Cost = 465 }
    "P2" = @{ DTU = 250; Cost = 930 }
    "P4" = @{ DTU = 500; Cost = 1860 }
    "P6" = @{ DTU = 1000; Cost = 3720 }
    "P11" = @{ DTU = 1750; Cost = 7440 }
    "P15" = @{ DTU = 4000; Cost = 14880 }
}

# Analyze databases
Write-Host "[5/5] Analyzing databases (this may take a few minutes)..." -ForegroundColor Yellow
Write-Host ""

$allDatabases = @()
$totalCurrentCost = 0
$totalRecommendedCost = 0

foreach ($server in $servers) {
    $serverName = $server.ServerName
    $resourceGroup = $server.ResourceGroupName
    
    Write-Host "  Analyzing server: $serverName" -ForegroundColor Cyan
    
    $databases = Get-AzSqlDatabase -ServerName $serverName -ResourceGroupName $resourceGroup | 
                 Where-Object { $_.DatabaseName -ne "master" }
    
    foreach ($db in $databases) {
        $dbName = $db.DatabaseName
        
        # GET CURRENT TIER INFO
        $currentSku = $db.SkuName
        $currentEdition = $db.Edition
        $currentCapacity = $db.Capacity
        $currentMaxSizeGB = [math]::Round($db.MaxSizeBytes / 1GB, 2)
        
        # Build current tier display string
        if ($currentEdition -eq "Basic") {
            $currentTierDisplay = "Basic"
            $currentDTULimit = 5
        } elseif ($currentEdition -eq "Standard") {
            $currentTierDisplay = $currentSku  # S0, S1, S2, etc.
            $currentDTULimit = if ($dtuPricing.ContainsKey($currentSku)) { $dtuPricing[$currentSku].DTU } else { $currentCapacity }
        } elseif ($currentEdition -eq "Premium") {
            $currentTierDisplay = $currentSku  # P1, P2, etc.
            $currentDTULimit = if ($dtuPricing.ContainsKey($currentSku)) { $dtuPricing[$currentSku].DTU } else { $currentCapacity }
        } elseif ($currentEdition -eq "GeneralPurpose" -or $currentEdition -eq "BusinessCritical") {
            $currentTierDisplay = "$currentEdition (vCore: $currentCapacity)"
            $currentDTULimit = $currentCapacity * 100  # Approximate
        } elseif ($db.SkuName -eq "ElasticPool") {
            $currentTierDisplay = "ElasticPool"
            $currentDTULimit = 0
        } else {
            $currentTierDisplay = "$currentEdition $currentSku"
            $currentDTULimit = $currentCapacity
        }
        
        # Current monthly cost
        $currentMonthlyCost = if ($dtuPricing.ContainsKey($currentSku)) { 
            $dtuPricing[$currentSku].Cost 
        } else { 
            switch ($currentEdition) {
                "Basic" { 5 }
                "Standard" { 30 }
                "Premium" { 465 }
                default { 0 }
            }
        }
        
        # Get metrics (last 7 days)
        $endTime = Get-Date
        $startTime = $endTime.AddDays(-7)
        
        $avgDTU = 0
        $maxDTU = 0
        $totalConnections = 0
        
        try {
            $dtuMetric = Get-AzMetric -ResourceId $db.ResourceId -MetricName "dtu_consumption_percent" -StartTime $startTime -EndTime $endTime -TimeGrain (New-TimeSpan -Hours 1) -AggregationType Average -ErrorAction SilentlyContinue
            
            if ($dtuMetric -and $dtuMetric.Data) {
                $dtuData = $dtuMetric.Data.Average | Where-Object { $null -ne $_ }
                if ($dtuData.Count -gt 0) {
                    $avgDTU = [math]::Round(($dtuData | Measure-Object -Average).Average, 2)
                    $maxDTU = [math]::Round(($dtuData | Measure-Object -Maximum).Maximum, 2)
                }
            }
            
            $connectionMetric = Get-AzMetric -ResourceId $db.ResourceId -MetricName "connection_successful" -StartTime $startTime -EndTime $endTime -TimeGrain (New-TimeSpan -Hours 1) -AggregationType Total -ErrorAction SilentlyContinue
            
            if ($connectionMetric -and $connectionMetric.Data) {
                $connData = $connectionMetric.Data.Total | Where-Object { $null -ne $_ }
                if ($connData.Count -gt 0) {
                    $totalConnections = [math]::Round(($connData | Measure-Object -Sum).Sum, 0)
                }
            }
        } catch { }
        
        # Calculate actual DTU used (based on percentage)
        $actualDTUUsed = [math]::Round(($avgDTU / 100) * $currentDTULimit, 2)
        $peakDTUUsed = [math]::Round(($maxDTU / 100) * $currentDTULimit, 2)
        
        # Determine recommendation
        $recommendedTier = $currentTierDisplay
        $recommendedCost = $currentMonthlyCost
        $savings = 0
        $recommendation = "No change recommended"
        $priority = "Low"
        
        # Skip elastic pool databases
        if ($db.SkuName -ne "ElasticPool") {
            
            # UNUSED DATABASE
            if ($avgDTU -eq 0 -and $maxDTU -eq 0 -and $totalConnections -eq 0) {
                $recommendedTier = "ELIMINATE"
                $recommendedCost = 0
                $savings = $currentMonthlyCost
                $recommendation = "UNUSED DATABASE - Candidate for immediate decommission"
                $priority = "Critical"
            }
            # Very low usage - downgrade to Basic
            elseif ($avgDTU -lt 5 -and $maxDTU -lt 15 -and $currentSku -notin @("Basic")) {
                $recommendedTier = "Basic"
                $recommendedCost = 5
                $savings = $currentMonthlyCost - 5
                $recommendation = "Very low utilization - downgrade to Basic"
                $priority = "High"
            }
            # Low usage - downgrade to S0
            elseif ($avgDTU -lt 10 -and $maxDTU -lt 25 -and $currentSku -notin @("Basic", "S0")) {
                $recommendedTier = "S0"
                $recommendedCost = 15
                $savings = $currentMonthlyCost - 15
                $recommendation = "Low utilization - downgrade to S0"
                $priority = "High"
            }
            # Low-Medium usage - downgrade to S1
            elseif ($avgDTU -lt 20 -and $maxDTU -lt 40 -and $currentSku -notin @("Basic", "S0", "S1")) {
                $recommendedTier = "S1"
                $recommendedCost = 30
                $savings = $currentMonthlyCost - 30
                $recommendation = "Low utilization - downgrade to S1"
                $priority = "High"
            }
            # Moderate usage - downgrade to S2
            elseif ($avgDTU -lt 40 -and $maxDTU -lt 60 -and $currentSku -notin @("Basic", "S0", "S1", "S2")) {
                $recommendedTier = "S2"
                $recommendedCost = 75
                $savings = $currentMonthlyCost - 75
                $recommendation = "Moderate utilization - downgrade to S2"
                $priority = "Medium"
            }
            # HIGH usage - consider upgrade
            elseif ($avgDTU -gt 80 -or $maxDTU -gt 95) {
                $recommendation = "High utilization - consider upgrading to prevent performance issues"
                $priority = "High"
            }
        }
        
        if ($savings -lt 0) { $savings = 0 }
        
        $totalCurrentCost += $currentMonthlyCost
        $totalRecommendedCost += $recommendedCost
        
        # Add to results
        $allDatabases += [PSCustomObject]@{
            ResourceGroup = $resourceGroup
            Server = $serverName
            Database = $dbName
            CurrentEdition = $currentEdition
            CurrentTier = $currentTierDisplay
            CurrentDTULimit = $currentDTULimit
            AvgDTUPercent = $avgDTU
            MaxDTUPercent = $maxDTU
            ActualDTUUsed = $actualDTUUsed
            PeakDTUUsed = $peakDTUUsed
            Connections7Days = $totalConnections
            CurrentMonthlyCost = $currentMonthlyCost
            RecommendedTier = $recommendedTier
            RecommendedCost = $recommendedCost
            MonthlySavings = $savings
            AnnualSavings = $savings * 12
            Recommendation = $recommendation
            Priority = $priority
        }
        
        Write-Host "    $dbName : $currentTierDisplay -> $recommendedTier" -ForegroundColor $(if ($savings -gt 0) { "Yellow" } else { "Gray" })
    }
}

# Export to CSV
$csvPath = Join-Path $OutputPath "SQL_DTU_Audit_$timestamp.csv"
$allDatabases | Export-Csv -Path $csvPath -NoTypeInformation

# Export to Excel-friendly format (tab-separated)
$xlsPath = Join-Path $OutputPath "SQL_DTU_Audit_$timestamp.txt"
$allDatabases | ConvertTo-Csv -Delimiter "`t" -NoTypeInformation | Out-File $xlsPath

# Generate HTML Report
$htmlPath = Join-Path $OutputPath "SQL_DTU_Audit_$timestamp.html"
$totalSavings = $totalCurrentCost - $totalRecommendedCost

$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>SQL Database DTU Audit - $timestamp</title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 100%; margin: 0 auto; }
        .header { background: linear-gradient(135deg, #0078d4 0%, #00bcf2 100%); color: white; padding: 30px; border-radius: 8px; margin-bottom: 20px; }
        .header h1 { margin: 0; font-size: 28px; }
        .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; margin-bottom: 30px; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); text-align: center; }
        .card h3 { margin: 0 0 10px 0; color: #666; font-size: 14px; }
        .card .value { font-size: 32px; font-weight: bold; color: #0078d4; }
        .card .value.savings { color: #107c10; }
        .card .value.critical { color: #d13438; }
        table { width: 100%; border-collapse: collapse; background: white; box-shadow: 0 2px 10px rgba(0,0,0,0.1); border-radius: 8px; overflow: hidden; }
        th { background: #0078d4; color: white; padding: 12px 8px; text-align: left; font-size: 12px; white-space: nowrap; }
        td { padding: 10px 8px; border-bottom: 1px solid #eee; font-size: 12px; }
        tr:hover { background: #f0f8ff; }
        .tier-current { background: #e1f5fe; padding: 4px 8px; border-radius: 4px; font-weight: bold; }
        .tier-recommended { background: #e8f5e9; padding: 4px 8px; border-radius: 4px; font-weight: bold; color: #2e7d32; }
        .tier-eliminate { background: #ffebee; padding: 4px 8px; border-radius: 4px; font-weight: bold; color: #c62828; }
        .priority-critical { background: #d13438; color: white; padding: 2px 8px; border-radius: 4px; }
        .priority-high { background: #ff8c00; color: white; padding: 2px 8px; border-radius: 4px; }
        .priority-medium { background: #ffc107; color: black; padding: 2px 8px; border-radius: 4px; }
        .priority-low { background: #e0e0e0; color: #666; padding: 2px 8px; border-radius: 4px; }
        .savings { color: #107c10; font-weight: bold; }
        .timestamp { color: rgba(255,255,255,0.8); margin-top: 10px; }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>📊 SQL Database DTU Audit Report</h1>
        <p>Subscription: $subName</p>
        <p class="timestamp">Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | Author: Syed Rizvi</p>
    </div>
    
    <div class="summary">
        <div class="card">
            <h3>Total Databases</h3>
            <div class="value">$($allDatabases.Count)</div>
        </div>
        <div class="card">
            <h3>Current Monthly Cost</h3>
            <div class="value">`$$([math]::Round($totalCurrentCost, 0))</div>
        </div>
        <div class="card">
            <h3>Recommended Monthly Cost</h3>
            <div class="value">`$$([math]::Round($totalRecommendedCost, 0))</div>
        </div>
        <div class="card">
            <h3>Potential Monthly Savings</h3>
            <div class="value savings">`$$([math]::Round($totalSavings, 0))</div>
        </div>
        <div class="card">
            <h3>Potential Annual Savings</h3>
            <div class="value savings">`$$([math]::Round($totalSavings * 12, 0))</div>
        </div>
        <div class="card">
            <h3>Databases to Optimize</h3>
            <div class="value critical">$($allDatabases | Where-Object { $_.MonthlySavings -gt 0 } | Measure-Object).Count</div>
        </div>
    </div>
    
    <h2>Database Details</h2>
    <table>
        <tr>
            <th>Server</th>
            <th>Database</th>
            <th>CURRENT TIER</th>
            <th>DTU Limit</th>
            <th>Avg DTU %</th>
            <th>Max DTU %</th>
            <th>Connections</th>
            <th>Current Cost</th>
            <th>RECOMMENDED</th>
            <th>New Cost</th>
            <th>Savings/Mo</th>
            <th>Priority</th>
            <th>Recommendation</th>
        </tr>
"@

foreach ($db in $allDatabases | Sort-Object -Property MonthlySavings -Descending) {
    $priorityClass = switch ($db.Priority) {
        "Critical" { "priority-critical" }
        "High" { "priority-high" }
        "Medium" { "priority-medium" }
        default { "priority-low" }
    }
    
    $recommendedClass = if ($db.RecommendedTier -eq "ELIMINATE") { "tier-eliminate" } else { "tier-recommended" }
    
    $html += @"
        <tr>
            <td>$($db.Server)</td>
            <td><strong>$($db.Database)</strong></td>
            <td><span class="tier-current">$($db.CurrentTier)</span></td>
            <td>$($db.CurrentDTULimit)</td>
            <td>$($db.AvgDTUPercent)%</td>
            <td>$($db.MaxDTUPercent)%</td>
            <td>$($db.Connections7Days)</td>
            <td>`$$($db.CurrentMonthlyCost)</td>
            <td><span class="$recommendedClass">$($db.RecommendedTier)</span></td>
            <td>`$$($db.RecommendedCost)</td>
            <td class="savings">`$$($db.MonthlySavings)</td>
            <td><span class="$priorityClass">$($db.Priority)</span></td>
            <td>$($db.Recommendation)</td>
        </tr>
"@
}

$html += @"
    </table>
    
    <h2 style="margin-top:30px;">Legend</h2>
    <ul>
        <li><strong>Current Tier</strong> - What the database is running on NOW (S0, S1, S2, Basic, etc.)</li>
        <li><strong>DTU Limit</strong> - Maximum DTUs available for the current tier</li>
        <li><strong>Avg/Max DTU %</strong> - Actual usage over last 7 days</li>
        <li><strong>Recommended</strong> - Suggested tier based on usage</li>
        <li><span class="priority-critical">Critical</span> - Unused database, eliminate immediately</li>
        <li><span class="priority-high">High</span> - Significant savings opportunity</li>
        <li><span class="priority-medium">Medium</span> - Moderate savings opportunity</li>
    </ul>
</div>
</body>
</html>
"@

$html | Out-File -FilePath $htmlPath -Encoding UTF8

# Display summary
Write-Host ""
Write-Host "=============================================================" -ForegroundColor Green
Write-Host "                    AUDIT COMPLETE!" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "SUMMARY:" -ForegroundColor Yellow
Write-Host "  Total Databases:         $($allDatabases.Count)" -ForegroundColor White
Write-Host "  Current Monthly Cost:    `$$([math]::Round($totalCurrentCost, 0))" -ForegroundColor White
Write-Host "  Recommended Cost:        `$$([math]::Round($totalRecommendedCost, 0))" -ForegroundColor White
Write-Host "  Potential Monthly Savings: `$$([math]::Round($totalSavings, 0))" -ForegroundColor Green
Write-Host "  Potential Annual Savings:  `$$([math]::Round($totalSavings * 12, 0))" -ForegroundColor Green
Write-Host ""
Write-Host "REPORTS SAVED:" -ForegroundColor Yellow
Write-Host "  CSV:  $csvPath" -ForegroundColor Cyan
Write-Host "  HTML: $htmlPath" -ForegroundColor Cyan
Write-Host ""

# Open HTML report
try {
    Start-Process $htmlPath
} catch {
    Write-Host "Open report manually: $htmlPath" -ForegroundColor Yellow
}
