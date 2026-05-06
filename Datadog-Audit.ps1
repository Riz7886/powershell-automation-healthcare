[CmdletBinding()]
param(
    [string]$ApiKey,
    [string]$AppKey,
    [string]$Site = "us3.datadoghq.com",
    [int]$StaleMinutes = 30,
    [int]$NoTracesHours = 4,
    [string]$OutDir = (Join-Path $env:USERPROFILE "Desktop\datadog-audit")
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $ApiKey) { $ApiKey = (Read-Host -Prompt "Datadog API Key" -AsSecureString) | ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) } }
if (-not $AppKey) { $AppKey = (Read-Host -Prompt "Datadog Application Key" -AsSecureString) | ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) } }

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$runId      = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $OutDir "datadog-audit-$runId.html"
$jsonPath   = Join-Path $OutDir "datadog-audit-$runId.json"

$baseApi = "https://api.$Site"
$baseApp = "https://app.$Site"
$headers = @{
    "DD-API-KEY"         = $ApiKey
    "DD-APPLICATION-KEY" = $AppKey
    "Accept"             = "application/json"
}

function Write-Step($Text) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Invoke-DD {
    param([string]$Path)
    $uri = "$baseApi$Path"
    try {
        Invoke-RestMethod -Uri $uri -Headers $headers -Method GET -TimeoutSec 60
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.Response.StatusCode.value__ -eq 401) {
            throw "Datadog auth failed (401). Check API key + Application key + Site ($Site)."
        }
        if ($_.Exception.Response.StatusCode.value__ -eq 403) {
            throw "Datadog auth failed (403). Application key lacks scope for $Path."
        }
        throw "Datadog $Path failed: $msg"
    }
}

function HtmlEncode($s) {
    if ($null -eq $s) { return "" }
    [System.Net.WebUtility]::HtmlEncode([string]$s)
}

function Format-Age($unixSeconds) {
    if (-not $unixSeconds -or $unixSeconds -le 0) { return "never" }
    $ts = [datetimeoffset]::FromUnixTimeSeconds([int64]$unixSeconds).UtcDateTime
    $age = (Get-Date).ToUniversalTime() - $ts
    if ($age.TotalDays -ge 1)    { return ("{0:N1} days ago" -f $age.TotalDays) }
    if ($age.TotalHours -ge 1)   { return ("{0:N1} hours ago" -f $age.TotalHours) }
    if ($age.TotalMinutes -ge 1) { return ("{0:N0} min ago"   -f $age.TotalMinutes) }
    return "just now"
}

Write-Step "Datadog Health Audit - run $runId"
Write-Host "Site:     $Site"
Write-Host "OutDir:   $OutDir"
Write-Host "Stale:    monitors=No Data, hosts=$StaleMinutes min, services=$NoTracesHours hours"
Write-Host ""

Write-Step "[1/5] Validating credentials"
$validate = Invoke-DD -Path "/api/v1/validate"
if (-not $validate.valid) { throw "API key not valid for site $Site." }
Write-Host "  OK - API key valid" -ForegroundColor Green

Write-Step "[2/5] Pulling monitors"
$monitorsResp = Invoke-DD -Path "/api/v1/monitor"
$totalMonitors  = $monitorsResp.Count
$noDataMonitors = @($monitorsResp | Where-Object { $_.overall_state -eq "No Data" })
$alertMonitors  = @($monitorsResp | Where-Object { $_.overall_state -eq "Alert" })
$warnMonitors   = @($monitorsResp | Where-Object { $_.overall_state -eq "Warn" })
$okMonitors     = @($monitorsResp | Where-Object { $_.overall_state -eq "OK" })
$mutedMonitors  = @($monitorsResp | Where-Object { $_.options.silenced.Count -gt 0 })
$dbxMonitors    = @($monitorsResp | Where-Object { ($_.tags -join ',') -match '(?i)databricks' -or $_.name -match '(?i)\b(dbx|databricks)\b' })
Write-Host "  Total monitors:    $totalMonitors"
Write-Host "  OK (working):      $($okMonitors.Count)" -ForegroundColor Green
Write-Host "  ALERT:             $($alertMonitors.Count)" -ForegroundColor Red
Write-Host "  WARN:              $($warnMonitors.Count)" -ForegroundColor Yellow
Write-Host "  No-Data:           $($noDataMonitors.Count)" -ForegroundColor $(if ($noDataMonitors.Count -gt 0) {'Yellow'} else {'Green'})
Write-Host "  Muted:             $($mutedMonitors.Count)"
Write-Host "  Databricks-tagged: $($dbxMonitors.Count)" -ForegroundColor Cyan

Write-Step "[3/5] Pulling hosts"
$allHosts = @()
$start = 0
do {
    $hostsResp = Invoke-DD -Path "/api/v1/hosts?count=1000&start=$start&sort_field=last_reported_time&sort_dir=asc"
    if ($hostsResp.host_list) { $allHosts += $hostsResp.host_list }
    $start += 1000
} while ($hostsResp.host_list.Count -eq 1000)
$staleCutoff = (Get-Date).ToUniversalTime().AddMinutes(-1 * $StaleMinutes)
$staleHosts = @($allHosts | Where-Object {
    $lr = $_.last_reported_time
    if (-not $lr -or $lr -le 0) { return $true }
    ([datetimeoffset]::FromUnixTimeSeconds([int64]$lr).UtcDateTime) -lt $staleCutoff
})
Write-Host "  Total hosts:       $($allHosts.Count)"
Write-Host "  Stale hosts (>$StaleMinutes min): $($staleHosts.Count)" -ForegroundColor $(if ($staleHosts.Count -gt 0) {'Yellow'} else {'Green'})

Write-Step "[4/5] Pulling synthetic tests"
$pausedSynth = @()
try {
    $synthResp = Invoke-DD -Path "/api/v1/synthetics/tests"
    $totalSynth = $synthResp.tests.Count
    $pausedSynth = @($synthResp.tests | Where-Object { $_.status -eq "paused" })
    Write-Host "  Total synthetic tests: $totalSynth"
    Write-Host "  Paused tests:          $($pausedSynth.Count)" -ForegroundColor $(if ($pausedSynth.Count -gt 0) {'Yellow'} else {'Green'})
} catch {
    Write-Host "  Synthetic tests skipped: $($_.Exception.Message)" -ForegroundColor DarkYellow
    $totalSynth = 0
}

Write-Step "[5/5] Pulling APM services with no traces"
$staleServices = @()
$totalServices = 0
try {
    $svcResp = Invoke-DD -Path "/api/v2/services/definitions"
    $totalServices = if ($svcResp.data) { $svcResp.data.Count } else { 0 }
    $fromTs = [int64]((Get-Date).ToUniversalTime().AddHours(-1 * $NoTracesHours) - (Get-Date "1970-01-01").ToUniversalTime()).TotalSeconds
    $toTs   = [int64]((Get-Date).ToUniversalTime() - (Get-Date "1970-01-01").ToUniversalTime()).TotalSeconds
    foreach ($svc in $svcResp.data) {
        $serviceName = $svc.attributes.schema.'dd-service'
        if (-not $serviceName) { continue }
        $hits = 0
        foreach ($prefix in @("servlet","django","flask","rails","express","aspnet_core","http","grpc","rack")) {
            $q = "sum:trace.$prefix.request.hits{service:$serviceName}.as_count()"
            try {
                $metric = Invoke-DD -Path ("/api/v1/query?from=$fromTs&to=$toTs&query=" + [uri]::EscapeDataString($q))
                if ($metric.series -and $metric.series.Count -gt 0) {
                    foreach ($pt in $metric.series[0].pointlist) {
                        if ($pt[1] -gt 0) { $hits += $pt[1] }
                    }
                }
            } catch { }
            if ($hits -gt 0) { break }
        }
        if ($hits -eq 0) {
            $staleServices += [pscustomobject]@{
                Name = $serviceName
                Team = $svc.attributes.schema.team
                Type = $svc.attributes.schema.application
            }
        }
    }
    Write-Host "  Total APM services:        $totalServices"
    Write-Host "  Services with 0 traces in $NoTracesHours h: $($staleServices.Count)" -ForegroundColor $(if ($staleServices.Count -gt 0) {'Yellow'} else {'Green'})
} catch {
    Write-Host "  APM services skipped: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

Write-Step "Building HTML report"

$kpiTotal = $noDataMonitors.Count + $staleHosts.Count + $pausedSynth.Count + $staleServices.Count
$generated = Get-Date -Format "MMMM d, yyyy h:mm tt zzz"

$noDataMonitorsHtml = if ($noDataMonitors.Count -eq 0) { "<p class='ok'>No monitors in No-Data state.</p>" } else {
    $rows = $noDataMonitors | ForEach-Object {
        $tags = ($_.tags -join ", ")
        $modified = if ($_.modified) { ([datetime]$_.modified).ToString("yyyy-MM-dd HH:mm") } else { "" }
        $query = if ($_.query) { $_.query } else { "" }
        $link = "$baseApp/monitors/$($_.id)"
        "<tr><td><a href='$link' target='_blank'>$(HtmlEncode $_.name)</a></td><td>$(HtmlEncode $_.type)</td><td>$(HtmlEncode $modified)</td><td>$(HtmlEncode $tags)</td><td><code style='font-size:11px;color:#374151;word-break:break-all;'>$(HtmlEncode $query)</code></td></tr>"
    }
    "<table><thead><tr><th>Name</th><th>Type</th><th>Last Modified</th><th>Tags</th><th>Query</th></tr></thead><tbody>$($rows -join '')</tbody></table>"
}

$dbxStatusGroups = $dbxMonitors | Group-Object -Property overall_state
$dbxOk      = @($dbxMonitors | Where-Object { $_.overall_state -eq "OK" })
$dbxAlert   = @($dbxMonitors | Where-Object { $_.overall_state -eq "Alert" })
$dbxWarn    = @($dbxMonitors | Where-Object { $_.overall_state -eq "Warn" })
$dbxNoData  = @($dbxMonitors | Where-Object { $_.overall_state -eq "No Data" })
$dbxIgnored = @($dbxMonitors | Where-Object { $_.overall_state -in @("Skipped","Ignored","Unknown") -or -not $_.overall_state })

$dbxDetailRows = $dbxMonitors | Sort-Object @{Expression={
    switch ($_.overall_state) { "Alert" {1} "Warn" {2} "No Data" {3} "OK" {4} default {5} }
}}, name | ForEach-Object {
    $state = if ($_.overall_state) { $_.overall_state } else { "Unknown" }
    $stateClass = switch ($state) {
        "OK"      { "state-ok" }
        "Alert"   { "state-alert" }
        "Warn"    { "state-warn" }
        "No Data" { "state-nodata" }
        default   { "state-other" }
    }
    $tags = ($_.tags -join ", ")
    $query = if ($_.query) { $_.query } else { "" }
    $link = "$baseApp/monitors/$($_.id)"
    "<tr><td><span class='state-badge $stateClass'>$(HtmlEncode $state)</span></td><td><a href='$link' target='_blank'>$(HtmlEncode $_.name)</a></td><td>$(HtmlEncode $_.type)</td><td>$(HtmlEncode $tags)</td><td><code style='font-size:11px;color:#374151;word-break:break-all;'>$(HtmlEncode $query)</code></td></tr>"
}

$dbxDetailHtml = if ($dbxMonitors.Count -eq 0) { "<p class='ok'>No Databricks-tagged monitors found.</p>" } else {
    "<table><thead><tr><th style='width:90px;'>Status</th><th>Monitor Name</th><th style='width:90px;'>Type</th><th>Tags</th><th>Query</th></tr></thead><tbody>$($dbxDetailRows -join '')</tbody></table>"
}

$staleHostsHtml = if ($staleHosts.Count -eq 0) { "<p class='ok'>All hosts reporting within $StaleMinutes min.</p>" } else {
    $rows = $staleHosts | Sort-Object last_reported_time | ForEach-Object {
        $age = Format-Age $_.last_reported_time
        $apps = ($_.apps -join ", ")
        $link = "$baseApp/infrastructure?host_name=$([uri]::EscapeDataString($_.name))"
        "<tr><td><a href='$link' target='_blank'>$(HtmlEncode $_.name)</a></td><td>$(HtmlEncode $age)</td><td>$(HtmlEncode $apps)</td><td>$(HtmlEncode ($_.aliases -join ', '))</td></tr>"
    }
    "<table><thead><tr><th>Host</th><th>Last Reported</th><th>Integrations</th><th>Aliases</th></tr></thead><tbody>$($rows -join '')</tbody></table>"
}

$pausedSynthHtml = if ($pausedSynth.Count -eq 0) { "<p class='ok'>No paused synthetic tests.</p>" } else {
    $rows = $pausedSynth | ForEach-Object {
        $link = "$baseApp/synthetics/details/$($_.public_id)"
        "<tr><td><a href='$link' target='_blank'>$(HtmlEncode $_.name)</a></td><td>$(HtmlEncode $_.type)</td><td>$(HtmlEncode $_.subtype)</td><td>$(HtmlEncode ($_.tags -join ', '))</td></tr>"
    }
    "<table><thead><tr><th>Test Name</th><th>Type</th><th>Subtype</th><th>Tags</th></tr></thead><tbody>$($rows -join '')</tbody></table>"
}

$staleServicesHtml = if ($staleServices.Count -eq 0) { "<p class='ok'>All APM services reporting traces within $NoTracesHours h.</p>" } else {
    $rows = $staleServices | ForEach-Object {
        $link = "$baseApp/apm/services/$([uri]::EscapeDataString($_.Name))/operations"
        "<tr><td><a href='$link' target='_blank'>$(HtmlEncode $_.Name)</a></td><td>$(HtmlEncode $_.Team)</td><td>$(HtmlEncode $_.Type)</td></tr>"
    }
    "<table><thead><tr><th>Service</th><th>Team</th><th>Application</th></tr></thead><tbody>$($rows -join '')</tbody></table>"
}

$html = @"
<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<title>Datadog Health Audit - $runId</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif; background:#f7f8fa; color:#1f2937; padding:32px; line-height:1.5; }
.wrap { max-width:1180px; margin:0 auto; }
header { background:#1d2030; color:#fff; padding:28px 32px; border-radius:10px; margin-bottom:24px; }
header h1 { font-size:24px; letter-spacing:0.5px; margin-bottom:6px; }
header .meta { color:#9ca3af; font-size:13px; }
.kpis { display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:14px; margin-bottom:28px; }
.kpi { background:#fff; padding:18px 20px; border-radius:8px; border:1px solid #e5e7eb; }
.kpi .n { font-size:28px; font-weight:700; color:#1d2030; }
.kpi .l { font-size:11px; text-transform:uppercase; letter-spacing:1px; color:#6b7280; margin-top:4px; }
.kpi.bad .n { color:#dc2626; }
.kpi.warn .n { color:#d97706; }
.kpi.ok .n   { color:#059669; }
section { background:#fff; padding:24px 28px; border-radius:8px; border:1px solid #e5e7eb; margin-bottom:20px; }
section h2 { font-size:17px; margin-bottom:14px; padding-bottom:10px; border-bottom:2px solid #f3f4f6; color:#1d2030; }
section .count { color:#6b7280; font-weight:400; font-size:13px; margin-left:8px; }
table { width:100%; border-collapse:collapse; font-size:13px; }
thead th { background:#f9fafb; text-align:left; padding:10px 14px; font-size:11px; text-transform:uppercase; letter-spacing:0.5px; color:#374151; border-bottom:1px solid #e5e7eb; }
tbody td { padding:10px 14px; border-bottom:1px solid #f3f4f6; vertical-align:top; }
tbody tr:hover { background:#fafbfc; }
a { color:#2563eb; text-decoration:none; }
a:hover { text-decoration:underline; }
.ok { color:#059669; font-style:italic; padding:8px 0; }
.footer { text-align:center; color:#9ca3af; font-size:11px; margin-top:24px; padding:16px; }
.state-badge { display:inline-block; padding:3px 9px; border-radius:4px; font-size:10px; font-weight:700; letter-spacing:0.5px; text-transform:uppercase; }
.state-ok      { background:#d1fae5; color:#065f46; }
.state-alert   { background:#fee2e2; color:#991b1b; }
.state-warn    { background:#fef3c7; color:#92400e; }
.state-nodata  { background:#e5e7eb; color:#374151; }
.state-other   { background:#dbeafe; color:#1e40af; }
.dbx-summary { display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:12px; margin-bottom:16px; }
.dbx-summary > div { background:#f9fafb; padding:12px 16px; border-radius:6px; border:1px solid #e5e7eb; text-align:center; }
.dbx-summary > div .n { font-size:22px; font-weight:700; }
.dbx-summary > div .l { font-size:10px; text-transform:uppercase; letter-spacing:1px; color:#6b7280; margin-top:3px; }
code { background:#f3f4f6; padding:2px 6px; border-radius:3px; font-family:Consolas,Menlo,monospace; }
</style>
</head><body>
<div class="wrap">

<header>
  <h1>Datadog Health Audit</h1>
  <div class="meta">
    Generated: $generated &middot; Site: $Site &middot; Run ID: $runId
  </div>
</header>

<div class="kpis">
  <div class="kpi $(if ($kpiTotal -eq 0) {'ok'} else {'bad'})"><div class="n">$kpiTotal</div><div class="l">Items Not Reporting</div></div>
  <div class="kpi $(if ($noDataMonitors.Count -eq 0) {'ok'} else {'bad'})"><div class="n">$($noDataMonitors.Count)</div><div class="l">No-Data Monitors</div></div>
  <div class="kpi $(if ($staleHosts.Count -eq 0) {'ok'} else {'warn'})"><div class="n">$($staleHosts.Count)</div><div class="l">Stale Hosts</div></div>
  <div class="kpi $(if ($pausedSynth.Count -eq 0) {'ok'} else {'warn'})"><div class="n">$($pausedSynth.Count)</div><div class="l">Paused Synthetics</div></div>
  <div class="kpi $(if ($staleServices.Count -eq 0) {'ok'} else {'warn'})"><div class="n">$($staleServices.Count)</div><div class="l">APM Services Silent</div></div>
  <div class="kpi"><div class="n">$totalMonitors</div><div class="l">Total Monitors</div></div>
  <div class="kpi"><div class="n">$($allHosts.Count)</div><div class="l">Total Hosts</div></div>
</div>

<section>
  <h2>Monitors in No-Data State <span class="count">($($noDataMonitors.Count))</span></h2>
  <p style="font-size:12px;color:#6b7280;margin-bottom:14px;">Monitors that ran but received zero data points during their evaluation window. These are typically what shows blank in Datadog UI tiles.</p>
  $noDataMonitorsHtml
</section>

<section>
  <h2>Hosts Not Reporting in last $StaleMinutes min <span class="count">($($staleHosts.Count))</span></h2>
  <p style="font-size:12px;color:#6b7280;margin-bottom:14px;">Hosts whose Datadog Agent has not checked in. Common causes: agent stopped, host shut down, network/auth issue, or host decommissioned but not pruned.</p>
  $staleHostsHtml
</section>

<section>
  <h2>Paused Synthetic Tests <span class="count">($($pausedSynth.Count))</span></h2>
  <p style="font-size:12px;color:#6b7280;margin-bottom:14px;">Synthetic browser/API tests that were manually paused. They produce no monitoring data while paused.</p>
  $pausedSynthHtml
</section>

<section>
  <h2>APM Services with no traces in $NoTracesHours h <span class="count">($($staleServices.Count))</span></h2>
  <p style="font-size:12px;color:#6b7280;margin-bottom:14px;">Services registered in the service catalog but no incoming traces during the window. Common causes: tracer not initialized, service is dead, or service renamed.</p>
  $staleServicesHtml
</section>

<section>
  <h2>Databricks Monitors - Full Breakdown <span class="count">($($dbxMonitors.Count))</span></h2>
  <p style="font-size:12px;color:#6b7280;margin-bottom:14px;">All monitors tagged or named with Databricks/DBX, broken out by current state. Sorted Alert &gt; Warn &gt; No Data &gt; OK so the broken ones are at the top.</p>
  <div class="dbx-summary">
    <div><div class="n" style="color:#065f46;">$($dbxOk.Count)</div><div class="l">Working (OK)</div></div>
    <div><div class="n" style="color:#991b1b;">$($dbxAlert.Count)</div><div class="l">Alert</div></div>
    <div><div class="n" style="color:#92400e;">$($dbxWarn.Count)</div><div class="l">Warn</div></div>
    <div><div class="n" style="color:#374151;">$($dbxNoData.Count)</div><div class="l">No Data</div></div>
    <div><div class="n" style="color:#1e40af;">$($dbxIgnored.Count)</div><div class="l">Ignored / Unknown</div></div>
  </div>
  $dbxDetailHtml
</section>

<div class="footer">Datadog Health Audit &middot; Author: Syed Rizvi &middot; $generated</div>

</div></body></html>
"@

Set-Content -Path $reportPath -Value $html -Encoding UTF8

$summary = [pscustomobject]@{
    runId             = $runId
    generatedAt       = (Get-Date).ToString("o")
    site              = $Site
    totalMonitors     = $totalMonitors
    noDataMonitors    = $noDataMonitors.Count
    mutedMonitors     = $mutedMonitors.Count
    totalHosts        = $allHosts.Count
    staleHosts        = $staleHosts.Count
    staleHostNames    = ($staleHosts | ForEach-Object { $_.name })
    totalSynthetic    = $totalSynth
    pausedSynthetic   = $pausedSynth.Count
    totalAPMServices  = $totalServices
    silentAPMServices = $staleServices.Count
    silentServiceNames = ($staleServices | ForEach-Object { $_.Name })
}
$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host "AUDIT COMPLETE" -ForegroundColor Green
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host "  Items not reporting:  $kpiTotal" -ForegroundColor $(if ($kpiTotal -eq 0) {'Green'} else {'Yellow'})
Write-Host "  HTML report:          $reportPath"
Write-Host "  JSON summary:         $jsonPath"
Write-Host ""

if (Test-Path $reportPath) { Start-Process $reportPath }
