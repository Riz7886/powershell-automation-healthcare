param(
    [Parameter(Mandatory=$false)]
    [string]$OutputFolder
)

if (-not $OutputFolder) {
    $latest = Get-ChildItem -Path $PSScriptRoot -Directory -Filter "EmergencyFix_*" | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { $latest = Get-ChildItem -Path (Get-Location).Path -Directory -Filter "EmergencyFix_*" | Sort-Object Name -Descending | Select-Object -First 1 }
    if (-not $latest) { Write-Host "No EmergencyFix folder found. Use -OutputFolder parameter." -ForegroundColor Red; exit 1 }
    $OutputFolder = $latest.FullName
}

Write-Host "Reading: $OutputFolder" -ForegroundColor Cyan

$csvFile = Get-ChildItem -Path $OutputFolder -Filter "SQL_Recommendations.csv" | Select-Object -First 1
$logFile = Get-ChildItem -Path $OutputFolder -Filter "fix.log" | Select-Object -First 1
$secretFile = Get-ChildItem -Path (Split-Path $OutputFolder) -Filter ".sp-secret" -ErrorAction SilentlyContinue | Select-Object -First 1

$allDbs = @()
if ($csvFile) { $allDbs = Import-Csv -Path $csvFile.FullName }

$logLines = @()
if ($logFile) { $logLines = Get-Content -Path $logFile.FullName }

$elimList = @($allDbs | Where-Object { $_.Act -eq "DELETE" })
$dropList = @($allDbs | Where-Object { $_.Act -eq "DROP" })
$okList = @($allDbs | Where-Object { $_.Act -eq "OK" })
$totalDbs = $allDbs.Count
$totalCost = [math]::Round(($allDbs | Measure-Object -Property Cost -Sum).Sum, 2)
$totalNewCost = [math]::Round(($allDbs | Measure-Object -Property NewCost -Sum).Sum, 2)
$totalSav = [math]::Round(($allDbs | Measure-Object -Property Save -Sum).Sum, 2)
$yearlySav = [math]::Round($totalSav * 12, 2)

$whStatus = "UNKNOWN"
$whDetails = ""
$spStatus = "UNKNOWN"
$spId = ""
$scimStatus = @()
$quotaInfo = ""
$subs = @()

foreach ($line in $logLines) {
    if ($line -match "WAREHOUSE ALREADY RUNNING|SQL WAREHOUSE IS RUNNING") { $whStatus = "RUNNING" }
    elseif ($line -match "RUNNING \[\d+/\d+\]") { $whStatus = "RUNNING" }
    elseif ($line -match "still starting|CHECK DATABRICKS") { $whStatus = "CHECK MANUALLY" }
    if ($line -match "Target:\s+(.+?)\s+\|") { $whDetails = $Matches[1] }
    if ($line -match "SP exists:\s+(\S+)|Created:\s+(\S+)|SP found:\s+(\S+)") { $spStatus = "OK"; $spId = ($Matches[1],$Matches[2],$Matches[3] | Where-Object {$_})[0] }
    if ($line -match "Current quota:\s+(.+)") { $quotaInfo = $Matches[1] }
    if ($line -match "Quota increase") { $quotaInfo += " | Increase submitted" }
    if ($line -match "Found (\d+) subscription") { $subs += $line }
    if ($line -match "Configured:\s+(.+)") { $whDetails += " | $($Matches[1])" }
}

$subGroups = $allDbs | Group-Object -Property Sub
$serverGroups = $allDbs | Group-Object -Property Server

$dbTableRows = ""
foreach ($db in ($allDbs | Sort-Object @{E={switch($_.Act){"DELETE"{0}"DROP"{1}default{2}}}},Sub,Server,DB)) {
    $rc = switch ($db.Act) { "DELETE" { "#ef4444" } "DROP" { "#f59e0b" } default { "#22c55e" } }
    $bg = switch ($db.Act) { "DELETE" { "background:#1a0505;" } "DROP" { "background:#1a1005;" } default { "" } }
    $dbTableRows += "<tr style='$bg'><td>$($db.Sub)</td><td>$($db.Server)</td><td style='font-weight:bold'>$($db.DB)</td><td>$($db.SKU)</td><td>$($db.AvgDTU)%</td><td>$($db.MaxDTU)%</td><td>$($db.Conn)</td><td style='color:$rc;font-weight:bold'>$($db.Rec)</td><td style='color:$rc;font-weight:bold'>$($db.Act)</td><td>`$$($db.Cost)</td><td>`$$($db.NewCost)</td><td style='color:#22c55e'>`$$($db.Save)</td></tr>"
}

$elimRows = ""
foreach ($e in $elimList) { $elimRows += "<tr><td>$($e.Sub)</td><td>$($e.Server)</td><td style='font-weight:bold;color:#fca5a5'>$($e.DB)</td><td>$($e.SKU)</td><td>$($e.AvgDTU)%</td><td>$($e.Conn)</td><td style='color:#22c55e'>`$$($e.Cost)/mo</td></tr>" }

$dropRows = ""
foreach ($d in $dropList) { $dropRows += "<tr><td>$($d.Sub)</td><td>$($d.Server)</td><td style='font-weight:bold'>$($d.DB)</td><td>$($d.SKU)</td><td style='color:#22c55e;font-weight:bold'>$($d.Rec)</td><td>$($d.AvgDTU)%</td><td>$($d.Conn)</td><td>`$$($d.Cost)</td><td>`$$($d.NewCost)</td><td style='color:#22c55e'>`$$($d.Save)/mo</td></tr>" }

$subSummaryRows = ""
foreach ($sg in $subGroups) {
    $sCost = [math]::Round(($sg.Group | Measure-Object -Property Cost -Sum).Sum, 2)
    $sSav = [math]::Round(($sg.Group | Measure-Object -Property Save -Sum).Sum, 2)
    $sElim = @($sg.Group | Where-Object { $_.Act -eq "DELETE" }).Count
    $sDrop = @($sg.Group | Where-Object { $_.Act -eq "DROP" }).Count
    $sOk = @($sg.Group | Where-Object { $_.Act -eq "OK" }).Count
    $subSummaryRows += "<tr><td style='font-weight:bold'>$($sg.Name)</td><td>$($sg.Count)</td><td style='color:#ef4444'>$sElim</td><td style='color:#f59e0b'>$sDrop</td><td style='color:#22c55e'>$sOk</td><td>`$$sCost</td><td style='color:#22c55e;font-weight:bold'>`$$sSav/mo</td></tr>"
}

$logHtml = ""
foreach ($l in $logLines) {
    $lc = "#94a3b8"
    if ($l -match "ERROR|FATAL|failed|FAIL") { $lc = "#ef4444" } elseif ($l -match "WARN|Yellow|stuck|trying") { $lc = "#f59e0b" } elseif ($l -match "OK|Green|RUNNING|Created|submitted|added") { $lc = "#22c55e" }
    $safe = $l -replace '<','&lt;' -replace '>','&gt;'
    $logHtml += "<div style='color:$lc;font-family:monospace;font-size:12px;line-height:1.6'>$safe</div>"
}

$deadline = [datetime]"2026-02-09"
$daysLeft = [math]::Max(0, ($deadline - (Get-Date)).Days)
$urgencyColor = if ($daysLeft -le 2) { '#ef4444' } elseif ($daysLeft -le 5) { '#f97316' } else { '#22c55e' }
$whColor = if ($whStatus -eq "RUNNING") { '#22c55e' } else { '#f59e0b' }
$spColor = if ($spStatus -eq "OK") { '#22c55e' } else { '#f59e0b' }

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Emergency Prod Fix Report - $(Get-Date -Format 'yyyy-MM-dd')</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',Tahoma,sans-serif;background:#0f172a;color:#e2e8f0;padding:20px}
.container{max-width:1500px;margin:0 auto}
.header{background:linear-gradient(135deg,#1e293b,#334155);border-radius:12px;padding:30px;margin-bottom:20px;border:1px solid #475569}
.header h1{font-size:26px;color:#f1f5f9;margin-bottom:5px}
.header p{color:#94a3b8;font-size:13px}
.banner{border-radius:12px;padding:18px;margin-bottom:15px;text-align:center}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-bottom:20px}
.card{background:#1e293b;border-radius:10px;padding:16px;border:1px solid #334155}
.card h3{font-size:11px;color:#94a3b8;text-transform:uppercase;letter-spacing:1px;margin-bottom:6px}
.card .v{font-size:32px;font-weight:700}
.card .s{font-size:11px;color:#64748b;margin-top:3px}
.section{background:#1e293b;border-radius:10px;padding:18px;margin-bottom:15px;border:1px solid #334155}
.section h2{font-size:16px;color:#f1f5f9;margin-bottom:12px;padding-bottom:8px;border-bottom:1px solid #334155}
table{width:100%;border-collapse:collapse;font-size:12px}
th{background:#0f172a;color:#94a3b8;padding:8px 10px;text-align:left;font-weight:600;text-transform:uppercase;font-size:10px;letter-spacing:0.5px;position:sticky;top:0}
td{padding:6px 10px;border-bottom:1px solid #1e293b}
tr:hover{background:#334155}
.footer{text-align:center;color:#475569;font-size:11px;margin-top:20px;padding:15px}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:10px;font-weight:600}
.badge-c{background:#7f1d1d;color:#fca5a5}.badge-w{background:#78350f;color:#fbbf24}.badge-o{background:#14532d;color:#86efac}
.ib{border-radius:8px;padding:14px;margin-bottom:12px}
@media print{body{background:#fff;color:#000}th{background:#f1f5f9;color:#000}td{border-color:#e2e8f0}.card,.section,.header{border-color:#e2e8f0;background:#fff}}
</style>
</head>
<body>
<div class="container">
<div class="header">
<h1>EMERGENCY PROD FIX - EXECUTION REPORT</h1>
<p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | Source: $OutputFolder</p>
</div>

<div class="banner" style="background:linear-gradient(135deg,$urgencyColor,$(if($daysLeft -le 2){'#dc2626'}else{'#ea580c'}))">
<h2 style="font-size:28px;color:#fff">$daysLeft DAYS UNTIL MFA ENFORCEMENT (Feb 9, 2026)</h2>
</div>

<div class="grid">
<div class="card"><h3>Warehouse</h3><div class="v" style="color:$whColor">$whStatus</div><div class="s">$whDetails</div></div>
<div class="card"><h3>Service Principal</h3><div class="v" style="color:$spColor">$spStatus</div><div class="s">$spId</div></div>
<div class="card"><h3>Databases Scanned</h3><div class="v" style="color:#60a5fa">$totalDbs</div><div class="s">Across $($subGroups.Count) subscriptions</div></div>
<div class="card"><h3>Eliminate (Delete)</h3><div class="v" style="color:#ef4444">$($elimList.Count)</div><div class="s">0 DTU + 0 connections</div></div>
<div class="card"><h3>Drop Tier</h3><div class="v" style="color:#f59e0b">$($dropList.Count)</div><div class="s">Oversized for usage</div></div>
<div class="card"><h3>OK (No Change)</h3><div class="v" style="color:#22c55e">$($okList.Count)</div><div class="s">Right-sized</div></div>
<div class="card"><h3>Current Monthly Cost</h3><div class="v" style="color:#f87171">`$$totalCost</div><div class="s">`$$([math]::Round($totalCost*12,2))/yr</div></div>
<div class="card"><h3>Monthly Savings</h3><div class="v" style="color:#22c55e">`$$totalSav</div><div class="s">`$$yearlySav/yr</div></div>
</div>

<div class="section" style="border:2px solid #f59e0b">
<h2 style="color:#f59e0b;font-size:18px">ACTIVE MICROSOFT ISSUES - EMERGENCY BRIEFING</h2>
<div class="ib" style="background:#7f1d1d;border-left:4px solid #ef4444">
<h3 style="color:#fca5a5;margin-bottom:6px">ISSUE 1: Azure Outage (Feb 2-3) - Hit Databricks West US</h3>
<p style="color:#e2e8f0;font-size:12px;line-height:1.6">Massive outage 19:46 UTC Feb 2 through 06:05 UTC Feb 3. Config change blocked public access to MS-managed storage accounts, cascading into Managed Identity failures in East US and West US. Services hit: Azure Databricks, Synapse, AKS, Container Apps, Firewall, GitHub Actions, Azure DevOps. Microsoft had to remove ALL traffic, repair at zero load, then ramp back up. Your Databricks workspaces in West US 2 were in the blast radius. Residual token/identity issues may persist — recycle clusters if warehouses are still flaky.</p>
</div>
<div class="ib" style="background:#7f1d1d;border-left:4px solid #ef4444">
<h3 style="color:#fca5a5;margin-bottom:6px">ISSUE 2: MFA Enforcement - $daysLeft DAYS (Feb 9, 2026)</h3>
<p style="color:#e2e8f0;font-size:12px;line-height:1.6">Feb 9: Microsoft enforces mandatory MFA for ALL M365 Admin Center users. Admins without MFA = locked out. Azure Portal MFA enforced since March 2025. Azure CLI/PowerShell/API MFA enforced since October 2025. M365 Admin Center is the final phase. Verify MFA on all admin accounts (Tony, John, Hunter, service desk) NOW.</p>
<table style="margin-top:8px"><tr><th>Target</th><th>Status</th></tr>
<tr><td>Azure Portal</td><td style="color:#22c55e">Enforced since March 2025</td></tr>
<tr><td>Azure CLI/PowerShell/APIs</td><td style="color:#22c55e">Enforced since October 2025</td></tr>
<tr><td style="color:#fca5a5;font-weight:bold">M365 Admin Center</td><td style="color:#ef4444;font-weight:bold">ENFORCING FEB 9, 2026</td></tr></table>
</div>
<div class="ib" style="background:#78350f;border-left:4px solid #f59e0b">
<h3 style="color:#fbbf24;margin-bottom:6px">ISSUE 3: Entra Portal - "Revoke Sessions" Button Change (Feb 2026)</h3>
<p style="color:#e2e8f0;font-size:12px;line-height:1.6">New "Revoke sessions" button replaces old "Revoke MFA sessions." New button invalidates ALL sessions (MFA + CA + per-user), not just per-user MFA. Inform helpdesk staff.</p>
</div>
<div class="ib" style="background:#78350f;border-left:4px solid #f59e0b">
<h3 style="color:#fbbf24;margin-bottom:6px">ISSUE 4: Authenticator Jailbreak/Root Detection (Feb 2026)</h3>
<p style="color:#e2e8f0;font-size:12px;line-height:1.6">Microsoft Authenticator auto-detects jailbroken/rooted devices and wipes all Entra credentials. Enabled by default. Anyone on a modified device loses MFA — must switch to unmodified device or hardware key.</p>
</div>
<div class="ib" style="background:#1e3a5f;border-left:4px solid #60a5fa">
<h3 style="color:#93c5fd;margin-bottom:6px">Service Principal Note</h3>
<p style="color:#e2e8f0;font-size:12px;line-height:1.6">The databricks-service-principal authenticates via client secret, NOT user MFA. Not affected by MFA enforcement. The az login browser flow already handles MFA (enforced since Oct 2025).</p>
</div>
</div>

<div class="section">
<h2>Phase 1: SQL Warehouse Fix</h2>
<table>
<tr><th>Item</th><th>Value</th></tr>
<tr><td>Warehouse Status</td><td style="color:$whColor;font-weight:bold">$whStatus</td></tr>
<tr><td>Target Warehouse</td><td>$whDetails</td></tr>
<tr><td>Quota (standardEDSv4Family westus2)</td><td>$quotaInfo</td></tr>
<tr><td>Root Cause</td><td>standardEDSv4Family quota 12 cores, need 32. Warehouse downsized to fit.</td></tr>
<tr><td>Resolution</td><td>Downsized cluster + requested quota increase to 64 cores. Scale back up after approval.</td></tr>
</table>
</div>

<div class="section">
<h2>Phase 2: Service Principal (databricks-service-principal)</h2>
<table>
<tr><th>Item</th><th>Value</th></tr>
<tr><td>App (Client) ID</td><td style="font-family:monospace">e44f4026-8d8e-4a26-a5c7-46269cc0d7de</td></tr>
<tr><td>SP Object ID</td><td style="font-family:monospace">$spId</td></tr>
<tr><td>Client Secret</td><td style="color:#22c55e">Created (saved to .sp-secret file)</td></tr>
<tr><td>Contributor Role</td><td style="color:#22c55e">Assigned to all Databricks workspaces</td></tr>
<tr><td>SCIM - adb-2758318924173706 (pyx-warehouse-prod)</td><td style="color:#22c55e">ADDED</td></tr>
<tr><td>SCIM - adb-3248848193480666 (pyxlake-databricks)</td><td style="color:#ef4444">403 Forbidden - needs PAT from this workspace</td></tr>
</table>
</div>

<div class="section">
<h2>Phase 3: SQL Database Summary by Subscription</h2>
<table>
<tr><th>Subscription</th><th>Total DBs</th><th style="color:#ef4444">Eliminate</th><th style="color:#f59e0b">Drop Tier</th><th style="color:#22c55e">OK</th><th>Current Cost</th><th>Savings</th></tr>
$subSummaryRows
<tr style="background:#0f172a;font-weight:bold"><td>TOTAL</td><td>$totalDbs</td><td style="color:#ef4444">$($elimList.Count)</td><td style="color:#f59e0b">$($dropList.Count)</td><td style="color:#22c55e">$($okList.Count)</td><td>`$$totalCost/mo</td><td style="color:#22c55e">`$$totalSav/mo (`$$yearlySav/yr)</td></tr>
</table>
</div>

$(if ($elimList.Count -gt 0) {
@"
<div class="section" style="border:2px solid #ef4444">
<h2 style="color:#ef4444">ELIMINATE - Idle Databases ($($elimList.Count) databases, 0 DTU + 0 connections)</h2>
<table>
<tr><th>Subscription</th><th>Server</th><th>Database</th><th>Current SKU</th><th>Avg DTU</th><th>Connections</th><th>Cost Eliminated</th></tr>
$elimRows
<tr style="background:#0f172a;font-weight:bold"><td colspan="6">TOTAL ELIMINATION SAVINGS</td><td style="color:#22c55e">`$$([math]::Round(($elimList | Measure-Object -Property Cost -Sum).Sum, 2))/mo</td></tr>
</table>
</div>
"@
})

$(if ($dropList.Count -gt 0) {
@"
<div class="section" style="border:2px solid #f59e0b">
<h2 style="color:#f59e0b">DROP TIER - Oversized Databases ($($dropList.Count) databases)</h2>
<table>
<tr><th>Subscription</th><th>Server</th><th>Database</th><th>Current</th><th>New Tier</th><th>Avg DTU</th><th>Connections</th><th>Old Cost</th><th>New Cost</th><th>Savings</th></tr>
$dropRows
<tr style="background:#0f172a;font-weight:bold"><td colspan="7">TOTAL TIER DROP SAVINGS</td><td>`$$([math]::Round(($dropList | Measure-Object -Property Cost -Sum).Sum, 2))</td><td>`$$([math]::Round(($dropList | Measure-Object -Property NewCost -Sum).Sum, 2))</td><td style="color:#22c55e">`$$([math]::Round(($dropList | Measure-Object -Property Save -Sum).Sum, 2))/mo</td></tr>
</table>
</div>
"@
})

<div class="section">
<h2>ALL DATABASES - Complete Scan Results ($totalDbs databases)</h2>
<div style="max-height:600px;overflow-y:auto">
<table>
<tr><th>Subscription</th><th>Server</th><th>Database</th><th>SKU</th><th>Avg DTU</th><th>Max DTU</th><th>Connections</th><th>Recommendation</th><th>Action</th><th>Current</th><th>New</th><th>Savings</th></tr>
$dbTableRows
</table>
</div>
</div>

<div class="section">
<h2>Action Items</h2>
<table>
<tr><th>#</th><th>Action</th><th>Owner</th><th>Priority</th><th>Deadline</th></tr>
<tr><td>1</td><td>Register MFA for all admin accounts at aka.ms/MFASetup</td><td>All Admins</td><td><span class="badge badge-c">CRITICAL</span></td><td>Before Feb 9</td></tr>
<tr><td>2</td><td>Fix SCIM 403 on pyxlake-databricks - generate PAT from that workspace and re-run SCIM add</td><td>Syed / John</td><td><span class="badge badge-c">CRITICAL</span></td><td>TODAY</td></tr>
<tr><td>3</td><td>Approve Azure quota increase: standardEDSv4Family westus2 (12 -> 64 cores), then scale warehouse back up</td><td>John / Tony</td><td><span class="badge badge-c">CRITICAL</span></td><td>TODAY</td></tr>
<tr><td>4</td><td>Review ELIMINATE list - confirm all $($elimList.Count) idle databases can be deleted (0 DTU, 0 connections, 14-day lookback)</td><td>Brian / Syed</td><td><span class="badge badge-w">HIGH</span></td><td>This week</td></tr>
<tr><td>5</td><td>Review DROP TIER list - confirm $($dropList.Count) tier changes match Brian's recommendations</td><td>Brian / Syed</td><td><span class="badge badge-w">HIGH</span></td><td>This week</td></tr>
<tr><td>6</td><td>Remove Shaun Raj personal account from production scripts - replace with SP</td><td>Syed / John</td><td><span class="badge badge-w">HIGH</span></td><td>This week</td></tr>
<tr><td>7</td><td>Set secret rotation reminder for SP client secret (expires in 1 year)</td><td>Syed</td><td><span class="badge badge-o">MEDIUM</span></td><td>This week</td></tr>
<tr><td>8</td><td>Recycle Databricks clusters if flaky after Feb 2-3 Azure outage</td><td>Syed</td><td><span class="badge badge-o">MEDIUM</span></td><td>As needed</td></tr>
<tr><td>9</td><td>Notify team: Authenticator wipes credentials on jailbroken/rooted devices starting Feb 2026</td><td>IT Admin</td><td><span class="badge badge-o">MEDIUM</span></td><td>Feb 28</td></tr>
</table>
</div>

<div class="section">
<h2>Execution Log</h2>
<div style="max-height:400px;overflow-y:auto;background:#0f172a;padding:12px;border-radius:6px">
$logHtml
</div>
</div>

<div class="footer">
<p>Emergency Prod Fix Report | Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Source: $OutputFolder</p>
<p style="margin-top:4px">MFA Deadline: February 9, 2026 | Days Remaining: $daysLeft</p>
</div>
</div>
</body>
</html>
"@

$reportFile = Join-Path $OutputFolder "Emergency-Fix-Report.html"
$html | Out-File -FilePath $reportFile -Encoding UTF8
Write-Host ""
Write-Host "REPORT GENERATED: $reportFile" -ForegroundColor Green
Write-Host ""
try { Start-Process $reportFile } catch {}
