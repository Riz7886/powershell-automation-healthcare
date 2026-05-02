[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$Rollback
)

$Token = "PUT_YOUR_FRESH_PROD_TOKEN_HERE"
$WorkspaceUrl = "https://adb-2758318924173706.6.azuredatabricks.net"
$ServicePrincipalDisplayName = "databricks-prod-svc"
$RemoveUserName = "shaun.raj"

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($Token -eq "PUT_YOUR_FRESH_PROD_TOKEN_HERE" -or [string]::IsNullOrWhiteSpace($Token)) {
    Write-Host ""
    Write-Host "STOP - paste your fresh PROD-workspace PAT into line 7 of this script." -ForegroundColor Red
    Write-Host ""
    Write-Host "How to get a fresh PROD PAT:" -ForegroundColor Yellow
    Write-Host "  1. Open $WorkspaceUrl in browser"
    Write-Host "  2. Top-right avatar > User Settings > Developer > Access tokens > Manage > Generate new token"
    Write-Host "  3. Comment: prod-migrate, Lifetime: 90 days"
    Write-Host "  4. Copy the dapi... token, paste it into line 7 of this script, save, run again"
    exit 1
}

$OutputFolder = "$env:USERPROFILE\Documents\Databricks-Audit"
$BackupFolder = Join-Path $OutputFolder "backups-prod-full"
foreach ($d in @($OutputFolder, $BackupFolder)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$headers = @{ "Authorization" = "Bearer $Token"; "Content-Type" = "application/json" }
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $OutputFolder "Databricks-PROD-Full-$timestamp.html"
$spOutputPath = Join-Path $OutputFolder "Databricks-PROD-ServicePrincipal-$timestamp.txt"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  DATABRICKS PROD FULL MIGRATION - $(if ($Apply) { 'APPLY' } elseif ($Rollback) { 'ROLLBACK' } else { 'DRY RUN' })" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Workspace : $WorkspaceUrl"
Write-Host "  SP name   : $ServicePrincipalDisplayName"
Write-Host "  Remove    : $RemoveUserName"
Write-Host ""

function Ensure-AzModules {
    $required = @('Az.Accounts','Az.Resources')
    foreach ($m in $required) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Write-Host "  installing $m ..."
            Install-Module $m -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
        }
        Import-Module $m -Force -ErrorAction Stop
    }
    try { $ctx = Get-AzContext -ErrorAction Stop; if (-not $ctx -or -not $ctx.Account) { throw 'no ctx' } }
    catch { Connect-AzAccount | Out-Null }
}

function Invoke-DbrApi {
    param([string]$Path, [string]$Method = "GET", $Body)
    $uri = "$WorkspaceUrl$Path"
    $params = @{ Uri = $uri; Headers = $headers; Method = $Method; TimeoutSec = 90; UseBasicParsing = $true; ErrorAction = "Stop" }
    if ($Body) { $params["Body"] = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    try { return Invoke-RestMethod @params }
    catch {
        $status = $null
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch {}
        $bodyMsg = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $bodyMsg = $_.ErrorDetails.Message }
        if ($bodyMsg -and $bodyMsg.Length -gt 240) { $bodyMsg = $bodyMsg.Substring(0,240) + '...' }
        Write-Host "  FAIL $Method $Path  status=$status  $($_.Exception.Message)" -ForegroundColor Red
        if ($status -eq 401 -or $status -eq 403) {
            Write-Host ""
            Write-Host "TOKEN EXPIRED OR INVALID. Generate a fresh one:" -ForegroundColor Yellow
            Write-Host "  1. Open $WorkspaceUrl in browser"
            Write-Host "  2. Top-right avatar > User Settings > Developer > Access tokens > Manage > Generate"
            Write-Host "  3. Comment: audit  Lifetime: 90  Click Generate"
            Write-Host "  4. Copy the dapi... value"
            Write-Host "  5. Open this script in Notepad, replace `$Token on line 7 with the new value, save, re-run"
        }
        return $null
    }
}

function Test-IsServerless {
    param($w)
    if (-not $w) { return $false }
    if ($w.enable_serverless_compute) { return $true }
    if ($w.warehouse_type -and $w.warehouse_type.ToString().ToUpper() -eq 'SERVERLESS') { return $true }
    return $false
}

function Save-Backup {
    param([object]$R, [string]$T, [string]$Reason)
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $idPart = if ($R.id) { $R.id } elseif ($R.cluster_id) { $R.cluster_id } else { 'unknown' }
    $name = "$T-$idPart-$stamp-$Reason.json"
    $path = Join-Path $BackupFolder $name
    @{ backup_time = (Get-Date).ToString('o'); workspace_url = $WorkspaceUrl; resource_type = $T; reason = $Reason; resource = $R } | ConvertTo-Json -Depth 30 | Out-File -FilePath $path -Encoding UTF8
    Write-Host "    backup -> $path" -ForegroundColor DarkGray
    return $path
}

function Build-WhEditBody {
    param([object]$W, [bool]$Sv)
    $body = @{
        name = $W.name; cluster_size = $W.cluster_size
        min_num_clusters = $W.min_num_clusters; max_num_clusters = $W.max_num_clusters
        auto_stop_mins = $W.auto_stop_mins; enable_photon = $W.enable_photon
        enable_serverless_compute = $Sv
    }
    if ($null -ne $W.spot_instance_policy) { $body['spot_instance_policy'] = $W.spot_instance_policy }
    if ($W.tags) { $body['tags'] = $W.tags }
    if ($W.channel) { $body['channel'] = $W.channel }
    if ($W.warehouse_type) { $body['warehouse_type'] = $W.warehouse_type }
    return $body
}

if ($Rollback) {
    if (-not (Test-Path $Rollback)) { Write-Host "ERROR: backup not found: $Rollback" -ForegroundColor Red; exit 1 }
    $payload = Get-Content -Raw -Path $Rollback | ConvertFrom-Json
    $r = $payload.resource
    Write-Host "ROLLBACK from: $Rollback  type=$($payload.resource_type)" -ForegroundColor Magenta
    if ($payload.resource_type -eq 'warehouse') {
        $current = Invoke-DbrApi "/api/2.0/sql/warehouses/$($r.id)"
        if (-not $current) { exit 1 }
        $origSv = Test-IsServerless $r
        $curSv = Test-IsServerless $current
        Write-Host "  $($r.name): orig_sv=$origSv  cur_sv=$curSv"
        if ($origSv -eq $curSv) { Write-Host "  no-op" -ForegroundColor Green; exit 0 }
        if (-not $Apply) { Write-Host "  [DRY RUN] add -Apply to actually rollback" -ForegroundColor Yellow; exit 0 }
        Save-Backup -R $current -T 'warehouse' -Reason 'pre-rollback' | Out-Null
        $body = Build-WhEditBody -W $r -Sv $origSv
        Invoke-DbrApi -Path "/api/2.0/sql/warehouses/$($r.id)/edit" -Method POST -Body $body | Out-Null
        Write-Host "  rolled back" -ForegroundColor Green
        exit 0
    }
    if ($payload.resource_type -eq 'cluster_acl') {
        if (-not $Apply) { Write-Host "  [DRY RUN] add -Apply to restore ACL" -ForegroundColor Yellow; exit 0 }
        $aclBody = @{ access_control_list = $r.access_control_list }
        Invoke-DbrApi -Path "/api/2.0/permissions/clusters/$($r.cluster_id)" -Method PUT -Body $aclBody | Out-Null
        Write-Host "  ACL restored on $($r.cluster_id)" -ForegroundColor Green
        exit 0
    }
    Write-Host "  unknown type: $($payload.resource_type)" -ForegroundColor Red
    exit 1
}

Write-Host "[1/5] Probing workspace API with current token..."
$probe = Invoke-DbrApi "/api/2.0/sql/warehouses"
if (-not $probe) {
    Write-Host ""
    Write-Host "Cannot continue - token rejected by API." -ForegroundColor Red
    exit 1
}
$warehouses = if ($probe.warehouses) { @($probe.warehouses) } else { @() }
$clResp = Invoke-DbrApi "/api/2.1/clusters/list"
$clusters = if ($clResp -and $clResp.clusters) { @($clResp.clusters) } else { @() }
$poolResp = Invoke-DbrApi "/api/2.0/instance-pools/list"
$pools = if ($poolResp -and $poolResp.instance_pools) { @($poolResp.instance_pools) } else { @() }
Write-Host "      warehouses=$($warehouses.Count)  clusters=$($clusters.Count)  pools=$($pools.Count)"

Write-Host ""
Write-Host "[2/5] Service Principal" -ForegroundColor Yellow
$spInfo = $null
Ensure-AzModules
$existing = Get-AzADServicePrincipal -DisplayName $ServicePrincipalDisplayName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "      SP exists: appId=$($existing.AppId)" -ForegroundColor Green
    $spInfo = @{ applicationId = $existing.AppId; objectId = $existing.Id; displayName = $existing.DisplayName; secret = $null; secretAlreadyExists = $true }
} elseif (-not $Apply) {
    Write-Host "      [DRY RUN] would create SP '$ServicePrincipalDisplayName'" -ForegroundColor Yellow
} else {
    Write-Host "      creating AD application + SP..."
    $app = New-AzADApplication -DisplayName $ServicePrincipalDisplayName
    $sp = New-AzADServicePrincipal -ApplicationId $app.AppId
    $cred = New-AzADAppCredential -ApplicationId $app.AppId -EndDate (Get-Date).AddDays(180)
    $spInfo = @{ applicationId = $app.AppId; objectId = $sp.Id; displayName = $app.DisplayName; secret = $cred.SecretText; secretEndDate = $cred.EndDate }
    $secretBody = @"
=========================================================
DATABRICKS PROD SERVICE PRINCIPAL CREDENTIALS - SAVE NOW
=========================================================
DisplayName     : $($spInfo.displayName)
Application Id  : $($spInfo.applicationId)
Object Id       : $($spInfo.objectId)
Tenant Id       : $((Get-AzContext).Tenant.Id)
Secret          : $($spInfo.secret)
Secret expires  : $($spInfo.secretEndDate)
=========================================================
This secret is shown ONCE. Save to a vault NOW.
=========================================================
"@
    $secretBody | Out-File -FilePath $spOutputPath -Encoding UTF8
    Write-Host "      SP created. Credentials saved to: $spOutputPath" -ForegroundColor Green
    Write-Host "      Application Id: $($spInfo.applicationId)" -ForegroundColor Green
}

Write-Host ""
Write-Host "[3/5] Add SP to workspace + grant admin" -ForegroundColor Yellow
if (-not $spInfo) {
    Write-Host "      no SP info available - skipping" -ForegroundColor Yellow
} elseif (-not $Apply) {
    Write-Host "      [DRY RUN] would POST SP $($spInfo.applicationId) to workspace SCIM + add to admins group" -ForegroundColor Yellow
} else {
    $scimBody = @{
        schemas = @('urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal')
        applicationId = $spInfo.applicationId
        displayName = $spInfo.displayName
        entitlements = @(
            @{ value = 'workspace-access' }
            @{ value = 'allow-cluster-create' }
            @{ value = 'allow-instance-pool-create' }
            @{ value = 'databricks-sql-access' }
        )
    }
    $scimResp = Invoke-DbrApi -Path '/api/2.0/preview/scim/v2/ServicePrincipals' -Method POST -Body $scimBody
    if ($scimResp -and $scimResp.id) {
        Write-Host "      SP added to workspace. SCIM id: $($scimResp.id)" -ForegroundColor Green
        $spInfo['workspaceScimId'] = $scimResp.id
        $adminGroup = Invoke-DbrApi -Path '/api/2.0/preview/scim/v2/Groups?filter=displayName%20eq%20%22admins%22'
        if ($adminGroup -and $adminGroup.Resources -and $adminGroup.Resources.Count -gt 0) {
            $adminGroupId = $adminGroup.Resources[0].id
            $patchBody = @{
                schemas = @('urn:ietf:params:scim:api:messages:2.0:PatchOp')
                Operations = @(@{ op = 'add'; path = 'members'; value = @(@{ value = $scimResp.id }) })
            }
            Invoke-DbrApi -Path "/api/2.0/preview/scim/v2/Groups/$adminGroupId" -Method PATCH -Body $patchBody | Out-Null
            Write-Host "      SP added to workspace 'admins' group" -ForegroundColor Green
        }
    } else {
        Write-Host "      WARNING: SCIM call returned nothing (SP may already exist in workspace)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "[4/5] Flip warehouses to Serverless" -ForegroundColor Yellow
$flipResults = @()
$flipTargets = $warehouses | Where-Object { -not (Test-IsServerless $_) }
foreach ($w in $warehouses) {
    $sv = Test-IsServerless $w
    Write-Host "      [$($w.id)] $($w.name)  state=$($w.state)  serverless=$sv"
    if ($sv) { continue }
    if (-not $Apply) {
        Write-Host "        [DRY RUN] would flip to Serverless" -ForegroundColor Yellow
        continue
    }
    $bp = Save-Backup -R $w -T 'warehouse' -Reason 'pre-flip'
    $body = Build-WhEditBody -W $w -Sv $true
    Invoke-DbrApi -Path "/api/2.0/sql/warehouses/$($w.id)/edit" -Method POST -Body $body | Out-Null
    Start-Sleep -Seconds 3
    $after = Invoke-DbrApi "/api/2.0/sql/warehouses/$($w.id)"
    $afterSv = Test-IsServerless $after
    if ($afterSv) { Write-Host "        OK - now Serverless" -ForegroundColor Green }
    else { Write-Host "        WARNING: not yet serverless after flip" -ForegroundColor Yellow }
    $flipResults += [PSCustomObject]@{ Name = $w.name; Id = $w.id; AfterServerless = $afterSv; Backup = $bp }
}

Write-Host ""
Write-Host "[5/5] Transfer cluster control: SP gets CAN_MANAGE, $RemoveUserName removed" -ForegroundColor Yellow
$aclResults = @()
if (-not $spInfo) {
    Write-Host "      no SP - cannot grant CAN_MANAGE without applicationId" -ForegroundColor Yellow
} else {
    foreach ($c in $clusters) {
        Write-Host "      [$($c.cluster_id)] $($c.cluster_name)  creator=$($c.creator_user_name)"
        $aclCurrent = Invoke-DbrApi "/api/2.0/permissions/clusters/$($c.cluster_id)"
        if (-not $aclCurrent) { continue }
        $hasOldUser = $false
        foreach ($a in $aclCurrent.access_control_list) {
            if ($a.user_name -and $a.user_name -like "*$RemoveUserName*") { $hasOldUser = $true; break }
        }
        $msg = if ($hasOldUser) { "$RemoveUserName has perms - will be removed" } else { "$RemoveUserName not in ACL" }
        Write-Host "        $msg"
        if (-not $Apply) {
            Write-Host "        [DRY RUN] would set ACL: SP CAN_MANAGE, $RemoveUserName removed" -ForegroundColor Yellow
            continue
        }
        $bp = Save-Backup -R @{ cluster_id = $c.cluster_id; access_control_list = $aclCurrent.access_control_list } -T 'cluster_acl' -Reason 'pre-acl'
        $newAcl = New-Object System.Collections.Generic.List[object]
        foreach ($a in $aclCurrent.access_control_list) {
            if ($a.user_name -and $a.user_name -like "*$RemoveUserName*") { continue }
            if ($a.all_permissions) {
                foreach ($p in $a.all_permissions) {
                    if (-not $p.inherited) {
                        $entry = @{}
                        if ($a.user_name) { $entry['user_name'] = $a.user_name }
                        if ($a.group_name) { $entry['group_name'] = $a.group_name }
                        if ($a.service_principal_name) { $entry['service_principal_name'] = $a.service_principal_name }
                        $entry['permission_level'] = $p.permission_level
                        $newAcl.Add($entry)
                        break
                    }
                }
            }
        }
        $newAcl.Add(@{ service_principal_name = $spInfo.applicationId; permission_level = 'CAN_MANAGE' })
        $aclBody = @{ access_control_list = $newAcl }
        $putResp = Invoke-DbrApi -Path "/api/2.0/permissions/clusters/$($c.cluster_id)" -Method PUT -Body $aclBody
        if ($putResp) { Write-Host "        OK - SP CAN_MANAGE, $RemoveUserName removed" -ForegroundColor Green }
        else { Write-Host "        WARNING: ACL update failed" -ForegroundColor Yellow }
        $aclResults += [PSCustomObject]@{ ClusterId = $c.cluster_id; ClusterName = $c.cluster_name; Backup = $bp }
    }
}

if ($Apply -and ($flipResults.Count -gt 0 -or $aclResults.Count -gt 0)) {
    Write-Host ""
    Write-Host "ROLLBACK COMMANDS (save these):" -ForegroundColor Yellow
    foreach ($f in $flipResults) {
        Write-Host "  .\Databricks-PROD-Full.ps1 -Rollback `"$($f.Backup)`" -Apply" -ForegroundColor Yellow
    }
    foreach ($a in $aclResults) {
        Write-Host "  .\Databricks-PROD-Full.ps1 -Rollback `"$($a.Backup)`" -Apply" -ForegroundColor Yellow
    }
}

if ($Apply -and $flipResults.Count -gt 0) {
    Start-Sleep -Seconds 2
    $postFlipProbe = Invoke-DbrApi "/api/2.0/sql/warehouses"
    if ($postFlipProbe -and $postFlipProbe.warehouses) {
        $warehouses = @($postFlipProbe.warehouses)
    }
}

$wRows = ""
foreach ($w in $warehouses) {
    $sv = Test-IsServerless $w
    $svColor = if ($sv) { '#28a745' } else { '#ff9800' }
    $wRows += "<tr><td><strong>$($w.name)</strong><br><span style='color:#888;font-size:11px;'>$($w.id)</span></td><td>$($w.warehouse_type)</td><td>$($w.cluster_size)</td><td>$($w.state)</td><td>$($w.auto_stop_mins) min</td><td style='color:$svColor;font-weight:bold;'>$(if ($sv) { 'YES' } else { 'NO' })</td></tr>"
}
$cRows = ""
foreach ($c in $clusters) {
    $minW = if ($c.autoscale) { $c.autoscale.min_workers } else { $c.num_workers }
    $maxW = if ($c.autoscale) { $c.autoscale.max_workers } else { $c.num_workers }
    $hasPool = if ($c.instance_pool_id) { 'YES' } else { 'NO' }
    $term = if ($c.autotermination_minutes) { "$($c.autotermination_minutes) min" } else { 'none' }
    $cRows += "<tr><td><strong>$($c.cluster_name)</strong><br><span style='color:#888;font-size:11px;'>$($c.cluster_id)</span></td><td>$($c.state)</td><td>$($c.spark_version)</td><td>$($c.node_type_id)</td><td>$minW / $maxW</td><td>$term</td><td>$hasPool</td><td>$($c.creator_user_name)</td></tr>"
}
$spBlock = if ($spInfo) {
    $secretLine = if ($spInfo.secret) { "<strong>Secret:</strong> saved to $spOutputPath (shown only once)" } else { "<strong>Secret:</strong> SP already existed; no new secret generated" }
    "<table><tr><th>Field</th><th>Value</th></tr><tr><td>Display Name</td><td>$($spInfo.displayName)</td></tr><tr><td>Application Id</td><td>$($spInfo.applicationId)</td></tr><tr><td>Object Id</td><td>$($spInfo.objectId)</td></tr></table><p>$secretLine</p>"
} else { "<p>SP not created/found this run.</p>" }

$html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><title>Databricks PROD Full</title>
<style>
body{font-family:Arial,sans-serif;margin:20px;background:#f5f5f5;color:#222;}
.container{max-width:1500px;margin:0 auto;background:white;padding:36px;border-radius:8px;}
h1{color:#FF3621;font-size:30px;}
h2{color:#1B3139;border-bottom:3px solid #FF3621;padding-bottom:8px;margin-top:28px;}
.summary{background:#f8f9fa;padding:20px;border-left:4px solid #FF3621;margin:18px 0;}
.metric{display:inline-block;background:#e3f2fd;padding:14px 22px;margin:6px;border-radius:5px;min-width:150px;text-align:center;}
.metric strong{display:block;font-size:22px;color:#1976d2;}
.metric span{color:#555;font-size:11px;}
table{width:100%;border-collapse:collapse;margin:12px 0;font-size:13px;}
th{background:#1B3139;color:white;padding:9px;text-align:left;font-size:11px;text-transform:uppercase;}
td{padding:8px 10px;border-bottom:1px solid #e0e0e0;vertical-align:top;}
.foot{margin-top:36px;padding-top:14px;border-top:2px solid #ddd;color:#666;font-size:12px;}
</style></head><body><div class="container">
<h1>Databricks PROD Full Migration</h1>
<p><strong>Run date:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm')<br>
<strong>Workspace:</strong> $WorkspaceUrl<br>
<strong>Mode:</strong> $(if ($Apply) { 'APPLY' } else { 'DRY RUN' })<br>
<strong>Prepared by:</strong> Syed Rizvi</p>
<div class="summary">
<div class="metric"><strong>$($warehouses.Count)</strong><span>Warehouses</span></div>
<div class="metric"><strong>$($clusters.Count)</strong><span>Clusters</span></div>
<div class="metric"><strong>$($pools.Count)</strong><span>Pools</span></div>
<div class="metric"><strong>$($flipResults.Count)</strong><span>Flipped</span></div>
<div class="metric"><strong>$($aclResults.Count)</strong><span>ACLs Updated</span></div>
</div>
<h2>Service Principal</h2>
$spBlock
<h2>Warehouses</h2>
$(if ($warehouses.Count -eq 0) { "<p>None.</p>" } else { "<table><tr><th>Warehouse</th><th>Type</th><th>Size</th><th>State</th><th>Auto-stop</th><th>Serverless</th></tr>$wRows</table>" })
<h2>Clusters</h2>
$(if ($clusters.Count -eq 0) { "<p>None.</p>" } else { "<table><tr><th>Cluster</th><th>State</th><th>DBR</th><th>Node SKU</th><th>Workers</th><th>Auto-term</th><th>Pool</th><th>Creator</th></tr>$cRows</table>" })
<div class="foot"><strong>Backup folder:</strong> $BackupFolder</div>
</div></body></html>
"@

$html | Out-File -FilePath $reportPath -Encoding UTF8

Write-Host ""
Write-Host "  Report : $reportPath" -ForegroundColor Green
if ($spInfo -and $spInfo.secret) {
    Write-Host "  SP creds: $spOutputPath" -ForegroundColor Green
}
Write-Host ""

try { Start-Process $reportPath } catch {}
