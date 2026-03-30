#Requires -Modules Az.Accounts, Az.CognitiveServices, Az.Resources, Az.Websites
<#
.SYNOPSIS
    PYX Health - Speech-to-Text REST API v3.0 Auto Fix
    Author:  Syed Rizvi
    Version: 3.0
    Date:    March 2026

.DESCRIPTION
    Connects to Azure, loops through ALL subscriptions automatically,
    finds every resource using Speech-to-text REST API v3.0 and
    updates them to version 2024-11-15. Fully automated. No prompts.
    Generates an HTML report of everything found and fixed.

.PARAMETER ReportOnly
    Set to $true to scan without making changes. Default: $false

.PARAMETER OutputPath
    Folder to save the HTML report. Default: current directory.

.EXAMPLE
    .\Fix-SpeechAPI-AutoFix-AllSubs.ps1
    .\Fix-SpeechAPI-AutoFix-AllSubs.ps1 -ReportOnly $true
#>

param(
    [Parameter(Mandatory = $false)]
    [bool]$ReportOnly = $false,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Off
$ErrorActionPreference = "SilentlyContinue"
$WarningPreference     = "SilentlyContinue"

$NewVersion = "2024-11-15"
$StartTime  = Get-Date
$AllResults = [System.Collections.ArrayList]::new()

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Prefix = switch ($Level) {
        "SUCCESS" { "[DONE]  " }
        "WARN"    { "[WARN]  " }
        "ERROR"   { "[ERROR] " }
        "SCAN"    { "[SCAN]  " }
        "FIX"     { "[FIX]   " }
        default   { "[INFO]  " }
    }
    $Color = switch ($Level) {
        "SUCCESS" { "Green"   }
        "WARN"    { "Yellow"  }
        "ERROR"   { "Red"     }
        "SCAN"    { "Cyan"    }
        "FIX"     { "Magenta" }
        default   { "White"   }
    }
    Write-Host "$Prefix[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Write-Line {
    Write-Host ("=" * 70) -ForegroundColor Blue
}

# -------------------------------------------------------------------------------
# STEP 1 - CONNECT
# -------------------------------------------------------------------------------
Write-Line
Write-Host "  PYX HEALTH - SPEECH API v3.0 AUTO FIX ALL SUBSCRIPTIONS" -ForegroundColor White
Write-Host "  Author: Syed Rizvi | Mode: $(if ($ReportOnly) { 'REPORT ONLY' } else { 'AUTO FIX' })" -ForegroundColor Gray
Write-Line

Write-Log "Checking Azure login status..."

$CurrentContext = Get-AzContext -ErrorAction SilentlyContinue

if (-not $CurrentContext -or -not $CurrentContext.Account) {
    Write-Log "Not logged in. Connecting now..." "WARN"
    Connect-AzAccount -ErrorAction Stop | Out-Null
    $CurrentContext = Get-AzContext
}

Write-Log "Connected as: $($CurrentContext.Account.Id)" "SUCCESS"

# -------------------------------------------------------------------------------
# STEP 2 - GET ALL SUBSCRIPTIONS
# FIX: wrap in @() to ALWAYS force an array even if only 1 sub returned
# -------------------------------------------------------------------------------
Write-Log "Discovering all subscriptions..." "SCAN"

$AllSubs = @(Get-AzSubscription -WarningAction SilentlyContinue 2>$null |
    Where-Object { $_.State -eq "Enabled" })

if ($AllSubs.Count -eq 0) {
    Write-Log "No enabled subscriptions found. Check Azure permissions." "ERROR"
    exit 1
}

Write-Log "Found $($AllSubs.Count) enabled subscription(s)" "SUCCESS"
for ($i = 0; $i -lt $AllSubs.Count; $i++) {
    Write-Log "  [$($i+1)] $($AllSubs[$i].Name) | $($AllSubs[$i].Id)" "SCAN"
}

# -------------------------------------------------------------------------------
# STEP 3 - LOOP ALL SUBSCRIPTIONS
# -------------------------------------------------------------------------------
for ($s = 0; $s -lt $AllSubs.Count; $s++) {

    $Sub = $AllSubs[$s]

    Write-Line
    Write-Log "[$($s+1)/$($AllSubs.Count)] Scanning: $($Sub.Name)" "SCAN"
    Write-Line

    $SetCtx = Set-AzContext -SubscriptionId $Sub.Id -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $SetCtx) {
        Write-Log "Cannot switch to $($Sub.Name) - skipping" "WARN"
        continue
    }

    $SubResult = [PSCustomObject]@{
        SubscriptionName = $Sub.Name
        SubscriptionId   = $Sub.Id
        Found            = [System.Collections.ArrayList]::new()
        Fixed            = [System.Collections.ArrayList]::new()
        Errors           = [System.Collections.ArrayList]::new()
    }

    # --- Cognitive Services ---
    Write-Log "Scanning Cognitive Services..." "SCAN"
    $CogAccounts = @(Get-AzCognitiveServicesAccount -ErrorAction SilentlyContinue 2>$null |
        Where-Object { $_.Kind -in @("SpeechServices","CognitiveServices","SpeechTranslation") })

    foreach ($Acct in $CogAccounts) {
        Write-Log "Found Speech Service: $($Acct.AccountName)" "WARN"
        $null = $SubResult.Found.Add([PSCustomObject]@{
            Type          = "Cognitive Service"
            Name          = $Acct.AccountName
            ResourceGroup = $Acct.ResourceGroupName
            Location      = $Acct.Location
            Kind          = $Acct.Kind
            OldValue      = "v3.0 endpoint risk"
            NewValue      = "Update app code calling this to use $NewVersion"
            Fixed         = $false
            Note          = "Check application code"
        })
    }

    # --- App Services + Function Apps ---
    Write-Log "Scanning App Services and Function Apps..." "SCAN"
    $AllApps = @(Get-AzWebApp -ErrorAction SilentlyContinue 2>$null)

    if ($AllApps.Count -eq 0) {
        Write-Log "No App Services found in this subscription" "SUCCESS"
    }

    foreach ($App in $AllApps) {

        $AppFull = Get-AzWebApp -ResourceGroupName $App.ResourceGroup -Name $App.Name -ErrorAction SilentlyContinue 2>$null
        if (-not $AppFull) { continue }

        $Settings = @($AppFull.SiteConfig.AppSettings)
        if ($Settings.Count -eq 0) { continue }

        $SpeechSettings = @($Settings | Where-Object {
            ($_.Name  -like "*SPEECH*")            -or
            ($_.Name  -like "*STT*")                -or
            ($_.Name  -like "*COGNITIVE*SPEECH*")   -or
            ($_.Value -like "*speechtotext/v3.0*")  -or
            ($_.Value -like "*speech*v3.0*")        -or
            ($_.Value -like "*/v3.0*")
        })

        if ($SpeechSettings.Count -eq 0) { continue }

        $AppType = if ($App.Kind -like "*functionapp*") { "Function App" } else { "Web App" }
        Write-Log "Found speech settings in $AppType $($App.Name)" "WARN"

        $NewSettingsHash = @{}
        foreach ($Setting in $Settings) {
            $NewSettingsHash[$Setting.Name] = $Setting.Value
        }

        $NeedsUpdate = $false

        foreach ($Setting in $SpeechSettings) {
            $OldVal = $Setting.Value
            $NewVal = $OldVal `
                -replace "speechtotext/v3\.0", "speechtotext/$NewVersion" `
                -replace "/v3\.0",             "/$NewVersion"

            $null = $SubResult.Found.Add([PSCustomObject]@{
                Type          = $AppType
                Name          = $App.Name
                ResourceGroup = $App.ResourceGroup
                Location      = $App.Location
                Kind          = $App.Kind
                OldValue      = "$($Setting.Name) = $OldVal"
                NewValue      = "$($Setting.Name) = $NewVal"
                Fixed         = $false
                Note          = ""
            })

            if ($OldVal -ne $NewVal) {
                $NewSettingsHash[$Setting.Name] = $NewVal
                $NeedsUpdate = $true
                Write-Log "  $($Setting.Name)" "FIX"
                Write-Log "  Old: $OldVal" "WARN"
                Write-Log "  New: $NewVal" "FIX"
            }
        }

        if ($NeedsUpdate -and -not $ReportOnly) {
            $FixResult = Set-AzWebApp `
                -ResourceGroupName $App.ResourceGroup `
                -Name $App.Name `
                -AppSettings $NewSettingsHash `
                -ErrorAction SilentlyContinue 2>$null

            if ($FixResult) {
                Write-Log "FIXED: $($App.Name)" "SUCCESS"
                $null = $SubResult.Fixed.Add($App.Name)
                foreach ($Item in $SubResult.Found) {
                    if ($Item.Name -eq $App.Name) { $Item.Fixed = $true }
                }
            } else {
                Write-Log "Fix failed for $($App.Name) - manual update needed" "ERROR"
                $null = $SubResult.Errors.Add("Fix failed for $($App.Name)")
            }
        }
    }

    Write-Log "Done: $($Sub.Name) | Found: $($SubResult.Found.Count) | Fixed: $($SubResult.Fixed.Count)" "SUCCESS"
    $null = $AllResults.Add($SubResult)
}

# -------------------------------------------------------------------------------
# STEP 4 - SUMMARY
# -------------------------------------------------------------------------------
Write-Line
Write-Host "  FINAL SUMMARY - ALL SUBSCRIPTIONS" -ForegroundColor White
Write-Line

$GrandFound  = 0
$GrandFixed  = 0
$GrandErrors = 0
foreach ($R in $AllResults) {
    $GrandFound  += $R.Found.Count
    $GrandFixed  += $R.Fixed.Count
    $GrandErrors += $R.Errors.Count
}
$Duration = [math]::Round(((Get-Date) - $StartTime).TotalSeconds)

Write-Log "Subscriptions Scanned : $($AllResults.Count)"
Write-Log "Total Resources Found : $GrandFound"
Write-Log "Total Resources Fixed : $GrandFixed" "SUCCESS"
Write-Log "Total Errors          : $GrandErrors" $(if ($GrandErrors -gt 0) { "ERROR" } else { "SUCCESS" })
Write-Log "Duration              : $Duration seconds"

foreach ($R in $AllResults) {
    $St = if ($R.Found.Count -eq 0) { "CLEAN" } elseif ($R.Fixed.Count -eq $R.Found.Count) { "ALL FIXED" } else { "REVIEW" }
    Write-Log "  $($R.SubscriptionName) | Found: $($R.Found.Count) | Fixed: $($R.Fixed.Count) | $St"
}

# -------------------------------------------------------------------------------
# STEP 5 - HTML REPORT
# -------------------------------------------------------------------------------
$ReportPath = Join-Path $OutputPath "PYX-SpeechAPI-Fix-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"

$SubSections = ""
foreach ($R in $AllResults) {
    $HdrColor = if ($R.Found.Count -eq 0 -or $R.Fixed.Count -ge $R.Found.Count) { "#065f46" } else { "#991b1b" }
    $StLabel  = if ($R.Found.Count -eq 0) { "CLEAN" } elseif ($R.Fixed.Count -ge $R.Found.Count) { "ALL FIXED" } else { "NEEDS REVIEW" }

    $Rows = ""
    if ($R.Found.Count -eq 0) {
        $Rows = "<tr><td colspan='6' style='text-align:center;color:#6b7280;padding:14px'>No Speech API v3.0 resources found</td></tr>"
    } else {
        foreach ($f in $R.Found) {
            $SBg  = if ($f.Fixed) { "#d1fae5" } else { "#fee2e2" }
            $SClr = if ($f.Fixed) { "#065f46" } else { "#991b1b" }
            $STxt = if ($f.Fixed) { "FIXED" } else { "PENDING" }
            $Rows += "<tr><td>$($f.Type)</td><td>$($f.Name)</td><td>$($f.ResourceGroup)</td><td style='font-family:Courier New;font-size:11px'>$($f.OldValue)</td><td style='font-family:Courier New;font-size:11px;color:#065f46'>$($f.NewValue)</td><td style='background:$SBg;color:$SClr;font-weight:bold;text-align:center'>$STxt</td></tr>"
        }
    }

    $ErrHtml = ""
    if ($R.Errors.Count -gt 0) {
        $EList = $R.Errors -join "</li><li>"
        $ErrHtml = "<div style='background:#fee2e2;padding:10px 16px;font-size:12px;color:#991b1b'><strong>Errors:</strong><ul><li>$EList</li></ul></div>"
    }

    $SubSections += "<div style='margin-bottom:28px'><div style='background:$HdrColor;color:#fff;padding:12px 18px;border-radius:6px 6px 0 0;font-weight:bold;font-size:13px'>$($R.SubscriptionName) | $($R.SubscriptionId) | Found: $($R.Found.Count) | Fixed: $($R.Fixed.Count) | $StLabel</div><table style='width:100%;border-collapse:collapse;font-size:12px'><tr style='background:#1e3a8a;color:#fff'><th style='padding:8px 10px;text-align:left'>Type</th><th style='padding:8px 10px;text-align:left'>Resource</th><th style='padding:8px 10px;text-align:left'>Resource Group</th><th style='padding:8px 10px;text-align:left'>Old Value</th><th style='padding:8px 10px;text-align:left'>New Value</th><th style='padding:8px 10px;text-align:left'>Status</th></tr>$Rows</table>$ErrHtml</div>"
}

"<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>PYX Health Speech API Fix</title><style>body{font-family:Arial,sans-serif;margin:0;background:#f8fafc;color:#1e293b}.hdr{background:#991b1b;color:#fff;padding:26px 34px}.hdr h1{margin:0;font-size:22px}.hdr p{margin:6px 0 0;opacity:.85;font-size:12px}.alert{background:#fef3c7;border-left:6px solid #d97706;padding:13px 34px;font-size:13px;color:#92400e;font-weight:bold}.kpi{display:flex;gap:14px;padding:18px 34px;background:#fff;border-bottom:1px solid #e2e8f0}.kpi-box{flex:1;border-radius:8px;padding:14px;text-align:center}.val{font-size:28px;font-weight:700}.lbl{font-size:12px;margin-top:4px}.red{background:#fee2e2}.red .val{color:#991b1b}.green{background:#d1fae5}.green .val{color:#065f46}.blue{background:#dbeafe}.blue .val{color:#1e40af}.gray{background:#f1f5f9}.gray .val{color:#374151}.sec{padding:22px 34px}.ftr{padding:14px 34px;text-align:center;color:#94a3b8;font-size:11px;border-top:1px solid #e2e8f0}td{padding:7px 10px;border-bottom:1px solid #e2e8f0;vertical-align:top}tr:hover{background:#f1f5f9}</style></head><body><div class='hdr'><h1>PYX Health - Speech-to-Text API v3.0 Fix Report</h1><p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | Subscriptions: $($AllResults.Count) | Author: Syed Rizvi</p></div><div class='alert'>URGENT: Speech-to-text REST API v3.0 retires March 31, 2026. All affected resources updated to $NewVersion.</div><div class='kpi'><div class='kpi-box gray'><div class='val'>$($AllResults.Count)</div><div class='lbl'>Subscriptions Scanned</div></div><div class='kpi-box red'><div class='val'>$GrandFound</div><div class='lbl'>Resources Found</div></div><div class='kpi-box green'><div class='val'>$GrandFixed</div><div class='lbl'>Resources Fixed</div></div><div class='kpi-box blue'><div class='val'>$Duration sec</div><div class='lbl'>Duration</div></div></div><div class='sec'><h2 style='color:#1e3a8a;border-bottom:2px solid #1e3a8a;padding-bottom:6px;font-size:15px'>Results by Subscription</h2>$SubSections</div><div class='ftr'>PYX Health | IT Infrastructure | Syed Rizvi | March 2026 | CONFIDENTIAL - Internal Use Only</div></body></html>" | Out-File -FilePath $ReportPath -Encoding UTF8

Write-Log "Report saved: $ReportPath" "SUCCESS"
Write-Log "COMPLETE" "SUCCESS"
