# SAP Cert Manager - Quick Start

## Prereqs (one time on jump server)

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Install-Module Az.Accounts,Az.KeyVault -Scope CurrentUser -Force -AllowClobber
$cred = Get-Credential
```

Use domain creds that have:
- WinRM (PSSession) rights on target server
- Local Admin on target server
- "Enroll" permission on the CA template (WebServer or your internal name)

## Tomorrow - ns2otpapp renewal (fastest path)

```powershell
cd C:\Users\PC\Downloads\SAP-Cert-Manager
$cred = Get-Credential
.\examples\Renew-Ns2otpapp.ps1 -Credential $cred -DiscoverOnly
```

Review the inventory table. Note which row is the expiring cert.

Then run the renewal. Three variants based on where the cert lives:

### A) Cert is in Windows cert store (most common for OpenText Core Archive Connector)

```powershell
.\examples\Renew-Ns2otpapp.ps1 -Credential $cred
```

It will:
1. Connect via WinRM to ns2otpapp (tries hostname, falls back to 10.168.0.32 / 10.168.2.22)
2. Auto-discover Parker Hannifin General Issuing CA v2 via AD
3. Generate CSR on the target (private key stays on target)
4. Submit CSR, retrieve signed cert
5. Install, re-bind any IIS SSL bindings to new thumbprint
6. Restart "OpenText Core Archive Connector" service
7. Log + back up the previous cert's public portion

### B) Cert is a SAP PSE file (STRUST)

```powershell
.\examples\Renew-Ns2otpapp.ps1 -Credential $cred -SapPsePin '<pse-pin>'
```

Same flow but uses sapgenpse.exe to gen a new PSE, submit CSR, import signed cert, and atomically swap the PSE file.

### C) Cert is a PFX file on disk

```powershell
.\examples\Renew-Ns2otpapp.ps1 -Credential $cred -PfxPassword '<pfx-password>'
```

## Password / PIN handling (locked PFX and SAP PSE)

You never have to paste a password on the command line. Any of these work:

**Option 1 - Interactive prompt (easiest)**

```powershell
.\Update-ServerCert.ps1 -Target ns2otpapp -Credential $cred -Action Renew `
    -Scope PfxFile -SubjectLike 'ns2otpapp.sap.parker.corp' -PfxPath 'E:\OTC\cert.pfx' `
    -PromptForPasswords
```

Hidden prompt asks for the PFX password and/or SAP PSE pin as a SecureString.

**Option 2 - Save once, reuse forever (DPAPI encrypted, locked to your Windows account)**

```powershell
.\Update-ServerCert.ps1 -Target ns2otpapp -Credential $cred -Action Renew `
    -Scope PfxFile -PfxPath 'E:\OTC\cert.pfx' -PromptForPasswords -SavePasswords
```

The next run on the same account / same jump server reads the stored secret automatically - no prompt. Stored at `$HOME\.cert-secrets\pfx-cert.xml` and only your user on this machine can decrypt it (Windows DPAPI).

To delete a saved secret:

```powershell
Remove-Item "$HOME\.cert-secrets\pfx-cert.xml"
```

**Option 3 - Pass a SecureString (for scripting pipelines)**

```powershell
$sec = Read-Host -AsSecureString -Prompt 'PFX password'
.\Update-ServerCert.ps1 -Target ns2otpapp -Credential $cred -Action Renew `
    -PfxPath 'E:\OTC\cert.pfx' -PfxPassword $sec
```

**Option 4 - Pull from Azure Key Vault**

```powershell
.\Update-ServerCert.ps1 -Target ns2otpapp -Credential $cred -Action Renew `
    -PfxPath 'E:\OTC\cert.pfx' `
    -KeyVaultName corp-kv-secrets -KvSecretNamePfx 'ns2otpapp-pfx-password' `
    -KvSecretNamePse 'ns2otpapp-pse-pin'
```

The script auto-installs `Az.KeyVault` if missing and runs `Connect-AzAccount` if you aren't signed in.

**Option 5 - Plaintext (NOT recommended, only for lab)**

```powershell
.\Update-ServerCert.ps1 ... -PfxPassword 'myPfxPass!' -SapPsePin 'myPin!'
```

### Password search order

When you don't pass it explicitly, Resolve-CertSecret checks in this order:

1. `-PfxPassword` / `-SapPsePin` you passed (string, SecureString, or PSCredential)
2. DPAPI-encrypted file at `$HOME\.cert-secrets\pfx-<filename>.xml` (or `pse-<filename>.xml`)
3. Azure Key Vault (needs both `-KeyVaultName` + `-KvSecretNamePfx` / `-KvSecretNamePse`)
4. Interactive prompt (only if `-PromptForPasswords` set and not `-NonInteractive`)
5. Fail with a clear message telling you which parameter to set

### Rights-Protected Email (rpmsg files)

If someone sent the password via `message_v2.rpmsg` (Microsoft Information Rights Management):

- **Do not use Outlook's preview pane** - it cannot preview rpmsg.
- **Double-click the attachment** in Outlook - it opens in a new window if you're authorized.
- **Or open in the browser** at `outlook.office.com` - OWA handles rpmsg natively.
- If it says "access denied", your signed-in identity doesn't have rights - ask the sender to re-authorize your exact email, or to forward without `Do Not Forward` restriction.
- Alternative: install **Azure Information Protection Viewer** (Microsoft Download Center).

Once you can see the password, feed it into option 1 or 2 above.

## Generic usage (any server, any cert type)

Discover everything:

```powershell
.\Update-ServerCert.ps1 -Target myserver -Credential $cred -Action Discover -Scope All
```

Renew a specific cert by thumbprint:

```powershell
.\Update-ServerCert.ps1 -Target myserver -Credential $cred -Action Renew `
    -Scope WindowsStore -Thumbprint AABBCC... -ServiceName 'MyApp'
```

Auto-renew anything expiring within 45 days:

```powershell
.\Update-ServerCert.ps1 -Target myserver -Credential $cred -Action RenewAuto `
    -ExpiryThresholdDays 45 -NonInteractive -Force
```

Renew across multiple servers at once:

```powershell
.\Update-ServerCert.ps1 -Target ns2otpapp,ns2otpapp2,sapweb1 -Credential $cred `
    -Action RenewAuto -Scope WindowsStore -Force
```

## Parameters

| Param | Purpose |
|-------|---------|
| `-Target` | One or more hostnames/IPs (ns2otpapp, 10.168.0.32) |
| `-Credential` | `Get-Credential` - domain account with WinRM+local-admin |
| `-Action` | Discover \| Renew \| RenewAuto \| Verify \| Rollback |
| `-Scope` | Auto \| WindowsStore \| PfxFile \| IisBinding \| SapPse \| AzureKv \| All |
| `-Thumbprint` | Filter to exactly one cert |
| `-SubjectLike` | Filter by substring ("ns2otpapp.sap.parker.corp") |
| `-PfxPath` / `-PfxPassword` | For PFX-backed certs |
| `-SapPsePath` / `-SapPsePin` / `-SapGenPsePath` | For SAP STRUST PSE files |
| `-KeyVaultName` / `-KvCertName` | For Azure Key Vault certs |
| `-CaConfig` | `"CAHOST\CA Common Name"` - skip AD auto-discovery |
| `-CaTemplate` | ADCS template name, default `WebServer` |
| `-SubjectOverride` | Force-set DN (`CN=...,OU=...,O=...,L=...,C=...`) |
| `-DnsNames` | SAN list - defaults to existing cert's SANs |
| `-KeySize` | Default 2048, use 4096 for high-security |
| `-ServiceName` | Service to restart after replacement |
| `-BackupRoot` / `-LogRoot` | Override default paths |
| `-ExpiryThresholdDays` | "Expiring soon" cutoff (default 45) |
| `-DryRun` | Discover + CSR planning, no changes |
| `-NonInteractive` | Fail on prompts instead of asking |
| `-Force` | Skip confirmation, continue past errors |
| `-SkipRestart` | Don't touch the service |

## Rollback

```powershell
.\Update-ServerCert.ps1 -Target ns2otpapp -Credential $cred -Action Rollback
```

Points to the most recent backup set. SAP PSE rollback is file-copy. Windows-store rollback requires the PFX (not just the public .cer) - keep PFX exports before any high-risk renewal.

## Manual emergency bail-out

If the script fails mid-flight on the target:

```powershell
Enter-PSSession -ComputerName ns2otpapp -Credential $cred
cd C:\Temp\CertRenew
dir
# signed.cer and request.csr are here if submission succeeded
# .pse.prev and PFX backups at same path + remote backup dir
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Cannot open PSSession` | Enable WinRM on target: `winrm quickconfig` / firewall / trusted hosts. Or use `-UseSSL` path. |
| `No ADCS Enterprise CA found` | Pass `-CaConfig "ca01.parker.corp\Parker Hannifin General Issuing CA v2"` |
| `certreq -submit exit 5` | CA policy blocks the template - ask PKI team to approve the template for this server's computer object |
| `sapgenpse.exe not found` | Pass `-SapGenPsePath "E:\usr\sap\PP4\SYS\exe\uc\NTAMD64\sapgenpse.exe"` |
| `Service not found` | Run `-Action Discover`, see service name, rerun with `-ServiceName 'exact name'` |
| Cert signed but not binding to app | Pass `-SkipRestart:$false -ServiceName` so the app picks up new cert |

## Where output goes

- Logs: `C:\Users\PC\Downloads\SAP-Cert-Manager\logs\cert-<runId>.log`
- Backups: `C:\Users\PC\Downloads\SAP-Cert-Manager\backups\<runId>\`
- Remote staging on target: `C:\Temp\CertRenew\` (CSRs, signed .cer, PFX backups)
