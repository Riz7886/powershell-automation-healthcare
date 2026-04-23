[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string[]]$Target,
    [pscredential]$Credential,
    [ValidateSet('Discover','Renew','Rollback','Verify','RenewAuto')][string]$Action = 'Discover',
    [ValidateSet('Auto','WindowsStore','PfxFile','IisBinding','SapPse','AzureKv','All')][string]$Scope = 'Auto',
    [string]$Thumbprint,
    [string]$SubjectLike,
    [string]$PfxPath,
    [object]$PfxPassword,
    [string]$SapPsePath,
    [object]$SapPsePin,
    [string]$SapGenPsePath,
    [string]$KeyVaultName,
    [string]$KvCertName,
    [string]$KvSecretNamePfx,
    [string]$KvSecretNamePse,
    [string]$SecretStorePath = "$HOME\.cert-secrets",
    [string]$CaConfig,
    [string]$CaTemplate = 'WebServer',
    [string]$SubjectOverride,
    [string[]]$DnsNames,
    [int]$KeySize = 2048,
    [string]$ServiceName,
    [string]$BackupRoot = 'C:\Users\PC\Downloads\SAP-Cert-Manager\backups',
    [string]$LogRoot = 'C:\Users\PC\Downloads\SAP-Cert-Manager\logs',
    [string]$RemoteStagingRoot = 'C:\Temp\CertRenew',
    [int]$ExpiryThresholdDays = 45,
    [switch]$DryRun,
    [switch]$NonInteractive,
    [switch]$Force,
    [switch]$SkipRestart,
    [switch]$PromptForPasswords,
    [switch]$SavePasswords,
    [switch]$IncludeAutoRenew
)

$ErrorActionPreference = 'Stop'
$script:RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:LogFile = Join-Path $LogRoot "cert-$($script:RunId).log"
$script:BackupDir = Join-Path $BackupRoot $script:RunId
$script:Sessions = @{}

New-Item -ItemType Directory -Force -Path $LogRoot     | Out-Null
New-Item -ItemType Directory -Force -Path $BackupRoot  | Out-Null
New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null

function Write-Log {
    param([string]$Message,[ValidateSet('INFO','WARN','ERROR','OK','DEBUG','HEAD')][string]$Level='INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $ts,$Level,$Message
    $color = switch ($Level) { 'ERROR' {'Red'}; 'WARN' {'Yellow'}; 'OK' {'Green'}; 'DEBUG' {'DarkGray'}; 'HEAD' {'Cyan'}; default {'White'} }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
}

function Stop-Fail {
    param([string]$Message)
    Write-Log -Level ERROR -Message $Message
    Close-AllSessions
    throw $Message
}

function ConvertTo-PlainText {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [securestring]) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if ($Value -is [pscredential]) { return (ConvertTo-PlainText -Value $Value.Password) }
    return [string]$Value
}

function ConvertTo-Secure {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [securestring]) { return $Value }
    if ($Value -is [pscredential]) { return $Value.Password }
    return (ConvertTo-SecureString -String ([string]$Value) -AsPlainText -Force)
}

function Get-SecretStorePath {
    param([string]$Name)
    if (-not (Test-Path $SecretStorePath)) { New-Item -ItemType Directory -Force -Path $SecretStorePath | Out-Null }
    Join-Path $SecretStorePath ("{0}.xml" -f $Name)
}

function Save-LocalSecret {
    param([string]$Name,[securestring]$SecureValue)
    $path = Get-SecretStorePath -Name $Name
    $SecureValue | Export-Clixml -Path $path
    Write-Log -Level OK -Message ("Secret saved (DPAPI-encrypted, this user only): {0}" -f $path)
}

function Get-LocalSecret {
    param([string]$Name)
    $path = Get-SecretStorePath -Name $Name
    if (-not (Test-Path $path)) { return $null }
    try { return Import-Clixml -Path $path } catch {
        Write-Log -Level WARN -Message ("Failed to import stored secret {0}: {1}" -f $Name,$_.Exception.Message)
        return $null
    }
}

function Get-KvSecretSecure {
    param([string]$VaultName,[string]$SecretName)
    if (-not $VaultName -or -not $SecretName) { return $null }
    if (-not (Get-Module -ListAvailable Az.KeyVault)) {
        try { Install-Module Az.Accounts,Az.KeyVault -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop | Out-Null } catch { Write-Log -Level WARN -Message "Az.KeyVault install failed; skipping KV lookup." ; return $null }
    }
    Import-Module Az.Accounts,Az.KeyVault -ErrorAction SilentlyContinue
    try { if (-not (Get-AzContext -ErrorAction Stop)) { Connect-AzAccount | Out-Null } } catch { try { Connect-AzAccount | Out-Null } catch { return $null } }
    try {
        $s = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -AsPlainText -ErrorAction Stop
        if (-not $s) { return $null }
        return (ConvertTo-SecureString -String $s -AsPlainText -Force)
    } catch {
        Write-Log -Level WARN -Message ("KV secret fetch failed for {0}/{1}: {2}" -f $VaultName,$SecretName,$_.Exception.Message)
        return $null
    }
}

function Resolve-CertSecret {
    param(
        [Parameter(Mandatory=$true)][string]$Label,
        [object]$Provided,
        [string]$LocalName,
        [string]$KvName,
        [switch]$Required
    )
    if ($null -ne $Provided -and ($Provided -isnot [string] -or $Provided -ne '')) {
        $sec = ConvertTo-Secure -Value $Provided
        if ($SavePasswords -and $LocalName) { Save-LocalSecret -Name $LocalName -SecureValue $sec }
        return $sec
    }
    if ($LocalName) {
        $sec = Get-LocalSecret -Name $LocalName
        if ($sec) { Write-Log -Level OK -Message ("Loaded {0} from local secret store ({1})" -f $Label,$LocalName); return $sec }
    }
    if ($KeyVaultName -and $KvName) {
        $sec = Get-KvSecretSecure -VaultName $KeyVaultName -SecretName $KvName
        if ($sec) { Write-Log -Level OK -Message ("Loaded {0} from Key Vault ({1}/{2})" -f $Label,$KeyVaultName,$KvName); return $sec }
    }
    if ($PromptForPasswords -and -not $NonInteractive) {
        $sec = Read-Host -AsSecureString -Prompt ("Enter {0}" -f $Label)
        if ($SavePasswords -and $LocalName) { Save-LocalSecret -Name $LocalName -SecureValue $sec }
        return $sec
    }
    if ($Required) { Stop-Fail -Message ("{0} not supplied. Pass -{1}, set -PromptForPasswords, save to '{2}', or use -KeyVaultName/-KvSecretName...." -f $Label,$Label,$SecretStorePath) }
    return $null
}

function Close-AllSessions {
    foreach ($name in @($script:Sessions.Keys)) {
        try { Remove-PSSession -Session $script:Sessions[$name] -ErrorAction SilentlyContinue } catch {}
    }
    $script:Sessions.Clear()
}

function Resolve-TargetSession {
    param([string]$HostName)
    if ($script:Sessions.ContainsKey($HostName)) { return $script:Sessions[$HostName] }
    $opts = New-PSSessionOption -IdleTimeout 7200000 -OperationTimeout 1800000
    try {
        $params = @{ ComputerName = $HostName; SessionOption = $opts; ErrorAction = 'Stop' }
        if ($Credential) { $params.Credential = $Credential }
        $s = New-PSSession @params
    } catch {
        Write-Log -Level WARN -Message ("WinRM default failed for {0}: {1}" -f $HostName,$_.Exception.Message)
        try {
            $params = @{ ComputerName = $HostName; SessionOption = $opts; UseSSL = $true; ErrorAction = 'Stop' }
            if ($Credential) { $params.Credential = $Credential }
            $s = New-PSSession @params
        } catch {
            Stop-Fail -Message ("Cannot open PSSession to {0}. Verify WinRM (port 5985/5986), firewall, and credentials. Underlying: {1}" -f $HostName,$_.Exception.Message)
        }
    }
    $script:Sessions[$HostName] = $s
    Write-Log -Level OK -Message ("Connected session to {0}" -f $HostName)
    return $s
}

function Invoke-OnTarget {
    param($Session,[scriptblock]$Script,[object[]]$ArgumentList)
    if ($ArgumentList) { Invoke-Command -Session $Session -ScriptBlock $Script -ArgumentList $ArgumentList }
    else               { Invoke-Command -Session $Session -ScriptBlock $Script }
}

function Get-WindowsStoreCerts {
    param($Session)
    Invoke-OnTarget -Session $Session -Script {
        $stores = 'Cert:\LocalMachine\My','Cert:\LocalMachine\WebHosting'
        foreach ($store in $stores) {
            if (-not (Test-Path $store)) { continue }
            Get-ChildItem $store | ForEach-Object {
                [pscustomobject]@{
                    Source      = 'WindowsStore'
                    Store       = $store
                    Subject     = $_.Subject
                    Issuer      = $_.Issuer
                    Thumbprint  = $_.Thumbprint
                    NotAfter    = $_.NotAfter
                    NotBefore   = $_.NotBefore
                    HasPrivate  = $_.HasPrivateKey
                    DnsSANs     = ($_.DnsNameList | ForEach-Object { $_.Unicode }) -join ','
                    FriendlyName= $_.FriendlyName
                    Location    = ''
                }
            }
        }
    }
}

function Get-IisBindings {
    param($Session)
    Invoke-OnTarget -Session $Session -Script {
        if (-not (Get-Module -ListAvailable WebAdministration)) { return @() }
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        if (-not (Test-Path 'IIS:\SslBindings')) { return @() }
        Get-ChildItem 'IIS:\SslBindings' | ForEach-Object {
            $b   = $_
            $cert = $null
            if ($b.Thumbprint) {
                $cert = Get-ChildItem Cert:\LocalMachine\My,Cert:\LocalMachine\WebHosting -ErrorAction SilentlyContinue |
                        Where-Object Thumbprint -eq $b.Thumbprint | Select-Object -First 1
            }
            [pscustomobject]@{
                Source       = 'IisBinding'
                Store        = 'IIS'
                Subject      = if ($cert) { $cert.Subject } else { '' }
                Issuer       = if ($cert) { $cert.Issuer } else { '' }
                Thumbprint   = $b.Thumbprint
                NotAfter     = if ($cert) { $cert.NotAfter } else { $null }
                NotBefore    = if ($cert) { $cert.NotBefore } else { $null }
                HasPrivate   = if ($cert) { $cert.HasPrivateKey } else { $false }
                DnsSANs      = if ($cert) { ($cert.DnsNameList | ForEach-Object { $_.Unicode }) -join ',' } else { '' }
                FriendlyName = ('{0}:{1}' -f $b.IPAddress,$b.Port)
                Location     = ('IIS:\SslBindings\{0}' -f $b.PSChildName)
            }
        }
    }
}

function Get-PfxFiles {
    param($Session,[string]$PfxPath,[string]$PfxPassword)
    Invoke-OnTarget -Session $Session -Script {
        param($Path,$PwdStr)
        $roots = @()
        if ($Path -and (Test-Path $Path)) { $roots += $Path }
        else {
            foreach ($drive in @('C:','D:','E:','F:')) {
                foreach ($sub in @('\SSL','\Certs','\Certificates','\OTC\OpenText\Core Archive Connector','\Program Files\SAP','\usr\sap','\inetpub\wwwroot\certs')) {
                    $full = $drive + $sub
                    if (Test-Path $full) { $roots += $full }
                }
            }
        }
        $results = @()
        foreach ($root in $roots | Select-Object -Unique) {
            try {
                $files = Get-ChildItem -Path $root -Recurse -Include '*.pfx','*.p12' -ErrorAction SilentlyContinue -Force
            } catch { continue }
            foreach ($f in $files) {
                $obj = [pscustomobject]@{
                    Source       = 'PfxFile'
                    Store        = 'File'
                    Subject      = ''
                    Issuer       = ''
                    Thumbprint   = ''
                    NotAfter     = $null
                    NotBefore    = $null
                    HasPrivate   = $true
                    DnsSANs      = ''
                    FriendlyName = $f.Name
                    Location     = $f.FullName
                }
                if ($PwdStr) {
                    try {
                        $sp = ConvertTo-SecureString -String $PwdStr -AsPlainText -Force
                        $c  = Get-PfxCertificate -FilePath $f.FullName -Password $sp -ErrorAction Stop
                        $obj.Subject    = $c.Subject
                        $obj.Issuer     = $c.Issuer
                        $obj.Thumbprint = $c.Thumbprint
                        $obj.NotAfter   = $c.NotAfter
                        $obj.NotBefore  = $c.NotBefore
                        $obj.DnsSANs    = ($c.DnsNameList | ForEach-Object { $_.Unicode }) -join ','
                    } catch {
                        $obj.FriendlyName = $f.Name + ' (locked)'
                    }
                }
                $results += $obj
            }
        }
        $results
    } -ArgumentList @($PfxPath,$PfxPassword)
}

function Get-SapPseFiles {
    param($Session,[string]$SapPsePath,[string]$SapPsePin,[string]$SapGenPsePath)
    Invoke-OnTarget -Session $Session -Script {
        param($SpecPath,$Pin,$SapGenPse)
        $candidates = @()
        if ($SpecPath) { $candidates += $SpecPath }
        else {
            $roots = @()
            foreach ($drive in @('C:','D:','E:','F:')) {
                foreach ($sub in @('\usr\sap','\Program Files\SAP','\OTC\OpenText','\sec','\SSO')) {
                    $full = $drive + $sub
                    if (Test-Path $full) { $roots += $full }
                }
            }
            foreach ($root in $roots) {
                try { $candidates += (Get-ChildItem -Path $root -Recurse -Include '*.pse' -ErrorAction SilentlyContinue -Force | ForEach-Object FullName) } catch {}
            }
        }
        $exe = $SapGenPse
        if (-not $exe) {
            foreach ($drive in @('C:','D:','E:','F:')) {
                foreach ($sub in @('\usr\sap\*\SYS\exe\run\sapgenpse.exe','\usr\sap\*\SYS\exe\uc\NTAMD64\sapgenpse.exe','\Program Files\SAP\FrontEnd\SAPGUI\sapgenpse.exe')) {
                    $found = Get-Item -Path ($drive + $sub) -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($found) { $exe = $found.FullName; break }
                }
                if ($exe) { break }
            }
        }
        $results = @()
        foreach ($pse in $candidates | Select-Object -Unique) {
            if (-not (Test-Path $pse)) { continue }
            $obj = [pscustomobject]@{
                Source       = 'SapPse'
                Store        = 'SAP'
                Subject      = ''
                Issuer       = ''
                Thumbprint   = ''
                NotAfter     = $null
                NotBefore    = $null
                HasPrivate   = $true
                DnsSANs      = ''
                FriendlyName = (Split-Path $pse -Leaf)
                Location     = $pse
                SapGenPseExe = $exe
            }
            if ($exe -and (Test-Path $exe) -and $Pin) {
                try {
                    $raw = & $exe maintain_pk -p $pse -x $Pin 2>&1
                    $txt = ($raw -join "`n")
                    $m = [regex]::Match($txt,'Subject\s*:\s*(?<s>[^\r\n]+)')
                    if ($m.Success) { $obj.Subject = $m.Groups['s'].Value.Trim() }
                    $m = [regex]::Match($txt,'Issuer\s*:\s*(?<i>[^\r\n]+)')
                    if ($m.Success) { $obj.Issuer = $m.Groups['i'].Value.Trim() }
                    $m = [regex]::Match($txt,'valid\s+until\s*:\s*(?<d>[^\r\n]+)')
                    if ($m.Success) { try { $obj.NotAfter = [DateTime]::Parse($m.Groups['d'].Value.Trim()) } catch {} }
                } catch {}
            }
            $results += $obj
        }
        $results
    } -ArgumentList @($SapPsePath,$SapPsePin,$SapGenPsePath)
}

function Get-AzureKvCerts {
    param([string]$KeyVaultName)
    if (-not $KeyVaultName) { return @() }
    if (-not (Get-Module -ListAvailable Az.KeyVault)) {
        Write-Log -Level WARN -Message 'Az.KeyVault module not installed, installing...'
        Install-Module Az.Accounts,Az.KeyVault -Scope CurrentUser -Force -AllowClobber | Out-Null
    }
    Import-Module Az.Accounts,Az.KeyVault -ErrorAction Stop
    try { $ctx = Get-AzContext -ErrorAction Stop } catch { $ctx = $null }
    if (-not $ctx) { Connect-AzAccount | Out-Null }
    $certs = Get-AzKeyVaultCertificate -VaultName $KeyVaultName
    foreach ($c in $certs) {
        $full = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $c.Name
        [pscustomobject]@{
            Source       = 'AzureKv'
            Store        = "KV:$KeyVaultName"
            Subject      = if ($full.Certificate) { $full.Certificate.Subject } else { '' }
            Issuer       = if ($full.Certificate) { $full.Certificate.Issuer } else { '' }
            Thumbprint   = if ($full.Certificate) { $full.Certificate.Thumbprint } else { '' }
            NotAfter     = $c.Expires
            NotBefore    = $c.Created
            HasPrivate   = $true
            DnsSANs      = ''
            FriendlyName = $c.Name
            Location     = $c.Id
        }
    }
}

function Get-Inventory {
    param($Session,[string]$HostName,[string]$Scope)
    $inv = @()
    $useAll = ($Scope -eq 'All' -or $Scope -eq 'Auto')
    if ($useAll -or $Scope -eq 'WindowsStore') { $inv += Get-WindowsStoreCerts -Session $Session }
    if ($useAll -or $Scope -eq 'IisBinding')   { $inv += Get-IisBindings    -Session $Session }
    if ($useAll -or $Scope -eq 'PfxFile')      { $inv += Get-PfxFiles       -Session $Session -PfxPath $PfxPath -PfxPassword $PfxPassword }
    if ($useAll -or $Scope -eq 'SapPse')       { $inv += Get-SapPseFiles    -Session $Session -SapPsePath $SapPsePath -SapPsePin $SapPsePin -SapGenPsePath $SapGenPsePath }
    if ($Scope -eq 'AzureKv')                  { $inv += Get-AzureKvCerts   -KeyVaultName $KeyVaultName }
    foreach ($i in $inv) { $i | Add-Member -NotePropertyName TargetHost -NotePropertyValue $HostName -Force }
    $inv
}

function Show-Inventory {
    param([object[]]$Inv)
    Write-Log -Level HEAD -Message '--- Certificate Inventory ---'
    $now = Get-Date
    $i = 0
    foreach ($c in $Inv) {
        $i++
        $days = if ($c.NotAfter) { [int]($c.NotAfter - $now).TotalDays } else { $null }
        $flag = ''
        if ($days -ne $null) {
            if ($days -lt 0)      { $flag = 'EXPIRED' }
            elseif ($days -le 14) { $flag = 'CRITICAL' }
            elseif ($days -le $ExpiryThresholdDays) { $flag = 'EXPIRING' }
            else                  { $flag = 'OK' }
        }
        $c | Add-Member -NotePropertyName Index -NotePropertyValue $i -Force
        $c | Add-Member -NotePropertyName DaysRemaining -NotePropertyValue $days -Force
        $c | Add-Member -NotePropertyName Status -NotePropertyValue $flag -Force
    }
    $Inv | Sort-Object TargetHost,Source,NotAfter | Format-Table Index,TargetHost,Source,Status,DaysRemaining,NotAfter,Subject,Thumbprint,Location -AutoSize | Out-String | Write-Host
}

function Select-Certificate {
    param([object[]]$Inv,[string]$Thumbprint,[string]$SubjectLike,[switch]$NonInteractive,[switch]$AutoExpiring)
    if ($Thumbprint)   { return $Inv | Where-Object { $_.Thumbprint -ieq $Thumbprint } }
    if ($SubjectLike)  {
        $match = $Inv | Where-Object { ($_.Subject -like "*$SubjectLike*") -or ($_.DnsSANs -like "*$SubjectLike*") -or ($_.FriendlyName -like "*$SubjectLike*") -or ($_.Location -like "*$SubjectLike*") }
        if ($match) { return $match }
    }
    if ($AutoExpiring) {
        return $Inv | Where-Object { $_.DaysRemaining -ne $null -and $_.DaysRemaining -le $ExpiryThresholdDays }
    }
    if ($NonInteractive) { Stop-Fail -Message 'NonInteractive mode but no -Thumbprint / -SubjectLike / -RenewAuto provided.' }
    Show-Inventory -Inv $Inv
    $choice = Read-Host 'Enter Index number(s) to renew (comma separated) or "q" to quit'
    if ($choice -eq 'q') { Stop-Fail -Message 'User cancelled.' }
    $picked = @()
    foreach ($n in ($choice -split ',')) {
        $idx = [int]($n.Trim())
        $hit = $Inv | Where-Object Index -eq $idx
        if ($hit) { $picked += $hit }
    }
    if (-not $picked) { Stop-Fail -Message 'No valid selection.' }
    $picked
}

function Find-AdcsCa {
    param([string]$Override)
    if ($Override) { return $Override }
    try {
        $root = ([ADSI]'LDAP://RootDSE').configurationNamingContext
        $path = "LDAP://CN=Enrollment Services,CN=Public Key Services,CN=Services,$root"
        $srch = New-Object System.DirectoryServices.DirectorySearcher ([ADSI]$path)
        $srch.Filter = '(objectClass=pKIEnrollmentService)'
        $found = $srch.FindAll()
        if ($found.Count -eq 0) { Stop-Fail -Message 'No ADCS Enterprise CA found via AD. Pass -CaConfig "CAHOST\\CA Common Name"' }
        $cas = foreach ($r in $found) {
            $cn   = $r.Properties['cn'][0]
            $host = $r.Properties['dnshostname'][0]
            [pscustomobject]@{ CommonName=$cn; Host=$host; Config=('{0}\{1}' -f $host,$cn) }
        }
        $preferred = $cas | Where-Object { $_.CommonName -match 'General Issuing' } | Select-Object -First 1
        if ($preferred) { Write-Log -Level OK -Message ("CA auto-selected: {0}" -f $preferred.Config); return $preferred.Config }
        if ($cas.Count -eq 1) { Write-Log -Level OK -Message ("CA auto-selected: {0}" -f $cas[0].Config); return $cas[0].Config }
        Write-Log -Level HEAD -Message 'Multiple CAs discovered:'
        $i = 0; $cas | ForEach-Object { $i++; $_ | Add-Member -NotePropertyName Index -NotePropertyValue $i -Force }
        $cas | Format-Table Index,CommonName,Host -AutoSize | Out-String | Write-Host
        $pick = [int](Read-Host 'Select CA index')
        $sel  = $cas | Where-Object Index -eq $pick
        if (-not $sel) { Stop-Fail -Message 'Invalid CA selection.' }
        return $sel.Config
    } catch {
        Stop-Fail -Message ("CA auto-discovery failed: {0}" -f $_.Exception.Message)
    }
}

function New-InfContent {
    param([string]$Subject,[string[]]$Sans,[int]$KeySize,[string]$Template,[bool]$Exportable)
    $ext = [string]::Empty
    if ($Sans -and $Sans.Count -gt 0) {
        $ext = "[Extensions]`r`n2.5.29.17 = `"{text}`"`r`n"
        foreach ($s in $Sans) { $ext += ("_continue_ = `"dns={0}&`"`r`n" -f $s) }
    }
    $expo = if ($Exportable) { 'TRUE' } else { 'FALSE' }
@"
[NewRequest]
Subject = "$Subject"
KeySpec = 1
KeyLength = $KeySize
Exportable = $expo
MachineKeySet = TRUE
SMIME = FALSE
PrivateKeyArchive = FALSE
UserProtected = FALSE
UseExistingKeySet = FALSE
ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
ProviderType = 12
RequestType = PKCS10
KeyUsage = 0xa0
[EnhancedKeyUsageExtension]
OID = 1.3.6.1.5.5.7.3.1
OID = 1.3.6.1.5.5.7.3.2
[RequestAttributes]
CertificateTemplate = $Template
$ext
"@
}

function Invoke-CsrOnTargetWindows {
    param($Session,[string]$Subject,[string[]]$Sans,[int]$KeySize,[string]$Template,[string]$Staging)
    $infBody = New-InfContent -Subject $Subject -Sans $Sans -KeySize $KeySize -Template $Template -Exportable $false
    Invoke-OnTarget -Session $Session -Script {
        param($Dir,$Inf)
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        $infPath = Join-Path $Dir 'request.inf'
        $csrPath = Join-Path $Dir 'request.csr'
        Set-Content -Path $infPath -Value $Inf -Encoding ASCII -Force
        $out = & certreq.exe -f -new $infPath $csrPath 2>&1
        if ($LASTEXITCODE -ne 0) { throw ("certreq -new failed: {0}" -f ($out -join "`n")) }
        [pscustomobject]@{ Inf=$infPath; Csr=$csrPath; CsrContent=(Get-Content $csrPath -Raw) }
    } -ArgumentList @($Staging,$infBody)
}

function Invoke-CsrSubmit {
    param($Session,[string]$Staging,[string]$CaConfig)
    Invoke-OnTarget -Session $Session -Script {
        param($Dir,$Ca)
        $csr = Join-Path $Dir 'request.csr'
        $cer = Join-Path $Dir 'signed.cer'
        $out = & certreq.exe -f -submit -config $Ca $csr $cer 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            throw ("certreq -submit failed (exit {0}): {1}" -f $code,($out -join "`n"))
        }
        if (-not (Test-Path $cer)) { throw 'Signed cert not produced. CA may require manual approval.' }
        [pscustomobject]@{ Cer=$cer; Output=($out -join "`n") }
    } -ArgumentList @($Staging,$CaConfig)
}

function Invoke-CsrAccept {
    param($Session,[string]$Staging)
    Invoke-OnTarget -Session $Session -Script {
        param($Dir)
        $cer = Join-Path $Dir 'signed.cer'
        $out = & certreq.exe -accept $cer 2>&1
        if ($LASTEXITCODE -ne 0) { throw ("certreq -accept failed: {0}" -f ($out -join "`n")) }
        $thumb = ([regex]::Match(($out -join "`n"),'Thumbprint:\s*([A-Fa-f0-9]+)')).Groups[1].Value
        if (-not $thumb) {
            $certObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $cer
            $thumb = $certObj.Thumbprint
        }
        [pscustomobject]@{ Thumbprint=$thumb; Output=($out -join "`n") }
    } -ArgumentList @($Staging)
}

function Backup-CertWindowsStore {
    param($Session,[string]$Thumbprint,[string]$LocalBackupDir)
    $remoteStage = Join-Path $RemoteStagingRoot 'backup'
    $exported = Invoke-OnTarget -Session $Session -Script {
        param($Thumb,$Dir)
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        $cert = Get-ChildItem Cert:\LocalMachine\My,Cert:\LocalMachine\WebHosting -ErrorAction SilentlyContinue | Where-Object Thumbprint -eq $Thumb | Select-Object -First 1
        if (-not $cert) { return $null }
        $cerPath = Join-Path $Dir ("$Thumb.cer")
        Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT -Force | Out-Null
        $cerPath
    } -ArgumentList @($Thumbprint,$remoteStage)
    if ($exported) {
        $local = Join-Path $LocalBackupDir ("$Thumbprint.cer")
        Copy-Item -FromSession (Resolve-TargetSession -HostName ($Session.ComputerName)) -Path $exported -Destination $local -ErrorAction SilentlyContinue
        Write-Log -Level OK -Message ("Backed up public cert to {0}" -f $local)
    }
}

function Bind-NewCertToIis {
    param($Session,[string]$Thumbprint,[string]$OldThumbprint)
    Invoke-OnTarget -Session $Session -Script {
        param($NewThumb,$OldThumb)
        if (-not (Get-Module -ListAvailable WebAdministration)) { return }
        Import-Module WebAdministration
        if (-not (Test-Path 'IIS:\SslBindings')) { return }
        Get-ChildItem 'IIS:\SslBindings' | Where-Object Thumbprint -eq $OldThumb | ForEach-Object {
            $path = $_.PSPath
            $ip   = $_.IPAddress
            $port = $_.Port
            Remove-Item $path -Confirm:$false -Force
            $newCert = Get-ChildItem Cert:\LocalMachine\My,Cert:\LocalMachine\WebHosting -ErrorAction SilentlyContinue | Where-Object Thumbprint -eq $NewThumb | Select-Object -First 1
            if ($newCert) {
                New-Item -Path ("IIS:\SslBindings\{0}!{1}" -f $ip,$port) -Value $newCert -Force | Out-Null
            }
        }
    } -ArgumentList @($Thumbprint,$OldThumbprint)
}

function Install-CertPfxFile {
    param($Session,[string]$PfxPath,[string]$PfxPassword,[string]$SignedCerPath,[string]$CertKeyThumbprint,[string]$LocalBackupDir)
    $backup = Invoke-OnTarget -Session $Session -Script {
        param($P,$Dir)
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        if (-not (Test-Path $P)) { return $null }
        $b = Join-Path $Dir (Split-Path $P -Leaf)
        Copy-Item $P $b -Force
        $b
    } -ArgumentList @($PfxPath,(Join-Path $RemoteStagingRoot 'backup'))
    if ($backup) {
        $local = Join-Path $LocalBackupDir (Split-Path $PfxPath -Leaf)
        try { Copy-Item -FromSession (Resolve-TargetSession -HostName ($Session.ComputerName)) -Path $backup -Destination $local -Force -ErrorAction Stop } catch {}
    }
    Invoke-OnTarget -Session $Session -Script {
        param($P,$PwdStr,$CerPath,$Thumb)
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -eq $Thumb | Select-Object -First 1
        if (-not $cert) { throw ("Thumbprint {0} not found in LocalMachine\My after accept." -f $Thumb) }
        $sp = ConvertTo-SecureString -String $PwdStr -AsPlainText -Force
        Export-PfxCertificate -Cert $cert -FilePath $P -Password $sp -Force | Out-Null
    } -ArgumentList @($PfxPath,$PfxPassword,$SignedCerPath,$CertKeyThumbprint)
}

function Install-CertSapPse {
    param($Session,[string]$SapPsePath,[string]$SapPsePin,[string]$SapGenPseExe,[string]$Subject,[string[]]$Sans,[string]$CaConfig,[string]$LocalBackupDir,[string]$RemoteStaging)
    $backup = Invoke-OnTarget -Session $Session -Script {
        param($P,$Dir)
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        if (-not (Test-Path $P)) { return $null }
        $b = Join-Path $Dir ((Split-Path $P -Leaf) + '.bak')
        Copy-Item $P $b -Force
        $b
    } -ArgumentList @($SapPsePath,(Join-Path $RemoteStaging 'backup'))
    if ($backup) {
        $local = Join-Path $LocalBackupDir ((Split-Path $SapPsePath -Leaf) + '.bak')
        try { Copy-Item -FromSession (Resolve-TargetSession -HostName ($Session.ComputerName)) -Path $backup -Destination $local -Force -ErrorAction Stop } catch {}
    }
    $artifacts = Invoke-OnTarget -Session $Session -Script {
        param($Exe,$Pse,$Pin,$Dir,$Dn,$SansCsv)
        if (-not (Test-Path $Exe))  { throw ("sapgenpse.exe not found at {0}" -f $Exe) }
        if (-not (Test-Path $Dir))  { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
        $newPse = Join-Path $Dir ((Split-Path $Pse -Leaf) + '.new')
        $csr    = Join-Path $Dir 'sap_request.csr'
        if (Test-Path $newPse) { Remove-Item $newPse -Force }
        $sanArgs = @()
        if ($SansCsv) { foreach ($s in ($SansCsv -split ',')) { if ($s) { $sanArgs += @('-s',('DNS={0}' -f $s.Trim())) } } }
        $args = @('gen_pse','-p',$newPse,'-x',$Pin,'-r',$csr) + $sanArgs + @($Dn)
        $out  = & $Exe @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw ("sapgenpse gen_pse failed: {0}" -f ($out -join "`n")) }
        [pscustomobject]@{ NewPse=$newPse; Csr=$csr; CsrContent=(Get-Content $csr -Raw); GenOutput=($out -join "`n") }
    } -ArgumentList @($SapGenPseExe,$SapPsePath,$SapPsePin,$RemoteStaging,$Subject,(($Sans) -join ','))
    $submit = Invoke-OnTarget -Session $Session -Script {
        param($Ca,$Csr,$Dir)
        $cer = Join-Path $Dir 'sap_signed.cer'
        $out = & certreq.exe -f -submit -config $Ca $Csr $cer 2>&1
        if ($LASTEXITCODE -ne 0) { throw ("certreq -submit failed: {0}" -f ($out -join "`n")) }
        if (-not (Test-Path $cer)) { throw 'No signed SAP cert produced.' }
        [pscustomobject]@{ Cer=$cer }
    } -ArgumentList @($CaConfig,$artifacts.Csr,$RemoteStaging)
    Invoke-OnTarget -Session $Session -Script {
        param($Exe,$NewPse,$Pin,$Signed,$TargetPse)
        $out = & $Exe import_own_cert -p $NewPse -x $Pin -c $Signed 2>&1
        if ($LASTEXITCODE -ne 0) { throw ("sapgenpse import_own_cert failed: {0}" -f ($out -join "`n")) }
        $bak = $TargetPse + '.prev'
        if (Test-Path $TargetPse) { Copy-Item $TargetPse $bak -Force }
        Copy-Item $NewPse $TargetPse -Force
    } -ArgumentList @($SapGenPseExe,$artifacts.NewPse,$SapPsePin,$submit.Cer,$SapPsePath)
}

function Install-CertAzureKv {
    param([string]$KeyVaultName,[string]$CertName,[string]$PfxPath,[string]$PfxPassword)
    if (-not (Get-Module -ListAvailable Az.KeyVault)) {
        Install-Module Az.Accounts,Az.KeyVault -Scope CurrentUser -Force -AllowClobber | Out-Null
    }
    Import-Module Az.Accounts,Az.KeyVault
    try { $ctx = Get-AzContext -ErrorAction Stop } catch { $ctx = $null }
    if (-not $ctx) { Connect-AzAccount | Out-Null }
    $sp = ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force
    Import-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertName -FilePath $PfxPath -Password $sp | Out-Null
    Write-Log -Level OK -Message ("Imported cert into Key Vault {0}/{1}" -f $KeyVaultName,$CertName)
}

function Restart-TargetService {
    param($Session,[string]$ServiceName)
    if (-not $ServiceName) { return }
    Invoke-OnTarget -Session $Session -Script {
        param($Svc)
        $s = Get-Service -Name $Svc -ErrorAction SilentlyContinue
        if (-not $s) { Write-Warning ("Service {0} not found on target." -f $Svc); return }
        if ($s.Status -eq 'Running') { Restart-Service -Name $Svc -Force; return }
        Start-Service -Name $Svc
    } -ArgumentList @($ServiceName)
    Write-Log -Level OK -Message ("Service {0} restart requested." -f $ServiceName)
}

function Test-NewCertificate {
    param($Session,[string]$Thumbprint)
    $ok = Invoke-OnTarget -Session $Session -Script {
        param($Thumb)
        $c = Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -eq $Thumb | Select-Object -First 1
        if (-not $c) { return $false }
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = 'NoCheck'
        $res = $chain.Build($c)
        [pscustomobject]@{ Built=$res; Subject=$c.Subject; NotAfter=$c.NotAfter; NotBefore=$c.NotBefore; Issuer=$c.Issuer; HasKey=$c.HasPrivateKey }
    } -ArgumentList @($Thumbprint)
    if (-not $ok) { Write-Log -Level ERROR -Message 'New cert not found on target after accept.' ; return $false }
    Write-Log -Level OK -Message ("Verified: Subject={0} NotAfter={1} ChainOk={2}" -f $ok.Subject,$ok.NotAfter,$ok.Built)
    $true
}

function Renew-SingleCert {
    param([object]$Cert,$Session)
    Write-Log -Level HEAD -Message ("Renewing: {0} [{1}] on {2}" -f $Cert.Subject,$Cert.Source,$Cert.TargetHost)
    if ($DryRun) { Write-Log -Level WARN -Message 'DryRun - skipping actual renewal.'; return }
    $subject = if ($SubjectOverride) { $SubjectOverride } elseif ($Cert.Subject) { $Cert.Subject } else { ('CN={0}' -f $Cert.TargetHost) }
    $sans = if ($DnsNames) { $DnsNames } elseif ($Cert.DnsSANs) { ($Cert.DnsSANs -split ',') | Where-Object { $_ } } else {
        $cn = [regex]::Match($subject,'CN=([^,]+)').Groups[1].Value
        if ($cn) { @($cn) } else { @($Cert.TargetHost) }
    }
    $ca = Find-AdcsCa -Override $CaConfig
    $stagingRoot = $RemoteStagingRoot
    Invoke-OnTarget -Session $Session -Script { param($D) New-Item -ItemType Directory -Force -Path $D | Out-Null } -ArgumentList @($stagingRoot)
    switch ($Cert.Source) {
        'SapPse' {
            $exe = $SapGenPsePath
            if (-not $exe -and $Cert.PSObject.Properties.Name -contains 'SapGenPseExe') { $exe = $Cert.SapGenPseExe }
            if (-not $exe) { Stop-Fail -Message 'sapgenpse.exe path unknown. Pass -SapGenPsePath.' }
            if (-not $SapPsePin) { Stop-Fail -Message 'SAP PSE requires -SapPsePin.' }
            Install-CertSapPse -Session $Session -SapPsePath $Cert.Location -SapPsePin $SapPsePin -SapGenPseExe $exe -Subject $subject -Sans $sans -CaConfig $ca -LocalBackupDir $script:BackupDir -RemoteStaging $stagingRoot
            Write-Log -Level OK -Message ("SAP PSE updated at {0}" -f $Cert.Location)
        }
        'PfxFile' {
            if (-not $PfxPassword) { Stop-Fail -Message 'PfxFile renewal needs -PfxPassword to re-export.' }
            $csr = Invoke-CsrOnTargetWindows -Session $Session -Subject $subject -Sans $sans -KeySize $KeySize -Template $CaTemplate -Staging $stagingRoot
            $sign = Invoke-CsrSubmit -Session $Session -Staging $stagingRoot -CaConfig $ca
            $acc  = Invoke-CsrAccept -Session $Session -Staging $stagingRoot
            if ($Cert.Thumbprint) { Backup-CertWindowsStore -Session $Session -Thumbprint $Cert.Thumbprint -LocalBackupDir $script:BackupDir }
            Install-CertPfxFile -Session $Session -PfxPath $Cert.Location -PfxPassword $PfxPassword -SignedCerPath $sign.Cer -CertKeyThumbprint $acc.Thumbprint -LocalBackupDir $script:BackupDir
            Write-Log -Level OK -Message ("PFX refreshed at {0} (thumb {1})" -f $Cert.Location,$acc.Thumbprint)
        }
        'AzureKv' {
            $tmpPfx = Join-Path $env:TEMP ("{0}.pfx" -f $KvCertName)
            if (-not (Test-Path $PfxPath)) { Stop-Fail -Message 'AzureKv renewal needs -PfxPath to a prepared PFX.' }
            Install-CertAzureKv -KeyVaultName $KeyVaultName -CertName $KvCertName -PfxPath $PfxPath -PfxPassword $PfxPassword
        }
        default {
            $csr = Invoke-CsrOnTargetWindows -Session $Session -Subject $subject -Sans $sans -KeySize $KeySize -Template $CaTemplate -Staging $stagingRoot
            $sign = Invoke-CsrSubmit -Session $Session -Staging $stagingRoot -CaConfig $ca
            $acc  = Invoke-CsrAccept -Session $Session -Staging $stagingRoot
            if ($Cert.Thumbprint) { Backup-CertWindowsStore -Session $Session -Thumbprint $Cert.Thumbprint -LocalBackupDir $script:BackupDir }
            if ($Cert.Source -eq 'IisBinding' -and $Cert.Thumbprint) {
                Bind-NewCertToIis -Session $Session -Thumbprint $acc.Thumbprint -OldThumbprint $Cert.Thumbprint
            }
            Test-NewCertificate -Session $Session -Thumbprint $acc.Thumbprint | Out-Null
            Write-Log -Level OK -Message ("Windows store cert updated (new thumb {0})" -f $acc.Thumbprint)
        }
    }
    if (-not $SkipRestart -and $ServiceName) { Restart-TargetService -Session $Session -ServiceName $ServiceName }
}

try {
    Write-Log -Level HEAD -Message ('Update-ServerCert starting | Action={0} | Targets={1}' -f $Action,($Target -join ','))
    Write-Log -Level INFO -Message ('LogFile: {0}' -f $script:LogFile)
    Write-Log -Level INFO -Message ('BackupDir: {0}' -f $script:BackupDir)

    $script:PfxSecure = Resolve-CertSecret -Label 'PfxPassword' -Provided $PfxPassword -LocalName (if ($PfxPath) { 'pfx-' + ([IO.Path]::GetFileNameWithoutExtension($PfxPath)) } else { 'pfx-default' }) -KvName $KvSecretNamePfx
    $script:PseSecure = Resolve-CertSecret -Label 'SapPsePin'   -Provided $SapPsePin   -LocalName (if ($SapPsePath) { 'pse-' + ([IO.Path]::GetFileNameWithoutExtension($SapPsePath)) } else { 'pse-default' }) -KvName $KvSecretNamePse
    $PfxPassword = ConvertTo-PlainText -Value $script:PfxSecure
    $SapPsePin   = ConvertTo-PlainText -Value $script:PseSecure

    $allInv = @()
    foreach ($h in $Target) {
        $s = Resolve-TargetSession -HostName $h
        $inv = Get-Inventory -Session $s -HostName $h -Scope $Scope
        $allInv += $inv
    }

    if ($Action -eq 'Discover') {
        Show-Inventory -Inv $allInv
        Write-Log -Level OK -Message 'Discovery complete.'
        Close-AllSessions
        return
    }

    if ($Action -eq 'Verify') {
        foreach ($c in $allInv) {
            if (-not $c.Thumbprint) { continue }
            $s = Resolve-TargetSession -HostName $c.TargetHost
            Test-NewCertificate -Session $s -Thumbprint $c.Thumbprint | Out-Null
        }
        Close-AllSessions
        return
    }

    if ($Action -eq 'Rollback') {
        Write-Log -Level WARN -Message 'Rollback: restoring latest backup files to target paths.'
        $backups = Get-ChildItem $BackupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if (-not $backups) { Stop-Fail -Message 'No backup found.' }
        Write-Log -Level INFO -Message ("Using backup set: {0}" -f $backups.FullName)
        foreach ($f in Get-ChildItem $backups.FullName -File) {
            Write-Log -Level INFO -Message ("Backup artifact: {0}" -f $f.FullName)
        }
        Write-Log -Level WARN -Message 'Manual restore required for SAP PSE and PFX paths. .cer public exports cannot restore private keys.'
        Close-AllSessions
        return
    }

    $picks = if ($Action -eq 'RenewAuto') {
        Select-Certificate -Inv $allInv -AutoExpiring -NonInteractive:$NonInteractive
    } else {
        Select-Certificate -Inv $allInv -Thumbprint $Thumbprint -SubjectLike $SubjectLike -NonInteractive:$NonInteractive
    }

    if (-not $picks) { Stop-Fail -Message 'No certificates picked for renewal.' }

    Write-Log -Level HEAD -Message ("{0} certificate(s) selected for renewal." -f ($picks | Measure-Object).Count)
    $picks | Format-Table TargetHost,Source,Subject,Thumbprint,NotAfter -AutoSize | Out-String | Write-Host

    if (-not $Force -and -not $NonInteractive) {
        $confirm = Read-Host 'Proceed with renewal? (yes/no)'
        if ($confirm -ne 'yes') { Stop-Fail -Message 'User aborted.' }
    }

    foreach ($c in $picks) {
        $s = Resolve-TargetSession -HostName $c.TargetHost
        try {
            Renew-SingleCert -Cert $c -Session $s
        } catch {
            Write-Log -Level ERROR -Message ("Renewal failed for {0} on {1}: {2}" -f $c.Subject,$c.TargetHost,$_.Exception.Message)
            if (-not $Force) { throw }
        }
    }

    Write-Log -Level OK -Message 'All requested renewals completed.'
}
catch {
    Write-Log -Level ERROR -Message $_.Exception.Message
    throw
}
finally {
    Close-AllSessions
    Write-Log -Level INFO -Message ('Run artifacts: {0}' -f $script:LogFile)
}
