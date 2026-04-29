[CmdletBinding()]
param(
    [string]$SubscriptionId   = "e42e94b5-c6f8-4af0-a41b-16fda520de6e",
    [string]$ResourceGroup    = "production",
    [hashtable]$ProfileMap    = @{
        "hipyx"        = "hipyx-std-v2"
        "pyxiq"        = "pyxiq-std"
        "pyxiq-stage"  = "pyxiq-stage-std"
        "pypwa-stage"  = "pypwa-stage-std"
    },
    [string]$Sku              = "Standard_AzureFrontDoor",
    [string]$WafPolicyName    = "hipyxWafPolicy",
    [int]   $CommitWaitSec    = 30,
    [int]   $PostMigrateWaitSec = 60,
    [switch]$DryRun,
    [switch]$NoConfirm,
    [switch]$DiscoveryOnly,
    [switch]$SkipCommit,
    [string[]]$OnlyProfiles   = @(),
    [string]$ReportDir        = (Join-Path $env:USERPROFILE "Desktop\pyx-atomic-migrate-report")
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
$logPath     = Join-Path $ReportDir "atomic-migrate-$timestamp.log"
$dnsHtmlPath = Join-Path $ReportDir "dns-handoff-all-$timestamp.html"
$summaryPath = Join-Path $ReportDir "summary-$timestamp.html"

function Log {
    param([string]$Message, [string]$Level = "INFO")
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line = "[$stamp] [$Level] $Message"
    Add-Content -Path $logPath -Value $line
    $color = switch ($Level) { "OK" {"Green"} "WARN" {"Yellow"} "ERR" {"Red"} "STEP" {"Cyan"} default {"White"} }
    Write-Host $line -ForegroundColor $color
}
function Banner($t) { Log ""; Log ("=" * 78); Log $t "STEP"; Log ("=" * 78) }
function SubBanner($t) { Log ""; Log ("-" * 78); Log $t "STEP"; Log ("-" * 78) }

# Filter scope if -OnlyProfiles passed
if ($OnlyProfiles.Count -gt 0) {
    $filtered = @{}
    foreach ($p in $OnlyProfiles) { if ($ProfileMap.ContainsKey($p)) { $filtered[$p] = $ProfileMap[$p] } }
    $ProfileMap = $filtered
}

# ============================================================================
Banner "PYX atomic Front Door migration  -  Classic to Standard"
# ============================================================================
Log "Subscription:           $SubscriptionId"
Log "Resource group:         $ResourceGroup"
Log "Profiles in scope:      $($ProfileMap.Keys -join ', ')"
Log "Target Standard SKU:    $Sku"
Log "WAF policy (target):    $WafPolicyName"
Log "Commit wait:            $CommitWaitSec sec"
Log "Post-migrate verify:    $PostMigrateWaitSec sec"
Log "DryRun:                 $DryRun"
Log "NoConfirm:              $NoConfirm"
Log "DiscoveryOnly:          $DiscoveryOnly"
Log "SkipCommit:             $SkipCommit"
Log "Report dir:             $ReportDir"

# ============================================================================
Banner "Phase 0 - Pre-flight"
# ============================================================================
$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $acct) { Log "az login..." "WARN"; az login --only-show-errors | Out-Null }
az account set --subscription $SubscriptionId --only-show-errors | Out-Null
$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json
Log "Signed in as $($acct.user.name)" "OK"

$installed = az extension list --query "[?name=='front-door'].name" -o tsv 2>$null
if (-not $installed) { az extension add --name front-door --only-show-errors | Out-Null }
az extension update --name front-door --only-show-errors 2>$null | Out-Null
Log "front-door extension ready" "OK"

# ============================================================================
Banner "Phase 1 - Discovery"
# ============================================================================
$plan = @()
foreach ($cp in $ProfileMap.Keys) {
    SubBanner "Discovering Classic profile: $cp"
    $classicId = az network front-door show -g $ResourceGroup --name $cp --query id -o tsv 2>$null
    if (-not $classicId) {
        Log "Profile '$cp' NOT FOUND in $ResourceGroup - SKIP" "WARN"
        continue
    }
    Log "Classic resource ID: $classicId" "OK"

    # Custom domains on Classic (filter out *.azurefd.net default)
    $feText = az network front-door frontend-endpoint list -g $ResourceGroup --front-door-name $cp --query "[].[name, hostName, customHttpsProvisioningState]" -o tsv 2>$null
    $customFEs = @()
    foreach ($line in @($feText -split "`r?`n" | Where-Object { $_ })) {
        $cols = $line -split "`t"
        if ($cols.Count -ge 2 -and $cols[1] -and $cols[1] -notlike "*.azurefd.net") {
            $customFEs += [PSCustomObject]@{
                Name = $cols[0]
                HostName = $cols[1]
                CertState = if ($cols.Count -ge 3) { $cols[2] } else { "" }
            }
        }
    }
    Log "$($customFEs.Count) custom domain(s) on $cp"
    foreach ($fe in $customFEs) { Log "  $($fe.HostName)  (endpoint: $($fe.Name), cert: $($fe.CertState))" }

    # Check if target Standard profile name is taken
    $targetStd = $ProfileMap[$cp]
    $targetExists = az afd profile show -g $ResourceGroup --profile-name $targetStd --query id -o tsv 2>$null
    $targetState = ""
    if ($targetExists) {
        $targetState = az afd profile show -g $ResourceGroup --profile-name $targetStd --query "extendedProperties.migrationState" -o tsv 2>$null
        if (-not $targetState) { $targetState = "<not from migration>" }
        Log "Target Standard '$targetStd' already exists (state: $targetState)" "WARN"
    } else {
        Log "Target Standard '$targetStd' available - will be created by migrate" "OK"
    }

    $plan += [PSCustomObject]@{
        Classic           = $cp
        ClassicResourceId = $classicId
        Standard          = $targetStd
        StandardExists    = [bool]$targetExists
        StandardState     = $targetState
        CustomDomains     = $customFEs
    }
}

if ($plan.Count -eq 0) { Log "No profiles to migrate. Exiting." "ERR"; exit 1 }

# ============================================================================
Banner "Phase 2 - Migration plan"
# ============================================================================
$plan | ForEach-Object {
    Log ""
    Log "  Classic:          $($_.Classic)" "STEP"
    Log "  -> Standard:      $($_.Standard)  ($(if ($_.StandardExists) { "EXISTS, state: $($_.StandardState)" } else { "will be created" }))"
    Log "  Custom domains:   $($_.CustomDomains.Count)"
    foreach ($d in $_.CustomDomains) { Log "    - $($d.HostName)" }
}

if ($DiscoveryOnly) {
    Log ""
    Log "DiscoveryOnly mode - stopping before any changes" "WARN"
    exit 0
}

# Sanity check: any Standard target that exists and is NOT from a prior migration is a hard stop
$badTargets = @($plan | Where-Object { $_.StandardExists -and $_.StandardState -ne "Migrated" -and $_.StandardState -ne "Migrating" })
if ($badTargets.Count -gt 0) {
    Log ""
    Log "STOP - the following target Standard profile names are already taken by NON-migrated profiles:" "ERR"
    foreach ($b in $badTargets) { Log "  $($b.Classic) -> $($b.Standard) (state: $($b.StandardState))" "ERR" }
    Log "Pick different target names via -ProfileMap or rename / delete the conflicting profile." "ERR"
    exit 2
}

# Confirmation gate
if (-not $NoConfirm) {
    Log ""
    Log "About to migrate $($plan.Count) Classic AFD profile(s) to Standard via atomic API." "WARN"
    Log "Each profile gets its own NEW Standard target (see plan above)." "WARN"
    Log "Custom domains, routes, origins, certs are transferred by Azure - no manual recreate." "WARN"
    Log "DNS owner must publish a CNAME flip per custom domain after migration." "WARN"
    if (-not $DryRun) {
        $resp = Read-Host "Type YES to proceed with the migration for ALL profiles above"
        if ($resp -ne "YES") { Log "Aborted by operator" "WARN"; exit 0 }
    } else {
        Log "DryRun mode - skipping confirmation" "WARN"
    }
}

# ============================================================================
Banner "Phase 3 - Per-profile atomic migration"
# ============================================================================

$results = @()
foreach ($p in $plan) {
    SubBanner "Migrating $($p.Classic)  ->  $($p.Standard)"

    $r = [PSCustomObject]@{
        Classic = $p.Classic
        Standard = $p.Standard
        Status = "pending"
        Error = ""
        DnsRecords = @()
    }

    if ($DryRun) {
        Log "DryRun - skipping actual migrate for $($p.Classic)" "WARN"
        $r.Status = "dryrun"
        $results += $r
        continue
    }

    # Step A - migrate (create new Standard from Classic)
    if (-not $p.StandardExists) {
        Log "Submitting migrate request: classic=$($p.Classic) -> standard=$($p.Standard)..."
        $migOut = az afd profile migrate `
            --resource-group $ResourceGroup `
            --profile-name $p.Standard `
            --classic-resource-id $p.ClassicResourceId `
            --sku $Sku `
            --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errText = ($migOut | Out-String).Trim()
            Log "Migrate failed for $($p.Classic): $errText" "ERR"
            $r.Status = "migrate-failed"
            $r.Error = $errText
            $results += $r
            continue
        }
        Log "Migrate accepted - Standard '$($p.Standard)' created in Migrating state" "OK"
        Log "Waiting $PostMigrateWaitSec sec for migration to settle..."
        Start-Sleep -Seconds $PostMigrateWaitSec
    } else {
        Log "Standard '$($p.Standard)' already exists (state: $($p.StandardState)) - skipping migrate, going to commit" "OK"
    }

    # Step B - commit
    if (-not $SkipCommit) {
        $currentState = az afd profile show -g $ResourceGroup --profile-name $p.Standard --query "extendedProperties.migrationState" -o tsv 2>$null
        Log "Pre-commit state: $currentState"
        if ($currentState -eq "Committed" -or $currentState -eq "Migrated") {
            Log "Already committed - skipping commit" "OK"
        } else {
            Log "Submitting migration-commit (this retires the Classic profile)..."
            $commitOut = az afd profile migration-commit `
                --resource-group $ResourceGroup `
                --profile-name $p.Standard `
                --only-show-errors 2>&1
            if ($LASTEXITCODE -ne 0) {
                $errText = ($commitOut | Out-String).Trim()
                Log "Commit failed for $($p.Standard): $errText" "ERR"
                $r.Status = "commit-failed"
                $r.Error = $errText
                $results += $r
                continue
            }
            Log "Commit accepted" "OK"
            Log "Waiting $CommitWaitSec sec for commit to settle..."
            Start-Sleep -Seconds $CommitWaitSec
        }
    } else {
        Log "SkipCommit=true - leaving Standard in Migrating state for review" "WARN"
        $r.Status = "migrated-not-committed"
        $results += $r
        continue
    }

    # Step C - discover what's on the new Standard, build DNS handoff
    $stdProfile = az afd profile show -g $ResourceGroup --profile-name $p.Standard -o json 2>$null | ConvertFrom-Json
    if (-not $stdProfile) {
        Log "Could not read Standard profile $($p.Standard) post-commit" "ERR"
        $r.Status = "post-commit-readback-failed"
        $results += $r
        continue
    }

    # List custom domains on new Standard
    $stdCdText = az afd custom-domain list -g $ResourceGroup --profile-name $p.Standard --query "[].[name, hostName, domainValidationState]" -o tsv 2>$null
    $stdCustomDomains = @()
    foreach ($line in @($stdCdText -split "`r?`n" | Where-Object { $_ })) {
        $cols = $line -split "`t"
        if ($cols.Count -ge 2) {
            $stdCustomDomains += [PSCustomObject]@{
                Name = $cols[0]
                HostName = $cols[1]
                ValidationState = if ($cols.Count -ge 3) { $cols[2] } else { "" }
            }
        }
    }
    Log "$($stdCustomDomains.Count) custom domain(s) on new Standard"

    # List endpoints on new Standard
    $stdEpText = az afd endpoint list -g $ResourceGroup --profile-name $p.Standard --query "[].[name, hostName]" -o tsv 2>$null
    $stdEndpoints = @{}
    foreach ($line in @($stdEpText -split "`r?`n" | Where-Object { $_ })) {
        $cols = $line -split "`t"
        if ($cols.Count -ge 2) { $stdEndpoints[$cols[0]] = $cols[1] }
    }

    # Match Classic custom domains to Standard ones, build DNS records
    foreach ($classicFE in $p.CustomDomains) {
        $matchStd = $stdCustomDomains | Where-Object { $_.HostName -ieq $classicFE.HostName } | Select-Object -First 1
        if (-not $matchStd) {
            Log "WARN: hostname $($classicFE.HostName) is on Classic but NOT on new Standard - migrate may have skipped it" "WARN"
            continue
        }

        # Walk routes to find which endpoint serves this custom-domain
        $cnameTarget = "<UNKNOWN>"
        foreach ($epName in $stdEndpoints.Keys) {
            $routeText = az afd route list -g $ResourceGroup --profile-name $p.Standard --endpoint-name $epName --query "[].customDomains[].id" -o tsv 2>$null
            $routeIds = @($routeText -split "`r?`n" | Where-Object { $_ })
            foreach ($rid in $routeIds) {
                if ($rid -match [regex]::Escape("/customDomains/$($matchStd.Name)")) {
                    $cnameTarget = $stdEndpoints[$epName]
                    break
                }
            }
            if ($cnameTarget -ne "<UNKNOWN>") { break }
        }
        if ($cnameTarget -eq "<UNKNOWN>" -and $stdEndpoints.Count -gt 0) {
            $cnameTarget = ($stdEndpoints.Values | Select-Object -First 1)
            Log "  Route lookup didn't match $($matchStd.Name); falling back to first endpoint: $cnameTarget" "WARN"
        }

        # Pull TXT validation token (only relevant if state isn't Approved)
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

    $r.Status = "migrated"
    $results += $r
}

# ============================================================================
Banner "Phase 4 - Aggregate DNS handoff"
# ============================================================================

$migrated = @($results | Where-Object { $_.Status -eq "migrated" })
$failed   = @($results | Where-Object { $_.Status -ne "migrated" -and $_.Status -ne "dryrun" })

# Console output - large readable banner per migrated profile
Write-Host ""
Write-Host "   ===============================================================================" -ForegroundColor Green
Write-Host "   DNS RECORDS  -  hand to DNS owner" -ForegroundColor Green
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
if ($failed.Count -gt 0) {
    Write-Host "   FAILURES:" -ForegroundColor Red
    foreach ($f in $failed) {
        Write-Host "       $($f.Classic) -> $($f.Standard) :  $($f.Status)" -ForegroundColor Red
        if ($f.Error) { Write-Host "         $($f.Error.Substring(0, [Math]::Min(140, $f.Error.Length)))" -ForegroundColor Red }
    }
    Write-Host ""
}

# HTML output for Maryfin / DNS owner
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
if ($migrated.Count -eq 0) { $rowsHtmlJoined = "<tr><td colspan='6'>No successful migrations.</td></tr>" }

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
<p>$($migrated.Count) profile(s) migrated to AFD Standard via Azure's atomic migration API. Records to publish below.</p>
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

# Summary HTML
$summaryRows = ($results | ForEach-Object {
    $color = switch ($_.Status) { "migrated" {"#1B6B3A"} "dryrun" {"#555E6D"} default {"#9B2226"} }
    $errCell = if ($_.Error) { "<code>$([System.Web.HttpUtility]::HtmlEncode($_.Error.Substring(0, [Math]::Min(160, $_.Error.Length))))</code>" } else { "-" }
    "<tr><td><b>$($_.Classic)</b></td><td><code>$($_.Standard)</code></td><td style='color:$color'><b>$($_.Status)</b></td><td>$($_.DnsRecords.Count)</td><td>$errCell</td></tr>"
}) -join "`n"

Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

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
<p>Migrated: $($migrated.Count) &middot; Failed: $($failed.Count) &middot; Total: $($results.Count)</p>
<table>
<thead><tr><th>Classic profile</th><th>New Standard profile</th><th>Status</th><th>DNS records</th><th>Error</th></tr></thead>
<tbody>
$summaryRows
</tbody></table>
<div class='foot'>Prepared by Syed Rizvi - PYX Health Production - $(Get-Date -Format 'yyyy-MM-dd')</div>
</body></html>
"@
Set-Content -Path $summaryPath -Value $summaryHtml -Encoding ASCII

Banner "DONE"
Log "Migrated: $($migrated.Count)  -  Failed: $($failed.Count)  -  Total: $($results.Count)" "OK"
Log ""
Log "Artifacts:"
Log "  Run log         : $logPath"
Log "  DNS handoff HTML: $dnsHtmlPath  <- send to DNS owner"
Log "  Summary HTML    : $summaryPath"
if ($failed.Count -gt 0) {
    Log ""
    Log "Failures (review log + Azure portal for next steps):" "WARN"
    foreach ($f in $failed) { Log "  $($f.Classic) -> $($f.Standard) : $($f.Status)" "WARN" }
}
exit 0
