param(
    [string]$InputCSV = ".\AzureSQLAuditReport_*.csv",
    [string]$OutputHTML = ".\AzureSQLAuditReport.html"
)

$csvFile = Get-ChildItem $InputCSV | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $csvFile) { Write-Host "CSV not found" -ForegroundColor Red; exit }

Write-Host "Processing: $($csvFile.Name)" -ForegroundColor Cyan
$data = Import-Csv $csvFile.FullName

$totalDatabases = $data.Count
$totalCurrentCost = 0
$totalSavings = 0
$totalUpgradeCost = 0

$savingsOpportunities = @()
$upgradeNeeded = @()

foreach ($row in $data) {
    $currentCost = [decimal]($row.CurrentMonthlyCost -replace '[^0-9.-]','')
    $recCost = [decimal]($row.RecommendedCost -replace '[^0-9.-]','')
    $totalCurrentCost += $currentCost
    
    if ($recCost -lt $currentCost -and $recCost -gt 0) {
        $savings = $currentCost - $recCost
        $totalSavings += $savings
        $savingsOpportunities += [PSCustomObject]@{
            Database = $row.DatabaseName
            Server = $row.ServerName
            Subscription = $row.SubscriptionName
            CurrentTier = $row.ServiceObjective
            CurrentCost = $currentCost
            AvgDTU = $row.AvgDTUPercent
            MaxDTU = $row.MaxDTUPercent
            RecommendedTier = $row.RecommendedTier
            RecommendedCost = $recCost
            MonthlySavings = $savings
            AnnualSavings = $savings * 12
        }
    }
    elseif ($recCost -gt $currentCost) {
        $upgrade = $recCost - $currentCost
        $totalUpgradeCost += $upgrade
        $upgradeNeeded += [PSCustomObject]@{
            Database = $row.DatabaseName
            Server = $row.ServerName
            CurrentTier = $row.ServiceObjective
            CurrentCost = $currentCost
            AvgDTU = $row.AvgDTUPercent
            MaxDTU = $row.MaxDTUPercent
            RecommendedTier = $row.RecommendedTier
            RecommendedCost = $recCost
            AdditionalCost = $upgrade
        }
    }
}

$savingsOpportunities = $savingsOpportunities | Sort-Object MonthlySavings -Descending
$upgradeNeeded = $upgradeNeeded | Sort-Object AdditionalCost -Descending

$annualSavings = $totalSavings * 12
$afterOptimization = $totalCurrentCost - $totalSavings
$savingsPercent = [math]::Round(($totalSavings / $totalCurrentCost) * 100, 1)

Write-Host ""
Write-Host "RESULTS:" -ForegroundColor Green
Write-Host "  Current Monthly Spend: `$$($totalCurrentCost.ToString('N2'))" -ForegroundColor Red
Write-Host "  Can Save: `$$($totalSavings.ToString('N2'))/month" -ForegroundColor Green
Write-Host "  After Optimization: `$$($afterOptimization.ToString('N2'))/month" -ForegroundColor Cyan
Write-Host "  Annual Savings: `$$($annualSavings.ToString('N2'))" -ForegroundColor Green
Write-Host ""

$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Azure SQL Cost Optimization Report</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', Arial, sans-serif; background: #1a1a2e; color: #eee; }
        .header { background: linear-gradient(135deg, #0f3460, #16213e); padding: 50px 40px; text-align: center; border-bottom: 4px solid #e94560; }
        .header h1 { font-size: 2.8em; margin-bottom: 10px; color: #fff; }
        .header p { font-size: 1.2em; color: #aaa; }
        .container { max-width: 1400px; margin: 0 auto; padding: 30px; }
        .executive-summary { background: linear-gradient(135deg, #16213e, #1a1a2e); border-radius: 16px; padding: 40px; margin-bottom: 30px; border: 1px solid #0f3460; }
        .executive-summary h2 { color: #e94560; font-size: 1.8em; margin-bottom: 25px; text-align: center; }
        .money-flow { display: grid; grid-template-columns: 1fr auto 1fr auto 1fr; align-items: center; gap: 20px; margin: 30px 0; }
        .money-box { background: #16213e; border-radius: 12px; padding: 30px; text-align: center; }
        .money-box.current { border: 3px solid #e94560; }
        .money-box.savings { border: 3px solid #00bf63; }
        .money-box.after { border: 3px solid #0096ff; }
        .money-box h3 { font-size: 0.9em; color: #aaa; text-transform: uppercase; margin-bottom: 10px; }
        .money-box .amount { font-size: 2.5em; font-weight: bold; }
        .money-box.current .amount { color: #e94560; }
        .money-box.savings .amount { color: #00bf63; }
        .money-box.after .amount { color: #0096ff; }
        .money-box .period { color: #888; font-size: 0.9em; }
        .arrow { font-size: 3em; color: #444; }
        .stats-row { display: grid; grid-template-columns: repeat(4, 1fr); gap: 20px; margin: 30px 0; }
        .stat-card { background: #16213e; border-radius: 12px; padding: 25px; text-align: center; border-left: 4px solid; }
        .stat-card.red { border-color: #e94560; }
        .stat-card.green { border-color: #00bf63; }
        .stat-card.blue { border-color: #0096ff; }
        .stat-card.orange { border-color: #ff9f43; }
        .stat-card h4 { color: #888; font-size: 0.85em; text-transform: uppercase; margin-bottom: 8px; }
        .stat-card .value { font-size: 2.2em; font-weight: bold; color: #fff; }
        .section { background: #16213e; border-radius: 16px; padding: 30px; margin-bottom: 25px; }
        .section h2 { color: #fff; margin-bottom: 20px; padding-bottom: 15px; border-bottom: 2px solid #0f3460; }
        .section h2 .count { background: #e94560; color: #fff; padding: 4px 12px; border-radius: 20px; font-size: 0.6em; margin-left: 10px; }
        .section h2.green .count { background: #00bf63; }
        table { width: 100%; border-collapse: collapse; }
        th { background: #0f3460; color: #fff; padding: 15px; text-align: left; font-weight: 600; font-size: 0.85em; text-transform: uppercase; }
        td { padding: 15px; border-bottom: 1px solid #0f3460; }
        tr:hover { background: #1f2b47; }
        .tier-badge { display: inline-block; padding: 5px 12px; border-radius: 6px; font-size: 0.85em; font-weight: bold; background: #0078d4; color: #fff; }
        .cost-current { color: #e94560; font-weight: bold; }
        .cost-savings { color: #00bf63; font-weight: bold; }
        .cost-new { color: #0096ff; font-weight: bold; }
        .cost-upgrade { color: #ff9f43; font-weight: bold; }
        .action-tag { display: inline-block; padding: 4px 10px; border-radius: 4px; font-size: 0.8em; font-weight: bold; margin-left: 8px; }
        .action-downgrade { background: rgba(0,191,99,0.2); color: #00bf63; }
        .action-upgrade { background: rgba(255,159,67,0.2); color: #ff9f43; }
        .highlight-row { background: rgba(0,191,99,0.1) !important; }
        .footer { text-align: center; padding: 30px; color: #666; }
        .big-number { font-size: 4em; font-weight: bold; text-align: center; margin: 20px 0; }
        .big-number.green { color: #00bf63; }
        .cta-box { background: linear-gradient(135deg, #00bf63, #00a854); border-radius: 12px; padding: 30px; text-align: center; margin: 30px 0; }
        .cta-box h3 { color: #fff; font-size: 1.5em; margin-bottom: 10px; }
        .cta-box p { color: rgba(255,255,255,0.9); font-size: 1.1em; }
        @media (max-width: 1000px) { .money-flow { grid-template-columns: 1fr; } .arrow { transform: rotate(90deg); } .stats-row { grid-template-columns: repeat(2, 1fr); } }
    </style>
</head>
<body>
    <div class="header">
        <h1>Azure SQL Cost Optimization Report</h1>
        <p>Generated: $(Get-Date -Format "MMMM dd, yyyy 'at' hh:mm tt")</p>
    </div>
    <div class="container">
        <div class="executive-summary">
            <h2>Executive Summary - The Money Story</h2>
            <div class="money-flow">
                <div class="money-box current">
                    <h3>You're Paying Now</h3>
                    <div class="amount">`$$('{0:N0}' -f $totalCurrentCost)</div>
                    <div class="period">per month</div>
                </div>
                <div class="arrow">→</div>
                <div class="money-box savings">
                    <h3>You Can Save</h3>
                    <div class="amount">`$$('{0:N0}' -f $totalSavings)</div>
                    <div class="period">per month ($savingsPercent%)</div>
                </div>
                <div class="arrow">→</div>
                <div class="money-box after">
                    <h3>You Should Pay</h3>
                    <div class="amount">`$$('{0:N0}' -f $afterOptimization)</div>
                    <div class="period">per month</div>
                </div>
            </div>
            <div class="cta-box">
                <h3>Annual Savings Opportunity</h3>
                <p class="big-number green">`$$('{0:N0}' -f $annualSavings)</p>
                <p>By right-sizing $($savingsOpportunities.Count) overprovisioned databases</p>
            </div>
            <div class="stats-row">
                <div class="stat-card blue"><h4>Total Databases</h4><div class="value">$totalDatabases</div></div>
                <div class="stat-card green"><h4>Can Downgrade</h4><div class="value">$($savingsOpportunities.Count)</div></div>
                <div class="stat-card orange"><h4>Need Upgrade</h4><div class="value">$($upgradeNeeded.Count)</div></div>
                <div class="stat-card red"><h4>Wasted Monthly</h4><div class="value">`$$('{0:N0}' -f $totalSavings)</div></div>
            </div>
        </div>
        <div class="section">
            <h2 class="green">DOWNGRADE THESE - SAVE MONEY <span class="count">$($savingsOpportunities.Count)</span></h2>
            <p style="color: #888; margin-bottom: 20px;">These databases are overprovisioned. Downgrade to save money with zero performance impact.</p>
            <table>
                <tr><th>Database</th><th>Server</th><th>Current Tier</th><th>Paying Now</th><th>Avg DTU</th><th>Max DTU</th><th>Recommended</th><th>Should Pay</th><th>Monthly Savings</th><th>Annual Savings</th></tr>
"@

$rank = 0
foreach ($db in $savingsOpportunities) {
    $rank++
    $highlightClass = if ($rank -le 5) { "highlight-row" } else { "" }
    $html += @"
                <tr class="$highlightClass">
                    <td><strong>$($db.Database)</strong></td>
                    <td style="color: #888;">$($db.Server)</td>
                    <td><span class="tier-badge">$($db.CurrentTier)</span></td>
                    <td class="cost-current">`$$('{0:N2}' -f $db.CurrentCost)</td>
                    <td>$($db.AvgDTU)%</td>
                    <td>$($db.MaxDTU)%</td>
                    <td><span class="tier-badge" style="background:#00bf63;">$($db.RecommendedTier)</span><span class="action-tag action-downgrade">DOWNGRADE</span></td>
                    <td class="cost-new">`$$('{0:N2}' -f $db.RecommendedCost)</td>
                    <td class="cost-savings">`$$('{0:N2}' -f $db.MonthlySavings)</td>
                    <td class="cost-savings">`$$('{0:N0}' -f $db.AnnualSavings)</td>
                </tr>
"@
}

$html += "</table></div>"

if ($upgradeNeeded.Count -gt 0) {
$html += @"
        <div class="section">
            <h2>UPGRADE THESE - PERFORMANCE AT RISK <span class="count" style="background:#ff9f43;">$($upgradeNeeded.Count)</span></h2>
            <p style="color: #888; margin-bottom: 20px;">These databases are maxing out. Upgrade to avoid performance issues.</p>
            <table>
                <tr><th>Database</th><th>Server</th><th>Current Tier</th><th>Paying Now</th><th>Avg DTU</th><th>Max DTU</th><th>Recommended</th><th>New Cost</th><th>Additional Cost</th></tr>
"@
foreach ($db in $upgradeNeeded | Select-Object -First 15) {
    $html += @"
                <tr>
                    <td><strong>$($db.Database)</strong></td>
                    <td style="color: #888;">$($db.Server)</td>
                    <td><span class="tier-badge">$($db.CurrentTier)</span></td>
                    <td>`$$('{0:N2}' -f $db.CurrentCost)</td>
                    <td>$($db.AvgDTU)%</td>
                    <td style="color: #e94560; font-weight: bold;">$($db.MaxDTU)%</td>
                    <td><span class="tier-badge" style="background:#ff9f43;">$($db.RecommendedTier)</span><span class="action-tag action-upgrade">UPGRADE</span></td>
                    <td>`$$('{0:N2}' -f $db.RecommendedCost)</td>
                    <td class="cost-upgrade">+`$$('{0:N2}' -f $db.AdditionalCost)</td>
                </tr>
"@
}
$html += "</table></div>"
}

$html += @"
        <div class="section">
            <h2>Action Plan</h2>
            <table>
                <tr><th>Priority</th><th>Action</th><th>Databases</th><th>Savings</th><th>Risk</th></tr>
                <tr class="highlight-row">
                    <td><strong>1. NOW</strong></td>
                    <td>Downgrade 0% DTU databases</td>
                    <td>$(($savingsOpportunities | Where-Object { [decimal]($_.AvgDTU -replace '[^0-9.]','') -eq 0 }).Count)</td>
                    <td class="cost-savings">`$$('{0:N0}' -f (($savingsOpportunities | Where-Object { [decimal]($_.AvgDTU -replace '[^0-9.]','') -eq 0 } | Measure-Object -Property MonthlySavings -Sum).Sum))/mo</td>
                    <td style="color: #00bf63;">ZERO</td>
                </tr>
                <tr>
                    <td><strong>2. THIS WEEK</strong></td>
                    <td>Downgrade &lt;10% DTU databases</td>
                    <td>$(($savingsOpportunities | Where-Object { [decimal]($_.AvgDTU -replace '[^0-9.]','') -gt 0 -and [decimal]($_.AvgDTU -replace '[^0-9.]','') -lt 10 }).Count)</td>
                    <td class="cost-savings">`$$('{0:N0}' -f (($savingsOpportunities | Where-Object { [decimal]($_.AvgDTU -replace '[^0-9.]','') -gt 0 -and [decimal]($_.AvgDTU -replace '[^0-9.]','') -lt 10 } | Measure-Object -Property MonthlySavings -Sum).Sum))/mo</td>
                    <td style="color: #00bf63;">LOW</td>
                </tr>
                <tr>
                    <td><strong>3. THIS MONTH</strong></td>
                    <td>Downgrade remaining</td>
                    <td>$(($savingsOpportunities | Where-Object { [decimal]($_.AvgDTU -replace '[^0-9.]','') -ge 10 }).Count)</td>
                    <td class="cost-savings">`$$('{0:N0}' -f (($savingsOpportunities | Where-Object { [decimal]($_.AvgDTU -replace '[^0-9.]','') -ge 10 } | Measure-Object -Property MonthlySavings -Sum).Sum))/mo</td>
                    <td style="color: #ff9f43;">MEDIUM</td>
                </tr>
            </table>
        </div>
    </div>
    <div class="footer">
        <p><strong>Azure SQL Cost Optimization Audit</strong> | Infrastructure Team | $(Get-Date -Format "yyyy-MM-dd")</p>
    </div>
</body>
</html>
"@

$html | Out-File $OutputHTML -Encoding UTF8
Write-Host "Report Generated: $OutputHTML" -ForegroundColor Green
Start-Process $OutputHTML
