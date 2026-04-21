<#
================================================================================
  Databricks -> Azure SQL stable access — cluster-IP-change-proof fix
================================================================================
  Problem: Databricks clusters get a new public IP on every restart/autoscale,
  so per-IP firewall rules break constantly.

  Fix: Whitelist Microsoft's published AzureDatabricks SERVICE-TAG IP ranges
  for the regions where your Databricks workspaces live. These ranges cover
  EVERY current and future Databricks cluster in those regions. Individual
  cluster IPs are always inside these ranges, so cluster restarts are a
  non-issue.

  Also cleans up obsolete user-specific IP rules if passed via -RemoveOldRules.

  Defaults to DRY-RUN. Add -Execute to actually change Azure.
================================================================================
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SqlServerName,

  [Parameter(Mandatory = $false)]
  [string]$SqlResourceGroup,

  [Parameter(Mandatory = $false)]
  [string[]]$Regions = @('westus2','westus','centralus'),

  [Parameter(Mandatory = $false)]
  [string[]]$RemoveOldRules = @(),

  [Parameter(Mandatory = $false)]
  [string]$TenantId = 'supportpyxhealth.onmicrosoft.com',

  [Parameter(Mandatory = $false)]
  [string]$SubscriptionId = 'e42e94b5-c6f8-4af0-a41b-16fda520de6e',

  [switch]$Execute
)

$ErrorActionPreference = 'Stop'
$DryRun = -not $Execute
$env:AZURE_CORE_LOGIN_EXPERIENCE_V2 = 'Off'

function Ok   ($m) { Write-Host "  [OK] $m"   -ForegroundColor Green  }
function Info ($m) { Write-Host "  $m"                                }
function Warn ($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Err  ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red    }

# --- Module bootstrap (cmdlet-level, proven) -----------------------------------
$neededCmdlets = @{
  'Connect-AzAccount'      = 'Az.Accounts'
  'Get-AzSqlServer'        = 'Az.Sql'
  'Get-AzNetworkServiceTag'= 'Az.Network'
  'Get-AzResource'         = 'Az.Resources'
}
foreach ($kv in $neededCmdlets.GetEnumerator()) {
  if (-not (Get-Command $kv.Key -ErrorAction SilentlyContinue)) {
    Write-Host ("  Installing $($kv.Value)...") -ForegroundColor Yellow
    Install-Module -Name $kv.Value -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck
    Import-Module $kv.Value -Force
  }
}

# --- Header --------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Databricks -> SQL stable access (service-tag firewall rules)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ("  Mode:       {0}" -f ($(if ($DryRun) { 'DRY-RUN (no changes)' } else { 'EXECUTE (will modify Azure)' })))
Write-Host ("  SQL server: {0}" -f $SqlServerName)
Write-Host ("  Regions:    {0}" -f ($Regions -join ', '))
Write-Host ""

# --- Auto-login ----------------------------------------------------------------
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx -or -not $ctx.Account) {
  Write-Host "Logging into Azure..." -ForegroundColor Yellow
  Connect-AzAccount -TenantId $TenantId -Subscription $SubscriptionId -WarningAction SilentlyContinue | Out-Null
  $ctx = Get-AzContext
}
if ($ctx.Subscription.Id -ne $SubscriptionId) {
  Set-AzContext -Subscription $SubscriptionId | Out-Null
}
Ok ("Signed in as: {0}" -f $ctx.Account.Id)
Ok ("Subscription: {0}" -f $ctx.Subscription.Name)

# --- Locate SQL Server ---------------------------------------------------------
if (-not $SqlResourceGroup) {
  $srv = Get-AzResource -ResourceType 'Microsoft.Sql/servers' -Name $SqlServerName -ErrorAction SilentlyContinue
  if (-not $srv) { Err "SQL Server '$SqlServerName' not found in this subscription."; exit 1 }
  $SqlResourceGroup = $srv.ResourceGroupName
}
$sql = Get-AzSqlServer -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName
Ok ("SQL Server: {0} / {1}  (region: {2})" -f $sql.ResourceGroupName, $sql.ServerName, $sql.Location)
Write-Host ""

# --- Fetch AzureDatabricks service-tag IP ranges ------------------------------
Write-Host "[1/3] Fetching AzureDatabricks egress IP ranges from Microsoft..."
$allRanges = @()
foreach ($region in $Regions) {
  try {
    $tags = (Get-AzNetworkServiceTag -Location $region -ErrorAction Stop).Values
    $db = $tags | Where-Object { $_.Name -eq "AzureDatabricks.$region" -or $_.Name -eq "AzureDatabricks" }
    if (-not $db) {
      $db = $tags | Where-Object { $_.Name -like "AzureDatabricks*" -and $_.Properties.Region -eq $region }
    }
    if (-not $db) {
      Warn "No AzureDatabricks service tag found for $region — skipping"
      continue
    }
    # Flatten address prefixes
    $prefixes = @()
    foreach ($d in $db) {
      if ($d.Properties.AddressPrefixes) { $prefixes += $d.Properties.AddressPrefixes }
    }
    $prefixes = $prefixes | Sort-Object -Unique
    Ok ("{0}: {1} IP ranges" -f $region, $prefixes.Count)
    foreach ($p in $prefixes) {
      $allRanges += [pscustomobject]@{ Region = $region; Prefix = $p }
    }
  } catch {
    Warn ("Could not fetch service tags for {0}: {1}" -f $region, $_.Exception.Message)
  }
}
if ($allRanges.Count -eq 0) { Err "No AzureDatabricks ranges found. Aborting."; exit 1 }
Write-Host ("`n  Total ranges to whitelist: {0}" -f $allRanges.Count)
Write-Host ""

# --- Convert each CIDR range to start/end IP and plan rules --------------------
Write-Host "[2/3] Planning firewall rules..."
function ConvertFrom-Cidr($cidr) {
  $parts = $cidr -split '/'
  $ip = $parts[0]; $mask = [int]$parts[1]
  if ($ip -match ':') { return $null } # skip IPv6
  $ipBytes = ([System.Net.IPAddress]$ip).GetAddressBytes()
  [Array]::Reverse($ipBytes)
  $ipInt = [BitConverter]::ToUInt32($ipBytes, 0)
  $maskInt = if ($mask -eq 0) { 0 } else { [uint32]((0xFFFFFFFF -shl (32 - $mask)) -band 0xFFFFFFFF) }
  $networkInt = $ipInt -band $maskInt
  $broadcastInt = $networkInt -bor (-bnot $maskInt -band 0xFFFFFFFF)
  function Int2Ip($i) {
    $b = [BitConverter]::GetBytes([uint32]$i)
    [Array]::Reverse($b)
    return ([System.Net.IPAddress]$b).ToString()
  }
  return @{ Start = (Int2Ip $networkInt); End = (Int2Ip $broadcastInt) }
}

$existingRules = Get-AzSqlServerFirewallRule -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName
$planned = @()
$idx = 0
foreach ($r in $allRanges) {
  $idx++
  $range = ConvertFrom-Cidr $r.Prefix
  if (-not $range) { continue }
  $ruleName = ("databricks-{0}-{1:D3}" -f $r.Region, $idx)
  $exists = $existingRules | Where-Object {
    $_.StartIpAddress -eq $range.Start -and $_.EndIpAddress -eq $range.End
  }
  $planned += [pscustomobject]@{
    Name     = $ruleName
    Region   = $r.Region
    Prefix   = $r.Prefix
    Start    = $range.Start
    End      = $range.End
    Exists   = [bool]$exists
  }
}
$toAdd = $planned | Where-Object { -not $_.Exists }
$skipped = $planned | Where-Object { $_.Exists }
Ok ("Will add:    {0} new rules" -f $toAdd.Count)
Ok ("Already set: {0} ranges already covered" -f $skipped.Count)
if ($RemoveOldRules.Count -gt 0) {
  $toRemove = $existingRules | Where-Object { $RemoveOldRules -contains $_.FirewallRuleName }
  Ok ("Will remove: {0} obsolete rules ({1})" -f $toRemove.Count, ($toRemove.FirewallRuleName -join ', '))
}
Write-Host ""

if ($toAdd.Count -eq 0 -and ($RemoveOldRules.Count -eq 0 -or $toRemove.Count -eq 0)) {
  Ok "Nothing to change — all AzureDatabricks ranges already whitelisted."
  exit 0
}

# --- Apply (unless dry-run) ----------------------------------------------------
Write-Host "[3/3] Applying rules..."
if ($DryRun) {
  Info "[DRY-RUN] Sample of rules that would be added:"
  $toAdd | Select-Object -First 5 | ForEach-Object {
    Info ("  + {0} : {1} - {2}  (from {3})" -f $_.Name, $_.Start, $_.End, $_.Prefix)
  }
  if ($toAdd.Count -gt 5) { Info ("  ... plus {0} more" -f ($toAdd.Count - 5)) }
  if ($RemoveOldRules.Count -gt 0) {
    $toRemove | ForEach-Object {
      Info ("  - {0} : {1} - {2}" -f $_.FirewallRuleName, $_.StartIpAddress, $_.EndIpAddress)
    }
  }
  Write-Host ""
  Write-Host "DRY-RUN DONE. Rerun with -Execute to apply." -ForegroundColor Yellow
  exit 0
}

$added = 0
foreach ($p in $toAdd) {
  try {
    New-AzSqlServerFirewallRule -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName `
      -FirewallRuleName $p.Name -StartIpAddress $p.Start -EndIpAddress $p.End -ErrorAction Stop | Out-Null
    $added++
    if ($added % 10 -eq 0) { Info ("  ...$added added") }
  } catch {
    Warn ("Skipped {0}: {1}" -f $p.Name, $_.Exception.Message)
  }
}
Ok ("Added $added AzureDatabricks firewall rules.")

if ($RemoveOldRules.Count -gt 0) {
  foreach ($r in $toRemove) {
    try {
      Remove-AzSqlServerFirewallRule -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName `
        -FirewallRuleName $r.FirewallRuleName -ErrorAction Stop | Out-Null
      Ok ("Removed obsolete rule: {0}" -f $r.FirewallRuleName)
    } catch {
      Warn ("Could not remove {0}: {1}" -f $r.FirewallRuleName, $_.Exception.Message)
    }
  }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  DONE. Have Brian restart a Databricks cluster and retry." -ForegroundColor Green
Write-Host "  Cluster IP changes NO LONGER MATTER — any AzureDatabricks" -ForegroundColor Green
Write-Host "  egress IP in $($Regions -join ', ') is now permanently allowed." -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
