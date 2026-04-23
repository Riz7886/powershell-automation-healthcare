[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][pscredential]$Credential,
    [string]$SapPsePin,
    [string]$PfxPassword,
    [switch]$DiscoverOnly,
    [switch]$NonInteractive,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'Update-ServerCert.ps1'

$targets = @('ns2otpapp','10.168.0.32','10.168.2.22')
$live    = foreach ($t in $targets) {
    $icmp   = Test-Connection -ComputerName $t -Count 1 -Quiet -ErrorAction SilentlyContinue
    $winrm  = $false
    try { Test-WSMan -ComputerName $t -ErrorAction Stop | Out-Null; $winrm = $true } catch {}
    if ($icmp -or $winrm) { $t }
}
if (-not $live) { throw 'No ns2otpapp target reachable by ICMP or WinRM. Check VPN / jump-server routing.' }

Write-Host ("Reachable target(s): {0}" -f ($live -join ', ')) -ForegroundColor Cyan

if ($DiscoverOnly) {
    & $script -Target $live -Credential $Credential -Action Discover -Scope All -PfxPassword $PfxPassword -SapPsePin $SapPsePin
    return
}

$common = @{
    Target           = $live
    Credential       = $Credential
    Action           = 'Renew'
    Scope            = 'Auto'
    SubjectLike      = 'ns2otpapp.sap.parker.corp'
    SubjectOverride  = 'CN=ns2otpapp.sap.parker.corp, OU=COR, O=Parker Hannifin, L=Cleveland, C=US'
    DnsNames         = @('ns2otpapp.sap.parker.corp','ns2otpapp','ns2otpapp.parker.corp')
    CaTemplate       = 'WebServer'
    ServiceName      = 'OpenText Core Archive Connector'
    KeySize          = 2048
    ExpiryThresholdDays = 45
}

if ($SapPsePin)   { $common.SapPsePin   = $SapPsePin }
if ($PfxPassword) { $common.PfxPassword = $PfxPassword }
if ($NonInteractive) { $common.NonInteractive = $true }
if ($Force)          { $common.Force          = $true }

& $script @common
