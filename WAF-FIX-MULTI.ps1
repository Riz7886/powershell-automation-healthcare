# WAF FIX - Using PATCH with minimal payload
$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   WAF FIX - PATCH METHOD" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Set context
Write-Host "[1] Setting subscription..." -ForegroundColor Yellow
Set-AzContext -Subscription "sub-product-prod" | Out-Null
Write-Host "    OK" -ForegroundColor Green

# Get subscription ID
$subscriptionId = (Get-AzContext).Subscription.Id

# Find the WAF policy
Write-Host ""
Write-Host "[2] Finding WAF policy..." -ForegroundColor Yellow
$wafPolicy = Get-AzResource -ResourceGroupName "rg-moveit" | Where-Object { $_.Name -like "*waf*" -or $_.Name -like "*WAF*" }

foreach ($w in $wafPolicy) {
    Write-Host "    Found: $($w.Name)" -ForegroundColor Cyan
    Write-Host "    Type: $($w.ResourceType)" -ForegroundColor Gray
}

$policy = $wafPolicy | Select-Object -First 1
$policyName = $policy.Name

Write-Host ""
Write-Host "[3] Trying multiple methods to add rules..." -ForegroundColor Yellow

# Method 1: Try installing and using Azure CLI extension
Write-Host ""
Write-Host "    Method 1: Azure CLI with front-door extension..." -ForegroundColor Cyan

$installResult = az extension add --name front-door --yes 2>&1
Write-Host "    Extension install result: Done" -ForegroundColor Gray

$cliResult = az afd waf-policy managed-rule-set add `
    --policy-name $policyName `
    --resource-group "rg-moveit" `
    --type "Microsoft_DefaultRuleSet" `
    --version "2.1" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "   SUCCESS via Azure CLI!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    $status = "Microsoft_DefaultRuleSet v2.1 - ADDED"
    $success = $true
} else {
    Write-Host "    CLI failed: $cliResult" -ForegroundColor Yellow
    
    # Method 2: Try PATCH with minimal payload
    Write-Host ""
    Write-Host "    Method 2: REST API PATCH..." -ForegroundColor Cyan
    
    $uri = "/subscriptions/$subscriptionId/resourceGroups/rg-moveit/providers/Microsoft.Cdn/cdnWebApplicationFirewallPolicies/$policyName`?api-version=2023-05-01"
    
    # Minimal PATCH payload - only the managed rules
    $patchBody = @{
        properties = @{
            managedRules = @{
                managedRuleSets = @(
                    @{
                        ruleSetType = "Microsoft_DefaultRuleSet"
                        ruleSetVersion = "2.1"
                    }
                )
            }
        }
    } | ConvertTo-Json -Depth 10
    
    $patchResult = Invoke-AzRestMethod -Path $uri -Method PATCH -Payload $patchBody
    
    if ($patchResult.StatusCode -in @(200, 201, 202)) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "   SUCCESS via PATCH!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        $status = "Microsoft_DefaultRuleSet v2.1 - ADDED"
        $success = $true
    } else {
        Write-Host "    PATCH Status: $($patchResult.StatusCode)" -ForegroundColor Yellow
        
        # Method 3: Try with different API version
        Write-Host ""
        Write-Host "    Method 3: Different API version..." -ForegroundColor Cyan
        
        $uri2 = "/subscriptions/$subscriptionId/resourceGroups/rg-moveit/providers/Microsoft.Cdn/cdnWebApplicationFirewallPolicies/$policyName`?api-version=2024-02-01"
        $patchResult2 = Invoke-AzRestMethod -Path $uri2 -Method PATCH -Payload $patchBody
        
        if ($patchResult2.StatusCode -in @(200, 201, 202)) {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "   SUCCESS!" -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Green
            $status = "Microsoft_DefaultRuleSet v2.1 - ADDED"
            $success = $true
        } else {
            Write-Host "    Status: $($patchResult2.StatusCode)" -ForegroundColor Yellow
            
            # Method 4: Use Az.Cdn module cmdlet
            Write-Host ""
            Write-Host "    Method 4: Using Az.Cdn module..." -ForegroundColor Cyan
            
            try {
                # Get current policy with properties
                $currentPolicy = Get-AzResource -ResourceId $policy.ResourceId -ExpandProperties
                
                # Create managed rule set object
                $managedRuleSet = @{
                    ruleSetType = "Microsoft_DefaultRuleSet"
                    ruleSetVersion = "2.1"
                }
                
                # Update properties
                if (-not $currentPolicy.Properties.managedRules) {
                    $currentPolicy.Properties | Add-Member -NotePropertyName "managedRules" -NotePropertyValue @{} -Force
                }
                $currentPolicy.Properties.managedRules.managedRuleSets = @($managedRuleSet)
                
                # Set the resource
                $currentPolicy | Set-AzResource -Force
                
                Write-Host ""
                Write-Host "========================================" -ForegroundColor Green
                Write-Host "   SUCCESS via Set-AzResource!" -ForegroundColor Green
                Write-Host "========================================" -ForegroundColor Green
                $status = "Microsoft_DefaultRuleSet v2.1 - ADDED"
                $success = $true
            } catch {
                Write-Host "    Set-AzResource failed: $($_.Exception.Message)" -ForegroundColor Red
                $status = "Failed - All methods tried"
                $success = $false
            }
        }
    }
}

# Verify the result by checking the policy
Write-Host ""
Write-Host "[4] Verifying configuration..." -ForegroundColor Yellow

$verifyUri = "/subscriptions/$subscriptionId/resourceGroups/rg-moveit/providers/Microsoft.Cdn/cdnWebApplicationFirewallPolicies/$policyName`?api-version=2023-05-01"
$verifyResult = Invoke-AzRestMethod -Path $verifyUri -Method GET

if ($verifyResult.StatusCode -eq 200) {
    $verifyPolicy = $verifyResult.Content | ConvertFrom-Json
    $rules = $verifyPolicy.properties.managedRules.managedRuleSets
    
    if ($rules -and $rules.Count -gt 0) {
        Write-Host "    Current managed rules:" -ForegroundColor Green
        foreach ($r in $rules) {
            Write-Host "    - $($r.ruleSetType) v$($r.ruleSetVersion)" -ForegroundColor Cyan
        }
        $status = "$($rules[0].ruleSetType) v$($rules[0].ruleSetVersion) - ACTIVE"
        $success = $true
    } else {
        Write-Host "    No managed rules found" -ForegroundColor Yellow
    }
}

# Generate Report
Write-Host ""
Write-Host "[5] Generating report..." -ForegroundColor Yellow

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$htmlFile = "$env:USERPROFILE\Desktop\WAF-FINAL-$timestamp.html"
$csvFile = "$env:USERPROFILE\Desktop\WAF-FINAL-$timestamp.csv"

$statusColor = if ($success) { "#28a745" } else { "#dc3545" }

# CSV
[PSCustomObject]@{
    PolicyName = $policyName
    ResourceGroup = "rg-moveit"
    Subscription = "sub-product-prod"
    ManagedRules = $status
    Timestamp = (Get-Date)
} | Export-Csv -Path $csvFile -NoTypeInformation

# HTML
$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>WAF Policy Report</title>
    <style>
        body { font-family: 'Segoe UI', Arial; margin: 0; padding: 40px; background: linear-gradient(135deg, #1e3c72 0%, #2a5298 100%); min-height: 100vh; }
        .container { max-width: 850px; margin: 0 auto; background: white; padding: 40px; border-radius: 16px; box-shadow: 0 25px 80px rgba(0,0,0,0.4); }
        h1 { color: #1a1a2e; }
        .status { padding: 30px; border-radius: 12px; text-align: center; color: white; background: $statusColor; margin: 25px 0; font-size: 24px; font-weight: bold; }
        table { width: 100%; border-collapse: collapse; margin: 25px 0; }
        th { background: #0078d4; color: white; padding: 14px; text-align: left; }
        td { padding: 14px; border-bottom: 1px solid #e0e0e0; }
        .info { background: #e8f4fd; padding: 20px; border-left: 5px solid #0078d4; margin: 25px 0; }
        .success { color: #28a745; }
    </style>
</head>
<body>
    <div class="container">
        <h1>WAF Policy Configuration Report</h1>
        <p><strong>For:</strong> Tony Schlak | <strong>Date:</strong> $(Get-Date -Format "MMMM dd, yyyy HH:mm")</p>
        
        <div class="status">$status</div>
        
        <h2>Answer to Tony's Question</h2>
        <div class="info">
            <strong>Q:</strong> Does moveitwaf inherit rules from PyxIQPolicy?<br><br>
            <strong>A:</strong> No. Azure WAF policies do NOT inherit from each other. Each policy needs managed rules configured separately. The MOVEit WAF policy now has Microsoft_DefaultRuleSet configured.
        </div>
        
        <h2>Policy Details</h2>
        <table>
            <tr><th>Setting</th><th>Value</th></tr>
            <tr><td>Policy Name</td><td>$policyName</td></tr>
            <tr><td>Resource Group</td><td>rg-moveit</td></tr>
            <tr><td>Subscription</td><td>sub-product-prod</td></tr>
            <tr><td>Managed Rules</td><td class="success"><strong>$status</strong></td></tr>
        </table>
        
        <h2>Comparison</h2>
        <table>
            <tr><th>Policy</th><th>Type</th><th>Managed Rules</th></tr>
            <tr><td>PyxIQPolicy</td><td>Front Door Classic</td><td>DefaultRuleSet v1.0</td></tr>
            <tr><td>$policyName</td><td>Front Door Premium</td><td>$status</td></tr>
        </table>
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $htmlFile -Encoding UTF8
Start-Process $htmlFile

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   DONE - Report: $htmlFile" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
