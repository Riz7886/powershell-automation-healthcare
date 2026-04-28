[CmdletBinding()]
param(
    [string]$SubscriptionId   = "e42e94b5-c6f8-4af0-a41b-16fda520de6e",
    [string]$ResourceGroup    = "production",
    [string]$ClassicProfile   = "hipyx",
    [string]$StandardProfile  = "hipyx-std",
    [string]$WafPolicyName    = "hipyxWafPolicy",
    [switch]$DryRun,
    [string]$ReportDir        = (Join-Path $env:USERPROFILE "Desktop\hipyx-migrate-all-report")
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")

if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
$logPath  = Join-Path $ReportDir "run-$timestamp.log"
$dnsPath  = Join-Path $ReportDir "dns-handoff-$timestamp.txt"
$csvPath  = Join-Path $ReportDir "dns-handoff-$timestamp.csv"
$htmlPath = Join-Path $ReportDir "summary-$timestamp.html"

function Log {
    param([string]$Message, [string]$Level = "INFO")
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line = "[$stamp] [$Level] $Message"
    Add-Content -Path $logPath -Value $line
    $color = switch ($Level) { "OK" {"Green"} "WARN" {"Yellow"} "ERR" {"Red"} "STEP" {"Cyan"} default {"White"} }
    Write-Host $line -ForegroundColor $color
}

function Step($title) {
    Log ""
    Log ("=" * 78)
    Log $title "STEP"
    Log ("=" * 78)
}

function Has-Cmd($name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# ----------------------------------------------------------------------------
Step "Phase 0 - Pre-flight"
# ----------------------------------------------------------------------------
if (-not (Has-Cmd az)) { Log "Azure CLI not installed - aborting" "ERR"; exit 1 }
Log "Azure CLI found" "OK"

# Login + subscription
$acct = $null
try { $acct = az account show --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
if (-not $acct) {
    Log "Not signed in to Azure - launching az login" "WARN"
    az login --only-show-errors | Out-Null
}
az account set --subscription $SubscriptionId --only-show-errors | Out-Null
$current = az account show --query "{Name:name, Id:id, User:user.name}" -o json | ConvertFrom-Json
Log "Subscription: $($current.Name) ($($current.Id))" "OK"
Log "User: $($current.User)" "OK"

# Front-door extension
$installed = az extension list --query "[?name=='front-door'].name" -o tsv 2>$null
if (-not $installed) {
    Log "Installing front-door CLI extension" "WARN"
    az extension add --name front-door --only-show-errors | Out-Null
}
az extension update --name front-door --only-show-errors 2>$null | Out-Null
Log "front-door extension ready" "OK"

# ----------------------------------------------------------------------------
Step "Phase 1 - Inventory Classic hipyx custom domains"
# ----------------------------------------------------------------------------
$classicEndpointsJson = az network front-door frontend-endpoint list --resource-group $ResourceGroup --front-door-name $ClassicProfile -o json 2>$null
if (-not $classicEndpointsJson) { Log "Could not enumerate Classic profile - aborting" "ERR"; exit 2 }
$classicEndpoints = $classicEndpointsJson | ConvertFrom-Json

$customEndpoints = $classicEndpoints | Where-Object { $_.hostName -and $_.hostName -notlike "*.azurefd.net" }
Log ("Found {0} frontend endpoints on Classic ({1} custom domains, {2} default azurefd.net)" -f $classicEndpoints.Count, $customEndpoints.Count, ($classicEndpoints.Count - $customEndpoints.Count)) "OK"

if ($customEndpoints.Count -eq 0) {
    Log "No custom domains on Classic to migrate. Classic can be deprovisioned after the 14-day rollback window." "OK"
    exit 0
}

foreach ($e in $customEndpoints) {
    Log ("  Classic custom domain: {0}  (cert state: {1})" -f $e.hostName, $e.customHttpsProvisioningState)
}

# ----------------------------------------------------------------------------
Step "Phase 2 - Inventory existing Standard hipyx-std domains (to skip duplicates)"
# ----------------------------------------------------------------------------
$standardDomainsJson = az afd custom-domain list --resource-group $ResourceGroup --profile-name $StandardProfile -o json 2>$null
$standardDomains = if ($standardDomainsJson) { $standardDomainsJson | ConvertFrom-Json } else { @() }
$standardHostnames = @{}
foreach ($d in $standardDomains) {
    if ($d.hostName) { $standardHostnames[$d.hostName.ToLower()] = $d }
}
Log ("Standard profile already has {0} custom domain(s)" -f $standardDomains.Count) "OK"

# ----------------------------------------------------------------------------
Step "Phase 3 - Build migration plan"
# ----------------------------------------------------------------------------
$plan = @()
foreach ($e in $customEndpoints) {
    $hostName = $e.hostName
    $alreadyOnStd = $standardHostnames.ContainsKey($hostName.ToLower())
    $safeName = ($hostName -replace '\.', '-').ToLower()
    $endpointName = "pyx-fx-$safeName-ep"
    $plan += [PSCustomObject]@{
        Hostname     = $hostName
        SafeName     = $safeName
        EndpointName = $endpointName
        Action       = if ($alreadyOnStd) { "skip-already-on-standard" } else { "migrate" }
        ClassicCert  = $e.customHttpsProvisioningState
    }
}
$plan | Format-Table -AutoSize | Out-String | ForEach-Object { Log $_ }
$planPath = Join-Path $ReportDir "plan-$timestamp.json"
$plan | ConvertTo-Json -Depth 5 | Out-File -FilePath $planPath -Encoding UTF8
Log "Plan saved: $planPath" "OK"

if ($DryRun) {
    Log "DryRun mode - stopping before any changes are made" "WARN"
    exit 0
}

# ----------------------------------------------------------------------------
Step "Phase 4 - Verify WAF policy exists on Standard"
# ----------------------------------------------------------------------------
$wafCheck = az afd profile show --resource-group $ResourceGroup --profile-name $StandardProfile -o json 2>$null
if (-not $wafCheck) { Log "Standard profile $StandardProfile not found - aborting" "ERR"; exit 3 }
Log "Standard profile $StandardProfile is present" "OK"

$wafExists = az network front-door waf-policy show --resource-group $ResourceGroup --name $WafPolicyName --query id -o tsv 2>$null
if (-not $wafExists) {
    Log "WAF policy $WafPolicyName not found - creating in Detection mode" "WARN"
    az network front-door waf-policy create --resource-group $ResourceGroup --name $WafPolicyName --mode Detection --sku Standard_AzureFrontDoor --only-show-errors | Out-Null
} else {
    Log "WAF policy $WafPolicyName already exists" "OK"
}

# ----------------------------------------------------------------------------
Step "Phase 5 - Migrate each Classic custom domain to Standard"
# ----------------------------------------------------------------------------
$dnsRecords = @()
$migrated = 0
$skipped = 0
$failed = 0

foreach ($p in $plan) {
    Log ""
    Log ("--- {0} ---" -f $p.Hostname) "STEP"

    if ($p.Action -eq "skip-already-on-standard") {
        Log "Already on Standard - skipping" "OK"
        $skipped++
        continue
    }

    # Endpoint
    $epExists = az afd endpoint show --resource-group $ResourceGroup --profile-name $StandardProfile --endpoint-name $p.EndpointName --query id -o tsv 2>$null
    if (-not $epExists) {
        Log "Creating endpoint $($p.EndpointName)" "INFO"
        az afd endpoint create --resource-group $ResourceGroup --profile-name $StandardProfile --endpoint-name $p.EndpointName --enabled-state Enabled --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { Log "Endpoint creation failed for $($p.Hostname)" "ERR"; $failed++; continue }
    } else {
        Log "Endpoint $($p.EndpointName) already exists" "OK"
    }

    # Custom domain
    $cdExists = az afd custom-domain show --resource-group $ResourceGroup --profile-name $StandardProfile --custom-domain-name $p.SafeName --query id -o tsv 2>$null
    if (-not $cdExists) {
        Log "Creating custom domain $($p.SafeName) -> $($p.Hostname)" "INFO"
        az afd custom-domain create --resource-group $ResourceGroup --profile-name $StandardProfile --custom-domain-name $p.SafeName --host-name $p.Hostname --certificate-type ManagedCertificate --minimum-tls-version TLS12 --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { Log "Custom domain creation failed for $($p.Hostname)" "ERR"; $failed++; continue }
    } else {
        Log "Custom domain $($p.SafeName) already exists" "OK"
    }

    # Read TXT token + CNAME target
    Start-Sleep -Seconds 3
    $txt = az afd custom-domain show --resource-group $ResourceGroup --profile-name $StandardProfile --custom-domain-name $p.SafeName --query "validationProperties.validationToken" -o tsv 2>$null
    $cname = az afd endpoint show --resource-group $ResourceGroup --profile-name $StandardProfile --endpoint-name $p.EndpointName --query hostName -o tsv 2>$null

    if (-not $txt -or -not $cname) {
        Log "Could not read TXT or CNAME for $($p.Hostname) - retrying in 10s" "WARN"
        Start-Sleep -Seconds 10
        $txt = az afd custom-domain show --resource-group $ResourceGroup --profile-name $StandardProfile --custom-domain-name $p.SafeName --query "validationProperties.validationToken" -o tsv 2>$null
        $cname = az afd endpoint show --resource-group $ResourceGroup --profile-name $StandardProfile --endpoint-name $p.EndpointName --query hostName -o tsv 2>$null
    }

    # Security policy (bind WAF to this domain)
    $secPolicyName = "fx-$($p.SafeName)-waf"
    $spExists = az afd security-policy show --resource-group $ResourceGroup --profile-name $StandardProfile --security-policy-name $secPolicyName --query id -o tsv 2>$null
    if (-not $spExists) {
        $wafId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/$WafPolicyName"
        $domId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Cdn/profiles/$StandardProfile/customDomains/$($p.SafeName)"
        Log "Binding WAF security policy $secPolicyName" "INFO"
        az afd security-policy create --resource-group $ResourceGroup --profile-name $StandardProfile --security-policy-name $secPolicyName --waf-policy $wafId --domains $domId --only-show-errors | Out-Null
    } else {
        Log "Security policy $secPolicyName already bound" "OK"
    }

    # Aggregate DNS handoff
    $hostShort = $p.Hostname.Split('.')[0]
    $zone = ($p.Hostname.Split('.')[1..($p.Hostname.Split('.').Length - 1)]) -join '.'
    $dnsRecords += [PSCustomObject]@{
        Hostname     = $p.Hostname
        Zone         = $zone
        TxtHost      = "_dnsauth.$hostShort"
        TxtValue     = $txt
        CnameHost    = $hostShort
        CnameValue   = $cname
        Ttl          = 300
    }

    Log "Migrated $($p.Hostname)" "OK"
    $migrated++
}

# ----------------------------------------------------------------------------
Step "Phase 6 - Generate DNS handoff package"
# ----------------------------------------------------------------------------
$dnsLines = @()
$dnsLines += "DNS handoff package - generated $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"
$dnsLines += ("=" * 78)
$dnsLines += ""
foreach ($r in $dnsRecords) {
    $dnsLines += "Domain: $($r.Hostname)  (zone: $($r.Zone))"
    $dnsLines += "  Step 1 - publish TXT first:"
    $dnsLines += "    Host  : $($r.TxtHost)"
    $dnsLines += "    Type  : TXT"
    $dnsLines += "    Value : $($r.TxtValue)"
    $dnsLines += "    TTL   : $($r.Ttl)"
    $dnsLines += ""
    $dnsLines += "  Step 2 - after cert is Approved, publish CNAME:"
    $dnsLines += "    Host  : $($r.CnameHost)"
    $dnsLines += "    Type  : CNAME"
    $dnsLines += "    Value : $($r.CnameValue)"
    $dnsLines += "    TTL   : $($r.Ttl)"
    $dnsLines += ""
    $dnsLines += ("-" * 78)
    $dnsLines += ""
}
Set-Content -Path $dnsPath -Value $dnsLines -Encoding UTF8
$dnsRecords | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Log "DNS handoff text: $dnsPath" "OK"
Log "DNS handoff CSV : $csvPath" "OK"

# ----------------------------------------------------------------------------
Step "Phase 7 - Generate HTML summary report"
# ----------------------------------------------------------------------------
$rowsHtml = ($plan | ForEach-Object {
    $color = switch ($_.Action) {
        "migrate"                     { "#1B6B3A" }
        "skip-already-on-standard"    { "#555E6D" }
        default                       { "#9B2226" }
    }
    "<tr><td>$($_.Hostname)</td><td>$($_.SafeName)</td><td>$($_.EndpointName)</td><td style='color:$color'><b>$($_.Action)</b></td><td>$($_.ClassicCert)</td></tr>"
}) -join "`n"

$dnsRowsHtml = ($dnsRecords | ForEach-Object {
    "<tr><td>$($_.Hostname)</td><td><code>$($_.TxtHost)</code></td><td><code>$($_.TxtValue)</code></td><td><code>$($_.CnameHost)</code></td><td><code>$($_.CnameValue)</code></td></tr>"
}) -join "`n"

$html = @"
<!DOCTYPE html>
<html><head><meta charset='UTF-8'><title>hipyx-migrate-all summary $timestamp</title>
<style>
body{font-family:-apple-system,Segoe UI,sans-serif;color:#11151C;max-width:1100px;margin:32px auto;padding:0 24px;line-height:1.55}
h1{font-size:26px;border-bottom:1px solid #C8CFD9;padding-bottom:8px}
h2{font-size:18px;margin-top:32px;border-bottom:1px solid #E5E8EE;padding-bottom:4px}
table{width:100%;border-collapse:collapse;margin:12px 0;font-size:13px}
th{text-align:left;background:#F5F7FA;padding:8px 10px;border-bottom:2px solid #1F3D7A;color:#1F3D7A;font-weight:600}
td{padding:8px 10px;border-bottom:1px solid #E5E8EE;vertical-align:top}
code{font-family:Consolas,monospace;font-size:12px;background:#F5F7FA;padding:1px 5px;border-radius:3px}
.stat{display:inline-block;margin-right:24px;padding:10px 14px;background:#F5F7FA;border-left:3px solid #1F3D7A;font-size:14px}
.stat b{font-size:20px;display:block}
.footer{margin-top:48px;padding-top:16px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px}
</style></head><body>

<h1>Azure Front Door - Classic to Standard migration run</h1>
<p>Subscription: <code>$SubscriptionId</code> &middot; Resource group: <code>$ResourceGroup</code><br>
Classic profile: <code>$ClassicProfile</code> &middot; Standard profile: <code>$StandardProfile</code> &middot; WAF: <code>$WafPolicyName</code><br>
Run timestamp: $timestamp</p>

<div class='stat'><b>$($plan.Count)</b>Custom domains found on Classic</div>
<div class='stat'><b>$migrated</b>Migrated this run</div>
<div class='stat'><b>$skipped</b>Already on Standard</div>
<div class='stat'><b>$failed</b>Failed</div>

<h2>Migration plan</h2>
<table><thead><tr><th>Hostname</th><th>Resource name</th><th>Endpoint</th><th>Action</th><th>Classic cert state</th></tr></thead>
<tbody>$rowsHtml</tbody></table>

<h2>DNS handoff package (give to network team)</h2>
<p>For each domain, publish the TXT record first. Once the managed cert reports <i>Approved</i>, publish the CNAME. TTL is 300 seconds across the board.</p>
<table><thead><tr><th>Hostname</th><th>TXT host</th><th>TXT value</th><th>CNAME host</th><th>CNAME value</th></tr></thead>
<tbody>$dnsRowsHtml</tbody></table>

<h2>Verification commands</h2>
<p>For each migrated domain, poll until <code>domainValidationState</code> returns <code>Approved</code>:</p>
<pre><code>az afd custom-domain show --resource-group $ResourceGroup --profile-name $StandardProfile --custom-domain-name &lt;safe-name&gt; --query domainValidationState -o tsv</code></pre>

<h2>Rollback (DNS-only, no downtime)</h2>
<ol>
<li>In each affected DNS zone, point the host CNAME back to <code>$ClassicProfile.azurefd.net</code></li>
<li>Wait for the TTL window (300 seconds)</li>
<li>Traffic returns to Classic automatically</li>
</ol>

<div class='footer'>Prepared by Syed Rizvi &middot; PYX Health Production &middot; $((Get-Date).ToString('yyyy-MM-dd'))</div>
</body></html>
"@
Set-Content -Path $htmlPath -Value $html -Encoding UTF8
Log "HTML summary: $htmlPath" "OK"

# ----------------------------------------------------------------------------
Step "Phase 8 - Final summary"
# ----------------------------------------------------------------------------
Log ""
Log ("DONE: {0} migrated, {1} already on Standard, {2} failed" -f $migrated, $skipped, $failed) "OK"
Log ""
Log "Artifacts:"
Log "  Run log     : $logPath"
Log "  Plan JSON   : $planPath"
Log "  DNS text    : $dnsPath"
Log "  DNS CSV     : $csvPath"
Log "  HTML report : $htmlPath"
Log ""
if ($migrated -gt 0) {
    Log "NEXT STEP: send $dnsPath (or $csvPath) to the DNS owner for each domain. Each cert will issue once the TXT record is published. Then publish CNAME to flip traffic." "INFO"
}
if ($failed -gt 0) {
    Log "NOTE: $failed domain(s) failed. Review $logPath for details." "WARN"
    exit 4
}
exit 0
