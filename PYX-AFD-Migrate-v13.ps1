[CmdletBinding()]
param(
    [string]$Subscription = "e42e94b5-c6f8-4af0-a41b-16fda520de6e",
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$AbortStuck
)

if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say  ($m) { Write-Host "`n[step] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "  ok   $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  warn $m" -ForegroundColor Yellow }
function Err  ($m) { Write-Host "  ERR  $m" -ForegroundColor Red }
function Info ($m) { Write-Host "       $m" -ForegroundColor Gray }

$reportDir = Join-Path $env:USERPROFILE "Desktop\pyx-frontdoor-migration"
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$logPath  = Join-Path $reportDir "migration-v13-$stamp.log"
$jsonPath = Join-Path $reportDir "results-v13-$stamp.json"
$htmlPath = Join-Path $reportDir "PYX-AFD-Migration-Report-v13-$stamp.html"
Start-Transcript -Path $logPath -Force | Out-Null

Say "PYX AFD/CDN Migration v13 (REST + async polling + real error visibility)"
Info "Subscription:  $Subscription"
Info "Report dir:    $reportDir"
Info "PowerShell:    $($PSVersionTable.PSVersion)"
Info "API version:   2025-04-15"

Say "Phase 0 - Auth"
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$ctxRaw = & az account show -o json --only-show-errors 2>$null
$ErrorActionPreference = $prevEAP
if ([string]::IsNullOrWhiteSpace($ctxRaw)) {
    Warn "Not logged in. Running az login..."
    & az login --only-show-errors | Out-Null
    $ctxRaw = & az account show -o json --only-show-errors 2>$null
}
$ctx = $ctxRaw | ConvertFrom-Json
& az account set --subscription $Subscription --only-show-errors | Out-Null
Ok "Logged in: $($ctx.user.name)"

$tokenRaw = & az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv --only-show-errors 2>$null
if ([string]::IsNullOrWhiteSpace($tokenRaw)) { throw "Failed to get bearer token" }
$bearer = $tokenRaw.Trim()
$authHeaders = @{ Authorization = "Bearer $bearer"; "Content-Type" = "application/json" }
Ok "Bearer token acquired"

function Invoke-AzureRest {
    param([string]$Method, [string]$Url, [string]$Body)
    $params = @{
        Uri = $Url
        Method = $Method
        Headers = $authHeaders
        UseBasicParsing = $true
        TimeoutSec = 60
    }
    if ($Body) { $params["Body"] = $Body }
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    try {
        $resp = Invoke-WebRequest @params
        return @{
            StatusCode = $resp.StatusCode
            Headers = $resp.Headers
            Body = $resp.Content
            AsyncOp = $resp.Headers["azure-asyncoperation"]
            Location = $resp.Headers["location"]
            Ok = $true
            Error = $null
        }
    } catch {
        $errResp = $_.Exception.Response
        $errBody = ""
        if ($errResp) {
            try {
                $stream = $errResp.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $errBody = $reader.ReadToEnd()
            } catch {}
        }
        return @{
            StatusCode = if ($errResp) { [int]$errResp.StatusCode } else { 0 }
            Headers = @{}
            Body = $errBody
            AsyncOp = $null
            Location = $null
            Ok = $false
            Error = $_.Exception.Message
        }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

function Wait-AsyncOperation {
    param([string]$AsyncUrl, [int]$MaxSec = 1800, [int]$IntervalSec = 20)
    $elapsed = 0
    while ($elapsed -lt $MaxSec) {
        Start-Sleep -Seconds $IntervalSec
        $elapsed += $IntervalSec
        $r = Invoke-AzureRest -Method "GET" -Url $AsyncUrl
        if (-not $r.Ok) {
            Info "  [${elapsed}s] async-op query failed: $($r.Error)"
            continue
        }
        try {
            $obj = $r.Body | ConvertFrom-Json
            $status = $obj.status
            Info "  [${elapsed}s] async status: $status"
            if ($status -in @("Succeeded","Failed","Canceled")) {
                return @{ Status = $status; Body = $r.Body; Object = $obj }
            }
        } catch {
            Info "  [${elapsed}s] could not parse async response"
        }
    }
    return @{ Status = "Timeout"; Body = ""; Object = $null }
}

function Get-ProfileViaRest {
    param([string]$Name, [string]$RG)
    $url = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$RG/providers/Microsoft.Cdn/profiles/${Name}?api-version=2025-04-15"
    $r = Invoke-AzureRest -Method "GET" -Url $url
    if ($r.Ok) { return ($r.Body | ConvertFrom-Json) }
    return $null
}

function Get-ClassicAfdViaRest {
    param([string]$Name, [string]$RG)
    foreach ($apiVer in @("2020-05-01","2021-06-01","2020-04-01")) {
        $url = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$RG/providers/Microsoft.Network/frontdoors/${Name}?api-version=$apiVer"
        $r = Invoke-AzureRest -Method "GET" -Url $url
        if ($r.Ok) { return ($r.Body | ConvertFrom-Json) }
    }
    return $null
}

$profiles = @(
    @{ Classic = "pyxiq";        Standard = "pyxiq-std";        RG = "Production"; Type = "AFD"; Sku = "Standard_AzureFrontDoor" }
    @{ Classic = "hipyx";        Standard = "hipyx-std-v2";     RG = "production"; Type = "AFD"; Sku = "Standard_AzureFrontDoor" }
    @{ Classic = "pyxiq-stage";  Standard = "pyxiq-stage-std";  RG = "Stage";      Type = "AFD"; Sku = "Standard_AzureFrontDoor" }
    @{ Classic = "pyxpwa-stage"; Standard = "pyxpwa-stage-std"; RG = "Stage";      Type = "AFD"; Sku = "Standard_AzureFrontDoor" }
    @{ Classic = "standard";     Standard = "standard-afdstd";  RG = "Test";       Type = "CDN"; Sku = "Standard_AzureFrontDoor" }
)

Say "Phase 1 - Discovery"
$plan = @()
foreach ($p in $profiles) {
    $info = @{ Classic=$p.Classic; Standard=$p.Standard; RG=$p.RG; Type=$p.Type; Sku=$p.Sku; Action=""; ClassicId=""; Status="pending"; Error=""; Verified=$false; VerifiedSku=""; VerifiedState=""; AsyncOpUrl=""; PrepareError="" }
    $existing = Get-ProfileViaRest -Name $p.Standard -RG $p.RG
    if ($existing -and $existing.sku -and $existing.sku.name -in @("Standard_AzureFrontDoor","Premium_AzureFrontDoor") -and $existing.properties.provisioningState -eq "Succeeded") {
        $info.Action = "ALREADY-DONE"
        $info.VerifiedSku = $existing.sku.name
        $info.VerifiedState = $existing.properties.provisioningState
    } elseif ($existing) {
        $info.Action = "COMMIT-ONLY"
        $info.VerifiedSku = $existing.sku.name
        $info.VerifiedState = $existing.properties.provisioningState
    } else {
        if ($p.Type -eq "AFD") {
            $classic = Get-ClassicAfdViaRest -Name $p.Classic -RG $p.RG
            if ($classic) { $info.ClassicId = $classic.id; $info.Action = "MIGRATE" } else { $info.Action = "NO-CLASSIC" }
        } else {
            $url = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$($p.RG)/providers/Microsoft.Cdn/profiles/$($p.Classic)?api-version=2025-04-15"
            $r = Invoke-AzureRest -Method "GET" -Url $url
            if ($r.Ok) {
                $cdn = $r.Body | ConvertFrom-Json
                $info.ClassicId = $cdn.id; $info.Action = "MIGRATE"
            } else {
                $info.Action = "NO-CLASSIC"
            }
        }
    }
    Info ("  {0,-14} ({1}) -> {2,-20} action={3,-14} new-sku={4} new-state={5}" -f $p.Classic, $p.Type, $p.Standard, $info.Action, $info.VerifiedSku, $info.VerifiedState)
    $plan += $info
}

if ($AbortStuck) {
    Say "Phase 1.5 - Aborting any stuck migrations"
    foreach ($info in $plan) {
        if ($info.Action -in @("COMMIT-ONLY","MIGRATE")) {
            $abortUrl = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$($info.RG)/providers/Microsoft.Cdn/profiles/$($info.Standard)/migrationAbort?api-version=2025-04-15"
            Info "Trying abort on $($info.Standard)..."
            $r = Invoke-AzureRest -Method "POST" -Url $abortUrl
            if ($r.Ok -or $r.StatusCode -eq 202) {
                Ok "Abort submitted for $($info.Standard)"
            } else {
                Warn "Abort skipped/failed for $($info.Standard) (status=$($r.StatusCode))"
            }
        }
    }
    Info "Waiting 60s for aborts to settle..."
    Start-Sleep -Seconds 60
}

if ($DryRun) {
    Ok "DryRun complete."
    Stop-Transcript | Out-Null
    return
}

if (-not $Yes) {
    Write-Host ""
    $resp = Read-Host "Proceed with migration? Type YES"
    if ($resp -ne "YES") { Warn "Aborted"; Stop-Transcript | Out-Null; return }
}

Say "Phase 2 - Per-profile migration"
foreach ($info in $plan) {
    Write-Host ""
    Say "$($info.Classic) [$($info.Type)] -> $($info.Standard) ($($info.Action))"

    if ($info.Action -eq "ALREADY-DONE") {
        $info.Status = "already-done"; $info.Verified = $true
        Ok "Already on Standard SKU. Nothing to do."
        continue
    }
    if ($info.Action -eq "NO-CLASSIC") {
        $info.Status = "no-classic"
        Err "Classic profile not found. Skipping."
        continue
    }

    if ($info.Action -eq "MIGRATE") {
        if ($info.Type -eq "AFD") {
            $migrateUrl = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$($info.RG)/providers/Microsoft.Cdn/migrate?api-version=2025-04-15"
            $body = @{ sku = @{ name = $info.Sku }; classicResourceReference = @{ id = $info.ClassicId }; profileName = $info.Standard } | ConvertTo-Json -Depth 5 -Compress
        } else {
            $migrateUrl = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$($info.RG)/providers/Microsoft.Cdn/profiles/$($info.Classic)/cdnMigrateToAfd?api-version=2025-04-15"
            $body = @{ sku = @{ name = $info.Sku } } | ConvertTo-Json -Depth 5 -Compress
        }

        Info "Step 1/3: POST migrate"
        $migResp = Invoke-AzureRest -Method "POST" -Url $migrateUrl -Body $body
        if (-not $migResp.Ok) {
            $info.Status = "prepare-failed"; $info.Error = "HTTP $($migResp.StatusCode): $($migResp.Body)"
            Err "Migrate REST FAILED: status=$($migResp.StatusCode)"
            Err "Body: $($migResp.Body)"
            continue
        }
        Ok "Migrate accepted: HTTP $($migResp.StatusCode)"
        Info "Async-op URL: $($migResp.AsyncOp)"
        $info.AsyncOpUrl = $migResp.AsyncOp

        if ($migResp.AsyncOp) {
            Info "Step 2/3: Polling async-op for prepare completion (up to 30 min)..."
            $waitResult = Wait-AsyncOperation -AsyncUrl $migResp.AsyncOp -MaxSec 1800 -IntervalSec 20
            if ($waitResult.Status -ne "Succeeded") {
                $errDetail = ""
                if ($waitResult.Object -and $waitResult.Object.error) { $errDetail = ($waitResult.Object.error | ConvertTo-Json -Depth 5 -Compress) }
                $info.Status = "prepare-async-$($waitResult.Status.ToLower())"
                $info.PrepareError = $errDetail
                $info.Error = "Async prepare $($waitResult.Status). Detail: $errDetail"
                Err "Prepare async result: $($waitResult.Status)"
                if ($errDetail) { Err "Detail: $errDetail" }
                continue
            }
            Ok "Prepare async completed: Succeeded"
        } else {
            Warn "No async-op URL returned. Sleeping 60s and proceeding to commit."
            Start-Sleep -Seconds 60
        }
    }

    Info "Step 3/3: POST migrationCommit"
    $commitUrl = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$($info.RG)/providers/Microsoft.Cdn/profiles/$($info.Standard)/migrationCommit?api-version=2025-04-15"
    $commitResp = Invoke-AzureRest -Method "POST" -Url $commitUrl
    if (-not $commitResp.Ok -and $commitResp.StatusCode -notin @(200,202)) {
        $info.Status = "commit-failed"; $info.Error = "HTTP $($commitResp.StatusCode): $($commitResp.Body)"
        Err "Commit REST FAILED: status=$($commitResp.StatusCode)"
        Err "Body: $($commitResp.Body)"
        continue
    }
    Ok "Commit accepted: HTTP $($commitResp.StatusCode)"
    if ($commitResp.AsyncOp) {
        Info "Polling commit async-op (up to 15 min)..."
        $cw = Wait-AsyncOperation -AsyncUrl $commitResp.AsyncOp -MaxSec 900 -IntervalSec 15
        if ($cw.Status -ne "Succeeded") {
            $info.Status = "commit-async-$($cw.Status.ToLower())"
            Err "Commit async result: $($cw.Status)"
            continue
        }
        Ok "Commit async completed: Succeeded"
    }
    $info.Status = "migrated-and-committed"
}

Say "Phase 3 - Final verification"
foreach ($info in $plan) {
    if ($info.Status -in @("no-classic")) { continue }
    $check = Get-ProfileViaRest -Name $info.Standard -RG $info.RG
    if ($check -and $check.sku -and $check.sku.name -in @("Standard_AzureFrontDoor","Premium_AzureFrontDoor") -and $check.properties.provisioningState -eq "Succeeded") {
        $info.Verified = $true
        $info.VerifiedSku = $check.sku.name
        $info.VerifiedState = $check.properties.provisioningState
        Ok "$($info.Standard): VERIFIED (sku=$($check.sku.name), state=$($check.properties.provisioningState))"
    } elseif ($check) {
        $info.VerifiedSku = $check.sku.name
        $info.VerifiedState = $check.properties.provisioningState
        Warn "$($info.Standard): exists but state=$($check.properties.provisioningState) sku=$($check.sku.name)"
    } else {
        Err "$($info.Standard): not found in Azure"
    }
}

Say "Phase 4 - HTML Report"
$plan | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding utf8

$rowsHtml = ""
foreach ($i in $plan) {
    $cssClass = if ($i.Verified -eq $true) { "ok" } else { "bad" }
    $statusTxt = if ($i.Verified -eq $true) { "PASS" } else { "FAIL" }
    $errCell = if ($i.Error) { ($i.Error -replace '<','&lt;' -replace '>','&gt;') } else { "&mdash;" }
    $rowsHtml += "<tr class='$cssClass'><td><strong>$statusTxt</strong></td><td>$($i.Classic)</td><td>$($i.Type)</td><td>$($i.Standard)</td><td>$($i.RG)</td><td>$($i.Sku)</td><td>$($i.VerifiedSku)</td><td>$($i.VerifiedState)</td><td>$($i.Action)</td><td>$($i.Status)</td><td>$errCell</td></tr>`n"
}
$verifiedCount = @($plan | Where-Object { $_.Verified -eq $true }).Count
$totalCount = $plan.Count
$failedCount = $totalCount - $verifiedCount
$reportTimestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$bigClass = if ($failedCount -eq 0) { "" } else { " bad" }

$html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>PYX Front Door Migration Report v13</title>
<style>
body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; max-width: 1200px; margin: 30px auto; padding: 0 20px; color: #11151C; }
h1 { color: #1F3D7A; border-bottom: 3px solid #1F3D7A; padding-bottom: 10px; }
h2 { color: #1F3D7A; margin-top: 30px; }
.summary { background: #F5F7FA; padding: 20px; border-left: 5px solid #1F3D7A; margin: 20px 0; }
.summary .big { font-size: 36px; font-weight: bold; color: #1B6B3A; }
.summary .big.bad { color: #9B2226; }
table { width: 100%; border-collapse: collapse; margin: 20px 0; font-size: 13px; }
th { background: #1F3D7A; color: white; padding: 8px; text-align: left; }
td { padding: 8px; border-bottom: 1px solid #C8CFD9; word-break: break-word; }
tr.ok td:first-child { color: #1B6B3A; font-weight: bold; }
tr.bad td:first-child { color: #9B2226; font-weight: bold; }
tr.ok { background: #F1FAF4; }
tr.bad { background: #FFF1F2; }
.meta { color: #555E6D; font-size: 13px; margin-top: 30px; }
code { background: #F5F7FA; padding: 2px 6px; border-radius: 3px; font-family: Consolas, monospace; }
</style></head><body>
<h1>PYX Front Door Migration Report</h1>
<p>Migration via direct Azure REST API with async operation polling (Microsoft.Cdn 2025-04-15).</p>

<div class="summary">
<div class="big$bigClass">$verifiedCount / $totalCount profiles VERIFIED LIVE</div>
</div>

<h2>Per-profile results</h2>
<table>
<thead><tr><th>Status</th><th>Classic</th><th>Type</th><th>New profile</th><th>RG</th><th>Target SKU</th><th>Verified SKU</th><th>State</th><th>Action</th><th>Script status</th><th>Error</th></tr></thead>
<tbody>
$rowsHtml
</tbody>
</table>

<h2>Subscription</h2>
<p><code>$Subscription</code> (sub-corp-prod-001)</p>

<h2>Artifacts</h2>
<ul>
<li>Run log: <code>$logPath</code></li>
<li>Results JSON: <code>$jsonPath</code></li>
</ul>

<h2>Next steps</h2>
<ul>
<li>For any FAIL row, the Error column contains the actual Azure REST error</li>
<li>If all rows show "prepare-async-failed" with the same root cause, fix that one cause and re-run</li>
<li>If repeated REST failures persist, fall back to Azure Portal: profile -> Migration -> Validate -> Prepare -> Migrate</li>
<li>Custom domains need DNS cutover to new <code>*.azurefd.net</code> endpoints after migration</li>
</ul>

<p class="meta">Generated $reportTimestamp | Script: PYX-AFD-Migrate-v13.ps1 | API: Microsoft.Cdn 2025-04-15</p>
</body></html>
"@
$html | Out-File -FilePath $htmlPath -Encoding utf8

Say "Final summary"
Ok "Verified live: $verifiedCount / $totalCount"
if ($failedCount -gt 0) {
    foreach ($f in @($plan | Where-Object { $_.Verified -ne $true })) {
        Err "  $($f.Classic): action=$($f.Action) status=$($f.Status)"
        if ($f.Error) { Err "    -> $($f.Error.Substring(0, [Math]::Min(200, $f.Error.Length)))" }
    }
}
Ok "JSON: $jsonPath"
Ok "HTML: $htmlPath"
Ok "Log:  $logPath"

Stop-Transcript | Out-Null
