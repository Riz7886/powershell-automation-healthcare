# Update-DatadogHostname.ps1
# Run this on each VM as Administrator

param(
    [Parameter(Mandatory=$true)]
    [string]$NewHostname
)

$configFile = "C:\ProgramData\Datadog\datadog. yaml"

if (-not (Test-Path $configFile)) {
    Write-Host "ERROR:  Datadog config file not found at $configFile"
    exit 1
}

Write-Host "Updating Datadog hostname to:  $NewHostname"

# Backup the config file
Copy-Item $configFile "$configFile.backup"

# Read the config
$config = Get-Content $configFile

# Update or add hostname
$hostnameFound = $false
$newConfig = @()
foreach ($line in $config) {
    if ($line -match "^hostname:") {
        $newConfig += "hostname: $NewHostname"
        $hostnameFound = $true
    } else {
        $newConfig += $line
    }
}

if (-not $hostnameFound) {
    # Add hostname at the beginning
    $newConfig = @("hostname: $NewHostname") + $newConfig
}

# Write the updated config
$newConfig | Set-Content $configFile

# Restart the agent
Write-Host "Restarting Datadog Agent..."
Restart-Service datadogagent

Start-Sleep -Seconds 5

Write-Host "Agent restarted.  New hostname: $NewHostname"
Write-Host "Verifying..."
& "C:\Program Files\Datadog\Datadog Agent\bin\agent.exe" status