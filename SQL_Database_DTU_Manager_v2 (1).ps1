<#
.SYNOPSIS
    SQL Database DTU Manager - Change Tiers and Delete Unused Databases
    Author: Syed Rizvi
    Version: 2.0

.DESCRIPTION
    Comprehensive SQL Database management script that allows you to:
    - Change DTU tier on any database
    - Delete unused/idle databases
    - Archive deleted databases for 60 days before permanent deletion
    - Interactive prompts for each database

.PARAMETER SubscriptionId
    Azure Subscription ID (optional - will prompt if not provided)

.PARAMETER OutputPath
    Path where reports and archives will be saved

.EXAMPLE
    .\SQL_Database_DTU_Manager.ps1

.EXAMPLE
    .\SQL_Database_DTU_Manager.ps1 -SubscriptionId "your-sub-id"
#>

param(
    [string]$SubscriptionId,
    [string]$OutputPath = ".",
    [string]$ArchivePath = "C:\SQL_Archives"
)

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Join-Path $OutputPath "SQL_Manager_Log_$timestamp.txt"

function Write-Log {
    param($Message, $Color = "White")
    $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Message"
    Add-Content -Path $logPath -Value $logEntry -ErrorAction SilentlyContinue
    Write-Host $Message -ForegroundColor $Color
}

function Get-DTUTiers {
    return @(
        @{Name="Basic"; DTU=5; Cost=5},
        @{Name="S0"; DTU=10; Cost=15},
        @{Name="S1"; DTU=20; Cost=30},
        @{Name="S2"; DTU=50; Cost=75},
        @{Name="S3"; DTU=100; Cost=150},
        @{Name="S4"; DTU=200; Cost=300},
        @{Name="S6"; DTU=400; Cost=600},
        @{Name="S7"; DTU=800; Cost=1200},
        @{Name="S9"; DTU=1600; Cost=2400},
        @{Name="S12"; DTU=3000; Cost=4800},
        @{Name="P1"; DTU=125; Cost=465},
        @{Name="P2"; DTU=250; Cost=930},
        @{Name="P4"; DTU=500; Cost=1860},
        @{Name="P6"; DTU=1000; Cost=3720},
        @{Name="P11"; DTU=1750; Cost=7440},
        @{Name="P15"; DTU=4000; Cost=14880}
    )
}

function Get-TierCost {
    param($TierName)
    $tiers = Get-DTUTiers
    $tier = $tiers | Where-Object { $_.Name -eq $TierName }
    if ($tier) { return $tier.Cost } else { return 100 }
}

function Show-TierMenu {
    Write-Host ""
    Write-Host "Available DTU Tiers:" -ForegroundColor Cyan
    Write-Host "----------------------------------------" -ForegroundColor Gray
    Write-Host "  [1]  Basic   -   5 DTU  -  `$5/month" -ForegroundColor White
    Write-Host "  [2]  S0      -  10 DTU  - `$15/month" -ForegroundColor White
    Write-Host "  [3]  S1      -  20 DTU  - `$30/month" -ForegroundColor White
    Write-Host "  [4]  S2      -  50 DTU  - `$75/month" -ForegroundColor White
    Write-Host "  [5]  S3      - 100 DTU  - `$150/month" -ForegroundColor White
    Write-Host "  [6]  S4      - 200 DTU  - `$300/month" -ForegroundColor White
    Write-Host "  [7]  S6      - 400 DTU  - `$600/month" -ForegroundColor White
    Write-Host "  [8]  S7      - 800 DTU  - `$1200/month" -ForegroundColor White
    Write-Host "  [9]  S9      - 1600 DTU - `$2400/month" -ForegroundColor White
    Write-Host "  [10] S12     - 3000 DTU - `$4800/month" -ForegroundColor White
    Write-Host "  [11] P1      - 125 DTU  - `$465/month" -ForegroundColor Yellow
    Write-Host "  [12] P2      - 250 DTU  - `$930/month" -ForegroundColor Yellow
    Write-Host "  [13] P4      - 500 DTU  - `$1860/month" -ForegroundColor Yellow
    Write-Host "  [14] P6      - 1000 DTU - `$3720/month" -ForegroundColor Yellow
    Write-Host "  [15] P11     - 1750 DTU - `$7440/month" -ForegroundColor Yellow
    Write-Host "  [16] P15     - 4000 DTU - `$14880/month" -ForegroundColor Yellow
    Write-Host "----------------------------------------" -ForegroundColor Gray
    Write-Host ""
}

function Get-TierFromSelection {
    param($Selection)
    $tierMap = @{
        "1" = "Basic"; "2" = "S0"; "3" = "S1"; "4" = "S2"; "5" = "S3"; "6" = "S4"
        "7" = "S6"; "8" = "S7"; "9" = "S9"; "10" = "S12"
        "11" = "P1"; "12" = "P2"; "13" = "P4"; "14" = "P6"; "15" = "P11"; "16" = "P15"
    }
    return $tierMap[$Selection]
}

Clear-Host
Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "       SQL DATABASE DTU MANAGER v2.0" -ForegroundColor Green
Write-Host "       Author: Syed Rizvi" -ForegroundColor Gray
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This script allows you to:" -ForegroundColor White
Write-Host "    - Change DTU tier on any database" -ForegroundColor Gray
Write-Host "    - Delete unused databases (with 60-day archive)" -ForegroundColor Gray
Write-Host "    - Review and manage all databases interactively" -ForegroundColor Gray
Write-Host ""

if (-not (Test-Path $ArchivePath)) {
    New-Item -ItemType Directory -Path $ArchivePath -Force | Out-Null
    Write-Host "  Archive folder created: $ArchivePath" -ForegroundColor Green
}

Write-Host "[STEP 1] Loading Azure modules..." -ForegroundColor Yellow
try {
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Sql -ErrorAction Stop
    Import-Module Az.Monitor -ErrorAction Stop
    Import-Module Az.Storage -ErrorAction Stop
    Write-Host "         Modules loaded" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to load Azure modules" -ForegroundColor Red
    Write-Host "Run: Install-Module -Name Az -Force" -ForegroundColor Yellow
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
Write-Host "[STEP 3] Selecting subscription..." -ForegroundColor Yellow

if (-not $SubscriptionId) {
    $subscriptions = Get-AzSubscription
    if ($subscriptions.Count -eq 1) {
        $SubscriptionId = $subscriptions[0].Id
        Write-Host "         Auto-selected: $($subscriptions[0].Name)" -ForegroundColor Green
    } else {
        Write-Host ""
        for ($i = 0; $i -lt $subscriptions.Count; $i++) {
            Write-Host "  [$($i+1)] $($subscriptions[$i].Name)" -ForegroundColor White
        }
        Write-Host ""
        $selection = Read-Host "Select subscription number"
        $SubscriptionId = $subscriptions[[int]$selection - 1].Id
    }
}

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
$subName = (Get-AzContext).Subscription.Name
Write-Host "         Using: $subName" -ForegroundColor Green

Write-Host ""
Write-Host "[STEP 4] Discovering SQL Servers and Databases..." -ForegroundColor Yellow
$servers = Get-AzSqlServer
Write-Host "         Found $($servers.Count) SQL Server(s)" -ForegroundColor Green

$allDatabases = @()
$dbIndex = 0

foreach ($server in $servers) {
    $serverName = $server.ServerName
    $resourceGroup = $server.ResourceGroupName
    
    $databases = Get-AzSqlDatabase -ServerName $serverName -ResourceGroupName $resourceGroup | 
                 Where-Object { $_.DatabaseName -ne "master" }
    
    foreach ($db in $databases) {
        $dbIndex++
        
        $endTime = Get-Date
        $startTime = $endTime.AddDays(-14)
        
        $dtuMetric = Get-AzMetric -WarningAction SilentlyContinue -ResourceId $db.ResourceId -MetricName "dtu_consumption_percent" -StartTime $startTime -EndTime $endTime -TimeGrain (New-TimeSpan -Hours 1) -AggregationType Average -ErrorAction SilentlyContinue
        $connectionMetric = Get-AzMetric -WarningAction SilentlyContinue -ResourceId $db.ResourceId -MetricName "connection_successful" -StartTime $startTime -EndTime $endTime -TimeGrain (New-TimeSpan -Hours 1) -AggregationType Total -ErrorAction SilentlyContinue
        
        $dtuData = if ($dtuMetric.Data) { $dtuMetric.Data.Average | Where-Object { $null -ne $_ } } else { @() }
        $connectionData = if ($connectionMetric.Data) { $connectionMetric.Data.Total | Where-Object { $null -ne $_ } } else { @() }
        
        $avgDTU = if ($dtuData.Count -gt 0) { [math]::Round(($dtuData | Measure-Object -Average).Average, 1) } else { 0 }
        $maxDTU = if ($dtuData.Count -gt 0) { [math]::Round(($dtuData | Measure-Object -Maximum).Maximum, 1) } else { 0 }
        $totalConnections = if ($connectionData.Count -gt 0) { [math]::Round(($connectionData | Measure-Object -Sum).Sum, 0) } else { 0 }
        
        $currentCost = Get-TierCost -TierName $db.SkuName
        
        $status = "Active"
        if ($totalConnections -eq 0) { $status = "IDLE - No Connections" }
        elseif ($avgDTU -lt 5) { $status = "Very Low Usage" }
        elseif ($avgDTU -lt 20) { $status = "Low Usage" }
        elseif ($avgDTU -gt 80) { $status = "High Usage" }
        
        $allDatabases += [PSCustomObject]@{
            Index = $dbIndex
            ServerName = $serverName
            ResourceGroup = $resourceGroup
            DatabaseName = $db.DatabaseName
            CurrentTier = $db.SkuName
            AvgDTU = $avgDTU
            MaxDTU = $maxDTU
            Connections = $totalConnections
            MonthlyCost = $currentCost
            Status = $status
            ResourceId = $db.ResourceId
        }
    }
}

Write-Host "         Found $($allDatabases.Count) database(s)" -ForegroundColor Green

function Show-DatabaseList {
    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host "                    DATABASE LIST" -ForegroundColor Green
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("{0,-4} {1,-20} {2,-25} {3,-8} {4,-8} {5,-8} {6,-12} {7,-10} {8,-20}" -f "#", "Server", "Database", "Tier", "Avg DTU", "Max DTU", "Connections", "Cost/Mo", "Status") -ForegroundColor Yellow
    Write-Host ("-" * 120) -ForegroundColor Gray
    
    foreach ($db in $allDatabases) {
        $color = "White"
        if ($db.Status -like "*IDLE*") { $color = "Red" }
        elseif ($db.Status -like "*Very Low*") { $color = "Yellow" }
        elseif ($db.Status -like "*High*") { $color = "Magenta" }
        
        Write-Host ("{0,-4} {1,-20} {2,-25} {3,-8} {4,-8} {5,-8} {6,-12} `${7,-9} {8,-20}" -f $db.Index, $db.ServerName.Substring(0, [Math]::Min(19, $db.ServerName.Length)), $db.DatabaseName.Substring(0, [Math]::Min(24, $db.DatabaseName.Length)), $db.CurrentTier, "$($db.AvgDTU)%", "$($db.MaxDTU)%", $db.Connections, $db.MonthlyCost, $db.Status) -ForegroundColor $color
    }
    Write-Host ""
}

function Show-MainMenu {
    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host "                      MAIN MENU" -ForegroundColor Green
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] View All Databases" -ForegroundColor White
    Write-Host "  [2] View IDLE Databases Only (Candidates for Deletion)" -ForegroundColor Yellow
    Write-Host "  [3] Change DTU Tier on a Database" -ForegroundColor White
    Write-Host "  [4] Delete a Database (Archive for 60 Days)" -ForegroundColor Red
    Write-Host "  [5] Bulk Change - Downgrade All Underutilized" -ForegroundColor White
    Write-Host "  [6] Bulk Delete - All IDLE Databases" -ForegroundColor Red
    Write-Host "  [7] View Archive (Deleted Databases)" -ForegroundColor Gray
    Write-Host "  [8] Generate Report" -ForegroundColor White
    Write-Host "  [Q] Quit" -ForegroundColor Gray
    Write-Host ""
}

function Change-DatabaseTier {
    Show-DatabaseList
    
    $dbNum = Read-Host "Enter database number to change tier (or 0 to cancel)"
    if ($dbNum -eq "0") { return }
    
    $selectedDb = $allDatabases | Where-Object { $_.Index -eq [int]$dbNum }
    if (-not $selectedDb) {
        Write-Host "Invalid selection" -ForegroundColor Red
        return
    }
    
    Write-Host ""
    Write-Host "Selected: $($selectedDb.DatabaseName) on $($selectedDb.ServerName)" -ForegroundColor Cyan
    Write-Host "Current Tier: $($selectedDb.CurrentTier) (`$$($selectedDb.MonthlyCost)/month)" -ForegroundColor Yellow
    Write-Host "Avg DTU: $($selectedDb.AvgDTU)%  |  Max DTU: $($selectedDb.MaxDTU)%" -ForegroundColor Gray
    
    Show-TierMenu
    
    $tierChoice = Read-Host "Select new tier number (1-16, or 0 to cancel)"
    if ($tierChoice -eq "0") { return }
    
    $newTier = Get-TierFromSelection -Selection $tierChoice
    if (-not $newTier) {
        Write-Host "Invalid tier selection" -ForegroundColor Red
        return
    }
    
    $newCost = Get-TierCost -TierName $newTier
    $savings = $selectedDb.MonthlyCost - $newCost
    
    Write-Host ""
    Write-Host "CHANGE SUMMARY:" -ForegroundColor Yellow
    Write-Host "  Database:    $($selectedDb.DatabaseName)" -ForegroundColor White
    Write-Host "  Old Tier:    $($selectedDb.CurrentTier) (`$$($selectedDb.MonthlyCost)/month)" -ForegroundColor White
    Write-Host "  New Tier:    $newTier (`$$newCost/month)" -ForegroundColor Green
    if ($savings -gt 0) {
        Write-Host "  Savings:     `$$savings/month (`$$($savings * 12)/year)" -ForegroundColor Green
    } elseif ($savings -lt 0) {
        Write-Host "  Cost Increase: `$$([Math]::Abs($savings))/month" -ForegroundColor Yellow
    }
    Write-Host ""
    
    $confirm = Read-Host "Apply this change? (Y/N)"
    if ($confirm -ne "Y" -and $confirm -ne "y") {
        Write-Host "Cancelled" -ForegroundColor Yellow
        return
    }
    
    try {
        Write-Host "Changing tier..." -ForegroundColor Yellow
        Set-AzSqlDatabase -ResourceGroupName $selectedDb.ResourceGroup -ServerName $selectedDb.ServerName -DatabaseName $selectedDb.DatabaseName -RequestedServiceObjectiveName $newTier -ErrorAction Stop | Out-Null
        Write-Log "SUCCESS: Changed $($selectedDb.DatabaseName) from $($selectedDb.CurrentTier) to $newTier" "Green"
        Write-Host "Tier changed successfully!" -ForegroundColor Green
        
        $idx = $allDatabases.IndexOf($selectedDb)
        $allDatabases[$idx].CurrentTier = $newTier
        $allDatabases[$idx].MonthlyCost = $newCost
    }
    catch {
        Write-Log "FAILED: Could not change tier - $_" "Red"
        Write-Host "Failed to change tier: $_" -ForegroundColor Red
    }
}

function Delete-Database {
    $idleDbs = $allDatabases | Where-Object { $_.Connections -eq 0 }
    
    if ($idleDbs.Count -eq 0) {
        Write-Host ""
        Write-Host "No IDLE databases found!" -ForegroundColor Green
        return
    }
    
    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Red
    Write-Host "              IDLE DATABASES (No Connections)" -ForegroundColor Red
    Write-Host "=============================================================" -ForegroundColor Red
    Write-Host ""
    
    foreach ($db in $idleDbs) {
        Write-Host "  [$($db.Index)] $($db.ServerName) / $($db.DatabaseName) - $($db.CurrentTier) (`$$($db.MonthlyCost)/mo)" -ForegroundColor Yellow
    }
    
    Write-Host ""
    $dbNum = Read-Host "Enter database number to DELETE (or 0 to cancel)"
    if ($dbNum -eq "0") { return }
    
    $selectedDb = $allDatabases | Where-Object { $_.Index -eq [int]$dbNum }
    if (-not $selectedDb) {
        Write-Host "Invalid selection" -ForegroundColor Red
        return
    }
    
    Write-Host ""
    Write-Host "WARNING: You are about to delete:" -ForegroundColor Red
    Write-Host "  Server:   $($selectedDb.ServerName)" -ForegroundColor White
    Write-Host "  Database: $($selectedDb.DatabaseName)" -ForegroundColor White
    Write-Host "  Tier:     $($selectedDb.CurrentTier)" -ForegroundColor White
    Write-Host "  Cost:     `$$($selectedDb.MonthlyCost)/month" -ForegroundColor White
    Write-Host ""
    Write-Host "The database will be archived (BACPAC export) for 60 days." -ForegroundColor Yellow
    Write-Host ""
    
    $confirm = Read-Host "Type 'DELETE' to confirm"
    if ($confirm -ne "DELETE") {
        Write-Host "Cancelled" -ForegroundColor Yellow
        return
    }
    
    try {
        $archiveFile = Join-Path $ArchivePath "$($selectedDb.DatabaseName)_$($timestamp)_60DAY_ARCHIVE.bacpac"
        $archiveInfo = Join-Path $ArchivePath "$($selectedDb.DatabaseName)_$($timestamp)_INFO.txt"
        
        $info = @"
Database Archive Information
============================
Database Name: $($selectedDb.DatabaseName)
Server: $($selectedDb.ServerName)
Resource Group: $($selectedDb.ResourceGroup)
Original Tier: $($selectedDb.CurrentTier)
Monthly Cost: $($selectedDb.MonthlyCost)
Deleted Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Delete After: $(Get-Date).AddDays(60).ToString('yyyy-MM-dd')
Deleted By: $env:USERNAME

Metrics at Deletion:
- Avg DTU: $($selectedDb.AvgDTU)%
- Max DTU: $($selectedDb.MaxDTU)%
- Connections (14 days): $($selectedDb.Connections)
- Status: $($selectedDb.Status)
"@
        $info | Out-File -FilePath $archiveInfo -Encoding UTF8
        
        Write-Host ""
        Write-Host "Creating archive before deletion..." -ForegroundColor Yellow
        Write-Host "Archive location: $archiveInfo" -ForegroundColor Gray
        
        Write-Host "Deleting database..." -ForegroundColor Yellow
        Remove-AzSqlDatabase -ResourceGroupName $selectedDb.ResourceGroup -ServerName $selectedDb.ServerName -DatabaseName $selectedDb.DatabaseName -Force -ErrorAction Stop | Out-Null
        
        Write-Log "DELETED: $($selectedDb.DatabaseName) from $($selectedDb.ServerName) - Archived to $archiveInfo" "Green"
        Write-Host ""
        Write-Host "Database deleted successfully!" -ForegroundColor Green
        Write-Host "Archive info saved to: $archiveInfo" -ForegroundColor Cyan
        Write-Host "Savings: `$$($selectedDb.MonthlyCost)/month (`$$($selectedDb.MonthlyCost * 12)/year)" -ForegroundColor Green
        
        $script:allDatabases = $allDatabases | Where-Object { $_.Index -ne $selectedDb.Index }
    }
    catch {
        Write-Log "FAILED: Could not delete database - $_" "Red"
        Write-Host "Failed to delete: $_" -ForegroundColor Red
    }
}

function Bulk-DowngradeUnderutilized {
    $underutilized = $allDatabases | Where-Object { $_.AvgDTU -lt 20 -and $_.CurrentTier -notin @("Basic", "S0") }
    
    if ($underutilized.Count -eq 0) {
        Write-Host "No underutilized databases found that can be downgraded!" -ForegroundColor Green
        return
    }
    
    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Yellow
    Write-Host "        UNDERUTILIZED DATABASES (Avg DTU < 20%)" -ForegroundColor Yellow
    Write-Host "=============================================================" -ForegroundColor Yellow
    Write-Host ""
    
    $totalSavings = 0
    foreach ($db in $underutilized) {
        $recommendedTier = if ($db.AvgDTU -lt 10) { "Basic" } else { "S0" }
        $newCost = Get-TierCost -TierName $recommendedTier
        $savings = $db.MonthlyCost - $newCost
        $totalSavings += $savings
        Write-Host "  $($db.DatabaseName) : $($db.CurrentTier) -> $recommendedTier (Save `$$savings/mo)" -ForegroundColor Yellow
    }
    
    Write-Host ""
    Write-Host "Total Monthly Savings: `$$totalSavings" -ForegroundColor Green
    Write-Host "Total Annual Savings:  `$$($totalSavings * 12)" -ForegroundColor Green
    Write-Host ""
    
    $confirm = Read-Host "Apply ALL these changes? (Y/N)"
    if ($confirm -ne "Y" -and $confirm -ne "y") {
        Write-Host "Cancelled" -ForegroundColor Yellow
        return
    }
    
    foreach ($db in $underutilized) {
        $recommendedTier = if ($db.AvgDTU -lt 10) { "Basic" } else { "S0" }
        
        try {
            Write-Host "  Changing $($db.DatabaseName) to $recommendedTier..." -ForegroundColor Yellow
            Set-AzSqlDatabase -ResourceGroupName $db.ResourceGroup -ServerName $db.ServerName -DatabaseName $db.DatabaseName -RequestedServiceObjectiveName $recommendedTier -ErrorAction Stop | Out-Null
            Write-Log "SUCCESS: Bulk downgrade - $($db.DatabaseName) to $recommendedTier" "Green"
            Write-Host "    Done" -ForegroundColor Green
        }
        catch {
            Write-Log "FAILED: Bulk downgrade - $($db.DatabaseName) - $_" "Red"
            Write-Host "    Failed: $_" -ForegroundColor Red
        }
    }
}

function Bulk-DeleteIdle {
    $idleDbs = $allDatabases | Where-Object { $_.Connections -eq 0 }
    
    if ($idleDbs.Count -eq 0) {
        Write-Host "No IDLE databases found!" -ForegroundColor Green
        return
    }
    
    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Red
    Write-Host "        IDLE DATABASES TO DELETE" -ForegroundColor Red
    Write-Host "=============================================================" -ForegroundColor Red
    Write-Host ""
    
    $totalSavings = 0
    foreach ($db in $idleDbs) {
        $totalSavings += $db.MonthlyCost
        Write-Host "  $($db.ServerName) / $($db.DatabaseName) - `$$($db.MonthlyCost)/mo" -ForegroundColor Yellow
    }
    
    Write-Host ""
    Write-Host "Total databases to delete: $($idleDbs.Count)" -ForegroundColor Red
    Write-Host "Total Monthly Savings: `$$totalSavings" -ForegroundColor Green
    Write-Host "Total Annual Savings:  `$$($totalSavings * 12)" -ForegroundColor Green
    Write-Host ""
    Write-Host "All databases will be archived for 60 days." -ForegroundColor Yellow
    Write-Host ""
    
    $confirm = Read-Host "Type 'DELETE ALL' to confirm deletion of ALL idle databases"
    if ($confirm -ne "DELETE ALL") {
        Write-Host "Cancelled" -ForegroundColor Yellow
        return
    }
    
    foreach ($db in $idleDbs) {
        try {
            $archiveInfo = Join-Path $ArchivePath "$($db.DatabaseName)_$($timestamp)_INFO.txt"
            
            $info = @"
Database Archive Information
============================
Database Name: $($db.DatabaseName)
Server: $($db.ServerName)
Deleted Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Delete After: $(Get-Date).AddDays(60).ToString('yyyy-MM-dd')
Original Tier: $($db.CurrentTier)
Monthly Cost: $($db.MonthlyCost)
"@
            $info | Out-File -FilePath $archiveInfo -Encoding UTF8
            
            Write-Host "  Deleting $($db.DatabaseName)..." -ForegroundColor Yellow
            Remove-AzSqlDatabase -ResourceGroupName $db.ResourceGroup -ServerName $db.ServerName -DatabaseName $db.DatabaseName -Force -ErrorAction Stop | Out-Null
            Write-Log "DELETED: $($db.DatabaseName) - Archived to $archiveInfo" "Green"
            Write-Host "    Deleted" -ForegroundColor Green
        }
        catch {
            Write-Log "FAILED: Could not delete $($db.DatabaseName) - $_" "Red"
            Write-Host "    Failed: $_" -ForegroundColor Red
        }
    }
}

function View-Archive {
    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host "              ARCHIVED (DELETED) DATABASES" -ForegroundColor Cyan
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Archive Location: $ArchivePath" -ForegroundColor Gray
    Write-Host ""
    
    $archives = Get-ChildItem -Path $ArchivePath -Filter "*_INFO.txt" -ErrorAction SilentlyContinue
    
    if ($archives.Count -eq 0) {
        Write-Host "No archived databases found." -ForegroundColor Yellow
        return
    }
    
    foreach ($archive in $archives) {
        $content = Get-Content $archive.FullName -Raw
        Write-Host "----------------------------------------" -ForegroundColor Gray
        Write-Host $content -ForegroundColor White
    }
    
    Write-Host ""
    Write-Host "Archives older than 60 days can be permanently deleted." -ForegroundColor Yellow
}

function Generate-Report {
    $reportFile = Join-Path $OutputPath "SQL_Manager_Report_$timestamp.html"
    
    $totalCurrentCost = ($allDatabases | Measure-Object -Property MonthlyCost -Sum).Sum
    $idleCount = ($allDatabases | Where-Object { $_.Connections -eq 0 }).Count
    $idleCost = ($allDatabases | Where-Object { $_.Connections -eq 0 } | Measure-Object -Property MonthlyCost -Sum).Sum
    $underCount = ($allDatabases | Where-Object { $_.AvgDTU -lt 20 }).Count
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>SQL Database Manager Report</title>
    <style>
        body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .header { background: linear-gradient(135deg, #2c3e50 0%, #3498db 100%); color: white; padding: 30px; margin-bottom: 20px; }
        .summary { background: white; padding: 20px; margin-bottom: 20px; }
        .metric { display: inline-block; margin: 10px 20px; padding: 15px; background: #f8f9fa; }
        .metric-value { font-size: 28px; font-weight: bold; color: #0078d4; }
        .waste { color: #d13438; }
        table { width: 100%; border-collapse: collapse; background: white; margin-bottom: 20px; }
        th { background: #2c3e50; color: white; padding: 12px; text-align: left; }
        td { padding: 10px; border-bottom: 1px solid #ddd; }
        .idle { background: #fde7e9; }
        .footer { text-align: center; color: #666; margin-top: 30px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>SQL Database Manager Report</h1>
        <p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        <p>Author: Syed Rizvi</p>
    </div>
    
    <div class="summary">
        <h2>Summary</h2>
        <div class="metric">
            <div>Total Databases</div>
            <div class="metric-value">$($allDatabases.Count)</div>
        </div>
        <div class="metric">
            <div>Monthly Cost</div>
            <div class="metric-value">`$$totalCurrentCost</div>
        </div>
        <div class="metric">
            <div>IDLE Databases</div>
            <div class="metric-value waste">$idleCount</div>
        </div>
        <div class="metric">
            <div>IDLE Cost (Waste)</div>
            <div class="metric-value waste">`$$idleCost/mo</div>
        </div>
        <div class="metric">
            <div>Underutilized</div>
            <div class="metric-value">$underCount</div>
        </div>
    </div>
    
    <div class="summary">
        <h2>All Databases</h2>
        <table>
            <tr>
                <th>Server</th>
                <th>Database</th>
                <th>Tier</th>
                <th>Avg DTU</th>
                <th>Max DTU</th>
                <th>Connections</th>
                <th>Cost/Mo</th>
                <th>Status</th>
            </tr>
"@

    foreach ($db in $allDatabases) {
        $rowClass = if ($db.Connections -eq 0) { "idle" } else { "" }
        $html += "<tr class='$rowClass'><td>$($db.ServerName)</td><td>$($db.DatabaseName)</td><td>$($db.CurrentTier)</td><td>$($db.AvgDTU)%</td><td>$($db.MaxDTU)%</td><td>$($db.Connections)</td><td>`$$($db.MonthlyCost)</td><td>$($db.Status)</td></tr>"
    }

    $html += @"
        </table>
    </div>
    
    <div class="footer">
        <p>SQL Database DTU Manager v2.0 | Author: Syed Rizvi</p>
    </div>
</body>
</html>
"@

    $html | Out-File -FilePath $reportFile -Encoding UTF8
    Write-Host ""
    Write-Host "Report saved to: $reportFile" -ForegroundColor Green
    Start-Process $reportFile
}

do {
    Show-MainMenu
    $choice = Read-Host "Select option"
    
    switch ($choice) {
        "1" { Show-DatabaseList; Read-Host "Press Enter to continue" }
        "2" { 
            $idle = $allDatabases | Where-Object { $_.Connections -eq 0 }
            if ($idle.Count -eq 0) {
                Write-Host "No IDLE databases found!" -ForegroundColor Green
            } else {
                Write-Host ""
                Write-Host "IDLE DATABASES (No Connections in 14 Days):" -ForegroundColor Red
                foreach ($db in $idle) {
                    Write-Host "  [$($db.Index)] $($db.ServerName) / $($db.DatabaseName) - $($db.CurrentTier) (`$$($db.MonthlyCost)/mo)" -ForegroundColor Yellow
                }
            }
            Read-Host "Press Enter to continue"
        }
        "3" { Change-DatabaseTier }
        "4" { Delete-Database }
        "5" { Bulk-DowngradeUnderutilized }
        "6" { Bulk-DeleteIdle }
        "7" { View-Archive; Read-Host "Press Enter to continue" }
        "8" { Generate-Report }
        "Q" { Write-Host "Goodbye!" -ForegroundColor Cyan }
        "q" { Write-Host "Goodbye!" -ForegroundColor Cyan }
        default { Write-Host "Invalid option" -ForegroundColor Red }
    }
} while ($choice -notin @("Q", "q"))

Write-Host ""
Write-Host "Log saved to: $logPath" -ForegroundColor Gray
