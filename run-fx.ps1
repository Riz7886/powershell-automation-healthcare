param(
    [switch]$DryRun,
    [switch]$Yes,
    [string]$Subscription,
    [string]$Classic         = "hipyx",
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
    param([string]$Type,[string]$Name,[string]$ResourceGroup,[string]$Parent)
    if ($DryRun) { return $false }
    try {
        switch ($Type) {
            "afd-profile"         { $r = az afd profile show --profile-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null; return -not [string]::IsNullOrEmpty($r) }
            "afd-origin-group"    { $r = az afd origin-group show --profile-name $Parent --origin-group-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null; return -not [string]::IsNullOrEmpty($r) }
            "afd-origin"          { $r = az afd origin show --profile-name $Parent --origin-group-name $OriginGroupName --origin-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null; return -not [string]::IsNullOrEmpty($r) }
            "afd-endpoint"        { $r = az afd endpoint show --profile-name $Parent --endpoint-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null; return -not [string]::IsNullOrEmpty($r) }
            "afd-route"           { $r = az afd route show --profile-name $Parent --endpoint-name $endpointName --route-name $Name --resource-group $ResourceGroup -o tsv --query id --only-show-errors 2>$null; return -not [string]::IsNullOrEmpty($r) }
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
Ok "Logged in: $($acct.name) ($($acct.id))"

$extJson = az extension list --only-show-errors 2>$null | ConvertFrom-Json
$hasExt = $false
if ($extJson) { $hasExt = @($extJson | Where-Object { $_.name -eq "front-door" }).Count -gt 0 }
if (-not $hasExt) { Warn "Installing front-door extension"; az extension add --name front-door --only-show-errors --yes | Out-Null }

Say "Scanning subs for '$Classic'"
if ($Subscription) {
    az account set --subscription $Subscription --only-show-errors | Out-Null
    $subs = @([pscustomobject]@{id=$Subscription;name=(az account show --query name -o tsv)})
} else {
    $raw  = az account list --query "[?state=='Enabled'].{id:id, name:name}" -o json --only-show-errors
    $subs = $raw | ConvertFrom-Json
}
if (-not $subs -or $subs.Count -eq 0) { Die "No enabled subs." }
Ok ("Scanning {0} subs..." -f $subs.Count)

$found = $null
$matchCount = 0
foreach ($s in $subs) {
    Write-Host ("      .. {0}   ({1})" -f $s.name, $s.id)
    try { az account set --subscription $s.id --only-show-errors | Out-Null } catch { continue }
    $hit = ""
    try { $hit = az network front-door list --query "[?name=='$Classic'] | [0].id" -o tsv --only-show-errors 2>$null } catch { $hit = "" }
    if (-not $hit) {
        try { $hit = az resource list --name $Classic --resource-type "Microsoft.Network/frontDoors" --query "[0].id" -o tsv --only-show-errors 2>$null } catch { $hit = "" }
    }
    if ($hit -and $hit.StartsWith("/subscriptions/")) {
        $matchCount++
        $rg = $hit.Split("/")[4]
        $found = [pscustomobject]@{ SubscriptionId=$s.id; SubscriptionName=$s.name; ResourceId=$hit; ResourceGroup=$rg }
        Write-Host ("      MATCH  {0}   rg={1}" -f $s.name, $rg) -ForegroundColor Green
    }
}
if ($matchCount -eq 0) { Die "'$Classic' not found." }
if ($matchCount -gt 1) { Die "Multiple matches. Use -Subscription <id>." }
Ok "Located: $($found.SubscriptionName)  rg=$($found.ResourceGroup)"
az account set --subscription $found.SubscriptionId --only-show-errors | Out-Null

Say "Plan"
Write-Host "   Migrate: $Classic -> $NewName ($Sku)"
Write-Host "   Sub: $($found.SubscriptionName)"
Write-Host "   RG : $($found.ResourceGroup)"
if ($DryRun) { Warn "DRY-RUN mode." }
if (-not (Confirm-Action "Proceed?")) { Die "Aborted." }

Say "Migrate + commit"
if (Test-AzResource -Type "afd-profile" -Name $NewName -ResourceGroup $found.ResourceGroup) {
    Ok "Standard '$NewName' exists - checking state..."
    $migState = ""
    try { $migState = az afd profile show --profile-name $NewName --resource-group $found.ResourceGroup --query "extendedProperties.migrationState" -o tsv --only-show-errors 2>$null } catch { $migState = "" }
    if ($migState -and $migState -ne "Committed") {
        Ok "State=$migState. Needs commit."
        if (-not (Confirm-Action "Commit? (retires classic)")) { Die "Aborted." }
        Invoke-Az afd profile migration-commit --profile-name $NewName --resource-group $found.ResourceGroup
    } else {
        Ok "Already committed."
    }
} else {
    if (-not (Confirm-Action "Start migration?")) { Die "Aborted." }
    Invoke-Az afd profile migrate --profile-name $NewName --resource-group $found.ResourceGroup --classic-resource-id $found.ResourceId --sku $Sku
    Ok "Standard '$NewName' created in Migrating state."
    if (-not (Confirm-Action "Commit? (retires classic)")) { Die "Aborted." }
    Invoke-Az afd profile migration-commit --profile-name $NewName --resource-group $found.ResourceGroup
}

if (-not $DryRun) {
    if (-not (Test-AzResource -Type "afd-profile" -Name $NewName -ResourceGroup $found.ResourceGroup)) { Die "Post-migrate check FAILED." }
    Ok "Phase-gate PASSED."
}

Say "Origin group + origin + route"
if (-not (Test-AzResource -Type "afd-origin-group" -Name $OriginGroupName -ResourceGroup $found.ResourceGroup -Parent $NewName)) {
    Invoke-Az afd origin-group create --profile-name $NewName --resource-group $found.ResourceGroup --origin-group-name $OriginGroupName --probe-path "/" --probe-protocol Https --probe-request-type GET --probe-interval-in-seconds 60 --sample-size 4 --successful-samples-required 3 --additional-latency-in-milliseconds 50
}
if (-not (Test-AzResource -Type "afd-origin" -Name $OriginName -ResourceGroup $found.ResourceGroup -Parent $NewName)) {
    Invoke-Az afd origin create --profile-name $NewName --resource-group $found.ResourceGroup --origin-group-name $OriginGroupName --origin-name $OriginName --host-name $Origin --origin-host-header $Origin --http-port 80 --https-port 443 --priority 1 --weight 1000 --enabled-state Enabled
}

$endpointName = ""
if (-not $DryRun) { try { $endpointName = az afd endpoint list --profile-name $NewName --resource-group $found.ResourceGroup --query "[0].name" -o tsv --only-show-errors 2>$null } catch { $endpointName = "" } }
if (-not $endpointName) {
    $endpointName = "hipyx-endpoint"
    if (-not (Test-AzResource -Type "afd-endpoint" -Name $endpointName -ResourceGroup $found.ResourceGroup -Parent $NewName)) {
        Invoke-Az afd endpoint create --profile-name $NewName --resource-group $found.ResourceGroup --endpoint-name $endpointName --enabled-state Enabled
    }
}
Ok "Endpoint: $endpointName"

if (-not (Test-AzResource -Type "afd-route" -Name $RouteName -ResourceGroup $found.ResourceGroup -Parent $NewName)) {
    Invoke-Az afd route create --profile-name $NewName --resource-group $found.ResourceGroup --endpoint-name $endpointName --route-name $RouteName --origin-group $OriginGroupName --supported-protocols Https --forwarding-protocol HttpsOnly --link-to-default-domain Disabled --https-redirect Enabled --patterns-to-match "/*"
}

Say "Custom domain + cert + WAF"
if (-not (Test-AzResource -Type "afd-custom-domain" -Name $DomainSafe -ResourceGroup $found.ResourceGroup -Parent $NewName)) {
    Invoke-Az afd custom-domain create --profile-name $NewName --resource-group $found.ResourceGroup --custom-domain-name $DomainSafe --host-name $Domain --minimum-tls-version TLS12 --certificate-type ManagedCertificate
}
Invoke-Az afd route update --profile-name $NewName --resource-group $found.ResourceGroup --endpoint-name $endpointName --route-name $RouteName --custom-domains $DomainSafe

if (-not (Test-AzResource -Type "waf-policy" -Name $WafPolicyName -ResourceGroup $found.ResourceGroup)) {
    Invoke-Az network front-door waf-policy create --resource-group $found.ResourceGroup --name $WafPolicyName --mode Detection --sku $Sku
}
Invoke-Az network front-door waf-policy managed-rules add --resource-group $found.ResourceGroup --policy-name $WafPolicyName --type Microsoft_DefaultRuleSet --version 2.1

$wafResId = "/subscriptions/$($found.SubscriptionId)/resourceGroups/$($found.ResourceGroup)/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/$WafPolicyName"
$domResId = "/subscriptions/$($found.SubscriptionId)/resourceGroups/$($found.ResourceGroup)/providers/Microsoft.Cdn/profiles/$NewName/customDomains/$DomainSafe"

if (-not (Test-AzResource -Type "afd-security-policy" -Name "fx-survey-waf" -ResourceGroup $found.ResourceGroup -Parent $NewName)) {
    Invoke-Az afd security-policy create --profile-name $NewName --resource-group $found.ResourceGroup --security-policy-name "fx-survey-waf" --waf-policy $wafResId --domains $domResId
}

Say "DNS records"
$cnameTarget = "<endpoint>.azurefd.net"
$validationToken = "<pending>"
if (-not $DryRun) {
    try {
        $cnameTarget = az afd endpoint show --profile-name $NewName --resource-group $found.ResourceGroup --endpoint-name $endpointName --query hostName -o tsv --only-show-errors 2>$null
        $validationToken = az afd custom-domain show --profile-name $NewName --resource-group $found.ResourceGroup --custom-domain-name $DomainSafe --query "validationProperties.validationToken" -o tsv --only-show-errors 2>$null
    } catch { $cnameTarget = "err"; $validationToken = "err" }
}

Write-Host ""
Write-Host "   =============================================================" -ForegroundColor Green
Write-Host "   DNS RECORDS FOR SKYE" -ForegroundColor Green
Write-Host "   =============================================================" -ForegroundColor Green
Write-Host "   1) TXT  _dnsauth.survey  =  $validationToken  (TTL 300)  -- ADD FIRST" -ForegroundColor Cyan
Write-Host "   2) CNAME survey          =  $cnameTarget       (TTL 300)  -- ADD AFTER CERT APPROVED" -ForegroundColor Cyan
Write-Host ""
Write-Host "   Check cert:" -ForegroundColor Yellow
Write-Host "     az afd custom-domain show --profile-name $NewName --resource-group $($found.ResourceGroup) --custom-domain-name $DomainSafe --query domainValidationState -o tsv" -ForegroundColor Yellow
Write-Host "   =============================================================" -ForegroundColor Green
Ok "All done."
