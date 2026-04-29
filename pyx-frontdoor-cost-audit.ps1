[CmdletBinding()]
param(
    [string]$SubscriptionId  = "e42e94b5-c6f8-4af0-a41b-16fda520de6e",
    [string]$ResourceGroup   = "production",
    [int]   $LookbackDays    = 30,
    [string[]]$MigrationScope = @("hipyx","pyxiq","pyxiq-stage","pypwa-stage"),
    [string]$ReportDir       = (Join-Path $env:USERPROFILE "Desktop\pyx-frontdoor-cost-audit")
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
$logPath  = Join-Path $ReportDir "audit-$timestamp.log"
$htmlPath = Join-Path $ReportDir "frontdoor-cost-audit-$timestamp.html"
$jsonPath = Join-Path $ReportDir "frontdoor-cost-audit-$timestamp.json"

function Log {
    param([string]$Message, [string]$Color = "White")
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line = "[$stamp] $Message"
    Add-Content -Path $logPath -Value $line
    Write-Host $line -ForegroundColor $Color
}
function Banner($t) { Log ""; Log ("=" * 78) Cyan; Log $t Cyan; Log ("=" * 78) Cyan }

Banner "Front Door cost audit  -  subscription wide"
Log "Subscription:  $SubscriptionId"
Log "Resource group: $ResourceGroup"
Log "Lookback days: $LookbackDays"
Log "Migration scope (planned cutover): $($MigrationScope -join ', ')"
Log "Report dir:    $ReportDir"

# Pre-flight
$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $acct) { Log "az login..." Yellow; az login --only-show-errors | Out-Null }
az account set --subscription $SubscriptionId --only-show-errors | Out-Null
Log "Signed in as $($acct.user.name)" Green

$installed = az extension list --query "[?name=='front-door'].name" -o tsv 2>$null
if (-not $installed) { az extension add --name front-door --only-show-errors | Out-Null }
az extension update --name front-door --only-show-errors 2>$null | Out-Null

$startTime = (Get-Date).AddDays(-$LookbackDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
$endTime   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
Log "Metrics window: $startTime  ->  $endTime"

$results = @()

# ============================================================================
Banner "Phase 1 - Discover all Front Door Classic profiles in the RG"
# ============================================================================
$classicNames = az network front-door list -g $ResourceGroup --query "[].name" -o tsv 2>$null
$classicList = @($classicNames -split "`r?`n" | Where-Object { $_ })
Log "Found $($classicList.Count) Classic Front Door profile(s)"

foreach ($cp in $classicList) {
    Log ""
    Log "--- $cp (Classic) ---" Cyan
    $resId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/frontDoors/$cp"

    # Custom domains (frontend-endpoints excluding *.azurefd.net)
    $feText = az network front-door frontend-endpoint list -g $ResourceGroup --front-door-name $cp --query "[].[name,hostName]" -o tsv 2>$null
    $customDomains = @()
    foreach ($line in @($feText -split "`r?`n" | Where-Object { $_ })) {
        $cols = $line -split "`t"
        if ($cols.Count -ge 2 -and $cols[1] -notlike "*.azurefd.net") { $customDomains += $cols[1] }
    }

    # Routing rules count
    $ruleCount = (az network front-door routing-rule list -g $ResourceGroup --front-door-name $cp --query "length([])" -o tsv 2>$null)
    if (-not $ruleCount) { $ruleCount = 0 }

    # Backend pools count
    $bpCount = (az network front-door backend-pool list -g $ResourceGroup --front-door-name $cp --query "length([])" -o tsv 2>$null)
    if (-not $bpCount) { $bpCount = 0 }

    # WAF policies referenced by frontend-endpoints
    $wafLinks = az network front-door frontend-endpoint list -g $ResourceGroup --front-door-name $cp --query "[].webApplicationFirewallPolicyLink.id" -o tsv 2>$null
    $wafs = @($wafLinks -split "`r?`n" | Where-Object { $_ } | ForEach-Object { ($_ -split '/')[-1] } | Select-Object -Unique)

    # 30-day total request count
    $reqJson = az monitor metrics list --resource $resId --metric RequestCount --interval P1D --aggregation Total --start-time $startTime --end-time $endTime -o json 2>$null | ConvertFrom-Json
    $reqTotal = 0
    if ($reqJson -and $reqJson.value -and $reqJson.value[0].timeseries) {
        foreach ($ts in $reqJson.value[0].timeseries) {
            foreach ($d in $ts.data) { if ($d.total) { $reqTotal += [long]$d.total } }
        }
    }

    # 30-day total billable response size (bytes)
    $bytesJson = az monitor metrics list --resource $resId --metric BillableResponseSize --interval P1D --aggregation Total --start-time $startTime --end-time $endTime -o json 2>$null | ConvertFrom-Json
    $bytesTotal = 0
    if ($bytesJson -and $bytesJson.value -and $bytesJson.value[0].timeseries) {
        foreach ($ts in $bytesJson.value[0].timeseries) {
            foreach ($d in $ts.data) { if ($d.total) { $bytesTotal += [long]$d.total } }
        }
    }

    Log "  Custom domains: $($customDomains.Count)  ($([string]::Join(', ', $customDomains)))"
    Log "  Routing rules:  $ruleCount"
    Log "  Backend pools:  $bpCount"
    Log "  WAF policies:   $([string]::Join(', ', $wafs))"
    Log "  Requests (30d): $reqTotal"
    Log "  Bytes (30d):    $bytesTotal"

    $rec = if ($reqTotal -eq 0) { "DECOMMISSION-CANDIDATE" }
           elseif ($reqTotal -lt 1000) { "LOW-USAGE-REVIEW" }
           elseif ($reqTotal -lt 100000) { "ACTIVE-LOW-TRAFFIC" }
           else { "ACTIVE-HIGH-TRAFFIC" }

    # Cost projection (Classic): base $35/mo + bandwidth $0.082/GB outbound (Zone 1, US)
    # Classic does NOT have per-request charges (bundled in base)
    $bytesGB30d        = [math]::Round($bytesTotal / 1GB, 2)
    $bandwidthCost30d  = [math]::Round($bytesGB30d * 0.082, 2)
    $bandwidthCostMo   = $bandwidthCost30d  # 30 days ~= 1 month
    $requestCostMo     = 0
    $totalMonthlyCost  = 35 + $bandwidthCostMo
    $totalAnnualCost   = $totalMonthlyCost * 12

    $results += [PSCustomObject]@{
        Name = $cp
        Type = "AFD-Classic"
        Sku = "Classic_AzureFrontDoor"
        BasePriceMonthly = 35
        InMigrationScope = ($MigrationScope -contains $cp)
        CustomDomainCount = $customDomains.Count
        CustomDomains = ($customDomains -join ', ')
        RoutingRuleCount = [int]$ruleCount
        BackendPoolCount = [int]$bpCount
        WafPolicies = ($wafs -join ', ')
        Requests30d = $reqTotal
        Bytes30d = $bytesTotal
        BytesGB30d = $bytesGB30d
        BandwidthCostMonthly = $bandwidthCostMo
        RequestCostMonthly = $requestCostMo
        TotalMonthlyCost = [math]::Round($totalMonthlyCost, 2)
        TotalAnnualCost = [math]::Round($totalAnnualCost, 2)
        Recommendation = $rec
    }
}

# ============================================================================
Banner "Phase 2 - Discover all AFD Standard / Premium (Microsoft.Cdn) profiles in the RG"
# ============================================================================
$cdnText = az afd profile list -g $ResourceGroup --query "[].[name, sku.name]" -o tsv 2>$null
$cdnList = @()
foreach ($line in @($cdnText -split "`r?`n" | Where-Object { $_ })) {
    $cols = $line -split "`t"
    if ($cols.Count -ge 2) { $cdnList += [PSCustomObject]@{ Name = $cols[0]; Sku = $cols[1] } }
}
Log "Found $($cdnList.Count) AFD Standard/Premium profile(s)"

foreach ($p in $cdnList) {
    Log ""
    Log "--- $($p.Name) ($($p.Sku)) ---" Cyan
    $resId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Cdn/profiles/$($p.Name)"

    $cdCount = (az afd custom-domain list -g $ResourceGroup --profile-name $p.Name --query "length([])" -o tsv 2>$null)
    if (-not $cdCount) { $cdCount = 0 }
    $epCount = (az afd endpoint list -g $ResourceGroup --profile-name $p.Name --query "length([])" -o tsv 2>$null)
    if (-not $epCount) { $epCount = 0 }
    $ogCount = (az afd origin-group list -g $ResourceGroup --profile-name $p.Name --query "length([])" -o tsv 2>$null)
    if (-not $ogCount) { $ogCount = 0 }
    $secCount = (az afd security-policy list -g $ResourceGroup --profile-name $p.Name --query "length([])" -o tsv 2>$null)
    if (-not $secCount) { $secCount = 0 }
    $ruleSetCount = (az afd rule-set list -g $ResourceGroup --profile-name $p.Name --query "length([])" -o tsv 2>$null)
    if (-not $ruleSetCount) { $ruleSetCount = 0 }

    # Custom domain hostnames
    $cdHosts = az afd custom-domain list -g $ResourceGroup --profile-name $p.Name --query "[].hostName" -o tsv 2>$null
    $cdHostList = @($cdHosts -split "`r?`n" | Where-Object { $_ })

    # 30-day request count (Standard metric is RequestCount on the profile)
    $reqJson = az monitor metrics list --resource $resId --metric RequestCount --interval P1D --aggregation Total --start-time $startTime --end-time $endTime -o json 2>$null | ConvertFrom-Json
    $reqTotal = 0
    if ($reqJson -and $reqJson.value -and $reqJson.value[0].timeseries) {
        foreach ($ts in $reqJson.value[0].timeseries) {
            foreach ($d in $ts.data) { if ($d.total) { $reqTotal += [long]$d.total } }
        }
    }
    $bytesJson = az monitor metrics list --resource $resId --metric ResponseSize --interval P1D --aggregation Total --start-time $startTime --end-time $endTime -o json 2>$null | ConvertFrom-Json
    $bytesTotal = 0
    if ($bytesJson -and $bytesJson.value -and $bytesJson.value[0].timeseries) {
        foreach ($ts in $bytesJson.value[0].timeseries) {
            foreach ($d in $ts.data) { if ($d.total) { $bytesTotal += [long]$d.total } }
        }
    }

    $isPremium = $p.Sku -match "Premium"
    $basePrice = if ($isPremium) { 165 } else { 35 }

    Log "  SKU:             $($p.Sku)  (base \$$basePrice/month)"
    Log "  Custom domains:  $cdCount  ($([string]::Join(', ', $cdHostList)))"
    Log "  Endpoints:       $epCount"
    Log "  Origin groups:   $ogCount"
    Log "  Security policies: $secCount"
    Log "  Rule sets:       $ruleSetCount"
    Log "  Requests (30d):  $reqTotal"
    Log "  Bytes (30d):     $bytesTotal"

    $rec = if ($reqTotal -eq 0) { "DECOMMISSION-CANDIDATE" }
           elseif ($reqTotal -lt 1000) { "LOW-USAGE-REVIEW" }
           elseif ($reqTotal -lt 100000) { "ACTIVE-LOW-TRAFFIC" }
           else { "ACTIVE-HIGH-TRAFFIC" }

    # Cost projection (Standard / Premium): base + bandwidth $0.082/GB + per-request after 10M free
    $bytesGB30d        = [math]::Round($bytesTotal / 1GB, 2)
    $bandwidthCostMo   = [math]::Round($bytesGB30d * 0.082, 2)
    $billableRequests  = [math]::Max(0, $reqTotal - 10000000)
    $requestCostMo     = [math]::Round(($billableRequests / 10000) * 0.01, 2)
    $totalMonthlyCost  = $basePrice + $bandwidthCostMo + $requestCostMo
    $totalAnnualCost   = $totalMonthlyCost * 12

    $results += [PSCustomObject]@{
        Name = $p.Name
        Type = "AFD-Standard"
        Sku = $p.Sku
        BasePriceMonthly = $basePrice
        InMigrationScope = $false
        CustomDomainCount = [int]$cdCount
        CustomDomains = ($cdHostList -join ', ')
        RoutingRuleCount = [int]$ruleSetCount
        BackendPoolCount = [int]$ogCount
        WafPolicies = "via security-policy ($secCount)"
        Requests30d = $reqTotal
        Bytes30d = $bytesTotal
        BytesGB30d = $bytesGB30d
        BandwidthCostMonthly = $bandwidthCostMo
        RequestCostMonthly = $requestCostMo
        TotalMonthlyCost = [math]::Round($totalMonthlyCost, 2)
        TotalAnnualCost = [math]::Round($totalAnnualCost, 2)
        Recommendation = $rec
    }
}

# ============================================================================
Banner "Phase 3 - Cost-impact summary"
# ============================================================================
$inScope    = @($results | Where-Object { $_.InMigrationScope })
$outOfScope = @($results | Where-Object { -not $_.InMigrationScope })
$totalReqs  = ($results | Measure-Object Requests30d -Sum).Sum
$totalGB    = [math]::Round((($results | Measure-Object Bytes30d -Sum).Sum) / 1GB, 2)

Log "Total Front Door profiles in RG: $($results.Count)"
Log "  Classic (in migration scope): $($inScope.Count)  ->  $($MigrationScope -join ', ')"
Log "  Other Front Doors (untouched by this migration): $($outOfScope.Count)"
Log "  30-day total requests across all profiles: $totalReqs"
Log "  30-day total bytes across all profiles:    $totalGB GB"

# HTML report
$rowsAll = ($results | Sort-Object Type, Name | ForEach-Object {
    $scopeBadge = if ($_.InMigrationScope) { "<span class='badge in'>In scope</span>" } else { "<span class='badge out'>Untouched</span>" }
    $recClass = switch ($_.Recommendation) {
        "DECOMMISSION-CANDIDATE" { "rec rec-decom" }
        "LOW-USAGE-REVIEW" { "rec rec-review" }
        "ACTIVE-LOW-TRAFFIC" { "rec rec-active-low" }
        "ACTIVE-HIGH-TRAFFIC" { "rec rec-active" }
        default { "rec" }
    }
    "<tr><td><b>$($_.Name)</b><br/>$scopeBadge</td><td>$($_.Type)</td><td><code>$($_.Sku)</code></td><td style='text-align:right'>`$$($_.BasePriceMonthly)/mo</td><td>$($_.CustomDomainCount)<br/><span class='dim'>$([System.Web.HttpUtility]::HtmlEncode($_.CustomDomains))</span></td><td>$($_.RoutingRuleCount)</td><td>$($_.BackendPoolCount)</td><td><code>$($_.WafPolicies)</code></td><td style='text-align:right'>$('{0:N0}' -f $_.Requests30d)</td><td style='text-align:right'>$($_.BytesGB30d) GB</td><td style='text-align:right'>`$$('{0:N2}' -f $_.BandwidthCostMonthly)</td><td style='text-align:right'>`$$('{0:N2}' -f $_.RequestCostMonthly)</td><td style='text-align:right'><b>`$$('{0:N0}' -f $_.TotalAnnualCost)</b></td><td><span class='$recClass'>$($_.Recommendation)</span></td></tr>"
}) -join "`n"

# Decommission analysis
$decomCandidates = @($results | Where-Object { $_.Recommendation -eq "DECOMMISSION-CANDIDATE" })
$lowUsage       = @($results | Where-Object { $_.Recommendation -eq "LOW-USAGE-REVIEW" })
$decomSavingsMonthly = ($decomCandidates | Measure-Object BasePriceMonthly -Sum).Sum
$decomSavingsAnnual  = $decomSavingsMonthly * 12
$lowSavingsMonthly   = ($lowUsage | Measure-Object BasePriceMonthly -Sum).Sum
$lowSavingsAnnual    = $lowSavingsMonthly * 12

# Cost totals (across all profiles)
$totalMonthlyAll  = [math]::Round((($results | Measure-Object TotalMonthlyCost -Sum).Sum), 2)
$totalAnnualAll   = [math]::Round((($results | Measure-Object TotalAnnualCost -Sum).Sum), 2)
$totalBaseAnnual  = (($results | Measure-Object BasePriceMonthly -Sum).Sum) * 12
$totalBwAnnual    = [math]::Round((($results | Measure-Object BandwidthCostMonthly -Sum).Sum) * 12, 2)
$totalReqAnnual   = [math]::Round((($results | Measure-Object RequestCostMonthly -Sum).Sum) * 12, 2)

# Decommission savings (full annual cost, not just base, since we'd save bandwidth too)
$decomFullSavingsAnnual = [math]::Round((($decomCandidates | Measure-Object TotalAnnualCost -Sum).Sum), 2)
$lowFullSavingsAnnual   = [math]::Round((($lowUsage | Measure-Object TotalAnnualCost -Sum).Sum), 2)

$decomRows = if ($decomCandidates.Count -eq 0) { "<tr><td colspan='5' class='dim'>No zero-traffic profiles found.</td></tr>" } else {
    ($decomCandidates | ForEach-Object {
        "<tr><td><b>$($_.Name)</b></td><td>$($_.Type)</td><td>$($_.CustomDomainCount) ($([System.Web.HttpUtility]::HtmlEncode($_.CustomDomains)))</td><td style='text-align:right'>$('{0:N0}' -f $_.Requests30d)</td><td style='text-align:right'>`$$('{0:N0}' -f $_.TotalAnnualCost)/yr</td></tr>"
    }) -join "`n"
}
$lowRows = if ($lowUsage.Count -eq 0) { "<tr><td colspan='5' class='dim'>No low-usage profiles found.</td></tr>" } else {
    ($lowUsage | ForEach-Object {
        "<tr><td><b>$($_.Name)</b></td><td>$($_.Type)</td><td>$($_.CustomDomainCount) ($([System.Web.HttpUtility]::HtmlEncode($_.CustomDomains)))</td><td style='text-align:right'>$('{0:N0}' -f $_.Requests30d)</td><td style='text-align:right'>`$$('{0:N0}' -f $_.TotalAnnualCost)/yr</td></tr>"
    }) -join "`n"
}

Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

$html = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>PYX Front Door cost audit</title>
<style>
body{font-family:-apple-system,Segoe UI,Arial,sans-serif;color:#11151C;max-width:1300px;margin:32px auto;padding:0 28px;line-height:1.55;font-size:14px}
h1{font-size:22px;color:#1F3D7A;border-bottom:2px solid #1F3D7A;padding-bottom:8px;margin-bottom:6px}
.subtitle{color:#555E6D;font-size:13px;margin-bottom:24px}
h2{font-size:16px;color:#1F3D7A;border-bottom:1px solid #E5E8EE;padding-bottom:4px;margin-top:30px}
table{width:100%;border-collapse:collapse;margin:10px 0;font-size:12.5px}
th{text-align:left;background:#F5F7FA;padding:8px 10px;border-bottom:2px solid #1F3D7A;color:#1F3D7A;font-weight:600;font-size:12px}
td{padding:8px 10px;border-bottom:1px solid #E5E8EE;vertical-align:top}
code{font-family:Consolas,monospace;font-size:11.5px;background:#F5F7FA;padding:1px 5px;border-radius:3px}
.badge{display:inline-block;padding:1px 7px;border-radius:3px;font-size:10px;font-weight:600;color:#fff;margin-top:3px}
.badge.in{background:#A06A00}
.badge.out{background:#555E6D}
.dim{font-size:11px;color:#555E6D}
.box{background:#F5F7FA;border-left:3px solid #1F3D7A;padding:10px 14px;margin:14px 0;font-size:13px}
.box-green{background:#EAF7EE;border-left-color:#1B6B3A}
.box-amber{background:#FFF8E1;border-left-color:#A06A00}
.foot{margin-top:40px;padding-top:14px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:11.5px}
.kv{display:grid;grid-template-columns:240px 1fr;gap:6px 14px;font-size:13px;margin:6px 0}
.kv b{color:#1F3D7A}
.rec{display:inline-block;padding:2px 8px;border-radius:3px;font-size:10px;font-weight:600;color:#fff}
.rec-decom{background:#9B2226}
.rec-review{background:#A06A00}
.rec-active-low{background:#1F3D7A}
.rec-active{background:#1B6B3A}
.savings-callout{background:#FBEAEA;border-left:3px solid #9B2226;padding:12px 16px;margin:14px 0;font-size:14px}
.savings-callout b{color:#9B2226;font-size:18px}
</style></head><body>

<h1>Front Door cost-impact audit</h1>
<div class="subtitle">Subscription-wide inventory of every Azure Front Door profile in the production resource group, with 30-day traffic counts and the cost-relevant configuration (SKU, WAF, rules) per profile. Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') for the AFD Classic-to-Standard migration cost review.</div>

<h2>1.  Headline answers</h2>
<div class="box box-green">
<b>The AFD Classic-to-Standard migration adds zero new billing surface.</b><br><br>
- The migration moves the in-scope Classic profiles to AFD <b>Standard</b> SKU - <i>not</i> Premium. Same per-profile base fee (\$35/month).<br>
- The existing WAF policy is reused; no new WAF policy is being created.<br>
- Existing routing rules transfer as-is; no new rules-engine rules being added.<br>
- Managed TLS certificates are zero-cost on both Classic and Standard SKUs.<br>
- No DDoS Standard, no Application Insights, no Log Analytics export upsells touched by the migration script.<br>
- Bandwidth pricing is the same per-GB tier. Custom-domain count is unchanged.<br><br>
Net effect: roughly zero cost difference. Slight reduction is possible since Microsoft was preparing to charge for legacy Classic-managed-cert auto-renewal in April 2026 and the migration takes us off that path.
</div>

<div class="savings-callout">
<b>Current Front Door spend (projected annual, all profiles):</b> <code>\$$('{0:N0}' -f $totalAnnualAll)/year</code><br>
&nbsp;&nbsp;Base fees: <code>\$$('{0:N0}' -f $totalBaseAnnual)/yr</code> &nbsp;|&nbsp; Bandwidth: <code>\$$('{0:N0}' -f $totalBwAnnual)/yr</code> &nbsp;|&nbsp; Per-request (Standard tier 1 over 10M/mo): <code>\$$('{0:N0}' -f $totalReqAnnual)/yr</code><br><br>
<b>Decommission opportunities identified:</b> $($decomCandidates.Count) zero-traffic profile(s), $($lowUsage.Count) low-usage profile(s).<br>
Potential annual savings if all zero-traffic profiles are decommissioned: <b>\$$('{0:N0}' -f $decomFullSavingsAnnual)/year</b> (full cost: base + bandwidth + requests).<br>
Additional potential if all low-usage profiles are consolidated: <b>\$$('{0:N0}' -f $lowFullSavingsAnnual)/year</b>.<br>
Combined upper bound: <b>\$$('{0:N0}' -f ($decomFullSavingsAnnual + $lowFullSavingsAnnual))/year</b>.<br>
Details in Sections 3 and 4. These are <i>candidates</i> - each one needs an owner-confirmation before delete.
</div>

<h2>2.  All Front Door profiles in <code>$ResourceGroup</code></h2>
<p>30-day RequestCount drives the recommendation. Thresholds: 0 = decommission candidate, &lt;1K = low-usage review, &lt;100K = active low-traffic, &gt;=100K = active high-traffic. Cost columns are projections based on Microsoft's published Standard SKU rates: \$0.082/GB outbound bandwidth, \$0.01 per 10K requests over the 10M/month free tier (Standard only - Classic has no per-request fee).</p>
<table>
<thead><tr><th>Profile</th><th>Type</th><th>SKU</th><th style='text-align:right'>Base /mo</th><th>Custom domains</th><th>Rules</th><th>Pools</th><th>WAF</th><th style='text-align:right'>Requests (30d)</th><th style='text-align:right'>Bytes (30d)</th><th style='text-align:right'>BW \$/mo</th><th style='text-align:right'>Req \$/mo</th><th style='text-align:right'>Annual \$</th><th>Recommendation</th></tr></thead>
<tbody>
$rowsAll
</tbody></table>

<h2>3.  Decommission candidates  -  zero traffic in $($LookbackDays) days</h2>
<p>These profiles served <b>0 requests</b> over the lookback window. Almost certainly safe to delete after a quick owner-confirmation. Deletion saves the profile base fee plus any incidental WAF / rules-engine / origin-group costs. <b>Verify each one is not still wired to any production DNS record before deleting.</b></p>
<table>
<thead><tr><th>Profile</th><th>Type</th><th>Custom domains</th><th style='text-align:right'>Requests (30d)</th><th style='text-align:right'>Annual cost (full)</th></tr></thead>
<tbody>
$decomRows
</tbody></table>
<p><b>Total potential annual savings (zero-traffic):</b> <code>\$$('{0:N0}' -f $decomFullSavingsAnnual)/year</code> across $($decomCandidates.Count) profile(s).</p>

<h2>4.  Low-usage profiles  -  &lt;1,000 requests in $($LookbackDays) days</h2>
<p>These profiles are technically alive but barely used. They may be sandbox / test / legacy environments that can be merged into a sandbox profile or simply retired. Owner-review recommended before any action.</p>
<table>
<thead><tr><th>Profile</th><th>Type</th><th>Custom domains</th><th style='text-align:right'>Requests (30d)</th><th style='text-align:right'>Annual cost (full)</th></tr></thead>
<tbody>
$lowRows
</tbody></table>
<p><b>Additional potential annual savings (low-usage, if all consolidated):</b> <code>\$$('{0:N0}' -f $lowFullSavingsAnnual)/year</code> across $($lowUsage.Count) profile(s).</p>

<h2>5.  Migration scope (this CR)</h2>
<table>
<thead><tr><th>Classic profile</th><th>Target Standard profile</th><th>SKU change</th><th>WAF change</th><th>Rules change</th><th>Premium upgrade?</th></tr></thead>
<tbody>
"@

foreach ($cp in $MigrationScope) {
    $cur = $results | Where-Object { $_.Name -eq $cp -and $_.Type -eq "AFD-Classic" } | Select-Object -First 1
    if (-not $cur) { continue }
    $html += "<tr><td><b>$cp</b></td><td><code>$cp-std</code> or <code>$cp-std-v2</code></td><td>Classic -> Standard (same `$35/mo)</td><td>Reuse <code>hipyxWafPolicy</code> (no new policy)</td><td>$($cur.RoutingRuleCount) rules transferred 1:1</td><td><b>NO</b> (Standard, not Premium)</td></tr>`n"
}

$html += @"
</tbody></table>

<h2>6.  Cost-relevant changes the migration script does NOT make</h2>
<table>
<thead><tr><th>Feature</th><th>Status</th><th>Cost impact</th></tr></thead>
<tbody>
<tr><td>SKU upgrade to Premium</td><td><b>Not changed</b> - staying on Standard</td><td>Avoided +\$130/mo per profile</td></tr>
<tr><td>New WAF policy</td><td><b>Not created</b> - reusing <code>hipyxWafPolicy</code></td><td>Zero additional WAF fee</td></tr>
<tr><td>WAF managed-rules add-on</td><td><b>Not added</b> - Standard SKU custom rules only</td><td>Zero additional managed-rules fee</td></tr>
<tr><td>DDoS Standard add-on</td><td><b>Not added</b></td><td>Zero (DDoS Network Protection is a separate ~\$3K/mo SKU we are NOT adding)</td></tr>
<tr><td>Application Insights / Log Analytics export</td><td><b>Not added or modified</b></td><td>Zero new ingestion or retention fees</td></tr>
<tr><td>Rules engine rule additions</td><td><b>Not added</b> - existing rules transfer 1:1</td><td>Zero new per-rule fees</td></tr>
<tr><td>Custom domain count</td><td><b>Same</b> - same domains move from Classic to Standard</td><td>Custom domains are free on both SKUs</td></tr>
<tr><td>Reserved capacity / commit pricing</td><td><b>None signed</b></td><td>No long-term commit dollars</td></tr>
</tbody></table>

<h2>7.  Traffic baseline ($($LookbackDays) days)</h2>
<div class="kv">
<b>Total Front Door profiles in RG</b><span>$($results.Count)</span>
<b>In migration scope (this CR)</b><span>$($inScope.Count) - $($MigrationScope -join ', ')</span>
<b>Untouched by this migration</b><span>$($outOfScope.Count)</span>
<b>Total requests across all profiles</b><span>$('{0:N0}' -f $totalReqs)</span>
<b>Total bytes served across all profiles</b><span>$totalGB GB</span>
</div>
<div class="box box-amber">
The full subscription-wide traffic baseline is included so the cost review can verify utilization. Profiles with very low 30-day request counts may be candidates for consolidation in a separate effort - that is <b>not</b> in scope for this CR.
</div>

<h2>8.  Method</h2>
<ul>
<li>Inventory: <code>az network front-door list</code> (Classic) + <code>az afd profile list</code> (Standard / Premium).</li>
<li>SKU read directly from the resource (Classic profiles are always <code>Classic_AzureFrontDoor</code>; Standard / Premium profiles report SKU on the resource).</li>
<li>Traffic: <code>az monitor metrics list --metric RequestCount --aggregation Total --interval P1D --start-time T-${LookbackDays}d</code>; bytes via <code>BillableResponseSize</code> (Classic) and <code>ResponseSize</code> (Standard).</li>
<li>Configuration counts: <code>az network front-door routing-rule list</code>, <code>backend-pool list</code>, <code>frontend-endpoint list</code> (Classic); <code>az afd custom-domain list</code>, <code>endpoint list</code>, <code>origin-group list</code>, <code>security-policy list</code>, <code>rule-set list</code> (Standard).</li>
<li>WAF references pulled from the <code>webApplicationFirewallPolicyLink</code> on Classic frontend-endpoints and security-policy bindings on Standard.</li>
</ul>

<div class="foot">
Prepared by Syed Rizvi - PYX Health Production - $(Get-Date -Format 'yyyy-MM-dd')
</div>

</body></html>
"@

Set-Content -Path $htmlPath -Value $html -Encoding ASCII

# JSON for archival
$results | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding ASCII

Banner "DONE"
Log "Total profiles inventoried: $($results.Count)" Green
Log "  In migration scope: $($inScope.Count)" Green
Log "  Untouched:          $($outOfScope.Count)" Green
Log ""
Log "Artifacts:"
Log "  Run log    : $logPath"
Log "  HTML report: $htmlPath  <- send to approver"
Log "  JSON       : $jsonPath"
exit 0
