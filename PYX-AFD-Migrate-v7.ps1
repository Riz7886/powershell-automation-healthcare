[CmdletBinding()]
param(
    [string]$Subscription = "e42e94b5-c6f8-4af0-a41b-16fda520de6e",
    [switch]$Yes,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Say  ($m) { Write-Host "`n[step] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "  ok   $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  warn $m" -ForegroundColor Yellow }
function Err  ($m) { Write-Host "  ERR  $m" -ForegroundColor Red }
function Info ($m) { Write-Host "       $m" -ForegroundColor Gray }

function Confirm-Action($prompt) {
    if ($Yes) { return $true }
    $ans = Read-Host "  ?? $prompt [y/N]"
    if ($null -eq $ans) { return $false }
    return $ans.ToString().Trim().ToLower().StartsWith('y')
}

$Benign = @('already exists','ResourceAlreadyExists','AlreadyExistsError','is already associated','AlreadyMigrated','MigrationAlreadyCommitted')

function Invoke-Az {
    $cmdText = "az " + ($args -join " ")
    if ($DryRun) { Write-Host "  DRYRUN: $cmdText" -ForegroundColor Magenta; return "" }
    $output = & az @args 2>&1
    $exit = $LASTEXITCODE
    if ($exit -eq 0) { return $output }
    $errText = ($output | Out-String)
    foreach ($pat in $Benign) {
        if ($errText -match [regex]::Escape($pat)) {
            Warn "Benign already-exists: $cmdText"
            return $output
        }
    }
    Err "az FAILED exit=$exit : $cmdText"
    $errText.TrimEnd() -split "`n" | ForEach-Object { Err "    $_" }
    throw "Azure CLI failed: $cmdText"
}

function Get-AzProfileExists {
    param([string]$Type, [string]$Name, [string]$RG)
    if ($Type -eq "afd") {
        $r = az afd profile show --profile-name $Name --resource-group $RG -o tsv --query id --only-show-errors 2>$null
    } else {
        $r = az cdn profile show --profile-name $Name --resource-group $RG -o tsv --query id --only-show-errors 2>$null
    }
    return -not [string]::IsNullOrWhiteSpace($r)
}

function Get-AzProfileSku {
    param([string]$Name, [string]$RG)
    $r = az afd profile show --profile-name $Name --resource-group $RG -o tsv --query "sku.name" --only-show-errors 2>$null
    if ([string]::IsNullOrWhiteSpace($r)) { return "" }
    return $r.Trim()
}

function Get-AzProfileState {
    param([string]$Name, [string]$RG)
    $r = az afd profile show --profile-name $Name --resource-group $RG -o tsv --query "provisioningState" --only-show-errors 2>$null
    if ([string]::IsNullOrWhiteSpace($r)) { return "" }
    return $r.Trim()
}

function Get-ClassicAfdId {
    param([string]$Name, [string]$RG)
    $r = az network front-door show --resource-group $RG --name $Name -o tsv --query id --only-show-errors 2>$null
    if ([string]::IsNullOrWhiteSpace($r)) { return "" }
    return $r.Trim()
}

function Get-ClassicCdnId {
    param([string]$Name, [string]$RG)
    $r = az cdn profile show --profile-name $Name --resource-group $RG -o tsv --query id --only-show-errors 2>$null
    if ([string]::IsNullOrWhiteSpace($r)) { return "" }
    return $r.Trim()
}

$reportDir = Join-Path $env:USERPROFILE "Desktop\pyx-frontdoor-migration"
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$logPath  = Join-Path $reportDir "migration-v7-$stamp.log"
$jsonPath = Join-Path $reportDir "results-v7-$stamp.json"
$htmlPath = Join-Path $reportDir "PYX-AFD-Migration-Report-v7-$stamp.html"
Start-Transcript -Path $logPath -Force | Out-Null

Say "PYX AFD/CDN Classic-to-Standard Migration v7"
Info "Subscription:  $Subscription"
Info "Report dir:    $reportDir"
Info "PowerShell:    $($PSVersionTable.PSVersion)"

Say "Preflight"
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI not installed." }

$acct = $null
try { $acct = az account show --only-show-errors 2>$null | ConvertFrom-Json } catch { $acct = $null }
if (-not $acct) {
    Warn "Not logged in. Running az login..."
    az login --only-show-errors | Out-Null
    $acct = az account show --only-show-errors 2>$null | ConvertFrom-Json
}
Ok "Logged in: $($acct.user.name) (sub $($acct.id))"

az account set --subscription $Subscription --only-show-errors | Out-Null
Ok "Subscription set: $Subscription"

$profiles = @(
    @{ Classic = "pyxiq";        Standard = "pyxiq-std";        RG = "Production"; Type = "afd"; Sku = "Standard_AzureFrontDoor" }
    @{ Classic = "hipyx";        Standard = "hipyx-std-v2";     RG = "production"; Type = "afd"; Sku = "Standard_AzureFrontDoor" }
    @{ Classic = "pyxiq-stage";  Standard = "pyxiq-stage-std";  RG = "Stage";      Type = "afd"; Sku = "Standard_AzureFrontDoor" }
    @{ Classic = "pyxpwa-stage"; Standard = "pyxpwa-stage-std"; RG = "Stage";      Type = "afd"; Sku = "Standard_AzureFrontDoor" }
    @{ Classic = "standard";     Standard = "standard-afdstd";  RG = "Test";       Type = "cdn"; Sku = "Standard_AzureFrontDoor" }
)

Say "Phase 1 - Discovery (real Azure state)"
$plan = @()
foreach ($p in $profiles) {
    $info = @{
        Classic = $p.Classic; Standard = $p.Standard; RG = $p.RG; Type = $p.Type; Sku = $p.Sku
        ClassicId = ""; ClassicExists = $false
        NewExists = $false; NewSku = ""; NewState = ""
        Action = ""; Status = "pending"; Error = ""
    }

    if ($p.Type -eq "afd") {
        $info.ClassicId = Get-ClassicAfdId -Name $p.Classic -RG $p.RG
    } else {
        $info.ClassicId = Get-ClassicCdnId -Name $p.Classic -RG $p.RG
    }
    $info.ClassicExists = -not [string]::IsNullOrWhiteSpace($info.ClassicId)

    $info.NewExists = Get-AzProfileExists -Type "afd" -Name $p.Standard -RG $p.RG
    if ($info.NewExists) {
        $info.NewSku = Get-AzProfileSku -Name $p.Standard -RG $p.RG
        $info.NewState = Get-AzProfileState -Name $p.Standard -RG $p.RG
    }

    if ($info.NewExists -and $info.NewSku -in @("Standard_AzureFrontDoor","Premium_AzureFrontDoor") -and $info.NewState -eq "Succeeded") {
        $info.Action = "ALREADY-DONE"
    } elseif ($info.NewExists) {
        $info.Action = "VERIFY-AND-COMMIT"
    } elseif ($info.ClassicExists) {
        $info.Action = "MIGRATE"
    } else {
        $info.Action = "NO-CLASSIC-FOUND"
    }

    Info ("  {0,-14} ({1}) -> {2,-20} action={3,-18} new-exists={4} sku={5} state={6}" -f $p.Classic, $p.Type, $p.Standard, $info.Action, $info.NewExists, $info.NewSku, $info.NewState)
    $plan += $info
}

if ($DryRun) {
    Ok "DryRun complete. No changes made."
    Stop-Transcript | Out-Null
    return
}

if (-not $Yes) {
    if (-not (Confirm-Action "Proceed with migrations above?")) {
        Warn "User aborted"
        Stop-Transcript | Out-Null
        return
    }
}

Say "Phase 2 - Per-profile execution"
foreach ($info in $plan) {
    Write-Host ""
    Say "$($info.Classic) [$($info.Type)] -> $($info.Standard) ($($info.Action))"

    if ($info.Action -eq "ALREADY-DONE") {
        $info.Status = "already-done"
        Ok "Already on Standard SKU. Nothing to do."
        continue
    }

    if ($info.Action -eq "NO-CLASSIC-FOUND") {
        $info.Status = "no-classic-found"
        Err "Classic profile $($info.Classic) does not exist in $($info.RG). Skipping."
        continue
    }

    if ($info.Action -eq "MIGRATE") {
        try {
            if ($info.Type -eq "afd") {
                Info "Step 1/2: az afd profile migrate (proven April 24 pattern)"
                Invoke-Az afd profile migrate --profile-name $info.Standard --resource-group $info.RG --classic-resource-id $info.ClassicId --sku $info.Sku --only-show-errors | Out-Null
                Ok "AFD Migrate (Prepare) succeeded"
            } else {
                Info "Step 1/2: az cdn profile-migration migrate (against classic profile)"
                Invoke-Az cdn profile-migration migrate --profile-name $info.Classic --resource-group $info.RG --sku $info.Sku --only-show-errors | Out-Null
                Ok "CDN Migrate (Prepare) succeeded"
            }
        } catch {
            $info.Status = "prepare-failed"
            $info.Error = $_.Exception.Message
            Err "Prepare FAILED: $($_.Exception.Message)"
            continue
        }
    }

    try {
        if ($info.Type -eq "afd") {
            Info "Step 2/2: az afd profile migration-commit"
            Invoke-Az afd profile migration-commit --profile-name $info.Standard --resource-group $info.RG --only-show-errors | Out-Null
            Ok "AFD Commit succeeded"
        } else {
            Info "Step 2/2: az cdn profile-migration commit (against classic profile)"
            Invoke-Az cdn profile-migration commit --profile-name $info.Classic --resource-group $info.RG --only-show-errors | Out-Null
            Ok "CDN Commit succeeded"
        }
        $info.Status = "migrated-and-committed"
    } catch {
        $info.Status = "commit-failed"
        $info.Error = $_.Exception.Message
        Err "Commit FAILED: $($_.Exception.Message)"
    }
}

Say "Phase 3 - Real Azure verification"
foreach ($info in $plan) {
    $exists = Get-AzProfileExists -Type "afd" -Name $info.Standard -RG $info.RG
    if ($exists) {
        $sku = Get-AzProfileSku   -Name $info.Standard -RG $info.RG
        $state = Get-AzProfileState -Name $info.Standard -RG $info.RG
        $info.NewSku = $sku
        $info.NewState = $state
        if ($sku -in @("Standard_AzureFrontDoor","Premium_AzureFrontDoor") -and $state -eq "Succeeded") {
            $info.Verified = $true
            Ok "$($info.Standard): VERIFIED LIVE (sku=$sku, state=$state)"
        } else {
            $info.Verified = $false
            Warn "$($info.Standard): exists but state=$state sku=$sku"
        }
    } else {
        $info.Verified = $false
        Err "$($info.Standard): NOT FOUND in Azure"
    }
}

Say "Phase 4 - Reports"
$plan | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding utf8

$rowsHtml = ""
foreach ($i in $plan) {
    $cssClass  = if ($i.Verified -eq $true) { "ok" } else { "bad" }
    $statusTxt = if ($i.Verified -eq $true) { "PASS" } else { "FAIL" }
    $rowsHtml += "<tr class='$cssClass'><td><strong>$statusTxt</strong></td><td>$($i.Classic)</td><td>$($i.Type.ToUpper())</td><td>$($i.Standard)</td><td>$($i.RG)</td><td>$($i.NewSku)</td><td>$($i.NewState)</td><td>$($i.Status)</td></tr>`n"
}
$verifiedCount = @($plan | Where-Object { $_.Verified -eq $true }).Count
$totalCount    = $plan.Count
$failedCount   = $totalCount - $verifiedCount
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
<p>Classic-to-Standard migration via Azure CLI (v7). Verification queries each new profile in Azure to confirm it exists on Standard_AzureFrontDoor SKU with provisioningState=Succeeded.</p>

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

<h2>Next steps</h2>
<ul>
<li>Classic profiles will auto-cleanup approximately 15 days after migration-commit</li>
<li>Custom domains (if any) need DNS cutover to new <code>*.azurefd.net</code> endpoints</li>
<li>Monitor traffic on new profiles via Azure Portal</li>
</ul>

<p class="meta">Generated $reportTimestamp | Script: PYX-AFD-Migrate-v7.ps1</p>
</body></html>
"@
$html | Out-File -FilePath $htmlPath -Encoding utf8

Say "Final summary"
Ok "Verified live in Azure: $verifiedCount / $totalCount"
if ($failedCount -gt 0) {
    Err "NOT verified live: $failedCount"
    foreach ($f in @($plan | Where-Object { $_.Verified -ne $true })) {
        Err "  $($f.Classic): action=$($f.Action) status=$($f.Status) sku=$($f.NewSku) state=$($f.NewState)"
    }
}
Ok "JSON:    $jsonPath"
Ok "HTML:    $htmlPath"
Ok "Log:     $logPath"

Stop-Transcript | Out-Null
