# Syed Rizvi - Pyx Health IT Infrastructure
# Azure SSL Certificate Audit and AutoFix
# Connects to all subscriptions automatically
# Run: .\PyxHealth_Azure_Cert_Audit.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$ReportDir = "$env:USERPROFILE\Desktop\PyxHealth-CertReports"
$LogFile   = "$ReportDir\CertAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$Domains = @(
    'clientportal.pyxhealth.com',
    'moveit.pyxhealth.com',
    'pyxiq.pyxhealth.com',
    'moveitauto.pyxhealth.com'
)

$AppServiceMap = @{
    'clientportal.pyxhealth.com' = 'clientportal-app'
    'pyxiq.pyxhealth.com'        = 'pyxiq-app'
    'moveitauto.pyxhealth.com'   = 'moveitauto-app'
}

$ResourceGroup = 'PyxHealth-RG'

function Write-Log {
    param([string]$Message, [string]$Color = 'White')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$ts]  $Message" -ForegroundColor $Color
    Add-Content -Path $LogFile -Value "[$ts]  $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host '  =============================================================' -ForegroundColor Cyan
    Write-Host '   Pyx Health - Azure SSL Certificate Management Tool'           -ForegroundColor Cyan
    Write-Host '   Syed Rizvi - IT Infrastructure'                               -ForegroundColor Cyan
    Write-Host '  =============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '   1.  Audit Only  -  Scan all subscriptions, report cert status (no changes)' -ForegroundColor White
    Write-Host '   2.  AutoFix     -  Enable Azure managed certs on all App Services'          -ForegroundColor White
    Write-Host '   3.  Live Check  -  Test SSL connection to all 4 Pyx Health domains'         -ForegroundColor White
    Write-Host '   4.  Exit'                                                                    -ForegroundColor White
    Write-Host ''
    $choice = Read-Host '   Select option (1-4)'
    return $choice
}

function Initialize-Dirs {
    if (-not (Test-Path $ReportDir)) {
        New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    }
    Write-Log "Reports will be saved to: $ReportDir"
}

function Connect-Azure {
    Write-Log 'Connecting to Azure...'
    try {
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if ($null -eq $ctx) {
            Write-Log 'No active session. Launching Azure login...' 'Yellow'
            Connect-AzAccount -ErrorAction Stop | Out-Null
        }
        else {
            Write-Log "Signed in as: $($ctx.Account.Id)" 'Green'
        }
        Write-Log 'Azure connection successful.' 'Green'
        return $true
    }
    catch {
        Write-Log "Azure connection failed: $($_.Exception.Message)" 'Red'
        return $false
    }
}

function Get-Subscriptions {
    Write-Log 'Retrieving all Azure subscriptions...'
    try {
        $subs = Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' }
        Write-Log "Found $($subs.Count) active subscription(s)." 'Green'
        return $subs
    }
    catch {
        Write-Log "Failed to get subscriptions: $($_.Exception.Message)" 'Red'
        return @()
    }
}

function Get-LiveCert {
    param([string]$Domain)
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new($Domain, 443)
        $ssl = [System.Net.Security.SslStream]::new(
            $tcp.GetStream(), $false,
            { param($s, $c, $ch, $e) $true }
        )
        $ssl.AuthenticateAsClient($Domain)
        $cert     = $ssl.RemoteCertificate
        $expiry   = [datetime]::Parse($cert.GetExpirationDateString())
        $days     = ($expiry - (Get-Date)).Days
        $issuer   = $cert.Issuer
        $ssl.Dispose()
        $tcp.Dispose()
        return @{
            Domain     = $Domain
            Expiry     = $expiry.ToString('yyyy-MM-dd')
            DaysLeft   = $days
            Issuer     = $issuer
            IsDigiCert = ($issuer -match 'DigiCert')
            IsAzure    = ($issuer -match 'Microsoft')
            Status     = if ($days -gt 30) { 'OK' } elseif ($days -gt 0) { 'WARNING' } else { 'EXPIRED' }
        }
    }
    catch {
        return @{
            Domain     = $Domain
            Expiry     = 'Could not connect'
            DaysLeft   = -1
            Issuer     = 'Error'
            IsDigiCert = $false
            IsAzure    = $false
            Status     = 'ERROR'
        }
    }
}

function Invoke-LiveCheck {
    Write-Log '-----------------------------------------------------------'
    Write-Log 'LIVE SSL CHECK - Testing all 4 Pyx Health domains'
    Write-Log '-----------------------------------------------------------'
    $results = @()
    foreach ($domain in $Domains) {
        Write-Log "Checking: $domain" 'Cyan'
        $info = Get-LiveCert -Domain $domain
        $results += $info
        $color = if ($info.Status -eq 'OK') { 'Green' } elseif ($info.Status -eq 'WARNING') { 'Yellow' } else { 'Red' }
        $certType = if ($info.IsAzure) { 'AZURE MANAGED - FREE' } elseif ($info.IsDigiCert) { 'DIGICERT - NEEDS MIGRATION' } else { 'OTHER' }
        Write-Log "  Domain    : $($info.Domain)"        $color
        Write-Log "  Expiry    : $($info.Expiry)"        $color
        Write-Log "  Days Left : $($info.DaysLeft)"      $color
        Write-Log "  Cert Type : $certType"              $color
        Write-Log "  Status    : $($info.Status)"        $color
        Write-Log ''
    }
    return $results
}

function Invoke-Audit {
    param([switch]$AutoFix)
    $allResults = @()
    $subs = Get-Subscriptions
    if ($subs.Count -eq 0) {
        Write-Log 'No subscriptions found. Check your Azure login.' 'Red'
        return @()
    }
    foreach ($sub in $subs) {
        Write-Log "Scanning subscription: $($sub.Name)" 'Cyan'
        try {
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
            $apps = Get-AzWebApp -ErrorAction SilentlyContinue
            if ($null -eq $apps -or $apps.Count -eq 0) {
                Write-Log "  No App Services found in: $($sub.Name)" 'Gray'
                continue
            }
            foreach ($app in $apps) {
                foreach ($hostSsl in $app.HostNameSslStates) {
                    if ($hostSsl.Name -like '*.azurewebsites.net') { continue }
                    $certType  = 'Unknown'
                    $expiry    = 'Unknown'
                    $daysLeft  = -1
                    $issuer    = 'Unknown'
                    $status    = 'UNKNOWN'
                    if ($hostSsl.SslState -ne 'Disabled' -and $hostSsl.Thumbprint) {
                        $certs = Get-AzWebAppCertificate -ResourceGroupName $app.ResourceGroup -ErrorAction SilentlyContinue
                        $cert  = $certs | Where-Object { $_.Thumbprint -eq $hostSsl.Thumbprint } | Select-Object -First 1
                        if ($cert) {
                            $expiry   = $cert.ExpirationDate.ToString('yyyy-MM-dd')
                            $daysLeft = ($cert.ExpirationDate - (Get-Date)).Days
                            $issuer   = $cert.Issuer
                            if ($cert.Issuer -match 'DigiCert') {
                                $certType = 'DIGICERT - NEEDS MIGRATION'
                                $status   = 'ACTION REQUIRED'
                            }
                            elseif ($cert.Issuer -match 'Microsoft') {
                                $certType = 'Azure Managed - Free'
                                $status   = if ($daysLeft -gt 30) { 'OK' } else { 'WARNING' }
                            }
                            else {
                                $certType = $cert.Issuer
                                $status   = 'REVIEW'
                            }
                        }
                    }
                    else {
                        $certType = 'No SSL Binding'
                        $status   = 'ACTION REQUIRED'
                    }
                    $row = [PSCustomObject]@{
                        Subscription  = $sub.Name
                        AppService    = $app.Name
                        Domain        = $hostSsl.Name
                        CertType      = $certType
                        Expiry        = $expiry
                        DaysLeft      = $daysLeft
                        Issuer        = $issuer
                        Status        = $status
                        ResourceGroup = $app.ResourceGroup
                    }
                    $allResults += $row
                    $color = if ($status -eq 'OK') { 'Green' } elseif ($status -eq 'ACTION REQUIRED') { 'Red' } else { 'Yellow' }
                    Write-Log "  $($app.Name) | $($hostSsl.Name) | $certType | $status" $color
                    if ($AutoFix -and $status -eq 'ACTION REQUIRED' -and $AppServiceMap.ContainsKey($hostSsl.Name)) {
                        Write-Log "  Enabling Azure Managed Certificate for: $($hostSsl.Name)" 'Yellow'
                        try {
                            $newCert = New-AzWebAppCertificate `
                                -ResourceGroupName $ResourceGroup `
                                -WebAppName $app.Name `
                                -Name ($hostSsl.Name -replace '\.', '-') `
                                -HostName $hostSsl.Name `
                                -ErrorAction Stop
                            New-AzWebAppSSLBinding `
                                -ResourceGroupName $ResourceGroup `
                                -WebAppName $app.Name `
                                -Thumbprint $newCert.Thumbprint `
                                -Name $hostSsl.Name `
                                -SslState 'SniEnabled' `
                                -ErrorAction Stop | Out-Null
                            Write-Log "  Azure Managed Certificate enabled for: $($hostSsl.Name)" 'Green'
                        }
                        catch {
                            Write-Log "  Failed to enable cert for $($hostSsl.Name): $($_.Exception.Message)" 'Red'
                        }
                    }
                }
            }
        }
        catch {
            Write-Log "  Error scanning $($sub.Name): $($_.Exception.Message)" 'Red'
        }
    }
    return $allResults
}

function New-HtmlReport {
    param([object[]]$AuditResults, [object[]]$LiveResults)
    $ts         = Get-Date -Format 'yyyyMMdd_HHmmss'
    $reportPath = "$ReportDir\PyxHealth_CertAudit_$ts.html"
    $liveRows = ''
    foreach ($r in $LiveResults) {
        $bg       = if ($r.Status -eq 'OK') { '#E8F5E9' } elseif ($r.Status -eq 'WARNING') { '#FFF8E1' } else { '#FFEBEE' }
        $typeText = if ($r.IsAzure) { 'Azure Managed - FREE' } elseif ($r.IsDigiCert) { 'DigiCert - Needs Migration' } else { 'Other' }
        $typeColor = if ($r.IsAzure) { '#2E7D32' } elseif ($r.IsDigiCert) { '#C62828' } else { '#E65100' }
        $liveRows += "<tr style='background:$bg'>
            <td style='padding:10px;border:1px solid #ddd;font-weight:bold'>$($r.Domain)</td>
            <td style='padding:10px;border:1px solid #ddd;color:$typeColor;font-weight:bold'>$typeText</td>
            <td style='padding:10px;border:1px solid #ddd'>$($r.Expiry)</td>
            <td style='padding:10px;border:1px solid #ddd;text-align:center;font-weight:bold'>$($r.DaysLeft)</td>
            <td style='padding:10px;border:1px solid #ddd;font-weight:bold;color:$(if($r.Status -eq "OK"){"#2E7D32"}elseif($r.Status -eq "WARNING"){"#E65100"}else{"#C62828"})'>$($r.Status)</td>
        </tr>"
    }
    $auditRows = ''
    foreach ($r in $AuditResults) {
        $color = if ($r.Status -eq 'OK') { '#E8F5E9' } elseif ($r.Status -eq 'ACTION REQUIRED') { '#FFEBEE' } else { '#FFF8E1' }
        $auditRows += "<tr style='background:$color'>
            <td style='padding:10px;border:1px solid #ddd'>$($r.Subscription)</td>
            <td style='padding:10px;border:1px solid #ddd;font-weight:bold'>$($r.AppService)</td>
            <td style='padding:10px;border:1px solid #ddd'>$($r.Domain)</td>
            <td style='padding:10px;border:1px solid #ddd'>$($r.CertType)</td>
            <td style='padding:10px;border:1px solid #ddd'>$($r.Expiry)</td>
            <td style='padding:10px;border:1px solid #ddd;text-align:center'>$($r.DaysLeft)</td>
            <td style='padding:10px;border:1px solid #ddd;font-weight:bold'>$($r.Status)</td>
        </tr>"
    }
    $digiCount  = ($LiveResults | Where-Object { $_.IsDigiCert }).Count
    $azureCount = ($LiveResults | Where-Object { $_.IsAzure }).Count
    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset='utf-8'>
<title>Pyx Health SSL Certificate Audit</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 0; padding: 0; background: #f0f4f8; }
.header { background: #0A1628; color: white; padding: 24px 40px; }
.header h1 { margin: 0; font-size: 22px; }
.header p  { margin: 6px 0 0; color: #90CAF9; font-size: 13px; }
.content { max-width: 1100px; margin: 30px auto; padding: 0 20px; }
.card { background: white; border-radius: 10px; padding: 28px; margin-bottom: 24px; box-shadow: 0 2px 12px rgba(0,0,0,0.08); }
.card h2 { color: #0D47A1; font-size: 17px; border-bottom: 2px solid #E3F2FD; padding-bottom: 8px; margin-top: 0; }
.summary { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; margin-bottom: 24px; }
.sum-box { border-radius: 8px; padding: 18px; text-align: center; }
.sum-box .num { font-size: 32px; font-weight: 800; }
.sum-box .lbl { font-size: 12px; margin-top: 4px; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th { background: #0A1628; color: white; padding: 11px 14px; text-align: left; font-size: 12px; }
.footer { background: #0A1628; color: #546E7A; text-align: center; padding: 14px; font-size: 12px; margin-top: 20px; }
</style>
</head>
<body>
<div class='header'>
  <h1>Pyx Health - Azure SSL Certificate Audit Report</h1>
  <p>Prepared by Syed Rizvi - IT Infrastructure &nbsp;|&nbsp; $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') &nbsp;|&nbsp; CONFIDENTIAL</p>
</div>
<div class='content'>
  <div class='summary'>
    <div class='sum-box' style='background:#E8F5E9'><div class='num' style='color:#2E7D32'>$azureCount</div><div class='lbl' style='color:#546E7A'>Domains on Azure Free Certs</div></div>
    <div class='sum-box' style='background:#FFEBEE'><div class='num' style='color:#C62828'>$digiCount</div><div class='lbl' style='color:#546E7A'>Domains Still on DigiCert</div></div>
    <div class='sum-box' style='background:#E3F2FD'><div class='num' style='color:#1565C0'>0</div><div class='lbl' style='color:#546E7A'>Annual Cost After Migration</div></div>
  </div>
  <div class='card'>
    <h2>Live Certificate Status - All 4 Pyx Health Domains</h2>
    <table>
      <thead><tr><th>Domain</th><th>Certificate Type</th><th>Expiry Date</th><th>Days Left</th><th>Status</th></tr></thead>
      <tbody>$liveRows</tbody>
    </table>
  </div>
  <div class='card'>
    <h2>App Service Certificate Scan - All Subscriptions</h2>
    <table>
      <thead><tr><th>Subscription</th><th>App Service</th><th>Domain</th><th>Cert Type</th><th>Expiry</th><th>Days Left</th><th>Status</th></tr></thead>
      <tbody>$auditRows</tbody>
    </table>
  </div>
</div>
<div class='footer'>Pyx Health IT Infrastructure &nbsp;|&nbsp; Prepared by Syed Rizvi &nbsp;|&nbsp; Confidential</div>
</body>
</html>
"@
    Set-Content -Path $reportPath -Value $html -Encoding UTF8
    Write-Log "HTML report saved: $reportPath" 'Green'
    Start-Process $reportPath
    return $reportPath
}

function Main {
    Initialize-Dirs
    Write-Log 'Starting Pyx Health Azure SSL Certificate Management Tool'
    $connected = Connect-Azure
    if (-not $connected) {
        Write-Log 'Cannot continue without Azure connection. Exiting.' 'Red'
        exit 1
    }
    $running = $true
    while ($running) {
        $choice = Show-Menu
        switch ($choice) {
            '1' {
                Write-Log 'Mode: Audit Only'
                $liveResults  = Invoke-LiveCheck
                $auditResults = Invoke-Audit
                New-HtmlReport -AuditResults $auditResults -LiveResults $liveResults
                Write-Log 'Audit complete. HTML report opened on your desktop.' 'Green'
                Read-Host 'Press ENTER to return to menu'
            }
            '2' {
                Write-Log 'Mode: AutoFix - Enabling Azure Managed Certificates'
                $liveResults  = Invoke-LiveCheck
                $auditResults = Invoke-Audit -AutoFix
                New-HtmlReport -AuditResults $auditResults -LiveResults $liveResults
                Write-Log 'AutoFix complete. HTML report opened on your desktop.' 'Green'
                Read-Host 'Press ENTER to return to menu'
            }
            '3' {
                Write-Log 'Mode: Live Check'
                $liveResults = Invoke-LiveCheck
                New-HtmlReport -AuditResults @() -LiveResults $liveResults
                Write-Log 'Live check complete. HTML report opened on your desktop.' 'Green'
                Read-Host 'Press ENTER to return to menu'
            }
            '4' {
                Write-Log 'Exiting. Goodbye.'
                $running = $false
            }
            default {
                Write-Host 'Invalid selection. Please enter 1, 2, 3, or 4.' -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            }
        }
    }
}

Main
