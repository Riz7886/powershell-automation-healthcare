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
$logPath = Join-Path $reportDir "migration-v5-$stamp.log"
Start-Transcript -Path $logPath -Force | Out-Null

Banner "PYX AFD Classic-to-Standard Migration v5 (az CLI path - hardened)"
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
            Log "Profile already migrated -- running migration-commit" "WARN"
            try {
                if ($p.Type -eq "AFD") {
                    Invoke-Az -Args @("afd","profile","migration-commit","--profile-name",$p.Standard,"-g",$p.RG,"--only-show-errors")
                } else {
                    Invoke-Az -Args @("cdn","profile","migration-commit","--profile-name",$p.Classic,"-g",$p.RG,"--only-show-errors")
                }
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
        $newProfileResId = "/subscriptions/$SubscriptionId/resourceGroups/$($p.RG)/providers/Microsoft.Cdn/profiles/$($p.Standard)"
        try {
            Invoke-Az -Args @("cdn","migrate","--profile-name",$p.Classic,"-g",$p.RG,"--sku",$p.Sku,"--new-profile-name",$p.Standard,"--only-show-errors")
            Log "CDN Prepare succeeded" "OK"
        } catch {
            $r.Status = "prepare-failed"; $r.Error = $_.Exception.Message
            Log "CDN Prepare FAILED: $($_.Exception.Message)" "ERR"
            $results += $r
            continue
        }

        Log "Step 2 -- az cdn profile migration-commit"
        try {
            Invoke-Az -Args @("cdn","profile","migration-commit","--profile-name",$p.Classic,"-g",$p.RG,"--only-show-errors")
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

Banner "Final summary"
$ok = @($results | Where-Object { $_.Status -in @("migrated-and-committed","committed","already-done") })
$bad = @($results | Where-Object { $_.Status -notin @("migrated-and-committed","committed","already-done") })
Log "Succeeded: $($ok.Count) / $($results.Count)" "OK"
if ($bad.Count -gt 0) {
    Log "Failed:    $($bad.Count)" "ERR"
    foreach ($f in $bad) { Log "  $($f.Profile): $($f.Status) -- $($f.Error)" "ERR" }
}

$results | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $reportDir "results-v4-$stamp.json") -Encoding utf8
Log "Results JSON: $(Join-Path $reportDir "results-v4-$stamp.json")" "OK"
Log "Log:          $logPath" "OK"

Stop-Transcript | Out-Null
