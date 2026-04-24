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

function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$AzArgs)
    $out  = & az @AzArgs 2>&1
    $exit = $LASTEXITCODE
    return [pscustomobject]@{ Output = ($out | Out-String); Exit = $exit }
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
$wafCheck = Invoke-Az network front-door waf-policy show --resource-group $ResourceGroup --name $WafPolicyName -o tsv --query id --only-show-errors
if ($wafCheck.Exit -eq 0 -and $wafCheck.Output.Trim().Length -gt 0) {
    Log "WAF already exists: $WafPolicyName" "Green"
} else {
    Log "Creating WAF policy..." "Yellow"
    $wafCreate = Invoke-Az network front-door waf-policy create --resource-group $ResourceGroup --name $WafPolicyName --mode Detection --sku $Sku --only-show-errors
    if ($wafCreate.Exit -eq 0) {
        Log "WAF created: $WafPolicyName" "Green"
    } else {
        Log "WAF create failed:" "Red"
        Log $wafCreate.Output "Red"
    }
}
Log "  (Standard SKU = custom rules only, no managed rules - Azure design)" "Gray"

Step "2. Security policy (bind WAF to $DomainSafe)"
$wafId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/frontdoorwebapplicationfirewallpolicies/$WafPolicyName"
$domId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Cdn/profiles/$NewName/customDomains/$DomainSafe"

$secCheck = Invoke-Az afd security-policy show --profile-name $NewName --resource-group $ResourceGroup --security-policy-name $SecPolicyName -o tsv --query id --only-show-errors
if ($secCheck.Exit -eq 0 -and $secCheck.Output.Trim().Length -gt 0) {
    Log "Security policy already exists: $SecPolicyName" "Green"
} else {
    Log "Creating security policy..." "Yellow"
    $secCreate = Invoke-Az afd security-policy create --profile-name $NewName --resource-group $ResourceGroup --security-policy-name $SecPolicyName --waf-policy $wafId --domains $domId --only-show-errors
    if ($secCreate.Exit -eq 0) {
        Log "Security policy created and bound" "Green"
    } else {
        $txt = $secCreate.Output
        if ($txt -match "already exists|Conflict|AlreadyExists") {
            Log "Security policy already exists (conflict on create = fine)" "Green"
        } else {
            Log "Security policy create failed:" "Red"
            Log $txt "Red"
        }
    }
}

Step "3. CNAME value (for Skye)"
$cname = ""
$cnameRes = Invoke-Az afd endpoint show --profile-name $NewName --resource-group $ResourceGroup --endpoint-name $EndpointName --query hostName -o tsv --only-show-errors
if ($cnameRes.Exit -eq 0) {
    $cname = ($cnameRes.Output -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Last 1).Trim()
    Log "CNAME = $cname" "Green"
} else {
    Log "Error fetching CNAME:" "Red"
    Log $cnameRes.Output "Red"
}

Step "4. TXT validation token (for Skye)"
$token = ""
$tokRes = Invoke-Az afd custom-domain show --profile-name $NewName --resource-group $ResourceGroup --custom-domain-name $DomainSafe --query "validationProperties.validationToken" -o tsv --only-show-errors
if ($tokRes.Exit -eq 0) {
    $token = ($tokRes.Output -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Last 1).Trim()
    Log "TXT = $token" "Green"
} else {
    Log "Error fetching TXT:" "Red"
    Log $tokRes.Output "Red"
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
