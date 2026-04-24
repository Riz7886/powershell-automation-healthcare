
# =============================================================================
#  PYX Health - FX Survey Portal Migration
# =============================================================================
param(
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Show,
    [string]$Subscription,
    [string]$Classic              = "hipyx",
    [string]$NewName              = "hipyx-std",
    [string]$Sku                  = "Standard_AzureFrontDoor",
    [string]$Domain               = "survey.farmboxrx.com",
    [string]$Origin               = "mycareloop.z22.web.core.windows.net",
    [string]$OriginGroupName      = "fx-survey-origin-group",
    [string]$OriginName           = "fx-survey-origin",
    [string]$RouteName            = "fx-survey-route",
    [string]$WafPolicyName        = "hipyxWafPolicy",
    [switch]$HtmlReport,
    [string]$HtmlReportPath       = ""
)

$ErrorActionPreference = "Stop"

$_boolWords = @('yes','y','no','n','true','false','t','f','confirm','ok','dryrun','htmlreport')
if ($Subscription -and ($Subscription.Trim().ToLower() -in $_boolWords)) {
    Write-Host "  xx  It looks like you passed '$Subscription' as a positional arg." -ForegroundColor Red
    Write-Host "      Did you mean: .\migrate.ps1 -Yes" -ForegroundColor Yellow
    exit 1
}

if ($HtmlReport -and -not $DryRun) { $DryRun = $true }
if ($HtmlReport -and -not $HtmlReportPath) {
    $HtmlReportPath = ".\pyx-fx-migration-plan-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
}

$DomainSafe = $Domain -replace '\.','-'
$Script:PlannedCommands = New-Object System.Collections.ArrayList

function Say  ($m) { Write-Host "`n[step] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "  ok  $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  !!  $m" -ForegroundColor Yellow }
function Die  ($m) {
    Write-Host "  xx  $m" -ForegroundColor Red
    Write-Host "  Re-run the same command to resume (idempotent)." -ForegroundColor Yellow
    exit 1
}

$Script:Completed  = New-Object System.Collections.ArrayList
$Script:Skipped    = New-Object System.Collections.ArrayList
$Script:Warnings   = New-Object System.Collections.ArrayList

function Mark-Done($what)    { [void]$Script:Completed.Add($what) }
function Mark-Skipped($what) { [void]$Script:Skipped.Add($what) }

function Confirm-Action($prompt) {
    if ($Yes) { return $true }
    $ans = Read-Host "  ?? $prompt [y/N or yes]"
    if ($null -eq $ans) { return $false }
    return $ans.ToString().Trim().ToLower().StartsWith('y')
}

$Script:IdempotentPatterns = @(
    'already exists','ResourceAlreadyExists','AlreadyExistsError',
    'Code: Conflict','The resource already exists','is already associated',
    'AssociationAlreadyExists','already attached','is already in use'
)

function Invoke-Az {
    $cmdText = "az " + ($args -join " ")
    if ($Show -or $DryRun) { Write-Host "  `$ $cmdText" -ForegroundColor Magenta }
    if ($HtmlReport) { [void]$Script:PlannedCommands.Add($cmdText) }
    if ($DryRun) { return "" }
    $output = & az @args 2>&1
    $exit = $LASTEXITCODE
    if ($exit -eq 0) { return $output }
    $errText = ($output | Out-String)
    $isBenign = $false
    foreach ($pat in $Script:IdempotentPatterns) {
        if ($errText -match [regex]::Escape($pat)) { $isBenign = $true; break }
    }
    if ($isBenign) {
        Warn "Already exists, skipping (idempotent): $cmdText"
        [void]$Script:Warnings.Add("IDEMPOTENT SKIP: $cmdText")
        return $output
    }
    Write-Host "  xx  az FAILED (exit $exit)" -ForegroundColor Red
    Write-Host "      command : $cmdText" -ForegroundColor Red
    $errText.TrimEnd() -split "`n" | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    Die "Azure CLI command above failed."
}

function Test-AzResource {
    param([string]$Type, [string]$Name, [string]$ResourceGroup, [string]$Parent)
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

Say "[0/7] Preflight checks"
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Die "Azure CLI not installed." }
$acct = $null
try { $acct = az account show --only-show-errors 2>$null | ConvertFrom-Json } catch { $acct = $null }
if (-not $acct) { Die "Not logged into Azure. Run 'az login' first." }
Ok "az CLI logged in. Active: $($acct.name)  ($($acct.id))"

$extJson = az extension list --only-show-errors 2>$null | ConvertFrom-Json
$hasExt = $false
if ($extJson) { $hasExt = @($extJson | Where-Object { $_.name -eq "front-door" }).Count -gt 0 }
if (-not $hasExt) {
    Warn "Installing az extension 'front-door'"
    az extension add --name front-door --only-show-errors --yes | Out-Null
}

Say "[1/7] Scanning subscriptions for classic profile '$Classic'"
if ($Subscription) {
    az account set --subscription $Subscription --only-show-errors | Out-Null
    $subs = @([pscustomobject]@{id=$Subscription;name=(az account show --query name -o tsv)})
    Ok "Using forced subscription: $Subscription"
} else {
    $raw  = az account list --query "[?state=='Enabled'].{id:id, name:name}" -o json --only-show-errors
    $subs = $raw | ConvertFrom-Json
}
if (-not $subs -or $subs.Count -eq 0) { Die "No enabled subscriptions found." }
Ok ("Scanning {0} subscription(s)..." -f $subs.Count)

$found = $null
$matches = 0
foreach ($s in $subs) {
    Write-Host ("      .. {0}   ({1})" -f $s.name, $s.id)
    try { az account set --subscription $s.id --only-show-errors | Out-Null } catch { continue }
    $hit = ""
    try { $hit = az network front-door list --query "[?name=='$Classic'] | [0].id" -o tsv --only-show-errors 2>$null } catch { $hit = "" }
    if (-not $hit) {
        try { $hit = az resource list --name $Classic --resource-type "Microsoft.Network/frontDoors" --query "[0].id" -o tsv --only-show-errors 2>$null } catch { $hit = "" }
    }
    if ($hit -and $hit.StartsWith("/subscriptions/")) {
        $matches++
        $rg = $hit.Split("/")[4]
        $found = [pscustomobject]@{
            SubscriptionId   = $s.id
            SubscriptionName = $s.name
            ResourceId       = $hit
            ResourceGroup    = $rg
        }
        Write-Host ("      MATCH  {0}   rg={1}" -f $s.name, $rg) -ForegroundColor Green
    }
}
if ($matches -eq 0) { Die "Classic Front Door '$Classic' not found." }
if ($matches -gt 1) { Die "Found in MULTIPLE subscriptions. Re-run with -Subscription <id>." }
Ok ("Located {0}:" -f $Classic)
Ok "  subscription: $($found.SubscriptionName) ($($found.SubscriptionId))"
Ok "  resource grp: $($found.ResourceGroup)"
az account set --subscription $found.SubscriptionId --only-show-errors | Out-Null

Say "[2/7] Plan summary"
Write-Host @"
   ACTIONS:
     1. Migrate: $Classic -> $NewName ($Sku)
     2. Create origin group + origin -> $Origin
     3. Create route '$RouteName'
     4. Add custom domain '$Domain' (Azure-managed cert)
     5. Attach WAF '$WafPolicyName' (OWASP detection)
     6. Print DNS records for farmboxrx.com

   subscription : $($found.SubscriptionNam