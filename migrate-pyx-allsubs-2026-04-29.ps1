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
    [int]   $PostMigrateWaitSec  = 60,
    [int]   $CommitWaitSec       = 30,
    [int]   $WatchdogSec         = 300,
    [int]   $WatchdogIntervalSec = 30,
    [switch]$DryRun,
    [switch]$DiscoveryOnly,
    [switch]$NoConfirm,
    [switch]$AutoCommit,
    [switch]$SkipWatchdog,
    [string[]]$OnlyProfiles      = @(),
    [string]$Rollback            = "",
    [string]$ReportDir           = (Join-Path $env:USERPROFILE "Desktop\pyx-atomic-migrate-report")
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"
$timestamp   = (Get-Date).ToString("yyyyMMdd-HHmmss")
$startTime   = Get-Date
if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
$snapshotDir = Join-Path $ReportDir "snapshots-$timestamp"
if (-not (Test-Path $snapshotDir)) { New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null }
$logPath     = Join-Path $ReportDir "atomic-migrate-$timestamp.log"
$dnsHtmlPath = Join-Path $ReportDir "dns-handoff-all-$timestamp.html"
$summaryPath = Join-Path $ReportDir "summary-$timestamp.html"
$changePath  = Join-Path $ReportDir "change-report-$timestamp.html"
$statePath   = Join-Path $ReportDir "state-$timestamp.json"

function Log {
    param([string]$Message, [string]$Level = "INFO")
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line  = "[$stamp] [$Level] $Message"
    Add-Content -Path $logPath -Value $line
    $color = switch ($Level) { "OK" {"Green"} "WARN" {"Yellow"} "ERR" {"Red"} "STEP" {"Cyan"} "GATE" {"Magenta"} default {"White"} }
    Write-Host $line -ForegroundColor $color
}
function Banner($t)    { Log ""; Log ("=" * 78); Log $t "STEP"; Log ("=" * 78) }
function SubBanner($t) { Log ""; Log ("-" * 78); Log $t "STEP"; Log ("-" * 78) }

function Save-State {
    param($Plan, $Results)
    $state = [PSCustomObject]@{
        timestamp = $timestamp
        plan      = $Plan
        results   = $Results
    }
    $state | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath -Encoding ASCII
}

function Invoke-Rollback {
    param([string]$ClassicName, [string]$StandardName, [string]$Sub, [string]$Rg)
    SubBanner "ROLLBACK $ClassicName  ->  delete uncommitted Standard $StandardName"
    $stdId = az afd profile show --subscription $Sub -g $Rg --profile-name $StandardName --query id -o tsv 2>$null
    if (-not $stdId) {
        Log "Standard '$StandardName' not found in $Sub/$Rg - nothing to roll back" "WARN"
        return $true
    }
    $state = az afd profile show --subscription $Sub -g $Rg --profile-name $StandardName --query "extendedProperties.migrationState" -o tsv 2>$null
    Log "Current Standard state: $state"
    if ($state -eq "Committed") {
        Log "Standard '$StandardName' is already COMMITTED - rollback NOT possible at this point" "ERR"
        return $false
    }
    Log "Deleting uncommitted Standard '$StandardName' (Classic '$ClassicName' is unaffected)..."
    az afd profile delete --subscription $Sub --resource-group $Rg --profile-name $StandardName --yes --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Log "Rollback complete - Classic '$ClassicName' resumes serving" "OK"
        return $true
    } else {
        Log "Rollback delete failed - inspect Azure portal" "ERR"
        return $false
    }
}

if ($OnlyProfiles.Count -gt 0) {
    $filtered = @{}
    foreach ($p in $OnlyProfiles) { if ($ProfileMap.ContainsKey($p)) { $filtered[$p] = $ProfileMap[$p] } }
    $ProfileMap = $filtered
}

Banner "PYX atomic migration  -  AFD Classic + CDN Classic  ->  AFD Standard  -  ALL SUBSCRIPTIONS"
Log "Profiles in scope:      $($ProfileMap.Keys -join ', ')"
Log "Target Standard SKU:    $Sku"
Log "Post-migrate wait:      $PostMigrateWaitSec sec"
Log "Commit wait:            $CommitWaitSec sec"
Log "Watchdog window:        $WatchdogSec sec (interval $WatchdogIntervalSec sec)"
Log "DryRun:                 $DryRun"
Log "DiscoveryOnly:          $DiscoveryOnly"
Log "NoConfirm:              $NoConfirm"
Log "AutoCommit:             $AutoCommit"
Log "SkipWatchdog:           $SkipWatchdog"
Log "Rollback target:        $(if ($Rollback) { $Rollback } else { '<none>' })"
Log "Report dir:             $ReportDir"
Log "Snapshot dir:           $snapshotDir"

Banner "Phase 0 - Pre-flight"
$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $acct) { Log "az login..." "WARN"; az login --only-show-errors | Out-Null }
$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $acct) { Log "Could not establish Azure session - aborting" "ERR"; exit 10 }
Log "Signed in as $($acct.user.name)" "OK"

$installed = az extension list --query "[?name=='front-door'].name" -o tsv 2>$null
if (-not $installed) { az extension add --name front-door --only-show-errors | Out-Null }
az extension update --name front-door --only-show-errors 2>$null | Out-Null
Log "front-door extension ready" "OK"

$rgInstalled = az extension list --query "[?name=='resource-graph'].name" -o tsv 2>$null
if (-not $rgInstalled) { az extension add --name resource-graph --only-show-errors | Out-Null }
Log "resource-graph extension ready" "OK"

$allSubsJson = az account list --query "[?state=='Enabled'].{id:id,name:name}" -o json 2>$null
$allSubs = $allSubsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
Log "Tenant subscriptions enabled: $($allSubs.Count)"
foreach ($s in $allSubs) { Log "  - $($s.name)  ($($s.id))" }

Banner "Phase 1 - Multi-subscription discovery via Azure Resource Graph"
$nameList = "'" + ($ProfileMap.Keys -join "','") + "'"
$kql = "Resources | where type =~ 'Microsoft.Network/frontdoors' or type =~ 'Microsoft.Cdn/profiles' | where name in~ ($nameList) | project name, resourceGroup, subscriptionId, type, sku=tostring(sku.name), id"
Log "Resource Graph query: $kql"
$matchesJson = az graph query -q $kql --first 1000 -o json 2>&1
$ghMatches = @()
if ($LASTEXITCODE -ne 0) {
    Log "Resource Graph query failed: $matchesJson" "ERR"
    Log "Falling back to per-subscription enumeration..." "WARN"
    foreach ($s in $allSubs) {
        foreach ($cp in $ProfileMap.Keys) {
            $found = az resource list --subscription $s.id --name $cp --query "[?type=='Microsoft.Network/frontdoors' || type=='Microsoft.Cdn/profiles'] | [0]" -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($found -and $found.id) {
                $ghMatches += [PSCustomObject]@{
                    name           = $found.name
                    resourceGroup  = $found.resourceGroup
                    subscriptionId = $s.id
                    type           = $found.type
                    sku            = if ($found.sku) { $found.sku.name } else { "" }
                    id             = $found.id
                }
            }
        }
    }
} else {
    $parsed = $matchesJson | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($parsed.data) { $ghMatches = $parsed.data } else { $ghMatches = @($parsed) }
}
Log "Resource Graph returned $($ghMatches.Count) match(es)"

$plan = @()
foreach ($cp in $ProfileMap.Keys) {
    SubBanner "Resolving Classic profile: $cp"
    $hit = $ghMatches | Where-Object { $_.name -ieq $cp } | Select-Object -First 1
    if (-not $hit) {
        Log "Profile '$cp' NOT FOUND anywhere across $($allSubs.Count) subscription(s) - SKIP" "WARN"
        continue
    }

    $migrationType = if ($hit.type -ieq "microsoft.network/frontdoors") { "AFD" } else { "CDN" }
    $detectedSub   = $hit.subscriptionId
    $detectedRg    = $hit.resourceGroup
    $classicId     = $hit.id
    $cdnSku        = if ($migrationType -eq "CDN") { $hit.sku } else { "" }

    Log "Found in subscription:  $detectedSub" "OK"
    Log "Resource group:         $detectedRg" "OK"
    Log "Migration type:         $migrationType$(if ($cdnSku) { " (CDN SKU: $cdnSku)" })" "OK"
    Log "Classic resource ID:    $classicId" "OK"

    $customFEs = @()
    if ($migrationType -eq "AFD") {
        $feText = az network front-door frontend-endpoint list --subscription $detectedSub -g $detectedRg --front-door-name $cp --query "[].[name, hostName, customHttpsProvisioningState]" -o tsv 2>$null
        foreach ($line in @($feText -split "`r?`n" | Where-Object { $_ })) {
            $cols = $line -split "`t"
            if ($cols.Count -ge 2 -and $cols[1] -and $cols[1] -notlike "*.azurefd.net") {
                $customFEs += [PSCustomObject]@{
                    Name      = $cols[0]
                    HostName  = $cols[1]
                    CertState = if ($cols.Count -ge 3) { $cols[2] } else { "" }
                    Endpoint  = ""
                }
            }
        }
    } else {
        $cdnEpText = az cdn endpoint list --subscription $detectedSub -g $detectedRg --profile-name $cp --query "[].name" -o tsv 2>$null
        $cdnEps = @($cdnEpText -split "`r?`n" | Where-Object { $_ })
        foreach ($ep in $cdnEps) {
            $cdText = az cdn custom-domain list --subscription $detectedSub -g $detectedRg --profile-name $cp --endpoint-name $ep --query "[].[name, hostName, customHttpsProvisioningState]" -o tsv 2>$null
            foreach ($line in @($cdText -split "`r?`n" | Where-Object { $_ })) {
                $cols = $line -split "`t"
                if ($cols.Count -ge 2 -and $cols[1] -and $cols[1] -notlike "*.azureedge.net") {
                    $customFEs += [PSCustomObject]@{
                        Name      = $cols[0]
                        HostName  = $cols[1]
                        CertState = if ($cols.Count -ge 3) { $cols[2] } else { "" }
                        Endpoint  = $ep
                    }
                }
            }
        }
    }
    Log "$($customFEs.Count) custom domain(s) on $cp"
    foreach ($fe in $customFEs) { Log "  $($fe.HostName)  (endpoint: $($fe.Name), cert: $($fe.CertState))" }

    $targetStd = $ProfileMap[$cp]
    $targetExists = az afd profile show --subscription $detectedSub -g $detectedRg --profile-name $targetStd --query id -o tsv 2>$null
    $targetState  = ""
    if ($targetExists) {
        $targetState = az afd profile show --subscription $detectedSub -g $detectedRg --profile-name $targetStd --query "extendedProperties.migrationState" -o tsv 2>$null
        if (-not $targetState) { $targetState = "<not from migration>" }
        Log "Target Standard '$targetStd' already exists in $detectedRg (state: $targetState)" "WARN"
    } else {
        Log "Target Standard '$targetStd' available in $detectedRg" "OK"
    }

    $plan += [PSCustomObject]@{
        Classic           = $cp
        ClassicResourceId = $classicId
        SubscriptionId    = $detectedSub
        ResourceGroup     = $detectedRg
        MigrationType     = $migrationType
        CdnSku            = $cdnSku
        Standard          = $targetStd
        StandardExists    = [bool]$targetExists
        StandardState     = $targetState
        CustomDomains     = $customFEs
    }
}

if ($plan.Count -eq 0) { Log "No profiles to migrate - exiting" "ERR"; exit 1 }

if ($Rollback) {
    Banner "ROLLBACK MODE - profile '$Rollback'"
    $rbEntry = $plan | Where-Object { $_.Classic -ieq $Rollback } | Select-Object -First 1
    if (-not $rbEntry) { Log "Rollback target '$Rollback' not in plan" "ERR"; exit 11 }
    $ok = Invoke-Rollback -ClassicName $rbEntry.Classic -StandardName $rbEntry.Standard -Sub $rbEntry.SubscriptionId -Rg $rbEntry.ResourceGroup
    if ($ok) { exit 0 } else { exit 12 }
}

Banner "Phase 1.5 - Pre-migrate snapshot (rollback dossier)"
foreach ($p in $plan) {
    $snapPath = Join-Path $snapshotDir "$($p.Classic)-classic-snapshot.json"
    Log "Snapshotting '$($p.Classic)' ($($p.MigrationType)) from $($p.SubscriptionId)/$($p.ResourceGroup)"
    if ($p.MigrationType -eq "AFD") {
        az network front-door show --subscription $p.SubscriptionId -g $p.ResourceGroup --name $p.Classic -o json 2>$null | Set-Content -Path $snapPath -Encoding ASCII
        $waf = az network front-door waf-policy list --subscription $p.SubscriptionId -g $p.ResourceGroup --query "[?contains(frontendEndpointLinks[].id, '$($p.Classic)')]" -o json 2>$null
        if ($waf) {
            $wafPath = Join-Path $snapshotDir "$($p.Classic)-waf-snapshot.json"
            $waf | Set-Content -Path $wafPath -Encoding ASCII
            Log "  WAF snapshot: $wafPath" "OK"
        }
    } else {
        az cdn profile show --subscription $p.SubscriptionId -g $p.ResourceGroup --name $p.Classic -o json 2>$null | Set-Content -Path $snapPath -Encoding ASCII
        $cdnEpsJson = az cdn endpoint list --subscription $p.SubscriptionId -g $p.ResourceGroup --profile-name $p.Classic -o json 2>$null
        if ($cdnEpsJson) {
            $cdnEpsPath = Join-Path $snapshotDir "$($p.Classic)-cdn-endpoints-snapshot.json"
            $cdnEpsJson | Set-Content -Path $cdnEpsPath -Encoding ASCII
            Log "  CDN endpoints snapshot: $cdnEpsPath" "OK"
        }
    }
    Log "  Classic snapshot: $snapPath" "OK"
}
Log "All snapshots saved to $snapshotDir" "OK"
Log "Post-commit recovery requires these JSON files - DO NOT DELETE the snapshot dir" "WARN"

Banner "Phase 2 - Migration plan"
$plan | ForEach-Object {
    Log ""
    Log "  Classic:          $($_.Classic)" "STEP"
    Log "  Subscription:     $($_.SubscriptionId)"
    Log "  Resource group:   $($_.ResourceGroup)"
    Log "  Migration type:   $($_.MigrationType)$(if ($_.CdnSku) { " (CDN SKU: $($_.CdnSku))" })"
    Log "  -> Standard:      $($_.Standard)  ($(if ($_.StandardExists) { "EXISTS, state: $($_.StandardState)" } else { "will be created" }))"
    Log "  Custom domains:   $($_.CustomDomains.Count)"
    foreach ($d in $_.CustomDomains) { Log "    - $($d.HostName)" }
}

if ($DiscoveryOnly) {
    Log ""
    Log "DiscoveryOnly mode - stopping before any changes" "WARN"
    exit 0
}

$badTargets = @($plan | Where-Object { $_.StandardExists -and $_.StandardState -ne "Migrated" -and $_.StandardState -ne "Migrating" -and $_.StandardState -ne "Committed" })
if ($badTargets.Count -gt 0) {
    Log "STOP - target Standard names already taken by NON-migrated profiles:" "ERR"
    foreach ($b in $badTargets) { Log "  $($b.Classic) -> $($b.Standard) (state: $($b.StandardState))" "ERR" }
    exit 2
}

if (-not $NoConfirm) {
    Log ""
    $uniqSubs = ($plan | Select-Object -ExpandProperty SubscriptionId -Unique).Count
    Log "About to migrate $($plan.Count) Classic profile(s) across $uniqSubs subscription(s)." "WARN"
    if (-not $DryRun) {
        $resp = Read-Host "Type YES to proceed with migration for ALL profiles above"
        if ($resp -ne "YES") { Log "Aborted by operator" "WARN"; exit 0 }
    }
}

Banner "Phase 3 - Per-profile atomic migration"

$results = @()
foreach ($p in $plan) {
    SubBanner "Migrating $($p.Classic) ($($p.MigrationType))  ->  $($p.Standard)   in $($p.SubscriptionId)/$($p.ResourceGroup)"

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
    }

    if ($DryRun) {
        Log "DryRun - skipping actual migrate for $($p.Classic)" "WARN"
        $r.Status = "dryrun"
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }

    if (-not $p.StandardExists) {
        Log "Step A - az afd profile migrate (classic=$($p.Classic) -> standard=$($p.Standard))..."
        $migOut = az afd profile migrate `
            --subscription $p.SubscriptionId `
            --resource-group $p.ResourceGroup `
            --profile-name $p.Standard `
            --classic-resource-id $p.ClassicResourceId `
            --sku $Sku `
            --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errText = ($migOut | Out-String).Trim()
            Log "Migrate FAILED for $($p.Classic): $errText" "ERR"
            $r.Status = "migrate-failed"
            $r.Error  = $errText
            $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $results += $r
            Save-State -Plan $plan -Results $results
            continue
        }
        Log "Migrate accepted - Standard '$($p.Standard)' is in Migrating state" "OK"
        Log "Waiting $PostMigrateWaitSec sec..."
        Start-Sleep -Seconds $PostMigrateWaitSec
    } else {
        Log "Standard '$($p.Standard)' already exists - skipping migrate" "OK"
    }

    $stdEpText = az afd endpoint list --subscription $p.SubscriptionId -g $p.ResourceGroup --profile-name $p.Standard --query "[].hostName" -o tsv 2>$null
    $stdEndpoints = @($stdEpText -split "`r?`n" | Where-Object { $_ })
    if ($stdEndpoints.Count -gt 0) { $r.TestFqdn = $stdEndpoints[0] }
    $r.AllNewEndpoints = $stdEndpoints

    $decision = "COMMIT"
    if (-not $AutoCommit) {
        Log ""
        Log ("=" * 78) "GATE"
        Log "VERIFY GATE for $($p.Classic) -> $($p.Standard)" "GATE"
        foreach ($ep in $stdEndpoints) { Log "    https://$ep/" "GATE" }
        Log "Type COMMIT (irreversible), ROLLBACK (delete uncommitted Standard), SKIP (defer)" "GATE"
        Log ("=" * 78) "GATE"
        $decision = ""
        while ($decision -notin @("COMMIT","ROLLBACK","SKIP")) {
            $decision = (Read-Host "Decision for $($p.Classic) [COMMIT/ROLLBACK/SKIP]").Trim().ToUpper()
        }
    } else {
        Log "AutoCommit=true - proceeding to COMMIT" "WARN"
    }
    $r.Decision = $decision

    if ($decision -eq "ROLLBACK") {
        $rbOk = Invoke-Rollback -ClassicName $p.Classic -StandardName $p.Standard -Sub $p.SubscriptionId -Rg $p.ResourceGroup
        $r.Status = if ($rbOk) { "rolled-back" } else { "rollback-failed" }
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }
    if ($decision -eq "SKIP") {
        Log "Skipping commit for $($p.Classic)" "WARN"
        $r.Status = "migrated-not-committed"
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }

    $currentState = az afd profile show --subscription $p.SubscriptionId -g $p.ResourceGroup --profile-name $p.Standard --query "extendedProperties.migrationState" -o tsv 2>$null
    Log "Pre-commit state: $currentState"
    if ($currentState -eq "Committed") {
        Log "Already committed" "OK"
    } else {
        Log "Submitting az afd profile migration-commit..."
        $commitOut = az afd profile migration-commit `
            --subscription $p.SubscriptionId `
            --resource-group $p.ResourceGroup `
            --profile-name $p.Standard `
            --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errText = ($commitOut | Out-String).Trim()
            Log "Commit FAILED for $($p.Standard): $errText" "ERR"
            $r.Status = "commit-failed"
            $r.Error  = $errText
            $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $results += $r
            Save-State -Plan $plan -Results $results
            continue
        }
        Log "Commit accepted" "OK"
        Log "Waiting $CommitWaitSec sec..."
        Start-Sleep -Seconds $CommitWaitSec
    }

    if (-not $SkipWatchdog -and $r.TestFqdn) {
        SubBanner "Watchdog ($WatchdogSec sec) for $($p.Standard)"
        $deadline = (Get-Date).AddSeconds($WatchdogSec)
        $tick = 0
        $watchdogIssue = $false
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
                Tick    = $tick
                Time    = $tStamp
                Url     = "https://$($r.TestFqdn)/"
                Code    = "$code"
                AzRef   = if ($azref) { $azref.Substring(0, [Math]::Min(40, $azref.Length)) } else { "" }
                Healthy = $tickOk
            }
            $msg = "watchdog tick $tick - $($r.TestFqdn) -> $code"
            if ($azref) { $msg += "  (x-azure-ref: $($azref.Substring(0, [Math]::Min(40, $azref.Length))))" }
            if ($tickOk) { Log $msg "OK" } else { Log $msg "WARN"; $watchdogIssue = $true }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds $WatchdogIntervalSec
        }
        if ($watchdogIssue) { Log "Watchdog: non-2xx/3xx detected" "WARN" } else { Log "Watchdog clean for full window" "OK" }
    }

    $stdCdText = az afd custom-domain list --subscription $p.SubscriptionId -g $p.ResourceGroup --profile-name $p.Standard --query "[].[name, hostName, domainValidationState]" -o tsv 2>$null
    $stdCustomDomains = @()
    foreach ($line in @($stdCdText -split "`r?`n" | Where-Object { $_ })) {
        $cols = $line -split "`t"
        if ($cols.Count -ge 2) {
            $stdCustomDomains += [PSCustomObject]@{
                Name            = $cols[0]
                HostName        = $cols[1]
                ValidationState = if ($cols.Count -ge 3) { $cols[2] } else { "" }
            }
        }
    }
    $r.PostCDs = @($stdCustomDomains | ForEach-Object { "$($_.HostName) [$($_.ValidationState)]" })

    $stdEpMap = @{}
    $stdEpText2 = az afd endpoint list --subscription $p.SubscriptionId -g $p.ResourceGroup --profile-name $p.Standard --query "[].[name, hostName]" -o tsv 2>$null
    foreach ($line in @($stdEpText2 -split "`r?`n" | Where-Object { $_ })) {
        $cols = $line -split "`t"
        if ($cols.Count -ge 2) { $stdEpMap[$cols[0]] = $cols[1] }
    }

    foreach ($classicFE in $p.CustomDomains) {
        $matchStd = $stdCustomDomains | Where-Object { $_.HostName -ieq $classicFE.HostName } | Select-Object -First 1
        if (-not $matchStd) {
            Log "WARN: $($classicFE.HostName) on Classic but NOT on new Standard" "WARN"
            continue
        }
        $cnameTarget = "<UNKNOWN>"
        foreach ($epName in $stdEpMap.Keys) {
            $routeText = az afd route list --subscription $p.SubscriptionId -g $p.ResourceGroup --profile-name $p.Standard --endpoint-name $epName --query "[].customDomains[].id" -o tsv 2>$null
            $routeIds = @($routeText -split "`r?`n" | Where-Object { $_ })
            foreach ($rid in $routeIds) {
                if ($rid -match [regex]::Escape("/customDomains/$($matchStd.Name)")) {
                    $cnameTarget = $stdEpMap[$epName]
                    break
                }
            }
            if ($cnameTarget -ne "<UNKNOWN>") { break }
        }
        if ($cnameTarget -eq "<UNKNOWN>" -and $stdEpMap.Count -gt 0) {
            $cnameTarget = ($stdEpMap.Values | Select-Object -First 1)
        }
        $txt = ""
        if ($matchStd.ValidationState -ne "Approved") {
            $txt = az afd custom-domain show --subscription $p.SubscriptionId -g $p.ResourceGroup --profile-name $p.Standard --custom-domain-name $matchStd.Name --query "validationProperties.validationToken" -o tsv 2>$null
        }
        $r.DnsRecords += [PSCustomObject]@{
            Hostname        = $classicFE.HostName
            ValidationState = $matchStd.ValidationState
            TxtValue        = $txt
            CnameTarget     = $cnameTarget
        }
        Log "  $($classicFE.HostName) -> CNAME $cnameTarget (cert: $($matchStd.ValidationState))" "OK"
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
$failed   = @($results | Where-Object { $_.Status -in @("migrate-failed","commit-failed") })

Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

$rowsHtml = @()
foreach ($r in $migrated) {
    foreach ($d in $r.DnsRecords) {
        $hostShort = $d.Hostname.Split('.')[0]
        $txtRow = if ($d.TxtValue) {
            "<tr><td rowspan='2'><b>$($d.Hostname)</b><br/><span style='color:#555'>via $($r.Standard) ($($r.SubscriptionId))</span></td><td><span class='tag txt'>TXT</span></td><td><code>_dnsauth.$hostShort</code></td><td><code>$($d.TxtValue)</code></td><td>300</td><td>Step 1</td></tr>"
        } else {
            "<tr><td rowspan='2'><b>$($d.Hostname)</b><br/><span style='color:#555'>via $($r.Standard) ($($r.SubscriptionId))</span></td><td><span class='tag txt'>TXT</span></td><td colspan='4'><i>cert pre-validated</i></td></tr>"
        }
        $rowsHtml += $txtRow
        $rowsHtml += "<tr><td><span class='tag cn'>CNAME</span></td><td><code>$hostShort</code></td><td><code>$($d.CnameTarget)</code></td><td>300</td><td>Step 2</td></tr>"
    }
}
$rowsJoined = if ($rowsHtml.Count -gt 0) { $rowsHtml -join "`n" } else { "<tr><td colspan='6'>No committed migrations.</td></tr>" }

$dnsHtml = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>PYX FD - DNS handoff</title>
<style>body{font-family:Segoe UI,Arial;max-width:1200px;margin:30px auto;padding:0 24px;color:#11151C;line-height:1.55}
h1{color:#1F3D7A;border-bottom:2px solid #1F3D7A;padding-bottom:8px}
table{width:100%;border-collapse:collapse;margin:10px 0;font-size:13px}
th{background:#F5F7FA;padding:10px;text-align:left;border-bottom:2px solid #1F3D7A;color:#1F3D7A}
td{padding:10px;border-bottom:1px solid #E5E8EE;vertical-align:top}
code{font-family:Consolas,monospace;font-size:12px;background:#F5F7FA;padding:2px 6px;border-radius:3px;word-break:break-all}
.tag{display:inline-block;padding:2px 8px;border-radius:3px;font-size:11px;font-weight:600;color:#fff}
.tag.txt{background:#1B6B3A}.tag.cn{background:#1F3D7A}
.foot{margin-top:30px;padding-top:12px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px}
</style></head><body>
<h1>PYX Front Door - DNS records to publish</h1>
<p>$($migrated.Count) profile(s) migrated and committed.</p>
<table><thead><tr><th>Domain</th><th>Type</th><th>Host</th><th>Value</th><th>TTL</th><th>When</th></tr></thead><tbody>
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
        $safe = if ($_.Error.Length -gt 160) { $_.Error.Substring(0,160) } else { $_.Error }
        "<code>$([System.Web.HttpUtility]::HtmlEncode($safe))</code>"
    } else { "-" }
    "<tr><td><b>$($_.Classic)</b></td><td><code>$($_.MigrationType)</code></td><td><code style='font-size:11px'>$($_.SubscriptionId)</code></td><td><code>$($_.ResourceGroup)</code></td><td><code>$($_.Standard)</code></td><td><code>$($_.Decision)</code></td><td style='color:$color'><b>$($_.Status)</b></td><td>$errCell</td></tr>"
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
<h1>PYX migration summary</h1>
<p>Run: $timestamp &middot; Migrated: $($migrated.Count) &middot; Rolled back: $($rolled.Count) &middot; Pending: $($pending.Count) &middot; Failed: $($failed.Count)</p>
<table><thead><tr><th>Classic</th><th>Type</th><th>Subscription</th><th>RG</th><th>New Standard</th><th>Decision</th><th>Status</th><th>Error</th></tr></thead><tbody>
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
            "<tr><td>$($_.Tick)</td><td>$($_.Time)</td><td><code>$($_.Url)</code></td><td style='color:$tColor'><b>$($_.Code)</b></td><td><code>$($_.AzRef)</code></td></tr>"
        }) -join "`n"
        $rateColor = if ($okCount -eq $totalTicks) { "#1B6B3A" } else { "#B7791F" }
        $watchHtml = "<h3>Watchdog verification</h3><p>Health rate: <b style='color:$rateColor'>$watchRate</b></p><table><thead><tr><th>#</th><th>Time</th><th>URL</th><th>Code</th><th>x-azure-ref</th></tr></thead><tbody>$tickRows</tbody></table>"
    }

    $endpointsList = if ($r.AllNewEndpoints.Count -gt 0) { ($r.AllNewEndpoints | ForEach-Object { "<li><code>https://$_/</code></li>" }) -join "" } else { "<li><i>none</i></li>" }

    $dnsHtml2 = ""
    if ($r.DnsRecords.Count -gt 0) {
        $dnsRows = ($r.DnsRecords | ForEach-Object {
            $hostShort = $_.Hostname.Split('.')[0]
            $txtPart = if ($_.TxtValue) { "<code>_dnsauth.$hostShort</code> TXT <code>$($_.TxtValue)</code>" } else { "<i>cert pre-validated</i>" }
            "<tr><td><b>$($_.Hostname)</b></td><td>$($_.ValidationState)</td><td>$txtPart</td><td><code>$hostShort</code> CNAME <code>$($_.CnameTarget)</code></td></tr>"
        }) -join "`n"
        $dnsHtml2 = "<h3>DNS records to publish (Maryfin)</h3><table><thead><tr><th>Hostname</th><th>Cert state</th><th>TXT</th><th>CNAME</th></tr></thead><tbody>$dnsRows</tbody></table>"
    }

    $errBlock = ""
    if ($r.Error) {
        $safeErr = if ($r.Error.Length -gt 400) { $r.Error.Substring(0,400) } else { $r.Error }
        $errBlock = "<h3 style='color:#9B2226'>Error</h3><pre style='background:#FEE;border-left:3px solid #9B2226;padding:10px;font-size:12px;white-space:pre-wrap'>$([System.Web.HttpUtility]::HtmlEncode($safeErr))</pre>"
    }

    $card = @"
<div class='card'>
  <h2>$($r.Classic) <span class='arrow'>-&gt;</span> $($r.Standard)</h2>
  <table class='kv'>
    <tr><td>Source type</td><td><b>$skuLabel</b></td></tr>
    <tr><td>Subscription</td><td><code>$($r.SubscriptionId)</code></td></tr>
    <tr><td>Resource group</td><td><code>$($r.ResourceGroup)</code></td></tr>
    <tr><td>Source resource ID</td><td><code style='font-size:11px'>$($r.ClassicResourceId)</code></td></tr>
    <tr><td>Migration cmdlet</td><td><code>az afd profile migrate</code> + <code>migration-commit</code></td></tr>
    <tr><td>Operator decision</td><td><code>$($r.Decision)</code></td></tr>
    <tr><td>Final status</td><td style='color:$statusColor'><b>$($r.Status)</b></td></tr>
    <tr><td>Started</td><td>$($r.StartedAt)</td></tr>
    <tr><td>Completed</td><td>$($r.CompletedAt)</td></tr>
    <tr><td>Watchdog success</td><td><b>$watchRate</b></td></tr>
    <tr><td>Custom domains</td><td>$($r.PreCDs.Count) before -&gt; $($r.PostCDs.Count) after</td></tr>
  </table>
  <h3>New AFD Standard endpoints</h3>
  <ul>$endpointsList</ul>
  <h3>Custom domains - before migration</h3>
  <ul>$preCdRows</ul>
  <h3>Custom domains - after migration (cert state)</h3>
  <ul>$postCdRows</ul>
  $watchHtml
  $dnsHtml2
  $errBlock
</div>
"@
    $changeCards += $card
}
$cardsJoined = if ($changeCards.Count -gt 0) { $changeCards -join "`n" } else { "<p><i>No profiles processed.</i></p>" }

$snapFiles = @()
if (Test-Path $snapshotDir) {
    $snapFiles = Get-ChildItem -Path $snapshotDir -File -ErrorAction SilentlyContinue | ForEach-Object { "<li><code>$($_.Name)</code> ($([Math]::Round($_.Length/1KB,1)) KB)</li>" }
}
$snapFilesJoined = if ($snapFiles.Count -gt 0) { $snapFiles -join "" } else { "<li><i>none</i></li>" }

$logTailHtml = "<i>log not readable</i>"
if (Test-Path $logPath) {
    $tail = Get-Content -Path $logPath -Tail 80 -ErrorAction SilentlyContinue
    if ($tail) {
        $tailEsc = ($tail | ForEach-Object { [System.Web.HttpUtility]::HtmlEncode($_) }) -join "`n"
        $logTailHtml = "<pre style='background:#0F172A;color:#E2E8F0;padding:12px;border-radius:6px;font-family:Consolas,monospace;font-size:11px;overflow-x:auto;max-height:400px;overflow-y:auto'>$tailEsc</pre>"
    }
}

$subsTouched = @($results | Select-Object -ExpandProperty SubscriptionId -Unique)

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
ul{margin:6px 0;padding-left:22px}
li{margin:3px 0}
.card{background:#FFF;border:1px solid #C8CFD9;border-radius:8px;padding:18px 22px;margin:18px 0;box-shadow:0 1px 3px rgba(0,0,0,0.04)}
.arrow{color:#1F3D7A;font-weight:600}
.summary{background:#F5F7FA;border-left:4px solid #1F3D7A;padding:14px 18px;margin:14px 0}
.foot{margin-top:30px;padding-top:12px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px}
.bigcount{font-size:24px;font-weight:600;color:#1F3D7A}
</style></head><body>

<h1>PYX migration change report</h1>
<p>Atomic migration evidence across all PYX subscriptions. Per-profile source state, migration method, post-migration verification, rollback artifacts.</p>

<div class='summary'>
<table class='kv'>
<tr><td>Run timestamp</td><td><code>$timestamp</code></td></tr>
<tr><td>Started</td><td>$($startTime.ToString("yyyy-MM-dd HH:mm:ss"))</td></tr>
<tr><td>Ended</td><td>$($endTime.ToString("yyyy-MM-dd HH:mm:ss"))</td></tr>
<tr><td>Duration</td><td>$durationMin minutes</td></tr>
<tr><td>Tenant subscriptions enumerated</td><td>$($allSubs.Count)</td></tr>
<tr><td>Subscriptions touched</td><td>$($subsTouched.Count)</td></tr>
<tr><td>Profiles in scope</td><td>$($results.Count)</td></tr>
<tr><td>Migrated and committed</td><td><span class='bigcount' style='color:#1B6B3A'>$($migrated.Count)</span></td></tr>
<tr><td>Rolled back</td><td><span class='bigcount' style='color:#B7791F'>$($rolled.Count)</span></td></tr>
<tr><td>Pending / skipped</td><td><span class='bigcount' style='color:#1F3D7A'>$($pending.Count)</span></td></tr>
<tr><td>Failed</td><td><span class='bigcount' style='color:#9B2226'>$($failed.Count)</span></td></tr>
</table>
</div>

<h2>Per-profile change detail</h2>
$cardsJoined

<h2>Snapshot dossier (rollback artifacts)</h2>
<p>Pre-migration JSON snapshots stored at <code>$snapshotDir</code>:</p>
<ul>$snapFilesJoined</ul>

<h2>Run log (last 80 lines)</h2>
$logTailHtml

<h2>Companion artifacts</h2>
<ul>
<li>DNS handoff (Maryfin): <code>$dnsHtmlPath</code></li>
<li>Migration summary: <code>$summaryPath</code></li>
<li>Full run log: <code>$logPath</code></li>
<li>State JSON: <code>$statePath</code></li>
</ul>

<div class='foot'>Prepared by Syed Rizvi - PYX Health Production - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</body></html>
"@
Set-Content -Path $changePath -Value $changeReportHtml -Encoding ASCII

Banner "DONE"
Log "Migrated: $($migrated.Count)  -  Rolled back: $($rolled.Count)  -  Pending: $($pending.Count)  -  Failed: $($failed.Count)" "OK"
Log ""
Log "Artifacts:"
Log "  Run log         : $logPath"
Log "  Snapshot dir    : $snapshotDir   (DO NOT DELETE)"
Log "  State JSON      : $statePath"
Log "  DNS handoff HTML: $dnsHtmlPath  <- Maryfin"
Log "  Summary HTML    : $summaryPath"
Log "  Change report   : $changePath  <- detailed evidence for Tony"
exit 0
