<#
.SYNOPSIS
    PYX Health - Speech API v3.0 Fix
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

$Tenant1 = "4504822a-07ef-4037-94c0-e632d4ad1a72"
$Tenant2 = "8ef3d734-3ca5-4493-8d8b-52b2c54eab04"

$AllSubscriptions = @(
    @{ Name="sub-corp-prod-001";         Id="e42e94b5-c6f8-4af0-a41b-16fda520de6e"; T=$Tenant1 },
    @{ Name="sub-dataAnalytics-preProd"; Id="abcadd97-a465-41eb-8288-fef36da59fd5"; T=$Tenant1 },
    @{ Name="sub-dataAnalytics-prod";    Id="cf3b06f3-3865-48a4-8ded-2a97914f2f97"; T=$Tenant1 },
    @{ Name="sub-Drivers-Health-Test";   Id="fab2f5b8-5b17-4105-9348-8c4903e11748"; T=$Tenant1 },
    @{ Name="Sub-Drivers-Health-Prod";   Id="302aceb9-3ab3-4110-bb3e-64e0c118829a"; T=$Tenant1 },
    @{ Name="sub-it-management";         Id="a90514d9-361b-4119-a013-585d6765b35d"; T=$Tenant1 },
    @{ Name="sub-product-preProd";       Id="52d0d667-a89a-4fe0-be5c-3fb2d72e90ed"; T=$Tenant1 },
    @{ Name="sub-product-prod";          Id="730dd182-eb99-4f54-8f4c-698a5338013f"; T=$Tenant1 },
    @{ Name="Sub-Production";            Id="da72e6ae-e86d-4dfb-a5fd-dd6b2c96ae05"; T=$Tenant1 },
    @{ Name="sub-sandbox";               Id="076fbf87-2655-4fb0-810e-98cb4e1266dc"; T=$Tenant1 },
    @{ Name="Sub-Staging";               Id="e0ecde18-5086-4ee7-855a-8261a328eddc"; T=$Tenant1 },
    @{ Name="Azure-subscription-1";      Id="977e4f83-3649-428b-9416-cf9adfe24cec"; T=$Tenant2 },
    @{ Name="sub-csc-avd";               Id="7edfb9f6-940e-47cd-af4b-04d0b6e6020f"; T=$Tenant2 }
)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Prefix = switch ($Level) {
        "SUCCESS" {"[DONE]  "} "WARN" {"[WARN]  "} "ERROR" {"[ERROR] "}
        "SCAN"    {"[SCAN]  "} "FIX"  {"[FIX]   "} default {"[INFO]  "}
    }
    $Color = switch ($Level) {
        "SUCCESS" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"}
        "SCAN"    {"Cyan" } "FIX"  {"Magenta"} default {"White"}
    }
    Write-Host "$Prefix[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Write-Line { Write-Host ("=" * 70) -ForegroundColor Blue }

Clear-Host
Write-Line
Write-Host "  PYX HEALTH - SPEECH API v3.0 FIX - ALL 13 SUBSCRIPTIONS" -ForegroundColor White
Write-Host "  Author: Syed Rizvi | Mode: $Mode" -ForegroundColor Gray
Write-Line

$ctx = Get-AzContext
if (-not $ctx) { Write-Log "Not logged in." "ERROR"; exit 1 }
Write-Log "Logged in as: $($ctx.Account.Id)" "SUCCESS"
Write-Log "Mode: $Mode | Retirement: March 31 2026 - TOMORROW" "WARN"

$n = 0
foreach ($sub in $AllSubscriptions) {
    $n++
    Write-Line
    Write-Log "[$n/13] $($sub.Name)" "SCAN"

    $ok = Set-AzContext -SubscriptionId $sub.Id -WarningAction SilentlyContinue
    if (-not $ok) {
        Write-Log "No access to $($sub.Name) - skipping" "WARN"
        continue
    }
    Write-Log "Connected OK" "SUCCESS"

    $r = [PSCustomObject]@{
        Name   = $sub.Name
        Id     = $sub.Id
        Found  = [System.Collections.ArrayList]::new()
        Fixed  = [System.Collections.ArrayList]::new()
        Errors = [System.Collections.ArrayList]::new()
    }

    foreach ($cog in (Get-AzCognitiveServicesAccount)) {
        if ($cog.Kind -in @("SpeechServices","CognitiveServices","SpeechTranslation")) {
            Write-Log "Speech Service: $($cog.AccountName)" "WARN"
            $null = $r.Found.Add([PSCustomObject]@{
                Type="Cognitive Service"; Name=$cog.AccountName
                RG=$cog.ResourceGroupName; OldValue="v3.0 in use"
                NewValue="Update code to $NewVersion"; Fixed=$false
            })
        }
    }

    foreach ($app in (Get-AzWebApp)) {
        $full = Get-AzWebApp -ResourceGroupName $app.ResourceGroup -Name $app.Name
        if (-not $full -or -not $full.SiteConfig -or -not $full.SiteConfig.AppSettings) { continue }

        $hits = @($full.SiteConfig.AppSettings | Where-Object {
            $_.Name  -like "*SPEECH*" -or $_.Name  -like "*STT*" -or
            $_.Value -like "*speechtotext/v3.0*" -or $_.Value -like "*/v3.0*"
        })
        if ($hits.Count -eq 0) { continue }

        $type = if ($app.Kind -like "*functionapp*") {"Function App"} else {"Web App"}
        Write-Log "Found: $type $($app.Name)" "WARN"

        $hash = @{}
        $update = $false
        foreach ($s in $full.SiteConfig.AppSettings) { $hash[$s.Name] = $s.Value }

        foreach ($s in $hits) {
            $old = $s.Value
            $new = $old -replace "speechtotext/v3\.0","speechtotext/$NewVersion" -replace "/v3\.0","/$NewVersion"
            $null = $r.Found.Add([PSCustomObject]@{
                Type=$type; Name=$app.Name; RG=$app.ResourceGroup
                OldValue="$($s.Name) = $old"; NewValue="$($s.Name) = $new"; Fixed=$false
            })
            if ($old -ne $new) { $hash[$s.Name] = $new; $update = $true }
        }

        if ($update -and $Mode -eq "FIXALL") {
            if (-not (Test-Path $BackupFolder)) { New-Item -ItemType Directory -Path $BackupFolder | Out-Null }
            $full.SiteConfig.AppSettings | ConvertTo-Json | Out-File "$BackupFolder\$($sub.Name)-$($app.Name).json" -Encoding UTF8
            Write-Log "Backup saved" "SCAN"
            $fix = Set-AzWebApp -ResourceGroupName $app.ResourceGroup -Name $app.Name -AppSettings $hash
            if ($fix) {
                Write-Log "FIXED: $($app.Name)" "SUCCESS"
                $null = $r.Fixed.Add($app.Name)
                foreach ($i in $r.Found) { if ($i.Name -eq $app.Name) { $i.Fixed = $true } }
            } else {
                Write-Log "FAILED: $($app.Name)" "ERROR"
                $null = $r.Errors.Add($app.Name)
            }
        }
    }

    Write-Log "Found=$($r.Found.Count) Fixed=$($r.Fixed.Count)" "SUCCESS"
    $null = $AllResults.Add($r)
}

Write-Line
Write-Host "  FINAL SUMMARY" -ForegroundColor White
Write-Line

$gFound=0; $gFixed=0
foreach ($r in $AllResults) { $gFound += $r.Found.Count; $gFixed += $r.Fixed.Count }
$dur = [math]::Round(((Get-Date)-$StartTime).TotalSeconds)
Write-Log "Subscriptions Scanned : $($AllResults.Count)"
Write-Log "Resources Found       : $gFound"
Write-Log "Resources Fixed       : $gFixed" "SUCCESS"
Write-Log "Duration              : $dur seconds"
foreach ($r in $AllResults) {
    $st = if ($r.Found.Count -eq 0) {"CLEAN"} elseif ($r.Fixed.Count -ge $r.Found.Count) {"ALL FIXED"} else {"NEEDS FIX"}
    Write-Log "  $($r.Name) | Found=$($r.Found.Count) Fixed=$($r.Fixed.Count) | $st"
}

$rp = Join-Path $OutputPath "PYX-SpeechAPI-$Mode-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
$rows = ""
foreach ($r in $AllResults) {
    $hc = if ($r.Found.Count -eq 0) {"#065f46"} elseif ($r.Fixed.Count -ge $r.Found.Count) {"#065f46"} else {"#991b1b"}
    $sl = if ($r.Found.Count -eq 0) {"CLEAN"} elseif ($r.Fixed.Count -ge $r.Found.Count) {"ALL FIXED"} else {"NEEDS FIX"}
    $tr = ""
    if ($r.Found.Count -eq 0) {
        $tr = "<tr><td colspan='5' style='text-align:center;color:#6b7280;padding:12px'>No issues found</td></tr>"
    } else {
        foreach ($f in $r.Found) {
            $bg = if ($f.Fixed) {"#d1fae5"} elseif ($Mode -eq "REPORT") {"#fef3c7"} else {"#fee2e2"}
            $fc = if ($f.Fixed) {"#065f46"} elseif ($Mode -eq "REPORT") {"#92400e"} else {"#991b1b"}
            $ft = if ($f.Fixed) {"FIXED"} elseif ($Mode -eq "REPORT") {"NEEDS FIX"} else {"PENDING"}
            $tr += "<tr><td>$($f.Type)</td><td>$($f.Name)</td><td>$($f.RG)</td><td style='font-family:Courier New;font-size:11px'>$($f.OldValue)</td><td style='background:$bg;color:$fc;font-weight:bold;text-align:center'>$ft</td></tr>"
        }
    }
    $rows += "<div style='margin-bottom:24px'><div style='background:$hc;color:#fff;padding:10px 16px;font-weight:bold;font-size:13px;border-radius:6px 6px 0 0'>$($r.Name) | $($r.Id) | Found:$($r.Found.Count) Fixed:$($r.Fixed.Count) | $sl</div><table style='width:100%;border-collapse:collapse;font-size:12px'><tr style='background:#1e3a8a;color:#fff'><th style='padding:8px'>Type</th><th style='padding:8px'>Name</th><th style='padding:8px'>Resource Group</th><th style='padding:8px'>Setting</th><th style='padding:8px'>Status</th></tr>$tr</table></div>"
}

"<!DOCTYPE html><html><head><meta charset='UTF-8'><title>PYX Speech API Report</title><style>body{font-family:Arial,sans-serif;margin:0;background:#f8fafc}.hdr{background:#991b1b;color:#fff;padding:24px 32px}.hdr h1{margin:0;font-size:20px}.hdr p{margin:4px 0 0;font-size:12px;opacity:.85}.alert{background:#fef3c7;border-left:6px solid #d97706;padding:12px 32px;font-size:13px;color:#92400e;font-weight:bold}.kpi{display:flex;gap:12px;padding:16px 32px;background:#fff;border-bottom:1px solid #e2e8f0}.kb{flex:1;border-radius:8px;padding:12px;text-align:center}.val{font-size:26px;font-weight:700}.lbl{font-size:11px;margin-top:3px}.r{background:#fee2e2}.r .val{color:#991b1b}.g{background:#d1fae5}.g .val{color:#065f46}.b{background:#dbeafe}.b .val{color:#1e40af}.gr{background:#f1f5f9}.gr .val{color:#374151}.sec{padding:20px 32px}.ftr{padding:12px 32px;text-align:center;color:#94a3b8;font-size:11px;border-top:1px solid #e2e8f0}td{padding:7px 10px;border-bottom:1px solid #e2e8f0}</style></head><body><div class='hdr'><h1>PYX Health - Speech API v3.0 $Mode Report</h1><p>$(Get-Date -Format 'MMMM dd yyyy HH:mm') | Scanned: $($AllResults.Count) subs | Author: Syed Rizvi</p></div><div class='alert'>Speech-to-text REST API v3.0 retires March 31 2026 - TOMORROW. Update to $NewVersion</div><div class='kpi'><div class='kb gr'><div class='val'>$($AllResults.Count)</div><div class='lbl'>Scanned</div></div><div class='kb r'><div class='val'>$gFound</div><div class='lbl'>Found</div></div><div class='kb g'><div class='val'>$gFixed</div><div class='lbl'>Fixed</div></div><div class='kb b'><div class='val'>$dur sec</div><div class='lbl'>Duration</div></div></div><div class='sec'>$rows</div><div class='ftr'>PYX Health | Syed Rizvi | March 2026 | CONFIDENTIAL</div></body></html>" | Out-File -FilePath $rp -Encoding UTF8

Write-Log "Report: $rp" "SUCCESS"
Write-Log "DONE" "SUCCESS"
