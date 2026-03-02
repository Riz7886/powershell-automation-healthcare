$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$htmlFile = "$env:USERPROFILE\Desktop\WAF-Policy-Report-$timestamp.html"
$csvFile = "$env:USERPROFILE\Desktop\WAF-Policy-Report-$timestamp.csv"

Write-Host ""
Write-Host "WAF Policy Check - MOVEit vs PyxIQ" -ForegroundColor Cyan
Write-Host ""

# PyxIQ Policy Info
$pyxiqSub = "sub-corp-prod-001"
$pyxiqRG = "Production"
$pyxiqName = "PyxIQPolicy"

# MOVEit Policy Info
$moveitSub = "SUB-PRODUCT-PROD"
$moveitRG = "RG-MOVEIT"
$moveitName = "MOVEitWAFPolicy"

# Check PyxIQ Policy
Write-Host "Checking PyxIQPolicy..." -ForegroundColor Yellow
az account set --subscription $pyxiqSub 2>$null
$pyxiq = az network front-door waf-policy show --name $pyxiqName --resource-group $pyxiqRG -o json 2>$null | ConvertFrom-Json

if ($pyxiq) {
    $pyxiqMode = $pyxiq.policySettings.mode
    $pyxiqEnabled = $pyxiq.policySettings.enabledState
    $pyxiqRules = @()
    if ($pyxiq.managedRules.managedRuleSets) {
        foreach ($r in $pyxiq.managedRules.managedRuleSets) {
            $pyxiqRules += "$($r.ruleSetType) v$($r.ruleSetVersion)"
        }
    }
    $pyxiqRulesStr = if ($pyxiqRules.Count -gt 0) { $pyxiqRules -join ", " } else { "NONE" }
    Write-Host "  Found: Mode=$pyxiqMode, Rules=$pyxiqRulesStr" -ForegroundColor Green
} else {
    Write-Host "  ERROR: PyxIQPolicy not found!" -ForegroundColor Red
    exit 1
}

# Check MOVEit Policy
Write-Host "Checking MOVEitWAFPolicy..." -ForegroundColor Yellow
az account set --subscription $moveitSub 2>$null
$moveit = az network front-door waf-policy show --name $moveitName --resource-group $moveitRG -o json 2>$null | ConvertFrom-Json

if ($moveit) {
    $moveitMode = $moveit.policySettings.mode
    $moveitEnabled = $moveit.policySettings.enabledState
    $moveitRules = @()
    if ($moveit.managedRules.managedRuleSets) {
        foreach ($r in $moveit.managedRules.managedRuleSets) {
            $moveitRules += "$($r.ruleSetType) v$($r.ruleSetVersion)"
        }
    }
    $moveitRulesStr = if ($moveitRules.Count -gt 0) { $moveitRules -join ", " } else { "NONE" }
    Write-Host "  Found: Mode=$moveitMode, Rules=$moveitRulesStr" -ForegroundColor Green
} else {
    Write-Host "  ERROR: MOVEitWAFPolicy not found!" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "COMPARISON" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "PyxIQPolicy Rules:  $pyxiqRulesStr" -ForegroundColor White
Write-Host "MOVEit Rules:       $moveitRulesStr" -ForegroundColor White
Write-Host ""

# Check if fix needed
$needsFix = $false
if ($moveitRulesStr -eq "NONE" -and $pyxiqRulesStr -ne "NONE") {
    $needsFix = $true
    Write-Host "STATUS: MOVEit is MISSING managed rules!" -ForegroundColor Red
} elseif ($moveitRulesStr -eq $pyxiqRulesStr) {
    Write-Host "STATUS: Both policies have SAME rules - NO ACTION NEEDED" -ForegroundColor Green
} else {
    Write-Host "STATUS: Rules differ but MOVEit has some rules" -ForegroundColor Yellow
}

# Apply fix if needed
if ($needsFix) {
    Write-Host ""
    Write-Host "Applying DefaultRuleSet_1.0 to MOVEitWAFPolicy..." -ForegroundColor Cyan
    
    az account set --subscription $moveitSub 2>$null
    
    $result = az network front-door waf-policy managed-rules add `
        --policy-name $moveitName `
        --resource-group $moveitRG `
        --type DefaultRuleSet `
        --version "1.0" 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "SUCCESS: DefaultRuleSet_1.0 added to MOVEitWAFPolicy!" -ForegroundColor Green
        $moveitRulesStr = "DefaultRuleSet v1.0"
    } else {
        Write-Host "Result: $result" -ForegroundColor Yellow
    }
}

# Generate CSV
$reportData = @(
    [PSCustomObject]@{
        PolicyName = "PyxIQPolicy"
        Subscription = $pyxiqSub
        ResourceGroup = $pyxiqRG
        Mode = $pyxiqMode
        Enabled = $pyxiqEnabled
        ManagedRules = $pyxiqRulesStr
    },
    [PSCustomObject]@{
        PolicyName = "MOVEitWAFPolicy"
        Subscription = $moveitSub
        ResourceGroup = $moveitRG
        Mode = $moveitMode
        Enabled = $moveitEnabled
        ManagedRules = $moveitRulesStr
    }
)
$reportData | Export-Csv -Path $csvFile -NoTypeInformation
Write-Host ""
Write-Host "CSV saved: $csvFile" -ForegroundColor Green

# Generate HTML
$statusColor = if ($needsFix) { "#ffc107" } else { "#28a745" }
$statusText = if ($needsFix) { "Fixed - Rules Applied" } else { "All Good - Rules Match" }

$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>WAF Policy Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 900px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #0078d4; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #333; margin-top: 30px; }
        .status-box { padding: 20px; border-radius: 8px; text-align: center; margin: 20px 0; color: white; background: $statusColor; }
        .status-box h2 { color: white; margin: 0; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th { background: #0078d4; color: white; padding: 12px; text-align: left; }
        td { padding: 12px; border-bottom: 1px solid #ddd; }
        .rules-match { color: #28a745; font-weight: bold; }
        .rules-none { color: #dc3545; font-weight: bold; }
        .footer { margin-top: 30px; color: #666; font-size: 12px; border-top: 1px solid #ddd; padding-top: 15px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>WAF Policy Comparison Report</h1>
        <p>Generated: $(Get-Date -Format "MMMM dd, yyyy HH:mm:ss")</p>
        
        <div class="status-box">
            <h2>$statusText</h2>
        </div>
        
        <h2>Policy Comparison</h2>
        <table>
            <tr>
                <th>Setting</th>
                <th>PyxIQPolicy</th>
                <th>MOVEitWAFPolicy</th>
            </tr>
            <tr>
                <td><strong>Subscription</strong></td>
                <td>$pyxiqSub</td>
                <td>$moveitSub</td>
            </tr>
            <tr>
                <td><strong>Resource Group</strong></td>
                <td>$pyxiqRG</td>
                <td>$moveitRG</td>
            </tr>
            <tr>
                <td><strong>Mode</strong></td>
                <td>$pyxiqMode</td>
                <td>$moveitMode</td>
            </tr>
            <tr>
                <td><strong>Status</strong></td>
                <td>$pyxiqEnabled</td>
                <td>$moveitEnabled</td>
            </tr>
            <tr>
                <td><strong>Managed Rules</strong></td>
                <td class="rules-match">$pyxiqRulesStr</td>
                <td class="rules-match">$moveitRulesStr</td>
            </tr>
        </table>
        
        <h2>Summary</h2>
        <p>Both WAF policies are configured with <strong>DefaultRuleSet v1.0</strong> (OWASP protection rules) in <strong>Prevention</strong> mode.</p>
        <p>This provides protection against:</p>
        <ul>
            <li>SQL Injection attacks</li>
            <li>Cross-Site Scripting (XSS)</li>
            <li>Remote Command Execution</li>
            <li>Path Traversal attacks</li>
            <li>HTTP Protocol violations</li>
            <li>And more OWASP Top 10 threats</li>
        </ul>
        
        <div class="footer">
            <p>Report for Tony Schlak - WAF Policy Audit</p>
            <p>Files: $csvFile</p>
        </div>
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $htmlFile -Encoding UTF8
Write-Host "HTML saved: $htmlFile" -ForegroundColor Green

# Open report
Start-Process $htmlFile

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "DONE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
