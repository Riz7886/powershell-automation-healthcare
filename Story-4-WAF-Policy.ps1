# ================================================================
# STORY 4: WAF POLICY
# Component: Web Application Firewall
# Duration: 4 minutes
# ================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  STORY 4: WAF POLICY" -ForegroundColor Cyan
Write-Host "  Component-Based Deployment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

# ----------------------------------------------------------------
# LOAD STATE
# ----------------------------------------------------------------
$stateFile = "$env:USERPROFILE\Desktop\MOVEit-Deployment-State.json"
if (-not (Test-Path $stateFile)) {
    Write-Log "ERROR: State file not found! Run Stories 1-3 first." "Red"
    exit 1
}

Write-Log "Loading deployment state..." "Yellow"
$state = Get-Content $stateFile | ConvertFrom-Json
Write-Log "State loaded successfully" "Green"
Write-Host ""

# Display current state
Write-Log "Current Configuration:" "Cyan"
Write-Log "  Deployment RG: $($state.DeploymentResourceGroup)" "White"
Write-Log "  Location: $($state.Location)" "White"
Write-Host ""

# Set subscription
az account set --subscription $state.SubscriptionId

# ----------------------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------------------
$wafPolicyName = "moveitWAFPolicy"
$wafMode = "Prevention"
$wafSKU = "Standard_AzureFrontDoor"

# ----------------------------------------------------------------
# CREATE WAF POLICY
# ----------------------------------------------------------------
Write-Log "============================================" "Cyan"
Write-Log "CREATING WAF POLICY" "Cyan"
Write-Log "============================================" "Cyan"
Write-Host ""

Write-Log "Creating WAF policy: $wafPolicyName..." "Yellow"
$wafExists = az network front-door waf-policy show --resource-group $state.DeploymentResourceGroup --name $wafPolicyName 2>$null
if (-not $wafExists) {
    az network front-door waf-policy create --resource-group $state.DeploymentResourceGroup --name $wafPolicyName --sku $wafSKU --mode $wafMode --output none
    Write-Log "WAF policy created" "Green"
} else {
    Write-Log "WAF policy already exists" "Green"
}

# ----------------------------------------------------------------
# CONFIGURE POLICY SETTINGS
# ----------------------------------------------------------------
Write-Host ""
Write-Log "Configuring WAF policy settings..." "Yellow"

az network front-door waf-policy policy-setting update --resource-group $state.DeploymentResourceGroup --policy-name $wafPolicyName --mode Prevention --redirect-url "" --custom-block-response-status-code 403 --custom-block-response-body "QWNjZXNzIERlbmllZA==" --request-body-check Enabled --max-request-body-size-in-kb 524288 --file-upload-enforcement true --file-upload-limit-in-mb 500 --output none

Write-Log "Policy settings configured:" "Green"
Write-Log "  Mode: Prevention" "White"
Write-Log "  Block Status: 403" "White"
Write-Log "  Request Body Check: Enabled" "White"
Write-Log "  Max Body Size: 524288 KB" "White"
Write-Log "  File Upload Limit: 500 MB" "White"

# ----------------------------------------------------------------
# ADD MANAGED RULES
# ----------------------------------------------------------------
Write-Host ""
Write-Log "Adding managed rule sets..." "Yellow"

# DefaultRuleSet
$defaultRuleSetExists = az network front-door waf-policy managed-rule-definition list --resource-group $state.DeploymentResourceGroup --policy-name $wafPolicyName --query "[?ruleSetType=='DefaultRuleSet']" --output json 2>$null | ConvertFrom-Json
if (-not $defaultRuleSetExists) {
    az network front-door waf-policy managed-rules add --resource-group $state.DeploymentResourceGroup --policy-name $wafPolicyName --type DefaultRuleSet --version 1.0 --output none
    Write-Log "  Added: DefaultRuleSet 1.0" "Green"
} else {
    Write-Log "  DefaultRuleSet already exists" "Green"
}

# BotManagerRuleSet
$botRuleSetExists = az network front-door waf-policy managed-rule-definition list --resource-group $state.DeploymentResourceGroup --policy-name $wafPolicyName --query "[?ruleSetType=='Microsoft_BotManagerRuleSet']" --output json 2>$null | ConvertFrom-Json
if (-not $botRuleSetExists) {
    az network front-door waf-policy managed-rules add --resource-group $state.DeploymentResourceGroup --policy-name $wafPolicyName --type Microsoft_BotManagerRuleSet --version 1.0 --output none
    Write-Log "  Added: Microsoft_BotManagerRuleSet 1.0" "Green"
} else {
    Write-Log "  BotManagerRuleSet already exists" "Green"
}

# ----------------------------------------------------------------
# ADD CUSTOM RULES
# ----------------------------------------------------------------
Write-Host ""
Write-Log "Adding custom rules for MOVEit..." "Yellow"

# Custom Rule 1: Allow Large Uploads
$rule1Exists = az network front-door waf-policy rule show --resource-group $state.DeploymentResourceGroup --policy-name $wafPolicyName --name "AllowLargeUploads" 2>$null
if (-not $rule1Exists) {
    az network front-door waf-policy rule create --resource-group $state.DeploymentResourceGroup --policy-name $wafPolicyName --name "AllowLargeUploads" --rule-type MatchRule --priority 100 --action Allow --match-condition "RequestMethod Equal POST PUT PATCH" --output none 2>$null
    Write-Log "  Added: AllowLargeUploads (priority 100)" "Green"
} else {
    Write-Log "  AllowLargeUploads already exists" "Green"
}

# Custom Rule 2: Allow MOVEit Methods
$rule2Exists = az network front-door waf-policy rule show --resource-group $state.DeploymentResourceGroup --policy-name $wafPolicyName --name "AllowMOVEitMethods" 2>$null
if (-not $rule2Exists) {
    az network front-door waf-policy rule create --resource-group $state.DeploymentResourceGroup --policy-name $wafPolicyName --name "AllowMOVEitMethods" --rule-type MatchRule --priority 110 --action Allow --match-condition "RequestMethod Equal GET POST HEAD OPTIONS PUT PATCH DELETE" --output none 2>$null
    Write-Log "  Added: AllowMOVEitMethods (priority 110)" "Green"
} else {
    Write-Log "  AllowMOVEitMethods already exists" "Green"
}

# ----------------------------------------------------------------
# UPDATE STATE
# ----------------------------------------------------------------
$state | Add-Member -MemberType NoteProperty -Name "WAFPolicyName" -Value $wafPolicyName -Force
$state | Add-Member -MemberType NoteProperty -Name "WAFMode" -Value $wafMode -Force
$state | ConvertTo-Json | Out-File -FilePath $stateFile -Encoding UTF8

# ----------------------------------------------------------------
# SUMMARY
# ----------------------------------------------------------------
Write-Host ""
Write-Log "============================================" "Green"
Write-Log "  STORY 4 COMPLETE!" "Green"
Write-Log "============================================" "Green"
Write-Host ""
Write-Log "WAF Policy Configuration:" "Cyan"
Write-Log "  Name: $wafPolicyName" "White"
Write-Log "  Mode: Prevention" "White"
Write-Log "  SKU: $wafSKU" "White"
Write-Host ""
Write-Log "Managed Rules:" "White"
Write-Log "  - DefaultRuleSet 1.0 (OWASP)" "White"
Write-Log "  - Microsoft_BotManagerRuleSet 1.0" "White"
Write-Host ""
Write-Log "Custom Rules:" "White"
Write-Log "  - AllowLargeUploads (priority 100)" "White"
Write-Log "  - AllowMOVEitMethods (priority 110)" "White"
Write-Host ""
Write-Log "State updated: $stateFile" "Yellow"
Write-Host ""
Write-Log "NEXT: Run Story-5-Front-Door.ps1" "Cyan"
Write-Host ""
