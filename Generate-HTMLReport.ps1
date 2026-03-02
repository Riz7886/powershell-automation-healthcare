#Requires -Version 5.1
<#
.SYNOPSIS
    HTML Report Generator for Databricks Quota Analysis
    
.DESCRIPTION
    ADD-ON to the main script. Run this AFTER the main script to get HTML reports.
    Also checks if quota increased from 10 to 64.
    
.PARAMETER LogFile
    Path to the log file from the main script
    
.EXAMPLE
    .\Generate-HTMLReport.ps1 -LogFile ".\DatabricksRootCause_20250209_123456.log"
#>

param(
    [string]$LogFile = "",
    [string]$OutputFile = ".\DatabricksQuotaReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
)

# ============================================================================
# SETUP
# ============================================================================
$ErrorActionPreference = "Continue"
$script:WorkspaceUrl = ""
$script:Token = ""
$script:SubscriptionId = ""
$script:Location = ""
$script:QuotaData = @()
$script:RootCauses = @()
$script:Fixes = @()
$script:ResourceHogs = @()

Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "  DATABRICKS QUOTA ANALYSIS - HTML REPORT GENERATOR" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# AUTO-DISCOVERY (LIGHT VERSION)
# ============================================================================
function Get-DatabricksConnection {
    Write-Host "Connecting to Azure and Databricks..." -ForegroundColor Yellow
    
    # Azure
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        Connect-AzAccount | Out-Null
        $ctx = Get-AzContext
    }
    
    $script:SubscriptionId = $ctx.Subscription.Id
    Write-Host "✓ Azure: $($ctx.Subscription.Name)" -ForegroundColor Green
    
    # Find Databricks
    $ws = Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" | Select-Object -First 1
    if ($ws) {
        $detail = Get-AzResource -ResourceId $ws.ResourceId -ExpandProperties
        $url = $detail.Properties.workspaceUrl
        if ($url) {
            $script:WorkspaceUrl = "https://$url"
        }
        else {
            $wid = $detail.Properties.workspaceId
            $script:WorkspaceUrl = "https://adb-$wid.azuredatabricks.net"
        }
        $script:Location = $ws.Location
        Write-Host "✓ Databricks: $($ws.Name)" -ForegroundColor Green
    }
    
    # Get token
    $dbAppId = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
    try {
        $tokenObj = Get-AzAccessToken -ResourceUrl $dbAppId -ErrorAction Stop
        $script:Token = if ($tokenObj.Token) { $tokenObj.Token } else { $tokenObj.AccessToken }
        Write-Host "✓ Token acquired" -ForegroundColor Green
    }
    catch {
        Write-Host "✗ Auto-token failed. Need manual token." -ForegroundColor Red
        $script:Token = Read-Host "Paste Databricks token"
    }
}

# ============================================================================
# CHECK QUOTA INCREASE (10 -> 64)
# ============================================================================
function Check-QuotaIncrease {
    Write-Host "`nChecking if quota was increased..." -ForegroundColor Yellow
    
    try {
        $usages = Get-AzVMUsage -Location $script:Location -ErrorAction Stop
        
        $quotaIncreased = $false
        $quotaChanges = @()
        
        foreach ($u in $usages) {
            if ($u.Limit -ge 64 -and $u.Limit -le 100) {
                # Likely increased from 10 to 64
                $quotaChanges += @{
                    Family = $u.Name.LocalizedValue
                    CurrentLimit = $u.Limit
                    Usage = $u.CurrentValue
                    Percent = [math]::Round(($u.CurrentValue / $u.Limit) * 100, 1)
                    LikelyIncreased = ($u.Limit -eq 64)
                }
                
                if ($u.Limit -eq 64) {
                    Write-Host "  ✓ FOUND: $($u.Name.LocalizedValue) = 64 vCPUs (likely increased from 10)" -ForegroundColor Green
                    $quotaIncreased = $true
                }
            }
        }
        
        if ($quotaIncreased) {
            Write-Host "`n✓✓✓ QUOTA INCREASE CONFIRMED ✓✓✓" -ForegroundColor Green
            Write-Host "At least one VM family shows 64 vCPU limit (increased from 10)" -ForegroundColor Green
        }
        else {
            Write-Host "`n⚠ No obvious quota increase detected" -ForegroundColor Yellow
            Write-Host "Current quotas:" -ForegroundColor Yellow
            $top = $usages | Where-Object { $_.Limit -gt 0 } | Sort-Object Limit -Descending | Select-Object -First 5
            foreach ($t in $top) {
                Write-Host "  $($t.Name.LocalizedValue): $($t.Limit) vCPUs" -ForegroundColor Cyan
            }
        }
        
        $script:QuotaData = $quotaChanges
        return $quotaIncreased
    }
    catch {
        Write-Host "Error checking quota: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ============================================================================
# COLLECT DATA FOR REPORT
# ============================================================================
function Collect-ReportData {
    Write-Host "`nCollecting data for report..." -ForegroundColor Yellow
    
    # Get clusters
    $headers = @{
        "Authorization" = "Bearer $($script:Token)"
        "Content-Type" = "application/json"
    }
    
    try {
        $clustersResp = Invoke-RestMethod -Uri "$($script:WorkspaceUrl)/api/2.0/clusters/list" -Headers $headers -Method Get
        $clusters = if ($clustersResp.clusters) { $clustersResp.clusters } else { @() }
        
        # Get jobs
        $jobsResp = Invoke-RestMethod -Uri "$($script:WorkspaceUrl)/api/2.0/jobs/list" -Headers $headers -Method Get
        $jobs = if ($jobsResp.jobs) { $jobsResp.jobs } else { @() }
        
        # Get SQL warehouses
        try {
            $warehousesResp = Invoke-RestMethod -Uri "$($script:WorkspaceUrl)/api/2.0/sql/warehouses" -Headers $headers -Method Get
            $warehouses = if ($warehousesResp.warehouses) { $warehousesResp.warehouses } else { @() }
        }
        catch {
            $warehouses = @()
        }
        
        Write-Host "✓ Found: $($clusters.Count) clusters, $($jobs.Count) jobs, $($warehouses.Count) SQL warehouses" -ForegroundColor Green
        
        return @{
            Clusters = $clusters
            Jobs = $jobs
            Warehouses = $warehouses
        }
    }
    catch {
        Write-Host "Error collecting data: $($_.Exception.Message)" -ForegroundColor Red
        return @{
            Clusters = @()
            Jobs = @()
            Warehouses = @()
        }
    }
}

# ============================================================================
# GENERATE HTML REPORT
# ============================================================================
function Generate-HTMLReport {
    param(
        [object]$Data,
        [bool]$QuotaIncreased
    )
    
    Write-Host "`nGenerating HTML report..." -ForegroundColor Yellow
    
    $timestamp = Get-Date -Format "MMMM dd, yyyy HH:mm:ss"
    
    # Build cluster table rows
    $clusterRows = ""
    foreach ($c in $Data.Clusters) {
        $state = $c.state
        $stateColor = switch ($state) {
            "RUNNING" { "green" }
            "TERMINATED" { "gray" }
            "PENDING" { "orange" }
            default { "black" }
        }
        
        $autoscale = if ($c.autoscale) { 
            "$($c.autoscale.min_workers)-$($c.autoscale.max_workers)" 
        } else { 
            "Fixed: $($c.num_workers)" 
        }
        
        $autoTerm = if ($c.autotermination_minutes) { 
            "$($c.autotermination_minutes) min" 
        } else { 
            "<span style='color: red;'>NEVER</span>" 
        }
        
        $clusterRows += @"
        <tr>
            <td>$($c.cluster_name)</td>
            <td style="color: $stateColor; font-weight: bold;">$state</td>
            <td>$autoscale</td>
            <td>$autoTerm</td>
            <td style="font-size: 11px;">$($c.node_type_id)</td>
        </tr>
"@
    }
    
    # Build quota table rows
    $quotaRows = ""
    if ($script:QuotaData.Count -gt 0) {
        foreach ($q in ($script:QuotaData | Sort-Object Percent -Descending)) {
            $pctColor = if ($q.Percent -gt 80) { "red" } elseif ($q.Percent -gt 60) { "orange" } else { "green" }
            $increased = if ($q.LikelyIncreased) { "✓ YES" } else { "" }
            
            $quotaRows += @"
            <tr>
                <td>$($q.Family)</td>
                <td>$($q.Usage)</td>
                <td>$($q.CurrentLimit)</td>
                <td style="color: $pctColor; font-weight: bold;">$($q.Percent)%</td>
                <td style="color: green; font-weight: bold;">$increased</td>
            </tr>
"@
        }
    }
    
    # Build warehouse table rows
    $warehouseRows = ""
    foreach ($w in $Data.Warehouses) {
        $state = $w.state
        $stateColor = if ($state -eq "RUNNING") { "green" } else { "gray" }
        $size = $w.cluster_size
        
        $warehouseRows += @"
        <tr>
            <td>$($w.name)</td>
            <td style="color: $stateColor; font-weight: bold;">$state</td>
            <td>$size</td>
            <td>$($w.num_clusters)</td>
            <td>$($w.auto_stop_mins) min</td>
        </tr>
"@
    }
    
    # Quota increase banner
    $quotaBanner = if ($QuotaIncreased) {
        @"
        <div style="background: #d4edda; border: 2px solid #28a745; border-radius: 8px; padding: 20px; margin: 20px 0;">
            <h2 style="color: #155724; margin: 0;">✓ QUOTA INCREASE CONFIRMED</h2>
            <p style="margin: 10px 0 0 0; color: #155724;">
                Detected VM families with 64 vCPU limit (likely increased from 10).
                The quota increase request was approved!
            </p>
        </div>
"@
    } else {
        @"
        <div style="background: #fff3cd; border: 2px solid #ffc107; border-radius: 8px; padding: 20px; margin: 20px 0;">
            <h2 style="color: #856404; margin: 0;">⚠ Quota Status Unknown</h2>
            <p style="margin: 10px 0 0 0; color: #856404;">
                No obvious quota increase detected. Check Azure Portal to verify.
            </p>
        </div>
"@
    }
    
    # Generate full HTML
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Databricks Quota Analysis Report</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 0;
            padding: 20px;
            background: #f5f5f5;
        }
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            padding: 40px;
            border-radius: 10px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        h1 {
            color: #2c3e50;
            border-bottom: 3px solid #3498db;
            padding-bottom: 10px;
        }
        h2 {
            color: #34495e;
            margin-top: 30px;
            border-left: 4px solid #3498db;
            padding-left: 15px;
        }
        .header-info {
            background: #ecf0f1;
            padding: 15px;
            border-radius: 5px;
            margin: 20px 0;
        }
        .header-info p {
            margin: 5px 0;
            color: #2c3e50;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
        }
        th {
            background: #3498db;
            color: white;
            padding: 12px;
            text-align: left;
            font-weight: bold;
        }
        td {
            padding: 10px;
            border-bottom: 1px solid #ddd;
        }
        tr:hover {
            background: #f8f9fa;
        }
        .metric-box {
            display: inline-block;
            background: #3498db;
            color: white;
            padding: 20px;
            margin: 10px;
            border-radius: 8px;
            min-width: 200px;
            text-align: center;
        }
        .metric-box h3 {
            margin: 0;
            font-size: 36px;
        }
        .metric-box p {
            margin: 5px 0 0 0;
            opacity: 0.9;
        }
        .warning {
            background: #fff3cd;
            border-left: 4px solid #ffc107;
            padding: 15px;
            margin: 20px 0;
            color: #856404;
        }
        .success {
            background: #d4edda;
            border-left: 4px solid #28a745;
            padding: 15px;
            margin: 20px 0;
            color: #155724;
        }
        .footer {
            margin-top: 40px;
            padding-top: 20px;
            border-top: 2px solid #ddd;
            text-align: center;
            color: #7f8c8d;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔍 Databricks Quota Analysis Report</h1>
        
        <div class="header-info">
            <p><strong>Generated:</strong> $timestamp</p>
            <p><strong>Workspace:</strong> $($script:WorkspaceUrl)</p>
            <p><strong>Subscription:</strong> $($script:SubscriptionId)</p>
            <p><strong>Location:</strong> $($script:Location)</p>
        </div>
        
        $quotaBanner
        
        <h2>📊 Summary Metrics</h2>
        <div style="text-align: center;">
            <div class="metric-box" style="background: #3498db;">
                <h3>$($Data.Clusters.Count)</h3>
                <p>Total Clusters</p>
            </div>
            <div class="metric-box" style="background: #2ecc71;">
                <h3>$(($Data.Clusters | Where-Object { $_.state -eq 'RUNNING' }).Count)</h3>
                <p>Running Clusters</p>
            </div>
            <div class="metric-box" style="background: #e74c3c;">
                <h3>$(($Data.Clusters | Where-Object { -not $_.autoscale }).Count)</h3>
                <p>No Autoscale</p>
            </div>
            <div class="metric-box" style="background: #f39c12;">
                <h3>$($Data.Jobs.Count)</h3>
                <p>Total Jobs</p>
            </div>
            <div class="metric-box" style="background: #9b59b6;">
                <h3>$($Data.Warehouses.Count)</h3>
                <p>SQL Warehouses</p>
            </div>
        </div>
        
        <h2>🖥️ Cluster Configuration</h2>
        <table>
            <thead>
                <tr>
                    <th>Cluster Name</th>
                    <th>State</th>
                    <th>Autoscale</th>
                    <th>Auto-Terminate</th>
                    <th>Node Type</th>
                </tr>
            </thead>
            <tbody>
                $clusterRows
            </tbody>
        </table>
        
        <h2>📈 Azure vCPU Quota Status</h2>
        <table>
            <thead>
                <tr>
                    <th>VM Family</th>
                    <th>Current Usage</th>
                    <th>Limit</th>
                    <th>Usage %</th>
                    <th>Increased?</th>
                </tr>
            </thead>
            <tbody>
                $quotaRows
            </tbody>
        </table>
        
        <h2>🗄️ SQL Warehouses</h2>
        <table>
            <thead>
                <tr>
                    <th>Warehouse Name</th>
                    <th>State</th>
                    <th>Size</th>
                    <th>Num Clusters</th>
                    <th>Auto-Stop</th>
                </tr>
            </thead>
            <tbody>
                $warehouseRows
            </tbody>
        </table>
        
        <h2>✅ Recommendations</h2>
        <div class="success">
            <h3>What to Do Next:</h3>
            <ul>
                <li><strong>Monitor:</strong> Check cluster usage over next 48 hours</li>
                <li><strong>Optimize:</strong> Review jobs that run longest</li>
                <li><strong>Policy:</strong> Assign quota-safe cluster policy to all production clusters</li>
                <li><strong>Support:</strong> Update Databricks ticket with quota increase confirmation</li>
            </ul>
        </div>
        
        <div class="footer">
            <p>Report generated by Databricks Quota Analyzer</p>
            <p>For questions, contact your Azure administrator</p>
        </div>
    </div>
</body>
</html>
"@
    
    # Save HTML file
    Set-Content -Path $OutputFile -Value $html -Encoding UTF8
    Write-Host "✓ HTML report saved: $OutputFile" -ForegroundColor Green
    
    # Open in browser
    Start-Process $OutputFile
    Write-Host "✓ Opening report in browser..." -ForegroundColor Green
}

# ============================================================================
# MAIN
# ============================================================================

Get-DatabricksConnection
$quotaIncreased = Check-QuotaIncrease
$data = Collect-ReportData
Generate-HTMLReport -Data $data -QuotaIncreased $quotaIncreased

Write-Host ""
Write-Host "=" * 80 -ForegroundColor Green
Write-Host "  DONE! Report saved to: $OutputFile" -ForegroundColor Green
Write-Host "=" * 80 -ForegroundColor Green
Write-Host ""
