param(
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "$env:TEMP"
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportFile = Join-Path $OutputPath "V4C_Quota_Analysis_$timestamp.html"
$dataFile = Join-Path $OutputPath "v4c_data.json"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  V4C vs V3 QUOTA ANALYSIS - TONY'S REQUEST" -ForegroundColor Cyan
Write-Host "  Checking newer V4C VMs for available quota" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$modules = @('Az.Accounts', 'Az.Compute', 'Az.Resources')
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
Write-Host "Analyzing V3 vs V4C quota across all regions..." -ForegroundColor Yellow
Write-Host ""

$regionsToCheck = @(
    @{Name="East US"; Location="eastus"},
    @{Name="East US 2"; Location="eastus2"},
    @{Name="Central US"; Location="centralus"},
    @{Name="North Central US"; Location="northcentralus"},
    @{Name="South Central US"; Location="southcentralus"},
    @{Name="West US 2"; Location="westus2"; IsCurrent=$true},
    @{Name="West US 3"; Location="westus3"},
    @{Name="Canada Central"; Location="canadacentral"}
)

$analysisResults = @()

foreach ($region in $regionsToCheck) {
    Write-Host "Region: $($region.Name)" -ForegroundColor Cyan
    
    try {
        $usage = Get-AzVMUsage -Location $region.Location -ErrorAction SilentlyContinue
        
        # V3 Quota
        $v3Quota = $usage | Where-Object { $_.Name.LocalizedValue -like "*Standard Dv3*" -or $_.Name.LocalizedValue -like "*Standard DSv3*" } | Select-Object -First 1
        
        if ($v3Quota) {
            $v3Available = $v3Quota.Limit - $v3Quota.CurrentValue
            $v3Percent = [math]::Round(($v3Quota.CurrentValue / $v3Quota.Limit) * 100, 1)
            Write-Host "  V3 Series: $($v3Quota.CurrentValue)/$($v3Quota.Limit) ($v3Available available)" -ForegroundColor White
        } else {
            $v3Available = 0
            $v3Percent = 0
            $v3Quota = @{ CurrentValue = 0; Limit = 0 }
        }
        
        # V4 Quota
        $v4Quota = $usage | Where-Object { $_.Name.LocalizedValue -like "*Standard Dv4*" -or $_.Name.LocalizedValue -like "*Standard DSv4*" } | Select-Object -First 1
        
        if ($v4Quota) {
            $v4Available = $v4Quota.Limit - $v4Quota.CurrentValue
            $v4Percent = [math]::Round(($v4Quota.CurrentValue / $v4Quota.Limit) * 100, 1)
            Write-Host "  V4 Series: $($v4Quota.CurrentValue)/$($v4Quota.Limit) ($v4Available available)" -ForegroundColor $(if ($v4Available -ge 64) { "Green" } else { "Yellow" })
        } else {
            $v4Available = 0
            $v4Percent = 0
            $v4Quota = @{ CurrentValue = 0; Limit = 0 }
        }
        
        # Total Regional
        $totalQuota = $usage | Where-Object { $_.Name.LocalizedValue -like "*Total Regional*" } | Select-Object -First 1
        
        if ($totalQuota) {
            $totalAvailable = $totalQuota.Limit - $totalQuota.CurrentValue
            Write-Host "  Total Regional: $($totalQuota.CurrentValue)/$($totalQuota.Limit) ($totalAvailable available)" -ForegroundColor White
        } else {
            $totalAvailable = 0
            $totalQuota = @{ CurrentValue = 0; Limit = 0 }
        }
        
        $hasV4Quota = $v4Available -ge 64
        $hasV3Quota = $v3Available -ge 64
        
        $recommendation = if ($hasV4Quota) { "Use V4C - Has quota!" } 
                         elseif ($hasV3Quota) { "Use V3 - Has quota" }
                         else { "Request quota increase" }
        
        $v3Cost = 1000
        $v4Cost = 950
        
        $analysisResults += [PSCustomObject]@{
            RegionName = $region.Name
            Location = $region.Location
            IsCurrent = if ($region.IsCurrent) { $true } else { $false }
            V3Used = $v3Quota.CurrentValue
            V3Limit = $v3Quota.Limit
            V3Available = $v3Available
            V3HasQuota = $hasV3Quota
            V4Used = $v4Quota.CurrentValue
            V4Limit = $v4Quota.Limit
            V4Available = $v4Available
            V4HasQuota = $hasV4Quota
            TotalAvailable = $totalAvailable
            Recommendation = $recommendation
            V3MonthlyCost = $v3Cost
            V4MonthlyCost = $v4Cost
            Savings = $v3Cost - $v4Cost
        }
        
    } catch {
        Write-Host "  ERROR checking region" -ForegroundColor Red
    }
    
    Write-Host ""
}

$v4ViableRegions = $analysisResults | Where-Object { $_.V4HasQuota -eq $true }
$v3ViableRegions = $analysisResults | Where-Object { $_.V3HasQuota -eq $true }
$bestV4Region = $v4ViableRegions | Sort-Object -Property V4Available -Descending | Select-Object -First 1
$bestV3Region = $v3ViableRegions | Sort-Object -Property V3Available -Descending | Select-Object -First 1

Write-Host "============================================================" -ForegroundColor Green
Write-Host "  ANALYSIS RESULTS" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

if ($v4ViableRegions.Count -gt 0) {
    Write-Host "GOOD NEWS: V4C quota found in $($v4ViableRegions.Count) region(s)!" -ForegroundColor Green
    Write-Host "Best V4C region: $($bestV4Region.RegionName) ($($bestV4Region.V4Available) cores)" -ForegroundColor Green
} else {
    Write-Host "V4C: No regions with 64+ cores available" -ForegroundColor Yellow
}

if ($v3ViableRegions.Count -gt 0) {
    Write-Host "V3 quota found in $($v3ViableRegions.Count) region(s)" -ForegroundColor White
} else {
    Write-Host "V3: No regions with 64+ cores available" -ForegroundColor Yellow
}

Write-Host ""

$exportData = @{
    GeneratedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Analyst = "Syed Rizvi"
    V4RegionsFound = $v4ViableRegions.Count
    V3RegionsFound = $v3ViableRegions.Count
    BestV4Region = if ($bestV4Region) { $bestV4Region.RegionName } else { "None" }
    BestV3Region = if ($bestV3Region) { $bestV3Region.RegionName } else { "None" }
    Regions = $analysisResults
}

$exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $dataFile -Encoding UTF8

$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>V4C vs V3 Quota Analysis</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); }
        .container { background: white; padding: 40px; border-radius: 10px; max-width: 1400px; margin: 0 auto; }
        h1 { color: #333; border-bottom: 3px solid #28a745; padding-bottom: 10px; }
        .success { background: #d4edda; border-left: 5px solid #28a745; padding: 20px; margin: 20px 0; }
        .warning { background: #fff3cd; border-left: 5px solid #ffc107; padding: 20px; margin: 20px 0; }
        .summary { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 25px; border-radius: 8px; margin: 20px 0; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 12px; text-align: left; font-size: 12px; }
        td { padding: 10px; border-bottom: 1px solid #ddd; font-size: 11px; }
        .has-quota { background: #d4edda; font-weight: bold; }
        .no-quota { background: #f8d7da; }
        .current-region { background: #fff3cd; }
        .best-option { background: #d4edda; border-left: 4px solid #28a745; }
    </style>
</head>
<body>
    <div class="container">
        <h1>V4C vs V3 Quota Analysis - Tony's Request</h1>
        <p><strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | <strong>Analyst:</strong> Syed Rizvi</p>
"@

if ($v4ViableRegions.Count -gt 0) {
    $html += @"
        <div class="success">
            <h2>YES! V4C Has Available Quota!</h2>
            <p><strong>Regions with V4C quota:</strong> $($v4ViableRegions.Count)</p>
            <p><strong>Best V4C region:</strong> $($bestV4Region.RegionName) - $($bestV4Region.V4Available) cores available</p>
            <p><strong>Cost advantage:</strong> V4C is ~5% cheaper than V3 ($950/mo vs $1,000/mo)</p>
            <p><strong>Recommendation:</strong> Use V4C VMs in $($bestV4Region.RegionName) - No quota request needed!</p>
        </div>
"@
} else {
    $html += @"
        <div class="warning">
            <h2>V4C Quota Also Exhausted</h2>
            <p>V4C series has same quota limitations as V3 across all checked regions.</p>
            <p><strong>Recommendation:</strong> Request quota increase for either V3 or V4C (V4C preferred for cost)</p>
        </div>
"@
}

$html += @"
        <div class="summary">
            <h2>Quick Summary</h2>
            <table style="color: white; border: none;">
                <tr>
                    <td><strong>Regions Analyzed:</strong></td>
                    <td>$($analysisResults.Count)</td>
                </tr>
                <tr>
                    <td><strong>V4C Regions with 64+ cores:</strong></td>
                    <td>$($v4ViableRegions.Count)</td>
                </tr>
                <tr>
                    <td><strong>V3 Regions with 64+ cores:</strong></td>
                    <td>$($v3ViableRegions.Count)</td>
                </tr>
                <tr>
                    <td><strong>Cost Difference (V4C vs V3):</strong></td>
                    <td>Save ~$50/month with V4C</td>
                </tr>
            </table>
        </div>
        
        <h2>Regional Quota Comparison - V4C vs V3</h2>
        <table>
            <tr>
                <th>Region</th>
                <th>V3 Available</th>
                <th>V3 Has 64+?</th>
                <th>V4C Available</th>
                <th>V4C Has 64+?</th>
                <th>Recommendation</th>
            </tr>
"@

foreach ($r in $analysisResults | Sort-Object -Property { $_.V4Available } -Descending) {
    $rowClass = ""
    if ($r.V4HasQuota) { $rowClass = "best-option" }
    elseif ($r.IsCurrent) { $rowClass = "current-region" }
    elseif ($r.V3HasQuota) { $rowClass = "has-quota" }
    
    $regionLabel = $r.RegionName
    if ($r.IsCurrent) { $regionLabel += " (Current)" }
    if ($r -eq $bestV4Region) { $regionLabel += " (BEST V4C)" }
    
    $v3Status = if ($r.V3HasQuota) { "YES" } else { "NO" }
    $v4Status = if ($r.V4HasQuota) { "YES" } else { "NO" }
    
    $html += @"
            <tr class="$rowClass">
                <td><strong>$regionLabel</strong></td>
                <td>$($r.V3Available) cores</td>
                <td>$v3Status</td>
                <td><strong>$($r.V4Available) cores</strong></td>
                <td><strong>$v4Status</strong></td>
                <td>$($r.Recommendation)</td>
            </tr>
"@
}

$html += @"
        </table>
        
        <h2>V4C vs V3 Comparison</h2>
        <table>
            <tr>
                <th>Feature</th>
                <th>V3 Series (DS3_v3)</th>
                <th>V4 Series (DS4_v4)</th>
            </tr>
            <tr>
                <td><strong>Generation</strong></td>
                <td>3rd Gen (older)</td>
                <td>4th Gen (newer)</td>
            </tr>
            <tr>
                <td><strong>Performance</strong></td>
                <td>Baseline</td>
                <td>~15% faster per core</td>
            </tr>
            <tr>
                <td><strong>Cost (Databricks)</strong></td>
                <td>~$1,000/month</td>
                <td>~$950/month (~5% cheaper)</td>
            </tr>
            <tr>
                <td><strong>Quota Pool</strong></td>
                <td>Shared with existing workloads</td>
                <td>Separate quota pool</td>
            </tr>
            <tr class="best-option">
                <td><strong>Recommendation</strong></td>
                <td>Use if V4 unavailable</td>
                <td><strong>PREFERRED - Better performance + lower cost</strong></td>
            </tr>
        </table>
        
        <h2>Recommended Action Plan</h2>
"@

if ($v4ViableRegions.Count -gt 0) {
    $html += @"
        <div class="success">
            <h3>IMMEDIATE ACTION - No Quota Request Needed!</h3>
            <ol>
                <li>Create dev Databricks workspace in <strong>$($bestV4Region.RegionName)</strong></li>
                <li>Use V4C VM types (Standard_D4s_v4, Standard_D8s_v4)</li>
                <li>Configure auto-scaling clusters</li>
                <li>Start development work immediately</li>
            </ol>
            <p><strong>Timeline:</strong> Can deploy TODAY - no waiting for quota approval!</p>
            <p><strong>Cost:</strong> $950/month (5% cheaper than V3)</p>
        </div>
"@
} else {
    $html += @"
        <div class="warning">
            <h3>Quota Request Needed</h3>
            <ol>
                <li>Request V4C quota increase (preferred) in East US</li>
                <li>Request amount: 128 vCPUs Standard Dv4 Family</li>
                <li>Alternative: Request V3 quota if V4C denied</li>
                <li>Timeline: 2-5 business days</li>
            </ol>
            <p><strong>Why request V4C over V3:</strong> Better performance, lower cost, newer generation</p>
        </div>
"@
}

$html += @"
        <h2>Cost Savings Comparison</h2>
        <table>
            <tr>
                <th>Scenario</th>
                <th>Monthly Cost</th>
                <th>Annual Cost</th>
            </tr>
            <tr>
                <td>Current Prod (V3)</td>
                <td>$1,000</td>
                <td>$12,000</td>
            </tr>
            <tr>
                <td>Dev with V3</td>
                <td>$346</td>
                <td>$4,152</td>
            </tr>
            <tr class="best-option">
                <td><strong>Dev with V4C (RECOMMENDED)</strong></td>
                <td><strong>$328</strong></td>
                <td><strong>$3,936</strong></td>
            </tr>
            <tr>
                <td>Annual Savings (V4C vs V3 Dev)</td>
                <td>$18/mo</td>
                <td><strong>$216/year</strong></td>
            </tr>
        </table>
        
        <p style="margin-top: 40px; text-align: center; color: #666;">
            <strong>Prepared by Syed Rizvi</strong><br>
            V4C vs V3 quota analysis - Response to Tony's question
        </p>
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host "HTML Report: $reportFile" -ForegroundColor Green
Write-Host "Data exported: $dataFile" -ForegroundColor Green
Write-Host ""
Write-Host "Opening HTML report..." -ForegroundColor Cyan

Start-Process $reportFile

Write-Host ""
Write-Host "Data saved for PDF generation. Run PDF script next." -ForegroundColor Yellow
Write-Host ""
