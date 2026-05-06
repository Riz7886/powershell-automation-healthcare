[CmdletBinding()]
param(
    [string]$ApiKey,
    [string]$AppKey,
    [string]$Site = "us3.datadoghq.com",
    [string[]]$AgentHosts = @(),
    [string]$AgentServiceName = "datadogagent",
    [switch]$DryRun,
    [switch]$MuteNoData,
    [int]$MuteDays = 7,
    [string]$MuteOwner = "Syed Rizvi",
    [switch]$RotateAzureSecrets,
    [int]$AzureSecretYears = 2,
    [string]$OutDir = (Join-Path $env:USERPROFILE "Desktop\datadog-audit")
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $ApiKey) { $ApiKey = (Read-Host -Prompt "Datadog API Key" -AsSecureString) | ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) } }
if (-not $AppKey) { $AppKey = (Read-Host -Prompt "Datadog Application Key" -AsSecureString) | ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) } }

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$runId      = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $OutDir "datadog-fix-$runId.html"
$baseApi    = "https://api.$Site"
$baseApp    = "https://app.$Site"
$headers    = @{
    "DD-API-KEY"         = $ApiKey
    "DD-APPLICATION-KEY" = $AppKey
    "Accept"             = "application/json"
}

function Write-Step($Text, $Color = "Cyan") {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor $Color
    Write-Host $Text -ForegroundColor $Color
    Write-Host ("=" * 70) -ForegroundColor $Color
}

function Invoke-DD {
    param([string]$Path, [string]$Method = "GET", $Body = $null)
    $uri = "$baseApi$Path"
    try {
        if ($Body) {
            Invoke-RestMethod -Uri $uri -Headers $headers -Method $Method -Body ($Body | ConvertTo-Json -Depth 10) -ContentType "application/json" -TimeoutSec 60
        } else {
            Invoke-RestMethod -Uri $uri -Headers $headers -Method $Method -TimeoutSec 60
        }
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 401) { throw "Datadog auth 401 - check API/App key + Site" }
        if ($_.Exception.Response.StatusCode.value__ -eq 403) { return $null }
        throw "Datadog ${Path}: $($_.Exception.Message)"
    }
}

function HtmlEncode($s) { if ($null -eq $s) { return "" } else { [System.Net.WebUtility]::HtmlEncode([string]$s) } }

$results = [ordered]@{
    azureIntegration       = $null
    azureRotationResults   = @()
    customMetricsDiagnosis = @()
    agentRestartResults    = @()
    downtimeResults        = @()
    monitorSummary         = $null
}

Write-Step "Datadog Auto-Fix - run $runId"
Write-Host "Site:         $Site"
Write-Host "DryRun:       $DryRun"
Write-Host "Agent hosts:  $(if ($AgentHosts.Count) { $AgentHosts -join ', ' } else { '(none provided)' })"

Write-Step "[1/5] Validate credentials" "Yellow"
$v = Invoke-DD -Path "/api/v1/validate"
if (-not $v -or -not $v.valid) { throw "API key not valid for site $Site" }
Write-Host "  OK" -F Green

Write-Step "[2/5] Pull monitors + cluster the no-data ones" "Yellow"
$monitors = Invoke-DD -Path "/api/v1/monitor"
$noData = @($monitors | Where-Object { $_.overall_state -eq "No Data" })
$results.monitorSummary = [pscustomobject]@{
    total   = $monitors.Count
    okCount = @($monitors | Where-Object { $_.overall_state -eq "OK" }).Count
    noData  = $noData.Count
}
$azureMonitors = @($noData | Where-Object { $_.query -match '(?i)\bazure\.' })
$dbxOfficial   = @($noData | Where-Object { $_.query -match '(?i)\bdatabricks\.' -and $_.query -notmatch '(?i)custom\.databricks' })
$dbxCustom     = @($noData | Where-Object { $_.query -match '(?i)custom\.databricks\.' })
$hostScoped    = @($noData | Where-Object { $_.query -match '(?i)\bhost:' -or $_.query -match '(?i)system\.' -or $_.query -match '(?i)datadog\.agent\.up' })
Write-Host "  Total monitors:                  $($monitors.Count)"
Write-Host "  No-Data monitors:                $($noData.Count)" -F Yellow
Write-Host "    Azure cloud integration:       $($azureMonitors.Count)"
Write-Host "    Databricks (official):         $($dbxOfficial.Count)"
Write-Host "    Databricks (custom collector): $($dbxCustom.Count)"
Write-Host "    Host-scoped (agent down):      $($hostScoped.Count)"

Write-Step "[3/5] Diagnose Azure cloud integration" "Yellow"
$azureDiag = Invoke-DD -Path "/api/v1/integration/azure"
if ($null -eq $azureDiag) {
    Write-Host "  App key lacks scope to read Azure integration. Check Integrations -> Azure manually." -F DarkYellow
    $results.azureIntegration = @{ accessible = $false; tenants = @() }
} else {
    Write-Host "  Azure tenants configured: $($azureDiag.Count)"
    $tenantSummary = @()
    foreach ($t in $azureDiag) {
        $errorCount = if ($t.errors) { $t.errors.Count } else { 0 }
        Write-Host ("    Tenant: {0}  client: {1}  errors: {2}" -f $t.tenant_name, $t.client_id, $errorCount) -F $(if ($errorCount -gt 0) {'Red'} else {'Green'})
        $tenantSummary += [pscustomobject]@{ tenant = $t.tenant_name; client = $t.client_id; errors = $errorCount; errorList = ($t.errors -join '; ') }
    }
    $results.azureIntegration = @{ accessible = $true; tenants = $tenantSummary }
}

Write-Step "[3b] Auto-rotate Azure SP client secrets and push to Datadog" "Yellow"
if (-not $RotateAzureSecrets) {
    Write-Host "  -RotateAzureSecrets flag not set. Skipping." -F DarkYellow
} elseif (-not $results.azureIntegration.accessible -or $results.azureIntegration.tenants.Count -eq 0) {
    Write-Host "  Cannot rotate: Datadog Azure integration unreadable or unconfigured." -F Red
} else {
    if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
        Install-Module -Name Az.Resources -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
    }
    Import-Module Az.Resources -Force -ErrorAction SilentlyContinue
    $azCtx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $azCtx -or -not $azCtx.Account) {
        Write-Host "  No Az PowerShell login. Run Connect-AzAccount, then re-run." -F Red
    } else {
        Write-Host "  Az login: $($azCtx.Account.Id) on tenant $($azCtx.Tenant.Id)" -F DarkCyan
        foreach ($t in $results.azureIntegration.tenants) {
            Write-Host "    Tenant: $($t.tenant)  client: $($t.client)" -F Cyan
            if ($azCtx.Tenant.Id -ne $t.tenant) {
                Write-Host "      Active Az tenant differs. Skipping." -F Yellow
                $results.azureRotationResults += [pscustomobject]@{ tenant = $t.tenant; client = $t.client; result = "Skipped (tenant mismatch)"; expires = "" }
                continue
            }
            $appReg = $null
            try { $appReg = Get-AzADApplication -ApplicationId $t.client -ErrorAction SilentlyContinue } catch {}
            if (-not $appReg) {
                Write-Host "      App Registration not found. Skipping." -F Yellow
                $results.azureRotationResults += [pscustomobject]@{ tenant = $t.tenant; client = $t.client; result = "Not found"; expires = "" }
                continue
            }
            if ($DryRun) {
                Write-Host "      DRYRUN" -F DarkYellow
                $results.azureRotationResults += [pscustomobject]@{ tenant = $t.tenant; client = $t.client; result = "DryRun"; expires = "" }
                continue
            }
            try {
                $endDate = (Get-Date).AddYears($AzureSecretYears)
                $newCred = New-AzADAppCredential -ApplicationId $t.client -EndDate $endDate -ErrorAction Stop
                $newSecret = $newCred.SecretText
                if (-not $newSecret) { throw "no SecretText" }
                $body = @{ tenant_name = $t.tenant; client_id = $t.client; client_secret = $newSecret }
                Invoke-DD -Path "/api/v1/integration/azure" -Method "PUT" -Body $body | Out-Null
                Write-Host "      OK - rotated, exp: $($endDate.ToShortDateString())" -F Green
                $results.azureRotationResults += [pscustomobject]@{ tenant = $t.tenant; client = $t.client; result = "Rotated"; expires = $endDate.ToShortDateString() }
            } catch {
                Write-Host "      FAIL - $($_.Exception.Message)" -F Red
                $results.azureRotationResults += [pscustomobject]@{ tenant = $t.tenant; client = $t.client; result = "Error"; expires = "" }
            }
        }
    }
}

Write-Step "[4/5] Diagnose custom.databricks.* metric publishing" "Yellow"
$customMetricNames = $dbxCustom | ForEach-Object { if ($_.query -match 'custom\.databricks\.[a-zA-Z0-9_\.]+') { $matches[0] } } | Sort-Object -Unique
$now = [int64]((Get-Date).ToUniversalTime() - (Get-Date "1970-01-01")).TotalSeconds
$thirtyMinAgo = $now - 1800
foreach ($m in $customMetricNames) {
    $q = "$m{*}"
    $resp = Invoke-DD -Path ("/api/v1/query?from=$thirtyMinAgo&to=$now&query=" + [uri]::EscapeDataString($q))
    $hasData = $false
    if ($resp -and $resp.series -and $resp.series.Count -gt 0) {
        foreach ($pt in $resp.series[0].pointlist) { if ($pt[1] -gt 0) { $hasData = $true; break } }
    }
    $status = if ($hasData) { "PUBLISHING" } else { "SILENT" }
    Write-Host ("    {0}  -  {1}" -f $m, $status) -F $(if ($hasData) {'Green'} else {'Red'})
    $results.customMetricsDiagnosis += [pscustomobject]@{ metric = $m; status = $status; last30min = $hasData }
}

Write-Step "[5/5] Restart Datadog Agent on host-scoped VMs" "Yellow"
if ($AgentHosts.Count -eq 0) {
    Write-Host "  No -AgentHosts provided." -F DarkYellow
} else {
    foreach ($h in $AgentHosts) {
        Write-Host "  Trying $h ..." -F Cyan
        if ($DryRun) {
            $results.agentRestartResults += [pscustomobject]@{ host = $h; result = "DryRun"; status = "SKIPPED"; before = ""; after = "" }
            continue
        }
        try {
            $r = Invoke-Command -ComputerName $h -ArgumentList $AgentServiceName -ScriptBlock {
                param($svc)
                $s = Get-Service -Name $svc -EA SilentlyContinue
                if (-not $s) { return @{ ok = $false; error = "Service '$svc' not found" } }
                $beforeStatus = $s.Status.ToString()
                Stop-Service -Name $svc -Force -EA SilentlyContinue
                Start-Sleep 3
                Start-Service -Name $svc
                Start-Sleep 8
                $after = (Get-Service -Name $svc).Status.ToString()
                return @{ ok = ($after -eq 'Running'); before = $beforeStatus; after = $after }
            } -ErrorAction Stop
            if ($r.ok) {
                Write-Host "    OK - $h: $($r.before) -> $($r.after)" -F Green
                $results.agentRestartResults += [pscustomobject]@{ host = $h; result = "Restarted"; status = "Running"; before = $r.before; after = $r.after }
            } else {
                Write-Host "    FAIL - $h - $($r.error)" -F Red
                $results.agentRestartResults += [pscustomobject]@{ host = $h; result = "Failed"; status = "$($r.error)"; before = $r.before; after = $r.after }
            }
        } catch {
            Write-Host "    UNREACHABLE - $h" -F Red
            $results.agentRestartResults += [pscustomobject]@{ host = $h; result = "Unreachable"; status = $_.Exception.Message; before = "?"; after = "?" }
        }
    }
}

Write-Step "[6/6] Mute No-Data monitors with investigation note" "Yellow"
if (-not $MuteNoData) {
    Write-Host "  -MuteNoData flag not set. Skipping." -F DarkYellow
} else {
    $muteEnd = [int64]((Get-Date).ToUniversalTime().AddDays($MuteDays) - (Get-Date "1970-01-01").ToUniversalTime()).TotalSeconds
    $note = "Investigation - data ingestion broken upstream of Datadog. Owner: $MuteOwner. Auto-unmutes after $MuteDays days."
    foreach ($mon in $noData) {
        if ($DryRun) {
            $results.downtimeResults += [pscustomobject]@{ monitorId = $mon.id; name = $mon.name; result = "DryRun"; downtimeId = "" }
            continue
        }
        $muteOk = $false
        $detail = ""
        try {
            $muteBody = @{ scope = "*"; end = $muteEnd }
            $muteResp = Invoke-DD -Path "/api/v1/monitor/$($mon.id)/mute" -Method "POST" -Body $muteBody
            if ($null -ne $muteResp) {
                $muteOk = $true
                $detail = "muted until $(([datetimeoffset]::FromUnixTimeSeconds($muteEnd)).UtcDateTime.ToString('yyyy-MM-dd'))"
            }
        } catch {
            $detail = $_.Exception.Message
        }
        if ($muteOk) {
            Write-Host "    OK - $($mon.name)" -F Green
            $results.downtimeResults += [pscustomobject]@{ monitorId = $mon.id; name = $mon.name; result = "Muted"; downtimeId = $detail }
        } else {
            Write-Host "    FAIL - #$($mon.id) - $detail" -F Red
            $results.downtimeResults += [pscustomobject]@{ monitorId = $mon.id; name = $mon.name; result = "Failed"; downtimeId = $detail }
        }
    }
    $muted = ($results.downtimeResults | Where-Object { $_.result -eq "Muted" }).Count
    Write-Host "  Monitors muted: $muted / $($noData.Count)" -F $(if ($muted -eq $noData.Count) { 'Green' } else { 'Yellow' })
}

Write-Step "Building fix report HTML"
$generated = Get-Date -Format "MMMM d, yyyy h:mm tt zzz"

$fixed   = ($results.agentRestartResults | Where-Object { $_.result -eq "Restarted" }).Count
$failed  = ($results.agentRestartResults | Where-Object { $_.result -in @("Failed","Unreachable") }).Count
$silentMetrics = ($results.customMetricsDiagnosis | Where-Object { -not $_.last30min }).Count
$publishingMetrics = ($results.customMetricsDiagnosis | Where-Object { $_.last30min }).Count
$mutedCount = ($results.downtimeResults | Where-Object { $_.result -eq "Muted" }).Count

$customMetricRows = ($results.customMetricsDiagnosis | ForEach-Object {
    $cls = if ($_.last30min) { "state-ok" } else { "state-alert" }
    "<tr><td><span class='state-badge $cls'>$(HtmlEncode $_.status)</span></td><td><code>$(HtmlEncode $_.metric)</code></td></tr>"
}) -join ''
if (-not $customMetricRows) { $customMetricRows = "<tr><td colspan='2' style='color:#6b7280;'>None</td></tr>" }

$agentRows = ($results.agentRestartResults | ForEach-Object {
    $cls = switch ($_.result) { "Restarted" { "state-ok" } "Failed" { "state-alert" } "Unreachable" { "state-alert" } default { "state-other" } }
    "<tr><td><span class='state-badge $cls'>$(HtmlEncode $_.result)</span></td><td>$(HtmlEncode $_.host)</td><td>$(HtmlEncode $_.before) -> $(HtmlEncode $_.after)</td><td>$(HtmlEncode $_.status)</td></tr>"
}) -join ''
if (-not $agentRows) { $agentRows = "<tr><td colspan='4' style='color:#6b7280;'>No -AgentHosts passed.</td></tr>" }

$muteRows = ($results.downtimeResults | ForEach-Object {
    $cls = if ($_.result -eq "Muted") { "state-ok" } else { "state-alert" }
    "<tr><td><span class='state-badge $cls'>$(HtmlEncode $_.result)</span></td><td><a href='$baseApp/monitors/$($_.monitorId)' target='_blank'>$(HtmlEncode $_.name)</a></td><td>$(HtmlEncode $_.downtimeId)</td></tr>"
}) -join ''
if (-not $muteRows) { $muteRows = "<tr><td colspan='3' style='color:#6b7280;'>Mute step skipped.</td></tr>" }

$html = @"
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Datadog Auto-Fix - $runId</title>
<style>
* { box-sizing:border-box; margin:0; padding:0; }
body { font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif; background:#f7f8fa; color:#1f2937; padding:32px; line-height:1.5; }
.wrap { max-width:1180px; margin:0 auto; }
header { background:#1d2030; color:#fff; padding:28px 32px; border-radius:10px; margin-bottom:24px; }
header h1 { font-size:24px; margin-bottom:6px; }
header .meta { color:#9ca3af; font-size:13px; }
.kpis { display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:14px; margin-bottom:28px; }
.kpi { background:#fff; padding:18px 20px; border-radius:8px; border:1px solid #e5e7eb; }
.kpi .n { font-size:28px; font-weight:700; }
.kpi .l { font-size:11px; text-transform:uppercase; letter-spacing:1px; color:#6b7280; margin-top:4px; }
section { background:#fff; padding:24px 28px; border-radius:8px; border:1px solid #e5e7eb; margin-bottom:20px; }
section h2 { font-size:17px; margin-bottom:14px; padding-bottom:10px; border-bottom:2px solid #f3f4f6; color:#1d2030; }
table { width:100%; border-collapse:collapse; font-size:13px; }
thead th { background:#f9fafb; text-align:left; padding:10px 14px; font-size:11px; text-transform:uppercase; color:#374151; border-bottom:1px solid #e5e7eb; }
tbody td { padding:10px 14px; border-bottom:1px solid #f3f4f6; }
.state-badge { display:inline-block; padding:3px 9px; border-radius:4px; font-size:10px; font-weight:700; text-transform:uppercase; }
.state-ok { background:#d1fae5; color:#065f46; }
.state-alert { background:#fee2e2; color:#991b1b; }
.state-other { background:#dbeafe; color:#1e40af; }
code { background:#f3f4f6; padding:2px 6px; border-radius:3px; font-family:Consolas,monospace; }
a { color:#2563eb; text-decoration:none; }
.footer { text-align:center; color:#9ca3af; font-size:11px; margin-top:24px; padding:16px; }
</style></head><body><div class="wrap">
<header><h1>Datadog Auto-Fix Report</h1><div class="meta">Generated: $generated &middot; Site: $Site &middot; Run ID: $runId</div></header>
<div class="kpis">
  <div class="kpi"><div class="n" style="color:#065f46;">$mutedCount</div><div class="l">Monitors Muted</div></div>
  <div class="kpi"><div class="n" style="color:#065f46;">$fixed</div><div class="l">Agents Restarted</div></div>
  <div class="kpi"><div class="n" style="color:#dc2626;">$failed</div><div class="l">Agents Failed</div></div>
  <div class="kpi"><div class="n" style="color:#dc2626;">$silentMetrics</div><div class="l">Silent Custom Metrics</div></div>
  <div class="kpi"><div class="n" style="color:#065f46;">$publishingMetrics</div><div class="l">Publishing Custom Metrics</div></div>
</div>
<section><h2>Monitors Muted</h2><table><thead><tr><th>Result</th><th>Monitor</th><th>Detail</th></tr></thead><tbody>$muteRows</tbody></table></section>
<section><h2>Agent Restart Results</h2><table><thead><tr><th>Result</th><th>Host</th><th>Before -&gt; After</th><th>Notes</th></tr></thead><tbody>$agentRows</tbody></table></section>
<section><h2>Custom Databricks Metrics</h2><table><thead><tr><th>Status</th><th>Metric</th></tr></thead><tbody>$customMetricRows</tbody></table></section>
<div class="footer">Datadog Auto-Fix &middot; Author: Syed Rizvi &middot; $generated</div>
</div></body></html>
"@
Set-Content -Path $reportPath -Value $html -Encoding UTF8

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host "FIX REPORT COMPLETE" -ForegroundColor Green
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host "  Monitors muted:        $mutedCount"
Write-Host "  Agents restarted:      $fixed"
Write-Host "  Agents failed:         $failed"
Write-Host "  Custom metrics SILENT: $silentMetrics"
Write-Host "  Report:                $reportPath"
if (Test-Path $reportPath) { Start-Process $reportPath }