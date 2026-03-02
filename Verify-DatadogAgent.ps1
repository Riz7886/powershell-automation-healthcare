# Verify-DatadogAgent.ps1
# This script checks the current Datadog agent configuration
# Can be run without Administrator rights

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "   DATADOG AGENT VERIFICATION" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# Check current computer name
$computerName = $env:COMPUTERNAME
Write-Host "Windows Computer Name: $computerName" -ForegroundColor Green
Write-Host ""

# Check if Datadog is installed
$agentExe = "C:\Program Files\Datadog\Datadog Agent\bin\agent.exe"
$configFile = "C:\ProgramData\Datadog\datadog.yaml"

if (-not (Test-Path $agentExe)) {
    Write-Host "ERROR: Datadog Agent is NOT installed" -ForegroundColor Red
    Write-Host "Location checked: $agentExe" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Run Install-DatadogAgent-Production.ps1 first" -ForegroundColor Yellow
    exit 1
}

Write-Host "Datadog Agent: INSTALLED" -ForegroundColor Green
Write-Host ""

# Check service status
$service = Get-Service -Name "datadogagent" -ErrorAction SilentlyContinue
if ($service) {
    if ($service.Status -eq "Running") {
        Write-Host "Agent Service Status: RUNNING" -ForegroundColor Green
    } else {
        Write-Host "Agent Service Status: $($service.Status)" -ForegroundColor Red
        Write-Host "Run: Start-Service datadogagent" -ForegroundColor Yellow
    }
} else {
    Write-Host "Agent Service: NOT FOUND" -ForegroundColor Red
}
Write-Host ""

# Check configured hostname in config file
if (Test-Path $configFile) {
    Write-Host "Reading configuration file..." -ForegroundColor Cyan
    $config = Get-Content $configFile
    $hostnameLines = $config | Select-String -Pattern "^hostname:" 
    
    if ($hostnameLines) {
        Write-Host ""
        Write-Host "Configured Hostname in datadog.yaml:" -ForegroundColor Yellow
        foreach ($line in $hostnameLines) {
            Write-Host "  $line" -ForegroundColor White
        }
    } else {
        Write-Host "WARNING: No hostname configured in datadog.yaml" -ForegroundColor Yellow
        Write-Host "The agent will use: $computerName" -ForegroundColor White
    }
} else {
    Write-Host "WARNING: Config file not found at $configFile" -ForegroundColor Red
}

Write-Host ""
Write-Host "Getting agent status (this may take a few seconds)..." -ForegroundColor Cyan
Write-Host ""

# Get full agent status
try {
    $statusOutput = & $agentExe status 2>&1
    
    # Extract hostname information
    $hostnameSection = $statusOutput | Select-String -Pattern "Hostnames" -Context 0,10
    
    if ($hostnameSection) {
        Write-Host "================================================" -ForegroundColor Cyan
        Write-Host "HOSTNAME REPORTED TO DATADOG:" -ForegroundColor Cyan
        Write-Host "================================================" -ForegroundColor Cyan
        $hostnameSection | ForEach-Object { Write-Host $_.Line -ForegroundColor White }
    }
    
    # Check connectivity
    $apiKeyCheck = $statusOutput | Select-String -Pattern "API Keys status"
    if ($apiKeyCheck) {
        Write-Host ""
        Write-Host "API Key Status:" -ForegroundColor Cyan
        $apiKeyCheck | ForEach-Object { Write-Host $_.Line -ForegroundColor White }
    }
    
} catch {
    Write-Host "Could not get full agent status: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "SUMMARY:" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# Determine what needs to be fixed
$needsFix = $false

if (Test-Path $configFile) {
    $config = Get-Content $configFile
    $hostnameLines = $config | Select-String -Pattern "^hostname:\s*(.+)" 
    
    if ($hostnameLines) {
        $configuredHostname = ($hostnameLines[0] -replace "^hostname:\s*", "").Trim()
        
        if ($configuredHostname -ne $computerName) {
            Write-Host "ISSUE FOUND:" -ForegroundColor Red
            Write-Host "  Windows computer name: $computerName" -ForegroundColor Yellow
            Write-Host "  Datadog configured hostname: $configuredHostname" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "THESE DO NOT MATCH!" -ForegroundColor Red
            Write-Host ""
            Write-Host "To fix this, run:" -ForegroundColor Green
            Write-Host "  .\Fix-DatadogHostname.ps1 -NewHostname '$computerName'" -ForegroundColor White
            $needsFix = $true
        } else {
            Write-Host "Hostnames match - configuration looks good!" -ForegroundColor Green
        }
    } else {
        Write-Host "WARNING: No hostname set in config" -ForegroundColor Yellow
        Write-Host "Agent is using default: $computerName" -ForegroundColor White
        Write-Host ""
        Write-Host "To explicitly set hostname, run:" -ForegroundColor Green
        Write-Host "  .\Fix-DatadogHostname.ps1 -NewHostname '$computerName'" -ForegroundColor White
        $needsFix = $true
    }
}

Write-Host ""