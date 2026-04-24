$ErrorActionPreference = "Stop"

$SubscriptionId  = "e42e94b5-c6f8-4af0-a41b-16fda520de6e"
$ResourceGroup   = "Production"
$NewName         = "hipyx-std"
$Sku             = "Standard_AzureFrontDoor"
$Domain          = "survey.farmboxrx.com"
$DomainSafe      = "survey-farmboxrx-com"
$EndpointName    = "pyx-fx-survey-ep"
$WafPolicyName   = "hipyxWafPolicy"

function Say ($m) { Write-Host "`n[step] $m" -ForegroundColor Cyan }
function Ok  ($m) { Write-Host "  ok  $m"   -ForegroundColor Green }
function Warn($m) { Write-Host "  !!  $m"   -ForegroundColor Yellow }

az account set --subscription $SubscriptionId --only-show-errors | Out-Null

Say "1. WAF policy (Standard SKU = no managed rules)"
$wafShow = az network front-door waf-policy show --resource-group $ResourceGroup --name $WafPolicyName -o tsv --query id --only-show-errors 2>$null
if (-not $wafShow) {
    az network front-door waf-policy create --resource-group $ResourceGroup --name $WafPolicyName --mode Detection --sku $Sku --only-show-errors | Out-Null
    Ok "Created WAF: $WafPolicyName"
} else {
    Ok "WAF already exists: $WafPolicyName"
}
Warn "Standard SKU = custom rules only, no managed rules. For OWASP, need Premium."

Say "2. Security policy (bind WAF to custom domain)"
$wafId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/$WafPolicyName"
$domId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Cdn/profiles/$NewName/customDomains/$DomainSafe"
$secShow = az afd security-policy show --profile-name $NewName --resource-group $ResourceGroup --security-policy-name "fx-survey-waf" -o tsv --query id --only-show-errors 2>$null
if (-not $secShow) {
    az afd security-policy create --profile-name $NewName --resource-group $ResourceGroup --security-policy-name "fx-survey-waf" --waf-policy $wafId --domains $domId --only-show-errors | Out-Null
    Ok "Security policy bound"
} else {
    Ok "Security policy already exists"
}

Say "3. DNS records for Skye"
$cname = az afd endpoint show --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $EndpointName --query hostName -o tsv --only-show-errors 2>$null
$token = az afd custom-domain show --profile-name $NewName --resource-group $ResourceGroup --custom-domain-name $DomainSafe --query "validationProperties.validationToken" -o tsv --only-show-errors 2>$null

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Green
Write-Host "DNS RECORDS FOR SKYE - farmboxrx.com zone" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Green
Write-Host "1) TXT    _dnsauth.survey   =  $token   (TTL 300)  -- ADD FIRST" -ForegroundColor Cyan
Write-Host "2) CNAME  survey            =  $cname   (TTL 300)  -- ADD AFTER CERT APPROVED" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Green

Ok "DONE - send those 2 DNS records to Skye"
