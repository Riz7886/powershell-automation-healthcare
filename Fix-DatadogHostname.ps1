# Fix-DatadogHostname.ps1
# Run this on each VM as Administrator

param(
    [Parameter(Mandatory=$true)]
    [string]$NewHostname
)

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "   FIXING DATADOG HOSTNAME" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Run PowerShell as Administrator!" -ForegroundColor Red
    exit 1
}

$configFile = "C:\ProgramData\Datadog\datadog.yaml"

if (-not (Test-Path $configFile)) {
    Write-Host "ERROR:  Datadog config file not found at $configFile" -ForegroundColor Red
    exit 1
}

Write-Host "Setting hostname to:  $NewHostname" -ForegroundColor Green
Write-Host ""

# Backup the config file
$backupFile = "$configFile.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host "Creating backup: $backupFile" -ForegroundColor Yellow
Copy-Item $configFile $backupFile

# Read the config
$config = Get-Content $configFile

# Update or add hostname
$hostnameFound = $false
$newConfig = @()

foreach ($line in $config) {
    if ($line -match "^hostname:" -or $line -match "^#hostname:") {
        $newConfig += "hostname: $NewHostname"
        $hostnameFound = $true
        Write-Host "Updated existing hostname line" -ForegroundColor Yellow
    } else {
        $newConfig += $line
    }
}

if (-not $hostnameFound) {
    Write-Host "Adding hostname at top of config" -ForegroundColor Yellow
    $newConfig = @("hostname: $NewHostname", "") + $newConfig
}

# Write the updated config
$newConfig | Set-Content $configFile -Force

Write-Host "Config file updated!" -ForegroundColor Green
Write-Host ""

# Restart the agent
Write-Host "Restarting Datadog Agent..." -ForegroundColor Yellow
Restart-Service datadogagent
Start-Sleep -Seconds 5

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "   DONE!" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "New hostname: $NewHostname" -ForegroundColor Green
Write-Host "Backup saved:  $backupFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "Wait 2-3 minutes then check Datadog!" -ForegroundColor Yellow
Write-Host "https://us3.datadoghq.com/infrastructure" -ForegroundColor White
Write-Host ""