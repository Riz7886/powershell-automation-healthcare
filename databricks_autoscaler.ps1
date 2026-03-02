$ErrorActionPreference = "Continue"

# ===============================================================
# DATABRICKS AUTO-SCALER
# Checks latency + load, scales warehouses ONLY when needed
# Designed to run via Windows Task Scheduler 24/7
# ===============================================================

# ---------------------------------------------------------------
# CONFIGURATION - Edit these values
# ---------------------------------------------------------------
$config = @{
    # Service Principal credentials
    tenantId     = "8ef3d734-3ca5-4493-8d8b-52b2c54eab04"
    clientId     = "e44f4026-8d8e-4a26-a5c7-46269cc0d7de"
    # clientSecret will be read from environment variable or prompted
    clientSecret = ""

    # Databricks workspace URLs
    workspaces = @(
        "https://adb-3248848193480666.6.azuredatabricks.net",
        "https://adb-2758318924173706.6.azuredatabricks.net"
    )

    # Scaling thresholds
    latencyHighMs       = 30000   # 30 sec avg query time = scale UP
    latencyLowMs        = 5000    # 5 sec avg = can scale DOWN
    queueDepthHigh      = 5       # 5+ queued queries = scale UP
    idleMinutes         = 30      # 30 min no queries = scale DOWN

    # Cluster size ladder (smallest to largest)
    sizeLadder = @("2X-Small", "X-Small", "Small", "Medium", "Large", "X-Large", "2X-Large", "3X-Large", "4X-Large")

    # Max clusters scaling
    maxClustersMin      = 1
    maxClustersMax      = 4
    maxClustersStep     = 1

    # Safety limits
    maxScaleUpsPerHour  = 3       # Don't scale up more than 3 times/hour
    cooldownMinutes     = 10      # Wait 10 min between scale actions

    # Logging
    logDir              = ""      # Set below
    reportDir           = ""      # Set below
}

# Set log/report directories relative to script location
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$config.logDir = Join-Path $scriptDir "autoscaler-logs"
$config.reportDir = Join-Path $scriptDir "autoscaler-reports"

# Create directories
if (-not (Test-Path $config.logDir)) { New-Item -ItemType Directory -Path $config.logDir -Force | Out-Null }
if (-not (Test-Path $config.reportDir)) { New-Item -ItemType Directory -Path $config.reportDir -Force | Out-Null }

# State file to track scaling history
$stateFile = Join-Path $config.logDir "scaler-state.json"

# ---------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------
$logFile = Join-Path $config.logDir "autoscaler-$(Get-Date -Format 'yyyy-MM-dd').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "SCALE" { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line -ForegroundColor Gray }
    }
}

# ---------------------------------------------------------------
# LOAD STATE
# ---------------------------------------------------------------
$state = @{}
if (Test-Path $stateFile) {
    try {
        $state = Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    }
    catch { $state = @{} }
}
if (-not $state.scaleActions) { $state.scaleActions = @() }

function Save-State {
    $state | ConvertTo-Json -Depth 10 | Out-File $stateFile -Encoding UTF8
}

function Can-ScaleNow {
    param([string]$warehouseId)

    $now = Get-Date
    $hourAgo = $now.AddHours(-1)

    # Check cooldown
    $recent = $state.scaleActions | Where-Object {
        $_.warehouseId -eq $warehouseId -and
        [DateTime]::Parse($_.timestamp) -gt $now.AddMinutes(-$config.cooldownMinutes)
    }
    if ($recent) {
        Write-Log "  Cooldown active for $warehouseId (last action < $($config.cooldownMinutes) min ago)" "WARN"
        return $false
    }

    # Check max scale-ups per hour
    $hourActions = $state.scaleActions | Where-Object {
        $_.warehouseId -eq $warehouseId -and
        $_.direction -eq "UP" -and
        [DateTime]::Parse($_.timestamp) -gt $hourAgo
    }
    if ($hourActions.Count -ge $config.maxScaleUpsPerHour) {
        Write-Log "  Max scale-ups reached for $warehouseId ($($config.maxScaleUpsPerHour)/hour)" "WARN"
        return $false
    }

    return $true
}

function Record-ScaleAction {
    param([string]$warehouseId, [string]$name, [string]$direction, [string]$from, [string]$to, [string]$reason)

    $action = @{
        timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        warehouseId = $warehouseId
        name = $name
        direction = $direction
        from = $from
        to = $to
        reason = $reason
    }

    $state.scaleActions += $action

    # Keep only last 24 hours of actions
    $cutoff = (Get-Date).AddHours(-24).ToString("yyyy-MM-ddTHH:mm:ss")
    $state.scaleActions = @($state.scaleActions | Where-Object { $_.timestamp -gt $cutoff })

    Save-State
}

# ---------------------------------------------------------------
# GET OAUTH TOKEN
# ---------------------------------------------------------------
function Get-ServicePrincipalToken {
    $secret = $config.clientSecret

    # Try environment variable first
    if (-not $secret) {
        $secret = $env:DATABRICKS_SP_SECRET
    }

    # Try reading from a secrets file
    $secretFile = Join-Path $scriptDir ".sp-secret"
    if (-not $secret -and (Test-Path $secretFile)) {
        $secret = (Get-Content $secretFile -Raw).Trim()
    }

    if (-not $secret) {
        Write-Log "No client secret found. Set DATABRICKS_SP_SECRET env var or create .sp-secret file." "ERROR"
        return $null
    }

    try {
        $body = @{
            grant_type    = "client_credentials"
            client_id     = $config.clientId
            client_secret = $secret
            scope         = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d/.default"
        }

        $tokenResp = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$($config.tenantId)/oauth2/v2.0/token" -Method Post -Body $body -TimeoutSec 30
        return $tokenResp.access_token
    }
    catch {
        Write-Log "OAuth token failed: $_" "ERROR"

        # Fallback to Azure CLI
        try {
            Write-Log "Falling back to Azure CLI token..." "WARN"
            $tokenRaw = az account get-access-token --resource "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" --query accessToken -o tsv 2>$null
            if ($tokenRaw) { return $tokenRaw.Trim() }
        }
        catch {}

        return $null
    }
}

# ---------------------------------------------------------------
# DATABRICKS API HELPERS
# ---------------------------------------------------------------
function Get-Warehouses {
    param([string]$wsUrl, [hashtable]$headers)

    try {
        $resp = Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/warehouses" -Headers $headers -Method Get -TimeoutSec 30
        return $resp.warehouses
    }
    catch {
        Write-Log "  Failed to list warehouses at $wsUrl : $_" "ERROR"
        return @()
    }
}

function Get-QueryHistory {
    param([string]$wsUrl, [hashtable]$headers, [string]$warehouseId, [int]$minutesBack = 15)

    $startMs = [long]([DateTimeOffset]::UtcNow.AddMinutes(-$minutesBack).ToUnixTimeMilliseconds())
    $endMs = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())

    try {
        $body = @{
            filter_by = @{
                warehouse_ids = @($warehouseId)
                query_start_time_range = @{
                    start_time_ms = $startMs
                    end_time_ms = $endMs
                }
                statuses = @("FINISHED", "RUNNING", "QUEUED")
            }
            max_results = 100
        } | ConvertTo-Json -Depth 5

        $resp = Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/history/queries" -Headers $headers -Method Get -Body $body -TimeoutSec 30
        return $resp
    }
    catch {
        # Try GET with query params instead
        try {
            $resp = Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/history/queries?max_results=50" -Headers $headers -Method Get -TimeoutSec 30
            if ($resp.res) {
                $filtered = $resp.res | Where-Object { $_.warehouse_id -eq $warehouseId }
                return @{ res = $filtered }
            }
            return $resp
        }
        catch {
            Write-Log "  Query history failed for $warehouseId : $_" "WARN"
            return $null
        }
    }
}

function Get-WarehouseMetrics {
    param([string]$wsUrl, [hashtable]$headers, $warehouse)

    $metrics = @{
        id = $warehouse.id
        name = $warehouse.name
        state = $warehouse.state
        clusterSize = $warehouse.cluster_size
        minClusters = 1
        maxClusters = 1
        numActive = 0
        numQueued = 0
        avgLatencyMs = 0
        p95LatencyMs = 0
        queryCount = 0
        lastQueryTime = $null
        recommendation = "NONE"
        reason = ""
    }

    if ($warehouse.min_num_clusters) { $metrics.minClusters = $warehouse.min_num_clusters }
    if ($warehouse.max_num_clusters) { $metrics.maxClusters = $warehouse.max_num_clusters }
    if ($warehouse.num_active_sessions) { $metrics.numActive = $warehouse.num_active_sessions }
    if ($warehouse.num_clusters) { $metrics.numActive = $warehouse.num_clusters }

    # Get running/queued from warehouse state
    if ($warehouse.state -eq "RUNNING") {
        if ($warehouse.health) {
            if ($warehouse.health.status -eq "DEGRADED") {
                $metrics.recommendation = "SCALE_UP"
                $metrics.reason = "Health degraded"
            }
        }
    }
    elseif ($warehouse.state -ne "RUNNING") {
        $metrics.recommendation = "NONE"
        $metrics.reason = "Warehouse not running (state: $($warehouse.state))"
        return $metrics
    }

    # Get query history for latency analysis
    $history = Get-QueryHistory -wsUrl $wsUrl -headers $headers -warehouseId $warehouse.id -minutesBack 15

    if ($history -and $history.res) {
        $queries = $history.res

        $finishedQueries = @($queries | Where-Object { $_.status -eq "FINISHED" -and $_.duration -gt 0 })
        $queuedQueries = @($queries | Where-Object { $_.status -eq "QUEUED" })
        $runningQueries = @($queries | Where-Object { $_.status -eq "RUNNING" })

        $metrics.queryCount = $queries.Count
        $metrics.numQueued = $queuedQueries.Count

        if ($finishedQueries.Count -gt 0) {
            $durations = $finishedQueries | ForEach-Object { $_.duration }
            $metrics.avgLatencyMs = [math]::Round(($durations | Measure-Object -Average).Average)

            $sorted = $durations | Sort-Object
            $p95Index = [math]::Floor($sorted.Count * 0.95)
            if ($p95Index -ge $sorted.Count) { $p95Index = $sorted.Count - 1 }
            $metrics.p95LatencyMs = $sorted[$p95Index]

            $lastQuery = $finishedQueries | Sort-Object -Property end_time -Descending | Select-Object -First 1
            if ($lastQuery.end_time) { $metrics.lastQueryTime = $lastQuery.end_time }
        }

        # Determine recommendation
        if ($metrics.numQueued -ge $config.queueDepthHigh) {
            $metrics.recommendation = "SCALE_UP"
            $metrics.reason = "Queue depth: $($metrics.numQueued) (threshold: $($config.queueDepthHigh))"
        }
        elseif ($metrics.avgLatencyMs -ge $config.latencyHighMs -and $metrics.queryCount -gt 3) {
            $metrics.recommendation = "SCALE_UP"
            $metrics.reason = "Avg latency: $([math]::Round($metrics.avgLatencyMs/1000, 1))s (threshold: $($config.latencyHighMs/1000)s)"
        }
        elseif ($metrics.queryCount -eq 0) {
            # Check if idle for too long
            $metrics.recommendation = "MONITOR"
            $metrics.reason = "No queries in last 15 min"
        }
        elseif ($metrics.avgLatencyMs -le $config.latencyLowMs -and $metrics.numQueued -eq 0) {
            # Could potentially scale down
            $currentIdx = $config.sizeLadder.IndexOf($warehouse.cluster_size)
            if ($currentIdx -gt 0 -or $metrics.maxClusters -gt $config.maxClustersMin) {
                $metrics.recommendation = "SCALE_DOWN"
                $metrics.reason = "Low latency ($([math]::Round($metrics.avgLatencyMs/1000, 1))s) and no queue"
            }
            else {
                $metrics.recommendation = "NONE"
                $metrics.reason = "Already at minimum size"
            }
        }
        else {
            $metrics.recommendation = "NONE"
            $metrics.reason = "Performance OK (avg: $([math]::Round($metrics.avgLatencyMs/1000, 1))s, queue: $($metrics.numQueued))"
        }
    }
    else {
        $metrics.recommendation = "MONITOR"
        $metrics.reason = "Could not retrieve query metrics"
    }

    return $metrics
}

function Scale-Warehouse {
    param([string]$wsUrl, [hashtable]$headers, $warehouse, [string]$direction, [string]$reason)

    $whId = $warehouse.id
    $whName = $warehouse.name
    $currentSize = $warehouse.cluster_size
    $currentMax = 1
    if ($warehouse.max_num_clusters) { $currentMax = $warehouse.max_num_clusters }

    $newSize = $currentSize
    $newMax = $currentMax
    $changed = $false

    $sizeIdx = $config.sizeLadder.IndexOf($currentSize)
    if ($sizeIdx -lt 0) { $sizeIdx = 0 }

    if ($direction -eq "UP") {
        # First try adding more clusters
        if ($currentMax -lt $config.maxClustersMax) {
            $newMax = [math]::Min($currentMax + $config.maxClustersStep, $config.maxClustersMax)
            $changed = $true
            Write-Log "  SCALE UP $whName : max_clusters $currentMax -> $newMax" "SCALE"
        }
        # Then try bigger size
        elseif ($sizeIdx -lt ($config.sizeLadder.Count - 1)) {
            $newSize = $config.sizeLadder[$sizeIdx + 1]
            $changed = $true
            Write-Log "  SCALE UP $whName : size $currentSize -> $newSize" "SCALE"
        }
        else {
            Write-Log "  $whName already at maximum scale" "WARN"
            return $false
        }
    }
    elseif ($direction -eq "DOWN") {
        # First try reducing clusters
        if ($currentMax -gt $config.maxClustersMin) {
            $newMax = [math]::Max($currentMax - $config.maxClustersStep, $config.maxClustersMin)
            $changed = $true
            Write-Log "  SCALE DOWN $whName : max_clusters $currentMax -> $newMax" "SCALE"
        }
        # Then try smaller size (be conservative - only if latency is very low)
        elseif ($sizeIdx -gt 0) {
            $newSize = $config.sizeLadder[$sizeIdx - 1]
            $changed = $true
            Write-Log "  SCALE DOWN $whName : size $currentSize -> $newSize" "SCALE"
        }
        else {
            Write-Log "  $whName already at minimum scale" "INFO"
            return $false
        }
    }

    if (-not $changed) { return $false }

    # Check cooldown and limits
    if (-not (Can-ScaleNow -warehouseId $whId)) {
        return $false
    }

    # Apply the change
    try {
        $editBody = @{
            id = $whId
            name = $whName
            cluster_size = $newSize
            max_num_clusters = $newMax
            warehouse_type = $warehouse.warehouse_type
        } | ConvertTo-Json -Depth 5

        Invoke-RestMethod -Uri "$wsUrl/api/2.0/sql/warehouses/$whId/edit" -Headers $headers -Method Post -Body $editBody -TimeoutSec 30 | Out-Null

        $fromStr = "$currentSize / $($currentMax)x"
        $toStr = "$newSize / $($newMax)x"

        Record-ScaleAction -warehouseId $whId -name $whName -direction $direction -from $fromStr -to $toStr -reason $reason
        Write-Log "  APPLIED: $whName scaled $direction from $fromStr to $toStr" "SCALE"

        return $true
    }
    catch {
        Write-Log "  FAILED to scale $whName : $_" "ERROR"
        return $false
    }
}

# ---------------------------------------------------------------
# MAIN EXECUTION
# ---------------------------------------------------------------
$runTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Log "========== AUTO-SCALER RUN START =========="
Write-Log "Workspaces: $($config.workspaces.Count)"

# Get token
$token = Get-ServicePrincipalToken
if (-not $token) {
    # Try Azure CLI fallback
    try {
        $token = (az account get-access-token --resource "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" --query accessToken -o tsv 2>$null)
        if ($token) { $token = $token.Trim() }
    }
    catch {}
}

if (-not $token) {
    Write-Log "FATAL: No authentication token available. Exiting." "ERROR"
    exit 1
}

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

$allResults = @()
$scaleActionsThisRun = @()

foreach ($wsUrl in $config.workspaces) {
    Write-Log "--- Workspace: $wsUrl ---"

    $warehouses = Get-Warehouses -wsUrl $wsUrl -headers $headers

    if (-not $warehouses -or $warehouses.Count -eq 0) {
        Write-Log "  No warehouses found" "WARN"
        continue
    }

    foreach ($wh in $warehouses) {
        Write-Log "  Warehouse: $($wh.name) (state: $($wh.state), size: $($wh.cluster_size))"

        if ($wh.state -ne "RUNNING") {
            Write-Log "    Skipping - not running" "INFO"
            $allResults += @{
                workspace = $wsUrl
                id = $wh.id
                name = $wh.name
                state = $wh.state
                size = $wh.cluster_size
                type = $wh.warehouse_type
                avgLatency = 0
                p95Latency = 0
                queryCount = 0
                queued = 0
                action = "SKIP"
                reason = "Not running"
            }
            continue
        }

        # Get metrics
        $metrics = Get-WarehouseMetrics -wsUrl $wsUrl -headers $headers -warehouse $wh

        Write-Log "    Avg latency: $([math]::Round($metrics.avgLatencyMs/1000, 1))s | P95: $([math]::Round($metrics.p95LatencyMs/1000, 1))s | Queries: $($metrics.queryCount) | Queued: $($metrics.numQueued)"
        Write-Log "    Recommendation: $($metrics.recommendation) - $($metrics.reason)"

        $actionTaken = "NONE"

        # Act on recommendation
        switch ($metrics.recommendation) {
            "SCALE_UP" {
                $scaled = Scale-Warehouse -wsUrl $wsUrl -headers $headers -warehouse $wh -direction "UP" -reason $metrics.reason
                if ($scaled) {
                    $actionTaken = "SCALED_UP"
                    $scaleActionsThisRun += @{ name = $wh.name; direction = "UP"; reason = $metrics.reason }
                }
                else {
                    $actionTaken = "BLOCKED"
                }
            }
            "SCALE_DOWN" {
                $scaled = Scale-Warehouse -wsUrl $wsUrl -headers $headers -warehouse $wh -direction "DOWN" -reason $metrics.reason
                if ($scaled) {
                    $actionTaken = "SCALED_DOWN"
                    $scaleActionsThisRun += @{ name = $wh.name; direction = "DOWN"; reason = $metrics.reason }
                }
                else {
                    $actionTaken = "BLOCKED"
                }
            }
            default {
                $actionTaken = "NONE"
            }
        }

        $allResults += @{
            workspace = $wsUrl
            id = $wh.id
            name = $wh.name
            state = $wh.state
            size = $metrics.clusterSize
            maxClusters = $metrics.maxClusters
            type = $wh.warehouse_type
            avgLatency = $metrics.avgLatencyMs
            p95Latency = $metrics.p95LatencyMs
            queryCount = $metrics.queryCount
            queued = $metrics.numQueued
            action = $actionTaken
            reason = $metrics.reason
        }
    }
}

# ---------------------------------------------------------------
# GENERATE HTML REPORT
# ---------------------------------------------------------------
Write-Log "Generating report..."

$rows = ""
foreach ($r in $allResults) {
    $actionColor = switch ($r.action) {
        "SCALED_UP"   { "#f87171" }
        "SCALED_DOWN" { "#60a5fa" }
        "BLOCKED"     { "#fbbf24" }
        "SKIP"        { "#64748b" }
        default       { "#4ade80" }
    }

    $latencyColor = "#4ade80"
    if ($r.avgLatency -gt $config.latencyHighMs) { $latencyColor = "#f87171" }
    elseif ($r.avgLatency -gt ($config.latencyHighMs / 2)) { $latencyColor = "#fbbf24" }

    $queueColor = "#4ade80"
    if ($r.queued -ge $config.queueDepthHigh) { $queueColor = "#f87171" }
    elseif ($r.queued -ge 2) { $queueColor = "#fbbf24" }

    $wsShort = $r.workspace -replace "https://", "" -replace "\.azuredatabricks\.net", ""

    $rows += "<tr>"
    $rows += "<td>$($r.name)</td>"
    $rows += "<td style=`"font-size:11px`">$wsShort</td>"
    $rows += "<td>$($r.state)</td>"
    $rows += "<td>$($r.size)</td>"
    $rows += "<td>$($r.maxClusters)</td>"
    $rows += "<td style=`"color:$latencyColor`">$([math]::Round($r.avgLatency/1000, 1))s</td>"
    $rows += "<td>$([math]::Round($r.p95Latency/1000, 1))s</td>"
    $rows += "<td>$($r.queryCount)</td>"
    $rows += "<td style=`"color:$queueColor`">$($r.queued)</td>"
    $rows += "<td style=`"color:$actionColor;font-weight:bold`">$($r.action)</td>"
    $rows += "<td style=`"font-size:11px`">$($r.reason)</td>"
    $rows += "</tr>`n"
}

$scaleRows = ""
$recentActions = @()
if ($state.scaleActions) {
    $recentActions = @($state.scaleActions | Sort-Object -Property timestamp -Descending | Select-Object -First 20)
}
foreach ($a in $recentActions) {
    $dirColor = if ($a.direction -eq "UP") { "#f87171" } else { "#60a5fa" }
    $scaleRows += "<tr>"
    $scaleRows += "<td>$($a.timestamp)</td>"
    $scaleRows += "<td>$($a.name)</td>"
    $scaleRows += "<td style=`"color:$dirColor;font-weight:bold`">$($a.direction)</td>"
    $scaleRows += "<td>$($a.from)</td>"
    $scaleRows += "<td>$($a.to)</td>"
    $scaleRows += "<td style=`"font-size:11px`">$($a.reason)</td>"
    $scaleRows += "</tr>`n"
}

$totalWh = $allResults.Count
$runningWh = ($allResults | Where-Object { $_.state -eq "RUNNING" }).Count
$scaledCount = $scaleActionsThisRun.Count

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Databricks Auto-Scaler Report</title>
<meta http-equiv="refresh" content="300">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',Tahoma,sans-serif;background:#0f172a;color:#e2e8f0;padding:30px}
.container{max-width:1400px;margin:0 auto}
.header{background:linear-gradient(135deg,#1e3a5f,#0f172a);border:1px solid #334155;border-radius:12px;padding:24px;margin-bottom:24px;text-align:center}
.header h1{font-size:24px;color:#60a5fa;margin-bottom:4px}
.header p{color:#94a3b8;font-size:13px}
.summary-grid{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin-bottom:20px}
.summary-card{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:16px;text-align:center}
.summary-card .num{font-size:32px;font-weight:bold;color:#60a5fa}
.summary-card .lbl{font-size:11px;color:#94a3b8;text-transform:uppercase;margin-top:4px}
.section{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:20px;margin-bottom:16px}
.section h2{color:#60a5fa;font-size:18px;margin-bottom:12px;border-bottom:1px solid #334155;padding-bottom:6px}
table{width:100%;border-collapse:collapse}
th{background:#334155;color:#e2e8f0;padding:8px;text-align:left;font-size:11px}
td{padding:8px;border-bottom:1px solid #334155;font-size:12px}
tr:hover{background:#334155}
.config-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
.config-item{background:#0f172a;border:1px solid #334155;border-radius:6px;padding:10px}
.config-item .label{font-size:10px;color:#94a3b8;text-transform:uppercase}
.config-item .value{font-size:13px;color:#f1f5f9;font-family:Consolas,monospace}
.footer{text-align:center;color:#64748b;font-size:11px;margin-top:20px;padding:16px}
@media print{body{background:#fff;color:#000}.section{border-color:#ccc}th{background:#eee;color:#000}}
</style>
</head>
<body>
<div class="container">
<div class="header">
<h1>Databricks Auto-Scaler Report</h1>
<p>Run: $runTimestamp | Next check: ~5 min (if scheduled)</p>
</div>

<div class="summary-grid">
<div class="summary-card"><div class="num">$totalWh</div><div class="lbl">Warehouses</div></div>
<div class="summary-card"><div class="num">$runningWh</div><div class="lbl">Running</div></div>
<div class="summary-card"><div class="num" style="color:$(if($scaledCount -gt 0){'#f87171'}else{'#4ade80'})">$scaledCount</div><div class="lbl">Scaled This Run</div></div>
<div class="summary-card"><div class="num">$($recentActions.Count)</div><div class="lbl">Actions (24h)</div></div>
<div class="summary-card"><div class="num">$($config.workspaces.Count)</div><div class="lbl">Workspaces</div></div>
</div>

<div class="section">
<h2>Current Warehouse Status</h2>
<table>
<thead><tr>
<th>Warehouse</th><th>Workspace</th><th>State</th><th>Size</th><th>Max Clusters</th><th>Avg Latency</th><th>P95 Latency</th><th>Queries (15m)</th><th>Queued</th><th>Action</th><th>Reason</th>
</tr></thead>
<tbody>$rows</tbody>
</table>
</div>

<div class="section">
<h2>Scaling History (Last 24h)</h2>
<table>
<thead><tr><th>Time</th><th>Warehouse</th><th>Direction</th><th>From</th><th>To</th><th>Reason</th></tr></thead>
<tbody>$scaleRows</tbody>
</table>
</div>

<div class="section">
<h2>Scaling Configuration</h2>
<div class="config-grid">
<div class="config-item"><div class="label">Scale UP if avg latency above</div><div class="value">$($config.latencyHighMs / 1000)s</div></div>
<div class="config-item"><div class="label">Scale DOWN if avg latency below</div><div class="value">$($config.latencyLowMs / 1000)s</div></div>
<div class="config-item"><div class="label">Scale UP if queue depth above</div><div class="value">$($config.queueDepthHigh) queries</div></div>
<div class="config-item"><div class="label">Max cluster range</div><div class="value">$($config.maxClustersMin) - $($config.maxClustersMax)</div></div>
<div class="config-item"><div class="label">Cooldown between actions</div><div class="value">$($config.cooldownMinutes) min</div></div>
<div class="config-item"><div class="label">Max scale-ups per hour</div><div class="value">$($config.maxScaleUpsPerHour)</div></div>
</div>
</div>

<div class="footer">
<p>Auto-Scaler v1.0 | Service Principal: $($config.clientId) | Log: $logFile</p>
</div>
</div>
</body>
</html>
"@

$reportFile = Join-Path $config.reportDir "autoscaler-report.html"
$html | Out-File -FilePath $reportFile -Encoding UTF8

# Also save timestamped copy
$reportCopy = Join-Path $config.reportDir "autoscaler-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').html"
$html | Out-File -FilePath $reportCopy -Encoding UTF8

Write-Log "Report: $reportFile"

if ($scaleActionsThisRun.Count -gt 0) {
    Write-Log "SCALING ACTIONS THIS RUN:" "SCALE"
    foreach ($a in $scaleActionsThisRun) {
        Write-Log "  $($a.name) -> $($a.direction) : $($a.reason)" "SCALE"
    }
}
else {
    Write-Log "No scaling needed this run." "INFO"
}

Write-Log "========== AUTO-SCALER RUN COMPLETE =========="
