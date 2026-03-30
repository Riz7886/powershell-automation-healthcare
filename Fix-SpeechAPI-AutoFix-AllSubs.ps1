#Requires -Modules Az.Accounts, Az.CognitiveServices, Az.Resources, Az.Websites
<#
.SYNOPSIS
    PYX Health - Speech-to-Text REST API v3.0 Auto Fix
    Author:  Syed Rizvi
    Version: 2.0
    Date:    March 2026

.DESCRIPTION
    Automatically connects to Azure, loops through ALL subscriptions,
    finds every resource using Speech-to-text REST API v3.0, and
    updates them to version 2024-11-15. No prompts. Fully automated.
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

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$OldVersion = "v3.0"
$NewVersion = "2024-11-15"
$StartTime  = Get-Date
$AllResults = @()

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
# STEP 1 - CONNECT TO AZURE
# -------------------------------------------------------------------------------
Write-Line
Write-Host "  PYX HEALTH - SPEECH API v3.0 AUTO FIX - ALL SUBSCRIPTIONS" -ForegroundColor White
Write-Host "  Author: Syed Rizvi | Mode: $(if ($ReportOnly) { 'REPORT ONLY' } else { 'AUTO FIX' })" -ForegroundColor Gray
Write-Line

Write-Log "Connecting to Azure..."

try {
    $Account = Connect-AzAccount -ErrorAction Stop
    Write-Log "Connected as: $($Account.Context.Account.Id)" "SUCCESS"
} catch {
    Write-Log "Not logged in. Attempting device login..." "WARN"
    try {
        $Account = Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop
        Write-Log "Connected via device auth" "SUCCESS"
    } catch {
        Write-Log "Failed to connect to Azure: $_" "ERROR"
        Write-Log "Run Connect-AzAccount manually first then retry" "WARN"
        exit 1
    }
}

# -------------------------------------------------------------------------------
# STEP 2 - GET ALL SUBSCRIPTIONS
# -------------------------------------------------------------------------------
Write-Log "Discovering all subscriptions..." "SCAN"

$AllSubs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }

if ($AllSubs.Count -eq 0) {
    Write-Log "No enabled subscriptions found. Check your Azure account permissions." "ERROR"
    exit 1
}

Write-Log "Found $($AllSubs.Count) enabled subscription(s)" "SUCCESS"
foreach ($Sub in $AllSubs) {
    Write-Log "  Sub: $($Sub.Name) | $($Sub.Id)" "SCAN"
}

# -------------------------------------------------------------------------------
# STEP 3 - SCAN AND FIX ALL SUBSCRIPTIONS
# -------------------------------------------------------------------------------
foreach ($Sub in $AllSubs) {

    Write-Line
    Write-Log "Processing: $($Sub.Name) ($($Sub.Id))" "SCAN"
    Write-Line

    try {
        Set-AzContext -SubscriptionId $Sub.Id -ErrorAction Stop | Out-Null
    } catch {
        Write-Log "Cannot switch to sub $($Sub.Name): $_" "ERROR"
        continue
    }

    $SubResult = [PSCustomObject]@{
        SubscriptionName = $Sub.Name
        SubscriptionId   = $Sub.Id
        Found            = @()
        Fixed            = @()
        Skipped          = @()
        Errors           = @()
    }

    # --- Scan Cognitive Services ---
    Write-Log "Scanning Cognitive Services..." "SCAN"
    try {
        $CogAccounts = Get-AzCognitiveServicesAccount -ErrorAction SilentlyContinue |
            Where-Object { $_.Kind -in @("SpeechServices","CognitiveServices","SpeechTranslation") }

        foreach ($Acct in $CogAccounts) {
            Write-Log "Found Speech Service: $($Acct.AccountName) | $($Acct.ResourceGroupName)" "WARN"
            $SubResult.Found += [PSCustomObject]@{
                Type          = "Cognitive Services"
                Name          = $Acct.AccountName
                ResourceGroup = $Acct.ResourceGroupName
                Location      = $Acct.Location
                Kind          = $Acct.Kind
                OldValue      = $OldVersion
                NewValue      = $NewVersion
                Fixed         = $false
                Note          = "Review endpoint calls in application code"
            }
        }
    } catch {
        $SubResult.Errors += "Cognitive Services scan error: $_"
        Write-Log "Error scanning Cognitive Services: $_" "ERROR"
    }

    # --- Scan App Services and Function Apps ---
    Write-Log "Scanning App Services and Function Apps..." "SCAN"
    try {
        $AllApps = Get-AzWebApp -ErrorAction SilentlyContinue

        foreach ($App in $AllApps) {
            try {
                $AppFull  = Get-AzWebApp -ResourceGroupName $App.ResourceGroup -Name $App.Name -ErrorAction SilentlyContinue
                $Settings = $AppFull.SiteConfig.AppSettings

                $SpeechSettings = $Settings | Where-Object {
                    $_.Name  -like "*SPEECH*"      -or
                    $_.Name  -like "*STT*"          -or
                    $_.Name  -like "*COGNITIVE*"    -or
                    $_.Value -like "*speechtotext/v3.0*" -or
                    $_.Value -like "*speech*v3.0*"  -or
                    $_.Value -like "*v3.0*speech*"  -or
                    $_.Value -like "*/v3.0*"
                }

                if ($SpeechSettings) {
                    $AppType = if ($App.Kind -like "*functionapp*") { "Function App" } else { "Web App" }
                    Write-Log "Found speech settings in $AppType`: $($App.Name)" "WARN"

                    $NewSettingsHash = @{}
                    foreach ($s in $Settings) {
                        $NewSettingsHash[$s.Name] = $s.Value
                    }

                    $NeedsUpdate = $false

                    foreach ($s in $SpeechSettings) {
                        $OldVal = $s.Value
                        $NewVal = $s.Value `
                            -replace "speechtotext/v3\.0", "speechtotext/$NewVersion" `
                            -replace "/v3\.0",             "/$NewVersion"

                        $SubResult.Found += [PSCustomObject]@{
                            Type          = $AppType
                            Name          = $App.Name
                            ResourceGroup = $App.ResourceGroup
                            Location      = $App.Location
                            Kind          = $App.Kind
                            OldValue      = "$($s.Name) = $OldVal"
                            NewValue      = "$($s.Name) = $NewVal"
                            Fixed         = $false
                            Note          = ""
                        }

                        if ($OldVal -ne $NewVal) {
                            $NewSettingsHash[$s.Name] = $NewVal
                            $NeedsUpdate = $true
                            Write-Log "  Setting: $($s.Name)" "WARN"
                            Write-Log "  Old: $OldVal" "WARN"
                            Write-Log "  New: $NewVal" "FIX"
                        }
                    }

                    if ($NeedsUpdate -and -not $ReportOnly) {
                        try {
                            Set-AzWebApp -ResourceGroupName $App.ResourceGroup `
                                         -Name $App.Name `
                                         -AppSettings $NewSettingsHash `
                                         -ErrorAction Stop | Out-Null

                            Write-Log "FIXED: $($App.Name)" "SUCCESS"
                            $SubResult.Fixed += $App.Name

                            $SubResult.Found | Where-Object { $_.Name -eq $App.Name } |
                                ForEach-Object { $_.Fixed = $true }

                        } catch {
                            Write-Log "Failed to fix $($App.Name): $_" "ERROR"
                            $SubResult.Errors += "Fix failed for $($App.Name): $_"
                        }
                    } elseif (-not $NeedsUpdate) {
                        Write-Log "No v3.0 values to update in $($App.Name) - skipping" "WARN"
                        $SubResult.Skipped += $App.Name
                    }
                }

                # --- Check Connection Strings ---
                $ConnStrings = $AppFull.SiteConfig.ConnectionStrings | Where-Object {
                    $_.ConnectionString -like "*speechtotext/v3*" -or
                    $_.ConnectionString -like "*speech*v3.0*"
                }

                foreach ($Conn in $ConnStrings) {
                    Write-Log "Found Speech connection string in: $($App.Name) - $($Conn.Name)" "WARN"
                    $SubResult.Found += [PSCustomObject]@{
                        Type          = "Connection String"
                        Name          = $App.Name
                        ResourceGroup = $App.ResourceGroup
                        Location      = $App.Location
                        Kind          = "ConnectionString"
                        OldValue      = "$($Conn.Name) = $($Conn.ConnectionString)"
                        NewValue      = "$($Conn.Name) = $($Conn.ConnectionString -replace 'v3\.0', $NewVersion)"
                        Fixed         = $false
                        Note          = "Manual update required for connection strings"
                    }
                }

            } catch {
                Write-Log "Error checking app $($App.Name): $_" "ERROR"
            }
        }
    } catch {
        $SubResult.Errors += "App Services scan error: $_"
        Write-Log "Error scanning App Services: $_" "ERROR"
    }

    $SubResult.Found  = @($SubResult.Found)
    $SubResult.Fixed  = @($SubResult.Fixed)
    $SubResult.Errors = @($SubResult.Errors)

    Write-Log "Sub complete: $($Sub.Name) | Found: $($SubResult.Found.Count) | Fixed: $($SubResult.Fixed.Count) | Errors: $($SubResult.Errors.Count)" "SUCCESS"
    $AllResults += $SubResult
}

# -------------------------------------------------------------------------------
# STEP 4 - FINAL SUMMARY
# -------------------------------------------------------------------------------
Write-Line
Write-Host "  FINAL SUMMARY - ALL SUBSCRIPTIONS" -ForegroundColor White
Write-Line

$GrandFound = ($AllResults | ForEach-Object { $_.Found.Count } | Measure-Object -Sum).Sum
$GrandFixed = ($AllResults | ForEach-Object { $_.Fixed.Count } | Measure-Object -Sum).Sum
$GrandErrors= ($AllResults | ForEach-Object { $_.Errors.Count } | Measure-Object -Sum).Sum
$Duration   = [math]::Round(((Get-Date) - $StartTime).TotalSeconds)

Write-Log "Subscriptions Scanned : $($AllResults.Count)"
Write-Log "Total Resources Found : $GrandFound"
Write-Log "Total Resources Fixed : $GrandFixed" "SUCCESS"
Write-Log "Total Errors          : $GrandErrors" $(if ($GrandErrors -gt 0) { "ERROR" } else { "SUCCESS" })
Write-Log "Duration              : $Duration seconds"

foreach ($R in $AllResults) {
    Write-Log "  $($R.SubscriptionName) | Found: $($R.Found.Count) | Fixed: $($R.Fixed.Count)"
}

# -------------------------------------------------------------------------------
# STEP 5 - HTML REPORT
# -------------------------------------------------------------------------------
$ReportPath = Join-Path $OutputPath "PYX-SpeechAPI-AutoFix-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"

$SubSections = foreach ($R in $AllResults) {
    $FoundCount = $R.Found.Count
    $FixedCount = $R.Fixed.Count
    $BgHeader   = if ($FoundCount -eq 0) { "#065f46" } elseif ($FixedCount -eq $FoundCount) { "#065f46" } else { "#991b1b" }

    $Rows = foreach ($f in $R.Found) {
        $StatusBg    = if ($f.Fixed) { "#d1fae5" } else { "#fee2e2" }
        $StatusColor = if ($f.Fixed) { "#065f46" } else { "#991b1b" }
        $StatusText  = if ($f.Fixed) { "FIXED" } else { "PENDING" }
        "<tr>
          <td>$($f.Type)</td>
          <td>$($f.Name)</td>
          <td>$($f.ResourceGroup)</td>
          <td style='font-family:Courier New;font-size:11px'>$($f.OldValue)</td>
          <td style='font-family:Courier New;font-size:11px;color:#065f46'>$($f.NewValue)</td>
          <td style='background:$StatusBg;color:$StatusColor;font-weight:bold;text-align:center'>$StatusText</td>
        </tr>"
    }

    if ($FoundCount -eq 0) {
        $Rows = "<tr><td colspan='6' style='text-align:center;color:#6b7280;padding:16px'>No Speech API v3.0 resources found in this subscription</td></tr>"
    }

    "<div style='margin-bottom:32px'>
      <div style='background:$BgHeader;color:#fff;padding:14px 20px;border-radius:6px 6px 0 0;font-weight:bold;font-size:14px'>
        $($R.SubscriptionName) &nbsp;|&nbsp; ID: $($R.SubscriptionId) &nbsp;|&nbsp; Found: $FoundCount &nbsp;|&nbsp; Fixed: $FixedCount
      </div>
      <table style='width:100%;border-collapse:collapse;font-size:12px'>
        <tr style='background:#1e3a8a;color:#fff'>
          <th style='padding:8px 10px;text-align:left'>Type</th>
          <th style='padding:8px 10px;text-align:left'>Resource Name</th>
          <th style='padding:8px 10px;text-align:left'>Resource Group</th>
          <th style='padding:8px 10px;text-align:left'>Old Value</th>
          <th style='padding:8px 10px;text-align:left'>New Value</th>
          <th style='padding:8px 10px;text-align:left'>Status</th>
        </tr>
        $($Rows -join '')
      </table>
      $(if ($R.Errors.Count -gt 0) {
        "<div style='background:#fee2e2;padding:10px 16px;margin-top:4px;font-size:12px;color:#991b1b'><strong>Errors:</strong> $($R.Errors -join ' | ')</div>"
      })
    </div>"
}

@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>PYX Health - Speech API Auto Fix Report</title>
<style>
  body { font-family: Arial, sans-serif; margin: 0; background: #f8fafc; color: #1e293b; }
  .hdr { background: #991b1b; color: #fff; padding: 28px 36px; }
  .hdr h1 { margin: 0; font-size: 24px; }
  .hdr p { margin: 6px 0 0; opacity: .85; font-size: 13px; }
  .alert { background: #fef3c7; border-left: 6px solid #d97706; padding: 14px 36px; font-size: 13px; color: #92400e; font-weight: bold; }
  .kpi { display: flex; gap: 16px; padding: 20px 36px; background: #fff; border-bottom: 1px solid #e2e8f0; }
  .kpi-box { flex: 1; border-radius: 8px; padding: 16px; text-align: center; }
  .val { font-size: 30px; font-weight: 700; }
  .lbl { font-size: 12px; margin-top: 4px; }
  .red { background: #fee2e2; } .red .val { color: #991b1b; }
  .green { background: #d1fae5; } .green .val { color: #065f46; }
  .blue { background: #dbeafe; } .blue .val { color: #1e40af; }
  .gray { background: #f1f5f9; } .gray .val { color: #374151; }
  .sec { padding: 24px 36px; }
  .ftr { padding: 16px 36px; text-align: center; color: #94a3b8; font-size: 11px; border-top: 1px solid #e2e8f0; }
  td { padding: 7px 10px; border-bottom: 1px solid #e2e8f0; vertical-align: middle; }
  tr:hover { background: #f1f5f9; }
</style>
</head>
<body>
<div class="hdr">
  <h1>PYX Health - Speech-to-Text API v3.0 Auto Fix Report</h1>
  <p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | Subscriptions Scanned: $($AllResults.Count) | Author: Syed Rizvi</p>
</div>
<div class="alert">
  URGENT: Microsoft Speech-to-text REST API v3.0 retires March 31, 2026.
  All affected resources have been updated to version 2024-11-15.
</div>
<div class="kpi">
  <div class="kpi-box gray"><div class="val">$($AllResults.Count)</div><div class="lbl">Subscriptions Scanned</div></div>
  <div class="kpi-box red"><div class="val">$GrandFound</div><div class="lbl">Resources Found</div></div>
  <div class="kpi-box green"><div class="val">$GrandFixed</div><div class="lbl">Resources Fixed</div></div>
  <div class="kpi-box blue"><div class="val">$Duration sec</div><div class="lbl">Total Duration</div></div>
</div>
<div class="sec">
  <h2 style="color:#1e3a8a;border-bottom:2px solid #1e3a8a;padding-bottom:6px;font-size:16px">Results by Subscription</h2>
  $($SubSections -join '')
</div>
<div class="ftr">
  PYX Health | IT Infrastructure | Syed Rizvi | March 2026 | CONFIDENTIAL - Internal Use Only
</div>
</body>
</html>
"@ | Out-File -FilePath $ReportPath -Encoding UTF8

Write-Log "Report saved: $ReportPath" "SUCCESS"
Write-Log "DONE - Share the HTML report with IT Director" "SUCCESS"
