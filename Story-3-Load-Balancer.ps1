# ================================================================
# STORY 3: LOAD BALANCER (FTPS)
# Component: Public FTPS Access
# Duration: 5 minutes
# ================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  STORY 3: LOAD BALANCER (FTPS)" -ForegroundColor Cyan
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
    Write-Log "ERROR: State file not found! Run Story 1 and 2 first." "Red"
    exit 1
}

Write-Log "Loading deployment state..." "Yellow"
$state = Get-Content $stateFile | ConvertFrom-Json
Write-Log "State loaded successfully" "Green"
Write-Host ""

# Display current state
Write-Log "Current Configuration:" "Cyan"
Write-Log "  Deployment RG: $($state.DeploymentResourceGroup)" "White"
Write-Log "  Network RG: $($state.NetworkResourceGroup)" "White"
Write-Log "  VNet: $($state.VNetName)" "White"
Write-Log "  MOVEit IP: $($state.MOVEitPrivateIP)" "White"
Write-Host ""

# Set subscription
az account set --subscription $state.SubscriptionId

# ----------------------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------------------
$lbName = "lb-moveit-ftps"
$publicIPName = "pip-moveit-ftps"
$backendPoolName = "backend-pool-lb"
$healthProbeName = "health-probe-ftps"

# ----------------------------------------------------------------
# CREATE PUBLIC IP
# ----------------------------------------------------------------
Write-Log "============================================" "Cyan"
Write-Log "CREATING PUBLIC IP FOR LOAD BALANCER" "Cyan"
Write-Log "============================================" "Cyan"
Write-Host ""

Write-Log "Creating public IP: $publicIPName..." "Yellow"
$publicIPExists = az network public-ip show --resource-group $state.DeploymentResourceGroup --name $publicIPName 2>$null
if (-not $publicIPExists) {
    az network public-ip create --resource-group $state.DeploymentResourceGroup --name $publicIPName --sku Standard --allocation-method Static --location $state.Location --output none
    Write-Log "Public IP created" "Green"
} else {
    Write-Log "Public IP already exists" "Green"
}

# Get the IP address
$publicIP = az network public-ip show --resource-group $state.DeploymentResourceGroup --name $publicIPName --query ipAddress --output tsv
Write-Log "Public IP Address: $publicIP" "Cyan"

# ----------------------------------------------------------------
# CREATE LOAD BALANCER
# ----------------------------------------------------------------
Write-Host ""
Write-Log "============================================" "Cyan"
Write-Log "CREATING LOAD BALANCER" "Cyan"
Write-Log "============================================" "Cyan"
Write-Host ""

Write-Log "Creating load balancer: $lbName..." "Yellow"
$lbExists = az network lb show --resource-group $state.DeploymentResourceGroup --name $lbName 2>$null
if (-not $lbExists) {
    az network lb create --resource-group $state.DeploymentResourceGroup --name $lbName --sku Standard --public-ip-address $publicIPName --frontend-ip-name "LoadBalancerFrontEnd" --backend-pool-name $backendPoolName --location $state.Location --output none
    Write-Log "Load balancer created" "Green"
} else {
    Write-Log "Load balancer already exists" "Green"
}

# ----------------------------------------------------------------
# ADD BACKEND ADDRESS
# ----------------------------------------------------------------
Write-Host ""
Write-Log "Configuring backend pool..." "Yellow"

# Get VNet ID
$vnetId = az network vnet show --resource-group $state.NetworkResourceGroup --name $state.VNetName --query id --output tsv

# Check if backend address exists
$backendAddressExists = az network lb address-pool address list --resource-group $state.DeploymentResourceGroup --lb-name $lbName --pool-name $backendPoolName --query "[?name=='moveit-backend']" --output json 2>$null | ConvertFrom-Json

if (-not $backendAddressExists) {
    az network lb address-pool address add --resource-group $state.DeploymentResourceGroup --lb-name $lbName --pool-name $backendPoolName --name "moveit-backend" --vnet $vnetId --ip-address $state.MOVEitPrivateIP --output none
    Write-Log "Backend address added: $($state.MOVEitPrivateIP)" "Green"
} else {
    Write-Log "Backend address already exists" "Green"
}

# ----------------------------------------------------------------
# CREATE HEALTH PROBE
# ----------------------------------------------------------------
Write-Host ""
Write-Log "Creating health probe..." "Yellow"
$probeExists = az network lb probe show --resource-group $state.DeploymentResourceGroup --lb-name $lbName --name $healthProbeName 2>$null
if (-not $probeExists) {
    az network lb probe create --resource-group $state.DeploymentResourceGroup --lb-name $lbName --name $healthProbeName --protocol tcp --port 990 --interval 15 --threshold 2 --output none
    Write-Log "Health probe created (TCP port 990)" "Green"
} else {
    Write-Log "Health probe already exists" "Green"
}

# ----------------------------------------------------------------
# CREATE LOAD BALANCING RULES
# ----------------------------------------------------------------
Write-Host ""
Write-Log "Creating load balancing rules..." "Yellow"

# Rule for port 990 (FTPS command)
$rule990 = az network lb rule show --resource-group $state.DeploymentResourceGroup --lb-name $lbName --name "lb-rule-990" 2>$null
if (-not $rule990) {
    az network lb rule create --resource-group $state.DeploymentResourceGroup --lb-name $lbName --name "lb-rule-990" --protocol Tcp --frontend-port 990 --backend-port 990 --frontend-ip-name "LoadBalancerFrontEnd" --backend-pool-name $backendPoolName --probe-name $healthProbeName --idle-timeout 15 --enable-tcp-reset true --output none
    Write-Log "  Rule: lb-rule-990 (FTPS command)" "Green"
} else {
    Write-Log "  Rule lb-rule-990 already exists" "Green"
}

# Rule for port 989 (FTPS data)
$rule989 = az network lb rule show --resource-group $state.DeploymentResourceGroup --lb-name $lbName --name "lb-rule-989" 2>$null
if (-not $rule989) {
    az network lb rule create --resource-group $state.DeploymentResourceGroup --lb-name $lbName --name "lb-rule-989" --protocol Tcp --frontend-port 989 --backend-port 989 --frontend-ip-name "LoadBalancerFrontEnd" --backend-pool-name $backendPoolName --probe-name $healthProbeName --idle-timeout 15 --enable-tcp-reset true --output none
    Write-Log "  Rule: lb-rule-989 (FTPS data)" "Green"
} else {
    Write-Log "  Rule lb-rule-989 already exists" "Green"
}

# ----------------------------------------------------------------
# UPDATE STATE
# ----------------------------------------------------------------
$state | Add-Member -MemberType NoteProperty -Name "LoadBalancerName" -Value $lbName -Force
$state | Add-Member -MemberType NoteProperty -Name "LoadBalancerPublicIP" -Value $publicIP -Force
$state | Add-Member -MemberType NoteProperty -Name "LoadBalancerPublicIPName" -Value $publicIPName -Force
$state | ConvertTo-Json | Out-File -FilePath $stateFile -Encoding UTF8

# ----------------------------------------------------------------
# SUMMARY
# ----------------------------------------------------------------
Write-Host ""
Write-Log "============================================" "Green"
Write-Log "  STORY 3 COMPLETE!" "Green"
Write-Log "============================================" "Green"
Write-Host ""
Write-Log "Load Balancer Configuration:" "Cyan"
Write-Log "  Name: $lbName" "White"
Write-Log "  Public IP: $publicIP" "White"
Write-Log "  Backend: $($state.MOVEitPrivateIP)" "White"
Write-Log "  Health Probe: TCP port 990" "White"
Write-Log "  Rules:" "White"
Write-Log "    - Port 990 (FTPS command)" "White"
Write-Log "    - Port 989 (FTPS data)" "White"
Write-Host ""
Write-Log "FTPS Endpoint: $publicIP:990" "Yellow"
Write-Host ""
Write-Log "State updated: $stateFile" "Yellow"
Write-Host ""
Write-Log "NEXT: Run Story-4-WAF-Policy.ps1" "Cyan"
Write-Host ""
