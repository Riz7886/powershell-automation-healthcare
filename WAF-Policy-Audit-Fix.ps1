param(
    [switch]$ApplyFix = $false
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = "$env:USERPROFILE\Desktop\WAF-Policy-Report-$timestamp"
$csvFile = "$reportPath.csv"
$htmlFile = "$reportPath.html"

Write-Host ""
Write-Host "WAF Policy Audit and Report" -ForegroundColor Cyan
Write-Host "Scanning all subscriptions for WAF policies" -ForegroundColor White
Write-Host ""

# Check Azure CLI
try {
    $azVersion = az version --output json 2>$null | ConvertFrom-Json
    Write-Host "Azure CLI: $($azVersion.'azure-cli')" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Azure CLI not found" -ForegroundColor Red
    exit 1
}

# Check login
$loginCheck = az account show 2>$null
if (-not $loginCheck) {
    Write-Host "Logging into Azure..." -ForegroundColor Yellow
    az login
}

# Get all subscriptions
Write-Host ""
Write-Host "Getting subscriptions..." -ForegroundColor Cyan
$subscriptions = az account list --query "[?state=='Enabled']" -o json | ConvertFrom-Json
Write-Host "Found $($subscriptions.Count) active subscriptions" -ForegroundColor Green

# Store all WAF policy data
$allPolicies = @()
$pyxiqPolicy = $null
$moveitPolicy = $null

foreach ($sub in $subscriptions) {
    Write-Host "Scanning: $($sub.name)" -ForegroundColor White
    az account set --subscription $sub.id 2>$null
    
    # Get Front Door Classic WAF policies
    $policies = az network front-door waf-policy list -o json 2>$null | ConvertFrom-Json
    
    if ($policies) {
        foreach ($policy in $policies) {
            $policyName = $policy.name
            $resourceGroup = $policy.resourceGroup
            $mode = $policy.policySettings.mode
            $enabled = $policy.policySettings.enabledState
            
            # Get managed rules for this policy
            $managedRuleSets = @()
            if ($policy.managedRules.managedRuleSets) {
                foreach ($ruleSet in $policy.managedRules.managedRuleSets) {
                    $managedRuleSets += "$($ruleSet.ruleSetType) v$($ruleSet.ruleSetVersion)"
                }
            }
            $managedRulesStr = if ($managedRuleSets.Count -gt 0) { $managedRuleSets -join ", " } else { "NONE" }
            
            # Get custom rules count
            $customRulesCount = if ($policy.customRules.rules) { $policy.customRules.rules.Count } else { 0 }
            
            # Get associations
            $associations = if ($policy.frontendEndpointLinks) { $policy.frontendEndpointLinks.Count } else { 0 }
            
            $policyData = [PSCustomObject]@{
                Subscription = $sub.name
                SubscriptionId = $sub.id
                PolicyName = $policyName
                ResourceGroup = $resourceGroup
                Mode = $mode
                Enabled = $enabled
                ManagedRules = $managedRulesStr
                CustomRulesCount = $customRulesCount
                Associations = $associations
                Type = "Front Door Classic"
            }
            
            $allPolicies += $policyData
            
            # Track specific policies
            if ($policyName -like "*PyxIQ*" -or $policyName -like "*pyxiq*") {
                $pyxiqPolicy = $policyData
                $pyxiqPolicy | Add-Member -NotePropertyName "FullPolicy" -NotePropertyValue $policy -Force
            }
            if ($policyName -like "*moveit*" -or $policyName -like "*MOVEit*") {
                $moveitPolicy = $policyData
                $moveitPolicy | Add-Member -NotePropertyName "FullPolicy" -NotePropertyValue $policy -Force
                $moveitPolicy | Add-Member -NotePropertyName "SubId" -NotePropertyValue $sub.id -Force
                $moveitPolicy | Add-Member -NotePropertyName "RG" -NotePropertyValue $resourceGroup -Force
            }
            
            Write-Host "  Found: $policyName (Mode: $mode, Rules: $managedRulesStr)" -ForegroundColor Green
        }
    }
    
    # Get CDN Front Door WAF policies (Standard/Premium)
    $cdnPolicies = az afd waf-policy list -o json 2>$null | ConvertFrom-Json
    
    if ($cdnPolicies) {
        foreach ($policy in $cdnPolicies) {
            $policyName = $policy.name
            $resourceGroup = $policy.resourceGroup
            
            $policyData = [PSCustomObject]@{
                Subscription = $sub.name
                SubscriptionId = $sub.id
                PolicyName = $policyName
                ResourceGroup = $resourceGroup
                Mode = "Standard/Premium"
                Enabled = "Yes"
                ManagedRules = "CDN Front Door"
                CustomRulesCount = 0
                Associations = 0
                Type = "CDN Front Door"
            }
            
            $allPolicies += $policyData
            Write-Host "  Found (CDN): $policyName" -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "Scan complete. Found $($allPolicies.Count) WAF policies." -ForegroundColor Cyan
Write-Host ""

# Generate CSV Report
Write-Host "Generating CSV report..." -ForegroundColor Yellow
$allPolicies | Export-Csv -Path $csvFile -NoTypeInformation
Write-Host "CSV saved: $csvFile" -ForegroundColor Green

# Generate HTML Report
Write-Host "Generating HTML report..." -ForegroundColor Yellow

$pyxiqStatus = if ($pyxiqPolicy) { "FOUND" } else { "NOT FOUND" }
$pyxiqColor = if ($pyxiqPolicy) { "#28a745" } else { "#dc3545" }
$pyxiqRules = if ($pyxiqPolicy) { $pyxiqPolicy.ManagedRules } else { "N/A" }

$moveitStatus = if ($moveitPolicy) { "FOUND" } else { "NOT FOUND" }
$moveitColor = if ($moveitPolicy) { "#28a745" } else { "#dc3545" }
$moveitRules = if ($moveitPolicy) { $moveitPolicy.ManagedRules } else { "N/A" }

$needsFix = $false
$fixMessage = ""
if ($moveitPolicy -and $moveitPolicy.ManagedRules -eq "NONE") {
    $needsFix = $true
    $moveitColor = "#ffc107"
    $fixMessage = "MOVEit WAF policy exists but has NO managed rules configured!"
}

$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>WAF Policy Audit Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #0078d4; margin-top: 30px; }
        .summary-box { display: inline-block; padding: 20px; margin: 10px; border-radius: 8px; color: white; min-width: 200px; text-align: center; }
        .green { background: #28a745; }
        .red { background: #dc3545; }
        .yellow { background: #ffc107; color: #333; }
        .blue { background: #0078d4; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th { background: #0078d4; color: white; padding: 12px; text-align: left; }
        td { padding: 10px; border-bottom: 1px solid #ddd; }
        tr:hover { background: #f5f5f5; }
        .status-found { color: #28a745; font-weight: bold; }
        .status-missing { color: #dc3545; font-weight: bold; }
        .status-warning { color: #ffc107; font-weight: bold; }
        .policy-card { border: 1px solid #ddd; border-radius: 8px; padding: 15px; margin: 10px 0; }
        .policy-card h3 { margin-top: 0; color: #0078d4; }
        .detail-row { display: flex; margin: 5px 0; }
        .detail-label { font-weight: bold; width: 150px; }
        .detail-value { flex: 1; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; color: #666; font-size: 12px; }
        .alert { padding: 15px; border-radius: 5px; margin: 15px 0; }
        .alert-warning { background: #fff3cd; border: 1px solid #ffc107; }
        .alert-success { background: #d4edda; border: 1px solid #28a745; }
        .alert-info { background: #cce5ff; border: 1px solid #0078d4; }
    </style>
</head>
<body>
    <div class="container">
        <h1>WAF Policy Audit Report</h1>
        <p>Generated: $(Get-Date -Format "MMMM dd, yyyy HH:mm:ss")</p>
        
        <h2>Summary</h2>
        <div>
            <div class="summary-box blue">
                <h3>$($allPolicies.Count)</h3>
                <p>Total Policies</p>
            </div>
            <div class="summary-box" style="background: $pyxiqColor">
                <h3>PyxIQPolicy</h3>
                <p>$pyxiqStatus</p>
            </div>
            <div class="summary-box" style="background: $moveitColor">
                <h3>MOVEit WAF</h3>
                <p>$moveitStatus</p>
            </div>
        </div>
        
        $(if ($needsFix) {
        @"
        <div class="alert alert-warning">
            <strong>Action Required:</strong> $fixMessage
        </div>
"@
        })
        
        <h2>PyxIQPolicy Configuration</h2>
        $(if ($pyxiqPolicy) {
        @"
        <div class="policy-card">
            <h3>PyxIQPolicy</h3>
            <div class="detail-row"><span class="detail-label">Subscription:</span><span class="detail-value">$($pyxiqPolicy.Subscription)</span></div>
            <div class="detail-row"><span class="detail-label">Resource Group:</span><span class="detail-value">$($pyxiqPolicy.ResourceGroup)</span></div>
            <div class="detail-row"><span class="detail-label">Mode:</span><span class="detail-value">$($pyxiqPolicy.Mode)</span></div>
            <div class="detail-row"><span class="detail-label">Status:</span><span class="detail-value">$($pyxiqPolicy.Enabled)</span></div>
            <div class="detail-row"><span class="detail-label">Managed Rules:</span><span class="detail-value" style="color: #28a745; font-weight: bold;">$($pyxiqPolicy.ManagedRules)</span></div>
            <div class="detail-row"><span class="detail-label">Custom Rules:</span><span class="detail-value">$($pyxiqPolicy.CustomRulesCount)</span></div>
            <div class="detail-row"><span class="detail-label">Associations:</span><span class="detail-value">$($pyxiqPolicy.Associations)</span></div>
        </div>
"@
        } else { "<p class='status-missing'>PyxIQPolicy not found</p>" })
        
        <h2>MOVEit WAF Policy Configuration</h2>
        $(if ($moveitPolicy) {
        @"
        <div class="policy-card">
            <h3>$($moveitPolicy.PolicyName)</h3>
            <div class="detail-row"><span class="detail-label">Subscription:</span><span class="detail-value">$($moveitPolicy.Subscription)</span></div>
            <div class="detail-row"><span class="detail-label">Resource Group:</span><span class="detail-value">$($moveitPolicy.ResourceGroup)</span></div>
            <div class="detail-row"><span class="detail-label">Mode:</span><span class="detail-value">$($moveitPolicy.Mode)</span></div>
            <div class="detail-row"><span class="detail-label">Status:</span><span class="detail-value">$($moveitPolicy.Enabled)</span></div>
            <div class="detail-row"><span class="detail-label">Managed Rules:</span><span class="detail-value" style="color: $(if($moveitPolicy.ManagedRules -eq 'NONE'){'#dc3545'}else{'#28a745'}); font-weight: bold;">$($moveitPolicy.ManagedRules)</span></div>
            <div class="detail-row"><span class="detail-label">Custom Rules:</span><span class="detail-value">$($moveitPolicy.CustomRulesCount)</span></div>
            <div class="detail-row"><span class="detail-label">Associations:</span><span class="detail-value">$($moveitPolicy.Associations)</span></div>
        </div>
"@
        } else { "<p class='status-missing'>MOVEit WAF Policy not found</p>" })
        
        <h2>All WAF Policies</h2>
        <table>
            <tr>
                <th>Policy Name</th>
                <th>Subscription</th>
                <th>Resource Group</th>
                <th>Mode</th>
                <th>Managed Rules</th>
                <th>Custom Rules</th>
                <th>Associations</th>
            </tr>
            $($allPolicies | ForEach-Object {
                $rulesColor = if ($_.ManagedRules -eq "NONE") { "#dc3545" } else { "#28a745" }
                "<tr>
                    <td><strong>$($_.PolicyName)</strong></td>
                    <td>$($_.Subscription)</td>
                    <td>$($_.ResourceGroup)</td>
                    <td>$($_.Mode)</td>
                    <td style='color: $rulesColor; font-weight: bold;'>$($_.ManagedRules)</td>
                    <td>$($_.CustomRulesCount)</td>
                    <td>$($_.Associations)</td>
                </tr>"
            })
        </table>
        
        <h2>Recommendation</h2>
        <div class="alert alert-info">
            $(if ($pyxiqPolicy -and $moveitPolicy -and $moveitPolicy.ManagedRules -ne "NONE") {
                "<strong>Status: All Good</strong><br>Both PyxIQPolicy and MOVEit WAF policy are configured with managed rules. No action needed."
            } elseif ($pyxiqPolicy -and $moveitPolicy -and $moveitPolicy.ManagedRules -eq "NONE") {
                "<strong>Status: Action Required</strong><br>MOVEit WAF policy exists but has no managed rules. Apply DefaultRuleSet_1.0 to match PyxIQPolicy configuration."
            } elseif ($pyxiqPolicy -and -not $moveitPolicy) {
                "<strong>Status: MOVEit WAF Missing</strong><br>PyxIQPolicy exists but no MOVEit WAF policy found. Consider creating one with matching rules."
            } else {
                "<strong>Status: Review Required</strong><br>Please review the WAF policy configurations."
            })
        </div>
        
        <div class="footer">
            <p>Report generated by WAF Policy Audit Script</p>
            <p>Files: $csvFile | $htmlFile</p>
        </div>
    </div>
</body>
</html>
"@

$htmlContent | Out-File -FilePath $htmlFile -Encoding UTF8
Write-Host "HTML saved: $htmlFile" -ForegroundColor Green

# Apply fix if needed and requested
if ($needsFix -or ($moveitPolicy -and $moveitPolicy.ManagedRules -eq "NONE")) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "MOVEit WAF Policy needs managed rules!" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "PyxIQPolicy has: $($pyxiqPolicy.ManagedRules)" -ForegroundColor White
    Write-Host "MOVEit has: $($moveitPolicy.ManagedRules)" -ForegroundColor Red
    Write-Host ""
    
    if ($ApplyFix) {
        Write-Host "ApplyFix flag detected. Adding managed rules to MOVEit WAF..." -ForegroundColor Cyan
        
        # Set subscription
        az account set --subscription $moveitPolicy.SubId 2>$null
        
        # Add DefaultRuleSet_1.0 (same as PyxIQ)
        Write-Host "Adding DefaultRuleSet_1.0 (OWASP rules)..." -ForegroundColor Yellow
        $result = az network front-door waf-policy managed-rules add `
            --policy-name $moveitPolicy.PolicyName `
            --resource-group $moveitPolicy.RG `
            --type DefaultRuleSet `
            --version "1.0" `
            -o json 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "SUCCESS: DefaultRuleSet_1.0 added to MOVEit WAF policy!" -ForegroundColor Green
            Write-Host ""
            Write-Host "MOVEit WAF now matches PyxIQPolicy configuration." -ForegroundColor Green
        } else {
            Write-Host "Note: $result" -ForegroundColor Yellow
            Write-Host "Rules may already exist or different command needed for this WAF type." -ForegroundColor Yellow
        }
    } else {
        Write-Host "To apply the fix, run:" -ForegroundColor White
        Write-Host "  .\WAF-Policy-Audit-Fix.ps1 -ApplyFix" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "This will add DefaultRuleSet_1.0 to MOVEit WAF (same as PyxIQ)." -ForegroundColor White
        Write-Host "This is SAFE and will NOT break existing policies." -ForegroundColor Green
    }
}

# Open HTML report
Write-Host ""
Write-Host "Opening HTML report..." -ForegroundColor Cyan
Start-Process $htmlFile

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Reports saved to Desktop:" -ForegroundColor White
Write-Host "  CSV: $csvFile" -ForegroundColor Gray
Write-Host "  HTML: $htmlFile" -ForegroundColor Gray
Write-Host ""
