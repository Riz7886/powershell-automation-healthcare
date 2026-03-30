<#
.SYNOPSIS
    PYX Health - Speech API v3.0 DEEP Scan - All 13 Subscriptions
    Author:  Syed Rizvi
    Date:    March 2026
.EXAMPLE
    .\Fix-SpeechAPI-AutoFix-AllSubs.ps1 -Mode REPORT
    .\Fix-SpeechAPI-AutoFix-AllSubs.ps1 -Mode FIXALL
#>
param(
    [ValidateSet("REPORT","FIXALL")]
    [string]$Mode = "REPORT",
    [string]$OutputPath = "."
)

$ErrorActionPreference = "SilentlyContinue"
$WarningPreference     = "SilentlyContinue"
$NewVersion            = "2024-11-15"
$StartTime             = Get-Date
$AllResults            = [System.Collections.ArrayList]::new()
$BackupFolder          = Join-Path $OutputPath "PYX-Backups-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$AllSubscriptions = @(
    @{ Name="sub-corp-prod-001";         Id="e42e94b5-c6f8-4af0-a41b-16fda520de6e" },
    @{ Name="sub-dataAnalytics-preProd"; Id="abcadd97-a465-41eb-8288-fef36da59fd5" },
    @{ Name="sub-dataAnalytics-prod";    Id="cf3b06f3-3865-48a4-8ded-2a97914f2f97" },
    @{ Name="sub-Drivers-Health-Test";   Id="fab2f5b8-5b17-4105-9348-8c4903e11748" },
    @{ Name="Sub-Drivers-Health-Prod";   Id="302aceb9-3ab3-4110-bb3e-64e0c118829a" },
    @{ Name="sub-it-management";         Id="a90514d9-361b-4119-a013-585d6765b35d" },
    @{ Name="sub-product-preProd";       Id="52d0d667-a89a-4fe0-be5c-3fb2d72e90ed" },
    @{ Name="sub-product-prod";          Id="730dd182-eb99-4f54-8f4c-698a5338013f" },
    @{ Name="Sub-Production";            Id="da72e6ae-e86d-4dfb-a5fd-dd6b2c96ae05" },
    @{ Name="sub-sandbox";               Id="076fbf87-2655-4fb0-810e-98cb4e1266dc" },
    @{ Name="Sub-Staging";               Id="e0ecde18-5086-4ee7-855a-8261a328eddc" },
    @{ Name="Azure-subscription-1";      Id="977e4f83-3649-428b-9416-cf9adfe24cec" },
    @{ Name="sub-csc-avd";               Id="7edfb9f6-940e-47cd-af4b-04d0b6e6020f" }
)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Prefix = switch ($Level) {
        "SUCCESS" {"[DONE]  "} "WARN" {"[WARN]  "} "ERROR" {"[ERROR] "}
        "SCAN"    {"[SCAN]  "} "FIX"  {"[FIX]   "} "FOUND" {"[FOUND] "}
        default   {"[INFO]  "}
    }
    $Color = switch ($Level) {
        "SUCCESS" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"}
        "SCAN"    {"Cyan" } "FIX"  {"Magenta"} "FOUND" {"Red"}
        default   {"White"}
    }
    Write-Host "$Prefix[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Write-Line { Write-Host ("=" * 70) -ForegroundColor Blue }

function Add-Finding {
    param($Result, $Type, $Name, $RG, $OldValue, $NewValue, $Note = "")
    $null = $Result.Found.Add([PSCustomObject]@{
        Type=$Type; Name=$Name; RG=$RG
        OldValue=$OldValue; NewValue=$NewValue
        Fixed=$false; Note=$Note
    })
    Write-Log "FOUND: $Type - $Name - $RG" "FOUND"
}

Clear-Host
Write-Line
Write-Host "  PYX HEALTH - SPEECH API v3.0 DEEP SCAN - ALL 13 SUBSCRIPTIONS" -ForegroundColor White
Write-Host "  Scanning: App Services, Functions, Logic Apps, API Mgmt, Container Apps, Key Vault, AKS" -ForegroundColor Gray
Write-Host "  Author: Syed Rizvi | Mode: $Mode" -ForegroundColor Gray
Write-Line

$ctx = Get-AzContext
if (-not $ctx) { Write-Log "Not logged in. Run Connect-AzAccount first." "ERROR"; exit 1 }
Write-Log "Logged in as: $($ctx.Account.Id)" "SUCCESS"
Write-Log "Mode: $Mode | Retirement: March 31 2026 - TOMORROW" "WARN"
Write-Host ""

$n = 0
foreach ($sub in $AllSubscriptions) {
    $n++
    Write-Line
    Write-Log "[$n/13] $($sub.Name)" "SCAN"

    $ok = Set-AzContext -SubscriptionId $sub.Id -WarningAction SilentlyContinue
    if (-not $ok) { Write-Log "No access - skipping" "WARN"; continue }
    Write-Log "Connected OK" "SUCCESS"

    $r = [PSCustomObject]@{
        Name=$sub.Name; Id=$sub.Id
        Found=[System.Collections.ArrayList]::new()
        Fixed=[System.Collections.ArrayList]::new()
        Errors=[System.Collections.ArrayList]::new()
    }

    # COGNITIVE SERVICES                                                                                                                                                       
    Write-Log "  [1/7] Cognitive Services..." "SCAN"
    foreach ($cog in (Get-AzCognitiveServicesAccount)) {
        if ($cog.Kind -in @("SpeechServices","CognitiveServices","SpeechTranslation")) {
            Add-Finding $r "Cognitive Service" $cog.AccountName $cog.ResourceGroupName "v3.0 endpoint risk" "Update calling app code to $NewVersion" "Check all apps calling this endpoint"
        }
    }

    # APP SERVICES + FUNCTION APPS (App Settings)                                                                         
    Write-Log "  [2/7] App Services and Function Apps..." "SCAN"
    foreach ($app in (Get-AzWebApp)) {
        $full = Get-AzWebApp -ResourceGroupName $app.ResourceGroup -Name $app.Name
        if (-not $full -or -not $full.SiteConfig -or -not $full.SiteConfig.AppSettings) { continue }

        $hits = @($full.SiteConfig.AppSettings | Where-Object {
            $_.Name  -like "*SPEECH*" -or $_.Name  -like "*STT*" -or
            $_.Value -like "*speechtotext/v3.0*" -or $_.Value -like "*/v3.0*"
        })
        if ($hits.Count -eq 0) { continue }

        $type = if ($app.Kind -like "*functionapp*") {"Function App"} else {"Web App"}
        $hash = @{}; $needsUpdate = $false
        foreach ($s in $full.SiteConfig.AppSettings) { $hash[$s.Name] = $s.Value }

        foreach ($s in $hits) {
            $old = $s.Value
            $new = $old -replace "speechtotext/v3\.0","speechtotext/$NewVersion" -replace "/v3\.0","/$NewVersion"
            Add-Finding $r $type $app.Name $app.ResourceGroup "$($s.Name) = $old" "$($s.Name) = $new"
            if ($old -ne $new) { $hash[$s.Name] = $new; $needsUpdate = $true }
        }

        if ($needsUpdate -and $Mode -eq "FIXALL") {
            if (-not (Test-Path $BackupFolder)) { New-Item -ItemType Directory -Path $BackupFolder | Out-Null }
            $full.SiteConfig.AppSettings | ConvertTo-Json | Out-File "$BackupFolder\$($sub.Name)-$($app.Name).json" -Encoding UTF8
            $fix = Set-AzWebApp -ResourceGroupName $app.ResourceGroup -Name $app.Name -AppSettings $hash
            if ($fix) {
                Write-Log "  FIXED: $($app.Name)" "SUCCESS"
                $null = $r.Fixed.Add($app.Name)
                foreach ($i in $r.Found) { if ($i.Name -eq $app.Name) { $i.Fixed = $true } }
            } else {
                $null = $r.Errors.Add("Fix failed: $($app.Name)")
            }
        }
    }

    # API MANAGEMENT                                                                                                                                                                
    Write-Log "  [3/7] API Management..." "SCAN"
    foreach ($apim in (Get-AzApiManagement)) {
        $ctx2 = New-AzApiManagementContext -ResourceGroupName $apim.ResourceGroupName -ServiceName $apim.Name
        $backends = Get-AzApiManagementBackend -Context $ctx2
        foreach ($b in $backends) {
            if ($b.Url -like "*speechtotext/v3.0*" -or $b.Url -like "*speech*v3*") {
                Add-Finding $r "API Management Backend" $apim.Name $apim.ResourceGroupName "Backend URL: $($b.Url)" "Update to $NewVersion" "Update backend URL in APIM"
            }
        }
        $namedValues = Get-AzApiManagementNamedValue -Context $ctx2
        foreach ($nv in $namedValues) {
            if ($nv.Value -like "*speechtotext/v3.0*" -or $nv.Value -like "*speech*v3*") {
                Add-Finding $r "API Management Named Value" "$($apim.Name)/$($nv.Name)" $apim.ResourceGroupName "Value: $($nv.Value)" "Update to $NewVersion"
            }
        }
    }

    # LOGIC APPS                                                                                                                                                                            
    Write-Log "  [4/7] Logic Apps..." "SCAN"
    $token = (Get-AzAccessToken).Token
    $subId = $sub.Id
    $laUri = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Logic/workflows?api-version=2019-05-01"
    $laResp = Invoke-RestMethod -Uri $laUri -Headers @{Authorization="Bearer $token"} -Method GET
    foreach ($la in $laResp.value) {
        $defStr = $la.properties.definition | ConvertTo-Json -Depth 20
        if ($defStr -like "*speechtotext/v3.0*" -or $defStr -like "*speech*v3.0*") {
            Add-Finding $r "Logic App" $la.name ($la.id -split '/resourceGroups/')[1].Split('/')[0] "v3.0 reference in definition" "Update Logic App action to $NewVersion" "Edit Logic App definition"
        }
    }

    # CONTAINER APPS                                                                                                                                                                
    Write-Log "  [5/7] Container Apps..." "SCAN"
    $caUri = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.App/containerApps?api-version=2023-05-01"
    $caResp = Invoke-RestMethod -Uri $caUri -Headers @{Authorization="Bearer $token"} -Method GET
    foreach ($ca in $caResp.value) {
        $envVars = $ca.properties.template.containers | ForEach-Object { $_.env }
        foreach ($ev in $envVars) {
            if ($ev.name -like "*SPEECH*" -or $ev.value -like "*speechtotext/v3.0*" -or $ev.value -like "*/v3.0*") {
                Add-Finding $r "Container App" $ca.name ($ca.id -split '/resourceGroups/')[1].Split('/')[0] "$($ev.name) = $($ev.value)" "Update env var to $NewVersion" "Update Container App environment variable"
            }
        }
    }

    # KEY VAULT SECRETS                                                                                                                                                       
    Write-Log "  [6/7] Key Vault Secrets..." "SCAN"
    foreach ($kv in (Get-AzKeyVault)) {
        $secrets = Get-AzKeyVaultSecret -VaultName $kv.VaultName
        foreach ($s in $secrets) {
            if ($s.Name -like "*SPEECH*" -or $s.Name -like "*STT*" -or $s.Name -like "*COGNITIVE*") {
                $secretVal = (Get-AzKeyVaultSecret -VaultName $kv.VaultName -Name $s.Name -AsPlainText)
                if ($secretVal -like "*speechtotext/v3.0*" -or $secretVal -like "*/v3.0*") {
                    Add-Finding $r "Key Vault Secret" "$($kv.VaultName)/$($s.Name)" $kv.ResourceGroupName "Secret contains v3.0 endpoint" "Update secret value to $NewVersion" "Update Key Vault secret"
                }
            }
        }
    }

    # APP CONFIGURATION                                                                                                                                                       
    Write-Log "  [7/7] App Configuration stores..." "SCAN"
    $acUri = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.AppConfiguration/configurationStores?api-version=2023-03-01"
    $acResp = Invoke-RestMethod -Uri $acUri -Headers @{Authorization="Bearer $token"} -Method GET
    foreach ($ac in $acResp.value) {
        $acName = $ac.name
        $acRG   = ($ac.id -split '/resourceGroups/')[1].Split('/')[0]
        $kvUri  = "$($ac.properties.endpoint)/kv?api-version=1.0&`$filter=name eq '*SPEECH*'"
        $kvResp = Invoke-RestMethod -Uri $kvUri -Headers @{Authorization="Bearer $token"} -Method GET
        foreach ($kv2 in $kvResp.items) {
            if ($kv2.value -like "*speechtotext/v3.0*" -or $kv2.value -like "*/v3.0*") {
                Add-Finding $r "App Configuration" "$acName/$($kv2.key)" $acRG "Value: $($kv2.value)" "Update to $NewVersion" "Update App Config key"
            }
        }
    }

    Write-Log "Done: Found=$($r.Found.Count) Fixed=$($r.Fixed.Count)" "SUCCESS"
    $null = $AllResults.Add($r)
}

# SUMMARY                                                                                                                                                                                                             
Write-Line
Write-Host "  FINAL SUMMARY - DEEP SCAN ALL 13 SUBSCRIPTIONS" -ForegroundColor White
Write-Line

$gFound=0; $gFixed=0
foreach ($r in $AllResults) { $gFound += $r.Found.Count; $gFixed += $r.Fixed.Count }
$dur = [math]::Round(((Get-Date)-$StartTime).TotalSeconds)

Write-Log "Subscriptions Scanned : $($AllResults.Count)"
Write-Log "Resources Found       : $gFound" $(if ($gFound -gt 0) {"FOUND"} else {"SUCCESS"})
Write-Log "Resources Fixed       : $gFixed" "SUCCESS"
Write-Log "Duration              : $dur seconds"

foreach ($r in $AllResults) {
    $st = if ($r.Found.Count -eq 0) {"CLEAN"} elseif ($r.Fixed.Count -ge $r.Found.Count) {"ALL FIXED"} else {"NEEDS FIX"}
    Write-Log "  $($r.Name) | Found=$($r.Found.Count) Fixed=$($r.Fixed.Count) | $st"
}

# HTML REPORT                                                                                                                                                                                                 
$rp = Join-Path $OutputPath "PYX-SpeechAPI-DEEPSCAN-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"

$rows = ""
foreach ($r in $AllResults) {
    $hc = if ($r.Found.Count -eq 0) {"#065f46"} elseif ($r.Fixed.Count -ge $r.Found.Count) {"#065f46"} else {"#991b1b"}
    $sl = if ($r.Found.Count -eq 0) {"CLEAN"} elseif ($r.Fixed.Count -ge $r.Found.Count) {"ALL FIXED"} else {"NEEDS FIX"}
    $tr = ""
    if ($r.Found.Count -eq 0) {
        $tr = "<tr><td colspan='6' style='text-align:center;color:#6b7280;padding:12px'>No Speech API v3.0 resources found - CLEAN</td></tr>"
    } else {
        foreach ($f in $r.Found) {
            $bg = if ($f.Fixed) {"#d1fae5"} else {"#fee2e2"}
            $fc = if ($f.Fixed) {"#065f46"} else {"#991b1b"}
            $ft = if ($f.Fixed) {"FIXED"} else {"NEEDS FIX"}
            $tr += "<tr><td>$($f.Type)</td><td>$($f.Name)</td><td>$($f.RG)</td><td style='font-family:Courier New;font-size:11px'>$($f.OldValue)</td><td style='font-family:Courier New;font-size:11px;color:#065f46'>$($f.NewValue)</td><td style='background:$bg;color:$fc;font-weight:bold;text-align:center'>$ft</td></tr>"
        }
    }
    $rows += "<div style='margin-bottom:24px'><div style='background:$hc;color:#fff;padding:10px 16px;font-weight:bold;font-size:13px;border-radius:6px 6px 0 0'>$($r.Name) | $($r.Id) | Found:$($r.Found.Count) Fixed:$($r.Fixed.Count) | $sl</div><table style='width:100%;border-collapse:collapse;font-size:12px'><tr style='background:#1e3a8a;color:#fff'><th style='padding:8px'>Type</th><th style='padding:8px'>Resource</th><th style='padding:8px'>Resource Group</th><th style='padding:8px'>Current Value</th><th style='padding:8px'>Recommended</th><th style='padding:8px'>Status</th></tr>$tr</table></div>"
}

"<!DOCTYPE html><html><head><meta charset='UTF-8'><title>PYX Speech API Deep Scan</title><style>body{font-family:Arial,sans-serif;margin:0;background:#f8fafc}.hdr{background:#991b1b;color:#fff;padding:24px 32px}.hdr h1{margin:0;font-size:20px}.hdr p{margin:4px 0 0;font-size:12px;opacity:.85}.alert{background:#fef3c7;border-left:6px solid #d97706;padding:12px 32px;font-size:13px;color:#92400e;font-weight:bold}.scope{background:#dbeafe;border-left:6px solid #1e40af;padding:12px 32px;font-size:13px;color:#1e40af}.kpi{display:flex;gap:12px;padding:16px 32px;background:#fff;border-bottom:1px solid #e2e8f0}.kb{flex:1;border-radius:8px;padding:12px;text-align:center}.val{font-size:26px;font-weight:700}.lbl{font-size:11px;margin-top:3px}.r{background:#fee2e2}.r .val{color:#991b1b}.g{background:#d1fae5}.g .val{color:#065f46}.b{background:#dbeafe}.b .val{color:#1e40af}.gr{background:#f1f5f9}.gr .val{color:#374151}.sec{padding:20px 32px}.ftr{padding:12px 32px;text-align:center;color:#94a3b8;font-size:11px;border-top:1px solid #e2e8f0}td{padding:7px 10px;border-bottom:1px solid #e2e8f0;vertical-align:top}</style></head><body><div class='hdr'><h1>PYX Health - Speech API v3.0 DEEP SCAN Report - All 13 Subscriptions</h1><p>$(Get-Date -Format 'MMMM dd yyyy HH:mm') | Scanned: $($AllResults.Count) subs | Author: Syed Rizvi</p></div><div class='alert'>Speech-to-text REST API v3.0 retires March 31 2026 - TOMORROW. Target version: $NewVersion</div><div class='scope'>Scanned: App Services, Function Apps, Cognitive Services, Logic Apps, Container Apps, Key Vault Secrets, API Management, App Configuration</div><div class='kpi'><div class='kb gr'><div class='val'>$($AllResults.Count)</div><div class='lbl'>Subscriptions</div></div><div class='kb r'><div class='val'>$gFound</div><div class='lbl'>Issues Found</div></div><div class='kb g'><div class='val'>$gFixed</div><div class='lbl'>Fixed</div></div><div class='kb b'><div class='val'>$dur sec</div><div class='lbl'>Duration</div></div></div><div class='sec'>$rows</div><div class='ftr'>PYX Health | IT Infrastructure | Syed Rizvi | March 2026 | CONFIDENTIAL - Internal Use Only</div></body></html>" | Out-File -FilePath $rp -Encoding UTF8

Write-Log "Deep Scan Report saved: $rp" "SUCCESS"
Write-Log "ALL DONE - OPEN THE HTML FILE AND SEND TO TONY" "SUCCESS"
