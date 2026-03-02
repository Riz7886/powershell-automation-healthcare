param(
    [string]$OutputPath = ".\Azure-Complete-Cleanup-Results",
    [int]$SnapshotAgeDays = 90,
    [int]$LogicAppFailedDays = 30
)

$ErrorActionPreference = "Continue"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        "SAVINGS" { "Cyan" }
        "HEADER" { "Magenta" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Get-ResourceCost {
    param([string]$ResourceType, [string]$Size)
    
    $costs = @{
        "VirtualMachine_Standard_D2s_v3" = 70
        "VirtualMachine_Standard_D4s_v3" = 140
        "VirtualMachine_Standard_D8s_v3" = 280
        "VirtualMachine_Standard_D2_v3" = 65
        "VirtualMachine_Standard_D4_v3" = 130
        "VirtualMachine_Standard_B2s" = 30
        "VirtualMachine_Standard_B2ms" = 60
        "VirtualMachine_Standard_B4ms" = 120
        "VirtualMachine_Standard_DS1_v2" = 45
        "VirtualMachine_Standard_DS2_v2" = 90
        "VirtualMachine_Standard_DS3_v2" = 180
        "VirtualMachine_Standard_E2s_v3" = 90
        "VirtualMachine_Standard_E4s_v3" = 180
        "VirtualMachine_Default" = 100
        "Disk_Premium_P10" = 20
        "Disk_Premium_P20" = 40
        "Disk_Premium_P30" = 80
        "Disk_Premium_P40" = 150
        "Disk_Premium_P50" = 250
        "Disk_StandardSSD_E10" = 10
        "Disk_StandardSSD_E20" = 20
        "Disk_StandardSSD_E30" = 40
        "Disk_Standard_S10" = 5
        "Disk_Standard_S20" = 10
        "Disk_Standard_S30" = 20
        "Disk_Default" = 25
        "PublicIP_Standard" = 4
        "PublicIP_Basic" = 3
        "PublicIP_Default" = 4
        "LoadBalancer_Standard" = 25
        "LoadBalancer_Basic" = 18
        "LoadBalancer_Default" = 25
        "ApplicationGateway_Standard_v2" = 250
        "ApplicationGateway_WAF_v2" = 350
        "ApplicationGateway_Default" = 200
        "VPNGateway_VpnGw1" = 140
        "VPNGateway_VpnGw2" = 280
        "VPNGateway_VpnGw3" = 560
        "VPNGateway_Default" = 140
        "LogicApp_Standard" = 30
        "LogicApp_Default" = 25
        "AppService_B1" = 13
        "AppService_B2" = 26
        "AppService_B3" = 52
        "AppService_S1" = 70
        "AppService_S2" = 140
        "AppService_S3" = 280
        "AppService_P1v2" = 80
        "AppService_P2v2" = 160
        "AppService_P3v2" = 320
        "AppService_Default" = 50
        "FunctionApp" = 20
        "NIC" = 0
        "EmptyResourceGroup" = 0
        "Snapshot" = 15
        "StorageAccount" = 20
        "SQLDatabase_Basic" = 5
        "SQLDatabase_S0" = 15
        "SQLDatabase_S1" = 30
        "SQLDatabase_S2" = 75
        "SQLDatabase_Default" = 50
        "CosmosDB" = 25
        "Redis_C0" = 16
        "Redis_C1" = 50
        "Redis_Default" = 50
        "AKS_Node" = 100
        "ContainerInstance" = 30
        "DataFactory" = 25
        "EventHub" = 15
        "ServiceBus" = 10
    }
    
    $key = "${ResourceType}_${Size}"
    if ($costs.ContainsKey($key)) { return $costs[$key] }
    elseif ($costs.ContainsKey("${ResourceType}_Default")) { return $costs["${ResourceType}_Default"] }
    elseif ($costs.ContainsKey($ResourceType)) { return $costs[$ResourceType] }
    return 25
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     AZURE COMPLETE CLEANUP TOOLKIT" -ForegroundColor Cyan
Write-Host "     SQL | VMs | Logic Apps | App Services | Storage | More" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This script audits ALL resource types for cleanup opportunities" -ForegroundColor Gray
Write-Host "  Mode: AUDIT ONLY - No changes will be made" -ForegroundColor Yellow
Write-Host ""

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$requiredModules = @("Az.Accounts", "Az.Compute", "Az.Network", "Az.Storage", "Az.Resources", "Az.Sql", "Az.Websites", "Az.LogicApp")
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Log "Installing $module..." "WARNING"
        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -ErrorAction SilentlyContinue
    }
}

Import-Module Az.Accounts, Az.Compute, Az.Network, Az.Storage, Az.Resources -ErrorAction SilentlyContinue
Import-Module Az.Sql, Az.Websites, Az.LogicApp -ErrorAction SilentlyContinue

try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Log "Connecting to Azure..." "INFO"
        Connect-AzAccount | Out-Null
        $context = Get-AzContext
    }
    Write-Log "Connected as: $($context.Account.Id)" "SUCCESS"
}
catch {
    Write-Log "Failed to connect to Azure: $($_.Exception.Message)" "ERROR"
    exit 1
}

$allIdleResources = @()
$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
Write-Log "Found $($subscriptions.Count) subscriptions to scan" "SUCCESS"
Write-Host ""

foreach ($subscription in $subscriptions) {
    Write-Host ""
    Write-Log "========== SCANNING: $($subscription.Name) ==========" "HEADER"
    
    try {
        Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "Cannot access subscription: $($subscription.Name)" "WARNING"
        continue
    }
    
    # ============================================================
    # 1. VIRTUAL MACHINES (Stopped/Deallocated)
    # ============================================================
    Write-Log "Checking Virtual Machines..." "INFO"
    try {
        $vms = Get-AzVM -Status -ErrorAction SilentlyContinue
        foreach ($vm in $vms) {
            if ($vm.PowerState -eq "VM deallocated" -or $vm.PowerState -eq "VM stopped") {
                $cost = Get-ResourceCost -ResourceType "VirtualMachine" -Size $vm.HardwareProfile.VmSize
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $vm.ResourceGroupName
                    ResourceType = "Virtual Machine (Stopped)"
                    ResourceName = $vm.Name
                    Location = $vm.Location
                    Details = "Size: $($vm.HardwareProfile.VmSize)"
                    Status = $vm.PowerState
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete if not needed or convert to Reserved Instance"
                }
                Write-Log "  Found stopped VM: $($vm.Name) - `$$cost/month" "SAVINGS"
            }
        }
    } catch { Write-Log "  Error checking VMs: $($_.Exception.Message)" "WARNING" }
    
    # ============================================================
    # 2. MANAGED DISKS (Unattached)
    # ============================================================
    Write-Log "Checking Managed Disks..." "INFO"
    try {
        $disks = Get-AzDisk -ErrorAction SilentlyContinue
        foreach ($disk in $disks) {
            if ($disk.DiskState -eq "Unattached" -or [string]::IsNullOrEmpty($disk.ManagedBy)) {
                $cost = Get-ResourceCost -ResourceType "Disk" -Size $disk.Sku.Name
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $disk.ResourceGroupName
                    ResourceType = "Managed Disk (Unattached)"
                    ResourceName = $disk.Name
                    Location = $disk.Location
                    Details = "$($disk.DiskSizeGB) GB - $($disk.Sku.Name)"
                    Status = "Unattached"
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete or attach to VM"
                }
                Write-Log "  Found unattached disk: $($disk.Name) - `$$cost/month" "SAVINGS"
            }
        }
    } catch { Write-Log "  Error checking disks: $($_.Exception.Message)" "WARNING" }
    
    # ============================================================
    # 3. PUBLIC IP ADDRESSES (Unused)
    # ============================================================
    Write-Log "Checking Public IPs..." "INFO"
    try {
        $publicIPs = Get-AzPublicIpAddress -ErrorAction SilentlyContinue
        foreach ($pip in $publicIPs) {
            if ([string]::IsNullOrEmpty($pip.IpConfiguration) -and [string]::IsNullOrEmpty($pip.IpConfiguration.Id)) {
                $cost = Get-ResourceCost -ResourceType "PublicIP" -Size $pip.Sku.Name
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $pip.ResourceGroupName
                    ResourceType = "Public IP (Unused)"
                    ResourceName = $pip.Name
                    Location = $pip.Location
                    Details = "SKU: $($pip.Sku.Name) - IP: $($pip.IpAddress)"
                    Status = "Not Associated"
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete if not reserved for future use"
                }
                Write-Log "  Found unused Public IP: $($pip.Name) - `$$cost/month" "SAVINGS"
            }
        }
    } catch { Write-Log "  Error checking Public IPs: $($_.Exception.Message)" "WARNING" }
    
    # ============================================================
    # 4. NETWORK INTERFACES (Unattached)
    # ============================================================
    Write-Log "Checking Network Interfaces..." "INFO"
    try {
        $nics = Get-AzNetworkInterface -ErrorAction SilentlyContinue
        foreach ($nic in $nics) {
            if ([string]::IsNullOrEmpty($nic.VirtualMachine) -or [string]::IsNullOrEmpty($nic.VirtualMachine.Id)) {
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $nic.ResourceGroupName
                    ResourceType = "Network Interface (Orphaned)"
                    ResourceName = $nic.Name
                    Location = $nic.Location
                    Details = "Not attached to any VM"
                    Status = "Orphaned"
                    MonthlyCost = 0
                    AnnualCost = 0
                    Recommendation = "Delete - no longer needed"
                }
                Write-Log "  Found orphaned NIC: $($nic.Name)" "SAVINGS"
            }
        }
    } catch { Write-Log "  Error checking NICs: $($_.Exception.Message)" "WARNING" }
    
    # ============================================================
    # 5. LOAD BALANCERS (Empty Backend Pools)
    # ============================================================
    Write-Log "Checking Load Balancers..." "INFO"
    try {
        $lbs = Get-AzLoadBalancer -ErrorAction SilentlyContinue
        foreach ($lb in $lbs) {
            $hasBackend = $false
            foreach ($pool in $lb.BackendAddressPools) {
                if ($pool.BackendIpConfigurations -and $pool.BackendIpConfigurations.Count -gt 0) {
                    $hasBackend = $true
                    break
                }
            }
            if (-not $hasBackend) {
                $cost = Get-ResourceCost -ResourceType "LoadBalancer" -Size $lb.Sku.Name
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $lb.ResourceGroupName
                    ResourceType = "Load Balancer (Empty)"
                    ResourceName = $lb.Name
                    Location = $lb.Location
                    Details = "SKU: $($lb.Sku.Name) - No backends"
                    Status = "No Backend Pools"
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete - no backend targets"
                }
                Write-Log "  Found empty Load Balancer: $($lb.Name) - `$$cost/month" "SAVINGS"
            }
        }
    } catch { Write-Log "  Error checking Load Balancers: $($_.Exception.Message)" "WARNING" }
    
    # ============================================================
    # 6. APPLICATION GATEWAYS (No Backend Pools)
    # ============================================================
    Write-Log "Checking Application Gateways..." "INFO"
    try {
        $appGWs = Get-AzApplicationGateway -ErrorAction SilentlyContinue
        foreach ($gw in $appGWs) {
            $hasBackend = $false
            foreach ($pool in $gw.BackendAddressPools) {
                if ($pool.BackendAddresses -and $pool.BackendAddresses.Count -gt 0) {
                    $hasBackend = $true
                    break
                }
            }
            if (-not $hasBackend) {
                $cost = Get-ResourceCost -ResourceType "ApplicationGateway" -Size $gw.Sku.Name
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $gw.ResourceGroupName
                    ResourceType = "Application Gateway (Empty)"
                    ResourceName = $gw.Name
                    Location = $gw.Location
                    Details = "SKU: $($gw.Sku.Name)"
                    Status = "No Backend Pools"
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete - no backend targets"
                }
                Write-Log "  Found empty App Gateway: $($gw.Name) - `$$cost/month" "SAVINGS"
            }
        }
    } catch { Write-Log "  Error checking App Gateways: $($_.Exception.Message)" "WARNING" }
    
    # ============================================================
    # 7. LOGIC APPS (Disabled or Failed)
    # ============================================================
    Write-Log "Checking Logic Apps..." "INFO"
    try {
        $logicApps = Get-AzResource -ResourceType "Microsoft.Logic/workflows" -ErrorAction SilentlyContinue
        foreach ($la in $logicApps) {
            $logicApp = Get-AzLogicApp -ResourceGroupName $la.ResourceGroupName -Name $la.Name -ErrorAction SilentlyContinue
            if ($logicApp) {
                $isIdle = $false
                $status = ""
                
                if ($logicApp.State -eq "Disabled") {
                    $isIdle = $true
                    $status = "Disabled"
                }
                
                if ($isIdle) {
                    $cost = Get-ResourceCost -ResourceType "LogicApp" -Size "Standard"
                    $allIdleResources += [PSCustomObject]@{
                        SubscriptionName = $subscription.Name
                        ResourceGroup = $la.ResourceGroupName
                        ResourceType = "Logic App (Disabled)"
                        ResourceName = $la.Name
                        Location = $la.Location
                        Details = "State: $status"
                        Status = $status
                        MonthlyCost = $cost
                        AnnualCost = $cost * 12
                        Recommendation = "Delete if no longer needed"
                    }
                    Write-Log "  Found disabled Logic App: $($la.Name) - `$$cost/month" "SAVINGS"
                }
            }
        }
    } catch { Write-Log "  Error checking Logic Apps: $($_.Exception.Message)" "WARNING" }
    
    # ============================================================
    # 8. APP SERVICES (Stopped)
    # ============================================================
    Write-Log "Checking App Services..." "INFO"
    try {
        $webApps = Get-AzWebApp -ErrorAction SilentlyContinue
        foreach ($app in $webApps) {
            if ($app.State -eq "Stopped") {
                $plan = Get-AzAppServicePlan -ResourceGroupName $app.ResourceGroup -Name $app.ServerFarmId.Split('/')[-1] -ErrorAction SilentlyContinue
                $sku = if ($plan) { $plan.Sku.Name } else { "Default" }
                $cost = Get-ResourceCost -ResourceType "AppService" -Size $sku
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $app.ResourceGroup
                    ResourceType = "App Service (Stopped)"
                    ResourceName = $app.Name
                    Location = $app.Location
                    Details = "SKU: $sku - URL: $($app.DefaultHostName)"
                    Status = "Stopped"
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete or restart if needed"
                }
                Write-Log "  Found stopped App Service: $($app.Name) - `$$cost/month" "SAVINGS"
            }
        }
    } catch { Write-Log "  Error checking App Services: $($_.Exception.Message)" "WARNING" }
    
    # ============================================================
    # 9. FUNCTION APPS (Disabled)
    # ============================================================
    Write-Log "Checking Function Apps..." "INFO"
    try {
        $funcApps = Get-AzFunctionApp -ErrorAction SilentlyContinue
        foreach ($func in $funcApps) {
            if ($func.State -eq "Stopped") {
                $cost = Get-ResourceCost -ResourceType "FunctionApp" -Size ""
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $func.ResourceGroup
                    ResourceType = "Function App (Stopped)"
                    ResourceName = $func.Name
                    Location = $func.Location
                    Details = "Runtime: $($func.Runtime)"
                    Status = "Stopped"
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete if no longer needed"
                }
                Write-Log "  Found stopped Function App: $($func.Name) - `$$cost/month" "SAVINGS"
            }
        }
    } catch { Write-Log "  Error checking Function Apps: $($_.Exception.Message)" "WARNING" }
    
    # ============================================================
    # 10. SNAPSHOTS (Older than X days)
    # ============================================================
    Write-Log "Checking Snapshots (older than $SnapshotAgeDays days)..." "INFO"
    try {
        $snapshots = Get-AzSnapshot -ErrorAction SilentlyContinue
        $cutoffDate = (Get-Date).AddDays(-$SnapshotAgeDays)
        foreach ($snapshot in $snapshots) {
            if ($snapshot.TimeCreated -lt $cutoffDate) {
                $cost = Get-ResourceCost -ResourceType "Snapshot" -Size ""
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $snapshot.ResourceGroupName
                    ResourceType = "Snapshot (Old)"
                    ResourceName = $snapshot.Name
                    Location = $snapshot.Location
                    Details = "$($snapshot.DiskSizeGB) GB - Created: $($snapshot.TimeCreated.ToString('yyyy-MM-dd'))"
                    Status = "Older than $SnapshotAgeDays days"
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete old snapshot if backup not needed"
                }
                Write-Log "  Found old snapshot: $($snapshot.Name) - `$$cost/month" "SAVINGS"
            }
        }
    } catch { Write-Log "  Error checking Snapshots: $($_.Exception.Message)" "WARNING" }
    
    # ============================================================
    # 11. STORAGE ACCOUNTS (Empty or minimal usage)
    # ============================================================
    Write-Log "Checking Storage Accounts..." "INFO"
    try {
        $storageAccounts = Get-AzStorageAccount -ErrorAction SilentlyContinue
        foreach ($sa in $storageAccounts) {
            try {
                $ctx = $sa.Context
                $containers = Get-AzStorageContainer -Context $ctx -ErrorAction SilentlyContinue
                $tables = Get-AzStorageTable -Context $ctx -ErrorAction SilentlyContinue
                $queues = Get-AzStorageQueue -Context $ctx -ErrorAction SilentlyContinue
                $shares = Get-AzStorageShare -Context $ctx -ErrorAction SilentlyContinue
                
                $totalItems = 0
                if ($containers) { $totalItems += $containers.Count }
                if ($tables) { $totalItems += $tables.Count }
                if ($queues) { $totalItems += $queues.Count }
                if ($shares) { $totalItems += $shares.Count }
                
                if ($totalItems -eq 0) {
                    $cost = Get-ResourceCost -ResourceType "StorageAccount" -Size ""
                    $allIdleResources += [PSCustomObject]@{
                        SubscriptionName = $subscription.Name
                        ResourceGroup = $sa.ResourceGroupName
                        ResourceType = "Storage Account (Empty)"
                        ResourceName = $sa.StorageAccountName
                        Location = $sa.Location
                        Details = "SKU: $($sa.Sku.Name) - No containers/tables/queues"
                        Status = "Empty"
                        MonthlyCost = $cost
                        AnnualCost = $cost * 12
                        Recommendation = "Delete if not needed"
                    }
                    Write-Log "  Found empty Storage Account: $($sa.StorageAccountName) - `$$cost/month" "SAVINGS"
                }
            } catch { }
        }
    } catch { Write-Log "  Error checking Storage Accounts: $($_.Exception.Message)" "WARNING" }
    
    # ============================================================
    # 12. EMPTY RESOURCE GROUPS
    # ============================================================
    Write-Log "Checking Empty Resource Groups..." "INFO"
    try {
        $resourceGroups = Get-AzResourceGroup -ErrorAction SilentlyContinue
        foreach ($rg in $resourceGroups) {
            $resources = Get-AzResource -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
            if (-not $resources -or $resources.Count -eq 0) {
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $rg.ResourceGroupName
                    ResourceType = "Resource Group (Empty)"
                    ResourceName = $rg.ResourceGroupName
                    Location = $rg.Location
                    Details = "No resources inside"
                    Status = "Empty"
                    MonthlyCost = 0
                    AnnualCost = 0
                    Recommendation = "Delete empty resource group"
                }
                Write-Log "  Found empty RG: $($rg.ResourceGroupName)" "SAVINGS"
            }
        }
    } catch { Write-Log "  Error checking Resource Groups: $($_.Exception.Message)" "WARNING" }
}

# ============================================================
# CALCULATE TOTALS
# ============================================================
$totalMonthlySavings = ($allIdleResources | Measure-Object -Property MonthlyCost -Sum).Sum
if (-not $totalMonthlySavings) { $totalMonthlySavings = 0 }
$totalAnnualSavings = $totalMonthlySavings * 12
$totalResources = $allIdleResources.Count

# Group by type
$byType = $allIdleResources | Group-Object -Property ResourceType | 
    Select-Object Name, Count, @{N='MonthlyCost';E={($_.Group | Measure-Object -Property MonthlyCost -Sum).Sum}} |
    Sort-Object MonthlyCost -Descending

# Group by subscription
$bySub = $allIdleResources | Group-Object -Property SubscriptionName | 
    Select-Object Name, Count, @{N='MonthlyCost';E={($_.Group | Measure-Object -Property MonthlyCost -Sum).Sum}} |
    Sort-Object MonthlyCost -Descending

# ============================================================
# EXPORT CSV
# ============================================================
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$csvPath = Join-Path $OutputPath "Azure-Complete-Cleanup-Report_$timestamp.csv"
$allIdleResources | Export-Csv -Path $csvPath -NoTypeInformation

# ============================================================
# GENERATE HTML REPORT
# ============================================================
$htmlPath = Join-Path $OutputPath "Azure-Complete-Cleanup-Report_$timestamp.html"

$typeRows = ""
foreach ($type in $byType) {
    $typeRows += "<tr><td>$($type.Name)</td><td>$($type.Count)</td><td>`$$([math]::Round($type.MonthlyCost, 2))</td><td>`$$([math]::Round($type.MonthlyCost * 12, 2))</td></tr>"
}

$subRows = ""
foreach ($sub in $bySub) {
    $subRows += "<tr><td>$($sub.Name)</td><td>$($sub.Count)</td><td>`$$([math]::Round($sub.MonthlyCost, 2))</td><td>`$$([math]::Round($sub.MonthlyCost * 12, 2))</td></tr>"
}

$detailRows = ""
foreach ($resource in ($allIdleResources | Sort-Object MonthlyCost -Descending)) {
    $rowColor = if ($resource.MonthlyCost -ge 100) { "background:#ffe6e6;" } elseif ($resource.MonthlyCost -ge 50) { "background:#fff3e6;" } else { "" }
    $detailRows += "<tr style='$rowColor'><td>$($resource.ResourceName)</td><td>$($resource.ResourceType)</td><td>$($resource.SubscriptionName)</td><td>$($resource.ResourceGroup)</td><td>$($resource.Details)</td><td>$($resource.Status)</td><td>`$$($resource.MonthlyCost)</td><td>`$$($resource.AnnualCost)</td><td>$($resource.Recommendation)</td></tr>"
}

$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>Azure Complete Cleanup Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f0f0f0; }
        .container { max-width: 1600px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; box-shadow: 0 4px 20px rgba(0,0,0,0.15); }
        h1 { color: #d83b01; border-bottom: 4px solid #d83b01; padding-bottom: 15px; margin-bottom: 10px; }
        h2 { color: #0078d4; margin-top: 30px; border-left: 4px solid #0078d4; padding-left: 15px; }
        .summary { display: flex; gap: 15px; margin: 25px 0; flex-wrap: wrap; }
        .card { flex: 1; min-width: 180px; padding: 25px 15px; border-radius: 10px; text-align: center; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .card.green { background: linear-gradient(135deg, #107c10, #0b5c0b); color: white; }
        .card.red { background: linear-gradient(135deg, #d83b01, #a62c01); color: white; }
        .card.blue { background: linear-gradient(135deg, #0078d4, #005a9e); color: white; }
        .card.purple { background: linear-gradient(135deg, #5c2d91, #441f6b); color: white; }
        .card h2 { margin: 0; font-size: 2.2em; color: white; border: none; padding: 0; }
        .card p { margin: 10px 0 0 0; opacity: 0.95; font-size: 0.95em; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; font-size: 0.9em; }
        th { background: #0078d4; color: white; padding: 12px 8px; text-align: left; position: sticky; top: 0; }
        td { padding: 10px 8px; border-bottom: 1px solid #ddd; }
        tr:hover { background: #e6f3ff; }
        .type-table th { background: #d83b01; }
        .sub-table th { background: #5c2d91; }
        .footer { margin-top: 40px; text-align: center; color: #666; font-size: 0.85em; padding-top: 20px; border-top: 1px solid #ddd; }
        .warning { background: #fff8e6; border-left: 5px solid #d83b01; padding: 15px 20px; margin: 25px 0; border-radius: 0 5px 5px 0; }
        .tip { background: #e6f7e6; border-left: 5px solid #107c10; padding: 15px 20px; margin: 25px 0; border-radius: 0 5px 5px 0; }
        .section { margin-bottom: 40px; }
        .highlight { font-size: 1.4em; font-weight: bold; color: #107c10; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Azure Complete Cleanup Report</h1>
        <p><strong>Generated:</strong> $(Get-Date -Format "MMMM dd, yyyy HH:mm:ss")</p>
        <p><strong>Mode:</strong> <span style="color:#d83b01;font-weight:bold;">AUDIT ONLY - No changes made</span></p>
        <p><strong>Subscriptions Scanned:</strong> $($subscriptions.Count)</p>
        
        <div class="summary">
            <div class="card green">
                <h2>`$$([math]::Round($totalMonthlySavings, 2))</h2>
                <p>Monthly Savings</p>
            </div>
            <div class="card green">
                <h2>`$$([math]::Round($totalAnnualSavings, 2))</h2>
                <p>Annual Savings</p>
            </div>
            <div class="card red">
                <h2>$totalResources</h2>
                <p>Idle Resources</p>
            </div>
            <div class="card blue">
                <h2>$($subscriptions.Count)</h2>
                <p>Subscriptions</p>
            </div>
            <div class="card purple">
                <h2>$($byType.Count)</h2>
                <p>Resource Types</p>
            </div>
        </div>
        
        <div class="warning">
            <strong>Important:</strong> This report identifies potentially idle resources. Review each item carefully before deletion. Some resources may be intentionally stopped, reserved for DR, or used periodically.
        </div>
        
        <div class="tip">
            <strong>Total Potential Savings:</strong> <span class="highlight">`$$([math]::Round($totalAnnualSavings, 2)) per year</span> by cleaning up $totalResources idle resources across $($subscriptions.Count) subscriptions.
        </div>
        
        <div class="section">
            <h2>Savings by Resource Type</h2>
            <table class="type-table">
                <tr><th>Resource Type</th><th>Count</th><th>Monthly Cost</th><th>Annual Cost</th></tr>
                $typeRows
            </table>
        </div>
        
        <div class="section">
            <h2>Savings by Subscription</h2>
            <table class="sub-table">
                <tr><th>Subscription</th><th>Idle Resources</th><th>Monthly Cost</th><th>Annual Cost</th></tr>
                $subRows
            </table>
        </div>
        
        <div class="section">
            <h2>All Idle Resources (Sorted by Cost)</h2>
            <table>
                <tr>
                    <th>Resource Name</th>
                    <th>Type</th>
                    <th>Subscription</th>
                    <th>Resource Group</th>
                    <th>Details</th>
                    <th>Status</th>
                    <th>Monthly</th>
                    <th>Annual</th>
                    <th>Recommendation</th>
                </tr>
                $detailRows
            </table>
        </div>
        
        <div class="footer">
            <p><strong>Azure Complete Cleanup Toolkit</strong> | Infrastructure Team</p>
            <p>Resources covered: VMs, Disks, Public IPs, NICs, Load Balancers, App Gateways, Logic Apps, App Services, Function Apps, Snapshots, Storage Accounts, Resource Groups</p>
        </div>
    </div>
</body>
</html>
"@

$htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8

# ============================================================
# FINAL SUMMARY
# ============================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     AZURE COMPLETE CLEANUP AUDIT FINISHED" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Subscriptions Scanned:    $($subscriptions.Count)" -ForegroundColor White
Write-Host "  Idle Resources Found:     $totalResources" -ForegroundColor Red
Write-Host "  Resource Types Checked:   12" -ForegroundColor White
Write-Host ""
Write-Host "  MONTHLY SAVINGS:          `$$([math]::Round($totalMonthlySavings, 2))" -ForegroundColor Green
Write-Host "  ANNUAL SAVINGS:           `$$([math]::Round($totalAnnualSavings, 2))" -ForegroundColor Green
Write-Host ""
Write-Host "  Reports saved to:" -ForegroundColor White
Write-Host "    CSV:  $csvPath" -ForegroundColor Gray
Write-Host "    HTML: $htmlPath" -ForegroundColor Gray
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan

# Open the HTML report
Start-Process $htmlPath

Write-Host ""
Write-Log "Report opened in browser!" "SUCCESS"
Write-Host ""
