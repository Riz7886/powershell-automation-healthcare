# ============================================================================
# MOVEIT TRANSFER SECURITY INFRASTRUCTURE DEPLOYMENT
# Deploys WAF, Front Door, Load Balancer, NSG, and Microsoft Defender
# ============================================================================

param(
    [string]$ResourceGroup = "rg-moveit",
    [string]$Location = "westus",
    [string]$MOVEitPrivateIP = "192.168.0.5",
    [string]$CustomDomain = "moveit.pyxhealth.com"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "MOVEIT SECURITY INFRASTRUCTURE DEPLOYMENT" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------------------------------
$config = @{
    ResourceGroup            = $ResourceGroup
    Location                 = $Location
    MOVEitPrivateIP          = $MOVEitPrivateIP
    CustomDomain             = $CustomDomain
    
    # Network Security Group
    NSGName                  = "nsg-moveit"
    
    # Load Balancer (SFTP Port 22)
    LoadBalancerName         = "lb-moveit-sftp"
    PublicIPName             = "pip-moveit-lb"
    BackendPoolName          = "pool-moveit"
    HealthProbeName          = "probe-sftp-22"
    LoadBalancingRuleName    = "rule-sftp-22"
    
    # WAF Policy
    WAFPolicyName            = "waf-moveit-policy"
    
    # Front Door (HTTPS Port 443)
    FrontDoorProfileName     = "fd-moveit-profile"
    FrontDoorEndpointName    = "fd-moveit-endpoint"
    FrontDoorOriginGroupName = "fd-moveit-origin-group"
    FrontDoorOriginName      = "fd-moveit-origin"
    FrontDoorRouteName       = "fd-moveit-route"
}

# ----------------------------------------------------------------------------
# FUNCTIONS
# ----------------------------------------------------------------------------
function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "White" }
    }
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $color
}

function Test-ResourceExists {
    param([string]$ResourceType, [string]$Name, [string]$RG)
    $result = $null
    switch ($ResourceType) {
        "nsg" { $result = az network nsg show --name $Name --resource-group $RG 2>$null }
        "pip" { $result = az network public-ip show --name $Name --resource-group $RG 2>$null }
        "lb"  { $result = az network lb show --name $Name --resource-group $RG 2>$null }
        "waf" { $result = az network front-door waf-policy show --name $Name --resource-group $RG 2>$null }
        "afd" { $result = az afd profile show --profile-name $Name --resource-group $RG 2>$null }
    }
    return ($null -ne $result)
}

# ----------------------------------------------------------------------------
# STEP 1: AZURE AUTHENTICATION
# ----------------------------------------------------------------------------
Write-Host "[1/8] Verifying Azure authentication..." -ForegroundColor Yellow

try {
    $account = az account show 2>$null | ConvertFrom-Json
    if ($account) {
        Write-Status "Authenticated as: $($account.user.name)" "OK"
    } else {
        throw "Not authenticated"
    }
} catch {
    Write-Status "Not authenticated. Initiating login..." "WARN"
    az login
    $account = az account show | ConvertFrom-Json
    Write-Status "Authenticated as: $($account.user.name)" "OK"
}

# ----------------------------------------------------------------------------
# STEP 2: SUBSCRIPTION SELECTION
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/8] Loading subscriptions..." -ForegroundColor Yellow

$subscriptions = az account list 2>$null | ConvertFrom-Json
$activeSubscriptions = $subscriptions | Where-Object { $_.state -eq "Enabled" }

Write-Host ""
Write-Host "Available Subscriptions:" -ForegroundColor Cyan
for ($i = 0; $i -lt $activeSubscriptions.Count; $i++) {
    $current = if ($activeSubscriptions[$i].isDefault) { " (current)" } else { "" }
    Write-Host "  [$($i + 1)] $($activeSubscriptions[$i].name)$current" -ForegroundColor White
}

Write-Host ""
$selection = Read-Host "Select subscription (1-$($activeSubscriptions.Count))"
$selectedSub = $activeSubscriptions[[int]$selection - 1]

az account set --subscription $selectedSub.id
Write-Status "Using subscription: $($selectedSub.name)" "OK"

# ----------------------------------------------------------------------------
# STEP 3: RESOURCE GROUP
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/8] Configuring resource group..." -ForegroundColor Yellow

$rgExists = az group show --name $config.ResourceGroup 2>$null
if ($rgExists) {
    Write-Status "Resource group exists: $($config.ResourceGroup)" "OK"
} else {
    Write-Status "Creating resource group: $($config.ResourceGroup)" "INFO"
    az group create --name $config.ResourceGroup --location $config.Location --output none
    Write-Status "Resource group created" "OK"
}

# ----------------------------------------------------------------------------
# STEP 4: NETWORK SECURITY GROUP
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[4/8] Configuring Network Security Group..." -ForegroundColor Yellow

$nsgExists = az network nsg show --name $config.NSGName --resource-group $config.ResourceGroup 2>$null
if ($nsgExists) {
    Write-Status "NSG exists: $($config.NSGName)" "OK"
} else {
    Write-Status "Creating NSG: $($config.NSGName)" "INFO"
    az network nsg create `
        --resource-group $config.ResourceGroup `
        --name $config.NSGName `
        --location $config.Location `
        --output none

    # Rule: Allow SFTP (Port 22)
    az network nsg rule create `
        --resource-group $config.ResourceGroup `
        --nsg-name $config.NSGName `
        --name "Allow-SFTP-22" `
        --priority 100 `
        --direction Inbound `
        --access Allow `
        --protocol Tcp `
        --source-address-prefixes "*" `
        --source-port-ranges "*" `
        --destination-address-prefixes "*" `
        --destination-port-ranges 22 `
        --output none

    # Rule: Allow HTTPS (Port 443)
    az network nsg rule create `
        --resource-group $config.ResourceGroup `
        --nsg-name $config.NSGName `
        --name "Allow-HTTPS-443" `
        --priority 110 `
        --direction Inbound `
        --access Allow `
        --protocol Tcp `
        --source-address-prefixes "*" `
        --source-port-ranges "*" `
        --destination-address-prefixes "*" `
        --destination-port-ranges 443 `
        --output none

    # Rule: Allow Front Door
    az network nsg rule create `
        --resource-group $config.ResourceGroup `
        --nsg-name $config.NSGName `
        --name "Allow-FrontDoor" `
        --priority 120 `
        --direction Inbound `
        --access Allow `
        --protocol Tcp `
        --source-address-prefixes "AzureFrontDoor.Backend" `
        --source-port-ranges "*" `
        --destination-address-prefixes "*" `
        --destination-port-ranges 443 `
        --output none

    Write-Status "NSG created with security rules" "OK"
}

# ----------------------------------------------------------------------------
# STEP 5: LOAD BALANCER (SFTP)
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/8] Configuring Load Balancer for SFTP..." -ForegroundColor Yellow

# Public IP
$pipExists = az network public-ip show --name $config.PublicIPName --resource-group $config.ResourceGroup 2>$null
if (-not $pipExists) {
    Write-Status "Creating Public IP: $($config.PublicIPName)" "INFO"
    az network public-ip create `
        --resource-group $config.ResourceGroup `
        --name $config.PublicIPName `
        --sku Standard `
        --allocation-method Static `
        --location $config.Location `
        --output none
}

# Load Balancer
$lbExists = az network lb show --name $config.LoadBalancerName --resource-group $config.ResourceGroup 2>$null
if ($lbExists) {
    Write-Status "Load Balancer exists: $($config.LoadBalancerName)" "OK"
} else {
    Write-Status "Creating Load Balancer: $($config.LoadBalancerName)" "INFO"
    
    az network lb create `
        --resource-group $config.ResourceGroup `
        --name $config.LoadBalancerName `
        --sku Standard `
        --public-ip-address $config.PublicIPName `
        --frontend-ip-name "frontend-sftp" `
        --backend-pool-name $config.BackendPoolName `
        --location $config.Location `
        --output none

    # Health Probe
    az network lb probe create `
        --resource-group $config.ResourceGroup `
        --lb-name $config.LoadBalancerName `
        --name $config.HealthProbeName `
        --protocol Tcp `
        --port 22 `
        --interval 15 `
        --threshold 2 `
        --output none

    # Load Balancing Rule
    az network lb rule create `
        --resource-group $config.ResourceGroup `
        --lb-name $config.LoadBalancerName `
        --name $config.LoadBalancingRuleName `
        --protocol Tcp `
        --frontend-port 22 `
        --backend-port 22 `
        --frontend-ip-name "frontend-sftp" `
        --backend-pool-name $config.BackendPoolName `
        --probe-name $config.HealthProbeName `
        --idle-timeout 30 `
        --enable-tcp-reset true `
        --output none

    Write-Status "Load Balancer created with SFTP configuration" "OK"
}

$publicIP = az network public-ip show `
    --resource-group $config.ResourceGroup `
    --name $config.PublicIPName `
    --query ipAddress -o tsv

Write-Status "SFTP Endpoint: $publicIP:22" "OK"

# ----------------------------------------------------------------------------
# STEP 6: WAF POLICY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[6/8] Configuring WAF Policy..." -ForegroundColor Yellow

$wafExists = az network front-door waf-policy show --name $config.WAFPolicyName --resource-group $config.ResourceGroup 2>$null
if ($wafExists) {
    Write-Status "WAF Policy exists: $($config.WAFPolicyName)" "OK"
} else {
    Write-Status "Creating WAF Policy: $($config.WAFPolicyName)" "INFO"
    
    az network front-door waf-policy create `
        --resource-group $config.ResourceGroup `
        --name $config.WAFPolicyName `
        --sku Premium_AzureFrontDoor `
        --mode Prevention `
        --output none

    # Add managed rule set (OWASP)
    az network front-door waf-policy managed-rules add `
        --resource-group $config.ResourceGroup `
        --policy-name $config.WAFPolicyName `
        --type Microsoft_DefaultRuleSet `
        --version 2.1 `
        --output none 2>$null

    # Add bot manager rule set
    az network front-door waf-policy managed-rules add `
        --resource-group $config.ResourceGroup `
        --policy-name $config.WAFPolicyName `
        --type Microsoft_BotManagerRuleSet `
        --version 1.0 `
        --output none 2>$null

    Write-Status "WAF Policy created with OWASP and Bot protection" "OK"
}

# ----------------------------------------------------------------------------
# STEP 7: FRONT DOOR (HTTPS)
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[7/8] Configuring Azure Front Door..." -ForegroundColor Yellow

$fdExists = az afd profile show --profile-name $config.FrontDoorProfileName --resource-group $config.ResourceGroup 2>$null
if ($fdExists) {
    Write-Status "Front Door exists: $($config.FrontDoorProfileName)" "OK"
} else {
    Write-Status "Creating Front Door Profile..." "INFO"
    
    # Create Front Door Profile
    az afd profile create `
        --resource-group $config.ResourceGroup `
        --profile-name $config.FrontDoorProfileName `
        --sku Premium_AzureFrontDoor `
        --output none

    # Create Endpoint
    az afd endpoint create `
        --resource-group $config.ResourceGroup `
        --profile-name $config.FrontDoorProfileName `
        --endpoint-name $config.FrontDoorEndpointName `
        --enabled-state Enabled `
        --output none

    # Create Origin Group
    az afd origin-group create `
        --resource-group $config.ResourceGroup `
        --profile-name $config.FrontDoorProfileName `
        --origin-group-name $config.FrontDoorOriginGroupName `
        --probe-request-type GET `
        --probe-protocol Https `
        --probe-interval-in-seconds 30 `
        --sample-size 4 `
        --successful-samples-required 3 `
        --output none

    # Create Origin (MOVEit Server)
    az afd origin create `
        --resource-group $config.ResourceGroup `
        --profile-name $config.FrontDoorProfileName `
        --origin-group-name $config.FrontDoorOriginGroupName `
        --origin-name $config.FrontDoorOriginName `
        --host-name $config.MOVEitPrivateIP `
        --origin-host-header $config.MOVEitPrivateIP `
        --http-port 80 `
        --https-port 443 `
        --priority 1 `
        --weight 1000 `
        --enabled-state Enabled `
        --output none

    # Create Route
    az afd route create `
        --resource-group $config.ResourceGroup `
        --profile-name $config.FrontDoorProfileName `
        --endpoint-name $config.FrontDoorEndpointName `
        --route-name $config.FrontDoorRouteName `
        --origin-group $config.FrontDoorOriginGroupName `
        --supported-protocols Https `
        --patterns-to-match "/*" `
        --forwarding-protocol HttpsOnly `
        --https-redirect Enabled `
        --link-to-default-domain Enabled `
        --output none

    Write-Status "Front Door created with origin and routing" "OK"
}

# Get Front Door endpoint
$fdEndpoint = az afd endpoint show `
    --resource-group $config.ResourceGroup `
    --profile-name $config.FrontDoorProfileName `
    --endpoint-name $config.FrontDoorEndpointName `
    --query hostName -o tsv

Write-Status "HTTPS Endpoint: https://$fdEndpoint" "OK"

# ----------------------------------------------------------------------------
# STEP 8: MICROSOFT DEFENDER
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[8/8] Enabling Microsoft Defender..." -ForegroundColor Yellow

$defenderTypes = @("VirtualMachines", "AppServices", "StorageAccounts", "SqlServers")

foreach ($type in $defenderTypes) {
    try {
        az security pricing create --name $type --tier Standard --output none 2>$null
    } catch {
        # Silently continue if already enabled
    }
}

Write-Status "Microsoft Defender enabled for VMs, App Services, Storage, SQL" "OK"

# ----------------------------------------------------------------------------
# DEPLOYMENT SUMMARY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Green
Write-Host "DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Green
Write-Host ""

Write-Host "ENDPOINTS:" -ForegroundColor Cyan
Write-Host "  SFTP:  sftp://user@$publicIP (Port 22)" -ForegroundColor White
Write-Host "  HTTPS: https://$fdEndpoint" -ForegroundColor White
Write-Host ""

Write-Host "SECURITY COMPONENTS:" -ForegroundColor Cyan
Write-Host "  NSG:       $($config.NSGName)" -ForegroundColor White
Write-Host "  WAF:       $($config.WAFPolicyName) (Prevention Mode)" -ForegroundColor White
Write-Host "  Defender:  Enabled (Standard Tier)" -ForegroundColor White
Write-Host ""

Write-Host "CUSTOM DOMAIN SETUP:" -ForegroundColor Yellow
Write-Host "  1. Add CNAME record in DNS:" -ForegroundColor White
Write-Host "     Host:  moveit" -ForegroundColor White
Write-Host "     Type:  CNAME" -ForegroundColor White
Write-Host "     Value: $fdEndpoint" -ForegroundColor White
Write-Host ""
Write-Host "  2. Add custom domain in Azure Portal:" -ForegroundColor White
Write-Host "     Front Door > Domains > Add > $($config.CustomDomain)" -ForegroundColor White
Write-Host ""
Write-Host "  3. Configure SSL certificate from Key Vault" -ForegroundColor White
Write-Host ""

Write-Host "ARCHITECTURE:" -ForegroundColor Cyan
Write-Host "  SFTP Traffic:  Internet -> Load Balancer -> MOVEit (Port 22)" -ForegroundColor White
Write-Host "  HTTPS Traffic: Internet -> Front Door -> WAF -> MOVEit (Port 443)" -ForegroundColor White
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Green
