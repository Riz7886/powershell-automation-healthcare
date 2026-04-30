[CmdletBinding()]
param(
    [string]$SubscriptionId      = "e42e94b5-c6f8-4af0-a41b-16fda520de6e",
    [string]$ResourceGroup       = "production",
    [hashtable]$ProfileMap       = @{
        "pyxiq"        = "pyxiq-std"
        "hipyx"        = "hipyx-std-v2"
        "pyxiq-stage"  = "pyxiq-stage-std"
        "pyxpwa-stage" = "pyxpwa-stage-std"
        "standard"     = "standard-afdstd"
    },
    [string[]]$VerifyAlsoStandard = @(),
    [string]$Sku                 = "Standard_AzureFrontDoor",
    [int]   $PostMigrateWaitSec  = 60,
    [int]   $CommitWaitSec       = 30,
    [int]   $WatchdogSec         = 300,
    [int]   $WatchdogIntervalSec = 30,
    [int]   $VerifyOnlyTickCount = 3,
    [switch]$DryRun,
    [switch]$DiscoveryOnly,
    [switch]$NoConfirm,
    [switch]$AutoCommit,
    [switch]$SkipValidate,
    [switch]$SkipWatchdog,
    [switch]$SkipVerifyAlso,
    [string[]]$OnlyProfiles      = @(),
    [string]$Rollback            = "",
    [string]$ReportDir           = (Join-Path $env:USERPROFILE "Desktop\pyx-atomic-migrate-report")
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
$snapshotDir = Join-Path $ReportDir "snapshots-$timestamp"
if (-not (Test-Path $snapshotDir)) { New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null }
$logPath     = Join-Path $ReportDir "atomic-migrate-$timestamp.log"
$dnsHtmlPath = Join-Path $ReportDir "dns-handoff-all-$timestamp.html"
$summaryPath = Join-Path $ReportDir "summary-$timestamp.html"
$changePath  = Join-Path $ReportDir "change-report-$timestamp.html"
$statePath   = Join-Path $ReportDir "state-$timestamp.json"
$startTime   = Get-Date

function Log {
    param([string]$Message, [string]$Level = "INFO")
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line = "[$stamp] [$Level] $Message"
    Add-Content -Path $logPath -Value $line
    $color = switch ($Level) { "OK" {"Green"} "WARN" {"Yellow"} "ERR" {"Red"} "STEP" {"Cyan"} "GATE" {"Magenta"} default {"White"} }
    Write-Host $line -ForegroundColor $color
}
function Banner($t) { Log ""; Log ("=" * 78); Log $t "STEP"; Log ("=" * 78) }
function SubBanner($t) { Log ""; Log ("-" * 78); Log $t "STEP"; Log ("-" * 78) }

function Save-State {
    param($Plan, $Results)
    $state = [PSCustomObject]@{
        timestamp    = $timestamp
        subscription = $SubscriptionId
        rg           = $ResourceGroup
        plan         = $Plan
        results      = $Results
    }
    $state | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath -Encoding ASCII
}

function Invoke-Rollback {
    param(
        [string]$ClassicName,
        [string]$StandardName,
        [string]$RG
    )
    SubBanner "ROLLBACK $ClassicName  ->  delete uncommitted Standard $StandardName"
    $stdId = az afd profile show -g $RG --profile-name $StandardName --query id -o tsv 2>$null
    if (-not $stdId) {
        Log "Standard '$StandardName' not found - nothing to roll back" "WARN"
        return $true
    }
    $state = az afd profile show -g $RG --profile-name $StandardName --query "extendedProperties.migrationState" -o tsv 2>$null
    Log "Current Standard state: $state"
    if ($state -eq "Committed") {
        Log "Standard '$StandardName' is already COMMITTED - rollback is NOT possible at this point" "ERR"
        Log "Recovery path: redeploy Classic from snapshot at $snapshotDir\$ClassicName-classic-snapshot.json + open Azure support ticket" "ERR"
        return $false
    }
    Log "Deleting uncommitted Standard profile '$StandardName' (Classic '$ClassicName' is unaffected)..."
    az afd profile delete --resource-group $RG --profile-name $StandardName --yes --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Log "Rollback complete - Classic '$ClassicName' resumes serving as if nothing happened" "OK"
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

Banner "PYX atomic migration  -  AFD Classic + CDN Classic  ->  AFD Standard  -  with rollback gate"
Log "Subscription:           $SubscriptionId"
Log "Resource group:         $ResourceGroup"
Log "Profiles in scope:      $($ProfileMap.Keys -join ', ')"
Log "Target Standard SKU:    $Sku"
Log "Post-migrate wait:      $PostMigrateWaitSec sec"
Log "Commit wait:            $CommitWaitSec sec"
Log "Watchdog window:        $WatchdogSec sec (interval $WatchdogIntervalSec sec)"
Log "DryRun:                 $DryRun"
Log "DiscoveryOnly:          $DiscoveryOnly"
Log "NoConfirm:              $NoConfirm"
Log "AutoCommit:             $AutoCommit"
Log "SkipValidate:           $SkipValidate"
Log "SkipWatchdog:           $SkipWatchdog"
Log "Rollback target:        $(if ($Rollback) { $Rollback } else { '<none>' })"
Log "Report dir:             $ReportDir"
Log "Snapshot dir:           $snapshotDir"

Banner "Phase 0 - Pre-flight"
$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $acct) { Log "az login..." "WARN"; az login --only-show-errors | Out-Null }
az account set --subscription $SubscriptionId --only-show-errors | Out-Null
$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $acct) { Log "Could not establish Azure session - aborting" "ERR"; exit 10 }
Log "Signed in as $($acct.user.name)" "OK"

$installed = az extension list --query "[?name=='front-door'].name" -o tsv 2>$null
if (-not $installed) { az extension add --name front-door --only-show-errors | Out-Null }
az extension update --name front-door --only-show-errors 2>$null | Out-Null
Log "front-door extension ready" "OK"

if ($Rollback) {
    Banner "ROLLBACK MODE - profile '$Rollback'"
    if (-not $ProfileMap.ContainsKey($Rollback)) {
        Log "Rollback target '$Rollback' is not in the ProfileMap; nothing to do" "ERR"
        exit 11
    }
    $stdName = $ProfileMap[$Rollback]
    $ok = Invoke-Rollback -ClassicName $Rollback -StandardName $stdName -RG $ResourceGroup
    if ($ok) { exit 0 } else { exit 12 }
}

Banner "Phase 1 - Discovery"
$plan = @()
foreach ($cp in $ProfileMap.Keys) {
    SubBanner "Discovering Classic profile: $cp"

    $classicId = az network front-door show -g $ResourceGroup --name $cp --query id -o tsv 2>$null
    $migrationType = "AFD"
    $cdnSku = ""

    if (-not $classicId) {
        $cdnId = az cdn profile show -g $ResourceGroup --name $cp --query id -o tsv 2>$null
        if ($cdnId) {
            $classicId = $cdnId
            $migrationType = "CDN"
            $cdnSku = az cdn profile show -g $ResourceGroup --name $cp --query "sku.name" -o tsv 2>$null
        }
    }

    if (-not $classicId) {
        Log "Profile '$cp' NOT FOUND as AFD or CDN profile in $ResourceGroup - SKIP" "WARN"
        continue
    }
    Log "Classic resource ID: $classicId" "OK"
    if ($migrationType -eq "CDN") {
        Log "Migration type:      $migrationType (CDN SKU: $cdnSku)  -  portal-driven migrate" "OK"
    } else {
        Log "Migration type:      $migrationType  -  az afd profile migrate" "OK"
    }

    $customFEs = @()
    if ($migrationType -eq "AFD") {
        $feText = az network front-door frontend-endpoint list -g $ResourceGroup --front-door-name $cp --query "[].[name, hostName, customHttpsProvisioningState]" -o tsv 2>$null
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
        $cdnEpText = az cdn endpoint list -g $ResourceGroup --profile-name $cp --query "[].name" -o tsv 2>$null
        $cdnEps = @($cdnEpText -split "`r?`n" | Where-Object { $_ })
        Log "  $($cdnEps.Count) CDN endpoint(s) on $cp"
        foreach ($ep in $cdnEps) {
            $cdText = az cdn custom-domain list -g $ResourceGroup --profile-name $cp --endpoint-name $ep --query "[].[name, hostName, customHttpsProvisioningState]" -o tsv 2>$null
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
    $targetExists = az afd profile show -g $ResourceGroup --profile-name $targetStd --query id -o tsv 2>$null
    $targetState = ""
    if ($targetExists) {
        $targetState = az afd profile show -g $ResourceGroup --profile-name $targetStd --query "extendedProperties.migrationState" -o tsv 2>$null
        if (-not $targetState) { $targetState = "<not from migration>" }
        Log "Target Standard '$targetStd' already exists (state: $targetState)" "WARN"
    } else {
        Log "Target Standard '$targetStd' available - will be created by migration" "OK"
    }

    $plan += [PSCustomObject]@{
        Classic           = $cp
        ClassicResourceId = $classicId
        MigrationType     = $migrationType
        CdnSku            = $cdnSku
        Standard          = $targetStd
        StandardExists    = [bool]$targetExists
        StandardState     = $targetState
        CustomDomains     = $customFEs
    }
}

if ($plan.Count -eq 0) { Log "No profiles to migrate. Exiting." "ERR"; exit 1 }

Banner "Phase 1.5 - Pre-migrate snapshot (rollback dossier)"
foreach ($p in $plan) {
    $snapPath = Join-Path $snapshotDir "$($p.Classic)-classic-snapshot.json"
    Log "Snapshotting Classic '$($p.Classic)' ($($p.MigrationType)) to $snapPath"
    if ($p.MigrationType -eq "AFD") {
        az network front-door show -g $ResourceGroup --name $p.Classic -o json 2>$null | Set-Content -Path $snapPath -Encoding ASCII
        $waf = az network front-door waf-policy list -g $ResourceGroup --query "[?contains(frontendEndpointLinks[].id, '$($p.Classic)')]" -o json 2>$null
        if ($waf) {
            $wafPath = Join-Path $snapshotDir "$($p.Classic)-waf-snapshot.json"
            $waf | Set-Content -Path $wafPath -Encoding ASCII
            Log "  WAF snapshot: $wafPath" "OK"
        }
    } else {
        az cdn profile show -g $ResourceGroup --name $p.Classic -o json 2>$null | Set-Content -Path $snapPath -Encoding ASCII
        $cdnEpsJson = az cdn endpoint list -g $ResourceGroup --profile-name $p.Classic -o json 2>$null
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

$validateResults = @{}
if (-not $SkipValidate) {
    Banner "Phase 2 - Validate migration eligibility (az afd profile validate-migration)"
    $blockers = @()
    foreach ($p in $plan) {
        if ($p.StandardExists -and $p.StandardState -in @("Migrated","Migrating","Committed")) {
            Log "Skipping validate for $($p.Classic) - target Standard already exists in migration state" "WARN"
            $validateResults[$p.Classic] = "skipped (target exists)"
            continue
        }
        SubBanner "Validating $($p.Classic) ($($p.MigrationType))"
        $vOut = az afd profile validate-migration `
            --resource-group $ResourceGroup `
            --classic-resource-id $p.ClassicResourceId `
            --profile-name $p.Standard `
            --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errText = ($vOut | Out-String).Trim()
            Log "validate-migration FAILED for $($p.Classic): $errText" "ERR"
            $blockers += "$($p.Classic): $errText"
            $validateResults[$p.Classic] = "FAILED: $errText"
        } else {
            $vJson = ($vOut | Out-String) | ConvertFrom-Json -ErrorAction SilentlyContinue
            $errs = @()
            if ($vJson) { $errs = @($vJson.errors) }
            if ($errs.Count -gt 0) {
                $blockerMsgs = @()
                foreach ($e in $errs) {
                    Log "  blocker: $($e.errorMessage)" "ERR"
                    $blockers += "$($p.Classic): $($e.errorMessage)"
                    $blockerMsgs += $e.errorMessage
                }
                $validateResults[$p.Classic] = "BLOCKED: " + ($blockerMsgs -join "; ")
            } else {
                Log "validate-migration OK for $($p.Classic)" "OK"
                $validateResults[$p.Classic] = "PASSED"
            }
        }
    }
    if ($blockers.Count -gt 0) {
        Log "" "ERR"
        Log "STOP - validate-migration returned $($blockers.Count) blocker(s):" "ERR"
        foreach ($b in $blockers) { Log "  - $b" "ERR" }
        Log "Resolve blockers in Azure portal first, or rerun with -SkipValidate (not recommended)" "ERR"
        exit 3
    }
} else {
    Log "SkipValidate=true - skipping validate-migration phase" "WARN"
}

Banner "Phase 2.5 - Migration plan"
$plan | ForEach-Object {
    Log ""
    Log "  Classic:          $($_.Classic)" "STEP"
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
    Log ""
    Log "STOP - the following target Standard profile names are already taken by NON-migrated profiles:" "ERR"
    foreach ($b in $badTargets) { Log "  $($b.Classic) -> $($b.Standard) (state: $($b.StandardState))" "ERR" }
    Log "Pick different target names via -ProfileMap or rename / delete the conflicting profile." "ERR"
    exit 2
}

if (-not $NoConfirm) {
    Log ""
    Log "About to migrate $($plan.Count) Classic AFD profile(s) to Standard via atomic API." "WARN"
    Log "Per profile: validate done -> migrate (reversible) -> VERIFY GATE -> commit (irreversible) -> watchdog." "WARN"
    Log "Snapshots saved to $snapshotDir" "WARN"
    if (-not $DryRun) {
        $resp = Read-Host "Type YES to proceed with the migration for ALL profiles above"
        if ($resp -ne "YES") { Log "Aborted by operator" "WARN"; exit 0 }
    } else {
        Log "DryRun mode - skipping confirmation" "WARN"
    }
}

Banner "Phase 3 - Per-profile atomic migration with rollback gate"

$results = @()
foreach ($p in $plan) {
    SubBanner "Migrating $($p.Classic)  ->  $($p.Standard)"

    $r = [PSCustomObject]@{
        Classic           = $p.Classic
        Standard          = $p.Standard
        MigrationType     = $p.MigrationType
        CdnSku            = $p.CdnSku
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
        ValidateResult    = if ($validateResults -and $validateResults.ContainsKey($p.Classic)) { $validateResults[$p.Classic] } else { "not-run" }
        StartedAt         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CompletedAt       = ""
    }

    if ($DryRun) {
        Log "DryRun - skipping actual migrate for $($p.Classic)" "WARN"
        $r.Status = "dryrun"
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }

    if (-not $p.StandardExists) {
        Log "Step A - Submitting migrate request: classic=$($p.Classic) ($($p.MigrationType)) -> standard=$($p.Standard)..."
        $migOut = az afd profile migrate `
            --resource-group $ResourceGroup `
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
        Log "Migrate accepted - Standard '$($p.Standard)' created in Migrating state (Classic still serving)" "OK"
        Log "Waiting $PostMigrateWaitSec sec for migration to settle..."
        Start-Sleep -Seconds $PostMigrateWaitSec
    } else {
        Log "Standard '$($p.Standard)' already exists (state: $($p.StandardState)) - skipping migrate, going to verify gate" "OK"
    }

    $stdEpText = az afd endpoint list -g $ResourceGroup --profile-name $p.Standard --query "[].hostName" -o tsv 2>$null
    $stdEndpoints = @($stdEpText -split "`r?`n" | Where-Object { $_ })
    if ($stdEndpoints.Count -gt 0) { $r.TestFqdn = $stdEndpoints[0] }
    $r.AllNewEndpoints = $stdEndpoints

    Log ""
    Log "================================================================================" "GATE"
    Log "Step B - VERIFICATION GATE for $($p.Classic) -> $($p.Standard)" "GATE"
    Log "================================================================================" "GATE"
    Log "" "GATE"
    Log "Standard profile '$($p.Standard)' is created and READY to commit." "GATE"
    Log "Classic '$($p.Classic)' ($($p.MigrationType)) is STILL ACTIVE and serving production traffic." "GATE"
    Log "" "GATE"
    Log "Test endpoint(s) on the new Standard:" "GATE"
    foreach ($ep in $stdEndpoints) { Log "    https://$ep/" "GATE" }
    Log "" "GATE"
    Log "RECOMMENDED VERIFICATION (run in another terminal NOW, before deciding):" "GATE"
    if ($r.TestFqdn) {
        Log "    curl.exe -I https://$($r.TestFqdn)/" "GATE"
        Log "    -> expect HTTP 200/301/302 + 'x-azure-ref' header" "GATE"
    }
    Log "    az afd endpoint list -g $ResourceGroup --profile-name $($p.Standard) -o table" "GATE"
    Log "    az afd route list -g $ResourceGroup --profile-name $($p.Standard) --endpoint-name <ep> -o table" "GATE"
    Log "" "GATE"
    Log "DECISION:" "GATE"
    Log "    COMMIT   - run az afd profile migration-commit (IRREVERSIBLE - retires Classic)" "GATE"
    Log "    ROLLBACK - delete uncommitted Standard profile, Classic stays active" "GATE"
    Log "    SKIP     - leave Standard in Migrating state, do nothing now (decide later)" "GATE"
    Log "================================================================================" "GATE"

    $decision = ""
    if ($AutoCommit) {
        Log "AutoCommit=true - skipping operator gate, proceeding to COMMIT" "WARN"
        $decision = "COMMIT"
    } else {
        while ($decision -notin @("COMMIT","ROLLBACK","SKIP")) {
            $decision = (Read-Host "Type COMMIT, ROLLBACK, or SKIP for $($p.Classic)").Trim().ToUpper()
        }
    }
    $r.Decision = $decision

    if ($decision -eq "ROLLBACK") {
        $rbOk = Invoke-Rollback -ClassicName $p.Classic -StandardName $p.Standard -RG $ResourceGroup
        $r.Status = if ($rbOk) { "rolled-back" } else { "rollback-failed" }
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }

    if ($decision -eq "SKIP") {
        Log "Skipping commit for $($p.Classic) - Standard '$($p.Standard)' left in Migrating state" "WARN"
        Log "Resume later with: .\migrate-pyx-atomic-v2-tonight.ps1 -OnlyProfiles $($p.Classic) -NoConfirm" "WARN"
        $r.Status = "migrated-not-committed"
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }

    $currentState = az afd profile show -g $ResourceGroup --profile-name $p.Standard --query "extendedProperties.migrationState" -o tsv 2>$null
    Log "Step C - Pre-commit state: $currentState"
    if ($currentState -eq "Committed") {
        Log "Already committed - skipping commit" "OK"
    } else {
        Log "Submitting migration-commit (this retires Classic '$($p.Classic)')..."
        $commitOut = az afd profile migration-commit `
            --resource-group $ResourceGroup `
            --profile-name $p.Standard `
            --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errText = ($commitOut | Out-String).Trim()
            Log "Commit FAILED for $($p.Standard): $errText" "ERR"
            Log "Standard is still in Migrating state - rerun with -OnlyProfiles $($p.Classic) -NoConfirm to retry, or -Rollback $($p.Classic) to delete" "ERR"
            $r.Status = "commit-failed"
            $r.Error  = $errText
            $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $results += $r
            Save-State -Plan $plan -Results $results
            continue
        }
        Log "Commit accepted" "OK"
        Log "Waiting $CommitWaitSec sec for commit to settle..."
        Start-Sleep -Seconds $CommitWaitSec
    }

    if (-not $SkipWatchdog -and $r.TestFqdn) {
        SubBanner "Phase 4 - Post-migration watchdog ($WatchdogSec sec) for $($p.Standard)"
        $deadline = (Get-Date).AddSeconds($WatchdogSec)
        $tick = 0
        $watchdogIssue = $false
        while ((Get-Date) -lt $deadline) {
            $tick++
            $code = ""
            $azref = ""
            $stamp = (Get-Date).ToString("HH:mm:ss")
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
                Time    = $stamp
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
        if ($watchdogIssue) {
            Log "Watchdog detected non-2xx/3xx responses during the window - inspect manually" "WARN"
        } else {
            Log "Watchdog clean - $($r.TestFqdn) returned 2xx/3xx for the full $WatchdogSec sec window" "OK"
        }
    }

    $stdProfile = az afd profile show -g $ResourceGroup --profile-name $p.Standard -o json 2>$null | ConvertFrom-Json
    if (-not $stdProfile) {
        Log "Could not read Standard profile $($p.Standard) post-commit" "ERR"
        $r.Status = "post-commit-readback-failed"
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }

    $stdCdText = az afd custom-domain list -g $ResourceGroup --profile-name $p.Standard --query "[].[name, hostName, domainValidationState]" -o tsv 2>$null
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
    Log "$($stdCustomDomains.Count) custom domain(s) on new Standard"
    $r.PostCDs = @($stdCustomDomains | ForEach-Object { "$($_.HostName) [$($_.ValidationState)]" })

    $stdEpMap = @{}
    $stdEpText2 = az afd endpoint list -g $ResourceGroup --profile-name $p.Standard --query "[].[name, hostName]" -o tsv 2>$null
    foreach ($line in @($stdEpText2 -split "`r?`n" | Where-Object { $_ })) {
        $cols = $line -split "`t"
        if ($cols.Count -ge 2) { $stdEpMap[$cols[0]] = $cols[1] }
    }

    foreach ($classicFE in $p.CustomDomains) {
        $matchStd = $stdCustomDomains | Where-Object { $_.HostName -ieq $classicFE.HostName } | Select-Object -First 1
        if (-not $matchStd) {
            Log "WARN: hostname $($classicFE.HostName) is on Classic but NOT on new Standard - migrate may have skipped it" "WARN"
            continue
        }

        $cnameTarget = "<UNKNOWN>"
        foreach ($epName in $stdEpMap.Keys) {
            $routeText = az afd route list -g $ResourceGroup --profile-name $p.Standard --endpoint-name $epName --query "[].customDomains[].id" -o tsv 2>$null
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
            Log "  Route lookup didn't match $($matchStd.Name); falling back to first endpoint: $cnameTarget" "WARN"
        }

        $txt = ""
        if ($matchStd.ValidationState -ne "Approved") {
            $txt = az afd custom-domain show -g $ResourceGroup --profile-name $p.Standard --custom-domain-name $matchStd.Name --query "validationProperties.validationToken" -o tsv 2>$null
        }

        $r.DnsRecords += [PSCustomObject]@{
            Hostname        = $classicFE.HostName
            ValidationState = $matchStd.ValidationState
            TxtValue        = $txt
            CnameTarget     = $cnameTarget
        }
        Log "  $($classicFE.HostName)" "OK"
        Log "    validation: $($matchStd.ValidationState)"
        if ($txt) { Log "    TXT _dnsauth.$($classicFE.HostName.Split('.')[0])  ->  $txt" }
        Log "    CNAME $($classicFE.HostName.Split('.')[0])  ->  $cnameTarget"
    }

    $r.Status = "migrated-and-committed"
    $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $results += $r
    Save-State -Plan $plan -Results $results
}

$verifyResults = @()
if (-not $SkipVerifyAlso -and $VerifyAlsoStandard.Count -gt 0) {
    Banner "Phase 4.5 - Verify-only health check on existing Standard profiles"
    foreach ($vName in $VerifyAlsoStandard) {
        SubBanner "Verify-only: $vName"
        $vr = [PSCustomObject]@{
            Standard        = $vName
            Status          = "pending"
            Error           = ""
            CustomDomains   = @()
            Endpoints       = @()
            CertStates      = @()
            CurlChecks      = @()
            SnapshotPath    = ""
        }

        $stdId = az afd profile show -g $ResourceGroup --profile-name $vName --query id -o tsv 2>$null
        if (-not $stdId) {
            Log "Standard profile '$vName' NOT FOUND in $ResourceGroup - SKIP" "WARN"
            $vr.Status = "not-found"
            $verifyResults += $vr
            continue
        }
        Log "Standard resource ID: $stdId" "OK"

        $snapPath = Join-Path $snapshotDir "$vName-standard-snapshot.json"
        az afd profile show -g $ResourceGroup --profile-name $vName -o json 2>$null | Set-Content -Path $snapPath -Encoding ASCII
        $vr.SnapshotPath = $snapPath
        Log "Snapshot saved: $snapPath" "OK"

        $cdText = az afd custom-domain list -g $ResourceGroup --profile-name $vName --query "[].[name, hostName, domainValidationState]" -o tsv 2>$null
        foreach ($line in @($cdText -split "`r?`n" | Where-Object { $_ })) {
            $cols = $line -split "`t"
            if ($cols.Count -ge 2) {
                $vr.CustomDomains += [PSCustomObject]@{
                    Name            = $cols[0]
                    HostName        = $cols[1]
                    ValidationState = if ($cols.Count -ge 3) { $cols[2] } else { "" }
                }
            }
        }
        Log "$($vr.CustomDomains.Count) custom domain(s) on $vName"

        $epText = az afd endpoint list -g $ResourceGroup --profile-name $vName --query "[].hostName" -o tsv 2>$null
        $vr.Endpoints = @($epText -split "`r?`n" | Where-Object { $_ })
        Log "$($vr.Endpoints.Count) endpoint(s) on $vName"

        $checkTargets = @()
        foreach ($cd in $vr.CustomDomains) { $checkTargets += $cd.HostName }
        if ($checkTargets.Count -eq 0 -and $vr.Endpoints.Count -gt 0) { $checkTargets += $vr.Endpoints[0] }

        foreach ($host in $checkTargets) {
            $tickResults = @()
            for ($i = 1; $i -le $VerifyOnlyTickCount; $i++) {
                $code = ""
                $azref = ""
                try {
                    $resp = Invoke-WebRequest -Uri "https://$host/" -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                    $code  = $resp.StatusCode
                    $azref = $resp.Headers["x-azure-ref"]
                } catch {
                    $code = "ERR: $($_.Exception.Message.Substring(0, [Math]::Min(80, $_.Exception.Message.Length)))"
                }
                $tickResults += [PSCustomObject]@{ Tick = $i; Code = $code; AzRef = $azref }
                $msg = "verify $vName -> https://$host/  tick $i  status $code"
                if ($azref) { $msg += "  x-azure-ref: $($azref.Substring(0, [Math]::Min(40, $azref.Length)))" }
                if ("$code" -match '^(2|3)\d\d$') { Log $msg "OK" } else { Log $msg "WARN" }
                if ($i -lt $VerifyOnlyTickCount) { Start-Sleep -Seconds 5 }
            }
            $vr.CurlChecks += [PSCustomObject]@{ Hostname = $host; Ticks = $tickResults }
        }

        foreach ($cd in $vr.CustomDomains) {
            $vr.CertStates += [PSCustomObject]@{
                Hostname        = $cd.HostName
                ValidationState = $cd.ValidationState
            }
        }

        $allOk = $true
        foreach ($cc in $vr.CurlChecks) {
            foreach ($t in $cc.Ticks) {
                if (-not ("$($t.Code)" -match '^(2|3)\d\d$')) { $allOk = $false }
            }
        }
        foreach ($cs in $vr.CertStates) {
            if ($cs.ValidationState -and $cs.ValidationState -ne "Approved") { $allOk = $false }
        }
        $vr.Status = if ($allOk) { "verified-healthy" } else { "verified-degraded" }
        Log "Verify-only result for $vName : $($vr.Status)" $(if ($allOk) { "OK" } else { "WARN" })
        $verifyResults += $vr
    }
} else {
    if ($SkipVerifyAlso) { Log "SkipVerifyAlso=true - skipping Phase 4.5" "WARN" }
}

Banner "Phase 5 - Aggregate DNS handoff + summary"

$migrated = @($results | Where-Object { $_.Status -eq "migrated-and-committed" })
$rolled   = @($results | Where-Object { $_.Status -in @("rolled-back","cdn-rollback-by-operator") })
$pending  = @($results | Where-Object { $_.Status -in @("migrated-not-committed","cdn-portal-skip") })
$failed   = @($results | Where-Object { $_.Status -in @("migrate-failed","commit-failed","rollback-failed","post-commit-readback-failed","cdn-portal-target-not-found") })

Write-Host ""
Write-Host "   ===============================================================================" -ForegroundColor Green
Write-Host "   DNS RECORDS  -  hand to DNS owner (Maryfin)" -ForegroundColor Green
Write-Host "   ===============================================================================" -ForegroundColor Green
foreach ($r in $migrated) {
    Write-Host ""
    Write-Host "   [$($r.Standard)]  (was Classic $($r.Classic))" -ForegroundColor Yellow
    foreach ($d in $r.DnsRecords) {
        $hostShort = $d.Hostname.Split('.')[0]
        Write-Host "       Domain : $($d.Hostname)" -ForegroundColor White
        Write-Host "       Validation state: $($d.ValidationState)" -ForegroundColor Gray
        if ($d.TxtValue) {
            Write-Host "       TXT   _dnsauth.$hostShort  =  $($d.TxtValue)   (TTL 300)  -- ADD FIRST" -ForegroundColor Cyan
        } else {
            Write-Host "       TXT   (not needed - cert already validated)" -ForegroundColor Gray
        }
        Write-Host "       CNAME $hostShort           =  $($d.CnameTarget)   (TTL 300)  -- ADD AFTER CERT APPROVED" -ForegroundColor Cyan
        Write-Host ""
    }
}
Write-Host "   ===============================================================================" -ForegroundColor Green
Write-Host ""
if ($rolled.Count -gt 0) {
    Write-Host "   ROLLED BACK (Classic restored):" -ForegroundColor Yellow
    foreach ($r in $rolled) { Write-Host "       $($r.Classic)  (Standard $($r.Standard) was deleted)" -ForegroundColor Yellow }
    Write-Host ""
}
if ($pending.Count -gt 0) {
    Write-Host "   PENDING COMMIT (Standard exists in Migrating state):" -ForegroundColor Cyan
    foreach ($r in $pending) { Write-Host "       $($r.Classic) -> $($r.Standard)  (rerun with -OnlyProfiles $($r.Classic) to commit, or -Rollback $($r.Classic) to delete)" -ForegroundColor Cyan }
    Write-Host ""
}
if ($failed.Count -gt 0) {
    Write-Host "   FAILURES:" -ForegroundColor Red
    foreach ($f in $failed) {
        Write-Host "       $($f.Classic) -> $($f.Standard) :  $($f.Status)" -ForegroundColor Red
        if ($f.Error) { Write-Host "         $($f.Error.Substring(0, [Math]::Min(160, $f.Error.Length)))" -ForegroundColor Red }
    }
    Write-Host ""
}

$rowsHtml = @()
foreach ($r in $migrated) {
    foreach ($d in $r.DnsRecords) {
        $hostShort = $d.Hostname.Split('.')[0]
        $txtRow = if ($d.TxtValue) {
            "<tr><td rowspan='2'><b>$($d.Hostname)</b><br/><span style='color:#555'>via $($r.Standard)</span></td><td><span class='tag txt'>TXT</span></td><td><code>_dnsauth.$hostShort</code></td><td><code>$($d.TxtValue)</code></td><td>300</td><td>Step 1 - publish first</td></tr>"
        } else {
            "<tr><td rowspan='2'><b>$($d.Hostname)</b><br/><span style='color:#555'>via $($r.Standard)</span></td><td><span class='tag txt'>TXT</span></td><td colspan='4'><i>not needed - cert already validated by Azure during migration</i></td></tr>"
        }
        $rowsHtml += $txtRow
        $rowsHtml += "<tr><td><span class='tag cn'>CNAME</span></td><td><code>$hostShort</code></td><td><code>$($d.CnameTarget)</code></td><td>300</td><td>Step 2 - publish after cert state Approved</td></tr>"
    }
}
$rowsHtmlJoined = ($rowsHtml -join "`n")
if ($migrated.Count -eq 0) { $rowsHtmlJoined = "<tr><td colspan='6'>No successful committed migrations.</td></tr>" }

$dnsHtml = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>PYX Front Door - DNS records to publish</title>
<style>body{font-family:Segoe UI,Arial;max-width:1200px;margin:30px auto;padding:0 24px;color:#11151C;line-height:1.55}
h1{color:#1F3D7A;border-bottom:2px solid #1F3D7A;padding-bottom:8px}
h2{color:#1F3D7A;font-size:16px;margin-top:24px}
table{width:100%;border-collapse:collapse;margin:10px 0;font-size:13px}
th{background:#F5F7FA;padding:10px;text-align:left;border-bottom:2px solid #1F3D7A;color:#1F3D7A}
td{padding:10px;border-bottom:1px solid #E5E8EE;vertical-align:top}
code{font-family:Consolas,monospace;font-size:12px;background:#F5F7FA;padding:2px 6px;border-radius:3px;word-break:break-all}
.tag{display:inline-block;padding:2px 8px;border-radius:3px;font-size:11px;font-weight:600;color:#fff}
.tag.txt{background:#1B6B3A}.tag.cn{background:#1F3D7A}
.note{background:#FFF8E1;border-left:3px solid #F5A623;padding:10px 14px;margin:14px 0;font-size:13px}
.foot{margin-top:30px;padding-top:12px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px}
</style></head><body>
<h1>PYX Front Door - DNS records to publish</h1>
<p>$($migrated.Count) profile(s) migrated and committed to AFD Standard via Azure's atomic migration API. Records to publish below.</p>
<div class='note'><b>Order of operations (per domain):</b><ol>
<li>If a TXT record is shown, publish it first (validates AFD managed cert).</li>
<li>Wait until the cert state shows <i>Approved</i> (5-30 min).</li>
<li>Publish the CNAME (cuts traffic over to the new Standard endpoint).</li>
<li>TTL is 300 sec for fast rollback.</li>
</ol></div>
<table>
<thead><tr><th>Domain</th><th>Type</th><th>Host</th><th>Value</th><th>TTL</th><th>When</th></tr></thead>
<tbody>
$rowsHtmlJoined
</tbody></table>
<h2>Cert validation polling</h2>
<p>Per migrated domain, poll until <code>domainValidationState</code> = <code>Approved</code>:</p>
<pre style='background:#0F172A;color:#E2E8F0;padding:12px;border-radius:6px;font-family:Consolas,monospace;font-size:12px;overflow-x:auto'>az afd custom-domain show -g $ResourceGroup --profile-name [std-profile] --custom-domain-name [cd-name] --query domainValidationState -o tsv</pre>
<h2>Verification (after CNAME flip)</h2>
<pre style='background:#0F172A;color:#E2E8F0;padding:12px;border-radius:6px;font-family:Consolas,monospace;font-size:12px;overflow-x:auto'>nslookup [hostname]
curl.exe -I https://[hostname]/</pre>
<p>Should resolve through <code>*.z02.azurefd.net</code> with <code>x-azure-ref</code> header in the response.</p>
<div class='foot'>Prepared by Syed Rizvi - PYX Health Production - $(Get-Date -Format 'yyyy-MM-dd')</div>
</body></html>
"@
Set-Content -Path $dnsHtmlPath -Value $dnsHtml -Encoding ASCII

Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
$summaryRows = ($results | ForEach-Object {
    $color = switch ($_.Status) {
        "migrated-and-committed"     {"#1B6B3A"}
        "rolled-back"                {"#B7791F"}
        "cdn-rollback-by-operator"   {"#B7791F"}
        "migrated-not-committed"     {"#1F3D7A"}
        "cdn-portal-skip"            {"#1F3D7A"}
        "dryrun"                     {"#555E6D"}
        default                      {"#9B2226"}
    }
    $errCell = if ($_.Error) {
        $safe = if ($_.Error.Length -gt 160) { $_.Error.Substring(0,160) } else { $_.Error }
        "<code>$([System.Web.HttpUtility]::HtmlEncode($safe))</code>"
    } else { "-" }
    "<tr><td><b>$($_.Classic)</b></td><td><code>$($_.MigrationType)</code></td><td><code>$($_.Standard)</code></td><td><code>$($_.Decision)</code></td><td style='color:$color'><b>$($_.Status)</b></td><td>$($_.DnsRecords.Count)</td><td>$errCell</td></tr>"
}) -join "`n"

$summaryHtml = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>PYX atomic migration summary</title>
<style>body{font-family:Segoe UI,Arial;max-width:1100px;margin:30px auto;padding:0 24px;color:#11151C}
h1{color:#1F3D7A;border-bottom:2px solid #1F3D7A;padding-bottom:8px}
table{width:100%;border-collapse:collapse;margin:10px 0;font-size:13px}
th{background:#F5F7FA;padding:10px;text-align:left;border-bottom:2px solid #1F3D7A;color:#1F3D7A}
td{padding:10px;border-bottom:1px solid #E5E8EE}
code{font-family:Consolas,monospace;font-size:12px;background:#F5F7FA;padding:2px 6px;border-radius:3px}
.foot{margin-top:30px;padding-top:12px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px}
</style></head><body>
<h1>PYX atomic Front Door migration - summary</h1>
<p>Run timestamp: $timestamp</p>
<p>Migrated &amp; committed: $($migrated.Count) &middot; Rolled back: $($rolled.Count) &middot; Pending commit: $($pending.Count) &middot; Failed: $($failed.Count) &middot; Total: $($results.Count)</p>
<p>Snapshot dossier (for any post-commit recovery): <code>$snapshotDir</code></p>
<table>
<thead><tr><th>Classic profile</th><th>Type</th><th>New Standard</th><th>Operator decision</th><th>Status</th><th>DNS records</th><th>Error</th></tr></thead>
<tbody>
$summaryRows
</tbody></table>
<div class='foot'>Prepared by Syed Rizvi - PYX Health Production - $(Get-Date -Format 'yyyy-MM-dd')</div>
</body></html>
"@
Set-Content -Path $summaryPath -Value $summaryHtml -Encoding ASCII

$endTime = Get-Date
$durationMin = [Math]::Round(($endTime - $startTime).TotalMinutes, 1)

$changeCards = @()
foreach ($r in $results) {
    $statusColor = switch ($r.Status) {
        "migrated-and-committed"     {"#1B6B3A"}
        "rolled-back"                {"#B7791F"}
        "cdn-rollback-by-operator"   {"#B7791F"}
        "migrated-not-committed"     {"#1F3D7A"}
        "cdn-portal-skip"            {"#1F3D7A"}
        "dryrun"                     {"#555E6D"}
        default                      {"#9B2226"}
    }

    $methodLabel = "Atomic API (az afd profile migrate + migration-commit)$(if ($r.MigrationType -eq 'CDN') { ' - source: Microsoft CDN Classic' } else { '' })"
    $skuLabel = if ($r.CdnSku) { "$($r.MigrationType) ($($r.CdnSku))" } else { $r.MigrationType }

    $preCdRows = if ($r.PreCDs -and $r.PreCDs.Count -gt 0) {
        ($r.PreCDs | ForEach-Object { "<li><code>$_</code></li>" }) -join ""
    } else { "<li><i>none</i></li>" }

    $postCdRows = if ($r.PostCDs -and $r.PostCDs.Count -gt 0) {
        ($r.PostCDs | ForEach-Object { "<li><code>$_</code></li>" }) -join ""
    } else { "<li><i>not captured (status: $($r.Status))</i></li>" }

    $watchHtml = ""
    $watchRate = "n/a"
    if ($r.WatchdogTicks -and $r.WatchdogTicks.Count -gt 0) {
        $okCount = @($r.WatchdogTicks | Where-Object { $_.Healthy }).Count
        $totalTicks = $r.WatchdogTicks.Count
        $watchRate = "$okCount / $totalTicks (" + [Math]::Round(($okCount / $totalTicks) * 100, 1) + "%)"
        $tickRows = ($r.WatchdogTicks | ForEach-Object {
            $tColor = if ($_.Healthy) { "#1B6B3A" } else { "#9B2226" }
            "<tr><td>$($_.Tick)</td><td>$($_.Time)</td><td><code>$($_.Url)</code></td><td style='color:$tColor'><b>$($_.Code)</b></td><td><code>$($_.AzRef)</code></td></tr>"
        }) -join "`n"
        $rateColor = if ($okCount -eq $totalTicks) { "#1B6B3A" } else { "#B7791F" }
        $watchHtml = "<h3>Watchdog verification</h3><p>Health check success rate: <b style='color:$rateColor;font-size:15px'>$watchRate</b> across the $WatchdogSec sec window after commit.</p><table><thead><tr><th>#</th><th>Time</th><th>URL</th><th>HTTP code</th><th>x-azure-ref</th></tr></thead><tbody>$tickRows</tbody></table>"
    } else {
        $watchHtml = "<h3>Watchdog verification</h3><p><i>No watchdog ticks recorded (skipped or no test FQDN available).</i></p>"
    }

    $endpointsList = if ($r.AllNewEndpoints -and $r.AllNewEndpoints.Count -gt 0) {
        ($r.AllNewEndpoints | ForEach-Object { "<li><code>https://$_/</code></li>" }) -join ""
    } else { "<li><i>none recorded</i></li>" }

    $dnsHtml2 = ""
    if ($r.DnsRecords -and $r.DnsRecords.Count -gt 0) {
        $dnsRows = ($r.DnsRecords | ForEach-Object {
            $hostShort = $_.Hostname.Split('.')[0]
            $txtPart = if ($_.TxtValue) { "<code>_dnsauth.$hostShort</code> TXT <code>$($_.TxtValue)</code>" } else { "<i>cert pre-validated, no TXT needed</i>" }
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
    <tr><td>Source resource ID</td><td><code style='font-size:11px'>$($r.ClassicResourceId)</code></td></tr>
    <tr><td>Migration method</td><td>$methodLabel</td></tr>
    <tr><td>validate-migration</td><td><code>$($r.ValidateResult)</code></td></tr>
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
$changeCardsJoined = $changeCards -join "`n"
if ($results.Count -eq 0) { $changeCardsJoined = "<p><i>No profiles processed.</i></p>" }

$snapFiles = @()
if (Test-Path $snapshotDir) {
    $snapFiles = Get-ChildItem -Path $snapshotDir -File -ErrorAction SilentlyContinue | ForEach-Object { "<li><code>$($_.Name)</code> ($([Math]::Round($_.Length/1KB,1)) KB)</li>" }
}
$snapFilesJoined = if ($snapFiles.Count -gt 0) { $snapFiles -join "" } else { "<li><i>no snapshot files found</i></li>" }

$logTailHtml = "<i>log file not readable</i>"
if (Test-Path $logPath) {
    $tail = Get-Content -Path $logPath -Tail 80 -ErrorAction SilentlyContinue
    if ($tail) {
        $tailEsc = ($tail | ForEach-Object { [System.Web.HttpUtility]::HtmlEncode($_) }) -join "`n"
        $logTailHtml = "<pre style='background:#0F172A;color:#E2E8F0;padding:12px;border-radius:6px;font-family:Consolas,monospace;font-size:11px;overflow-x:auto;max-height:400px;overflow-y:auto'>$tailEsc</pre>"
    }
}

$changeReportHtml = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>PYX migration change report - $timestamp</title>
<style>
body{font-family:Segoe UI,Arial;max-width:1200px;margin:30px auto;padding:0 24px;color:#11151C;line-height:1.55}
h1{color:#1F3D7A;border-bottom:2px solid #1F3D7A;padding-bottom:8px}
h2{color:#1F3D7A;font-size:18px;margin-top:18px;margin-bottom:8px}
h3{color:#1F3D7A;font-size:14px;margin-top:18px;margin-bottom:6px;border-bottom:1px solid #E5E8EE;padding-bottom:4px}
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
<p>Detailed evidence of every change made during the migration window. Includes per-profile source state, migration method, operator decisions, post-migration verification, and rollback artifacts.</p>

<div class='summary'>
<table class='kv'>
<tr><td>Run timestamp</td><td><code>$timestamp</code></td></tr>
<tr><td>Started</td><td>$($startTime.ToString("yyyy-MM-dd HH:mm:ss"))</td></tr>
<tr><td>Ended</td><td>$($endTime.ToString("yyyy-MM-dd HH:mm:ss"))</td></tr>
<tr><td>Duration</td><td>$durationMin minutes</td></tr>
<tr><td>Subscription</td><td><code>$SubscriptionId</code></td></tr>
<tr><td>Resource group</td><td><code>$ResourceGroup</code></td></tr>
<tr><td>Profiles in scope</td><td>$($results.Count)</td></tr>
<tr><td>Migrated and committed</td><td><span class='bigcount' style='color:#1B6B3A'>$($migrated.Count)</span></td></tr>
<tr><td>Rolled back</td><td><span class='bigcount' style='color:#B7791F'>$($rolled.Count)</span></td></tr>
<tr><td>Pending / skipped</td><td><span class='bigcount' style='color:#1F3D7A'>$($pending.Count)</span></td></tr>
<tr><td>Failed</td><td><span class='bigcount' style='color:#9B2226'>$($failed.Count)</span></td></tr>
</table>
</div>

<h2>Per-profile change detail</h2>
$changeCardsJoined

<h2>Snapshot dossier (rollback artifacts)</h2>
<p>Full pre-migration JSON snapshots are stored at <code>$snapshotDir</code> and are required for any post-commit recovery scenario:</p>
<ul>$snapFilesJoined</ul>

<h2>Run log (last 80 lines)</h2>
$logTailHtml

<h2>Companion artifacts</h2>
<ul>
<li>DNS handoff (Maryfin): <code>$dnsHtmlPath</code></li>
<li>Migration summary: <code>$summaryPath</code></li>
<li>Full run log: <code>$logPath</code></li>
<li>State JSON (machine-readable): <code>$statePath</code></li>
</ul>

<div class='foot'>Prepared by Syed Rizvi - PYX Health Production - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</body></html>
"@
Set-Content -Path $changePath -Value $changeReportHtml -Encoding ASCII

Banner "DONE"
Log "Migrated & committed: $($migrated.Count)  -  Rolled back: $($rolled.Count)  -  Pending: $($pending.Count)  -  Failed: $($failed.Count)" "OK"
Log ""
Log "Artifacts:"
Log "  Run log         : $logPath"
Log "  Snapshot dir    : $snapshotDir   (DO NOT DELETE - rollback dossier)"
Log "  State JSON      : $statePath"
Log "  DNS handoff HTML: $dnsHtmlPath  <- send to Maryfin"
Log "  Summary HTML    : $summaryPath"
Log "  Change report   : $changePath  <- detailed evidence for Tony"
if ($pending.Count -gt 0) {
    Log ""
    Log "PENDING COMMIT - rerun with -OnlyProfiles <name> -NoConfirm to finish, or -Rollback <name> to abort:" "WARN"
    foreach ($p2 in $pending) { Log "  $($p2.Classic) -> $($p2.Standard)" "WARN" }
}
if ($failed.Count -gt 0) {
    Log ""
    Log "FAILURES:" "WARN"
    foreach ($f in $failed) { Log "  $($f.Classic) -> $($f.Standard) : $($f.Status)" "WARN" }
}
exit 0
