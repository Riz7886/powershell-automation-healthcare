[CmdletBinding()]
param(
    [hashtable]$ProfileMap = @{
        "pyxiq"        = "pyxiq-std"
        "hipyx"        = "hipyx-std-v2"
        "pyxiq-stage"  = "pyxiq-stage-std"
        "pyxpwa-stage" = "pyxpwa-stage-std"
        "standard"     = "standard-afdstd"
    },
    [hashtable]$PreferredTier = @{
        "standard"     = "Standard"
        "pyxiq-stage"  = "Standard"
        "pyxpwa-stage" = "Standard"
        "pyxiq"        = "Standard"
        "hipyx"        = "Standard"
    },
    [ValidateSet("AutoDetect","Standard","Premium")]
    [string]$TierStrategy        = "AutoDetect",
    [string]$TenantId            = "",
    [string]$SubscriptionId      = "",
    [int]   $WatchdogSec         = 300,
    [int]   $WatchdogIntervalSec = 30,
    [int]   $RetryCount          = 5,
    [int]   $RetryBackoffSec     = 10,
    [switch]$DiscoveryOnly,
    [switch]$DryRun,
    [switch]$AutoCommit,
    [switch]$NoConfirm,
    [switch]$SkipWatchdog,
    [switch]$SkipKeyVaultGrant,
    [switch]$StripManagedRulesToForceStandard,
    [string[]]$OnlyProfiles      = @(),
    [string]$ReportDir           = (Join-Path $env:USERPROFILE "Desktop\pyx-frontdoor-migration"),
    [string]$ResumeFromState     = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "PowerShell 7.2 or newer required. Current: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    Write-Host "Auto-installing PowerShell 7 via winget..." -ForegroundColor Cyan
    $wingetAvailable = $null
    try { $wingetAvailable = Get-Command winget -ErrorAction Stop } catch {}
    if ($wingetAvailable) {
        Start-Process winget -ArgumentList "install","--id","Microsoft.PowerShell","--silent","--accept-source-agreements","--accept-package-agreements" -Wait -NoNewWindow
    } else {
        $msi = Join-Path $env:TEMP "PowerShell-7-x64.msi"
        Invoke-WebRequest -Uri "https://github.com/PowerShell/PowerShell/releases/latest/download/PowerShell-7.4.6-win-x64.msi" -OutFile $msi -UseBasicParsing
        Start-Process msiexec.exe -ArgumentList "/i","$msi","/quiet","/norestart" -Wait
    }
    $pwshExe = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    if (Test-Path $pwshExe) {
        Write-Host "Re-launching script in PowerShell 7..." -ForegroundColor Cyan
        & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @PSBoundParameters
        exit $LASTEXITCODE
    } else {
        Write-Host "PowerShell 7 install failed. Manual install required: https://aka.ms/powershell" -ForegroundColor Red
        exit 1
    }
}

$timestamp   = (Get-Date).ToString("yyyyMMdd-HHmmss")
$startTime   = Get-Date
if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
$snapshotDir = Join-Path $ReportDir "snapshots-$timestamp"
if (-not (Test-Path $snapshotDir)) { New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null }
$logPath     = Join-Path $ReportDir "migration-$timestamp.log"
$dnsHtmlPath = Join-Path $ReportDir "dns-handoff-$timestamp.html"
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
    $state = [PSCustomObject]@{
        timestamp      = $timestamp
        plan           = $Plan
        results        = $Results
        completedAt    = (Get-Date).ToString("o")
        scriptVersion  = "2.0"
    }
    $state | ConvertTo-Json -Depth 12 | Set-Content -Path $statePath -Encoding UTF8
}

function Invoke-WithRetry {
    param([scriptblock]$Code, [string]$Description, [int]$Max = $RetryCount, [int]$Backoff = $RetryBackoffSec)
    for ($i = 1; $i -le $Max; $i++) {
        try {
            return & $Code
        } catch {
            if ($i -eq $Max) {
                Log "$Description failed after $Max attempts: $($_.Exception.Message)" "ERR"
                throw
            }
            $wait = $Backoff * $i
            Log "$Description attempt $i failed: $($_.Exception.Message) -- retrying in ${wait}s" "WARN"
            Start-Sleep -Seconds $wait
        }
    }
}

function Strip-And-Unlink-WafFromClassicAfd {
    param($AfdProfile, $WafPolicies, $SnapshotDir, $WhatIfMode)
    if ($WhatIfMode) {
        Log "  [WHATIF] Would back up $($WafPolicies.Count) Classic WAF(s) to $SnapshotDir" "WARN"
        Log "  [WHATIF] Would unlink WAF policy from each frontend endpoint of $($AfdProfile.Name)" "WARN"
        Log "  [WHATIF] WAF policies remain in resource group, only the AFD link is removed" "WARN"
        return
    }
    foreach ($w in $WafPolicies) {
        $backupPath = Join-Path $SnapshotDir "waf-pre-unlink-$($w.Name).json"
        $w | ConvertTo-Json -Depth 20 | Set-Content -Path $backupPath -Encoding UTF8
        Log "  Backup saved: $backupPath" "OK"
    }
    $rg   = (Get-AzResource -ResourceId $AfdProfile.Id -ErrorAction Stop).ResourceGroupName
    $name = $AfdProfile.Name
    $afd  = Get-AzFrontDoor -ResourceGroupName $rg -Name $name -ErrorAction Stop
    $changed = $false
    foreach ($fe in $afd.FrontendEndpoints) {
        if ($fe.WebApplicationFirewallPolicyLink) {
            Log "  Unlinking WAF from FE: $($fe.Name)" "OK"
            $fe.WebApplicationFirewallPolicyLink = $null
            $changed = $true
        }
    }
    if ($changed) {
        Invoke-WithRetry -Description "Set-AzFrontDoor (unlink WAFs)" -Code {
            Set-AzFrontDoor -InputObject $afd -ErrorAction Stop | Out-Null
        }
        Log "  AFD Classic profile updated (WAF policies unlinked from all FEs)" "OK"
        Start-Sleep -Seconds 5
    } else {
        Log "  No WAF links found on FEs (nothing to unlink)" "WARN"
    }
}

function Test-IsBYOC {
    param($AfdProfile)
    if (-not $AfdProfile -or -not $AfdProfile.FrontendEndpoints) { return $false }
    foreach ($fe in $AfdProfile.FrontendEndpoints) {
        if ($fe.CustomHttpsConfiguration -and $fe.CustomHttpsConfiguration.CertificateSource -eq "AzureKeyVault") { return $true }
        if ($fe.Vault) { return $true }
    }
    return $false
}

function Get-KvIdsFromAfdProfile {
    param($AfdProfile)
    $kvIds = @{}
    if (-not $AfdProfile -or -not $AfdProfile.FrontendEndpoints) { return @() }
    foreach ($fe in $AfdProfile.FrontendEndpoints) {
        if ($fe.CustomHttpsConfiguration -and $fe.CustomHttpsConfiguration.Vault -and $fe.CustomHttpsConfiguration.Vault.Id) {
            $kvIds[$fe.CustomHttpsConfiguration.Vault.Id] = $true
        }
    }
    return @($kvIds.Keys)
}

if ($OnlyProfiles.Count -gt 0) {
    $filtered = @{}
    foreach ($pname in $OnlyProfiles) { if ($ProfileMap.ContainsKey($pname)) { $filtered[$pname] = $ProfileMap[$pname] } }
    $ProfileMap = $filtered
}

Banner "PYX Front Door migration -- Classic to Standard/Premium AFD"
Log "Profiles in scope: $($ProfileMap.Keys -join ', ')"
Log "Tier strategy:     $TierStrategy"
Log "Report directory:  $ReportDir"
Log "PowerShell:        $($PSVersionTable.PSVersion)"

Banner "Phase 0a -- Module install / import"
$requiredModules = @("Az.Accounts","Az.Cdn","Az.FrontDoor","Az.Resources","Az.KeyVault")
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m -ErrorAction SilentlyContinue)) {
        Log "Installing $m (CurrentUser scope)..."
        Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module $m -ErrorAction Stop
    $ver = (Get-Module -Name $m).Version
    Log "$m loaded (v$ver)" "OK"
}

Banner "Phase 0b -- Connect-AzAccount"
$ctx = Get-AzContext -ErrorAction SilentlyContinue
$needConnect = $false
if (-not $ctx) {
    $needConnect = $true
} elseif ($TenantId -and $ctx.Tenant.Id -ne $TenantId) {
    Log "Current tenant $($ctx.Tenant.Id) does not match requested $TenantId -- reconnecting" "WARN"
    $needConnect = $true
}
if ($needConnect) {
    $connectArgs = @{ ErrorAction = "Stop" }
    if ($TenantId)       { $connectArgs["Tenant"]       = $TenantId }
    if ($SubscriptionId) { $connectArgs["Subscription"] = $SubscriptionId }
    Log "Prompting Connect-AzAccount $(if ($TenantId) { "(tenant $TenantId)" })..." "WARN"
    Connect-AzAccount @connectArgs | Out-Null
    $ctx = Get-AzContext
}
Log "Connected as: $($ctx.Account.Id)" "OK"
Log "Tenant:       $($ctx.Tenant.Id)" "OK"
$allSubs = Get-AzSubscription -TenantId $ctx.Tenant.Id -ErrorAction SilentlyContinue | Where-Object { $_.State -eq "Enabled" }
if ($SubscriptionId) { $allSubs = $allSubs | Where-Object { $_.Id -eq $SubscriptionId } }
Log "Subscriptions enabled in tenant: $($allSubs.Count)"

if ($ResumeFromState -and (Test-Path $ResumeFromState)) {
    Banner "Resume mode -- loading state from $ResumeFromState"
    $loaded = Get-Content $ResumeFromState -Raw | ConvertFrom-Json
    $plan    = $loaded.plan
    $results = $loaded.results
    Log "Resumed: $($plan.Count) profiles in plan, $($results.Count) results captured" "OK"
} else {
    Banner "Phase 1 -- Multi-subscription discovery"
    $plan = @()
    foreach ($cp in $ProfileMap.Keys) {
        SubBanner "Resolving: $cp"
        $found = $null
        foreach ($s in $allSubs) {
            try { Set-AzContext -SubscriptionId $s.Id -TenantId $ctx.Tenant.Id -ErrorAction Stop | Out-Null } catch { continue }
            $afdRes = Get-AzResource -Name $cp -ResourceType "Microsoft.Network/frontdoors" -ErrorAction SilentlyContinue
            if ($afdRes) {
                $found = [PSCustomObject]@{ Type="AFD"; Sub=$s.Id; SubName=$s.Name; Rg=$afdRes.ResourceGroupName; Id=$afdRes.ResourceId; CdnSku="" }
                break
            }
            $cdnRes = Get-AzResource -Name $cp -ResourceType "Microsoft.Cdn/profiles" -ErrorAction SilentlyContinue
            if ($cdnRes) {
                $cdnObj = Get-AzCdnProfile -ResourceGroupName $cdnRes.ResourceGroupName -Name $cp -ErrorAction SilentlyContinue
                $cdnSku = if ($cdnObj) { $cdnObj.SkuName } else { "" }
                if ($cdnSku -like "Standard_AzureFrontDoor*" -or $cdnSku -like "Premium_AzureFrontDoor*") {
                    Log "  Skipping '$cp' -- already AFD Standard/Premium tier ($cdnSku)" "WARN"
                    continue
                }
                $found = [PSCustomObject]@{ Type="CDN"; Sub=$s.Id; SubName=$s.Name; Rg=$cdnRes.ResourceGroupName; Id=$cdnRes.ResourceId; CdnSku=$cdnSku }
                break
            }
        }
        if (-not $found) { Log "Profile '$cp' NOT FOUND in any subscription -- SKIP" "WARN"; continue }
        Log "$($found.Type) found: sub=$($found.SubName) rg=$($found.Rg)$(if ($found.CdnSku) { " sku=$($found.CdnSku)" })" "OK"

        Set-AzContext -SubscriptionId $found.Sub -TenantId $ctx.Tenant.Id -ErrorAction SilentlyContinue | Out-Null

        $customFEs   = @()
        $cdnEpNames  = @()
        $isBYOC      = $false
        $kvIds       = @()
        if ($found.Type -eq "AFD") {
            $afdProfile = Get-AzFrontDoor -ResourceGroupName $found.Rg -Name $cp -ErrorAction SilentlyContinue
            if ($afdProfile -and $afdProfile.FrontendEndpoints) {
                foreach ($fe in $afdProfile.FrontendEndpoints) {
                    if ($fe.HostName -and $fe.HostName -notlike "*.azurefd.net") {
                        $customFEs += [PSCustomObject]@{ Name = $fe.Name; HostName = $fe.HostName }
                    }
                }
            }
            $isBYOC = Test-IsBYOC -AfdProfile $afdProfile
            $kvIds  = Get-KvIdsFromAfdProfile -AfdProfile $afdProfile
            if ($isBYOC) { Log "BYOC detected -- $($kvIds.Count) Key Vault reference(s)" "WARN" }
        } else {
            $cdnEndpoints = Get-AzCdnEndpoint -ResourceGroupName $found.Rg -ProfileName $cp -ErrorAction SilentlyContinue
            foreach ($ep in $cdnEndpoints) {
                $cdnEpNames += $ep.Name
                $cds = Get-AzCdnCustomDomain -ResourceGroupName $found.Rg -ProfileName $cp -EndpointName $ep.Name -ErrorAction SilentlyContinue
                foreach ($cd in $cds) {
                    if ($cd.HostName -and $cd.HostName -notlike "*.azureedge.net") {
                        $customFEs += [PSCustomObject]@{ Name = $cd.Name; HostName = $cd.HostName }
                    }
                }
            }
        }
        Log "$($customFEs.Count) custom domain(s):"
        foreach ($fe in $customFEs) { Log "  $($fe.HostName)" }
        if ($cdnEpNames.Count -gt 0) { Log "$($cdnEpNames.Count) CDN endpoint(s): $($cdnEpNames -join ', ')" }

        $wafPolicies = @()
        $hasManagedRules = $false
        if ($found.Type -eq "AFD") {
            try {
                $wafResources = Get-AzResource -ResourceType "Microsoft.Network/frontdoorwebapplicationfirewallpolicies" -ErrorAction SilentlyContinue
                foreach ($wafRes in $wafResources) {
                    try {
                        $w = Get-AzFrontDoorWafPolicy -ResourceGroupName $wafRes.ResourceGroupName -Name $wafRes.Name -ErrorAction Stop
                    } catch { continue }
                    if ($w.Sku -ne "Classic_AzureFrontDoor") { continue }
                    $linkedToThis = $false
                    if ($w.FrontendEndpointLinks) {
                        foreach ($link in $w.FrontendEndpointLinks) {
                            $lid = if ($link.Id) { $link.Id } else { "$link" }
                            if ($lid -match "/frontDoors/$([regex]::Escape($cp))/") { $linkedToThis = $true; break }
                        }
                    }
                    if ($linkedToThis) {
                        $wafPolicies += $w
                        if ($w.ManagedRules -and @($w.ManagedRules.ManagedRuleSets).Count -gt 0) {
                            $hasManagedRules = $true
                        }
                    }
                }
            } catch {
                Log "WAF enumeration error: $($_.Exception.Message)" "WARN"
            }
        }
        Log "$($wafPolicies.Count) Classic WAF policy(ies) linked. Managed rule sets present: $hasManagedRules"
        if ($wafPolicies.Count -gt 0) {
            foreach ($w in $wafPolicies) {
                $managedSetCount = if ($w.ManagedRules -and $w.ManagedRules.ManagedRuleSets) { @($w.ManagedRules.ManagedRuleSets).Count } else { 0 }
                $customRuleCount = if ($w.CustomRules) { @($w.CustomRules).Count } else { 0 }
                Log "  WAF: $($w.Name) (rg=$(($w.Id -split '/')[4])) managed=$managedSetCount custom=$customRuleCount"
            }
        }

        $preferredForThis = $null
        if ($PreferredTier -and $PreferredTier.ContainsKey($cp)) {
            $preferredForThis = $PreferredTier[$cp]
            Log "Preferred tier for this profile: $preferredForThis" "OK"
        }

        $resolvedTier = if ($preferredForThis -eq "Standard") {
            "Standard_AzureFrontDoor"
        } elseif ($preferredForThis -eq "Premium") {
            "Premium_AzureFrontDoor"
        } else {
            switch ($TierStrategy) {
                "Standard" { "Standard_AzureFrontDoor" }
                "Premium"  { "Premium_AzureFrontDoor" }
                default    { if ($hasManagedRules) { "Premium_AzureFrontDoor" } else { "Standard_AzureFrontDoor" } }
            }
        }
        Log "Resolved tier for migration: $resolvedTier" "OK"

        $needsStrip = ($preferredForThis -eq "Standard") -and $hasManagedRules
        if ($needsStrip) {
            if ($StripManagedRulesToForceStandard) {
                Log "  ACTION: $($wafPolicies.Count) Classic WAF(s) have managed rules; will be STRIPPED to enable Standard tier (backup saved)" "WARN"
            } else {
                Log "  WARNING: preferred=Standard but managed WAF rules present. Microsoft will force Premium unless -StripManagedRulesToForceStandard is set" "WARN"
            }
        }

        $targetStd = $ProfileMap[$cp]
        $targetExists = $false
        try { $existing = Get-AzFrontDoorCdnProfile -ResourceGroupName $found.Rg -ProfileName $targetStd -ErrorAction Stop; $targetExists = [bool]$existing } catch { $targetExists = $false }
        if ($targetExists) {
            Log "Target profile '$targetStd' already exists in $($found.Rg) -- will be reused" "WARN"
        }

        $snapshotFile = Join-Path $snapshotDir "$cp-classic-snapshot.json"
        if ($found.Type -eq "AFD") {
            (Get-AzFrontDoor -ResourceGroupName $found.Rg -Name $cp -ErrorAction SilentlyContinue) | ConvertTo-Json -Depth 20 | Set-Content -Path $snapshotFile -Encoding UTF8
        } else {
            (Get-AzCdnProfile -ResourceGroupName $found.Rg -Name $cp -ErrorAction SilentlyContinue) | ConvertTo-Json -Depth 20 | Set-Content -Path $snapshotFile -Encoding UTF8
        }
        Log "Snapshot saved: $snapshotFile" "OK"

        $plan += [PSCustomObject]@{
            Classic           = $cp
            ClassicResourceId = $found.Id
            SubscriptionId    = $found.Sub
            SubscriptionName  = $found.SubName
            ResourceGroup     = $found.Rg
            MigrationType     = $found.Type
            CdnSku            = $found.CdnSku
            CdnEndpoints      = $cdnEpNames
            Standard          = $targetStd
            StandardExists    = $targetExists
            ResolvedTier      = $resolvedTier
            CustomDomains     = $customFEs
            WafPolicies       = $wafPolicies
            HasManagedRules   = $hasManagedRules
            IsBYOC            = $isBYOC
            KeyVaultIds       = $kvIds
        }
    }
    $results = @()
}

if ($plan.Count -eq 0) { Log "No profiles to migrate. Exiting." "ERR"; exit 1 }

Banner "Phase 2 -- Plan summary"
foreach ($p in $plan) {
    $byocFlag = if ($p.IsBYOC) { " BYOC" } else { "" }
    Log "  $($p.Classic) ($($p.MigrationType)) -> $($p.Standard) [$($p.ResolvedTier)] in $($p.SubscriptionName)/$($p.ResourceGroup) -- WAFs: $($p.WafPolicies.Count) (managed: $($p.HasManagedRules))$byocFlag"
}
Save-State -Plan $plan -Results $results

if ($DiscoveryOnly) { Log "DiscoveryOnly mode -- stopping after plan generation" "WARN"; exit 0 }

if (-not $NoConfirm -and -not $DryRun) {
    $resp = Read-Host "Type YES to migrate $($plan.Count) profile(s)"
    if ($resp -ne "YES") { Log "Aborted by operator" "WARN"; exit 0 }
}
if ($DryRun) { Log "DryRun mode -- read-only validation, no migration calls will be made" "WARN" }

Banner "Phase 3 -- Per-profile migration"

foreach ($p in $plan) {
    $existing = $results | Where-Object { $_.Classic -eq $p.Classic } | Select-Object -First 1
    if ($existing -and $existing.Status -in @("migrated-and-committed","rolled-back","skipped")) {
        Log "Profile $($p.Classic) already in terminal state ($($existing.Status)) -- skip" "WARN"
        continue
    }

    SubBanner "$($p.Classic) -> $($p.Standard) [$($p.ResolvedTier)] ($($p.MigrationType)) in $($p.SubscriptionName)/$($p.ResourceGroup)"
    $r = [PSCustomObject]@{
        Classic           = $p.Classic
        Standard          = $p.Standard
        MigrationType     = $p.MigrationType
        ResolvedTier      = $p.ResolvedTier
        SubscriptionId    = $p.SubscriptionId
        SubscriptionName  = $p.SubscriptionName
        ResourceGroup     = $p.ResourceGroup
        ClassicResourceId = $p.ClassicResourceId
        Status            = "in-progress"
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
        WafMappingsCount  = 0
        EndpointMappings  = 0
        IsBYOC            = $p.IsBYOC
        KvGrants          = @()
        PreferredTier     = if ($PreferredTier -and $PreferredTier.ContainsKey($p.Classic)) { $PreferredTier[$p.Classic] } else { "" }
        WafUnlinked       = $false
    }

    Set-AzContext -SubscriptionId $p.SubscriptionId -TenantId $ctx.Tenant.Id -ErrorAction SilentlyContinue | Out-Null

    if ($DryRun) {
        Log "DryRun -- read-only validation only ($($p.MigrationType))"
        $preferredForThis = if ($PreferredTier -and $PreferredTier.ContainsKey($p.Classic)) { $PreferredTier[$p.Classic] } else { $null }
        if ($p.MigrationType -eq "AFD") {
            try {
                $dryTest = Test-AzFrontDoorCdnProfileMigration -ResourceGroupName $p.ResourceGroup -ClassicResourceReferenceId $p.ClassicResourceId -ErrorAction Stop
                $canM = if ($dryTest) { $dryTest.CanMigrate } else { $false }
                $defS = if ($dryTest -and $dryTest.DefaultSku) { $dryTest.DefaultSku } else { "" }
                $r.TestResult = "CanMigrate=$canM DefaultSku=$defS"
                if ($canM) {
                    $mismatchTag = ""
                    if ($preferredForThis -eq "Standard" -and $defS -like "Premium*") {
                        $action = if ($StripManagedRulesToForceStandard) { "WILL UNLINK $($p.WafPolicies.Count) WAF(s) -> migrate Standard" } else { "needs -StripManagedRulesToForceStandard to downgrade" }
                        $mismatchTag = " | preferred=Standard, MS=$defS, action=$action"
                    } elseif ($preferredForThis -and $defS -like "$($preferredForThis)*") {
                        $mismatchTag = " | preferred=$preferredForThis MATCH"
                    }
                    Log "  PASS -- CanMigrate=True DefaultSku=$defS WAFs=$($p.WafPolicies.Count) BYOC=$($p.IsBYOC)$mismatchTag" "OK"
                    $r.Status = "dryrun-passed"
                } else {
                    Log "  FAIL -- CanMigrate=False ($defS)" "ERR"
                    $r.Status = "dryrun-failed"
                    $r.Error = "Test cmdlet returned CanMigrate=False"
                }
            } catch {
                Log "  FAIL -- Test cmdlet error: $($_.Exception.Message)" "ERR"
                $r.Status = "dryrun-failed"
                $r.Error = $_.Exception.Message
            }
        } else {
            try {
                $cdnProfile = Get-AzCdnProfile -ResourceGroupName $p.ResourceGroup -Name $p.Classic -ErrorAction Stop
                $isMigratable = $cdnProfile.SkuName -in @("Standard_Microsoft","Standard_Verizon","Premium_Verizon","Standard_Akamai","Standard_ChinaCdn")
                $r.TestResult = "Sku=$($cdnProfile.SkuName) Migratable=$isMigratable Endpoints=$($p.CdnEndpoints.Count)"
                if ($isMigratable) {
                    Log "  PASS -- CDN classic SKU $($cdnProfile.SkuName) migratable, $($p.CdnEndpoints.Count) endpoint(s)" "OK"
                    $r.Status = "dryrun-passed"
                } else {
                    Log "  FAIL -- SKU $($cdnProfile.SkuName) not eligible for AFD migration" "ERR"
                    $r.Status = "dryrun-failed"
                    $r.Error = "Non-migratable CDN SKU: $($cdnProfile.SkuName)"
                }
            } catch {
                Log "  FAIL -- CDN profile fetch error: $($_.Exception.Message)" "ERR"
                $r.Status = "dryrun-failed"
                $r.Error = $_.Exception.Message
            }
        }
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }

    $skuToUse = $p.ResolvedTier

    if ($p.MigrationType -eq "AFD") {
        $preferredForThis = if ($PreferredTier -and $PreferredTier.ContainsKey($p.Classic)) { $PreferredTier[$p.Classic] } else { $null }
        if ($preferredForThis -eq "Standard" -and $p.HasManagedRules -and $StripManagedRulesToForceStandard) {
            Log "Step 0 -- Pre-migration WAF unlink (preferred=Standard, $($p.WafPolicies.Count) Classic WAF(s) with managed rules attached)"
            try {
                $afdProfileObj = Get-AzFrontDoor -ResourceGroupName $p.ResourceGroup -Name $p.Classic -ErrorAction Stop
                Strip-And-Unlink-WafFromClassicAfd -AfdProfile $afdProfileObj -WafPolicies $p.WafPolicies -SnapshotDir $snapshotDir -WhatIfMode:$false
                $r.WafUnlinked = $true
            } catch {
                Log "WAF unlink failed: $($_.Exception.Message)" "ERR"
                $r.Status = "waf-unlink-failed"; $r.Error = $_.Exception.Message; $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                $results += $r; Save-State -Plan $plan -Results $results; continue
            }
        }

        Log "Step 1 -- Test-AzFrontDoorCdnProfileMigration"
        try {
            $testResult = Invoke-WithRetry -Description "Test-AzFrontDoorCdnProfileMigration" -Code {
                Test-AzFrontDoorCdnProfileMigration -ResourceGroupName $p.ResourceGroup -ClassicResourceReferenceId $p.ClassicResourceId -ErrorAction Stop
            }
        } catch {
            $r.Status = "test-failed"; $r.Error = $_.Exception.Message; $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $results += $r; Save-State -Plan $plan -Results $results; continue
        }
        $canMigrate = if ($testResult) { $testResult.CanMigrate } else { $false }
        $defaultSku = if ($testResult.DefaultSku) { $testResult.DefaultSku } else { "" }
        $r.TestResult = "CanMigrate=$canMigrate DefaultSku=$defaultSku"
        Log "Test result: $($r.TestResult)" "OK"

        if (-not $canMigrate) {
            Log "Profile NOT compatible -- SKIP" "ERR"
            $r.Status = "test-incompatible"; $r.Error = "Test returned CanMigrate=False (DefaultSku: $defaultSku)"
            $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $results += $r; Save-State -Plan $plan -Results $results; continue
        }

        if ($defaultSku) {
            $skuToUse = $defaultSku
            if ($defaultSku -ne $p.ResolvedTier) {
                Log "Microsoft DefaultSku ($defaultSku) overrides resolved tier ($($p.ResolvedTier))" "WARN"
            }
        }
        Log "Using SKU: $skuToUse"

        $wafMappings = @()
        if ($p.WafPolicies.Count -gt 0) {
            Log "Step 2 -- Pre-creating new $skuToUse-tier WAF policies"
            foreach ($w in $p.WafPolicies) {
                try {
                    $suffix = if ($skuToUse -like "Premium*") { "Prem" } else { "Std" }
                    $newWafName = "$($w.Name)$suffix"
                    $existingNew = Get-AzFrontDoorWafPolicy -ResourceGroupName $p.ResourceGroup -Name $newWafName -ErrorAction SilentlyContinue
                    if ($existingNew -and $existingNew.Sku -ne $skuToUse) {
                        Log "  WAF '$newWafName' wrong SKU ($($existingNew.Sku) vs $skuToUse) -- recreate" "WARN"
                        Remove-AzFrontDoorWafPolicy -ResourceGroupName $p.ResourceGroup -Name $newWafName -ErrorAction SilentlyContinue | Out-Null
                        $existingNew = $null
                    }
                    if ($existingNew) {
                        Log "  Reusing $newWafName ($skuToUse)" "OK"
                        $newWafId = $existingNew.Id
                    } else {
                        $newWaf = Invoke-WithRetry -Description "New-AzFrontDoorWafPolicy $newWafName" -Code {
                            New-AzFrontDoorWafPolicy -Name $newWafName -ResourceGroupName $p.ResourceGroup -Sku $skuToUse -EnabledState "Enabled" -Mode "Detection" -ErrorAction Stop
                        }
                        $newWafId = $newWaf.Id
                        Log "  Created $newWafName" "OK"
                    }
                    $mapping = New-AzFrontDoorCdnMigrationWebApplicationFirewallMappingObject -MigratedFromId $w.Id -MigratedToId $newWafId -ErrorAction Stop
                    $wafMappings += $mapping
                    Log "  Mapping: $($w.Name) -> $newWafName" "OK"
                } catch {
                    Log "  WAF setup failed for $($w.Name): $($_.Exception.Message)" "WARN"
                }
            }
        }
        $r.WafMappingsCount = $wafMappings.Count

        Log "Step 3 -- Start-AzFrontDoorCdnProfilePrepareMigration with $skuToUse$(if ($p.IsBYOC) { ' (BYOC + SystemAssigned identity)' })"
        try {
            $prepParams = @{
                ResourceGroupName          = $p.ResourceGroup
                ClassicResourceReferenceId = $p.ClassicResourceId
                ProfileName                = $p.Standard
                SkuName                    = $skuToUse
                ErrorAction                = "Stop"
            }
            if ($wafMappings.Count -gt 0) { $prepParams["MigrationWebApplicationFirewallMapping"] = $wafMappings }
            if ($p.IsBYOC) { $prepParams["IdentityType"] = "SystemAssigned" }
            Invoke-WithRetry -Description "Start-AzFrontDoorCdnProfilePrepareMigration" -Code {
                Start-AzFrontDoorCdnProfilePrepareMigration @prepParams
            } | Out-Null
            Log "Prepare migration succeeded -- Classic still serving traffic" "OK"
        } catch {
            $r.Status = "prepare-failed"; $r.Error = $_.Exception.Message; $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $results += $r; Save-State -Plan $plan -Results $results; continue
        }
    } else {
        Log "Step 1 -- Move-AzCdnProfileToAFD (CDN classic prepare) with $skuToUse$(if ($p.IsBYOC) { ' (BYOC + SystemAssigned identity)' })"
        $epMappings = @()
        foreach ($epName in $p.CdnEndpoints) {
            try {
                $newEpName = "$epName-afd"
                $oldHost   = "$epName.azureedge.net"
                $map = New-AzCdnMigrationEndpointMappingObject -MigratedFrom $oldHost -MigratedTo $newEpName -ErrorAction Stop
                $epMappings += $map
                Log "  Endpoint mapping: $oldHost -> $newEpName" "OK"
            } catch {
                Log "  Endpoint mapping failed for ${epName}: $($_.Exception.Message)" "WARN"
            }
        }
        $r.EndpointMappings = $epMappings.Count

        try {
            $moveParams = @{
                ProfileName       = $p.Classic
                ResourceGroupName = $p.ResourceGroup
                SkuName           = $skuToUse
                ErrorAction       = "Stop"
            }
            if ($epMappings.Count -gt 0) { $moveParams["MigrationEndpointMapping"] = $epMappings }
            if ($p.IsBYOC) { $moveParams["IdentityType"] = "SystemAssigned" }
            Invoke-WithRetry -Description "Move-AzCdnProfileToAFD" -Code {
                Move-AzCdnProfileToAFD @moveParams
            } | Out-Null
            Log "CDN prepare migration succeeded -- Classic still serving traffic" "OK"
        } catch {
            $r.Status = "prepare-failed"; $r.Error = $_.Exception.Message; $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $results += $r; Save-State -Plan $plan -Results $results; continue
        }
    }

    $newProfileName = if ($p.MigrationType -eq "AFD") { $p.Standard } else { $p.Classic }

    try {
        $newAfdEndpoints = Get-AzFrontDoorCdnEndpoint -ResourceGroupName $p.ResourceGroup -ProfileName $newProfileName -ErrorAction SilentlyContinue
        $stdEndpoints = @()
        foreach ($ep in $newAfdEndpoints) { if ($ep.HostName) { $stdEndpoints += $ep.HostName } }
        if ($stdEndpoints.Count -gt 0) { $r.TestFqdn = $stdEndpoints[0] }
        $r.AllNewEndpoints = $stdEndpoints
        Log "New AFD endpoint(s): $($stdEndpoints -join ', ')" "OK"
    } catch {}

    if ($p.IsBYOC -and -not $SkipKeyVaultGrant -and $p.KeyVaultIds.Count -gt 0) {
        Log "Step KV -- Granting new profile managed identity access to Key Vault(s)"
        try {
            $newProfile = Get-AzFrontDoorCdnProfile -ResourceGroupName $p.ResourceGroup -ProfileName $newProfileName -ErrorAction Stop
            $miPrincipalId = $newProfile.IdentityPrincipalId
            if (-not $miPrincipalId) {
                Log "  Managed identity principal ID not yet available -- skipping KV grant (run Grant phase manually)" "WARN"
            } else {
                Log "  Profile managed identity: $miPrincipalId"
                foreach ($kvId in $p.KeyVaultIds) {
                    try {
                        $kvParts = $kvId -split "/"
                        $kvSubId = $kvParts[2]
                        $kvRg    = $kvParts[4]
                        $kvName  = $kvParts[-1]
                        Set-AzContext -SubscriptionId $kvSubId -TenantId $ctx.Tenant.Id -ErrorAction SilentlyContinue | Out-Null
                        $kv = Get-AzKeyVault -ResourceGroupName $kvRg -VaultName $kvName -ErrorAction Stop
                        if ($kv.EnableRbacAuthorization) {
                            New-AzRoleAssignment -ObjectId $miPrincipalId -RoleDefinitionName "Key Vault Secrets User" -Scope $kvId -ErrorAction SilentlyContinue | Out-Null
                            New-AzRoleAssignment -ObjectId $miPrincipalId -RoleDefinitionName "Key Vault Certificate User" -Scope $kvId -ErrorAction SilentlyContinue | Out-Null
                            Log "    RBAC roles granted on $kvName" "OK"
                        } else {
                            Set-AzKeyVaultAccessPolicy -VaultName $kvName -ResourceGroupName $kvRg -ObjectId $miPrincipalId -PermissionsToSecrets get,list -PermissionsToCertificates get,list -ErrorAction Stop
                            Log "    Access policy set on $kvName" "OK"
                        }
                        $r.KvGrants += "$kvName ($($kv.ResourceId))"
                    } catch {
                        Log "    KV grant failed for $kvId : $($_.Exception.Message)" "WARN"
                    }
                }
                Set-AzContext -SubscriptionId $p.SubscriptionId -TenantId $ctx.Tenant.Id -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {
            Log "  KV grant phase error: $($_.Exception.Message)" "WARN"
        }
    }

    $decision = "COMMIT"
    if (-not $AutoCommit) {
        Log "New endpoint above. Test it now if desired before commit (Classic is still live)."
        $decision = ""
        while ($decision -notin @("COMMIT","ROLLBACK","SKIP")) {
            $decision = (Read-Host "Decision for $($p.Classic) [COMMIT/ROLLBACK/SKIP]").Trim().ToUpper()
        }
    } else {
        Log "AutoCommit enabled -- committing" "WARN"
    }
    $r.Decision = $decision

    if ($decision -eq "ROLLBACK") {
        Log "Step ROLLBACK -- Stop-AzFrontDoorCdnProfileMigration"
        try {
            Stop-AzFrontDoorCdnProfileMigration -ProfileName $newProfileName -ResourceGroupName $p.ResourceGroup -ErrorAction Stop
            $r.Status = "rolled-back"
            Log "Migration aborted -- Classic remains active" "OK"
        } catch {
            $r.Status = "rollback-failed"; $r.Error = $_.Exception.Message
            Log "Rollback FAILED: $($_.Exception.Message)" "ERR"
        }
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r; Save-State -Plan $plan -Results $results; continue
    }
    if ($decision -eq "SKIP") {
        $r.Status = "migrated-not-committed"
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r; Save-State -Plan $plan -Results $results; continue
    }

    Log "Step COMMIT -- Enable-AzFrontDoorCdnProfileMigration (retires Classic)"
    try {
        Invoke-WithRetry -Description "Enable-AzFrontDoorCdnProfileMigration" -Code {
            Enable-AzFrontDoorCdnProfileMigration -ProfileName $newProfileName -ResourceGroupName $p.ResourceGroup -ErrorAction Stop
        } | Out-Null
        Log "Commit succeeded -- traffic now on new Standard/Premium profile" "OK"
    } catch {
        $r.Status = "enable-failed"; $r.Error = $_.Exception.Message; $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r; Save-State -Plan $plan -Results $results; continue
    }

    if (-not $SkipWatchdog -and $r.TestFqdn) {
        SubBanner "Watchdog ($WatchdogSec sec) for $($r.TestFqdn)"
        $deadline = (Get-Date).AddSeconds($WatchdogSec)
        $tick = 0
        while ((Get-Date) -lt $deadline) {
            $tick++
            $code = ""; $azref = ""
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
            $msg = "watchdog tick $tick -- $($r.TestFqdn) -> $code"
            if ($tickOk) { Log $msg "OK" } else { Log $msg "WARN" }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds $WatchdogIntervalSec
        }
    }

    try {
        $stdCustomDomains = Get-AzFrontDoorCdnCustomDomain -ResourceGroupName $p.ResourceGroup -ProfileName $newProfileName -ErrorAction SilentlyContinue
        $r.PostCDs = @($stdCustomDomains | ForEach-Object { "$($_.HostName) [$($_.DomainValidationState)]" })
        $primaryEp = if ($r.AllNewEndpoints.Count -gt 0) { $r.AllNewEndpoints[0] } else { "<UNKNOWN>" }
        foreach ($classicFE in $p.CustomDomains) {
            $matchStd = $stdCustomDomains | Where-Object { $_.HostName -ieq $classicFE.HostName } | Select-Object -First 1
            if (-not $matchStd) { continue }
            $txt = if ($matchStd.DomainValidationState -ne "Approved" -and $matchStd.ValidationProperties) { $matchStd.ValidationProperties.ValidationToken } else { "" }
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

Banner "Phase 4 -- Reports"

$migrated   = @($results | Where-Object { $_.Status -eq "migrated-and-committed" })
$rolled     = @($results | Where-Object { $_.Status -in @("rolled-back","rollback-failed") })
$pending    = @($results | Where-Object { $_.Status -eq "migrated-not-committed" })
$failed     = @($results | Where-Object { $_.Status -in @("test-failed","test-incompatible","prepare-failed","enable-failed","dryrun-failed") })
$dryPassed  = @($results | Where-Object { $_.Status -eq "dryrun-passed" })

if ($DryRun) {
    Banner "DryRun results"
    Log "Profiles tested: $($results.Count)"
    Log "PASS:            $($dryPassed.Count)" "OK"
    Log "FAIL:            $($failed.Count)" $(if ($failed.Count -gt 0) { "ERR" } else { "OK" })
    foreach ($r in $results) {
        $tag = if ($r.Status -eq "dryrun-passed") { "PASS" } else { "FAIL" }
        $level = if ($r.Status -eq "dryrun-passed") { "OK" } else { "ERR" }
        Log "  [$tag] $($r.Classic) ($($r.MigrationType)) -> $($r.Standard) -- $($r.TestResult)" $level
    }
}

Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

$dnsRows = @()
foreach ($r in $migrated) {
    foreach ($d in $r.DnsRecords) {
        $hostShort = $d.Hostname.Split('.')[0]
        $txtPart = if ($d.TxtValue) { "<code>_dnsauth.$hostShort</code> TXT <code>$($d.TxtValue)</code>" } else { "<i>cert pre-validated</i>" }
        $dnsRows += "<tr><td><b>$($d.Hostname)</b></td><td>$($d.ValidationState)</td><td>$txtPart</td><td><code>$hostShort</code> CNAME <code>$($d.CnameTarget)</code></td><td>$($r.SubscriptionName) / $($r.ResourceGroup)</td></tr>"
    }
}
$dnsRowsJoined = if ($dnsRows.Count -gt 0) { $dnsRows -join "`n" } else { "<tr><td colspan='5'><i>No DNS records pending -- all migrations complete or none committed.</i></td></tr>" }

$dnsHtml = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>PYX Front Door -- DNS handoff</title>
<style>body{font-family:'Segoe UI',Arial,sans-serif;max-width:1200px;margin:30px auto;padding:0 24px;color:#11151C;line-height:1.55}
h1{color:#1F3D7A;border-bottom:3px solid #1F3D7A;padding-bottom:10px;font-size:24px}
h2{color:#1F3D7A;font-size:17px;margin-top:24px}
table{width:100%;border-collapse:collapse;margin:14px 0;font-size:13px}
th{background:#F5F7FA;padding:10px;text-align:left;border-bottom:2px solid #1F3D7A;color:#1F3D7A}
td{padding:10px;border-bottom:1px solid #E5E8EE;vertical-align:top}
code{font-family:Consolas,monospace;font-size:12px;background:#F5F7FA;padding:2px 6px;border-radius:3px;word-break:break-all}
.note{background:#FFF8E1;border-left:4px solid #B7791F;padding:12px 16px;margin:14px 0;font-size:13px}
.foot{margin-top:36px;padding-top:12px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px;text-align:center}
</style></head><body>
<h1>PYX Front Door -- DNS records to publish</h1>
<p>$($migrated.Count) profile(s) committed. Publish the records below in DNS in this order per domain.</p>
<div class='note'><b>Order of operations per domain:</b>
<ol><li>Publish TXT record (validates the AFD-managed certificate)</li>
<li>Wait for cert validation state to become <i>Approved</i> in Azure portal (5-30 min)</li>
<li>Publish CNAME record (cuts traffic to the new endpoint)</li>
<li>TTL 300 seconds for fast rollback if needed</li></ol></div>
<table><thead><tr><th>Hostname</th><th>Cert state</th><th>TXT record</th><th>CNAME record</th><th>Subscription / RG</th></tr></thead>
<tbody>$dnsRowsJoined</tbody></table>
<div class='foot'>Prepared by Syed Rizvi</div>
</body></html>
"@
Set-Content -Path $dnsHtmlPath -Value $dnsHtml -Encoding UTF8

$summaryRows = ($results | ForEach-Object {
    $color = switch ($_.Status) {
        "migrated-and-committed" {"#1B6B3A"}
        "rolled-back"            {"#B7791F"}
        "migrated-not-committed" {"#1F3D7A"}
        "dryrun-passed"          {"#1B6B3A"}
        "dryrun-failed"          {"#9B2226"}
        default                  {"#9B2226"}
    }
    $errCell = if ($_.Error) {
        $safe = if ($_.Error.Length -gt 200) { $_.Error.Substring(0,200) } else { $_.Error }
        "<code>$([System.Web.HttpUtility]::HtmlEncode($safe))</code>"
    } else { "-" }
    "<tr><td><b>$($_.Classic)</b></td><td><code>$($_.MigrationType)</code></td><td><code>$($_.ResolvedTier)</code></td><td><code>$($_.SubscriptionName)</code></td><td><code>$($_.ResourceGroup)</code></td><td><code>$($_.Standard)</code></td><td style='color:$color'><b>$($_.Status)</b></td><td>$errCell</td></tr>"
}) -join "`n"

$endTime     = Get-Date
$durationMin = [Math]::Round(($endTime - $startTime).TotalMinutes, 1)

$changeCards = @()
foreach ($r in $results) {
    $statusColor = switch ($r.Status) {
        "migrated-and-committed" {"#1B6B3A"}
        "rolled-back"            {"#B7791F"}
        "migrated-not-committed" {"#1F3D7A"}
        "dryrun-passed"          {"#1B6B3A"}
        "dryrun-failed"          {"#9B2226"}
        default                  {"#9B2226"}
    }
    $preCdRows = if ($r.PreCDs.Count -gt 0) { ($r.PreCDs | ForEach-Object { "<li><code>$_</code></li>" }) -join "" } else { "<li><i>none</i></li>" }
    $postCdRows = if ($r.PostCDs.Count -gt 0) { ($r.PostCDs | ForEach-Object { "<li><code>$_</code></li>" }) -join "" } else { "<li><i>not captured</i></li>" }
    $kvRows = if ($r.KvGrants.Count -gt 0) { ($r.KvGrants | ForEach-Object { "<li><code>$_</code></li>" }) -join "" } else { "<li><i>n/a (managed cert)</i></li>" }
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
        $watchHtml = "<h3>Watchdog</h3><p>Health: <b>$watchRate</b></p><table><thead><tr><th>#</th><th>Time</th><th>Status</th><th>x-azure-ref</th></tr></thead><tbody>$tickRows</tbody></table>"
    }
    $endpointsList = if ($r.AllNewEndpoints.Count -gt 0) { ($r.AllNewEndpoints | ForEach-Object { "<li><code>https://$_/</code></li>" }) -join "" } else { "<li><i>none</i></li>" }
    $errBlock = ""
    if ($r.Error) {
        $safeErr = if ($r.Error.Length -gt 600) { $r.Error.Substring(0,600) } else { $r.Error }
        $errBlock = "<h3 style='color:#9B2226'>Error</h3><pre style='background:#FEE;border-left:3px solid #9B2226;padding:10px;font-size:12px;white-space:pre-wrap'>$([System.Web.HttpUtility]::HtmlEncode($safeErr))</pre>"
    }
    $byocRow = if ($r.IsBYOC) { "<tr><td>BYOC certificate</td><td><b>Yes</b> &mdash; managed identity granted to KV</td></tr>" } else { "<tr><td>BYOC certificate</td><td>No (managed cert)</td></tr>" }
    $epRow   = if ($r.MigrationType -eq "CDN") { "<tr><td>CDN endpoint mappings</td><td><b>$($r.EndpointMappings)</b></td></tr>" } else { "" }
    $changeCards += @"
<div class='card'>
  <h2>$($r.Classic) -&gt; $($r.Standard) [$($r.ResolvedTier)]</h2>
  <table class='kv'>
    <tr><td>Source type</td><td><b>$($r.MigrationType)</b></td></tr>
    <tr><td>Subscription</td><td><code>$($r.SubscriptionName)</code></td></tr>
    <tr><td>Resource group</td><td><code>$($r.ResourceGroup)</code></td></tr>
    <tr><td>Source resource ID</td><td><code style='font-size:11px'>$($r.ClassicResourceId)</code></td></tr>
    <tr><td>Test result</td><td><code>$($r.TestResult)</code></td></tr>
    <tr><td>WAF mappings</td><td><b>$($r.WafMappingsCount)</b></td></tr>
    $epRow
    $byocRow
    <tr><td>Operator decision</td><td><code>$($r.Decision)</code></td></tr>
    <tr><td>Final status</td><td style='color:$statusColor'><b>$($r.Status)</b></td></tr>
    <tr><td>Started</td><td>$($r.StartedAt)</td></tr>
    <tr><td>Completed</td><td>$($r.CompletedAt)</td></tr>
    <tr><td>Watchdog health</td><td><b>$watchRate</b></td></tr>
  </table>
  <h3>New AFD endpoints</h3><ul>$endpointsList</ul>
  <h3>Custom domains - before</h3><ul>$preCdRows</ul>
  <h3>Custom domains - after</h3><ul>$postCdRows</ul>
  <h3>Key Vault grants</h3><ul>$kvRows</ul>
  $watchHtml
  $errBlock
</div>
"@
}
$cardsJoined = if ($changeCards.Count -gt 0) { $changeCards -join "`n" } else { "<p><i>No profiles processed.</i></p>" }

$changeReportHtml = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>PYX Front Door migration -- change report</title>
<style>body{font-family:'Segoe UI',Arial,sans-serif;max-width:1200px;margin:30px auto;padding:0 24px;color:#11151C;line-height:1.55}
h1{color:#1F3D7A;border-bottom:3px solid #1F3D7A;padding-bottom:10px;font-size:26px}
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
.foot{margin-top:36px;padding-top:12px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px;text-align:center}
.bigcount{font-size:24px;font-weight:600}
</style></head><body>
<h1>PYX Front Door migration -- change report</h1>
<div class='summary'>
<table class='kv'>
<tr><td>Started</td><td>$($startTime.ToString("yyyy-MM-dd HH:mm:ss"))</td></tr>
<tr><td>Ended</td><td>$($endTime.ToString("yyyy-MM-dd HH:mm:ss"))</td></tr>
<tr><td>Duration</td><td>$durationMin minutes</td></tr>
<tr><td>Subscriptions enumerated</td><td>$($allSubs.Count)</td></tr>
<tr><td>Profiles in scope</td><td>$($results.Count)</td></tr>
<tr><td>Migrated and committed</td><td><span class='bigcount' style='color:#1B6B3A'>$($migrated.Count)</span></td></tr>
<tr><td>Rolled back</td><td><span class='bigcount' style='color:#B7791F'>$($rolled.Count)</span></td></tr>
<tr><td>Pending commit</td><td><span class='bigcount' style='color:#1F3D7A'>$($pending.Count)</span></td></tr>
<tr><td>Failed</td><td><span class='bigcount' style='color:#9B2226'>$($failed.Count)</span></td></tr>
</table>
</div>
<h2>Per-profile detail</h2>
$cardsJoined
<div class='foot'>Prepared by Syed Rizvi</div>
</body></html>
"@
Set-Content -Path $changePath -Value $changeReportHtml -Encoding UTF8

$summaryHtml = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>PYX Front Door migration -- summary</title>
<style>body{font-family:'Segoe UI',Arial,sans-serif;max-width:1200px;margin:30px auto;padding:0 24px;color:#11151C}
h1{color:#1F3D7A;border-bottom:3px solid #1F3D7A;padding-bottom:10px;font-size:24px}
table{width:100%;border-collapse:collapse;font-size:13px}
th{background:#F5F7FA;padding:10px;text-align:left;border-bottom:2px solid #1F3D7A;color:#1F3D7A}
td{padding:10px;border-bottom:1px solid #E5E8EE}
code{font-family:Consolas,monospace;font-size:12px;background:#F5F7FA;padding:2px 6px;border-radius:3px}
.foot{margin-top:30px;padding-top:12px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px;text-align:center}
</style></head><body>
<h1>PYX Front Door migration -- summary</h1>
<p>Migrated: $($migrated.Count) &middot; Rolled back: $($rolled.Count) &middot; Pending commit: $($pending.Count) &middot; Failed: $($failed.Count)</p>
<table><thead><tr><th>Classic</th><th>Type</th><th>Tier</th><th>Sub</th><th>RG</th><th>New profile</th><th>Status</th><th>Error</th></tr></thead>
<tbody>$summaryRows</tbody></table>
<div class='foot'>Prepared by Syed Rizvi</div>
</body></html>
"@
Set-Content -Path $summaryPath -Value $summaryHtml -Encoding UTF8

Banner "DONE"
Log "Migrated and committed: $($migrated.Count)" "OK"
Log "Rolled back:            $($rolled.Count)"
Log "Pending commit:         $($pending.Count)"
Log "Failed:                 $($failed.Count)"
Log ""
Log "Reports generated:"
Log "  Change report:        $changePath"
Log "  DNS handoff:          $dnsHtmlPath"
Log "  Operations summary:   $summaryPath"
Log "  State checkpoint:     $statePath"
Log "  Pre-migration snaps:  $snapshotDir"
Log "  Run log:              $logPath"
exit 0
