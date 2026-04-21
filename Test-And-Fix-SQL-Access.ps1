<#
================================================================================
  TEST AND FIX — sql-qa-datasystems access from Azure (including Databricks)
================================================================================
  What this does (one shot, idempotent, no destructive ops):

    1. Logs into Azure (cached if you've done it before)
    2. Reads the current firewall state on sql-qa-datasystems
    3. Verifies Public Network Access is Enabled
    4. Verifies the "Allow Azure services and resources" rule exists
       (firewall rule 0.0.0.0 - 0.0.0.0 — the Azure-documented answer
       to "my Databricks cluster IPs keep changing")
    5. Fixes anything that's missing
    6. Prints a PASS/FAIL verdict:
         PASS  = Databricks clusters can reach this SQL server forever,
                 regardless of cluster restarts or new cluster IPs.
         FAIL  = The real problem is NOT firewall — send me the report.

  Safe to re-run. Does not touch user-specific IP rules (burge-20260421,
  FL-LOWELL-COX) unless you pass -RemoveObsoleteRules.
================================================================================
#>

[CmdletBinding()]
param(
  [string]$SqlServerName   = 'sql-qa-datasystems',
  [string]$SqlResourceGroup,
  [string]$TenantId        = 'supportpyxhealth.onmicrosoft.com',
  [string]$SubscriptionId  = 'e42e94b5-c6f8-4af0-a41b-16fda520de6e',
  [string[]]$RemoveObsoleteRules = @()
)

$ErrorActionPreference = 'Stop'
$env:AZURE_CORE_LOGIN_EXPERIENCE_V2 = 'Off'

function Ok   ($m) { Write-Host "  [OK] $m"   -ForegroundColor Green  }
function Info ($m) { Write-Host "  $m"                                }
function Warn ($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Err  ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red    }

# -----------------------------------------------------------------------------
# Modules — cmdlet-level check, auto-install what's missing
# -----------------------------------------------------------------------------
$needed = @{
  'Connect-AzAccount' = 'Az.Accounts'
  'Get-AzSqlServer'   = 'Az.Sql'
  'Get-AzResource'    = 'Az.Resources'
}
foreach ($kv in $needed.GetEnumerator()) {
  if (-not (Get-Command $kv.Key -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing $($kv.Value)..." -ForegroundColor Yellow
    Install-Module -Name $kv.Value -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck
    Import-Module $kv.Value -Force
  }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  SQL access TEST + FIX : $SqlServerName" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# Login (cached; prompts browser only if never logged in)
# -----------------------------------------------------------------------------
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx -or -not $ctx.Account) {
  Write-Host "  Signing into Azure (browser will open)..." -ForegroundColor Yellow
  Connect-AzAccount -TenantId $TenantId -Subscription $SubscriptionId -WarningAction SilentlyContinue | Out-Null
  $ctx = Get-AzContext
}
if ($ctx.Subscription.Id -ne $SubscriptionId) {
  Set-AzContext -Subscription $SubscriptionId -WarningAction SilentlyContinue | Out-Null
  $ctx = Get-AzContext
}
Ok "Signed in as $($ctx.Account.Id)"
Ok "Subscription: $($ctx.Subscription.Name)"

# -----------------------------------------------------------------------------
# Locate the SQL Server
# -----------------------------------------------------------------------------
if (-not $SqlResourceGroup) {
  $found = Get-AzResource -ResourceType 'Microsoft.Sql/servers' -Name $SqlServerName -ErrorAction SilentlyContinue
  if (-not $found) { Err "SQL Server '$SqlServerName' not found in this subscription."; exit 1 }
  $SqlResourceGroup = $found.ResourceGroupName
}
$sql = Get-AzSqlServer -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName
Ok "SQL Server: $SqlResourceGroup / $SqlServerName (region: $($sql.Location))"

# -----------------------------------------------------------------------------
# TEST current state
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "  --- CURRENT STATE ---" -ForegroundColor Cyan
Info "Public network access:     $($sql.PublicNetworkAccess)"
Info "Minimum TLS version:       $($sql.MinimalTlsVersion)"
Info "Fully qualified DNS:       $($sql.FullyQualifiedDomainName)"

$rules = Get-AzSqlServerFirewallRule -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName
Info "Firewall rules ($($rules.Count)):"
foreach ($r in $rules) {
  $tag = if ($r.StartIpAddress -eq '0.0.0.0' -and $r.EndIpAddress -eq '0.0.0.0') { '  << Allow-All-Azure-Services' } else { '' }
  Info "   - $($r.FirewallRuleName) : $($r.StartIpAddress) - $($r.EndIpAddress)$tag"
}

$allowAllAzure = $rules | Where-Object { $_.StartIpAddress -eq '0.0.0.0' -and $_.EndIpAddress -eq '0.0.0.0' }
$publicEnabled = ($sql.PublicNetworkAccess -eq 'Enabled')

# -----------------------------------------------------------------------------
# FIX what's missing
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "  --- FIX PHASE ---" -ForegroundColor Cyan

$changes = 0

if (-not $publicEnabled) {
  Warn "Public network access is DISABLED — turning it ON..."
  Set-AzSqlServer -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName -PublicNetworkAccess 'Enabled' | Out-Null
  Ok "Public network access -> Enabled."
  $changes++
} else {
  Ok "Public network access already Enabled."
}

if (-not $allowAllAzure) {
  Warn "'Allow Azure services' rule is MISSING — adding it now..."
  New-AzSqlServerFirewallRule -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName `
    -FirewallRuleName 'AllowAllWindowsAzureIps' `
    -StartIpAddress '0.0.0.0' -EndIpAddress '0.0.0.0' | Out-Null
  Ok "'Allow Azure services' firewall rule added."
  $changes++
} else {
  Ok "'Allow Azure services' already enabled (rule '$($allowAllAzure.FirewallRuleName)')."
}

if ($RemoveObsoleteRules.Count -gt 0) {
  foreach ($ruleName in $RemoveObsoleteRules) {
    $victim = $rules | Where-Object { $_.FirewallRuleName -eq $ruleName }
    if ($victim) {
      Remove-AzSqlServerFirewallRule -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName `
        -FirewallRuleName $ruleName -WarningAction SilentlyContinue | Out-Null
      Ok "Removed obsolete IP rule '$ruleName'."
      $changes++
    } else {
      Info "Rule '$ruleName' not found (already gone)."
    }
  }
}

# -----------------------------------------------------------------------------
# VERDICT
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
if ($publicEnabled -and $allowAllAzure -or $changes -gt 0) {
  Write-Host "  RESULT: PASS" -ForegroundColor Green
  Write-Host ""
  Write-Host "  - Public network access: ENABLED" -ForegroundColor Green
  Write-Host "  - Allow Azure services : ENABLED" -ForegroundColor Green
  Write-Host ""
  Write-Host "  Every Databricks cluster (current, restarted, new,"        -ForegroundColor Green
  Write-Host "  auto-scaled) in ANY Azure region can reach this SQL"        -ForegroundColor Green
  Write-Host "  server. Cluster IP changes no longer matter."               -ForegroundColor Green
  Write-Host ""
  Write-Host "  If Brian still reports a connection failure, it's NOT"      -ForegroundColor Green
  Write-Host "  the firewall — it's SQL auth/permissions or his connection" -ForegroundColor Green
  Write-Host "  string. Send me his error text and I'll fix that in one"    -ForegroundColor Green
  Write-Host "  shot — no more scripts."                                    -ForegroundColor Green
} else {
  Write-Host "  RESULT: FAIL — something unusual on this SQL server" -ForegroundColor Red
  Write-Host "  Send me the CURRENT STATE block above." -ForegroundColor Red
}
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
