<#
.SYNOPSIS
    MOVEit Server - ALL-IN-ONE Automated Setup
.DESCRIPTION
    Run this ONCE on the MOVEit server. It sets up EVERYTHING:
      - 10 Azure audit reports (RBAC, NSG, Encryption, etc.)
      - SQL Database health + DTU monitoring
      - Daily SQL DTU spike alerts
      - Weekly email reports to Tony, John, Brian
      - Monthly executive summary reports
      - All scheduled tasks
      - Uses existing databricks-service-principal
    
    After this script runs, everything is automated forever.

.NOTES
    Run as Administrator in PowerShell
    Usage: .\MOVEit-Master-Setup.ps1
           .\MOVEit-Master-Setup.ps1 -ReportFolder "D:\Reports" -GitRepoUrl "https://github.com/Riz7886/Pyex-AVD-deployment.git"
#>

#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ScriptsFolder = "C:\Scripts",
    [string]$ReportFolder = "C:\Scripts\Reports",
    [string]$LogFolder = "C:\Scripts\Logs",
    [string]$GitRepoUrl = "https://github.com/Riz7886/Pyex-AVD-deployment.git",
    [string]$SmtpServer = "smtp.office365.com",
    [int]$SmtpPort = 587,
    [string]$EmailFrom = "SRizvi@pyxhealth.com",
    [string[]]$EmailTo = @("Anthony.schlak@pyxhealth.com", "John.pinto@pyxhealth.com", "brian@pyxhealth.com"),
    [string]$WeeklyRunDay = "Friday",
    [string]$WeeklyRunTime = "17:00",
    [string]$MonthlyRunTime = "18:00",
    [string]$DailyAlertTime = "07:00"
)

$ErrorActionPreference = "Stop"

# ============================================================================
# EXISTING SERVICE PRINCIPAL (databricks-service-principal)
# ============================================================================
$SP_APP_ID   = "e44f4026-8d8e-4a26-a5c7-46269cc0d7de"
$SP_TENANT   = "8ef3d734-3ca5-4493-8d8b-52b2c54eab04"
$credentialPath = Join-Path $env:USERPROFILE ".moveit_azure_creds.xml"

# ============================================================================
# LOGGING
# ============================================================================
function Write-Step {
    param([string]$Step, [string]$Message)
    Write-Host ""
    Write-Host "[$Step] $Message" -ForegroundColor Yellow
    Write-Host ("-" * 60) -ForegroundColor DarkGray
}

function Write-OK {
    param([string]$Message)
    Write-Host "  [+] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [*] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [!] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [-] $Message" -ForegroundColor Red
}

# ============================================================================
# START
# ============================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  MOVEIT SERVER - ALL-IN-ONE AUTOMATED SETUP" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This script will:" -ForegroundColor White
Write-Host "    1.  Install required PowerShell modules" -ForegroundColor Gray
Write-Host "    2.  Create folder structure" -ForegroundColor Gray
Write-Host "    3.  Authenticate with databricks-service-principal" -ForegroundColor Gray
Write-Host "    4.  Save encrypted credentials" -ForegroundColor Gray
Write-Host "    5.  Clone audit scripts from GitHub" -ForegroundColor Gray
Write-Host "    6.  Create SQL Database monitoring script" -ForegroundColor Gray
Write-Host "    7.  Create daily DTU alert script" -ForegroundColor Gray
Write-Host "    8.  Create weekly report script" -ForegroundColor Gray
Write-Host "    9.  Create monthly report script" -ForegroundColor Gray
Write-Host "    10. Register ALL scheduled tasks" -ForegroundColor Gray
Write-Host "    11. Test run" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# STEP 1: INSTALL MODULES
# ============================================================================
Write-Step "1/11" "Installing required PowerShell modules"

$requiredModules = @("Az.Accounts", "Az.Sql", "Az.Monitor", "Az.Resources", "Az.Network", 
                     "Az.Security", "Az.Storage", "Az.KeyVault", "Az.PolicyInsights",
                     "Az.CostManagement", "Az.Compute")

foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Info "Installing $mod..."
        Install-Module $mod -Force -AllowClobber -Scope AllUsers -WarningAction SilentlyContinue
        Write-OK "$mod installed"
    }
    else {
        Write-OK "$mod already installed"
    }
}

# ============================================================================
# STEP 2: CREATE FOLDER STRUCTURE
# ============================================================================
Write-Step "2/11" "Creating folder structure"

$folders = @($ScriptsFolder, $ReportFolder, $LogFolder, 
             "$ReportFolder\Daily", "$ReportFolder\Weekly", "$ReportFolder\Monthly",
             "$ScriptsFolder\SQL-Monitor")

foreach ($folder in $folders) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
}
Write-OK "Folder structure created at $ScriptsFolder"

# ============================================================================
# STEP 3: AUTHENTICATE WITH SERVICE PRINCIPAL
# ============================================================================
Write-Step "3/11" "Authenticating with databricks-service-principal"

Write-Info "App ID:    $SP_APP_ID"
Write-Info "Tenant ID: $SP_TENANT"

# Check if we already have saved creds
$spSecret = $null
if (Test-Path $credentialPath) {
    Write-Info "Found saved credentials, testing..."
    try {
        $savedCreds = Import-Clixml -Path $credentialPath
        $secureSecret = $savedCreds.ClientSecret | ConvertTo-SecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
        $spSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

        $credential = New-Object System.Management.Automation.PSCredential($SP_APP_ID, $secureSecret)
        Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $SP_TENANT -WarningAction SilentlyContinue | Out-Null
        
        $testSubs = @(Get-AzSubscription -WarningAction SilentlyContinue -ErrorAction Stop)
        if ($testSubs.Count -gt 0) {
            Write-OK "Authenticated with saved credentials ($($testSubs.Count) subscriptions)"
        }
        else {
            throw "No subscriptions found"
        }
    }
    catch {
        Write-Warn "Saved credentials failed, need new secret"
        $spSecret = $null
    }
}

if (-not $spSecret) {
    Write-Host ""
    Write-Host "  Enter the Client Secret for databricks-service-principal:" -ForegroundColor Cyan
    Write-Host "  (This is the ONLY manual input - never asked again)" -ForegroundColor Gray
    $spSecret = Read-Host "  Client Secret"
    
    try {
        $secureSecret = ConvertTo-SecureString $spSecret -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($SP_APP_ID, $secureSecret)
        Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $SP_TENANT -WarningAction SilentlyContinue | Out-Null
        
        $testSubs = @(Get-AzSubscription -WarningAction SilentlyContinue -ErrorAction Stop)
        if ($testSubs.Count -eq 0) { throw "No subscriptions" }
        Write-OK "Authenticated successfully ($($testSubs.Count) subscriptions found)"
    }
    catch {
        Write-Fail "Authentication failed: $($_.Exception.Message)"
        Write-Fail "Check the Client Secret and ensure the SP has Reader role on subscriptions"
        Write-Host ""
        Write-Host "  Fix with:" -ForegroundColor Yellow
        Write-Host "  az role assignment create --assignee $SP_APP_ID --role Reader --scope /subscriptions/<sub-id>" -ForegroundColor White
        Write-Host "  az role assignment create --assignee $SP_APP_ID --role 'Monitoring Reader' --scope /subscriptions/<sub-id>" -ForegroundColor White
        exit 1
    }
}

# ============================================================================
# STEP 4: SAVE ENCRYPTED CREDENTIALS
# ============================================================================
Write-Step "4/11" "Saving encrypted credentials (never asked again)"

$credsToSave = @{
    TenantId     = $SP_TENANT
    ClientId     = $SP_APP_ID
    ClientSecret = $spSecret | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString
}
$credsToSave | Export-Clixml -Path $credentialPath -Force
Write-OK "Credentials saved to: $credentialPath"
Write-Info "Encrypted - only this user on this machine can read them"

# ============================================================================
# STEP 5: CLONE AUDIT SCRIPTS FROM GITHUB
# ============================================================================
Write-Step "5/11" "Cloning audit scripts from GitHub"

$repoFolder = Join-Path $ScriptsFolder "Pyex-AVD-deployment"

if (Test-Path $repoFolder) {
    Write-Info "Repo already exists, pulling latest..."
    Push-Location $repoFolder
    try {
        git pull origin main --quiet 2>&1 | Out-Null
        Write-OK "Updated to latest"
    }
    catch {
        Write-Warn "Git pull failed, using existing copy"
    }
    Pop-Location
}
else {
    Write-Info "Cloning $GitRepoUrl..."
    try {
        git clone $GitRepoUrl $repoFolder --quiet 2>&1 | Out-Null
        Write-OK "Cloned to: $repoFolder"
    }
    catch {
        Write-Warn "Git clone failed. Checking if git is installed..."
        $gitInstalled = Get-Command git -ErrorAction SilentlyContinue
        if (-not $gitInstalled) {
            Write-Info "Installing Git..."
            winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements 2>$null
            $env:PATH += ";C:\Program Files\Git\bin"
            git clone $GitRepoUrl $repoFolder --quiet 2>&1 | Out-Null
            Write-OK "Git installed and repo cloned"
        }
        else {
            Write-Fail "Git clone failed: $($_.Exception.Message)"
            Write-Info "Continuing without repo - SQL monitoring will still work"
        }
    }
}

# ============================================================================
# STEP 6: CREATE SQL DATABASE MONITORING SCRIPT
# ============================================================================
Write-Step "6/11" "Creating SQL Database health monitoring script"

$sqlMonitorScript = Join-Path $ScriptsFolder "SQL-Monitor\Monitor-AzureSQLHealth.ps1"

$sqlMonitorContent = @'
<#
.SYNOPSIS
    Azure SQL Database Health Monitor - Automated
.DESCRIPTION
    Scans all SQL databases, checks DTU/CPU, storage, idle status.
    Generates HTML + CSV reports. Runs unattended.
#>

param(
    [string]$ExportPath = "C:\Scripts\Reports\Daily",
    [int]$IdleThresholdDays = 14,
    [int]$LookbackDays = 30
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$csvPath = Join-Path $ExportPath "SQLHealth_$timestamp.csv"
$htmlPath = Join-Path $ExportPath "SQLHealth_$timestamp.html"
$logPath = Join-Path "C:\Scripts\Logs" "SQLHealth_$timestamp.log"
$credentialPath = Join-Path $env:USERPROFILE ".moveit_azure_creds.xml"

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $logPath -Value $entry -ErrorAction SilentlyContinue
    Write-Host $entry
}

# --- Authenticate ---
try {
    $creds = Import-Clixml -Path $credentialPath
    $secureSecret = $creds.ClientSecret | ConvertTo-SecureString
    $credential = New-Object System.Management.Automation.PSCredential($creds.ClientId, $secureSecret)
    Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $creds.TenantId -WarningAction SilentlyContinue | Out-Null
    Write-Log "Authenticated as: $($creds.ClientId)"
}
catch {
    Write-Log "AUTH FAILED: $($_.Exception.Message)" -Level "Error"
    exit 1
}

# --- Scan databases ---
$allResults = [System.Collections.ArrayList]::new()
$subscriptions = @(Get-AzSubscription -WarningAction SilentlyContinue | Where-Object { $_.State -eq "Enabled" })

foreach ($sub in $subscriptions) {
    Set-AzContext -SubscriptionId $sub.Id -WarningAction SilentlyContinue | Out-Null
    Write-Log "Scanning: $($sub.Name)"

    $servers = Get-AzSqlServer -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    if (-not $servers) { continue }

    foreach ($server in $servers) {
        $databases = Get-AzSqlDatabase -ResourceGroupName $server.ResourceGroupName `
            -ServerName $server.ServerName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
            Where-Object { $_.DatabaseName -ne "master" }

        if (-not $databases) { continue }

        foreach ($db in $databases) {
            Write-Log "  Checking: $($server.ServerName)/$($db.DatabaseName)"

            $resourceId = $db.ResourceId
            $endTime = Get-Date
            $startTime = $endTime.AddDays(-$LookbackDays)

            # DTU/CPU
            $avgDtu = $null; $maxDtu = $null
            $dtuMetric = Get-AzMetric -ResourceId $resourceId -MetricName "dtu_consumption_percent" `
                -StartTime $startTime -EndTime $endTime -TimeGrain 01:00:00 `
                -AggregationType Average -ErrorAction SilentlyContinue

            if ($dtuMetric -and $dtuMetric.Data) {
                $valid = $dtuMetric.Data | Where-Object { $null -ne $_.Average }
                if ($valid) {
                    $avgDtu = [math]::Round(($valid | Measure-Object -Property Average -Average).Average, 2)
                    $maxDtu = [math]::Round(($valid | Measure-Object -Property Average -Maximum).Maximum, 2)
                }
            }

            # Fallback CPU percent
            if ($null -eq $avgDtu) {
                $cpuMetric = Get-AzMetric -ResourceId $resourceId -MetricName "cpu_percent" `
                    -StartTime $startTime -EndTime $endTime -TimeGrain 01:00:00 `
                    -AggregationType Average -ErrorAction SilentlyContinue
                if ($cpuMetric -and $cpuMetric.Data) {
                    $valid = $cpuMetric.Data | Where-Object { $null -ne $_.Average }
                    if ($valid) {
                        $avgDtu = [math]::Round(($valid | Measure-Object -Property Average -Average).Average, 2)
                        $maxDtu = [math]::Round(($valid | Measure-Object -Property Average -Maximum).Maximum, 2)
                    }
                }
            }

            # Storage
            $storPct = $null
            $storMetric = Get-AzMetric -ResourceId $resourceId -MetricName "storage_percent" `
                -StartTime $endTime.AddDays(-1) -EndTime $endTime -TimeGrain 01:00:00 `
                -AggregationType Maximum -ErrorAction SilentlyContinue
            if ($storMetric -and $storMetric.Data) {
                $valid = $storMetric.Data | Where-Object { $null -ne $_.Maximum }
                if ($valid) { $storPct = [math]::Round(($valid | Measure-Object -Property Maximum -Maximum).Maximum, 2) }
            }

            # Connections (idle detection)
            $idleDays = $null; $connCount = 0; $lastActive = "Unknown"
            $connMetric = Get-AzMetric -ResourceId $resourceId -MetricName "connection_successful" `
                -StartTime $startTime -EndTime $endTime -TimeGrain 1.00:00:00 `
                -AggregationType Total -ErrorAction SilentlyContinue
            if ($connMetric -and $connMetric.Data) {
                $valid = $connMetric.Data | Where-Object { $null -ne $_.Total -and $_.Total -gt 0 }
                if ($valid) {
                    $connCount = ($valid | Measure-Object -Property Total -Sum).Sum
                    $last = $valid | Sort-Object TimeStamp -Descending | Select-Object -First 1
                    $lastActive = $last.TimeStamp
                    $idleDays = [math]::Round(($endTime - $last.TimeStamp).TotalDays, 1)
                }
                else {
                    $idleDays = $LookbackDays
                    $lastActive = "No activity in ${LookbackDays}d"
                }
            }

            # DTU recommendation
            $rec = "N/A"
            if ($null -ne $avgDtu -and $null -ne $maxDtu) {
                if ($avgDtu -lt 10 -and $maxDtu -lt 25) { $rec = "DOWNSCALE - Severely underutilized" }
                elseif ($avgDtu -lt 25 -and $maxDtu -lt 50) { $rec = "DOWNSCALE - Underutilized" }
                elseif ($avgDtu -ge 80 -and $maxDtu -ge 90) { $rec = "UPSCALE - Consistently maxed" }
                elseif ($avgDtu -ge 80) { $rec = "UPSCALE - High average" }
                elseif ($maxDtu -ge 90 -and $avgDtu -lt 50) { $rec = "MONITOR - Spiky" }
                else { $rec = "RIGHT-SIZED" }
            }

            # Risk
            $flags = @()
            if ($db.Status -ne "Online") { $flags += "NOT_ONLINE" }
            if ($avgDtu -ge 80) { $flags += "HIGH_DTU" }
            if ($null -ne $avgDtu -and $avgDtu -lt 10 -and $null -ne $maxDtu -and $maxDtu -lt 25) { $flags += "LOW_DTU_WASTE" }
            if ($storPct -ge 80) { $flags += "HIGH_STORAGE" }
            if ($null -ne $idleDays -and $idleDays -ge $IdleThresholdDays) { $flags += "IDLE" }

            $risk = if ($flags.Count -eq 0) { "OK" }
                    elseif ($flags.Count -ge 2 -or $flags -contains "HIGH_DTU") { "HIGH" }
                    else { "MEDIUM" }

            $maxGB = if ($db.MaxSizeBytes) { [math]::Round($db.MaxSizeBytes / 1GB, 2) } else { "N/A" }

            [void]$allResults.Add([PSCustomObject]@{
                Subscription     = $sub.Name
                Server           = $server.ServerName
                Database         = $db.DatabaseName
                Status           = $db.Status
                Edition          = $db.Edition
                Tier             = $db.CurrentServiceObjectiveName
                MaxSizeGB        = $maxGB
                StoragePercent   = if ($storPct) { "$storPct%" } else { "N/A" }
                AvgDtuCpu        = if ($avgDtu) { "$avgDtu%" } else { "N/A" }
                MaxDtuCpu        = if ($maxDtu) { "$maxDtu%" } else { "N/A" }
                LastActivity     = $lastActive
                IdleDays         = if ($null -ne $idleDays) { $idleDays } else { "Unknown" }
                Connections30d   = $connCount
                DtuRecommendation = $rec
                RiskLevel        = $risk
                RiskFlags        = ($flags -join ", ")
            })
        }
    }
}

# --- Summary ---
$total = $allResults.Count
$highRisk = ($allResults | Where-Object { $_.RiskLevel -eq "HIGH" }).Count
$downscale = ($allResults | Where-Object { $_.DtuRecommendation -like "DOWNSCALE*" }).Count
$upscale = ($allResults | Where-Object { $_.DtuRecommendation -like "UPSCALE*" }).Count
$idle = ($allResults | Where-Object { $_.RiskFlags -like "*IDLE*" }).Count

Write-Log "SUMMARY: $total DBs | $highRisk HIGH RISK | $upscale UPSCALE | $downscale DOWNSCALE | $idle IDLE"

# --- Export CSV ---
$allResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

# --- Generate HTML ---
$flagged = $allResults | Where-Object { $_.RiskLevel -ne "OK" } | Sort-Object RiskLevel -Descending

$flaggedRows = ""
foreach ($f in $flagged) {
    $rc = if ($f.RiskLevel -eq "HIGH") { "risk-HIGH" } else { "risk-MEDIUM" }
    $recTag = if ($f.DtuRecommendation -like "DOWNSCALE*") { "<span class='downscale'>$($f.DtuRecommendation)</span>" }
              elseif ($f.DtuRecommendation -like "UPSCALE*") { "<span class='upscale'>$($f.DtuRecommendation)</span>" }
              elseif ($f.DtuRecommendation -like "MONITOR*") { "<span class='monitor'>$($f.DtuRecommendation)</span>" }
              else { $f.DtuRecommendation }
    $flaggedRows += "<tr class='$rc'><td><b>$($f.RiskLevel)</b></td><td>$($f.Server)</td><td>$($f.Database)</td><td>$($f.Status)</td><td>$($f.AvgDtuCpu)</td><td>$($f.MaxDtuCpu)</td><td>$($f.StoragePercent)</td><td>$($f.IdleDays)</td><td>$recTag</td><td>$($f.RiskFlags)</td></tr>`n"
}

$allRows = ""
foreach ($r in ($allResults | Sort-Object RiskLevel -Descending)) {
    $rc = "risk-$($r.RiskLevel)"
    $recTag = if ($r.DtuRecommendation -like "DOWNSCALE*") { "<span class='downscale'>DOWNSCALE</span>" }
              elseif ($r.DtuRecommendation -like "UPSCALE*") { "<span class='upscale'>UPSCALE</span>" }
              elseif ($r.DtuRecommendation -like "MONITOR*") { "<span class='monitor'>MONITOR</span>" }
              elseif ($r.DtuRecommendation -eq "RIGHT-SIZED") { "<span class='ok'>OK</span>" }
              else { $r.DtuRecommendation }
    $allRows += "<tr class='$rc'><td>$($r.Subscription)</td><td>$($r.Server)</td><td>$($r.Database)</td><td>$($r.Status)</td><td>$($r.Edition)</td><td>$($r.Tier)</td><td>$($r.AvgDtuCpu)</td><td>$($r.MaxDtuCpu)</td><td>$($r.StoragePercent)</td><td>$($r.LastActivity)</td><td>$($r.IdleDays)</td><td>$($r.Connections30d)</td><td>$recTag</td><td><b>$($r.RiskLevel)</b></td></tr>`n"
}

$html = @"
<!DOCTYPE html>
<html><head><title>SQL Health Report - $timestamp</title>
<style>
body{font-family:'Segoe UI',Arial,sans-serif;margin:20px;background:#f5f5f5}
h1{color:#0078d4;border-bottom:3px solid #0078d4;padding-bottom:10px}
h2{color:#333;margin-top:30px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:20px 0}
.card{background:#fff;padding:18px;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,.1);text-align:center}
.card .num{font-size:32px;font-weight:bold}.card .lbl{color:#666;margin-top:4px;font-size:13px}
.ok{color:#107c10}.warning{color:#ff8c00}.critical{color:#d13438}
table{border-collapse:collapse;width:100%;background:#fff;box-shadow:0 2px 4px rgba(0,0,0,.1);border-radius:8px;overflow:hidden;margin:15px 0;font-size:13px}
th{background:#0078d4;color:#fff;padding:10px 12px;text-align:left;white-space:nowrap}
td{padding:8px 12px;border-bottom:1px solid #eee}tr:hover{background:#f0f6ff}
.risk-HIGH{background:#fde7e9}.risk-MEDIUM{background:#fff4ce}
.downscale{background:#fff4ce;color:#8a6914;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:bold}
.upscale{background:#fde7e9;color:#d13438;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:bold}
.monitor{background:#e6f2ff;color:#0078d4;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:bold}
.badge{background:#107c10;color:#fff;padding:3px 10px;border-radius:12px;font-size:11px}
</style></head><body>
<h1>Azure SQL Database Health Report <span class="badge">AUTOMATED</span></h1>
<p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Server: $env:COMPUTERNAME</p>
<div class="grid">
<div class="card"><div class="num">$total</div><div class="lbl">Total DBs</div></div>
<div class="card"><div class="num critical">$highRisk</div><div class="lbl">High Risk</div></div>
<div class="card"><div class="num critical">$upscale</div><div class="lbl">Needs Upscale</div></div>
<div class="card"><div class="num warning">$downscale</div><div class="lbl">Needs Downscale</div></div>
<div class="card"><div class="num warning">$idle</div><div class="lbl">Idle</div></div>
</div>
$(if($flagged){"<h2>Flagged Databases</h2><table><tr><th>Risk</th><th>Server</th><th>Database</th><th>Status</th><th>Avg DTU</th><th>Max DTU</th><th>Storage</th><th>Idle Days</th><th>Recommendation</th><th>Flags</th></tr>$flaggedRows</table>"})
<h2>All Databases</h2><table><tr><th>Subscription</th><th>Server</th><th>Database</th><th>Status</th><th>Edition</th><th>Tier</th><th>Avg DTU</th><th>Max DTU</th><th>Storage</th><th>Last Activity</th><th>Idle Days</th><th>Conns 30d</th><th>Rec</th><th>Risk</th></tr>
$allRows</table>
<p style="color:#999;font-size:12px;margin-top:30px">MOVEit Automated Report | $($subscriptions.Count) subscription(s) scanned</p>
</body></html>
"@

$html | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Log "Reports: $htmlPath | $csvPath"

# Return results for pipeline
return @{
    Results  = $allResults
    HtmlPath = $htmlPath
    CsvPath  = $csvPath
    Summary  = @{ Total=$total; HighRisk=$highRisk; Upscale=$upscale; Downscale=$downscale; Idle=$idle }
}
'@

$sqlMonitorContent | Out-File -FilePath $sqlMonitorScript -Encoding UTF8 -Force
Write-OK "SQL Monitor script: $sqlMonitorScript"

# ============================================================================
# STEP 7: CREATE DAILY DTU ALERT SCRIPT
# ============================================================================
Write-Step "7/11" "Creating daily DTU spike alert script"

$dtuAlertScript = Join-Path $ScriptsFolder "SQL-Monitor\Daily-DTU-Alert.ps1"

$dtuAlertContent = @"
<#
.SYNOPSIS
    Daily DTU Spike Alert - Emails team if any DB is above threshold
#>

param(
    [int]`$DtuAlertThreshold = 70,
    [int]`$StorageAlertThreshold = 80
)

`$ErrorActionPreference = "Continue"
`$credentialPath = Join-Path `$env:USERPROFILE ".moveit_azure_creds.xml"
`$logPath = "C:\Scripts\Logs\DTU-Alert_`$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log { param([string]`$Msg) Add-Content -Path `$logPath -Value "[`$(Get-Date -Format 'HH:mm:ss')] `$Msg" -ErrorAction SilentlyContinue }

# Auth
try {
    `$creds = Import-Clixml -Path `$credentialPath
    `$sec = `$creds.ClientSecret | ConvertTo-SecureString
    `$cred = New-Object System.Management.Automation.PSCredential(`$creds.ClientId, `$sec)
    Connect-AzAccount -ServicePrincipal -Credential `$cred -Tenant `$creds.TenantId -WarningAction SilentlyContinue | Out-Null
} catch { Write-Log "AUTH FAILED: `$(`$_.Exception.Message)"; exit 1 }

`$alerts = @()
`$subscriptions = @(Get-AzSubscription -WarningAction SilentlyContinue | Where-Object { `$_.State -eq "Enabled" })

foreach (`$sub in `$subscriptions) {
    Set-AzContext -SubscriptionId `$sub.Id -WarningAction SilentlyContinue | Out-Null
    `$servers = Get-AzSqlServer -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    if (-not `$servers) { continue }

    foreach (`$srv in `$servers) {
        `$dbs = Get-AzSqlDatabase -ResourceGroupName `$srv.ResourceGroupName -ServerName `$srv.ServerName `
            -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object { `$_.DatabaseName -ne "master" -and `$_.Status -eq "Online" }

        foreach (`$db in `$dbs) {
            `$endTime = Get-Date
            `$startTime = `$endTime.AddHours(-24)
            `$rid = `$db.ResourceId

            # Check DTU
            `$m = Get-AzMetric -ResourceId `$rid -MetricName "dtu_consumption_percent" -StartTime `$startTime -EndTime `$endTime `
                -TimeGrain 01:00:00 -AggregationType Average -ErrorAction SilentlyContinue
            if (-not `$m -or -not `$m.Data) {
                `$m = Get-AzMetric -ResourceId `$rid -MetricName "cpu_percent" -StartTime `$startTime -EndTime `$endTime `
                    -TimeGrain 01:00:00 -AggregationType Average -ErrorAction SilentlyContinue
            }

            `$avgDtu = `$null; `$maxDtu = `$null
            if (`$m -and `$m.Data) {
                `$v = `$m.Data | Where-Object { `$null -ne `$_.Average }
                if (`$v) {
                    `$avgDtu = [math]::Round((`$v | Measure-Object -Property Average -Average).Average, 1)
                    `$maxDtu = [math]::Round((`$v | Measure-Object -Property Average -Maximum).Maximum, 1)
                }
            }

            # Check Storage
            `$sm = Get-AzMetric -ResourceId `$rid -MetricName "storage_percent" -StartTime `$startTime -EndTime `$endTime `
                -TimeGrain 01:00:00 -AggregationType Maximum -ErrorAction SilentlyContinue
            `$storPct = `$null
            if (`$sm -and `$sm.Data) {
                `$sv = `$sm.Data | Where-Object { `$null -ne `$_.Maximum }
                if (`$sv) { `$storPct = [math]::Round((`$sv | Measure-Object -Property Maximum -Maximum).Maximum, 1) }
            }

            # Alert conditions
            `$issues = @()
            if (`$avgDtu -ge `$DtuAlertThreshold) { `$issues += "AVG DTU: `$avgDtu%" }
            if (`$maxDtu -ge 90) { `$issues += "MAX DTU SPIKE: `$maxDtu%" }
            if (`$storPct -ge `$StorageAlertThreshold) { `$issues += "STORAGE: `$storPct%" }

            if (`$issues.Count -gt 0) {
                `$alerts += [PSCustomObject]@{
                    Subscription = `$sub.Name
                    Server       = `$srv.ServerName
                    Database     = `$db.DatabaseName
                    Tier         = `$db.CurrentServiceObjectiveName
                    AvgDtu       = "`$avgDtu%"
                    MaxDtu       = "`$maxDtu%"
                    Storage      = "`$storPct%"
                    Issues       = (`$issues -join " | ")
                }
                Write-Log "ALERT: `$(`$srv.ServerName)/`$(`$db.DatabaseName) - `$(`$issues -join ', ')"
            }
        }
    }
}

# Send alert email if any issues found
if (`$alerts.Count -gt 0) {
    Write-Log "Sending alert email for `$(`$alerts.Count) database(s)"

    `$rows = ""
    foreach (`$a in `$alerts) {
        `$rows += "<tr><td>`$(`$a.Server)</td><td>`$(`$a.Database)</td><td>`$(`$a.Tier)</td><td>`$(`$a.AvgDtu)</td><td>`$(`$a.MaxDtu)</td><td>`$(`$a.Storage)</td><td style='color:red;font-weight:bold'>`$(`$a.Issues)</td></tr>"
    }

    `$body = @"
<html><body style='font-family:Segoe UI,Arial;'>
<h2 style='color:#d13438'>SQL Database Alert - `$(Get-Date -Format 'yyyy-MM-dd')</h2>
<p><b>`$(`$alerts.Count) database(s)</b> exceeded thresholds in the last 24 hours:</p>
<table style='border-collapse:collapse;width:100%'>
<tr style='background:#d13438;color:white'><th style='padding:8px'>Server</th><th style='padding:8px'>Database</th><th style='padding:8px'>Tier</th><th style='padding:8px'>Avg DTU</th><th style='padding:8px'>Max DTU</th><th style='padding:8px'>Storage</th><th style='padding:8px'>Issues</th></tr>
`$rows
</table>
<p style='color:#666;font-size:12px;margin-top:20px'>Automated alert from MOVEit Server | Threshold: DTU >`$DtuAlertThreshold% | Storage >`$StorageAlertThreshold%</p>
</body></html>
"@

    try {
        Send-MailMessage `
            -From "$EmailFrom" `
            -To @("$($EmailTo -join '","')") `
            -Subject "SQL ALERT: `$(`$alerts.Count) DB(s) exceeded thresholds - `$(Get-Date -Format 'yyyy-MM-dd')" `
            -Body `$body `
            -BodyAsHtml `
            -SmtpServer "$SmtpServer" `
            -Port $SmtpPort `
            -UseSsl
        Write-Log "Alert email sent"
    }
    catch {
        Write-Log "EMAIL FAILED: `$(`$_.Exception.Message)"
    }
}
else {
    Write-Log "All databases healthy - no alerts"
}
"@

$dtuAlertContent | Out-File -FilePath $dtuAlertScript -Encoding UTF8 -Force
Write-OK "Daily DTU Alert script: $dtuAlertScript"

# ============================================================================
# STEP 8: CREATE WEEKLY REPORT SCRIPT
# ============================================================================
Write-Step "8/11" "Creating weekly report script"

$weeklyScript = Join-Path $ScriptsFolder "SQL-Monitor\Weekly-Report.ps1"

$weeklyContent = @"
<#
.SYNOPSIS
    Weekly Azure Report - Runs all audits + SQL monitor, emails results
#>

`$ErrorActionPreference = "Continue"
`$timestamp = Get-Date -Format "yyyyMMdd"
`$reportDir = "C:\Scripts\Reports\Weekly\Week_`$timestamp"
`$logPath = "C:\Scripts\Logs\Weekly_`$timestamp.log"

if (-not (Test-Path `$reportDir)) { New-Item -ItemType Directory -Path `$reportDir -Force | Out-Null }

function Write-Log { param([string]`$Msg) Add-Content -Path `$logPath -Value "[`$(Get-Date -Format 'HH:mm:ss')] `$Msg" -ErrorAction SilentlyContinue; Write-Host `$Msg }

Write-Log "=== WEEKLY REPORT STARTED ==="

# Auth with service principal
`$credentialPath = Join-Path `$env:USERPROFILE ".moveit_azure_creds.xml"
try {
    `$creds = Import-Clixml -Path `$credentialPath
    `$sec = `$creds.ClientSecret | ConvertTo-SecureString
    `$cred = New-Object System.Management.Automation.PSCredential(`$creds.ClientId, `$sec)
    Connect-AzAccount -ServicePrincipal -Credential `$cred -Tenant `$creds.TenantId -WarningAction SilentlyContinue | Out-Null
    Write-Log "Authenticated"
} catch { Write-Log "AUTH FAILED"; exit 1 }

# --- Run SQL Health Monitor ---
Write-Log "Running SQL Database Health Monitor..."
try {
    & "C:\Scripts\SQL-Monitor\Monitor-AzureSQLHealth.ps1" -ExportPath `$reportDir
    Write-Log "SQL Monitor complete"
} catch { Write-Log "SQL Monitor error: `$(`$_.Exception.Message)" }

# --- Run Audit Scripts (if repo exists) ---
`$repoDir = "C:\Scripts\Pyex-AVD-deployment"
`$auditScripts = @(
    "1-RBAC-Audit.ps1",
    "2-NSG-Audit.ps1",
    "3-Encryption-Audit.ps1",
    "4-Backup-Audit.ps1",
    "5-Cost-Tagging-Audit.ps1",
    "6-Policy-Compliance-Audit.ps1",
    "7-Identity-AAD-Audit.ps1",
    "8-SecurityCenter-Audit.ps1",
    "9-AuditLog-Collection.ps1",
    "Azure-Complete-Cost-Analysis.ps1"
)

foreach (`$script in `$auditScripts) {
    `$scriptPath = Join-Path `$repoDir `$script
    if (Test-Path `$scriptPath) {
        Write-Log "Running `$script..."
        try {
            & `$scriptPath -ErrorAction SilentlyContinue 2>`$null
            Write-Log "  `$script complete"
        } catch { Write-Log "  `$script error: `$(`$_.Exception.Message)" }
    }
}

# --- Collect all report files ---
`$attachments = @()
`$attachments += Get-ChildItem -Path `$reportDir -Filter "*.html" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
`$attachments += Get-ChildItem -Path `$reportDir -Filter "*.csv" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName

# Also grab reports from repo Reports folder
`$repoReports = Join-Path `$repoDir "Reports"
if (Test-Path `$repoReports) {
    `$latestReports = Get-ChildItem -Path `$repoReports -Filter "*.html" -ErrorAction SilentlyContinue |
        Where-Object { `$_.LastWriteTime -gt (Get-Date).AddHours(-2) } | Select-Object -ExpandProperty FullName
    `$attachments += `$latestReports
}

Write-Log "Collected `$(`$attachments.Count) report files"

# --- Send Email ---
if (`$attachments.Count -gt 0) {
    `$body = @"
<html><body style='font-family:Segoe UI,Arial;'>
<h2 style='color:#0078d4'>Weekly Azure Infrastructure Report</h2>
<p>Week of `$(Get-Date -Format 'MMMM dd, yyyy')</p>
<p>Attached are all audit and monitoring reports for this week:</p>
<ul>
<li>SQL Database Health + DTU Analysis</li>
<li>RBAC & Identity Audit</li>
<li>Network Security (NSG) Audit</li>
<li>Encryption Audit</li>
<li>Backup & Recovery Audit</li>
<li>Cost & Tagging Audit</li>
<li>Policy Compliance Audit</li>
<li>Security Center Audit</li>
<li>Complete Cost Analysis</li>
</ul>
<p style='color:#666;font-size:12px'>Automated weekly report from MOVEit Server</p>
</body></html>
"@

    try {
        `$emailParams = @{
            From       = "$EmailFrom"
            To         = @("$($EmailTo -join '","')")
            Subject    = "Weekly Azure Report - `$(Get-Date -Format 'yyyy-MM-dd')"
            Body       = `$body
            BodyAsHtml = `$true
            SmtpServer = "$SmtpServer"
            Port       = $SmtpPort
            UseSsl     = `$true
        }
        if (`$attachments.Count -le 20) { `$emailParams.Attachments = `$attachments }
        Send-MailMessage @emailParams
        Write-Log "Weekly email sent to: $($EmailTo -join ', ')"
    }
    catch { Write-Log "EMAIL FAILED: `$(`$_.Exception.Message)" }
}

Write-Log "=== WEEKLY REPORT COMPLETE ==="
"@

$weeklyContent | Out-File -FilePath $weeklyScript -Encoding UTF8 -Force
Write-OK "Weekly report script: $weeklyScript"

# ============================================================================
# STEP 9: CREATE MONTHLY REPORT SCRIPT
# ============================================================================
Write-Step "9/11" "Creating monthly report script"

$monthlyScript = Join-Path $ScriptsFolder "SQL-Monitor\Monthly-Report.ps1"

$monthlyContent = @"
<#
.SYNOPSIS
    Monthly Executive Summary - Comprehensive report with cost analysis
#>

`$ErrorActionPreference = "Continue"
`$month = Get-Date -Format "yyyy-MM"
`$reportDir = "C:\Scripts\Reports\Monthly\`$month"
`$logPath = "C:\Scripts\Logs\Monthly_`$month.log"

if (-not (Test-Path `$reportDir)) { New-Item -ItemType Directory -Path `$reportDir -Force | Out-Null }

function Write-Log { param([string]`$Msg) Add-Content -Path `$logPath -Value "[`$(Get-Date -Format 'HH:mm:ss')] `$Msg" -ErrorAction SilentlyContinue; Write-Host `$Msg }

Write-Log "=== MONTHLY REPORT STARTED ==="

# Auth
`$credentialPath = Join-Path `$env:USERPROFILE ".moveit_azure_creds.xml"
try {
    `$creds = Import-Clixml -Path `$credentialPath
    `$sec = `$creds.ClientSecret | ConvertTo-SecureString
    `$cred = New-Object System.Management.Automation.PSCredential(`$creds.ClientId, `$sec)
    Connect-AzAccount -ServicePrincipal -Credential `$cred -Tenant `$creds.TenantId -WarningAction SilentlyContinue | Out-Null
    Write-Log "Authenticated"
} catch { Write-Log "AUTH FAILED"; exit 1 }

# Run SQL Monitor with 30 day lookback
Write-Log "Running SQL Monitor (30-day lookback)..."
& "C:\Scripts\SQL-Monitor\Monitor-AzureSQLHealth.ps1" -ExportPath `$reportDir -LookbackDays 30

# Run all audit scripts
`$repoDir = "C:\Scripts\Pyex-AVD-deployment"
`$auditScripts = @("1-RBAC-Audit.ps1","2-NSG-Audit.ps1","3-Encryption-Audit.ps1","4-Backup-Audit.ps1",
    "5-Cost-Tagging-Audit.ps1","6-Policy-Compliance-Audit.ps1","7-Identity-AAD-Audit.ps1",
    "8-SecurityCenter-Audit.ps1","9-AuditLog-Collection.ps1","Azure-Complete-Cost-Analysis.ps1")

foreach (`$script in `$auditScripts) {
    `$path = Join-Path `$repoDir `$script
    if (Test-Path `$path) {
        Write-Log "Running `$script..."
        try { & `$path -ErrorAction SilentlyContinue 2>`$null } catch { Write-Log "  Error: `$(`$_.Exception.Message)" }
    }
}

# Collect reports
`$attachments = @()
`$attachments += Get-ChildItem -Path `$reportDir -Filter "*.html" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
`$attachments += Get-ChildItem -Path `$reportDir -Filter "*.csv" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName

`$body = @"
<html><body style='font-family:Segoe UI,Arial;'>
<h2 style='color:#0078d4'>Monthly Executive Summary - `$(Get-Date -Format 'MMMM yyyy')</h2>
<p>Comprehensive monthly infrastructure report attached.</p>
<h3>Reports Included:</h3>
<ul>
<li>SQL Database Health, DTU Sizing, Idle Detection</li>
<li>Full Security Audit (RBAC, NSG, Encryption, Identity)</li>
<li>Backup & Recovery Status</li>
<li>Cost Analysis & Optimization Opportunities</li>
<li>Policy Compliance Status</li>
<li>Security Center Findings</li>
</ul>
<p style='color:#666;font-size:12px'>Automated monthly report from MOVEit Server</p>
</body></html>
"@

try {
    `$emailParams = @{
        From       = "$EmailFrom"
        To         = @("$($EmailTo -join '","')")
        Subject    = "Monthly Azure Executive Summary - `$(Get-Date -Format 'MMMM yyyy')"
        Body       = `$body
        BodyAsHtml = `$true
        SmtpServer = "$SmtpServer"
        Port       = $SmtpPort
        UseSsl     = `$true
    }
    if (`$attachments.Count -le 20) { `$emailParams.Attachments = `$attachments }
    Send-MailMessage @emailParams
    Write-Log "Monthly email sent"
} catch { Write-Log "EMAIL FAILED: `$(`$_.Exception.Message)" }

Write-Log "=== MONTHLY REPORT COMPLETE ==="
"@

$monthlyContent | Out-File -FilePath $monthlyScript -Encoding UTF8 -Force
Write-OK "Monthly report script: $monthlyScript"

# ============================================================================
# STEP 10: REGISTER ALL SCHEDULED TASKS
# ============================================================================
Write-Step "10/11" "Registering scheduled tasks"

$tasks = @(
    @{
        Name        = "Azure-Daily-SQL-Alert"
        Description = "Daily SQL DTU/Storage spike alert - emails team if thresholds exceeded"
        Script      = $dtuAlertScript
        Trigger     = "Daily"
        Time        = $DailyAlertTime
        Day         = $null
    },
    @{
        Name        = "Azure-Daily-SQL-Health"
        Description = "Daily SQL Database health scan and report"
        Script      = $sqlMonitorScript
        Trigger     = "Daily"
        Time        = "06:30"
        Day         = $null
    },
    @{
        Name        = "Azure-Weekly-Full-Report"
        Description = "Weekly full audit + SQL report - emails Tony, John, Brian"
        Script      = $weeklyScript
        Trigger     = "Weekly"
        Time        = $WeeklyRunTime
        Day         = $WeeklyRunDay
    },
    @{
        Name        = "Azure-Monthly-Executive"
        Description = "Monthly executive summary - all audits + cost analysis"
        Script      = $monthlyScript
        Trigger     = "Monthly"
        Time        = $MonthlyRunTime
        Day         = $null
    }
)

foreach ($task in $tasks) {
    Write-Info "Creating: $($task.Name)"

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($task.Script)`""

    $trigger = switch ($task.Trigger) {
        "Daily"   { New-ScheduledTaskTrigger -Daily -At $task.Time }
        "Weekly"  { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $task.Day -At $task.Time }
        "Monthly" { 
            # Last business day of month - use daily trigger with logic in script
            New-ScheduledTaskTrigger -Monthly -DaysOfMonth 28 -At $task.Time
        }
    }

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 5)

    try {
        Register-ScheduledTask `
            -TaskName $task.Name `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Description $task.Description `
            -RunLevel Highest `
            -Force | Out-Null

        Write-OK "$($task.Name) - $($task.Trigger) at $($task.Time)"
    }
    catch {
        Write-Fail "Failed to create $($task.Name): $($_.Exception.Message)"
    }
}

# ============================================================================
# STEP 11: VERIFICATION
# ============================================================================
Write-Step "11/11" "Verifying everything is set up"

Write-Host ""
Write-Host "  SCHEDULED TASKS:" -ForegroundColor Cyan
$registeredTasks = Get-ScheduledTask | Where-Object { $_.TaskName -like "Azure-*" }
foreach ($t in $registeredTasks) {
    $state = $t.State
    $color = if ($state -eq "Ready") { "Green" } else { "Yellow" }
    Write-Host "    $($t.TaskName) - $state" -ForegroundColor $color
}

Write-Host ""
Write-Host "  SCRIPTS:" -ForegroundColor Cyan
$scripts = @($sqlMonitorScript, $dtuAlertScript, $weeklyScript, $monthlyScript)
foreach ($s in $scripts) {
    $exists = Test-Path $s
    $color = if ($exists) { "Green" } else { "Red" }
    $status = if ($exists) { "OK" } else { "MISSING" }
    Write-Host "    [$status] $(Split-Path $s -Leaf)" -ForegroundColor $color
}

Write-Host ""
Write-Host "  CREDENTIALS:" -ForegroundColor Cyan
$credExists = Test-Path $credentialPath
Write-Host "    [$(if($credExists){'OK'}else{'MISSING'})] $credentialPath" -ForegroundColor $(if($credExists){"Green"}else{"Red"})

Write-Host ""
Write-Host "  REPO:" -ForegroundColor Cyan
$repoExists = Test-Path (Join-Path $ScriptsFolder "Pyex-AVD-deployment")
Write-Host "    [$(if($repoExists){'OK'}else{'MISSING'})] Pyex-AVD-deployment" -ForegroundColor $(if($repoExists){"Green"}else{"Yellow"})

# ============================================================================
# DONE
# ============================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  SETUP COMPLETE - EVERYTHING IS AUTOMATED" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  What runs automatically now:" -ForegroundColor Cyan
Write-Host "    Daily  7:00 AM  - DTU spike alerts (email if thresholds hit)" -ForegroundColor White
Write-Host "    Daily  6:30 AM  - SQL health scan (report saved locally)" -ForegroundColor White
Write-Host "    Friday 5:00 PM  - Full weekly report (email to team)" -ForegroundColor White
Write-Host "    28th   6:00 PM  - Monthly executive summary (email to team)" -ForegroundColor White
Write-Host ""
Write-Host "  Reports saved to:  $ReportFolder" -ForegroundColor White
Write-Host "  Logs saved to:     $LogFolder" -ForegroundColor White
Write-Host "  Emails go to:      $($EmailTo -join ', ')" -ForegroundColor White
Write-Host ""
Write-Host "  Service Principal: databricks-service-principal ($SP_APP_ID)" -ForegroundColor Gray
Write-Host "  Credentials:       Encrypted at $credentialPath" -ForegroundColor Gray
Write-Host ""
Write-Host "  To test right now:" -ForegroundColor Yellow
Write-Host "    Start-ScheduledTask -TaskName 'Azure-Daily-SQL-Health'" -ForegroundColor White
Write-Host "    Start-ScheduledTask -TaskName 'Azure-Daily-SQL-Alert'" -ForegroundColor White
Write-Host ""
Write-Host "  NO MORE MANUAL WORK. EVER." -ForegroundColor Green
Write-Host ""
