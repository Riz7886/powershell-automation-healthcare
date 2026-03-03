param(
    [Parameter(Mandatory=$false)]
    [switch]$AutoStop,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "$env:TEMP"
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportFile = Join-Path $OutputPath "VM_Quota_Analysis_$timestamp.html"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Red
Write-Host "  EMERGENCY: VM QUOTA ANALYSIS" -ForegroundColor Red
Write-Host "  Finding VMs to stop and free quota for Databricks" -ForegroundColor Red
Write-Host "============================================================" -ForegroundColor Red
Write-Host ""

$modules = @('Az.Accounts', 'Az.Compute')
foreach ($mod in $modules) {
    if (!(Get-Module -ListAvailable -Name $mod)) {
        Write-Host "Installing $mod..." -ForegroundColor Yellow
        Install-Module -Name $mod -Force -AllowClobber -Scope CurrentUser -ErrorAction SilentlyContinue
    }
    Import-Module $mod -ErrorAction SilentlyContinue
}

Write-Host "Connecting to Azure..." -ForegroundColor Yellow
try {
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount | Out-Null
        $context = Get-AzContext
    }
    Write-Host "Connected: $($context.Account.Id)" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Cannot connect to Azure" -ForegroundColor Red
    exit
}

Write-Host ""
Write-Host "Scanning ALL VMs across subscriptions..." -ForegroundColor Yellow
Write-Host ""

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
$allVMs = @()
$totalCoresUsed = 0
$totalCoresCanFree = 0

foreach ($sub in $subscriptions) {
    Write-Host "Subscription: $($sub.Name)" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    
    $vms = Get-AzVM -Status
    
    foreach ($vm in $vms) {
        $vmSize = $vm.HardwareProfile.VmSize
        $powerState = ($vm.PowerState -split ' ')[1]
        
        $cores = switch -Regex ($vmSize) {
            'D2' { 2 }
            'D3' { 4 }
            'D4' { 8 }
            'D8' { 8 }
            'D11' { 2 }
            'D12' { 4 }
            'D13' { 8 }
            'D14' { 16 }
            'D16' { 16 }
            'D32' { 32 }
            'D48' { 48 }
            'D64' { 64 }
            'DS2' { 2 }
            'DS3' { 4 }
            'DS4' { 8 }
            'DS11' { 2 }
            'DS12' { 4 }
            'DS13' { 8 }
            'DS14' { 16 }
            default { 0 }
        }
        
        if ($powerState -eq 'running') {
            $totalCoresUsed += $cores
        }
        
        $tags = $vm.Tags
        $isDatabricks = $false
        $isProduction = $false
        $canStop = $false
        
        if ($tags) {
            if ($tags.Keys -contains 'Databricks' -or $vm.ResourceGroupName -like '*databricks*') {
                $isDatabricks = $true
            }
            if ($tags.Keys -contains 'Environment' -and $tags['Environment'] -like '*prod*') {
                $isProduction = $true
            }
        }
        
        if ($powerState -eq 'running' -and -not $isDatabricks -and -not $isProduction) {
            $canStop = $true
            $totalCoresCanFree += $cores
        }
        
        $allVMs += [PSCustomObject]@{
            Subscription = $sub.Name
            ResourceGroup = $vm.ResourceGroupName
            VMName = $vm.Name
            Size = $vmSize
            Cores = $cores
            PowerState = $powerState
            IsDatabricks = $isDatabricks
            IsProduction = $isProduction
            CanStop = $canStop
            Location = $vm.Location
        }
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host "  QUOTA ANALYSIS RESULTS" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "Total VMs found: $($allVMs.Count)" -ForegroundColor White
Write-Host "Total cores in use: $totalCoresUsed" -ForegroundColor White
Write-Host "Cores that can be freed: $totalCoresCanFree" -ForegroundColor Green
Write-Host ""

$stoppableVMs = $allVMs | Where-Object { $_.CanStop -eq $true }

if ($stoppableVMs.Count -gt 0) {
    Write-Host "VMs that can be stopped to free quota:" -ForegroundColor Green
    Write-Host ""
    
    foreach ($vm in $stoppableVMs) {
        Write-Host "  - $($vm.VMName) ($($vm.Size) - $($vm.Cores) cores)" -ForegroundColor White
    }
    
    Write-Host ""
    
    if ($AutoStop) {
        Write-Host "AUTO-STOP MODE: Stopping non-production VMs..." -ForegroundColor Red
        Write-Host ""
        
        foreach ($vm in $stoppableVMs) {
            Write-Host "Stopping: $($vm.VMName)..." -ForegroundColor Yellow
            
            Set-AzContext -SubscriptionId ($subscriptions | Where-Object { $_.Name -eq $vm.Subscription }).Id | Out-Null
            
            try {
                Stop-AzVM -ResourceGroupName $vm.ResourceGroup -Name $vm.VMName -Force -NoWait
                Write-Host "  Stopped: $($vm.VMName) (freed $($vm.Cores) cores)" -ForegroundColor Green
            } catch {
                Write-Host "  ERROR stopping $($vm.VMName): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        
        Write-Host ""
        Write-Host "VMs are stopping in background. Wait 2-3 minutes for quota to free up." -ForegroundColor Green
    } else {
        Write-Host "DRY RUN MODE - No VMs stopped" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "To automatically stop these VMs and free $totalCoresCanFree cores:" -ForegroundColor Cyan
        Write-Host "  Run: .\Emergency-Free-Quota.ps1 -AutoStop" -ForegroundColor White
    }
} else {
    Write-Host "NO VMs found that can be safely stopped!" -ForegroundColor Red
    Write-Host ""
    Write-Host "All running VMs are either:" -ForegroundColor Yellow
    Write-Host "  - Databricks infrastructure" -ForegroundColor White
    Write-Host "  - Production resources" -ForegroundColor White
    Write-Host ""
    Write-Host "RECOMMENDATION: Request quota increase from Microsoft" -ForegroundColor Red
}

Write-Host ""

$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Emergency VM Quota Analysis</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); }
        .container { background: white; padding: 30px; border-radius: 10px; max-width: 1200px; margin: 0 auto; }
        h1 { color: #333; border-bottom: 3px solid #dc3545; padding-bottom: 10px; }
        .emergency { background: #f8d7da; border-left: 5px solid #dc3545; padding: 20px; margin: 20px 0; }
        .success { background: #d4edda; border-left: 5px solid #28a745; padding: 20px; margin: 20px 0; }
        .summary { background: #667eea; color: white; padding: 20px; border-radius: 8px; margin: 20px 0; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 12px; text-align: left; }
        td { padding: 10px; border-bottom: 1px solid #ddd; }
        .can-stop { background: #d4edda; }
        .cannot-stop { background: #fff3cd; }
    </style>
</head>
<body>
    <div class="container">
        <h1>EMERGENCY: VM Quota Analysis</h1>
        <p><strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        
        <div class="emergency">
            <h2>CRITICAL ISSUE: Databricks Clusters Won't Start</h2>
            <p><strong>Root Cause:</strong> Azure quota exhausted in West US 2</p>
            <p><strong>Impact:</strong> Databricks compute clusters stuck in "Starting" state</p>
        </div>
        
        <div class="summary">
            <h2>Quota Summary</h2>
            <p><strong>Total VMs:</strong> $($allVMs.Count)</p>
            <p><strong>Total Cores Used:</strong> $totalCoresUsed</p>
            <p><strong>Cores That Can Be Freed:</strong> $totalCoresCanFree</p>
            <p><strong>VMs That Can Be Stopped:</strong> $($stoppableVMs.Count)</p>
        </div>
        
        <h2>All VMs Analyzed</h2>
        <table>
            <tr>
                <th>VM Name</th>
                <th>Size</th>
                <th>Cores</th>
                <th>State</th>
                <th>Can Stop?</th>
                <th>Reason</th>
            </tr>
"@

foreach ($vm in $allVMs | Sort-Object -Property CanStop -Descending) {
    $rowClass = if ($vm.CanStop) { "can-stop" } else { "cannot-stop" }
    $canStopText = if ($vm.CanStop) { "YES" } else { "NO" }
    
    $reason = if ($vm.IsDatabricks) { "Databricks infrastructure" } 
              elseif ($vm.IsProduction) { "Production resource" }
              elseif ($vm.PowerState -ne 'running') { "Already stopped" }
              else { "Can be stopped safely" }
    
    $html += @"
            <tr class="$rowClass">
                <td>$($vm.VMName)</td>
                <td>$($vm.Size)</td>
                <td>$($vm.Cores)</td>
                <td>$($vm.PowerState)</td>
                <td><strong>$canStopText</strong></td>
                <td>$reason</td>
            </tr>
"@
}

$html += @"
        </table>
        
        <div class="success">
            <h3>Recommended Actions</h3>
            <ol>
                <li><strong>Immediate:</strong> Stop $($stoppableVMs.Count) non-production VMs to free $totalCoresCanFree cores</li>
                <li><strong>Short-term:</strong> Request quota increase from Microsoft (2-5 days)</li>
                <li><strong>Long-term:</strong> Migrate to region with available quota (East US recommended)</li>
            </ol>
        </div>
        
        <p><strong>Analyst:</strong> Syed Rizvi | <strong>Report:</strong> Emergency Quota Analysis</p>
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host "Report saved: $reportFile" -ForegroundColor Green
Write-Host "Opening report..." -ForegroundColor Cyan

Start-Process $reportFile
