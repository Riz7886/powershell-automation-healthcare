<#
.SYNOPSIS
    SQL Database DTU Manager - Scans ALL Subscriptions
    Author: Syed Rizvi
    Version: 2.1

.DESCRIPTION
    Scans ALL Azure subscriptions and finds ALL SQL databases.
    - Change DTU tier on any database
    - Delete unused databases (with 60-day archive)
    - Interactive prompts for each action

.EXAMPLE
    .\SQL_Database_DTU_Manager_v2.ps1
#>

param(
    [string]$OutputPath = ".",
    [string]$ArchivePath = "C:\SQL_Archives"
)

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Join-Path $OutputPath "SQL_Manager_Log_$timestamp.txt"

function Write-Log {
    param($Message, $Color = "White")
    $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Message"
    Add-Content -Path $logPath -Value $logEntry -ErrorAction SilentlyContinue
    Write-Host $Message -ForegroundColor $Color
}

function Get-TierCost {
    param($TierName)
    $costs = @{
        "Basic"=5; "S0"=15; "S1"=30; "S2"=75; "S3"=150; "S4"=300
        "S6"=600; "S7"=1200; "S9"=2400; "S12"=4800
        "P1"=465; "P2"=930; "P4"=1860; "P6"=3720; "P11"=7440; "P15"=14880
        "GP_Gen5_2"=200; "GP_Gen5_4"=400; "GP_Gen5_8"=800; "GP_Gen5_16"=1600
        "BC_Gen5_2"=500; "BC_Gen5_4"=1000; "BC_Gen5_8"=2000
    }
    if ($costs.ContainsKey($TierName)) { return $costs[$TierName] } else { return 100 }
}

function Show-TierMenu {
    Write-Host ""
    Write-Host "Available DTU Tiers:" -ForegroundColor Cyan
    Write-Host "  [1]  Basic  -   5 DTU  -   `$5/mo" -ForegroundColor White
    Write-Host "  [2]  S0     -  10 DTU  -  `$15/mo" -ForegroundColor White
    Write-Host "  [3]  S1     -  20 DTU  -  `$30/mo" -ForegroundColor White
    Write-Host "  [4]  S2     -  50 DTU  -  `$75/mo" -ForegroundColor White
    Write-Host "  [5]  S3     - 100 DTU  - `$150/mo" -ForegroundColor White
    Write-Host "  [6]  S4     - 200 DTU  - `$300/mo" -ForegroundColor White
    Write-Host "  [7]  S6     - 400 DTU  - `$600/mo" -ForegroundColor White
    Write-Host "  [8]  S7     - 800 DTU  - `$1200/mo" -ForegroundColor White
    Write-Host "  [9]  S9     - 1600 DTU - `$2400/mo" -ForegroundColor White
    Write-Host "  [10] S12    - 3000 DTU - `$4800/mo" -ForegroundColor White
    Write-Host ""
}

function Get-TierFromSelection {
    param($Selection)
    $map = @{"1"="Basic";"2"="S0";"3"="S1";"4"="S2";"5"="S3";"6"="S4";"7"="S6";"8"="S7";"9"="S9";"10"="S12"}
    return $map[$Selection]
}

Clear-Host
Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "       SQL DATABASE DTU MANAGER v2.1" -ForegroundColor Green
Write-Host "       Author: Syed Rizvi" -ForegroundColor Gray
Write-Host "       SCANS ALL SUBSCRIPTIONS" -ForegroundColor Yellow
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $ArchivePath)) {
    New-Item -ItemType Directory -Path $ArchivePath -Force | Out-Null
}

Write-Host "[STEP 1] Loading Azure modules..." -ForegroundColor Yellow
try {
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Sql -ErrorAction Stop
    Import-Module Az.Monitor -ErrorAction Stop
    Write-Host "         Modules loaded" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Run: Install-Module -Name Az -Force" -ForegroundColor Red
    exit
}

Write-Host ""
Write-Host "[STEP 2] Connecting to Azure..." -ForegroundColor Yellow
try {
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount | Out-Null
    }
    Write-Host "         Connected" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to connect" -ForegroundColor Red
    exit
}

Write-Host ""
Write-Host "[STEP 3] Getting ALL subscriptions..." -ForegroundColor Yellow
$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
Write-Host "         Found $($subscriptions.Count) subscription(s)" -ForegroundColor Green

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "       SCANNING ALL $($subscriptions.Count) SUBSCRIPTIONS" -ForegroundColor Yellow
Write-Host "=============================================================" -ForegroundColor Cyan

$allDatabases = @()
$dbIndex = 0
$subCount = 0
$totalServers = 0

foreach ($sub in $subscriptions) {
    $subCount++
    Write-Host ""
    Write-Host "[$subCount/$($subscriptions.Count)] Subscription: $($sub.Name)" -ForegroundColor Cyan
    
    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "         Skipping - Cannot access" -ForegroundColor Yellow
        continue
    }
    
    $servers = Get-AzSqlServer -ErrorAction SilentlyContinue
    
    if (-not $servers -or $servers.Count -eq 0) {
        Write-Host "         No SQL servers found" -ForegroundColor Gray
        continue
    }
    
    $totalServers += $servers.Count
    Write-Host "         Found $($servers.Count) SQL server(s)" -ForegroundColor Green
    
    foreach ($server in $servers) {
        $serverName = $server.ServerName
        $resourceGroup = $server.ResourceGroupName
        
        Write-Host "           Server: $serverName" -ForegroundColor Gray
        
        $databases = Get-AzSqlDatabase -ServerName $serverName -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue | 
                     Where-Object { $_.DatabaseName -ne "master" }
        
        if (-not $databases) { continue }
        
        foreach ($db in $databases) {
            $dbIndex++
            
            $endTime = Get-Date
            $startTime = $endTime.AddDays(-14)
            
            try {
                $dtuMetric = Get-AzMetric -WarningAction SilentlyContinue -ResourceId $db.ResourceId -MetricName "dtu_consumption_percent" -StartTime $startTime -EndTime $endTime -TimeGrain (New-TimeSpan -Hours 1) -AggregationType Average -ErrorAction SilentlyContinue
                $connectionMetric = Get-AzMetric -WarningAction SilentlyContinue -ResourceId $db.ResourceId -MetricName "connection_successful" -StartTime $startTime -EndTime $endTime -TimeGrain (New-TimeSpan -Hours 1) -AggregationType Total -ErrorAction SilentlyContinue
            } catch {
                $dtuMetric = $null
                $connectionMetric = $null
            }
            
            $dtuData = if ($dtuMetric -and $dtuMetric.Data) { $dtuMetric.Data.Average | Where-Object { $null -ne $_ } } else { @() }
            $connectionData = if ($connectionMetric -and $connectionMetric.Data) { $connectionMetric.Data.Total | Where-Object { $null -ne $_ } } else { @() }
            
            $avgDTU = if ($dtuData.Count -gt 0) { [math]::Round(($dtuData | Measure-Object -Average).Average, 1) } else { 0 }
            $maxDTU = if ($dtuData.Count -gt 0) { [math]::Round(($dtuData | Measure-Object -Maximum).Maximum, 1) } else { 0 }
            $totalConnections = if ($connectionData.Count -gt 0) { [math]::Round(($connectionData | Measure-Object -Sum).Sum, 0) } else { 0 }
            
            $currentCost = Get-TierCost -TierName $db.SkuName
            
            $status = "Active"
            if ($totalConnections -eq 0) { $status = "IDLE" }
            elseif ($avgDTU -lt 5) { $status = "Very Low" }
            elseif ($avgDTU -lt 20) { $status = "Low" }
            elseif ($avgDTU -gt 80) { $status = "High" }
            
            $recommendedTier = $db.SkuName
            $recommendedCost = $currentCost
            
            if ($avgDTU -lt 10 -and $maxDTU -lt 25) {
                $recommendedTier = "Basic"
                $recommendedCost = 5
            } elseif ($avgDTU -lt 20 -and $maxDTU -lt 40) {
                $recommendedTier = "S0"
                $recommendedCost = 15
            } elseif ($avgDTU -lt 40 -and $maxDTU -lt 60) {
                $recommendedTier = "S1"
                $recommendedCost = 30
            }
            
            $savings = $currentCost - $recommendedCost
            if ($savings -lt 0) { $savings = 0; $recommendedTier = $db.SkuName; $recommendedCost = $currentCost }
            
            $allDatabases += [PSCustomObject]@{
                Index = $dbIndex
                Subscription = $sub.Name
                SubscriptionId = $sub.Id
                ServerName = $serverName
                ResourceGroup = $resourceGroup
                DatabaseName = $db.DatabaseName
                CurrentTier = $db.SkuName
                AvgDTU = $avgDTU
                MaxDTU = $maxDTU
                Connections = $totalConnections
                MonthlyCost = $currentCost
                RecommendedTier = $recommendedTier
                RecommendedCost = $recommendedCost
                MonthlySavings = $savings
                AnnualSavings = $savings * 12
                Status = $status
                ResourceId = $db.ResourceId
            }
            
            Write-Host "             [$dbIndex] $($db.DatabaseName) - $($db.SkuName) - `$$currentCost/mo - $status" -ForegroundColor $(if ($status -eq "IDLE") { "Red" } elseif ($savings -gt 0) { "Yellow" } else { "Gray" })
        }
    }
}

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "                 SCAN COMPLETE!" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Subscriptions Scanned:  $($subscriptions.Count)" -ForegroundColor White
Write-Host "  SQL Servers Found:      $totalServers" -ForegroundColor White
Write-Host "  Databases Found:        $($allDatabases.Count)" -ForegroundColor Green
Write-Host ""

$totalCurrentCost = ($allDatabases | Measure-Object -Property MonthlyCost -Sum).Sum
$totalSavings = ($allDatabases | Measure-Object -Property MonthlySavings -Sum).Sum
$idleDbs = ($allDatabases | Where-Object { $_.Status -eq "IDLE" }).Count
$idleCost = ($allDatabases | Where-Object { $_.Status -eq "IDLE" } | Measure-Object -Property MonthlyCost -Sum).Sum

Write-Host "  Current Monthly Cost:   `$$totalCurrentCost" -ForegroundColor Red
Write-Host "  Potential Monthly Savings: `$$totalSavings" -ForegroundColor Green
Write-Host "  Potential Annual Savings:  `$$($totalSavings * 12)" -ForegroundColor Green -BackgroundColor Black
Write-Host ""
Write-Host "  IDLE Databases:         $idleDbs (wasting `$$idleCost/month)" -ForegroundColor Yellow
Write-Host ""

function Show-DatabaseList {
    Write-Host ""
    Write-Host ("{0,-4} {1,-25} {2,-20} {3,-20} {4,-8} {5,-8} {6,-10} {7,-10} {8,-10} {9,-8}" -f "#", "Subscription", "Server", "Database", "Tier", "AvgDTU", "Connects", "Cost", "Savings", "Status") -ForegroundColor Yellow
    Write-Host ("-" * 140) -ForegroundColor Gray
    
    foreach ($db in $allDatabases | Sort-Object -Property MonthlySavings -Descending) {
        $color = "White"
        if ($db.Status -eq "IDLE") { $color = "Red" }
        elseif ($db.MonthlySavings -gt 100) { $color = "Yellow" }
        elseif ($db.MonthlySavings -gt 0) { $color = "Cyan" }
        
        $subShort = if ($db.Subscription.Length -gt 24) { $db.Subscription.Substring(0,24) } else { $db.Subscription }
        $srvShort = if ($db.ServerName.Length -gt 19) { $db.ServerName.Substring(0,19) } else { $db.ServerName }
        $dbShort = if ($db.DatabaseName.Length -gt 19) { $db.DatabaseName.Substring(0,19) } else { $db.DatabaseName }
        
        Write-Host ("{0,-4} {1,-25} {2,-20} {3,-20} {4,-8} {5,-8} {6,-10} `${7,-9} `${8,-9} {9,-8}" -f $db.Index, $subShort, $srvShort, $dbShort, $db.CurrentTier, "$($db.AvgDTU)%", $db.Connections, $db.MonthlyCost, $db.MonthlySavings, $db.Status) -ForegroundColor $color
    }
    Write-Host ""
}

function Show-MainMenu {
    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host "                      MAIN MENU" -ForegroundColor Green
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] View All Databases (sorted by savings)" -ForegroundColor White
    Write-Host "  [2] View IDLE Databases Only" -ForegroundColor Yellow
    Write-Host "  [3] Change DTU Tier on a Database" -ForegroundColor White
    Write-Host "  [4] Delete a Database (Archive 60 Days)" -ForegroundColor Red
    Write-Host "  [5] Bulk - Apply ALL Recommended Tier Changes" -ForegroundColor White
    Write-Host "  [6] Bulk - Delete ALL IDLE Databases" -ForegroundColor Red
    Write-Host "  [7] Generate HTML Report" -ForegroundColor White
    Write-Host "  [8] Export to CSV" -ForegroundColor White
    Write-Host "  [Q] Quit" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Total: $($allDatabases.Count) DBs | Cost: `$$totalCurrentCost/mo | Savings: `$$totalSavings/mo" -ForegroundColor Cyan
    Write-Host ""
}

function Change-DatabaseTier {
    Show-DatabaseList
    
    $dbNum = Read-Host "Enter database number to change (0 to cancel)"
    if ($dbNum -eq "0") { return }
    
    $selectedDb = $allDatabases | Where-Object { $_.Index -eq [int]$dbNum }
    if (-not $selectedDb) {
        Write-Host "Invalid selection" -ForegroundColor Red
        return
    }
    
    Write-Host ""
    Write-Host "Selected: $($selectedDb.DatabaseName)" -ForegroundColor Cyan
    Write-Host "Server: $($selectedDb.ServerName)" -ForegroundColor Gray
    Write-Host "Subscription: $($selectedDb.Subscription)" -ForegroundColor Gray
    Write-Host "Current: $($selectedDb.CurrentTier) (`$$($selectedDb.MonthlyCost)/mo)" -ForegroundColor Yellow
    Write-Host "Recommended: $($selectedDb.RecommendedTier) (`$$($selectedDb.RecommendedCost)/mo)" -ForegroundColor Green
    
    Show-TierMenu
    
    $tierChoice = Read-Host "Select new tier (1-10) or 0 to cancel"
    if ($tierChoice -eq "0") { return }
    
    $newTier = Get-TierFromSelection -Selection $tierChoice
    if (-not $newTier) {
        Write-Host "Invalid tier" -ForegroundColor Red
        return
    }
    
    $newCost = Get-TierCost -TierName $newTier
    
    Write-Host ""
    Write-Host "Change $($selectedDb.DatabaseName): $($selectedDb.CurrentTier) -> $newTier" -ForegroundColor Yellow
    Write-Host "Cost: `$$($selectedDb.MonthlyCost) -> `$$newCost/month" -ForegroundColor Yellow
    Write-Host ""
    
    $confirm = Read-Host "Apply change? (Y/N)"
    if ($confirm -ne "Y" -and $confirm -ne "y") { return }
    
    try {
        Set-AzContext -SubscriptionId $selectedDb.SubscriptionId | Out-Null
        Set-AzSqlDatabase -ResourceGroupName $selectedDb.ResourceGroup -ServerName $selectedDb.ServerName -DatabaseName $selectedDb.DatabaseName -RequestedServiceObjectiveName $newTier -ErrorAction Stop | Out-Null
        Write-Log "SUCCESS: $($selectedDb.DatabaseName) changed to $newTier" "Green"
        Write-Host "Done!" -ForegroundColor Green
    }
    catch {
        Write-Log "FAILED: $($selectedDb.DatabaseName) - $_" "Red"
        Write-Host "Failed: $_" -ForegroundColor Red
    }
}

function Delete-Database {
    $idleDbsList = $allDatabases | Where-Object { $_.Status -eq "IDLE" }
    
    if ($idleDbsList.Count -eq 0) {
        Write-Host "No IDLE databases found" -ForegroundColor Green
        return
    }
    
    Write-Host ""
    Write-Host "IDLE DATABASES:" -ForegroundColor Red
    foreach ($db in $idleDbsList) {
        Write-Host "  [$($db.Index)] $($db.Subscription) / $($db.ServerName) / $($db.DatabaseName) - `$$($db.MonthlyCost)/mo" -ForegroundColor Yellow
    }
    Write-Host ""
    
    $dbNum = Read-Host "Enter database number to DELETE (0 to cancel)"
    if ($dbNum -eq "0") { return }
    
    $selectedDb = $allDatabases | Where-Object { $_.Index -eq [int]$dbNum }
    if (-not $selectedDb) {
        Write-Host "Invalid selection" -ForegroundColor Red
        return
    }
    
    Write-Host ""
    Write-Host "DELETE: $($selectedDb.DatabaseName)" -ForegroundColor Red
    Write-Host "Server: $($selectedDb.ServerName)" -ForegroundColor White
    Write-Host "Cost: `$$($selectedDb.MonthlyCost)/month" -ForegroundColor White
    Write-Host ""
    
    $confirm = Read-Host "Type 'DELETE' to confirm"
    if ($confirm -ne "DELETE") {
        Write-Host "Cancelled" -ForegroundColor Yellow
        return
    }
    
    try {
        $archiveInfo = Join-Path $ArchivePath "$($selectedDb.DatabaseName)_$timestamp.txt"
        "Database: $($selectedDb.DatabaseName)`nServer: $($selectedDb.ServerName)`nSubscription: $($selectedDb.Subscription)`nDeleted: $(Get-Date)`nExpires: $((Get-Date).AddDays(60))`nTier: $($selectedDb.CurrentTier)`nCost: $($selectedDb.MonthlyCost)" | Out-File $archiveInfo
        
        Set-AzContext -SubscriptionId $selectedDb.SubscriptionId | Out-Null
        Remove-AzSqlDatabase -ResourceGroupName $selectedDb.ResourceGroup -ServerName $selectedDb.ServerName -DatabaseName $selectedDb.DatabaseName -Force -ErrorAction Stop | Out-Null
        
        Write-Log "DELETED: $($selectedDb.DatabaseName)" "Green"
        Write-Host "Deleted! Archive: $archiveInfo" -ForegroundColor Green
    }
    catch {
        Write-Log "FAILED: $($selectedDb.DatabaseName) - $_" "Red"
        Write-Host "Failed: $_" -ForegroundColor Red
    }
}

function Bulk-ApplyRecommendations {
    $toChange = $allDatabases | Where-Object { $_.MonthlySavings -gt 0 }
    
    if ($toChange.Count -eq 0) {
        Write-Host "No optimization opportunities found" -ForegroundColor Green
        return
    }
    
    Write-Host ""
    Write-Host "RECOMMENDED CHANGES:" -ForegroundColor Yellow
    $bulkSavings = 0
    foreach ($db in $toChange) {
        $bulkSavings += $db.MonthlySavings
        Write-Host "  $($db.DatabaseName): $($db.CurrentTier) -> $($db.RecommendedTier) (Save `$$($db.MonthlySavings)/mo)" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "Total Monthly Savings: `$$bulkSavings" -ForegroundColor Green
    Write-Host "Total Annual Savings: `$$($bulkSavings * 12)" -ForegroundColor Green
    Write-Host ""
    
    $confirm = Read-Host "Apply ALL changes? (Y/N)"
    if ($confirm -ne "Y" -and $confirm -ne "y") { return }
    
    foreach ($db in $toChange) {
        try {
            Write-Host "  Changing $($db.DatabaseName)..." -ForegroundColor Yellow
            Set-AzContext -SubscriptionId $db.SubscriptionId | Out-Null
            Set-AzSqlDatabase -ResourceGroupName $db.ResourceGroup -ServerName $db.ServerName -DatabaseName $db.DatabaseName -RequestedServiceObjectiveName $db.RecommendedTier -ErrorAction Stop | Out-Null
            Write-Log "SUCCESS: $($db.DatabaseName) -> $($db.RecommendedTier)" "Green"
            Write-Host "    Done" -ForegroundColor Green
        }
        catch {
            Write-Log "FAILED: $($db.DatabaseName) - $_" "Red"
            Write-Host "    Failed" -ForegroundColor Red
        }
    }
}

function Bulk-DeleteIdle {
    $idleDbsList = $allDatabases | Where-Object { $_.Status -eq "IDLE" }
    
    if ($idleDbsList.Count -eq 0) {
        Write-Host "No IDLE databases" -ForegroundColor Green
        return
    }
    
    $idleCostCalc = ($idleDbsList | Measure-Object -Property MonthlyCost -Sum).Sum
    
    Write-Host ""
    Write-Host "IDLE DATABASES TO DELETE: $($idleDbsList.Count)" -ForegroundColor Red
    Write-Host "Total Savings: `$$idleCostCalc/month (`$$($idleCostCalc * 12)/year)" -ForegroundColor Green
    Write-Host ""
    
    foreach ($db in $idleDbsList) {
        Write-Host "  $($db.Subscription) / $($db.DatabaseName) - `$$($db.MonthlyCost)/mo" -ForegroundColor Yellow
    }
    Write-Host ""
    
    $confirm = Read-Host "Type 'DELETE ALL' to delete all idle databases"
    if ($confirm -ne "DELETE ALL") {
        Write-Host "Cancelled" -ForegroundColor Yellow
        return
    }
    
    foreach ($db in $idleDbsList) {
        try {
            $archiveInfo = Join-Path $ArchivePath "$($db.DatabaseName)_$timestamp.txt"
            "Database: $($db.DatabaseName)`nServer: $($db.ServerName)`nDeleted: $(Get-Date)`nCost: $($db.MonthlyCost)" | Out-File $archiveInfo
            
            Set-AzContext -SubscriptionId $db.SubscriptionId | Out-Null
            Remove-AzSqlDatabase -ResourceGroupName $db.ResourceGroup -ServerName $db.ServerName -DatabaseName $db.DatabaseName -Force -ErrorAction Stop | Out-Null
            Write-Log "DELETED: $($db.DatabaseName)" "Green"
            Write-Host "  Deleted: $($db.DatabaseName)" -ForegroundColor Green
        }
        catch {
            Write-Host "  Failed: $($db.DatabaseName)" -ForegroundColor Red
        }
    }
}

function Generate-Report {
    $reportFile = Join-Path $OutputPath "SQL_DTU_Report_$timestamp.html"
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>SQL Database DTU Report</title>
    <style>
        body { font-family: Segoe UI, Arial; margin: 20px; background: #f5f5f5; }
        .header { background: linear-gradient(135deg, #d13438 0%, #ff8c00 100%); color: white; padding: 30px; margin-bottom: 20px; }
        .summary { background: white; padding: 20px; margin-bottom: 20px; }
        .metric { display: inline-block; margin: 10px 20px; padding: 15px; background: #f8f9fa; text-align: center; }
        .metric-value { font-size: 32px; font-weight: bold; }
        .savings { color: #107c10; }
        .waste { color: #d13438; }
        table { width: 100%; border-collapse: collapse; background: white; font-size: 12px; }
        th { background: #2c3e50; color: white; padding: 10px; text-align: left; }
        td { padding: 8px; border-bottom: 1px solid #ddd; }
        .idle { background: #fde7e9; }
        .high-savings { background: #fff4ce; }
    </style>
</head>
<body>
    <div class="header">
        <h1>SQL DATABASE DTU AUDIT REPORT</h1>
        <p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        <p>Author: Syed Rizvi</p>
    </div>
    
    <div class="summary">
        <h2>Executive Summary</h2>
        <div class="metric">
            <div>Subscriptions</div>
            <div class="metric-value">$($subscriptions.Count)</div>
        </div>
        <div class="metric">
            <div>Databases</div>
            <div class="metric-value">$($allDatabases.Count)</div>
        </div>
        <div class="metric">
            <div>Monthly Cost</div>
            <div class="metric-value waste">`$$totalCurrentCost</div>
        </div>
        <div class="metric">
            <div>Monthly Savings</div>
            <div class="metric-value savings">`$$totalSavings</div>
        </div>
        <div class="metric">
            <div>Annual Savings</div>
            <div class="metric-value savings">`$$($totalSavings * 12)</div>
        </div>
        <div class="metric">
            <div>IDLE Databases</div>
            <div class="metric-value waste">$idleDbs</div>
        </div>
    </div>
    
    <div class="summary">
        <h2>All Databases</h2>
        <table>
            <tr>
                <th>Subscription</th>
                <th>Server</th>
                <th>Database</th>
                <th>Current Tier</th>
                <th>Avg DTU</th>
                <th>Max DTU</th>
                <th>Connections</th>
                <th>Current Cost</th>
                <th>Recommended</th>
                <th>Monthly Savings</th>
                <th>Annual Savings</th>
                <th>Status</th>
            </tr>
"@

    foreach ($db in $allDatabases | Sort-Object -Property MonthlySavings -Descending) {
        $rowClass = ""
        if ($db.Status -eq "IDLE") { $rowClass = "idle" }
        elseif ($db.MonthlySavings -gt 100) { $rowClass = "high-savings" }
        
        $html += "<tr class='$rowClass'><td>$($db.Subscription)</td><td>$($db.ServerName)</td><td>$($db.DatabaseName)</td><td>$($db.CurrentTier)</td><td>$($db.AvgDTU)%</td><td>$($db.MaxDTU)%</td><td>$($db.Connections)</td><td>`$$($db.MonthlyCost)</td><td>$($db.RecommendedTier)</td><td>`$$($db.MonthlySavings)</td><td>`$$($db.AnnualSavings)</td><td>$($db.Status)</td></tr>"
    }

    $html += "</table></div></body></html>"
    $html | Out-File -FilePath $reportFile -Encoding UTF8
    
    Write-Host "Report saved: $reportFile" -ForegroundColor Green
    Start-Process $reportFile
}

function Export-CSV {
    $csvFile = Join-Path $OutputPath "SQL_DTU_Data_$timestamp.csv"
    $allDatabases | Export-Csv -Path $csvFile -NoTypeInformation
    Write-Host "CSV saved: $csvFile" -ForegroundColor Green
}

do {
    Show-MainMenu
    $choice = Read-Host "Select option"
    
    switch ($choice) {
        "1" { Show-DatabaseList; Read-Host "Press Enter" }
        "2" { 
            $idle = $allDatabases | Where-Object { $_.Status -eq "IDLE" }
            Write-Host "`nIDLE DATABASES ($($idle.Count)):" -ForegroundColor Red
            foreach ($db in $idle) {
                Write-Host "  [$($db.Index)] $($db.Subscription) / $($db.DatabaseName) - `$$($db.MonthlyCost)/mo" -ForegroundColor Yellow
            }
            Read-Host "`nPress Enter"
        }
        "3" { Change-DatabaseTier }
        "4" { Delete-Database }
        "5" { Bulk-ApplyRecommendations }
        "6" { Bulk-DeleteIdle }
        "7" { Generate-Report }
        "8" { Export-CSV }
        "Q" { break }
        "q" { break }
    }
} while ($choice -notin @("Q", "q"))

Write-Host "`nLog: $logPath" -ForegroundColor Gray
Write-Host "Goodbye!" -ForegroundColor Cyan
