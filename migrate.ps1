# =============================================================================
#  PYX Health - FX Survey Portal Migration  (native PowerShell - no bash needed)
#
#  Same capability as migrate.sh but written in pure PowerShell so it runs on
#  any Windows PYX laptop with just Azure CLI installed. No Git-for-Windows,
#  no WSL, no bash required.
#
#  Usage:
#     .\migrate.ps1 -DryRun                       # preview only, no changes
#     .\migrate.ps1 -DryRun -HtmlReport           # preview + HTML change plan
#     .\migrate.ps1                               # real migration (prompts y/N)
#     .\migrate.ps1 -Yes                          # real migration, no prompts
# =============================================================================
param(
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Show,
    [string]$Subscription,
    [string]$Classic              = "hipyx",
    [string]$NewName              = "hipyx-std",
    [string]$Sku                  = "Standard_AzureFrontDoor",
    [string]$Domain               = "survey.farmboxrx.com",
    [string]$Origin               = "mycareloop.z22.web.core.windows.net",
    [string]$OriginGroupName      = "fx-survey-origin-group",
    [string]$OriginName           = "fx-survey-origin",
    [string]$RouteName            = "fx-survey-route",
    [string]$WafPolicyName        = "hipyxWafPolicy",
    [switch]$HtmlReport,
    [string]$HtmlReportPath       = ""
)

$ErrorActionPreference = "Stop"

# Defensive: catch common mistype where user passes "Yes" as a positional
# arg instead of -Yes as a switch. Without this, "Yes" binds to $Subscription
# and the script later dies with a cryptic "subscription 'yes' doesn't exist"
# error from Azure CLI. This check protects against that.
$_boolWords = @('yes','y','no','n','true','false','t','f','confirm','ok','dryrun','htmlreport')
if ($Subscription -and ($Subscription.Trim().ToLower() -in $_boolWords)) {
    Write-Host ""
    Write-Host "  xx  It looks like you passed '$Subscription' as a positional arg." -ForegroundColor Red
    Write-Host "      That got bound to -Subscription, which expects an Azure sub ID." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Did you mean to skip confirmation prompts?" -ForegroundColor Yellow
    Write-Host "      .\migrate.ps1 -DryRun -HtmlReport -Yes       (WITH the dash in -Yes)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Or to force a specific subscription?" -ForegroundColor Yellow
    Write-Host "      .\migrate.ps1 -Subscription <sub-id-or-name>" -ForegroundColor Green
    Write-Host ""
    exit 1
}

# If HtmlReport is set, imply DryRun (plan only, don't execute)
if ($HtmlReport -and -not $DryRun) { $DryRun = $true }
if ($HtmlReport -and -not $HtmlReportPath) {
    $HtmlReportPath = ".\pyx-fx-migration-plan-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
}

$DomainSafe = $Domain -replace '\.','-'
$Script:PlannedCommands = New-Object System.Collections.ArrayList

function Say  ($m) { Write-Host "`n[step] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "  ok  $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  !!  $m" -ForegroundColor Yellow }
function Die  ($m) {
    Write-Host "  xx  $m" -ForegroundColor Red
    Write-Host ""
    Write-Host "  RESUMING SAFELY:" -ForegroundColor Yellow
    Write-Host "    The script halts mid-way. To continue after fixing the root cause," -ForegroundColor Yellow
    Write-Host "    simply re-run this exact same command. Already-created resources will" -ForegroundColor Yellow
    Write-Host "    be detected and skipped (idempotent)." -ForegroundColor Yellow
    exit 1
}

# Track what succeeded vs skipped — for end-of-run summary
$Script:Completed  = New-Object System.Collections.ArrayList
$Script:Skipped    = New-Object System.Collections.ArrayList
$Script:Warnings   = New-Object System.Collections.ArrayList

function Mark-Done($what)    { [void]$Script:Completed.Add($what) }
function Mark-Skipped($what) { [void]$Script:Skipped.Add($what) }

function Confirm-Action($prompt) {
    if ($Yes) { return $true }
    $ans = Read-Host "  ?? $prompt [y/N or yes]"
    if ($null -eq $ans) { return $false }
    $clean = $ans.ToString().Trim().ToLower()
    # Accept anything that starts with 'y' — y, Y, yes, Yes, YES, yeah, yep, etc.
    return $clean.StartsWith('y')
}

# Idempotency whitelist — these exit-code patterns mean "already exists, safe to continue"
$Script:IdempotentPatterns = @(
    'already exists',
    'ResourceAlreadyExists',
    'AlreadyExistsError',
    'Code: Conflict',
    'The resource already exists',
    'is already associated',
    'AssociationAlreadyExists',
    'already attached',
    'is already in use'
)

function Invoke-Az {
    # Uses $args (automatic) so PowerShell doesn't try to bind named params
    # like -o / --resource-group to this function's cmdlet-common parameters.
    $cmdText = "az " + ($args -join " ")
    if ($Show -or $DryRun) { Write-Host "  `$ $cmdText" -ForegroundColor Magenta }
    if ($HtmlReport) { [void]$Script:PlannedCommands.Add($cmdText) }
    if ($DryRun) { return "" }

    # Capture BOTH stdout and stderr so we can inspect error messages
    $output = & az @args 2>&1
    $exit   = $LASTEXITCODE

    if ($exit -eq 0) {
        return $output
    }

    # Non-zero exit — is it an idempotency-safe "already exists" error?
    $errText = ($output | Out-String)
    $isBenign = $false
    foreach ($pat in $Script:IdempotentPatterns) {
        if ($errText -match [regex]::Escape($pat)) { $isBenign = $true; break }
    }

    if ($isBenign) {
        Warn "Already exists, skipping (idempotent): $cmdText"
        [void]$Script:Warnings.Add("IDEMPOTENT SKIP: $cmdText")
        return $output
    }

    # Real failure — halt loudly with full context
    Write-Host ""
    Write-Host "  xx  az FAILED (exit $exit)" -ForegroundColor Red
    Write-Host "      command : $cmdText" -ForegroundColor Red
    Write-Host "      --- azure cli output ---" -ForegroundColor Red
    $errText.TrimEnd() -split "`n" | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    Write-Host "      -------------------------" -ForegroundColor Red
    Die "Azure CLI command above failed. Fix the root cause, then re-run this script — idempotent resources will be skipped on retry."
}

function Test-AzResource {
    # Returns $true if an AFD / CDN / WAF resource exists. Used for idempotency
    # guards so we can pre-check before a create and skip if already present.
    param([string]$Type, [string]$Name, [string]$ResourceGroup, [string]$Parent)
    if ($DryRun) { return $false }
    try {
        switch ($Type) {
            "afd-profile" {
                $r = az afd profile show --profile-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null
                return -not [string]::IsNullOrEmpty($r)
            }
            "afd-origin-group" {
                $r = az afd origin-group show --profile-name $Parent --origin-group-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null
                return -not [string]::IsNullOrEmpty($r)
            }
            "afd-origin" {
                $r = az afd origin show --profile-name $Parent --origin-group-name $OriginGroupName --origin-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null
                return -not [string]::IsNullOrEmpty($r)
            }
            "afd-endpoint" {
                $r = az afd endpoint show --profile-name $Parent --endpoint-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null
                return -not [string]::IsNullOrEmpty($r)
            }
            "afd-route" {
                $r = az afd route show --profile-name $Parent --endpoint-name $endpointName --route-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null
                return -not [string]::IsNullOrEmpty($r)
            }
            "afd-custom-domain" {
                $r = az afd custom-domain show --profile-name $Parent --custom-domain-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null
                return -not [string]::IsNullOrEmpty($r)
            }
            "waf-policy" {
                $r = az network front-door waf-policy show --resource-group $ResourceGroup --name $Name -o tsv --query id --only-show-errors 2>$null
                return -not [string]::IsNullOrEmpty($r)
            }
            "afd-security-policy" {
                $r = az afd security-policy show --profile-name $Parent --security-policy-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null
                return -not [string]::IsNullOrEmpty($r)
            }
            default { return $false }
        }
    } catch { return $false }
}

# ---- Phase 0: preflight -----------------------------------------------------
Say "[0/7] Preflight checks"
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Die "Azure CLI (az) not installed. https://aka.ms/installazurecliwindows"
}

$acct = $null
try { $acct = az account show --only-show-errors 2>$null | ConvertFrom-Json } catch { $acct = $null }
if (-not $acct) { Die "Not logged into Azure. Run 'az login' first." }
Ok "az CLI logged in. Active: $($acct.name)  ($($acct.id))"

# Ensure legacy front-door extension is installed (classic discovery needs it)
$extJson = az extension list --only-show-errors 2>$null | ConvertFrom-Json
$hasExt = $false
if ($extJson) { $hasExt = @($extJson | Where-Object { $_.name -eq "front-door" }).Count -gt 0 }
if (-not $hasExt) {
    Warn "Installing az extension 'front-door' (needed for classic FD discovery)"
    az extension add --name front-door --only-show-errors --yes | Out-Null
}

# ---- Phase 1: discovery -----------------------------------------------------
Say "[1/7] Scanning every accessible subscription for classic profile '$Classic'"

if ($Subscription) {
    az account set --subscription $Subscription --only-show-errors | Out-Null
    $subs = @([pscustomobject]@{id=$Subscription;name=(az account show --query name -o tsv)})
    Ok "Using forced subscription: $Subscription"
} else {
    $raw  = az account list --query "[?state=='Enabled'].{id:id, name:name}" -o json --only-show-errors
    $subs = $raw | ConvertFrom-Json
}

if (-not $subs -or $subs.Count -eq 0) { Die "No enabled subscriptions found. Did you 'az login' to the right tenant?" }
Ok ("Scanning {0} subscription(s)..." -f $subs.Count)

$found = $null
$matches = 0
foreach ($s in $subs) {
    Write-Host ("      .. {0}   ({1})" -f $s.name, $s.id)
    try { az account set --subscription $s.id --only-show-errors | Out-Null } catch { continue }

    $hit = ""
    try {
        $hit = az network front-door list --query "[?name=='$Classic'] | [0].id" -o tsv --only-show-errors 2>$null
    } catch { $hit = "" }
    if (-not $hit) {
        try {
            $hit = az resource list --name $Classic --resource-type "Microsoft.Network/frontDoors" --query "[0].id" -o tsv --only-show-errors 2>$null
        } catch { $hit = "" }
    }
    if ($hit -and $hit.StartsWith("/subscriptions/")) {
        $matches++
        $rg = $hit.Split("/")[4]
        $found = [pscustomobject]@{
            SubscriptionId   = $s.id
            SubscriptionName = $s.name
            ResourceId       = $hit
            ResourceGroup    = $rg
        }
        Write-Host ("      MATCH  {0}   rg={1}" -f $s.name, $rg) -ForegroundColor Green
    }
}

if ($matches -eq 0) { Die "Classic Front Door '$Classic' not found in any subscription. Check the name, or specify -Subscription <id>." }
if ($matches -gt 1) { Die "Profile '$Classic' found in MULTIPLE subscriptions. Re-run with -Subscription <id> to pick one." }

Ok ("Located {0}:" -f $Classic)
Ok "  subscription: $($found.SubscriptionName) ($($found.SubscriptionId))"
Ok "  resource grp: $($found.ResourceGroup)"
Ok "  resource id : $($found.ResourceId)"
az account set --subscription $found.SubscriptionId --only-show-errors | Out-Null

# ---- Phase 2: plan ----------------------------------------------------------
Say "[2/7] Plan summary"
Write-Host @"
   ACTIONS:
     1. Preview classic->Standard migration
     2. COMMIT migration: $Classic -> $NewName ($Sku)
     3. Create origin group + origin -> $Origin
     4. Create route '$RouteName'
     5. Add custom domain '$Domain' (Azure-managed cert)
     6. Attach WAF '$WafPolicyName' (OWASP detection)
     7. Print DNS records Robert needs at farmboxrx.com

   subscription : $($found.SubscriptionName)
   resource grp : $($found.ResourceGroup)
"@
if ($DryRun) { Warn "DRY-RUN mode: no mutations will be made." }
if (-not (Confirm-Action "Proceed with this plan?")) { Die "Aborted by user." }

# ---- Phase 3: show classic profile (read-only) ------------------------------
Say "[3/7] Show classic profile (read-only)"
Invoke-Az network front-door show `
    --name $Classic `
    --resource-group $found.ResourceGroup `
    --query "{name:name, resourceState:resourceState, enabledState:enabledState, frontendEndpoints:frontendEndpoints[].hostName}" `
    -o json --only-show-errors

# ---- Phase 4: migrate + commit ----------------------------------------------
Say "[4/7] COMMITTING migration (this is the real change)"

if (Test-AzResource -Type "afd-profile" -Name $NewName -ResourceGroup $found.ResourceGroup) {
    Ok "Standard profile '$NewName' already exists - checking migration state..."
    $migState = ""
    try {
        $migState = az afd profile show --profile-name $NewName --resource-group $found.ResourceGroup --query "extendedProperties.migrationState" -o tsv --only-show-errors 2>$null
    } catch { $migState = "" }
    if ($migState -and $migState -ne "Committed") {
        Ok "Migration state: $migState - needs commit."
        if (-not (Confirm-Action "Commit migration now? (this retires classic)")) { Die "Aborted before commit." }
        Invoke-Az afd profile migration-commit `
            --profile-name $NewName `
            --resource-group $found.ResourceGroup
        Mark-Done "Migration committed"
    } else {
        Ok "Migration already committed in prior run. Skipping."
        Mark-Skipped "Migrate + commit (already done)"
    }
} else {
    if (-not (Confirm-Action "Start migration (creates Standard profile, classic still serves traffic)?")) { Die "Aborted before migrate." }
    Invoke-Az afd profile migrate `
        --profile-name $NewName `
        --resource-group $found.ResourceGroup `
        --classic-resource-id $found.ResourceId `
        --sku $Sku
    Mark-Done "Migrated (Standard profile in Migrating state)"
    Ok "Standard profile '$NewName' created. Classic '$Classic' still serving traffic."

    if (-not (Confirm-Action "Commit migration now? (this retires classic)")) { Die "Aborted before commit." }
    Invoke-Az afd profile migration-commit `
        --profile-name $NewName `
        --resource-group $found.ResourceGroup
    Mark-Done "Migration committed"
}
Ok "Migration committed."

# Phase-gate: verify the Standard profile now exists before moving to Phase 5.
# If this fails, Phase 5 would create orphan resources under a non-existent profile.
if (-not $DryRun) {
    if (-not (Test-AzResource -Type "afd-profile" -Name $NewName -ResourceGroup $found.ResourceGroup)) {
        Die "Post-migrate verification FAILED. Standard profile '$NewName' was not found in rg '$($found.ResourceGroup)'. Cannot proceed to Phase 5. Check Azure portal for error details on the migration operation."
    }
    Ok "Phase-gate PASSED: Standard profile '$NewName' verified in Azure."
}

# ---- Phase 5: origin + route ------------------------------------------------
Say "[5/7] Origin group + origin + route"

if (Test-AzResource -Type "afd-origin-group" -Name $OriginGroupName -ResourceGroup $found.ResourceGroup -Parent $NewName) {
    Ok "Origin group '$OriginGroupName' already exists — skipping."
    Mark-Skipped "Origin group create"
} else {
    Invoke-Az afd origin-group create `
        --profile-name $NewName `
        --resource-group $found.ResourceGroup `
        --origin-group-name $OriginGroupName `
        --probe-path "/" --probe-protocol Https `
        --probe-request-type GET --probe-interval-in-seconds 60 `
        --sample-size 4 --successful-samples-required 3 `
        --additional-latency-in-milliseconds 50
    Mark-Done "Origin group created"
}

if (Test-AzResource -Type "afd-origin" -Name $OriginName -ResourceGroup $found.ResourceGroup -Parent $NewName) {
    Ok "Origin '$OriginName' already exists — skipping."
    Mark-Skipped "Origin create"
} else {
    Invoke-Az afd origin create `
        --profile-name $NewName `
        --resource-group $found.ResourceGroup `
        --origin-group-name $OriginGroupName `
        --origin-name $OriginName `
        --host-name $Origin `
        --origin-host-header $Origin `
        --http-port 80 --https-port 443 `
        --priority 1 --weight 1000 `
        --enabled-state Enabled
    Mark-Done "Origin created"
}

# Find or create endpoint
$endpointName = ""
if (-not $DryRun) {
    try {
        $endpointName = az afd endpoint list --profile-name $NewName --resource-group $found.ResourceGroup --query "[0].name" -o tsv --only-show-errors 2>$null
    } catch { $endpointName = "" }
}
if (-not $endpointName) {
    $endpointName = "hipyx-endpoint"
    if (Test-AzResource -Type "afd-endpoint" -Name $endpointName -ResourceGroup $found.ResourceGroup -Parent $NewName) {
        Ok "Endpoint '$endpointName' already exists — skipping."
        Mark-Skipped "Endpoint create"
    } else {
        Invoke-Az afd endpoint create `
            --profile-name $NewName `
            --resource-group $found.ResourceGroup `
            --endpoint-name $endpointName `
            --enabled-state Enabled
        Mark-Done "Endpoint created"
    }
}
Ok "Using endpoint: $endpointName"

if (Test-AzResource -Type "afd-route" -Name $RouteName -ResourceGroup $found.ResourceGroup -Parent $NewName) {
    Ok "Route '$RouteName' already exists — skipping create (will update with custom domain in Phase 6)."
    Mark-Skipped "Route create"
} else {
    Invoke-Az afd route create `
        --profile-name $NewName `
        --resource-group $found.ResourceGroup `
        --endpoint-name $endpointName `
        --route-name $RouteName `
        --origin-group $OriginGroupName `
        --supported-protocols Https `
        --forwarding-protocol HttpsOnly `
        --link-to-default-domain Disabled `
        --https-redirect Enabled `
        --patterns-to-match "/*"
    Mark-Done "Route created"
}

# ---- Phase 6: custom domain + cert + WAF ------------------------------------
Say "[6/7] Custom domain + managed cert + WAF"

if (Test-AzResource -Type "afd-custom-domain" -Name $DomainSafe -ResourceGroup $found.ResourceGroup -Parent $NewName) {
    Ok "Custom domain '$DomainSafe' already exists — skipping create."
    Mark-Skipped "Custom domain create"
} else {
    Invoke-Az afd custom-domain create `
        --profile-name $NewName `
        --resource-group $found.ResourceGroup `
        --custom-domain-name $DomainSafe `
        --host-name $Domain `
        --minimum-tls-version TLS12 `
        --certificate-type ManagedCertificate
    Mark-Done "Custom domain created"
}

# Route update is idempotent by nature (update vs create), always run.
Invoke-Az afd route update `
    --profile-name $NewName `
    --resource-group $found.ResourceGroup `
    --endpoint-name $endpointName `
    --route-name $RouteName `
    --custom-domains $DomainSafe
Mark-Done "Route attached to custom domain"

if (Test-AzResource -Type "waf-policy" -Name $WafPolicyName -ResourceGroup $found.ResourceGroup) {
    Ok "WAF policy '$WafPolicyName' already exists — skipping create."
    Mark-Skipped "WAF policy create"
} else {
    Invoke-Az network front-door waf-policy create `
        --resource-group $found.ResourceGroup `
        --name $WafPolicyName `
        --mode Detection `
        --sku $Sku
    Mark-Done "WAF policy created"
}

# managed-rules add is idempotent — it upserts the rule set version.
Invoke-Az network front-door waf-policy managed-rules add `
    --resource-group $found.ResourceGroup `
    --policy-name $WafPolicyName `
    --type Microsoft_DefaultRuleSet `
    --version 2.1
Mark-Done "WAF default rule-set attached"

$wafResId = "/subscriptions/$($found.SubscriptionId)/resourceGroups/$($found.ResourceGroup)/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/$WafPolicyName"
$domResId = "/subscriptions/$($found.SubscriptionId)/resourceGroups/$($found.ResourceGroup)/providers/Microsoft.Cdn/profiles/$NewName/customDomains/$DomainSafe"

if (Test-AzResource -Type "afd-security-policy" -Name "fx-survey-waf" -ResourceGroup $found.ResourceGroup -Parent $NewName) {
    Ok "Security policy 'fx-survey-waf' already exists — skipping."
    Mark-Skipped "Security policy create"
} else {
    Invoke-Az afd security-policy create `
        --profile-name $NewName `
        --resource-group $found.ResourceGroup `
        --security-policy-name "fx-survey-waf" `
        --waf-policy $wafResId `
        --domains $domResId
    Mark-Done "Security policy created (WAF attached to custom domain)"
}

Ok "Custom domain + managed cert + WAF in place."

# ---- Phase 7: DNS handoff ---------------------------------------------------
Say "[7/7] DNS records Robert needs at farmboxrx.com"
if ($DryRun) {
    $cnameTarget     = "<endpoint>.azurefd.net"
    $validationToken = "<issued-after-real-run>"
} else {
    try {
        $cnameTarget     = az afd endpoint show --profile-name $NewName --resource-group $found.ResourceGroup --endpoint-name $endpointName --query hostName -o tsv --only-show-errors 2>$null
        $validationToken = az afd custom-domain show --profile-name $NewName --resource-group $found.ResourceGroup --custom-domain-name $DomainSafe --query "validationProperties.validationToken" -o tsv --only-show-errors 2>$null
    } catch {
        $cnameTarget = "<unknown>"; $validationToken = "<unknown>"
    }
}

Write-Host ""
Write-Host "   ======================================================================" -ForegroundColor Green
Write-Host "   DNS records at farmboxrx.com (send to Robert / Natalie)" -ForegroundColor Green
Write-Host "   ======================================================================" -ForegroundColor Green
Write-Host "   STEP 1 (add FIRST, wait for cert approval ~20-60 min):" -ForegroundColor Cyan
Write-Host "      TYPE : TXT"
Write-Host "      NAME : _dnsauth.survey"
Write-Host "      VALUE: $validationToken"
Write-Host "      TTL  : 300"
Write-Host ""
Write-Host "   STEP 2 (add AFTER Azure managed cert = Approved):" -ForegroundColor Cyan
Write-Host "      TYPE : CNAME"
Write-Host "      NAME : survey"
Write-Host "      VALUE: $cnameTarget"
Write-Host "      TTL  : 300"
Write-Host ""
Write-Host "   WARNING: Flipping CNAME BEFORE cert is Approved = SSL error window" -ForegroundColor Yellow
Write-Host "   Check cert status:" -ForegroundColor Yellow
Write-Host "     az afd custom-domain show --profile-name $NewName \\" -ForegroundColor Yellow
Write-Host "       --resource-group $($found.ResourceGroup) --custom-domain-name $DomainSafe \\" -ForegroundColor Yellow
Write-Host "       --query domainValidationState -o tsv" -ForegroundColor Yellow
Write-Host "   Wait until it returns: Approved" -ForegroundColor Yellow
Write-Host "   ======================================================================" -ForegroundColor Green
Write-Host ""

# ---- Run summary ------------------------------------------------------------
Write-Host ""
Write-Host "   ======================================================================" -ForegroundColor Green
Write-Host "    RUN SUMMARY" -ForegroundColor Green
Write-Host "   ======================================================================" -ForegroundColor Green
Write-Host "   Classic profile   : $Classic  (rg $($found.ResourceGroup))" -ForegroundColor White
Write-Host "   Standard profile  : $NewName  ($Sku)" -ForegroundColor White
Write-Host "   Endpoint          : $endpointName" -ForegroundColor White
Write-Host "   Custom domain     : $Domain  (TLS 1.2, Azure-managed cert)" -ForegroundColor White
Write-Host "   WAF policy        : $WafPolicyName  (Detection, OWASP 2.1)" -ForegroundColor White
Write-Host ""
Write-Host "   COMPLETED ($($Script:Completed.Count)):" -ForegroundColor Green
foreach ($item in $Script:Completed) { Write-Host "     [done]   $item" -ForegroundColor Green }
if ($Script:Skipped.Count -gt 0) {
    Write-Host ""
    Write-Host "   SKIPPED (idempotent — already existed from prior run) ($($Script:Skipped.Count)):" -ForegroundColor Yellow
    foreach ($item in $Script:Skipped) { Write-Host "     [skip]   $item" -ForegroundColor Yellow }
}
if ($Script:Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "   WARNINGS ($($Script:Warnings.Count)):" -ForegroundColor Yellow
    foreach ($w in $Script:Warnings) { Write-Host "     [warn]   $w" -ForegroundColor Yellow }
}
Write-Host ""
Write-Host "   NEXT STEPS:" -ForegroundColor Cyan
Write-Host "     1. Send Robert the TWO DNS records above (TXT first, CNAME after cert approval)"
Write-Host "     2. Poll cert status every 10 min until state = Approved"
Write-Host "     3. Once Approved, tell Robert to flip the CNAME"
Write-Host "     4. Monitor https://$Domain for 24h, then change WAF mode Detection -> Prevention"
Write-Host "     5. If anything breaks, roll back with: .\fx-survey-rollback.ps1 -Yes"
Write-Host "   ======================================================================" -ForegroundColor Green

Ok "All done."

# ---- Optional: HTML change-plan report --------------------------------------
if ($HtmlReport) {
    Say "Writing HTML change plan: $HtmlReportPath"
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
    $cmdsHtml = ""
    foreach ($c in $Script:PlannedCommands) {
        $escaped = [System.Web.HttpUtility]::HtmlEncode($c) 2>$null
        if (-not $escaped) { $escaped = $c -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
        $cmdsHtml += "    <div class=`"cmd`"><code>$escaped</code></div>`n"
    }
    $html = @"
<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><title>PYX FX Survey Migration - Change Plan</title>
<style>
 body { font-family: -apple-system, Segoe UI, Roboto, Arial, sans-serif; background:#f7f9fc; color:#1f2d3d; margin:0; padding:0; font-size:14px; line-height:1.55; }
 .wrap { max-width:1040px; margin:0 auto; padding:32px 28px 60px; }
 h1 { font-size:24px; margin:0 0 4px; color:#0b2d4e; }
 h2 { font-size:16px; margin:0 0 14px; color:#0b2d4e; text-transform:uppercase; letter-spacing:1px; border-bottom:2px solid #e1e8f1; padding-bottom:8px; }
 header { background:#0b2d4e; color:#fff; padding:28px 28px 22px; }
 header h1 { color:#fff; } header .sub { color:#9cc2ff; font-size:13px; margin-top:4px; }
 header .stamp { color:#6c90bf; font-size:12px; margin-top:10px; font-family: Consolas, monospace; }
 .card { background:#fff; border:1px solid #e1e8f1; border-radius:8px; padding:20px 24px; margin-bottom:18px; }
 table { width:100%; border-collapse:collapse; font-size:13px; }
 table th { background:#f0f4f9; text-align:left; padding:9px 12px; border:1px solid #e1e8f1; color:#0b2d4e; font-weight:600; white-space:nowrap; }
 table td { padding:9px 12px; border:1px solid #e1e8f1; vertical-align:top; }
 .cmd { background:#0e1c2e; color:#c9e2ff; padding:6px 10px; margin:4px 0; border-radius:4px; font-family: Consolas, monospace; font-size:12px; overflow-x:auto; white-space:pre-wrap; word-break:break-all; }
 .dns { background:#fff8e1; border:2px solid #ffd87a; padding:18px 22px; border-radius:8px; font-family: Consolas, monospace; font-size:13px; }
 .signoff { background:#f0f4f9; padding:20px 24px; border-radius:8px; margin-top:22px; }
 .signoff .row { display:flex; gap:26px; margin-top:14px; }
 .signoff .row > div { flex:1; border-bottom:1px solid #94a3b8; padding-bottom:30px; font-size:12px; color:#64748b; }
 footer { text-align:center; color:#6c90bf; font-size:11px; margin-top:30px; }
</style></head><body>
<header>
 <div class="stamp">PYX Health / Change Request</div>
 <h1>FX Survey Portal - Front Door Migration + Custom Domain</h1>
 <div class="sub">Classic -&gt; Standard migration + survey.farmboxrx.com setup + Azure-managed cert + WAF</div>
 <div class="stamp">Generated $ts - dry-run plan only (no changes made)</div>
</header>
<div class="wrap">
<section class="card"><h2>Executive summary</h2>
 <table><tbody>
  <tr><th style="width:34%;">Managed TLS cert expired</th><td>Azure-managed certs on classic <b>hipyx</b> expired 2026-04-14. Azure begins auto-migration on 2026-04-30; controlled migration before that avoids service disruption.</td></tr>
  <tr><th>Front Door Classic retirement</th><td>Classic tier EOL 2027-03-31. Migration moves us to Standard tier two years early.</td></tr>
  <tr><th>FX Survey URL cleanup</th><td>Puts <b>survey.farmboxrx.com</b> in front of the Static Web App with a valid managed cert before Monday's program launch.</td></tr>
 </tbody></table></section>

<section class="card"><h2>Discovered state</h2>
 <table><tbody>
  <tr><th>Classic profile</th><td><code>$Classic</code></td></tr>
  <tr><th>Subscription</th><td>$($found.SubscriptionName) &middot; <code>$($found.SubscriptionId)</code></td></tr>
  <tr><th>Resource group</th><td><code>$($found.ResourceGroup)</code></td></tr>
  <tr><th>Resource ID</th><td style="font-family:Consolas,monospace;font-size:11px;">$($found.ResourceId)</td></tr>
 </tbody></table></section>

<section class="card"><h2>Proposed changes</h2>
 <table><tbody>
  <tr><th style="width:28%;">Resource</th><th>Current</th><th>After migration</th></tr>
  <tr><td>Front Door profile</td><td>$Classic (Classic)</td><td>$NewName (<b>$Sku</b>)</td></tr>
  <tr><td>Origin</td><td>(existing, unchanged)</td><td>New origin -&gt; <code>$Origin</code></td></tr>
  <tr><td>Custom domain</td><td>None on new profile</td><td><b>$Domain</b> + Azure-managed cert (TLS 1.2)</td></tr>
  <tr><td>WAF</td><td>None</td><td>$WafPolicyName (OWASP 2.1, detection mode)</td></tr>
 </tbody></table></section>

<section class="card"><h2>Commands the script will execute</h2>
 <p style="color:#64748b;">Every command runs via Azure CLI. Each destructive step is gated behind a y/N prompt in the live run.</p>
$cmdsHtml
</section>

<section class="card"><h2>DNS records Robert publishes at farmboxrx.com</h2>
 <div class="dns">
<b>1) Ownership validation</b> (publish FIRST)
   TYPE : TXT
   NAME : _dnsauth.survey
   VALUE: &lt;issued by Azure on live run&gt;
   TTL  : 300

<b>2) Traffic routing</b> (publish AFTER step 1 validates)
   TYPE : CNAME
   NAME : survey
   VALUE: $NewName-endpoint.azurefd.net
   TTL  : 300
 </div></section>

<section class="card"><h2>Timing</h2>
 <table><tbody>
  <tr><th>Azure-side migration + config</th><td>30 - 90 min</td></tr>
  <tr><th>DNS publish (Robert)</th><td>~5 min + 15-60 min propagation</td></tr>
  <tr><th>Managed cert issuance</th><td>15 - 60 min after DNS validates</td></tr>
  <tr><th>Total wall-clock</th><td><b>~1.5 to 3 hours</b> &middot; hands-on: 10-15 min</td></tr>
 </tbody></table></section>

<section class="card"><h2>Rollback</h2>
 <ul style="margin:4px 0 0 18px;">
  <li>Before migration commit: abort returns environment to pre-change state (no mutations applied).</li>
  <li>After commit: Azure retains a 60-day rollback window on the classic profile.</li>
  <li>Custom domain, WAF, and route are independent resources &mdash; each can be deleted individually.</li>
 </ul></section>

<section class="card signoff"><h2>Sign-off</h2>
 <p>Approvals required before the live run:</p>
 <div class="row">
  <div><b>Tony Schlak</b> &middot; Director of IT</div>
  <div><b>John Pinto</b> &middot; Application Owner</div>
  <div><b>Syed Rizvi</b> &middot; Executor</div>
 </div></section>

<footer>PYX Health internal change request &middot; FX survey portal migration<br>
Generated by pyx-fx-survey-migration/migrate.ps1 &middot; this document is a DRY-RUN plan.</footer>
</div></body></html>
"@
    Set-Content -Path $HtmlReportPath -Value $html -Encoding UTF8
    if (Test-Path $HtmlReportPath) {
        Ok "HTML change plan written: $((Resolve-Path $HtmlReportPath).Path)"
        Ok "Open it in a browser, then forward to Tony/John for sign-off."
    }
}
