# =============================================================================
#  FX Survey Portal Migration - ROLLBACK
#
#  Reverses the changes that migrate.ps1 made. Use this if the Thursday
#  cutover introduces fallout and Friday needs a clean restore for
#  survey.farmboxrx.com.
#
#  DEFAULT MODE (surgical, recommended):
#    Removes only the FX-survey-specific resources that migrate.ps1 created:
#      - security policy   'fx-survey-waf'
#      - route             'fx-survey-route'
#      - origin            'fx-survey-origin'
#      - origin group      'fx-survey-origin-group'
#      - custom domain     'survey-farmboxrx-com'  (survey.farmboxrx.com)
#      - WAF policy        'hipyxWafPolicy'
#    Leaves the hipyx-std Standard profile in place, because classic
#    hostnames that Azure migrated into it are now served from that same
#    profile. Deleting it would break every classic customer hostname.
#
#  -DeleteProfile (only if fully rolling back the Classic->Standard migration):
#    Also deletes every endpoint and the hipyx-std profile itself. Use only
#    within Azure's 60-day rollback window AND after coordinating with
#    Tony / John that every classic customer hostname is being reverted.
#
#  Recommended run order if fallout hits Friday:
#    1. Robert reverts DNS (survey.farmboxrx.com CNAME to its pre-migration
#       target). Wait 10-20 min for propagation.
#    2. THEN run this script to remove the now-unused Azure resources.
#    Doing DNS first avoids a brief hard-error window for end users.
#
#  Usage:
#     .\fx-survey-rollback.ps1 -DryRun                       # preview only
#     .\fx-survey-rollback.ps1 -DryRun -HtmlReport           # preview + HTML report
#     .\fx-survey-rollback.ps1                                # prompts y/N each step
#     .\fx-survey-rollback.ps1 -Yes                           # no prompts
#     .\fx-survey-rollback.ps1 -DeleteProfile                 # also drops hipyx-std
# =============================================================================
param(
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Show,
    [switch]$DeleteProfile,
    [string]$Subscription,
    [string]$NewName              = "hipyx-std",
    [string]$Classic              = "hipyx",
    [string]$Domain               = "survey.farmboxrx.com",
    [string]$OriginGroupName      = "fx-survey-origin-group",
    [string]$OriginName           = "fx-survey-origin",
    [string]$RouteName            = "fx-survey-route",
    [string]$WafPolicyName        = "hipyxWafPolicy",
    [string]$SecurityPolicyName   = "fx-survey-waf",
    [switch]$HtmlReport,
    [string]$HtmlReportPath       = ""
)

$ErrorActionPreference = "Stop"

# If HtmlReport is set, imply DryRun (plan only, don't execute)
if ($HtmlReport -and -not $DryRun) { $DryRun = $true }
if ($HtmlReport -and -not $HtmlReportPath) {
    $HtmlReportPath = ".\fx-survey-rollback-plan-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
}

$DomainSafe = $Domain -replace '\.','-'
$Script:PlannedCommands = New-Object System.Collections.ArrayList

function Say  ($m) { Write-Host "`n[step] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "  ok  $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  !!  $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "  xx  $m" -ForegroundColor Red; exit 1 }

function Confirm-Action($prompt) {
    if ($Yes) { return $true }
    $ans = Read-Host "  ?? $prompt [y/N]"
    return $ans -match '^[Yy]$'
}

function Invoke-Az {
    # Same pattern as migrate.ps1 - use $args to avoid binding -o/-Name to
    # cmdlet common parameters. Continue on errors so a missing resource
    # (already gone) does not abort the whole rollback.
    $cmdText = "az " + ($args -join " ")
    if ($Show -or $DryRun) { Write-Host "  `$ $cmdText" -ForegroundColor Magenta }
    if ($HtmlReport) { [void]$Script:PlannedCommands.Add($cmdText) }
    if ($DryRun) { return "" }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & az @args
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($exit -ne 0) {
        Warn "az command returned exit code $exit : $cmdText (continuing - resource may already be gone)"
    }
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

# ---- Phase 1: discovery -----------------------------------------------------
Say "[1/7] Scanning every accessible subscription for Standard profile '$NewName'"

if ($Subscription) {
    az account set --subscription $Subscription --only-show-errors | Out-Null
    $subs = @([pscustomobject]@{id=$Subscription;name=(az account show --query name -o tsv)})
    Ok "Using forced subscription: $Subscription"
} else {
    $raw  = az account list --query "[?state=='Enabled'].{id:id, name:name}" -o json --only-show-errors
    if ($raw) { $subs = $raw | ConvertFrom-Json } else { $subs = $null }
}

$subsArr = @($subs)
if (-not $subsArr -or $subsArr.Count -eq 0) { Die "No enabled subscriptions found. Did you 'az login' to the right tenant?" }
Ok ("Scanning {0} subscription(s)..." -f $subsArr.Count)

$found      = $null
$matchCount = 0
foreach ($s in $subsArr) {
    Write-Host ("      .. {0}   ({1})" -f $s.name, $s.id)
    try { az account set --subscription $s.id --only-show-errors | Out-Null } catch { continue }

    $hit = ""
    try {
        $hit = az afd profile list --query "[?name=='$NewName'] | [0].id" -o tsv --only-show-errors 2>$null
    } catch { $hit = "" }

    if ($hit -and $hit.StartsWith("/subscriptions/")) {
        $matchCount++
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

if ($matchCount -eq 0) {
    Die "Standard profile '$NewName' not found in any accessible subscription. Either migration never ran, was already rolled back, or is in a subscription/tenant you can't access."
}
if ($matchCount -gt 1) {
    Die "Profile '$NewName' exists in MULTIPLE subscriptions. Re-run with -Subscription <id> to pick one."
}

Ok "Located ${NewName}:"
Ok "  subscription: $($found.SubscriptionName) ($($found.SubscriptionId))"
Ok "  resource grp: $($found.ResourceGroup)"
Ok "  resource id : $($found.ResourceId)"
az account set --subscription $found.SubscriptionId --only-show-errors | Out-Null

# Find the endpoint that actually hosts the FX-survey route (avoids guessing
# if Azure created multiple endpoints during the classic->std migration).
$endpointName = ""
if (-not $DryRun) {
    $epsRaw = $null
    try { $epsRaw = az afd endpoint list --profile-name $NewName --resource-group $found.ResourceGroup -o json --only-show-errors 2>$null } catch { $epsRaw = $null }
    $eps = $null
    if ($epsRaw) { try { $eps = $epsRaw | ConvertFrom-Json } catch { $eps = $null } }
    foreach ($ep in @($eps)) {
        try {
            $r = az afd route show --profile-name $NewName --resource-group $found.ResourceGroup --endpoint-name $ep.name --route-name $RouteName --only-show-errors 2>$null
            if ($LASTEXITCODE -eq 0 -and $r) { $endpointName = $ep.name; break }
        } catch { continue }
    }
    if (-not $endpointName -and $eps) { $endpointName = $eps[0].name }
}
if (-not $endpointName) { $endpointName = "hipyx-endpoint" }
Ok "Using endpoint: $endpointName"

# ---- Phase 2: plan ----------------------------------------------------------
Say "[2/7] Rollback plan"
$profileAction = if ($DeleteProfile) {
    "DELETE $NewName profile (full Classic->Std rollback)"
} else {
    "LEAVE $NewName in place (surgical rollback, FX survey only)"
}
Write-Host @"
   SCOPE:
     1. Remove security policy  '$SecurityPolicyName'
     2. Delete route            '$RouteName'         on endpoint '$endpointName'
     3. Delete origin           '$OriginName'        in '$OriginGroupName'
     4. Delete origin group     '$OriginGroupName'
     5. Delete custom domain    '$DomainSafe'        ($Domain)
     6. Delete WAF policy       '$WafPolicyName'
     7. $profileAction

   DNS ROLLBACK (Robert, at farmboxrx.com):
     - Remove TXT _dnsauth.survey
     - Revert CNAME 'survey' to its pre-migration target
       (if unknown, point at: mycareloop.z22.web.core.windows.net)

   RECOMMENDED: flip DNS at farmboxrx.com FIRST, wait 10-20 min for
   propagation, THEN run this script. That avoids a hard-error window
   for end users between resource deletion and DNS update.

   subscription : $($found.SubscriptionName)
   resource grp : $($found.ResourceGroup)
"@
if ($DryRun) { Warn "DRY-RUN mode: no mutations will be made." }
if (-not (Confirm-Action "Proceed with rollback?")) { Die "Aborted by user." }

# ---- Phase 3: security policy -----------------------------------------------
Say "[3/7] Removing security policy '$SecurityPolicyName'"
Invoke-Az afd security-policy delete `
    --profile-name $NewName `
    --resource-group $found.ResourceGroup `
    --security-policy-name $SecurityPolicyName `
    --yes

# ---- Phase 4: route ---------------------------------------------------------
Say "[4/7] Deleting route '$RouteName' on endpoint '$endpointName'"
Invoke-Az afd route delete `
    --profile-name $NewName `
    --resource-group $found.ResourceGroup `
    --endpoint-name $endpointName `
    --route-name $RouteName `
    --yes

# ---- Phase 5: origin + origin group -----------------------------------------
Say "[5/7] Deleting origin '$OriginName' then origin group '$OriginGroupName'"
Invoke-Az afd origin delete `
    --profile-name $NewName `
    --resource-group $found.ResourceGroup `
    --origin-group-name $OriginGroupName `
    --origin-name $OriginName `
    --yes

Invoke-Az afd origin-group delete `
    --profile-name $NewName `
    --resource-group $found.ResourceGroup `
    --origin-group-name $OriginGroupName `
    --yes

# ---- Phase 6: custom domain + WAF policy ------------------------------------
Say "[6/7] Deleting custom domain '$DomainSafe' and WAF policy '$WafPolicyName'"
Invoke-Az afd custom-domain delete `
    --profile-name $NewName `
    --resource-group $found.ResourceGroup `
    --custom-domain-name $DomainSafe `
    --yes

Invoke-Az network front-door waf-policy delete `
    --resource-group $found.ResourceGroup `
    --name $WafPolicyName `
    --yes

# ---- Phase 7: optional profile deletion -------------------------------------
Say "[7/7] Profile-level action"
if ($DeleteProfile) {
    Warn "-DeleteProfile is set. This drops the entire Standard profile."
    Warn "EVERY classic customer hostname that was migrated into '$NewName' will stop serving."
    Warn "Verify with Tony / John before proceeding."
    if (Confirm-Action "Really delete the $NewName profile?") {
        # Cascade: remove endpoints first, then the profile itself.
        if (-not $DryRun) {
            $epsRaw2 = $null
            try { $epsRaw2 = az afd endpoint list --profile-name $NewName --resource-group $found.ResourceGroup -o json --only-show-errors 2>$null } catch { $epsRaw2 = $null }
            $eps2 = $null
            if ($epsRaw2) { try { $eps2 = $epsRaw2 | ConvertFrom-Json } catch { $eps2 = $null } }
            foreach ($ep in @($eps2)) {
                Invoke-Az afd endpoint delete `
                    --profile-name $NewName `
                    --resource-group $found.ResourceGroup `
                    --endpoint-name $ep.name `
                    --yes
            }
        }
        Invoke-Az afd profile delete `
            --profile-name $NewName `
            --resource-group $found.ResourceGroup `
            --yes
        Ok "$NewName profile deleted."
    } else {
        Warn "Profile deletion skipped by user."
    }
} else {
    Ok "Leaving $NewName profile in place (use -DeleteProfile for full rollback)."
}

Ok "Rollback complete."

# ---- DNS rollback handoff ---------------------------------------------------
Write-Host ""
Write-Host "   ----------------------------------------------------------------------"
Write-Host "   DNS rollback for Robert / Natalie at farmboxrx.com"
Write-Host "   ----------------------------------------------------------------------"
Write-Host "   1) REMOVE:  TXT    _dnsauth.survey"
Write-Host "   2) REVERT:  CNAME  survey  ->  <pre-migration target>"
Write-Host "               (if unknown: CNAME survey -> mycareloop.z22.web.core.windows.net)"
Write-Host "   ----------------------------------------------------------------------"
Write-Host ""

# ---- Optional: HTML rollback plan -------------------------------------------
if ($HtmlReport) {
    Say "Writing HTML rollback plan: $HtmlReportPath"
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
    $cmdsHtml = ""
    foreach ($c in $Script:PlannedCommands) {
        $escaped = $null
        try { $escaped = [System.Web.HttpUtility]::HtmlEncode($c) } catch { $escaped = $null }
        if (-not $escaped) { $escaped = $c -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
        $cmdsHtml += "    <div class=`"cmd`"><code>$escaped</code></div>`n"
    }
    $profileRow = if ($DeleteProfile) {
        "<tr><td>$NewName Standard profile</td><td>In use</td><td><b>Deleted</b></td></tr>"
    } else {
        "<tr><td>$NewName Standard profile</td><td>In use</td><td>Unchanged (surgical rollback)</td></tr>"
    }
    $html = @"
<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><title>FX Survey Rollback - Change Plan</title>
<style>
 body { font-family: -apple-system, Segoe UI, Roboto, Arial, sans-serif; background:#f7f9fc; color:#1f2d3d; margin:0; padding:0; font-size:14px; line-height:1.55; }
 .wrap { max-width:1040px; margin:0 auto; padding:32px 28px 60px; }
 h1 { font-size:24px; margin:0 0 4px; color:#0b2d4e; }
 h2 { font-size:16px; margin:0 0 14px; color:#0b2d4e; text-transform:uppercase; letter-spacing:1px; border-bottom:2px solid #e1e8f1; padding-bottom:8px; }
 header { background:#8b1a1a; color:#fff; padding:28px 28px 22px; }
 header h1 { color:#fff; } header .sub { color:#ffc9c9; font-size:13px; margin-top:4px; }
 header .stamp { color:#ffb0b0; font-size:12px; margin-top:10px; font-family: Consolas, monospace; }
 .card { background:#fff; border:1px solid #e1e8f1; border-radius:8px; padding:20px 24px; margin-bottom:18px; }
 table { width:100%; border-collapse:collapse; font-size:13px; }
 table th { background:#f0f4f9; text-align:left; padding:9px 12px; border:1px solid #e1e8f1; color:#0b2d4e; font-weight:600; white-space:nowrap; }
 table td { padding:9px 12px; border:1px solid #e1e8f1; vertical-align:top; }
 .cmd { background:#0e1c2e; color:#c9e2ff; padding:6px 10px; margin:4px 0; border-radius:4px; font-family: Consolas, monospace; font-size:12px; overflow-x:auto; white-space:pre-wrap; word-break:break-all; }
 .dns { background:#fff8e1; border:2px solid #ffd87a; padding:18px 22px; border-radius:8px; font-family: Consolas, monospace; font-size:13px; }
 .warn { background:#fff3cd; border:2px solid #ffeeba; padding:14px 18px; border-radius:6px; color:#664d03; }
 .signoff { background:#f0f4f9; padding:20px 24px; border-radius:8px; margin-top:22px; }
 .signoff .row { display:flex; gap:26px; margin-top:14px; }
 .signoff .row > div { flex:1; border-bottom:1px solid #94a3b8; padding-bottom:30px; font-size:12px; color:#64748b; }
 footer { text-align:center; color:#6c90bf; font-size:11px; margin-top:30px; }
</style></head><body>
<header>
 <div class="stamp">Emergency Change / Rollback</div>
 <h1>FX Survey Portal - Front Door Migration ROLLBACK</h1>
 <div class="sub">Reverses migrate.ps1 changes if Thursday's cutover causes fallout</div>
 <div class="stamp">Generated $ts - dry-run plan only (no changes made)</div>
</header>
<div class="wrap">

<section class="card warn"><b>When to run:</b> only if the Thursday migration causes user-facing issues that cannot be hot-fixed in place. Coordinate with Tony (Director of IT) and John (application owner) before executing. <b>Flip DNS first</b> at farmboxrx.com, wait 10-20 min for propagation, then run this script to remove the unused Azure resources.
</section>

<section class="card"><h2>Target state after rollback</h2>
 <table><tbody>
  <tr><th style="width:28%;">Resource</th><th>Current (post-migration)</th><th>After rollback</th></tr>
  <tr><td>Custom domain</td><td>$Domain on $NewName</td><td>Removed</td></tr>
  <tr><td>Route</td><td>$RouteName on endpoint $endpointName</td><td>Removed</td></tr>
  <tr><td>Origin / origin group</td><td>$OriginName / $OriginGroupName</td><td>Removed</td></tr>
  <tr><td>WAF policy</td><td>$WafPolicyName</td><td>Removed</td></tr>
  <tr><td>Security policy</td><td>$SecurityPolicyName</td><td>Removed</td></tr>
  $profileRow
 </tbody></table></section>

<section class="card"><h2>Discovered state</h2>
 <table><tbody>
  <tr><th style="width:28%;">Profile</th><td><code>$NewName</code></td></tr>
  <tr><th>Subscription</th><td>$($found.SubscriptionName) &middot; <code>$($found.SubscriptionId)</code></td></tr>
  <tr><th>Resource group</th><td><code>$($found.ResourceGroup)</code></td></tr>
  <tr><th>Endpoint hosting route</th><td><code>$endpointName</code></td></tr>
 </tbody></table></section>

<section class="card"><h2>Commands the script will execute</h2>
 <p style="color:#64748b;">Each destructive step is gated behind a y/N prompt in the live run. Use <code>-Yes</code> to skip prompts.</p>
$cmdsHtml
</section>

<section class="card"><h2>DNS rollback (Robert at farmboxrx.com)</h2>
 <div class="dns">
<b>1) Remove</b>
   TYPE : TXT
   NAME : _dnsauth.survey

<b>2) Revert</b>
   TYPE : CNAME
   NAME : survey
   VALUE: &lt;pre-migration target&gt;
          (if unknown: mycareloop.z22.web.core.windows.net)
   TTL  : 300
 </div></section>

<section class="card signoff"><h2>Sign-off</h2>
 <p>Approvals required before executing the rollback:</p>
 <div class="row">
  <div><b>Tony Schlak</b> &middot; Director of IT</div>
  <div><b>John Pinto</b> &middot; Application Owner</div>
  <div><b>Syed Rizvi</b> &middot; Executor</div>
 </div></section>

<footer>Internal emergency-change rollback &middot; FX survey portal<br>
Generated by fx-survey-rollback.ps1 &middot; this document is a DRY-RUN plan.</footer>
</div></body></html>
"@
    Set-Content -Path $HtmlReportPath -Value $html -Encoding UTF8
    if (Test-Path $HtmlReportPath) {
        Ok "HTML rollback plan written: $((Resolve-Path $HtmlReportPath).Path)"
        Ok "Open it in a browser, then forward to Tony/John as the rollback change-ticket attachment."
    }
}
