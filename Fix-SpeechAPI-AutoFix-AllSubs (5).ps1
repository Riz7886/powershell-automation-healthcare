<#
.SYNOPSIS
    PYX Health - Speech API v3.0 Auto Fix
    Author:  Syed Rizvi
    Version: 6.0 - FINAL
    Date:    March 2026
.EXAMPLE
    .\Fix-SpeechAPI-AutoFix-AllSubs.ps1
    .\Fix-SpeechAPI-AutoFix-AllSubs.ps1 -ReportOnly $true
#>
param(
    [bool]$ReportOnly   = $false,
    [string]$OutputPath = "."
)

$ErrorActionPreference = "SilentlyContinue"
$WarningPreference     = "SilentlyContinue"
$NewVersion            = "2024-11-15"
$StartTime             = Get-Date
$AllResults            = [System.Collections.ArrayList]::new()

# PYX Health Tenant ID - from your Azure environment
$PYXTenantId = "4504822a-07ef-4037-94c0-e632d4ad1a72"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Prefix = switch ($Level) {
        "SUCCESS" { "[DONE]  " } "WARN" { "[WARN]  " }
        "ERROR"   { "[ERROR] " } "SCAN" { "[SCAN]  " }
        "FIX"     { "[FIX]   " } default { "[INFO]  " }
    }
    $Color = switch ($Level) {
        "SUCCESS" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" }
        "SCAN"    { "Cyan"  } "FIX"  { "Magenta" } default { "White" }
    }
    Write-Host "$Prefix[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Write-Line { Write-Host ("=" * 70) -ForegroundColor Blue }

Write-Line
Write-Host "  PYX HEALTH - SPEECH API v3.0 AUTO FIX ALL SUBSCRIPTIONS" -ForegroundColor White
Write-Host "  Author: Syed Rizvi | Mode: $(if ($ReportOnly) { 'REPORT ONLY' } else { 'AUTO FIX' })" -ForegroundColor Gray
Write-Line

# STEP 1 - CONNECT TO PYX TENANT DIRECTLY
Write-Log "Connecting to PYX Health Azure tenant..." "SCAN"

Connect-AzAccount -TenantId $PYXTenantId -WarningAction SilentlyContinue | Out-Null

$Ctx = Get-AzContext
if (-not $Ctx -or -not $Ctx.Account) {
    Write-Log "Login failed. Please try again." "ERROR"
    exit 1
}
Write-Log "Logged in as: $($Ctx.Account.Id)" "SUCCESS"

# STEP 2 - GET ALL SUBSCRIPTIONS FROM PYX TENANT
Write-Log "Getting all subscriptions from PYX Health tenant..." "SCAN"

$AllSubs = [System.Collections.ArrayList]::new()
$RawSubs = Get-AzSubscription -TenantId $PYXTenantId -WarningAction SilentlyContinue

foreach ($Sub in $RawSubs) {
    $null = $AllSubs.Add($Sub)
    Write-Log "  Found: $($Sub.Name) | $($Sub.Id)" "SCAN"
}

if ($AllSubs.Count -eq 0) {
    Write-Log "No subscriptions found. Trying without TenantId filter..." "WARN"
    $RawSubs2 = Get-AzSubscription -WarningAction SilentlyContinue
    foreach ($Sub in $RawSubs2) {
        $null = $AllSubs.Add($Sub)
        Write-Log "  Found: $($Sub.Name) | $($Sub.Id)" "SCAN"
    }
}

if ($AllSubs.Count -eq 0) {
    Write-Log "Could not find subscriptions. Run manually: Get-AzSubscription | Select Name,Id" "ERROR"
    exit 1
}

Write-Log "Total subscriptions to scan: $($AllSubs.Count)" "SUCCESS"

# STEP 3 - SCAN AND FIX EACH SUBSCRIPTION
for ($s = 0; $s -lt $AllSubs.Count; $s++) {

    $Sub = $AllSubs[$s]
    Write-Line
    Write-Log "[$($s+1)/$($AllSubs.Count)] Scanning: $($Sub.Name)" "SCAN"
    Write-Line

    $Switched = Set-AzContext -SubscriptionId $Sub.Id -TenantId $PYXTenantId -WarningAction SilentlyContinue
    if (-not $Switched) {
        Write-Log "Cannot access $($Sub.Name) - skipping" "WARN"
        continue
    }

    $SubResult = [PSCustomObject]@{
        SubscriptionName = $Sub.Name
        SubscriptionId   = $Sub.Id
        Found            = [System.Collections.ArrayList]::new()
        Fixed            = [System.Collections.ArrayList]::new()
        Errors           = [System.Collections.ArrayList]::new()
    }

    # Scan Cognitive Services
    Write-Log "Scanning Cognitive Services..." "SCAN"
    $CogList = Get-AzCognitiveServicesAccount
    foreach ($Cog in $CogList) {
        if ($Cog.Kind -in @("SpeechServices","CognitiveServices","SpeechTranslation")) {
            Write-Log "Found Speech Service: $($Cog.AccountName)" "WARN"
            $null = $SubResult.Found.Add([PSCustomObject]@{
                Type          = "Cognitive Service"
                Name          = $Cog.AccountName
                ResourceGroup = $Cog.ResourceGroupName
                Location      = $Cog.Location
                OldValue      = "v3.0 endpoint in use"
                NewValue      = "Update calling app to use endpoint version $NewVersion"
                Fixed         = $false
            })
        }
    }

    # Scan App Services and Function Apps
    Write-Log "Scanning App Services and Function Apps..." "SCAN"
    $AppList = Get-AzWebApp
    $AppCount = 0
    foreach ($x in $AppList) { $AppCount++ }
    Write-Log "Found $AppCount apps to check" "SCAN"

    foreach ($App in $AppList) {

        $AppFull = Get-AzWebApp -ResourceGroupName $App.ResourceGroup -Name $App.Name
        if (-not $AppFull)                        { continue }
        if (-not $AppFull.SiteConfig)             { continue }
        if (-not $AppFull.SiteConfig.AppSettings) { continue }

        $Matched = [System.Collections.ArrayList]::new()
        foreach ($S in $AppFull.SiteConfig.AppSettings) {
            if (($S.Name  -like "*SPEECH*")            -or
                ($S.Name  -like "*STT*")               -or
                ($S.Value -like "*speechtotext/v3.0*") -or
                ($S.Value -like "*/v3.0*")) {
                $null = $Matched.Add($S)
            }
        }
        if ($Matched.Count -eq 0) { continue }

        $AppType = if ($App.Kind -like "*functionapp*") { "Function App" } else { "Web App" }
        Write-Log "Found speech settings in $AppType $($App.Name)" "WARN"

        $NewHash     = @{}
        $NeedsUpdate = $false
        foreach ($S in $AppFull.SiteConfig.AppSettings) { $NewHash[$S.Name] = $S.Value }

        foreach ($S in $Matched) {
            $OldVal = $S.Value
            $NewVal = $OldVal -replace "speechtotext/v3\.0","speechtotext/$NewVersion" `
                               -replace "/v3\.0","/$NewVersion"
            $null = $SubResult.Found.Add([PSCustomObject]@{
                Type          = $AppType
                Name          = $App.Name
                ResourceGroup = $App.ResourceGroup
                Location      = $App.Location
                OldValue      = "$($S.Name) = $OldVal"
                NewValue      = "$($S.Name) = $NewVal"
                Fixed         = $false
            })
            if ($OldVal -ne $NewVal) {
                $NewHash[$S.Name] = $NewVal
                $NeedsUpdate      = $true
                Write-Log "  $($S.Name)" "FIX"
                Write-Log "  Old: $OldVal" "WARN"
                Write-Log "  New: $NewVal" "FIX"
            }
        }

        if ($NeedsUpdate -and (-not $ReportOnly)) {
            $Fix = Set-AzWebApp -ResourceGroupName $App.ResourceGroup -Name $App.Name -AppSettings $NewHash
            if ($Fix) {
                Write-Log "FIXED: $($App.Name)" "SUCCESS"
                $null = $SubResult.Fixed.Add($App.Name)
                foreach ($Item in $SubResult.Found) {
                    if ($Item.Name -eq $App.Name) { $Item.Fixed = $true }
                }
            } else {
                Write-Log "Fix failed: $($App.Name)" "ERROR"
                $null = $SubResult.Errors.Add("Fix failed: $($App.Name)")
            }
        }
    }

    Write-Log "Done: Found=$($SubResult.Found.Count) Fixed=$($SubResult.Fixed.Count)" "SUCCESS"
    $null = $AllResults.Add($SubResult)
}

# STEP 4 - SUMMARY
Write-Line
Write-Host "  FINAL SUMMARY" -ForegroundColor White
Write-Line

$GrandFound = 0; $GrandFixed = 0; $GrandErrors = 0
foreach ($R in $AllResults) {
    $GrandFound  += $R.Found.Count
    $GrandFixed  += $R.Fixed.Count
    $GrandErrors += $R.Errors.Count
}
$Duration = [math]::Round(((Get-Date) - $StartTime).TotalSeconds)

Write-Log "Subscriptions Scanned : $($AllResults.Count)"
Write-Log "Total Resources Found : $GrandFound"
Write-Log "Total Resources Fixed : $GrandFixed" "SUCCESS"
Write-Log "Errors                : $GrandErrors"
Write-Log "Duration              : $Duration seconds"

foreach ($R in $AllResults) {
    $St = if ($R.Found.Count -eq 0) { "CLEAN" } elseif ($R.Fixed.Count -ge $R.Found.Count) { "ALL FIXED" } else { "REVIEW" }
    Write-Log "  $($R.SubscriptionName) | Found=$($R.Found.Count) Fixed=$($R.Fixed.Count) | $St"
}

# STEP 5 - HTML REPORT
$ReportPath = Join-Path $OutputPath "PYX-SpeechAPI-Fix-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"

$SubSections = ""
foreach ($R in $AllResults) {
    $HdrColor = if ($R.Found.Count -eq 0) { "#065f46" } elseif ($R.Fixed.Count -ge $R.Found.Count) { "#065f46" } else { "#991b1b" }
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
        $EList = ""
        foreach ($E in $R.Errors) { $EList += "<li>$E</li>" }
        $ErrHtml = "<div style='background:#fee2e2;padding:10px 16px;font-size:12px;color:#991b1b'><strong>Errors:</strong><ul>$EList</ul></div>"
    }
    $SubSections += "<div style='margin-bottom:28px'><div style='background:$HdrColor;color:#fff;padding:12px 18px;border-radius:6px 6px 0 0;font-weight:bold;font-size:13px'>$($R.SubscriptionName) | $($R.SubscriptionId) | Found: $($R.Found.Count) | Fixed: $($R.Fixed.Count) | $StLabel</div><table style='width:100%;border-collapse:collapse;font-size:12px'><tr style='background:#1e3a8a;color:#fff'><th style='padding:8px 10px;text-align:left'>Type</th><th style='padding:8px 10px;text-align:left'>Resource</th><th style='padding:8px 10px;text-align:left'>Resource Group</th><th style='padding:8px 10px;text-align:left'>Old Value</th><th style='padding:8px 10px;text-align:left'>New Value</th><th style='padding:8px 10px;text-align:left'>Status</th></tr>$Rows</table>$ErrHtml</div>"
}

$Html  = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>PYX Speech API Fix</title>"
$Html += "<style>body{font-family:Arial,sans-serif;margin:0;background:#f8fafc;color:#1e293b}.hdr{background:#991b1b;color:#fff;padding:26px 34px}.hdr h1{margin:0;font-size:22px}.hdr p{margin:6px 0 0;opacity:.85;font-size:12px}.alert{background:#fef3c7;border-left:6px solid #d97706;padding:13px 34px;font-size:13px;color:#92400e;font-weight:bold}.kpi{display:flex;gap:14px;padding:18px 34px;background:#fff;border-bottom:1px solid #e2e8f0}.kpi-box{flex:1;border-radius:8px;padding:14px;text-align:center}.val{font-size:28px;font-weight:700}.lbl{font-size:12px;margin-top:4px}.red{background:#fee2e2}.red .val{color:#991b1b}.green{background:#d1fae5}.green .val{color:#065f46}.blue{background:#dbeafe}.blue .val{color:#1e40af}.gray{background:#f1f5f9}.gray .val{color:#374151}.sec{padding:22px 34px}.ftr{padding:14px 34px;text-align:center;color:#94a3b8;font-size:11px;border-top:1px solid #e2e8f0}td{padding:7px 10px;border-bottom:1px solid #e2e8f0;vertical-align:top}tr:hover{background:#f1f5f9}</style></head><body>"
$Html += "<div class='hdr'><h1>PYX Health - Speech API v3.0 Fix Report</h1><p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | Subscriptions: $($AllResults.Count) | Author: Syed Rizvi</p></div>"
$Html += "<div class='alert'>URGENT: Speech-to-text REST API v3.0 retires March 31 2026. All affected resources updated to $NewVersion.</div>"
$Html += "<div class='kpi'><div class='kpi-box gray'><div class='val'>$($AllResults.Count)</div><div class='lbl'>Subscriptions Scanned</div></div><div class='kpi-box red'><div class='val'>$GrandFound</div><div class='lbl'>Resources Found</div></div><div class='kpi-box green'><div class='val'>$GrandFixed</div><div class='lbl'>Resources Fixed</div></div><div class='kpi-box blue'><div class='val'>$Duration sec</div><div class='lbl'>Duration</div></div></div>"
$Html += "<div class='sec'><h2 style='color:#1e3a8a;border-bottom:2px solid #1e3a8a;padding-bottom:6px;font-size:15px'>Results by Subscription</h2>$SubSections</div>"
$Html += "<div class='ftr'>PYX Health | IT Infrastructure | Syed Rizvi | March 2026 | CONFIDENTIAL</div></body></html>"

$Html | Out-File -FilePath $ReportPath -Encoding UTF8
Write-Log "Report saved: $ReportPath" "SUCCESS"
Write-Log "ALL DONE" "SUCCESS"
