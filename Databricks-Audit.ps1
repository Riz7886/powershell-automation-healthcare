# DATABRICKS AUDIT - FULLY AUTOMATED
# READ ONLY - NO CHANGES

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  DATABRICKS COMPREHENSIVE AUDIT REPORT" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

$ReportPath = "$env:USERPROFILE\Desktop\Databricks-Audit-Reports"
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not (Test-Path $ReportPath)) {
    New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
}

# ============================================================
# STEP 1: CLEAR OLD TOKENS AND FORCE FRESH LOGIN
# ============================================================
Write-Host "Step 1: Clearing old tokens and connecting fresh..." -ForegroundColor Yellow

# Disconnect any existing account
Write-Host "  Disconnecting old sessions..." -ForegroundColor Gray
try { Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null } catch { }

# Clear all cached contexts
Write-Host "  Clearing token cache..." -ForegroundColor Gray
try { Clear-AzContext -Force -ErrorAction SilentlyContinue | Out-Null } catch { }

# Force fresh login with browser
Write-Host "  Opening browser for fresh login..." -ForegroundColor Yellow
Write-Host ""
try {
    $loginResult = Connect-AzAccount -Force -ErrorAction Stop
    $ctx = Get-AzContext
    if (-not $ctx -or -not $ctx.Account) {
        Write-Host "ERROR: Login failed!" -ForegroundColor Red
        exit 1
    }
    Write-Host "Connected as: $($ctx.Account.Id)" -ForegroundColor Green
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ============================================================
# STEP 2: GET SUBSCRIPTIONS
# ============================================================
Write-Host ""
Write-Host "Step 2: Getting subscriptions..." -ForegroundColor Yellow

$subList = @()
try {
    $subList = @(Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq "Enabled" })
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if ($subList.Count -eq 0) {
    Write-Host "No subscriptions found!" -ForegroundColor Red
    exit 1
}

Write-Host "Found $($subList.Count) subscription(s):" -ForegroundColor Green
Write-Host ""
for ($i = 0; $i -lt $subList.Count; $i++) {
    Write-Host "  $($i + 1). $($subList[$i].Name)" -ForegroundColor White
}

Write-Host ""
$pick = Read-Host "Select subscription (1-$($subList.Count))"
$idx = [int]$pick - 1

if ($idx -lt 0 -or $idx -ge $subList.Count) {
    Write-Host "Invalid!" -ForegroundColor Red
    exit 1
}

$sub = $subList[$idx]
Write-Host "Setting: $($sub.Name)..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
Write-Host "Done!" -ForegroundColor Green

# ============================================================
# STEP 3: FIND DATABRICKS WORKSPACES
# ============================================================
Write-Host ""
Write-Host "Step 3: Finding Databricks workspaces..." -ForegroundColor Yellow

$wsList = @(Get-AzResource -ResourceType "Microsoft.Databricks/workspaces" -ErrorAction SilentlyContinue)

if ($wsList.Count -eq 0) {
    Write-Host "No Databricks workspaces found!" -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($wsList.Count) workspace(s):" -ForegroundColor Green
foreach ($w in $wsList) {
    Write-Host "  - $($w.Name) [RG: $($w.ResourceGroupName)]" -ForegroundColor Cyan
}

# ============================================================
# STEP 4: GET ALL RESOURCE GROUPS
# ============================================================
Write-Host ""
Write-Host "Step 4: Getting resource groups..." -ForegroundColor Yellow

$rgNames = @()
foreach ($w in $wsList) {
    if ($rgNames -notcontains $w.ResourceGroupName) { $rgNames += $w.ResourceGroupName }
    try {
        $det = Get-AzDatabricksWorkspace -ResourceGroupName $w.ResourceGroupName -Name $w.Name -ErrorAction SilentlyContinue
        if ($det.ManagedResourceGroupId) {
            $mrg = $det.ManagedResourceGroupId.Split("/")[-1]
            if ($rgNames -notcontains $mrg) { $rgNames += $mrg }
        }
    } catch { }
}
Write-Host "RGs: $($rgNames -join ', ')" -ForegroundColor Gray

# ============================================================
# STEP 5: SCAN ALL RESOURCES
# ============================================================
Write-Host ""
Write-Host "Step 5: Scanning resources..." -ForegroundColor Yellow

$allRes = @()
$vms = @()
$storage = @()
$nsgs = @()
$vnets = @()
$disks = @()
$pips = @()
$nics = @()
$idle = @()

foreach ($rg in $rgNames) {
    Write-Host "  $rg..." -ForegroundColor Gray
    
    $r = @(Get-AzResource -ResourceGroupName $rg -ErrorAction SilentlyContinue)
    $allRes += $r
    
    $v = @(Get-AzVM -ResourceGroupName $rg -ErrorAction SilentlyContinue)
    foreach ($vm in $v) {
        $st = Get-AzVM -ResourceGroupName $rg -Name $vm.Name -Status -ErrorAction SilentlyContinue
        $pwr = "Unknown"
        if ($st.Statuses) { $p = $st.Statuses | Where-Object { $_.Code -like "PowerState/*" }; if ($p) { $pwr = $p.DisplayStatus } }
        $run = ($pwr -eq "VM running")
        $vms += [PSCustomObject]@{ Name=$vm.Name; RG=$rg; Size=$vm.HardwareProfile.VmSize; Location=$vm.Location; PowerState=$pwr; OS=$vm.StorageProfile.OsDisk.OsType; Running=$run; Idle=(-not $run) }
    }
    
    $s = @(Get-AzStorageAccount -ResourceGroupName $rg -ErrorAction SilentlyContinue)
    foreach ($sa in $s) { $storage += [PSCustomObject]@{ Name=$sa.StorageAccountName; RG=$rg; Kind=$sa.Kind; Sku=$sa.Sku.Name; Location=$sa.Location; Tier=$sa.AccessTier } }
    
    $n = @(Get-AzNetworkSecurityGroup -ResourceGroupName $rg -ErrorAction SilentlyContinue)
    foreach ($nsg in $n) { $sn=""; if($nsg.Subnets){$sn=($nsg.Subnets.Id|ForEach-Object{$_.Split("/")[-1]})-join","}; $nsgs += [PSCustomObject]@{ Name=$nsg.Name; RG=$rg; Location=$nsg.Location; Rules=$nsg.SecurityRules.Count; Subnets=$sn } }
    
    $vn = @(Get-AzVirtualNetwork -ResourceGroupName $rg -ErrorAction SilentlyContinue)
    foreach ($vnet in $vn) { $addr=""; if($vnet.AddressSpace.AddressPrefixes){$addr=$vnet.AddressSpace.AddressPrefixes-join","}; $subs=""; if($vnet.Subnets){$subs=($vnet.Subnets.Name)-join","}; $vnets += [PSCustomObject]@{ Name=$vnet.Name; RG=$rg; Location=$vnet.Location; Address=$addr; Subnets=$subs } }
    
    $d = @(Get-AzDisk -ResourceGroupName $rg -ErrorAction SilentlyContinue)
    foreach ($disk in $d) { $att="Unattached"; $ua=$true; if($disk.ManagedBy){$att=$disk.ManagedBy.Split("/")[-1];$ua=$false}; $disks += [PSCustomObject]@{ Name=$disk.Name; RG=$rg; SizeGB=$disk.DiskSizeGB; Sku=$disk.Sku.Name; State=$disk.DiskState; AttachedTo=$att; Unattached=$ua } }
    
    $pi = @(Get-AzPublicIpAddress -ResourceGroupName $rg -ErrorAction SilentlyContinue)
    foreach ($pip in $pi) { $asc="Unassociated"; $ua=$true; if($pip.IpConfiguration){$asc=$pip.IpConfiguration.Id.Split("/")[-3];$ua=$false}; $pips += [PSCustomObject]@{ Name=$pip.Name; RG=$rg; IP=$pip.IpAddress; Allocation=$pip.PublicIpAllocationMethod; AssocTo=$asc; Unassociated=$ua } }
    
    $nc = @(Get-AzNetworkInterface -ResourceGroupName $rg -ErrorAction SilentlyContinue)
    foreach ($nic in $nc) { $att="Unattached"; $ua=$true; if($nic.VirtualMachine){$att=$nic.VirtualMachine.Id.Split("/")[-1];$ua=$false}; $priv=""; if($nic.IpConfigurations){$priv=($nic.IpConfigurations.PrivateIpAddress)-join","}; $nics += [PSCustomObject]@{ Name=$nic.Name; RG=$rg; PrivateIP=$priv; AttachedTo=$att; Unattached=$ua } }
}

# ============================================================
# STEP 6: FIND IDLE RESOURCES
# ============================================================
Write-Host ""
Write-Host "Step 6: Finding idle resources..." -ForegroundColor Yellow

foreach ($vm in $vms) { if ($vm.Idle) { $idle += [PSCustomObject]@{ Name=$vm.Name; Type="VM"; RG=$vm.RG; Reason="Stopped" } } }
foreach ($d in $disks) { if ($d.Unattached) { $idle += [PSCustomObject]@{ Name=$d.Name; Type="Disk"; RG=$d.RG; Reason="Unattached" } } }
foreach ($p in $pips) { if ($p.Unassociated) { $idle += [PSCustomObject]@{ Name=$p.Name; Type="PublicIP"; RG=$p.RG; Reason="Unassociated" } } }
foreach ($n in $nics) { if ($n.Unattached) { $idle += [PSCustomObject]@{ Name=$n.Name; Type="NIC"; RG=$n.RG; Reason="Unattached" } } }

Write-Host "Idle: $($idle.Count)" -ForegroundColor Yellow

# ============================================================
# STEP 7: GENERATE REPORTS
# ============================================================
Write-Host ""
Write-Host "Step 7: Generating reports..." -ForegroundColor Yellow

$tVMs=$vms.Count; $tRun=@($vms|Where-Object{$_.Running}).Count; $tStop=$tVMs-$tRun
$tStor=$storage.Count; $tDisk=$disks.Count; $tUaDisk=@($disks|Where-Object{$_.Unattached}).Count
$tNSG=$nsgs.Count; $tVNet=$vnets.Count; $tPIP=$pips.Count; $tNIC=$nics.Count
$tIdle=$idle.Count; $tRes=$allRes.Count; $tWS=$wsList.Count
$subN=$sub.Name; $dt=Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$htmlFile = Join-Path $ReportPath "Databricks-Report-$Timestamp.html"

$h = New-Object System.Text.StringBuilder
[void]$h.Append("<!DOCTYPE html><html><head><title>Databricks Audit</title><style>")
[void]$h.Append("body{font-family:Segoe UI,Arial;margin:20px;background:#f5f5f5}")
[void]$h.Append(".hdr{background:linear-gradient(135deg,#FF3621,#E25A1C);color:#fff;padding:25px;border-radius:10px;margin-bottom:20px}")
[void]$h.Append(".hdr h1{margin:0}.hdr p{margin:8px 0 0 0}")
[void]$h.Append(".grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin-bottom:20px}")
[void]$h.Append(".card{background:#fff;padding:15px;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,0.1);text-align:center}")
[void]$h.Append(".card h3{margin:0;color:#666;font-size:10px;text-transform:uppercase}.card .n{font-size:26px;font-weight:bold;color:#FF3621;margin:6px 0}.card .s{color:#999;font-size:9px}")
[void]$h.Append(".sec{background:#fff;padding:18px;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,0.1);margin-bottom:18px}")
[void]$h.Append(".sec h2{color:#333;border-bottom:2px solid #FF3621;padding-bottom:8px;margin-top:0;font-size:16px}")
[void]$h.Append("table{width:100%;border-collapse:collapse;margin-top:10px;font-size:11px}")
[void]$h.Append("th{background:#FF3621;color:#fff;padding:7px;text-align:left}td{padding:5px;border-bottom:1px solid #eee}tr:hover{background:#fff8f6}")
[void]$h.Append(".ok{color:#28a745;font-weight:bold}.bad{color:#dc3545;font-weight:bold}.warn{color:#ffc107;font-weight:bold}.idl{background:#fff3cd}")
[void]$h.Append(".wc{background:linear-gradient(135deg,#ffc107,#fd7e14)}.wc .n,.wc h3{color:#333}")
[void]$h.Append(".ft{text-align:center;color:#666;padding:15px}.ws{background:#f8f9fa;padding:10px;border-radius:6px;margin-bottom:8px;border-left:3px solid #FF3621}.ws b{color:#FF3621}")
[void]$h.Append("</style></head><body>")

[void]$h.Append("<div class='hdr'><h1>Databricks Audit Report</h1><p>$subN | $dt</p></div>")
[void]$h.Append("<div class='grid'>")
[void]$h.Append("<div class='card'><h3>Workspaces</h3><div class='n'>$tWS</div></div>")
[void]$h.Append("<div class='card'><h3>VMs</h3><div class='n'>$tVMs</div><div class='s'>$tRun running</div></div>")
[void]$h.Append("<div class='card'><h3>Storage</h3><div class='n'>$tStor</div></div>")
[void]$h.Append("<div class='card'><h3>Disks</h3><div class='n'>$tDisk</div><div class='s'>$tUaDisk unattached</div></div>")
[void]$h.Append("<div class='card'><h3>NSGs</h3><div class='n'>$tNSG</div></div>")
[void]$h.Append("<div class='card'><h3>VNets</h3><div class='n'>$tVNet</div></div>")
[void]$h.Append("<div class='card wc'><h3>Idle</h3><div class='n'>$tIdle</div></div>")
[void]$h.Append("<div class='card'><h3>Total</h3><div class='n'>$tRes</div></div>")
[void]$h.Append("</div>")

[void]$h.Append("<div class='sec'><h2>Workspaces ($tWS)</h2>")
foreach($w in $wsList){[void]$h.Append("<div class='ws'><b>$($w.Name)</b> - RG: $($w.ResourceGroupName) | $($w.Location)</div>")}
[void]$h.Append("</div>")

if($vms.Count -gt 0){
[void]$h.Append("<div class='sec'><h2>VMs ($tVMs)</h2><table><tr><th>Name</th><th>RG</th><th>Size</th><th>OS</th><th>State</th><th>Status</th></tr>")
foreach($vm in $vms){$c="ok";$s="Running";$r="";if(-not $vm.Running){$c="bad";$s="Stopped";$r="idl"};[void]$h.Append("<tr class='$r'><td>$($vm.Name)</td><td>$($vm.RG)</td><td>$($vm.Size)</td><td>$($vm.OS)</td><td>$($vm.PowerState)</td><td class='$c'>$s</td></tr>")}
[void]$h.Append("</table></div>")}

if($storage.Count -gt 0){
[void]$h.Append("<div class='sec'><h2>Storage ($tStor)</h2><table><tr><th>Name</th><th>RG</th><th>Kind</th><th>SKU</th><th>Tier</th><th>Location</th></tr>")
foreach($s in $storage){[void]$h.Append("<tr><td>$($s.Name)</td><td>$($s.RG)</td><td>$($s.Kind)</td><td>$($s.Sku)</td><td>$($s.Tier)</td><td>$($s.Location)</td></tr>")}
[void]$h.Append("</table></div>")}

if($disks.Count -gt 0){
[void]$h.Append("<div class='sec'><h2>Disks ($tDisk)</h2><table><tr><th>Name</th><th>Size</th><th>SKU</th><th>State</th><th>Attached</th><th>Status</th></tr>")
foreach($d in $disks){$c="ok";$s="OK";$r="";if($d.Unattached){$c="warn";$s="Unattached";$r="idl"};[void]$h.Append("<tr class='$r'><td>$($d.Name)</td><td>$($d.SizeGB)GB</td><td>$($d.Sku)</td><td>$($d.State)</td><td>$($d.AttachedTo)</td><td class='$c'>$s</td></tr>")}
[void]$h.Append("</table></div>")}

if($nsgs.Count -gt 0){
[void]$h.Append("<div class='sec'><h2>NSGs ($tNSG)</h2><table><tr><th>Name</th><th>RG</th><th>Location</th><th>Rules</th><th>Subnets</th></tr>")
foreach($n in $nsgs){[void]$h.Append("<tr><td>$($n.Name)</td><td>$($n.RG)</td><td>$($n.Location)</td><td>$($n.Rules)</td><td>$($n.Subnets)</td></tr>")}
[void]$h.Append("</table></div>")}

if($vnets.Count -gt 0){
[void]$h.Append("<div class='sec'><h2>VNets ($tVNet)</h2><table><tr><th>Name</th><th>RG</th><th>Address</th><th>Subnets</th></tr>")
foreach($v in $vnets){[void]$h.Append("<tr><td>$($v.Name)</td><td>$($v.RG)</td><td>$($v.Address)</td><td>$($v.Subnets)</td></tr>")}
[void]$h.Append("</table></div>")}

if($pips.Count -gt 0){
[void]$h.Append("<div class='sec'><h2>Public IPs ($tPIP)</h2><table><tr><th>Name</th><th>IP</th><th>Allocation</th><th>Associated</th><th>Status</th></tr>")
foreach($p in $pips){$c="ok";$s="OK";$r="";if($p.Unassociated){$c="warn";$s="Unassociated";$r="idl"};[void]$h.Append("<tr class='$r'><td>$($p.Name)</td><td>$($p.IP)</td><td>$($p.Allocation)</td><td>$($p.AssocTo)</td><td class='$c'>$s</td></tr>")}
[void]$h.Append("</table></div>")}

if($nics.Count -gt 0){
[void]$h.Append("<div class='sec'><h2>NICs ($tNIC)</h2><table><tr><th>Name</th><th>RG</th><th>Private IP</th><th>Attached</th><th>Status</th></tr>")
foreach($n in $nics){$c="ok";$s="OK";$r="";if($n.Unattached){$c="warn";$s="Unattached";$r="idl"};[void]$h.Append("<tr class='$r'><td>$($n.Name)</td><td>$($n.RG)</td><td>$($n.PrivateIP)</td><td>$($n.AttachedTo)</td><td class='$c'>$s</td></tr>")}
[void]$h.Append("</table></div>")}

if($idle.Count -gt 0){
[void]$h.Append("<div class='sec'><h2>Idle Resources ($tIdle)</h2><table><tr><th>Name</th><th>Type</th><th>RG</th><th>Reason</th></tr>")
foreach($i in $idle){[void]$h.Append("<tr class='idl'><td>$($i.Name)</td><td>$($i.Type)</td><td>$($i.RG)</td><td>$($i.Reason)</td></tr>")}
[void]$h.Append("</table></div>")}

[void]$h.Append("<div class='sec'><h2>Resources by Type</h2><table><tr><th>Type</th><th>Count</th></tr>")
$grp=$allRes|Group-Object ResourceType|Sort-Object Count -Descending
foreach($g in $grp){[void]$h.Append("<tr><td>$($g.Name)</td><td>$($g.Count)</td></tr>")}
[void]$h.Append("</table></div>")

[void]$h.Append("<div class='ft'>Databricks Audit | $dt | READ ONLY</div></body></html>")

$h.ToString() | Out-File -FilePath $htmlFile -Encoding UTF8
Write-Host "HTML: $htmlFile" -ForegroundColor Green

# CSVs
$allRes|Select-Object Name,ResourceType,ResourceGroupName,Location|Export-Csv (Join-Path $ReportPath "AllResources-$Timestamp.csv") -NoTypeInformation
if($vms.Count -gt 0){$vms|Export-Csv (Join-Path $ReportPath "VMs-$Timestamp.csv") -NoTypeInformation}
if($storage.Count -gt 0){$storage|Export-Csv (Join-Path $ReportPath "Storage-$Timestamp.csv") -NoTypeInformation}
if($disks.Count -gt 0){$disks|Export-Csv (Join-Path $ReportPath "Disks-$Timestamp.csv") -NoTypeInformation}
if($nsgs.Count -gt 0){$nsgs|Export-Csv (Join-Path $ReportPath "NSGs-$Timestamp.csv") -NoTypeInformation}
if($vnets.Count -gt 0){$vnets|Export-Csv (Join-Path $ReportPath "VNets-$Timestamp.csv") -NoTypeInformation}
if($idle.Count -gt 0){$idle|Export-Csv (Join-Path $ReportPath "Idle-$Timestamp.csv") -NoTypeInformation}
$wsList|Select-Object Name,ResourceGroupName,Location|Export-Csv (Join-Path $ReportPath "Workspaces-$Timestamp.csv") -NoTypeInformation

Write-Host "CSVs: $ReportPath" -ForegroundColor Green

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  COMPLETE" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  Workspaces: $tWS" -ForegroundColor White
Write-Host "  VMs:        $tVMs ($tRun running)" -ForegroundColor White
Write-Host "  Storage:    $tStor" -ForegroundColor White
Write-Host "  Disks:      $tDisk ($tUaDisk unattached)" -ForegroundColor White
Write-Host "  NSGs:       $tNSG" -ForegroundColor White
Write-Host "  VNets:      $tVNet" -ForegroundColor White
Write-Host "  TOTAL:      $tRes" -ForegroundColor Cyan
Write-Host "  IDLE:       $tIdle" -ForegroundColor Yellow
Write-Host ""

Start-Process $htmlFile
Write-Host "Done!" -ForegroundColor Green
