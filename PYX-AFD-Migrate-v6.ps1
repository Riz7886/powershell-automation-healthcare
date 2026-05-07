[CmdletBinding()]
param(
    [string]$SubscriptionId = "e42e94b5-c6f8-4af0-a41b-16fda520de6e",
    [switch]$NoConfirm,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$global:ProgressPreference = "SilentlyContinue"

function Log($msg, $level = "INFO") {
    $ts = (Get-Date).ToString("HH:mm:ss")
    $prefix = switch ($level) { "OK" { "[OK]" } "ERR" { "[ERR]" } "WARN" { "[WARN]" } "STEP" { "[STEP]" } default { "[INFO]" } }
    Write-Host "[$ts] $prefix $msg"
}

function Banner($t) { Log ""; Log ("=" * 80); Log $t "STEP"; Log ("=" * 80); Log "" }

function Invoke-Az {
    param([string[]]$Args)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $combined = & az @Args 2>&1
        $stdout = @()
        foreach ($item in $combined) {
            if ($item -is [System.Management.Automation.ErrorRecord]) { continue }
            $stdout += $item
        }
        if ($LASTEXITCODE -ne 0) {
            throw ("az " + ($Args -join " ") + " FAILED (exit=$LASTEXITCODE): " + (($combined | Out-String).Trim()))
        }
        return $stdout
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

function Az-Try {
    param([string[]]$Args)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $combined = & az @Args 2>&1
        $stdout = @()
        foreach ($item in $combined) {
            if ($item -is [System.Management.Automation.ErrorRecord]) { continue }
            $stdout += $item
        }
        return @{ Ok = ($LASTEXITCODE -eq 0); Out = $stdout }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

$reportDir = Join-Path $env:USERPROFILE "Desktop\pyx-frontdoor-migration"
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$logPath = Join-Path $reportDir "migration-v6-$stamp.log"
Start-Transcript -Path $logPath -Force | Out-Null

Banner "PYX AFD Classic-to-Standard Migration v6 (az CLI - verified, with HTML report)"
Log "Subscription: $SubscriptionId"
Log "Report dir:   $reportDir"
Log "DryRun:       $DryRun"
Log "PowerShell:   $($PSVersionTable.PSVersion)"

Banner "Phase 0 -- Azure CLI auth"
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$azVerOut = & az --version 2>&1
$azVerLine = ($azVerOut | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | Select-Object -First 1)
$ErrorActionPreference = $prevEAP
Log "az CLI: $azVerLine"

$ctxCheck = Az-Try -Args @("account","show","--query","id","-o","tsv","--only-show-errors")
if (-not $ctxCheck.Ok) {
    Log "Not logged in. Running az login..." "WARN"
    $prevEAP2 = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & az login --only-show-errors *>&1 | Out-Null
    $ErrorActionPreference = $prevEAP2
}
$null = Invoke-Az -Args @("account","set","--subscription",$SubscriptionId,"--only-show-errors")
$meOut = Invoke-Az -Args @("account","show","--query","user.name","-o","tsv","--only-show-errors")
$me = ($meOut -join "").Trim()
Log "Logged in as: $me" "OK"
Log "Subscription set: $SubscriptionId" "OK"

$profiles = @(
    @{ Classic = "pyxiq";        Standard = "pyxiq-std";        RG = "Production"; Type = "AFD"; Sku = "Standard_AzureFrontDoor" }
    @{ Classic = "hipyx";        Standard = "hipyx-std-v2";     RG = "production"; Type = "AFD"; Sku = "Standard_AzureFrontDoor" }
    @{ Classic = "pyxiq-stage";  Standard = "pyxiq-stage-std";  RG = "Stage";      Type = "AFD"; Sku = "Standard_AzureFrontDoor" }
    @{ Classic = "pyxpwa-stage"; Standard = "pyxpwa-stage-std"; RG = "Stage";      Type = "AFD"; Sku = "Standard_AzureFrontDoor" }
    @{ Classic = "standard";     Standard = "standard-afdstd";  RG = "Test";       Type = "CDN"; Sku = "Standard_AzureFrontDoor" }
)

Banner "Phase 1 -- Discovery"
$plan = @()
foreach ($p in $profiles) {
    Log "Resolving $($p.Classic) ($($p.Type)) in $($p.RG)..."

    if ($p.Type -eq "AFD") {
        $r = Az-Try -Args @("network","front-door","show","-g",$p.RG,"-n",$p.Classic,"--query","id","-o","tsv","--only-show-errors")
        if ($r.Ok -and $r.Out) {
            $classicId = ($r.Out -join "").Trim()
            $p.ClassicId = $classicId
            Log "  Classic AFD found: $classicId" "OK"
        } else {
            Log "  Classic AFD NOT FOUND" "WARN"
            $p.ClassicId = $null
        }
    } else {
        $r = Az-Try -Args @("cdn","profile","show","-g",$p.RG,"-n",$p.Classic,"--query","id","-o","tsv","--only-show-errors")
        if ($r.Ok -and $r.Out) {
            $classicId = ($r.Out -join "").Trim()
            $p.ClassicId = $classicId
            Log "  Classic CDN found: $classicId" "OK"
        } else {
            Log "  Classic CDN NOT FOUND" "WARN"
            $p.ClassicId = $null
        }
    }

    $newCheck = Az-Try -Args @("afd","profile","show","--profile-name",$p.Standard,"-g",$p.RG,"--query","{name:name, sku:sku.name, state:provisioningState, mig:extendedProperties.migrationState}","-o","json","--only-show-errors")
    if ($newCheck.Ok -and $newCheck.Out) {
        try {
            $newJson = ($newCheck.Out -join "") | ConvertFrom-Json
            $p.NewExists = $true
            $p.NewSku = $newJson.sku
            $p.NewState = $newJson.state
            $p.MigrationState = $newJson.mig
            Log "  Standard profile EXISTS: sku=$($newJson.sku) state=$($newJson.state) migration=$($newJson.mig)" "WARN"
        } catch {
            $p.NewExists = $false
        }
    } else {
        $p.NewExists = $false
        Log "  Standard profile does NOT exist yet" "OK"
    }

    $plan += $p
    Log ""
}

Banner "Phase 2 -- Migration plan"
foreach ($p in $plan) {
    $action = "MIGRATE"
    if ($p.NewExists) {
        if ($p.MigrationState -eq "Migrated" -or $p.NewSku -in @("Standard_AzureFrontDoor","Premium_AzureFrontDoor")) {
            if ($p.MigrationState -eq "Migrated") { $action = "COMMIT-ONLY" }
            else { $action = "ALREADY-DONE" }
        } else {
            $action = "RESUME-OR-ABORT"
        }
    }
    Log "  $($p.Classic) [$($p.Type)] -> $($p.Standard) -- ACTION: $action"
}

if ($DryRun) {
    Log ""
    Log "DryRun -- exiting after plan" "OK"
    Stop-Transcript | Out-Null
    return
}

if (-not $NoConfirm) {
    $resp = Read-Host "Proceed with migration? (Type YES)"
    if ($resp -ne "YES") { Log "Aborted by user" "WARN"; Stop-Transcript | Out-Null; return }
}

Banner "Phase 3 -- Per-profile migration"
$results = @()
foreach ($p in $plan) {
    Banner "$($p.Classic) -> $($p.Standard)"
    $r = @{ Profile = $p.Classic; Status = "pending"; StartedAt = (Get-Date).ToString("HH:mm:ss") }

    if ($p.NewExists -and ($p.MigrationState -eq "Migrated" -or $p.NewSku -in @("Standard_AzureFrontDoor","Premium_AzureFrontDoor"))) {
        if ($p.MigrationState -eq "Migrated") {
            Log "Profile already migrated -- running migration-commit on AFD profile" "WARN"
            try {
                Invoke-Az -Args @("afd","profile","migration-commit","--profile-name",$p.Standard,"-g",$p.RG,"--only-show-errors")
                $r.Status = "committed"
                Log "Commit succeeded" "OK"
            } catch {
                $r.Status = "commit-failed"; $r.Error = $_.Exception.Message
                Log "Commit FAILED: $($_.Exception.Message)" "ERR"
            }
        } else {
            $r.Status = "already-done"
            Log "Already on Standard SKU -- nothing to do" "OK"
        }
        $results += $r
        continue
    }

    if (-not $p.ClassicId) {
        $r.Status = "no-classic"
        Log "Classic profile not found -- SKIP" "WARN"
        $results += $r
        continue
    }

    if ($p.Type -eq "AFD") {
        Log "Step 1 -- az afd profile migrate (Prepare)"
        try {
            Invoke-Az -Args @("afd","profile","migrate","--profile-name",$p.Standard,"-g",$p.RG,"--classic-resource-id",$p.ClassicId,"--sku",$p.Sku,"--only-show-errors")
            Log "Prepare succeeded" "OK"
        } catch {
            $r.Status = "prepare-failed"; $r.Error = $_.Exception.Message
            Log "Prepare FAILED: $($_.Exception.Message)" "ERR"
            $results += $r
            continue
        }

        Log "Step 2 -- az afd profile migration-commit"
        try {
            Invoke-Az -Args @("afd","profile","migration-commit","--profile-name",$p.Standard,"-g",$p.RG,"--only-show-errors")
            $r.Status = "migrated-and-committed"
            Log "Commit succeeded -- traffic on Standard profile" "OK"
        } catch {
            $r.Status = "commit-failed"; $r.Error = $_.Exception.Message
            Log "Commit FAILED: $($_.Exception.Message)" "ERR"
        }
    } else {
        Log "Step 1 -- az cdn migrate (CDN classic Prepare)"
        try {
            Invoke-Az -Args @("cdn","migrate","--new-sku",$p.Sku,"--profile-name",$p.Classic,"-g",$p.RG,"--new-profile-name",$p.Standard,"--only-show-errors")
            Log "CDN Prepare succeeded" "OK"
        } catch {
            $r.Status = "prepare-failed"; $r.Error = $_.Exception.Message
            Log "CDN Prepare FAILED: $($_.Exception.Message)" "ERR"
            $results += $r
            continue
        }

        Log "Step 2 -- az afd profile migration-commit (on new AFD profile)"
        try {
            Invoke-Az -Args @("afd","profile","migration-commit","--profile-name",$p.Standard,"-g",$p.RG,"--only-show-errors")
            $r.Status = "migrated-and-committed"
            Log "CDN Commit succeeded" "OK"
        } catch {
            $r.Status = "commit-failed"; $r.Error = $_.Exception.Message
            Log "CDN Commit FAILED: $($_.Exception.Message)" "ERR"
        }
    }

    $r.CompletedAt = (Get-Date).ToString("HH:mm:ss")
    $results += $r
}

Banner "Phase 4 -- Real Azure verification (query each new profile)"
foreach ($r in $results) {
    $p = $plan | Where-Object { $_.Classic -eq $r.Profile } | Select-Object -First 1
    if (-not $p) { continue }
    $check = Az-Try -Args @("afd","profile","show","--profile-name",$p.Standard,"-g",$p.RG,"--query","{name:name, sku:sku.name, state:provisioningState}","-o","json","--only-show-errors")
    if ($check.Ok -and $check.Out) {
        try {
            $obj = ($check.Out -join "") | ConvertFrom-Json
            if ($obj.sku -in @("Standard_AzureFrontDoor","Premium_AzureFrontDoor") -and $obj.state -eq "Succeeded") {
                $r.Verified = $true
                $r.VerifiedSku = $obj.sku
                $r.VerifiedState = $obj.state
                Log "  $($p.Standard): VERIFIED LIVE (sku=$($obj.sku), state=$($obj.state))" "OK"
            } else {
                $r.Verified = $false
                $r.VerifiedSku = $obj.sku
                $r.VerifiedState = $obj.state
                Log "  $($p.Standard): EXISTS but unexpected state (sku=$($obj.sku), state=$($obj.state))" "WARN"
            }
        } catch {
            $r.Verified = $false
            Log "  $($p.Standard): query parse failed -- $($_.Exception.Message)" "WARN"
        }
    } else {
        $r.Verified = $false
        Log "  $($p.Standard): NOT FOUND in Azure -- migration did NOT happen" "ERR"
    }
}

Banner "Final summary"
$verifiedOk  = @($results | Where-Object { $_.Verified -eq $true })
$verifiedBad = @($results | Where-Object { $_.Verified -ne $true })
Log "Verified live in Azure: $($verifiedOk.Count) / $($results.Count)" "OK"
if ($verifiedBad.Count -gt 0) {
    Log "NOT verified live:      $($verifiedBad.Count)" "ERR"
    foreach ($f in $verifiedBad) { Log "  $($f.Profile): script-status=$($f.Status), azure-state=$($f.VerifiedState), azure-sku=$($f.VerifiedSku)" "ERR" }
}

$jsonPath = Join-Path $reportDir "results-v6-$stamp.json"
$results | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding utf8
Log "Results JSON: $jsonPath" "OK"

$htmlPath = Join-Path $reportDir "PYX-AFD-Migration-Report-$stamp.html"
$rowsHtml = ""
foreach ($r in $results) {
    $p = $plan | Where-Object { $_.Classic -eq $r.Profile } | Select-Object -First 1
    $cssClass = if ($r.Verified -eq $true) { "ok" } else { "bad" }
    $statusIcon = if ($r.Verified -eq $true) { "PASS" } else { "FAIL" }
    $rowsHtml += "<tr class='$cssClass'><td><strong>$statusIcon</strong></td><td>$($r.Profile)</td><td>$($p.Type)</td><td>$($p.Standard)</td><td>$($p.RG)</td><td>$($r.VerifiedSku)</td><td>$($r.VerifiedState)</td><td>$($r.Status)</td></tr>`n"
}
$totalCount = $results.Count
$verifiedCount = $verifiedOk.Count
$failedCount = $verifiedBad.Count
$reportTimestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
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
<p>Classic-to-Standard migration via Azure CLI (v6).</p>

<div class="summary">
<div class="big$(if ($failedCount -gt 0) { " bad" })">$verifiedCount / $totalCount profiles VERIFIED LIVE</div>
<p>Verification queries each new profile in Azure to confirm it exists on Standard_AzureFrontDoor SKU with provisioningState=Succeeded.</p>
</div>

<h2>Per-profile results</h2>
<table>
<thead><tr><th>Status</th><th>Classic profile</th><th>Type</th><th>New profile</th><th>Resource group</th><th>SKU</th><th>State</th><th>Script status</th></tr></thead>
<tbody>
$rowsHtml
</tbody>
</table>

<h2>Subscription</h2>
<p><code>$SubscriptionId</code> (sub-corp-prod-001)</p>

<h2>Next steps</h2>
<ul>
<li>Classic profiles will auto-cleanup approximately 15 days after migration-commit</li>
<li>Custom domains (if any) need DNS cutover - publish TXT validation records, wait for Approved cert state, publish CNAME to new <code>*.azurefd.net</code> endpoints, TTL 300s for fast rollback</li>
<li>Monitor traffic on new profiles via Azure Portal -> Front Door and CDN profiles -> Metrics</li>
</ul>

<p class="meta">Generated $reportTimestamp | Script: PYX-AFD-Migrate-v6.ps1 | Run log: <code>migration-v6-$stamp.log</code></p>
</body></html>
"@
$html | Out-File -FilePath $htmlPath -Encoding utf8
Log "HTML report: $htmlPath" "OK"
Log "Log:         $logPath" "OK"

Stop-Transcript | Out-Null
