# ================================================================
# STORY 1: PREREQUISITES & NETWORK DISCOVERY
# Component: Foundation Setup
# Duration: 5 minutes
# ================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  STORY 1: PREREQUISITES & NETWORK" -ForegroundColor Cyan
Write-Host "  Component-Based Deployment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

# ----------------------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------------------
$deploymentState = @{
    MOVEitPrivateIP          = "192.168.0.5"
    Location                 = "westus"
    DeploymentResourceGroup  = "rg-moveit"
}

# ----------------------------------------------------------------
# STEP 1: CHECK AZURE CLI
# ----------------------------------------------------------------
Write-Log "Checking Azure CLI..." "Yellow"
try {
    $azVersion = az version --output json 2>$null | ConvertFrom-Json
    Write-Log "Azure CLI version: $($azVersion.'azure-cli')" "Green"
} catch {
    Write-Log "ERROR: Azure CLI not found! Install from: https://aka.ms/installazurecliwindows" "Red"
    exit 1
}

# ----------------------------------------------------------------
# STEP 2: LOGIN TO AZURE
# ----------------------------------------------------------------
Write-Log "Checking Azure login..." "Yellow"
$loginCheck = az account show 2>$null
if (-not $loginCheck) {
    Write-Log "Not logged in. Starting login..." "Yellow"
    az login --use-device-code
} else {
    Write-Log "Already logged in" "Green"
}

# ----------------------------------------------------------------
# STEP 3: SELECT SUBSCRIPTION
# ----------------------------------------------------------------
Write-Host ""
Write-Log "============================================" "Cyan"
Write-Log "AVAILABLE SUBSCRIPTIONS" "Cyan"
Write-Log "============================================" "Cyan"

$subscriptions = az account list --output json | ConvertFrom-Json

for ($i = 0; $i -lt $subscriptions.Count; $i++) {
    $sub = $subscriptions[$i]
    $stateColor = if ($sub.state -eq "Enabled") { "Green" } else { "Yellow" }
    Write-Host "[$($i + 1)] " -NoNewline -ForegroundColor Cyan
    Write-Host "$($sub.name) " -NoNewline -ForegroundColor White
    Write-Host "($($sub.state))" -ForegroundColor $stateColor
}

Write-Host ""
$selection = Read-Host "Select subscription number"
$selectedSubscription = $subscriptions[[int]$selection - 1]
az account set --subscription $selectedSubscription.id
Write-Log "Active subscription: $($selectedSubscription.name)" "Green"

$deploymentState.SubscriptionId = $selectedSubscription.id
$deploymentState.SubscriptionName = $selectedSubscription.name

# ----------------------------------------------------------------
# STEP 4: AUTO-DETECT NETWORK RESOURCES
# ----------------------------------------------------------------
Write-Host ""
Write-Log "============================================" "Cyan"
Write-Log "AUTO-DETECTING NETWORK RESOURCES" "Cyan"
Write-Log "============================================" "Cyan"
Write-Host ""

# Find resource group with "network" in name
Write-Log "Searching for network resource group..." "Yellow"
$allRGs = az group list --output json | ConvertFrom-Json
$networkRG = $null

foreach ($rg in $allRGs) {
    if ($rg.name -like "*network*") {
        $networkRG = $rg.name
        Write-Log "FOUND: $networkRG" "Green"
        break
    }
}

if (-not $networkRG) {
    Write-Log "ERROR: No resource group with 'network' in name found!" "Red"
    Write-Log "Available resource groups:" "Yellow"
    foreach ($rg in $allRGs) {
        Write-Log "  - $($rg.name)" "White"
    }
    exit 1
}

$deploymentState.NetworkResourceGroup = $networkRG

# Find VNet
Write-Log "Searching for VNets in $networkRG..." "Yellow"
$allVNets = az network vnet list --resource-group $networkRG --output json 2>$null | ConvertFrom-Json

if (-not $allVNets -or $allVNets.Count -eq 0) {
    Write-Log "ERROR: No VNets found in $networkRG!" "Red"
    exit 1
}

Write-Log "FOUND VNets:" "Green"
foreach ($vnet in $allVNets) {
    Write-Log "  - $($vnet.name)" "Cyan"
}

# Select VNet with "prod" in name, or first one
$selectedVNet = $null
foreach ($vnet in $allVNets) {
    if ($vnet.name -like "*prod*") {
        $selectedVNet = $vnet.name
        break
    }
}
if (-not $selectedVNet) {
    $selectedVNet = $allVNets[0].name
}

$deploymentState.VNetName = $selectedVNet
Write-Log "Selected VNet: $selectedVNet" "Green"

# Find Subnet
Write-Log "Searching for subnets in $selectedVNet..." "Yellow"
$allSubnets = az network vnet subnet list --resource-group $networkRG --vnet-name $selectedVNet --output json 2>$null | ConvertFrom-Json

if (-not $allSubnets -or $allSubnets.Count -eq 0) {
    Write-Log "ERROR: No subnets found!" "Red"
    exit 1
}

Write-Log "FOUND Subnets:" "Green"
foreach ($subnet in $allSubnets) {
    Write-Log "  - $($subnet.name) ($($subnet.addressPrefix))" "Cyan"
}

# Select subnet with "moveit" in name, or first one
$selectedSubnet = $null
foreach ($subnet in $allSubnets) {
    if ($subnet.name -like "*moveit*") {
        $selectedSubnet = $subnet.name
        break
    }
}
if (-not $selectedSubnet) {
    $selectedSubnet = $allSubnets[0].name
}

$deploymentState.SubnetName = $selectedSubnet
Write-Log "Selected Subnet: $selectedSubnet" "Green"

# ----------------------------------------------------------------
# STEP 5: CREATE DEPLOYMENT RESOURCE GROUP
# ----------------------------------------------------------------
Write-Host ""
Write-Log "Creating deployment resource group..." "Yellow"
$rgExists = az group show --name $deploymentState.DeploymentResourceGroup 2>$null
if (-not $rgExists) {
    az group create --name $deploymentState.DeploymentResourceGroup --location $deploymentState.Location --output none
    Write-Log "Created: $($deploymentState.DeploymentResourceGroup)" "Green"
} else {
    Write-Log "Already exists: $($deploymentState.DeploymentResourceGroup)" "Green"
}

# ----------------------------------------------------------------
# STEP 6: SAVE STATE FOR NEXT STORY
# ----------------------------------------------------------------
$stateFile = "$env:USERPROFILE\Desktop\MOVEit-Deployment-State.json"
$deploymentState | ConvertTo-Json | Out-File -FilePath $stateFile -Encoding UTF8

Write-Host ""
Write-Log "============================================" "Green"
Write-Log "  STORY 1 COMPLETE!" "Green"
Write-Log "============================================" "Green"
Write-Host ""
Write-Log "Discovered Resources:" "Cyan"
Write-Log "  Subscription: $($deploymentState.SubscriptionName)" "White"
Write-Log "  Network RG: $($deploymentState.NetworkResourceGroup)" "White"
Write-Log "  VNet: $($deploymentState.VNetName)" "White"
Write-Log "  Subnet: $($deploymentState.SubnetName)" "White"
Write-Log "  Deployment RG: $($deploymentState.DeploymentResourceGroup)" "White"
Write-Log "  MOVEit IP: $($deploymentState.MOVEitPrivateIP)" "White"
Write-Host ""
Write-Log "State saved to: $stateFile" "Yellow"
Write-Host ""
Write-Log "NEXT: Run Story-2-Network-Security.ps1" "Cyan"
Write-Host ""
