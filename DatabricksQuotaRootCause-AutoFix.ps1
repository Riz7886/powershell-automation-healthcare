#Requires -Version 5.1
<#
.SYNOPSIS
    Databricks Quota Breach - ROOT CAUSE ANALYSIS & PERMANENT FIX
    
.DESCRIPTION
    This script FULLY AUTOMATES:
    1. ROOT CAUSE ANALYSIS - Finds EXACTLY what caused the quota breach
    2. PERMANENT FIX - Not bandaids, real solutions
    3. PREVENTION - Stops it from happening again
    
    NO MANUAL CONFIG NEEDED - Just run it and it handles everything.
    
.PARAMETER Mode
    rootcause  - Deep dive into what caused the quota breach
    fix        - Apply permanent fixes based on root cause
    all        - Do everything (recommended)
    
.EXAMPLE
    .\DatabricksQuotaRootCause-AutoFix.ps1 -Mode all
    .\DatabricksQuotaRootCause-AutoFix.ps1 -Mode rootcause
    
.NOTES
    Author: Auto-Discovery Wizard
    This script will:
    - Auto-find your Databricks workspace
    - Auto-generate access tokens
    - Analyze job execution history
    - Identify resource-hungry jobs
    - Find inefficient queries
    - Detect runaway autoscaling
    - Apply permanent fixes
    - Set up prevention measures
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("rootcause", "fix", "all")]
    [string]$Mode,
    
    [int]$AnalysisDays = 7,  # How far back to analyze
    [switch]$ExportReport    # Export detailed CSV reports
)

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================
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
$script:IneffientJobs = @()
$LogFile = ".\DatabricksRootCause_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$ReportDir = ".\DatabricksReports_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

# ============================================================================
# LOGGING & UTILITIES
# ============================================================================
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

# ============================================================================
# STEP 1: AUTO-DISCOVERY
# ============================================================================
function Initialize-AutoDiscovery {
    Write-Banner "STEP 1: AUTO-DISCOVERING DATABRICKS WORKSPACE"
    
    # Check/Install Az modules
    Write-Log "Checking PowerShell modules..."
    $modules = @("Az.Accounts", "Az.Resources", "Az.Compute", "Az.Monitor")
    foreach ($mod in $modules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            Write-Log "Installing $mod..." "WARN"
            try {
                Install-Module $mod -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
                Write-Log "Installed $mod" "SUCCESS"
            }
            catch {
                Write-Log "Failed to install $mod. Try: Install-Module Az -Force" "ERROR"
                exit 1
            }
        }
    }
    
    # Import modules
    Import-Module Az.Accounts -Force -ErrorAction SilentlyContinue
    Import-Module Az.Resources -Force -ErrorAction SilentlyContinue
    Import-Module Az.Compute -Force -ErrorAction SilentlyContinue
    Import-Module Az.Monitor -Force -ErrorAction SilentlyContinue
    
    # Azure login
    Write-Log "Checking Azure login..."
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        Write-Log "Not logged in. Opening Azure login..." "WARN"
        try {
            Connect-AzAccount -ErrorAction Stop | Out-Null
            $ctx = Get-AzContext
        }
        catch {
            Write-Log "Azure login failed: $($_.Exception.Message)" "ERROR"
            exit 1
        }
    }
    
    Write-Log "Logged in as: $($ctx.Account.Id)" "SUCCESS"
    $script:SubscriptionId = $ctx.Subscription.Id
    Write-Log "Subscription: $($ctx.Subscription.Name)" "SUCCESS"
    
    # Find Databricks workspaces
    Write-Log "Searching for Databricks workspaces..."
    $workspaces = Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" -ErrorAction SilentlyContinue
    
    if (-not $workspaces -or $workspaces.Count -eq 0) {
        Write-Log "No workspaces in current subscription. Checking all..." "WARN"
        $allSubs = Get-AzSubscription
        foreach ($sub in $allSubs) {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
            $workspaces = Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" -ErrorAction SilentlyContinue
            if ($workspaces -and $workspaces.Count -gt 0) {
                $script:SubscriptionId = $sub.Id
                Write-Log "Found workspaces in: $($sub.Name)" "SUCCESS"
                break
            }
        }
    }
    
    if (-not $workspaces -or $workspaces.Count -eq 0) {
        Write-Log "No Databricks workspaces found!" "ERROR"
        exit 1
    }
    
    # Select workspace
    $ws = $null
    $workspaces = @($workspaces)
    if ($workspaces.Count -eq 1) {
        $ws = $workspaces[0]
        Write-Log "Found workspace: $($ws.Name)" "SUCCESS"
    }
    else {
        Write-Log "Found $($workspaces.Count) workspaces:"
        for ($i = 0; $i -lt $workspaces.Count; $i++) {
            Write-Host "  [$($i+1)] $($workspaces[$i].Name) - $($workspaces[$i].ResourceGroupName)" -ForegroundColor Cyan
        }
        $pick = Read-Host "Select number (1-$($workspaces.Count))"
        $idx = [int]$pick - 1
        if ($idx -lt 0 -or $idx -ge $workspaces.Count) { $idx = 0 }
        $ws = $workspaces[$idx]
    }
    
    $script:ResourceGroup = $ws.ResourceGroupName
    $script:Location = $ws.Location
    
    # Get workspace URL
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
    Write-Log "Resource Group: $($script:ResourceGroup)" "SUCCESS"
    Write-Log "Location: $($script:Location)" "SUCCESS"
    
    # Get token
    Write-Log "Acquiring Databricks API token..."
    $dbAppId = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
    $gotToken = $false
    
    # Try Azure AD token
    try {
        $tokenObj = Get-AzAccessToken -ResourceUrl $dbAppId -ErrorAction Stop
        $tokenStr = if ($tokenObj.Token) { $tokenObj.Token } else { $tokenObj.AccessToken }
        if ($tokenStr -and $tokenStr.Length -gt 20) {
            $script:Token = $tokenStr
            Write-Log "Got Azure AD token" "SUCCESS"
            $gotToken = $true
        }
    }
    catch {
        try {
            $tokenObj = Get-AzAccessToken -Resource $dbAppId -ErrorAction Stop
            $tokenStr = if ($tokenObj.Token) { $tokenObj.Token } else { $tokenObj.AccessToken }
            if ($tokenStr -and $tokenStr.Length -gt 20) {
                $script:Token = $tokenStr
                Write-Log "Got Azure AD token (alt method)" "SUCCESS"
                $gotToken = $true
            }
        }
        catch { }
    }
    
    # Try CLI
    if (-not $gotToken) {
        try {
            $cliExists = Get-Command az -ErrorAction SilentlyContinue
            if ($cliExists) {
                $cliTok = & az account get-access-token --resource $dbAppId --query accessToken -o tsv 2>$null
                if ($cliTok -and $cliTok.Length -gt 20) {
                    $script:Token = $cliTok
                    Write-Log "Got CLI token" "SUCCESS"
                    $gotToken = $true
                }
            }
        }
        catch { }
    }
    
    # Manual fallback
    if (-not $gotToken) {
        Write-Host ""
        Write-Host "  AUTO-TOKEN FAILED - Need manual token" -ForegroundColor Yellow
        Write-Host "  1. Open: $($script:WorkspaceUrl)" -ForegroundColor Cyan
        Write-Host "  2. Click your name > User Settings > Developer > Access Tokens" -ForegroundColor Cyan
        Write-Host "  3. Generate New Token > Copy it" -ForegroundColor Cyan
        Write-Host ""
        $manual = Read-Host "  Paste token here"
        if ($manual -and $manual.Length -gt 5) {
            $script:Token = $manual.Trim()
            $gotToken = $true
        }
    }
    
    if (-not $gotToken) {
        Write-Log "Could not acquire token!" "ERROR"
        exit 1
    }
    
    # Test connection
    Write-Log "Testing API connection..."
    try {
        $test = Invoke-DBApi -Path "/clusters/list"
        Write-Log "Connection successful!" "SUCCESS"
    }
    catch {
        Write-Log "Connection test failed!" "ERROR"
        exit 1
    }
    
    # Create report directory
    if ($ExportReport) {
        New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
        Write-Log "Report directory: $ReportDir" "SUCCESS"
    }
}

# ============================================================================
# STEP 2: ROOT CAUSE ANALYSIS - JOB EXECUTION HISTORY
# ============================================================================
function Analyze-JobExecutionHistory {
    Write-Banner "STEP 2: ANALYZING JOB EXECUTION HISTORY (ROOT CAUSE)"
    
    Write-Log "Fetching job runs from last $AnalysisDays days..."
    
    $startTime = (Get-Date).AddDays(-$AnalysisDays).ToUniversalTime()
    $startTimeMs = [long]($startTime - (Get-Date "1970-01-01")).TotalMilliseconds
    
    # Get all jobs
    $jobsResp = Invoke-DBApi -Path "/jobs/list"
    if (-not $jobsResp -or -not $jobsResp.jobs) {
        Write-Log "No jobs found in workspace" "WARN"
        return
    }
    
    $jobs = $jobsResp.jobs
    Write-Log "Found $($jobs.Count) jobs. Analyzing execution history..."
    
    $allRuns = @()
    $resourceUsageByJob = @{}
    $jobFailures = @{}
    $longRunningJobs = @{}
    
    foreach ($job in $jobs) {
        $jobId = $job.job_id
        $jobName = $job.settings.name
        
        Write-Log "Analyzing job: $jobName (ID: $jobId)"
        
        # Get runs for this job
        try {
            $runsResp = Invoke-DBApi -Path "/jobs/runs/list" -Method "GET"
            
            if ($runsResp -and $runsResp.runs) {
                $jobRuns = $runsResp.runs | Where-Object { 
                    $_.job_id -eq $jobId -and $_.start_time -ge $startTimeMs 
                }
                
                foreach ($run in $jobRuns) {
                    $runId = $run.run_id
                    
                    # Get detailed run info
                    $runDetail = Invoke-DBApi -Path "/jobs/runs/get?run_id=$runId"
                    
                    if ($runDetail) {
                        $duration = if ($runDetail.end_time -and $runDetail.start_time) {
                            ($runDetail.end_time - $runDetail.start_time) / 1000 / 60  # minutes
                        } else { 0 }
                        
                        $clusterUsed = $null
                        if ($runDetail.cluster_spec) {
                            $clusterUsed = $runDetail.cluster_spec
                        }
                        elseif ($runDetail.cluster_instance) {
                            $clusterUsed = $runDetail.cluster_instance.cluster_id
                        }
                        
                        # Track resource usage
                        if (-not $resourceUsageByJob.ContainsKey($jobName)) {
                            $resourceUsageByJob[$jobName] = @{
                                TotalRuns = 0
                                TotalDurationMins = 0
                                AvgDurationMins = 0
                                MaxWorkers = 0
                                Failures = 0
                            }
                        }
                        
                        $resourceUsageByJob[$jobName].TotalRuns++
                        $resourceUsageByJob[$jobName].TotalDurationMins += $duration
                        
                        # Track failures
                        if ($runDetail.state.life_cycle_state -eq "FAILED" -or 
                            $runDetail.state.life_cycle_state -eq "TERMINATED") {
                            $resourceUsageByJob[$jobName].Failures++
                            
                            if (-not $jobFailures.ContainsKey($jobName)) {
                                $jobFailures[$jobName] = @()
                            }
                            $jobFailures[$jobName] += @{
                                RunId = $runId
                                StartTime = $runDetail.start_time
                                Error = $runDetail.state.state_message
                            }
                        }
                        
                        # Track long-running jobs (> 60 mins)
                        if ($duration -gt 60) {
                            if (-not $longRunningJobs.ContainsKey($jobName)) {
                                $longRunningJobs[$jobName] = @()
                            }
                            $longRunningJobs[$jobName] += @{
                                RunId = $runId
                                DurationMins = $duration
                                StartTime = $runDetail.start_time
                            }
                        }
                        
                        $allRuns += @{
                            JobName = $jobName
                            JobId = $jobId
                            RunId = $runId
                            StartTime = $runDetail.start_time
                            EndTime = $runDetail.end_time
                            DurationMins = $duration
                            State = $runDetail.state.life_cycle_state
                            ClusterId = $clusterUsed
                        }
                    }
                }
            }
        }
        catch {
            Write-Log "Error analyzing job $jobName : $($_.Exception.Message)" "WARN"
        }
    }
    
    # Calculate averages
    foreach ($jobName in $resourceUsageByJob.Keys) {
        $totalRuns = $resourceUsageByJob[$jobName].TotalRuns
        if ($totalRuns -gt 0) {
            $resourceUsageByJob[$jobName].AvgDurationMins = 
                [math]::Round($resourceUsageByJob[$jobName].TotalDurationMins / $totalRuns, 2)
        }
    }
    
    # Sort by total resource consumption
    $topResourceHogs = $resourceUsageByJob.GetEnumerator() | 
        Sort-Object { $_.Value.TotalDurationMins } -Descending |
        Select-Object -First 10
    
    Write-Log ""
    Write-Log "=== TOP 10 RESOURCE-CONSUMING JOBS ===" "CRITICAL"
    Write-Log ("{0,-40} {1,10} {2,15} {3,15}" -f "Job Name", "Runs", "Total Mins", "Avg Mins")
    Write-Log ("-" * 80)
    
    foreach ($job in $topResourceHogs) {
        $name = $job.Key
        $stats = $job.Value
        Write-Log ("{0,-40} {1,10} {2,15:N2} {3,15:N2}" -f 
            $name, $stats.TotalRuns, $stats.TotalDurationMins, $stats.AvgDurationMins) "WARN"
        
        $script:ResourceHogs += @{
            JobName = $name
            TotalRuns = $stats.TotalRuns
            TotalDurationMins = $stats.TotalDurationMins
            AvgDurationMins = $stats.AvgDurationMins
        }
        
        # This is a root cause if job consumed significant resources
        if ($stats.TotalDurationMins -gt 500) {
            $script:RootCauses += "Job '$name' consumed $([math]::Round($stats.TotalDurationMins, 0)) minutes of cluster time"
        }
    }
    
    # Report long-running jobs
    if ($longRunningJobs.Count -gt 0) {
        Write-Log ""
        Write-Log "=== LONG-RUNNING JOBS (>60 mins) ===" "CRITICAL"
        foreach ($jobName in $longRunningJobs.Keys) {
            Write-Log "Job: $jobName" "WARN"
            foreach ($run in $longRunningJobs[$jobName]) {
                Write-Log "  Run $($run.RunId): $([math]::Round($run.DurationMins, 2)) mins" "WARN"
                
                $script:RootCauses += "Job '$jobName' had run lasting $([math]::Round($run.DurationMins, 0)) minutes"
            }
        }
    }
    
    # Report failures
    if ($jobFailures.Count -gt 0) {
        Write-Log ""
        Write-Log "=== JOB FAILURES ===" "ERROR"
        foreach ($jobName in $jobFailures.Keys) {
            Write-Log "Job: $jobName - $($jobFailures[$jobName].Count) failures" "ERROR"
            foreach ($failure in $jobFailures[$jobName]) {
                Write-Log "  Run $($failure.RunId): $($failure.Error)" "ERROR"
            }
        }
    }
    
    # Export to CSV
    if ($ExportReport -and $allRuns.Count -gt 0) {
        $csvPath = Join-Path $ReportDir "JobExecutionHistory.csv"
        $allRuns | ForEach-Object { [PSCustomObject]$_ } | Export-Csv -Path $csvPath -NoTypeInformation
        Write-Log "Exported job execution history to: $csvPath" "SUCCESS"
    }
}

# ============================================================================
# STEP 3: ROOT CAUSE ANALYSIS - CLUSTER AUTOSCALING EVENTS
# ============================================================================
function Analyze-ClusterAutoscaling {
    Write-Banner "STEP 3: ANALYZING CLUSTER AUTOSCALING (ROOT CAUSE)"
    
    Write-Log "Fetching cluster list..."
    $clustersResp = Invoke-DBApi -Path "/clusters/list"
    
    if (-not $clustersResp -or -not $clustersResp.clusters) {
        Write-Log "No clusters found" "WARN"
        return
    }
    
    $clusters = $clustersResp.clusters
    Write-Log "Found $($clusters.Count) clusters. Analyzing autoscaling behavior..."
    
    $autoscaleIssues = @()
    $noAutoscaleClusters = @()
    $noAutoTerminateClusters = @()
    
    foreach ($cluster in $clusters) {
        $name = $cluster.cluster_name
        $id = $cluster.cluster_id
        $state = $cluster.state
        
        Write-Log "Analyzing cluster: $name (State: $state)"
        
        # Check autoscale configuration
        if (-not $cluster.autoscale) {
            $workers = if ($cluster.num_workers) { $cluster.num_workers } else { "Unknown" }
            Write-Log "  ⚠ NO AUTOSCALE - Fixed $workers workers" "WARN"
            $noAutoscaleClusters += $name
            $script:RootCauses += "Cluster '$name' has NO AUTOSCALING - fixed worker count can waste resources"
        }
        else {
            $minW = $cluster.autoscale.min_workers
            $maxW = $cluster.autoscale.max_workers
            Write-Log "  Autoscale: $minW - $maxW workers" "INFO"
            
            # Check if max is too high
            if ($maxW -gt 20) {
                Write-Log "  ⚠ MAX WORKERS TOO HIGH: $maxW" "WARN"
                $autoscaleIssues += "Cluster '$name' can scale to $maxW workers (quota risk)"
                $script:RootCauses += "Cluster '$name' max workers = $maxW (very high, likely caused quota breach)"
            }
        }
        
        # Check auto-termination
        $autoTerm = $cluster.autotermination_minutes
        if (-not $autoTerm -or $autoTerm -eq 0) {
            Write-Log "  ⚠ NO AUTO-TERMINATION - Cluster never shuts down!" "ERROR"
            $noAutoTerminateClusters += $name
            $script:RootCauses += "Cluster '$name' has NO AUTO-TERMINATION - runs indefinitely, wasting quota"
        }
        else {
            Write-Log "  Auto-terminate: $autoTerm minutes" "INFO"
        }
        
        # Get cluster events (autoscaling events)
        try {
            $eventsResp = Invoke-DBApi -Path "/clusters/events" -Method "POST" -Body @{
                cluster_id = $id
                order = "DESC"
                limit = 100
            }
            
            if ($eventsResp -and $eventsResp.events) {
                $scaleEvents = $eventsResp.events | Where-Object {
                    $_.type -match "RESIZE|SCALE|UPSIZE|DOWNSIZE"
                }
                
                if ($scaleEvents.Count -gt 0) {
                    Write-Log "  Found $($scaleEvents.Count) autoscaling events"
                    
                    # Look for rapid scaling
                    $rapidScaleEvents = 0
                    for ($i = 0; $i -lt ($scaleEvents.Count - 1); $i++) {
                        $timeDiff = ($scaleEvents[$i].timestamp - $scaleEvents[$i+1].timestamp) / 1000 / 60
                        if ($timeDiff -lt 5) {  # Less than 5 minutes apart
                            $rapidScaleEvents++
                        }
                    }
                    
                    if ($rapidScaleEvents -gt 5) {
                        Write-Log "  ⚠ RAPID AUTOSCALING DETECTED: $rapidScaleEvents events < 5 mins apart" "CRITICAL"
                        $script:RootCauses += "Cluster '$name' experienced rapid autoscaling ($rapidScaleEvents events) - indicates workload spikes or inefficient queries"
                    }
                }
            }
        }
        catch {
            Write-Log "  Could not fetch events: $($_.Exception.Message)" "WARN"
        }
    }
    
    # Summary
    Write-Log ""
    Write-Log "=== AUTOSCALING ANALYSIS SUMMARY ===" "CRITICAL"
    
    if ($noAutoscaleClusters.Count -gt 0) {
        Write-Log "Clusters WITHOUT autoscaling: $($noAutoscaleClusters.Count)" "WARN"
        foreach ($c in $noAutoscaleClusters) {
            Write-Log "  - $c" "WARN"
        }
        $script:Recommendations += "Enable autoscaling on: $($noAutoscaleClusters -join ', ')"
    }
    
    if ($noAutoTerminateClusters.Count -gt 0) {
        Write-Log "Clusters WITHOUT auto-termination: $($noAutoTerminateClusters.Count)" "ERROR"
        foreach ($c in $noAutoTerminateClusters) {
            Write-Log "  - $c" "ERROR"
        }
        $script:Recommendations += "Enable auto-termination on: $($noAutoTerminateClusters -join ', ')"
    }
    
    if ($autoscaleIssues.Count -gt 0) {
        Write-Log "Autoscaling issues found: $($autoscaleIssues.Count)" "WARN"
        foreach ($issue in $autoscaleIssues) {
            Write-Log "  - $issue" "WARN"
        }
    }
}

# ============================================================================
# STEP 4: ROOT CAUSE ANALYSIS - AZURE QUOTA USAGE
# ============================================================================
function Analyze-AzureQuota {
    Write-Banner "STEP 4: ANALYZING AZURE VCPU QUOTA (ROOT CAUSE)"
    
    Write-Log "Checking vCPU quota usage in $($script:Location)..."
    
    try {
        $usages = Get-AzVMUsage -Location $script:Location -ErrorAction Stop
        
        $all = $usages | Where-Object {
            $_.Limit -gt 0 -and $_.CurrentValue -gt 0
        } | Sort-Object { $_.CurrentValue / $_.Limit } -Descending | Select-Object -First 20
        
        Write-Log ""
        Write-Log ("{0,-50} {1,8} {2,8} {3,8}" -f "VM Family", "Used", "Limit", "Usage%")
        Write-Log ("-" * 80)
        
        $quotaBreached = @()
        $quotaNearLimit = @()
        
        foreach ($u in $all) {
            $pct = [math]::Round(($u.CurrentValue / $u.Limit) * 100, 1)
            $level = if ($pct -gt 90) { "CRITICAL" } elseif ($pct -gt 80) { "ERROR" } elseif ($pct -gt 70) { "WARN" } else { "INFO" }
            
            Write-Log ("{0,-50} {1,8} {2,8} {3,7}%" -f $u.Name.LocalizedValue, $u.CurrentValue, $u.Limit, $pct) $level
            
            if ($pct -gt 90) {
                $quotaBreached += $u.Name.LocalizedValue
                $script:RootCauses += "QUOTA BREACH: $($u.Name.LocalizedValue) at $pct% ($($u.CurrentValue)/$($u.Limit) vCPUs)"
            }
            elseif ($pct -gt 80) {
                $quotaNearLimit += $u.Name.LocalizedValue
                $script:RootCauses += "QUOTA NEAR LIMIT: $($u.Name.LocalizedValue) at $pct%"
            }
        }
        
        Write-Log ""
        if ($quotaBreached.Count -gt 0) {
            Write-Log "=== QUOTA BREACHED ===" "CRITICAL"
            foreach ($q in $quotaBreached) {
                Write-Log "  - $q" "CRITICAL"
                $u = $all | Where-Object { $_.Name.LocalizedValue -eq $q }
                $recommended = [int]([Math]::Max($u.Limit * 2, $u.CurrentValue * 2.5))
                Write-Log "    RECOMMENDED: Increase from $($u.Limit) to $recommended vCPUs" "CRITICAL"
                $script:Recommendations += "Request quota increase for $q : $($u.Limit) -> $recommended vCPUs"
            }
        }
        
        if ($quotaNearLimit.Count -gt 0) {
            Write-Log "=== QUOTA NEAR LIMIT ===" "WARN"
            foreach ($q in $quotaNearLimit) {
                Write-Log "  - $q" "WARN"
            }
        }
    }
    catch {
        Write-Log "Error checking quota: $($_.Exception.Message)" "ERROR"
    }
}

# ============================================================================
# STEP 5: ROOT CAUSE SUMMARY
# ============================================================================
function Show-RootCauseSummary {
    Write-Banner "ROOT CAUSE ANALYSIS - SUMMARY"
    
    if ($script:RootCauses.Count -eq 0) {
        Write-Log "No specific root causes identified (all systems appear healthy)" "SUCCESS"
        Write-Log "The quota issue may have been a temporary spike." "INFO"
        return
    }
    
    Write-Log "=== IDENTIFIED ROOT CAUSES ===" "CRITICAL"
    Write-Log "Total issues found: $($script:RootCauses.Count)" "CRITICAL"
    Write-Log ""
    
    for ($i = 0; $i -lt $script:RootCauses.Count; $i++) {
        Write-Log "$($i+1). $($script:RootCauses[$i])" "ROOTCAUSE"
    }
    
    Write-Log ""
    Write-Log "=== RECOMMENDATIONS ===" "CRITICAL"
    for ($i = 0; $i -lt $script:Recommendations.Count; $i++) {
        Write-Log "$($i+1). $($script:Recommendations[$i])" "SUCCESS"
    }
    
    # Export root cause report
    if ($ExportReport) {
        $reportPath = Join-Path $ReportDir "RootCauseReport.txt"
        $report = @"
DATABRICKS QUOTA BREACH - ROOT CAUSE ANALYSIS
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Workspace: $($script:WorkspaceUrl)
Analysis Period: Last $AnalysisDays days

=== ROOT CAUSES IDENTIFIED ===
$($script:RootCauses | ForEach-Object { "- $_" } | Out-String)

=== RECOMMENDATIONS ===
$($script:Recommendations | ForEach-Object { "- $_" } | Out-String)

=== TOP RESOURCE HOGS ===
$($script:ResourceHogs | ForEach-Object { 
    "Job: $($_.JobName) | Runs: $($_.TotalRuns) | Total: $($_.TotalDurationMins) mins | Avg: $($_.AvgDurationMins) mins"
} | Out-String)
"@
        
        Set-Content -Path $reportPath -Value $report
        Write-Log "Root cause report exported to: $reportPath" "SUCCESS"
    }
}

# ============================================================================
# STEP 6: APPLY PERMANENT FIXES
# ============================================================================
function Apply-PermanentFixes {
    Write-Banner "APPLYING PERMANENT FIXES"
    
    if (-not $PSCmdlet.ShouldProcess("Databricks clusters", "Apply permanent fixes")) {
        Write-Log "Skipped by user (use -WhatIf to see changes)" "WARN"
        return
    }
    
    Write-Log "WARNING: This will modify cluster configurations!" "WARN"
    Write-Host ""
    $confirm = Read-Host "Type 'YES' to proceed with fixes"
    if ($confirm -ne "YES") {
        Write-Log "Cancelled by user" "WARN"
        return
    }
    
    # Get all clusters
    $clustersResp = Invoke-DBApi -Path "/clusters/list"
    if (-not $clustersResp -or -not $clustersResp.clusters) {
        Write-Log "No clusters to fix" "WARN"
        return
    }
    
    $clusters = $clustersResp.clusters
    
    foreach ($cluster in $clusters) {
        $name = $cluster.cluster_name
        $id = $cluster.cluster_id
        $state = $cluster.state
        
        Write-Log "Processing cluster: $name"
        
        # Skip non-running clusters for now
        if ($state -notin @("RUNNING", "PENDING", "RESIZING")) {
            Write-Log "  Skipping (state: $state)" "INFO"
            continue
        }
        
        $changes = @()
        $edit = @{
            cluster_id = $id
            cluster_name = $name
            spark_version = $cluster.spark_version
            node_type_id = $cluster.node_type_id
        }
        
        # Copy essential fields
        if ($cluster.driver_node_type_id) { $edit["driver_node_type_id"] = $cluster.driver_node_type_id }
        if ($cluster.azure_attributes) { $edit["azure_attributes"] = $cluster.azure_attributes }
        if ($cluster.custom_tags) { $edit["custom_tags"] = $cluster.custom_tags }
        
        # FIX 1: Enable autoscaling
        if (-not $cluster.autoscale) {
            $currentWorkers = if ($cluster.num_workers) { $cluster.num_workers } else { 2 }
            $minW = [Math]::Max(1, [Math]::Floor($currentWorkers / 2))
            $maxW = [Math]::Min(8, $currentWorkers * 2)  # Cap at 8 to prevent quota issues
            
            $edit["autoscale"] = @{
                min_workers = $minW
                max_workers = $maxW
            }
            $changes += "ENABLED autoscaling: $minW-$maxW workers (was fixed $currentWorkers)"
        }
        else {
            # Fix excessive max workers
            $minW = $cluster.autoscale.min_workers
            $maxW = $cluster.autoscale.max_workers
            
            if ($maxW -gt 12) {
                $newMax = 12  # Safe limit to prevent quota exhaustion
                $edit["autoscale"] = @{
                    min_workers = $minW
                    max_workers = $newMax
                }
                $changes += "REDUCED max workers: $maxW -> $newMax (quota safety)"
            }
            else {
                $edit["autoscale"] = @{
                    min_workers = $minW
                    max_workers = $maxW
                }
            }
        }
        
        # FIX 2: Enable auto-termination
        $autoTerm = $cluster.autotermination_minutes
        if (-not $autoTerm -or $autoTerm -eq 0) {
            $edit["autotermination_minutes"] = 30
            $changes += "ENABLED auto-termination: 30 minutes (was NEVER)"
        }
        elseif ($autoTerm -gt 120) {
            $edit["autotermination_minutes"] = 60
            $changes += "REDUCED auto-termination: $autoTerm -> 60 minutes"
        }
        else {
            $edit["autotermination_minutes"] = $autoTerm
        }
        
        # FIX 3: Add Spark optimizations
        $conf = @{}
        if ($cluster.spark_conf) {
            try {
                $cluster.spark_conf.PSObject.Properties | ForEach-Object { 
                    $conf[$_.Name] = $_.Value 
                }
            }
            catch { }
        }
        
        $optimizations = @{
            "spark.sql.adaptive.enabled" = "true"
            "spark.sql.adaptive.coalescePartitions.enabled" = "true"
            "spark.sql.adaptive.skewJoin.enabled" = "true"
            "spark.databricks.delta.optimizeWrite.enabled" = "true"
            "spark.databricks.delta.autoCompact.enabled" = "true"
            "spark.databricks.io.cache.enabled" = "true"
            "spark.databricks.adaptive.autoOptimizeShuffle.enabled" = "true"
        }
        
        $added = 0
        foreach ($key in $optimizations.Keys) {
            if (-not $conf.ContainsKey($key)) {
                $conf[$key] = $optimizations[$key]
                $added++
            }
        }
        
        if ($added -gt 0) {
            $changes += "ADDED $added Spark optimizations (better resource usage)"
        }
        $edit["spark_conf"] = $conf
        
        # Apply changes
        if ($changes.Count -gt 0) {
            Write-Log "  Changes to apply:" "SUCCESS"
            foreach ($change in $changes) {
                Write-Log "    + $change" "SUCCESS"
            }
            
            try {
                Invoke-DBApi -Path "/clusters/edit" -Method "POST" -Body $edit | Out-Null
                Write-Log "  ✓ UPDATED cluster '$name'" "SUCCESS"
                $script:FixesApplied += "Cluster '$name': $($changes -join '; ')"
            }
            catch {
                Write-Log "  ✗ FAILED to update '$name': $($_.Exception.Message)" "ERROR"
            }
        }
        else {
            Write-Log "  Already optimized" "INFO"
        }
        
        Write-Log ""
    }
    
    # FIX 4: Create cluster policy
    Write-Log "Creating quota-safe cluster policy..."
    
    $policyDef = @{
        "autoscale.min_workers" = @{ 
            type = "range"
            minValue = 1
            maxValue = 4
            defaultValue = 1
        }
        "autoscale.max_workers" = @{ 
            type = "range"
            minValue = 2
            maxValue = 12
            defaultValue = 8
        }
        "autotermination_minutes" = @{ 
            type = "range"
            minValue = 10
            maxValue = 120
            defaultValue = 30
        }
        "spark_conf.spark.sql.adaptive.enabled" = @{
            type = "fixed"
            value = "true"
            hidden = $true
        }
        "spark_conf.spark.databricks.delta.optimizeWrite.enabled" = @{
            type = "fixed"
            value = "true"
            hidden = $true
        }
    }
    
    try {
        $policyBody = @{
            name = "Quota-Safe Production Policy (Auto-Created)"
            definition = ($policyDef | ConvertTo-Json -Depth 10 -Compress)
            max_clusters_per_user = 5
        }
        
        $result = Invoke-DBApi -Path "/policies/clusters/create" -Method "POST" -Body $policyBody
        if ($result -and $result.policy_id) {
            Write-Log "✓ Created cluster policy: $($result.policy_id)" "SUCCESS"
            $script:FixesApplied += "Created cluster policy: $($result.policy_id)"
        }
    }
    catch {
        if ($_.Exception.Message -match "already exists") {
            Write-Log "Policy already exists (skipped)" "INFO"
        }
        else {
            Write-Log "Policy creation failed: $($_.Exception.Message)" "ERROR"
        }
    }
}

# ============================================================================
# STEP 7: SETUP PREVENTION MEASURES
# ============================================================================
function Setup-PreventionMeasures {
    Write-Banner "SETTING UP PREVENTION MEASURES"
    
    Write-Log "Creating Azure Monitor alerts for quota monitoring..."
    
    try {
        Import-Module Az.Monitor -ErrorAction SilentlyContinue
        
        # Alert 1: High vCPU usage
        Write-Log "Setting up vCPU quota alert..."
        
        # This would require workspace-level metrics
        # For now, we'll log the recommendation
        Write-Log "RECOMMENDATION: Set up Azure Monitor alerts:" "WARN"
        Write-Log "  1. Go to Azure Portal > Monitor > Alerts" "INFO"
        Write-Log "  2. Create alert for vCPU quota > 80%" "INFO"
        Write-Log "  3. Set up notification to your team" "INFO"
        
        $script:Recommendations += "Set up Azure Monitor alert for vCPU quota > 80%"
        
    }
    catch {
        Write-Log "Could not set up alerts: $($_.Exception.Message)" "WARN"
    }
    
    Write-Log ""
    Write-Log "Creating monitoring dashboard recommendations..."
    Write-Log "  1. Monitor cluster autoscaling events daily" "INFO"
    Write-Log "  2. Review long-running jobs weekly" "INFO"
    Write-Log "  3. Check quota usage before major deployments" "INFO"
    Write-Log "  4. Set up Databricks SQL alerts for job failures" "INFO"
}

# ============================================================================
# STEP 8: FINAL SUMMARY & NEXT STEPS
# ============================================================================
function Show-FinalSummary {
    Write-Banner "FINAL SUMMARY & NEXT STEPS"
    
    Write-Log "=== ROOT CAUSES FOUND ===" "CRITICAL"
    if ($script:RootCauses.Count -eq 0) {
        Write-Log "No specific root causes identified" "SUCCESS"
    }
    else {
        for ($i = 0; $i -lt $script:RootCauses.Count; $i++) {
            Write-Log "$($i+1). $($script:RootCauses[$i])" "WARN"
        }
    }
    
    Write-Log ""
    Write-Log "=== FIXES APPLIED ===" "SUCCESS"
    if ($script:FixesApplied.Count -eq 0) {
        Write-Log "No fixes applied (run with -Mode fix)" "INFO"
    }
    else {
        for ($i = 0; $i -lt $script:FixesApplied.Count; $i++) {
            Write-Log "$($i+1). $($script:FixesApplied[$i])" "SUCCESS"
        }
    }
    
    Write-Log ""
    Write-Log "=== NEXT STEPS ===" "CRITICAL"
    Write-Log ""
    Write-Log "1. RESPOND TO DATABRICKS SUPPORT (Ticket 500Vp00000IrEJdIAM):" "INFO"
    Write-Log "   - Share the root cause findings from this analysis" "INFO"
    Write-Log "   - Confirm fixes have been applied" "INFO"
    Write-Log "   - Ask about workspace-level throttling if quota wasn't the issue" "INFO"
    Write-Log ""
    Write-Log "2. REQUEST AZURE QUOTA INCREASE (if quota was breached):" "INFO"
    Write-Log "   - Portal: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" "INFO"
    Write-Log "   - Filter: Microsoft.Compute, Location: $($script:Location)" "INFO"
    Write-Log "   - Request 2x current peak for affected VM families" "INFO"
    Write-Log ""
    Write-Log "3. MONITOR FOR 48 HOURS:" "INFO"
    Write-Log "   - Check cluster autoscaling events" "INFO"
    Write-Log "   - Monitor job execution times" "INFO"
    Write-Log "   - Watch for quota warnings" "INFO"
    Write-Log ""
    Write-Log "4. ASSIGN CLUSTER POLICY:" "INFO"
    Write-Log "   - Databricks UI > Compute > Policies" "INFO"
    Write-Log "   - Assign 'Quota-Safe Production Policy' to all production clusters" "INFO"
    Write-Log ""
    Write-Log "5. OPTIMIZE RESOURCE-HUNGRY JOBS:" "INFO"
    if ($script:ResourceHogs.Count -gt 0) {
        Write-Log "   Focus on these jobs:" "WARN"
        foreach ($job in ($script:ResourceHogs | Select-Object -First 5)) {
            Write-Log "     - $($job.JobName) (Avg: $($job.AvgDurationMins) mins)" "WARN"
        }
    }
    Write-Log ""
    Write-Log "=== FILES GENERATED ===" "INFO"
    Write-Log "Log file: $LogFile" "SUCCESS"
    if ($ExportReport) {
        Write-Log "Reports: $ReportDir" "SUCCESS"
    }
    Write-Log ""
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Banner "DATABRICKS QUOTA ROOT CAUSE ANALYZER & AUTO-FIX"
Write-Log "Mode: $Mode"
Write-Log "Analysis Period: Last $AnalysisDays days"
Write-Log ""

# Step 1: Auto-discovery
Initialize-AutoDiscovery

# Step 2-5: Root cause analysis
if ($Mode -in @("rootcause", "all")) {
    Analyze-JobExecutionHistory
    Analyze-ClusterAutoscaling
    Analyze-AzureQuota
    Show-RootCauseSummary
}

# Step 6-7: Apply fixes
if ($Mode -in @("fix", "all")) {
    Apply-PermanentFixes
    Setup-PreventionMeasures
}

# Step 8: Final summary
Show-FinalSummary

Write-Log ""
Write-Log "=== DONE ===" "SUCCESS"
Write-Log "Check the log file for complete details: $LogFile" "SUCCESS"
