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
    [string]$ApiVersion          = "2024-02-01",
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
    [string]$ReportDir           = (Join-Path $env:USERPROFILE "Desktop\pyx-atomic-migrate-report")
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"
$timestamp   = (Get-Date).ToString("yyyyMMdd-HHmmss")
$startTime   = Get-Date
if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
$snapshotDir = Join-Path $ReportDir "snapshots-$timestamp"
if (-not (Test-Path $snapshotDir)) { New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null }
$logPath     = Join-Path $ReportDir "rest-migrate-$timestamp.log"
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

Banner "PYX migration via Azure REST API (az rest) - bypasses missing CLI cmdlet"
Log "Profiles in scope: $($ProfileMap.Keys -join ', ')"
Log "API version:       $ApiVersion"
Log "Report dir:        $ReportDir"

Banner "Phase 0 - Login + sub list"
$acct = & az account show --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $acct) { Log "Not logged in - starting az login..." "WARN"; & az login --only-show-errors | Out-Null }
$acct = & az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $acct) { Log "Could not establish Azure session" "ERR"; exit 10 }
Log "Signed in: $($acct.user.name)" "OK"

$allSubsJson = & az account list --query "[?state=='Enabled'].{id:id,name:name}" -o json 2>$null
$allSubs = $allSubsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
Log "Tenant subscriptions enabled: $($allSubs.Count)"

Banner "Phase 1 - Multi-subscription discovery (per-sub iteration)"
$plan = @()
foreach ($cp in $ProfileMap.Keys) {
    SubBanner "Resolving: $cp"
    $found = $null
    foreach ($s in $allSubs) {
        try { & az account set --subscription $s.id --only-show-errors 2>&1 | Out-Null } catch { continue }
        $afdHit = ""
        try { $afdHit = & az resource list --name $cp --resource-type "Microsoft.Network/frontDoors" --query "[0].id" -o tsv --only-show-errors 2>$null } catch { $afdHit = "" }
        if ($afdHit -and $afdHit.StartsWith("/subscriptions/")) {
            $found = [PSCustomObject]@{ Type="AFD"; Sub=$s.id; Rg=$afdHit.Split("/")[4]; Id=$afdHit; Sku="" }
            break
        }
        $cdnHit = ""
        try { $cdnHit = & az resource list --name $cp --resource-type "Microsoft.Cdn/profiles" --query "[0].id" -o tsv --only-show-errors 2>$null } catch { $cdnHit = "" }
        if ($cdnHit -and $cdnHit.StartsWith("/subscriptions/")) {
            $cdnSku = & az cdn profile show --ids $cdnHit --query "sku.name" -o tsv --only-show-errors 2>$null
            $found = [PSCustomObject]@{ Type="CDN"; Sub=$s.id; Rg=$cdnHit.Split("/")[4]; Id=$cdnHit; Sku=$cdnSku }
            break
        }
    }
    if (-not $found) {
        Log "Profile '$cp' NOT FOUND - SKIP" "WARN"
        continue
    }
    Log "$($found.Type) found  sub=$($found.Sub)  rg=$($found.Rg)$(if ($found.Sku) { "  sku=$($found.Sku)" })" "OK"

    & az account set --subscription $found.Sub --only-show-errors 2>&1 | Out-Null

    $customFEs = @()
    if ($found.Type -eq "AFD") {
        $feText = & az network front-door frontend-endpoint list -g $found.Rg --front-door-name $cp --query "[].[name, hostName]" -o tsv 2>$null
        foreach ($line in @($feText -split "`r?`n" | Where-Object { $_ })) {
            $cols = $line -split "`t"
            if ($cols.Count -ge 2 -and $cols[1] -and $cols[1] -notlike "*.azurefd.net") {
                $customFEs += [PSCustomObject]@{ Name = $cols[0]; HostName = $cols[1] }
            }
        }
    } else {
        $cdnEpText = & az cdn endpoint list -g $found.Rg --profile-name $cp --query "[].name" -o tsv 2>$null
        $cdnEps = @($cdnEpText -split "`r?`n" | Where-Object { $_ })
        foreach ($ep in $cdnEps) {
            $cdText = & az cdn custom-domain list -g $found.Rg --profile-name $cp --endpoint-name $ep --query "[].[name, hostName]" -o tsv 2>$null
            foreach ($line in @($cdText -split "`r?`n" | Where-Object { $_ })) {
                $cols = $line -split "`t"
                if ($cols.Count -ge 2 -and $cols[1] -and $cols[1] -notlike "*.azureedge.net") {
                    $customFEs += [PSCustomObject]@{ Name = $cols[0]; HostName = $cols[1] }
                }
            }
        }
    }
    Log "$($customFEs.Count) custom domain(s)"
    foreach ($fe in $customFEs) { Log "  $($fe.HostName)" }

    $targetStd = $ProfileMap[$cp]
    $targetUrl = "https://management.azure.com/subscriptions/$($found.Sub)/resourceGroups/$($found.Rg)/providers/Microsoft.Cdn/profiles/$targetStd" + "?api-version=$ApiVersion"
    $targetCheck = & az rest --method GET --url $targetUrl --only-show-errors 2>$null
    $targetExists = ($LASTEXITCODE -eq 0 -and $targetCheck)
    if ($targetExists) {
        Log "Target Standard '$targetStd' already exists in $($found.Rg)" "WARN"
    } else {
        Log "Target Standard '$targetStd' available" "OK"
    }

    $plan += [PSCustomObject]@{
        Classic           = $cp
        ClassicResourceId = $found.Id
        SubscriptionId    = $found.Sub
        ResourceGroup     = $found.Rg
        MigrationType     = $found.Type
        CdnSku            = $found.Sku
        Standard          = $targetStd
        StandardExists    = [bool]$targetExists
        CustomDomains     = $customFEs
    }
}

if ($plan.Count -eq 0) { Log "No profiles in plan" "ERR"; exit 1 }

Banner "Phase 1.5 - Snapshot"
foreach ($p in $plan) {
    & az account set --subscription $p.SubscriptionId --only-show-errors 2>&1 | Out-Null
    $snapPath = Join-Path $snapshotDir "$($p.Classic)-classic-snapshot.json"
    if ($p.MigrationType -eq "AFD") {
        & az network front-door show -g $p.ResourceGroup --name $p.Classic -o json 2>$null | Set-Content -Path $snapPath -Encoding ASCII
    } else {
        & az cdn profile show -g $p.ResourceGroup --name $p.Classic -o json 2>$null | Set-Content -Path $snapPath -Encoding ASCII
    }
    Log "Snapshot: $snapPath" "OK"
}

Banner "Phase 2 - Plan"
$plan | ForEach-Object { Log "  $($_.Classic) ($($_.MigrationType)) -> $($_.Standard) in $($_.SubscriptionId)/$($_.ResourceGroup)" }

if ($DiscoveryOnly) { Log "DiscoveryOnly - stopping" "WARN"; exit 0 }

if (-not $NoConfirm) {
    $resp = Read-Host "Type YES to migrate $($plan.Count) profile(s) via REST API"
    if ($resp -ne "YES") { Log "Aborted" "WARN"; exit 0 }
}

Banner "Phase 3 - REST API migrate + commit per profile"

$results = @()
foreach ($p in $plan) {
    SubBanner "$($p.Classic) -> $($p.Standard)  via REST API"

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
        $r.Status = "dryrun"
        $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $results += $r
        Save-State -Plan $plan -Results $results
        continue
    }

    & az account set --subscription $p.SubscriptionId --only-show-errors 2>&1 | Out-Null

    if (-not $p.StandardExists) {
        $migUrl = "https://management.azure.com/subscriptions/$($p.SubscriptionId)/resourceGroups/$($p.ResourceGroup)/providers/Microsoft.Cdn/migrate?api-version=$ApiVersion"
        $migBody = @{
            sku = @{ name = $Sku }
            classicResourceReference = @{ id = $p.ClassicResourceId }
            profileName = $p.Standard
            migrationWebApplicationFirewallMappings = @()
        } | ConvertTo-Json -Depth 5 -Compress

        $bodyFile = Join-Path $env:TEMP "pyx-migrate-body-$($p.Classic)-$timestamp.json"
        Set-Content -Path $bodyFile -Value $migBody -Encoding ASCII

        Log "POST $migUrl"
        Log "Body: $migBody"
        $migOut = & az rest --method POST --url $migUrl --body "@$bodyFile" --only-show-errors 2>&1
        $migExit = $LASTEXITCODE
        Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue

        if ($migExit -ne 0) {
            $errText = ($migOut | Out-String).Trim()
            Log "REST migrate FAILED for $($p.Classic): $errText" "ERR"
            $r.Status = "migrate-failed"
            $r.Error  = $errText
            $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $results += $r
            Save-State -Plan $plan -Results $results
            continue
        }
        Log "REST migrate accepted - waiting $PostMigrateWaitSec sec for resource to settle..." "OK"
        Start-Sleep -Seconds $PostMigrateWaitSec
    } else {
        Log "Standard '$($p.Standard)' already exists - skipping migrate" "OK"
    }

    $stdShowUrl = "https://management.azure.com/subscriptions/$($p.SubscriptionId)/resourceGroups/$($p.ResourceGroup)/providers/Microsoft.Cdn/profiles/$($p.Standard)?api-version=$ApiVersion"
    $stdJson = & az rest --method GET --url $stdShowUrl --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    $migState = if ($stdJson -and $stdJson.properties -and $stdJson.properties.extendedProperties) { $stdJson.properties.extendedProperties.migrationState } else { "" }
    Log "Current migrationState: $migState"

    $epListUrl = "https://management.azure.com/subscriptions/$($p.SubscriptionId)/resourceGroups/$($p.ResourceGroup)/providers/Microsoft.Cdn/profiles/$($p.Standard)/afdEndpoints?api-version=$ApiVersion"
    $epJson = & az rest --method GET --url $epListUrl --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    $stdEndpoints = @()
    if ($epJson -and $epJson.value) {
        foreach ($ep in $epJson.value) { if ($ep.properties.hostName) { $stdEndpoints += $ep.properties.hostName } }
    }
    if ($stdEndpoints.Count -gt 0) { $r.TestFqdn = $stdEndpoints[0] }
    $r.AllNewEndpoints = $stdEndpoints

    $decision = "COMMIT"
    if (-not $AutoCommit) {
        Log "Test endpoints:"
        foreach ($ep in $stdEndpoints) { Log "  https://$ep/" }
        $decision = ""
        while ($decision -notin @("COMMIT","ROLLBACK","SKIP")) {
            $decision = (Read-Host "Decision for $($p.Classic) [COMMIT/ROLLBACK/SKIP]").Trim().ToUpper()
        }
    } else {
        Log "AutoCommit=true - proceeding to COMMIT" "WARN"
    }
    $r.Decision = $decision

    if ($decision -eq "ROLLBACK") {
        Log "Rolling back via DELETE on uncommitted Standard..."
        $delUrl = "https://management.azure.com/subscriptions/$($p.SubscriptionId)/resourceGroups/$($p.ResourceGroup)/providers/Microsoft.Cdn/profiles/$($p.Standard)?api-version=$ApiVersion"
        & az rest --method DELETE --url $delUrl --only-show-errors 2>&1 | Out-Null
        $r.Status = if ($LASTEXITCODE -eq 0) { "rolled-back" } else { "rollback-failed" }
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

    if ($migState -eq "Committed") {
        Log "Already committed" "OK"
    } else {
        $commitUrl = "https://management.azure.com/subscriptions/$($p.SubscriptionId)/resourceGroups/$($p.ResourceGroup)/providers/Microsoft.Cdn/profiles/$($p.Standard)/migrationCommit?api-version=$ApiVersion"
        Log "POST $commitUrl"
        $commitOut = & az rest --method POST --url $commitUrl --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errText = ($commitOut | Out-String).Trim()
            Log "REST commit FAILED: $errText" "ERR"
            $r.Status = "commit-failed"
            $r.Error  = $errText
            $r.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $results += $r
            Save-State -Plan $plan -Results $results
            continue
        }
        Log "REST commit accepted" "OK"
        Start-Sleep -Seconds $CommitWaitSec
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

    $cdListUrl = "https://management.azure.com/subscriptions/$($p.SubscriptionId)/resourceGroups/$($p.ResourceGroup)/providers/Microsoft.Cdn/profiles/$($p.Standard)/customDomains?api-version=$ApiVersion"
    $cdJson = & az rest --method GET --url $cdListUrl --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    $stdCustomDomains = @()
    if ($cdJson -and $cdJson.value) {
        foreach ($cd in $cdJson.value) {
            $stdCustomDomains += [PSCustomObject]@{
                Name            = $cd.name
                HostName        = $cd.properties.hostName
                ValidationState = $cd.properties.domainValidationState
                ValidationToken = $cd.properties.validationProperties.validationToken
            }
        }
    }
    $r.PostCDs = @($stdCustomDomains | ForEach-Object { "$($_.HostName) [$($_.ValidationState)]" })

    $primaryEp = if ($r.AllNewEndpoints.Count -gt 0) { $r.AllNewEndpoints[0] } else { "<UNKNOWN>" }
    foreach ($classicFE in $p.CustomDomains) {
        $matchStd = $stdCustomDomains | Where-Object { $_.HostName -ieq $classicFE.HostName } | Select-Object -First 1
        if (-not $matchStd) { continue }
        $r.DnsRecords += [PSCustomObject]@{
            Hostname        = $classicFE.HostName
            ValidationState = $matchStd.ValidationState
            TxtValue        = if ($matchStd.ValidationState -ne "Approved") { $matchStd.ValidationToken } else { "" }
            CnameTarget     = $primaryEp
        }
        Log "  $($classicFE.HostName) -> CNAME $primaryEp (cert: $($matchStd.ValidationState))" "OK"
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
<p>$($migrated.Count) profile(s) migrated and committed via REST API.</p>
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
<h1>PYX migration summary (REST API)</h1>
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
    <tr><td>Migration method</td><td>Azure REST API (az rest)</td></tr>
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
<h1>PYX migration change report (REST API)</h1>
<div class='summary'>
<table class='kv'>
<tr><td>Run timestamp</td><td><code>$timestamp</code></td></tr>
<tr><td>Started</td><td>$($startTime.ToString("yyyy-MM-dd HH:mm:ss"))</td></tr>
<tr><td>Ended</td><td>$($endTime.ToString("yyyy-MM-dd HH:mm:ss"))</td></tr>
<tr><td>Duration</td><td>$durationMin minutes</td></tr>
<tr><td>API version</td><td><code>$ApiVersion</code></td></tr>
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
