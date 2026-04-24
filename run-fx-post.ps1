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
    [string]$RouteName       = "fx-survey-route",
    [string]$WafPolicyName   = "hipyxWafPolicy"
)

$ErrorActionPreference = "Stop"
$DomainSafe = $Domain -replace '\.','-'

function Say  ($m) { Write-Host "`n[step] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "  ok  $m"   -ForegroundColor Green }
function Warn ($m) { Write-Host "  !!  $m"   -ForegroundColor Yellow }
function Die  ($m) { Write-Host "  xx  $m"   -ForegroundColor Red; exit 1 }

function Confirm-Action($prompt) {
    if ($Yes) { return $true }
    $ans = Read-Host "  ?? $prompt [y/N]"
    if ($null -eq $ans) { return $false }
    return $ans.ToString().Trim().ToLower().StartsWith('y')
}

$Benign = @('already exists','ResourceAlreadyExists','AlreadyExistsError','Code: Conflict','is already associated','AssociationAlreadyExists','already attached','is already in use')

function Invoke-Az {
    $cmdText = "az " + ($args -join " ")
    if ($DryRun) { Write-Host "  DRYRUN: $cmdText" -ForegroundColor Magenta; return "" }
    $output = & az @args 2>&1
    $exit = $LASTEXITCODE
    if ($exit -eq 0) { return $output }
    $errText = ($output | Out-String)
    foreach ($pat in $Benign) { if ($errText -match [regex]::Escape($pat)) { Warn "Already exists: $cmdText"; return $output } }
    Write-Host "  xx az FAILED exit=$exit : $cmdText" -ForegroundColor Red
    $errText.TrimEnd() -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Die "Azure CLI failed."
}

function Test-AzResource {
    param([string]$Type,[string]$Name,[string]$Parent)
    if ($DryRun) { return $false }
    try {
        switch ($Type) {
            "afd-profile"         { $r = az afd profile show --profile-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null; return -not [string]::IsNullOrEmpty($r) }
            "afd-origin-group"    { $r = az afd origin-group show --profile-name $Parent --origin-group-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null; return -not [string]::IsNullOrEmpty($r) }
            "afd-origin"          { $r = az afd origin show --profile-name $Parent --origin-group-name $OriginGroupName --origin-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null; return -not [string]::IsNullOrEmpty($r) }
            "afd-endpoint"        { $r = az afd endpoint show --profile-name $Parent --endpoint-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null; return -not [string]::IsNullOrEmpty($r) }
            "afd-route"           { $r = az afd route show --profile-name $Parent --endpoint-name $script:endpointName --route-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null; return -not [string]::IsNullOrEmpty($r) }
            "afd-custom-domain"   { $r = az afd custom-domain show --profile-name $Parent --custom-domain-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null; return -not [string]::IsNullOrEmpty($r) }
            "waf-policy"          { $r = az network front-door waf-policy show --resource-group $ResourceGroup --name $Name -o tsv --query id --only-show-errors 2>$null; return -not [string]::IsNullOrEmpty($r) }
            "afd-security-policy" { $r = az afd security-policy show --profile-name $Parent --security-policy-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null; return -not [string]::IsNullOrEmpty($r) }
            default { return $false }
        }
    } catch { return $false }
}

Say "Preflight"
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Die "Azure CLI not installed." }
$acct = $null
try { $acct = az account show --only-show-errors 2>$null | ConvertFrom-Json } catch { $acct = $null }
if (-not $acct) { Die "Run 'az login' first." }
az account set --subscription $SubscriptionId --only-show-errors | Out-Null
Ok "Subscription set: $SubscriptionId"

Say "Verify Standard profile exists"
if (-not (Test-AzResource -Type "afd-profile" -Name $NewName)) {
    Die "Profile '$NewName' NOT found in RG '$ResourceGroup'. Run portal migration first: portal.azure.com -> Front Door and CDN profiles -> hipyx -> Migrate."
}
Ok "Standard profile '$NewName' present."

Say "Plan"
Write-Host "   Profile : $NewName ($Sku)"
Write-Host "   RG      : $ResourceGroup"
Write-Host "   Domain  : $Domain"
Write-Host "   Origin  : $Origin"
Write-Host "   WAF     : $WafPolicyName"
if ($DryRun) { Warn "DRY-RUN mode." }
if (-not (Confirm-Action "Proceed?")) { Die "Aborted." }

Say "Origin group + origin"
if (-not (Test-AzResource -Type "afd-origin-group" -Name $OriginGroupName -Parent $NewName)) {
    Invoke-Az afd origin-group create --profile-name $NewName --resource-group $ResourceGroup --origin-group-name $OriginGroupName --probe-path "/" --probe-protocol Https --probe-request-type GET --probe-interval-in-seconds 60 --sample-size 4 --successful-samples-required 3 --additional-latency-in-milliseconds 50
}
if (-not (Test-AzResource -Type "afd-origin" -Name $OriginName -Parent $NewName)) {
    Invoke-Az afd origin create --profile-name $NewName --resource-group $ResourceGroup --origin-group-name $OriginGroupName --origin-name $OriginName --host-name $Origin --origin-host-header $Origin --http-port 80 --https-port 443 --priority 1 --weight 1000 --enabled-state Enabled
}

Say "Endpoint + route"
$script:endpointName = ""
if (-not $DryRun) { try { $script:endpointName = az afd endpoint list --profile-name $NewName --resource-group $ResourceGroup --query "[0].name" -o tsv --only-show-errors 2>$null } catch { $script:endpointName = "" } }
if (-not $script:endpointName) {
    $script:endpointName = "hipyx-endpoint"
    if (-not (Test-AzResource -Type "afd-endpoint" -Name $script:endpointName -Parent $NewName)) {
        Invoke-Az afd endpoint create --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $script:endpointName --enabled-state Enabled
    }
}
Ok "Endpoint: $script:endpointName"

if (-not (Test-AzResource -Type "afd-route" -Name $RouteName -Parent $NewName)) {
    Invoke-Az afd route create --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $script:endpointName --route-name $RouteName --origin-group $OriginGroupName --supported-protocols Https --forwarding-protocol HttpsOnly --link-to-default-domain Disabled --https-redirect Enabled --patterns-to-match "/*"
}

Say "Custom domain"
if (-not (Test-AzResource -Type "afd-custom-domain" -Name $DomainSafe -Parent $NewName)) {
    Invoke-Az afd custom-domain create --profile-name $NewName --resource-group $ResourceGroup --custom-domain-name $DomainSafe --host-name $Domain --minimum-tls-version TLS12 --certificate-type ManagedCertificate
}
Invoke-Az afd route update --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $script:endpointName --route-name $RouteName --custom-domains $DomainSafe

Say "WAF"
if (-not (Test-AzResource -Type "waf-policy" -Name $WafPolicyName)) {
    Invoke-Az network front-door waf-policy create --resource-group $ResourceGroup --name $WafPolicyName --mode Detection --sku $Sku
}
Invoke-Az network front-door waf-policy managed-rules add --resource-group $ResourceGroup --policy-name $WafPolicyName --type Microsoft_DefaultRuleSet --version 2.1

$wafResId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/$WafPolicyName"
$domResId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Cdn/profiles/$NewName/customDomains/$DomainSafe"

if (-not (Test-AzResource -Type "afd-security-policy" -Name "fx-survey-waf" -Parent $NewName)) {
    Invoke-Az afd security-policy create --profile-name $NewName --resource-group $ResourceGroup --security-policy-name "fx-survey-waf" --waf-policy $wafResId --domains $domResId
}

Say "DNS records"
$cnameTarget = "<endpoint>.azurefd.net"
$validationToken = "<pending>"
if (-not $DryRun) {
    try {
        $cnameTarget = az afd endpoint show --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $script:endpointName --query hostName -o tsv --only-show-errors 2>$null
        $validationToken = az afd custom-domain show --profile-name $NewName --resource-group $ResourceGroup --custom-domain-name $DomainSafe --query "validationProperties.validationToken" -o tsv --only-show-errors 2>$null
    } catch { $cnameTarget = "err"; $validationToken = "err" }
}

Write-Host ""
Write-Host "   =============================================================" -ForegroundColor Green
Write-Host "   DNS RECORDS FOR SKYE" -ForegroundColor Green
Write-Host "   =============================================================" -ForegroundColor Green
Write-Host "   1) TXT  _dnsauth.survey  =  $validationToken  (TTL 300)  -- ADD FIRST" -ForegroundColor Cyan
Write-Host "   2) CNAME survey          =  $cnameTarget       (TTL 300)  -- ADD AFTER CERT APPROVED" -ForegroundColor Cyan
Write-Host ""
Write-Host "   Check cert state:" -ForegroundColor Yellow
Write-Host "     az afd custom-domain show --profile-name $NewName --resource-group $ResourceGroup --custom-domain-name $DomainSafe --query domainValidationState -o tsv" -ForegroundColor Yellow
Write-Host "   =============================================================" -ForegroundColor Green
Ok "All done."
