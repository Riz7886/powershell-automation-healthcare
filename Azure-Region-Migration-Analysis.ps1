param(
    [Parameter(Mandatory=$false)]
    [int]$DatabricksRequiredCores = 64,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "$env:TEMP"
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportFile = Join-Path $OutputPath "Azure_Region_Migration_Analysis_$timestamp.html"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  AZURE REGION MIGRATION ANALYSIS" -ForegroundColor Cyan
Write-Host "  SQL Databases + Databricks Cost & Quota Analysis" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$modules = @('Az.Accounts', 'Az.Sql', 'Az.Compute', 'Az.Resources')
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
    "sqldb-aetna-prod", "sqldb-arch-prod", "sqldb-banner-prod",
    "sqldb-parkland-prod", "sqldb-magellan-prod", "sqldb-sentara-prod",
    "Pyx-Health", "sqldb-healthchoice-prod", "sqldb-humana-prod",
    "sqldb-partners-prod", "sqldb-pyx-central-prod", "sqldb-ubc-prod",
    "sqldb-bcbs-prod", "sqldb-chs-prod", "sqldb-lakeland-prod",
    "sqldb-arch-prod_Copy", "sqldb-multipass-prod", "sqldb-wrgm-prod"
)

Write-Host "Step 1: Getting current SQL database costs..." -ForegroundColor Yellow

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
$currentSQLCost = 0
$dbCount = 0

foreach ($sub in $subscriptions) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    $servers = Get-AzSqlServer -ErrorAction SilentlyContinue
    
    foreach ($server in $servers) {
        $databases = Get-AzSqlDatabase -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName -ErrorAction SilentlyContinue
        
        foreach ($db in $databases) {
            if ($targetDatabases -contains $db.DatabaseName) {
                $dbCount++
                $sku = $db.CurrentServiceObjectiveName
                $cost = switch ($sku) {
                    "Basic" { 4.99 }
                    "S0" { 15 }
                    "S1" { 30 }
                    "S2" { 75 }
                    "S3" { 150 }
                    "S4" { 300 }
                    default { 0 }
                }
                $currentSQLCost += $cost
            }
        }
    }
}

Write-Host "  Found $dbCount databases" -ForegroundColor White
Write-Host "  Current monthly SQL cost: `$$currentSQLCost" -ForegroundColor White
Write-Host ""

Write-Host "Step 2: Analyzing Azure regions for quota and cost..." -ForegroundColor Yellow

$regions = @(
    @{Name="West US 2"; Location="westus2"; IsCurrent=$true},
    @{Name="West US 3"; Location="westus3"; IsCurrent=$false},
    @{Name="East US"; Location="eastus"; IsCurrent=$false},
    @{Name="East US 2"; Location="eastus2"; IsCurrent=$false},
    @{Name="Central US"; Location="centralus"; IsCurrent=$false},
    @{Name="South Central US"; Location="southcentralus"; IsCurrent=$false}
)

$regionAnalysis = @()

foreach ($region in $regions) {
    Write-Host ""
    Write-Host "Analyzing: $($region.Name)..." -ForegroundColor Cyan
    
    try {
        $usage = Get-AzVMUsage -Location $region.Location -ErrorAction SilentlyContinue
        $quotaInfo = $usage | Where-Object { $_.Name.LocalizedValue -like "*Standard*v3*" -or $_.Name.LocalizedValue -like "*Total Regional*" } | Select-Object -First 1
        
        if ($quotaInfo) {
            $currentUsage = $quotaInfo.CurrentValue
            $limit = $quotaInfo.Limit
            $available = $limit - $currentUsage
            $canSupport = $available -ge $DatabricksRequiredCores
            
            Write-Host "  Quota: $currentUsage / $limit cores (Available: $available)" -ForegroundColor White
            Write-Host "  Can support $DatabricksRequiredCores cores: $(if ($canSupport) { 'YES' } else { 'NO' })" -ForegroundColor $(if ($canSupport) { 'Green' } else { 'Red' })
        } else {
            $currentUsage = 0
            $limit = "Unknown"
            $available = "Unknown"
            $canSupport = $false
        }
        
        $sqlCostMultiplier = 1.0
        if ($region.Location -eq "westus3") {
            $sqlCostMultiplier = 0.95
        } elseif ($region.Location -like "east*") {
            $sqlCostMultiplier = 0.98
        }
        
        $sqlCostInRegion = [math]::Round($currentSQLCost * $sqlCostMultiplier, 2)
        
        $databricksCost = 0
        if ($DatabricksRequiredCores -eq 64) {
            $databricksCost = 1000
        } else {
            $databricksCost = ($DatabricksRequiredCores / 64) * 1000
        }
        
        $totalMonthlyCost = $sqlCostInRegion + $databricksCost
        $totalAnnualCost = $totalMonthlyCost * 12
        
        $regionAnalysis += [PSCustomObject]@{
            RegionName = $region.Name
            Location = $region.Location
            IsCurrent = $region.IsCurrent
            QuotaUsed = $currentUsage
            QuotaLimit = $limit
            QuotaAvailable = $available
            CanSupportDatabricks = $canSupport
            SQLMonthlyCost = $sqlCostInRegion
            DatabricksMonthlyCost = $databricksCost
            TotalMonthlyCost = $totalMonthlyCost
            TotalAnnualCost = $totalAnnualCost
        }
        
        Write-Host "  SQL Cost: `$$sqlCostInRegion/mo | Databricks: `$$databricksCost/mo | Total: `$$totalMonthlyCost/mo" -ForegroundColor White
        
    } catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        
        $regionAnalysis += [PSCustomObject]@{
            RegionName = $region.Name
            Location = $region.Location
            IsCurrent = $region.IsCurrent
            QuotaUsed = 0
            QuotaLimit = "Error"
            QuotaAvailable = "Error"
            CanSupportDatabricks = $false
            SQLMonthlyCost = 0
            DatabricksMonthlyCost = 0
            TotalMonthlyCost = 0
            TotalAnnualCost = 0
        }
    }
}

$currentRegionData = $regionAnalysis | Where-Object { $_.IsCurrent -eq $true }
$viableRegions = $regionAnalysis | Where-Object { $_.CanSupportDatabricks -eq $true -and $_.IsCurrent -eq $false }
$recommendedRegion = $viableRegions | Sort-Object -Property TotalMonthlyCost | Select-Object -First 1

$savingsVsCurrent = 0
if ($recommendedRegion) {
    $savingsVsCurrent = $currentRegionData.TotalMonthlyCost - $recommendedRegion.TotalMonthlyCost
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  ANALYSIS COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

if ($recommendedRegion) {
    Write-Host "RECOMMENDED REGION: $($recommendedRegion.RegionName)" -ForegroundColor Green
    Write-Host "  Has quota: YES ($($recommendedRegion.QuotaAvailable) cores available)" -ForegroundColor Green
    Write-Host "  Total monthly cost: `$$($recommendedRegion.TotalMonthlyCost)" -ForegroundColor Green
    Write-Host "  Monthly savings: `$$savingsVsCurrent" -ForegroundColor Green
} else {
    Write-Host "NO VIABLE REGIONS FOUND!" -ForegroundColor Red
}

Write-Host ""

$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Azure Region Migration Analysis</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        }
        .container {
            background: white;
            padding: 40px;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            max-width: 1400px;
            margin: 0 auto;
        }
        h1 {
            color: #333;
            border-bottom: 3px solid #667eea;
            padding-bottom: 15px;
            margin-bottom: 20px;
        }
        .executive-summary {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            border-radius: 8px;
            margin: 25px 0;
        }
        .executive-summary h2 {
            margin: 0 0 20px 0;
            color: white;
        }
        .recommendation-box {
            background: #d4edda;
            border-left: 5px solid #28a745;
            padding: 25px;
            margin: 25px 0;
            border-radius: 5px;
        }
        .recommendation-box h3 {
            margin-top: 0;
            color: #155724;
        }
        .problem-box {
            background: #f8d7da;
            border-left: 5px solid #dc3545;
            padding: 25px;
            margin: 25px 0;
            border-radius: 5px;
        }
        .problem-box h3 {
            margin-top: 0;
            color: #721c24;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
        }
        th {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 15px;
            text-align: left;
            font-weight: bold;
        }
        td {
            padding: 12px 15px;
            border-bottom: 1px solid #ddd;
        }
        tr:hover {
            background: #f5f5f5;
        }
        .current-region {
            background: #fff3cd;
        }
        .recommended-region {
            background: #d4edda;
        }
        .no-quota {
            color: #dc3545;
            font-weight: bold;
        }
        .has-quota {
            color: #28a745;
            font-weight: bold;
        }
        .cost-breakdown {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin: 25px 0;
        }
        .cost-card {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 8px;
            border-left: 4px solid #667eea;
        }
        .cost-card h4 {
            margin: 0 0 10px 0;
            color: #333;
        }
        .cost-value {
            font-size: 28px;
            font-weight: bold;
            color: #667eea;
        }
        .savings-highlight {
            background: #d4edda;
            border-left-color: #28a745;
        }
        .savings-highlight .cost-value {
            color: #28a745;
        }
        .footer {
            margin-top: 40px;
            padding-top: 20px;
            border-top: 2px solid #ddd;
            text-align: center;
            color: #666;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Azure Region Migration Analysis</h1>
        <p><strong>Report Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | <strong>Analyst:</strong> Syed Rizvi</p>
        
        <div class="executive-summary">
            <h2>Executive Summary</h2>
            <p><strong>Current Situation:</strong> Running $dbCount SQL databases + Databricks in West US 2</p>
            <p><strong>Problem:</strong> West US 2 has exhausted quota - cannot increase Databricks capacity</p>
            <p><strong>Solution:</strong> Migrate to region with available quota + potential cost savings</p>
            <p><strong>Databases Analyzed:</strong> sqldb-aetna-prod, sqldb-arch-prod, sqldb-banner-prod, sqldb-parkland-prod, sqldb-magellan-prod, sqldb-sentara-prod, Pyx-Health, sqldb-healthchoice-prod, sqldb-humana-prod, sqldb-partners-prod, sqldb-pyx-central-prod, sqldb-ubc-prod, sqldb-bcbs-prod, sqldb-chs-prod, sqldb-lakeland-prod, sqldb-arch-prod_Copy, sqldb-multipass-prod, sqldb-wrgm-prod</p>
        </div>
"@

if ($recommendedRegion) {
    $html += @"
        <div class="recommendation-box">
            <h3>✅ RECOMMENDED ACTION: Migrate to $($recommendedRegion.RegionName)</h3>
            <p><strong>Why this region:</strong></p>
            <ul>
                <li>Has $($recommendedRegion.QuotaAvailable) cores available (need $DatabricksRequiredCores)</li>
                <li>Total monthly cost: `$$($recommendedRegion.TotalMonthlyCost) (SQL: `$$($recommendedRegion.SQLMonthlyCost) + Databricks: `$$($recommendedRegion.DatabricksMonthlyCost))</li>
                <li>Monthly savings: `$$savingsVsCurrent</li>
                <li>Annual savings: `$$([math]::Round($savingsVsCurrent * 12, 2))</li>
            </ul>
        </div>
"@
} else {
    $html += @"
        <div class="problem-box">
            <h3>⚠️ WARNING: No viable regions found with sufficient quota!</h3>
            <p>None of the analyzed regions have sufficient quota available. Consider:</p>
            <ul>
                <li>Requesting quota increase in a target region</li>
                <li>Analyzing additional regions</li>
                <li>Reviewing Databricks requirements</li>
            </ul>
        </div>
"@
}

$html += @"
        <div class="cost-breakdown">
            <div class="cost-card">
                <h4>Current SQL Databases</h4>
                <div class="cost-value">`$$currentSQLCost/mo</div>
                <p>$dbCount databases</p>
            </div>
            <div class="cost-card">
                <h4>Databricks (64 cores)</h4>
                <div class="cost-value">`$$(if ($currentRegionData) { $currentRegionData.DatabricksMonthlyCost } else { 1000 })/mo</div>
                <p>Current region estimate</p>
            </div>
"@

if ($recommendedRegion) {
    $html += @"
            <div class="cost-card savings-highlight">
                <h4>Potential Monthly Savings</h4>
                <div class="cost-value">`$$savingsVsCurrent</div>
                <p>By moving to $($recommendedRegion.RegionName)</p>
            </div>
            <div class="cost-card savings-highlight">
                <h4>Annual Savings</h4>
                <div class="cost-value">`$$([math]::Round($savingsVsCurrent * 12, 2))</div>
                <p>First year projection</p>
            </div>
"@
}

$html += @"
        </div>
        
        <h2>Regional Analysis - All Regions</h2>
        <table>
            <tr>
                <th>Region</th>
                <th>Quota Status</th>
                <th>Available Cores</th>
                <th>SQL Cost/mo</th>
                <th>Databricks Cost/mo</th>
                <th>Total Cost/mo</th>
                <th>Annual Cost</th>
            </tr>
"@

foreach ($r in $regionAnalysis | Sort-Object -Property TotalMonthlyCost) {
    $rowClass = ""
    if ($r.IsCurrent) { $rowClass = "current-region" }
    elseif ($r -eq $recommendedRegion) { $rowClass = "recommended-region" }
    
    $quotaStatus = if ($r.CanSupportDatabricks) { 
        "<span class='has-quota'>✓ YES</span>" 
    } else { 
        "<span class='no-quota'>✗ NO</span>" 
    }
    
    $regionLabel = $r.RegionName
    if ($r.IsCurrent) { $regionLabel += " (Current)" }
    if ($r -eq $recommendedRegion) { $regionLabel += " (Recommended)" }
    
    $html += @"
            <tr class='$rowClass'>
                <td><strong>$regionLabel</strong></td>
                <td>$quotaStatus</td>
                <td>$($r.QuotaAvailable)</td>
                <td>`$$($r.SQLMonthlyCost)</td>
                <td>`$$($r.DatabricksMonthlyCost)</td>
                <td><strong>`$$($r.TotalMonthlyCost)</strong></td>
                <td>`$$($r.TotalAnnualCost)</td>
            </tr>
"@
}

$html += @"
        </table>
        
        <h2>Migration Strategy</h2>
        <div class="recommendation-box">
            <h3>Recommended Migration Steps</h3>
            <ol>
                <li><strong>Preparation (Week 1):</strong>
                    <ul>
                        <li>Confirm quota request in $($recommendedRegion.RegionName) if needed</li>
                        <li>Document current database configurations</li>
                        <li>Test connectivity from new region to existing services</li>
                    </ul>
                </li>
                <li><strong>Database Migration (Week 2-3):</strong>
                    <ul>
                        <li>Use Azure SQL Database geo-replication for zero-downtime migration</li>
                        <li>Migrate databases in batches (5-6 at a time)</li>
                        <li>Validate each batch before proceeding</li>
                    </ul>
                </li>
                <li><strong>Databricks Migration (Week 3-4):</strong>
                    <ul>
                        <li>Create new Databricks workspace in $($recommendedRegion.RegionName)</li>
                        <li>Migrate notebooks, jobs, and configurations</li>
                        <li>Test all workflows in new region</li>
                    </ul>
                </li>
                <li><strong>Cutover & Validation (Week 4):</strong>
                    <ul>
                        <li>Update connection strings</li>
                        <li>Monitor performance for 1 week</li>
                        <li>Decommission old resources</li>
                    </ul>
                </li>
            </ol>
        </div>
        
        <div class="footer">
            <p><strong>Report prepared by:</strong> Syed Rizvi</p>
            <p><strong>Analysis Date:</strong> $(Get-Date -Format 'MMMM dd, yyyy')</p>
            <p><strong>Contact:</strong> For questions or to proceed with migration, contact Infrastructure team</p>
        </div>
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host "Report saved: $reportFile" -ForegroundColor Green
Write-Host "Opening report in browser..." -ForegroundColor Cyan
Write-Host ""

Start-Process $reportFile
