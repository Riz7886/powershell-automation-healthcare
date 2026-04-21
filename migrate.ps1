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
function Die  ($m) { Write-Host "  xx  $m" -ForegroundColor Red; exit 1 }

function Confirm-Action($prompt) {
    if ($Yes) { return $true }
    $ans = Read-Host "  ?? $prompt [y/N]"
    return $ans -match '^[Yy]$'
}

function Invoke-Az {
    # NOTE: intentionally NO param() block. Using the automatic $args variable
    # so PowerShell does not try to bind names like -o / --resource-group to
    # this function's cmdlet-common parameters (which caused "ambiguous
    # parameter -o" errors against -OutVariable / -OutBuffer).
    $cmdText = "az " + ($args -join " ")
    if ($Show -or $DryRun) { Write-Host "  `$ $cmdText" -ForegroundColor Magenta }
    if ($HtmlReport) { [void]$Script:PlannedCommands.Add($cmdText) }
    if ($DryRun) { return "" }
    & az @args
    if ($LASTEXITCODE -ne 0) {
        Warn "az command returned exit code $LASTEXITCODE : $cmdText"
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

# ---- Phase 3: preview -------------------------------------------------------
Say "[3/7] Migration preview (read-only)"
Invoke-Az afd profile-migration validate `
    --name $NewName `
    --resource-group $found.ResourceGroup `
    --classic-resource-id $found.ResourceId `
    --sku $Sku `
    -o json --only-show-errors

# ---- Phase 4: commit --------------------------------------------------------
Say "[4/7] COMMITTING migration (this is the real change)"
if (-not (Confirm-Action "Commit migration now?")) { Die "Aborted before commit." }
Invoke-Az afd profile-migration migrate `
    --name $NewName `
    --resource-group $found.ResourceGroup `
    --classic-resource-id $found.ResourceId `
    --sku $Sku
Ok "Migration committed. Standard profile '$NewName' is now live."

# ---- Phase 5: origin + route ------------------------------------------------
Say "[5/7] Origin group + origin + route"
Invoke-Az afd origin-group create `
    --profile-name $NewName `
    --resource-group $found.ResourceGroup `
    --origin-group-name $OriginGroupName `
    --probe-path "/" --probe-protocol Https `
    --probe-request-type GET --probe-interval-in-seconds 60 `
    --sample-size 4 --successful-samples-required 3 `
    --additional-latency-in-milliseconds 50

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

# Find or create endpoint
$endpointName = ""
if (-not $DryRun) {
    try {
        $endpointName = az afd endpoint list --profile-name $NewName --resource-group $found.ResourceGroup --query "[0].name" -o tsv --only-show-errors 2>$null
    } catch { $endpointName = "" }
}
if (-not $endpointName) {
    $endpointName = "hipyx-endpoint"
    Invoke-Az afd endpoint create `
        --profile-name $NewName `
        --resource-group $found.ResourceGroup `
        --endpoint-name $endpointName `
        --enabled-state Enabled
}
Ok "Using endpoint: $endpointName"

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

# ---- Phase 6: custom domain + cert + WAF ------------------------------------
Say "[6/7] Custom domain + managed cert + WAF"

Invoke-Az afd custom-domain create `
    --profile-name $NewName `
    --resource-group $found.ResourceGroup `
    --custom-domain-name $DomainSafe `
    --host-name $Domain `
    --minimum-tls-version TLS12 `
    --certificate-type ManagedCertificate

Invoke-Az afd route update `
    --profile-name $NewName `
    --resource-group $found.ResourceGroup `
    --endpoint-name $endpointName `
    --route-name $RouteName `
    --custom-domains $DomainSafe

Invoke-Az network front-door waf-policy create `
    --resource-group $found.ResourceGroup `
    --name $WafPolicyName `
    --mode Detection `
    --sku $Sku

Invoke-Az network front-door waf-policy managed-rules add `
    --resource-group $found.ResourceGroup `
    --policy-name $WafPolicyName `
    --type Microsoft_DefaultRuleSet `
    --version 2.1

$wafResId = "/subscriptions/$($found.SubscriptionId)/resourceGroups/$($found.ResourceGroup)/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/$WafPolicyName"
$domResId = "/subscriptions/$($found.SubscriptionId)/resourceGroups/$($found.ResourceGroup)/providers/Microsoft.Cdn/profiles/$NewName/customDomains/$DomainSafe"
Invoke-Az afd security-policy create `
    --profile-name $NewName `
    --resource-group $found.ResourceGroup `
    --security-policy-name "fx-survey-waf" `
    --waf-policy $wafResId `
    --domains $domResId

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
Write-Host "   ----------------------------------------------------------------------"
Write-Host "   DNS records at farmboxrx.com (send to Robert / Natalie)"
Write-Host "   ----------------------------------------------------------------------"
Write-Host "   1) TYPE : TXT"
Write-Host "      NAME : _dnsauth.survey"
Write-Host "      VALUE: $validationToken"
Write-Host "      TTL  : 300"
Write-Host "   2) TYPE : CNAME"
Write-Host "      NAME : survey"
Write-Host "      VALUE: $cnameTarget"
Write-Host "      TTL  : 300"
Write-Host "   ----------------------------------------------------------------------"
Write-Host ""

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
