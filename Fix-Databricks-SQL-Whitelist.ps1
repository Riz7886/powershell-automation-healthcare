<#
================================================================================
  PYX — Databricks -> Azure SQL whitelist fix (subnet-based)
================================================================================
  Brian flagged that Databricks clusters get a new public IP on every restart,
  so the IP rule we added (20.245.178.35) won't survive. This script swaps
  IP-based firewall rules for SUBNET-based VNet rules, which are stable.

  What it does:
    1. Finds every Databricks workspace in the active subscription
    2. For each workspace that's VNet-injected (Hybrid + No Public IP),
       resolves the 2 subnets the clusters use
    3. Enables the Microsoft.Sql service endpoint on each subnet (if not already)
    4. Adds each subnet to the target SQL Server's VNet firewall rules
    5. Optionally removes the now-obsolete IP-based rule

  Defaults to DRY-RUN. Pass -Execute to actually change anything.

  USAGE
  -----
  .\Fix-Databricks-SQL-Whitelist.ps1 `
      -SqlServerName 'sql-qa-datasystems' `
      -SqlResourceGroup 'rg-corp-sql-qa'       # auto-detects if omitted
      -RemoveIpRuleName 'burge-20260421'       # optional: drop the old IP rule
      -Execute                                  # remove to dry-run first

  Requires Az PowerShell (pwsh 7+):  Install-Module Az -Scope CurrentUser
================================================================================
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SqlServerName,

  [Parameter(Mandatory = $false)]
  [string]$SqlResourceGroup,

  [Parameter(Mandatory = $false)]
  [string]$RemoveIpRuleName,

  [Parameter(Mandatory = $false)]
  [string]$TenantId = 'supportpyxhealth.onmicrosoft.com',

  [Parameter(Mandatory = $false)]
  [string]$SubscriptionName = 'sub-corp-prod-001',

  [switch]$Execute
)

$ErrorActionPreference = 'Stop'
$DryRun = -not $Execute

function Ok   ($m) { Write-Host "  [OK] $m"    -ForegroundColor Green  }
function Info ($m) { Write-Host "  $m"                                  }
function Warn ($m) { Write-Host "  [WARN] $m"  -ForegroundColor Yellow }
function Err  ($m) { Write-Host "  [FAIL] $m"  -ForegroundColor Red    }

# ------------------------------------------------------------------------------
# 0. Auto-install Az module if missing (first-run only)
# ------------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
  Write-Host ""
  Write-Host "Az PowerShell module not found. Installing..." -ForegroundColor Yellow
  Install-Module Az -Scope CurrentUser -Force -AllowClobber
  Ok "Az module installed."
}
Import-Module Az.Accounts, Az.Resources, Az.Network, Az.Sql, Az.Databricks -ErrorAction SilentlyContinue | Out-Null

# ------------------------------------------------------------------------------
# 1. Auto-login + auto-select subscription (no copy/paste)
# ------------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  PYX Databricks -> Azure SQL subnet-whitelist fix" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ("  Mode:   {0}" -f ($(if ($DryRun) { 'DRY-RUN (no changes)' } else { 'EXECUTE (will modify Azure)' })))
Write-Host ""

$ctx = Get-AzContext -ErrorAction SilentlyContinue
$needsLogin = $false

if (-not $ctx -or -not $ctx.Account) {
  $needsLogin = $true
} elseif ($ctx.Tenant.Id -and $TenantId -and $ctx.Tenant.Directory -ne $TenantId -and $ctx.Tenant.Id -ne $TenantId) {
  # Signed in to a different tenant — re-auth into PYX tenant
  $needsLogin = $true
}

if ($needsLogin) {
  Write-Host "Not logged in (or wrong tenant) — opening browser for Azure login..." -ForegroundColor Yellow
  try {
    Connect-AzAccount -TenantId $TenantId -ErrorAction Stop | Out-Null
  } catch {
    Err ("Azure login failed: {0}" -f $_.Exception.Message)
    exit 1
  }
  $ctx = Get-AzContext
}
Ok ("Signed in as: {0}" -f $ctx.Account.Id)

# Switch to the right subscription if we're not already on it
if ($ctx.Subscription.Name -ne $SubscriptionName -and $ctx.Subscription.Id -ne $SubscriptionName) {
  try {
    Set-AzContext -Subscription $SubscriptionName -ErrorAction Stop | Out-Null
    $ctx = Get-AzContext
  } catch {
    Err ("Could not switch to subscription '{0}': {1}" -f $SubscriptionName, $_.Exception.Message)
    Info "Available subscriptions for your account:"
    Get-AzSubscription | ForEach-Object { Info (" - {0} ({1})" -f $_.Name, $_.Id) }
    exit 1
  }
}
Ok ("Subscription: {0} ({1})" -f $ctx.Subscription.Name, $ctx.Subscription.Id)
Write-Host ""

# ------------------------------------------------------------------------------
# 2. Locate the target SQL Server
# ------------------------------------------------------------------------------
Write-Host "[1/4] Locating SQL Server '$SqlServerName'..."
if (-not $SqlResourceGroup) {
  $sql = Get-AzSqlServer -ErrorAction SilentlyContinue | Where-Object { $_.ServerName -eq $SqlServerName }
  if (-not $sql) { Err "SQL Server not found in this subscription."; exit 1 }
  if ($sql.Count -gt 1) {
    Err "Multiple SQL Servers named '$SqlServerName' — pass -SqlResourceGroup explicitly."
    $sql | ForEach-Object { Info (" - $($_.ResourceGroupName) / $($_.ServerName) ($($_.Location))") }
    exit 1
  }
  $SqlResourceGroup = $sql.ResourceGroupName
} else {
  $sql = Get-AzSqlServer -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName
}
Ok ("SQL Server: {0} / {1}  (region: {2})" -f $sql.ResourceGroupName, $sql.ServerName, $sql.Location)
Write-Host ""

# ------------------------------------------------------------------------------
# 3. Enumerate all Databricks workspaces, pick the VNet-injected ones
# ------------------------------------------------------------------------------
Write-Host "[2/4] Discovering Databricks workspaces..."
$workspaces = Get-AzResource -ResourceType 'Microsoft.Databricks/workspaces'
if (-not $workspaces) { Err "No Databricks workspaces found."; exit 1 }

$injected = @()
foreach ($w in $workspaces) {
  $full = Get-AzResource -ResourceId $w.ResourceId -ExpandProperties
  $state = $full.Properties.provisioningState
  $params = $full.Properties.parameters
  $vnetId = $params.customVirtualNetworkId.value
  $pubSub = $params.customPublicSubnetName.value
  $priSub = $params.customPrivateSubnetName.value

  if ($state -ne 'Succeeded') {
    Warn ("Skipping {0}: state={1} (fix the workspace first, then re-run)" -f $w.Name, $state)
    continue
  }
  if (-not $vnetId) {
    Warn ("Skipping {0}: workspace is NOT VNet-injected (managed-default). Use Private Endpoint instead." -f $w.Name)
    continue
  }

  $injected += [pscustomobject]@{
    Name            = $w.Name
    Region          = $w.Location
    VNetId          = $vnetId
    PublicSubnet    = $pubSub
    PrivateSubnet   = $priSub
  }
  Ok ("{0} ({1}): VNet-injected, subnets={2}, {3}" -f $w.Name, $w.Location, $pubSub, $priSub)
}
if ($injected.Count -eq 0) { Err "No VNet-injected Databricks workspaces to process."; exit 1 }
Write-Host ""

# ------------------------------------------------------------------------------
# 4. Enable Microsoft.Sql service endpoint on each subnet + add VNet rule to SQL
# ------------------------------------------------------------------------------
Write-Host "[3/4] Enabling service endpoint + SQL VNet rule on each subnet..."
$ruleOps = @()
foreach ($w in $injected) {
  if ($w.Region -ne $sql.Location) {
    Warn ("{0} is in {1} but SQL is in {2} — cross-region VNet rules work but add latency. Private Endpoint is cleaner long-term." -f $w.Name, $w.Region, $sql.Location)
  }

  # Parse VNet id: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>
  $parts = $w.VNetId -split '/'
  $vnetRg = $parts[4]; $vnetName = $parts[-1]

  try {
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $vnetRg -Name $vnetName
  } catch {
    Err ("{0}: could not read VNet {1}/{2}: {3}" -f $w.Name, $vnetRg, $vnetName, $_.Exception.Message)
    continue
  }

  foreach ($sn in @($w.PublicSubnet, $w.PrivateSubnet)) {
    if (-not $sn) { continue }
    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $sn }
    if (-not $subnet) { Err ("{0}: subnet '{1}' missing on VNet {2}" -f $w.Name, $sn, $vnet.Name); continue }

    # Step A: service endpoint
    $hasSql = $subnet.ServiceEndpoints | Where-Object { $_.Service -eq 'Microsoft.Sql' }
    if ($hasSql) {
      Ok ("{0}/{1}: Microsoft.Sql SE already present" -f $vnet.Name, $sn)
    } else {
      if ($DryRun) {
        Info ("[DRY-RUN] Would enable Microsoft.Sql SE on {0}/{1}" -f $vnet.Name, $sn)
      } else {
        $newSEs = @()
        if ($subnet.ServiceEndpoints) { $newSEs += $subnet.ServiceEndpoints }
        $newSEs += [Microsoft.Azure.Commands.Network.Models.PSServiceEndpoint]@{ Service = 'Microsoft.Sql' }
        $vnet = Set-AzVirtualNetworkSubnetConfig -Name $sn -VirtualNetwork $vnet `
                  -AddressPrefix $subnet.AddressPrefix `
                  -ServiceEndpoint $newSEs.Service `
                  -NetworkSecurityGroup $subnet.NetworkSecurityGroup `
                  -RouteTable $subnet.RouteTable `
                  -Delegation $subnet.Delegations
        $vnet = Set-AzVirtualNetwork -VirtualNetwork $vnet
        Ok ("{0}/{1}: Microsoft.Sql SE enabled" -f $vnet.Name, $sn)
      }
    }

    # Step B: SQL VNet firewall rule
    $ruleName = ("dbw-{0}-{1}" -f $w.Name, $sn) -replace '[^a-zA-Z0-9-]', '-'
    if ($ruleName.Length -gt 128) { $ruleName = $ruleName.Substring(0,128) }
    $subnetId = ("{0}/subnets/{1}" -f $vnet.Id, $sn)

    $existing = Get-AzSqlServerVirtualNetworkRule -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName -ErrorAction SilentlyContinue |
                Where-Object { $_.VirtualNetworkSubnetId -eq $subnetId }
    if ($existing) {
      Ok ("SQL VNet rule already exists for {0}/{1}" -f $vnet.Name, $sn)
    } else {
      if ($DryRun) {
        Info ("[DRY-RUN] Would add SQL VNet rule '{0}' -> {1}" -f $ruleName, $subnetId)
      } else {
        New-AzSqlServerVirtualNetworkRule `
          -ResourceGroupName $SqlResourceGroup `
          -ServerName $SqlServerName `
          -VirtualNetworkRuleName $ruleName `
          -VirtualNetworkSubnetId $subnetId | Out-Null
        Ok ("SQL VNet rule '{0}' added" -f $ruleName)
      }
    }
    $ruleOps += [pscustomobject]@{ Workspace = $w.Name; Subnet = $sn; Applied = -not $DryRun }
  }
}
Write-Host ""

# ------------------------------------------------------------------------------
# 5. Optionally remove the old IP-based firewall rule
# ------------------------------------------------------------------------------
Write-Host "[4/4] Clean up old IP-based rule..."
if ($RemoveIpRuleName) {
  $oldRule = Get-AzSqlServerFirewallRule -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName -ErrorAction SilentlyContinue |
             Where-Object { $_.FirewallRuleName -eq $RemoveIpRuleName }
  if (-not $oldRule) {
    Info ("No IP rule named '{0}' found — nothing to remove." -f $RemoveIpRuleName)
  } elseif ($DryRun) {
    Info ("[DRY-RUN] Would remove IP rule '{0}' ({1} -> {2})" -f $RemoveIpRuleName, $oldRule.StartIpAddress, $oldRule.EndIpAddress)
  } else {
    Remove-AzSqlServerFirewallRule -ResourceGroupName $SqlResourceGroup -ServerName $SqlServerName -FirewallRuleName $RemoveIpRuleName | Out-Null
    Ok ("Removed obsolete IP rule '{0}'" -f $RemoveIpRuleName)
  }
} else {
  Info "No -RemoveIpRuleName passed. Keep the old IP rule for now if you want a belt-and-suspenders."
}

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
if ($DryRun) {
  Write-Host "  DRY-RUN COMPLETE. Rerun with  -Execute  to apply changes." -ForegroundColor Yellow
} else {
  Write-Host "  DONE. Test from Databricks:" -ForegroundColor Green
  Write-Host "    %sql  SELECT 1"
  Write-Host "  (from a notebook attached to ANY cluster in the workspace)"
}
Write-Host "================================================================" -ForegroundColor Cyan
