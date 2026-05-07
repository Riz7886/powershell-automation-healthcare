[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Log($msg, $level = "INFO") {
    $ts = (Get-Date).ToString("HH:mm:ss")
    $prefix = switch ($level) { "OK" { "[OK]" } "ERR" { "[ERR]" } "WARN" { "[WARN]" } default { "[INFO]" } }
    Write-Host "[$ts] $prefix $msg"
}

$pinnedVersions = @{ "Az.Cdn" = "6.0.1" }
$requiredModules = @("Az.Accounts","Az.Cdn","Az.Resources")
foreach ($m in $requiredModules) {
    $pinVer = $pinnedVersions[$m]
    if ($pinVer) {
        $existing = Get-Module -ListAvailable -Name $m -ErrorAction SilentlyContinue | Where-Object { $_.Version -eq $pinVer }
        if (-not $existing) {
            Log "Installing $m v$pinVer (pinned)..."
            Install-Module -Name $m -RequiredVersion $pinVer -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        }
        Remove-Module $m -Force -ErrorAction SilentlyContinue
        Import-Module $m -RequiredVersion $pinVer -Force -ErrorAction Stop
    } else {
        if (-not (Get-Module -ListAvailable -Name $m -ErrorAction SilentlyContinue)) {
            Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        }
        Import-Module $m -ErrorAction Stop
    }
    $ver = (Get-Module -Name $m).Version
    Log "$m loaded (v$ver)" "OK"
}

$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    Log "Connecting to Azure..."
    Connect-AzAccount -ErrorAction Stop | Out-Null
}

$subId = "e42e94b5-c6f8-4af0-a41b-16fda520de6e"
Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
Log "Subscription: sub-corp-prod-001"

$profiles = @(
    @{ Classic = "standard"; Standard = "standard-afdstd"; RG = "Test"; Type = "CDN" }
    @{ Classic = "pyxiq";    Standard = "pyxiq-std";       RG = "Production"; Type = "AFD" }
    @{ Classic = "hipyx";    Standard = "hipyx-std-v2";    RG = "production"; Type = "AFD" }
    @{ Classic = "pyxiq-stage"; Standard = "pyxiq-stage-std"; RG = "Stage"; Type = "AFD" }
    @{ Classic = "pyxpwa-stage"; Standard = "pyxpwa-stage-std"; RG = "Stage"; Type = "AFD" }
)

Log ""
Log "=========================================="
Log "  PYX AFD/CDN Migration Status Check"
Log "=========================================="
Log ""

foreach ($p in $profiles) {
    Log "--- $($p.Classic) ($($p.Type)) in RG $($p.RG) ---"

    $classicExists = $false
    if ($p.Type -eq "AFD") {
        try {
            $fd = Get-AzFrontDoor -ResourceGroupName $p.RG -Name $p.Classic -ErrorAction Stop
            if ($fd) { $classicExists = $true; Log "  Classic profile EXISTS -- still active" "OK" }
        } catch { Log "  Classic profile NOT FOUND (may have been migrated or deleted)" "WARN" }
    } else {
        try {
            $cdn = Get-AzCdnProfile -ResourceGroupName $p.RG -ProfileName $p.Classic -ErrorAction Stop
            if ($cdn) {
                $classicExists = $true
                Log "  Classic CDN profile EXISTS (SKU: $($cdn.SkuName))" "OK"
                if ($cdn.SkuName -in @("Standard_AzureFrontDoor","Premium_AzureFrontDoor")) {
                    Log "  NOTE: Profile already shows AFD SKU -- migration may have completed" "WARN"
                }
            }
        } catch { Log "  Classic CDN profile NOT FOUND" "WARN" }
    }

    $newExists = $false
    try {
        $newProfile = Get-AzFrontDoorCdnProfile -ResourceGroupName $p.RG -ProfileName $p.Standard -ErrorAction Stop
        if ($newProfile) {
            $newExists = $true
            Log "  New Standard profile '$($p.Standard)' EXISTS (SKU: $($newProfile.SkuName))" "WARN"
            Log "  This means Prepare was started -- profile is in migration state"
        }
    } catch {
        Log "  New Standard profile '$($p.Standard)' does NOT exist -- Prepare was NOT started or already rolled back" "OK"
    }

    if ($newExists -and -not $Force) {
        Log "  To ROLLBACK this profile, re-run with: -Force" "WARN"
        Log "  Rollback command: Stop-AzFrontDoorCdnProfileMigration -ProfileName '$($p.Standard)' -ResourceGroupName '$($p.RG)'" "INFO"
    }

    if ($newExists -and $Force) {
        Log "  ROLLING BACK: Stop-AzFrontDoorCdnProfileMigration..."
        try {
            Stop-AzFrontDoorCdnProfileMigration -ProfileName $p.Standard -ResourceGroupName $p.RG -ErrorAction Stop
            Log "  Rollback SUCCEEDED -- Classic profile remains active" "OK"
        } catch {
            Log "  Rollback FAILED: $($_.Exception.Message)" "ERR"
            Log "  Manual cleanup may be needed in Azure Portal" "ERR"
        }
    }
    Log ""
}

Log "=========================================="
Log "  Status check complete"
Log "=========================================="
Log ""
Log "SAFE states:"
Log "  - Classic EXISTS + New does NOT exist = untouched, safe to re-run migration"
Log "  - Classic EXISTS + New EXISTS = prepared but not committed, can ROLLBACK or COMMIT"
Log ""
Log "To rollback all prepared profiles: .\PYX-AFD-Rollback-Standard.ps1 -Force"
Log "To retry migration after fix:     .\PYX-AFD-Migrate-v2.ps1"
