$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

$SubscriptionId = "e42e94b5-c6f8-4af0-a41b-16fda520de6e"
$ResourceGroup  = "Production"
$NewName        = "hipyx-std"
$Sku            = "Standard_AzureFrontDoor"
$DomainSafe     = "survey-farmboxrx-com"
$EndpointName   = "pyx-fx-survey-ep"
$WafPolicyName  = "hipyxWafPolicy"
$SecPolicyName  = "fx-survey-waf"

function Log ($msg, $color = "White") { Write-Host $msg -ForegroundColor $color }
function Step($msg) { Log ""; Log "====== $msg ======" "Cyan" }

function Clean-Tsv($raw) {
    (($raw | Out-String) -split "`r?`n" |
        Where-Object { $_.Trim().Length -gt 0 -and $_ -notmatch "^(WARNING|ERROR|DEBUG)" } |
        Select-Object -Last 1).Trim()
}

Step "Login check"
$acct = $null
try { $acct = az account show --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
if (-not $acct) {
    Log "Not logged in - starting az login..." "Yellow"
    az login --only-show-errors | Out-Null
}
az account set --subscription $SubscriptionId --only-show-errors | Out-Null
Log "Subscription set: $SubscriptionId" "Green"

Step "1. WAF policy ($WafPolicyName)"
$wafShowOut  = & az network front-door waf-policy show --resource-group $ResourceGroup --name $WafPolicyName --query id -o tsv --only-show-errors 2>&1
$wafShowExit = $LASTEXITCODE
if ($wafShowExit -eq 0 -and (Clean-Tsv $wafShowOut).Length -gt 0) {
    Log "WAF already exists: $WafPolicyName" "Green"
} else {
    Log "Creating WAF policy..." "Yellow"
    $wafCreateOut = & az network front-door waf-policy create --resource-group $ResourceGroup --name $WafPolicyName --mode Detection --sku $Sku --only-show-errors 2>&1
    if ($LASTEXITCODE -eq 0) {
        Log "WAF created: $WafPolicyName" "Green"
    } else {
        $t = ($wafCreateOut | Out-String)
        if ($t -match "already exists|Conflict|AlreadyExists") {
            Log "WAF already exists (conflict on create = fine)" "Green"
        } else {
            Log "WAF create failed:" "Red"
            Log $t "Red"
        }
    }
}
Log "  (Standard SKU = custom rules only, no managed rules - Azure design)" "Gray"

Step "2. Security policy (bind WAF to $DomainSafe)"
$wafId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/$WafPolicyName"
$domId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Cdn/profiles/$NewName/customDomains/$DomainSafe"

$secShowOut  = & az afd security-policy show --profile-name $NewName --resource-group $ResourceGroup --security-policy-name $SecPolicyName --query id -o tsv --only-show-errors 2>&1
$secShowExit = $LASTEXITCODE
if ($secShowExit -eq 0 -and (Clean-Tsv $secShowOut).Length -gt 0) {
    Log "Security policy already exists: $SecPolicyName" "Green"
} else {
    Log "Creating security policy..." "Yellow"
    $secCreateOut = & az afd security-policy create --profile-name $NewName --resource-group $ResourceGroup --security-policy-name $SecPolicyName --waf-policy $wafId --domains $domId --only-show-errors 2>&1
    if ($LASTEXITCODE -eq 0) {
        Log "Security policy created and bound" "Green"
    } else {
        $t = ($secCreateOut | Out-String)
        if ($t -match "already exists|Conflict|AlreadyExists") {
            Log "Security policy already exists (conflict on create = fine)" "Green"
        } else {
            Log "Security policy create failed:" "Red"
            Log $t "Red"
        }
    }
}

Step "3. CNAME value (for Skye)"
$cname = ""
$cnameOut  = & az afd endpoint show --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $EndpointName --query hostName -o tsv --only-show-errors 2>&1
$cnameExit = $LASTEXITCODE
if ($cnameExit -eq 0) {
    $cname = Clean-Tsv $cnameOut
    if ($cname) { Log "CNAME = $cname" "Green" } else { Log "CNAME returned empty" "Red" }
} else {
    Log "Error fetching CNAME:" "Red"
    Log ($cnameOut | Out-String) "Red"
}

Step "4. TXT validation token (for Skye)"
$token = ""
$tokOut  = & az afd custom-domain show --profile-name $NewName --resource-group $ResourceGroup --custom-domain-name $DomainSafe --query "validationProperties.validationToken" -o tsv --only-show-errors 2>&1
$tokExit = $LASTEXITCODE
if ($tokExit -eq 0) {
    $token = Clean-Tsv $tokOut
    if ($token) { Log "TXT = $token" "Green" } else { Log "TXT returned empty" "Red" }
} else {
    Log "Error fetching TXT:" "Red"
    Log ($tokOut | Out-String) "Red"
}

Log ""
Log "=============================================================" "Green"
Log "   DNS RECORDS FOR SKYE - farmboxrx.com zone" "Green"
Log "=============================================================" "Green"
Log ""
Log "   (1) TXT record - ADD FIRST" "Yellow"
Log "       Host  : _dnsauth.survey"
Log "       Value : $token"
Log "       TTL   : 300"
Log ""
Log "   (2) CNAME record - ADD AFTER CERT APPROVED" "Yellow"
Log "       Host  : survey"
Log "       Value : $cname"
Log "       TTL   : 300"
Log ""
Log "=============================================================" "Green"
Log ""
Log "   Check cert approval (rerun every ~5 min):" "Gray"
Log "   az afd custom-domain show --profile-name $NewName --resource-group $ResourceGroup --custom-domain-name $DomainSafe --query domainValidationState -o tsv" "Gray"
Log ""
Log "   Classic hipyx is UNTOUCHED - no impact until Skye flips DNS" "Green"
Log ""
Log "DONE" "Green"
