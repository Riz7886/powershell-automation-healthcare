param(
    [string]$OutputPath = ".\Idle-Resources-Results",
    [switch]$WhatIf
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
        "VirtualMachine_Standard_B2s" = 30
        "VirtualMachine_Standard_B2ms" = 60
        "VirtualMachine_Standard_B4ms" = 120
        "VirtualMachine_Standard_DS1_v2" = 45
        "VirtualMachine_Standard_DS2_v2" = 90
        "VirtualMachine_Standard_DS3_v2" = 180
        "VirtualMachine_Default" = 100
        "Disk_Premium_P10" = 20
        "Disk_Premium_P20" = 40
        "Disk_Premium_P30" = 80
        "Disk_Premium_P40" = 150
        "Disk_Standard_E10" = 5
        "Disk_Standard_E20" = 10
        "Disk_Standard_E30" = 20
        "Disk_Default" = 25
        "PublicIP" = 4
        "LoadBalancer" = 25
        "ApplicationGateway" = 200
        "VPNGateway" = 140
        "NIC" = 0
        "EmptyResourceGroup" = 0
        "Snapshot" = 15
        "StorageAccount" = 20
    }
    
    $key = "${ResourceType}_${Size}"
    if ($costs.ContainsKey($key)) {
        return $costs[$key]
    }
    elseif ($costs.ContainsKey("${ResourceType}_Default")) {
        return $costs["${ResourceType}_Default"]
    }
    elseif ($costs.ContainsKey($ResourceType)) {
        return $costs[$ResourceType]
    }
    return 25
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  AZURE IDLE RESOURCES AUDIT" -ForegroundColor Cyan
Write-Host "  Find Unused Resources and Calculate Savings" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$requiredModules = @("Az.Accounts", "Az.Compute", "Az.Network", "Az.Storage", "Az.Resources")
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Log "Installing $module..." "WARNING"
        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
    }
}

try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Log "Connecting to Azure..." "INFO"
        Connect-AzAccount | Out-Null
    }
    Write-Log "Connected as: $($context.Account.Id)" "SUCCESS"
}
catch {
    Write-Log "Failed to connect to Azure: $($_.Exception.Message)" "ERROR"
    exit 1
}

$allIdleResources = @()
$totalMonthlySavings = 0

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
Write-Log "Found $($subscriptions.Count) subscriptions to scan" "INFO"

foreach ($subscription in $subscriptions) {
    Write-Host ""
    Write-Log "Scanning: $($subscription.Name)" "INFO"
    
    try {
        Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "Cannot access subscription: $($subscription.Name)" "WARNING"
        continue
    }
    
    # 1. STOPPED VMs
    Write-Log "  Checking VMs..." "INFO"
    try {
        $vms = Get-AzVM -Status -ErrorAction SilentlyContinue
        foreach ($vm in $vms) {
            if ($vm.PowerState -eq "VM deallocated" -or $vm.PowerState -eq "VM stopped") {
                $cost = Get-ResourceCost -ResourceType "VirtualMachine" -Size $vm.HardwareProfile.VmSize
                $totalMonthlySavings += $cost
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $vm.ResourceGroupName
                    ResourceType = "Virtual Machine (Stopped)"
                    ResourceName = $vm.Name
                    Location = $vm.Location
                    Size = $vm.HardwareProfile.VmSize
                    Status = $vm.PowerState
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete if not needed or deallocate reservation"
                }
                Write-Log "    Found stopped VM: $($vm.Name) - $cost/month" "SAVINGS"
            }
        }
    }
    catch {
        Write-Log "  Error checking VMs: $($_.Exception.Message)" "WARNING"
    }
    
    # 2. UNATTACHED DISKS
    Write-Log "  Checking Disks..." "INFO"
    try {
        $disks = Get-AzDisk -ErrorAction SilentlyContinue
        foreach ($disk in $disks) {
            if ($disk.DiskState -eq "Unattached" -or [string]::IsNullOrEmpty($disk.ManagedBy)) {
                $cost = Get-ResourceCost -ResourceType "Disk" -Size $disk.Sku.Name
                $totalMonthlySavings += $cost
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $disk.ResourceGroupName
                    ResourceType = "Managed Disk (Unattached)"
                    ResourceName = $disk.Name
                    Location = $disk.Location
                    Size = "$($disk.DiskSizeGB) GB - $($disk.Sku.Name)"
                    Status = "Unattached"
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete or attach to VM"
                }
                Write-Log "    Found unattached disk: $($disk.Name) - $cost/month" "SAVINGS"
            }
        }
    }
    catch {
        Write-Log "  Error checking disks: $($_.Exception.Message)" "WARNING"
    }
    
    # 3. UNUSED PUBLIC IPs
    Write-Log "  Checking Public IPs..." "INFO"
    try {
        $publicIPs = Get-AzPublicIpAddress -ErrorAction SilentlyContinue
        foreach ($pip in $publicIPs) {
            if ([string]::IsNullOrEmpty($pip.IpConfiguration)) {
                $cost = Get-ResourceCost -ResourceType "PublicIP" -Size ""
                $totalMonthlySavings += $cost
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $pip.ResourceGroupName
                    ResourceType = "Public IP (Unused)"
                    ResourceName = $pip.Name
                    Location = $pip.Location
                    Size = $pip.Sku.Name
                    Status = "Not Associated"
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete if not reserved for future use"
                }
                Write-Log "    Found unused Public IP: $($pip.Name) - $cost/month" "SAVINGS"
            }
        }
    }
    catch {
        Write-Log "  Error checking Public IPs: $($_.Exception.Message)" "WARNING"
    }
    
    # 4. UNATTACHED NICs
    Write-Log "  Checking NICs..." "INFO"
    try {
        $nics = Get-AzNetworkInterface -ErrorAction SilentlyContinue
        foreach ($nic in $nics) {
            if ([string]::IsNullOrEmpty($nic.VirtualMachine)) {
                $cost = Get-ResourceCost -ResourceType "NIC" -Size ""
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $nic.ResourceGroupName
                    ResourceType = "Network Interface (Unattached)"
                    ResourceName = $nic.Name
                    Location = $nic.Location
                    Size = "N/A"
                    Status = "Not Attached"
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete - no longer needed"
                }
                Write-Log "    Found unattached NIC: $($nic.Name)" "SAVINGS"
            }
        }
    }
    catch {
        Write-Log "  Error checking NICs: $($_.Exception.Message)" "WARNING"
    }
    
    # 5. UNUSED LOAD BALANCERS
    Write-Log "  Checking Load Balancers..." "INFO"
    try {
        $lbs = Get-AzLoadBalancer -ErrorAction SilentlyContinue
        foreach ($lb in $lbs) {
            $hasBackend = $false
            foreach ($pool in $lb.BackendAddressPools) {
                if ($pool.BackendIpConfigurations.Count -gt 0) {
                    $hasBackend = $true
                    break
                }
            }
            if (-not $hasBackend) {
                $cost = Get-ResourceCost -ResourceType "LoadBalancer" -Size ""
                $totalMonthlySavings += $cost
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $lb.ResourceGroupName
                    ResourceType = "Load Balancer (Empty)"
                    ResourceName = $lb.Name
                    Location = $lb.Location
                    Size = $lb.Sku.Name
                    Status = "No Backend Pools"
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete - no backend targets configured"
                }
                Write-Log "    Found empty Load Balancer: $($lb.Name) - $cost/month" "SAVINGS"
            }
        }
    }
    catch {
        Write-Log "  Error checking Load Balancers: $($_.Exception.Message)" "WARNING"
    }
    
    # 6. OLD SNAPSHOTS (older than 90 days)
    Write-Log "  Checking Snapshots..." "INFO"
    try {
        $snapshots = Get-AzSnapshot -ErrorAction SilentlyContinue
        $cutoffDate = (Get-Date).AddDays(-90)
        foreach ($snapshot in $snapshots) {
            if ($snapshot.TimeCreated -lt $cutoffDate) {
                $cost = Get-ResourceCost -ResourceType "Snapshot" -Size ""
                $totalMonthlySavings += $cost
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $snapshot.ResourceGroupName
                    ResourceType = "Snapshot (Old > 90 days)"
                    ResourceName = $snapshot.Name
                    Location = $snapshot.Location
                    Size = "$($snapshot.DiskSizeGB) GB"
                    Status = "Created: $($snapshot.TimeCreated.ToString('yyyy-MM-dd'))"
                    MonthlyCost = $cost
                    AnnualCost = $cost * 12
                    Recommendation = "Delete old snapshot if backup not needed"
                }
                Write-Log "    Found old snapshot: $($snapshot.Name) - $cost/month" "SAVINGS"
            }
        }
    }
    catch {
        Write-Log "  Error checking Snapshots: $($_.Exception.Message)" "WARNING"
    }
    
    # 7. EMPTY RESOURCE GROUPS
    Write-Log "  Checking Empty Resource Groups..." "INFO"
    try {
        $resourceGroups = Get-AzResourceGroup -ErrorAction SilentlyContinue
        foreach ($rg in $resourceGroups) {
            $resources = Get-AzResource -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
            if ($resources.Count -eq 0) {
                $allIdleResources += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    ResourceGroup = $rg.ResourceGroupName
                    ResourceType = "Resource Group (Empty)"
                    ResourceName = $rg.ResourceGroupName
                    Location = $rg.Location
                    Size = "N/A"
                    Status = "Empty - 0 resources"
                    MonthlyCost = 0
                    AnnualCost = 0
                    Recommendation = "Delete empty resource group"
                }
                Write-Log "    Found empty RG: $($rg.ResourceGroupName)" "SAVINGS"
            }
        }
    }
    catch {
        Write-Log "  Error checking Resource Groups: $($_.Exception.Message)" "WARNING"
    }
}

# Calculate totals
$totalMonthlySavings = ($allIdleResources | Measure-Object -Property MonthlyCost -Sum).Sum
$totalAnnualSavings = $totalMonthlySavings * 12
$totalResources = $allIdleResources.Count

# Group by type for summary
$byType = $allIdleResources | Group-Object -Property ResourceType | Select-Object Name, Count, @{N='MonthlyCost';E={($_.Group | Measure-Object -Property MonthlyCost -Sum).Sum}}

# Export CSV
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$csvPath = Join-Path $OutputPath "Idle-Resources-Report_$timestamp.csv"
$allIdleResources | Export-Csv -Path $csvPath -NoTypeInformation

# Generate HTML Report
$htmlPath = Join-Path $OutputPath "Idle-Resources-Report_$timestamp.html"

$typeRows = ""
foreach ($type in $byType) {
    $typeRows += "<tr><td>$($type.Name)</td><td>$($type.Count)</td><td>`$$([math]::Round($type.MonthlyCost, 2))</td><td>`$$([math]::Round($type.MonthlyCost * 12, 2))</td></tr>"
}

$detailRows = ""
foreach ($resource in $allIdleResources) {
    $detailRows += "<tr><td>$($resource.ResourceName)</td><td>$($resource.ResourceType)</td><td>$($resource.SubscriptionName)</td><td>$($resource.ResourceGroup)</td><td>$($resource.Status)</td><td>`$$($resource.MonthlyCost)</td><td>`$$($resource.AnnualCost)</td><td>$($resource.Recommendation)</td></tr>"
}

$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>Azure Idle Resources Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 1400px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #d83b01; border-bottom: 3px solid #d83b01; padding-bottom: 10px; }
        h2 { color: #333; margin-top: 30px; }
        .summary { display: flex; gap: 20px; margin: 30px 0; flex-wrap: wrap; }
        .card { flex: 1; min-width: 200px; padding: 20px; border-radius: 8px; text-align: center; }
        .card.savings { background: linear-gradient(135deg, #107c10, #0b5c0b); color: white; }
        .card.resources { background: linear-gradient(135deg, #d83b01, #a62c01); color: white; }
        .card.subs { background: linear-gradient(135deg, #0078d4, #005a9e); color: white; }
        .card h2 { margin: 0; font-size: 2.5em; color: white; border: none; }
        .card p { margin: 10px 0 0 0; opacity: 0.9; }
        table { width: 100%; border-collapse: collapse; margin-top: 20px; }
        th { background: #0078d4; color: white; padding: 12px; text-align: left; }
        td { padding: 10px; border-bottom: 1px solid #ddd; }
        tr:hover { background: #f0f8ff; }
        .type-table th { background: #d83b01; }
        .footer { margin-top: 30px; text-align: center; color: #666; font-size: 0.9em; }
        .warning { background: #fff4ce; border-left: 4px solid #d83b01; padding: 15px; margin: 20px 0; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Azure Idle Resources Audit Report</h1>
        <p>Generated: $(Get-Date -Format "MMMM dd, yyyy HH:mm:ss")</p>
        <p>Mode: <span style="color:#d83b01;font-weight:bold;">AUDIT ONLY - No changes made</span></p>
        
        <div class="summary">
            <div class="card savings">
                <h2>`$$([math]::Round($totalMonthlySavings, 2))</h2>
                <p>Monthly Savings</p>
            </div>
            <div class="card savings">
                <h2>`$$([math]::Round($totalAnnualSavings, 2))</h2>
                <p>Annual Savings</p>
            </div>
            <div class="card resources">
                <h2>$totalResources</h2>
                <p>Idle Resources Found</p>
            </div>
            <div class="card subs">
                <h2>$($subscriptions.Count)</h2>
                <p>Subscriptions Scanned</p>
            </div>
        </div>
        
        <div class="warning">
            <strong>Action Required:</strong> Review each resource before deletion. Some resources may be intentionally stopped or reserved for future use.
        </div>
        
        <h2>Summary by Resource Type</h2>
        <table class="type-table">
            <tr>
                <th>Resource Type</th>
                <th>Count</th>
                <th>Monthly Cost</th>
                <th>Annual Cost</th>
            </tr>
            $typeRows
        </table>
        
        <h2>All Idle Resources</h2>
        <table>
            <tr>
                <th>Resource Name</th>
                <th>Type</th>
                <th>Subscription</th>
                <th>Resource Group</th>
                <th>Status</th>
                <th>Monthly</th>
                <th>Annual</th>
                <th>Recommendation</th>
            </tr>
            $detailRows
        </table>
        
        <div class="footer">
            <p>Azure Idle Resources Audit | Infrastructure Team</p>
        </div>
    </div>
</body>
</html>
"@

$htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  IDLE RESOURCES AUDIT COMPLETE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Subscriptions Scanned:  $($subscriptions.Count)" -ForegroundColor White
Write-Host "  Idle Resources Found:   $totalResources" -ForegroundColor Red
Write-Host ""
Write-Host "  MONTHLY SAVINGS:        `$$([math]::Round($totalMonthlySavings, 2))" -ForegroundColor Cyan
Write-Host "  ANNUAL SAVINGS:         `$$([math]::Round($totalAnnualSavings, 2))" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Reports saved to:" -ForegroundColor White
Write-Host "    CSV:  $csvPath" -ForegroundColor Gray
Write-Host "    HTML: $htmlPath" -ForegroundColor Gray
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan

Start-Process $htmlPath

Write-Host ""
Write-Log "Report opened in browser!" "SUCCESS"
