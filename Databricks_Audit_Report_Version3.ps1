<#
.SYNOPSIS
    Comprehensive Databricks audit and optimization analysis script

.DESCRIPTION
    This script performs a complete audit of Databricks workspaces, clusters, jobs, and costs
    to identify optimization opportunities and generate detailed reports

.PARAMETER WorkspaceUrl
    The URL of your Databricks workspace (e.g., https://adb-1234567890123456.7.azuredatabricks.net)

.PARAMETER Token
    Personal Access Token for Databricks API authentication

.PARAMETER SubscriptionId
    Azure Subscription ID for cost data retrieval

.PARAMETER OutputPath
    Path where audit reports will be saved (default: current directory)

.EXAMPLE
    .\Databricks_Audit_Report_Version3.ps1 -WorkspaceUrl "https://adb-xxx.azuredatabricks.net" -Token "dapi..." -SubscriptionId "sub-id" -OutputPath "C:\Reports"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceUrl,
    
    [Parameter(Mandatory=$true)]
    [string]$Token,
    
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "."
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportPath = Join-Path $OutputPath "Databricks_Audit_Report_$timestamp.html"
$csvPath = Join-Path $OutputPath "Databricks_Audit_Data_$timestamp.csv"

$headers = @{
    "Authorization" = "Bearer $Token"
    "Content-Type" = "application/json"
}

Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host "Starting Databricks Audit Report Generation..." -ForegroundColor Green
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host "Workspace:  $WorkspaceUrl" -ForegroundColor Cyan
Write-Host "Timestamp: $timestamp" -ForegroundColor Cyan
Write-Host ""

function Invoke-DatabricksApi {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body = $null
    )
    
    $uri = "$WorkspaceUrl/api/2.0/$Endpoint"
    
    try {
        if ($Body) {
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method $Method -Body ($Body | ConvertTo-Json)
        } else {
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method $Method
        }
        return $response
    }
    catch {
        Write-Warning "API call failed for $Endpoint : $_"
        return $null
    }
}

Write-Host "[1/5] Retrieving cluster information..." -ForegroundColor Yellow
$clusters = Invoke-DatabricksApi -Endpoint "clusters/list"
$clusterList = if ($clusters.clusters) { $clusters.clusters } else { @() }
Write-Host "      Found $($clusterList.Count) clusters" -ForegroundColor Gray

Write-Host "[2/5] Retrieving jobs information..." -ForegroundColor Yellow
$jobs = Invoke-DatabricksApi -Endpoint "jobs/list"
$jobList = if ($jobs.jobs) { $jobs.jobs } else { @() }
Write-Host "      Found $($jobList.Count) jobs" -ForegroundColor Gray

Write-Host "[3/5] Retrieving instance pools..." -ForegroundColor Yellow
$pools = Invoke-DatabricksApi -Endpoint "instance-pools/list"
$poolList = if ($pools.instance_pools) { $pools.instance_pools } else { @() }
Write-Host "      Found $($poolList.Count) instance pools" -ForegroundColor Gray

Write-Host "[4/5] Analyzing cluster configurations..." -ForegroundColor Yellow

$auditResults = @()
$totalMonthlyCost = 0
$potentialSavings = 0
$clusterCount = 0

foreach ($cluster in $clusterList) {
    $clusterCount++
    Write-Host "      Processing cluster $clusterCount/$($clusterList.Count): $($cluster.cluster_name)" -ForegroundColor Gray
    
    $clusterId = $cluster.cluster_id
    $clusterName = $cluster.cluster_name
    $clusterSource = $cluster.cluster_source
    $state = $cluster.state
    $nodeType = if ($cluster.node_type_id) { $cluster.node_type_id } else { "Unknown" }
    $numWorkers = if ($cluster.num_workers) { $cluster.num_workers } elseif ($cluster.autoscale) { $cluster.autoscale.max_workers } else { 0 }
    $autoTermination = $cluster.autotermination_minutes
    $sparkVersion = if ($cluster.spark_version) { $cluster.spark_version } else { "Unknown" }
    $enablePhoton = if ($cluster.runtime_engine -eq "PHOTON") { "Yes" } else { "No" }
    
    $isJobCluster = $clusterSource -eq "JOB"
    $hasAutoTermination = $null -ne $autoTermination -and $autoTermination -gt 0
    
    # Estimate monthly cost (simplified calculation)
    $estimatedMonthlyCost = 0
    if ($numWorkers -gt 0) {
        $estimatedMonthlyCost = ($numWorkers + 1) * 730 * 0.15  # $0.15/hour estimate
    }
    
    $recommendations = @()
    $savingsOpportunity = 0
    
    # Auto-termination check
    if (-not $hasAutoTermination -and -not $isJobCluster) {
        $recommendations += "Enable auto-termination (30 min recommended)"
        $savingsOpportunity += $estimatedMonthlyCost * 0.60
    }
    
    # Interactive cluster check
    if ($clusterSource -eq "UI" -and $state -eq "RUNNING") {
        $recommendations += "Consider converting to job cluster if used for scheduled tasks"
        $savingsOpportunity += $estimatedMonthlyCost * 0.35
    }
    
    # Photon check
    if ($enablePhoton -eq "No" -and $sparkVersion -notlike "*ML*") {
        $recommendations += "Enable Photon for better performance and cost efficiency"
        $savingsOpportunity += $estimatedMonthlyCost * 0.25
    }
    
    # Cluster size check
    if ($numWorkers -gt 10) {
        $recommendations += "Review cluster size - consider rightsizing or autoscaling"
        $savingsOpportunity += $estimatedMonthlyCost * 0.30
    }
    
    # Instance type check
    if ($nodeType -like "*Standard_D*" -and $numWorkers -gt 0) {
        $recommendations += "Consider memory-optimized instances for Spark workloads"
    }
    
    $totalMonthlyCost += $estimatedMonthlyCost
    $potentialSavings += $savingsOpportunity
    
    $auditResults += [PSCustomObject]@{
        ClusterId = $clusterId
        ClusterName = $clusterName
        Type = if ($isJobCluster) { "Job Cluster" } else { "Interactive Cluster" }
        State = $state
        NodeType = $nodeType
        Workers = $numWorkers
        AutoTermination = if ($hasAutoTermination) { "$autoTermination min" } else { "Disabled" }
        PhotonEnabled = $enablePhoton
        SparkVersion = $sparkVersion
        EstimatedMonthlyCost = [math]::Round($estimatedMonthlyCost, 2)
        SavingsOpportunity = [math]::Round($savingsOpportunity, 2)
        Recommendations = if ($recommendations.Count -gt 0) { $recommendations -join "; " } else { "No recommendations" }
        Priority = if ($savingsOpportunity -gt 1000) { "High" } elseif ($savingsOpportunity -gt 500) { "Medium" } else { "Low" }
    }
}

Write-Host "[5/5] Analyzing jobs..." -ForegroundColor Yellow

$jobAnalysis = @()
$jobCount = 0

foreach ($job in $jobList) {
    $jobCount++
    Write-Host "      Processing job $jobCount/$($jobList.Count)" -ForegroundColor Gray
    
    $jobId = $job.job_id
    $jobName = if ($job.settings.name) { $job.settings.name } else { "Unnamed Job" }
    $schedule = if ($job.settings.schedule) { "Scheduled" } else { "Manual" }
    $clusterType = if ($job.settings.new_cluster) { "New Cluster" } else { "Existing Cluster" }
    
    $jobRecommendations = @()
    
    if ($clusterType -eq "Existing Cluster" -and $schedule -eq "Scheduled") {
        $jobRecommendations += "Convert to job cluster for cost savings"
    }
    
    if ($job.settings.new_cluster -and -not $job.settings.new_cluster.autotermination_minutes) {
        $jobRecommendations += "Ensure job cluster auto-terminates immediately"
    }
    
    $jobAnalysis += [PSCustomObject]@{
        JobId = $jobId
        JobName = $jobName
        Schedule = $schedule
        ClusterType = $clusterType
        Recommendations = if ($jobRecommendations.Count -gt 0) { $jobRecommendations -join "; " } else { "No recommendations" }
    }
}

Write-Host ""
Write-Host "Generating HTML report..." -ForegroundColor Yellow

$htmlReport = @"
<!DOCTYPE html>
<html>
<head>
    <title>Databricks Audit Report - $timestamp</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background-color: #f5f5f5; }
        .header { background-color: #0078d4; color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; }
        .header h1 { margin: 0; font-size: 28px; }
        .header p { margin: 5px 0 0 0; font-size: 14px; }
        .summary { background-color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .summary h2 { margin-top: 0; color: #0078d4; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        .metric { display: inline-block; margin: 10px 20px 10px 0; }
        .metric-label { font-size: 12px; color: #666; text-transform: uppercase; }
        .metric-value { font-size: 24px; font-weight: bold; color: #0078d4; }
        .savings { color: #107c10; }
        table { width: 100%; border-collapse: collapse; background-color: white; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin-bottom: 20px; font-size: 13px; }
        th { background-color: #0078d4; color: white; padding: 12px; text-align: left; font-weight: 600; }
        td { padding: 10px 12px; border-bottom: 1px solid #e0e0e0; }
        tr:hover { background-color: #f5f5f5; }
        .priority-high { color: #d13438; font-weight: bold; }
        .priority-medium { color: #ff8c00; font-weight: bold; }
        .priority-low { color: #107c10; }
        .section { background-color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .section h2 { margin-top: 0; color: #0078d4; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        .footer { text-align: center; color: #666; font-size: 12px; margin-top: 30px; padding-top: 20px; border-top: 1px solid #e0e0e0; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Databricks Audit Report</h1>
        <p>Generated: $timestamp</p>
        <p>Workspace: $WorkspaceUrl</p>
    </div>
    
    <div class="summary">
        <h2>Executive Summary</h2>
        <div class="metric">
            <div class="metric-label">Total Clusters</div>
            <div class="metric-value">$($clusterList.Count)</div>
        </div>
        <div class="metric">
            <div class="metric-label">Total Jobs</div>
            <div class="metric-value">$($jobList.Count)</div>
        </div>
        <div class="metric">
            <div class="metric-label">Estimated Monthly Cost</div>
            <div class="metric-value">`$$([math]::Round($totalMonthlyCost, 2))</div>
        </div>
        <div class="metric">
            <div class="metric-label savings">Potential Monthly Savings</div>
            <div class="metric-value savings">`$$([math]::Round($potentialSavings, 2))</div>
        </div>
        <div class="metric">
            <div class="metric-label savings">Potential Annual Savings</div>
            <div class="metric-value savings">`$$([math]::Round($potentialSavings * 12, 2))</div>
        </div>
    </div>
    
    <div class="section">
        <h2>Cluster Analysis and Recommendations</h2>
        <table>
            <tr>
                <th>Cluster Name</th>
                <th>Type</th>
                <th>State</th>
                <th>Workers</th>
                <th>Auto-Term</th>
                <th>Photon</th>
                <th>Monthly Cost</th>
                <th>Savings Opp.</th>
                <th>Priority</th>
                <th>Recommendations</th>
            </tr>
"@

foreach ($result in $auditResults | Sort-Object -Property SavingsOpportunity -Descending) {
    $priorityClass = "priority-$($result.Priority.ToLower())"
    $htmlReport += @"
            <tr>
                <td>$($result.ClusterName)</td>
                <td>$($result.Type)</td>
                <td>$($result.State)</td>
                <td>$($result.Workers)</td>
                <td>$($result.AutoTermination)</td>
                <td>$($result.PhotonEnabled)</td>
                <td>`$$($result.EstimatedMonthlyCost)</td>
                <td class="savings">`$$($result.SavingsOpportunity)</td>
                <td class="$priorityClass">$($result.Priority)</td>
                <td>$($result.Recommendations)</td>
            </tr>
"@
}

$htmlReport += @"
        </table>
    </div>
    
    <div class="section">
        <h2>Job Analysis</h2>
        <table>
            <tr>
                <th>Job Name</th>
                <th>Schedule</th>
                <th>Cluster Type</th>
                <th>Recommendations</th>
            </tr>
"@

foreach ($job in $jobAnalysis) {
    $htmlReport += @"
            <tr>
                <td>$($job.JobName)</td>
                <td>$($job.Schedule)</td>
                <td>$($job.ClusterType)</td>
                <td>$($job.Recommendations)</td>
            </tr>
"@
}

$clustersWithoutAutoTerm = ($auditResults | Where-Object { $_.Type -eq 'Interactive Cluster' -and $_.AutoTermination -eq 'Disabled' }).Count
$clustersWithoutPhoton = ($auditResults | Where-Object { $_.PhotonEnabled -eq 'No' }).Count
$highPriorityCount = ($auditResults | Where-Object { $_.Priority -eq 'High' }).Count
$jobsUsingExistingClusters = ($jobAnalysis | Where-Object { $_.ClusterType -eq 'Existing Cluster' -and $_.Schedule -eq 'Scheduled' }).Count

$htmlReport += @"
        </table>
    </div>
    
    <div class="section">
        <h2>Key Findings</h2>
        <ul>
            <li>Total clusters analyzed: $($clusterList.Count)</li>
            <li>Interactive clusters without auto-termination: $clustersWithoutAutoTerm</li>
            <li>Clusters without Photon enabled: $clustersWithoutPhoton</li>
            <li>High priority optimization opportunities: $highPriorityCount</li>
            <li>Jobs using existing clusters for scheduled tasks: $jobsUsingExistingClusters</li>
            <li>Estimated monthly cost: `$$([math]::Round($totalMonthlyCost, 2))</li>
            <li>Potential monthly savings: `$$([math]::Round($potentialSavings, 2))</li>
        </ul>
    </div>
    
    <div class="section">
        <h2>Recommended Actions</h2>
        <ol>
            <li>Enable auto-termination on all interactive clusters (30 minutes recommended)</li>
            <li>Convert scheduled jobs to use job clusters instead of existing clusters</li>
            <li>Enable Photon engine on all eligible clusters for 30-50% performance improvement</li>
            <li>Review and rightsize clusters with high worker counts</li>
            <li>Implement cluster policies to enforce governance</li>
            <li>Enable spot instances for fault-tolerant workloads</li>
            <li>Consolidate underutilized clusters</li>
        </ol>
    </div>
    
    <div class="footer">
        <p>This report is generated automatically. Please review recommendations with technical teams before implementation.</p>
        <p>For questions or concerns, contact the Infrastructure Optimization Team.</p>
    </div>
</body>
</html>
"@

$htmlReport | Out-File -FilePath $reportPath -Encoding UTF8

Write-Host "Exporting detailed data to CSV..." -ForegroundColor Yellow
$auditResults | Export-Csv -Path $csvPath -NoTypeInformation

Write-Host ""
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host "Audit Complete!" -ForegroundColor Green
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Reports Generated:" -ForegroundColor Yellow
Write-Host "  HTML Report: $reportPath" -ForegroundColor Cyan
Write-Host "  CSV Data:    $csvPath" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor Yellow
Write-Host "  Total Clusters:              $($clusterList.Count)" -ForegroundColor White
Write-Host "  Total Jobs:                  $($jobList.Count)" -ForegroundColor White
Write-Host "  Estimated Monthly Cost:      `$$([math]::Round($totalMonthlyCost, 2))" -ForegroundColor White
Write-Host "  Potential Monthly Savings:   `$$([math]::Round($potentialSavings, 2))" -ForegroundColor Green
Write-Host "  Potential Annual Savings:    `$$([math]::Round($potentialSavings * 12, 2))" -ForegroundColor Green
Write-Host ""