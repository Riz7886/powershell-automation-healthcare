[CmdletBinding()]
param(
    [string]$SubscriptionId   = "e42e94b5-c6f8-4af0-a41b-16fda520de6e",
    [string]$ResourceGroup    = "production",
    [string]$ClassicProfile   = "hipyx",
    [string]$StandardProfile  = "hipyx-std",
    [string]$Hostname         = "www.hipyx.com",
    [string]$ClassicEndpoint  = "www-hipyx-com",
    [string]$StandardEndpoint = "pyx-fx-www-hipyx-com-ep",
    [string]$CdName           = "www-hipyx-com",
    [string]$OriginHost       = "appsvc-pwa-prod.azurewebsites.net",
    [string]$WafPolicyName    = "hipyxWafPolicy",
    [int]   $StandardAttempts = 2,
    [int]   $StandardWaitSec  = 60,
    [switch]$ForceRollback,
    [string]$ReportDir        = (Join-Path $env:USERPROFILE "Desktop\hipyx-fix-report")
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
$logPath = Join-Path $ReportDir "fix-$timestamp.log"

function Log {
    param([string]$Message, [string]$Level = "INFO")
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line = "[$stamp] [$Level] $Message"
    Add-Content -Path $logPath -Value $line
    $color = switch ($Level) { "OK" {"Green"} "WARN" {"Yellow"} "ERR" {"Red"} "STEP" {"Cyan"} default {"White"} }
    Write-Host $line -ForegroundColor $color
}
function Banner($t) { Log ""; Log ("=" * 78); Log $t "STEP"; Log ("=" * 78) }

# ============================================================================
Banner "FIX www.hipyx.com - try Standard, else rollback to Classic"
# ============================================================================
Log "Subscription:        $SubscriptionId"
Log "Resource group:      $ResourceGroup"
Log "Classic profile:     $ClassicProfile"
Log "Standard profile:    $StandardProfile"
Log "Hostname:            $Hostname"
Log "Origin host:         $OriginHost"
Log "Force rollback:      $ForceRollback"

# Pre-flight
$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $acct) { Log "az login..." "WARN"; az login --only-show-errors | Out-Null }
az account set --subscription $SubscriptionId --only-show-errors | Out-Null
Log "Azure CLI signed in" "OK"

$ourClassicId  = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/frontDoors/$ClassicProfile/frontendEndpoints/$ClassicEndpoint"
$ourCdId       = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Cdn/profiles/$StandardProfile/customDomains/$CdName"
$ourWafId      = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/$WafPolicyName"

$standardSucceeded = $false

# ============================================================================
if (-not $ForceRollback) {
    Banner "PHASE A - Try Standard custom-domain create (forward path)"
# ============================================================================

    for ($attempt = 1; $attempt -le $StandardAttempts; $attempt++) {
        $cdExists = az afd custom-domain show -g $ResourceGroup --profile-name $StandardProfile --custom-domain-name $CdName --query id -o tsv 2>$null
        if ($cdExists) {
            Log "Custom-domain $CdName already exists on Standard" "OK"
            $standardSucceeded = $true
            break
        }

        Log "Creating custom-domain on Standard (attempt $attempt/$StandardAttempts)..."
        $cdOut = az afd custom-domain create `
            -g $ResourceGroup --profile-name $StandardProfile `
            --custom-domain-name $CdName --host-name $Hostname `
            --certificate-type ManagedCertificate --minimum-tls-version TLS12 `
            --only-show-errors 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log "Custom-domain created on Standard" "OK"
            $standardSucceeded = $true
            break
        }
        $errText = ($cdOut | Out-String)
        Log "Attempt $attempt failed: $errText" "WARN"
        if ($attempt -lt $StandardAttempts) {
            Log "Waiting $StandardWaitSec sec for Azure hostname lock to release..."
            Start-Sleep -Seconds $StandardWaitSec
        }
    }
}

# ============================================================================
if ($standardSucceeded) {
    Banner "PHASE A2 - Complete the migration on Standard"
# ============================================================================

    # Endpoint exists check
    $epExists = az afd endpoint show -g $ResourceGroup --profile-name $StandardProfile --endpoint-name $StandardEndpoint --query id -o tsv 2>$null
    if (-not $epExists) {
        Log "Creating Standard endpoint $StandardEndpoint..."
        az afd endpoint create -g $ResourceGroup --profile-name $StandardProfile --endpoint-name $StandardEndpoint --enabled-state Enabled --only-show-errors | Out-Null
    } else {
        Log "Standard endpoint already exists" "OK"
    }

    # Read CNAME target + TXT validation token
    Start-Sleep -Seconds 5
    $cname = az afd endpoint show -g $ResourceGroup --profile-name $StandardProfile --endpoint-name $StandardEndpoint --query hostName -o tsv 2>$null
    $txt   = az afd custom-domain show -g $ResourceGroup --profile-name $StandardProfile --custom-domain-name $CdName --query "validationProperties.validationToken" -o tsv 2>$null
    if (-not $txt) { Start-Sleep -Seconds 15; $txt = az afd custom-domain show -g $ResourceGroup --profile-name $StandardProfile --custom-domain-name $CdName --query "validationProperties.validationToken" -o tsv 2>$null }

    Log "Standard endpoint hostname (CNAME target): $cname" "OK"
    Log "Validation token (TXT value): $txt" "OK"

    # Origin group + origin
    $ogName = "og-www-hipyx-com"
    $ogExists = az afd origin-group show -g $ResourceGroup --profile-name $StandardProfile --origin-group-name $ogName --query id -o tsv 2>$null
    if (-not $ogExists) {
        Log "Creating origin group $ogName..."
        az afd origin-group create -g $ResourceGroup --profile-name $StandardProfile --origin-group-name $ogName --probe-request-type GET --probe-protocol Https --probe-interval-in-seconds 60 --probe-path "/" --sample-size 4 --successful-samples-required 3 --additional-latency-in-milliseconds 50 --only-show-errors | Out-Null
        az afd origin create -g $ResourceGroup --profile-name $StandardProfile --origin-group-name $ogName --origin-name "origin-www-hipyx-com" --host-name $OriginHost --origin-host-header $OriginHost --priority 1 --weight 1000 --enabled-state Enabled --http-port 80 --https-port 443 --only-show-errors | Out-Null
    } else {
        Log "Origin group $ogName already exists" "OK"
    }

    # Route
    $routeExists = az afd route show -g $ResourceGroup --profile-name $StandardProfile --endpoint-name $StandardEndpoint --route-name "default-route" --query id -o tsv 2>$null
    if (-not $routeExists) {
        Log "Creating route default-route..."
        az afd route create -g $ResourceGroup --profile-name $StandardProfile --endpoint-name $StandardEndpoint --route-name "default-route" --origin-group $ogName --custom-domains $ourCdId --supported-protocols Http Https --link-to-default-domain Disabled --forwarding-protocol MatchRequest --https-redirect Enabled --only-show-errors | Out-Null
    } else {
        Log "Route already exists" "OK"
    }

    # WAF
    $spName = "fx-www-hipyx-com-waf"
    $spExists = az afd security-policy show -g $ResourceGroup --profile-name $StandardProfile --security-policy-name $spName --query id -o tsv 2>$null
    if (-not $spExists) {
        Log "Binding WAF policy..."
        az afd security-policy create -g $ResourceGroup --profile-name $StandardProfile --security-policy-name $spName --waf-policy $ourWafId --domains $ourCdId --only-show-errors | Out-Null
    } else {
        Log "WAF policy already bound" "OK"
    }

    Banner "DNS RECORDS TO SEND TO SKYE"
    Log ""
    Log "  TXT  _dnsauth.www  ->  $txt   (TTL 300, publish FIRST)"
    Log "  CNAME  www  ->  $cname   (TTL 300, publish AFTER cert state = Approved)"
    Log ""
    Log "Watch cert state with:"
    Log "  az afd custom-domain show -g $ResourceGroup --profile-name $StandardProfile --custom-domain-name $CdName --query domainValidationState -o tsv"
    Log ""
    Log "MIGRATION COMPLETE ON AZURE SIDE - email Skye these two records." "OK"
    Log "Log saved: $logPath" "OK"
    exit 0
}

# ============================================================================
Banner "PHASE B - Rollback to Classic"
# ============================================================================

# B1: Recreate frontend-endpoint
$existingFE = az network front-door frontend-endpoint show -g $ResourceGroup --front-door-name $ClassicProfile --name $ClassicEndpoint --query id -o tsv 2>$null
if ($existingFE) {
    Log "Classic frontend-endpoint $ClassicEndpoint already exists" "OK"
} else {
    Log "Recreating Classic frontend-endpoint $ClassicEndpoint..."
    $createOut = az network front-door frontend-endpoint create `
        -g $ResourceGroup --front-door-name $ClassicProfile `
        --name $ClassicEndpoint --host-name $Hostname `
        --session-affinity-enabled-state Disabled 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errText = ($createOut | Out-String)
        if ($errText -match "Conflict|already exists|same host name") {
            Log "Hostname is still locked at Azure level - wait 5 min and re-run" "ERR"
            Log "$errText" "WARN"
            exit 1
        } else {
            Log "Frontend-endpoint create failed: $errText" "ERR"
            exit 2
        }
    }
    Log "Classic frontend-endpoint created" "OK"
}

# B2/B3: Re-add to both routing rules
foreach ($rule in @("httpToHttpsRedirect", "defaultForwardingRule")) {
    Log "Re-attaching $ClassicEndpoint to routing rule '$rule'..."
    $currentRaw = az network front-door routing-rule show -g $ResourceGroup --front-door-name $ClassicProfile --name $rule --query "frontendEndpoints[].id" -o tsv 2>$null
    if (-not $currentRaw) {
        Log "  Could not read rule '$rule' - skipping" "WARN"
        continue
    }
    $currentList = @($currentRaw -split "`r?`n" | Where-Object { $_ -and $_.Trim() })
    Log "  Current refs ($($currentList.Count)):"
    foreach ($id in $currentList) { Log "    $id" }

    $alreadyHas = $false
    foreach ($id in $currentList) { if ($id.ToLower() -eq $ourClassicId.ToLower()) { $alreadyHas = $true; break } }
    if ($alreadyHas) {
        Log "  Already references $ClassicEndpoint - skip" "OK"
        continue
    }

    $newList = $currentList + $ourClassicId
    az network front-door routing-rule update -g $ResourceGroup --front-door-name $ClassicProfile --name $rule --frontend-endpoints @newList --only-show-errors | Out-Null
    if ($LASTEXITCODE -eq 0) { Log "  Rule '$rule' updated ($($newList.Count) refs now)" "OK" }
    else { Log "  Rule '$rule' update returned non-zero - check portal" "WARN" }
}

# B4: Enable HTTPS managed cert
$certState = az network front-door frontend-endpoint show -g $ResourceGroup --front-door-name $ClassicProfile --name $ClassicEndpoint --query customHttpsProvisioningState -o tsv 2>$null
Log "Current cert state on Classic: $certState"
if ($certState -ne "Enabled" -and $certState -ne "Enabling") {
    Log "Enabling HTTPS managed cert (cert reissue takes 5-30 min)..."
    az network front-door frontend-endpoint enable-https -g $ResourceGroup --front-door-name $ClassicProfile --name $ClassicEndpoint --only-show-errors | Out-Null
    if ($LASTEXITCODE -eq 0) { Log "HTTPS enable requested" "OK" }
    else { Log "HTTPS enable returned non-zero - enable in portal" "WARN" }
} else {
    Log "HTTPS already enabled / enabling" "OK"
}

Banner "ROLLBACK COMPLETE"
Log ""
Log "What happens next:"
Log "  - HTTP traffic to www.hipyx.com resumes within 1-2 min"
Log "  - HTTPS resumes once managed cert reissues (5-30 min, runs in background)"
Log "  - DNS does NOT need to change - existing CNAME to hipyx.azurefd.net is still correct"
Log ""
Log "Verify:"
Log "  curl -I http://www.hipyx.com/"
Log "  curl -I https://www.hipyx.com/   (may show cert warning until reissue completes)"
Log ""
Log "Log saved: $logPath"
Log ""
Log "Slack Tony: 'Rolled back to Classic. www.hipyx.com restoring. Will reschedule migration for a maintenance window with Skye on standby.'" "OK"
exit 0
