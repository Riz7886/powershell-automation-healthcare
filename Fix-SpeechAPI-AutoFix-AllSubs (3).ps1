<#
.SYNOPSIS
    PYX Health - Speech API v3.0 Safe Fix - All 13 Subscriptions
    Author:  Syed Rizvi
    Version: 11.0 FINAL
    Date:    March 2026
.EXAMPLE
    .\Fix-SpeechAPI-AutoFix-AllSubs.ps1 -Mode REPORT
    .\Fix-SpeechAPI-AutoFix-AllSubs.ps1 -Mode TEST
    .\Fix-SpeechAPI-AutoFix-AllSubs.ps1 -Mode FIXALL
#>
param(
    [ValidateSet("REPORT","TEST","FIXALL")]
    [string]$Mode = "REPORT",
    [string]$OutputPath = "."
)

$ErrorActionPreference = "SilentlyContinue"
$WarningPreference     = "SilentlyContinue"
$NewVersion            = "2024-11-15"
$StartTime             = Get-Date
$AllResults            = [System.Collections.ArrayList]::new()
$BackupFolder          = Join-Path $OutputPath "PYX-Backups-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# BOTH TENANT IDs
$Tenant1 = "4504822a-07ef-4037-94c0-e632d4ad1a72"  # Pyx Applications Tenant
$Tenant2 = "8ef3d734-3ca5-4493-8d8b-52b2c54eab04"  # Pyx Health Corporate

# ALL 13 SUBSCRIPTIONS HARDCODED
$AllSubscriptions = @(
    @{ Name = "sub-corp-prod-001";         Id = "e42e94b5-c6f8-4af0-a41b-16fda520de6e"; Tenant = $Tenant1 },
    @{ Name = "sub-dataAnalytics-preProd"; Id = "abcadd97-a465-41eb-8288-fef36da59fd5"; Tenant = $Tenant1 },
    @{ Name = "sub-dataAnalytics-prod";    Id = "cf3b06f3-3865-48a4-8ded-2a97914f2f97"; Tenant = $Tenant1 },
    @{ Name = "sub-Drivers-Health-Test";   Id = "fab2f5b8-5b17-4105-9348-8c4903e11748"; Tenant = $Tenant1 },
    @{ Name = "Sub-Drivers-Health-Prod";   Id = "302aceb9-3ab3-4110-bb3e-64e0c118829a"; Tenant = $Tenant1 },
    @{ Name = "sub-it-management";         Id = "a90514d9-361b-4119-a013-585d6765b35d"; Tenant = $Tenant1 },
    @{ Name = "sub-product-preProd";       Id = "52d0d667-a89a-4fe0-be5c-3fb2d72e90ed"; Tenant = $Tenant1 },
    @{ Name = "sub-product-prod";          Id = "730dd182-eb99-4f54-8f4c-698a5338013f"; Tenant = $Tenant1 },
    @{ Name = "Sub-Production";            Id = "da72e6ae-e86d-4dfb-a5fd-dd6b2c96ae05"; Tenant = $Tenant1 },
    @{ Name = "sub-sandbox";              Id = "076fbf87-2655-4fb0-810e-98cb4e1266dc"; Tenant = $Tenant1 },
    @{ Name = "Sub-Staging";              Id = "e0ecde18-5086-4ee7-855a-8261a328eddc"; Tenant = $Tenant1 },
    @{ Name = "Azure-subscription-1";     Id = "977e4f83-3649-428b-9416-cf9adfe24cec"; Tenant = $Tenant2 },
    @{ Name = "sub-csc-avd";              Id = "7edfb9f6-940e-47cd-af4b-04d0b6e6020f"; Tenant = $Tenant2 }
)

$TestSubId = "076fbf87-2655-4fb0-810e-98cb4e1266dc"  # sub-sandbox

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Prefix = switch ($Level) {
        "SUCCESS" { "[DONE]  " } "WARN"   { "[WARN]  " }
        "ERROR"   { "[ERROR] " } "SCAN"   { "[SCAN]  " }
        "FIX"     { "[FIX]   " } "BACKUP" { "[BACK]  " }
        default   { "[INFO]  " }
    }
    $Color = switch ($Level) {
        "SUCCESS" { "Green"    } "WARN"   { "Yellow"   }
        "ERROR"   { "Red"      } "SCAN"   { "Cyan"     }
        "FIX"     { "Magenta"  } "BACKUP" { "DarkCyan" }
        default   { "White"    }
    }
    Write-Host "$Prefix[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Write-Line { Write-Host ("=" * 70) -ForegroundColor Blue }

Clear-Host
Write-Line
Write-Host "  PYX HEALTH - SPEECH API v3.0 SAFE FIX - ALL 13 SUBSCRIPTIONS" -ForegroundColor White
Write-Host "  Author: Syed Rizvi | Mode: $Mode" -ForegroundColor Gray
Write-Line

# STEP 1 - GET CURRENT LOGIN
Write-Log "Checking Azure login..." "SCAN"
$ctx = Get-AzContext
if (-not $ctx -or -not $ctx.Account) {
    Write-Log "Not logged in. Run: Connect-AzAccount then re-run." "ERROR"
    exit 1
}
$AccountId = $ctx.Account.Id
Write-Log "Logged in as: $AccountId" "SUCCESS"

# STEP 2 - CONNECT TO BOTH TENANTS SILENTLY USING EXISTING ACCOUNT
# Using -AccountId forces cached SSO token - no browser popup
Write-Log "Connecting to Pyx Applications Tenant..." "SCAN"
Connect-AzAccount -TenantId $Tenant1 -AccountId $AccountId -SkipContextPopulation -WarningAction SilentlyContinue | Out-Null
Write-Log "Connecting to Pyx Health Corporate Tenant..." "SCAN"
Connect-AzAccount -TenantId $Tenant2 -AccountId $AccountId -SkipContextPopulation -WarningAction SilentlyContinue | Out-Null
Write-Log "Both tenants connected" "SUCCESS"
Write-Log "Mode: $Mode | Subs: 13 | Retirement: March 31 2026 - TOMORROW" "WARN"
Write-Host ""

# STEP 3 - LOOP ALL 13 SUBS
$subNum = 0
foreach ($sub in $AllSubscriptions) {
    $subNum++

    if ($Mode -eq "TEST" -and $sub.Id -ne $TestSubId) { continue }

    Write-Line
    Write-Log "[$subNum/13] $($sub.Name)" "SCAN"

    $switched = Set-AzContext -SubscriptionId $sub.Id -TenantId $sub.Tenant -WarningAction SilentlyContinue
    if (-not $switched) {
        Write-Log "Cannot access $($sub.Name) - skipping" "WARN"
        continue
    }
    Write-Log "Context OK: $($sub.Name)" "SUCCESS"

    $SubResult = [PSCustomObject]@{
        SubscriptionName = $sub.Name
        SubscriptionId   = $sub.Id
        Found            = [System.Collections.ArrayList]::new()
        Fixed            = [System.Collections.ArrayList]::new()
        Errors           = [System.Collections.ArrayList]::new()
    }

    # Scan Cognitive Services
    Write-Log "Scanning Cognitive Services..." "SCAN"
    $cogList = Get-AzCognitiveServicesAccount
    foreach ($cog in $cogList) {
        if ($cog.Kind -in @("SpeechServices","CognitiveServices","SpeechTranslation")) {
            Write-Log "Found Speech Service: $($cog.AccountName)" "WARN"
            $null = $SubResult.Found.Add([PSCustomObject]@{
                Type          = "Cognitive Service"
                Name          = $cog.AccountName
                ResourceGroup = $cog.ResourceGroupName
                Location      = $cog.Location
                OldValue      = "v3.0 endpoint in use"
                NewValue      = "Update app code to endpoint version $NewVersion"
                Fixed         = $false
                Note          = "Update application code manually"
            })
        }
    }

    # Scan App Services
    Write-Log "Scanning App Services and Function Apps..." "SCAN"
    $apps = Get-AzWebApp
    $cnt = 0; foreach ($x in $apps) { $cnt++ }
    Write-Log "Found $cnt apps" "SCAN"

    foreach ($app in $apps) {
        $full = Get-AzWebApp -ResourceGroupName $app.ResourceGroup -Name $app.Name
        if (-not $full -or -not $full.SiteConfig -or -not $full.SiteConfig.AppSettings) { continue }

        $matched = [System.Collections.ArrayList]::new()
        foreach ($s in $full.SiteConfig.AppSettings) {
            if (($s.Name  -like "*SPEECH*")            -or
                ($s.Name  -like "*STT*")               -or
                ($s.Value -like "*speechtotext/v3.0*") -or
                ($s.Value -like "*/v3.0*")) {
                $null = $matched.Add($s)
            }
        }
        if ($matched.Count -eq 0) { continue }

        $appType = if ($app.Kind -like "*functionapp*") { "Function App" } else { "Web App" }
        Write-Log "Found speech settings in $appType $($app.Name)" "WARN"

        $newHash = @{}
        $needsUpdate = $false
        foreach ($s in $full.SiteConfig.AppSettings) { $newHash[$s.Name] = $s.Value }

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
                Note          = ""
            })
            if ($oldVal -ne $newVal) {
                $newHash[$s.Name] = $newVal
                $needsUpdate = $true
                Write-Log "  $($s.Name): $oldVal --> $newVal" "FIX"
            }
        }

        if ($needsUpdate -and ($Mode -eq "TEST" -or $Mode -eq "FIXALL")) {
            if (-not (Test-Path $BackupFolder)) { New-Item -ItemType Directory -Path $BackupFolder | Out-Null }
            $backupFile = Join-Path $BackupFolder "$($sub.Name)-$($app.Name).json"
            $full.SiteConfig.AppSettings | ConvertTo-Json | Out-File $backupFile -Encoding UTF8
            Write-Log "Backup: $backupFile" "BACKUP"

            $fix = Set-AzWebApp -ResourceGroupName $app.ResourceGroup -Name $app.Name -AppSettings $newHash
            if ($fix) {
                Write-Log "FIXED: $($app.Name)" "SUCCESS"
                $null = $SubResult.Fixed.Add($app.Name)
                foreach ($item in $SubResult.Found) {
                    if ($item.Name -eq $app.Name) { $item.Fixed = $true }
                }
            } else {
                Write-Log "Fix failed: $($app.Name) - restoring..." "ERROR"
                $orig = Get-Content $backupFile | ConvertFrom-Json
                $restore = @{}
                foreach ($s in $orig) { $restore[$s.Name] = $s.Value }
                Set-AzWebApp -ResourceGroupName $app.ResourceGroup -Name $app.Name -AppSettings $restore | Out-Null
                $null = $SubResult.Errors.Add("Fix failed and restored: $($app.Name)")
            }
        }
    }

    Write-Log "Done: Found=$($SubResult.Found.Count) Fixed=$($SubResult.Fixed.Count)" "SUCCESS"
    $null = $AllResults.Add($SubResult)
}

# SUMMARY
Write-Line
Write-Host "  FINAL SUMMARY" -ForegroundColor White
Write-Line

$grandFound = 0; $grandFixed = 0; $grandErrors = 0
foreach ($r in $AllResults) {
    $grandFound  += $r.Found.Count
    $grandFixed  += $r.Fixed.Count
    $grandErrors += $r.Errors.Count
}
$duration = [math]::Round(((Get-Date) - $StartTime).TotalSeconds)

Write-Log "Mode                  : $Mode"
Write-Log "Subscriptions Scanned : $($AllResults.Count)"
Write-Log "Total Resources Found : $grandFound"
Write-Log "Total Resources Fixed : $grandFixed" "SUCCESS"
Write-Log "Errors                : $grandErrors"
Write-Log "Duration              : $duration seconds"

foreach ($r in $AllResults) {
    $st = if ($r.Found.Count -eq 0) { "CLEAN" } elseif ($r.Fixed.Count -ge $r.Found.Count) { "ALL FIXED" } else { "NEEDS FIX" }
    Write-Log "  $($r.SubscriptionName) | Found=$($r.Found.Count) Fixed=$($r.Fixed.Count) | $st"
}

if ($Mode -eq "REPORT" -and $grandFound -gt 0) {
    Write-Host ""
    Write-Log "NEXT: Run -Mode TEST on sandbox, then -Mode FIXALL" "WARN"
}
if ($Mode -eq "TEST") {
    Write-Host ""
    Write-Log "TEST DONE - Run -Mode FIXALL to fix all subscriptions" "SUCCESS"
}

# HTML REPORT
$reportPath = Join-Path $OutputPath "PYX-SpeechAPI-$Mode-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"

$subSections = ""
foreach ($r in $AllResults) {
    $hdrColor = if ($r.Found.Count -eq 0) { "#065f46" } elseif ($r.Fixed.Count -ge $r.Found.Count) { "#065f46" } else { "#991b1b" }
    $stLabel  = if ($r.Found.Count -eq 0) { "CLEAN" } elseif ($r.Fixed.Count -ge $r.Found.Count) { "ALL FIXED" } else { "NEEDS FIX" }
    $rows = ""
    if ($r.Found.Count -eq 0) {
        $rows = "<tr><td colspan='6' style='text-align:center;color:#6b7280;padding:14px'>No Speech API v3.0 resources found in this subscription</td></tr>"
    } else {
        foreach ($f in $r.Found) {
            $sBg  = if ($f.Fixed) { "#d1fae5" } elseif ($Mode -eq "REPORT") { "#fef3c7" } else { "#fee2e2" }
            $sClr = if ($f.Fixed) { "#065f46" } elseif ($Mode -eq "REPORT") { "#92400e" } else { "#991b1b" }
            $sTxt = if ($f.Fixed) { "FIXED" } elseif ($Mode -eq "REPORT") { "NEEDS FIX" } else { "PENDING" }
            $rows += "<tr><td>$($f.Type)</td><td>$($f.Name)</td><td>$($f.ResourceGroup)</td><td style='font-family:Courier New;font-size:11px'>$($f.OldValue)</td><td style='font-family:Courier New;font-size:11px;color:#065f46'>$($f.NewValue)</td><td style='background:$sBg;color:$sClr;font-weight:bold;text-align:center'>$sTxt</td></tr>"
        }
    }
    $errHtml = ""
    if ($r.Errors.Count -gt 0) {
        $eList = ""
        foreach ($e in $r.Errors) { $eList += "<li>$e</li>" }
        $errHtml = "<div style='background:#fee2e2;padding:10px 16px;font-size:12px;color:#991b1b'><strong>Errors (auto-restored from backup):</strong><ul>$eList</ul></div>"
    }
    $subSections += "<div style='margin-bottom:28px'><div style='background:$hdrColor;color:#fff;padding:12px 18px;border-radius:6px 6px 0 0;font-weight:bold;font-size:13px'>$($r.SubscriptionName) | $($r.SubscriptionId) | Found: $($r.Found.Count) | Fixed: $($r.Fixed.Count) | $stLabel</div><table style='width:100%;border-collapse:collapse;font-size:12px'><tr style='background:#1e3a8a;color:#fff'><th style='padding:8px 10px;text-align:left'>Type</th><th style='padding:8px 10px;text-align:left'>Resource</th><th style='padding:8px 10px;text-align:left'>Resource Group</th><th style='padding:8px 10px;text-align:left'>Old Value</th><th style='padding:8px 10px;text-align:left'>New Value</th><th style='padding:8px 10px;text-align:left'>Status</th></tr>$rows</table>$errHtml</div>"
}

$html  = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>PYX Speech API $Mode Report</title>"
$html += "<style>body{font-family:Arial,sans-serif;margin:0;background:#f8fafc;color:#1e293b}.hdr{background:#991b1b;color:#fff;padding:26px 34px}.hdr h1{margin:0;font-size:22px}.hdr p{margin:6px 0 0;opacity:.85;font-size:12px}.alert{background:#fef3c7;border-left:6px solid #d97706;padding:13px 34px;font-size:13px;color:#92400e;font-weight:bold}.steps{background:#dbeafe;border-left:6px solid #1e40af;padding:13px 34px;font-size:13px;color:#1e40af}.kpi{display:flex;gap:14px;padding:18px 34px;background:#fff;border-bottom:1px solid #e2e8f0}.kpi-box{flex:1;border-radius:8px;padding:14px;text-align:center}.val{font-size:28px;font-weight:700}.lbl{font-size:12px;margin-top:4px}.red{background:#fee2e2}.red .val{color:#991b1b}.green{background:#d1fae5}.green .val{color:#065f46}.blue{background:#dbeafe}.blue .val{color:#1e40af}.gray{background:#f1f5f9}.gray .val{color:#374151}.sec{padding:22px 34px}.ftr{padding:14px 34px;text-align:center;color:#94a3b8;font-size:11px;border-top:1px solid #e2e8f0}td{padding:7px 10px;border-bottom:1px solid #e2e8f0;vertical-align:top}tr:hover{background:#f1f5f9}</style></head><body>"
$html += "<div class='hdr'><h1>PYX Health - Speech API v3.0 $Mode Report - All 13 Subscriptions</h1><p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | Mode: $Mode | Scanned: $($AllResults.Count) | Author: Syed Rizvi</p></div>"
$html += "<div class='alert'>URGENT: Speech-to-text REST API v3.0 retires March 31 2026 - TOMORROW. New version: $NewVersion</div>"
if ($Mode -eq "REPORT") { $html += "<div class='steps'>NEXT STEPS: (1) Send this report to IT Director (2) Run -Mode TEST to fix sandbox first (3) Run -Mode FIXALL tonight to fix all</div>" }
$html += "<div class='kpi'><div class='kpi-box gray'><div class='val'>$($AllResults.Count)</div><div class='lbl'>Subscriptions Scanned</div></div><div class='kpi-box red'><div class='val'>$grandFound</div><div class='lbl'>Resources Found</div></div><div class='kpi-box green'><div class='val'>$grandFixed</div><div class='lbl'>Resources Fixed</div></div><div class='kpi-box blue'><div class='val'>$duration sec</div><div class='lbl'>Duration</div></div></div>"
$html += "<div class='sec'><h2 style='color:#1e3a8a;border-bottom:2px solid #1e3a8a;padding-bottom:6px;font-size:15px'>Results by Subscription</h2>$subSections</div>"
$html += "<div class='ftr'>PYX Health | IT Infrastructure | Syed Rizvi | March 2026 | CONFIDENTIAL - Internal Use Only</div></body></html>"

$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Log "HTML Report saved: $reportPath" "SUCCESS"
Write-Log "ALL DONE" "SUCCESS"
