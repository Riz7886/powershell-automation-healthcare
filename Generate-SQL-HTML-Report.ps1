param(
    [string]$InputCSV = ".\AzureSQLAuditReport_*.csv",
    [string]$OutputHTML = ".\AzureSQLAuditReport.html"
)

$csvFile = Get-ChildItem $InputCSV | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $csvFile) { Write-Host "CSV not found" -ForegroundColor Red; exit }

$data = Import-Csv $csvFile.FullName
$totalDatabases = $data.Count
$underutilized = ($data | Where-Object { $_.StatusFlag -eq "UNDERUTILIZED" }).Count
$totalCurrentCost = ($data | Measure-Object -Property CurrentMonthlyCost -Sum).Sum
$totalSavings = ($data | Measure-Object -Property PotentialSavings -Sum).Sum
$annualSavings = $totalSavings * 12
$topSavings = $data | Sort-Object { [decimal]$_.PotentialSavings } -Descending | Select-Object -First 15

$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Azure SQL Cost Optimization Report</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', Arial, sans-serif; background: #f0f2f5; color: #333; }
        .header { background: linear-gradient(135deg, #0078d4, #00bcf2); color: white; padding: 40px; text-align: center; }
        .header h1 { font-size: 2.5em; margin-bottom: 10px; }
        .header p { font-size: 1.2em; opacity: 0.9; }
        .container { max-width: 1400px; margin: 0 auto; padding: 30px; }
        .summary-cards { display: grid; grid-template-columns: repeat(4, 1fr); gap: 20px; margin-bottom: 30px; }
        .card { background: white; border-radius: 12px; padding: 25px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); text-align: center; }
        .card.savings { background: linear-gradient(135deg, #107c10, #00cc6a); color: white; }
        .card.warning { background: linear-gradient(135deg, #ff8c00, #ffb900); color: white; }
        .card h3 { font-size: 0.9em; text-transform: uppercase; opacity: 0.8; margin-bottom: 10px; }
        .card .value { font-size: 2.5em; font-weight: bold; }
        .card .subtext { font-size: 0.85em; margin-top: 5px; opacity: 0.8; }
        .section { background: white; border-radius: 12px; padding: 25px; margin-bottom: 25px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .section h2 { color: #0078d4; margin-bottom: 20px; padding-bottom: 10px; border-bottom: 2px solid #f0f2f5; }
        table { width: 100%; border-collapse: collapse; }
        th { background: #0078d4; color: white; padding: 12px 15px; text-align: left; font-weight: 600; }
        td { padding: 12px 15px; border-bottom: 1px solid #e0e0e0; }
        tr:hover { background: #f8f9fa; }
        .status-underutilized { background: #fff4ce; color: #8a6d3b; padding: 4px 10px; border-radius: 12px; font-size: 0.85em; }
        .status-ok { background: #dff6dd; color: #107c10; padding: 4px 10px; border-radius: 12px; font-size: 0.85em; }
        .savings-amount { color: #107c10; font-weight: bold; }
        .current-cost { color: #d83b01; }
        .recommendation { background: #e6f2ff; padding: 4px 10px; border-radius: 8px; font-size: 0.85em; }
        .footer { text-align: center; padding: 20px; color: #666; font-size: 0.9em; }
        .chart-container { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 25px; }
        .chart-box { background: white; border-radius: 12px; padding: 25px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .bar { height: 30px; border-radius: 4px; margin: 8px 0; display: flex; align-items: center; padding-left: 10px; color: white; font-weight: bold; }
        .bar-underutilized { background: linear-gradient(90deg, #ff8c00, #ffb900); }
        .bar-ok { background: linear-gradient(90deg, #107c10, #00cc6a); }
        .tier-badge { display: inline-block; padding: 3px 8px; border-radius: 4px; font-size: 0.8em; font-weight: bold; }
        .tier-basic { background: #e0e0e0; color: #333; }
        .tier-standard { background: #0078d4; color: white; }
        .tier-premium { background: #8661c5; color: white; }
        @media (max-width: 1000px) { .summary-cards { grid-template-columns: repeat(2, 1fr); } }
        @media (max-width: 600px) { .summary-cards { grid-template-columns: 1fr; } }
    </style>
</head>
<body>
    <div class="header">
        <h1>Azure SQL Cost Optimization Report</h1>
        <p>Generated: $(Get-Date -Format "MMMM dd, yyyy 'at' hh:mm tt")</p>
    </div>
    <div class="container">
        <div class="summary-cards">
            <div class="card">
                <h3>Total Databases</h3>
                <div class="value">$totalDatabases</div>
                <div class="subtext">Analyzed</div>
            </div>
            <div class="card warning">
                <h3>Underutilized</h3>
                <div class="value">$underutilized</div>
                <div class="subtext">$([math]::Round(($underutilized/$totalDatabases)*100))% of total</div>
            </div>
            <div class="card">
                <h3>Current Monthly Spend</h3>
                <div class="value">`$$('{0:N0}' -f $totalCurrentCost)</div>
                <div class="subtext">Per month</div>
            </div>
            <div class="card savings">
                <h3>Potential Annual Savings</h3>
                <div class="value">`$$('{0:N0}' -f $annualSavings)</div>
                <div class="subtext">`$$('{0:N0}' -f $totalSavings)/month</div>
            </div>
        </div>

        <div class="chart-container">
            <div class="chart-box">
                <h2>Database Status Distribution</h2>
                <div class="bar bar-underutilized" style="width: $([math]::Round(($underutilized/$totalDatabases)*100))%">Underutilized: $underutilized</div>
                <div class="bar bar-ok" style="width: $([math]::Round((($totalDatabases-$underutilized)/$totalDatabases)*100))%">OK: $($totalDatabases - $underutilized)</div>
            </div>
            <div class="chart-box">
                <h2>Cost Breakdown</h2>
                <p style="margin: 15px 0;"><strong>Current Spend:</strong> <span class="current-cost">`$$('{0:N2}' -f $totalCurrentCost)/month</span></p>
                <p style="margin: 15px 0;"><strong>After Optimization:</strong> <span class="savings-amount">`$$('{0:N2}' -f ($totalCurrentCost - $totalSavings))/month</span></p>
                <p style="margin: 15px 0;"><strong>Monthly Savings:</strong> <span class="savings-amount">`$$('{0:N2}' -f $totalSavings)</span></p>
                <p style="margin: 15px 0;"><strong>Annual Savings:</strong> <span class="savings-amount">`$$('{0:N2}' -f $annualSavings)</span></p>
            </div>
        </div>

        <div class="section">
            <h2>Top 15 Savings Opportunities</h2>
            <table>
                <tr>
                    <th>Database</th>
                    <th>Server</th>
                    <th>Current Tier</th>
                    <th>Current Cost</th>
                    <th>Avg DTU %</th>
                    <th>Max DTU %</th>
                    <th>Recommended</th>
                    <th>Potential Savings</th>
                </tr>
"@

foreach ($db in $topSavings) {
    $tierClass = switch -Wildcard ($db.Edition) {
        "Basic" { "tier-basic" }
        "Standard" { "tier-standard" }
        "Premium" { "tier-premium" }
        default { "tier-standard" }
    }
    $recTierClass = switch -Wildcard ($db.RecommendedTier) {
        "Basic" { "tier-basic" }
        "Standard" { "tier-standard" }
        "Premium" { "tier-premium" }
        default { "tier-basic" }
    }
    $html += @"
                <tr>
                    <td><strong>$($db.DatabaseName)</strong></td>
                    <td>$($db.ServerName)</td>
                    <td><span class="tier-badge $tierClass">$($db.ServiceObjective)</span></td>
                    <td class="current-cost">`$$('{0:N2}' -f [decimal]$db.CurrentMonthlyCost)</td>
                    <td>$($db.AvgDTUPercent)%</td>
                    <td>$($db.MaxDTUPercent)%</td>
                    <td><span class="tier-badge $recTierClass">$($db.RecommendedTier)</span></td>
                    <td class="savings-amount">`$$('{0:N2}' -f [decimal]$db.PotentialSavings)/mo</td>
                </tr>
"@
}

$html += @"
            </table>
        </div>

        <div class="section">
            <h2>All Underutilized Databases</h2>
            <table>
                <tr>
                    <th>Database</th>
                    <th>Server</th>
                    <th>Subscription</th>
                    <th>Current Tier</th>
                    <th>DTU</th>
                    <th>Avg DTU %</th>
                    <th>Cost/Month</th>
                    <th>Status</th>
                </tr>
"@

$underutilizedDbs = $data | Where-Object { $_.StatusFlag -eq "UNDERUTILIZED" } | Sort-Object { [decimal]$_.CurrentMonthlyCost } -Descending | Select-Object -First 50

foreach ($db in $underutilizedDbs) {
    $tierClass = switch -Wildcard ($db.Edition) {
        "Basic" { "tier-basic" }
        "Standard" { "tier-standard" }
        "Premium" { "tier-premium" }
        default { "tier-standard" }
    }
    $html += @"
                <tr>
                    <td><strong>$($db.DatabaseName)</strong></td>
                    <td>$($db.ServerName)</td>
                    <td>$($db.SubscriptionName)</td>
                    <td><span class="tier-badge $tierClass">$($db.ServiceObjective)</span></td>
                    <td>$($db.CurrentDTU)</td>
                    <td>$($db.AvgDTUPercent)%</td>
                    <td class="current-cost">`$$('{0:N2}' -f [decimal]$db.CurrentMonthlyCost)</td>
                    <td><span class="status-underutilized">Underutilized</span></td>
                </tr>
"@
}

$html += @"
            </table>
        </div>

        <div class="section">
            <h2>Recommendations Summary</h2>
            <table>
                <tr>
                    <th>Action</th>
                    <th>Count</th>
                    <th>Total Savings</th>
                </tr>
                <tr>
                    <td>Downgrade to Basic</td>
                    <td>$(($data | Where-Object { $_.RecommendedTier -eq "Basic" }).Count)</td>
                    <td class="savings-amount">`$$('{0:N2}' -f (($data | Where-Object { $_.RecommendedTier -eq "Basic" } | Measure-Object -Property PotentialSavings -Sum).Sum))/mo</td>
                </tr>
                <tr>
                    <td>Downgrade within Standard</td>
                    <td>$(($data | Where-Object { $_.RecommendedTier -like "S*" -and $_.RecommendedTier -ne $_.ServiceObjective }).Count)</td>
                    <td class="savings-amount">`$$('{0:N2}' -f (($data | Where-Object { $_.RecommendedTier -like "S*" -and $_.RecommendedTier -ne $_.ServiceObjective } | Measure-Object -Property PotentialSavings -Sum).Sum))/mo</td>
                </tr>
                <tr>
                    <td>Downgrade within Premium</td>
                    <td>$(($data | Where-Object { $_.RecommendedTier -like "P*" -and $_.RecommendedTier -ne $_.ServiceObjective }).Count)</td>
                    <td class="savings-amount">`$$('{0:N2}' -f (($data | Where-Object { $_.RecommendedTier -like "P*" -and $_.RecommendedTier -ne $_.ServiceObjective } | Measure-Object -Property PotentialSavings -Sum).Sum))/mo</td>
                </tr>
            </table>
        </div>
    </div>
    <div class="footer">
        <p>Azure SQL Cost Optimization Audit | Generated by Infrastructure Team | $(Get-Date -Format "yyyy-MM-dd")</p>
    </div>
</body>
</html>
"@

$html | Out-File $OutputHTML -Encoding UTF8
Write-Host "HTML Report Generated: $OutputHTML" -ForegroundColor Green
Write-Host "Open in browser to view" -ForegroundColor Cyan
Start-Process $OutputHTML
