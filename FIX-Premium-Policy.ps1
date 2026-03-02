# FIX moveitwafpolicyPremium - The one Tony is looking at
$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   FIXING moveitwafpolicyPremium" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Set subscription
Write-Host "[1] Setting subscription..." -ForegroundColor Yellow
Set-AzContext -Subscription "sub-product-prod" | Out-Null
Write-Host "    OK" -ForegroundColor Green

$subscriptionId = (Get-AzContext).Subscription.Id
$resourceGroup = "rg-moveit"
$policyName = "moveitwafpolicyPremium"

# Try to add managed rule set using REST API
Write-Host ""
Write-Host "[2] Adding Microsoft_DefaultRuleSet 2.1 to $policyName..." -ForegroundColor Yellow

# Get current policy
$uri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Cdn/cdnWebApplicationFirewallPolicies/$policyName`?api-version=2023-05-01"

$getResponse = Invoke-AzRestMethod -Path $uri -Method GET

if ($getResponse.StatusCode -eq 200) {
    Write-Host "    Got policy" -ForegroundColor Green
    
    $policy = $getResponse.Content | ConvertFrom-Json
    
    # Check current rules
    Write-Host "    Current managed rules: $($policy.properties.managedRules.managedRuleSets.Count)" -ForegroundColor Gray
    
    # Create new managed rules structure
    $policy.properties.managedRules = @{
        managedRuleSets = @(
            @{
                ruleSetType = "Microsoft_DefaultRuleSet"
                ruleSetVersion = "2.1"
            }
        )
    }
    
    # Remove read-only properties
    $policy.PSObject.Properties.Remove('id')
    $policy.PSObject.Properties.Remove('type')
    $policy.PSObject.Properties.Remove('systemData')
    if ($policy.properties.PSObject.Properties['provisioningState']) {
        $policy.properties.PSObject.Properties.Remove('provisioningState')
    }
    if ($policy.properties.PSObject.Properties['resourceState']) {
        $policy.properties.PSObject.Properties.Remove('resourceState')
    }
    if ($policy.properties.PSObject.Properties['endpointLinks']) {
        $policy.properties.PSObject.Properties.Remove('endpointLinks')
    }
    
    $body = $policy | ConvertTo-Json -Depth 30 -Compress
    
    Write-Host "    Updating policy..." -ForegroundColor Yellow
    $putResponse = Invoke-AzRestMethod -Path $uri -Method PUT -Payload $body
    
    Write-Host "    Response: $($putResponse.StatusCode)" -ForegroundColor Cyan
    
    if ($putResponse.StatusCode -in @(200, 201, 202)) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "   SUCCESS!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
    } else {
        Write-Host "    PUT failed, trying PATCH..." -ForegroundColor Yellow
        
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
        
        $patchResponse = Invoke-AzRestMethod -Path $uri -Method PATCH -Payload $patchBody
        Write-Host "    PATCH Response: $($patchResponse.StatusCode)" -ForegroundColor Cyan
        
        if ($patchResponse.StatusCode -in @(200, 201, 202)) {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "   SUCCESS via PATCH!" -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "    API methods failed." -ForegroundColor Red
            Write-Host ""
            Write-Host "    DO IT MANUALLY:" -ForegroundColor Yellow
            Write-Host "    1. Go to Azure Portal" -ForegroundColor White
            Write-Host "    2. Search: moveitwafpolicyPremium" -ForegroundColor White
            Write-Host "    3. Click 'Managed rules' (left menu)" -ForegroundColor White
            Write-Host "    4. Click '+ Add'" -ForegroundColor White
            Write-Host "    5. Select 'Microsoft_DefaultRuleSet' v2.1" -ForegroundColor White
            Write-Host "    6. Click 'Add' then 'Save'" -ForegroundColor White
        }
    }
} else {
    Write-Host "    Could not get policy: $($getResponse.StatusCode)" -ForegroundColor Red
}

# Verify
Write-Host ""
Write-Host "[3] Verifying..." -ForegroundColor Yellow
Start-Sleep -Seconds 3

$verifyResponse = Invoke-AzRestMethod -Path $uri -Method GET
if ($verifyResponse.StatusCode -eq 200) {
    $verifyPolicy = $verifyResponse.Content | ConvertFrom-Json
    $rules = $verifyPolicy.properties.managedRules.managedRuleSets
    
    if ($rules -and $rules.Count -gt 0) {
        Write-Host "    Managed rules NOW configured:" -ForegroundColor Green
        foreach ($r in $rules) {
            Write-Host "    - $($r.ruleSetType) v$($r.ruleSetVersion)" -ForegroundColor Cyan
        }
    } else {
        Write-Host "    Still no rules - manual fix required" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "DONE - Tell Tony to refresh the page!" -ForegroundColor Green
Write-Host ""
