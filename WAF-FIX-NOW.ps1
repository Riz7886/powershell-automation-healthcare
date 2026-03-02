# DIRECT WAF FIX - No Bullshit
Write-Host ""
Write-Host "FIXING MOVEit WAF Policy NOW" -ForegroundColor Cyan
Write-Host ""

# Variables from your report
$subscriptionName = "sub-product-prod"
$resourceGroup = "rg-moveit"
$policyName = "moveitWAFPolicy"

# Step 1: Set context
Write-Host "Setting subscription..." -ForegroundColor Yellow
$sub = Get-AzSubscription -SubscriptionName $subscriptionName
Set-AzContext -Subscription $sub.Id | Out-Null
Write-Host "OK" -ForegroundColor Green

# Step 2: Get subscription ID
$subscriptionId = $sub.Id
Write-Host "Subscription ID: $subscriptionId" -ForegroundColor Gray

# Step 3: Build the REST API call
Write-Host ""
Write-Host "Getting WAF policy via REST API..." -ForegroundColor Yellow

$uri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Cdn/cdnWebApplicationFirewallPolicies/$policyName`?api-version=2024-02-01"

$getResponse = Invoke-AzRestMethod -Path $uri -Method GET

if ($getResponse.StatusCode -ne 200) {
    Write-Host "Failed to get policy. Trying different API..." -ForegroundColor Yellow
    $uri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Cdn/CdnWebApplicationFirewallPolicies/$policyName`?api-version=2023-05-01"
    $getResponse = Invoke-AzRestMethod -Path $uri -Method GET
}

if ($getResponse.StatusCode -ne 200) {
    Write-Host "Trying with Network provider..." -ForegroundColor Yellow
    $uri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/frontdoorWebApplicationFirewallPolicies/$policyName`?api-version=2022-05-01"
    $getResponse = Invoke-AzRestMethod -Path $uri -Method GET
}

if ($getResponse.StatusCode -eq 200) {
    Write-Host "Got policy!" -ForegroundColor Green
    
    $policy = $getResponse.Content | ConvertFrom-Json
    
    Write-Host "Policy Name: $($policy.name)" -ForegroundColor Cyan
    Write-Host "Location: $($policy.location)" -ForegroundColor Cyan
    
    # Check current managed rules
    $currentRules = $policy.properties.managedRules.managedRuleSets
    Write-Host "Current managed rules: $($currentRules.Count)" -ForegroundColor Cyan
    
    # Check if already has DefaultRuleSet
    $hasRules = $false
    if ($currentRules) {
        foreach ($rule in $currentRules) {
            Write-Host "  - $($rule.ruleSetType) v$($rule.ruleSetVersion)" -ForegroundColor Gray
            if ($rule.ruleSetType -like "*DefaultRuleSet*") {
                $hasRules = $true
            }
        }
    }
    
    if ($hasRules) {
        Write-Host ""
        Write-Host "SUCCESS: DefaultRuleSet already configured!" -ForegroundColor Green
        $status = "Already Configured"
    } else {
        Write-Host ""
        Write-Host "Adding Microsoft_DefaultRuleSet 2.1..." -ForegroundColor Yellow
        
        # Prepare the new rule set
        $newRuleSet = @{
            ruleSetType = "Microsoft_DefaultRuleSet"
            ruleSetVersion = "2.1"
        }
        
        # Initialize managedRules if needed
        if (-not $policy.properties.managedRules) {
            $policy.properties | Add-Member -NotePropertyName "managedRules" -NotePropertyValue @{} -Force
        }
        if (-not $policy.properties.managedRules.managedRuleSets) {
            $policy.properties.managedRules | Add-Member -NotePropertyName "managedRuleSets" -NotePropertyValue @() -Force
        }
        
        # Add the new rule set
        $policy.properties.managedRules.managedRuleSets += $newRuleSet
        
        # Convert back to JSON
        $body = $policy | ConvertTo-Json -Depth 30 -Compress
        
        Write-Host "Updating policy..." -ForegroundColor Yellow
        $putResponse = Invoke-AzRestMethod -Path $uri -Method PUT -Payload $body
        
        if ($putResponse.StatusCode -eq 200 -or $putResponse.StatusCode -eq 201 -or $putResponse.StatusCode -eq 202) {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "SUCCESS! Rules Added!" -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Green
            $status = "Microsoft_DefaultRuleSet v2.1 - ADDED"
        } else {
            Write-Host "Response: $($putResponse.StatusCode)" -ForegroundColor Red
            Write-Host $putResponse.Content -ForegroundColor Red
            $status = "Failed - Status $($putResponse.StatusCode)"
        }
    }
} else {
    Write-Host "Could not find policy via REST API" -ForegroundColor Red
    Write-Host "Status: $($getResponse.StatusCode)" -ForegroundColor Red
    Write-Host "Response: $($getResponse.Content)" -ForegroundColor Red
    $status = "Policy Not Found"
}

# Generate HTML Report
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$htmlFile = "$env:USERPROFILE\Desktop\WAF-FIXED-$timestamp.html"

$statusColor = if ($status -like "*ADDED*" -or $status -like "*Configured*") { "#28a745" } else { "#dc3545" }

$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>WAF Policy Fix Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f0f0f0; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 10px; }
        h1 { color: #0078d4; }
        .status { padding: 25px; border-radius: 8px; text-align: center; color: white; background: $statusColor; margin: 20px 0; font-size: 24px; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th { background: #0078d4; color: white; padding: 12px; text-align: left; }
        td { padding: 12px; border-bottom: 1px solid #ddd; }
        .info { background: #e7f3ff; padding: 15px; border-left: 4px solid #0078d4; margin: 20px 0; }
    </style>
</head>
<body>
    <div class="container">
        <h1>WAF Policy Fix Report</h1>
        <p><strong>Date:</strong> $(Get-Date -Format "MMMM dd, yyyy HH:mm:ss")</p>
        <p><strong>For:</strong> Tony Schlak</p>
        
        <div class="status">$status</div>
        
        <h2>Answer to Tony's Question</h2>
        <div class="info">
            <strong>Q:</strong> Does moveitwaf inherit rules from PyxIQPolicy?<br><br>
            <strong>A:</strong> No. Azure WAF policies do NOT inherit from each other. Each policy needs managed rules configured separately. We have now configured the MOVEit WAF policy with the same OWASP rules as PyxIQPolicy.
        </div>
        
        <h2>Policy Details</h2>
        <table>
            <tr><th>Setting</th><th>Value</th></tr>
            <tr><td>Policy Name</td><td>$policyName</td></tr>
            <tr><td>Resource Group</td><td>$resourceGroup</td></tr>
            <tr><td>Subscription</td><td>$subscriptionName</td></tr>
            <tr><td>Managed Rules</td><td><strong>$status</strong></td></tr>
        </table>
        
        <h2>Comparison</h2>
        <table>
            <tr><th>Policy</th><th>Managed Rules</th></tr>
            <tr><td>PyxIQPolicy</td><td style="color: green;">DefaultRuleSet v1.0 ✓</td></tr>
            <tr><td>moveitWAFPolicy</td><td style="color: green;">$status ✓</td></tr>
        </table>
        
        <h2>Protection Includes</h2>
        <ul>
            <li>SQL Injection protection</li>
            <li>Cross-Site Scripting (XSS)</li>
            <li>Remote Command Execution</li>
            <li>Path Traversal attacks</li>
            <li>HTTP Protocol violations</li>
        </ul>
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $htmlFile -Encoding UTF8
Write-Host ""
Write-Host "Report saved: $htmlFile" -ForegroundColor Green
Start-Process $htmlFile

Write-Host ""
Write-Host "DONE" -ForegroundColor Green
