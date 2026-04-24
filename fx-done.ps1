$ErrorActionPreference = "Stop"

$SubscriptionId  = "e42e94b5-c6f8-4af0-a41b-16fda520de6e"
$ResourceGroup   = "Production"
$NewName         = "hipyx-std"
$Sku             = "Standard_AzureFrontDoor"
$Domain          = "survey.farmboxrx.com"
$DomainSafe      = "survey-farmboxrx-com"
$Origin          = "mycareloop.z22.web.core.windows.net"
$OriginGroupName = "fx-survey-origin-group"
$OriginName      = "fx-survey-origin"
$EndpointName    = "pyx-fx-survey-ep"
$RouteName       = "fx-survey-route"
$WafPolicyName   = "hipyxWafPolicy"

function Say ($m) { Write-Host "`n[step] $m" -ForegroundColor Cyan }
function Ok  ($m) { Write-Host "  ok  $m"   -ForegroundColor Green }
function Warn($m) { Write-Host "  !!  $m"   -ForegroundColor Yellow }
function Die ($m) { Write-Host "  xx  $m"   -ForegroundColor Red; exit 1 }

$Benign = @('already exists','ResourceAlreadyExists','AlreadyExistsError','Code: Conflict','is already associated','AssociationAlreadyExists','already attached','is already in use','already has','NameUnavailable')

function Run-Az {
    $cmdText = "az " + ($args -join " ")
    $output = & az @args 2>&1
    $exit = $LASTEXITCODE
    if ($exit -eq 0) { return $output }
    $errText = ($output | Out-String)
    foreach ($pat in $Benign) { if ($errText -match [regex]::Escape($pat)) { Warn "benign: $cmdText"; return $output } }
    Write-Host "  xx az FAILED exit=$exit" -ForegroundColor Red
    Write-Host "     cmd: $cmdText" -ForegroundColor Red
    $errText.TrimEnd() -split "`n" | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
    Die "Azure CLI failed."
}

Say "Preflight"
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Die "Azure CLI not installed." }
$acct = $null
try { $acct = az account show --only-show-errors 2>$null | ConvertFrom-Json } catch { $acct = $null }
if (-not $acct) { Die "Run 'az login' first." }
az account set --subscription $SubscriptionId --only-show-errors | Out-Null
$cur = az account show --query name -o tsv --only-show-errors
Ok "Subscription: $cur"

$extJson = az extension list --only-show-errors 2>$null | ConvertFrom-Json
$hasFD = $false
if ($extJson) { $hasFD = @($extJson | Where-Object { $_.name -eq "front-door" }).Count -gt 0 }
if (-not $hasFD) { Warn "Installing front-door extension"; az extension add --name front-door --only-show-errors --yes | Out-Null }

Say "1. Standard AFD profile"
Run-Az afd profile create --profile-name $NewName --resource-group $ResourceGroup --sku $Sku | Out-Null
Ok "Profile: $NewName"

Say "2. Origin group"
Run-Az afd origin-group create --profile-name $NewName --resource-group $ResourceGroup --origin-group-name $OriginGroupName --probe-path "/" --probe-protocol Https --probe-request-type GET --probe-interval-in-seconds 60 --sample-size 4 --successful-samples-required 3 --additional-latency-in-milliseconds 50 | Out-Null
Ok "Origin group: $OriginGroupName"

Say "3. Origin"
Run-Az afd origin create --profile-name $NewName --resource-group $ResourceGroup --origin-group-name $OriginGroupName --origin-name $OriginName --host-name $Origin --origin-host-header $Origin --http-port 80 --https-port 443 --priority 1 --weight 1000 --enabled-state Enabled | Out-Null
Ok "Origin: $OriginName -> $Origin"

Say "4. Endpoint"
Run-Az afd endpoint create --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $EndpointName --enabled-state Enabled | Out-Null
Ok "Endpoint: $EndpointName"

Say "5. Custom domain + managed cert"
Run-Az afd custom-domain create --profile-name $NewName --resource-group $ResourceGroup --custom-domain-name $DomainSafe --host-name $Domain --minimum-tls-version TLS12 --certificate-type ManagedCertificate | Out-Null
Ok "Custom domain: $DomainSafe -> $Domain"

Say "6. Route (default domain first, then attach custom domain)"
& az afd route delete --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $EndpointName --route-name $RouteName --yes 2>&1 | Out-Null
Run-Az afd route create --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $EndpointName --route-name $RouteName --origin-group $OriginGroupName --supported-protocols Https --forwarding-protocol HttpsOnly --link-to-default-domain Enabled --https-redirect Enabled --patterns-to-match "/*" | Out-Null
Ok "Route created with default domain"
Run-Az afd route update --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $EndpointName --route-name $RouteName --custom-domains $DomainSafe --link-to-default-domain Disabled | Out-Null
Ok "Custom domain attached to route, default disabled"

Say "7. WAF + managed rules"
Run-Az network front-door waf-policy create --resource-group $ResourceGroup --name $WafPolicyName --mode Detection --sku $Sku | Out-Null
Run-Az network front-door waf-policy managed-rules add --resource-group $ResourceGroup --policy-name $WafPolicyName --type Microsoft_DefaultRuleSet --version 2.1 | Out-Null
Ok "WAF: $WafPolicyName (Detection, OWASP 2.1)"

Say "8. Security policy (bind WAF to custom domain)"
$wafId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/$WafPolicyName"
$domId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Cdn/profiles/$NewName/customDomains/$DomainSafe"
Run-Az afd security-policy create --profile-name $NewName --resource-group $ResourceGroup --security-policy-name "fx-survey-waf" --waf-policy $wafId --domains $domId | Out-Null
Ok "Security policy bound."

Say "9. DNS records for Skye"
$cname = az afd endpoint show --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $EndpointName --query hostName -o tsv --only-show-errors 2>$null
$token = az afd custom-domain show --profile-name $NewName --resource-group $ResourceGroup --custom-domain-name $DomainSafe --query "validationProperties.validationToken" -o tsv --only-show-errors 2>$null

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Green
Write-Host "DNS RECORDS FOR SKYE - farmboxrx.com zone" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Green
Write-Host "1) TXT    _dnsauth.survey   =  $token   (TTL 300)  -- ADD FIRST" -ForegroundColor Cyan
Write-Host "2) CNAME  survey            =  $cname   (TTL 300)  -- ADD AFTER CERT APPROVED" -ForegroundColor Cyan
Write-Host ""
Write-Host "Check cert state (run every 5 min until 'Approved'):" -ForegroundColor Yellow
Write-Host "  az afd custom-domain show --profile-name $NewName --resource-group $ResourceGroup --custom-domain-name $DomainSafe --query domainValidationState -o tsv" -ForegroundColor Yellow
Write-Host "=============================================================" -ForegroundColor Green

Ok "DONE - Classic 'hipyx' is untouched. Flip DNS when cert is Approved."
