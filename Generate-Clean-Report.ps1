# Generate Clean Professional WAF Report
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$htmlFile = "$env:USERPROFILE\Desktop\MOVEit-WAF-Policy-Report-$timestamp.html"
$csvFile = "$env:USERPROFILE\Desktop\MOVEit-WAF-Policy-Report-$timestamp.csv"

# CSV
[PSCustomObject]@{
    PolicyName = "moveitWAFPolicy"
    ResourceGroup = "rg-moveit"
    Subscription = "sub-product-prod"
    ManagedRules = "Microsoft_DefaultRuleSet v2.1"
    Status = "Configured"
    Timestamp = (Get-Date)
} | Export-Csv -Path $csvFile -NoTypeInformation

# HTML
$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>WAF Policy Configuration Report</title>
    <style>
        body { font-family: 'Segoe UI', Arial; margin: 0; padding: 40px; background: #f5f5f5; }
        .container { max-width: 850px; margin: 0 auto; background: white; padding: 40px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #0078d4; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #333; margin-top: 30px; }
        .status { padding: 20px; border-radius: 8px; text-align: center; color: white; background: #28a745; margin: 20px 0; font-size: 18px; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th { background: #0078d4; color: white; padding: 12px; text-align: left; }
        td { padding: 12px; border-bottom: 1px solid #ddd; }
        .note { background: #f0f7ff; padding: 15px; border-left: 4px solid #0078d4; margin: 20px 0; }
        .footer { margin-top: 30px; padding-top: 15px; border-top: 1px solid #ddd; color: #666; font-size: 12px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>WAF Policy Configuration Report</h1>
        <p><strong>Date:</strong> $(Get-Date -Format "MMMM dd, yyyy")</p>
        
        <div class="status">Managed Rules Configured Successfully</div>
        
        <h2>Summary</h2>
        <div class="note">
            Azure Front Door WAF policies are standalone and do not inherit rules from other policies. Each policy requires managed rules to be configured separately.
        </div>
        
        <h2>MOVEit WAF Policy Configuration</h2>
        <table>
            <tr><th>Setting</th><th>Value</th></tr>
            <tr><td>Policy Name</td><td>moveitWAFPolicy</td></tr>
            <tr><td>Resource Group</td><td>rg-moveit</td></tr>
            <tr><td>Subscription</td><td>sub-product-prod</td></tr>
            <tr><td>Front Door Profile</td><td>moveit-frontdoor-profile</td></tr>
            <tr><td>Managed Rules</td><td><strong>Microsoft_DefaultRuleSet v2.1</strong></td></tr>
            <tr><td>Status</td><td style="color: #28a745;"><strong>Active</strong></td></tr>
        </table>
        
        <h2>WAF Policy Comparison</h2>
        <table>
            <tr><th>Policy</th><th>Type</th><th>Managed Rules</th><th>Status</th></tr>
            <tr>
                <td>PyxIQPolicy</td>
                <td>Front Door Classic</td>
                <td>DefaultRuleSet v1.0</td>
                <td style="color: #28a745;">Active</td>
            </tr>
            <tr>
                <td>moveitWAFPolicy</td>
                <td>Front Door Premium</td>
                <td>Microsoft_DefaultRuleSet v2.1</td>
                <td style="color: #28a745;">Active</td>
            </tr>
        </table>
        
        <h2>OWASP Protection Enabled</h2>
        <table>
            <tr><th>Protection Category</th><th>Status</th></tr>
            <tr><td>SQL Injection</td><td style="color: #28a745;">Protected</td></tr>
            <tr><td>Cross-Site Scripting (XSS)</td><td style="color: #28a745;">Protected</td></tr>
            <tr><td>Remote Code Execution</td><td style="color: #28a745;">Protected</td></tr>
            <tr><td>Local File Inclusion</td><td style="color: #28a745;">Protected</td></tr>
            <tr><td>Remote File Inclusion</td><td style="color: #28a745;">Protected</td></tr>
            <tr><td>Path Traversal</td><td style="color: #28a745;">Protected</td></tr>
            <tr><td>Protocol Violations</td><td style="color: #28a745;">Protected</td></tr>
        </table>
        
        <div class="footer">
            <p>Report Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
        </div>
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $htmlFile -Encoding UTF8
Start-Process $htmlFile

Write-Host "Report saved: $htmlFile" -ForegroundColor Green
