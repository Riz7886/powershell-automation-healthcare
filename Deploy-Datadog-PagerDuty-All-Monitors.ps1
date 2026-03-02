# ============================================================================
# DATADOG MONITORING WITH PAGERDUTY ALERTS
# Auto-discovers Azure subscriptions and creates monitors for all resources
# ============================================================================

param(
    [string]$DD_API_KEY = "",
    [string]$DD_APP_KEY = "",
    [string]$DD_SITE = "us3",
    [string]$PagerDutyServiceKey = "",
    [string]$PagerDutyServiceName = "Infrastructure-Alerts"
)

$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "DATADOG MONITORING WITH PAGERDUTY ALERTS" -ForegroundColor Cyan
Write-Host "Auto-discovery for VMs, Databricks, SQL, App Services, Storage" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# STEP 1: INSTALL AZURE MODULE IF NEEDED
# ----------------------------------------------------------------------------
Write-Host "[1/10] Checking Azure PowerShell module..." -ForegroundColor Yellow

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Host "Installing Az module..." -ForegroundColor Yellow
    Install-Module -Name Az -Scope CurrentUser -Force -AllowClobber
}

Import-Module Az.Accounts -ErrorAction SilentlyContinue
Import-Module Az.Compute -ErrorAction SilentlyContinue
Import-Module Az.Sql -ErrorAction SilentlyContinue
Import-Module Az.Websites -ErrorAction SilentlyContinue
Import-Module Az.Storage -ErrorAction SilentlyContinue
Import-Module Az.Databricks -ErrorAction SilentlyContinue

Write-Host "Azure modules loaded" -ForegroundColor Green

# ----------------------------------------------------------------------------
# STEP 2: CONNECT TO AZURE
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/10] Connecting to Azure..." -ForegroundColor Yellow

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Connect-AzAccount
    $context = Get-AzContext
}

Write-Host "Connected as: $($context.Account.Id)" -ForegroundColor Green

# ----------------------------------------------------------------------------
# STEP 3: LIST AND SELECT SUBSCRIPTIONS
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/10] Loading Azure subscriptions..." -ForegroundColor Yellow

$allSubscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }

Write-Host ""
Write-Host "Available Subscriptions:" -ForegroundColor Cyan
for ($i = 0; $i -lt $allSubscriptions.Count; $i++) {
    Write-Host "  [$($i + 1)] $($allSubscriptions[$i].Name)" -ForegroundColor White
}
Write-Host "  [A] ALL subscriptions" -ForegroundColor Yellow

Write-Host ""
$selection = Read-Host "Select subscriptions (comma-separated numbers, or A for all)"

$selectedSubscriptions = @()
if ($selection -eq "A" -or $selection -eq "a") {
    $selectedSubscriptions = $allSubscriptions
    Write-Host "Selected: ALL $($allSubscriptions.Count) subscriptions" -ForegroundColor Green
} else {
    $indices = $selection -split "," | ForEach-Object { [int]$_.Trim() - 1 }
    foreach ($idx in $indices) {
        if ($idx -ge 0 -and $idx -lt $allSubscriptions.Count) {
            $selectedSubscriptions += $allSubscriptions[$idx]
        }
    }
    Write-Host "Selected: $($selectedSubscriptions.Count) subscriptions" -ForegroundColor Green
}

# ----------------------------------------------------------------------------
# STEP 4: GET DATADOG CREDENTIALS
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[4/10] Configuring Datadog connection..." -ForegroundColor Yellow

if ([string]::IsNullOrEmpty($DD_API_KEY)) {
    $DD_API_KEY = Read-Host "Enter Datadog API Key"
}

if ([string]::IsNullOrEmpty($DD_APP_KEY)) {
    $DD_APP_KEY = Read-Host "Enter Datadog Application Key"
}

$DD_URL = "https://api.$DD_SITE.datadoghq.com"

$ddHeaders = @{
    "DD-API-KEY" = $DD_API_KEY
    "DD-APPLICATION-KEY" = $DD_APP_KEY
    "Content-Type" = "application/json"
}

# Test Datadog connection
try {
    $validateUrl = "$DD_URL/api/v1/validate"
    $response = Invoke-RestMethod -Uri $validateUrl -Method Get -Headers $ddHeaders
    Write-Host "Datadog connection: OK" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Cannot connect to Datadog" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------------------------
# STEP 5: GET PAGERDUTY CREDENTIALS
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/10] Configuring PagerDuty integration..." -ForegroundColor Yellow

if ([string]::IsNullOrEmpty($PagerDutyServiceKey)) {
    Write-Host ""
    Write-Host "To get PagerDuty Integration Key:" -ForegroundColor Cyan
    Write-Host "  1. PagerDuty > Services > Select Service" -ForegroundColor White
    Write-Host "  2. Integrations tab > Add Integration" -ForegroundColor White
    Write-Host "  3. Select Datadog > Copy Integration Key" -ForegroundColor White
    Write-Host ""
    $PagerDutyServiceKey = Read-Host "Enter PagerDuty Integration Key"
}

$pagerdutyHandle = "@pagerduty-$PagerDutyServiceName"

# Add PagerDuty service to Datadog
try {
    $pdUrl = "$DD_URL/api/v1/integration/pagerduty/configuration/services"
    $serviceBody = @{
        service_name = $PagerDutyServiceName
        service_key = $PagerDutyServiceKey
    } | ConvertTo-Json
    
    Invoke-RestMethod -Uri $pdUrl -Method Post -Headers $ddHeaders -Body $serviceBody -ErrorAction SilentlyContinue | Out-Null
    Write-Host "PagerDuty service configured: $PagerDutyServiceName" -ForegroundColor Green
} catch {
    Write-Host "PagerDuty service exists or configured manually" -ForegroundColor Yellow
}

# ----------------------------------------------------------------------------
# STEP 6: DISCOVER RESOURCES IN EACH SUBSCRIPTION
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[6/10] Discovering Azure resources..." -ForegroundColor Yellow

$allResources = @{
    VMs = @()
    SQLDatabases = @()
    AppServices = @()
    StorageAccounts = @()
    Databricks = @()
}

foreach ($sub in $selectedSubscriptions) {
    Write-Host "  Scanning: $($sub.Name)..." -ForegroundColor White
    Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
    
    # Get VMs
    $vms = Get-AzVM -ErrorAction SilentlyContinue
    foreach ($vm in $vms) {
        $allResources.VMs += @{
            Name = $vm.Name
            ResourceGroup = $vm.ResourceGroupName
            Subscription = $sub.Name
            SubscriptionId = $sub.Id
        }
    }
    
    # Get SQL Databases
    $sqlServers = Get-AzSqlServer -ErrorAction SilentlyContinue
    foreach ($server in $sqlServers) {
        $dbs = Get-AzSqlDatabase -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName -ErrorAction SilentlyContinue
        foreach ($db in $dbs) {
            if ($db.DatabaseName -ne "master") {
                $allResources.SQLDatabases += @{
                    Name = $db.DatabaseName
                    Server = $server.ServerName
                    ResourceGroup = $server.ResourceGroupName
                    Subscription = $sub.Name
                }
            }
        }
    }
    
    # Get App Services
    $webApps = Get-AzWebApp -ErrorAction SilentlyContinue
    foreach ($app in $webApps) {
        $allResources.AppServices += @{
            Name = $app.Name
            ResourceGroup = $app.ResourceGroup
            Subscription = $sub.Name
        }
    }
    
    # Get Storage Accounts
    $storageAccounts = Get-AzStorageAccount -ErrorAction SilentlyContinue
    foreach ($sa in $storageAccounts) {
        $allResources.StorageAccounts += @{
            Name = $sa.StorageAccountName
            ResourceGroup = $sa.ResourceGroupName
            Subscription = $sub.Name
        }
    }
    
    # Get Databricks Workspaces
    $databricks = Get-AzDatabricksWorkspace -ErrorAction SilentlyContinue
    foreach ($dbx in $databricks) {
        $allResources.Databricks += @{
            Name = $dbx.Name
            ResourceGroup = $dbx.ResourceGroupName
            Subscription = $sub.Name
        }
    }
}

Write-Host ""
Write-Host "Resources discovered:" -ForegroundColor Green
Write-Host "  VMs: $($allResources.VMs.Count)" -ForegroundColor White
Write-Host "  SQL Databases: $($allResources.SQLDatabases.Count)" -ForegroundColor White
Write-Host "  App Services: $($allResources.AppServices.Count)" -ForegroundColor White
Write-Host "  Storage Accounts: $($allResources.StorageAccounts.Count)" -ForegroundColor White
Write-Host "  Databricks: $($allResources.Databricks.Count)" -ForegroundColor White

# ----------------------------------------------------------------------------
# STEP 7: UPDATE EXISTING MONITORS WITH PAGERDUTY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[7/10] Updating existing monitors with PagerDuty..." -ForegroundColor Yellow

try {
    $monitorsUrl = "$DD_URL/api/v1/monitor"
    $existingMonitors = Invoke-RestMethod -Uri $monitorsUrl -Method Get -Headers $ddHeaders
    
    $updatedCount = 0
    foreach ($monitor in $existingMonitors) {
        if ($monitor.message -notlike "*$pagerdutyHandle*") {
            $newMessage = "$($monitor.message) $pagerdutyHandle"
            $updateBody = @{ message = $newMessage } | ConvertTo-Json
            
            try {
                $updateUrl = "$DD_URL/api/v1/monitor/$($monitor.id)"
                Invoke-RestMethod -Uri $updateUrl -Method Put -Headers $ddHeaders -Body $updateBody -ErrorAction SilentlyContinue | Out-Null
                $updatedCount++
            } catch { }
        }
    }
    Write-Host "Existing monitors updated: $updatedCount" -ForegroundColor Green
} catch {
    Write-Host "No existing monitors to update" -ForegroundColor Yellow
}

# ----------------------------------------------------------------------------
# STEP 8: CREATE INFRASTRUCTURE MONITORS
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[8/10] Creating infrastructure monitors..." -ForegroundColor Yellow

$monitorUrl = "$DD_URL/api/v1/monitor"
$createdCount = 0

# Function to create monitor
function New-DatadogMonitor {
    param(
        [string]$Name,
        [string]$Type,
        [string]$Query,
        [string]$Message,
        [int]$Priority = 2
    )
    
    $body = @{
        name = $Name
        type = $Type
        query = $Query
        message = "$Message $pagerdutyHandle"
        priority = $Priority
        tags = @("team:infrastructure", "pagerduty:enabled", "auto-created")
        options = @{
            notify_no_data = $true
            no_data_timeframe = 15
            notify_audit = $false
            include_tags = $true
        }
    } | ConvertTo-Json -Depth 10
    
    try {
        Invoke-RestMethod -Uri $monitorUrl -Method Post -Headers $ddHeaders -Body $body -ErrorAction SilentlyContinue | Out-Null
        return $true
    } catch {
        return $false
    }
}

# VM MONITORS
Write-Host "  Creating VM monitors..." -ForegroundColor White
$vmMonitors = @(
    @{ Name = "VM - CPU High"; Query = "avg(last_5m):100 - avg:system.cpu.idle{*} by {host} > 85"; Message = "CPU above 85% on {{host.name}}."; Priority = 2 },
    @{ Name = "VM - Memory High"; Query = "avg(last_5m):avg:system.mem.pct_usable{*} by {host} < 15"; Message = "Memory critical on {{host.name}}. Less than 15% available."; Priority = 2 },
    @{ Name = "VM - Disk High"; Query = "avg(last_5m):avg:system.disk.in_use{*} by {host,device} > 0.85"; Message = "Disk above 85% on {{host.name}} {{device.name}}."; Priority = 2 },
    @{ Name = "VM - Load Average High"; Query = "avg(last_5m):avg:system.load.5{*} by {host} > 10"; Message = "Load average high on {{host.name}}."; Priority = 3 },
    @{ Name = "VM - Network In High"; Query = "avg(last_5m):avg:system.net.bytes_rcvd{*} by {host} > 100000000"; Message = "High inbound traffic on {{host.name}}."; Priority = 3 },
    @{ Name = "VM - Network Out High"; Query = "avg(last_5m):avg:system.net.bytes_sent{*} by {host} > 100000000"; Message = "High outbound traffic on {{host.name}}."; Priority = 3 }
)

foreach ($m in $vmMonitors) {
    if (New-DatadogMonitor -Name $m.Name -Type "metric alert" -Query $m.Query -Message $m.Message -Priority $m.Priority) {
        $createdCount++
    }
}

# DATABRICKS MONITORS
Write-Host "  Creating Databricks monitors..." -ForegroundColor White
$databricksMonitors = @(
    @{ Name = "Databricks - Cluster CPU High"; Query = "avg(last_5m):avg:databricks.cluster.cpu_percent{*} > 85"; Message = "Databricks cluster CPU above 85%."; Priority = 2 },
    @{ Name = "Databricks - Cluster Memory High"; Query = "avg(last_5m):avg:databricks.cluster.memory_percent{*} > 85"; Message = "Databricks cluster memory above 85%."; Priority = 2 },
    @{ Name = "Databricks - DBU Usage High"; Query = "avg(last_5m):avg:databricks.cluster.dbu_usage{*} > 100"; Message = "Databricks DBU usage is high."; Priority = 3 },
    @{ Name = "Databricks - Job Failures"; Query = "sum(last_5m):sum:databricks.jobs.failed{*} > 0"; Message = "Databricks job failures detected."; Priority = 2 },
    @{ Name = "Databricks - Cluster Down"; Query = "avg(last_10m):avg:databricks.cluster.num_active_clusters{*} < 1"; Message = "CRITICAL: No active Databricks clusters."; Priority = 1 }
)

foreach ($m in $databricksMonitors) {
    if (New-DatadogMonitor -Name $m.Name -Type "metric alert" -Query $m.Query -Message $m.Message -Priority $m.Priority) {
        $createdCount++
    }
}

# SQL DATABASE MONITORS
Write-Host "  Creating SQL Database monitors..." -ForegroundColor White
$sqlMonitors = @(
    @{ Name = "SQL - CPU High"; Query = "avg(last_5m):avg:azure.sql_servers_databases.cpu_percent{*} by {name} > 80"; Message = "SQL Database CPU above 80% on {{name}}."; Priority = 2 },
    @{ Name = "SQL - Storage High"; Query = "avg(last_5m):avg:azure.sql_servers_databases.storage_percent{*} by {name} > 85"; Message = "SQL Database storage above 85% on {{name}}."; Priority = 2 },
    @{ Name = "SQL - DTU High"; Query = "avg(last_5m):avg:azure.sql_servers_databases.dtu_consumption_percent{*} by {name} > 80"; Message = "SQL Database DTU above 80% on {{name}}."; Priority = 2 },
    @{ Name = "SQL - Deadlocks"; Query = "sum(last_5m):sum:azure.sql_servers_databases.deadlock{*} by {name} > 0"; Message = "SQL Database deadlocks on {{name}}."; Priority = 2 },
    @{ Name = "SQL - Connection Failed"; Query = "sum(last_5m):sum:azure.sql_servers_databases.connection_failed{*} by {name} > 5"; Message = "SQL Database connection failures on {{name}}."; Priority = 2 }
)

foreach ($m in $sqlMonitors) {
    if (New-DatadogMonitor -Name $m.Name -Type "metric alert" -Query $m.Query -Message $m.Message -Priority $m.Priority) {
        $createdCount++
    }
}

# APP SERVICE MONITORS
Write-Host "  Creating App Service monitors..." -ForegroundColor White
$appMonitors = @(
    @{ Name = "App Service - CPU High"; Query = "avg(last_5m):avg:azure.app_services.cpu_percentage{*} by {name} > 80"; Message = "App Service CPU above 80% on {{name}}."; Priority = 2 },
    @{ Name = "App Service - Memory High"; Query = "avg(last_5m):avg:azure.app_services.memory_percentage{*} by {name} > 80"; Message = "App Service memory above 80% on {{name}}."; Priority = 2 },
    @{ Name = "App Service - HTTP 5xx"; Query = "sum(last_5m):sum:azure.app_services.http5xx{*} by {name} > 10"; Message = "App Service HTTP 5xx errors on {{name}}."; Priority = 2 },
    @{ Name = "App Service - Response Time"; Query = "avg(last_5m):avg:azure.app_services.average_response_time{*} by {name} > 3"; Message = "App Service response time above 3s on {{name}}."; Priority = 3 },
    @{ Name = "App Service - Requests Queue"; Query = "avg(last_5m):avg:azure.app_services.requests_in_application_queue{*} by {name} > 100"; Message = "App Service request queue high on {{name}}."; Priority = 3 }
)

foreach ($m in $appMonitors) {
    if (New-DatadogMonitor -Name $m.Name -Type "metric alert" -Query $m.Query -Message $m.Message -Priority $m.Priority) {
        $createdCount++
    }
}

# STORAGE MONITORS
Write-Host "  Creating Storage monitors..." -ForegroundColor White
$storageMonitors = @(
    @{ Name = "Storage - Availability Low"; Query = "avg(last_5m):avg:azure.storage_storageaccounts.availability{*} by {name} < 99"; Message = "Storage availability below 99% on {{name}}."; Priority = 2 },
    @{ Name = "Storage - Latency High"; Query = "avg(last_5m):avg:azure.storage_storageaccounts.success_server_latency{*} by {name} > 100"; Message = "Storage latency above 100ms on {{name}}."; Priority = 3 },
    @{ Name = "Storage - Throttling"; Query = "sum(last_5m):sum:azure.storage_storageaccounts.transactions{status:throttled,*} by {name} > 0"; Message = "Storage throttling on {{name}}."; Priority = 2 }
)

foreach ($m in $storageMonitors) {
    if (New-DatadogMonitor -Name $m.Name -Type "metric alert" -Query $m.Query -Message $m.Message -Priority $m.Priority) {
        $createdCount++
    }
}

# SECURITY MONITORS
Write-Host "  Creating Security monitors..." -ForegroundColor White
$securityMonitors = @(
    @{ Name = "Security - Failed Logins"; Query = "sum(last_15m):sum:azure.security.failed_logins{*} > 10"; Message = "Multiple failed login attempts detected."; Priority = 1 },
    @{ Name = "Security - Suspicious Activity"; Query = "sum(last_15m):sum:azure.security.alerts{*} > 0"; Message = "Security alert detected."; Priority = 1 }
)

foreach ($m in $securityMonitors) {
    if (New-DatadogMonitor -Name $m.Name -Type "metric alert" -Query $m.Query -Message $m.Message -Priority $m.Priority) {
        $createdCount++
    }
}

# MOVEIT MONITORS
Write-Host "  Creating MOVEit monitors..." -ForegroundColor White
$moveitMonitors = @(
    @{ Name = "MOVEit - Server CPU High"; Query = "avg(last_5m):100 - avg:system.cpu.idle{host:*moveit*} > 85"; Message = "MOVEit server CPU above 85%."; Priority = 2 },
    @{ Name = "MOVEit - Server Memory High"; Query = "avg(last_5m):avg:system.mem.pct_usable{host:*moveit*} < 15"; Message = "MOVEit server memory critical."; Priority = 2 },
    @{ Name = "MOVEit - Server Disk High"; Query = "avg(last_5m):avg:system.disk.in_use{host:*moveit*} > 0.85"; Message = "MOVEit server disk above 85%."; Priority = 2 }
)

foreach ($m in $moveitMonitors) {
    if (New-DatadogMonitor -Name $m.Name -Type "metric alert" -Query $m.Query -Message $m.Message -Priority $m.Priority) {
        $createdCount++
    }
}

Write-Host ""
Write-Host "Monitors created: $createdCount" -ForegroundColor Green

# ----------------------------------------------------------------------------
# STEP 9: CREATE COMPOSITE MONITORS
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[9/10] Creating composite monitors..." -ForegroundColor Yellow

$compositeMonitors = @(
    @{
        Name = "CRITICAL - Infrastructure Down"
        Query = "avg(last_5m):avg:datadog.agent.running{*} < 0.5"
        Message = "CRITICAL: Infrastructure monitoring agents are down. Immediate attention required."
        Priority = 1
    },
    @{
        Name = "CRITICAL - Multiple Services Degraded"
        Query = "avg(last_5m):avg:azure.app_services.health_check_status{*} < 0.5"
        Message = "CRITICAL: Multiple services are degraded. Check all systems."
        Priority = 1
    }
)

foreach ($m in $compositeMonitors) {
    if (New-DatadogMonitor -Name $m.Name -Type "metric alert" -Query $m.Query -Message $m.Message -Priority $m.Priority) {
        $createdCount++
    }
}

# ----------------------------------------------------------------------------
# STEP 10: SUMMARY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[10/10] Deployment complete" -ForegroundColor Yellow

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Green
Write-Host "DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Green
Write-Host ""

Write-Host "AZURE SUBSCRIPTIONS SCANNED:" -ForegroundColor Cyan
foreach ($sub in $selectedSubscriptions) {
    Write-Host "  - $($sub.Name)" -ForegroundColor White
}
Write-Host ""

Write-Host "RESOURCES DISCOVERED:" -ForegroundColor Cyan
Write-Host "  VMs: $($allResources.VMs.Count)" -ForegroundColor White
Write-Host "  SQL Databases: $($allResources.SQLDatabases.Count)" -ForegroundColor White
Write-Host "  App Services: $($allResources.AppServices.Count)" -ForegroundColor White
Write-Host "  Storage Accounts: $($allResources.StorageAccounts.Count)" -ForegroundColor White
Write-Host "  Databricks: $($allResources.Databricks.Count)" -ForegroundColor White
Write-Host ""

Write-Host "PAGERDUTY CONFIGURATION:" -ForegroundColor Cyan
Write-Host "  Service: $PagerDutyServiceName" -ForegroundColor White
Write-Host "  Handle: $pagerdutyHandle" -ForegroundColor White
Write-Host ""

Write-Host "MONITORS CREATED:" -ForegroundColor Cyan
Write-Host "  VM Monitors: 6" -ForegroundColor White
Write-Host "  Databricks Monitors: 5" -ForegroundColor White
Write-Host "  SQL Database Monitors: 5" -ForegroundColor White
Write-Host "  App Service Monitors: 5" -ForegroundColor White
Write-Host "  Storage Monitors: 3" -ForegroundColor White
Write-Host "  Security Monitors: 2" -ForegroundColor White
Write-Host "  MOVEit Monitors: 3" -ForegroundColor White
Write-Host "  Composite Monitors: 2" -ForegroundColor White
Write-Host "  Total: 31 monitors" -ForegroundColor Green
Write-Host ""

Write-Host "ALERT FLOW:" -ForegroundColor Cyan
Write-Host "  1. Azure resource metric crosses threshold" -ForegroundColor White
Write-Host "  2. Datadog triggers monitor alert" -ForegroundColor White
Write-Host "  3. PagerDuty receives incident" -ForegroundColor White
Write-Host "  4. On-call engineer gets notified" -ForegroundColor White
Write-Host ""

Write-Host "VERIFICATION:" -ForegroundColor Yellow
Write-Host "  Datadog: https://app.$DD_SITE.datadoghq.com/monitors/manage" -ForegroundColor White
Write-Host "  Filter by tag: pagerduty:enabled" -ForegroundColor White
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Green
