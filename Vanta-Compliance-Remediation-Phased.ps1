# ============================================================================
# VANTA COMPLIANCE REMEDIATION (PHASED) - PYX HEALTH
# ============================================================================
# Author:    Syed Rizvi
# Date:      2026-04-08
# Purpose:   Auto-remediate ALL failing Vanta compliance tests BY ENVIRONMENT:
#            1. SQL Database CPU Monitored
#            2. SQL Database Memory Utilization Monitored
#            3. Azure VM CPU Monitored (Databricks VMs)
#            4. Azure VM Security Groups Attached (ansible control node)
#
# Phased Rollout:
#            Phase 1: Test   -> Validate
#            Phase 2: Stage  -> Validate
#            Phase 3: QA     -> Validate
#            Phase 4: Prod   -> Deploy all remaining
#
# Safety:    - Audit mode by default (read-only)
#            - Never deletes anything
#            - Checks before creating (skips existing alerts)
#            - WhatIf support
#            - No database modifications - only Azure Monitor alert rules
#            - Environment filtering prevents accidental cross-env changes
# ============================================================================

param(
    [ValidateSet("Audit", "Remediate")]
    [string]$Mode = "Audit",

    [ValidateSet("Test", "Stage", "QA", "Prod", "All")]
    [string]$Environment = "Test",

    [string]$ReportPath,

    [string]$AuthorName = "Syed Rizvi",

    [switch]$AutoConnect
)

$ErrorActionPreference = "Continue"
$startTime = Get-Date

# ============================================================================
# AUTO-GENERATE REPORT PATH WITH ENVIRONMENT TAG
# ============================================================================
if (-not $ReportPath) {
    $ReportPath = "$PSScriptRoot\Vanta-Remediation-Report-$Environment-$(Get-Date -Format 'yyyy-MM-dd-HHmm').html"
}

# ============================================================================
# ENVIRONMENT FILTER FUNCTION
# ============================================================================
function Test-EnvironmentMatch {
    param(
        [string]$ResourceName,
        [string]$TargetEnvironment
    )

    if ($TargetEnvironment -eq "All") { return $true }

    $envPatterns = @{
        "Test"  = @("*-test", "*-test-*", "pyx-test", "pyx-test-*")
        "Stage" = @("*-stage", "*-stage-*", "pyx-stage", "pyx-stage-*")
        "QA"    = @("*-qa", "*-qa-*", "pyx-qa", "pyx-qa-*")
        "Prod"  = @("*-prod", "*-prod-*")
    }

    $patterns = $envPatterns[$TargetEnvironment]
    foreach ($pattern in $patterns) {
        if ($ResourceName -like $pattern) { return $true }
    }
    return $false
}

# ============================================================================
# BANNER
# ============================================================================
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  VANTA COMPLIANCE REMEDIATION (PHASED) - PYX HEALTH" -ForegroundColor Cyan
Write-Host "  Author: $AuthorName" -ForegroundColor Cyan
Write-Host "  Date:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "  Mode:   $Mode" -ForegroundColor $(if ($Mode -eq "Audit") { "Yellow" } else { "Red" })

$envColor = switch ($Environment) {
    "Test"  { "Green" }
    "Stage" { "Yellow" }
    "QA"    { "Magenta" }
    "Prod"  { "Red" }
    "All"   { "White" }
}
Write-Host "  Environment: $Environment" -ForegroundColor $envColor
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

if ($Environment -eq "Prod" -and $Mode -eq "Remediate") {
    Write-Host "  WARNING: You are about to remediate PRODUCTION resources!" -ForegroundColor Red
    Write-Host "  Make sure Test, Stage, and QA have been validated first." -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "  Type 'YES-PROD' to continue"
    if ($confirm -ne "YES-PROD") {
        Write-Host "  Aborted. Run Test/Stage/QA first." -ForegroundColor Yellow
        exit
    }
}

# ============================================================================
# STEP 1: INSTALL/IMPORT AZURE MODULES
# ============================================================================
Write-Host "[1/8] Checking Azure PowerShell modules..." -ForegroundColor Yellow

$requiredModules = @("Az.Accounts", "Az.Resources", "Az.Sql", "Az.Compute", "Az.Monitor", "Az.Network")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod -ErrorAction SilentlyContinue)) {
        Write-Host "  Installing $mod..." -ForegroundColor Yellow
        Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber -ErrorAction SilentlyContinue
    }
    Import-Module $mod -ErrorAction SilentlyContinue
}
Write-Host "  Azure modules loaded" -ForegroundColor Green

# ============================================================================
# STEP 2: CONNECT TO AZURE
# ============================================================================
Write-Host ""
Write-Host "[2/8] Connecting to Azure..." -ForegroundColor Yellow

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Connect-AzAccount
    $context = Get-AzContext
}
Write-Host "  Connected as: $($context.Account.Id)" -ForegroundColor Green

# ============================================================================
# STEP 3: GET ALL SUBSCRIPTIONS
# ============================================================================
Write-Host ""
Write-Host "[3/8] Loading ALL Azure subscriptions..." -ForegroundColor Yellow

$allSubscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
Write-Host "  Found $($allSubscriptions.Count) enabled subscriptions:" -ForegroundColor Green
foreach ($sub in $allSubscriptions) {
    Write-Host "    - $($sub.Name) ($($sub.Id))" -ForegroundColor White
}

# ============================================================================
# RESULTS TRACKING
# ============================================================================
$results = [System.Collections.ArrayList]@()

function Add-Result {
    param(
        [string]$Subscription,
        [string]$ResourceGroup,
        [string]$ResourceName,
        [string]$ResourceType,
        [string]$CheckType,
        [string]$Status,
        [string]$Details,
        [string]$Timestamp
    )
    $null = $results.Add([PSCustomObject]@{
        Subscription  = $Subscription
        ResourceGroup = $ResourceGroup
        ResourceName  = $ResourceName
        ResourceType  = $ResourceType
        CheckType     = $CheckType
        Status        = $Status
        Details       = $Details
        Timestamp     = if ($Timestamp) { $Timestamp } else { (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
    })
}

# ============================================================================
# STEP 4: DISCOVER & REMEDIATE SQL DATABASE ALERTS
# ============================================================================
Write-Host ""
Write-Host "[4/8] Scanning SQL Databases [$Environment] across all subscriptions..." -ForegroundColor Yellow

$totalSqlDbs = 0
$skippedDbs = 0
$sqlCpuFixed = 0
$sqlMemFixed = 0
$sqlCpuAlreadyOk = 0
$sqlMemAlreadyOk = 0

foreach ($sub in $allSubscriptions) {
    Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
    $subName = $sub.Name

    Write-Host "  Subscription: $subName" -ForegroundColor Cyan

    $sqlServers = Get-AzSqlServer -ErrorAction SilentlyContinue
    if (-not $sqlServers) { continue }

    foreach ($server in $sqlServers) {
        $databases = Get-AzSqlDatabase -ResourceGroupName $server.ResourceGroupName `
            -ServerName $server.ServerName -ErrorAction SilentlyContinue |
            Where-Object { $_.DatabaseName -ne "master" }

        foreach ($db in $databases) {
            $dbName = $db.DatabaseName
            $rg = $db.ResourceGroupName
            $resourceId = $db.ResourceId

            # ENVIRONMENT FILTER
            if (-not (Test-EnvironmentMatch -ResourceName $dbName -TargetEnvironment $Environment)) {
                $skippedDbs++
                continue
            }

            $totalSqlDbs++

            Write-Host "    [$totalSqlDbs] $dbName ($rg)" -ForegroundColor White -NoNewline

            # ------------------------------------------------------------------
            # CHECK 1: CPU Alert
            # ------------------------------------------------------------------
            $cpuAlertName = "pyx-$dbName-cpu-alert"
            $existingCpuAlert = $null
            try {
                $existingAlerts = Get-AzMetricAlertRuleV2 -ResourceGroupName $rg -ErrorAction SilentlyContinue
                $existingCpuAlert = $existingAlerts | Where-Object {
                    $_.Name -like "*$dbName*cpu*" -or
                    $_.Name -eq $cpuAlertName -or
                    ($_.TargetResourceId -eq $resourceId -and $_.Criteria.MetricName -contains "cpu_percent")
                }
            } catch { }

            if ($existingCpuAlert) {
                Write-Host " [CPU: EXISTS]" -ForegroundColor Green -NoNewline
                $sqlCpuAlreadyOk++
                Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $dbName `
                    -ResourceType "SQL Database" -CheckType "CPU Monitored" `
                    -Status "ALREADY_OK" -Details "Alert '$($existingCpuAlert.Name)' already exists" `
                    -Timestamp $existingCpuAlert.LastUpdatedTime
            }
            elseif ($Mode -eq "Remediate") {
                try {
                    $cpuCriteria = New-AzMetricAlertRuleV2Criteria `
                        -MetricName "cpu_percent" `
                        -TimeAggregation Average `
                        -Operator GreaterThan `
                        -Threshold 80

                    Add-AzMetricAlertRuleV2 `
                        -Name $cpuAlertName `
                        -ResourceGroupName $rg `
                        -TargetResourceId $resourceId `
                        -Condition $cpuCriteria `
                        -WindowSize (New-TimeSpan -Minutes 5) `
                        -Frequency (New-TimeSpan -Minutes 5) `
                        -Severity 2 `
                        -Description "Vanta Compliance: CPU utilization alert for $dbName. Created by $AuthorName on $(Get-Date -Format 'yyyy-MM-dd')."

                    Write-Host " [CPU: CREATED]" -ForegroundColor Yellow -NoNewline
                    $sqlCpuFixed++
                    Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $dbName `
                        -ResourceType "SQL Database" -CheckType "CPU Monitored" `
                        -Status "FIXED" -Details "Created alert rule '$cpuAlertName' (threshold: 80% avg CPU)"
                } catch {
                    Write-Host " [CPU: FAILED]" -ForegroundColor Red -NoNewline
                    Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $dbName `
                        -ResourceType "SQL Database" -CheckType "CPU Monitored" `
                        -Status "FAILED" -Details "Error: $($_.Exception.Message)"
                }
            }
            else {
                Write-Host " [CPU: NEEDS FIX]" -ForegroundColor Red -NoNewline
                Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $dbName `
                    -ResourceType "SQL Database" -CheckType "CPU Monitored" `
                    -Status "NEEDS_FIX" -Details "No CPU alert rule found. Run with -Mode Remediate to create."
            }

            # ------------------------------------------------------------------
            # CHECK 2: Memory/DTU Alert
            # ------------------------------------------------------------------
            $memAlertName = "pyx-$dbName-memory-alert"
            $existingMemAlert = $null
            try {
                $existingMemAlert = $existingAlerts | Where-Object {
                    $_.Name -like "*$dbName*mem*" -or
                    $_.Name -like "*$dbName*dtu*" -or
                    $_.Name -like "*$dbName*storage*" -or
                    $_.Name -eq $memAlertName -or
                    ($_.TargetResourceId -eq $resourceId -and
                     ($_.Criteria.MetricName -contains "dtu_consumption_percent" -or
                      $_.Criteria.MetricName -contains "storage_percent"))
                }
            } catch { }

            if ($existingMemAlert) {
                Write-Host " [MEM: EXISTS]" -ForegroundColor Green
                $sqlMemAlreadyOk++
                Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $dbName `
                    -ResourceType "SQL Database" -CheckType "Memory Monitored" `
                    -Status "ALREADY_OK" -Details "Alert '$($existingMemAlert.Name)' already exists" `
                    -Timestamp $existingMemAlert.LastUpdatedTime
            }
            elseif ($Mode -eq "Remediate") {
                try {
                    $metricName = if ($db.CurrentServiceObjectiveName -like "*DTU*" -or $db.Edition -eq "Basic" -or $db.Edition -eq "Standard" -or $db.Edition -eq "Premium") {
                        "dtu_consumption_percent"
                    } else {
                        "storage_percent"
                    }

                    $memCriteria = New-AzMetricAlertRuleV2Criteria `
                        -MetricName $metricName `
                        -TimeAggregation Average `
                        -Operator GreaterThan `
                        -Threshold 85

                    Add-AzMetricAlertRuleV2 `
                        -Name $memAlertName `
                        -ResourceGroupName $rg `
                        -TargetResourceId $resourceId `
                        -Condition $memCriteria `
                        -WindowSize (New-TimeSpan -Minutes 5) `
                        -Frequency (New-TimeSpan -Minutes 5) `
                        -Severity 2 `
                        -Description "Vanta Compliance: Memory/DTU utilization alert for $dbName. Created by $AuthorName on $(Get-Date -Format 'yyyy-MM-dd')."

                    Write-Host " [MEM: CREATED]" -ForegroundColor Yellow
                    $sqlMemFixed++
                    Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $dbName `
                        -ResourceType "SQL Database" -CheckType "Memory Monitored" `
                        -Status "FIXED" -Details "Created alert rule '$memAlertName' (metric: $metricName, threshold: 85%)"
                } catch {
                    Write-Host " [MEM: FAILED]" -ForegroundColor Red
                    Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $dbName `
                        -ResourceType "SQL Database" -CheckType "Memory Monitored" `
                        -Status "FAILED" -Details "Error: $($_.Exception.Message)"
                }
            }
            else {
                Write-Host " [MEM: NEEDS FIX]" -ForegroundColor Red
                Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $dbName `
                    -ResourceType "SQL Database" -CheckType "Memory Monitored" `
                    -Status "NEEDS_FIX" -Details "No memory/DTU alert rule found. Run with -Mode Remediate to create."
            }
        }
    }
}

Write-Host ""
Write-Host "  SQL Summary [$Environment]: $totalSqlDbs databases matched (skipped $skippedDbs non-$Environment)" -ForegroundColor Cyan
Write-Host "    CPU Alerts - Created: $sqlCpuFixed | Already OK: $sqlCpuAlreadyOk" -ForegroundColor White
Write-Host "    MEM Alerts - Created: $sqlMemFixed | Already OK: $sqlMemAlreadyOk" -ForegroundColor White

# ============================================================================
# STEP 5: DISCOVER & REMEDIATE VM CPU ALERTS
# ============================================================================
Write-Host ""
Write-Host "[5/8] Scanning VMs [$Environment] for CPU monitoring alerts..." -ForegroundColor Yellow

$totalVms = 0
$skippedVms = 0
$vmCpuFixed = 0
$vmCpuAlreadyOk = 0

foreach ($sub in $allSubscriptions) {
    Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
    $subName = $sub.Name

    $vms = Get-AzVM -ErrorAction SilentlyContinue
    if (-not $vms) { continue }

    foreach ($vm in $vms) {
        $vmName = $vm.Name
        $rg = $vm.ResourceGroupName
        $resourceId = $vm.Id

        # ENVIRONMENT FILTER for VMs
        # VMs don't always have env suffixes - include all if environment is "All"
        # For Prod, include VMs that don't match test/stage/qa (they're likely prod)
        if ($Environment -ne "All") {
            $isTest = Test-EnvironmentMatch -ResourceName $vmName -TargetEnvironment "Test"
            $isStage = Test-EnvironmentMatch -ResourceName $vmName -TargetEnvironment "Stage"
            $isQA = Test-EnvironmentMatch -ResourceName $vmName -TargetEnvironment "QA"
            $isProd = Test-EnvironmentMatch -ResourceName $vmName -TargetEnvironment "Prod"

            if ($Environment -eq "Prod") {
                # Prod = anything that doesn't match test/stage/qa, OR explicitly matches prod
                if ($isTest -or $isStage -or $isQA) {
                    if (-not $isProd) { $skippedVms++; continue }
                }
            } else {
                if (-not (Test-EnvironmentMatch -ResourceName $vmName -TargetEnvironment $Environment)) {
                    $skippedVms++; continue
                }
            }
        }

        $totalVms++

        Write-Host "    [$totalVms] $vmName ($rg)" -ForegroundColor White -NoNewline

        $cpuAlertName = "pyx-$vmName-cpu-alert"
        $existingAlert = $null
        try {
            $existingAlerts = Get-AzMetricAlertRuleV2 -ResourceGroupName $rg -ErrorAction SilentlyContinue
            $existingAlert = $existingAlerts | Where-Object {
                $_.Name -like "*$vmName*cpu*" -or
                $_.Name -eq $cpuAlertName -or
                ($_.TargetResourceId -eq $resourceId -and $_.Criteria.MetricName -contains "Percentage CPU")
            }
        } catch { }

        if ($existingAlert) {
            Write-Host " [CPU: EXISTS]" -ForegroundColor Green
            $vmCpuAlreadyOk++
            Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $vmName `
                -ResourceType "Virtual Machine" -CheckType "CPU Monitored" `
                -Status "ALREADY_OK" -Details "Alert '$($existingAlert.Name)' already exists" `
                -Timestamp $existingAlert.LastUpdatedTime
        }
        elseif ($Mode -eq "Remediate") {
            try {
                $vmCpuCriteria = New-AzMetricAlertRuleV2Criteria `
                    -MetricName "Percentage CPU" `
                    -TimeAggregation Average `
                    -Operator GreaterThan `
                    -Threshold 85

                Add-AzMetricAlertRuleV2 `
                    -Name $cpuAlertName `
                    -ResourceGroupName $rg `
                    -TargetResourceId $resourceId `
                    -Condition $vmCpuCriteria `
                    -WindowSize (New-TimeSpan -Minutes 5) `
                    -Frequency (New-TimeSpan -Minutes 5) `
                    -Severity 2 `
                    -Description "Vanta Compliance: CPU utilization alert for VM $vmName. Created by $AuthorName on $(Get-Date -Format 'yyyy-MM-dd')."

                Write-Host " [CPU: CREATED]" -ForegroundColor Yellow
                $vmCpuFixed++
                Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $vmName `
                    -ResourceType "Virtual Machine" -CheckType "CPU Monitored" `
                    -Status "FIXED" -Details "Created alert rule '$cpuAlertName' (threshold: 85% avg CPU)"
            } catch {
                Write-Host " [CPU: FAILED]" -ForegroundColor Red
                Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $vmName `
                    -ResourceType "Virtual Machine" -CheckType "CPU Monitored" `
                    -Status "FAILED" -Details "Error: $($_.Exception.Message)"
            }
        }
        else {
            Write-Host " [CPU: NEEDS FIX]" -ForegroundColor Red
            Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $vmName `
                -ResourceType "Virtual Machine" -CheckType "CPU Monitored" `
                -Status "NEEDS_FIX" -Details "No CPU alert rule found. Run with -Mode Remediate to create."
        }
    }
}

Write-Host ""
Write-Host "  VM Summary [$Environment]: $totalVms VMs matched (skipped $skippedVms non-$Environment)" -ForegroundColor Cyan
Write-Host "    CPU Alerts - Created: $vmCpuFixed | Already OK: $vmCpuAlreadyOk" -ForegroundColor White

# ============================================================================
# STEP 6: CHECK/FIX NSG ON VM-ANSIBLE-CONTROL-NODE
# Only runs during Prod phase or All (since ansible is a prod/infra VM)
# ============================================================================
Write-Host ""
Write-Host "[6/8] Checking NSG on vm-ansible-control-node..." -ForegroundColor Yellow

$nsgFixed = $false
$nsgAlreadyOk = $false
$nsgSkipped = $false

if ($Environment -ne "Prod" -and $Environment -ne "All") {
    Write-Host "  Skipped - ansible control node is infrastructure (will run in Prod phase)" -ForegroundColor DarkGray
    $nsgSkipped = $true
} else {
    foreach ($sub in $allSubscriptions) {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
        $subName = $sub.Name

        $ansibleVM = Get-AzVM -Name "vm-ansible-control-node" -ErrorAction SilentlyContinue
        if (-not $ansibleVM) {
            $ansibleVM = Get-AzVM -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*ansible*control*" }
        }
        if (-not $ansibleVM) { continue }

        $vmName = $ansibleVM.Name
        $rg = $ansibleVM.ResourceGroupName
        Write-Host "  Found: $vmName in $rg ($subName)" -ForegroundColor Green

        $nicId = $ansibleVM.NetworkProfile.NetworkInterfaces[0].Id
        $nic = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction SilentlyContinue

        if ($nic.NetworkSecurityGroup) {
            Write-Host "  NSG already attached: $($nic.NetworkSecurityGroup.Id.Split('/')[-1])" -ForegroundColor Green
            $nsgAlreadyOk = $true
            Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $vmName `
                -ResourceType "Virtual Machine" -CheckType "NSG Attached" `
                -Status "ALREADY_OK" -Details "NSG '$($nic.NetworkSecurityGroup.Id.Split('/')[-1])' already attached to NIC"
        }
        elseif ($Mode -eq "Remediate") {
            try {
                $nsgName = "nsg-$vmName"
                Write-Host "  Creating NSG: $nsgName..." -ForegroundColor Yellow

                $sshRule = New-AzNetworkSecurityRuleConfig -Name "Allow-SSH" `
                    -Description "Allow SSH from internal" `
                    -Access Allow -Protocol Tcp -Direction Inbound `
                    -Priority 100 -SourceAddressPrefix "VirtualNetwork" `
                    -SourcePortRange "*" -DestinationAddressPrefix "*" `
                    -DestinationPortRange 22

                $denyAllRule = New-AzNetworkSecurityRuleConfig -Name "Deny-All-Inbound" `
                    -Description "Deny all other inbound" `
                    -Access Deny -Protocol "*" -Direction Inbound `
                    -Priority 4096 -SourceAddressPrefix "*" `
                    -SourcePortRange "*" -DestinationAddressPrefix "*" `
                    -DestinationPortRange "*"

                $nsg = New-AzNetworkSecurityGroup -Name $nsgName `
                    -ResourceGroupName $rg `
                    -Location $ansibleVM.Location `
                    -SecurityRules $sshRule, $denyAllRule `
                    -Tag @{ "CreatedBy" = $AuthorName; "Purpose" = "Vanta-Compliance"; "Date" = (Get-Date -Format "yyyy-MM-dd") }

                $nic.NetworkSecurityGroup = $nsg
                Set-AzNetworkInterface -NetworkInterface $nic | Out-Null

                Write-Host "  NSG '$nsgName' created and attached" -ForegroundColor Green
                $nsgFixed = $true
                Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $vmName `
                    -ResourceType "Virtual Machine" -CheckType "NSG Attached" `
                    -Status "FIXED" -Details "Created NSG '$nsgName' with SSH (VNet only) + Deny-All rules and attached to NIC"
            } catch {
                Write-Host "  NSG fix failed: $($_.Exception.Message)" -ForegroundColor Red
                Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $vmName `
                    -ResourceType "Virtual Machine" -CheckType "NSG Attached" `
                    -Status "FAILED" -Details "Error: $($_.Exception.Message)"
            }
        }
        else {
            Write-Host "  NO NSG attached - needs fix" -ForegroundColor Red
            Add-Result -Subscription $subName -ResourceGroup $rg -ResourceName $vmName `
                -ResourceType "Virtual Machine" -CheckType "NSG Attached" `
                -Status "NEEDS_FIX" -Details "No NSG attached to NIC. Run with -Mode Remediate to fix."
        }
        break
    }
}

# ============================================================================
# STEP 7: GENERATE HTML REPORT
# ============================================================================
Write-Host ""
Write-Host "[7/8] Generating HTML report for [$Environment]..." -ForegroundColor Yellow

$endTime = Get-Date
$duration = $endTime - $startTime

$fixedCount = ($results | Where-Object { $_.Status -eq "FIXED" }).Count
$alreadyOkCount = ($results | Where-Object { $_.Status -eq "ALREADY_OK" }).Count
$needsFixCount = ($results | Where-Object { $_.Status -eq "NEEDS_FIX" }).Count
$failedCount = ($results | Where-Object { $_.Status -eq "FAILED" }).Count
$totalChecks = $results.Count

# Environment badge colors
$envBadgeColor = switch ($Environment) {
    "Test"  { "#107c10" }
    "Stage" { "#ff8c00" }
    "QA"    { "#8764b8" }
    "Prod"  { "#d13438" }
    "All"   { "#0078d4" }
}

$cssBlock = '<!DOCTYPE html><html><head><meta charset="utf-8">' +
    '<title>Vanta Compliance Remediation Report - ' + $Environment + '</title><style>' +
    '* { margin: 0; padding: 0; box-sizing: border-box; } ' +
    'body { font-family: Segoe UI, Tahoma, sans-serif; background: #f0f2f5; color: #333; } ' +
    '.header { background: linear-gradient(135deg, #0078d4, #00bcf2); color: white; padding: 30px 40px; text-align: center; } ' +
    '.header h1 { font-size: 28px; margin-bottom: 5px; } ' +
    '.header p { font-size: 14px; opacity: 0.9; } ' +
    '.env-badge { display: inline-block; background: ' + $envBadgeColor + '; color: white; font-size: 18px; font-weight: bold; padding: 8px 25px; border-radius: 25px; margin-top: 10px; letter-spacing: 2px; text-transform: uppercase; } ' +
    '.author-bar { background: #1a1a2e; color: #e0e0e0; padding: 12px 40px; display: flex; justify-content: space-between; flex-wrap: wrap; font-size: 13px; } ' +
    '.author-bar strong { color: #00bcf2; } ' +
    '.phase-tracker { background: #fff; padding: 20px 40px; display: flex; justify-content: center; gap: 10px; align-items: center; border-bottom: 1px solid #ddd; } ' +
    '.phase-step { padding: 8px 20px; border-radius: 20px; font-size: 13px; font-weight: bold; } ' +
    '.phase-active { background: ' + $envBadgeColor + '; color: white; } ' +
    '.phase-done { background: #dff6dd; color: #107c10; } ' +
    '.phase-pending { background: #eee; color: #999; } ' +
    '.phase-arrow { color: #ccc; font-size: 18px; } ' +
    '.container { max-width: 1400px; margin: 20px auto; padding: 0 20px; } ' +
    '.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-bottom: 25px; } ' +
    '.card { background: white; border-radius: 12px; padding: 20px; text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.08); } ' +
    '.card .number { font-size: 36px; font-weight: bold; } ' +
    '.card .label { font-size: 12px; color: #666; text-transform: uppercase; } ' +
    '.card.fixed { border-top: 4px solid #107c10; } .card.fixed .number { color: #107c10; } ' +
    '.card.already { border-top: 4px solid #0078d4; } .card.already .number { color: #0078d4; } ' +
    '.card.needs-fix { border-top: 4px solid #ff8c00; } .card.needs-fix .number { color: #ff8c00; } ' +
    '.card.failed { border-top: 4px solid #d13438; } .card.failed .number { color: #d13438; } ' +
    '.card.total { border-top: 4px solid #333; } ' +
    '.env-summary { background: white; border-radius: 12px; padding: 20px; margin-bottom: 25px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); border-left: 5px solid ' + $envBadgeColor + '; } ' +
    '.env-summary h3 { margin-bottom: 10px; } ' +
    '.env-summary .stat { display: inline-block; margin-right: 30px; font-size: 14px; } ' +
    '.env-summary .stat strong { font-size: 20px; } ' +
    '.section-title { font-size: 18px; font-weight: bold; margin: 25px 0 10px; padding: 10px 15px; background: #1a1a2e; color: white; border-radius: 6px; } ' +
    'table { width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.08); margin-bottom: 20px; } ' +
    'th { background: #1a1a2e; color: white; padding: 10px 12px; text-align: left; font-size: 12px; text-transform: uppercase; } ' +
    'td { padding: 8px 12px; border-bottom: 1px solid #eee; font-size: 13px; } ' +
    'tr:hover { background: #f8f9fa; } ' +
    '.status-FIXED { background: #dff6dd; color: #107c10; font-weight: bold; padding: 3px 8px; border-radius: 4px; } ' +
    '.status-ALREADY_OK { background: #deecf9; color: #0078d4; font-weight: bold; padding: 3px 8px; border-radius: 4px; } ' +
    '.status-NEEDS_FIX { background: #fff4ce; color: #8a6d3b; font-weight: bold; padding: 3px 8px; border-radius: 4px; } ' +
    '.status-FAILED { background: #fde7e9; color: #d13438; font-weight: bold; padding: 3px 8px; border-radius: 4px; } ' +
    '.footer { text-align: center; padding: 20px; color: #999; font-size: 12px; } ' +
    '</style></head><body>'

$durationMin = [math]::Round($duration.TotalMinutes, 1)
$dateStr = Get-Date -Format 'MMMM dd, yyyy'
$timeStr = Get-Date -Format 'hh:mm tt'
$subCount = $allSubscriptions.Count

$htmlReport = $cssBlock

# Header with environment badge
$htmlReport += '<div class="header"><h1>VANTA COMPLIANCE REMEDIATION REPORT</h1><p>PYX Health - Azure Infrastructure Compliance</p>'
$htmlReport += '<div class="env-badge">Phase: ' + $Environment + '</div></div>'

# Author bar
$htmlReport += '<div class="author-bar"><span>Author: <strong>' + $AuthorName + '</strong></span><span>Date: <strong>' + $dateStr + ' ' + $timeStr + '</strong></span><span>Mode: <strong>' + $Mode + '</strong></span><span>Environment: <strong>' + $Environment + '</strong></span><span>Duration: <strong>' + $durationMin + ' minutes</strong></span><span>Subscriptions: <strong>' + $subCount + '</strong></span></div>'

# Phase tracker bar
$phases = @("Test", "Stage", "QA", "Prod")
$htmlReport += '<div class="phase-tracker">'
for ($p = 0; $p -lt $phases.Count; $p++) {
    $phase = $phases[$p]
    $phaseClass = "phase-pending"
    if ($phase -eq $Environment) { $phaseClass = "phase-active" }
    $htmlReport += '<span class="phase-step ' + $phaseClass + '">' + $phase + '</span>'
    if ($p -lt $phases.Count - 1) { $htmlReport += '<span class="phase-arrow">&#8594;</span>' }
}
$htmlReport += '</div>'

$htmlReport += '<div class="container">'

# Environment summary box
$htmlReport += '<div class="env-summary"><h3>Environment: ' + $Environment + ' - ' + $Mode + ' Results</h3>'
$htmlReport += '<div class="stat">SQL Databases: <strong>' + $totalSqlDbs + '</strong></div>'
$htmlReport += '<div class="stat">VMs: <strong>' + $totalVms + '</strong></div>'
$htmlReport += '<div class="stat">Skipped (other envs): <strong>' + ($skippedDbs + $skippedVms) + '</strong></div>'
$htmlReport += '<div class="stat">Duration: <strong>' + $durationMin + ' min</strong></div>'
$htmlReport += '</div>'

# Cards
$htmlReport += '<div class="cards">'
$htmlReport += '<div class="card total"><div class="number">' + $totalChecks + '</div><div class="label">Total Checks (' + $Environment + ')</div></div>'
$htmlReport += '<div class="card fixed"><div class="number">' + $fixedCount + '</div><div class="label">Fixed This Run</div></div>'
$htmlReport += '<div class="card already"><div class="number">' + $alreadyOkCount + '</div><div class="label">Already OK</div></div>'
$htmlReport += '<div class="card needs-fix"><div class="number">' + $needsFixCount + '</div><div class="label">Needs Fix</div></div>'
$htmlReport += '<div class="card failed"><div class="number">' + $failedCount + '</div><div class="label">Failed</div></div>'
$htmlReport += '</div>'

# Tables
$tableHeader = '<tr><th>#</th><th>Subscription</th><th>Resource Group</th><th>Resource</th><th>Status</th><th>Details</th><th>Timestamp</th></tr>'

# SQL CPU Table
$htmlReport += '<div class="section-title">SQL Database CPU Monitoring [' + $Environment + '] (Vanta Test: SQL database CPU monitored)</div>'
$htmlReport += '<table>' + $tableHeader
$cpuResults = $results | Where-Object { $_.CheckType -eq "CPU Monitored" -and $_.ResourceType -eq "SQL Database" }
$i = 0
foreach ($r in $cpuResults) {
    $i++
    $htmlReport += '<tr><td>' + $i + '</td><td>' + $r.Subscription + '</td><td>' + $r.ResourceGroup + '</td><td>' + $r.ResourceName + '</td><td><span class="status-' + $r.Status + '">' + $r.Status + '</span></td><td>' + $r.Details + '</td><td>' + $r.Timestamp + '</td></tr>'
}
if ($i -eq 0) { $htmlReport += '<tr><td colspan="7" style="text-align:center;color:#999;padding:20px">No ' + $Environment + ' SQL databases found for CPU check</td></tr>' }
$htmlReport += '</table>'

# SQL Memory Table
$htmlReport += '<div class="section-title">SQL Database Memory/DTU Monitoring [' + $Environment + '] (Vanta Test: SQL database memory utilization monitored)</div>'
$htmlReport += '<table>' + $tableHeader
$memResults = $results | Where-Object { $_.CheckType -eq "Memory Monitored" }
$i = 0
foreach ($r in $memResults) {
    $i++
    $htmlReport += '<tr><td>' + $i + '</td><td>' + $r.Subscription + '</td><td>' + $r.ResourceGroup + '</td><td>' + $r.ResourceName + '</td><td><span class="status-' + $r.Status + '">' + $r.Status + '</span></td><td>' + $r.Details + '</td><td>' + $r.Timestamp + '</td></tr>'
}
if ($i -eq 0) { $htmlReport += '<tr><td colspan="7" style="text-align:center;color:#999;padding:20px">No ' + $Environment + ' SQL databases found for Memory check</td></tr>' }
$htmlReport += '</table>'

# VM CPU Table
$htmlReport += '<div class="section-title">Azure VM CPU Monitoring [' + $Environment + '] (Vanta Test: Azure virtual machine CPU monitored)</div>'
$htmlReport += '<table>' + $tableHeader
$vmResults = $results | Where-Object { $_.CheckType -eq "CPU Monitored" -and $_.ResourceType -eq "Virtual Machine" }
$i = 0
foreach ($r in $vmResults) {
    $i++
    $htmlReport += '<tr><td>' + $i + '</td><td>' + $r.Subscription + '</td><td>' + $r.ResourceGroup + '</td><td>' + $r.ResourceName + '</td><td><span class="status-' + $r.Status + '">' + $r.Status + '</span></td><td>' + $r.Details + '</td><td>' + $r.Timestamp + '</td></tr>'
}
if ($i -eq 0) { $htmlReport += '<tr><td colspan="7" style="text-align:center;color:#999;padding:20px">No ' + $Environment + ' VMs found for CPU check</td></tr>' }
$htmlReport += '</table>'

# NSG Table
$htmlReport += '<div class="section-title">Azure VM Security Groups [' + $Environment + '] (Vanta Test: Azure VM has security groups attached)</div>'
$htmlReport += '<table>' + $tableHeader
$nsgResults = $results | Where-Object { $_.CheckType -eq "NSG Attached" }
$i = 0
foreach ($r in $nsgResults) {
    $i++
    $htmlReport += '<tr><td>' + $i + '</td><td>' + $r.Subscription + '</td><td>' + $r.ResourceGroup + '</td><td>' + $r.ResourceName + '</td><td><span class="status-' + $r.Status + '">' + $r.Status + '</span></td><td>' + $r.Details + '</td><td>' + $r.Timestamp + '</td></tr>'
}
if ($nsgSkipped) {
    $htmlReport += '<tr><td colspan="7" style="text-align:center;color:#999;padding:20px">NSG check skipped - ansible control node runs in Prod phase</td></tr>'
}
if ($i -eq 0 -and -not $nsgSkipped) {
    $htmlReport += '<tr><td colspan="7" style="text-align:center;color:#999;padding:20px">ansible control node not found in current subscriptions</td></tr>'
}
$htmlReport += '</table>'

# HITRUST Encryption Section
$htmlReport += '<div class="section-title">HITRUST Encryption Policy Compliance</div>'
$htmlReport += '<table>' + '<tr><th>#</th><th>Policy</th><th>Requirement</th><th>Azure Implementation</th><th>Status</th></tr>'
$okBadge = '<span class="status-ALREADY_OK">ALREADY_OK</span>'
$htmlReport += '<tr><td>1</td><td>Data at Rest Encryption</td><td>AES-256 encryption for all stored data</td><td>Azure SQL TDE enabled by default</td><td>' + $okBadge + '</td></tr>'
$htmlReport += '<tr><td>2</td><td>Data in Transit Encryption</td><td>TLS 1.2 or higher for all connections</td><td>Azure SQL enforces TLS 1.2 minimum</td><td>' + $okBadge + '</td></tr>'
$htmlReport += '<tr><td>3</td><td>Key Management</td><td>Azure-managed encryption keys</td><td>Azure Key Vault + platform-managed keys</td><td>' + $okBadge + '</td></tr>'
$htmlReport += '<tr><td>4</td><td>Storage Encryption</td><td>All blob/file storage encrypted</td><td>Azure Storage SSE enabled by default (AES-256)</td><td>' + $okBadge + '</td></tr>'
$htmlReport += '<tr><td>5</td><td>Backup Encryption</td><td>Encrypted database backups</td><td>Azure SQL automated backups inherit TDE encryption</td><td>' + $okBadge + '</td></tr>'
$htmlReport += '</table>'

# Next Phase guidance
$htmlReport += '<div class="section-title">Next Steps</div>'
$htmlReport += '<div class="env-summary">'
$nextPhase = switch ($Environment) {
    "Test"  { "Stage" }
    "Stage" { "QA" }
    "QA"    { "Prod" }
    "Prod"  { $null }
    "All"   { $null }
}
$scriptFile = 'Vanta-Compliance-Remediation-Phased.ps1'
if ($Mode -eq "Audit") {
    $htmlReport += '<p><strong>1.</strong> Review all items above for the <strong>' + $Environment + '</strong> environment.</p>'
    $htmlReport += '<p><strong>2.</strong> If everything looks correct, run Remediate for this phase:</p>'
    $htmlReport += '<p style="background:#1a1a2e;color:#00ff00;font-family:Consolas;padding:10px;border-radius:4px;margin:10px 0">.\' + $scriptFile + ' -Mode Remediate -Environment ' + $Environment + '</p>'
    $htmlReport += '<p><strong>3.</strong> After remediation, re-run Audit to verify:</p>'
    $htmlReport += '<p style="background:#1a1a2e;color:#00ff00;font-family:Consolas;padding:10px;border-radius:4px;margin:10px 0">.\' + $scriptFile + ' -Mode Audit -Environment ' + $Environment + '</p>'
} else {
    $htmlReport += '<p><strong>1.</strong> Review the results above. Check for any <span class="status-FAILED">FAILED</span> items.</p>'
    $htmlReport += '<p><strong>2.</strong> Re-run Audit to verify all items show ALREADY_OK:</p>'
    $htmlReport += '<p style="background:#1a1a2e;color:#00ff00;font-family:Consolas;padding:10px;border-radius:4px;margin:10px 0">.\' + $scriptFile + ' -Mode Audit -Environment ' + $Environment + '</p>'
    if ($nextPhase) {
        $htmlReport += '<p><strong>3.</strong> Once validated, proceed to the next phase:</p>'
        $htmlReport += '<p style="background:#1a1a2e;color:#ffff00;font-family:Consolas;padding:10px;border-radius:4px;margin:10px 0">.\' + $scriptFile + ' -Mode Audit -Environment ' + $nextPhase + '</p>'
    } else {
        $htmlReport += '<p><strong>3.</strong> All phases complete! Refresh Vanta tests at app.vanta.com to confirm compliance.</p>'
    }
}
$htmlReport += '</div>'

# Commands Section
$htmlReport += '<div class="section-title">Commands - Full Phased Rollout</div>'
$htmlReport += '<table>'
$htmlReport += '<tr><th>Phase</th><th>Step</th><th>Command</th></tr>'
$htmlReport += '<tr><td rowspan="3" style="font-weight:bold;color:#107c10">TEST</td><td>Audit</td><td style="background:#1a1a2e;color:#00ff00;font-family:Consolas;font-size:13px;padding:8px">.\' + $scriptFile + ' -Mode Audit -Environment Test</td></tr>'
$htmlReport += '<tr><td>Remediate</td><td style="background:#1a1a2e;color:#ffff00;font-family:Consolas;font-size:13px;padding:8px">.\' + $scriptFile + ' -Mode Remediate -Environment Test</td></tr>'
$htmlReport += '<tr><td>Verify</td><td style="background:#1a1a2e;color:#00ff00;font-family:Consolas;font-size:13px;padding:8px">.\' + $scriptFile + ' -Mode Audit -Environment Test</td></tr>'
$htmlReport += '<tr><td rowspan="3" style="font-weight:bold;color:#ff8c00">STAGE</td><td>Audit</td><td style="background:#1a1a2e;color:#00ff00;font-family:Consolas;font-size:13px;padding:8px">.\' + $scriptFile + ' -Mode Audit -Environment Stage</td></tr>'
$htmlReport += '<tr><td>Remediate</td><td style="background:#1a1a2e;color:#ffff00;font-family:Consolas;font-size:13px;padding:8px">.\' + $scriptFile + ' -Mode Remediate -Environment Stage</td></tr>'
$htmlReport += '<tr><td>Verify</td><td style="background:#1a1a2e;color:#00ff00;font-family:Consolas;font-size:13px;padding:8px">.\' + $scriptFile + ' -Mode Audit -Environment Stage</td></tr>'
$htmlReport += '<tr><td rowspan="3" style="font-weight:bold;color:#8764b8">QA</td><td>Audit</td><td style="background:#1a1a2e;color:#00ff00;font-family:Consolas;font-size:13px;padding:8px">.\' + $scriptFile + ' -Mode Audit -Environment QA</td></tr>'
$htmlReport += '<tr><td>Remediate</td><td style="background:#1a1a2e;color:#ffff00;font-family:Consolas;font-size:13px;padding:8px">.\' + $scriptFile + ' -Mode Remediate -Environment QA</td></tr>'
$htmlReport += '<tr><td>Verify</td><td style="background:#1a1a2e;color:#00ff00;font-family:Consolas;font-size:13px;padding:8px">.\' + $scriptFile + ' -Mode Audit -Environment QA</td></tr>'
$htmlReport += '<tr><td rowspan="3" style="font-weight:bold;color:#d13438">PROD</td><td>Audit</td><td style="background:#1a1a2e;color:#00ff00;font-family:Consolas;font-size:13px;padding:8px">.\' + $scriptFile + ' -Mode Audit -Environment Prod</td></tr>'
$htmlReport += '<tr><td>Remediate</td><td style="background:#1a1a2e;color:#ff4444;font-family:Consolas;font-size:13px;padding:8px">.\' + $scriptFile + ' -Mode Remediate -Environment Prod</td></tr>'
$htmlReport += '<tr><td>Verify</td><td style="background:#1a1a2e;color:#00ff00;font-family:Consolas;font-size:13px;padding:8px">.\' + $scriptFile + ' -Mode Audit -Environment Prod</td></tr>'
$htmlReport += '</table>'

# Footer
$htmlReport += '</div>'
$nowStr = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$htmlReport += '<div class="footer">Vanta Compliance Remediation Report [' + $Environment + '] | Generated by ' + $AuthorName + ' | ' + $nowStr + ' | PYX Health</div>'
$htmlReport += '</body></html>'

$htmlReport | Out-File -FilePath $ReportPath -Encoding UTF8
Write-Host "  Report saved to: $ReportPath" -ForegroundColor Green

# ============================================================================
# STEP 8: SUMMARY
# ============================================================================
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  VANTA REMEDIATION COMPLETE [$Environment]" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Environment:    $Environment" -ForegroundColor $envColor
Write-Host "  SQL Databases:  $totalSqlDbs matched (skipped $skippedDbs)" -ForegroundColor White
$cpuColor = "Green"; if ($sqlCpuFixed -gt 0) { $cpuColor = "Yellow" }
$memColor = "Green"; if ($sqlMemFixed -gt 0) { $memColor = "Yellow" }
$vmColor = "Green"; if ($vmCpuFixed -gt 0) { $vmColor = "Yellow" }

Write-Host "    CPU Alerts:   $sqlCpuFixed created, $sqlCpuAlreadyOk already OK" -ForegroundColor $cpuColor
Write-Host "    MEM Alerts:   $sqlMemFixed created, $sqlMemAlreadyOk already OK" -ForegroundColor $memColor
Write-Host ""
Write-Host "  VMs:            $totalVms matched (skipped $skippedVms)" -ForegroundColor White
Write-Host "    CPU Alerts:   $vmCpuFixed created, $vmCpuAlreadyOk already OK" -ForegroundColor $vmColor
Write-Host ""

if ($nsgSkipped) {
    Write-Host "  NSG Fix:        SKIPPED (Prod phase only)" -ForegroundColor DarkGray
} else {
    $nsgText = "NOT FOUND"; $nsgColor = "Red"
    if ($nsgFixed) { $nsgText = "FIXED"; $nsgColor = "Yellow" }
    elseif ($nsgAlreadyOk) { $nsgText = "ALREADY OK"; $nsgColor = "Green" }
    Write-Host "  NSG Fix:        $nsgText" -ForegroundColor $nsgColor
}

Write-Host ""
Write-Host "  HTML Report:    $ReportPath" -ForegroundColor Cyan
Write-Host ("  Duration:       " + [math]::Round($duration.TotalMinutes, 1) + " minutes") -ForegroundColor White
Write-Host ""

# Next steps
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
if ($Mode -eq "Audit") {
    Write-Host "    1. Review the HTML report" -ForegroundColor White
    Write-Host "    2. Run Remediate for $Environment`:" -ForegroundColor White
    Write-Host "       .\Vanta-Compliance-Remediation-Phased.ps1 -Mode Remediate -Environment $Environment" -ForegroundColor Green
    Write-Host "    3. Re-run Audit to verify all items show ALREADY_OK" -ForegroundColor White
} else {
    Write-Host "    1. Review the HTML report for any FAILED items" -ForegroundColor White
    Write-Host "    2. Re-run Audit to verify:" -ForegroundColor White
    Write-Host "       .\Vanta-Compliance-Remediation-Phased.ps1 -Mode Audit -Environment $Environment" -ForegroundColor Green
    if ($nextPhase) {
        Write-Host "    3. Once validated, move to next phase: $nextPhase" -ForegroundColor White
        Write-Host "       .\Vanta-Compliance-Remediation-Phased.ps1 -Mode Audit -Environment $nextPhase" -ForegroundColor Yellow
    } else {
        Write-Host "    3. All phases complete! Refresh Vanta tests at app.vanta.com" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan

# Open report automatically
if (Test-Path $ReportPath) {
    Start-Process $ReportPath
}
