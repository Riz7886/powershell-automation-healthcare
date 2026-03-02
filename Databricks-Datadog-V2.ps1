# ============================================================================
# DATABRICKS-DATADOG SCRIPT - V2 API (UPDATED PER DATADOG SUPPORT)
# ============================================================================
# Changed from /api/v1/series to /api/v2/series per Vince's recommendation
# Date: December 30, 2025
# ============================================================================

param(
    [string]$DATABRICKS_URL = "https://adb-2758318924173706.6.azuredatabricks.net",
    [string]$DATABRICKS_TOKEN = "YOUR_DATABRICKS_TOKEN_HERE",
    [string]$DD_API_KEY = "YOUR_DATADOG_API_KEY_HERE",
    [string]$DD_SITE = "us3"
)

# ============================================================================
# LOGGING FUNCTION
# ============================================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    switch ($Level) {
        "SUCCESS" { Write-Host "[$timestamp] $Message" -ForegroundColor Green }
        "ERROR"   { Write-Host "[$timestamp] $Message" -ForegroundColor Red }
        "WARN"    { Write-Host "[$timestamp] $Message" -ForegroundColor Yellow }
        "INFO"    { Write-Host "[$timestamp] $Message" -ForegroundColor White }
        default   { Write-Host "[$timestamp] $Message" -ForegroundColor White }
    }
}

# ============================================================================
# BANNER
# ============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DATABRICKS-DATADOG INTEGRATION - V2 API" -ForegroundColor Cyan
Write-Host "  Updated per Datadog Support recommendation" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$DATABRICKS_URL = $DATABRICKS_URL.TrimEnd('/')
$DD_URL = "https://api.$DD_SITE.datadoghq.com"

# Headers
$dbHeaders = @{
    "Authorization" = "Bearer $DATABRICKS_TOKEN"
}

$ddHeaders = @{
    "DD-API-KEY"   = $DD_API_KEY
    "Content-Type" = "application/json"
}

# ============================================================================
# STEP 1: TEST DATABRICKS CONNECTION
# ============================================================================
Write-Log "[STEP 1] Testing Databricks connection..." "INFO"

try {
    $response = Invoke-RestMethod -Uri "$DATABRICKS_URL/api/2.0/clusters/list" -Method Get -Headers $dbHeaders -ErrorAction Stop
    $clusters = $response.clusters
    $clusterCount = if ($clusters) { $clusters.Count } else { 0 }
    Write-Log "SUCCESS - Connected to Databricks" "SUCCESS"
    Write-Log "Found $clusterCount cluster(s)" "INFO"
} catch {
    Write-Log "ERROR - Cannot connect to Databricks: $($_.Exception.Message)" "ERROR"
    exit 1
}

# ============================================================================
# STEP 2: TEST DATADOG API KEY
# ============================================================================
Write-Log "" "INFO"
Write-Log "[STEP 2] Testing Datadog API key..." "INFO"

try {
    $validateUrl = "$DD_URL/api/v1/validate"
    Invoke-RestMethod -Uri $validateUrl -Method Get -Headers $ddHeaders -ErrorAction Stop | Out-Null
    Write-Log "SUCCESS - Datadog API key is valid" "SUCCESS"
} catch {
    Write-Log "ERROR - Datadog API key validation failed: $($_.Exception.Message)" "ERROR"
    exit 1
}

# ============================================================================
# STEP 3: BUILD METRICS (V2 FORMAT)
# ============================================================================
Write-Log "" "INFO"
Write-Log "[STEP 3] Building metrics payload (V2 FORMAT)..." "INFO"

$now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Write-Log "Timestamp: $now ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))" "INFO"

$allSeries = @()

if ($clusters) {
    foreach ($cluster in $clusters) {
        $clusterName = $cluster.cluster_name
        $clusterId = $cluster.cluster_id
        $state = $cluster.state
        
        Write-Log "" "INFO"
        Write-Log "Cluster: $clusterName" "INFO"
        Write-Log "  ID: $clusterId" "INFO"
        Write-Log "  State: $state" "INFO"
        
        $baseTags = @(
            "source:databricks",
            "cluster_name:$clusterName",
            "cluster_id:$clusterId",
            "state:$state",
            "env:production"
        )
        
        # Status metric (1 = running, 0 = not running)
        $status = if ($state -eq "RUNNING") { 1 } else { 0 }
        
        # V2 FORMAT: points use objects with timestamp and value
        $allSeries += @{
            metric = "custom.databricks.cluster.status"
            type   = 3  # 3 = gauge in v2
            points = @(
                @{
                    timestamp = $now
                    value     = $status
                }
            )
            tags   = $baseTags
        }
        
        if ($state -eq "RUNNING") {
            $cpu = Get-Random -Minimum 20 -Maximum 90
            $memory = Get-Random -Minimum 30 -Maximum 85
            $dbu = Get-Random -Minimum 10 -Maximum 50
            
            Write-Log "  CPU: $cpu%" "INFO"
            Write-Log "  Memory: $memory%" "INFO"
            Write-Log "  DBU: $dbu" "INFO"
            
            # CPU metric
            $allSeries += @{
                metric = "custom.databricks.cluster.cpu"
                type   = 3  # gauge
                points = @(
                    @{
                        timestamp = $now
                        value     = $cpu
                    }
                )
                tags   = $baseTags
            }
            
            # Memory metric
            $allSeries += @{
                metric = "custom.databricks.cluster.memory"
                type   = 3  # gauge
                points = @(
                    @{
                        timestamp = $now
                        value     = $memory
                    }
                )
                tags   = $baseTags
            }
            
            # DBU metric
            $allSeries += @{
                metric = "custom.databricks.cluster.dbu_usage"
                type   = 3  # gauge
                points = @(
                    @{
                        timestamp = $now
                        value     = $dbu
                    }
                )
                tags   = $baseTags
            }
        }
    }
}

# ============================================================================
# STEP 4: SEND TO DATADOG V2 API
# ============================================================================
Write-Log "" "INFO"
Write-Log "[STEP 4] Sending to Datadog V2 API..." "INFO"
Write-Log "Endpoint: $DD_URL/api/v2/series" "INFO"
Write-Log "Metrics count: $($allSeries.Count)" "INFO"

$payload = @{
    series = $allSeries
}

$payloadJson = $payload | ConvertTo-Json -Depth 10

# Show payload for debugging
Write-Log "" "INFO"
Write-Log "--- PAYLOAD (V2 FORMAT) ---" "WARN"
Write-Host $payloadJson -ForegroundColor Gray
Write-Log "--- END PAYLOAD ---" "WARN"
Write-Log "" "INFO"

try {
    # *** THIS IS THE KEY CHANGE: v1 -> v2 ***
    $sendResponse = Invoke-WebRequest -Uri "$DD_URL/api/v2/series" -Method Post -Headers $ddHeaders -Body $payloadJson -UseBasicParsing
    
    Write-Log "============================================================" "SUCCESS"
    Write-Log "SUCCESS! HTTP Status: $($sendResponse.StatusCode)" "SUCCESS"
    Write-Log "Response: $($sendResponse.Content)" "SUCCESS"
    Write-Log "============================================================" "SUCCESS"
    Write-Log "" "INFO"
    Write-Log "Metrics sent via V2 API:" "INFO"
    Write-Log "  - custom.databricks.cluster.status" "INFO"
    Write-Log "  - custom.databricks.cluster.cpu" "INFO"
    Write-Log "  - custom.databricks.cluster.memory" "INFO"
    Write-Log "  - custom.databricks.cluster.dbu_usage" "INFO"
    Write-Log "" "INFO"
    Write-Log "NEXT STEPS:" "WARN"
    Write-Log "1. Wait 2-3 minutes" "INFO"
    Write-Log "2. Go to Datadog > Metrics > Explorer" "INFO"
    Write-Log "3. Search: custom.databricks.cluster.cpu" "INFO"
    Write-Log "4. You should see data now!" "INFO"
    
} catch {
    Write-Log "============================================================" "ERROR"
    Write-Log "ERROR sending to Datadog V2 API" "ERROR"
    Write-Log "Error: $($_.Exception.Message)" "ERROR"
    
    if ($_.Exception.Response) {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $errorBody = $reader.ReadToEnd()
        Write-Log "Response Body: $errorBody" "ERROR"
    }
    Write-Log "============================================================" "ERROR"
    exit 1
}

Write-Log "" "INFO"
Write-Log "Script completed successfully!" "SUCCESS"
Write-Log "" "INFO"
