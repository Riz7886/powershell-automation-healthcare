###############################################################################
# Azure Infrastructure Deployment Script (PowerShell)
# Author: Syed Rizvi
# Description: Automates full Azure infrastructure provisioning including
#              subscriptions, resource groups, ACR, Key Vault, Container Apps,
#              Azure Policies, RBAC, and managed identities.
#
# Prerequisites:
#   - Azure CLI installed (az)
#   - Authenticated (az login)
#   - Sufficient permissions (Owner or Contributor + User Access Admin)
#   - PowerShell 5.1+ or PowerShell 7+
#
# Usage:
#   .\Deploy-AzureInfrastructure.ps1 -DryRun
#   .\Deploy-AzureInfrastructure.ps1 -TargetEnv dev
#   .\Deploy-AzureInfrastructure.ps1 -TargetEnv all
###############################################################################

[CmdletBinding()]
param(
    [switch]$DryRun,

    [ValidateSet("dev", "staging", "prod", "all")]
    [string]$TargetEnv = "all"
)

$ErrorActionPreference = "Stop"

# =============================================================================
# CONFIGURATION — UPDATE THESE VALUES FOR YOUR ENVIRONMENT
# =============================================================================
$Config = @{
    AppName       = "aics"
    Location      = "westus2"
    LocationDR    = "eastus2"

    # Subscription IDs — replace with your actual subscription IDs
    SubSandboxId  = "<your-sandbox-subscription-id>"
    SubNonprodId  = "<your-nonprod-subscription-id>"
    SubProdId     = "<your-prod-subscription-id>"

    # Tagging
    CostCenter    = "Engineering"
    Owner         = "Syed Rizvi"
    Application   = "AICS"

    # Container Apps
    ContainerAppName = "aics-api-app"
    ContainerEnvName = "aics-env"
    ContainerImage   = "aics-api"
    ContainerCpu     = "0.5"
    ContainerMemory  = "1.0Gi"

    # ACR
    AcrSku           = "Standard"
    AcrNonprodName   = "acraicsnonprod"
    AcrProdName      = "acraicsprod"

    # Key Vault
    KvSku            = "standard"

    # Log Analytics
    LogRetentionDays = 90
}

# =============================================================================
# GLOBALS
# =============================================================================
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile   = "deploy-$Timestamp.log"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$ts [$Level] $Message"
    Add-Content -Path $LogFile -Value $logEntry

    switch ($Level) {
        "INFO"    { Write-Host $logEntry -ForegroundColor Cyan }
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
        "WARN"    { Write-Host $logEntry -ForegroundColor Yellow }
        "ERROR"   { Write-Host $logEntry -ForegroundColor Red }
        "SECTION" { 
            Write-Host ""
            Write-Host ("=" * 60) -ForegroundColor Magenta
            Write-Host " $Message" -ForegroundColor Magenta
            Write-Host ("=" * 60) -ForegroundColor Magenta
            Write-Host ""
        }
    }
}

function Invoke-AzCommand {
    param(
        [string]$Description,
        [string]$Command
    )

    if ($DryRun) {
        Write-Log "WARN" "[DRY-RUN] Would execute: $Command"
        return $null
    }

    Write-Log "INFO" $Description
    try {
        $result = Invoke-Expression $Command 2>&1
        $output = $result | Out-String
        Add-Content -Path $LogFile -Value $output

        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Write-Log "ERROR" "$Description — FAILED (exit code: $LASTEXITCODE)"
            return $null
        }

        Write-Log "SUCCESS" "$Description — Done"
        return $result
    }
    catch {
        Write-Log "ERROR" "$Description — FAILED: $_"
        return $null
    }
}

function Test-AzResourceExists {
    param(
        [string]$Type,
        [string]$Name,
        [string]$ResourceGroup = ""
    )

    try {
        switch ($Type) {
            "group"    { az group show --name $Name 2>$null | Out-Null; return $? }
            "keyvault" { az keyvault show --name $Name 2>$null | Out-Null; return $? }
            "acr"      { az acr show --name $Name 2>$null | Out-Null; return $? }
            default    { return $false }
        }
    }
    catch {
        return $false
    }
}

function ShouldProcess-Env {
    param([string]$Env)
    return ($TargetEnv -eq "all" -or $TargetEnv -eq $Env)
}

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================

function Invoke-PreflightChecks {
    Write-Log "SECTION" "Preflight Checks"

    # Check Azure CLI
    $azVersion = az version --query '"azure-cli"' -o tsv 2>$null
    if (-not $azVersion) {
        Write-Log "ERROR" "Azure CLI not found. Install from https://aka.ms/installazurecli"
        exit 1
    }
    Write-Log "SUCCESS" "Azure CLI found: $azVersion"

    # Check logged in
    $currentUser = az account show --query user.name -o tsv 2>$null
    if (-not $currentUser) {
        Write-Log "ERROR" "Not logged in. Run 'az login' first."
        exit 1
    }
    Write-Log "SUCCESS" "Logged in as: $currentUser"

    # Install containerapp extension
    $extCheck = az extension show --name containerapp 2>$null
    if (-not $extCheck) {
        Write-Log "INFO" "Installing containerapp extension..."
        az extension add --name containerapp --yes
    }
    Write-Log "SUCCESS" "Extension ready: containerapp"

    # Register providers
    $providers = @(
        "Microsoft.App",
        "Microsoft.ContainerRegistry",
        "Microsoft.KeyVault",
        "Microsoft.OperationalInsights",
        "Microsoft.PolicyInsights"
    )
    foreach ($provider in $providers) {
        Invoke-AzCommand "Registering provider: $provider" `
            "az provider register --namespace $provider --wait"
    }
}

# =============================================================================
# 1. RESOURCE GROUPS
# =============================================================================

function New-ResourceGroups {
    Write-Log "SECTION" "1. Creating Resource Groups"

    $resourceGroups = @(
        @{ Name = "rg-$($Config.AppName)-dev";      Env = "dev";     SubId = $Config.SubNonprodId }
        @{ Name = "rg-$($Config.AppName)-staging";   Env = "staging"; SubId = $Config.SubNonprodId }
        @{ Name = "rg-shared-nonprod";               Env = "nonprod"; SubId = $Config.SubNonprodId }
        @{ Name = "rg-$($Config.AppName)-prod";      Env = "prod";    SubId = $Config.SubProdId }
        @{ Name = "rg-shared-prod";                  Env = "prod";    SubId = $Config.SubProdId }
    )

    foreach ($rg in $resourceGroups) {
        if ($TargetEnv -ne "all" -and $rg.Env -ne $TargetEnv -and $rg.Env -ne "nonprod") {
            continue
        }

        if (Test-AzResourceExists -Type "group" -Name $rg.Name) {
            Write-Log "WARN" "Resource group '$($rg.Name)' already exists — skipping"
            continue
        }

        Invoke-AzCommand "Creating resource group: $($rg.Name)" `
            "az group create --subscription '$($rg.SubId)' --name '$($rg.Name)' --location '$($Config.Location)' --tags Environment=$($rg.Env) CostCenter='$($Config.CostCenter)' Owner='$($Config.Owner)' Application=$($Config.Application)"
    }
}

# =============================================================================
# 2. LOG ANALYTICS WORKSPACES
# =============================================================================

function New-LogAnalyticsWorkspaces {
    Write-Log "SECTION" "2. Creating Log Analytics Workspaces"

    $workspaces = @(
        @{ Name = "la-$($Config.AppName)-nonprod"; RG = "rg-shared-nonprod"; SubId = $Config.SubNonprodId }
        @{ Name = "la-$($Config.AppName)-prod";    RG = "rg-shared-prod";    SubId = $Config.SubProdId }
    )

    foreach ($la in $workspaces) {
        Invoke-AzCommand "Creating Log Analytics workspace: $($la.Name)" `
            "az monitor log-analytics workspace create --subscription '$($la.SubId)' --resource-group '$($la.RG)' --workspace-name '$($la.Name)' --location '$($Config.Location)' --retention-time $($Config.LogRetentionDays) --sku PerGB2018"
    }
}

# =============================================================================
# 3. AZURE CONTAINER REGISTRIES
# =============================================================================

function New-ContainerRegistries {
    Write-Log "SECTION" "3. Creating Azure Container Registries"

    # Nonprod ACR
    if (Test-AzResourceExists -Type "acr" -Name $Config.AcrNonprodName) {
        Write-Log "WARN" "ACR '$($Config.AcrNonprodName)' already exists — skipping"
    }
    else {
        Invoke-AzCommand "Creating nonprod ACR: $($Config.AcrNonprodName)" `
            "az acr create --subscription '$($Config.SubNonprodId)' --resource-group 'rg-shared-nonprod' --name '$($Config.AcrNonprodName)' --sku '$($Config.AcrSku)' --location '$($Config.Location)' --admin-enabled false --tags Environment=nonprod CostCenter='$($Config.CostCenter)' Owner='$($Config.Owner)' Application=$($Config.Application)"
    }

    # Prod ACR
    if (Test-AzResourceExists -Type "acr" -Name $Config.AcrProdName) {
        Write-Log "WARN" "ACR '$($Config.AcrProdName)' already exists — skipping"
    }
    else {
        Invoke-AzCommand "Creating prod ACR: $($Config.AcrProdName)" `
            "az acr create --subscription '$($Config.SubProdId)' --resource-group 'rg-shared-prod' --name '$($Config.AcrProdName)' --sku '$($Config.AcrSku)' --location '$($Config.Location)' --admin-enabled false --tags Environment=prod CostCenter='$($Config.CostCenter)' Owner='$($Config.Owner)' Application=$($Config.Application)"
    }
}

# =============================================================================
# 4. KEY VAULTS
# =============================================================================

function New-KeyVaults {
    Write-Log "SECTION" "4. Creating Key Vaults"

    $keyVaults = @(
        @{ Name = "kv-$($Config.AppName)-dev";     RG = "rg-$($Config.AppName)-dev";     SubId = $Config.SubNonprodId; Env = "dev" }
        @{ Name = "kv-$($Config.AppName)-staging";  RG = "rg-$($Config.AppName)-staging";  SubId = $Config.SubNonprodId; Env = "staging" }
        @{ Name = "kv-$($Config.AppName)-prod";     RG = "rg-$($Config.AppName)-prod";     SubId = $Config.SubProdId;    Env = "prod" }
    )

    foreach ($kv in $keyVaults) {
        if (-not (ShouldProcess-Env $kv.Env)) { continue }

        if (Test-AzResourceExists -Type "keyvault" -Name $kv.Name) {
            Write-Log "WARN" "Key Vault '$($kv.Name)' already exists — skipping"
            continue
        }

        Invoke-AzCommand "Creating Key Vault: $($kv.Name)" `
            "az keyvault create --subscription '$($kv.SubId)' --resource-group '$($kv.RG)' --name '$($kv.Name)' --location '$($Config.Location)' --sku '$($Config.KvSku)' --enable-rbac-authorization true --enable-soft-delete true --retention-days 90 --enable-purge-protection true --tags Environment=$($kv.Env) CostCenter='$($Config.CostCenter)' Owner='$($Config.Owner)' Application=$($Config.Application)"
    }
}

# =============================================================================
# 5. CONTAINER APP ENVIRONMENTS
# =============================================================================

function New-ContainerAppEnvironments {
    Write-Log "SECTION" "5. Creating Container App Environments"

    $environments = @(
        @{ Env = "dev";     RG = "rg-$($Config.AppName)-dev";     SubId = $Config.SubNonprodId; LaName = "la-$($Config.AppName)-nonprod"; LaRG = "rg-shared-nonprod" }
        @{ Env = "staging"; RG = "rg-$($Config.AppName)-staging";  SubId = $Config.SubNonprodId; LaName = "la-$($Config.AppName)-nonprod"; LaRG = "rg-shared-nonprod" }
        @{ Env = "prod";    RG = "rg-$($Config.AppName)-prod";     SubId = $Config.SubProdId;    LaName = "la-$($Config.AppName)-prod";    LaRG = "rg-shared-prod" }
    )

    foreach ($e in $environments) {
        if (-not (ShouldProcess-Env $e.Env)) { continue }

        $caeName = "$($Config.ContainerEnvName)-$($e.Env)"

        $laId  = ""
        $laKey = ""
        if (-not $DryRun) {
            $laId  = az monitor log-analytics workspace show --subscription $e.SubId --resource-group $e.LaRG --workspace-name $e.LaName --query customerId -o tsv 2>$null
            $laKey = az monitor log-analytics workspace get-shared-keys --subscription $e.SubId --resource-group $e.LaRG --workspace-name $e.LaName --query primarySharedKey -o tsv 2>$null
        }

        Invoke-AzCommand "Creating Container App Environment: $caeName" `
            "az containerapp env create --subscription '$($e.SubId)' --resource-group '$($e.RG)' --name '$caeName' --location '$($Config.Location)' --logs-workspace-id '$laId' --logs-workspace-key '$laKey' --tags Environment=$($e.Env) CostCenter='$($Config.CostCenter)' Owner='$($Config.Owner)' Application=$($Config.Application)"
    }
}

# =============================================================================
# 6. CONTAINER APPS WITH MANAGED IDENTITY
# =============================================================================

function New-ContainerApps {
    Write-Log "SECTION" "6. Creating Container Apps with Managed Identity"

    $apps = @(
        @{ Env = "dev";     RG = "rg-$($Config.AppName)-dev";     SubId = $Config.SubNonprodId; AcrName = $Config.AcrNonprodName }
        @{ Env = "staging"; RG = "rg-$($Config.AppName)-staging";  SubId = $Config.SubNonprodId; AcrName = $Config.AcrNonprodName }
        @{ Env = "prod";    RG = "rg-$($Config.AppName)-prod";     SubId = $Config.SubProdId;    AcrName = $Config.AcrProdName }
    )

    foreach ($app in $apps) {
        if (-not (ShouldProcess-Env $app.Env)) { continue }

        $caName  = "$($Config.ContainerAppName)-$($app.Env)"
        $caeName = "$($Config.ContainerEnvName)-$($app.Env)"

        Invoke-AzCommand "Creating Container App: $caName" `
            "az containerapp create --subscription '$($app.SubId)' --resource-group '$($app.RG)' --name '$caName' --environment '$caeName' --image 'mcr.microsoft.com/k8se/quickstart:latest' --target-port 80 --ingress external --cpu '$($Config.ContainerCpu)' --memory '$($Config.ContainerMemory)' --min-replicas 1 --max-replicas 3 --system-assigned --tags Environment=$($app.Env) CostCenter='$($Config.CostCenter)' Owner='$($Config.Owner)' Application=$($Config.Application)"

        Write-Log "SUCCESS" "Container App $caName created with system-assigned managed identity"
    }
}

# =============================================================================
# 7. RBAC ASSIGNMENTS
# =============================================================================

function Set-RbacAssignments {
    Write-Log "SECTION" "7. Configuring RBAC Assignments"

    $apps = @(
        @{ Env = "dev";     RG = "rg-$($Config.AppName)-dev";     SubId = $Config.SubNonprodId; AcrName = $Config.AcrNonprodName; KvName = "kv-$($Config.AppName)-dev" }
        @{ Env = "staging"; RG = "rg-$($Config.AppName)-staging";  SubId = $Config.SubNonprodId; AcrName = $Config.AcrNonprodName; KvName = "kv-$($Config.AppName)-staging" }
        @{ Env = "prod";    RG = "rg-$($Config.AppName)-prod";     SubId = $Config.SubProdId;    AcrName = $Config.AcrProdName;    KvName = "kv-$($Config.AppName)-prod" }
    )

    foreach ($app in $apps) {
        if (-not (ShouldProcess-Env $app.Env)) { continue }

        $caName = "$($Config.ContainerAppName)-$($app.Env)"

        if ($DryRun) {
            Write-Log "WARN" "[DRY-RUN] Would assign RBAC for $caName"
            continue
        }

        # Get managed identity principal ID
        $principalId = az containerapp show --subscription $app.SubId --resource-group $app.RG --name $caName --query identity.principalId -o tsv 2>$null

        if (-not $principalId) {
            Write-Log "WARN" "Could not retrieve principal ID for $caName — skipping RBAC"
            continue
        }

        Write-Log "INFO" "Principal ID for ${caName}: $principalId"

        # Grant AcrPull on Container Registry
        $acrId = az acr show --name $app.AcrName --query id -o tsv 2>$null
        if ($acrId) {
            Invoke-AzCommand "Granting AcrPull to $caName on $($app.AcrName)" `
                "az role assignment create --assignee '$principalId' --role 'AcrPull' --scope '$acrId'"
        }

        # Grant Key Vault Secrets User
        $kvId = az keyvault show --name $app.KvName --query id -o tsv 2>$null
        if ($kvId) {
            Invoke-AzCommand "Granting Key Vault Secrets User to $caName on $($app.KvName)" `
                "az role assignment create --assignee '$principalId' --role 'Key Vault Secrets User' --scope '$kvId'"
        }
    }
}

# =============================================================================
# 8. AZURE POLICIES
# =============================================================================

function Set-AzurePolicies {
    Write-Log "SECTION" "8. Applying Azure Policies"

    # --- Subscription-level policies ---
    $subscriptions = @($Config.SubNonprodId, $Config.SubProdId)

    foreach ($subId in $subscriptions) {
        $subScope = "/subscriptions/$subId"

        # Require HTTPS on storage accounts
        Invoke-AzCommand "Assigning 'Require HTTPS on Storage' to subscription $subId" `
            "az policy assignment create --name 'require-https-storage' --display-name 'Require HTTPS for Storage Accounts' --policy '/providers/Microsoft.Authorization/policyDefinitions/404c3081-a854-4457-ae30-26a93ef643f9' --scope '$subScope' --enforcement-mode Default"

        # Require tags
        $requiredTags = @("Environment", "CostCenter", "Owner", "Application")
        foreach ($tag in $requiredTags) {
            $tagLower = $tag.ToLower()
            Invoke-AzCommand "Assigning 'Require tag: $tag' to subscription $subId" `
                "az policy assignment create --name 'require-tag-$tagLower' --display-name 'Require tag: $tag on Resource Groups' --policy '/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025' --scope '$subScope' --params '{""tagName"": {""value"": ""$tag""}}' --enforcement-mode Default"
        }
    }

    # --- Prod-specific policies ---
    Write-Log "INFO" "Applying production-specific policies..."

    $prodRGs = @("rg-$($Config.AppName)-prod", "rg-shared-prod")
    foreach ($rg in $prodRGs) {
        $rgScope = "/subscriptions/$($Config.SubProdId)/resourceGroups/$rg"

        Invoke-AzCommand "Assigning 'Deny Public IPs' to $rg" `
            "az policy assignment create --name 'deny-public-ip-$rg' --display-name 'Deny Public IP Addresses in $rg' --policy '/providers/Microsoft.Authorization/policyDefinitions/6c112d4e-5bc7-47ae-a041-ea2d9dccd749' --scope '$rgScope' --enforcement-mode Default"
    }

    # Allowed locations
    Invoke-AzCommand "Assigning 'Allowed Locations' to prod subscription" `
        "az policy assignment create --name 'allowed-locations-prod' --display-name 'Allowed Locations - Production' --policy '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c' --scope '/subscriptions/$($Config.SubProdId)' --params '{""listOfAllowedLocations"": {""value"": [""$($Config.Location)"", ""$($Config.LocationDR)""]}}' --enforcement-mode Default"
}

# =============================================================================
# 9. CONFIGURE KEY VAULT REFERENCES FOR CONTAINER APPS
# =============================================================================

function Set-KeyVaultReferences {
    Write-Log "SECTION" "9. Configuring Key Vault References for Container Apps"

    $envKvMap = @(
        @{ Env = "dev";     KvName = "kv-$($Config.AppName)-dev";     RG = "rg-$($Config.AppName)-dev";     SubId = $Config.SubNonprodId }
        @{ Env = "staging"; KvName = "kv-$($Config.AppName)-staging";  RG = "rg-$($Config.AppName)-staging";  SubId = $Config.SubNonprodId }
        @{ Env = "prod";    KvName = "kv-$($Config.AppName)-prod";     RG = "rg-$($Config.AppName)-prod";     SubId = $Config.SubProdId }
    )

    foreach ($item in $envKvMap) {
        if (-not (ShouldProcess-Env $item.Env)) { continue }

        $caName = "$($Config.ContainerAppName)-$($item.Env)"
        $envUpper = $item.Env.ToUpper()

        # Add placeholder secrets
        Invoke-AzCommand "Adding secret 'db-connection-string' to $($item.KvName)" `
            "az keyvault secret set --subscription '$($item.SubId)' --vault-name '$($item.KvName)' --name 'db-connection-string' --value 'REPLACE-WITH-ACTUAL-$envUpper-CONNECTION-STRING'"

        Invoke-AzCommand "Adding secret 'api-key' to $($item.KvName)" `
            "az keyvault secret set --subscription '$($item.SubId)' --vault-name '$($item.KvName)' --name 'api-key' --value 'REPLACE-WITH-ACTUAL-$envUpper-API-KEY'"

        # Link secrets to Container App
        if (-not $DryRun) {
            $kvUri = az keyvault show --name $item.KvName --query properties.vaultUri -o tsv 2>$null

            if ($kvUri) {
                Invoke-AzCommand "Linking Key Vault secrets to Container App: $caName" `
                    "az containerapp secret set --subscription '$($item.SubId)' --resource-group '$($item.RG)' --name '$caName' --secrets db-conn=keyvaultref:${kvUri}secrets/db-connection-string,identityref:system api-key=keyvaultref:${kvUri}secrets/api-key,identityref:system"
            }
        }
    }
}

# =============================================================================
# 10. SUMMARY
# =============================================================================

function Write-DeploymentSummary {
    Write-Log "SECTION" "Deployment Summary"

    $app = $Config.AppName

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "      Azure Infrastructure Deployment Complete                  " -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Application:     $app"                        -ForegroundColor Cyan
    Write-Host "  Region:          $($Config.Location)"         -ForegroundColor Cyan
    Write-Host "  DR Region:       $($Config.LocationDR)"       -ForegroundColor Cyan
    Write-Host "  Target Env:      $TargetEnv"                  -ForegroundColor Cyan
    Write-Host "  Dry Run:         $DryRun"                     -ForegroundColor Cyan
    Write-Host "  Log File:        $LogFile"                    -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Resources Created:" -ForegroundColor Yellow
    Write-Host "  +-- Resource Groups:      rg-${app}-{dev,staging,prod}, rg-shared-{nonprod,prod}"
    Write-Host "  +-- Log Analytics:        la-${app}-{nonprod,prod}"
    Write-Host "  +-- Container Registries: $($Config.AcrNonprodName), $($Config.AcrProdName)"
    Write-Host "  +-- Key Vaults:           kv-${app}-{dev,staging,prod}"
    Write-Host "  +-- Container Envs:       $($Config.ContainerEnvName)-{dev,staging,prod}"
    Write-Host "  +-- Container Apps:       $($Config.ContainerAppName)-{dev,staging,prod}"
    Write-Host "  +-- RBAC:                 AcrPull + KV Secrets User per app"
    Write-Host "  +-- Policies:             HTTPS, Tags, Public IP deny, Locations"
    Write-Host ""
    Write-Host "  Next Steps:" -ForegroundColor Yellow
    Write-Host "  1. Update Key Vault secrets with actual values per environment"
    Write-Host "  2. Push container images to ACR and update Container App image references"
    Write-Host "  3. Configure CI/CD pipelines (GitHub Actions recommended)"
    Write-Host "  4. Convert this script to Terraform/Bicep for long-term IaC"
    Write-Host "  5. Set up monitoring alerts in Log Analytics"
    Write-Host ""
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "    Azure Infrastructure Deployment — Syed Rizvi               " -ForegroundColor Green
Write-Host "    App: $($Config.AppName)  |  Region: $($Config.Location)    " -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""

if ($DryRun) {
    Write-Log "WARN" "DRY-RUN mode enabled — no changes will be made"
}

Invoke-PreflightChecks
New-ResourceGroups
New-LogAnalyticsWorkspaces
New-ContainerRegistries
New-KeyVaults
New-ContainerAppEnvironments
New-ContainerApps
Set-RbacAssignments
Set-AzurePolicies
Set-KeyVaultReferences
Write-DeploymentSummary

Write-Log "SUCCESS" "Full deployment completed. Log: $LogFile"
