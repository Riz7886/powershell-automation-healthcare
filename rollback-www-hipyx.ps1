[CmdletBinding()]
param(
    [string]$SubscriptionId   = "e42e94b5-c6f8-4af0-a41b-16fda520de6e",
    [string]$ResourceGroup    = "production",
    [string]$ClassicProfile   = "hipyx",
    [string]$Endpoint         = "www-hipyx-com",
    [string]$Hostname         = "www.hipyx.com",
    [string[]]$RulesToRestore = @("httpToHttpsRedirect", "defaultForwardingRule")
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

function Log {
    param([string]$Message, [string]$Color = "White")
    $stamp = (Get-Date).ToString("HH:mm:ss")
    Write-Host "[$stamp] $Message" -ForegroundColor $Color
}

Log "============================================================" Cyan
Log "ROLLBACK: www.hipyx.com -> Classic AFD hipyx" Cyan
Log "============================================================" Cyan

$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $acct) {
    Log "Not signed in - launching az login..." Yellow
    az login --only-show-errors | Out-Null
}
az account set --subscription $SubscriptionId --only-show-errors | Out-Null
Log "Subscription set: $SubscriptionId" Green

$ourId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/frontDoors/$ClassicProfile/frontendEndpoints/$Endpoint"

# ----------------------------------------------------------------------------
Log "" White
Log "STEP 1: Check / recreate frontend-endpoint $Endpoint" Cyan
# ----------------------------------------------------------------------------
$existing = az network front-door frontend-endpoint show -g $ResourceGroup --front-door-name $ClassicProfile --name $Endpoint --query id -o tsv 2>$null
if ($existing) {
    Log "  Frontend-endpoint already exists - skipping create" Green
} else {
    Log "  Creating frontend-endpoint..." White
    $createOut = az network front-door frontend-endpoint create `
        -g $ResourceGroup --front-door-name $ClassicProfile `
        --name $Endpoint --host-name $Hostname `
        --session-affinity-enabled-state Disabled 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errText = ($createOut | Out-String)
        if ($errText -match "Conflict|already exists|same host name") {
            Log "  Hostname is still locked at Azure's level - wait 5 min and retry this script" Red
            Log "  $errText" Yellow
            exit 1
        } else {
            Log "  Frontend-endpoint create failed:" Red
            Log "  $errText" Red
            exit 2
        }
    }
    Log "  Frontend-endpoint created" Green
}

# ----------------------------------------------------------------------------
foreach ($rule in $RulesToRestore) {
    Log "" White
    Log "STEP 2: Add $Endpoint reference back to routing rule '$rule'" Cyan
    # ----------------------------------------------------------------------------
    $currentRaw = az network front-door routing-rule show `
        -g $ResourceGroup --front-door-name $ClassicProfile `
        --name $rule --query "frontendEndpoints[].id" -o tsv 2>$null
    if (-not $currentRaw) {
        Log "  Could not read routing rule '$rule' - skipping" Yellow
        continue
    }
    $currentList = @($currentRaw -split "`r?`n" | Where-Object { $_ -and $_.Trim() })
    Log "  Current frontend-endpoints on '$rule': $($currentList.Count)" White
    foreach ($id in $currentList) { Log "    $id" White }

    $alreadyHas = $false
    foreach ($id in $currentList) { if ($id.ToLower() -eq $ourId.ToLower()) { $alreadyHas = $true; break } }

    if ($alreadyHas) {
        Log "  Rule '$rule' already references $Endpoint - skipping" Green
        continue
    }

    $newList = $currentList + $ourId
    Log "  Updating '$rule' with $($newList.Count) frontend-endpoints..." White
    az network front-door routing-rule update `
        -g $ResourceGroup --front-door-name $ClassicProfile `
        --name $rule --frontend-endpoints @newList --only-show-errors | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Log "  Rule '$rule' updated" Green
    } else {
        Log "  Rule '$rule' update returned non-zero exit code - check portal" Yellow
    }
}

# ----------------------------------------------------------------------------
Log "" White
Log "STEP 3: Enable HTTPS managed cert on $Endpoint" Cyan
# ----------------------------------------------------------------------------
$certState = az network front-door frontend-endpoint show `
    -g $ResourceGroup --front-door-name $ClassicProfile `
    --name $Endpoint --query customHttpsProvisioningState -o tsv 2>$null
Log "  Current HTTPS provisioning state: $certState" White

if ($certState -ne "Enabled" -and $certState -ne "Enabling") {
    az network front-door frontend-endpoint enable-https `
        -g $ResourceGroup --front-door-name $ClassicProfile --name $Endpoint --only-show-errors | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Log "  HTTPS enable requested - cert reissue takes 5-30 min" Green
    } else {
        Log "  HTTPS enable returned non-zero exit code - enable manually in portal" Yellow
    }
} else {
    Log "  HTTPS already in desired state" Green
}

# ----------------------------------------------------------------------------
Log "" White
Log "============================================================" Green
Log "ROLLBACK COMPLETE" Green
Log "============================================================" Green
Log "" White
Log "What happens next:" White
Log "  - HTTP traffic to www.hipyx.com should resume in 1-2 min" White
Log "  - HTTPS may show cert warnings until managed cert reissues (5-30 min)" Yellow
Log "  - DNS does NOT need to change - existing CNAME to hipyx.azurefd.net stays" White
Log "" White
Log "Verify with:" White
Log "  curl -I http://www.hipyx.com/" Cyan
Log "  curl -I https://www.hipyx.com/" Cyan
Log "" White
Log "Migration retry: schedule a real maintenance window with Skye on standby." White
