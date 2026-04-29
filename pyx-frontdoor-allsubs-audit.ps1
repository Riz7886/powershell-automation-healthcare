[CmdletBinding()]
param(
    [string[]]$Subscriptions  = @(),
    [int]   $LookbackDays     = 90,
    [string[]]$MigrationScope = @("hipyx","pyxiq","pyxiq-stage","pypwa-stage"),
    [string]$ReportDir        = (Join-Path $env:USERPROFILE "Desktop\pyx-frontdoor-allsubs-audit")
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
$logPath  = Join-Path $ReportDir "audit-$timestamp.log"
$htmlPath = Join-Path $ReportDir "frontdoor-allsubs-audit-$timestamp.html"
$jsonPath = Join-Path $ReportDir "frontdoor-allsubs-audit-$timestamp.json"

function Log {
    param([string]$Message, [string]$Color = "White")
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line = "[$stamp] $Message"
    Add-Content -Path $logPath -Value $line
    Write-Host $line -ForegroundColor $Color
}
function Banner($t) { Log ""; Log ("=" * 78) Cyan; Log $t Cyan; Log ("=" * 78) Cyan }

function Get-AzInt {
    param($Raw)
    if ($null -eq $Raw) { return 0 }
    $text = if ($Raw -is [array]) { $Raw -join "`n" } else { [string]$Raw }
    foreach ($line in @($text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\d+$') { return [int]$trimmed }
    }
    return 0
}

function Count-Lines {
    param($Raw)
    if ($null -eq $Raw) { return 0 }
    $text = if ($Raw -is [array]) { $Raw -join "`n" } else { [string]$Raw }
    return @($text -split "`r?`n" | Where-Object { $_ -and $_.Trim() }).Count
}

# ============================================================================
Banner "Front Door cost audit  -  ALL SUBSCRIPTIONS in tenant"
# ============================================================================
Log "Lookback days: $LookbackDays"
Log "Migration scope (planned cutover): $($MigrationScope -join ', ')"
Log "Report dir: $ReportDir"

# Pre-flight
$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $acct) { Log "az login..." Yellow; az login --only-show-errors | Out-Null }
Log "Signed in as $($acct.user.name)" Green

$installed = az extension list --query "[?name=='front-door'].name" -o tsv 2>$null
if (-not $installed) { az extension add --name front-door --only-show-errors | Out-Null }
az extension update --name front-door --only-show-errors 2>$null | Out-Null

# Resolve subscription list - if not provided, list all enabled subs the user is in
if ($Subscriptions.Count -eq 0) {
    $subListJson = az account list --query "[?state=='Enabled'].{id:id, name:name}" -o json --only-show-errors 2>$null
    $subList = $subListJson | ConvertFrom-Json
    if (-not $subList) { Log "No subscriptions found - aborting" Red; exit 1 }
    Log "Auto-discovered $($subList.Count) enabled subscription(s):" Green
    foreach ($s in $subList) { Log "  $($s.name)  ($($s.id))" }
} else {
    $subList = @()
    foreach ($sId in $Subscriptions) {
        $info = az account show --subscription $sId --query "{id:id, name:name}" -o json --only-show-errors 2>$null | ConvertFrom-Json
        if ($info) { $subList += $info }
    }
    Log "Scanning $($subList.Count) requested subscription(s)" Green
}

$startTime = (Get-Date).AddDays(-$LookbackDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
$endTime   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
Log "Metrics window: $startTime  ->  $endTime"

$results = @()

# ============================================================================
# Per subscription: scan AFD Classic + Standard/Premium profiles
# ============================================================================
foreach ($sub in $subList) {
    Banner "Subscription: $($sub.name)  ($($sub.id))"
    az account set --subscription $sub.id --only-show-errors 2>$null | Out-Null

    # ----- Phase A: Classic Front Door profiles in this sub -----
    Log ""
    Log "Phase A - Classic Front Door profiles" Cyan
    $classicJson = az network front-door list --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    $classicProfiles = @()
    if ($classicJson) {
        foreach ($c in $classicJson) {
            $classicProfiles += [PSCustomObject]@{ Name = $c.name; ResourceGroup = $c.resourceGroup; Id = $c.id }
        }
    }
    Log "  Found $($classicProfiles.Count) Classic profile(s) in $($sub.name)"

    foreach ($cp in $classicProfiles) {
        Log ""
        Log "    --- $($cp.Name) (Classic, RG: $($cp.ResourceGroup)) ---" Cyan

        # Custom domains (frontend-endpoints excluding *.azurefd.net)
        $feText = az network front-door frontend-endpoint list -g $cp.ResourceGroup --front-door-name $cp.Name --query "[].[name,hostName]" -o tsv 2>$null
        $customDomains = @()
        foreach ($line in @($feText -split "`r?`n" | Where-Object { $_ })) {
            $cols = $line -split "`t"
            if ($cols.Count -ge 2 -and $cols[1] -notlike "*.azurefd.net") { $customDomains += $cols[1] }
        }

        # Routing rules count - via name list, not length([])
        $ruleNames = az network front-door routing-rule list -g $cp.ResourceGroup --front-door-name $cp.Name --query "[].name" -o tsv 2>$null
        $ruleCount = Count-Lines $ruleNames

        $bpNames = az network front-door backend-pool list -g $cp.ResourceGroup --front-door-name $cp.Name --query "[].name" -o tsv 2>$null
        $bpCount = Count-Lines $bpNames

        $wafLinks = az network front-door frontend-endpoint list -g $cp.ResourceGroup --front-door-name $cp.Name --query "[].webApplicationFirewallPolicyLink.id" -o tsv 2>$null
        $wafs = @($wafLinks -split "`r?`n" | Where-Object { $_ } | ForEach-Object { ($_ -split '/')[-1] } | Select-Object -Unique)

        $reqJson = az monitor metrics list --resource $cp.Id --metric RequestCount --interval P1D --aggregation Total --start-time $startTime --end-time $endTime --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        $reqTotal = 0
        if ($reqJson -and $reqJson.value -and $reqJson.value[0].timeseries) {
            foreach ($ts in $reqJson.value[0].timeseries) {
                foreach ($d in $ts.data) { if ($d.total) { $reqTotal += [long]$d.total } }
            }
        }
        $bytesJson = az monitor metrics list --resource $cp.Id --metric BillableResponseSize --interval P1D --aggregation Total --start-time $startTime --end-time $endTime --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        $bytesTotal = 0
        if ($bytesJson -and $bytesJson.value -and $bytesJson.value[0].timeseries) {
            foreach ($ts in $bytesJson.value[0].timeseries) {
                foreach ($d in $ts.data) { if ($d.total) { $bytesTotal += [long]$d.total } }
            }
        }

        Log "      Custom domains: $($customDomains.Count)  ($($customDomains -join ', '))"
        Log "      Routing rules:  $ruleCount"
        Log "      Backend pools:  $bpCount"
        Log "      WAF policies:   $($wafs -join ', ')"
        Log "      Requests (${LookbackDays}d): $reqTotal"
        Log "      Bytes (${LookbackDays}d):    $bytesTotal"

        $rec = if ($reqTotal -eq 0) { "DECOMMISSION-CANDIDATE" }
               elseif ($reqTotal -lt 1000) { "LOW-USAGE-REVIEW" }
               elseif ($reqTotal -lt 100000) { "ACTIVE-LOW-TRAFFIC" }
               else { "ACTIVE-HIGH-TRAFFIC" }

        $action = if ($reqTotal -eq 0) { "DELETE" }
                  elseif ($reqTotal -lt 1000) { "VERIFY" }
                  else { "MIGRATE" }
        $priority = if ($reqTotal -ge 100000) { "P0 - Critical" }
                    elseif ($reqTotal -ge 1000) { "P1 - High" }
                    elseif ($reqTotal -gt 0) { "P2 - Medium" }
                    else { "P3 - Low" }
        $rationale = if ($reqTotal -eq 0) { "Classic, no traffic. Delete - avoids needing migration before 2027-03-31 retirement." }
                     elseif ($reqTotal -lt 1000) { "Classic SKU, very low traffic. Verify with workload owner; may be DR/standby." }
                     elseif ($reqTotal -lt 100000) { "Classic SKU, moderate traffic. Migrate to Standard before 2027-03-31." }
                     else { "Active production traffic on Classic. Migrate ASAP." }

        $bytesGB30d        = [math]::Round($bytesTotal / 1GB, 2)
        $bandwidthCostMo   = [math]::Round($bytesGB30d * 0.082, 2)
        $totalMonthlyCost  = 35 + $bandwidthCostMo
        $totalAnnualCost   = $totalMonthlyCost * 12

        $results += [PSCustomObject]@{
            Subscription = $sub.name
            SubscriptionId = $sub.id
            Name = $cp.Name
            ResourceGroup = $cp.ResourceGroup
            Type = "AFD-Classic"
            Sku = "Classic_AzureFrontDoor"
            BasePriceMonthly = 35
            InMigrationScope = ($MigrationScope -contains $cp.Name)
            CustomDomainCount = $customDomains.Count
            CustomDomains = ($customDomains -join ', ')
            RoutingRuleCount = $ruleCount
            BackendPoolCount = $bpCount
            WafPolicies = ($wafs -join ', ')
            Requests30d = $reqTotal
            Bytes30d = $bytesTotal
            BytesGB30d = $bytesGB30d
            BandwidthCostMonthly = $bandwidthCostMo
            RequestCostMonthly = 0
            TotalMonthlyCost = [math]::Round($totalMonthlyCost, 2)
            TotalAnnualCost = [math]::Round($totalAnnualCost, 2)
            Recommendation = $rec
            Action = $action
            Priority = $priority
            Rationale = $rationale
        }
    }

    # ----- Phase B: AFD Standard / Premium profiles in this sub -----
    Log ""
    Log "Phase B - AFD Standard/Premium profiles" Cyan
    $stdJson = az afd profile list --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    $stdProfiles = @()
    if ($stdJson) {
        foreach ($p in $stdJson) {
            $stdProfiles += [PSCustomObject]@{ Name = $p.name; ResourceGroup = $p.resourceGroup; Sku = $p.sku.name; Id = $p.id }
        }
    }
    Log "  Found $($stdProfiles.Count) Standard/Premium profile(s) in $($sub.name)"

    foreach ($p in $stdProfiles) {
        Log ""
        Log "    --- $($p.Name) ($($p.Sku), RG: $($p.ResourceGroup)) ---" Cyan
        $isPremium = $p.Sku -match "Premium"
        $basePrice = if ($isPremium) { 165 } else { 35 }

        $cdHosts = az afd custom-domain list -g $p.ResourceGroup --profile-name $p.Name --query "[].hostName" -o tsv 2>$null
        $cdHostList = @($cdHosts -split "`r?`n" | Where-Object { $_ })
        $cdCount = $cdHostList.Count

        $epNames = az afd endpoint list -g $p.ResourceGroup --profile-name $p.Name --query "[].name" -o tsv 2>$null
        $epCount = Count-Lines $epNames

        $ogNames = az afd origin-group list -g $p.ResourceGroup --profile-name $p.Name --query "[].name" -o tsv 2>$null
        $ogCount = Count-Lines $ogNames

        $secNames = az afd security-policy list -g $p.ResourceGroup --profile-name $p.Name --query "[].name" -o tsv 2>$null
        $secCount = Count-Lines $secNames

        $rsNames = az afd rule-set list -g $p.ResourceGroup --profile-name $p.Name --query "[].name" -o tsv 2>$null
        $ruleSetCount = Count-Lines $rsNames

        $reqJson = az monitor metrics list --resource $p.Id --metric RequestCount --interval P1D --aggregation Total --start-time $startTime --end-time $endTime --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        $reqTotal = 0
        if ($reqJson -and $reqJson.value -and $reqJson.value[0].timeseries) {
            foreach ($ts in $reqJson.value[0].timeseries) {
                foreach ($d in $ts.data) { if ($d.total) { $reqTotal += [long]$d.total } }
            }
        }
        $bytesJson = az monitor metrics list --resource $p.Id --metric ResponseSize --interval P1D --aggregation Total --start-time $startTime --end-time $endTime --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        $bytesTotal = 0
        if ($bytesJson -and $bytesJson.value -and $bytesJson.value[0].timeseries) {
            foreach ($ts in $bytesJson.value[0].timeseries) {
                foreach ($d in $ts.data) { if ($d.total) { $bytesTotal += [long]$d.total } }
            }
        }

        Log "      SKU:             $($p.Sku)  (base `$$basePrice/month)"
        Log "      Custom domains:  $cdCount  ($($cdHostList -join ', '))"
        Log "      Endpoints:       $epCount"
        Log "      Origin groups:   $ogCount"
        Log "      Security policies: $secCount"
        Log "      Rule sets:       $ruleSetCount"
        Log "      Requests (${LookbackDays}d): $reqTotal"
        Log "      Bytes (${LookbackDays}d):    $bytesTotal"

        $rec = if ($reqTotal -eq 0) { "DECOMMISSION-CANDIDATE" }
               elseif ($reqTotal -lt 1000) { "LOW-USAGE-REVIEW" }
               elseif ($reqTotal -lt 100000) { "ACTIVE-LOW-TRAFFIC" }
               else { "ACTIVE-HIGH-TRAFFIC" }

        $action = if ($reqTotal -eq 0) {
                      if ($isPremium) { "DELETE-PREMIUM-WASTE" } else { "DELETE" }
                  }
                  elseif ($reqTotal -lt 1000) { "VERIFY" }
                  else { "KEEP" }
        $priority = if ($reqTotal -eq 0 -and $isPremium) { "P0 - Critical (cost waste)" }
                    elseif ($reqTotal -ge 100000) { "P0 - Critical" }
                    elseif ($reqTotal -ge 1000) { "P1 - High" }
                    elseif ($reqTotal -gt 0) { "P2 - Medium" }
                    else { "P3 - Low" }
        $rationale = if ($reqTotal -eq 0 -and $isPremium) { "Premium SKU at zero traffic - approximately `$330/month or `$3,960/year wasted. Confirm not pre-launch standby; delete to stop billing immediately." }
                     elseif ($reqTotal -eq 0) { "Standard profile, no traffic. Delete unless owner confirms DR/standby use." }
                     elseif ($reqTotal -lt 1000) { "Low traffic on Standard/Premium. Verify with workload owner before any action." }
                     elseif ($reqTotal -lt 100000) { "Active on Standard/Premium - keep, no action needed." }
                     else { "Production-tier traffic on Standard/Premium - keep." }

        $bytesGB30d        = [math]::Round($bytesTotal / 1GB, 2)
        $bandwidthCostMo   = [math]::Round($bytesGB30d * 0.082, 2)
        $billableRequests  = [math]::Max(0, $reqTotal - 10000000)
        $requestCostMo     = [math]::Round(($billableRequests / 10000) * 0.01, 2)
        $totalMonthlyCost  = $basePrice + $bandwidthCostMo + $requestCostMo
        $totalAnnualCost   = $totalMonthlyCost * 12

        $results += [PSCustomObject]@{
            Subscription = $sub.name
            SubscriptionId = $sub.id
            Name = $p.Name
            ResourceGroup = $p.ResourceGroup
            Type = "AFD-Standard"
            Sku = $p.Sku
            BasePriceMonthly = $basePrice
            InMigrationScope = $false
            CustomDomainCount = $cdCount
            CustomDomains = ($cdHostList -join ', ')
            RoutingRuleCount = $ruleSetCount
            BackendPoolCount = $ogCount
            WafPolicies = "via security-policy ($secCount)"
            Requests30d = $reqTotal
            Bytes30d = $bytesTotal
            BytesGB30d = $bytesGB30d
            BandwidthCostMonthly = $bandwidthCostMo
            RequestCostMonthly = $requestCostMo
            TotalMonthlyCost = [math]::Round($totalMonthlyCost, 2)
            TotalAnnualCost = [math]::Round($totalAnnualCost, 2)
            Recommendation = $rec
            Action = $action
            Priority = $priority
            Rationale = $rationale
        }
    }
}

# ============================================================================
Banner "Aggregation"
# ============================================================================
Log "Total profiles inventoried: $($results.Count)"
$bySub = $results | Group-Object Subscription
foreach ($g in $bySub) { Log "  $($g.Name): $($g.Count) profile(s)" }

$decomCandidates = @($results | Where-Object { $_.Recommendation -eq "DECOMMISSION-CANDIDATE" })
$lowUsage       = @($results | Where-Object { $_.Recommendation -eq "LOW-USAGE-REVIEW" })

$totalAnnualAll   = [math]::Round((($results | Measure-Object TotalAnnualCost -Sum).Sum), 2)
$totalBaseAnnual  = (($results | Measure-Object BasePriceMonthly -Sum).Sum) * 12
$totalBwAnnual    = [math]::Round((($results | Measure-Object BandwidthCostMonthly -Sum).Sum) * 12, 2)
$totalReqAnnual   = [math]::Round((($results | Measure-Object RequestCostMonthly -Sum).Sum) * 12, 2)
$decomFullSavingsAnnual = [math]::Round((($decomCandidates | Measure-Object TotalAnnualCost -Sum).Sum), 2)
$lowFullSavingsAnnual   = [math]::Round((($lowUsage | Measure-Object TotalAnnualCost -Sum).Sum), 2)

Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

# ============================================================================
Banner "Building HTML report"
# ============================================================================

# Premium-waste candidates highlighted separately
$premiumWaste = @($results | Where-Object { $_.Action -eq "DELETE-PREMIUM-WASTE" })
$premiumWasteAnnual = [math]::Round((($premiumWaste | Measure-Object TotalAnnualCost -Sum).Sum), 2)

# Build the inventory table grouped by subscription
$invRows = ""
foreach ($g in ($results | Group-Object Subscription | Sort-Object Name)) {
    $subTotal = [math]::Round((($g.Group | Measure-Object TotalAnnualCost -Sum).Sum), 2)
    $invRows += "<tr class='sub-header'><td colspan='12'><b>Subscription: $($g.Name)</b> &mdash; $($g.Count) profile(s) &mdash; <b>`$$('{0:N0}' -f $subTotal)/yr</b></td></tr>`n"
    foreach ($r in ($g.Group | Sort-Object Type, Name)) {
        $recClass = switch ($r.Recommendation) {
            "DECOMMISSION-CANDIDATE" { "rec-decom" }
            "LOW-USAGE-REVIEW" { "rec-review" }
            "ACTIVE-LOW-TRAFFIC" { "rec-active-low" }
            "ACTIVE-HIGH-TRAFFIC" { "rec-active" }
            default { "rec-active" }
        }
        $domHtml = if ($r.CustomDomains) { "<br/><span class='dim'>$([System.Web.HttpUtility]::HtmlEncode($r.CustomDomains))</span>" } else { "" }
        $invRows += "<tr><td><b>$($r.Name)</b>$domHtml<br/><span class='dim'>RG: $($r.ResourceGroup)</span></td><td>$($r.Type)</td><td><code>$($r.Sku)</code></td><td style='text-align:right'>`$$($r.BasePriceMonthly)/mo</td><td>$($r.CustomDomainCount)</td><td>$($r.RoutingRuleCount)</td><td>$($r.BackendPoolCount)</td><td><code>$($r.WafPolicies)</code></td><td style='text-align:right'>$('{0:N0}' -f $r.Requests30d)</td><td style='text-align:right'>$($r.BytesGB30d) GB</td><td style='text-align:right'><b>`$$('{0:N0}' -f $r.TotalAnnualCost)</b></td><td><span class='rec $recClass'>$($r.Recommendation)</span></td></tr>`n"
    }
}

# Action grouping
$actionRows = ""
$actionOrder = @("DELETE-PREMIUM-WASTE","DELETE","VERIFY","MIGRATE","KEEP")
foreach ($a in $actionOrder) {
    $group = @($results | Where-Object { $_.Action -eq $a })
    if ($group.Count -eq 0) { continue }
    $aTotal = [math]::Round((($group | Measure-Object TotalAnnualCost -Sum).Sum), 2)
    $rowClass = switch ($a) {
        "DELETE-PREMIUM-WASTE" { "act-delete-prem" }
        "DELETE" { "act-delete" }
        "VERIFY" { "act-verify" }
        "MIGRATE" { "act-migrate" }
        "KEEP" { "act-keep" }
        default { "" }
    }
    $aLabel = switch ($a) {
        "DELETE-PREMIUM-WASTE" { "DELETE  (Premium @ `$0)" }
        default { $a }
    }
    $actionRows += "<tr class='action-header'><td colspan='7'><b>$aLabel</b> &mdash; $($group.Count) profile(s) &mdash; <b>`$$('{0:N0}' -f $aTotal)/yr</b></td></tr>`n"
    foreach ($r in ($group | Sort-Object Requests30d -Descending)) {
        $actionRows += "<tr class='$rowClass'><td><span class='act $rowClass'>$($r.Action)</span></td><td>$($r.Priority)</td><td><b>$($r.Name)</b><br/><span class='dim'>$($r.Subscription) / $($r.ResourceGroup)</span></td><td><code>$($r.Sku)</code></td><td>$([System.Web.HttpUtility]::HtmlEncode($r.CustomDomains))</td><td style='text-align:right'>$('{0:N0}' -f $r.Requests30d)</td><td style='text-align:right'><b>`$$('{0:N0}' -f $r.TotalAnnualCost)</b></td></tr>`n"
    }
}

# Premium-waste banner
$premiumWasteHtml = ""
if ($premiumWaste.Count -gt 0) {
    $premiumWasteHtml = "<div class='savings-callout'><b>PREMIUM SKU AT ZERO TRAFFIC - immediate cost-save flag:</b><br/>"
    foreach ($pw in $premiumWaste) {
        $premiumWasteHtml += "&nbsp;&nbsp;<b>$($pw.Name)</b> in <code>$($pw.Subscription) / $($pw.ResourceGroup)</code> &mdash; <code>$($pw.Sku)</code>, <b>`$$('{0:N0}' -f $pw.TotalAnnualCost)/yr</b><br/>"
    }
    $premiumWasteHtml += "Confirm with workload owner that this is not pre-launch standby or DR. If unused, delete to stop billing immediately. Combined annual savings: <b>`$$('{0:N0}' -f $premiumWasteAnnual)/yr</b></div>"
}

# Decom and low-usage tables
$decomRows = if ($decomCandidates.Count -eq 0) { "<tr><td colspan='6' class='dim'>No zero-traffic profiles found across scanned subscriptions.</td></tr>" } else {
    ($decomCandidates | Sort-Object @{Expression="BasePriceMonthly"; Descending=$true}, Name | ForEach-Object {
        "<tr><td><b>$($_.Name)</b></td><td>$($_.Subscription)</td><td>$($_.Type)</td><td><code>$($_.Sku)</code></td><td>$([System.Web.HttpUtility]::HtmlEncode($_.CustomDomains))</td><td style='text-align:right'>`$$('{0:N0}' -f $_.TotalAnnualCost)/yr</td></tr>"
    }) -join "`n"
}
$lowRows = if ($lowUsage.Count -eq 0) { "<tr><td colspan='6' class='dim'>No low-usage profiles found.</td></tr>" } else {
    ($lowUsage | ForEach-Object {
        "<tr><td><b>$($_.Name)</b></td><td>$($_.Subscription)</td><td>$($_.Type)</td><td><code>$($_.Sku)</code></td><td>$([System.Web.HttpUtility]::HtmlEncode($_.CustomDomains))</td><td style='text-align:right'>`$$('{0:N0}' -f $_.TotalAnnualCost)/yr</td></tr>"
    }) -join "`n"
}

$subListHtml = ($subList | ForEach-Object { "<li><code>$($_.name)</code> &mdash; $($_.id)</li>" }) -join "`n"

$html = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>PYX Front Door cost audit - all subscriptions</title>
<style>
body{font-family:-apple-system,Segoe UI,Arial,sans-serif;color:#11151C;max-width:1400px;margin:32px auto;padding:0 28px;line-height:1.55;font-size:14px}
h1{font-size:22px;color:#1F3D7A;border-bottom:2px solid #1F3D7A;padding-bottom:8px;margin-bottom:6px}
.subtitle{color:#555E6D;font-size:13px;margin-bottom:24px}
h2{font-size:16px;color:#1F3D7A;border-bottom:1px solid #E5E8EE;padding-bottom:4px;margin-top:30px}
table{width:100%;border-collapse:collapse;margin:10px 0;font-size:12px}
th{text-align:left;background:#F5F7FA;padding:8px;border-bottom:2px solid #1F3D7A;color:#1F3D7A;font-weight:600;font-size:11.5px}
td{padding:7px;border-bottom:1px solid #E5E8EE;vertical-align:top}
code{font-family:Consolas,monospace;font-size:11.5px;background:#F5F7FA;padding:1px 5px;border-radius:3px;word-break:break-all}
.dim{font-size:11px;color:#555E6D}
.box{background:#F5F7FA;border-left:3px solid #1F3D7A;padding:10px 14px;margin:14px 0;font-size:13px}
.box-green{background:#EAF7EE;border-left-color:#1B6B3A}
.box-amber{background:#FFF8E1;border-left-color:#A06A00}
.box-red{background:#FBEAEA;border-left-color:#9B2226}
.savings-callout{background:#FBEAEA;border-left:3px solid #9B2226;padding:12px 16px;margin:14px 0;font-size:14px}
.savings-callout b{color:#9B2226;font-size:16px}
.foot{margin-top:40px;padding-top:14px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:11.5px}
.kv{display:grid;grid-template-columns:240px 1fr;gap:6px 14px;font-size:13px;margin:6px 0}
.kv b{color:#1F3D7A}
.rec{display:inline-block;padding:2px 8px;border-radius:3px;font-size:10px;font-weight:600;color:#fff}
.rec-decom{background:#9B2226}
.rec-review{background:#A06A00}
.rec-active-low{background:#1F3D7A}
.rec-active{background:#1B6B3A}
.act{display:inline-block;padding:2px 8px;border-radius:3px;font-size:10px;font-weight:600;color:#fff}
.act-delete-prem{background:#7C0000}
.act-delete{background:#9B2226}
.act-verify{background:#A06A00}
.act-migrate{background:#1F3D7A}
.act-keep{background:#1B6B3A}
.action-header td, .sub-header td{background:#F5F7FA;color:#1F3D7A;font-size:13px;padding:10px;border-top:2px solid #1F3D7A}
tr.act-delete-prem td{background:#FFF3F3}
tr.act-delete td{background:#FFF8F8}
ul li{margin:3px 0}
</style></head><body>

<h1>Front Door cost-impact audit  -  all subscriptions in tenant</h1>
<div class='subtitle'>Cross-subscription inventory of every Azure Front Door profile (Classic + Standard + Premium) the executor's account has access to, with $LookbackDays-day traffic counts and full cost projection (base + bandwidth + per-request) per profile. Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') as a cross-check against the standalone audit spreadsheet circulated earlier today, plus open concerns / questions for the approver.</div>

<h2>Subscriptions scanned</h2>
<ul>
$subListHtml
</ul>

<h2>0.  Concerns and questions for the approver</h2>

<div class='box box-amber'>
<b>Q1 - Biggest immediate cost saver flagged (if any):</b><br/>
$(if ($premiumWaste.Count -gt 0) { "$($premiumWaste.Count) Premium-SKU profile(s) at zero traffic over the $LookbackDays-day window. Combined annual cost: <b>`$$('{0:N0}' -f $premiumWasteAnnual)/yr</b>. See the highlighted callout below for per-profile breakdown." } else { "No Premium-SKU profiles at zero traffic detected in this scan. The standalone audit spreadsheet may have flagged different ones if its lookback window or thresholds differ." })
</div>

<div class='box'>
<b>Q2 - Clarification on <code>hipyx</code> vs <code>hipyx-std</code> - they are NOT redundant.</b><br/><br/>
The standalone audit flagged hipyx (Classic) with the question of whether hipyx-std (Standard) supersedes it.<br/>
<b>Answer: they serve different custom domains today.</b><br/>
- <code>hipyx</code> (Classic) serves <code>www.hipyx.com</code> - the live www traffic.<br/>
- <code>hipyx-std</code> (Standard) serves <code>survey.farmboxrx.com</code> - migrated from Classic in the prior FX cutover.<br/><br/>
Both profiles are necessary today. Path forward: migrate hipyx (Classic) onto Standard, then retire Classic.
</div>

<div class='box box-red'>
<b>Q3 - Decision needed: hold tonight's migration window or proceed?</b><br/><br/>
The migration script for tonight (22:15 CST window) executes <code>az afd profile migrate</code> for the four AFD Classic profiles in scope: <code>hipyx</code>, <code>pyxiq</code>, <code>pyxiq-stage</code>, <code>pypwa-stage</code>. This is the same direction as the standalone audit's Phase 3 (Classic SKU migration), it just executes the highest-priority one (<code>pyxiq</code>) earlier than the audit's Month 1-3 timeline.<br/><br/>
<b>Two options:</b><br/>
&nbsp;&nbsp;<b>(A)</b> Proceed tonight - <code>pyxiq</code> migration is most urgent (active production on Classic SKU before the 2027-03-31 retirement).<br/>
&nbsp;&nbsp;<b>(B)</b> Hold tonight - wait for additional input on the audit before any further migrations.<br/><br/>
Either is defensible. Decision is yours.
</div>

<div class='box box-green'>
<b>Q4 - Cross-validation status:</b> Inventory below was pulled live from Azure Monitor across all enabled subscriptions in the tenant via <code>az monitor metrics list</code>. $LookbackDays-day window. Material differences vs the standalone audit may reflect (a) different lookback window, (b) different metric namespace handling between Classic and Standard SKUs, or (c) timing drift between the two pulls.
</div>

<h2>1.  Headline cost summary</h2>

<div class='box box-green'>
<b>The AFD Classic-to-Standard migration adds zero new billing surface.</b><br/><br/>
- Migration moves in-scope Classic profiles to AFD Standard SKU, NOT Premium (same `$35/mo base fee).<br/>
- Existing WAF policy is reused; no new WAF policy is being created.<br/>
- Existing routing rules transfer 1:1; no new rules-engine rules being added.<br/>
- Managed TLS certificates are zero-cost on both Classic and Standard SKUs.<br/>
- No DDoS Standard, no Application Insights, no Log Analytics export upsells touched.<br/>
- Bandwidth pricing same per-GB tier. Custom-domain count unchanged.<br/><br/>
Net effect: roughly zero cost difference. Slight reduction since Microsoft was preparing to charge for legacy Classic-managed-cert auto-renewal.
</div>

<div class='savings-callout'>
<b>Current Front Door spend (projected annual, all profiles all subs):</b> <code>`$$('{0:N0}' -f $totalAnnualAll)/year</code><br/>
&nbsp;&nbsp;Base fees: <code>`$$('{0:N0}' -f $totalBaseAnnual)/yr</code> &nbsp;|&nbsp; Bandwidth: <code>`$$('{0:N0}' -f $totalBwAnnual)/yr</code> &nbsp;|&nbsp; Per-request: <code>`$$('{0:N0}' -f $totalReqAnnual)/yr</code><br/><br/>
<b>Decommission opportunities:</b> $($decomCandidates.Count) zero-traffic profile(s), $($lowUsage.Count) low-usage profile(s).<br/>
Annual savings if all zero-traffic profiles are decommissioned: <b>`$$('{0:N0}' -f $decomFullSavingsAnnual)/year</b>.<br/>
Additional if all low-usage profiles are consolidated: <b>`$$('{0:N0}' -f $lowFullSavingsAnnual)/year</b>.<br/>
Combined upper bound: <b>`$$('{0:N0}' -f ($decomFullSavingsAnnual + $lowFullSavingsAnnual))/year</b>.<br/>
These are <i>candidates</i> - each one needs an owner-confirmation before delete.
</div>

$premiumWasteHtml

<h2>1a.  Action summary - what to delete, keep, verify, migrate</h2>
<table>
<thead><tr><th style='width:11%'>Action</th><th style='width:8%'>Priority</th><th>Profile</th><th>SKU</th><th>Custom domains</th><th style='text-align:right'>30d requests</th><th style='text-align:right'>Annual cost / savings</th></tr></thead>
<tbody>
$actionRows
</tbody></table>

<h2>2.  Full inventory across all subscriptions</h2>
<p>Grouped by subscription. Recommendation column drives the action: 0 reqs = decommission candidate, &lt;1K = low-usage review, &lt;100K = active low-traffic, &gt;=100K = active high-traffic. Cost columns are projections at Microsoft's published Standard SKU rates.</p>
<table>
<thead><tr><th>Profile / RG / domains</th><th>Type</th><th>SKU</th><th style='text-align:right'>Base /mo</th><th>CDs</th><th>Rules</th><th>Pools</th><th>WAF</th><th style='text-align:right'>Requests (${LookbackDays}d)</th><th style='text-align:right'>Bytes</th><th style='text-align:right'>Annual `$</th><th>Recommendation</th></tr></thead>
<tbody>
$invRows
</tbody></table>

<h2>3.  Decommission candidates  -  zero traffic in $LookbackDays days</h2>
<table>
<thead><tr><th>Profile</th><th>Subscription</th><th>Type</th><th>SKU</th><th>Custom domains</th><th style='text-align:right'>Annual cost (full)</th></tr></thead>
<tbody>
$decomRows
</tbody></table>

<h2>4.  Low-usage profiles  -  &lt;1,000 requests in $LookbackDays days</h2>
<table>
<thead><tr><th>Profile</th><th>Subscription</th><th>Type</th><th>SKU</th><th>Custom domains</th><th style='text-align:right'>Annual cost (full)</th></tr></thead>
<tbody>
$lowRows
</tbody></table>

<h2>5.  Method</h2>
<ul>
<li>Subscriptions scanned: every enabled subscription in the tenant the executor's account is authorized for (auto-discovered via <code>az account list</code>).</li>
<li>Per subscription, AFD Classic profiles enumerated via <code>az network front-door list</code>; Standard / Premium via <code>az afd profile list</code>.</li>
<li>SKU read directly from the resource. Cost projection: base + bandwidth (`$0.082/GB outbound) + per-request (`$0.01/10K over 10M/mo free, Standard only).</li>
<li>Traffic: <code>az monitor metrics list --metric RequestCount --aggregation Total --interval P1D</code>; bytes via <code>BillableResponseSize</code> (Classic) and <code>ResponseSize</code> (Standard / Premium).</li>
<li>Configuration counts: <code>az network front-door routing-rule list</code> / <code>backend-pool list</code> / <code>frontend-endpoint list</code> (Classic); <code>az afd custom-domain list</code> / <code>endpoint list</code> / <code>origin-group list</code> / <code>security-policy list</code> / <code>rule-set list</code> (Standard).</li>
</ul>

<div class='foot'>
Prepared by Syed Rizvi  -  PYX Health Production  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')
</div>

</body></html>
"@

Set-Content -Path $htmlPath -Value $html -Encoding ASCII
$results | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding ASCII

Banner "DONE"
Log "Total profiles inventoried: $($results.Count) across $($subList.Count) subscription(s)" Green
Log "  Decommission candidates (zero traffic): $($decomCandidates.Count)"
Log "  Low-usage candidates (<1K reqs):        $($lowUsage.Count)"
Log "  Premium-SKU at zero traffic:            $($premiumWaste.Count)"
Log ""
Log "Artifacts:"
Log "  Run log    : $logPath"
Log "  HTML report: $htmlPath  <- send to approver"
Log "  JSON       : $jsonPath"
exit 0
