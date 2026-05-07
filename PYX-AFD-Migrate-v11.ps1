[CmdletBinding()]
param(
    [string]$Subscription = "e42e94b5-c6f8-4af0-a41b-16fda520de6e",
    [switch]$Yes,
    [switch]$DryRun
)

if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Say  ($m) { Write-Host "`n[step] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "  ok   $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  warn $m" -ForegroundColor Yellow }
function Err  ($m) { Write-Host "  ERR  $m" -ForegroundColor Red }
function Info ($m) { Write-Host "       $m" -ForegroundColor Gray }

$reportDir = Join-Path $env:USERPROFILE "Desktop\pyx-frontdoor-migration"
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$logPath  = Join-Path $reportDir "migration-v10-$stamp.log"
$jsonPath = Join-Path $reportDir "results-v10-$stamp.json"
$htmlPath = Join-Path $reportDir "PYX-AFD-Migration-Report-v10-$stamp.html"
$bodyDir  = Join-Path $reportDir "rest-bodies-$stamp"
New-Item -ItemType Directory -Path $bodyDir -Force | Out-Null
Start-Transcript -Path $logPath -Force | Out-Null

Say "PYX AFD/CDN Migration v10 (Direct REST API via az rest)"
Info "Subscription:  $Subscription"
Info "Report dir:    $reportDir"
Info "PowerShell:    $($PSVersionTable.PSVersion)"
Info "API version:   2025-04-15"

Say "Phase 0 - Azure CLI auth"
$ctxRaw = ""
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
try { $ctxRaw = & az account show -o json --only-show-errors 2>$null } catch {}
$ErrorActionPreference = $prevEAP
if ([string]::IsNullOrWhiteSpace($ctxRaw)) {
    Warn "Not logged in. Running az login..."
    & az login --only-show-errors | Out-Null
    $ctxRaw = & az account show -o json --only-show-errors 2>$null
}
$ctx = $ctxRaw | ConvertFrom-Json
& az account set --subscription $Subscription --only-show-errors | Out-Null
Ok "Logged in: $($ctx.user.name)"
Ok "Subscription set: $Subscription"

function Test-ProfileExists {
    param([string]$Name, [string]$RG)
    $url = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$RG/providers/Microsoft.Cdn/profiles/${Name}?api-version=2025-04-15"
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    try {
        $r = & az rest --method get --url $url --only-show-errors 2>$null
        if ([string]::IsNullOrWhiteSpace($r)) { return $null }
        return ($r | ConvertFrom-Json)
    } catch { return $null }
    finally { $ErrorActionPreference = $prevEAP }
}

function Test-ClassicAfdExists {
    param([string]$Name, [string]$RG)
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    try {
        $r = & az network front-door show --resource-group $RG --name $Name -o json --only-show-errors 2>$null
        if ([string]::IsNullOrWhiteSpace($r)) { return $null }
        return ($r | ConvertFrom-Json)
    } catch { return $null }
    finally { $ErrorActionPreference = $prevEAP }
}

function Test-ClassicCdnExists {
    param([string]$Name, [string]$RG)
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    try {
        $r = & az cdn profile show --profile-name $Name --resource-group $RG -o json --only-show-errors 2>$null
        if ([string]::IsNullOrWhiteSpace($r)) { return $null }
        return ($r | ConvertFrom-Json)
    } catch { return $null }
    finally { $ErrorActionPreference = $prevEAP }
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
    $info = @{ Classic=$p.Classic; Standard=$p.Standard; RG=$p.RG; Type=$p.Type; Sku=$p.Sku; Action=""; ClassicId=""; Status="pending"; Error=""; Verified=$false; VerifiedSku=""; VerifiedState=""; }
    $existing = Test-ProfileExists -Name $p.Standard -RG $p.RG
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
            $classic = Test-ClassicAfdExists -Name $p.Classic -RG $p.RG
            if ($classic) {
                $info.ClassicId = $classic.id
                $info.Action = "MIGRATE"
            } else {
                $info.Action = "NO-CLASSIC"
            }
        } else {
            $cdn = Test-ClassicCdnExists -Name $p.Classic -RG $p.RG
            if ($cdn) {
                $info.ClassicId = $cdn.id
                $info.Action = "MIGRATE"
            } else {
                $info.Action = "NO-CLASSIC"
            }
        }
    }
    Info ("  {0,-14} ({1}) -> {2,-20} action={3,-14} new-sku={4} new-state={5}" -f $p.Classic, $p.Type, $p.Standard, $info.Action, $info.VerifiedSku, $info.VerifiedState)
    $plan += $info
}

if ($DryRun) {
    Ok "DryRun complete. No changes."
    Stop-Transcript | Out-Null
    return
}

if (-not $Yes) {
    Write-Host ""
    $resp = Read-Host "Proceed with migration via REST API? Type YES"
    if ($resp -ne "YES") { Warn "Aborted"; Stop-Transcript | Out-Null; return }
}

Say "Phase 2 - Per-profile migration via REST"
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
        Err "Classic profile $($info.Classic) does not exist. Skipping."
        continue
    }

    if ($info.Action -eq "MIGRATE") {
        if ($info.Type -eq "AFD") {
            $migrateUrl = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$($info.RG)/providers/Microsoft.Cdn/migrate?api-version=2025-04-15"
            $bodyObj = @{
                sku = @{ name = $info.Sku }
                classicResourceReference = @{ id = $info.ClassicId }
                profileName = $info.Standard
            }
        } else {
            $migrateUrl = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$($info.RG)/providers/Microsoft.Cdn/profiles/$($info.Classic)/cdnMigrateToAfd?api-version=2025-04-15"
            $bodyObj = @{
                sku = @{ name = $info.Sku }
            }
        }
        $bodyJson = $bodyObj | ConvertTo-Json -Depth 5 -Compress
        $bodyFile = Join-Path $bodyDir "migrate-$($info.Classic).json"
        $bodyJson | Out-File -FilePath $bodyFile -Encoding ascii -Force

        $endpointDesc = if ($info.Type -eq "AFD") { ".../Microsoft.Cdn/migrate" } else { ".../profiles/$($info.Classic)/cdnMigrateToAfd" }
        Info "Step 1/2: POST $endpointDesc"
        Info "Body file: $bodyFile"
        try {
            $resp = & az rest --method post --url $migrateUrl --body "@$bodyFile" --headers "Content-Type=application/json" --only-show-errors 2>&1
            $exit = $LASTEXITCODE
            if ($exit -ne 0) {
                $errOut = ($resp | Out-String)
                if ($errOut -match 'AlreadyMigrating|MigrationInProgress|already in migration|current state') {
                    Warn "Already in migration state (continuing to commit step)"
                } else {
                    throw "az rest exit=$exit. Output: $errOut"
                }
            } else {
                Ok "Migrate (Prepare) submitted successfully"
            }
            $info.MigratePending = $true
        } catch {
            $info.Status = "prepare-failed"; $info.Error = $_.Exception.Message
            Err "Migrate FAILED: $($_.Exception.Message)"
            continue
        }

        Info "Waiting 60 seconds for prepare to complete..."
        Start-Sleep -Seconds 60

        $checkProfile = Test-ProfileExists -Name $info.Standard -RG $info.RG
        if ($checkProfile) {
            Info "New profile state after prepare: $($checkProfile.properties.provisioningState)"
        } else {
            Warn "New profile not visible yet (will continue to commit)"
        }
    }

    $commitUrl = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$($info.RG)/providers/Microsoft.Cdn/profiles/$($info.Standard)/migrationCommit?api-version=2025-04-15"
    Info "Step 2/2: POST .../profiles/$($info.Standard)/migrationCommit"
    try {
        $resp = & az rest --method post --url $commitUrl --only-show-errors 2>&1
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
            $errOut = ($resp | Out-String)
            if ($errOut -match 'AlreadyCommitted|already committed|MigrationAlreadyCommitted') {
                Warn "Already committed (idempotent)"
                $info.Status = "migrated-and-committed"
            } else {
                throw "az rest exit=$exit. Output: $errOut"
            }
        } else {
            Ok "Commit submitted - traffic now on Standard"
            $info.Status = "migrated-and-committed"
        }
    } catch {
        $info.Status = "commit-failed"; $info.Error = $_.Exception.Message
        Err "Commit FAILED: $($_.Exception.Message)"
    }
}

Say "Phase 3 - Verification (poll Azure for actual state)"
$maxWaitSec = 180
$pollIntervalSec = 15
foreach ($info in $plan) {
    if ($info.Status -in @("no-classic","already-done")) {
        if ($info.Status -eq "already-done") { $info.Verified = $true }
        continue
    }

    $elapsed = 0
    while ($elapsed -lt $maxWaitSec) {
        $check = Test-ProfileExists -Name $info.Standard -RG $info.RG
        if ($check -and $check.sku -and $check.sku.name -in @("Standard_AzureFrontDoor","Premium_AzureFrontDoor") -and $check.properties.provisioningState -eq "Succeeded") {
            $info.Verified = $true
            $info.VerifiedSku = $check.sku.name
            $info.VerifiedState = $check.properties.provisioningState
            Ok "$($info.Standard): VERIFIED LIVE (sku=$($check.sku.name), state=$($check.properties.provisioningState))"
            break
        } elseif ($check) {
            $info.VerifiedSku = $check.sku.name
            $info.VerifiedState = $check.properties.provisioningState
            Info "  $($info.Standard): state=$($check.properties.provisioningState), waiting..."
        } else {
            Info "  $($info.Standard): not visible yet, waiting..."
        }
        Start-Sleep -Seconds $pollIntervalSec
        $elapsed += $pollIntervalSec
    }
    if (-not $info.Verified) {
        Err "$($info.Standard): NOT verified within ${maxWaitSec}s (final state=$($info.VerifiedState), sku=$($info.VerifiedSku))"
    }
}

Say "Phase 4 - Reports"
$plan | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding utf8

$rowsHtml = ""
foreach ($i in $plan) {
    $cssClass  = if ($i.Verified -eq $true) { "ok" } else { "bad" }
    $statusTxt = if ($i.Verified -eq $true) { "PASS" } else { "FAIL" }
    $rowsHtml += "<tr class='$cssClass'><td><strong>$statusTxt</strong></td><td>$($i.Classic)</td><td>$($i.Type)</td><td>$($i.Standard)</td><td>$($i.RG)</td><td>$($i.VerifiedSku)</td><td>$($i.VerifiedState)</td><td>$($i.Status)</td></tr>`n"
}
$verifiedCount = @($plan | Where-Object { $_.Verified -eq $true }).Count
$totalCount = $plan.Count
$failedCount = $totalCount - $verifiedCount
$reportTimestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$bigClass = if ($failedCount -eq 0) { "" } else { " bad" }

$html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>PYX Front Door Migration Report</title>
<style>
body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; max-width: 1100px; margin: 30px auto; padding: 0 20px; color: #11151C; }
h1 { color: #1F3D7A; border-bottom: 3px solid #1F3D7A; padding-bottom: 10px; }
h2 { color: #1F3D7A; margin-top: 30px; }
.summary { background: #F5F7FA; padding: 20px; border-left: 5px solid #1F3D7A; margin: 20px 0; }
.summary .big { font-size: 36px; font-weight: bold; color: #1B6B3A; }
.summary .big.bad { color: #9B2226; }
table { width: 100%; border-collapse: collapse; margin: 20px 0; }
th { background: #1F3D7A; color: white; padding: 10px; text-align: left; }
td { padding: 10px; border-bottom: 1px solid #C8CFD9; }
tr.ok td:first-child { color: #1B6B3A; font-weight: bold; }
tr.bad td:first-child { color: #9B2226; font-weight: bold; }
tr.ok { background: #F1FAF4; }
tr.bad { background: #FFF1F2; }
.meta { color: #555E6D; font-size: 13px; margin-top: 30px; }
code { background: #F5F7FA; padding: 2px 6px; border-radius: 3px; font-family: Consolas, monospace; }
</style></head><body>
<h1>PYX Front Door Migration Report</h1>
<p>Migration via Azure REST API (Microsoft.Cdn 2025-04-15) called through <code>az rest</code>.</p>

<div class="summary">
<div class="big$bigClass">$verifiedCount / $totalCount profiles VERIFIED LIVE</div>
</div>

<h2>Per-profile results</h2>
<table>
<thead><tr><th>Status</th><th>Classic profile</th><th>Type</th><th>New profile</th><th>Resource group</th><th>SKU</th><th>State</th><th>Script status</th></tr></thead>
<tbody>
$rowsHtml
</tbody>
</table>

<h2>Subscription</h2>
<p><code>$Subscription</code> (sub-corp-prod-001)</p>

<p class="meta">Generated $reportTimestamp | Script: PYX-AFD-Migrate-v10.ps1 | API: Microsoft.Cdn 2025-04-15</p>
</body></html>
"@
$html | Out-File -FilePath $htmlPath -Encoding utf8

Say "Final summary"
Ok "Verified live in Azure: $verifiedCount / $totalCount"
if ($failedCount -gt 0) {
    foreach ($f in @($plan | Where-Object { $_.Verified -ne $true })) {
        Err "  $($f.Classic): action=$($f.Action) status=$($f.Status) sku=$($f.VerifiedSku) state=$($f.VerifiedState)"
    }
}
Ok "JSON: $jsonPath"
Ok "HTML: $htmlPath"
Ok "Log:  $logPath"

Stop-Transcript | Out-Null
