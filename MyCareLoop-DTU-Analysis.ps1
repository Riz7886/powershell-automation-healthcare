param(
    [Parameter(Mandatory=$false)]
    [int]$AnalysisDays = 14,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "$env:TEMP"
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportFile = Join-Path $OutputPath "MyCareLoop_DTU_Analysis_$timestamp.html"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  MYCARELOOP DATABASE DTU ANALYSIS" -ForegroundColor Cyan
Write-Host "  Analyzing Past $AnalysisDays Days" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$modules = @('Az.Accounts', 'Az.Sql', 'Az.Monitor')
foreach ($mod in $modules) {
    if (!(Get-Module -ListAvailable -Name $mod)) {
        Write-Host "Installing $mod..." -ForegroundColor Yellow
        Install-Module -Name $mod -Force -AllowClobber -Scope CurrentUser -ErrorAction SilentlyContinue
    }
    Import-Module $mod -ErrorAction SilentlyContinue
}

Write-Host "Connecting to Azure..." -ForegroundColor Yellow
try {
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount | Out-Null
        $context = Get-AzContext
    }
    Write-Host "Connected: $($context.Account.Id)" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Cannot connect to Azure" -ForegroundColor Red
    exit
}

Write-Host ""

$targetDatabases = @(
    "sqldb-aetna-prod",
    "sqldb-arch-prod",
    "sqldb-banner-prod",
    "sqldb-parkland-prod",
    "sqldb-magellan-prod",
    "sqldb-sentara-prod",
    "Pyx-Health",
    "sqldb-healthchoice-prod",
    "sqldb-humana-prod",
    "sqldb-partners-prod",
    "sqldb-pyx-central-prod",
    "sqldb-ubc-prod",
    "sqldb-bcbs-prod",
    "sqldb-chs-prod",
    "sqldb-lakeland-prod",
    "sqldb-arch-prod_Copy",
    "sqldb-multipass-prod",
    "sqldb-wrgm-prod"
)

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
$allResults = @()

$startDate = (Get-Date).AddDays(-$AnalysisDays)
$endDate = Get-Date

Write-Host "Scanning subscriptions for MyCareLoop databases..." -ForegroundColor Yellow
Write-Host ""

foreach ($sub in $subscriptions) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    
    $servers = Get-AzSqlServer -ErrorAction SilentlyContinue
    if (-not $servers) { continue }
    
    foreach ($server in $servers) {
        $databases = Get-AzSqlDatabase -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName -ErrorAction SilentlyContinue
        
        foreach ($db in $databases) {
            if ($db.DatabaseName -eq 'master') { continue }
            if ($targetDatabases -notcontains $db.DatabaseName) { continue }
            
            Write-Host "Analyzing: $($db.DatabaseName) on $($server.ServerName)..." -ForegroundColor Cyan
            
            $resourceId = $db.ResourceId
            
            try {
                $metrics = Get-AzMetric -ResourceId $resourceId `
                    -MetricName "dtu_consumption_percent" `
                    -StartTime $startDate `
                    -EndTime $endDate `
                    -TimeGrain 01:00:00 `
                    -AggregationType Average `
                    -ErrorAction SilentlyContinue
                
                if ($metrics -and $metrics.Data -and $metrics.Data.Count -gt 0) {
                    $validData = $metrics.Data | Where-Object { $_.Average -ne $null }
                    
                    if ($validData.Count -gt 0) {
                        $avgDTU = ($validData | Measure-Object -Property Average -Average).Average
                        $maxDTU = ($validData | Measure-Object -Property Average -Maximum).Maximum
                        $minDTU = ($validData | Measure-Object -Property Average -Minimum).Minimum
                        
                        $avgDTU = [math]::Round($avgDTU, 2)
                        $maxDTU = [math]::Round($maxDTU, 2)
                        $minDTU = [math]::Round($minDTU, 2)
                    } else {
                        $avgDTU = 0
                        $maxDTU = 0
                        $minDTU = 0
                    }
                } else {
                    $avgDTU = 0
                    $maxDTU = 0
                    $minDTU = 0
                }
            } catch {
                $avgDTU = 0
                $maxDTU = 0
                $minDTU = 0
            }
            
            $currentSKU = $db.CurrentServiceObjectiveName
            $currentEdition = $db.Edition
            
            $currentDTU = switch ($currentSKU) {
                "Basic" { 5 }
                "S0" { 10 }
                "S1" { 20 }
                "S2" { 50 }
                "S3" { 100 }
                "S4" { 200 }
                "S6" { 400 }
                "S7" { 800 }
                "S9" { 1600 }
                "S12" { 3000 }
                default { 0 }
            }
            
            $recommendedSKU = ""
            $recommendedDTU = 0
            $reasoning = ""
            
            if ($maxDTU -eq 0) {
                $recommendedSKU = "Basic"
                $recommendedDTU = 5
                $reasoning = "No usage detected - recommend Basic tier"
            } elseif ($maxDTU -lt 20) {
                $recommendedSKU = "Basic"
                $recommendedDTU = 5
                $reasoning = "Very low usage (max $maxDTU%) - Basic is sufficient"
            } elseif ($maxDTU -lt 40) {
                $recommendedSKU = "S0"
                $recommendedDTU = 10
                $reasoning = "Low usage (max $maxDTU%) - S0 recommended"
            } elseif ($maxDTU -lt 60) {
                $recommendedSKU = "S1"
                $recommendedDTU = 20
                $reasoning = "Moderate usage (max $maxDTU%) - S1 recommended"
            } elseif ($maxDTU -lt 75) {
                $recommendedSKU = "S2"
                $recommendedDTU = 50
                $reasoning = "Higher usage (max $maxDTU%) - S2 recommended"
            } elseif ($maxDTU -lt 85) {
                $recommendedSKU = "S3"
                $recommendedDTU = 100
                $reasoning = "High usage (max $maxDTU%) - S3 recommended for headroom"
            } else {
                $recommendedSKU = "S4"
                $recommendedDTU = 200
                $reasoning = "Very high usage (max $maxDTU%) - S4 recommended"
            }
            
            $currentCost = switch ($currentSKU) {
                "Basic" { 4.99 }
                "S0" { 15 }
                "S1" { 30 }
                "S2" { 75 }
                "S3" { 150 }
                "S4" { 300 }
                "S6" { 600 }
                "S7" { 1200 }
                "S9" { 2400 }
                "S12" { 4500 }
                default { 0 }
            }
            
            $recommendedCost = switch ($recommendedSKU) {
                "Basic" { 4.99 }
                "S0" { 15 }
                "S1" { 30 }
                "S2" { 75 }
                "S3" { 150 }
                "S4" { 300 }
                "S6" { 600 }
                "S7" { 1200 }
                "S9" { 2400 }
                "S12" { 4500 }
                default { 0 }
            }
            
            $savings = $currentCost - $recommendedCost
            $savingsAnnual = $savings * 12
            
            $status = if ($currentSKU -eq $recommendedSKU) {
                "Optimal"
            } elseif ($currentDTU -lt $recommendedDTU) {
                "Under-provisioned"
            } else {
                "Over-provisioned"
            }
            
            $allResults += [PSCustomObject]@{
                Subscription = $sub.Name
                ResourceGroup = $server.ResourceGroupName
                Server = $server.ServerName
                Database = $db.DatabaseName
                CurrentSKU = $currentSKU
                CurrentDTU = $currentDTU
                CurrentCost = $currentCost
                AvgDTUPercent = $avgDTU
                MaxDTUPercent = $maxDTU
                MinDTUPercent = $minDTU
                RecommendedSKU = $recommendedSKU
                RecommendedDTU = $recommendedDTU
                RecommendedCost = $recommendedCost
                MonthlySavings = $savings
                AnnualSavings = $savingsAnnual
                Status = $status
                Reasoning = $reasoning
            }
            
            Write-Host "  Current: $currentSKU ($currentDTU DTU) | Avg: $avgDTU% | Max: $maxDTU%" -ForegroundColor White
            Write-Host "  Recommended: $recommendedSKU ($recommendedDTU DTU) | Status: $status" -ForegroundColor $(if ($status -eq "Optimal") { "Green" } elseif ($status -eq "Under-provisioned") { "Red" } else { "Yellow" })
            Write-Host ""
        }
    }
}

$totalCurrentCost = ($allResults | Measure-Object -Property CurrentCost -Sum).Sum
$totalRecommendedCost = ($allResults | Measure-Object -Property RecommendedCost -Sum).Sum
$totalMonthlySavings = $totalCurrentCost - $totalRecommendedCost
$totalAnnualSavings = $totalMonthlySavings * 12

$optimalCount = ($allResults | Where-Object { $_.Status -eq "Optimal" }).Count
$overCount = ($allResults | Where-Object { $_.Status -eq "Over-provisioned" }).Count
$underCount = ($allResults | Where-Object { $_.Status -eq "Under-provisioned" }).Count

$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>MyCareLoop DTU Analysis - $AnalysisDays Day Report</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        }
        .container {
            background: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            max-width: 1400px;
            margin: 0 auto;
        }
        h1 {
            color: #333;
            border-bottom: 3px solid #667eea;
            padding-bottom: 10px;
        }
        .summary {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            border-radius: 8px;
            margin: 20px 0;
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
        }
        .summary-item {
            text-align: center;
        }
        .summary-value {
            font-size: 32px;
            font-weight: bold;
            margin: 10px 0;
        }
        .summary-label {
            font-size: 14px;
            opacity: 0.9;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }
        th {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 12px;
            text-align: left;
            font-weight: bold;
            font-size: 12px;
        }
        td {
            padding: 10px;
            border-bottom: 1px solid #ddd;
            font-size: 12px;
        }
        tr:hover {
            background: #f5f5f5;
        }
        .optimal {
            background: #d4edda;
            color: #155724;
            font-weight: bold;
        }
        .over {
            background: #fff3cd;
            color: #856404;
            font-weight: bold;
        }
        .under {
            background: #f8d7da;
            color: #721c24;
            font-weight: bold;
        }
        .savings-positive {
            color: green;
            font-weight: bold;
        }
        .savings-negative {
            color: red;
            font-weight: bold;
        }
        .footer {
            margin-top: 30px;
            text-align: center;
            color: #666;
            font-size: 12px;
        }
        .info-box {
            background: #e7f3ff;
            border-left: 4px solid #2196F3;
            padding: 15px;
            margin: 20px 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>MyCareLoop Database DTU Analysis</h1>
        
        <div class="info-box">
            <strong>Analysis Period:</strong> Past $AnalysisDays days ($(Get-Date $startDate -Format 'MM/dd/yyyy') - $(Get-Date $endDate -Format 'MM/dd/yyyy'))<br>
            <strong>Report Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')<br>
            <strong>Total Databases Analyzed:</strong> $($allResults.Count)
        </div>
        
        <div class="summary">
            <div class="summary-item">
                <div class="summary-label">OPTIMAL</div>
                <div class="summary-value">$optimalCount</div>
            </div>
            <div class="summary-item">
                <div class="summary-label">OVER-PROVISIONED</div>
                <div class="summary-value">$overCount</div>
            </div>
            <div class="summary-item">
                <div class="summary-label">UNDER-PROVISIONED</div>
                <div class="summary-value">$underCount</div>
            </div>
            <div class="summary-item">
                <div class="summary-label">MONTHLY SAVINGS</div>
                <div class="summary-value">`$$([math]::Round($totalMonthlySavings, 2))</div>
            </div>
            <div class="summary-item">
                <div class="summary-label">ANNUAL SAVINGS</div>
                <div class="summary-value">`$$([math]::Round($totalAnnualSavings, 2))</div>
            </div>
        </div>
        
        <table>
            <tr>
                <th>Database</th>
                <th>Server</th>
                <th>Current SKU</th>
                <th>Avg DTU%</th>
                <th>Max DTU%</th>
                <th>Recommended SKU</th>
                <th>Status</th>
                <th>Monthly Savings</th>
                <th>Reasoning</th>
            </tr>
"@

foreach ($result in $allResults | Sort-Object -Property MaxDTUPercent -Descending) {
    $statusClass = switch ($result.Status) {
        "Optimal" { "optimal" }
        "Over-provisioned" { "over" }
        "Under-provisioned" { "under" }
    }
    
    $savingsClass = if ($result.MonthlySavings -gt 0) { "savings-positive" } elseif ($result.MonthlySavings -lt 0) { "savings-negative" } else { "" }
    $savingsText = if ($result.MonthlySavings -gt 0) { "+`$$([math]::Round($result.MonthlySavings, 2))" } elseif ($result.MonthlySavings -lt 0) { "-`$$([math]::Round([math]::Abs($result.MonthlySavings), 2))" } else { "`$0" }
    
    $html += @"
            <tr>
                <td><strong>$($result.Database)</strong></td>
                <td>$($result.Server)</td>
                <td>$($result.CurrentSKU) ($($result.CurrentDTU) DTU)</td>
                <td>$($result.AvgDTUPercent)%</td>
                <td><strong>$($result.MaxDTUPercent)%</strong></td>
                <td>$($result.RecommendedSKU) ($($result.RecommendedDTU) DTU)</td>
                <td class="$statusClass">$($result.Status)</td>
                <td class="$savingsClass">$savingsText</td>
                <td>$($result.Reasoning)</td>
            </tr>
"@
}

$html += @"
        </table>
        
        <div class="footer">
            <p>Report generated by: Syed Rizvi | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
            <p>Analysis based on $AnalysisDays days of Azure Monitor DTU metrics</p>
        </div>
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  ANALYSIS COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Total Databases: $($allResults.Count)" -ForegroundColor White
Write-Host "Optimal: $optimalCount | Over-provisioned: $overCount | Under-provisioned: $underCount" -ForegroundColor White
Write-Host ""
Write-Host "Current Monthly Cost: `$$([math]::Round($totalCurrentCost, 2))" -ForegroundColor Yellow
Write-Host "Recommended Cost: `$$([math]::Round($totalRecommendedCost, 2))" -ForegroundColor Yellow
Write-Host "Potential Monthly Savings: `$$([math]::Round($totalMonthlySavings, 2))" -ForegroundColor $(if ($totalMonthlySavings -gt 0) { "Green" } else { "Red" })
Write-Host "Potential Annual Savings: `$$([math]::Round($totalAnnualSavings, 2))" -ForegroundColor $(if ($totalAnnualSavings -gt 0) { "Green" } else { "Red" })
Write-Host ""
Write-Host "Report saved: $reportFile" -ForegroundColor Green
Write-Host ""

Start-Process $reportFile

Write-Host "Opening report in browser..." -ForegroundColor Cyan
Write-Host ""
