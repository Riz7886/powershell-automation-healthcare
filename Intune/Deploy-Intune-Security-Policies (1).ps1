# ============================================================================
# INTUNE SECURITY POLICIES DEPLOYMENT
# Deploys LLMNR Disable, USB Block, NETBIOS/WPAD Security Policies
# ============================================================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "INTUNE SECURITY POLICIES DEPLOYMENT" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# STEP 1: INSTALL REQUIRED MODULES
# ----------------------------------------------------------------------------
Write-Host "[1/7] Checking required modules..." -ForegroundColor Yellow

$requiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.DeviceManagement",
    "Microsoft.Graph.Groups"
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing $module..." -ForegroundColor Yellow
        Install-Module $module -Scope CurrentUser -Force -AllowClobber
    }
}

Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue
Import-Module Microsoft.Graph.DeviceManagement -ErrorAction SilentlyContinue
Import-Module Microsoft.Graph.Groups -ErrorAction SilentlyContinue

Write-Host "Modules loaded successfully" -ForegroundColor Green

# ----------------------------------------------------------------------------
# STEP 2: CONNECT TO MICROSOFT GRAPH
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/7] Connecting to Microsoft Graph..." -ForegroundColor Yellow

$scopes = @(
    "DeviceManagementConfiguration.ReadWrite.All",
    "DeviceManagementManagedDevices.ReadWrite.All",
    "Group.Read.All",
    "Organization.Read.All"
)

try {
    Connect-MgGraph -Scopes $scopes -NoWelcome
    $context = Get-MgContext
    Write-Host "Connected as: $($context.Account)" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to connect" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------------------------
# STEP 3: SHOW TENANT INFO AND CONFIRM
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/7] Retrieving tenant information..." -ForegroundColor Yellow

try {
    $org = Get-MgOrganization
    Write-Host ""
    Write-Host "CONNECTED TO:" -ForegroundColor Cyan
    Write-Host "  Tenant Name:  $($org.DisplayName)" -ForegroundColor White
    Write-Host "  Tenant ID:    $($org.Id)" -ForegroundColor White
    Write-Host "  Domain:       $($org.VerifiedDomains | Where-Object { $_.IsDefault } | Select-Object -ExpandProperty Name)" -ForegroundColor White
    Write-Host ""
} catch {
    Write-Host "Connected to tenant: $($context.TenantId)" -ForegroundColor White
    Write-Host ""
}

$confirm = Read-Host "Deploy security policies to this tenant? (Y/N)"
if ($confirm -ne "Y" -and $confirm -ne "y") {
    Write-Host "Deployment cancelled" -ForegroundColor Yellow
    Disconnect-MgGraph | Out-Null
    exit 0
}

# ----------------------------------------------------------------------------
# STEP 4: SELECT TARGET GROUP
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[4/7] Loading device groups..." -ForegroundColor Yellow

$allGroups = Get-MgGroup -All | Where-Object { 
    $_.DisplayName -like "*Windows*" -or 
    $_.DisplayName -like "*Device*" -or 
    $_.DisplayName -like "*Computer*" -or
    $_.DisplayName -like "*Workstation*" -or
    $_.DisplayName -like "*All*"
} | Sort-Object DisplayName

if ($allGroups.Count -eq 0) {
    Write-Host "No device groups found. Loading all groups..." -ForegroundColor Yellow
    $allGroups = Get-MgGroup -Top 50 | Sort-Object DisplayName
}

Write-Host ""
Write-Host "Available Groups:" -ForegroundColor Cyan
for ($i = 0; $i -lt $allGroups.Count; $i++) {
    Write-Host "  [$($i + 1)] $($allGroups[$i].DisplayName)" -ForegroundColor White
}

Write-Host ""
$selection = Read-Host "Select group number (1-$($allGroups.Count))"
$targetGroup = $allGroups[[int]$selection - 1]

Write-Host "Target group: $($targetGroup.DisplayName)" -ForegroundColor Green
$groupId = $targetGroup.Id

# ----------------------------------------------------------------------------
# STEP 5: CREATE DISABLE LLMNR POLICY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/7] Creating Disable LLMNR Policy..." -ForegroundColor Yellow

$llmnrPolicyName = "Security - Disable LLMNR"

# Check if exists
$existingPolicies = Get-MgDeviceManagementDeviceConfiguration -All
$existingLlmnr = $existingPolicies | Where-Object { $_.DisplayName -eq $llmnrPolicyName }

if ($existingLlmnr) {
    Write-Host "Policy exists: $llmnrPolicyName - Skipping" -ForegroundColor Yellow
    $llmnrPolicyId = $existingLlmnr.Id
} else {
    $llmnrPolicy = @{
        "@odata.type" = "#microsoft.graph.windows10CustomConfiguration"
        displayName = $llmnrPolicyName
        description = "Disables Link-Local Multicast Name Resolution to prevent poisoning attacks"
        omaSettings = @(
            @{
                "@odata.type" = "#microsoft.graph.omaSettingInteger"
                displayName = "Turn off multicast name resolution"
                description = "Disables LLMNR"
                omaUri = "./Device/Vendor/MSFT/Policy/Config/ADMX_DnsClient/Turn_Off_Multicast"
                value = 0
            }
        )
    }

    try {
        $newPolicy = New-MgDeviceManagementDeviceConfiguration -BodyParameter $llmnrPolicy
        Write-Host "Created: $llmnrPolicyName" -ForegroundColor Green
        $llmnrPolicyId = $newPolicy.Id
        
        # Assign to group
        $assignmentBody = @{
            assignments = @(
                @{
                    target = @{
                        "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                        groupId = $groupId
                    }
                }
            )
        }
        
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations/$llmnrPolicyId/assign" -Body ($assignmentBody | ConvertTo-Json -Depth 10)
        Write-Host "Assigned to: $($targetGroup.DisplayName)" -ForegroundColor Green
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ----------------------------------------------------------------------------
# STEP 6: CREATE USB BLOCK POLICY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[6/7] Creating USB Block Policy..." -ForegroundColor Yellow

$usbPolicyName = "Security - Block USB Storage"

$existingUsb = $existingPolicies | Where-Object { $_.DisplayName -eq $usbPolicyName }

if ($existingUsb) {
    Write-Host "Policy exists: $usbPolicyName - Skipping" -ForegroundColor Yellow
    $usbPolicyId = $existingUsb.Id
} else {
    $usbPolicy = @{
        "@odata.type" = "#microsoft.graph.windows10GeneralConfiguration"
        displayName = $usbPolicyName
        description = "Blocks USB removable storage to prevent data exfiltration"
        storageBlockRemovableStorage = $true
    }

    try {
        $newUsbPolicy = New-MgDeviceManagementDeviceConfiguration -BodyParameter $usbPolicy
        Write-Host "Created: $usbPolicyName" -ForegroundColor Green
        $usbPolicyId = $newUsbPolicy.Id
        
        # Assign to group
        $assignmentBody = @{
            assignments = @(
                @{
                    target = @{
                        "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                        groupId = $groupId
                    }
                }
            )
        }
        
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations/$usbPolicyId/assign" -Body ($assignmentBody | ConvertTo-Json -Depth 10)
        Write-Host "Assigned to: $($targetGroup.DisplayName)" -ForegroundColor Green
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ----------------------------------------------------------------------------
# STEP 7: CREATE NETBIOS/WPAD DISABLE POLICY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[7/7] Creating NETBIOS/WPAD Disable Policy..." -ForegroundColor Yellow

$netbiosPolicyName = "Security - Disable NETBIOS and WPAD"

$existingNetbios = $existingPolicies | Where-Object { $_.DisplayName -eq $netbiosPolicyName }

if ($existingNetbios) {
    Write-Host "Policy exists: $netbiosPolicyName - Skipping" -ForegroundColor Yellow
} else {
    $netbiosPolicy = @{
        "@odata.type" = "#microsoft.graph.windows10CustomConfiguration"
        displayName = $netbiosPolicyName
        description = "Disables NETBIOS and WPAD to prevent network poisoning attacks"
        omaSettings = @(
            @{
                "@odata.type" = "#microsoft.graph.omaSettingInteger"
                displayName = "Disable WPAD"
                description = "Disables Web Proxy Auto-Discovery"
                omaUri = "./Device/Vendor/MSFT/Policy/Config/ADMX_TerminalServer/TS_GATEWAY_POLICY_ENABLE"
                value = 0
            }
        )
    }

    try {
        $newNetbiosPolicy = New-MgDeviceManagementDeviceConfiguration -BodyParameter $netbiosPolicy
        Write-Host "Created: $netbiosPolicyName" -ForegroundColor Green
        $netbiosPolicyId = $newNetbiosPolicy.Id
        
        # Assign to group
        $assignmentBody = @{
            assignments = @(
                @{
                    target = @{
                        "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                        groupId = $groupId
                    }
                }
            )
        }
        
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations/$netbiosPolicyId/assign" -Body ($assignmentBody | ConvertTo-Json -Depth 10)
        Write-Host "Assigned to: $($targetGroup.DisplayName)" -ForegroundColor Green
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ----------------------------------------------------------------------------
# DEPLOYMENT SUMMARY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Green
Write-Host "DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Green
Write-Host ""

Write-Host "TENANT:" -ForegroundColor Cyan
Write-Host "  $($org.DisplayName)" -ForegroundColor White
Write-Host ""

Write-Host "POLICIES DEPLOYED:" -ForegroundColor Cyan
Write-Host "  1. $llmnrPolicyName" -ForegroundColor White
Write-Host "  2. $usbPolicyName" -ForegroundColor White
Write-Host "  3. $netbiosPolicyName" -ForegroundColor White
Write-Host ""

Write-Host "ASSIGNED TO:" -ForegroundColor Cyan
Write-Host "  Group: $($targetGroup.DisplayName)" -ForegroundColor White
Write-Host ""

Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  1. Open Intune admin center: https://intune.microsoft.com" -ForegroundColor White
Write-Host "  2. Go to Devices > Configuration profiles" -ForegroundColor White
Write-Host "  3. Verify policies are assigned and deploying" -ForegroundColor White
Write-Host "  4. Monitor Reports > Device configuration" -ForegroundColor White
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Green

# Disconnect
Disconnect-MgGraph | Out-Null
Write-Host "Disconnected from Microsoft Graph" -ForegroundColor Gray
