# DATABRICKS AUDIT - FULLY AUTOMATED
# READ ONLY - NO CHANGES
# GENERATES SEPARATE REPORTS PER WORKSPACE

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  DATABRICKS COMPREHENSIVE AUDIT REPORT" -ForegroundColor Cyan
Write-Host "  WITH COST BREAKDOWN PER WORKSPACE" -ForegroundColor Cyan
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

Write-Host "  Disconnecting old sessions..." -ForegroundColor Gray
try { Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null } catch { }

Write-Host "  Clearing token cache..." -ForegroundColor Gray
try { Clear-AzContext -Force -ErrorAction SilentlyContinue | Out-Null } catch { }

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
$subN = $sub.Name

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
# STEP 4: BUILD WORKSPACE INFO WITH MANAGED RGs
# ============================================================
Write-Host ""
Write-Host "Step 4: Getting workspace details..." -ForegroundColor Yellow

$workspaceData = @()
foreach ($w in $wsList) {
    $wsRGs = @($w.ResourceGroupName)
    try {
        $det = Get-AzDatabricksWorkspace -ResourceGroupName $w.ResourceGroupName -Name $w.Name -ErrorAction SilentlyContinue
        if ($det.ManagedResourceGroupId) {
            $mrg = $det.ManagedResourceGroupId.Split("/")[-1]
            $wsRGs += $mrg
        }
    } catch { }
    $workspaceData += [PSCustomObject]@{
        Name = $w.Name
        MainRG = $w.ResourceGroupName
        ManagedRG = if($wsRGs.Count -gt 1){$wsRGs[1]}else{""}
        Location = $w.Location
        RGs = $wsRGs
    }
    Write-Host "  $($w.Name): $($wsRGs -join ', ')" -ForegroundColor Gray
}

# ============================================================
# STEP 5: GENERATE REPORTS FOR EACH WORKSPACE
# ============================================================
Write-Host ""
Write-Host "Step 5: Generating reports for each workspace..." -ForegroundColor Yellow

$generatedReports = @()

foreach ($ws in $workspaceData) {
    $wsName = $ws.Name
    $wsRGs = $ws.RGs
    $dt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    Write-Host ""
    Write-Host "  Processing: $wsName" -ForegroundColor Cyan
    
    $allRes = @(); $vms = @(); $storage = @(); $nsgs = @(); $vnets = @(); $disks = @(); $pips = @(); $nics = @(); $idle = @()
    $costByResource = @(); $costByType = @{}; $totalCost5Mo = 0; $monthlyCosts = @()
    
    foreach ($rg in $wsRGs) {
        Write-Host "    Scanning: $rg" -ForegroundColor Gray
        
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
        
        Write-Host "    Getting costs: $rg" -ForegroundColor Gray
        try {
            $endDate = Get-Date
            $startDate = $endDate.AddMonths(-5)
            $usage = Get-AzConsumptionUsageDetail -ResourceGroup $rg -StartDate $startDate -EndDate $endDate -ErrorAction SilentlyContinue
            if ($usage) {
                $byRes = $usage | Group-Object InstanceName
                foreach ($br in $byRes) {
                    $resCost = [math]::Round(($br.Group | Measure-Object -Property PretaxCost -Sum).Sum, 2)
                    $resType = if($br.Group[0].ConsumedService){$br.Group[0].ConsumedService}else{"Unknown"}
                    $resName = $br.Name.Split("/")[-1]
                    if ($resCost -gt 0) {
                        $costByResource += [PSCustomObject]@{ Resource=$resName; Type=$resType; Cost=$resCost; RG=$rg }
                        if (-not $costByType.ContainsKey($resType)) { $costByType[$resType] = 0 }
                        $costByType[$resType] += $resCost
                    }
                    $totalCost5Mo += $resCost
                }
                $byMonth = $usage | Group-Object { $_.UsageStart.ToString("yyyy-MM") }
                foreach ($bm in $byMonth) {
                    $mCost = [math]::Round(($bm.Group | Measure-Object -Property PretaxCost -Sum).Sum, 2)
                    $existing = $monthlyCosts | Where-Object { $_.Month -eq $bm.Name }
                    if ($existing) { $existing.Total += $mCost }
                    else { $monthlyCosts += [PSCustomObject]@{ Month=$bm.Name; Total=$mCost } }
                }
            }
        } catch { }
    }
    
    $totalCost5Mo = [math]::Round($totalCost5Mo, 2)
    $monthlyCosts = $monthlyCosts | Sort-Object Month
    
    foreach ($vm in $vms) { if ($vm.Idle) { $idle += [PSCustomObject]@{ Name=$vm.Name; Type="VM"; RG=$vm.RG; Reason="Stopped"; EstMoCost=150 } } }
    foreach ($dd in $disks) { if ($dd.Unattached) { $idle += [PSCustomObject]@{ Name=$dd.Name; Type="Disk"; RG=$dd.RG; Reason="Unattached"; EstMoCost=20 } } }
    foreach ($pp in $pips) { if ($pp.Unassociated) { $idle += [PSCustomObject]@{ Name=$pp.Name; Type="PublicIP"; RG=$pp.RG; Reason="Unassociated"; EstMoCost=5 } } }
    foreach ($nn in $nics) { if ($nn.Unattached) { $idle += [PSCustomObject]@{ Name=$nn.Name; Type="NIC"; RG=$nn.RG; Reason="Unattached"; EstMoCost=0 } } }
    
    $avgMonthlyCost = if($monthlyCosts.Count -gt 0){[math]::Round($totalCost5Mo / $monthlyCosts.Count, 2)}else{0}
    $year1Cost = [math]::Round($avgMonthlyCost * 12, 2)
    $year2Cost = [math]::Round($year1Cost * 1.10, 2)
    $year3Cost = [math]::Round($year2Cost * 1.10, 2)
    $total3YearCost = [math]::Round($year1Cost + $year2Cost + $year3Cost, 2)
    
    $tVMs=$vms.Count; $tRun=@($vms|Where-Object{$_.Running}).Count; $tStop=$tVMs-$tRun
    $tStor=$storage.Count; $tDisk=$disks.Count; $tUaDisk=@($disks|Where-Object{$_.Unattached}).Count
    $tNSG=$nsgs.Count; $tVNet=$vnets.Count; $tPIP=$pips.Count; $tNIC=$nics.Count
    $tIdle=$idle.Count; $tRes=$allRes.Count
    
    $costByResource = $costByResource | Sort-Object Cost -Descending
    $top10Expensive = $costByResource | Select-Object -First 10
    
    $costByTypeList = @()
    foreach ($key in $costByType.Keys) { $costByTypeList += [PSCustomObject]@{ Type=$key; Cost=[math]::Round($costByType[$key],2) } }
    $costByTypeList = $costByTypeList | Sort-Object Cost -Descending
    
    $monthlySavings = ($idle | Measure-Object -Property EstMoCost -Sum).Sum
    if (-not $monthlySavings) { $monthlySavings = 0 }
    $yearlySavings = $monthlySavings * 12
    
    # BUILD HTML
    $safeWsName = $wsName -replace '[^a-zA-Z0-9\-]', '-'
    $htmlFile = Join-Path $ReportPath "$safeWsName-Report-$Timestamp.html"
    
    $h = New-Object System.Text.StringBuilder
    [void]$h.Append("<!DOCTYPE html><html><head><title>$wsName - Databricks Audit</title><style>")
    [void]$h.Append("body{font-family:Segoe UI,Arial;margin:20px;background:#f5f5f5}")
    [void]$h.Append(".hdr{background:linear-gradient(135deg,#FF3621,#E25A1C);color:#fff;padding:25px;border-radius:10px;margin-bottom:20px}")
    [void]$h.Append(".hdr h1{margin:0;font-size:24px}.hdr p{margin:8px 0 0 0}")
    [void]$h.Append(".grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:10px;margin-bottom:20px}")
    [void]$h.Append(".card{background:#fff;padding:12px;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,0.1);text-align:center}")
    [void]$h.Append(".card h3{margin:0;color:#666;font-size:9px;text-transform:uppercase}.card .n{font-size:22px;font-weight:bold;color:#FF3621;margin:5px 0}.card .s{color:#999;font-size:8px}")
    [void]$h.Append(".sec{background:#fff;padding:18px;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,0.1);margin-bottom:18px}")
    [void]$h.Append(".sec h2{color:#333;border-bottom:2px solid #FF3621;padding-bottom:8px;margin-top:0;font-size:16px}")
    [void]$h.Append("table{width:100%;border-collapse:collapse;margin-top:10px;font-size:11px}")
    [void]$h.Append("th{background:#FF3621;color:#fff;padding:7px;text-align:left}td{padding:5px;border-bottom:1px solid #eee}tr:hover{background:#fff8f6}")
    [void]$h.Append(".ok{color:#28a745;font-weight:bold}.bad{color:#dc3545;font-weight:bold}.warn{color:#ffc107;font-weight:bold}.idl{background:#fff3cd}")
    [void]$h.Append(".wc{background:linear-gradient(135deg,#ffc107,#fd7e14)}.wc .n,.wc h3{color:#333}")
    [void]$h.Append(".gc{background:linear-gradient(135deg,#28a745,#20c997)}.gc .n,.gc h3,.gc .s{color:#fff}")
    [void]$h.Append(".rc{background:linear-gradient(135deg,#dc3545,#c82333)}.rc .n,.rc h3,.rc .s{color:#fff}")
    [void]$h.Append(".ft{text-align:center;color:#666;padding:15px}")
    [void]$h.Append(".alert{background:#fff3cd;border-left:4px solid #ffc107;padding:15px;margin:15px 0;border-radius:4px}")
    [void]$h.Append(".tip{background:#e7f3ff;border-left:4px solid #0d6efd;padding:10px;margin:10px 0;border-radius:4px;font-size:12px}")
    [void]$h.Append(".big-cost{font-size:36px;font-weight:bold;color:#dc3545;text-align:center;padding:20px}")
    [void]$h.Append("</style></head><body>")
    
    [void]$h.Append("<div class='hdr'><h1>$wsName</h1><p>$subN | $dt</p><p style='font-size:12px'>Resource Groups: $($wsRGs -join ', ')</p></div>")
    
    [void]$h.Append("<div class='grid'>")
    [void]$h.Append("<div class='card rc'><h3>5 Mo Cost</h3><div class='n'>`$$totalCost5Mo</div></div>")
    [void]$h.Append("<div class='card'><h3>Monthly Avg</h3><div class='n'>`$$avgMonthlyCost</div></div>")
    [void]$h.Append("<div class='card'><h3>VMs</h3><div class='n'>$tVMs</div><div class='s'>$tRun running</div></div>")
    [void]$h.Append("<div class='card'><h3>Storage</h3><div class='n'>$tStor</div></div>")
    [void]$h.Append("<div class='card'><h3>Disks</h3><div class='n'>$tDisk</div></div>")
    [void]$h.Append("<div class='card wc'><h3>Idle</h3><div class='n'>$tIdle</div></div>")
    [void]$h.Append("<div class='card gc'><h3>Can Save</h3><div class='n'>`$$yearlySavings</div><div class='s'>per year</div></div>")
    [void]$h.Append("<div class='card'><h3>Resources</h3><div class='n'>$tRes</div></div>")
    [void]$h.Append("</div>")
    
    [void]$h.Append("<div class='sec'><h2>Smart Cost Analysis and Recommendations</h2>")
    [void]$h.Append("<div class='big-cost'>Total 5-Month Cost: `$$totalCost5Mo</div>")
    [void]$h.Append("<div class='alert'><strong>Cost Alert:</strong> This workspace costs approximately <strong>`$$avgMonthlyCost per month</strong>.</div>")
    if ($tIdle -gt 0) { [void]$h.Append("<div style='background:#d4edda;border-left:4px solid #28a745;padding:15px;margin:15px 0;border-radius:4px'><strong>Potential Savings!</strong> Save <strong>`$$yearlySavings/year</strong> by cleaning up $tIdle idle resources.</div>") }
    [void]$h.Append("<div class='tip'><strong>Recommendations:</strong><ul style='margin:5px 0'>")
    if ($tStop -gt 0) { [void]$h.Append("<li>Delete $tStop stopped VMs if not needed</li>") }
    if ($tUaDisk -gt 0) { [void]$h.Append("<li>Delete $tUaDisk unattached disks</li>") }
    [void]$h.Append("<li>Consider Reserved Instances for 40-60% savings</li>")
    [void]$h.Append("<li>Review storage tiers and lifecycle policies</li>")
    [void]$h.Append("<li>Use Databricks spot instances for non-critical jobs</li>")
    [void]$h.Append("</ul></div></div>")
    
    [void]$h.Append("<div class='sec'><h2>Cost Breakdown by Service Type (5 Months)</h2>")
    if ($costByTypeList.Count -gt 0) {
        [void]$h.Append("<table><tr><th>Service Type</th><th>Cost (USD)</th><th>% of Total</th><th>Recommendation</th></tr>")
        foreach ($ct in $costByTypeList) {
            $pct = if($totalCost5Mo -gt 0){[math]::Round(($ct.Cost / $totalCost5Mo) * 100, 1)}else{0}
            $rec = "Review usage"
            if ($ct.Type -like "*Storage*") { $rec = "Review tiers, enable lifecycle" }
            elseif ($ct.Type -like "*Compute*") { $rec = "Reserved Instances, right-size" }
            elseif ($ct.Type -like "*Databricks*") { $rec = "Cluster policies, spot instances" }
            elseif ($ct.Type -like "*Network*") { $rec = "Delete unused IPs" }
            $rowClass = if($pct -gt 30){"style='background:#fff3cd'"}else{""}
            [void]$h.Append("<tr $rowClass><td>$($ct.Type)</td><td>`$$($ct.Cost)</td><td>$pct%</td><td>$rec</td></tr>")
        }
        [void]$h.Append("</table>")
    } else { [void]$h.Append("<p>Cost breakdown not available.</p>") }
    [void]$h.Append("</div>")
    
    [void]$h.Append("<div class='sec'><h2>Top 10 Most Expensive Resources</h2>")
    if ($top10Expensive.Count -gt 0) {
        [void]$h.Append("<table><tr><th>#</th><th>Resource</th><th>Type</th><th>Cost (5 Mo)</th><th>Monthly</th></tr>")
        $rank = 1
        foreach ($exp in $top10Expensive) {
            $moAvg = [math]::Round($exp.Cost / 5, 2)
            $rowClass = if($rank -le 3){"style='background:#f8d7da'"}else{""}
            [void]$h.Append("<tr $rowClass><td>$rank</td><td>$($exp.Resource)</td><td>$($exp.Type)</td><td><strong>`$$($exp.Cost)</strong></td><td>`$$moAvg/mo</td></tr>")
            $rank++
        }
        [void]$h.Append("</table>")
    }
    [void]$h.Append("</div>")
    
    [void]$h.Append("<div class='sec'><h2>Monthly Cost Trend</h2>")
    if ($monthlyCosts.Count -gt 0) {
        [void]$h.Append("<table><tr><th>Month</th><th>Cost (USD)</th></tr>")
        foreach ($mc in $monthlyCosts) { [void]$h.Append("<tr><td>$($mc.Month)</td><td>`$$($mc.Total)</td></tr>") }
        [void]$h.Append("<tr style='background:#f0f0f0;font-weight:bold'><td>TOTAL</td><td>`$$totalCost5Mo</td></tr>")
        [void]$h.Append("</table>")
    }
    [void]$h.Append("</div>")
    
    [void]$h.Append("<div class='sec'><h2>3-Year Cost Projection</h2>")
    [void]$h.Append("<table><tr><th>Period</th><th>Cost</th></tr>")
    [void]$h.Append("<tr><td>Year 1</td><td>`$$year1Cost</td></tr>")
    [void]$h.Append("<tr><td>Year 2 (+10%)</td><td>`$$year2Cost</td></tr>")
    [void]$h.Append("<tr><td>Year 3 (+10%)</td><td>`$$year3Cost</td></tr>")
    [void]$h.Append("<tr style='background:#fff3cd;font-weight:bold'><td>TOTAL 3-YEAR</td><td>`$$total3YearCost</td></tr>")
    $optimized = [math]::Round($total3YearCost * 0.7, 2)
    [void]$h.Append("<tr style='background:#d4edda;font-weight:bold'><td>WITH 30% SAVINGS</td><td>`$$optimized</td></tr>")
    [void]$h.Append("</table></div>")
    
    if ($idle.Count -gt 0) {
        [void]$h.Append("<div class='sec'><h2>Idle Resources - Immediate Savings</h2>")
        [void]$h.Append("<table><tr><th>Resource</th><th>Type</th><th>RG</th><th>Reason</th><th>Est Cost</th><th>Action</th></tr>")
        foreach ($i in $idle) { [void]$h.Append("<tr class='idl'><td>$($i.Name)</td><td>$($i.Type)</td><td>$($i.RG)</td><td>$($i.Reason)</td><td>`$$($i.EstMoCost)/mo</td><td><strong>DELETE</strong></td></tr>") }
        [void]$h.Append("<tr style='background:#c3e6cb;font-weight:bold'><td colspan='4'>TOTAL SAVINGS</td><td>`$$monthlySavings/mo</td><td>`$$yearlySavings/yr</td></tr>")
        [void]$h.Append("</table></div>")
    }
    
    if($vms.Count -gt 0){
        [void]$h.Append("<div class='sec'><h2>VMs ($tVMs)</h2><table><tr><th>Name</th><th>RG</th><th>Size</th><th>OS</th><th>State</th><th>Status</th></tr>")
        foreach($vm in $vms){$c="ok";$ss="Running";$rr="";if(-not $vm.Running){$c="bad";$ss="Stopped";$rr="idl"};[void]$h.Append("<tr class='$rr'><td>$($vm.Name)</td><td>$($vm.RG)</td><td>$($vm.Size)</td><td>$($vm.OS)</td><td>$($vm.PowerState)</td><td class='$c'>$ss</td></tr>")}
        [void]$h.Append("</table></div>")
    }
    
    if($storage.Count -gt 0){
        [void]$h.Append("<div class='sec'><h2>Storage ($tStor)</h2><table><tr><th>Name</th><th>RG</th><th>Kind</th><th>SKU</th><th>Tier</th><th>Location</th></tr>")
        foreach($ss in $storage){[void]$h.Append("<tr><td>$($ss.Name)</td><td>$($ss.RG)</td><td>$($ss.Kind)</td><td>$($ss.Sku)</td><td>$($ss.Tier)</td><td>$($ss.Location)</td></tr>")}
        [void]$h.Append("</table></div>")
    }
    
    if($disks.Count -gt 0){
        [void]$h.Append("<div class='sec'><h2>Disks ($tDisk)</h2><table><tr><th>Name</th><th>Size</th><th>SKU</th><th>State</th><th>Attached</th><th>Status</th></tr>")
        foreach($dd in $disks){$c="ok";$ss="OK";$rr="";if($dd.Unattached){$c="warn";$ss="Unattached";$rr="idl"};[void]$h.Append("<tr class='$rr'><td>$($dd.Name)</td><td>$($dd.SizeGB)GB</td><td>$($dd.Sku)</td><td>$($dd.State)</td><td>$($dd.AttachedTo)</td><td class='$c'>$ss</td></tr>")}
        [void]$h.Append("</table></div>")
    }
    
    if($nsgs.Count -gt 0){
        [void]$h.Append("<div class='sec'><h2>NSGs ($tNSG)</h2><table><tr><th>Name</th><th>RG</th><th>Location</th><th>Rules</th><th>Subnets</th></tr>")
        foreach($nn in $nsgs){[void]$h.Append("<tr><td>$($nn.Name)</td><td>$($nn.RG)</td><td>$($nn.Location)</td><td>$($nn.Rules)</td><td>$($nn.Subnets)</td></tr>")}
        [void]$h.Append("</table></div>")
    }
    
    if($vnets.Count -gt 0){
        [void]$h.Append("<div class='sec'><h2>VNets ($tVNet)</h2><table><tr><th>Name</th><th>RG</th><th>Address</th><th>Subnets</th></tr>")
        foreach($vv in $vnets){[void]$h.Append("<tr><td>$($vv.Name)</td><td>$($vv.RG)</td><td>$($vv.Address)</td><td>$($vv.Subnets)</td></tr>")}
        [void]$h.Append("</table></div>")
    }
    
    if($pips.Count -gt 0){
        [void]$h.Append("<div class='sec'><h2>Public IPs ($tPIP)</h2><table><tr><th>Name</th><th>IP</th><th>Allocation</th><th>Associated</th><th>Status</th></tr>")
        foreach($pp in $pips){$c="ok";$ss="OK";$rr="";if($pp.Unassociated){$c="warn";$ss="Unassociated";$rr="idl"};[void]$h.Append("<tr class='$rr'><td>$($pp.Name)</td><td>$($pp.IP)</td><td>$($pp.Allocation)</td><td>$($pp.AssocTo)</td><td class='$c'>$ss</td></tr>")}
        [void]$h.Append("</table></div>")
    }
    
    if($nics.Count -gt 0){
        [void]$h.Append("<div class='sec'><h2>NICs ($tNIC)</h2><table><tr><th>Name</th><th>RG</th><th>Private IP</th><th>Attached</th><th>Status</th></tr>")
        foreach($nn in $nics){$c="ok";$ss="OK";$rr="";if($nn.Unattached){$c="warn";$ss="Unattached";$rr="idl"};[void]$h.Append("<tr class='$rr'><td>$($nn.Name)</td><td>$($nn.RG)</td><td>$($nn.PrivateIP)</td><td>$($nn.AttachedTo)</td><td class='$c'>$ss</td></tr>")}
        [void]$h.Append("</table></div>")
    }
    
    [void]$h.Append("<div class='sec'><h2>All Resources by Type</h2><table><tr><th>Type</th><th>Count</th></tr>")
    $grp = $allRes | Group-Object ResourceType | Sort-Object Count -Descending
    foreach ($g in $grp) { [void]$h.Append("<tr><td>$($g.Name)</td><td>$($g.Count)</td></tr>") }
    [void]$h.Append("</table></div>")
    
    [void]$h.Append("<div class='ft'>$wsName Audit | $dt | READ ONLY</div></body></html>")
    
    $h.ToString() | Out-File -FilePath $htmlFile -Encoding UTF8
    
    $csvPrefix = Join-Path $ReportPath "$safeWsName"
    $allRes | Select-Object Name,ResourceType,ResourceGroupName,Location | Export-Csv "$csvPrefix-Resources-$Timestamp.csv" -NoTypeInformation
    if ($costByResource.Count -gt 0) { $costByResource | Export-Csv "$csvPrefix-CostBreakdown-$Timestamp.csv" -NoTypeInformation }
    if ($idle.Count -gt 0) { $idle | Export-Csv "$csvPrefix-IdleResources-$Timestamp.csv" -NoTypeInformation }
    
    Write-Host "    HTML: $htmlFile" -ForegroundColor Green
    $generatedReports += $htmlFile
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  AUDIT COMPLETE!" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Generated $($generatedReports.Count) separate reports:" -ForegroundColor Cyan
foreach ($rpt in $generatedReports) { Write-Host "    - $rpt" -ForegroundColor White }
Write-Host ""
Write-Host "  ALL FILES SAVED TO:" -ForegroundColor Yellow
Write-Host "  $ReportPath" -ForegroundColor Cyan
Write-Host ""

foreach ($rpt in $generatedReports) { Start-Process $rpt }
Write-Host "Done!" -ForegroundColor Green
