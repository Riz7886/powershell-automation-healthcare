[CmdletBinding()]
param(
    [string]$SubscriptionId   = "e42e94b5-c6f8-4af0-a41b-16fda520de6e",
    [string]$ResourceGroup    = "production",
    [string]$ClassicProfile   = "hipyx",
    [string]$StandardProfile  = "hipyx-std",
    [string]$WafPolicyName    = "hipyxWafPolicy",
    [string]$DefaultOriginHost = "",
    [int]   $ReleaseWaitSec   = 60,
    [int]   $CreateRetryWaitSec = 60,
    [int]   $CreateMaxAttempts = 4,
    [switch]$DryRun,
    [string]$ReportDir        = (Join-Path $env:USERPROFILE "Desktop\hipyx-migrate-all-report")
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")

if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
$logPath     = Join-Path $ReportDir "run-$timestamp.log"
$dnsPath     = Join-Path $ReportDir "dns-handoff-$timestamp.txt"
$csvPath     = Join-Path $ReportDir "dns-handoff-$timestamp.csv"
$htmlPath    = Join-Path $ReportDir "summary-$timestamp.html"
$dnsHtmlPath = Join-Path $ReportDir "dns-handoff-$timestamp.html"
$planPath    = Join-Path $ReportDir "plan-$timestamp.json"

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
$classicEndpoints = @($classicEndpointsJson | ConvertFrom-Json)

$customEndpoints = @($classicEndpoints | Where-Object { $_.hostName -and $_.hostName -notlike "*.azurefd.net" })
Log ("Found {0} frontend endpoints on Classic ({1} custom domains, {2} default azurefd.net)" -f $classicEndpoints.Count, $customEndpoints.Count, ($classicEndpoints.Count - $customEndpoints.Count)) "OK"

if ($customEndpoints.Count -eq 0) {
    Log "No custom domains on Classic - nothing to migrate. Standard already has the domains." "OK"
    Log "Verify with: az afd custom-domain list -g $ResourceGroup --profile-name $StandardProfile -o table"
    exit 0
}

foreach ($e in $customEndpoints) {
    Log ("  Classic custom domain: {0}  (cert state: {1})" -f $e.hostName, $e.customHttpsProvisioningState)
}

# ----------------------------------------------------------------------------
Step "Phase 2 - Inventory existing Standard hipyx-std domains (skip duplicates)"
# ----------------------------------------------------------------------------
$standardDomainsJson = az afd custom-domain list --resource-group $ResourceGroup --profile-name $StandardProfile -o json 2>$null
$standardDomains = if ($standardDomainsJson) { @($standardDomainsJson | ConvertFrom-Json) } else { @() }
$standardHostnames = @{}
foreach ($d in $standardDomains) {
    if ($d.hostName) { $standardHostnames[$d.hostName.ToLower()] = $d }
}
Log ("Standard profile already has {0} custom domain(s)" -f $standardDomains.Count) "OK"
foreach ($d in $standardDomains) { Log ("  Standard custom domain: {0} -> {1} (state: {2})" -f $d.hostName, $d.name, $d.domainValidationState) }

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
        Hostname            = $hostName
        SafeName            = $safeName
        EndpointName        = $endpointName
        ClassicEndpointName = $e.name
        Action              = if ($alreadyOnStd) { "skip-already-on-standard" } else { "migrate" }
        ClassicCert         = $e.customHttpsProvisioningState
    }
}
$plan | Format-Table -AutoSize | Out-String | ForEach-Object { Log $_ }
$plan | ConvertTo-Json -Depth 5 | Out-File -FilePath $planPath -Encoding ASCII
Log "Plan saved: $planPath" "OK"

if ($DryRun) {
    Log "DryRun mode - stopping before any changes are made" "WARN"
    exit 0
}

# ----------------------------------------------------------------------------
Step "Phase 4 - Verify Standard profile and WAF policy"
# ----------------------------------------------------------------------------
$stdCheck = az afd profile show --resource-group $ResourceGroup --profile-name $StandardProfile -o json 2>$null
if (-not $stdCheck) { Log "Standard profile $StandardProfile not found - aborting" "ERR"; exit 3 }
Log "Standard profile $StandardProfile is present" "OK"

$wafExists = az network front-door waf-policy show --resource-group $ResourceGroup --name $WafPolicyName --query id -o tsv 2>$null
if (-not $wafExists) {
    Log "WAF policy $WafPolicyName not found - creating in Detection mode" "WARN"
    az network front-door waf-policy create --resource-group $ResourceGroup --name $WafPolicyName --mode Detection --sku Standard_AzureFrontDoor --only-show-errors | Out-Null
} else {
    Log "WAF policy $WafPolicyName already exists" "OK"
}

# ----------------------------------------------------------------------------
Step "Phase 5 - Detach from Classic, create on Standard, build origin/route"
# ----------------------------------------------------------------------------
$dnsRecords = @()
$migrated   = 0
$skipped    = 0
$failed     = 0

# Pre-fetch Classic routing rules + backend pools once
$classicRulesJson = az network front-door routing-rule list --resource-group $ResourceGroup --front-door-name $ClassicProfile -o json 2>$null
$classicRules = if ($classicRulesJson) { @($classicRulesJson | ConvertFrom-Json) } else { @() }

foreach ($p in $plan) {
    Log ""
    Log ("--- {0} ---" -f $p.Hostname) "STEP"

    if ($p.Action -eq "skip-already-on-standard") {
        Log "Already on Standard - skipping create, will emit DNS records for verification" "OK"
        $skipped++

        # Still emit DNS records so user can verify what's in DNS
        $existing = $standardHostnames[$p.Hostname.ToLower()]
        $cdShow = az afd custom-domain show --resource-group $ResourceGroup --profile-name $StandardProfile --custom-domain-name $existing.name -o json 2>$null | ConvertFrom-Json
        $existingTxt = $null
        if ($cdShow) { $existingTxt = $cdShow.validationProperties.validationToken }

        # Walk routes to find which endpoint this domain is bound to
        $existingCname = "UNKNOWN"
        $epListJson = az afd endpoint list --resource-group $ResourceGroup --profile-name $StandardProfile -o json 2>$null
        $epList = if ($epListJson) { @($epListJson | ConvertFrom-Json) } else { @() }
        foreach ($ep in $epList) {
            $routeListJson = az afd route list --resource-group $ResourceGroup --profile-name $StandardProfile --endpoint-name $ep.name -o json 2>$null
            $routeList = if ($routeListJson) { @($routeListJson | ConvertFrom-Json) } else { @() }
            foreach ($rt in $routeList) {
                $domIds = @($rt.customDomains | ForEach-Object { $_.id })
                if ($domIds -match [regex]::Escape("/customDomains/$($existing.name)")) {
                    $existingCname = $ep.hostName
                    break
                }
            }
            if ($existingCname -ne "UNKNOWN") { break }
        }

        $hostShort = $p.Hostname.Split('.')[0]
        $zone = ($p.Hostname.Split('.')[1..($p.Hostname.Split('.').Length - 1)]) -join '.'
        $dnsRecords += [PSCustomObject]@{
            Hostname   = $p.Hostname
            Zone       = $zone
            TxtHost    = "_dnsauth.$hostShort"
            TxtValue   = $existingTxt
            CnameHost  = $hostShort
            CnameValue = $existingCname
            Ttl        = 300
            OriginHost = "(existing)"
            Status     = "already-on-standard"
        }
        continue
    }

    # Step 5.1 - Discover Classic backend host for this domain (so Standard origin matches)
    $classicFEId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/frontDoors/$ClassicProfile/frontendEndpoints/$($p.ClassicEndpointName)"
    $rulesUsingFE = @()
    $originHost = $DefaultOriginHost
    foreach ($r in $classicRules) {
        $refIds = @($r.frontendEndpoints | ForEach-Object { $_.id })
        if ($refIds -contains $classicFEId) {
            $rulesUsingFE += $r
            try {
                $rcType = $r.routeConfiguration.'@odata.type'
                if ($rcType -match 'ForwardingConfiguration' -and $r.routeConfiguration.backendPool) {
                    $bpName = ($r.routeConfiguration.backendPool.id -split '/')[-1]
                    $bpJson = az network front-door backend-pool show --resource-group $ResourceGroup --front-door-name $ClassicProfile --name $bpName -o json 2>$null
                    if ($bpJson) {
                        $bp = $bpJson | ConvertFrom-Json
                        if ($bp.backends -and $bp.backends.Count -gt 0) {
                            $originHost = $bp.backends[0].address
                            Log ("  Classic backend pool: {0} -> origin host: {1}" -f $bpName, $originHost)
                        }
                    }
                } elseif ($rcType -match 'RedirectConfiguration') {
                    Log ("  Classic rule '{0}' is a redirect, not a forward - origin will use DefaultOriginHost or fail" -f $r.name) "WARN"
                }
            } catch { Log ("  Could not parse routeConfiguration on rule '{0}': {1}" -f $r.name, $_) "WARN" }
        }
    }

    if (-not $originHost) {
        Log "Could not detect Classic backend for $($p.Hostname) and no -DefaultOriginHost was provided" "ERR"
        Log "Re-run with: -DefaultOriginHost <fqdn-of-real-backend>" "ERR"
        $failed++
        continue
    }

    # Step 5.2 - Detach the frontendEndpoint from any Classic routing rules
    foreach ($r in $rulesUsingFE) {
        $remaining = @($r.frontendEndpoints | Where-Object { $_.id -ne $classicFEId } | ForEach-Object { $_.id })
        if ($remaining.Count -eq 0) {
            Log ("  Classic routing rule '{0}' has only this endpoint - deleting rule" -f $r.name)
            az network front-door routing-rule delete --resource-group $ResourceGroup --front-door-name $ClassicProfile --name $r.name --only-show-errors 2>$null | Out-Null
        } else {
            Log ("  Classic routing rule '{0}' updating - removing this endpoint reference" -f $r.name)
            az network front-door routing-rule update --resource-group $ResourceGroup --front-door-name $ClassicProfile --name $r.name --frontend-endpoints $remaining --only-show-errors 2>$null | Out-Null
        }
    }

    # Step 5.3 - Delete the Classic frontend-endpoint to release the hostname
    Log "Deleting Classic frontend-endpoint $($p.ClassicEndpointName)..."
    az network front-door frontend-endpoint delete --resource-group $ResourceGroup --front-door-name $ClassicProfile --name $p.ClassicEndpointName --only-show-errors 2>$null | Out-Null
    Log "Classic frontend-endpoint removed" "OK"

    # Step 5.4 - Wait for Azure to release the hostname binding
    Log "Waiting $ReleaseWaitSec sec for Azure to release the hostname..."
    Start-Sleep -Seconds $ReleaseWaitSec

    # Step 5.5 - Ensure Standard endpoint exists
    $epExists = az afd endpoint show --resource-group $ResourceGroup --profile-name $StandardProfile --endpoint-name $p.EndpointName --query id -o tsv 2>$null
    if (-not $epExists) {
        Log "Creating Standard endpoint $($p.EndpointName)"
        az afd endpoint create --resource-group $ResourceGroup --profile-name $StandardProfile --endpoint-name $p.EndpointName --enabled-state Enabled --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { Log "Endpoint create failed for $($p.Hostname)" "ERR"; $failed++; continue }
    } else {
        Log "Standard endpoint $($p.EndpointName) already exists" "OK"
    }

    # Step 5.6 - Get the endpoint hostname (CNAME target for DNS)
    $cname = az afd endpoint show --resource-group $ResourceGroup --profile-name $StandardProfile --endpoint-name $p.EndpointName --query hostName -o tsv 2>$null
    if (-not $cname) { Log "Could not read Standard endpoint hostname" "ERR"; $failed++; continue }
    Log "Standard endpoint hostname: $cname" "OK"

    # Step 5.7 - Create custom-domain on Standard, with retries if hostname not yet released
    $cdCreated = $false
    for ($attempt = 1; $attempt -le $CreateMaxAttempts; $attempt++) {
        $cdAlreadyExists = az afd custom-domain show --resource-group $ResourceGroup --profile-name $StandardProfile --custom-domain-name $p.SafeName --query id -o tsv 2>$null
        if ($cdAlreadyExists) {
            Log "Custom-domain $($p.SafeName) already exists on Standard" "OK"
            $cdCreated = $true
            break
        }

        Log "Creating custom-domain $($p.SafeName) -> $($p.Hostname) (attempt $attempt/$CreateMaxAttempts)..."
        $cdResult = az afd custom-domain create --resource-group $ResourceGroup --profile-name $StandardProfile --custom-domain-name $p.SafeName --host-name $p.Hostname --certificate-type ManagedCertificate --minimum-tls-version TLS12 --only-show-errors 2>&1
        if ($LASTEXITCODE -eq 0) {
            $cdCreated = $true
            Log "Custom-domain created" "OK"
            break
        }
        Log ("Custom-domain create attempt {0} failed: {1}" -f $attempt, ($cdResult -join ' ')) "WARN"
        if ($attempt -lt $CreateMaxAttempts) {
            Log "Waiting $CreateRetryWaitSec sec before retry (Classic hostname release can lag)..."
            Start-Sleep -Seconds $CreateRetryWaitSec
        }
    }
    if (-not $cdCreated) { Log "Custom-domain create failed for $($p.Hostname) after $CreateMaxAttempts attempts" "ERR"; $failed++; continue }

    # Step 5.8 - Get TXT validation token (with retry, sometimes lags)
    Start-Sleep -Seconds 5
    $txt = az afd custom-domain show --resource-group $ResourceGroup --profile-name $StandardProfile --custom-domain-name $p.SafeName --query "validationProperties.validationToken" -o tsv 2>$null
    if (-not $txt) {
        Start-Sleep -Seconds 15
        $txt = az afd custom-domain show --resource-group $ResourceGroup --profile-name $StandardProfile --custom-domain-name $p.SafeName --query "validationProperties.validationToken" -o tsv 2>$null
    }
    if (-not $txt) { Log "Could not read validation token - check portal" "WARN"; $txt = "READ-FROM-PORTAL" }
    Log "Validation token: $txt" "OK"

    # Step 5.9 - Find or create origin group + origin
    $targetOG = $null
    $ogListJson = az afd origin-group list --resource-group $ResourceGroup --profile-name $StandardProfile -o json 2>$null
    $ogList = if ($ogListJson) { @($ogListJson | ConvertFrom-Json) } else { @() }
    foreach ($og in $ogList) {
        $originsJson = az afd origin list --resource-group $ResourceGroup --profile-name $StandardProfile --origin-group-name $og.name -o json 2>$null
        $origins = if ($originsJson) { @($originsJson | ConvertFrom-Json) } else { @() }
        foreach ($o in $origins) {
            if ($o.hostName -ieq $originHost) {
                $targetOG = $og.name
                break
            }
        }
        if ($targetOG) { break }
    }

    if (-not $targetOG) {
        $targetOG = "og-$($p.SafeName)"
        Log "Creating origin group $targetOG -> $originHost"
        az afd origin-group create --resource-group $ResourceGroup --profile-name $StandardProfile --origin-group-name $targetOG --probe-request-type GET --probe-protocol Https --probe-interval-in-seconds 60 --probe-path "/" --sample-size 4 --successful-samples-required 3 --additional-latency-in-milliseconds 50 --only-show-errors | Out-Null
        az afd origin create --resource-group $ResourceGroup --profile-name $StandardProfile --origin-group-name $targetOG --origin-name "origin-$($p.SafeName)" --host-name $originHost --origin-host-header $originHost --priority 1 --weight 1000 --enabled-state Enabled --http-port 80 --https-port 443 --only-show-errors | Out-Null
    } else {
        Log "Reusing origin group: $targetOG (origin matches $originHost)" "OK"
    }

    # Step 5.10 - Create route on the new endpoint, attach the custom-domain
    $cdId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Cdn/profiles/$StandardProfile/customDomains/$($p.SafeName)"
    $routeExists = az afd route show --resource-group $ResourceGroup --profile-name $StandardProfile --endpoint-name $p.EndpointName --route-name "default-route" --query id -o tsv 2>$null
    if (-not $routeExists) {
        Log "Creating route default-route on $($p.EndpointName) -> origin group $targetOG"
        az afd route create --resource-group $ResourceGroup --profile-name $StandardProfile --endpoint-name $p.EndpointName --route-name "default-route" --origin-group $targetOG --custom-domains $cdId --supported-protocols Http Https --link-to-default-domain Disabled --forwarding-protocol MatchRequest --https-redirect Enabled --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { Log "Route create failed - traffic will not flow until you wire a route manually" "WARN" }
    } else {
        Log "Route default-route already exists" "OK"
    }

    # Step 5.11 - Bind WAF security policy
    $secPolicyName = "fx-$($p.SafeName)-waf"
    $spExists = az afd security-policy show --resource-group $ResourceGroup --profile-name $StandardProfile --security-policy-name $secPolicyName --query id -o tsv 2>$null
    if (-not $spExists) {
        $wafId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/$WafPolicyName"
        Log "Binding WAF security policy $secPolicyName"
        az afd security-policy create --resource-group $ResourceGroup --profile-name $StandardProfile --security-policy-name $secPolicyName --waf-policy $wafId --domains $cdId --only-show-errors | Out-Null
    } else {
        Log "Security policy $secPolicyName already bound" "OK"
    }

    # Step 5.12 - Append DNS handoff entry
    $hostShort = $p.Hostname.Split('.')[0]
    $zone = ($p.Hostname.Split('.')[1..($p.Hostname.Split('.').Length - 1)]) -join '.'
    $dnsRecords += [PSCustomObject]@{
        Hostname   = $p.Hostname
        Zone       = $zone
        TxtHost    = "_dnsauth.$hostShort"
        TxtValue   = $txt
        CnameHost  = $hostShort
        CnameValue = $cname
        Ttl        = 300
        OriginHost = $originHost
        Status     = "migrated"
    }

    Log ("Migrated {0}  ->  endpoint: {1}  origin: {2}" -f $p.Hostname, $cname, $originHost) "OK"
    $migrated++
}

# ----------------------------------------------------------------------------
Step "Phase 6 - Generate DNS handoff package"
# ----------------------------------------------------------------------------
$dnsLines = @()
$dnsLines += "DNS handoff package - generated $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"
$dnsLines += ("=" * 78)
$dnsLines += ""
if ($dnsRecords.Count -eq 0) {
    $dnsLines += "NO DNS RECORDS - all migrations failed. Review the run log for details."
    $dnsLines += "  $logPath"
} else {
    foreach ($r in $dnsRecords) {
        $dnsLines += ("Domain: {0}  (zone: {1})  [{2}]" -f $r.Hostname, $r.Zone, $r.Status)
        $dnsLines += "  Step 1 - publish TXT first (validates the AFD managed cert):"
        $dnsLines += ("    Host  : {0}" -f $r.TxtHost)
        $dnsLines += "    Type  : TXT"
        $dnsLines += ("    Value : {0}" -f $r.TxtValue)
        $dnsLines += ("    TTL   : {0}" -f $r.Ttl)
        $dnsLines += ""
        $dnsLines += "  Step 2 - after cert state shows Approved, publish CNAME (cuts traffic over):"
        $dnsLines += ("    Host  : {0}" -f $r.CnameHost)
        $dnsLines += "    Type  : CNAME"
        $dnsLines += ("    Value : {0}" -f $r.CnameValue)
        $dnsLines += ("    TTL   : {0}" -f $r.Ttl)
        $dnsLines += ""
        $dnsLines += ("  Origin host on AFD Standard: {0}" -f $r.OriginHost)
        $dnsLines += ("-" * 78)
        $dnsLines += ""
    }
}
Set-Content -Path $dnsPath -Value $dnsLines -Encoding ASCII
if ($dnsRecords.Count -gt 0) { $dnsRecords | Export-Csv -Path $csvPath -NoTypeInformation -Encoding ASCII } else { Set-Content -Path $csvPath -Value "Hostname,Zone,TxtHost,TxtValue,CnameHost,CnameValue,Ttl,OriginHost,Status" -Encoding ASCII }
Log "DNS handoff text: $dnsPath" "OK"
Log "DNS handoff CSV : $csvPath" "OK"

# Clean DNS-only HTML for the DNS owner (no admin clutter - just records to publish)
$dnsHandoffRows = ($dnsRecords | ForEach-Object {
    @"
<tr><td rowspan='2'><b>$($_.Hostname)</b></td><td><span class='tag txt'>TXT</span></td><td><code>$($_.TxtHost)</code></td><td><code>$($_.TxtValue)</code></td><td>$($_.Ttl)</td><td>Step 1 - publish first, validates AFD managed cert</td></tr>
<tr><td><span class='tag cname'>CNAME</span></td><td><code>$($_.CnameHost)</code></td><td><code>$($_.CnameValue)</code></td><td>$($_.Ttl)</td><td>Step 2 - publish AFTER cert state is Approved (cuts traffic over)</td></tr>
"@
}) -join "`n"

if ($dnsRecords.Count -eq 0) { $dnsHandoffRows = "<tr><td colspan='6'>No records - no successful migrations.</td></tr>" }

$dnsOnlyHtml = @"
<!DOCTYPE html>
<html><head><meta charset='UTF-8'><title>hipyx Front Door - DNS records to publish</title>
<style>
body{font-family:-apple-system,Segoe UI,sans-serif;color:#11151C;max-width:1100px;margin:32px auto;padding:0 24px;line-height:1.55}
h1{font-size:24px;border-bottom:2px solid #1F3D7A;padding-bottom:8px;color:#1F3D7A}
h2{font-size:16px;margin-top:28px;color:#1F3D7A}
table{width:100%;border-collapse:collapse;margin:12px 0;font-size:13px}
th{text-align:left;background:#F5F7FA;padding:10px;border-bottom:2px solid #1F3D7A;color:#1F3D7A;font-weight:600}
td{padding:10px;border-bottom:1px solid #E5E8EE;vertical-align:top}
code{font-family:Consolas,monospace;font-size:12px;background:#F5F7FA;padding:2px 6px;border-radius:3px;word-break:break-all}
.tag{display:inline-block;padding:2px 8px;border-radius:3px;font-size:11px;font-weight:600;color:#fff}
.tag.txt{background:#1B6B3A}.tag.cname{background:#1F3D7A}
.note{background:#FFF8E1;border-left:3px solid #F5A623;padding:10px 14px;margin:14px 0;font-size:13px}
.footer{margin-top:40px;padding-top:14px;border-top:1px solid #C8CFD9;color:#555E6D;font-size:12px}
ol li{margin:6px 0}
</style></head><body>

<h1>hipyx Front Door - DNS records to publish</h1>
<p>The records below need to go in the authoritative DNS for <b>hipyx.com</b> as part of the Azure Front Door Classic-to-Standard migration.</p>

<div class='note'><b>Order of operations:</b>
<ol>
<li>Publish all <span class='tag txt'>TXT</span> records first.</li>
<li>Wait until Azure reports the managed cert state as <i>Approved</i> (typically 5-30 min after the TXT record is live).</li>
<li>Then publish the <span class='tag cname'>CNAME</span> records to cut traffic over.</li>
<li>TTL is 300 seconds across the board so any rollback is fast.</li>
</ol></div>

<h2>Records</h2>
<table>
<thead><tr><th style='width:18%'>Domain</th><th style='width:8%'>Type</th><th style='width:22%'>Host / Name</th><th style='width:24%'>Value</th><th style='width:6%'>TTL</th><th>When to publish</th></tr></thead>
<tbody>
$dnsHandoffRows
</tbody></table>

<h2>Verification (after CNAME is live)</h2>
<p>From any machine:</p>
<pre><code>nslookup www.hipyx.com
curl -I https://www.hipyx.com/</code></pre>
<p>The CNAME chain should resolve through the AFD Standard endpoint shown in the value column above. The HTTP response should include the header <code>x-azure-ref</code>.</p>

<h2>Rollback (if anything looks wrong)</h2>
<p>Repoint each CNAME back to <code>hipyx.azurefd.net</code> and traffic returns to AFD Classic within the 300-second TTL. No code change required.</p>

<div class='footer'>Prepared by Syed Rizvi - PYX Health Production - $((Get-Date).ToString('yyyy-MM-dd'))</div>
</body></html>
"@
Set-Content -Path $dnsHtmlPath -Value $dnsOnlyHtml -Encoding ASCII
Log "DNS handoff HTML: $dnsHtmlPath" "OK"

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
    "<tr><td>$($_.Hostname)</td><td><code>$($_.TxtHost)</code></td><td><code>$($_.TxtValue)</code></td><td><code>$($_.CnameHost)</code></td><td><code>$($_.CnameValue)</code></td><td><code>$($_.OriginHost)</code></td><td>$($_.Status)</td></tr>"
}) -join "`n"

$html = @"
<!DOCTYPE html>
<html><head><meta charset='UTF-8'><title>hipyx-migrate-all summary $timestamp</title>
<style>
body{font-family:-apple-system,Segoe UI,sans-serif;color:#11151C;max-width:1200px;margin:32px auto;padding:0 24px;line-height:1.55}
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

<h2>DNS handoff package</h2>
<p>For each migrated domain, publish the TXT record first. Once <code>domainValidationState</code> reports <i>Approved</i>, publish the CNAME to cut traffic to Standard. TTL is 300 seconds.</p>
<table><thead><tr><th>Hostname</th><th>TXT host</th><th>TXT value</th><th>CNAME host</th><th>CNAME value</th><th>Origin</th><th>Status</th></tr></thead>
<tbody>$dnsRowsHtml</tbody></table>

<h2>Verification commands</h2>
<pre><code>az afd custom-domain show --resource-group $ResourceGroup --profile-name $StandardProfile --custom-domain-name &lt;safe-name&gt; --query domainValidationState -o tsv
az afd endpoint show --resource-group $ResourceGroup --profile-name $StandardProfile --endpoint-name &lt;endpoint&gt; --query hostName -o tsv</code></pre>

<h2>Rollback (if needed)</h2>
<ol>
<li>Re-create the Classic frontend-endpoint with <code>az network front-door frontend-endpoint create</code></li>
<li>Re-attach to the Classic routing rule</li>
<li>Repoint the public CNAME back to <code>$ClassicProfile.azurefd.net</code></li>
<li>Wait for TTL (300 sec)</li>
</ol>

<div class='footer'>Prepared by Syed Rizvi &middot; PYX Health Production &middot; $((Get-Date).ToString('yyyy-MM-dd'))</div>
</body></html>
"@
Set-Content -Path $htmlPath -Value $html -Encoding ASCII
Log "HTML summary: $htmlPath" "OK"

# ----------------------------------------------------------------------------
Step "Phase 8 - Final summary"
# ----------------------------------------------------------------------------
Log ""
Log ("DONE: {0} migrated, {1} already on Standard, {2} failed" -f $migrated, $skipped, $failed) "OK"
Log ""
Log "Artifacts:"
Log "  Run log         : $logPath"
Log "  Plan JSON       : $planPath"
Log "  DNS text        : $dnsPath"
Log "  DNS CSV         : $csvPath"
Log "  DNS handoff HTML: $dnsHtmlPath  <-- send THIS to whoever publishes DNS"
Log "  Full HTML report: $htmlPath"
Log ""
if ($dnsRecords.Count -gt 0) {
    Log "==== DNS RECORDS TO PUBLISH ====" "STEP"
    foreach ($r in $dnsRecords) {
        Log ("  [TXT]   {0}  ->  {1}" -f $r.TxtHost, $r.TxtValue)
        Log ("  [CNAME] {0}  ->  {1}" -f $r.CnameHost, $r.CnameValue)
        Log ""
    }
    Log "Order: TXT first. Wait until domainValidationState = Approved (5-30 min). Then CNAME."
}
if ($failed -gt 0) {
    Log "NOTE: $failed domain(s) failed. Review $logPath for details." "WARN"
    exit 4
}
exit 0
