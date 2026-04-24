param(
    [switch]$DryRun,
    [switch]$Yes,
    [string]$SubscriptionId  = "e42e94b5-c6f8-4af0-a41b-16fda520de6e",
    [string]$ResourceGroup   = "Production",
    [string]$NewName         = "hipyx-std",
    [string]$Sku             = "Standard_AzureFrontDoor",
    [string]$Domain          = "survey.farmboxrx.com",
    [string]$Origin          = "mycareloop.z22.web.core.windows.net",
    [string]$OriginGroupName = "fx-survey-origin-group",
    [string]$OriginName      = "fx-survey-origin",
    [string]$EndpointName    = "pyx-fx-survey-ep",
    [string]$RouteName       = "fx-survey-route",
    [string]$WafPolicyName   = "hipyxWafPolicy"
)

$ErrorActionPreference = "Stop"
$DomainSafe = $Domain -replace '\.','-'

function Say  ($m) { Write-Host "`n[step] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "  ok  $m"   -ForegroundColor Green }
function Warn ($m) { Write-Host "  !!  $m"   -ForegroundColor Yellow }
function Die  ($m) { Write-Host "  xx  $m"   -ForegroundColor Red; exit 1 }

function Confirm-Action($p) {
    if ($Yes) { return $true }
    $a = Read-Host "  ?? $p [y/N]"
    if ($null -eq $a) { return $false }
    return $a.ToString().Trim().ToLower().StartsWith('y')
}

$Benign = @('already exists','ResourceAlreadyExists','AlreadyExistsError','Code: Conflict','is already associated','AssociationAlreadyExists','already attached','is already in use','already has','NameUnavailable')

function Invoke-Az {
    $cmdText = "az " + ($args -join " ")
    if ($DryRun) { Write-Host "  DRYRUN: $cmdText" -ForegroundColor Magenta; return "" }
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

function Has-Resource([string]$kind, [string]$name, [string]$parent) {
    if ($DryRun) { return $false }
    $r = ""
    try {
        switch ($kind) {
            "profile"         { $r = az afd profile show --profile-name $name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null }
            "og"              { $r = az afd origin-group show --profile-name $parent --origin-group-name $name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null }
            "origin"          { $r = az afd origin show --profile-name $parent --origin-group-name $OriginGroupName --origin-name $name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null }
            "endpoint"        { $r = az afd endpoint show --profile-name $parent --endpoint-name $name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null }
            "route"           { $r = az afd route show --profile-name $parent --endpoint-name $EndpointName --route-name $name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null }
            "cd"              { $r = az afd custom-domain show --profile-name $parent --custom-domain-name $name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null }
            "waf"             { $r = az network front-door waf-policy show --resource-group $ResourceGroup --name $name -o tsv --query id --only-show-errors 2>$null }
            "secpol"          { $r = az afd security-policy show --profile-name $parent --security-policy-name $name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null }
        }
    } catch { $r = "" }
    return -not [string]::IsNullOrEmpty($r)
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

Say "Plan"
Write-Host "   Create Standard profile: $NewName ($Sku)"
Write-Host "   RG       : $ResourceGroup"
Write-Host "   Domain   : $Domain"
Write-Host "   Origin   : $Origin"
Write-Host "   Endpoint : $EndpointName"
Write-Host "   WAF      : $WafPolicyName (Detection)"
Write-Host ""
Write-Host "   Classic 'hipyx' is LEFT ALONE. Runs in parallel until DNS flips." -ForegroundColor Yellow
if ($DryRun) { Warn "DRY-RUN mode." }
if (-not (Confirm-Action "Proceed?")) { Die "Aborted." }

Say "1. Standard AFD profile"
if (-not (Has-Resource "profile" $NewName)) {
    Invoke-Az afd profile create --profile-name $NewName --resource-group $ResourceGroup --sku $Sku
}
Ok "Profile ready: $NewName"

Say "2. Origin group + origin"
if (-not (Has-Resource "og" $OriginGroupName $NewName)) {
    Invoke-Az afd origin-group create --profile-name $NewName --resource-group $ResourceGroup --origin-group-name $OriginGroupName --probe-path "/" --probe-protocol Https --probe-request-type GET --probe-interval-in-seconds 60 --sample-size 4 --successful-samples-required 3 --additional-latency-in-milliseconds 50
}
if (-not (Has-Resource "origin" $OriginName $NewName)) {
    Invoke-Az afd origin create --profile-name $NewName --resource-group $ResourceGroup --origin-group-name $OriginGroupName --origin-name $OriginName --host-name $Origin --origin-host-header $Origin --http-port 80 --https-port 443 --priority 1 --weight 1000 --enabled-state Enabled
}

Say "3. Endpoint"
if (-not (Has-Resource "endpoint" $EndpointName $NewName)) {
    Invoke-Az afd endpoint create --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $EndpointName --enabled-state Enabled
}

Say "4. Route"
if (-not (Has-Resource "route" $RouteName $NewName)) {
    Invoke-Az afd route create --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $EndpointName --route-name $RouteName --origin-group $OriginGroupName --supported-protocols Https --forwarding-protocol HttpsOnly --link-to-default-domain Disabled --https-redirect Enabled --patterns-to-match "/*"
}

Say "5. Custom domain + managed cert"
if (-not (Has-Resource "cd" $DomainSafe $NewName)) {
    Invoke-Az afd custom-domain create --profile-name $NewName --resource-group $ResourceGroup --custom-domain-name $DomainSafe --host-name $Domain --minimum-tls-version TLS12 --certificate-type ManagedCertificate
}
Invoke-Az afd route update --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $EndpointName --route-name $RouteName --custom-domains $DomainSafe

Say "6. WAF + managed rules"
if (-not (Has-Resource "waf" $WafPolicyName)) {
    Invoke-Az network front-door waf-policy create --resource-group $ResourceGroup --name $WafPolicyName --mode Detection --sku $Sku
}
Invoke-Az network front-door waf-policy managed-rules add --resource-group $ResourceGroup --policy-name $WafPolicyName --type Microsoft_DefaultRuleSet --version 2.1

Say "7. Security policy (bind WAF to domain)"
$wafId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/$WafPolicyName"
$domId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Cdn/profiles/$NewName/customDomains/$DomainSafe"
if (-not (Has-Resource "secpol" "fx-survey-waf" $NewName)) {
    Invoke-Az afd security-policy create --profile-name $NewName --resource-group $ResourceGroup --security-policy-name "fx-survey-waf" --waf-policy $wafId --domains $domId
}

Say "8. DNS records for Skye"
$cname = "<pending>"
$token = "<pending>"
if (-not $DryRun) {
    try { $cname = az afd endpoint show --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $EndpointName --query hostName -o tsv --only-show-errors 2>$null } catch { $cname = "err" }
    try { $token = az afd custom-domain show --profile-name $NewName --resource-group $ResourceGroup --custom-domain-name $DomainSafe --query "validationProperties.validationToken" -o tsv --only-show-errors 2>$null } catch { $token = "err" }
}

Write-Host ""
Write-Host "   =============================================================" -ForegroundColor Green
Write-Host "   DNS RECORDS FOR SKYE - farmboxrx.com zone" -ForegroundColor Green
Write-Host "   =============================================================" -ForegroundColor Green
Write-Host "   1) TXT   _dnsauth.survey  =  $token  (TTL 300)  -- ADD FIRST" -ForegroundColor Cyan
Write-Host "   2) CNAME survey           =  $cname             (TTL 300)  -- ADD AFTER CERT IS APPROVED" -ForegroundColor Cyan
Write-Host ""
Write-Host "   Check cert state (run every 5 min until 'Approved'):" -ForegroundColor Yellow
Write-Host "     az afd custom-domain show --profile-name $NewName --resource-group $ResourceGroup --custom-domain-name $DomainSafe --query domainValidationState -o tsv" -ForegroundColor Yellow
Write-Host "   =============================================================" -ForegroundColor Green
Ok "All done. Classic 'hipyx' still live - retire it later via portal once survey.farmboxrx.com is confirmed serving from hipyx-std."
