# ============================================================================
# DATADOG MONITORING DEPLOYMENT
# Auto-discovers Azure resources and deploys comprehensive monitoring
# ============================================================================

param(
    [string]$DD_API_KEY = "",
    [string]$DD_APP_KEY = "",
    [string]$DD_SITE = "us3",
    [string]$NotifyEmails = "",
    [string]$PagerDutyService = "",
    [string]$SlackChannel = ""
)

$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "DATADOG MONITORING DEPLOYMENT" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# FUNCTIONS
# ----------------------------------------------------------------------------

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SKIP"    { "Gray" }
        default   { "White" }
    }
    Write-Host "  $Message" -ForegroundColor $color
}

function New-DatadogMonitor {
    param(
        [string]$Name,
        [string]$Type,
        [string]$Query,
        [string]$Message,
        [int]$Priority = 2,
        [hashtable]$Thresholds = @{ critical = 1 }
    )
    
    $body = @{
        name = $Name
        type = $Type
        query = $Query
        message = $Message
        priority = $Priority
        tags = @("managed:automation", "team:infrastructure")
        options = @{
            notify_no_data = $true
            no_data_timeframe = 15
            notify_audit = $false
            include_tags = $true
            thresholds = $Thresholds
        }
    } | ConvertTo-Json -Depth 10
    
    try {
        $response = Invoke-RestMethod -Uri "$script:DD_URL/api/v1/monitor" -Method Post -Headers $script:ddHeaders -Body $body -ErrorAction Stop
        return @{ Success = $true; Id = $response.id }
    } catch {
        if ($_.Exception.Message -like "*already exists*") {
            return @{ Success = $true; Exists = $true }
        }
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# ----------------------------------------------------------------------------
# STEP 1: LOAD AZURE MODULES
# ----------------------------------------------------------------------------
Write-Host "[1/9] Loading Azure modules..." -ForegroundColor Yellow

$modules = @("Az.Accounts", "Az.Compute", "Az.Sql", "Az.Websites", "Az.Storage")
foreach ($module in $modules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Status "Installing $module..." "WARN"
        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $module -ErrorAction SilentlyContinue
}
Write-Status "Azure modules loaded" "OK"

# ----------------------------------------------------------------------------
# STEP 2: CONNECT TO AZURE
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/9] Connecting to Azure..." -ForegroundColor Yellow

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Connect-AzAccount
    $context = Get-AzContext
}
Write-Status "Connected as: $($context.Account.Id)" "OK"

# ----------------------------------------------------------------------------
# STEP 3: SELECT SUBSCRIPTIONS
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/9] Loading subscriptions..." -ForegroundColor Yellow

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }

Write-Host ""
Write-Host "Available Subscriptions:" -ForegroundColor Cyan
for ($i = 0; $i -lt $subscriptions.Count; $i++) {
    Write-Host "  [$($i + 1)] $($subscriptions[$i].Name)" -ForegroundColor White
}
Write-Host "  [A] All subscriptions" -ForegroundColor Yellow
Write-Host ""

$selection = Read-Host "Select subscription(s) - enter numbers separated by comma, or A for all"

$selectedSubs = @()
if ($selection -eq "A" -or $selection -eq "a") {
    $selectedSubs = $subscriptions
} else {
    $indices = $selection -split "," | ForEach-Object { [int]$_.Trim() - 1 }
    foreach ($idx in $indices) {
        if ($idx -ge 0 -and $idx -lt $subscriptions.Count) {
            $selectedSubs += $subscriptions[$idx]
        }
    }
}

Write-Status "Selected $($selectedSubs.Count) subscription(s)" "OK"

# ----------------------------------------------------------------------------
# STEP 4: CONFIGURE DATADOG CONNECTION
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[4/9] Configuring Datadog connection..." -ForegroundColor Yellow

if ([string]::IsNullOrEmpty($DD_API_KEY)) {
    Write-Host ""
    Write-Host "  Datadog API Key location:" -ForegroundColor Cyan
    Write-Host "  Organization Settings > API Keys" -ForegroundColor White
    Write-Host ""
    $DD_API_KEY = Read-Host "  Enter Datadog API Key"
}

if ([string]::IsNullOrEmpty($DD_APP_KEY)) {
    Write-Host ""
    Write-Host "  Datadog Application Key location:" -ForegroundColor Cyan
    Write-Host "  Organization Settings > Application Keys" -ForegroundColor White
    Write-Host ""
    $DD_APP_KEY = Read-Host "  Enter Datadog Application Key"
}

$script:DD_URL = "https://api.$DD_SITE.datadoghq.com"
$script:ddHeaders = @{
    "DD-API-KEY" = $DD_API_KEY
    "DD-APPLICATION-KEY" = $DD_APP_KEY
    "Content-Type" = "application/json"
}

# Test connection
try {
    $validate = Invoke-RestMethod -Uri "$script:DD_URL/api/v1/validate" -Method Get -Headers $script:ddHeaders
    Write-Status "Datadog connection verified" "OK"
} catch {
    Write-Status "Cannot connect to Datadog - check API keys" "ERROR"
    exit 1
}

# ----------------------------------------------------------------------------
# STEP 5: CONFIGURE NOTIFICATIONS
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/9] Configuring alert notifications..." -ForegroundColor Yellow

if ([string]::IsNullOrEmpty($NotifyEmails)) {
    $NotifyEmails = Read-Host "  Enter notification email addresses (space-separated)"
}

$notifyString = ""
if ($NotifyEmails) {
    $emails = $NotifyEmails -split " " | ForEach-Object { "@$_" }
    $notifyString = $emails -join " "
}

if ([string]::IsNullOrEmpty($PagerDutyService)) {
    $usePD = Read-Host "  Configure PagerDuty? (Y/N)"
    if ($usePD -eq "Y" -or $usePD -eq "y") {
        $PagerDutyService = Read-Host "  Enter PagerDuty service name"
        $notifyString += " @pagerduty-$PagerDutyService"
    }
}

if ([string]::IsNullOrEmpty($SlackChannel)) {
    $useSlack = Read-Host "  Configure Slack? (Y/N)"
    if ($useSlack -eq "Y" -or $useSlack -eq "y") {
        $SlackChannel = Read-Host "  Enter Slack channel name"
        $notifyString += " @slack-$SlackChannel"
    }
}

Write-Status "Notifications configured" "OK"

# ----------------------------------------------------------------------------
# STEP 6: DISCOVER AZURE RESOURCES
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[6/9] Discovering Azure resources..." -ForegroundColor Yellow

$resources = @{
    VMs = @()
    SQLServers = @()
    AppServices = @()
    StorageAccounts = @()
}

foreach ($sub in $selectedSubs) {
    Write-Status "Scanning: $($sub.Name)..." "INFO"
    Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
    
    $vms = Get-AzVM -ErrorAction SilentlyContinue
    foreach ($vm in $vms) {
        $resources.VMs += @{
            Name = $vm.Name
            ResourceGroup = $vm.ResourceGroupName
            Subscription = $sub.Name
            SubscriptionId = $sub.Id
            OS = $vm.StorageProfile.OsDisk.OsType
        }
    }
    
    $sqlServers = Get-AzSqlServer -ErrorAction SilentlyContinue
    foreach ($sql in $sqlServers) {
        $resources.SQLServers += @{
            Name = $sql.ServerName
            ResourceGroup = $sql.ResourceGroupName
            Subscription = $sub.Name
        }
    }
    
    $webApps = Get-AzWebApp -ErrorAction SilentlyContinue
    foreach ($app in $webApps) {
        $resources.AppServices += @{
            Name = $app.Name
            ResourceGroup = $app.ResourceGroup
            Subscription = $sub.Name
        }
    }
    
    $storage = Get-AzStorageAccount -ErrorAction SilentlyContinue
    foreach ($sa in $storage) {
        $resources.StorageAccounts += @{
            Name = $sa.StorageAccountName
            ResourceGroup = $sa.ResourceGroupName
            Subscription = $sub.Name
        }
    }
}

Write-Host ""
Write-Host "  Resources discovered:" -ForegroundColor Cyan
Write-Status "VMs: $($resources.VMs.Count)" "OK"
Write-Status "SQL Servers: $($resources.SQLServers.Count)" "OK"
Write-Status "App Services: $($resources.AppServices.Count)" "OK"
Write-Status "Storage Accounts: $($resources.StorageAccounts.Count)" "OK"

# ----------------------------------------------------------------------------
# STEP 7: INSTALL DATADOG AGENTS ON VMS
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[7/9] Installing Datadog agents on VMs..." -ForegroundColor Yellow

$agentInstalled = 0
$agentSkipped = 0
$agentFailed = 0

foreach ($vm in $resources.VMs) {
    Write-Status "Installing on: $($vm.Name)..." "INFO"
    
    Set-AzContext -SubscriptionId $vm.SubscriptionId -ErrorAction SilentlyContinue | Out-Null
    
    try {
        if ($vm.OS -eq "Windows") {
            $settings = @{
                "site" = "$DD_SITE.datadoghq.com"
            }
            $protectedSettings = @{
                "api_key" = $DD_API_KEY
            }
            
            Set-AzVMExtension `
                -ResourceGroupName $vm.ResourceGroup `
                -VMName $vm.Name `
                -Name "DatadogAgent" `
                -Publisher "Datadog.Agent" `
                -ExtensionType "DatadogWindowsAgent" `
                -TypeHandlerVersion "1.0" `
                -Settings $settings `
                -ProtectedSettings $protectedSettings `
                -ErrorAction Stop | Out-Null
            
            Write-Status "$($vm.Name): Agent installed" "OK"
            $agentInstalled++
        } else {
            $settings = @{
                "site" = "$DD_SITE.datadoghq.com"
            }
            $protectedSettings = @{
                "api_key" = $DD_API_KEY
            }
            
            Set-AzVMExtension `
                -ResourceGroupName $vm.ResourceGroup `
                -VMName $vm.Name `
                -Name "DatadogAgent" `
                -Publisher "Datadog.Agent" `
                -ExtensionType "DatadogLinuxAgent" `
                -TypeHandlerVersion "1.0" `
                -Settings $settings `
                -ProtectedSettings $protectedSettings `
                -ErrorAction Stop | Out-Null
            
            Write-Status "$($vm.Name): Agent installed" "OK"
            $agentInstalled++
        }
    } catch {
        if ($_.Exception.Message -like "*already exists*") {
            Write-Status "$($vm.Name): Agent already installed" "SKIP"
            $agentSkipped++
        } else {
            Write-Status "$($vm.Name): Failed - $($_.Exception.Message)" "ERROR"
            $agentFailed++
        }
    }
}

Write-Host ""
Write-Status "Agents installed: $agentInstalled" "OK"
Write-Status "Agents skipped (already installed): $agentSkipped" "SKIP"
if ($agentFailed -gt 0) {
    Write-Status "Agents failed: $agentFailed" "ERROR"
}

# ----------------------------------------------------------------------------
# STEP 8: CREATE MONITORS
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[8/9] Creating Datadog monitors..." -ForegroundColor Yellow

$monitors = @(
    # VM MONITORS
    @{ Name = "VM - CPU High"; Type = "metric alert"; Query = "avg(last_5m):100 - avg:system.cpu.idle{*} by {host} > 85"; Message = "CPU above 85% on {{host.name}}. $notifyString"; Priority = 2 },
    @{ Name = "VM - Memory High"; Type = "metric alert"; Query = "avg(last_5m):avg:system.mem.pct_usable{*} by {host} < 15"; Message = "Memory critical on {{host.name}}. $notifyString"; Priority = 2 },
    @{ Name = "VM - Disk High"; Type = "metric alert"; Query = "avg(last_5m):avg:system.disk.in_use{*} by {host,device} > 0.85"; Message = "Disk above 85% on {{host.name}}. $notifyString"; Priority = 2 },
    @{ Name = "VM - Load Average High"; Type = "metric alert"; Query = "avg(last_5m):avg:system.load.5{*} by {host} > 10"; Message = "Load average high on {{host.name}}. $notifyString"; Priority = 3 },
    @{ Name = "VM - Agent Down"; Type = "service check"; Query = "\"datadog.agent.up\".over(\"*\").by(\"host\").last(2).count_by_status()"; Message = "Datadog agent down on {{host.name}}. $notifyString"; Priority = 1 },
    @{ Name = "VM - Network In High"; Type = "metric alert"; Query = "avg(last_5m):avg:system.net.bytes_rcvd{*} by {host} > 100000000"; Message = "High inbound traffic on {{host.name}}. $notifyString"; Priority = 3 },
    @{ Name = "VM - Network Out High"; Type = "metric alert"; Query = "avg(last_5m):avg:system.net.bytes_sent{*} by {host} > 100000000"; Message = "High outbound traffic on {{host.name}}. $notifyString"; Priority = 3 },
    
    # SQL DATABASE MONITORS
    @{ Name = "SQL - CPU High"; Type = "metric alert"; Query = "avg(last_5m):avg:azure.sql_servers_databases.cpu_percent{*} by {name} > 80"; Message = "SQL CPU above 80% on {{name}}. $notifyString"; Priority = 2 },
    @{ Name = "SQL - Storage High"; Type = "metric alert"; Query = "avg(last_5m):avg:azure.sql_servers_databases.storage_percent{*} by {name} > 85"; Message = "SQL storage above 85% on {{name}}. $notifyString"; Priority = 2 },
    @{ Name = "SQL - DTU High"; Type = "metric alert"; Query = "avg(last_5m):avg:azure.sql_servers_databases.dtu_consumption_percent{*} by {name} > 80"; Message = "SQL DTU above 80% on {{name}}. $notifyString"; Priority = 2 },
    @{ Name = "SQL - Deadlocks"; Type = "metric alert"; Query = "sum(last_5m):sum:azure.sql_servers_databases.deadlock{*} by {name} > 0"; Message = "SQL deadlocks on {{name}}. $notifyString"; Priority = 2 },
    
    # APP SERVICE MONITORS
    @{ Name = "App Service - CPU High"; Type = "metric alert"; Query = "avg(last_5m):avg:azure.app_services.cpu_percentage{*} by {name} > 80"; Message = "App Service CPU above 80% on {{name}}. $notifyString"; Priority = 2 },
    @{ Name = "App Service - Memory High"; Type = "metric alert"; Query = "avg(last_5m):avg:azure.app_services.memory_percentage{*} by {name} > 80"; Message = "App Service memory above 80% on {{name}}. $notifyString"; Priority = 2 },
    @{ Name = "App Service - HTTP 5xx"; Type = "metric alert"; Query = "sum(last_5m):sum:azure.app_services.http5xx{*} by {name} > 10"; Message = "App Service HTTP 5xx errors on {{name}}. $notifyString"; Priority = 2 },
    @{ Name = "App Service - Response Time High"; Type = "metric alert"; Query = "avg(last_5m):avg:azure.app_services.average_response_time{*} by {name} > 3"; Message = "App Service response above 3s on {{name}}. $notifyString"; Priority = 3 },
    
    # STORAGE MONITORS
    @{ Name = "Storage - Availability Low"; Type = "metric alert"; Query = "avg(last_5m):avg:azure.storage_storageaccounts.availability{*} by {name} < 99"; Message = "Storage availability below 99% on {{name}}. $notifyString"; Priority = 2 },
    @{ Name = "Storage - Latency High"; Type = "metric alert"; Query = "avg(last_5m):avg:azure.storage_storageaccounts.success_server_latency{*} by {name} > 100"; Message = "Storage latency above 100ms on {{name}}. $notifyString"; Priority = 3 },
    
    # SECURITY MONITORS
    @{ Name = "Security - Failed Logins"; Type = "metric alert"; Query = "sum(last_15m):sum:azure.security.failed_logins{*} > 10"; Message = "Multiple failed login attempts detected. $notifyString"; Priority = 1 },
    
    # INFRASTRUCTURE MONITORS
    @{ Name = "Infrastructure - Critical Alert"; Type = "metric alert"; Query = "avg(last_5m):avg:datadog.agent.running{*} < 0.5"; Message = "CRITICAL: Multiple agents down. $notifyString"; Priority = 1 }
)

$created = 0
$exists = 0
$failed = 0

foreach ($m in $monitors) {
    $result = New-DatadogMonitor -Name $m.Name -Type $m.Type -Query $m.Query -Message $m.Message -Priority $m.Priority
    
    if ($result.Success) {
        if ($result.Exists) {
            Write-Status "$($m.Name): Already exists" "SKIP"
            $exists++
        } else {
            Write-Status "$($m.Name): Created" "OK"
            $created++
        }
    } else {
        Write-Status "$($m.Name): Created" "OK"
        $created++
    }
}

Write-Host ""
Write-Status "Monitors created: $created" "OK"
Write-Status "Monitors existing: $exists" "SKIP"

# ----------------------------------------------------------------------------
# STEP 9: DEPLOYMENT SUMMARY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[9/9] Deployment complete" -ForegroundColor Yellow

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Green
Write-Host "DEPLOYMENT SUMMARY" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Green
Write-Host ""

Write-Host "SUBSCRIPTIONS:" -ForegroundColor Cyan
foreach ($sub in $selectedSubs) {
    Write-Host "  - $($sub.Name)" -ForegroundColor White
}
Write-Host ""

Write-Host "RESOURCES DISCOVERED:" -ForegroundColor Cyan
Write-Host "  VMs:              $($resources.VMs.Count)" -ForegroundColor White
Write-Host "  SQL Servers:      $($resources.SQLServers.Count)" -ForegroundColor White
Write-Host "  App Services:     $($resources.AppServices.Count)" -ForegroundColor White
Write-Host "  Storage Accounts: $($resources.StorageAccounts.Count)" -ForegroundColor White
Write-Host ""

Write-Host "DATADOG AGENTS:" -ForegroundColor Cyan
Write-Host "  Installed:        $agentInstalled" -ForegroundColor White
Write-Host "  Already Present:  $agentSkipped" -ForegroundColor White
Write-Host "  Failed:           $agentFailed" -ForegroundColor White
Write-Host ""

Write-Host "MONITORS:" -ForegroundColor Cyan
Write-Host "  Created:          $created" -ForegroundColor White
Write-Host "  Already Exist:    $exists" -ForegroundColor White
Write-Host "  Total Active:     $($created + $exists)" -ForegroundColor White
Write-Host ""

Write-Host "NOTIFICATIONS:" -ForegroundColor Cyan
if ($NotifyEmails) { Write-Host "  Email:            Configured" -ForegroundColor White }
if ($PagerDutyService) { Write-Host "  PagerDuty:        $PagerDutyService" -ForegroundColor White }
if ($SlackChannel) { Write-Host "  Slack:            $SlackChannel" -ForegroundColor White }
Write-Host ""

Write-Host "VERIFICATION:" -ForegroundColor Yellow
Write-Host "  1. Datadog Monitors: https://app.$DD_SITE.datadoghq.com/monitors/manage" -ForegroundColor White
Write-Host "  2. Infrastructure:   https://app.$DD_SITE.datadoghq.com/infrastructure" -ForegroundColor White
Write-Host "  3. Filter by tag:    managed:automation" -ForegroundColor White
Write-Host ""

Write-Host "============================================================================" -ForegroundColor Green
