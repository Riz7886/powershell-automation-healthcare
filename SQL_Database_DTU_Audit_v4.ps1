<#
.SYNOPSIS
    SQL Database DTU Audit - Shows Edition, SKU Tier (S0, S1, S2), Size
    Author: Syed Rizvi

.DESCRIPTION
    READ-ONLY audit script that shows:
    - Edition (Basic, Standard, Premium)
    - SKU Tier (S0, S1, S2, S3, P1, P2, etc.) - FIXED!
    - Current Database Size (GB)
    - DTU Usage and Recommendations

    *** THIS SCRIPT MAKES NO CHANGES - READ ONLY ***

.EXAMPLE
    .\SQL_Database_DTU_Audit_v4.ps1
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
Write-Host "    SQL DATABASE DTU AUDIT v4 - READ ONLY" -ForegroundColor Cyan
Write-Host "    Author: Syed Rizvi" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "*** THIS SCRIPT MAKES NO CHANGES - READ ONLY ***" -ForegroundColor Green
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
        
        # =====================================================
        # GET CURRENT TIER INFO - EDITION, SKU TIER, SIZE
        # =====================================================
        
        # Edition: Basic, Standard, Premium, GeneralPurpose, etc.
        $currentEdition = $db.Edition
        
        # THIS IS THE FIX - Use CurrentServiceObjectiveName to get S0, S1, S2, etc.
        # NOT SkuName which returns "Standard"
        $currentServiceObjective = $db.CurrentServiceObjectiveName
        
        # Fallback options if CurrentServiceObjectiveName is empty
        if ([string]::IsNullOrEmpty($currentServiceObjective)) {
            $currentServiceObjective = $db.RequestedServiceObjectiveName
        }
        if ([string]::IsNullOrEmpty($currentServiceObjective)) {
            $currentServiceObjective = $db.SkuName
        }
        
        # For Elastic Pool databases
        if ($db.SkuName -eq "ElasticPool") {
            $currentServiceObjective = "ElasticPool"
            $currentEdition = "ElasticPool"
        }
        
        # Current capacity (DTUs or vCores)
        $currentCapacity = $db.Capacity
        
        # Get database SIZE
        $currentSizeGB = 0
        $maxSizeGB = 0
        
        try {
            # MaxSizeBytes is the max allowed size
            $maxSizeGB = [math]::Round($db.MaxSizeBytes / 1GB, 2)
            
            # Get actual used space via metric
            $endTime = Get-Date
            $startTime = $endTime.AddHours(-2)
            $sizeMetric = Get-AzMetric -ResourceId $db.ResourceId -MetricName "storage" -StartTime $startTime -EndTime $endTime -TimeGrain (New-TimeSpan -Hours 1) -AggregationType Maximum -ErrorAction SilentlyContinue
            
            if ($sizeMetric -and $sizeMetric.Data) {
                $sizeData = $sizeMetric.Data.Maximum | Where-Object { $null -ne $_ }
                if ($sizeData) {
                    $lastSize = $sizeData | Select-Object -Last 1
                    if ($lastSize) {
                        $currentSizeGB = [math]::Round($lastSize / 1GB, 2)
                    }
                }
            }
            
            # Fallback: try allocated_data_storage
            if ($currentSizeGB -eq 0) {
                $allocMetric = Get-AzMetric -ResourceId $db.ResourceId -MetricName "allocated_data_storage" -StartTime $startTime -EndTime $endTime -TimeGrain (New-TimeSpan -Hours 1) -AggregationType Maximum -ErrorAction SilentlyContinue
                if ($allocMetric -and $allocMetric.Data) {
                    $allocData = $allocMetric.Data.Maximum | Where-Object { $null -ne $_ } | Select-Object -Last 1
                    if ($allocData) {
                        $currentSizeGB = [math]::Round($allocData / 1GB, 2)
                    }
                }
            }
        } catch { }
        
        # Determine DTU Limit based on service objective (S0, S1, S2, etc.)
        $currentDTULimit = 0
        if ($dtuPricing.ContainsKey($currentServiceObjective)) {
            $currentDTULimit = $dtuPricing[$currentServiceObjective].DTU
        } elseif ($currentEdition -eq "Basic") {
            $currentDTULimit = 5
        } elseif ($currentCapacity -and $currentCapacity -gt 0) {
            $currentDTULimit = $currentCapacity
        }
        
        # Current monthly cost based on service objective
        $currentMonthlyCost = 0
        if ($dtuPricing.ContainsKey($currentServiceObjective)) { 
            $currentMonthlyCost = $dtuPricing[$currentServiceObjective].Cost 
        } elseif ($currentEdition -eq "Basic") {
            $currentMonthlyCost = 5
        } elseif ($currentEdition -eq "Standard") {
            # Estimate based on capacity
            $currentMonthlyCost = switch ($currentCapacity) {
                10 { 15 }
                20 { 30 }
                50 { 75 }
                100 { 150 }
                200 { 300 }
                default { 30 }
            }
        } elseif ($currentEdition -eq "Premium") {
            $currentMonthlyCost = 465
        }
        
        # Get DTU metrics (last 7 days)
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
        
        # Determine recommendation
        $recommendedTier = $currentServiceObjective
        $recommendedCost = $currentMonthlyCost
        $savings = 0
        $recommendation = "No change recommended"
        $priority = "Low"
        
        # Skip elastic pool databases for tier recommendations
        if ($currentServiceObjective -ne "ElasticPool") {
            
            # UNUSED DATABASE
            if ($avgDTU -eq 0 -and $maxDTU -eq 0 -and $totalConnections -eq 0) {
                $recommendedTier = "ELIMINATE"
                $recommendedCost = 0
                $savings = $currentMonthlyCost
                $recommendation = "UNUSED DATABASE - Candidate for immediate decommission"
                $priority = "Critical"
            }
            # Very low usage - downgrade to Basic
            elseif ($avgDTU -lt 5 -and $maxDTU -lt 15 -and $currentServiceObjective -notin @("Basic")) {
                $recommendedTier = "Basic"
                $recommendedCost = 5
                $savings = $currentMonthlyCost - 5
                $recommendation = "Very low utilization - downgrade to Basic"
                $priority = "High"
            }
            # Low usage - downgrade to S0
            elseif ($avgDTU -lt 10 -and $maxDTU -lt 25 -and $currentServiceObjective -notin @("Basic", "S0")) {
                $recommendedTier = "S0"
                $recommendedCost = 15
                $savings = $currentMonthlyCost - 15
                $recommendation = "Low utilization - downgrade to S0"
                $priority = "High"
            }
            # Low-Medium usage - downgrade to S1
            elseif ($avgDTU -lt 20 -and $maxDTU -lt 40 -and $currentServiceObjective -notin @("Basic", "S0", "S1")) {
                $recommendedTier = "S1"
                $recommendedCost = 30
                $savings = $currentMonthlyCost - 30
                $recommendation = "Low utilization - downgrade to S1"
                $priority = "High"
            }
            # Moderate usage - downgrade to S2
            elseif ($avgDTU -lt 40 -and $maxDTU -lt 60 -and $currentServiceObjective -notin @("Basic", "S0", "S1", "S2")) {
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
        
        # Add to results - SkuTier now shows S0, S1, S2, etc.
        $allDatabases += [PSCustomObject]@{
            ResourceGroup = $resourceGroup
            Server = $serverName
            Database = $dbName
            Edition = $currentEdition
            SkuTier = $currentServiceObjective
            DTULimit = $currentDTULimit
            CurrentSizeGB = $currentSizeGB
            MaxSizeGB = $maxSizeGB
            AvgDTUPercent = $avgDTU
            MaxDTUPercent = $maxDTU
            Connections7Days = $totalConnections
            CurrentCost = $currentMonthlyCost
            RecommendedTier = $recommendedTier
            RecommendedCost = $recommendedCost
            MonthlySavings = $savings
            AnnualSavings = $savings * 12
            Recommendation = $recommendation
            Priority = $priority
        }
        
        Write-Host "    $dbName : $currentEdition / $currentServiceObjective (${currentSizeGB}GB) -> $recommendedTier" -ForegroundColor $(if ($savings -gt 0) { "Yellow" } else { "Gray" })
    }
}

# =====================================================
# EXPORT TO CSV
# =====================================================
$csvPath = Join-Path $OutputPath "SQL_DTU_Audit_$timestamp.csv"
$allDatabases | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host ""
Write-Host "CSV saved: $csvPath" -ForegroundColor Green

# =====================================================
# GENERATE HTML REPORT
# =====================================================
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
        .readonly-badge { background: #107c10; padding: 5px 15px; border-radius: 20px; font-size: 14px; display: inline-block; margin-top: 10px; }
        .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 15px; margin-bottom: 30px; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); text-align: center; }
        .card h3 { margin: 0 0 10px 0; color: #666; font-size: 12px; text-transform: uppercase; }
        .card .value { font-size: 28px; font-weight: bold; color: #0078d4; }
        .card .value.savings { color: #107c10; }
        .card .value.critical { color: #d13438; }
        table { width: 100%; border-collapse: collapse; background: white; box-shadow: 0 2px 10px rgba(0,0,0,0.1); border-radius: 8px; overflow: hidden; font-size: 12px; }
        th { background: #0078d4; color: white; padding: 10px 6px; text-align: left; font-size: 11px; white-space: nowrap; }
        td { padding: 8px 6px; border-bottom: 1px solid #eee; }
        tr:hover { background: #f0f8ff; }
        .edition { background: #e3f2fd; padding: 3px 8px; border-radius: 4px; font-weight: bold; color: #1565c0; }
        .sku { background: #fff3e0; padding: 3px 8px; border-radius: 4px; font-weight: bold; color: #e65100; }
        .size { background: #f3e5f5; padding: 3px 8px; border-radius: 4px; color: #7b1fa2; }
        .recommended { background: #e8f5e9; padding: 3px 8px; border-radius: 4px; font-weight: bold; color: #2e7d32; }
        .eliminate { background: #ffebee; padding: 3px 8px; border-radius: 4px; font-weight: bold; color: #c62828; }
        .priority-critical { background: #d13438; color: white; padding: 2px 6px; border-radius: 4px; font-size: 10px; }
        .priority-high { background: #ff8c00; color: white; padding: 2px 6px; border-radius: 4px; font-size: 10px; }
        .priority-medium { background: #ffc107; color: black; padding: 2px 6px; border-radius: 4px; font-size: 10px; }
        .priority-low { background: #e0e0e0; color: #666; padding: 2px 6px; border-radius: 4px; font-size: 10px; }
        .savings-cell { color: #107c10; font-weight: bold; }
        .timestamp { color: rgba(255,255,255,0.8); margin-top: 10px; font-size: 14px; }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>📊 SQL Database DTU Audit Report</h1>
        <p>Subscription: $subName</p>
        <p class="timestamp">Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | Author: Syed Rizvi</p>
        <div class="readonly-badge">✓ READ-ONLY - NO CHANGES MADE</div>
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
            <h3>Recommended Cost</h3>
            <div class="value">`$$([math]::Round($totalRecommendedCost, 0))</div>
        </div>
        <div class="card">
            <h3>Monthly Savings</h3>
            <div class="value savings">`$$([math]::Round($totalSavings, 0))</div>
        </div>
        <div class="card">
            <h3>Annual Savings</h3>
            <div class="value savings">`$$([math]::Round($totalSavings * 12, 0))</div>
        </div>
        <div class="card">
            <h3>Need Action</h3>
            <div class="value critical">$($allDatabases | Where-Object { $_.MonthlySavings -gt 0 } | Measure-Object).Count</div>
        </div>
    </div>
    
    <h2>Database Analysis</h2>
    <table>
        <tr>
            <th>Server</th>
            <th>Database</th>
            <th>Edition</th>
            <th>SKU Tier</th>
            <th>DTU</th>
            <th>Size GB</th>
            <th>Max GB</th>
            <th>Avg DTU%</th>
            <th>Max DTU%</th>
            <th>Connections</th>
            <th>Cost/Mo</th>
            <th>Recommended</th>
            <th>New Cost</th>
            <th>Savings</th>
            <th>Priority</th>
        </tr>
"@

foreach ($db in $allDatabases | Sort-Object -Property MonthlySavings -Descending) {
    $priorityClass = switch ($db.Priority) {
        "Critical" { "priority-critical" }
        "High" { "priority-high" }
        "Medium" { "priority-medium" }
        default { "priority-low" }
    }
    
    $recommendedClass = if ($db.RecommendedTier -eq "ELIMINATE") { "eliminate" } else { "recommended" }
    
    $html += @"
        <tr>
            <td>$($db.Server)</td>
            <td><strong>$($db.Database)</strong></td>
            <td><span class="edition">$($db.Edition)</span></td>
            <td><span class="sku">$($db.SkuTier)</span></td>
            <td>$($db.DTULimit)</td>
            <td><span class="size">$($db.CurrentSizeGB)</span></td>
            <td>$($db.MaxSizeGB)</td>
            <td>$($db.AvgDTUPercent)%</td>
            <td>$($db.MaxDTUPercent)%</td>
            <td>$($db.Connections7Days)</td>
            <td>`$$($db.CurrentCost)</td>
            <td><span class="$recommendedClass">$($db.RecommendedTier)</span></td>
            <td>`$$($db.RecommendedCost)</td>
            <td class="savings-cell">`$$($db.MonthlySavings)</td>
            <td><span class="$priorityClass">$($db.Priority)</span></td>
        </tr>
"@
}

$html += @"
    </table>
    
    <h2 style="margin-top:30px;">Legend</h2>
    <table style="width:auto;">
        <tr><td><span class="edition">Edition</span></td><td>Basic, Standard, Premium</td></tr>
        <tr><td><span class="sku">SKU Tier</span></td><td>S0, S1, S2, S3, S4, P1, P2, etc.</td></tr>
        <tr><td><span class="size">Size GB</span></td><td>Current database size</td></tr>
        <tr><td>DTU</td><td>DTU limit (5, 10, 20, 50, 100, etc.)</td></tr>
        <tr><td><span class="recommended">Recommended</span></td><td>Suggested tier based on usage</td></tr>
        <tr><td><span class="eliminate">ELIMINATE</span></td><td>Unused - candidate for deletion</td></tr>
    </table>
    
    <p style="margin-top:30px; color:#107c10; font-weight:bold;">
        ✓ This is a READ-ONLY audit. No changes were made to any databases.
    </p>
</div>
</body>
</html>
"@

$html | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Host "HTML saved: $htmlPath" -ForegroundColor Green

# =====================================================
# DISPLAY SUMMARY
# =====================================================
Write-Host ""
Write-Host "=============================================================" -ForegroundColor Green
Write-Host "                    AUDIT COMPLETE!" -ForegroundColor Green
Write-Host "            *** NO CHANGES WERE MADE ***" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "SUMMARY:" -ForegroundColor Yellow
Write-Host "  Total Databases:           $($allDatabases.Count)" -ForegroundColor White
Write-Host "  Current Monthly Cost:      `$$([math]::Round($totalCurrentCost, 0))" -ForegroundColor White
Write-Host "  Potential Monthly Savings: `$$([math]::Round($totalSavings, 0))" -ForegroundColor Green
Write-Host "  Potential Annual Savings:  `$$([math]::Round($totalSavings * 12, 0))" -ForegroundColor Green
Write-Host ""
Write-Host "OUTPUT FILES:" -ForegroundColor Yellow
Write-Host "  CSV:  $csvPath" -ForegroundColor Cyan
Write-Host "  HTML: $htmlPath" -ForegroundColor Cyan
Write-Host ""

# Open HTML report
try {
    Start-Process $htmlPath
} catch {
    Write-Host "Open manually: $htmlPath" -ForegroundColor Yellow
}
