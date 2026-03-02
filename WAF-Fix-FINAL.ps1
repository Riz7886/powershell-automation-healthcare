# WAF Fix Script - Finds Resources First Then Fixes
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "WAF FIX - Finding MOVEit Resources" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Get all subscriptions
Write-Host "Step 1: Getting subscriptions..." -ForegroundColor Yellow
$subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
Write-Host "Found $($subs.Count) subscriptions" -ForegroundColor Green

# Step 2: Find the moveit WAF policy
Write-Host ""
Write-Host "Step 2: Searching for MOVEit WAF policy..." -ForegroundColor Yellow

$foundPolicy = $null
$foundSub = $null
$foundRG = $null

foreach ($sub in $subs) {
    Write-Host "  Checking: $($sub.Name)..." -ForegroundColor Gray -NoNewline
    Set-AzContext -Subscription $sub.Id -ErrorAction SilentlyContinue | Out-Null
    
    # Search for WAF policy
    $resources = Get-AzResource -ResourceType "Microsoft.Cdn/cdnWebApplicationFirewallPolicies" -ErrorAction SilentlyContinue
    
    if ($resources) {
        foreach ($r in $resources) {
            if ($r.Name -like "*moveit*" -or $r.Name -like "*waf*") {
                Write-Host " FOUND!" -ForegroundColor Green
                $foundPolicy = $r
                $foundSub = $sub
                $foundRG = $r.ResourceGroupName
                Write-Host ""
                Write-Host "  Policy Name: $($r.Name)" -ForegroundColor Cyan
                Write-Host "  Resource Group: $($r.ResourceGroupName)" -ForegroundColor Cyan
                Write-Host "  Subscription: $($sub.Name)" -ForegroundColor Cyan
                break
            }
        }
    }
    
    if (-not $foundPolicy) {
        # Also check classic front door WAF
        $classicWaf = Get-AzResource -ResourceType "Microsoft.Network/FrontDoorWebApplicationFirewallPolicies" -ErrorAction SilentlyContinue
        if ($classicWaf) {
            foreach ($r in $classicWaf) {
                if ($r.Name -like "*moveit*") {
                    Write-Host " FOUND (Classic)!" -ForegroundColor Green
                    $foundPolicy = $r
                    $foundSub = $sub
                    $foundRG = $r.ResourceGroupName
                    break
                }
            }
        }
    }
    
    if (-not $foundPolicy) {
        Write-Host "" -ForegroundColor Gray
    }
    
    if ($foundPolicy) { break }
}

if (-not $foundPolicy) {
    Write-Host ""
    Write-Host "ERROR: Could not find MOVEit WAF policy!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Searching ALL CDN WAF policies..." -ForegroundColor Yellow
    
    foreach ($sub in $subs) {
        Set-AzContext -Subscription $sub.Id -ErrorAction SilentlyContinue | Out-Null
        $allWaf = Get-AzResource -ResourceType "Microsoft.Cdn/cdnWebApplicationFirewallPolicies" -ErrorAction SilentlyContinue
        if ($allWaf) {
            foreach ($w in $allWaf) {
                Write-Host "  Found: $($w.Name) in $($w.ResourceGroupName) ($($sub.Name))" -ForegroundColor Cyan
            }
        }
    }
    exit 1
}

# Step 3: Add managed rules via REST API
Write-Host ""
Write-Host "Step 3: Adding managed rules to $($foundPolicy.Name)..." -ForegroundColor Yellow

Set-AzContext -Subscription $foundSub.Id | Out-Null
$token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

$uri = "https://management.azure.com$($foundPolicy.ResourceId)?api-version=2024-02-01"

try {
    # Get current policy
    Write-Host "  Getting current configuration..." -ForegroundColor Gray
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
    
    # Check current rules
    $currentRules = $response.properties.managedRules.managedRuleSets
    Write-Host "  Current managed rule sets: $($currentRules.Count)" -ForegroundColor Gray
    
    if ($currentRules) {
        foreach ($rule in $currentRules) {
            Write-Host "    - $($rule.ruleSetType) v$($rule.ruleSetVersion)" -ForegroundColor Gray
        }
    }
    
    # Check if DefaultRuleSet already exists
    $hasDefaultRuleSet = $currentRules | Where-Object { $_.ruleSetType -like "*DefaultRuleSet*" }
    
    if ($hasDefaultRuleSet) {
        Write-Host ""
        Write-Host "SUCCESS: DefaultRuleSet already configured!" -ForegroundColor Green
        $status = "Already Configured"
    } else {
        # Add DefaultRuleSet
        Write-Host "  Adding Microsoft_DefaultRuleSet 2.1..." -ForegroundColor Yellow
        
        if (-not $response.properties.managedRules) {
            $response.properties | Add-Member -NotePropertyName "managedRules" -NotePropertyValue @{ managedRuleSets = @() } -Force
        }
        if (-not $response.properties.managedRules.managedRuleSets) {
            $response.properties.managedRules.managedRuleSets = @()
        }
        
        $newRule = @{
            ruleSetType = "Microsoft_DefaultRuleSet"
            ruleSetVersion = "2.1"
            ruleGroupOverrides = @()
        }
        
        $response.properties.managedRules.managedRuleSets += $newRule
        
        $body = $response | ConvertTo-Json -Depth 30
        
        Write-Host "  Updating policy..." -ForegroundColor Yellow
        $updateResult = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $body
        
        Write-Host ""
        Write-Host "SUCCESS: Microsoft_DefaultRuleSet 2.1 ADDED!" -ForegroundColor Green
        $status = "Microsoft_DefaultRuleSet v2.1 ADDED"
    }
    
} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $status = "Error - Manual fix required"
    
    Write-Host ""
    Write-Host "MANUAL FIX:" -ForegroundColor Yellow
    Write-Host "1. Go to Azure Portal" -ForegroundColor White
    Write-Host "2. Search for: $($foundPolicy.Name)" -ForegroundColor White
    Write-Host "3. Click Managed rules > + Add" -ForegroundColor White
    Write-Host "4. Select Microsoft_DefaultRuleSet v2.1" -ForegroundColor White
    Write-Host "5. Save" -ForegroundColor White
}

# Generate HTML Report
Write-Host ""
Write-Host "Generating report..." -ForegroundColor Yellow

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$htmlFile = "$env:USERPROFILE\Desktop\WAF-Fix-Report-$timestamp.html"

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
        .status { padding: 20px; border-radius: 8px; text-align: center; color: white; background: $statusColor; margin: 20px 0; }
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
        
        <div class="status">
            <h2>$status</h2>
        </div>
        
        <h2>Answer to Tony's Question</h2>
        <div class="info">
            <strong>Q:</strong> Does moveitwaf inherit rules from PyxIQPolicy?<br><br>
            <strong>A:</strong> No. Azure WAF policies do NOT inherit from each other. Each policy needs managed rules configured separately.
        </div>
        
        <h2>Policy Details</h2>
        <table>
            <tr><th>Setting</th><th>Value</th></tr>
            <tr><td>Policy Name</td><td>$($foundPolicy.Name)</td></tr>
            <tr><td>Resource Group</td><td>$foundRG</td></tr>
            <tr><td>Subscription</td><td>$($foundSub.Name)</td></tr>
            <tr><td>Status</td><td><strong>$status</strong></td></tr>
        </table>
        
        <h2>Comparison</h2>
        <table>
            <tr><th>Policy</th><th>Managed Rules</th></tr>
            <tr><td>PyxIQPolicy</td><td>DefaultRuleSet v1.0</td></tr>
            <tr><td>$($foundPolicy.Name)</td><td>$status</td></tr>
        </table>
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $htmlFile -Encoding UTF8
Write-Host "Report: $htmlFile" -ForegroundColor Green

Start-Process $htmlFile

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "DONE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
