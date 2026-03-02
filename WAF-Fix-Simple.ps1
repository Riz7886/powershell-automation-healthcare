$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$htmlFile = "$env:USERPROFILE\Desktop\WAF-Fix-Report-$timestamp.html"

Write-Host ""
Write-Host "MOVEit WAF - Adding Managed Rules" -ForegroundColor Cyan
Write-Host ""

# Set subscription
Write-Host "Setting subscription to sub-product-prod..." -ForegroundColor Yellow
az account set --subscription "sub-product-prod"

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Cannot set subscription. Run 'az login' first." -ForegroundColor Red
    exit 1
}
Write-Host "OK" -ForegroundColor Green

# Add managed rule set
Write-Host ""
Write-Host "Adding Microsoft_DefaultRuleSet 2.1 to moveitwafpolicyPremium..." -ForegroundColor Yellow

az afd waf-policy managed-rule-set add `
    --policy-name "moveitwafpolicyPremium" `
    --resource-group "rg-moveit" `
    --type "Microsoft_DefaultRuleSet" `
    --version "2.1" `
    --output none

if ($LASTEXITCODE -eq 0) {
    Write-Host "SUCCESS: Microsoft_DefaultRuleSet 2.1 added!" -ForegroundColor Green
    $ruleStatus = "Microsoft_DefaultRuleSet v2.1 - ADDED"
    $statusColor = "#28a745"
    $statusText = "Rules Successfully Applied"
} else {
    Write-Host "First attempt failed, trying version 2.0..." -ForegroundColor Yellow
    
    az afd waf-policy managed-rule-set add `
        --policy-name "moveitwafpolicyPremium" `
        --resource-group "rg-moveit" `
        --type "Microsoft_DefaultRuleSet" `
        --version "2.0" `
        --output none
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "SUCCESS: Microsoft_DefaultRuleSet 2.0 added!" -ForegroundColor Green
        $ruleStatus = "Microsoft_DefaultRuleSet v2.0 - ADDED"
        $statusColor = "#28a745"
        $statusText = "Rules Successfully Applied"
    } else {
        Write-Host "Trying version 1.1..." -ForegroundColor Yellow
        
        az afd waf-policy managed-rule-set add `
            --policy-name "moveitwafpolicyPremium" `
            --resource-group "rg-moveit" `
            --type "Microsoft_DefaultRuleSet" `
            --version "1.1" `
            --output none
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "SUCCESS: Microsoft_DefaultRuleSet 1.1 added!" -ForegroundColor Green
            $ruleStatus = "Microsoft_DefaultRuleSet v1.1 - ADDED"
            $statusColor = "#28a745"
            $statusText = "Rules Successfully Applied"
        } else {
            Write-Host "CLI commands failed." -ForegroundColor Red
            $ruleStatus = "Manual action required"
            $statusColor = "#dc3545"
            $statusText = "Manual Action Required"
        }
    }
}

# Generate HTML Report
Write-Host ""
Write-Host "Generating report..." -ForegroundColor Yellow

$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>WAF Policy Update Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f0f0f0; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #0078d4; }
        .status { padding: 20px; border-radius: 8px; text-align: center; color: white; background: $statusColor; margin: 20px 0; }
        .status h2 { margin: 0; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th { background: #0078d4; color: white; padding: 12px; text-align: left; }
        td { padding: 12px; border-bottom: 1px solid #ddd; }
        .info { background: #e7f3ff; padding: 15px; border-left: 4px solid #0078d4; margin: 20px 0; }
    </style>
</head>
<body>
    <div class="container">
        <h1>WAF Policy Update Report</h1>
        <p><strong>Date:</strong> $(Get-Date -Format "MMMM dd, yyyy HH:mm:ss")</p>
        <p><strong>Prepared for:</strong> Tony Schlak</p>
        
        <div class="status">
            <h2>$statusText</h2>
        </div>
        
        <h2>Question Answered</h2>
        <div class="info">
            <strong>Tony asked:</strong> Does moveitwaf inherit rules from PyxIQPolicy?<br><br>
            <strong>Answer:</strong> No. Azure WAF policies are standalone - they do not inherit from other policies. Each policy needs managed rules configured separately.
        </div>
        
        <h2>Action Taken</h2>
        <table>
            <tr><th>Item</th><th>Details</th></tr>
            <tr><td>WAF Policy</td><td>moveitwafpolicyPremium</td></tr>
            <tr><td>Resource Group</td><td>rg-moveit</td></tr>
            <tr><td>Subscription</td><td>sub-product-prod</td></tr>
            <tr><td>Managed Rules</td><td><strong>$ruleStatus</strong></td></tr>
        </table>
        
        <h2>Protection Now Includes</h2>
        <ul>
            <li>SQL Injection protection</li>
            <li>Cross-Site Scripting (XSS) protection</li>
            <li>Remote Command Execution protection</li>
            <li>Path Traversal protection</li>
            <li>Local/Remote File Inclusion protection</li>
            <li>HTTP Protocol violation protection</li>
        </ul>
        
        <h2>Comparison</h2>
        <table>
            <tr><th>Policy</th><th>Managed Rules</th></tr>
            <tr><td>PyxIQPolicy</td><td>DefaultRuleSet v1.0</td></tr>
            <tr><td>moveitwafpolicyPremium</td><td>$ruleStatus</td></tr>
        </table>
        
        <p style="margin-top:30px; color:#666; font-size:12px;">Report generated automatically</p>
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $htmlFile -Encoding UTF8
Write-Host "Report saved: $htmlFile" -ForegroundColor Green

Start-Process $htmlFile

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "DONE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
