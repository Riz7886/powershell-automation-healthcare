#Requires -Version 5.1
<#
.SYNOPSIS
    Databricks Quota Root Cause Analyzer - FIXED VERSION
.PARAMETER Mode
    rootcause  - Analysis only
    fix        - Apply fixes
    all        - Everything
.EXAMPLE
    .\DatabricksQuotaRootCause-AutoFix-FIXED.ps1 -Mode rootcause
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("rootcause", "fix", "all")]
    [string]$Mode,
    
    [int]$AnalysisDays = 7
)

$ErrorActionPreference = "Continue"
$script:WorkspaceUrl = ""
$script:Token = ""
$script:SubscriptionId = ""
$script:ResourceGroup = ""
$script:Location = ""
$script:RootCauses = @()
$script:Recommendations = @()
$script:FixesApplied = @()
$script:ResourceHogs = @()
$LogFile = ".\DatabricksRootCause_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Msg"
    
    switch ($Level) {
        "ERROR"    { Write-Host $line -ForegroundColor Red }
        "WARN"     { Write-Host $line -ForegroundColor Yellow }
        "SUCCESS"  { Write-Host $line -ForegroundColor Green }
        "CRITICAL" { Write-Host $line -ForegroundColor Magenta }
        "ROOTCAUSE" { Write-Host $line -ForegroundColor Cyan }
        default    { Write-Host $line }
    }
    
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Write-Banner {
    param([string]$Title)
    $line = "=" * 80
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
}

function Invoke-DBApi {
    param(
        [string]$Path,
        [string]$Method = "GET",
        [object]$Body = $null
    )
    
    $uri = "$($script:WorkspaceUrl)/api/2.0$Path"
    $headers = @{
        "Authorization" = "Bearer $($script:Token)"
        "Content-Type"  = "application/json"
    }
    
    $params = @{
        Uri     = $uri
        Method  = $Method
        Headers = $headers
    }
    
    if ($Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }
    
    try {
        $response = Invoke-RestMethod @params -ErrorAction Stop
        return $response
    }
    catch {
        Write-Log "API call failed: $Path - $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Initialize-AutoDiscovery {
    Write-Banner "AUTO-DISCOVERING DATABRICKS WORKSPACE"
    
    Write-Log "Checking PowerShell modules..."
    $modules = @("Az.Accounts", "Az.Resources", "Az.Compute")
    foreach ($mod in $modules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            Write-Log "Installing $mod..." "WARN"
            Install-Module $mod -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
        }
    }
    
    Import-Module Az.Accounts -Force -ErrorAction SilentlyContinue
    Import-Module Az.Resources -Force -ErrorAction SilentlyContinue
    Import-Module Az.Compute -Force -ErrorAction SilentlyContinue
    
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        Write-Log "Opening Azure login..." "WARN"
        Connect-AzAccount -ErrorAction Stop | Out-Null
        $ctx = Get-AzContext
    }
    
    Write-Log "Logged in as: $($ctx.Account.Id)" "SUCCESS"
    $script:SubscriptionId = $ctx.Subscription.Id
    
    Write-Log "Searching for Databricks workspaces..."
    $workspaces = Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" -ErrorAction SilentlyContinue
    
    if (-not $workspaces) {
        $allSubs = Get-AzSubscription
        foreach ($sub in $allSubs) {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
            $workspaces = Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" -ErrorAction SilentlyContinue
            if ($workspaces) {
                $script:SubscriptionId = $sub.Id
                break
            }
        }
    }
    
    if (-not $workspaces) {
        Write-Log "No Databricks workspaces found!" "ERROR"
        exit 1
    }
    
    $ws = $null
    $workspaces = @($workspaces)
    if ($workspaces.Count -eq 1) {
        $ws = $workspaces[0]
    }
    else {
        for ($i = 0; $i -lt $workspaces.Count; $i++) {
            Write-Host "  [$($i+1)] $($workspaces[$i].Name)" -ForegroundColor Cyan
        }
        $pick = Read-Host "Select number"
        $idx = [int]$pick - 1
        if ($idx -lt 0 -or $idx -ge $workspaces.Count) { $idx = 0 }
        $ws = $workspaces[$idx]
    }
    
    $script:ResourceGroup = $ws.ResourceGroupName
    $script:Location = $ws.Location
    
    $detail = Get-AzResource -ResourceId $ws.ResourceId -ExpandProperties -ErrorAction Stop
    $url = $detail.Properties.workspaceUrl
    if ($url) {
        $script:WorkspaceUrl = "https://$url"
    }
    else {
        $wid = $detail.Properties.workspaceId
        $script:WorkspaceUrl = "https://adb-$wid.azuredatabricks.net"
    }
    
    Write-Log "Workspace URL: $($script:WorkspaceUrl)" "SUCCESS"
    
    Write-Log "Acquiring Databricks API token..."
    $dbAppId = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
    $gotToken = $false
    
    try {
        $tokenObj = Get-AzAccessToken -ResourceUrl $dbAppId -ErrorAction Stop
        $tokenStr = if ($tokenObj.Token) { $tokenObj.Token } else { $tokenObj.AccessToken }
        if ($tokenStr) {
            $script:Token = $tokenStr
            $gotToken = $true
        }
    }
    catch {
        try {
            $tokenObj = Get-AzAccessToken -Resource $dbAppId -ErrorAction Stop
            $tokenStr = if ($tokenObj.Token) { $tokenObj.Token } else { $tokenObj.AccessToken }
            if ($tokenStr) {
                $script:Token = $tokenStr
                $gotToken = $true
            }
        }
        catch { }
    }
    
    if (-not $gotToken) {
        Write-Host "Manual token required" -ForegroundColor Yellow
        Write-Host "1. Open: $($script:WorkspaceUrl)" -ForegroundColor Cyan
        Write-Host "2. User Settings > Developer > Access Tokens" -ForegroundColor Cyan
        $manual = Read-Host "Paste token here"
        if ($manual) {
            $script:Token = $manual.Trim()
            $gotToken = $true
        }
    }
    
    if (-not $gotToken) {
        Write-Log "Could not acquire token!" "ERROR"
        exit 1
    }
    
    Write-Log "Testing API connection..."
    $test = Invoke-DBApi -Path "/clusters/list"
    if ($test) {
        Write-Log "Connection successful!" "SUCCESS"
    }
    else {
        Write-Log "Connection test failed!" "ERROR"
        exit 1
    }
}

function Analyze-Clusters {
    Write-Banner "ANALYZING CLUSTERS"
    
    $clustersResp = Invoke-DBApi -Path "/clusters/list"
    if (-not $clustersResp -or -not $clustersResp.clusters) {
        Write-Log "No clusters found" "WARN"
        return
    }
    
    $clusters = $clustersResp.clusters
    Write-Log "Found $($clusters.Count) clusters"
    
    foreach ($cluster in $clusters) {
        $name = $cluster.cluster_name
        $state = $cluster.state
        
        Write-Log "Cluster: $name (State: $state)"
        
        if (-not $cluster.autoscale) {
            $workers = if ($cluster.num_workers) { $cluster.num_workers } else { "Unknown" }
            Write-Log "  ⚠ NO AUTOSCALE - Fixed $workers workers" "WARN"
            $script:RootCauses += "Cluster '$name' has NO AUTOSCALING"
        }
        else {
            $maxW = $cluster.autoscale.max_workers
            if ($maxW -gt 20) {
                Write-Log "  ⚠ MAX WORKERS TOO HIGH: $maxW" "WARN"
                $script:RootCauses += "Cluster '$name' max workers = $maxW (quota risk)"
            }
        }
        
        $autoTerm = $cluster.autotermination_minutes
        if (-not $autoTerm -or $autoTerm -eq 0) {
            Write-Log "  ⚠ NO AUTO-TERMINATION" "ERROR"
            $script:RootCauses += "Cluster '$name' has NO AUTO-TERMINATION"
        }
    }
}

function Analyze-AzureQuota {
    Write-Banner "ANALYZING AZURE QUOTA"
    
    try {
        $usages = Get-AzVMUsage -Location $script:Location -ErrorAction Stop
        
        $all = $usages | Where-Object {
            $_.Limit -gt 0 -and $_.CurrentValue -gt 0
        } | Sort-Object { $_.CurrentValue / $_.Limit } -Descending | Select-Object -First 10
        
        Write-Log ("{0,-50} {1,8} {2,8} {3,8}" -f "VM Family", "Used", "Limit", "Usage%")
        Write-Log ("-" * 80)
        
        foreach ($u in $all) {
            $pct = [math]::Round(($u.CurrentValue / $u.Limit) * 100, 1)
            $level = if ($pct -gt 90) { "CRITICAL" } elseif ($pct -gt 80) { "ERROR" } else { "INFO" }
            
            Write-Log ("{0,-50} {1,8} {2,8} {3,7}%" -f $u.Name.LocalizedValue, $u.CurrentValue, $u.Limit, $pct) $level
            
            if ($pct -gt 90) {
                $script:RootCauses += "QUOTA BREACH: $($u.Name.LocalizedValue) at $pct%"
                $recommended = [int]([Math]::Max($u.Limit * 2, $u.CurrentValue * 2.5))
                $script:Recommendations += "Request quota increase for $($u.Name.LocalizedValue): $($u.Limit) -> $recommended vCPUs"
            }
        }
    }
    catch {
        Write-Log "Error checking quota: $($_.Exception.Message)" "ERROR"
    }
}

function Show-RootCauseSummary {
    Write-Banner "ROOT CAUSE ANALYSIS - SUMMARY"
    
    if ($script:RootCauses.Count -eq 0) {
        Write-Log "No specific root causes identified" "SUCCESS"
        return
    }
    
    Write-Log "=== IDENTIFIED ROOT CAUSES ===" "CRITICAL"
    for ($i = 0; $i -lt $script:RootCauses.Count; $i++) {
        Write-Log "$($i+1). $($script:RootCauses[$i])" "ROOTCAUSE"
    }
    
    if ($script:Recommendations.Count -gt 0) {
        Write-Log ""
        Write-Log "=== RECOMMENDATIONS ===" "CRITICAL"
        for ($i = 0; $i -lt $script:Recommendations.Count; $i++) {
            Write-Log "$($i+1). $($script:Recommendations[$i])" "SUCCESS"
        }
    }
}

function Apply-Fixes {
    Write-Banner "APPLYING FIXES"
    
    Write-Host "Type 'YES' to apply fixes: " -NoNewline
    $confirm = Read-Host
    if ($confirm -ne "YES") {
        Write-Log "Cancelled" "WARN"
        return
    }
    
    $clustersResp = Invoke-DBApi -Path "/clusters/list"
    if (-not $clustersResp -or -not $clustersResp.clusters) {
        Write-Log "No clusters to fix" "WARN"
        return
    }
    
    foreach ($cluster in $clustersResp.clusters) {
        $name = $cluster.cluster_name
        $id = $cluster.cluster_id
        
        if ($cluster.state -notin @("RUNNING", "PENDING")) {
            continue
        }
        
        Write-Log "Processing: $name"
        
        $edit = @{
            cluster_id = $id
            cluster_name = $name
            spark_version = $cluster.spark_version
            node_type_id = $cluster.node_type_id
        }
        
        $changes = @()
        
        if (-not $cluster.autoscale) {
            $currentWorkers = if ($cluster.num_workers) { $cluster.num_workers } else { 2 }
            $edit["autoscale"] = @{
                min_workers = 1
                max_workers = [Math]::Min(8, $currentWorkers * 2)
            }
            $changes += "Enabled autoscaling"
        }
        
        if (-not $cluster.autotermination_minutes) {
            $edit["autotermination_minutes"] = 30
            $changes += "Enabled auto-termination (30 min)"
        }
        
        if ($changes.Count -gt 0) {
            Write-Log "  Applying: $($changes -join '; ')" "SUCCESS"
            Invoke-DBApi -Path "/clusters/edit" -Method "POST" -Body $edit | Out-Null
            $script:FixesApplied += "Cluster '$name': $($changes -join '; ')"
        }
    }
}

function Show-FinalSummary {
    Write-Banner "FINAL SUMMARY"
    
    if ($script:RootCauses.Count -gt 0) {
        Write-Log "ROOT CAUSES FOUND: $($script:RootCauses.Count)" "WARN"
        foreach ($rc in $script:RootCauses) {
            Write-Log "  - $rc" "WARN"
        }
    }
    
    if ($script:FixesApplied.Count -gt 0) {
        Write-Log ""
        Write-Log "FIXES APPLIED: $($script:FixesApplied.Count)" "SUCCESS"
        foreach ($fix in $script:FixesApplied) {
            Write-Log "  - $fix" "SUCCESS"
        }
    }
    
    Write-Log ""
    Write-Log "Log file: $LogFile" "SUCCESS"
}

# MAIN EXECUTION
Write-Banner "DATABRICKS QUOTA ROOT CAUSE ANALYZER"

Initialize-AutoDiscovery

if ($Mode -in @("rootcause", "all")) {
    Analyze-Clusters
    Analyze-AzureQuota
    Show-RootCauseSummary
}

if ($Mode -in @("fix", "all")) {
    Apply-Fixes
}

Show-FinalSummary

Write-Log "DONE" "SUCCESS"
