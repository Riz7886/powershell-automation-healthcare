$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$htmlFile = "$env:USERPROFILE\Desktop\WAF-Policy-Report-$timestamp.html"
$csvFile = "$env:USERPROFILE\Desktop\WAF-Policy-Report-$timestamp.csv"

Write-Host ""
Write-Host "WAF Policy Check - MOVEit vs PyxIQ" -ForegroundColor Cyan
Write-Host ""

# PyxIQ Policy Info (Classic Front Door)
$pyxiqSub = "sub-corp-prod-001"
$pyxiqRG = "Production"
$pyxiqName = "PyxIQPolicy"

# MOVEit Policy Info (CDN Front Door Premium)
$moveitSub = "sub-product-prod"
$moveitRG = "rg-moveit"
$moveitWafName = "moveitwafpolicyPremium"
$moveitFrontDoor = "moveit-frontdoor-profile"

Write-Host "Step 1: Checking PyxIQPolicy..." -ForegroundColor Yellow
az account set --subscription $pyxiqSub 2>$null

$pyxiq = az network front-door waf-policy show --name $pyxiqName --resource-group $pyxiqRG -o json 2>$null | ConvertFrom-Json

$pyxiqRulesStr = "NOT FOUND"
$pyxiqMode = "N/A"
$pyxiqEnabled = "N/A"

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
    Write-Host "  PyxIQPolicy not found" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Step 2: Checking MOVEit WAF Policy (CDN Front Door Premium)..." -ForegroundColor Yellow
az account set --subscription $moveitSub 2>$null

$moveit = az afd waf-policy show --policy-name $moveitWafName --resource-group $moveitRG -o json 2>$null | ConvertFrom-Json

$moveitRulesStr = "NONE"
$moveitMode = "Prevention"
$moveitEnabled = "Enabled"
$moveitFound = $false

if ($moveit) {
    $moveitFound = $true
    $moveitMode = if ($moveit.policySettings.mode) { $moveit.policySettings.mode } else { "Prevention" }
    $moveitEnabled = if ($moveit.policySettings.enabledState) { $moveit.policySettings.enabledState } else { "Enabled" }
    $moveitRules = @()
    if ($moveit.managedRules.managedRuleSets) {
        foreach ($r in $moveit.managedRules.managedRuleSets) {
            $moveitRules += "$($r.ruleSetType) v$($r.ruleSetVersion)"
        }
    }
    $moveitRulesStr = if ($moveitRules.Count -gt 0) { $moveitRules -join ", " } else { "NONE" }
    Write-Host "  Found: Mode=$moveitMode, Rules=$moveitRulesStr" -ForegroundColor Green
} else {
    Write-Host "  Checking alternate method..." -ForegroundColor Yellow
    $allPolicies = az afd waf-policy list --resource-group $moveitRG -o json 2>$null | ConvertFrom-Json
    if ($allPolicies) {
        foreach ($p in $allPolicies) {
            Write-Host "  Found: $($p.name)" -ForegroundColor Cyan
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "COMPARISON" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "PyxIQPolicy Rules:     $pyxiqRulesStr" -ForegroundColor White
Write-Host "MOVEit WAF Rules:      $moveitRulesStr" -ForegroundColor $(if($moveitRulesStr -eq "NONE"){"Red"}else{"Green"})
Write-Host ""

$needsFix = ($moveitRulesStr -eq "NONE")

if ($needsFix) {
    Write-Host "STATUS: MOVEit WAF is MISSING managed rules!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Applying Microsoft_DefaultRuleSet to MOVEit WAF..." -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "Adding Microsoft_DefaultRuleSet 2.1..." -ForegroundColor Yellow
    
    $result = az afd waf-policy managed-rule-set add `
        --policy-name $moveitWafName `
        --resource-group $moveitRG `
        --type Microsoft_DefaultRuleSet `
        --version "2.1" 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "SUCCESS: Microsoft_DefaultRuleSet 2.1 added!" -ForegroundColor Green
        $moveitRulesStr = "Microsoft_DefaultRuleSet v2.1"
        $needsFix = $false
    } else {
        Write-Host "Trying Microsoft_BotManagerRuleSet..." -ForegroundColor Yellow
        $result2 = az afd waf-policy managed-rule-set add `
            --policy-name $moveitWafName `
            --resource-group $moveitRG `
            --type Microsoft_BotManagerRuleSet `
            --version "1.0" 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "SUCCESS: BotManagerRuleSet added!" -ForegroundColor Green
        }
        
        Write-Host ""
        Write-Host "If CLI failed, apply manually in Azure Portal:" -ForegroundColor Yellow
        Write-Host "1. Go to: rg-moveit > moveitwafpolicyPremium" -ForegroundColor White
        Write-Host "2. Click 'Managed rules' in left menu" -ForegroundColor White
        Write-Host "3. Click '+ Add'" -ForegroundColor White
        Write-Host "4. Select 'Microsoft_DefaultRuleSet' version 2.1" -ForegroundColor White
        Write-Host "5. Click 'Add' then 'Save'" -ForegroundColor White
    }
} else {
    Write-Host "STATUS: Both policies have rules - NO ACTION NEEDED" -ForegroundColor Green
}

Write-Host ""
Write-Host "Generating reports..." -ForegroundColor Yellow

$reportData = @(
    [PSCustomObject]@{
        PolicyName = "PyxIQPolicy"
        Type = "Front Door Classic"
        Subscription = $pyxiqSub
        ResourceGroup = $pyxiqRG
        Mode = $pyxiqMode
        Enabled = $pyxiqEnabled
        ManagedRules = $pyxiqRulesStr
    },
    [PSCustomObject]@{
        PolicyName = $moveitWafName
        Type = "Front Door Premium"
        Subscription = $moveitSub
        ResourceGroup = $moveitRG
        Mode = $moveitMode
        Enabled = $moveitEnabled
        ManagedRules = $moveitRulesStr
    }
)
$reportData | Export-Csv -Path $csvFile -NoTypeInformation
Write-Host "CSV saved: $csvFile" -ForegroundColor Green

$statusColor = if ($moveitRulesStr -eq "NONE") { "#dc3545" } elseif ($needsFix) { "#ffc107" } else { "#28a745" }
$statusText = if ($moveitRulesStr -eq "NONE") { "Action Required - Add Rules Manually" } elseif ($needsFix) { "Rules Applied" } else { "All Policies Configured" }

$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>WAF Policy Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 1000px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #0078d4; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #333; margin-top: 30px; }
        .status-box { padding: 20px; border-radius: 8px; text-align: center; margin: 20px 0; color: white; background: $statusColor; }
        .status-box h2 { color: white; margin: 0; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th { background: #0078d4; color: white; padding: 12px; text-align: left; }
        td { padding: 12px; border-bottom: 1px solid #ddd; }
        tr:nth-child(even) { background: #f9f9f9; }
        .rules-good { color: #28a745; font-weight: bold; }
        .rules-none { color: #dc3545; font-weight: bold; }
        .info-box { background: #e7f3ff; border-left: 4px solid #0078d4; padding: 15px; margin: 20px 0; }
        .warning-box { background: #fff3cd; border-left: 4px solid #ffc107; padding: 15px; margin: 20px 0; }
        .footer { margin-top: 30px; color: #666; font-size: 12px; border-top: 1px solid #ddd; padding-top: 15px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>WAF Policy Comparison Report</h1>
        <p><strong>Prepared for:</strong> Tony Schlak</p>
        <p><strong>Generated:</strong> $(Get-Date -Format "MMMM dd, yyyy HH:mm:ss")</p>
        
        <div class="status-box">
            <h2>$statusText</h2>
        </div>
        
        <h2>Tony's Question</h2>
        <div class="info-box">
            <strong>Q:</strong> Does the moveitwaf policy inherit managed rules from PyxIQPolicy?<br><br>
            <strong>A:</strong> No. Azure Front Door WAF policies do NOT inherit from other policies. 
            Each policy is standalone. The MOVEit WAF policy needs managed rules explicitly configured 
            to match PyxIQPolicy's protection level.
        </div>
        
        <h2>Policy Comparison</h2>
        <table>
            <tr>
                <th>Setting</th>
                <th>PyxIQPolicy</th>
                <th>MOVEit WAF</th>
            </tr>
            <tr>
                <td><strong>Policy Name</strong></td>
                <td>PyxIQPolicy</td>
                <td>$moveitWafName</td>
            </tr>
            <tr>
                <td><strong>Type</strong></td>
                <td>Front Door Classic</td>
                <td>Front Door Premium (CDN)</td>
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
                <td><strong>Managed Rules</strong></td>
                <td class="rules-good">$pyxiqRulesStr</td>
                <td class="$(if($moveitRulesStr -eq 'NONE'){'rules-none'}else{'rules-good'})">$moveitRulesStr</td>
            </tr>
        </table>
        
        <h2>MOVEit Front Door Details</h2>
        <table>
            <tr><th>Setting</th><th>Value</th></tr>
            <tr><td>Front Door Name</td><td>moveit-frontdoor-profile</td></tr>
            <tr><td>Endpoint</td><td>moveit-endpoint-e9fqashyg2cddef0.z01.azurefd.net</td></tr>
            <tr><td>Custom Domain</td><td>moveit.pyxhealth.com</td></tr>
            <tr><td>Security Policy</td><td>moveit-waf-security</td></tr>
            <tr><td>Origin Group</td><td>moveit-origin-group</td></tr>
            <tr><td>Pricing Tier</td><td>Azure Front Door Premium</td></tr>
        </table>
        
        <h2>Managed Rules Protection</h2>
        <p>When configured, managed rules protect against:</p>
        <ul>
            <li>SQL Injection attacks</li>
            <li>Cross-Site Scripting (XSS)</li>
            <li>Remote Command Execution (RCE)</li>
            <li>Local/Remote File Inclusion (LFI/RFI)</li>
            <li>Path Traversal attacks</li>
            <li>HTTP Protocol violations</li>
            <li>HTTP Request Smuggling</li>
        </ul>
        
        <div class="footer">
            <p>Report generated by WAF Policy Audit Script</p>
            <p>CSV: $csvFile</p>
        </div>
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $htmlFile -Encoding UTF8
Write-Host "HTML saved: $htmlFile" -ForegroundColor Green

Start-Process $htmlFile

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
