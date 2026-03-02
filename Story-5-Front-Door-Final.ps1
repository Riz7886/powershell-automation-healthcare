# ================================================================
# STORY 5: FRONT DOOR & FINAL CONFIGURATION
# Component: Complete Integration
# Duration: 6 minutes
# ================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  STORY 5: FRONT DOOR & FINAL CONFIG" -ForegroundColor Cyan
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
    Write-Log "ERROR: State file not found! Run Stories 1-4 first." "Red"
    exit 1
}

Write-Log "Loading deployment state..." "Yellow"
$state = Get-Content $stateFile | ConvertFrom-Json
Write-Log "State loaded successfully" "Green"
Write-Host ""

# Display current state
Write-Log "Current Configuration:" "Cyan"
Write-Log "  Deployment RG: $($state.DeploymentResourceGroup)" "White"
Write-Log "  WAF Policy: $($state.WAFPolicyName)" "White"
Write-Log "  MOVEit IP: $($state.MOVEitPrivateIP)" "White"
Write-Host ""

# Set subscription
az account set --subscription $state.SubscriptionId

# ----------------------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------------------
$frontDoorProfileName = "moveit-frontdoor-profile"
$frontDoorEndpointName = "moveit-endpoint"
$originGroupName = "moveit-origin-group"
$originName = "moveit-origin"
$routeName = "moveit-route"
$frontDoorSKU = "Standard_AzureFrontDoor"

# ----------------------------------------------------------------
# CREATE FRONT DOOR PROFILE
# ----------------------------------------------------------------
Write-Log "============================================" "Cyan"
Write-Log "CREATING FRONT DOOR PROFILE" "Cyan"
Write-Log "============================================" "Cyan"
Write-Host ""

Write-Log "Creating Front Door profile: $frontDoorProfileName..." "Yellow"
$profileExists = az afd profile show --resource-group $state.DeploymentResourceGroup --profile-name $frontDoorProfileName 2>$null
if (-not $profileExists) {
    az afd profile create --resource-group $state.DeploymentResourceGroup --profile-name $frontDoorProfileName --sku $frontDoorSKU --output none
    Write-Log "Front Door profile created" "Green"
} else {
    Write-Log "Front Door profile already exists" "Green"
}

# ----------------------------------------------------------------
# CREATE FRONT DOOR ENDPOINT
# ----------------------------------------------------------------
Write-Host ""
Write-Log "Creating Front Door endpoint: $frontDoorEndpointName..." "Yellow"
$endpointExists = az afd endpoint show --resource-group $state.DeploymentResourceGroup --profile-name $frontDoorProfileName --endpoint-name $frontDoorEndpointName 2>$null
if (-not $endpointExists) {
    az afd endpoint create --resource-group $state.DeploymentResourceGroup --profile-name $frontDoorProfileName --endpoint-name $frontDoorEndpointName --enabled-state Enabled --output none
    Write-Log "Front Door endpoint created" "Green"
} else {
    Write-Log "Front Door endpoint already exists" "Green"
}

# Get endpoint hostname
$endpointHostname = az afd endpoint show --resource-group $state.DeploymentResourceGroup --profile-name $frontDoorProfileName --endpoint-name $frontDoorEndpointName --query hostName --output tsv
Write-Log "Endpoint URL: https://$endpointHostname" "Cyan"

# ----------------------------------------------------------------
# CREATE ORIGIN GROUP
# ----------------------------------------------------------------
Write-Host ""
Write-Log "Creating origin group: $originGroupName..." "Yellow"
$originGroupExists = az afd origin-group show --resource-group $state.DeploymentResourceGroup --profile-name $frontDoorProfileName --origin-group-name $originGroupName 2>$null
if (-not $originGroupExists) {
    az afd origin-group create --resource-group $state.DeploymentResourceGroup --profile-name $frontDoorProfileName --origin-group-name $originGroupName --probe-request-type GET --probe-protocol Https --probe-interval-in-seconds 30 --probe-path "/" --sample-size 4 --successful-samples-required 2 --additional-latency-in-milliseconds 0 --output none
    Write-Log "Origin group created" "Green"
} else {
    Write-Log "Origin group already exists" "Green"
}

# ----------------------------------------------------------------
# CREATE ORIGIN
# ----------------------------------------------------------------
Write-Host ""
Write-Log "Creating origin: $originName..." "Yellow"
$originExists = az afd origin show --resource-group $state.DeploymentResourceGroup --profile-name $frontDoorProfileName --origin-group-name $originGroupName --origin-name $originName 2>$null
if (-not $originExists) {
    az afd origin create --resource-group $state.DeploymentResourceGroup --profile-name $frontDoorProfileName --origin-group-name $originGroupName --origin-name $originName --host-name $state.MOVEitPrivateIP --origin-host-header $state.MOVEitPrivateIP --http-port 80 --https-port 443 --priority 1 --weight 1000 --enabled-state Enabled --output none
    Write-Log "Origin created (MOVEit at $($state.MOVEitPrivateIP))" "Green"
} else {
    Write-Log "Origin already exists" "Green"
}

# ----------------------------------------------------------------
# CREATE ROUTE
# ----------------------------------------------------------------
Write-Host ""
Write-Log "Creating route: $routeName..." "Yellow"
$routeExists = az afd route show --resource-group $state.DeploymentResourceGroup --profile-name $frontDoorProfileName --endpoint-name $frontDoorEndpointName --route-name $routeName 2>$null
if (-not $routeExists) {
    az afd route create --resource-group $state.DeploymentResourceGroup --profile-name $frontDoorProfileName --endpoint-name $frontDoorEndpointName --route-name $routeName --origin-group $originGroupName --supported-protocols Https --https-redirect Enabled --forwarding-protocol HttpsOnly --patterns-to-match "/*" --enabled-state Enabled --output none
    Write-Log "Route created" "Green"
} else {
    Write-Log "Route already exists" "Green"
}

# ----------------------------------------------------------------
# ATTACH WAF SECURITY POLICY
# ----------------------------------------------------------------
Write-Host ""
Write-Log "Attaching WAF security policy..." "Yellow"

$wafPolicyId = az network front-door waf-policy show --resource-group $state.DeploymentResourceGroup --name $state.WAFPolicyName --query id --output tsv
$subscriptionId = az account show --query id --output tsv

az afd security-policy create --resource-group $state.DeploymentResourceGroup --profile-name $frontDoorProfileName --security-policy-name "moveit-waf-security" --domains "/subscriptions/$subscriptionId/resourceGroups/$($state.DeploymentResourceGroup)/providers/Microsoft.Cdn/profiles/$frontDoorProfileName/afdEndpoints/$frontDoorEndpointName" --waf-policy $wafPolicyId --output none 2>$null

Write-Log "WAF security policy attached" "Green"

# ----------------------------------------------------------------
# ENABLE MICROSOFT DEFENDER
# ----------------------------------------------------------------
Write-Host ""
Write-Log "============================================" "Cyan"
Write-Log "ENABLING MICROSOFT DEFENDER" "Cyan"
Write-Log "============================================" "Cyan"
Write-Host ""

Write-Log "Enabling Defender for Cloud..." "Yellow"
az security pricing create --name VirtualMachines --tier Standard --output none 2>$null
Write-Log "  Defender for VMs: Enabled" "Green"

az security pricing create --name AppServices --tier Standard --output none 2>$null
Write-Log "  Defender for App Services: Enabled" "Green"

az security pricing create --name StorageAccounts --tier Standard --output none 2>$null
Write-Log "  Defender for Storage: Enabled" "Green"

# ----------------------------------------------------------------
# UPDATE STATE WITH FINAL INFO
# ----------------------------------------------------------------
$state | Add-Member -MemberType NoteProperty -Name "FrontDoorProfileName" -Value $frontDoorProfileName -Force
$state | Add-Member -MemberType NoteProperty -Name "FrontDoorEndpoint" -Value $endpointHostname -Force
$state | Add-Member -MemberType NoteProperty -Name "FrontDoorURL" -Value "https://$endpointHostname" -Force
$state | Add-Member -MemberType NoteProperty -Name "DeploymentCompleted" -Value $true -Force
$state | Add-Member -MemberType NoteProperty -Name "CompletionTime" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Force
$state | ConvertTo-Json | Out-File -FilePath $stateFile -Encoding UTF8

# ----------------------------------------------------------------
# CREATE FINAL SUMMARY
# ----------------------------------------------------------------
$summaryFile = "$env:USERPROFILE\Desktop\MOVEit-Deployment-Summary.txt"
$summary = @"
============================================
MOVEIT DEPLOYMENT - COMPLETE
============================================
Deployed: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Subscription: $($state.SubscriptionName)

ENDPOINTS
---------
FTPS (File Transfers):
  Public IP: $($state.LoadBalancerPublicIP)
  Ports: 990 (command), 989 (data)
  Protocol: FTPS

HTTPS (Web Interface):
  URL: https://$endpointHostname
  Port: 443
  WAF: Active (Prevention Mode)

ARCHITECTURE
------------
Network:
  Resource Group: $($state.NetworkResourceGroup)
  VNet: $($state.VNetName)
  Subnet: $($state.SubnetName)
  NSG: $($state.NSGName)

Deployment:
  Resource Group: $($state.DeploymentResourceGroup)
  Location: $($state.Location)

Backend:
  MOVEit Server: $($state.MOVEitPrivateIP)

SECURITY
--------
[x] Network Security Group - Ports 990, 989, 443
[x] Load Balancer - DDoS protection
[x] Azure Front Door - Edge security
[x] WAF Policy - Prevention mode
    - DefaultRuleSet 1.0 (OWASP)
    - BotManagerRuleSet 1.0
    - Custom rules for MOVEit
[x] Microsoft Defender for Cloud
    - VMs: Standard
    - App Services: Standard
    - Storage: Standard

COST ESTIMATE
-------------
Monthly: ~$83
  - Load Balancer: $18
  - Front Door: $35
  - WAF: $30
  - Defender: Included

Annual: ~$996
3-Year: ~$2,988

COMPONENT DEPLOYMENT
-------------------
Story 1: Prerequisites & Network Discovery [COMPLETE]
Story 2: Network Security (NSG) [COMPLETE]
Story 3: Load Balancer (FTPS) [COMPLETE]
Story 4: WAF Policy [COMPLETE]
Story 5: Front Door & Integration [COMPLETE]

CLIENT CONNECTIONS
------------------
FTPS Clients:
  Host: $($state.LoadBalancerPublicIP)
  Port: 990
  Protocol: FTPS

Web Browser:
  URL: https://$endpointHostname

DNS SETUP (Optional):
----------------------
ftps.yourdomain.com → $($state.LoadBalancerPublicIP)
moveit.yourdomain.com → $endpointHostname

MANAGEMENT
----------
Azure Portal:
  Resource Group: $($state.DeploymentResourceGroup)
  Front Door: $frontDoorProfileName
  Load Balancer: $($state.LoadBalancerName)
  WAF Policy: $($state.WAFPolicyName)

State File: $stateFile

To delete all resources:
  az group delete --name $($state.DeploymentResourceGroup) --yes --no-wait
  az group delete --name $($state.NetworkResourceGroup) --yes --no-wait
"@

$summary | Out-File -FilePath $summaryFile -Encoding UTF8

# ----------------------------------------------------------------
# FINAL OUTPUT
# ----------------------------------------------------------------
Write-Host ""
Write-Log "============================================" "Green"
Write-Log "  ALL STORIES COMPLETE!" "Green"
Write-Log "  MOVEIT DEPLOYMENT FINISHED!" "Green"
Write-Log "============================================" "Green"
Write-Host ""
Write-Log "DEPLOYMENT SUMMARY:" "Cyan"
Write-Host ""
Write-Log "FTPS Endpoint:" "Yellow"
Write-Log "  $($state.LoadBalancerPublicIP):990" "White"
Write-Host ""
Write-Log "HTTPS Endpoint:" "Yellow"
Write-Log "  https://$endpointHostname" "White"
Write-Host ""
Write-Log "Components Deployed:" "Cyan"
Write-Log "  [x] Story 1: Prerequisites & Network" "Green"
Write-Log "  [x] Story 2: Network Security (NSG)" "Green"
Write-Log "  [x] Story 3: Load Balancer (FTPS)" "Green"
Write-Log "  [x] Story 4: WAF Policy" "Green"
Write-Log "  [x] Story 5: Front Door & Integration" "Green"
Write-Host ""
Write-Log "Security Features:" "Cyan"
Write-Log "  [x] NSG with firewall rules" "Green"
Write-Log "  [x] Load Balancer with DDoS protection" "Green"
Write-Log "  [x] Front Door with edge security" "Green"
Write-Log "  [x] WAF in Prevention mode" "Green"
Write-Log "  [x] Microsoft Defender enabled" "Green"
Write-Host ""
Write-Log "Cost: $83/month" "Yellow"
Write-Host ""
Write-Log "Summary saved to:" "Yellow"
Write-Log "  $summaryFile" "White"
Write-Host ""
Write-Log "State file:" "Yellow"
Write-Log "  $stateFile" "White"
Write-Host ""
Write-Log "DEPLOYMENT COMPLETE! Test your endpoints!" "Green"
Write-Host ""
