<#
.SYNOPSIS
    Azure SQL Database Health & Audit Report
.DESCRIPTION
    Scans all Azure SQL Databases across subscriptions and generates a comprehensive 
    report including: status, DTU/size usage, last activity, idle time, and connection tests.
.NOTES
    Prerequisites:
      - Az PowerShell module (Install-Module Az -Force)
      - Logged in via Connect-AzAccount
      - Appropriate RBAC: Reader on subscriptions + db-level access for connection tests
    
    Usage:
      .\AzureSQLDatabaseAudit.ps1
      .\AzureSQLDatabaseAudit.ps1 -SubscriptionId "xxxx-xxxx" -SkipConnectionTest
      .\AzureSQLDatabaseAudit.ps1 -ExportPath "C:\Reports" -IdleThresholdDays 30
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = ".",

    [Parameter(Mandatory = $false)]
    [int]$IdleThresholdDays = 14,

    [Parameter(Mandatory = $false)]
    [switch]$SkipConnectionTest,

    [Parameter(Mandatory = $false)]
    [string]$ConnectionTestUsername,

    [Parameter(Mandatory = $false)]
    [SecureString]$ConnectionTestPassword
)

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportName = "AzureSQL_Audit_Report_$timestamp"
$csvPath = Join-Path $ExportPath "$reportName.csv"
$htmlPath = Join-Path $ExportPath "$reportName.html"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Status {
    param([string]$Message, [string]$Level = "Info")
    $color = switch ($Level) {
        "Info"    { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        default   { "White" }
    }
    $prefix = switch ($Level) {
        "Info"    { "[*]" }
        "Success" { "[+]" }
        "Warning" { "[!]" }
        "Error"   { "[-]" }
        default   { "[.]" }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Test-DatabaseConnection {
    param(
        [string]$ServerFQDN,
        [string]$DatabaseName,
        [string]$Username,
        [SecureString]$Password
    )

    $result = @{
        CanConnect    = $false
        ResponseTimeMs = $null
        ErrorMessage  = $null
    }

    try {
        $credential = New-Object System.Management.Automation.PSCredential($Username, $Password)
        $plainPassword = $credential.GetNetworkCredential().Password

        $connectionString = "Server=tcp:$ServerFQDN,1433;Initial Catalog=$DatabaseName;Persist Security Info=False;User ID=$Username;Password=$plainPassword;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=10;"
        
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        
        $connection.Open()
        $stopwatch.Stop()

        $result.CanConnect = $true
        $result.ResponseTimeMs = $stopwatch.ElapsedMilliseconds

        $connection.Close()
        $connection.Dispose()
    }
    catch {
        $result.ErrorMessage = $_.Exception.Message
    }

    return $result
}

function Get-DatabaseMetrics {
    param(
        [string]$ResourceGroupName,
        [string]$ServerName,
        [string]$DatabaseName,
        [int]$LookbackDays = 30
    )

    $metrics = @{
        AvgDtuPercent    = $null
        MaxDtuPercent    = $null
        AvgSizePercent   = $null
        CurrentSizeMB    = $null
        MaxSizeMB        = $null
        LastActiveTime   = $null
        IdleDays         = $null
        ConnectionCount  = $null
    }

    try {
        $endTime = Get-Date
        $startTime = $endTime.AddDays(-$LookbackDays)
        $resourceId = (Get-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $DatabaseName).ResourceId

        # DTU percentage (or CPU percent for vCore)
        $dtuMetric = Get-AzMetric -ResourceId $resourceId `
            -MetricName "dtu_consumption_percent" `
            -StartTime $startTime `
            -EndTime $endTime `
            -TimeGrain 01:00:00 `
            -AggregationType Average `
            -ErrorAction SilentlyContinue

        if ($dtuMetric -and $dtuMetric.Data) {
            $validData = $dtuMetric.Data | Where-Object { $null -ne $_.Average }
            if ($validData) {
                $metrics.AvgDtuPercent = [math]::Round(($validData | Measure-Object -Property Average -Average).Average, 2)
                $metrics.MaxDtuPercent = [math]::Round(($validData | Measure-Object -Property Average -Maximum).Maximum, 2)
            }
        }

        # If DTU metric is empty, try CPU percent (vCore model)
        if ($null -eq $metrics.AvgDtuPercent) {
            $cpuMetric = Get-AzMetric -ResourceId $resourceId `
                -MetricName "cpu_percent" `
                -StartTime $startTime `
                -EndTime $endTime `
                -TimeGrain 01:00:00 `
                -AggregationType Average `
                -ErrorAction SilentlyContinue

            if ($cpuMetric -and $cpuMetric.Data) {
                $validData = $cpuMetric.Data | Where-Object { $null -ne $_.Average }
                if ($validData) {
                    $metrics.AvgDtuPercent = [math]::Round(($validData | Measure-Object -Property Average -Average).Average, 2)
                    $metrics.MaxDtuPercent = [math]::Round(($validData | Measure-Object -Property Average -Maximum).Maximum, 2)
                }
            }
        }

        # Storage usage
        $storageMetric = Get-AzMetric -ResourceId $resourceId `
            -MetricName "storage_percent" `
            -StartTime $endTime.AddDays(-1) `
            -EndTime $endTime `
            -TimeGrain 01:00:00 `
            -AggregationType Maximum `
            -ErrorAction SilentlyContinue

        if ($storageMetric -and $storageMetric.Data) {
            $validData = $storageMetric.Data | Where-Object { $null -ne $_.Maximum }
            if ($validData) {
                $metrics.AvgSizePercent = [math]::Round(($validData | Measure-Object -Property Maximum -Maximum).Maximum, 2)
            }
        }

        # Storage size in bytes
        $storageSizeMetric = Get-AzMetric -ResourceId $resourceId `
            -MetricName "storage" `
            -StartTime $endTime.AddDays(-1) `
            -EndTime $endTime `
            -TimeGrain 01:00:00 `
            -AggregationType Maximum `
            -ErrorAction SilentlyContinue

        if ($storageSizeMetric -and $storageSizeMetric.Data) {
            $validData = $storageSizeMetric.Data | Where-Object { $null -ne $_.Maximum }
            if ($validData) {
                $metrics.CurrentSizeMB = [math]::Round(($validData | Measure-Object -Property Maximum -Maximum).Maximum / 1MB, 2)
            }
        }

        # Connection count (to determine activity)
        $connMetric = Get-AzMetric -ResourceId $resourceId `
            -MetricName "connection_successful" `
            -StartTime $startTime `
            -EndTime $endTime `
            -TimeGrain 1.00:00:00 `
            -AggregationType Total `
            -ErrorAction SilentlyContinue

        if ($connMetric -and $connMetric.Data) {
            $validData = $connMetric.Data | Where-Object { $null -ne $_.Total -and $_.Total -gt 0 }
            if ($validData) {
                $metrics.ConnectionCount = ($validData | Measure-Object -Property Total -Sum).Sum
                $lastActiveEntry = $validData | Sort-Object TimeStamp -Descending | Select-Object -First 1
                $metrics.LastActiveTime = $lastActiveEntry.TimeStamp
                $metrics.IdleDays = [math]::Round(($endTime - $lastActiveEntry.TimeStamp).TotalDays, 1)
            }
            else {
                $metrics.IdleDays = $LookbackDays
                $metrics.ConnectionCount = 0
                $metrics.LastActiveTime = "No activity in ${LookbackDays}d"
            }
        }
    }
    catch {
        Write-Status "  Metrics error for $DatabaseName : $($_.Exception.Message)" -Level "Warning"
    }

    return $metrics
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "       AZURE SQL DATABASE AUDIT & HEALTH REPORT" -ForegroundColor Cyan
Write-Host "       $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# --- Verify Az module and login ---
if (-not (Get-Module -ListAvailable -Name Az.Sql)) {
    Write-Status "Az.Sql module not found. Install with: Install-Module Az -Force" -Level "Error"
    exit 1
}

$context = Get-AzContext
if (-not $context) {
    Write-Status "Not logged in to Azure. Running Connect-AzAccount..." -Level "Warning"
    Connect-AzAccount
    $context = Get-AzContext
}
Write-Status "Logged in as: $($context.Account.Id)" -Level "Success"

# --- Get subscriptions ---
if ($SubscriptionId) {
    $subscriptions = Get-AzSubscription -SubscriptionId $SubscriptionId
}
else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
}
Write-Status "Found $($subscriptions.Count) subscription(s) to scan" -Level "Info"

# --- Prompt for connection test creds if needed ---
if (-not $SkipConnectionTest -and (-not $ConnectionTestUsername -or -not $ConnectionTestPassword)) {
    Write-Host ""
    Write-Status "Connection testing is enabled. Provide SQL auth credentials or use -SkipConnectionTest" -Level "Info"
    Write-Status "  (These creds will be used to test connectivity to each database)" -Level "Info"
    Write-Host ""
    
    if (-not $ConnectionTestUsername) {
        $ConnectionTestUsername = Read-Host "SQL Username"
    }
    if (-not $ConnectionTestPassword) {
        $ConnectionTestPassword = Read-Host "SQL Password" -AsSecureString
    }
    Write-Host ""
}

# --- Scan all databases ---
$allResults = [System.Collections.ArrayList]::new()
$totalDatabases = 0
$totalServers = 0

foreach ($sub in $subscriptions) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    Write-Host ""
    Write-Status "Scanning subscription: $($sub.Name) ($($sub.Id))" -Level "Info"

    $servers = Get-AzSqlServer -ErrorAction SilentlyContinue
    if (-not $servers) {
        Write-Status "  No SQL servers found in this subscription" -Level "Warning"
        continue
    }

    $totalServers += $servers.Count

    foreach ($server in $servers) {
        Write-Status "  Server: $($server.ServerName) ($($server.ResourceGroupName))" -Level "Info"

        $databases = Get-AzSqlDatabase -ResourceGroupName $server.ResourceGroupName `
            -ServerName $server.ServerName -ErrorAction SilentlyContinue |
            Where-Object { $_.DatabaseName -ne "master" }

        if (-not $databases) {
            Write-Status "    No user databases found" -Level "Warning"
            continue
        }

        foreach ($db in $databases) {
            $totalDatabases++
            Write-Status "    [$totalDatabases] $($db.DatabaseName) - Status: $($db.Status)" -Level "Info"

            # Get metrics
            $metrics = Get-DatabaseMetrics `
                -ResourceGroupName $server.ResourceGroupName `
                -ServerName $server.ServerName `
                -DatabaseName $db.DatabaseName

            # Max size
            $maxSizeGB = if ($db.MaxSizeBytes) { [math]::Round($db.MaxSizeBytes / 1GB, 2) } else { "N/A" }

            # Connection test
            $connResult = @{ CanConnect = "Skipped"; ResponseTimeMs = "N/A"; ErrorMessage = "N/A" }
            if (-not $SkipConnectionTest -and $db.Status -eq "Online") {
                Write-Status "      Testing connection..." -Level "Info"
                $connResult = Test-DatabaseConnection `
                    -ServerFQDN $server.FullyQualifiedDomainName `
                    -DatabaseName $db.DatabaseName `
                    -Username $ConnectionTestUsername `
                    -Password $ConnectionTestPassword
            }

            # Determine idle status
            $idleStatus = "Unknown"
            if ($null -ne $metrics.IdleDays) {
                if ($metrics.IdleDays -ge $IdleThresholdDays) {
                    $idleStatus = "IDLE (${IdleThresholdDays}d+)"
                }
                else {
                    $idleStatus = "Active"
                }
            }

            # DTU tier recommendation
            $dtuRecommendation = "N/A"
            if ($null -ne $metrics.AvgDtuPercent -and $null -ne $metrics.MaxDtuPercent) {
                if ($metrics.AvgDtuPercent -lt 10 -and $metrics.MaxDtuPercent -lt 25) {
                    $dtuRecommendation = "DOWNSCALE - Severely underutilized"
                }
                elseif ($metrics.AvgDtuPercent -lt 25 -and $metrics.MaxDtuPercent -lt 50) {
                    $dtuRecommendation = "DOWNSCALE - Underutilized"
                }
                elseif ($metrics.AvgDtuPercent -ge 80 -and $metrics.MaxDtuPercent -ge 90) {
                    $dtuRecommendation = "UPSCALE - Consistently maxed out"
                }
                elseif ($metrics.AvgDtuPercent -ge 80) {
                    $dtuRecommendation = "UPSCALE - High average usage"
                }
                elseif ($metrics.MaxDtuPercent -ge 90 -and $metrics.AvgDtuPercent -lt 50) {
                    $dtuRecommendation = "MONITOR - Spiky usage (low avg, high peaks)"
                }
                else {
                    $dtuRecommendation = "RIGHT-SIZED"
                }
            }

            # Determine risk level
            $riskFlags = @()
            if ($db.Status -ne "Online") { $riskFlags += "NOT_ONLINE" }
            if ($metrics.AvgDtuPercent -ge 80) { $riskFlags += "HIGH_DTU" }
            if ($null -ne $metrics.AvgDtuPercent -and $metrics.AvgDtuPercent -lt 10 -and $null -ne $metrics.MaxDtuPercent -and $metrics.MaxDtuPercent -lt 25) { $riskFlags += "LOW_DTU_WASTE" }
            if ($null -ne $metrics.AvgDtuPercent -and $metrics.AvgDtuPercent -lt 25 -and $metrics.AvgDtuPercent -ge 10) { $riskFlags += "LOW_DTU" }
            if ($metrics.AvgSizePercent -ge 80) { $riskFlags += "HIGH_STORAGE" }
            if ($metrics.IdleDays -ge $IdleThresholdDays) { $riskFlags += "IDLE" }
            if ($connResult.CanConnect -eq $false) { $riskFlags += "CONN_FAILED" }

            $riskLevel = if ($riskFlags.Count -eq 0) { "OK" }
                         elseif ($riskFlags -contains "HIGH_DTU" -or $riskFlags -contains "NOT_ONLINE" -or $riskFlags -contains "CONN_FAILED" -or $riskFlags.Count -ge 2) { "HIGH" }
                         else { "MEDIUM" }

            $record = [PSCustomObject]@{
                Subscription       = $sub.Name
                ResourceGroup      = $server.ResourceGroupName
                ServerName         = $server.ServerName
                ServerFQDN         = $server.FullyQualifiedDomainName
                DatabaseName       = $db.DatabaseName
                Status             = $db.Status
                Edition            = $db.Edition
                ServiceObjective   = $db.CurrentServiceObjectiveName
                MaxSizeGB          = $maxSizeGB
                CurrentSizeMB      = if ($metrics.CurrentSizeMB) { $metrics.CurrentSizeMB } else { "N/A" }
                StoragePercent     = if ($metrics.AvgSizePercent) { "$($metrics.AvgSizePercent)%" } else { "N/A" }
                AvgDtuCpuPercent   = if ($metrics.AvgDtuPercent) { "$($metrics.AvgDtuPercent)%" } else { "N/A" }
                MaxDtuCpuPercent   = if ($metrics.MaxDtuPercent) { "$($metrics.MaxDtuPercent)%" } else { "N/A" }
                LastActivity       = if ($metrics.LastActiveTime) { $metrics.LastActiveTime } else { "Unknown" }
                IdleDays           = if ($null -ne $metrics.IdleDays) { $metrics.IdleDays } else { "Unknown" }
                ConnectionsLast30d = if ($null -ne $metrics.ConnectionCount) { $metrics.ConnectionCount } else { "N/A" }
                IdleStatus         = $idleStatus
                ConnTestResult     = $connResult.CanConnect
                ConnResponseMs     = $connResult.ResponseTimeMs
                ConnError          = if ($connResult.ErrorMessage) { $connResult.ErrorMessage.Substring(0, [math]::Min(200, $connResult.ErrorMessage.Length)) } else { "" }
                DtuRecommendation  = $dtuRecommendation
                RiskLevel          = $riskLevel
                RiskFlags          = ($riskFlags -join ", ")
                CreatedDate        = $db.CreationDate
            }

            [void]$allResults.Add($record)
        }
    }
}

# ============================================================================
# GENERATE REPORTS
# ============================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "                    REPORT SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# --- Summary stats ---
$onlineCount = ($allResults | Where-Object { $_.Status -eq "Online" }).Count
$offlineCount = ($allResults | Where-Object { $_.Status -ne "Online" }).Count
$idleCount = ($allResults | Where-Object { $_.IdleStatus -like "IDLE*" }).Count
$highRiskCount = ($allResults | Where-Object { $_.RiskLevel -eq "HIGH" }).Count
$medRiskCount = ($allResults | Where-Object { $_.RiskLevel -eq "MEDIUM" }).Count
$connFailCount = ($allResults | Where-Object { $_.ConnTestResult -eq $false }).Count
$lowDtuCount = ($allResults | Where-Object { $_.DtuRecommendation -like "DOWNSCALE*" }).Count
$highDtuCount = ($allResults | Where-Object { $_.DtuRecommendation -like "UPSCALE*" }).Count
$spikyDtuCount = ($allResults | Where-Object { $_.DtuRecommendation -like "MONITOR*" }).Count
$rightSizedCount = ($allResults | Where-Object { $_.DtuRecommendation -eq "RIGHT-SIZED" }).Count

Write-Host ""
Write-Status "Total Servers Scanned:   $totalServers" -Level "Info"
Write-Status "Total Databases Found:   $totalDatabases" -Level "Info"
Write-Status "Online:                  $onlineCount" -Level "Success"
Write-Status "Offline/Other:           $offlineCount" -Level $(if ($offlineCount -gt 0) { "Warning" } else { "Info" })
Write-Status "Idle ($IdleThresholdDays+ days):          $idleCount" -Level $(if ($idleCount -gt 0) { "Warning" } else { "Info" })
Write-Status "Connection Failures:     $connFailCount" -Level $(if ($connFailCount -gt 0) { "Error" } else { "Info" })
Write-Status "High Risk:               $highRiskCount" -Level $(if ($highRiskCount -gt 0) { "Error" } else { "Info" })
Write-Status "Medium Risk:             $medRiskCount" -Level $(if ($medRiskCount -gt 0) { "Warning" } else { "Info" })
Write-Host ""
Write-Host "  DTU/CPU SIZING ANALYSIS:" -ForegroundColor Cyan
Write-Status "  Overloaded (UPSCALE):    $highDtuCount" -Level $(if ($highDtuCount -gt 0) { "Error" } else { "Info" })
Write-Status "  Underutilized (DOWNSCALE): $lowDtuCount" -Level $(if ($lowDtuCount -gt 0) { "Warning" } else { "Info" })
Write-Status "  Spiky (MONITOR):         $spikyDtuCount" -Level $(if ($spikyDtuCount -gt 0) { "Warning" } else { "Info" })
Write-Status "  Right-Sized:             $rightSizedCount" -Level "Success"
Write-Host ""

# --- Print flagged databases ---
$flagged = $allResults | Where-Object { $_.RiskLevel -ne "OK" } | Sort-Object RiskLevel -Descending
if ($flagged) {
    Write-Host "FLAGGED DATABASES:" -ForegroundColor Yellow
    Write-Host "-------------------" -ForegroundColor Yellow
    foreach ($f in $flagged) {
        $color = if ($f.RiskLevel -eq "HIGH") { "Red" } else { "Yellow" }
        Write-Host "  [$($f.RiskLevel)] $($f.ServerName)/$($f.DatabaseName) - Flags: $($f.RiskFlags)" -ForegroundColor $color
    }
    Write-Host ""
}

# --- Export CSV ---
$allResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "CSV Report:  $csvPath" -Level "Success"

# --- Generate HTML Report ---
$htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <title>Azure SQL Database Audit Report - $timestamp</title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        h1 { color: #0078d4; border-bottom: 3px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #333; margin-top: 30px; }
        .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 15px; margin: 20px 0; }
        .summary-card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); text-align: center; }
        .summary-card .number { font-size: 36px; font-weight: bold; }
        .summary-card .label { color: #666; margin-top: 5px; }
        .ok { color: #107c10; }
        .warning { color: #ff8c00; }
        .critical { color: #d13438; }
        table { border-collapse: collapse; width: 100%; background: white; box-shadow: 0 2px 4px rgba(0,0,0,0.1); border-radius: 8px; overflow: hidden; margin: 15px 0; }
        th { background: #0078d4; color: white; padding: 12px 15px; text-align: left; font-weight: 600; }
        td { padding: 10px 15px; border-bottom: 1px solid #eee; }
        tr:hover { background: #f0f6ff; }
        .risk-HIGH { background: #fde7e9; font-weight: bold; color: #d13438; }
        .risk-MEDIUM { background: #fff4ce; color: #8a6914; }
        .risk-OK { color: #107c10; }
        .status-Online { color: #107c10; font-weight: bold; }
        .status-Offline { color: #d13438; font-weight: bold; }
        .idle-tag { background: #ff8c00; color: white; padding: 2px 8px; border-radius: 10px; font-size: 12px; }
        .timestamp { color: #999; font-size: 12px; margin-top: 30px; }
    </style>
</head>
<body>
    <h1>Azure SQL Database Audit Report</h1>
    <p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Idle Threshold: ${IdleThresholdDays} days</p>
    
    <div class="summary-grid">
        <div class="summary-card"><div class="number">$totalDatabases</div><div class="label">Total Databases</div></div>
        <div class="summary-card"><div class="number ok">$onlineCount</div><div class="label">Online</div></div>
        <div class="summary-card"><div class="number warning">$idleCount</div><div class="label">Idle</div></div>
        <div class="summary-card"><div class="number critical">$highRiskCount</div><div class="label">High Risk</div></div>
        <div class="summary-card"><div class="number critical">$connFailCount</div><div class="label">Conn Failures</div></div>
        <div class="summary-card"><div class="number critical">$highDtuCount</div><div class="label">Needs Upscale</div></div>
        <div class="summary-card"><div class="number warning">$lowDtuCount</div><div class="label">Needs Downscale</div></div>
        <div class="summary-card"><div class="number ok">$rightSizedCount</div><div class="label">Right-Sized</div></div>
    </div>
"@

# Flagged databases table
$flaggedHtml = ""
if ($flagged) {
    $flaggedHtml = "<h2>Flagged Databases (Requires Attention)</h2><table><tr><th>Risk</th><th>Server</th><th>Database</th><th>Status</th><th>DTU/CPU Avg</th><th>DTU/CPU Max</th><th>Storage %</th><th>Idle Days</th><th>Connection</th><th>DTU Recommendation</th><th>Flags</th></tr>"
    foreach ($f in $flagged) {
        $riskClass = "risk-$($f.RiskLevel)"
        $statusClass = "status-$($f.Status)"
        $connDisplay = if ($f.ConnTestResult -eq $true) { "<span class='ok'>PASS</span>" }
                       elseif ($f.ConnTestResult -eq $false) { "<span class='critical'>FAIL</span>" }
                       else { "Skipped" }
        $recClass = if ($f.DtuRecommendation -like "DOWNSCALE*") { "warning" }
                    elseif ($f.DtuRecommendation -like "UPSCALE*") { "critical" }
                    elseif ($f.DtuRecommendation -like "MONITOR*") { "warning" }
                    else { "ok" }
        $flaggedHtml += "<tr class='$riskClass'><td>$($f.RiskLevel)</td><td>$($f.ServerName)</td><td>$($f.DatabaseName)</td><td class='$statusClass'>$($f.Status)</td><td>$($f.AvgDtuCpuPercent)</td><td>$($f.MaxDtuCpuPercent)</td><td>$($f.StoragePercent)</td><td>$($f.IdleDays)</td><td>$connDisplay</td><td class='$recClass'>$($f.DtuRecommendation)</td><td>$($f.RiskFlags)</td></tr>"
    }
    $flaggedHtml += "</table>"
}

# All databases table
$allDbHtml = "<h2>All Databases</h2><table><tr><th>Subscription</th><th>Server</th><th>Database</th><th>Status</th><th>Edition</th><th>Tier</th><th>Max Size GB</th><th>Used MB</th><th>Storage %</th><th>Avg DTU/CPU</th><th>Max DTU/CPU</th><th>Last Activity</th><th>Idle Days</th><th>Connections (30d)</th><th>Conn Test</th><th>DTU Recommendation</th><th>Risk</th></tr>"
foreach ($r in ($allResults | Sort-Object RiskLevel -Descending)) {
    $riskClass = "risk-$($r.RiskLevel)"
    $statusClass = "status-$($r.Status)"
    $connDisplay = if ($r.ConnTestResult -eq $true) { "<span class='ok'>PASS (${$r.ConnResponseMs}ms)</span>" }
                   elseif ($r.ConnTestResult -eq $false) { "<span class='critical'>FAIL</span>" }
                   else { "Skipped" }
    $recClass = if ($r.DtuRecommendation -like "DOWNSCALE*") { "warning" }
                elseif ($r.DtuRecommendation -like "UPSCALE*") { "critical" }
                elseif ($r.DtuRecommendation -like "MONITOR*") { "warning" }
                else { "ok" }
    $allDbHtml += "<tr><td>$($r.Subscription)</td><td>$($r.ServerName)</td><td>$($r.DatabaseName)</td><td class='$statusClass'>$($r.Status)</td><td>$($r.Edition)</td><td>$($r.ServiceObjective)</td><td>$($r.MaxSizeGB)</td><td>$($r.CurrentSizeMB)</td><td>$($r.StoragePercent)</td><td>$($r.AvgDtuCpuPercent)</td><td>$($r.MaxDtuCpuPercent)</td><td>$($r.LastActivity)</td><td>$($r.IdleDays)</td><td>$($r.ConnectionsLast30d)</td><td>$connDisplay</td><td class='$recClass'>$($r.DtuRecommendation)</td><td class='$riskClass'>$($r.RiskLevel)</td></tr>"
}
$allDbHtml += "</table>"

$htmlFooter = @"
    <p class="timestamp">Report generated by AzureSQLDatabaseAudit.ps1 | Scanned $totalServers server(s), $totalDatabases database(s)</p>
</body>
</html>
"@

$fullHtml = $htmlHeader + $flaggedHtml + $allDbHtml + $htmlFooter
$fullHtml | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Status "HTML Report: $htmlPath" -Level "Success"

# --- Final output ---
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  AUDIT COMPLETE" -ForegroundColor Green
Write-Host "  CSV:  $csvPath" -ForegroundColor Green
Write-Host "  HTML: $htmlPath" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""

# Return results for pipeline use
return $allResults
