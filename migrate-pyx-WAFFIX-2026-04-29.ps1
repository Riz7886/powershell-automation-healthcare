[CmdletBinding()]
param(
    [hashtable]$ProfileMap = @{
        "pyxiq"        = "pyxiq-std"
        "hipyx"        = "hipyx-std-v2"
        "pyxiq-stage"  = "pyxiq-stage-std"
        "pyxpwa-stage" = "pyxpwa-stage-std"
        "standard"     = "standard-afdstd"
    },
    [string]$Sku                 = "Standard_AzureFrontDoor",
    [int]   $WatchdogSec         = 300,
    [int]   $WatchdogIntervalSec = 30,
    [switch]$DryRun,
    [switch]$DiscoveryOnly,
    [switch]$NoConfirm,
    [switch]$AutoCommit,
    [switch]$SkipWatchdog,
    [string[]]$OnlyProfiles      = @(),
    [string]$ReportDir           = (Join-Path $env:USERPROFILE "Desktop\pyx-atomic-migrate-report")
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"
$timestamp   = (Get-Date).ToString("yyyyMMdd-HHmmss")
$startTime   = Get-Date
if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
$snapshotDir = Join-Path $ReportDir "snapshots-$timestamp"
if (-not (Test-Path $snapshotDir)) { New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null }
$logPath     = Join-Path $ReportDir "pwsh-migrate-$timestamp.log"
$dnsHtmlPath = Join-Path $ReportDir "dns-handoff-all-$timestamp.html"
$summaryPath = Join-Path $ReportDir "summary-$timestamp.html"
$changePath  = Join-Path $ReportDir "change-report-$timestamp.html"
$statePath   = Join-Path $ReportDir "state-$timestamp.json"

function Log {
    param([string]$Message, [string]$Level = "INFO")
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line  = "[$stamp] [$Level] $Message"
    Add-Content -Path $logPath -Value $line
    $color = switch ($Level) { "OK" {"Green"} "WARN" {"Yellow"} "ERR" {"Red"} "STEP" {"Cyan"} default {"White"} }
    Write-Host $line -ForegroundColor $color
}
function Banner($t)    { Log ""; Log ("=" * 78); Log $t "STEP"; Log ("=" * 78) }
function SubBanner($t) { Log ""; Log ("-" * 78); Log $t "STEP"; Log ("-" * 78) }

function Save-State {
    param($Plan, $Results)
    $state = [PSCustomObject]@{ timestamp = $timestamp; plan = $Plan; results = $Results }
    $state | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath -Encoding ASCII
}

if ($OnlyProfiles.Count -gt 0) {
    $filtered = @{}
    foreach ($pname in $OnlyProfiles) { if ($ProfileMap.ContainsKey($pname)) { $filtered[$pname] = $ProfileMap[$pname] } }
    $ProfileMap = $filtered
}

Banner "PYX migration via Az.Cdn PowerShell module - documented Microsoft cmdlets"
Log "Profiles in scope: $($ProfileMap.Keys -join ', ')"
Log "Target SKU:        $Sku"
Log "Report dir:        $ReportDir"

Banner "Phase 0a - Install / import required PowerShell modules"
$requiredModules = @("Az.Accounts", "Az.Cdn", "Az.FrontDoor", "Az.Resources")
foreach ($m in $requiredModules) {
    $installed = Get-Module -ListAvailable -Name $m -ErrorAction SilentlyContinue
    if (-not $installed) {
        Log "Installing $m (CurrentUser scope)..."
        Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module $m -ErrorAction Stop
    $loaded = (Get-Module -Name $m).Version
    Log "$m loaded ($loaded)" "OK"
}

Banner "Phase 0b - Connect-AzAccount"
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    Log "Not connected - prompting Connect-AzAccount..." "WARN"
    Connect-AzAccount -ErrorAction Stop | Out-Null
    $ctx = Get-AzContext
}
Log "Connected as: $($ctx.Account.Id)" "OK"

$allSubs = Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object { $_.State -eq "Enabled" }
Log "Tenant subscriptions enabled: $($allSubs.Count)"

Banner "Phase 1 - Multi-subscription discovery (per-sub iteration)"
$plan = @()
foreach ($cp in $ProfileMap.Keys) {
    SubBanner "Resolving: $cp"
    $found = $null
    foreach ($s in $allSubs) {
        try { Set-AzContext -SubscriptionId $s.Id -ErrorAction Stop | Out-Null } catch { continue }

        $afdRes = Get-AzResource -Name $cp -ResourceType "Microsoft.Network/frontdoors" -ErrorAction SilentlyContinue
        if ($afdRes) {
            $found = [PSCustomObject]@{ Type="AFD"; Sub=$s.Id; Rg=$afdRes.ResourceGroupName; Id=$afdRes.ResourceId; Sku="" }
            break
        }
        $cdnRes = Get-AzResource -Name $cp -ResourceType "Microsoft.Cdn/profiles" -ErrorAction SilentlyContinue
        if ($cdnRes) {
            $cdnObj = Get-AzCdnProfile -ResourceGroupName $cdnRes.ResourceGroupName -Name $cp -ErrorAction SilentlyContinue
            $cdnSku = if ($cdnObj) { $cdnObj.SkuName } else { "" }
            $found = [PSCustomObject]@{ Type="CDN"; Sub=$s.Id; Rg=$cdnRes.ResourceGroupName; Id=$cdnRes.ResourceId; Sku=$cdnSku }
            break
        }
    }
    if (-not $found) { Log "Profile '$cp' NOT FOUND - SKIP" "WARN"; continue }
    Log "$($found.Type) found  sub=$($found.Sub)  rg=$($found.Rg)$(if ($found.Sku) { "  sku=$($found.Sku)" })" "OK"

    Set-AzContext -SubscriptionId $found.Sub -ErrorAction SilentlyContinue | Out-Null

    $customFEs = @()
    if ($found.Type -eq "AFD") {
        $afdProfile = Get-AzFrontDoor -ResourceGroupName $found.Rg -Name $cp -ErrorAction SilentlyContinue
        if ($afdProfile -and $afdProfile.FrontendEndpoints) {
            foreach ($fe in $afdProfile.FrontendEndpoints) {
                if ($fe.HostName -and $fe.HostName -notlike "*.azurefd.net") {
                    $customFEs += [PSCustomObject]@{ Name = $fe.Name; HostName = $fe.HostName }
                }
            }
        }
    } else {
        $cdnEndpoints = Get-AzCdnEndpoint -ResourceGroupName $found.Rg -ProfileName $cp -ErrorAction SilentlyContinue
        foreach ($ep in $cdnEndpoints) {
            $cds = Get-AzCdnCustomDomain -ResourceGroupName $found.Rg -ProfileName $cp -EndpointName $ep.Name -ErrorAction SilentlyContinue
            foreach ($cd in $cds) {
                if ($cd.HostName -and $cd.HostName -notlike "*.azureedge.net") {
                    $customFEs += [PSCustomObject]@{ Name = $cd.Name; HostName = $cd.HostName }
                }
            }
        }
    }
    Log "$($customFEs.Count) custom domain(s)"
    foreach ($fe in $customFEs) { Log "  $($fe.HostName)" }

    $targetStd = $ProfileMap[$cp]
    $targetExists = $false
    try { $existing = Get-AzFrontDoorCdnProfile -ResourceGroupName $found.Rg -ProfileName $targetStd -ErrorAction Stop; $targetExists = [bool]$existing } catch { $targetExists = $false }
    if ($targetExists) {
        Log "Target Standard '$targetStd' already exists in $($found.Rg)" "WARN"
    } else {
        Log "Target Standard '$targetStd' available in $($found.Rg)" "OK"
    }

    $wafPolicies = @()
    if ($found.Type -eq "AFD") {
        try {
            $allWafs = Get-AzFrontDoorWafPolicy -ResourceGroupName $found.Rg -ErrorAction SilentlyContinue
            foreach ($w in $allWafs) {
                if ($w.Sku -eq "Classic_AzureFrontDoor") { $wafPolicies += $w }
            }
        } catch {}
    }
    Log "$($wafPolicies.Count) Classic WAF policy(ies) in $($found.Rg)"

    $plan += [PSCustomObject]@{
        Classic           = $cp
        ClassicResourceId = $found.Id
        SubscriptionId    = $found.Sub
        ResourceGroup     = $found.Rg
        MigrationType     = $found.Type
        CdnSku            = $found.Sku
        Standard          = $targetStd
        StandardExists    = $targetExists
        CustomDomains     = $customFEs
        WafPolicies       = $wafPolicies
    }
}

if ($plan.Count -eq 0) { Log "No profiles to migrate" "ERR"; exit 1 }

Banner "Phase 2 - Plan"
$plan | ForEach-Object {
    Log "  $($_.Classic) ($($_.MigrationType)) -> $($_.Standard)  in $($_.SubscriptionId)/$($_.ResourceGroup)  WAFs: $($_.WafPolicies.Count)"
}

if ($DiscoveryOnly) { Log "DiscoveryOnly - stopping" "WARN"; exit 0 }

if (-not $NoConfirm) {
    $resp = Read-Host "Type YES to migrate $($plan.Count) profile(s) via Az.Cdn cmdlets"
    if ($resp -ne "YES") { Log "Aborted" "WARN"; exit 0 }
}

Banner "Phase 3 - Per-profile: Test -> Prepare -> Enable migration"

$results = @()
foreach ($p in $plan) {
    SubBanner "$($p.Classic) -> $($p.Standard)  in $($p.SubscriptionId)/$($p.ResourceGroup)"

    $r = [PSCustomObject]@{
        Classic           = $p.Classic
        Standard          = $p.Standard
        MigrationType     = $p.MigrationType
        CdnSku            = $p.CdnSku
        SubscriptionId    = $p.SubscriptionId
        ResourceGroup     = $p.ResourceGroup
        ClassicResourceId = $p.ClassicResourceId
        Status            = "pending"
        Error             = ""
        DnsRecords        = @()
        TestFqdn          = ""
        AllNewEndpoints   = @()
        Decision          = ""
        WatchdogTicks     = @()
        PreCDs            = @($p.CustomDomains | ForEach-Object { $_.HostName })
        PostCDs           = @()
        StartedAt         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CompletedAt       = ""
        TestResult        = ""
    }

    if ($DryRun) {
        $r.Status = "dryrun"
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }

    Set-AzContext -SubscriptionId $p.SubscriptionId -ErrorAction SilentlyContinue | Out-Null

    Log "Step 1 - Test-AzFrontDoorCdnProfileMigration..."
    $testResult = $null
    try {
        $testResult = Test-AzFrontDoorCdnProfileMigration -ResourceGroupName $p.ResourceGroup -ClassicResourceReferenceId $p.ClassicResourceId -ErrorAction Stop
    } catch {
        $errText = $_.Exception.Message
        Log "Test-AzFrontDoorCdnProfileMigration FAILED: $errText" "ERR"
        $r.Status = "test-failed"
        $r.Error  = $errText
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }
    $canMigrate = if ($testResult) { $testResult.CanMigrate } else { $false }
    $r.TestResult = "CanMigrate=$canMigrate DefaultSku=$($testResult.DefaultSku -join ',')"
    Log "Test result: $($r.TestResult)" "OK"

    if (-not $canMigrate) {
        Log "Profile is NOT compatible for migration - SKIP" "ERR"
        $r.Status = "test-incompatible"
        $r.Error  = "Test-AzFrontDoorCdnProfileMigration returned CanMigrate=False"
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }

    $wafMappings = @()
    if ($p.WafPolicies.Count -gt 0) {
        Log "Step 2 - Building WAF mapping objects for $($p.WafPolicies.Count) policy(ies)..."
        foreach ($w in $p.WafPolicies) {
            try {
                $newWafName = "$($w.Name)Std"
                $newWafId = "/subscriptions/$($p.SubscriptionId)/resourcegroups/$($p.ResourceGroup)/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/$newWafName"
                $mapping = New-AzFrontDoorCdnMigrationWebApplicationFirewallMappingObject -MigratedFromId $w.Id -MigratedToId $newWafId -ErrorAction Stop
                $wafMappings += $mapping
                Log "  Mapping: $($w.Name) -> $newWafName" "OK"
            } catch {
                Log "  WAF mapping failed for $($w.Name): $($_.Exception.Message)" "WARN"
            }
        }
    }

    Log "Step 3 - Start-AzFrontDoorCdnProfilePrepareMigration..."
    try {
        if ($wafMappings.Count -gt 0) {
            Start-AzFrontDoorCdnProfilePrepareMigration `
                -ResourceGroupName $p.ResourceGroup `
                -ClassicResourceReferenceId $p.ClassicResourceId `
                -ProfileName $p.Standard `
                -SkuName $Sku `
                -MigrationWebApplicationFirewallMapping $wafMappings `
                -ErrorAction Stop
        } else {
            Start-AzFrontDoorCdnProfilePrepareMigration `
                -ResourceGroupName $p.ResourceGroup `
                -ClassicResourceReferenceId $p.ClassicResourceId `
                -ProfileName $p.Standard `
                -SkuName $Sku `
                -ErrorAction Stop
        }
        Log "Prepare migration succeeded - new Standard profile created (classic still serving)" "OK"
    } catch {
        $errText = $_.Exception.Message
        Log "Start-AzFrontDoorCdnProfilePrepareMigration FAILED: $errText" "ERR"
        $r.Status = "prepare-failed"
        $r.Error  = $errText
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }

    try {
        $newAfdEndpoints = Get-AzFrontDoorCdnEndpoint -ResourceGroupName $p.ResourceGroup -ProfileName $p.Standard -ErrorAction SilentlyContinue
        $stdEndpoints = @()
        foreach ($ep in $newAfdEndpoints) { if ($ep.HostName) { $stdEndpoints += $ep.HostName } }
        if ($stdEndpoints.Count -gt 0) { $r.TestFqdn = $stdEndpoints[0] }
        $r.AllNewEndpoints = $stdEndpoints
        Log "New AFD endpoint(s): $($stdEndpoints -join ', ')" "OK"
    } catch {}

    $decision = "COMMIT"
    if (-not $AutoCommit) {
        Log "Test the new endpoint(s) above. Then decide:"
        $decision = ""
        while ($decision -notin @("COMMIT","ROLLBACK","SKIP")) {
            $decision = (Read-Host "Decision for $($p.Classic) [COMMIT/ROLLBACK/SKIP]").Trim().ToUpper()
        }
    } else {
        Log "AutoCommit=true - proceeding to Enable-AzFrontDoorCdnProfileMigration" "WARN"
    }
    $r.Decision = $decision

    if ($decision -eq "ROLLBACK") {
        Log "Step 4 - Stop-AzFrontDoorCdnProfileMigration (abort)..."
        try {
            Stop-AzFrontDoorCdnProfileMigration -ProfileName $p.Standard -ResourceGroupName $p.ResourceGroup -ErrorAction Stop
            $r.Status = "rolled-back"
            Log "Migration aborted - Classic remains active" "OK"
        } catch {
            $r.Status = "rollback-failed"
            $r.Error  = $_.Exception.Message
            Log "Stop-AzFrontDoorCdnProfileMigration FAILED: $($_.Exception.Message)" "ERR"
        }
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }
    if ($decision -eq "SKIP") {
        $r.Status = "migrated-not-committed"
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }

    Log "Step 5 - Enable-AzFrontDoorCdnProfileMigration (commits, retires Classic)..."
    try {
        Enable-AzFrontDoorCdnProfileMigration -ProfileName $p.Standard -ResourceGroupName $p.ResourceGroup -ErrorAction Stop
        Log "Migrate succeeded - traffic now on new profile" "OK"
    } catch {
        $errText = $_.Exception.Message
        Log "Enable-AzFrontDoorCdnProfileMigration FAILED: $errText" "ERR"
        $r.Status = "enable-failed"
        $r.Error  = $errText
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }

    if (-not $SkipWatchdog -and $r.TestFqdn) {
        SubBanner "Watchdog ($WatchdogSec sec) for $($p.Standard)"
        $deadline = (Get-Date).AddSeconds($WatchdogSec)
        $tick = 0
        while ((Get-Date) -lt $deadline) {
            $tick++
            $code = ""
            $azref = ""
            $tStamp = (Get-Date).ToString("HH:mm:ss")
            try {
                $resp = Invoke-WebRequest -Uri "https://$($r.TestFqdn)/" -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                $code  = $resp.StatusCode
                $azref = $resp.Headers["x-azure-ref"]
            } catch {
                $code = "ERR: $($_.Exception.Message.Substring(0, [Math]::Min(80, $_.Exception.Message.Length)))"
            }
            $tickOk = ("$code" -match '^(2|3)\d\d$')
            $r.WatchdogTicks += [PSCustomObject]@{
                Tick = $tick; Time = $tStamp; Url = "https://$($r.TestFqdn)/"; Code = "$code"
                AzRef = if ($azref) { $azref.Substring(0, [Math]::Min(40, $azref.Length)) } else { "" }
                Healthy = $tickOk
            }
            $msg = "watchdog tick $tick - $($r.TestFqdn) -> $code"
            if ($tickOk) { Log $msg "OK" } else { Log $msg "WARN" }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds $WatchdogIntervalSec
        }
    }

    try {
        $stdCustomDomains = Get-AzFrontDoorCdnCustomDomain -ResourceGroupName $p.ResourceGroup -ProfileName $p.Standard -ErrorAction SilentlyContinue
        $r.PostCDs = @($stdCustomDomains | ForEach-Object { "$($_.HostName) [$($_.DomainValidationState)]" })

        $primaryEp = if ($r.AllNewEndpoints.Count -gt 0) { $r.AllNewEndpoints[0] } else { "<UNKNOWN>" }
        foreach ($classicFE in $p.CustomDomains) {
            $matchStd = $stdCustomDomains | Where-Object { $_.HostName -ieq $classicFE.HostName } | Select-Object -First 1
            if (-not $matchStd) { continue }
            $txt = ""
            if ($matchStd.DomainValidationState -ne "Approved") {
                $txt = $matchStd.ValidationProperties.ValidationToken
            }
            $r.DnsRecords += [PSCustomObject]@{
                Hostname        = $classicFE.HostName
                ValidationState = $matchStd.DomainValidationState
                TxtValue        = $txt
                CnameTarget     = $primaryEp
            }
            Log "  $($classicFE.HostName) -> CNAME $primaryEp (cert: $($matchStd.DomainValidationState))" "OK"
        }
    } catch {
        Log "Could not enumerate post-migration custom domains: $($_.Exception.Message)" "WARN"
    }

    $r.Status = "migrated-and-committed"
    $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $results += $r
    Save-State -Plan $plan -Results $results
}

Banner "Phase 5 - Reports"

$migrated = @($results | Where-Object { $_.Status -eq "migrated-and-committed" })
$rolled   = @($results | Where-Object { $_.Status -in @("rolled-back","rollback-failed") })
$pending  = @($results | Where-Object { $_.Status -eq "migrated-not-committed" })
$failed   = @($results | Where-Object { $_.Status -in @("test-failed","test-incompatible","prepare-failed","enable-failed") })

Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

$rowsHtml = @()
foreach ($r in $migrated) {
    foreach ($d in $r.DnsRecords) {
        $hostShort = $d.Hostname.Split('.')[0]
        $txtPart = if ($d.TxtValue) { "<code>_dnsauth.$hostShort</code> TXT <code>$($d.TxtValue)</code>" } else { "<i>cert pre-validated</i>" }
        $rowsHtml += "<tr><td><b>$($d.Hostname)</b></td><td>$($d.ValidationState)</td><td>$txtPart</td><td><code>$hostShort</code> CNAME <code>$($d.CnameTarget)</code></td><td>$($r.SubscriptionId) / $($r.ResourceGroup)</td></tr>"
    }
}
$rowsJoined = if ($rowsHtml.Count -gt 0) { $rowsHtml -join "`n" } else { "<tr><td colspan='5'>No committed migrations.</td></tr>" }

$dnsHtml = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>PYX FD - DNS handoff</title>
<style>body{font-family:Segoe UI,Arial;max-width:1200px;margin:30px auto;padding:0 24px;color:#11151C}
h1{color:#1F3D7A;border-bottom:2px solid #1F3D7A;padding-bottom:8px}
table{width:100%;border-collapse:collapse;font-size:13px}
th{background:#F5F7FA;padding:10px;text-align:left;border-bottom:2px solid #1F3D7A;color:#1F3D7A}
td{padding:10px;border-bottom:1px solid #E5E8EE}
code{font-family:Consolas,monospace;font-size:12px;background:#F5F7FA;padding:2px 6px;border-radius:3px}
.foot{margin-top:30px;padding-top:12px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px}
</style></head><body>
<h1>PYX Front Door - DNS records to publish</h1>
<p>$($migrated.Count) profile(s) migrated and committed via Az.Cdn PowerShell module.</p>
<table><thead><tr><th>Hostname</th><th>Cert</th><th>TXT</th><th>CNAME</th><th>Sub / RG</th></tr></thead><tbody>
$rowsJoined
</tbody></table>
<div class='foot'>Prepared by Syed Rizvi - PYX Health Production - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</body></html>
"@
Set-Content -Path $dnsHtmlPath -Value $dnsHtml -Encoding ASCII

$summaryRows = ($results | ForEach-Object {
    $color = switch ($_.Status) {
        "migrated-and-committed" {"#1B6B3A"}
        "rolled-back"            {"#B7791F"}
        "migrated-not-committed" {"#1F3D7A"}
        "dryrun"                 {"#555E6D"}
        default                  {"#9B2226"}
    }
    $errCell = if ($_.Error) {
        $safe = if ($_.Error.Length -gt 200) { $_.Error.Substring(0,200) } else { $_.Error }
        "<code>$([System.Web.HttpUtility]::HtmlEncode($safe))</code>"
    } else { "-" }
    "<tr><td><b>$($_.Classic)</b></td><td><code>$($_.MigrationType)</code></td><td><code style='font-size:11px'>$($_.SubscriptionId)</code></td><td><code>$($_.ResourceGroup)</code></td><td><code>$($_.Standard)</code></td><td style='color:$color'><b>$($_.Status)</b></td><td>$errCell</td></tr>"
}) -join "`n"

$summaryHtml = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>PYX migration summary</title>
<style>body{font-family:Segoe UI,Arial;max-width:1200px;margin:30px auto;padding:0 24px;color:#11151C}
h1{color:#1F3D7A;border-bottom:2px solid #1F3D7A;padding-bottom:8px}
table{width:100%;border-collapse:collapse;font-size:13px}
th{background:#F5F7FA;padding:10px;text-align:left;border-bottom:2px solid #1F3D7A;color:#1F3D7A}
td{padding:10px;border-bottom:1px solid #E5E8EE}
code{font-family:Consolas,monospace;font-size:12px;background:#F5F7FA;padding:2px 6px;border-radius:3px}
.foot{margin-top:30px;padding-top:12px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px}
</style></head><body>
<h1>PYX migration summary (Az.Cdn PowerShell module)</h1>
<p>Run: $timestamp &middot; Migrated: $($migrated.Count) &middot; Rolled back: $($rolled.Count) &middot; Pending: $($pending.Count) &middot; Failed: $($failed.Count)</p>
<table><thead><tr><th>Classic</th><th>Type</th><th>Sub</th><th>RG</th><th>New Standard</th><th>Status</th><th>Error</th></tr></thead><tbody>
$summaryRows
</tbody></table>
<div class='foot'>Prepared by Syed Rizvi - PYX Health Production - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</body></html>
"@
Set-Content -Path $summaryPath -Value $summaryHtml -Encoding ASCII

$endTime     = Get-Date
$durationMin = [Math]::Round(($endTime - $startTime).TotalMinutes, 1)

$changeCards = @()
foreach ($r in $results) {
    $statusColor = switch ($r.Status) {
        "migrated-and-committed" {"#1B6B3A"}
        "rolled-back"            {"#B7791F"}
        "migrated-not-committed" {"#1F3D7A"}
        "dryrun"                 {"#555E6D"}
        default                  {"#9B2226"}
    }
    $skuLabel = if ($r.CdnSku) { "$($r.MigrationType) ($($r.CdnSku))" } else { $r.MigrationType }
    $preCdRows = if ($r.PreCDs.Count -gt 0) { ($r.PreCDs | ForEach-Object { "<li><code>$_</code></li>" }) -join "" } else { "<li><i>none</i></li>" }
    $postCdRows = if ($r.PostCDs.Count -gt 0) { ($r.PostCDs | ForEach-Object { "<li><code>$_</code></li>" }) -join "" } else { "<li><i>not captured</i></li>" }

    $watchHtml = ""
    $watchRate = "n/a"
    if ($r.WatchdogTicks.Count -gt 0) {
        $okCount = @($r.WatchdogTicks | Where-Object { $_.Healthy }).Count
        $totalTicks = $r.WatchdogTicks.Count
        $pct = [Math]::Round(($okCount / $totalTicks) * 100, 1)
        $watchRate = "$okCount / $totalTicks ($pct%)"
        $tickRows = ($r.WatchdogTicks | ForEach-Object {
            $tColor = if ($_.Healthy) { "#1B6B3A" } else { "#9B2226" }
            "<tr><td>$($_.Tick)</td><td>$($_.Time)</td><td style='color:$tColor'><b>$($_.Code)</b></td><td><code>$($_.AzRef)</code></td></tr>"
        }) -join "`n"
        $watchHtml = "<h3>Watchdog</h3><p>Health: <b>$watchRate</b></p><table><thead><tr><th>#</th><th>Time</th><th>Code</th><th>x-azure-ref</th></tr></thead><tbody>$tickRows</tbody></table>"
    }
    $endpointsList = if ($r.AllNewEndpoints.Count -gt 0) { ($r.AllNewEndpoints | ForEach-Object { "<li><code>https://$_/</code></li>" }) -join "" } else { "<li><i>none</i></li>" }
    $errBlock = ""
    if ($r.Error) {
        $safeErr = if ($r.Error.Length -gt 600) { $r.Error.Substring(0,600) } else { $r.Error }
        $errBlock = "<h3 style='color:#9B2226'>Error</h3><pre style='background:#FEE;border-left:3px solid #9B2226;padding:10px;font-size:12px;white-space:pre-wrap'>$([System.Web.HttpUtility]::HtmlEncode($safeErr))</pre>"
    }

    $card = @"
<div class='card'>
  <h2>$($r.Classic) -&gt; $($r.Standard)</h2>
  <table class='kv'>
    <tr><td>Source type</td><td><b>$skuLabel</b></td></tr>
    <tr><td>Subscription</td><td><code>$($r.SubscriptionId)</code></td></tr>
    <tr><td>Resource group</td><td><code>$($r.ResourceGroup)</code></td></tr>
    <tr><td>Source resource ID</td><td><code style='font-size:11px'>$($r.ClassicResourceId)</code></td></tr>
    <tr><td>Migration method</td><td>Az.Cdn PowerShell module (Test/Prepare/Enable cmdlets)</td></tr>
    <tr><td>Test result</td><td><code>$($r.TestResult)</code></td></tr>
    <tr><td>Operator decision</td><td><code>$($r.Decision)</code></td></tr>
    <tr><td>Final status</td><td style='color:$statusColor'><b>$($r.Status)</b></td></tr>
    <tr><td>Started</td><td>$($r.StartedAt)</td></tr>
    <tr><td>Completed</td><td>$($r.CompletedAt)</td></tr>
    <tr><td>Watchdog</td><td><b>$watchRate</b></td></tr>
  </table>
  <h3>New AFD endpoints</h3><ul>$endpointsList</ul>
  <h3>Custom domains - before</h3><ul>$preCdRows</ul>
  <h3>Custom domains - after</h3><ul>$postCdRows</ul>
  $watchHtml
  $errBlock
</div>
"@
    $changeCards += $card
}
$cardsJoined = if ($changeCards.Count -gt 0) { $changeCards -join "`n" } else { "<p><i>No profiles processed.</i></p>" }

$changeReportHtml = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>PYX migration change report - $timestamp</title>
<style>
body{font-family:Segoe UI,Arial;max-width:1200px;margin:30px auto;padding:0 24px;color:#11151C;line-height:1.55}
h1{color:#1F3D7A;border-bottom:2px solid #1F3D7A;padding-bottom:8px}
h2{color:#1F3D7A;font-size:18px;margin-top:18px}
h3{color:#1F3D7A;font-size:14px;margin-top:18px;border-bottom:1px solid #E5E8EE;padding-bottom:4px}
table{width:100%;border-collapse:collapse;margin:8px 0;font-size:13px}
table.kv{margin-bottom:14px}
table.kv td:first-child{width:200px;color:#555E6D;font-weight:600}
th{background:#F5F7FA;padding:8px 10px;text-align:left;border-bottom:2px solid #1F3D7A;color:#1F3D7A;font-size:12px}
td{padding:8px 10px;border-bottom:1px solid #E5E8EE;vertical-align:top}
code{font-family:Consolas,monospace;font-size:12px;background:#F5F7FA;padding:2px 6px;border-radius:3px;word-break:break-all}
.card{background:#FFF;border:1px solid #C8CFD9;border-radius:8px;padding:18px 22px;margin:18px 0}
.summary{background:#F5F7FA;border-left:4px solid #1F3D7A;padding:14px 18px}
.foot{margin-top:30px;padding-top:12px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px}
.bigcount{font-size:24px;font-weight:600}
</style></head><body>
<h1>PYX migration change report (Az.Cdn PowerShell module)</h1>
<div class='summary'>
<table class='kv'>
<tr><td>Run timestamp</td><td><code>$timestamp</code></td></tr>
<tr><td>Started</td><td>$($startTime.ToString("yyyy-MM-dd HH:mm:ss"))</td></tr>
<tr><td>Ended</td><td>$($endTime.ToString("yyyy-MM-dd HH:mm:ss"))</td></tr>
<tr><td>Duration</td><td>$durationMin minutes</td></tr>
<tr><td>Subscriptions enumerated</td><td>$($allSubs.Count)</td></tr>
<tr><td>Profiles in scope</td><td>$($results.Count)</td></tr>
<tr><td>Migrated and committed</td><td><span class='bigcount' style='color:#1B6B3A'>$($migrated.Count)</span></td></tr>
<tr><td>Rolled back</td><td><span class='bigcount' style='color:#B7791F'>$($rolled.Count)</span></td></tr>
<tr><td>Pending</td><td><span class='bigcount' style='color:#1F3D7A'>$($pending.Count)</span></td></tr>
<tr><td>Failed</td><td><span class='bigcount' style='color:#9B2226'>$($failed.Count)</span></td></tr>
</table>
</div>
<h2>Per-profile detail</h2>
$cardsJoined
<div class='foot'>Prepared by Syed Rizvi - PYX Health Production - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</body></html>
"@
Set-Content -Path $changePath -Value $changeReportHtml -Encoding ASCII

Banner "DONE"
Log "Migrated: $($migrated.Count)  Rolled back: $($rolled.Count)  Pending: $($pending.Count)  Failed: $($failed.Count)" "OK"
Log "Change report: $changePath"
exit 0
