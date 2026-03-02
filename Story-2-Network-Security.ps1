# ================================================================
# STORY 2: NETWORK SECURITY (NSG)
# Component: Security Layer
# Duration: 3 minutes
# ================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  STORY 2: NETWORK SECURITY (NSG)" -ForegroundColor Cyan
Write-Host "  Component-Based Deployment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

# ----------------------------------------------------------------
# LOAD STATE FROM STORY 1
# ----------------------------------------------------------------
$stateFile = "$env:USERPROFILE\Desktop\MOVEit-Deployment-State.json"
if (-not (Test-Path $stateFile)) {
    Write-Log "ERROR: State file not found! Run Story 1 first." "Red"
    exit 1
}

Write-Log "Loading deployment state..." "Yellow"
$state = Get-Content $stateFile | ConvertFrom-Json
Write-Log "State loaded successfully" "Green"
Write-Host ""

# Display current state
Write-Log "Current Configuration:" "Cyan"
Write-Log "  Network RG: $($state.NetworkResourceGroup)" "White"
Write-Log "  VNet: $($state.VNetName)" "White"
Write-Log "  Subnet: $($state.SubnetName)" "White"
Write-Log "  Deployment RG: $($state.DeploymentResourceGroup)" "White"
Write-Host ""

# Set subscription
az account set --subscription $state.SubscriptionId

# ----------------------------------------------------------------
# CREATE NSG
# ----------------------------------------------------------------
Write-Log "============================================" "Cyan"
Write-Log "CREATING NETWORK SECURITY GROUP" "Cyan"
Write-Log "============================================" "Cyan"
Write-Host ""

$nsgName = "nsg-moveit"
Write-Log "Creating NSG: $nsgName..." "Yellow"

$nsgExists = az network nsg show --resource-group $state.NetworkResourceGroup --name $nsgName 2>$null
if (-not $nsgExists) {
    az network nsg create --resource-group $state.NetworkResourceGroup --name $nsgName --location $state.Location --output none
    Write-Log "NSG created" "Green"
} else {
    Write-Log "NSG already exists" "Green"
}

# ----------------------------------------------------------------
# ADD SECURITY RULES
# ----------------------------------------------------------------
Write-Log "Adding security rules..." "Yellow"

# Rule 1: Allow FTPS Command (990)
$rule990 = az network nsg rule show --resource-group $state.NetworkResourceGroup --nsg-name $nsgName --name "Allow-FTPS-990" 2>$null
if (-not $rule990) {
    az network nsg rule create --resource-group $state.NetworkResourceGroup --nsg-name $nsgName --name "Allow-FTPS-990" --priority 100 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes "*" --source-port-ranges "*" --destination-address-prefixes "*" --destination-port-ranges 990 --description "Allow FTPS command channel" --output none
    Write-Log "  Rule: Allow-FTPS-990" "Green"
}

# Rule 2: Allow FTPS Data (989)
$rule989 = az network nsg rule show --resource-group $state.NetworkResourceGroup --nsg-name $nsgName --name "Allow-FTPS-989" 2>$null
if (-not $rule989) {
    az network nsg rule create --resource-group $state.NetworkResourceGroup --nsg-name $nsgName --name "Allow-FTPS-989" --priority 110 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes "*" --source-port-ranges "*" --destination-address-prefixes "*" --destination-port-ranges 989 --description "Allow FTPS data channel" --output none
    Write-Log "  Rule: Allow-FTPS-989" "Green"
}

# Rule 3: Allow HTTPS (443)
$rule443 = az network nsg rule show --resource-group $state.NetworkResourceGroup --nsg-name $nsgName --name "Allow-HTTPS-443" 2>$null
if (-not $rule443) {
    az network nsg rule create --resource-group $state.NetworkResourceGroup --nsg-name $nsgName --name "Allow-HTTPS-443" --priority 120 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes "*" --source-port-ranges "*" --destination-address-prefixes "*" --destination-port-ranges 443 --description "Allow HTTPS from Front Door" --output none
    Write-Log "  Rule: Allow-HTTPS-443" "Green"
}

Write-Log "All security rules configured" "Green"

# ----------------------------------------------------------------
# ATTACH NSG TO SUBNET
# ----------------------------------------------------------------
Write-Host ""
Write-Log "Attaching NSG to subnet..." "Yellow"
az network vnet subnet update --resource-group $state.NetworkResourceGroup --vnet-name $state.VNetName --name $state.SubnetName --network-security-group $nsgName --output none
Write-Log "NSG attached to subnet: $($state.SubnetName)" "Green"

# ----------------------------------------------------------------
# UPDATE STATE
# ----------------------------------------------------------------
$state | Add-Member -MemberType NoteProperty -Name "NSGName" -Value $nsgName -Force
$state | ConvertTo-Json | Out-File -FilePath $stateFile -Encoding UTF8

# ----------------------------------------------------------------
# SUMMARY
# ----------------------------------------------------------------
Write-Host ""
Write-Log "============================================" "Green"
Write-Log "  STORY 2 COMPLETE!" "Green"
Write-Log "============================================" "Green"
Write-Host ""
Write-Log "Network Security Configured:" "Cyan"
Write-Log "  NSG Name: $nsgName" "White"
Write-Log "  Rules Created: 3" "White"
Write-Log "    - Allow-FTPS-990 (priority 100)" "White"
Write-Log "    - Allow-FTPS-989 (priority 110)" "White"
Write-Log "    - Allow-HTTPS-443 (priority 120)" "White"
Write-Log "  Attached to: $($state.VNetName)/$($state.SubnetName)" "White"
Write-Host ""
Write-Log "State updated: $stateFile" "Yellow"
Write-Host ""
Write-Log "NEXT: Run Story-3-Load-Balancer.ps1" "Cyan"
Write-Host ""
