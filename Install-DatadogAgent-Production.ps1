$DATADOG_API_KEY = "YOUR_DATADOG_API_KEY_HERE"

if ($DATADOG_API_KEY -eq "YOUR_DATADOG_API_KEY_HERE") {
    Write-Host "ERROR: Please configure the DATADOG_API_KEY variable at the top of this script."
    exit 1
}

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator."
    exit 1
}

Write-Host "Datadog Agent Installation Script"
Write-Host "Target Computer: $env:COMPUTERNAME"
Write-Host "Datadog Site: us3.datadoghq.com"
Write-Host ""

$agentInstalled = Test-Path "C:\Program Files\Datadog\Datadog Agent\bin\agent.exe"
if ($agentInstalled) {
    Write-Host "Datadog Agent is already installed on this system."
    $reinstall = Read-Host "Reinstall agent? (yes/no)"
    if ($reinstall -ne "yes") {
        exit 0
    }
    Write-Host "Uninstalling existing agent..."
    Start-Process msiexec -ArgumentList '/x', 'datadog-agent', '/quiet', '/norestart' -Wait -NoNewWindow
    Start-Sleep -Seconds 5
}

Write-Host "Downloading Datadog Agent installer..."
$installerUrl = "https://s3.amazonaws.com/ddagent-windows-stable/datadog-agent-7-latest.amd64.msi"
$installerPath = "$env:TEMP\datadog-agent-installer.msi"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

Write-Host "Installing Datadog Agent..."
$env:DD_API_KEY = $DATADOG_API_KEY
$env:DD_SITE = "us3.datadoghq.com"
$env:DD_HOSTNAME = $env:COMPUTERNAME

$installArgs = @(
    '/i',
    $installerPath,
    '/quiet',
    '/norestart',
    "APIKEY=$DATADOG_API_KEY",
    "SITE=us3.datadoghq.com",
    "HOSTNAME=$env:COMPUTERNAME"
)

$process = Start-Process msiexec -ArgumentList $installArgs -Wait -PassThru -NoNewWindow

if ($process.ExitCode -eq 0) {
    Write-Host "Agent installed successfully."
} else {
    Write-Host "Installation completed with exit code: $($process.ExitCode)"
}

Start-Sleep -Seconds 5

Write-Host "Starting Datadog Agent service..."
$service = Get-Service -Name "datadogagent" -ErrorAction SilentlyContinue
if ($service) {
    if ($service.Status -ne "Running") {
        Start-Service -Name "datadogagent"
        Start-Sleep -Seconds 3
    }
    $service = Get-Service -Name "datadogagent"
    Write-Host "Service status: $($service.Status)"
} else {
    Write-Host "WARNING: Could not find datadogagent service."
}

Write-Host ""
Write-Host "Installation complete."
Write-Host "Host: $env:COMPUTERNAME"
Write-Host "Site: us3.datadoghq.com"
Write-Host "The agent will begin sending metrics to Datadog within 2-3 minutes."