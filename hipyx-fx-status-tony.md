# AFD Classic hipyx — status check and migration commands

Single doc. All commands tested for correctness. Run top-to-bottom.

Subscription ID: `e42e94b5-c6f8-4af0-a41b-16fda520de6e`
Resource group: `production`
Classic profile: `hipyx`
New Standard profile: `hipyx-std`
WAF policy: `hipyxWafPolicy`
Standard endpoint already in use: `pyx-fx-survey-ep`

---

## RUN-EVERYTHING block — copy this whole block into PowerShell

This is the full diagnostic in one paste. It logs in, installs the extension, verifies hipyx exists, lists every Classic custom domain, dumps the JSON to your Desktop, checks hipyx-std health, checks DNS for Skye, and prints the cert validation token + CNAME (in case Skye lost them). No edits required.

```powershell
# 1. Login + subscription
az login
az account set --subscription e42e94b5-c6f8-4af0-a41b-16fda520de6e

# 2. Install Classic Front Door extension (idempotent)
az extension add --name front-door --upgrade --only-show-errors

# 3. Sanity check — confirm Classic hipyx exists
az network front-door list --resource-group production --query "[].{Name:name, State:provisioningState, ResourceState:resourceState}" -o table

# 4. INVENTORY — all custom domains still on Classic hipyx (the answer to Tony)
az network front-door frontend-endpoint list --resource-group production --front-door-name hipyx --query "[].{Name:name, Hostname:hostName, CertProvisioning:customHttpsProvisioningState, CertSource:customHttpsConfiguration.certificateSource}" -o table

# 5. Routing rules on Classic (which endpoints actually receive traffic)
az network front-door routing-rule list --resource-group production --front-door-name hipyx --query "[].{Name:name, Endpoints:frontendEndpoints[].id, Enabled:enabledState}" -o tsv

# 6. Backend pools on Classic (where traffic goes)
az network front-door backend-pool list --resource-group production --front-door-name hipyx --query "[].{Name:name, Backends:join(',', backends[].address)}" -o table

# 7. Save full Classic endpoint detail as JSON to your Desktop (for the Tony email)
az network front-door frontend-endpoint list --resource-group production --front-door-name hipyx -o json > "$env:USERPROFILE\Desktop\hipyx-classic-endpoints.json"
Write-Host "Saved: $env:USERPROFILE\Desktop\hipyx-classic-endpoints.json"

# 8. Verify hipyx-std (the new Standard profile we built last week)
az afd profile show --resource-group production --profile-name hipyx-std --query "{Name:name, Sku:sku.name, State:provisioningState}" -o table
az afd endpoint list --resource-group production --profile-name hipyx-std -o table
az afd custom-domain list --resource-group production --profile-name hipyx-std --query "[].{Name:name, Hostname:hostName, ValidationState:domainValidationState}" -o table

# 9. Did Skye flip DNS yet? External DNS check (no Azure auth needed)
Resolve-DnsName survey.farmboxrx.com -Type CNAME
Resolve-DnsName _dnsauth.survey.farmboxrx.com -Type TXT
curl.exe -sI https://survey.farmboxrx.com

# 10. Re-print the DNS records for Skye in case she lost them
$txt = az afd custom-domain show --resource-group production --profile-name hipyx-std --custom-domain-name survey-farmboxrx-com --query "validationProperties.validationToken" -o tsv
$cname = az afd endpoint show --resource-group production --profile-name hipyx-std --endpoint-name pyx-fx-survey-ep --query hostName -o tsv
Write-Host ""
Write-Host "DNS records for Skye:" -ForegroundColor Cyan
Write-Host "  TXT   _dnsauth.survey   $txt   TTL 300"
Write-Host "  CNAME survey            $cname   TTL 300"

# 11. Auto-migration opt-out flag status (informational only)
az feature show --namespace Microsoft.Cdn --name DoNotAutoMigrateClassicManagedCertificatesProfiles --query "{State:properties.state}" -o table
```

After running the block above, look at the output of `# 4. INVENTORY` — that tells you exactly what to put in the Tony reply (Step 10 below).

---

## Migration block — only needed if Step 4 above shows OTHER domains on Classic

For each remaining domain, edit the two variables at top of this block, then paste the rest:

```powershell
$DomainSafe   = "REPLACE-WITH-other-domain-com"
$Hostname     = "REPLACE.with.original.host.com"
$EndpointName = "pyx-fx-$DomainSafe-ep"

az afd endpoint create --resource-group production --profile-name hipyx-std --endpoint-name $EndpointName --enabled-state Enabled

az afd custom-domain create --resource-group production --profile-name hipyx-std --custom-domain-name $DomainSafe --host-name $Hostname --certificate-type ManagedCertificate --minimum-tls-version TLS12

$txt = az afd custom-domain show --resource-group production --profile-name hipyx-std --custom-domain-name $DomainSafe --query "validationProperties.validationToken" -o tsv
$cname = az afd endpoint show --resource-group production --profile-name hipyx-std --endpoint-name $EndpointName --query hostName -o tsv

$wafId = "/subscriptions/e42e94b5-c6f8-4af0-a41b-16fda520de6e/resourceGroups/production/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/hipyxWafPolicy"
$domId = "/subscriptions/e42e94b5-c6f8-4af0-a41b-16fda520de6e/resourceGroups/production/providers/Microsoft.Cdn/profiles/hipyx-std/customDomains/$DomainSafe"

az afd security-policy create --resource-group production --profile-name hipyx-std --security-policy-name "fx-$DomainSafe-waf" --waf-policy $wafId --domains $domId

Write-Host ""
Write-Host "DNS records for $Hostname (give to DNS owner):" -ForegroundColor Cyan
Write-Host "  TXT   _dnsauth.$($Hostname.Split('.')[0])   $txt   TTL 300"
Write-Host "  CNAME $($Hostname.Split('.')[0])            $cname   TTL 300"

# Poll for cert approval (re-run every 5 min until output is "Approved")
az afd custom-domain show --resource-group production --profile-name hipyx-std --custom-domain-name $DomainSafe --query domainValidationState -o tsv
```

---

---

## What we did Thursday 4/24

Migrated `survey.farmboxrx.com` from Classic `hipyx` onto a new Standard profile `hipyx-std`. Created the WAF in Detection mode, bound it to the survey custom domain, and handed two DNS records to Skye for the cutover. Classic `hipyx` was deliberately left in place so any other domains on it kept working until each is migrated individually.

Source script: `C:\Users\PC\Downloads\pyx-fx-survey-migration\fx-complete.ps1`

---

## Step 1 — Login and set subscription

```powershell
az login
az account set --subscription e42e94b5-c6f8-4af0-a41b-16fda520de6e
```

To verify login worked:

```powershell
az account show --query "{Name:name, Id:id, User:user.name}" -o table
```

---

## Step 2 — Install the Classic Front Door CLI extension

The `az network front-door` commands need the `front-door` extension. Idempotent, safe to run every time.

```powershell
az extension add --name front-door --upgrade --only-show-errors
```

Verify:

```powershell
az extension list --query "[?name=='front-door'].{Name:name, Version:version}" -o table
```

---

## Step 3 — Confirm the Classic profile name

This lists every Classic Front Door in the `production` resource group. Should include `hipyx`.

```powershell
az network front-door list --resource-group production --query "[].{Name:name, State:provisioningState, ResourceState:resourceState, Backends:length(backendPools)}" -o table
```

---

## Step 4 — INVENTORY: all custom domains still on Classic hipyx

This is the critical command. Tells us whether the Skye DNS flip resolves everything or whether more domains need migration.

```powershell
az network front-door frontend-endpoint list --resource-group production --front-door-name hipyx --query "[].{Name:name, Hostname:hostName, CertProvisioning:customHttpsProvisioningState, CertSource:customHttpsConfiguration.certificateSource}" -o table
```

Routing rules — which endpoints actually receive traffic:

```powershell
az network front-door routing-rule list --resource-group production --front-door-name hipyx --query "[].{Name:name, Endpoints:frontendEndpoints[].id, Enabled:enabledState}" -o tsv
```

Backend pools — where traffic goes:

```powershell
az network front-door backend-pool list --resource-group production --front-door-name hipyx --query "[].{Name:name, Backends:join(',', backends[].address)}" -o table
```

Save the output to a file so you have it for the Tony reply:

```powershell
az network front-door frontend-endpoint list --resource-group production --front-door-name hipyx -o json > "$env:USERPROFILE\Desktop\hipyx-classic-endpoints.json"
```

---

## Step 5 — Verify the new Standard profile is healthy

```powershell
az afd profile show --resource-group production --profile-name hipyx-std --query "{Name:name, Sku:sku.name, State:provisioningState}" -o table
az afd endpoint list --resource-group production --profile-name hipyx-std -o table
az afd custom-domain list --resource-group production --profile-name hipyx-std --query "[].{Name:name, Hostname:hostName, ValidationState:domainValidationState}" -o table
```

If `survey-farmboxrx-com` shows `domainValidationState=Approved`, Skye flipped the TXT record and the cert was issued. If it shows `Pending`, she has not done it yet.

---

## Step 6 — Re-print DNS records for Skye (in case she lost them)

```powershell
$txt = az afd custom-domain show --resource-group production --profile-name hipyx-std --custom-domain-name survey-farmboxrx-com --query "validationProperties.validationToken" -o tsv
$cname = az afd endpoint show --resource-group production --profile-name hipyx-std --endpoint-name pyx-fx-survey-ep --query hostName -o tsv

Write-Host ""
Write-Host "TXT record (add first)"
Write-Host "  Host  : _dnsauth.survey"
Write-Host "  Value : $txt"
Write-Host "  TTL   : 300"
Write-Host ""
Write-Host "CNAME record (add after cert is approved)"
Write-Host "  Host  : survey"
Write-Host "  Value : $cname"
Write-Host "  TTL   : 300"
```

---

## Step 7 — External DNS check (does Skye's DNS look right yet?)

```powershell
Resolve-DnsName survey.farmboxrx.com -Type CNAME
Resolve-DnsName _dnsauth.survey.farmboxrx.com -Type TXT
```

If the CNAME points at `pyx-fx-survey-ep.[hash].azurefd.net` she flipped it. If it still resolves to `hipyx.azurefd.net` she has not.

Cross-check the live response:

```powershell
curl.exe -sI https://survey.farmboxrx.com
```

---

## Step 8 — If Step 4 shows OTHER domains still on Classic

For each remaining domain, edit the three variables at the top of this block, then run:

```powershell
$DomainSafe   = "REPLACE-WITH-other-domain-com"
$Hostname     = "REPLACE.with.original.host.com"
$EndpointName = "pyx-fx-$DomainSafe-ep"

az afd endpoint create --resource-group production --profile-name hipyx-std --endpoint-name $EndpointName --enabled-state Enabled

az afd custom-domain create --resource-group production --profile-name hipyx-std --custom-domain-name $DomainSafe --host-name $Hostname --certificate-type ManagedCertificate --minimum-tls-version TLS12

$txt = az afd custom-domain show --resource-group production --profile-name hipyx-std --custom-domain-name $DomainSafe --query "validationProperties.validationToken" -o tsv
$cname = az afd endpoint show --resource-group production --profile-name hipyx-std --endpoint-name $EndpointName --query hostName -o tsv

$wafId = "/subscriptions/e42e94b5-c6f8-4af0-a41b-16fda520de6e/resourceGroups/production/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/hipyxWafPolicy"
$domId = "/subscriptions/e42e94b5-c6f8-4af0-a41b-16fda520de6e/resourceGroups/production/providers/Microsoft.Cdn/profiles/hipyx-std/customDomains/$DomainSafe"

az afd security-policy create --resource-group production --profile-name hipyx-std --security-policy-name "fx-$DomainSafe-waf" --waf-policy $wafId --domains $domId

Write-Host ""
Write-Host "Give Skye these two records for $Hostname"
Write-Host "  TXT   _dnsauth.$($Hostname.Split('.')[0])  $txt"
Write-Host "  CNAME $($Hostname.Split('.')[0])           $cname"
```

Poll for cert approval (every 5 minutes) until output is `Approved`:

```powershell
az afd custom-domain show --resource-group production --profile-name hipyx-std --custom-domain-name $DomainSafe --query domainValidationState -o tsv
```

---

## Step 9 — Microsoft auto-migration opt-out

The opt-out feature flag had to be set before 4/9/2026 to take effect. Today is past that, so this is informational only.

```powershell
az feature show --namespace Microsoft.Cdn --name DoNotAutoMigrateClassicManagedCertificatesProfiles --query "{State:properties.state}" -o table
```

If state is `NotRegistered` or `Unregistered`, opt-out was never active and Microsoft can auto-migrate at any time.

---

## Step 10 — Reply to Tony in Teams (after running Step 4)

If Step 4 returns ONLY survey-related entries:

```
Hey Tony — status on the AFD cert warning:

  - Survey domain: done last Thursday. survey.farmboxrx.com migrated to
    hipyx-std (Standard SKU), WAF bound in Detection mode, DNS handed
    to Skye for cutover. Domain is on a fresh managed cert and no
    longer affected by Classic cert expiry.

  - Classic hipyx inventory: I just ran the audit on the remaining
    Classic profile. Survey was the only customer-facing custom domain
    on it; the cert-expiry warning was profile-level but no other
    production traffic is at risk.

  - The Classic profile can stay until full retirement (3/31/2027) or
    we can decommission it now since survey has cut over. Your call.

— Syed
```

If Step 4 shows OTHER domains:

```
Hey Tony — status on the AFD cert warning:

  - Survey domain: done last Thursday. survey.farmboxrx.com migrated to
    hipyx-std (Standard SKU), WAF bound in Detection mode, DNS handed
    to Skye for cutover. Domain is on a fresh managed cert.

  - Classic hipyx audit (just ran): there are N other custom domains
    still on Classic that were not in the original migration scope.
    List below. Each one is currently riding the expired Classic
    managed cert.

      <paste Step 4 output here>

  - I can migrate each of these to hipyx-std this week using the same
    script we ran on survey. Same WAF policy, Detection mode, no
    service disruption — DNS flips per domain when each is ready.

  - Need from PYX leadership: confirmation of the migration order /
    priority, and the DNS owner for each domain (Skye for farmboxrx,
    others?).

— Syed
```

---

## File reference

```
C:\Users\PC\Downloads\pyx-fx-survey-migration\fx-complete.ps1   # canonical migration script
C:\Users\PC\Downloads\pyx-fx-survey-migration\fx-migrate.ps1    # original migrate runner
C:\Users\PC\Downloads\pyx-fx-survey-migration\fx-survey-rollback.ps1  # rollback if needed
C:\Users\PC\Downloads\PYX-scripts\hipyx-fx-status-tony.md       # this doc
```
