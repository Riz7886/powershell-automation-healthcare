$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

$SubscriptionId = "e42e94b5-c6f8-4af0-a41b-16fda520de6e"
$ResourceGroup  = "production"
$ClassicProfile = "hipyx"
$StandardProfile = "hipyx-std"
$StandardEndpoint = "pyx-fx-survey-ep"
$SurveyDomainSafe = "survey-farmboxrx-com"

function Section($title) {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host $title -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor Cyan
}

function Pass($msg) { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Note($msg) { Write-Host "  [..] $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "  [XX] $msg" -ForegroundColor Red }

Section "1. Login + subscription"
$acct = $null
try { $acct = az account show --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
if (-not $acct) {
    Note "Not logged in. Launching az login..."
    az login --only-show-errors | Out-Null
}
az account set --subscription $SubscriptionId --only-show-errors | Out-Null
$current = az account show --query "{Name:name, Id:id, User:user.name}" -o json | ConvertFrom-Json
Pass "Subscription: $($current.Name) ($($current.Id))"
Pass "Signed in as: $($current.User)"

Section "2. Install Classic Front Door extension (idempotent)"
$installed = az extension list --query "[?name=='front-door'].name" -o tsv 2>$null
if ($installed) {
    Pass "front-door extension already installed"
    az extension update --name front-door --only-show-errors 2>$null | Out-Null
} else {
    Note "Installing front-door extension..."
    az extension add --name front-door --only-show-errors | Out-Null
    Pass "front-door extension installed"
}

Section "3. Sanity check - confirm Classic hipyx exists"
$classicList = az network front-door list --resource-group $ResourceGroup --query "[].{Name:name, State:provisioningState, ResourceState:resourceState}" -o json 2>$null | ConvertFrom-Json
if ($classicList) {
    $classicList | Format-Table -AutoSize
} else {
    Fail "No Classic Front Door profiles found in RG '$ResourceGroup'"
}

Section "4. INVENTORY - all custom domains still on Classic hipyx (the answer to Tony)"
$endpoints = az network front-door frontend-endpoint list --resource-group $ResourceGroup --front-door-name $ClassicProfile --query "[].{Name:name, Hostname:hostName, CertProvisioning:customHttpsProvisioningState, CertSource:customHttpsConfiguration.certificateSource}" -o json 2>$null | ConvertFrom-Json
if ($endpoints) {
    $endpoints | Format-Table -AutoSize
    Pass "$($endpoints.Count) frontend endpoint(s) on Classic hipyx"
} else {
    Note "No frontend endpoints returned from Classic hipyx"
}

Section "5. Routing rules on Classic"
$routing = az network front-door routing-rule list --resource-group $ResourceGroup --front-door-name $ClassicProfile --query "[].{Name:name, Endpoints:frontendEndpoints[].id, Enabled:enabledState}" -o json 2>$null | ConvertFrom-Json
if ($routing) { $routing | Format-Table -AutoSize } else { Note "No routing rules returned" }

Section "6. Backend pools on Classic"
$pools = az network front-door backend-pool list --resource-group $ResourceGroup --front-door-name $ClassicProfile --query "[].{Name:name, Backends:backends[].address}" -o json 2>$null | ConvertFrom-Json
if ($pools) {
    foreach ($p in $pools) {
        Write-Host ("  Pool: " + $p.Name + "  ->  " + ($p.Backends -join ", "))
    }
} else {
    Note "No backend pools returned"
}

Section "7. Save full Classic endpoint detail to Desktop"
$jsonPath = Join-Path $env:USERPROFILE "Desktop\hipyx-classic-endpoints.json"
az network front-door frontend-endpoint list --resource-group $ResourceGroup --front-door-name $ClassicProfile -o json 2>$null | Out-File -FilePath $jsonPath -Encoding UTF8
if (Test-Path $jsonPath) { Pass "Saved: $jsonPath" } else { Fail "Could not save JSON" }

Section "8. Verify hipyx-std is healthy"
$std = az afd profile show --resource-group $ResourceGroup --profile-name $StandardProfile --query "{Name:name, Sku:sku.name, State:provisioningState}" -o json 2>$null | ConvertFrom-Json
if ($std) {
    $std | Format-Table -AutoSize
} else {
    Fail "hipyx-std profile not found"
}

$stdEndpoints = az afd endpoint list --resource-group $ResourceGroup --profile-name $StandardProfile --query "[].{Name:name, Hostname:hostName, State:enabledState}" -o json 2>$null | ConvertFrom-Json
if ($stdEndpoints) {
    Write-Host ""
    Write-Host "  Standard endpoints:"
    $stdEndpoints | Format-Table -AutoSize
}

$stdDomains = az afd custom-domain list --resource-group $ResourceGroup --profile-name $StandardProfile --query "[].{Name:name, Hostname:hostName, ValidationState:domainValidationState}" -o json 2>$null | ConvertFrom-Json
if ($stdDomains) {
    Write-Host "  Standard custom domains:"
    $stdDomains | Format-Table -AutoSize
}

Section "9. Did Skye flip DNS yet? (external check)"
try {
    $cname = Resolve-DnsName -Name "survey.farmboxrx.com" -Type CNAME -ErrorAction Stop
    Write-Host "  CNAME for survey.farmboxrx.com:"
    $cname | Where-Object { $_.Type -eq "CNAME" } | Format-Table Name, NameHost -AutoSize
} catch {
    Fail "DNS lookup CNAME failed: $($_.Exception.Message)"
}

try {
    $txt = Resolve-DnsName -Name "_dnsauth.survey.farmboxrx.com" -Type TXT -ErrorAction Stop
    Write-Host "  TXT for _dnsauth.survey.farmboxrx.com:"
    $txt | Format-Table Name, Strings -AutoSize
} catch {
    Note "TXT for _dnsauth.survey.farmboxrx.com not present (Skye may have removed it after cert issuance, that is normal)"
}

try {
    $live = curl.exe -sI "https://survey.farmboxrx.com" 2>$null | Select-Object -First 8
    Write-Host "  Live response from survey.farmboxrx.com:"
    $live | ForEach-Object { Write-Host "    $_" }
} catch {}

Section "10. Re-print DNS records for Skye (in case she lost them)"
$txtToken = az afd custom-domain show --resource-group $ResourceGroup --profile-name $StandardProfile --custom-domain-name $SurveyDomainSafe --query "validationProperties.validationToken" -o tsv 2>$null
$cnameTarget = az afd endpoint show --resource-group $ResourceGroup --profile-name $StandardProfile --endpoint-name $StandardEndpoint --query hostName -o tsv 2>$null
Write-Host ""
if ($txtToken) {
    Write-Host "  TXT record"
    Write-Host "    Host  : _dnsauth.survey"
    Write-Host "    Value : $txtToken"
    Write-Host "    TTL   : 300"
    Write-Host ""
}
if ($cnameTarget) {
    Write-Host "  CNAME record"
    Write-Host "    Host  : survey"
    Write-Host "    Value : $cnameTarget"
    Write-Host "    TTL   : 300"
}

Section "11. Auto-migration opt-out flag status (informational)"
$flag = az feature show --namespace Microsoft.Cdn --name DoNotAutoMigrateClassicManagedCertificatesProfiles --query "{State:properties.state}" -o json 2>$null | ConvertFrom-Json
if ($flag) {
    $flag | Format-Table -AutoSize
} else {
    Note "Feature flag query returned nothing (probably not registered)"
}

Write-Host ""
Write-Host ("=" * 78) -ForegroundColor Green
Write-Host "  DONE - now look at Section 4 (INVENTORY) above to write Tony's reply" -ForegroundColor Green
Write-Host ("=" * 78) -ForegroundColor Green
Write-Host ""
