#Requires -Modules Az.Accounts, Az.Websites, Az.CognitiveServices
<#
.SYNOPSIS
    PYX Health - Speech API v3.0 Scan - Sub-Drivers-Health-Prod ONLY
    Author:  Syed Rizvi
    Date:    March 2026
.EXAMPLE
    .\PYX-SpeechAPI-Scan-DriversHealthProd.ps1
#>

$ErrorActionPreference = "SilentlyContinue"
$WarningPreference     = "SilentlyContinue"
$SubId                 = "302aceb9-3ab3-4110-bb3e-64e0c118829a"
$SubName               = "Sub-Drivers-Health-Prod"
$NewVersion            = "2024-11-15"
$OutputPath            = "."
$Found                 = [System.Collections.ArrayList]::new()

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Prefix = switch ($Level) {
        "SUCCESS" {"[DONE]  "} "WARN" {"[WARN]  "} "ERROR" {"[ERROR] "}
        "SCAN"    {"[SCAN]  "} "FOUND"{"[FOUND] "} default {"[INFO]  "}
    }
    $Color = switch ($Level) {
        "SUCCESS" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"}
        "SCAN"    {"Cyan" } "FOUND"{"Red"   } default {"White"}
    }
    Write-Host "$Prefix[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Write-Line { Write-Host ("=" * 70) -ForegroundColor Blue }

Clear-Host
Write-Line
Write-Host "  PYX HEALTH - SPEECH API SCAN - SUB-DRIVERS-HEALTH-PROD" -ForegroundColor White
Write-Host "  Author: Syed Rizvi | The one subscription that was missed" -ForegroundColor Gray
Write-Line

# Check login
$ctx = Get-AzContext
if (-not $ctx) { Write-Log "Not logged in. Run Connect-AzAccount first." "ERROR"; exit 1 }
Write-Log "Logged in as: $($ctx.Account.Id)" "SUCCESS"

# Switch to this sub
Write-Log "Switching to $SubName..." "SCAN"
$ok = Set-AzContext -SubscriptionId $SubId -WarningAction SilentlyContinue
if (-not $ok) {
    Write-Log "Cannot access $SubName" "ERROR"
    Write-Log "Try: Connect-AzAccount -TenantId 4504822a-07ef-4037-94c0-e632d4ad1a72" "WARN"
    exit 1
}
Write-Log "Connected to $SubName" "SUCCESS"

$token = (Get-AzAccessToken).Token

# 1. Cognitive Services
Write-Log "[1/7] Scanning Cognitive Services..." "SCAN"
foreach ($cog in (Get-AzCognitiveServicesAccount)) {
    if ($cog.Kind -in @("SpeechServices","CognitiveServices","SpeechTranslation")) {
        Write-Log "FOUND Speech Service: $($cog.AccountName)" "FOUND"
        $null = $Found.Add("Cognitive Service: $($cog.AccountName) | RG: $($cog.ResourceGroupName)")
    }
}

# 2. App Services
Write-Log "[2/7] Scanning App Services and Function Apps..." "SCAN"
foreach ($app in (Get-AzWebApp)) {
    $full = Get-AzWebApp -ResourceGroupName $app.ResourceGroup -Name $app.Name
    if (-not $full -or -not $full.SiteConfig -or -not $full.SiteConfig.AppSettings) { continue }
    foreach ($s in $full.SiteConfig.AppSettings) {
        if ($s.Name -like "*SPEECH*" -or $s.Name -like "*STT*" -or
            $s.Value -like "*speechtotext/v3.0*" -or $s.Value -like "*/v3.0*") {
            Write-Log "FOUND: $($app.Name) - $($s.Name)" "FOUND"
            $null = $Found.Add("App Service: $($app.Name) | Setting: $($s.Name) = $($s.Value)")
        }
    }
}

# 3. API Management
Write-Log "[3/7] Scanning API Management..." "SCAN"
foreach ($apim in (Get-AzApiManagement)) {
    $ctx2 = New-AzApiManagementContext -ResourceGroupName $apim.ResourceGroupName -ServiceName $apim.Name
    foreach ($b in (Get-AzApiManagementBackend -Context $ctx2)) {
        if ($b.Url -like "*speechtotext/v3.0*" -or $b.Url -like "*speech*v3*") {
            Write-Log "FOUND APIM Backend: $($apim.Name)" "FOUND"
            $null = $Found.Add("APIM Backend: $($apim.Name) | URL: $($b.Url)")
        }
    }
}

# 4. Logic Apps
Write-Log "[4/7] Scanning Logic Apps..." "SCAN"
$laUri = "https://management.azure.com/subscriptions/$SubId/providers/Microsoft.Logic/workflows?api-version=2019-05-01"
$laResp = Invoke-RestMethod -Uri $laUri -Headers @{Authorization="Bearer $token"} -Method GET
foreach ($la in $laResp.value) {
    $defStr = $la.properties.definition | ConvertTo-Json -Depth 20
    if ($defStr -like "*speechtotext/v3.0*" -or $defStr -like "*speech*v3.0*") {
        Write-Log "FOUND Logic App: $($la.name)" "FOUND"
        $null = $Found.Add("Logic App: $($la.name) | Contains v3.0 reference")
    }
}

# 5. Container Apps
Write-Log "[5/7] Scanning Container Apps..." "SCAN"
$caUri = "https://management.azure.com/subscriptions/$SubId/providers/Microsoft.App/containerApps?api-version=2023-05-01"
$caResp = Invoke-RestMethod -Uri $caUri -Headers @{Authorization="Bearer $token"} -Method GET
foreach ($ca in $caResp.value) {
    $envVars = $ca.properties.template.containers | ForEach-Object { $_.env }
    foreach ($ev in $envVars) {
        if ($ev.name -like "*SPEECH*" -or $ev.value -like "*speechtotext/v3.0*") {
            Write-Log "FOUND Container App: $($ca.name)" "FOUND"
            $null = $Found.Add("Container App: $($ca.name) | Env: $($ev.name) = $($ev.value)")
        }
    }
}

# 6. Key Vault
Write-Log "[6/7] Scanning Key Vault Secrets..." "SCAN"
foreach ($kv in (Get-AzKeyVault)) {
    foreach ($s in (Get-AzKeyVaultSecret -VaultName $kv.VaultName)) {
        if ($s.Name -like "*SPEECH*" -or $s.Name -like "*STT*") {
            $val = Get-AzKeyVaultSecret -VaultName $kv.VaultName -Name $s.Name -AsPlainText
            if ($val -like "*speechtotext/v3.0*" -or $val -like "*/v3.0*") {
                Write-Log "FOUND Key Vault Secret: $($kv.VaultName)/$($s.Name)" "FOUND"
                $null = $Found.Add("Key Vault: $($kv.VaultName) | Secret: $($s.Name)")
            }
        }
    }
}

# 7. App Configuration
Write-Log "[7/7] Scanning App Configuration..." "SCAN"
$acUri = "https://management.azure.com/subscriptions/$SubId/providers/Microsoft.AppConfiguration/configurationStores?api-version=2023-03-01"
$acResp = Invoke-RestMethod -Uri $acUri -Headers @{Authorization="Bearer $token"} -Method GET
foreach ($ac in $acResp.value) {
    $kvUri = "$($ac.properties.endpoint)/kv?api-version=1.0"
    $kvResp = Invoke-RestMethod -Uri $kvUri -Headers @{Authorization="Bearer $token"} -Method GET
    foreach ($kv2 in $kvResp.items) {
        if ($kv2.value -like "*speechtotext/v3.0*" -or $kv2.value -like "*/v3.0*") {
            Write-Log "FOUND App Config: $($ac.name) | Key: $($kv2.key)" "FOUND"
            $null = $Found.Add("App Config: $($ac.name) | Key: $($kv2.key)")
        }
    }
}

# SUMMARY
Write-Line
Write-Host "  RESULT - SUB-DRIVERS-HEALTH-PROD" -ForegroundColor White
Write-Line

if ($Found.Count -eq 0) {
    Write-Log "CLEAN - Zero Speech API v3.0 issues found" "SUCCESS"
    Write-Log "Sub-Drivers-Health-Prod is fully clean" "SUCCESS"
} else {
    Write-Log "FOUND $($Found.Count) issues:" "FOUND"
    foreach ($f in $Found) { Write-Log "  $f" "FOUND" }
}

# Save small HTML report
$status = if ($Found.Count -eq 0) { "CLEAN" } else { "NEEDS FIX" }
$statusColor = if ($Found.Count -eq 0) { "#065f46" } else { "#991b1b" }
$statusBg    = if ($Found.Count -eq 0) { "#d1fae5" } else { "#fee2e2" }
$rows = if ($Found.Count -eq 0) {
    "<tr><td colspan='2' style='text-align:center;color:#065f46;font-weight:bold;padding:20px'>CLEAN - No Speech API v3.0 issues found</td></tr>"
} else {
    ($Found | ForEach-Object { "<tr><td>$_</td><td style='color:#991b1b;font-weight:bold'>NEEDS FIX</td></tr>" }) -join ""
}

$rp = Join-Path $OutputPath "PYX-DriversHealthProd-SpeechScan-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
"<!DOCTYPE html><html><head><meta charset='UTF-8'><title>Drivers Health Prod Scan</title><style>body{font-family:Arial,sans-serif;margin:0;background:#f8fafc}.hdr{background:$statusColor;color:#fff;padding:24px 32px}.hdr h1{margin:0;font-size:20px}.hdr p{margin:4px 0 0;font-size:12px;opacity:.85}.res{background:$statusBg;border-left:8px solid $statusColor;padding:16px 32px;font-size:18px;font-weight:bold;color:$statusColor}.sec{padding:20px 32px}table{width:100%;border-collapse:collapse;font-size:13px}th{background:#1e3a8a;color:#fff;padding:10px}td{padding:9px 12px;border-bottom:1px solid #e2e8f0}.ftr{padding:12px 32px;text-align:center;color:#94a3b8;font-size:11px;border-top:1px solid #e2e8f0}</style></head><body><div class='hdr'><h1>PYX Health - Sub-Drivers-Health-Prod - Speech API Scan</h1><p>$(Get-Date -Format 'MMMM dd yyyy HH:mm') | Author: Syed Rizvi</p></div><div class='res'>RESULT: $status - Issues Found: $($Found.Count)</div><div class='sec'><table><tr><th>Finding</th><th>Status</th></tr>$rows</table></div><div class='ftr'>PYX Health | Syed Rizvi | March 2026 | CONFIDENTIAL</div></body></html>" | Out-File -FilePath $rp -Encoding UTF8

Write-Log "Report saved: $rp" "SUCCESS"
Write-Log "DONE" "SUCCESS"
