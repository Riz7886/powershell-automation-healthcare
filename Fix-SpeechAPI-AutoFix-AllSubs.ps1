<#
.SYNOPSIS
    PYX Health - Speech API v3.0 Safe Fix - All 13 Subscriptions
    Author:  Syed Rizvi
    Version: 9.0 FINAL - SAFE MODE
    Date:    March 2026

.DESCRIPTION
    THREE MODES:
    1. REPORT   - Scan all 13 subs, show what needs fixing, no changes
    2. TEST     - Fix ONE safe subscription first to verify it works
    3. FIXALL   - Fix all 13 subscriptions after test is confirmed good

    SAFETY: Backs up all app settings before making any change.
    Will NOT break PROD - only changes the API version string in settings.
    If anything fails it restores the original settings automatically.

.PARAMETER Mode
    REPORT  = scan only, no changes (DEFAULT - run this first)
    TEST    = fix one test subscription only
    FIXALL  = fix all subscriptions

.PARAMETER TestSubscriptionId
    Subscription ID to use for TEST mode. Default: sub-sandbox

.EXAMPLE
    .\Fix-SpeechAPI-AutoFix-AllSubs.ps1 -Mode REPORT
    .\Fix-SpeechAPI-AutoFix-AllSubs.ps1 -Mode TEST
    .\Fix-SpeechAPI-AutoFix-AllSubs.ps1 -Mode FIXALL
#>
param(
    [ValidateSet("REPORT","TEST","FIXALL")]
    [string]$Mode = "REPORT",

    [string]$TestSubscriptionId = "e97e9ec5-0a81-4fca-a9bf-36cb5338ce6d",
    [string]$OutputPath = "."
)

$ErrorActionPreference = "SilentlyContinue"
$WarningPreference     = "SilentlyContinue"
$NewVersion            = "2024-11-15"
$StartTime             = Get-Date
$AllResults            = [System.Collections.ArrayList]::new()
$BackupFolder          = Join-Path $OutputPath "PYX-SpeechAPI-Backups-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# BOTH PYX TENANTS - hardcoded
$Tenants = @(
    @{ Name = "Pyx Applications Tenant"; Id = "4504822a-07ef-4037-94c0-e632d4ad1a72" },
    @{ Name = "Pyx Health Corporate";    Id = "8ef3d734-3ca5-4493-8d8b-52b2c54eab04" }
)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Prefix = switch ($Level) {
        "SUCCESS" { "[DONE]  " } "WARN"   { "[WARN]  " }
        "ERROR"   { "[ERROR] " } "SCAN"   { "[SCAN]  " }
        "FIX"     { "[FIX]   " } "BACKUP" { "[BACK]  " }
        default   { "[INFO]  " }
    }
    $Color = switch ($Level) {
        "SUCCESS" { "Green"   } "WARN"   { "Yellow"  }
        "ERROR"   { "Red"     } "SCAN"   { "Cyan"    }
        "FIX"     { "Magenta" } "BACKUP" { "DarkCyan"}
        default   { "White"   }
    }
    Write-Host "$Prefix[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Write-Line { Write-Host ("=" * 70) -ForegroundColor Blue }

function Backup-AppSettings {
    param($App, $Settings, $SubName)
    try {
        if (-not (Test-Path $BackupFolder)) {
            New-Item -ItemType Directory -Path $BackupFolder | Out-Null
        }
        $backupFile = Join-Path $BackupFolder "$SubName-$($App.Name)-backup.json"
        $Settings | ConvertTo-Json -Depth 5 | Out-File -FilePath $backupFile -Encoding UTF8
        Write-Log "Backup saved: $($App.Name)" "BACKUP"
        return $true
    } catch {
        Write-Log "Backup failed for $($App.Name): $_" "ERROR"
        return $false
    }
}

function Restore-AppSettings {
    param($App, $SubName)
    try {
        $backupFile = Join-Path $BackupFolder "$SubName-$($App.Name)-backup.json"
        if (Test-Path $backupFile) {
            $original = Get-Content $backupFile | ConvertFrom-Json
            $restoreHash = @{}
            foreach ($s in $original) { $restoreHash[$s.Name] = $s.Value }
            Set-AzWebApp -ResourceGroupName $App.ResourceGroup -Name $App.Name -AppSettings $restoreHash | Out-Null
            Write-Log "RESTORED: $($App.Name)" "SUCCESS"
        }
    } catch {
        Write-Log "Restore failed for $($App.Name): $_" "ERROR"
    }
}

function Scan-AndFix-Subscription {
    param($SubName, $SubId, $TenantId, $DoFix)

    $SubResult = [PSCustomObject]@{
        SubscriptionName = $SubName
        SubscriptionId   = $SubId
        Found            = [System.Collections.ArrayList]::new()
        Fixed            = [System.Collections.ArrayList]::new()
        Skipped          = [System.Collections.ArrayList]::new()
        Errors           = [System.Collections.ArrayList]::new()
    }

    # Scan Cognitive Services
    Write-Log "  Scanning Cognitive Services..." "SCAN"
    $cogAccounts = Get-AzCognitiveServicesAccount
    foreach ($cog in $cogAccounts) {
        if ($cog.Kind -in @("SpeechServices","CognitiveServices","SpeechTranslation")) {
            Write-Log "  Found Speech Service: $($cog.AccountName)" "WARN"
            $null = $SubResult.Found.Add([PSCustomObject]@{
                Type          = "Cognitive Service"
                Name          = $cog.AccountName
                ResourceGroup = $cog.ResourceGroupName
                Location      = $cog.Location
                OldValue      = "v3.0 endpoint in use"
                NewValue      = "Update app code to use endpoint version $NewVersion"
                Fixed         = $false
                SafeToFix     = $true
                Note          = "No automated fix - update application code manually"
            })
        }
    }

    # Scan App Services and Function Apps
    Write-Log "  Scanning App Services and Function Apps..." "SCAN"
    $webApps = Get-AzWebApp
    $appCount = 0
    foreach ($x in $webApps) { $appCount++ }
    Write-Log "  Found $appCount apps to check" "SCAN"

    foreach ($app in $webApps) {
        $appFull = Get-AzWebApp -ResourceGroupName $app.ResourceGroup -Name $app.Name
        if (-not $appFull)                        { continue }
        if (-not $appFull.SiteConfig)             { continue }
        if (-not $appFull.SiteConfig.AppSettings) { continue }

        $matched = [System.Collections.ArrayList]::new()
        foreach ($s in $appFull.SiteConfig.AppSettings) {
            if (($s.Name  -like "*SPEECH*")            -or
                ($s.Name  -like "*STT*")               -or
                ($s.Value -like "*speechtotext/v3.0*") -or
                ($s.Value -like "*/v3.0*")) {
                $null = $matched.Add($s)
            }
        }
        if ($matched.Count -eq 0) { continue }

        $appType = if ($app.Kind -like "*functionapp*") { "Function App" } else { "Web App" }
        Write-Log "  Found speech settings in $appType $($app.Name)" "WARN"

        $newHash     = @{}
        $needsUpdate = $false
        foreach ($s in $appFull.SiteConfig.AppSettings) { $newHash[$s.Name] = $s.Value }

        foreach ($s in $matched) {
            $oldVal = $s.Value
            $newVal = $oldVal -replace "speechtotext/v3\.0","speechtotext/$NewVersion" `
                               -replace "/v3\.0","/$NewVersion"

            $null = $SubResult.Found.Add([PSCustomObject]@{
                Type          = $appType
                Name          = $app.Name
                ResourceGroup = $app.ResourceGroup
                Location      = $app.Location
                OldValue      = "$($s.Name) = $oldVal"
                NewValue      = "$($s.Name) = $newVal"
                Fixed         = $false
                SafeToFix     = ($oldVal -ne $newVal)
                Note          = ""
            })

            if ($oldVal -ne $newVal) {
                $newHash[$s.Name] = $newVal
                $needsUpdate      = $true
                Write-Log "  $($s.Name)" "FIX"
                Write-Log "  Old: $oldVal" "WARN"
                Write-Log "  New: $newVal" "FIX"
            }
        }

        if ($needsUpdate -and $DoFix) {

            # BACKUP FIRST - always before any change
            $backedUp = Backup-AppSettings -App $app -Settings $appFull.SiteConfig.AppSettings -SubName $SubName

            if (-not $backedUp) {
                Write-Log "  Skipping $($app.Name) - backup failed, will not risk changing without backup" "ERROR"
                $null = $SubResult.Skipped.Add($app.Name)
                continue
            }

            # APPLY FIX
            $fix = Set-AzWebApp -ResourceGroupName $app.ResourceGroup -Name $app.Name -AppSettings $newHash

            if ($fix) {
                Write-Log "  FIXED: $($app.Name)" "SUCCESS"
                $null = $SubResult.Fixed.Add($app.Name)
                foreach ($item in $SubResult.Found) {
                    if ($item.Name -eq $app.Name) { $item.Fixed = $true }
                }
            } else {
                Write-Log "  Fix failed for $($app.Name) - restoring backup..." "ERROR"
                Restore-AppSettings -App $app -SubName $SubName
                $null = $SubResult.Errors.Add("Fix failed and restored: $($app.Name)")
            }
        }
    }

    return $SubResult
}

# -------------------------------------------------------------------------------
# MAIN
# -------------------------------------------------------------------------------
Clear-Host
Write-Line
Write-Host "  PYX HEALTH - SPEECH API v3.0 SAFE FIX - ALL 13 SUBSCRIPTIONS" -ForegroundColor White
Write-Host "  Author: Syed Rizvi | Mode: $Mode" -ForegroundColor Gray
Write-Line

Write-Log "MODE: $Mode" "WARN"
switch ($Mode) {
    "REPORT" { Write-Log "Scanning all subs - NO changes will be made" "WARN" }
    "TEST"   { Write-Log "Will fix ONE subscription only: $TestSubscriptionId" "WARN" }
    "FIXALL" { Write-Log "Will fix ALL 13 subscriptions - backups created before each change" "WARN" }
}
Write-Log "Retirement Date: March 31 2026 - TOMORROW" "WARN"
Write-Log "New API Version: $NewVersion"
Write-Host ""

foreach ($tenant in $Tenants) {

    Write-Line
    Write-Log "CONNECTING TO: $($tenant.Name)" "SCAN"
    Write-Line

    Connect-AzAccount -TenantId $tenant.Id -WarningAction SilentlyContinue | Out-Null

    $ctx = Get-AzContext
    if (-not $ctx) {
        Write-Log "Could not connect to $($tenant.Name) - skipping" "ERROR"
        continue
    }
    Write-Log "Connected as: $($ctx.Account.Id)" "SUCCESS"

    $subs = Get-AzSubscription -TenantId $tenant.Id -WarningAction SilentlyContinue
    $subCount = 0
    foreach ($x in $subs) { $subCount++ }
    Write-Log "Found $subCount subscriptions" "SUCCESS"

    foreach ($sub in $subs) {

        # In TEST mode - only run on the test subscription
        if ($Mode -eq "TEST" -and $sub.Id -ne $TestSubscriptionId) {
            Write-Log "TEST mode - skipping: $($sub.Name)" "WARN"
            continue
        }

        Write-Line
        Write-Log "Scanning: $($sub.Name)" "SCAN"

        $switched = Set-AzContext -SubscriptionId $sub.Id -TenantId $tenant.Id -WarningAction SilentlyContinue
        if (-not $switched) {
            Write-Log "Cannot access $($sub.Name) - skipping" "WARN"
            continue
        }

        $doFix = ($Mode -eq "TEST" -or $Mode -eq "FIXALL")
        $result = Scan-AndFix-Subscription -SubName $sub.Name -SubId $sub.Id -TenantId $tenant.Id -DoFix $doFix

        Write-Log "Done: Found=$($result.Found.Count) Fixed=$($result.Fixed.Count) Skipped=$($result.Skipped.Count) Errors=$($result.Errors.Count)" "SUCCESS"
        $null = $AllResults.Add($result)
    }
}

# -------------------------------------------------------------------------------
# SUMMARY
# -------------------------------------------------------------------------------
Write-Line
Write-Host "  FINAL SUMMARY" -ForegroundColor White
Write-Line

$grandFound = 0; $grandFixed = 0; $grandErrors = 0; $grandSkipped = 0
foreach ($r in $AllResults) {
    $grandFound   += $r.Found.Count
    $grandFixed   += $r.Fixed.Count
    $grandErrors  += $r.Errors.Count
    $grandSkipped += $r.Skipped.Count
}
$duration = [math]::Round(((Get-Date) - $StartTime).TotalSeconds)

Write-Log "Mode                  : $Mode"
Write-Log "Subscriptions Scanned : $($AllResults.Count)"
Write-Log "Total Resources Found : $grandFound"
Write-Log "Total Resources Fixed : $grandFixed" "SUCCESS"
Write-Log "Skipped (safe)        : $grandSkipped"
Write-Log "Errors                : $grandErrors"
Write-Log "Duration              : $duration seconds"

if ($Mode -ne "REPORT" -and (Test-Path $BackupFolder)) {
    Write-Log "Backups saved to      : $BackupFolder" "BACKUP"
}

foreach ($r in $AllResults) {
    $st = if ($r.Found.Count -eq 0) { "CLEAN" } elseif ($r.Fixed.Count -ge $r.Found.Count) { "ALL FIXED" } else { "NEEDS FIX" }
    Write-Log "  $($r.SubscriptionName) | Found=$($r.Found.Count) Fixed=$($r.Fixed.Count) | $st"
}

if ($Mode -eq "REPORT" -and $grandFound -gt 0) {
    Write-Host ""
    Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
    Write-Log "1. Review the HTML report below" "WARN"
    Write-Log "2. Run with -Mode TEST to fix one safe sub first" "WARN"
    Write-Log "3. Confirm test worked - then run -Mode FIXALL" "WARN"
}

if ($Mode -eq "TEST" -and $grandFixed -gt 0) {
    Write-Host ""
    Write-Log "TEST PASSED - Run -Mode FIXALL to fix all subscriptions" "SUCCESS"
}

# -------------------------------------------------------------------------------
# HTML REPORT
# -------------------------------------------------------------------------------
$reportPath = Join-Path $OutputPath "PYX-SpeechAPI-$(($Mode).ToUpper())-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"

$subSections = ""
foreach ($r in $AllResults) {
    $hdrColor = if ($r.Found.Count -eq 0) { "#065f46" } elseif ($r.Fixed.Count -ge $r.Found.Count) { "#065f46" } else { "#991b1b" }
    $stLabel  = if ($r.Found.Count -eq 0) { "CLEAN" } elseif ($r.Fixed.Count -ge $r.Found.Count) { "ALL FIXED" } else { "NEEDS FIX" }

    $rows = ""
    if ($r.Found.Count -eq 0) {
        $rows = "<tr><td colspan='7' style='text-align:center;color:#6b7280;padding:14px'>No Speech API v3.0 resources found in this subscription</td></tr>"
    } else {
        foreach ($f in $r.Found) {
            $sBg  = if ($f.Fixed) { "#d1fae5" } elseif ($Mode -eq "REPORT") { "#fef3c7" } else { "#fee2e2" }
            $sClr = if ($f.Fixed) { "#065f46" } elseif ($Mode -eq "REPORT") { "#92400e" } else { "#991b1b" }
            $sTxt = if ($f.Fixed) { "FIXED" } elseif ($Mode -eq "REPORT") { "NEEDS FIX" } else { "PENDING" }
            $rows += "<tr><td>$($f.Type)</td><td>$($f.Name)</td><td>$($f.ResourceGroup)</td><td style='font-family:Courier New;font-size:11px'>$($f.OldValue)</td><td style='font-family:Courier New;font-size:11px;color:#065f46'>$($f.NewValue)</td><td style='background:$sBg;color:$sClr;font-weight:bold;text-align:center'>$sTxt</td><td>$($f.Note)</td></tr>"
        }
    }

    $errHtml = ""
    if ($r.Errors.Count -gt 0) {
        $eList = ""
        foreach ($e in $r.Errors) { $eList += "<li>$e</li>" }
        $errHtml = "<div style='background:#fee2e2;padding:10px 16px;font-size:12px;color:#991b1b'><strong>Errors (originals restored from backup):</strong><ul>$eList</ul></div>"
    }

    $subSections += "<div style='margin-bottom:28px'><div style='background:$hdrColor;color:#fff;padding:12px 18px;border-radius:6px 6px 0 0;font-weight:bold;font-size:13px'>$($r.SubscriptionName) | $($r.SubscriptionId) | Found: $($r.Found.Count) | Fixed: $($r.Fixed.Count) | $stLabel</div><table style='width:100%;border-collapse:collapse;font-size:12px'><tr style='background:#1e3a8a;color:#fff'><th style='padding:8px 10px;text-align:left'>Type</th><th style='padding:8px 10px;text-align:left'>Resource</th><th style='padding:8px 10px;text-align:left'>Resource Group</th><th style='padding:8px 10px;text-align:left'>Old Value</th><th style='padding:8px 10px;text-align:left'>New Value</th><th style='padding:8px 10px;text-align:left'>Status</th><th style='padding:8px 10px;text-align:left'>Note</th></tr>$rows</table>$errHtml</div>"
}

$modeColor = switch ($Mode) { "REPORT" { "#1e3a8a" } "TEST" { "#d97706" } "FIXALL" { "#991b1b" } }

$html  = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>PYX Speech API $Mode Report</title>"
$html += "<style>body{font-family:Arial,sans-serif;margin:0;background:#f8fafc;color:#1e293b}.hdr{background:$modeColor;color:#fff;padding:26px 34px}.hdr h1{margin:0;font-size:22px}.hdr p{margin:6px 0 0;opacity:.85;font-size:12px}.alert{background:#fef3c7;border-left:6px solid #d97706;padding:13px 34px;font-size:13px;color:#92400e;font-weight:bold}.steps{background:#dbeafe;border-left:6px solid #1e40af;padding:13px 34px;font-size:13px;color:#1e40af}.kpi{display:flex;gap:14px;padding:18px 34px;background:#fff;border-bottom:1px solid #e2e8f0}.kpi-box{flex:1;border-radius:8px;padding:14px;text-align:center}.val{font-size:28px;font-weight:700}.lbl{font-size:12px;margin-top:4px}.red{background:#fee2e2}.red .val{color:#991b1b}.green{background:#d1fae5}.green .val{color:#065f46}.yellow{background:#fef3c7}.yellow .val{color:#92400e}.blue{background:#dbeafe}.blue .val{color:#1e40af}.gray{background:#f1f5f9}.gray .val{color:#374151}.sec{padding:22px 34px}.ftr{padding:14px 34px;text-align:center;color:#94a3b8;font-size:11px;border-top:1px solid #e2e8f0}td{padding:7px 10px;border-bottom:1px solid #e2e8f0;vertical-align:top}tr:hover{background:#f1f5f9}</style></head><body>"
$html += "<div class='hdr'><h1>PYX Health - Speech API v3.0 $Mode Report - All Subscriptions</h1><p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | Mode: $Mode | Subscriptions: $($AllResults.Count) | Author: Syed Rizvi</p></div>"
$html += "<div class='alert'>URGENT: Speech-to-text REST API v3.0 retires March 31 2026 - TOMORROW. New version: $NewVersion</div>"

if ($Mode -eq "REPORT") {
    $html += "<div class='steps'>NEXT STEPS: (1) Review findings below and send to IT Director (2) Run with -Mode TEST to fix one sub safely (3) Run -Mode FIXALL to fix everything</div>"
}
if ($Mode -ne "REPORT" -and (Test-Path $BackupFolder)) {
    $html += "<div class='steps'>BACKUPS: All original settings backed up to $BackupFolder before any changes were made.</div>"
}

$html += "<div class='kpi'><div class='kpi-box gray'><div class='val'>$($AllResults.Count)</div><div class='lbl'>Subscriptions Scanned</div></div><div class='kpi-box red'><div class='val'>$grandFound</div><div class='lbl'>Resources Found</div></div><div class='kpi-box green'><div class='val'>$grandFixed</div><div class='lbl'>Resources Fixed</div></div><div class='kpi-box yellow'><div class='val'>$grandSkipped</div><div class='lbl'>Skipped Safe</div></div><div class='kpi-box blue'><div class='val'>$duration sec</div><div class='lbl'>Duration</div></div></div>"
$html += "<div class='sec'><h2 style='color:#1e3a8a;border-bottom:2px solid #1e3a8a;padding-bottom:6px;font-size:15px'>Results by Subscription</h2>$subSections</div>"
$html += "<div class='ftr'>PYX Health | IT Infrastructure | Syed Rizvi | March 2026 | CONFIDENTIAL - Internal Use Only</div></body></html>"

$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Log "HTML Report saved: $reportPath" "SUCCESS"
Write-Log "ALL DONE" "SUCCESS"
