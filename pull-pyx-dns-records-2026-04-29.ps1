[CmdletBinding()]
param(
    [hashtable]$ProfileMap = @{
        "pyxiq"        = "pyxiq-std"
        "hipyx"        = "hipyx-std-v2"
        "pyxiq-stage"  = "pyxiq-stage-std"
        "pyxpwa-stage" = "pyxpwa-stage-std"
        "standard"     = "standard-afdstd"
    },
    [string]$ReportDir = (Join-Path $env:USERPROFILE "Desktop\pyx-atomic-migrate-report")
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"
$timestamp   = (Get-Date).ToString("yyyyMMdd-HHmmss")
$startTime   = Get-Date
if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
$logPath     = Join-Path $ReportDir "dns-pull-$timestamp.log"
$dnsHtmlPath = Join-Path $ReportDir "dns-handoff-$timestamp.html"
$changePath  = Join-Path $ReportDir "change-report-$timestamp.html"

function Log {
    param([string]$Message, [string]$Level = "INFO")
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line  = "[$stamp] [$Level] $Message"
    Add-Content -Path $logPath -Value $line
    $color = switch ($Level) { "OK" {"Green"} "WARN" {"Yellow"} "ERR" {"Red"} "STEP" {"Cyan"} default {"White"} }
    Write-Host $line -ForegroundColor $color
}
function Banner($t) { Log ""; Log ("=" * 78); Log $t "STEP"; Log ("=" * 78) }

Banner "PYX post-migration DNS records pull (read-only)"
Log "Profiles to inspect: $($ProfileMap.Values -join ', ')"

Banner "Phase 0 - Module load + Connect-AzAccount"
foreach ($m in @("Az.Accounts","Az.Cdn","Az.Resources")) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Log "Installing $m..."
        Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module $m -ErrorAction Stop
}
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) { Connect-AzAccount -ErrorAction Stop | Out-Null; $ctx = Get-AzContext }
Log "Connected as: $($ctx.Account.Id)" "OK"

$allSubs = Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object { $_.State -eq "Enabled" }
Log "Subscriptions to scan: $($allSubs.Count)"

Banner "Phase 1 - Locate each new AFD Standard profile across all subs"
$results = @()
foreach ($cp in $ProfileMap.Keys) {
    $newName = $ProfileMap[$cp]
    Log "Searching for new profile: $newName  (was $cp)"
    $found = $null
    foreach ($s in $allSubs) {
        try { Set-AzContext -SubscriptionId $s.Id -ErrorAction Stop | Out-Null } catch { continue }
        $res = Get-AzResource -Name $newName -ResourceType "Microsoft.Cdn/profiles" -ErrorAction SilentlyContinue
        if ($res) {
            $found = [PSCustomObject]@{
                Classic     = $cp
                NewName     = $newName
                Sub         = $s.Id
                SubName     = $s.Name
                Rg          = $res.ResourceGroupName
                Id          = $res.ResourceId
            }
            break
        }
    }
    if (-not $found) {
        Log "  NOT FOUND - $newName has not been created yet (migration not done?)" "WARN"
        $results += [PSCustomObject]@{
            Classic = $cp; NewName = $newName; Sub = ""; Rg = ""; Status = "not-found"
            Endpoints = @(); CustomDomains = @(); DnsRecords = @()
        }
        continue
    }
    Log "  Found in $($found.Sub)/$($found.Rg)" "OK"
    Set-AzContext -SubscriptionId $found.Sub -ErrorAction SilentlyContinue | Out-Null

    $endpoints = @()
    try {
        $eps = Get-AzFrontDoorCdnEndpoint -ResourceGroupName $found.Rg -ProfileName $newName -ErrorAction SilentlyContinue
        foreach ($ep in $eps) {
            if ($ep.HostName) { $endpoints += $ep.HostName }
        }
    } catch {
        Log "  Could not enumerate endpoints: $($_.Exception.Message)" "WARN"
    }
    Log "  $($endpoints.Count) endpoint(s)"
    foreach ($e in $endpoints) { Log "    https://$e/" }

    $customDomains = @()
    $dnsRecords = @()
    try {
        $cds = Get-AzFrontDoorCdnCustomDomain -ResourceGroupName $found.Rg -ProfileName $newName -ErrorAction SilentlyContinue
        foreach ($cd in $cds) {
            $customDomains += [PSCustomObject]@{
                Name            = $cd.Name
                HostName        = $cd.HostName
                ValidationState = $cd.DomainValidationState
                ValidationToken = if ($cd.ValidationProperty) { $cd.ValidationProperty.ValidationToken } else { "" }
            }
            $primaryEp = if ($endpoints.Count -gt 0) { $endpoints[0] } else { "<UNKNOWN>" }
            $txt = if ($cd.DomainValidationState -ne "Approved" -and $cd.ValidationProperty) { $cd.ValidationProperty.ValidationToken } else { "" }
            $dnsRecords += [PSCustomObject]@{
                Hostname        = $cd.HostName
                ValidationState = $cd.DomainValidationState
                TxtValue        = $txt
                CnameTarget     = $primaryEp
            }
            Log "    $($cd.HostName) -> CNAME $primaryEp (cert: $($cd.DomainValidationState))" "OK"
        }
    } catch {
        Log "  Could not enumerate custom domains: $($_.Exception.Message)" "WARN"
    }

    $results += [PSCustomObject]@{
        Classic         = $cp
        NewName         = $newName
        Sub             = $found.Sub
        SubName         = $found.SubName
        Rg              = $found.Rg
        Id              = $found.Id
        Status          = if ($endpoints.Count -gt 0) { "migrated" } else { "found-but-no-endpoints" }
        Endpoints       = $endpoints
        CustomDomains   = $customDomains
        DnsRecords      = $dnsRecords
    }
}

Banner "Phase 2 - Generate DNS handoff HTML (Skye / Maryfin)"
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

$dnsRows = @()
foreach ($r in $results) {
    foreach ($d in $r.DnsRecords) {
        $hostShort = $d.Hostname.Split('.')[0]
        $txtPart = if ($d.TxtValue) {
            "<code>_dnsauth.$hostShort</code> TXT <code>$($d.TxtValue)</code>"
        } else {
            "<i>cert pre-validated, no TXT needed</i>"
        }
        $dnsRows += "<tr><td><b>$($d.Hostname)</b></td><td>$($d.ValidationState)</td><td>$txtPart</td><td><code>$hostShort</code> CNAME <code>$($d.CnameTarget)</code></td><td>$($r.SubName) / $($r.Rg)</td><td><code>$($r.NewName)</code></td></tr>"
    }
}
$dnsRowsJoined = if ($dnsRows.Count -gt 0) { $dnsRows -join "`n" } else { "<tr><td colspan='6'><i>No DNS records found. Verify migrations completed.</i></td></tr>" }

$dnsHtml = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>PYX FD - DNS handoff</title>
<style>body{font-family:Segoe UI,Arial;max-width:1200px;margin:30px auto;padding:0 24px;color:#11151C}
h1{color:#1F3D7A;border-bottom:2px solid #1F3D7A;padding-bottom:8px}
h2{color:#1F3D7A;font-size:16px;margin-top:24px}
table{width:100%;border-collapse:collapse;margin:10px 0;font-size:13px}
th{background:#F5F7FA;padding:10px;text-align:left;border-bottom:2px solid #1F3D7A;color:#1F3D7A}
td{padding:10px;border-bottom:1px solid #E5E8EE;vertical-align:top}
code{font-family:Consolas,monospace;font-size:12px;background:#F5F7FA;padding:2px 6px;border-radius:3px;word-break:break-all}
.note{background:#FFF8E1;border-left:3px solid #F5A623;padding:10px 14px;margin:14px 0;font-size:13px}
.foot{margin-top:30px;padding-top:12px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px}
</style></head><body>
<h1>PYX Front Door - DNS records to publish</h1>
<p>Run timestamp: $timestamp</p>
<div class='note'><b>Order of operations per domain:</b>
<ol>
<li>If a TXT record is shown, publish it first (this validates the AFD managed cert)</li>
<li>Wait until cert validation state shows <i>Approved</i> in Azure portal (5 to 30 min)</li>
<li>Publish the CNAME (cuts traffic over to the new AFD Standard endpoint)</li>
<li>TTL 300 sec for fast rollback if needed</li>
</ol></div>
<table>
<thead><tr><th>Domain</th><th>Cert state</th><th>TXT record</th><th>CNAME record</th><th>Sub / RG</th><th>New profile</th></tr></thead>
<tbody>
$dnsRowsJoined
</tbody></table>
<div class='foot'>Prepared by Syed Rizvi - PYX Health Production - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</body></html>
"@
Set-Content -Path $dnsHtmlPath -Value $dnsHtml -Encoding ASCII
Log "DNS handoff HTML: $dnsHtmlPath" "OK"

Banner "Phase 3 - Generate change-report HTML (Tony)"
$endTime = Get-Date
$durationMin = [Math]::Round(($endTime - $startTime).TotalMinutes, 1)

$cards = @()
foreach ($r in $results) {
    $statusColor = switch ($r.Status) {
        "migrated"               {"#1B6B3A"}
        "found-but-no-endpoints" {"#B7791F"}
        "not-found"              {"#9B2226"}
        default                  {"#555E6D"}
    }
    $epList = if ($r.Endpoints.Count -gt 0) {
        ($r.Endpoints | ForEach-Object { "<li><code>https://$_/</code></li>" }) -join ""
    } else { "<li><i>none</i></li>" }
    $cdList = if ($r.CustomDomains.Count -gt 0) {
        ($r.CustomDomains | ForEach-Object { "<li><code>$($_.HostName)</code> &mdash; cert: $($_.ValidationState)</li>" }) -join ""
    } else { "<li><i>no custom domains</i></li>" }

    $cards += @"
<div class='card'>
  <h2>$($r.Classic) <span style='color:#555'>migrated to</span> $($r.NewName)</h2>
  <table class='kv'>
    <tr><td>Status</td><td style='color:$statusColor'><b>$($r.Status)</b></td></tr>
    <tr><td>Subscription</td><td>$($r.SubName)<br/><code style='font-size:11px'>$($r.Sub)</code></td></tr>
    <tr><td>Resource group</td><td><code>$($r.Rg)</code></td></tr>
    <tr><td>New profile resource ID</td><td><code style='font-size:11px'>$($r.Id)</code></td></tr>
    <tr><td>Endpoints</td><td>$($r.Endpoints.Count)</td></tr>
    <tr><td>Custom domains</td><td>$($r.CustomDomains.Count)</td></tr>
  </table>
  <h3>AFD Standard endpoint hostnames</h3><ul>$epList</ul>
  <h3>Custom domains + cert validation states</h3><ul>$cdList</ul>
</div>
"@
}
$cardsJoined = if ($cards.Count -gt 0) { $cards -join "`n" } else { "<p><i>No profiles inspected.</i></p>" }

$migratedCount = @($results | Where-Object { $_.Status -eq "migrated" }).Count
$missingCount  = @($results | Where-Object { $_.Status -eq "not-found" }).Count
$totalDomains  = ($results | ForEach-Object { $_.CustomDomains.Count } | Measure-Object -Sum).Sum

$changeHtml = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>PYX migration change report - $timestamp</title>
<style>
body{font-family:Segoe UI,Arial;max-width:1200px;margin:30px auto;padding:0 24px;color:#11151C;line-height:1.55}
h1{color:#1F3D7A;border-bottom:2px solid #1F3D7A;padding-bottom:8px}
h2{color:#1F3D7A;font-size:18px;margin-top:18px}
h3{color:#1F3D7A;font-size:14px;margin-top:14px;border-bottom:1px solid #E5E8EE;padding-bottom:4px}
table{width:100%;border-collapse:collapse;margin:8px 0;font-size:13px}
table.kv td:first-child{width:220px;color:#555E6D;font-weight:600}
th{background:#F5F7FA;padding:8px 10px;text-align:left;border-bottom:2px solid #1F3D7A;color:#1F3D7A;font-size:12px}
td{padding:8px 10px;border-bottom:1px solid #E5E8EE;vertical-align:top}
code{font-family:Consolas,monospace;font-size:12px;background:#F5F7FA;padding:2px 6px;border-radius:3px;word-break:break-all}
ul{margin:6px 0;padding-left:22px}
.card{background:#FFF;border:1px solid #C8CFD9;border-radius:8px;padding:18px 22px;margin:18px 0}
.summary{background:#F5F7FA;border-left:4px solid #1F3D7A;padding:14px 18px}
.foot{margin-top:30px;padding-top:12px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px}
.bigcount{font-size:24px;font-weight:600}
</style></head><body>

<h1>PYX Front Door / CDN migration - change report</h1>
<p>Post-migration evidence pulled from Azure: per-profile state, endpoints, custom domains, certificate validation status, and DNS records to publish.</p>

<div class='summary'>
<table class='kv'>
<tr><td>Run timestamp</td><td><code>$timestamp</code></td></tr>
<tr><td>Pulled by</td><td>$($ctx.Account.Id)</td></tr>
<tr><td>Subscriptions scanned</td><td>$($allSubs.Count)</td></tr>
<tr><td>Profiles in scope</td><td>$($results.Count)</td></tr>
<tr><td>Migrated and visible</td><td><span class='bigcount' style='color:#1B6B3A'>$migratedCount</span></td></tr>
<tr><td>Not found (not yet migrated)</td><td><span class='bigcount' style='color:#9B2226'>$missingCount</span></td></tr>
<tr><td>Total custom domains</td><td>$totalDomains</td></tr>
<tr><td>Pull duration</td><td>$durationMin minutes</td></tr>
</table>
</div>

<h2>Per-profile detail</h2>
$cardsJoined

<h2>Companion artifact</h2>
<ul>
<li>DNS handoff HTML (for Skye / Maryfin): <code>$dnsHtmlPath</code></li>
<li>Run log: <code>$logPath</code></li>
</ul>

<div class='foot'>Prepared by Syed Rizvi - PYX Health Production - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</body></html>
"@
Set-Content -Path $changePath -Value $changeHtml -Encoding ASCII
Log "Change report HTML: $changePath" "OK"

Banner "DONE"
Log "Profiles migrated and visible: $migratedCount / $($results.Count)" "OK"
Log "Total custom domains found: $totalDomains" "OK"
Log "" "OK"
Log "Send to Skye:  $dnsHtmlPath"
Log "Send to Tony:  $changePath"
exit 0
