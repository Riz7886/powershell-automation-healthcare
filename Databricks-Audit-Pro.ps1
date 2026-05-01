[CmdletBinding()]
param(
    [string[]]$SubscriptionIds,
    [string]$OutputFolder = "$env:USERPROFILE\Documents\Databricks-Audit",
    [int]$EventLookbackDays = 14,
    [switch]$SkipModuleInstall,
    [switch]$SingleSubOnly,
    [string]$PersonalAccessToken,
    [hashtable]$PatMap,
    [switch]$ShowDetail
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$required = @('Az.Accounts','Az.Resources','Az.Databricks')

function Ensure-Modules {
    if ($SkipModuleInstall) { foreach ($m in $required) { Import-Module $m -Force -ErrorAction Stop }; return }
    try { $null = Get-PackageProvider -Name NuGet -ErrorAction Stop }
    catch { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null }
    try {
        $repo = Get-PSRepository -Name PSGallery -ErrorAction Stop
        if ($repo.InstallationPolicy -ne 'Trusted') { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted }
    } catch {}
    foreach ($m in $required) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Install-Module $m -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
        }
        Import-Module $m -Force -ErrorAction Stop
    }
}

function Ensure-Login {
    try {
        $ctx = Get-AzContext -ErrorAction Stop
        if (-not $ctx -or -not $ctx.Account) { throw 'no context' }
    } catch { Connect-AzAccount | Out-Null }
}

$script:CachedToken = $null
$script:CachedTokenExpiry = [DateTime]::MinValue

function Get-AadDbrToken {
    if ($script:CachedToken -and ([DateTime]::UtcNow -lt $script:CachedTokenExpiry)) { return $script:CachedToken }
    $resources = @('2ff814a6-3304-4ab8-85cb-cd0e6f879c1d','https://databricks.azure.net/')
    $cmd = Get-Command Get-AzAccessToken -ErrorAction Stop
    $supportsSecure = $cmd.Parameters.ContainsKey('AsSecureString')
    $useResourceUrl = $cmd.Parameters.ContainsKey('ResourceUrl')
    foreach ($r in $resources) {
        try {
            $params = @{ ErrorAction = 'Stop' }
            if ($useResourceUrl) { $params['ResourceUrl'] = $r } else { $params['Resource'] = $r }
            if ($supportsSecure) { $params['AsSecureString'] = $false }
            $t = Get-AzAccessToken @params
            $tok = $null
            if ($t -is [string]) { $tok = $t }
            elseif ($null -ne $t.Token) {
                if ($t.Token -is [System.Security.SecureString]) {
                    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($t.Token)
                    try { $tok = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
                    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                } else { $tok = $t.Token.ToString() }
            }
            if ($tok) {
                $script:CachedToken = $tok
                $script:CachedTokenExpiry = [DateTime]::UtcNow.AddMinutes(45)
                return $tok
            }
        } catch {
            Write-Host ("    AAD token via " + $r + " failed: " + $_.Exception.Message) -ForegroundColor DarkYellow
        }
    }
    return $null
}

function Decode-JwtClaims {
    param([string]$Token)
    if (-not $Token -or $Token -notmatch '^ey') { return $null }
    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $payload = $parts[1].Replace('-','+').Replace('_','/')
    while ($payload.Length % 4 -ne 0) { $payload += '=' }
    try {
        $bytes = [Convert]::FromBase64String($payload)
        $json = [System.Text.Encoding]::UTF8.GetString($bytes)
        return ($json | ConvertFrom-Json)
    } catch { return $null }
}

function Resolve-WorkspaceToken {
    param([string]$WorkspaceUrl)
    if ($PersonalAccessToken) { return @{ Token = $PersonalAccessToken; Mode = 'PAT' } }
    if ($PatMap -and $PatMap.ContainsKey($WorkspaceUrl)) { return @{ Token = $PatMap[$WorkspaceUrl]; Mode = 'PAT-map' } }
    $aad = Get-AadDbrToken
    if ($aad) { return @{ Token = $aad; Mode = 'AAD' } }
    return $null
}

function Invoke-DbrApi {
    param(
        [string]$WorkspaceUrl,
        [string]$WorkspaceResourceId,
        [string]$Path,
        [string]$Method = 'GET',
        $Body
    )
    $tok = Resolve-WorkspaceToken -WorkspaceUrl $WorkspaceUrl
    if (-not $tok) { Write-Host "    no token available for $WorkspaceUrl" -ForegroundColor Red; return $null }
    $headers = @{ Authorization = "Bearer $($tok.Token)"; 'Content-Type' = 'application/json' }
    if ($tok.Mode -eq 'AAD' -and $WorkspaceResourceId) {
        $headers['X-Databricks-Azure-Workspace-Resource-Id'] = $WorkspaceResourceId
    }
    $uri = "https://$WorkspaceUrl$Path"
    $params = @{ Method = $Method; Uri = $uri; Headers = $headers; ErrorAction = 'Stop'; TimeoutSec = 60; UseBasicParsing = $true }
    if ($Body) { $params['Body'] = (ConvertTo-Json -InputObject $Body -Depth 10 -Compress) }
    try {
        $r = Invoke-RestMethod @params
        if ($ShowDetail) { Write-Host ("    OK  [" + $tok.Mode + "] " + $Method + " " + $Path) -ForegroundColor DarkGray }
        return $r
    } catch {
        $status = $null
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch {}
        $msg = $_.Exception.Message
        $body = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $body = $_.ErrorDetails.Message
        } else {
            try {
                if ($_.Exception.Response) {
                    $stream = $_.Exception.Response.GetResponseStream()
                    if ($stream) {
                        $reader = New-Object System.IO.StreamReader($stream)
                        $body = $reader.ReadToEnd()
                    }
                }
            } catch {}
        }
        if ($body -and $body.Length -gt 240) { $body = $body.Substring(0,240) + '...' }
        Write-Host ("    FAIL [" + $tok.Mode + "] " + $Method + " " + $Path + "  status=" + $status + "  " + $msg + "  body=" + $body) -ForegroundColor Red
        return $null
    }
}

function Test-IsGpuSku {
    param([string]$NodeType)
    if (-not $NodeType) { return $false }
    return ($NodeType -match 'Standard_N[CDV]')
}

function Get-ColdStartDiagnosis {
    param($Cluster, $Pools)
    $issues = New-Object System.Collections.Generic.List[string]
    if (-not $Cluster.instance_pool_id) { $issues.Add('NO_POOL') }
    else {
        $pool = $Pools | Where-Object { $_.instance_pool_id -eq $Cluster.instance_pool_id }
        if ($pool -and $pool.min_idle_instances -lt 1) { $issues.Add('POOL_NOT_PREWARMED') }
    }
    if ($Cluster.init_scripts -and ($Cluster.init_scripts | Measure-Object).Count -gt 0) { $issues.Add('INIT_SCRIPTS') }
    if ($Cluster.spark_version -match '^(7|8|9|10|11|12)\.') { $issues.Add('OLD_DBR_LT_13') }
    if ($Cluster.runtime_engine -ne 'PHOTON' -and $Cluster.spark_version -notmatch 'photon') { $issues.Add('NO_PHOTON') }
    if ($Cluster.docker_image) { $issues.Add('CUSTOM_CONTAINER') }
    if ($Cluster.num_workers -gt 8 -or ($Cluster.autoscale -and $Cluster.autoscale.max_workers -gt 8)) { $issues.Add('LARGE_CLUSTER') }
    if (Test-IsGpuSku $Cluster.node_type_id) { $issues.Add('GPU_SKU') }
    if ($Cluster.cluster_log_conf) { $issues.Add('LOG_CONF_ATTACHED') }
    if (-not $Cluster.autotermination_minutes -or $Cluster.autotermination_minutes -gt 120) { $issues.Add('LONG_OR_NO_AUTOTERM') }
    if ($issues.Count -eq 0) { return 'OK' }
    return ($issues -join '|')
}

function Get-ServerlessEligibility {
    param($Cluster)
    $blockers = New-Object System.Collections.Generic.List[string]
    if ($Cluster.init_scripts -and ($Cluster.init_scripts | Measure-Object).Count -gt 0) { $blockers.Add('init_scripts') }
    if ($Cluster.docker_image) { $blockers.Add('custom_container') }
    if (Test-IsGpuSku $Cluster.node_type_id) { $blockers.Add('gpu_workload') }
    if ($Cluster.spark_conf) {
        $props = $Cluster.spark_conf.PSObject.Properties
        foreach ($p in $props) {
            if ($p.Name -match 'fs\.azure\.account\.key') { $blockers.Add('storage_key_auth') }
            if ($p.Name -match 'spark\.databricks\.passthrough\.enabled') { $blockers.Add('credential_passthrough') }
        }
    }
    if ($Cluster.aws_attributes -or $Cluster.gcp_attributes) { $blockers.Add('non_azure_attrs') }
    $hard = @('custom_container','gpu_workload')
    $hardHit = $blockers | Where-Object { $hard -contains $_ }
    if (-not $blockers -or $blockers.Count -eq 0) { return 'ELIGIBLE' }
    if ($hardHit) { return ('BLOCKED:' + ($blockers -join ',')) }
    return ('PARTIAL:' + ($blockers -join ','))
}

function Compute-AvgColdStart {
    param($Events)
    if (-not $Events -or -not $Events.events) { return $null }
    $sorted = $Events.events | Sort-Object timestamp
    $startTs = $null
    $deltas = New-Object System.Collections.Generic.List[double]
    foreach ($e in $sorted) {
        if ($e.type -eq 'STARTING') { $startTs = $e.timestamp }
        elseif ($e.type -eq 'RUNNING' -and $startTs) {
            $delta = ($e.timestamp - $startTs) / 60000.0
            if ($delta -gt 0 -and $delta -lt 120) { $deltas.Add($delta) }
            $startTs = $null
        }
        elseif ($e.type -eq 'TERMINATED') { $startTs = $null }
    }
    if ($deltas.Count -eq 0) { return $null }
    return [math]::Round(($deltas | Measure-Object -Average).Average, 2)
}

function HtmlEnc {
    param([object]$s)
    if ($null -eq $s) { return '' }
    $str = [string]$s
    $str = $str.Replace('&','&amp;')
    $str = $str.Replace('<','&lt;')
    $str = $str.Replace('>','&gt;')
    $str = $str.Replace('"','&quot;')
    $str = $str.Replace("'",'&#39;')
    return $str
}

function Build-Html {
    param($Workspaces, $Clusters, $Warehouses, $Pools, $RunDate, $Subs, $Lookback)
    $totalWs = ($Workspaces | Measure-Object).Count
    $totalCl = ($Clusters | Measure-Object).Count
    $totalWh = ($Warehouses | Measure-Object).Count
    $slowCl = ($Clusters | Where-Object { $_.AvgColdStartMin -ne $null -and $_.AvgColdStartMin -ge 5 } | Measure-Object).Count
    $eligibleCl = ($Clusters | Where-Object { $_.ServerlessEligible -eq 'ELIGIBLE' } | Measure-Object).Count
    $partialCl = ($Clusters | Where-Object { $_.ServerlessEligible -like 'PARTIAL*' } | Measure-Object).Count
    $blockedCl = ($Clusters | Where-Object { $_.ServerlessEligible -like 'BLOCKED*' } | Measure-Object).Count
    $classicWh = ($Warehouses | Where-Object { -not $_.Serverless } | Measure-Object).Count
    $serverlessWh = ($Warehouses | Where-Object { $_.Serverless } | Measure-Object).Count

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>Databricks Audit</title>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#0e1424;color:#e6e9f5;margin:0;padding:30px 40px;line-height:1.55}')
    [void]$sb.AppendLine('h1{font-size:30px;margin:0 0 6px;color:#5fc7ff}h2{font-size:20px;margin:32px 0 12px;color:#7adfa7;border-bottom:1px solid #1f2a44;padding-bottom:6px}h3{font-size:15px;color:#ffb86b;margin:18px 0 8px;letter-spacing:1px;text-transform:uppercase}')
    [void]$sb.AppendLine('.kpi{display:inline-block;background:#172037;border:1px solid #243355;border-radius:8px;padding:14px 22px;margin:6px 8px 6px 0;min-width:170px;vertical-align:top}.kpi .v{font-size:26px;font-weight:700;color:#5fc7ff}.kpi .l{font-size:11px;color:#8a96b8;letter-spacing:1.4px;text-transform:uppercase}')
    [void]$sb.AppendLine('table{width:100%;border-collapse:collapse;font-size:12.5px;margin:10px 0 24px;background:#101830;border:1px solid #1f2a44;border-radius:8px;overflow:hidden}th{text-align:left;padding:9px 11px;background:#1a2440;color:#5fc7ff;font-size:11px;letter-spacing:1px;text-transform:uppercase;border-bottom:1px solid #243355}td{padding:8px 11px;border-bottom:1px solid #1a2440;color:#d4d9ec;vertical-align:top}tr:hover td{background:#152042}')
    [void]$sb.AppendLine('.red{color:#ff6b8a;font-weight:600}.yellow{color:#ffd166;font-weight:600}.green{color:#7adfa7;font-weight:600}.muted{color:#8a96b8}')
    [void]$sb.AppendLine('.tag{display:inline-block;padding:2px 8px;border-radius:999px;font-size:10.5px;font-weight:600;letter-spacing:0.5px}.tag.r{background:#3a1424;color:#ff6b8a;border:1px solid #ff6b8a}.tag.y{background:#3a2c14;color:#ffd166;border:1px solid #ffd166}.tag.g{background:#143a25;color:#7adfa7;border:1px solid #7adfa7}.tag.b{background:#142a3a;color:#5fc7ff;border:1px solid #5fc7ff}')
    [void]$sb.AppendLine('.recs{background:#101830;border:1px solid #243355;border-radius:8px;padding:14px 22px}.recs li{margin:8px 0}')
    [void]$sb.AppendLine('.foot{margin-top:40px;color:#8a96b8;font-size:11px;text-align:center}')
    [void]$sb.AppendLine('</style></head><body>')

    [void]$sb.AppendLine("<h1>Databricks Cold-Start &amp; Serverless Audit</h1>")
    [void]$sb.AppendLine("<div class='muted'>Run date: $RunDate &nbsp;&middot;&nbsp; Subscriptions audited: $($Subs.Count) &nbsp;&middot;&nbsp; Lookback for events: $Lookback days</div>")

    [void]$sb.AppendLine('<h2>Executive Summary</h2>')
    [void]$sb.AppendLine("<div class='kpi'><div class='v'>$totalWs</div><div class='l'>Workspaces</div></div>")
    [void]$sb.AppendLine("<div class='kpi'><div class='v'>$totalCl</div><div class='l'>All-purpose / Job Clusters</div></div>")
    [void]$sb.AppendLine("<div class='kpi'><div class='v'>$totalWh</div><div class='l'>SQL Warehouses</div></div>")
    [void]$sb.AppendLine("<div class='kpi'><div class='v red'>$slowCl</div><div class='l'>Clusters &gt;= 5 min cold start</div></div>")
    [void]$sb.AppendLine("<div class='kpi'><div class='v green'>$eligibleCl</div><div class='l'>Clusters serverless-eligible</div></div>")
    [void]$sb.AppendLine("<div class='kpi'><div class='v yellow'>$partialCl</div><div class='l'>Partial (some blockers)</div></div>")
    [void]$sb.AppendLine("<div class='kpi'><div class='v red'>$blockedCl</div><div class='l'>Hard-blocked</div></div>")
    [void]$sb.AppendLine("<div class='kpi'><div class='v yellow'>$classicWh</div><div class='l'>Pro/Classic warehouses</div></div>")
    [void]$sb.AppendLine("<div class='kpi'><div class='v green'>$serverlessWh</div><div class='l'>Serverless warehouses</div></div>")

    [void]$sb.AppendLine('<h2>Why Cold Start Is Slow &mdash; Root-Cause Reference</h2>')
    [void]$sb.AppendLine('<table><thead><tr><th>Code</th><th>Meaning</th><th>Typical impact</th><th>Fix</th></tr></thead><tbody>')
    [void]$sb.AppendLine('<tr><td><span class="tag r">NO_POOL</span></td><td>No instance pool attached. Every start provisions Azure VMs cold.</td><td>+4-7 min</td><td>Create instance pool with min_idle_instances &gt;= 1; attach cluster.</td></tr>')
    [void]$sb.AppendLine('<tr><td><span class="tag y">POOL_NOT_PREWARMED</span></td><td>Pool attached but min_idle_instances = 0.</td><td>+3-5 min</td><td>Set min_idle_instances to 1-2 during business hours.</td></tr>')
    [void]$sb.AppendLine('<tr><td><span class="tag y">INIT_SCRIPTS</span></td><td>Init scripts run on every cluster start.</td><td>+2-5 min</td><td>Bake into custom DBR image OR move logic to libraries OR use Unity Catalog volumes.</td></tr>')
    [void]$sb.AppendLine('<tr><td><span class="tag y">OLD_DBR_LT_13</span></td><td>DBR version &lt; 13.x; slower image pull / Spark init.</td><td>+1-3 min</td><td>Upgrade to DBR 14.3 LTS or 15.x LTS.</td></tr>')
    [void]$sb.AppendLine('<tr><td><span class="tag y">NO_PHOTON</span></td><td>Photon not enabled; longer warm-up + slower compute.</td><td>+30-60s startup, 2-5x runtime</td><td>Enable Photon (DBR Photon variant).</td></tr>')
    [void]$sb.AppendLine('<tr><td><span class="tag r">CUSTOM_CONTAINER</span></td><td>Custom Docker image pulled from ACR.</td><td>+2-8 min</td><td>Slim image; cache to pool VM disk; or move to Serverless Compute.</td></tr>')
    [void]$sb.AppendLine('<tr><td><span class="tag r">GPU_SKU</span></td><td>NC/ND/NV SKU; capacity constrained, slower image.</td><td>+5-10 min</td><td>Use GPU pool; Serverless GPU (preview) for supported workloads.</td></tr>')
    [void]$sb.AppendLine('<tr><td><span class="tag y">LARGE_CLUSTER</span></td><td>&gt;8 workers; multi-node handshake adds time.</td><td>+30-90s</td><td>Right-size; rely on autoscale; pool with capacity reservation.</td></tr>')
    [void]$sb.AppendLine('<tr><td><span class="tag y">LONG_OR_NO_AUTOTERM</span></td><td>autotermination &gt; 120 min or disabled. High cost, but masks cold-start pain.</td><td>cost</td><td>Set autotermination to 30-60 min for interactive; rely on Serverless for instant restart.</td></tr>')
    [void]$sb.AppendLine('</tbody></table>')

    [void]$sb.AppendLine('<h2>Clusters &mdash; Per-Cluster Diagnosis</h2>')
    if ($totalCl -eq 0) {
        [void]$sb.AppendLine("<div class='muted'>No clusters discovered.</div>")
    } else {
        [void]$sb.AppendLine('<table><thead><tr><th>Sub</th><th>Workspace</th><th>Cluster</th><th>State</th><th>DBR</th><th>Node SKU</th><th>Workers</th><th>Pool</th><th>Init scripts</th><th>Photon</th><th>Avg cold start (min)</th><th>Diagnosis</th><th>Serverless</th></tr></thead><tbody>')
        foreach ($c in ($Clusters | Sort-Object @{Expression='AvgColdStartMin';Descending=$true}, Workspace)) {
            $coldClass = if ($null -eq $c.AvgColdStartMin) { 'muted' } elseif ($c.AvgColdStartMin -ge 5) { 'red' } elseif ($c.AvgColdStartMin -ge 2) { 'yellow' } else { 'green' }
            $coldText = if ($null -eq $c.AvgColdStartMin) { 'no events' } else { $c.AvgColdStartMin }
            $svClass = if ($c.ServerlessEligible -eq 'ELIGIBLE') { 'g' } elseif ($c.ServerlessEligible -like 'PARTIAL*') { 'y' } else { 'r' }
            $svParts = $c.ServerlessEligible -split ':',2
            $svShort = $svParts[0]
            $svDetail = if ($svParts.Count -gt 1) { $svParts[1] } else { '' }
            [void]$sb.AppendLine("<tr><td>$(HtmlEnc $c.Sub)</td><td>$(HtmlEnc $c.Workspace)</td><td>$(HtmlEnc $c.Cluster)</td><td>$(HtmlEnc $c.State)</td><td>$(HtmlEnc $c.DbrVersion)</td><td>$(HtmlEnc $c.NodeType)</td><td>$(HtmlEnc $c.Workers)</td><td>$(HtmlEnc $c.PoolId)</td><td>$($c.InitScripts)</td><td>$($c.Photon)</td><td class='$coldClass'>$coldText</td><td>$(HtmlEnc $c.Diagnosis)</td><td><span class='tag $svClass'>$svShort</span> <span class='muted'>$(HtmlEnc $svDetail)</span></td></tr>")
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    [void]$sb.AppendLine('<h2>SQL Warehouses &mdash; Serverless Upgrade Path</h2>')
    if ($totalWh -eq 0) {
        [void]$sb.AppendLine("<div class='muted'>No SQL warehouses discovered.</div>")
    } else {
        [void]$sb.AppendLine('<table><thead><tr><th>Sub</th><th>Workspace</th><th>Warehouse</th><th>Type</th><th>Size</th><th>Min/Max Clusters</th><th>Auto-stop</th><th>State</th><th>Serverless</th><th>Upgrade</th></tr></thead><tbody>')
        foreach ($w in $Warehouses) {
            $sv = if ($w.Serverless) { '<span class="tag g">YES</span>' } else { '<span class="tag y">NO</span>' }
            $up = if ($w.Serverless) { '<span class="muted">already serverless</span>' } else { 'Switch to Serverless: ~5-10 sec start, no idle cost.' }
            [void]$sb.AppendLine("<tr><td>$(HtmlEnc $w.Sub)</td><td>$(HtmlEnc $w.Workspace)</td><td>$(HtmlEnc $w.Warehouse)</td><td>$(HtmlEnc $w.Type)</td><td>$(HtmlEnc $w.Size)</td><td>$(HtmlEnc $w.MinClusters)/$(HtmlEnc $w.MaxClusters)</td><td>$(HtmlEnc $w.AutoStopMins) min</td><td>$(HtmlEnc $w.State)</td><td>$sv</td><td>$up</td></tr>")
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    [void]$sb.AppendLine('<h2>Workspaces Inventory</h2>')
    if ($totalWs -eq 0) {
        [void]$sb.AppendLine("<div class='muted'>No workspaces discovered.</div>")
    } else {
        [void]$sb.AppendLine('<table><thead><tr><th>Subscription</th><th>Resource Group</th><th>Workspace</th><th>Region</th><th>SKU</th><th>URL</th><th>Auth Mode</th></tr></thead><tbody>')
        foreach ($w in $Workspaces) {
            [void]$sb.AppendLine("<tr><td>$(HtmlEnc $w.SubName)</td><td>$(HtmlEnc $w.ResourceGroup)</td><td>$(HtmlEnc $w.Workspace)</td><td>$(HtmlEnc $w.Region)</td><td>$(HtmlEnc $w.Sku)</td><td>$(HtmlEnc $w.Url)</td><td>$(HtmlEnc $w.AuthMode)</td></tr>")
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    [void]$sb.AppendLine('<h2>Recommendations</h2>')
    [void]$sb.AppendLine('<div class="recs"><ol>')
    [void]$sb.AppendLine('<li><strong>Promote SQL warehouses to Serverless.</strong> Pro/Classic warehouses cold-start in 3-5 min; Serverless is 5-10 sec and scales to zero. No code change. Switch via warehouse Edit -> Serverless.</li>')
    [void]$sb.AppendLine('<li><strong>Move eligible clusters to Serverless Compute for Notebooks/Jobs.</strong> Any cluster flagged ELIGIBLE has no init scripts, no custom container, no GPU SKU, and no legacy auth. Sub-30s start, per-second billing.</li>')
    [void]$sb.AppendLine('<li><strong>Attach an instance pool with min_idle_instances >= 1</strong> to all clusters that cannot move to serverless. Drops cold start from 5-10 min to 1-2 min for the cost of a few idle VMs.</li>')
    [void]$sb.AppendLine('<li><strong>Eliminate init scripts.</strong> Bake required setup into a custom DBR image or move to cluster libraries. Init scripts re-run on every restart and are the #2 cold-start tax after pool absence.</li>')
    [void]$sb.AppendLine('<li><strong>Upgrade old DBR.</strong> Anything below 13.x has slower image pull and Spark startup. Move to DBR 14.3 LTS or 15.x LTS; enable Photon where supported.</li>')
    [void]$sb.AppendLine('<li><strong>Right-size workers and autotermination.</strong> Lower max_workers to actual peak; set autotermination to 30-60 min; rely on Serverless for instant restart instead of long idle.</li>')
    [void]$sb.AppendLine('<li><strong>Track per-cluster cold-start time as a SLI.</strong> Re-run this audit weekly to catch regressions. Threshold: any cluster averaging >= 5 min cold start in a 14-day window is a remediation candidate.</li>')
    [void]$sb.AppendLine('</ol></div>')

    [void]$sb.AppendLine('<div class="foot">Prepared by Syed Rizvi &middot; Databricks Cold-Start &amp; Serverless Audit</div>')
    [void]$sb.AppendLine('</body></html>')
    return $sb.ToString()
}

Ensure-Modules
Ensure-Login

if (-not $SubscriptionIds -or $SubscriptionIds.Count -eq 0) {
    if ($SingleSubOnly) {
        $SubscriptionIds = @((Get-AzContext).Subscription.Id)
    } else {
        $tenant = (Get-AzContext).Tenant.Id
        $SubscriptionIds = (Get-AzSubscription -TenantId $tenant -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' }).Id
    }
}

Write-Host ""
Write-Host ("Scanning " + $SubscriptionIds.Count + " subscription(s)") -ForegroundColor Cyan

if ($PersonalAccessToken) {
    Write-Host "Auth mode: Personal Access Token (single PAT for all workspaces)" -ForegroundColor Cyan
    Write-Host "  note: a PAT is workspace-scoped, so this will work for ONE workspace; others will return empty" -ForegroundColor DarkYellow
} elseif ($PatMap) {
    Write-Host ("Auth mode: Per-workspace PAT map (" + $PatMap.Count + " entries)") -ForegroundColor Cyan
} else {
    Write-Host "Auth mode: AAD token via Connect-AzAccount + X-Databricks-Azure-Workspace-Resource-Id header" -ForegroundColor Cyan
    $diagToken = Get-AadDbrToken
    if ($diagToken) {
        $claims = Decode-JwtClaims -Token $diagToken
        if ($claims) {
            Write-Host ("  token aud=" + $claims.aud + "  tid=" + $claims.tid + "  upn=" + $claims.upn + "  exp=" + $claims.exp) -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  WARNING: AAD token could not be obtained. Pass -PersonalAccessToken or -PatMap" -ForegroundColor Red
    }
}

if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

$workspaceRows = New-Object System.Collections.Generic.List[object]
$clusterRows = New-Object System.Collections.Generic.List[object]
$warehouseRows = New-Object System.Collections.Generic.List[object]
$poolRows = New-Object System.Collections.Generic.List[object]

foreach ($subId in $SubscriptionIds) {
    Write-Host ""
    Write-Host ("[SUB] " + $subId) -ForegroundColor Cyan
    try { Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null }
    catch {
        Write-Warning ("Cannot access subscription " + $subId + " : " + $_.Exception.Message)
        continue
    }
    $subName = (Get-AzContext).Subscription.Name

    $workspaces = @()
    try { $workspaces = @(Get-AzDatabricksWorkspace -ErrorAction Stop) } catch {
        Write-Warning ("Get-AzDatabricksWorkspace failed for " + $subId + " : " + $_.Exception.Message)
        $workspaces = @()
    }
    if ($workspaces.Count -eq 0) {
        Write-Host "  no Databricks workspaces in this subscription"
        continue
    }

    foreach ($ws in $workspaces) {
        Write-Host ("  [WS] " + $ws.Name + "  (" + $ws.WorkspaceUrl + ")") -ForegroundColor Yellow

        $skuName = ''
        if ($ws.Sku -and $ws.Sku.Name) { $skuName = $ws.Sku.Name } elseif ($ws.SkuName) { $skuName = $ws.SkuName }
        $rgName = ''
        if ($ws.ResourceGroupName) { $rgName = $ws.ResourceGroupName }
        elseif ($ws.Id) {
            $idMatch = [regex]::Match($ws.Id,'/resourceGroups/([^/]+)/')
            if ($idMatch.Success) { $rgName = $idMatch.Groups[1].Value }
        }

        $tokInfo = Resolve-WorkspaceToken -WorkspaceUrl $ws.WorkspaceUrl
        $authMode = if ($tokInfo) { $tokInfo.Mode } else { 'NONE' }

        $workspaceRows.Add([PSCustomObject]@{
            SubId = $subId
            SubName = $subName
            ResourceGroup = $rgName
            Workspace = $ws.Name
            Url = $ws.WorkspaceUrl
            Sku = $skuName
            Region = $ws.Location
            ManagedRG = $ws.ManagedResourceGroupId
            AuthMode = $authMode
        })

        $pools = @()
        $pl = Invoke-DbrApi -WorkspaceUrl $ws.WorkspaceUrl -WorkspaceResourceId $ws.Id -Path '/api/2.0/instance-pools/list'
        if ($pl -and $pl.instance_pools) {
            foreach ($p in $pl.instance_pools) {
                $pools += $p
                $poolRows.Add([PSCustomObject]@{
                    Sub = $subName
                    Workspace = $ws.Name
                    PoolName = $p.instance_pool_name
                    PoolId = $p.instance_pool_id
                    NodeType = $p.node_type_id
                    MinIdle = $p.min_idle_instances
                    MaxCapacity = $p.max_capacity
                    IdleTimeoutMins = $p.idle_instance_autotermination_minutes
                    Preloaded = $p.preloaded_spark_versions -join ';'
                    State = $p.state
                })
            }
        }

        $cl = Invoke-DbrApi -WorkspaceUrl $ws.WorkspaceUrl -WorkspaceResourceId $ws.Id -Path '/api/2.1/clusters/list'
        $clustersInWs = @()
        if ($cl -and $cl.clusters) { $clustersInWs = $cl.clusters }
        Write-Host ("    clusters: " + $clustersInWs.Count + "  pools: " + $pools.Count)

        foreach ($c in $clustersInWs) {
            $eventsBody = @{
                cluster_id = $c.cluster_id
                event_types = @('STARTING','RUNNING','TERMINATED')
                start_time = ([DateTimeOffset]::UtcNow.AddDays(-$EventLookbackDays).ToUnixTimeMilliseconds())
                limit = 200
                order = 'ASC'
            }
            $ev = Invoke-DbrApi -WorkspaceUrl $ws.WorkspaceUrl -WorkspaceResourceId $ws.Id -Path '/api/2.1/clusters/events' -Method 'POST' -Body $eventsBody
            $avgCold = Compute-AvgColdStart -Events $ev

            $diag = Get-ColdStartDiagnosis -Cluster $c -Pools $pools
            $svElig = Get-ServerlessEligibility -Cluster $c

            $workersText = if ($c.autoscale) { "$($c.autoscale.min_workers)-$($c.autoscale.max_workers) auto" } else { "$($c.num_workers)" }
            $initCount = if ($c.init_scripts) { ($c.init_scripts | Measure-Object).Count } else { 0 }
            $poolDisplay = if ($c.instance_pool_id) { $c.instance_pool_id } else { 'NONE' }

            $clusterRows.Add([PSCustomObject]@{
                Sub = $subName
                Workspace = $ws.Name
                Cluster = $c.cluster_name
                ClusterId = $c.cluster_id
                State = $c.state
                DbrVersion = $c.spark_version
                NodeType = $c.node_type_id
                DriverNodeType = $c.driver_node_type_id
                Workers = $workersText
                PoolId = $poolDisplay
                InitScripts = $initCount
                Photon = ($c.runtime_engine -eq 'PHOTON')
                AutoTermMins = $c.autotermination_minutes
                AccessMode = $c.data_security_mode
                Creator = $c.creator_user_name
                AvgColdStartMin = $avgCold
                Diagnosis = $diag
                ServerlessEligible = $svElig
            })
        }

        $wh = Invoke-DbrApi -WorkspaceUrl $ws.WorkspaceUrl -WorkspaceResourceId $ws.Id -Path '/api/2.0/sql/warehouses'
        $whInWs = @()
        if ($wh -and $wh.warehouses) { $whInWs = $wh.warehouses }
        Write-Host ("    sql warehouses: " + $whInWs.Count)

        foreach ($w in $whInWs) {
            $isServerless = $false
            if ($w.enable_serverless_compute) { $isServerless = $true }
            elseif ($w.warehouse_type -and $w.warehouse_type.ToString().ToUpper() -eq 'SERVERLESS') { $isServerless = $true }

            $warehouseRows.Add([PSCustomObject]@{
                Sub = $subName
                Workspace = $ws.Name
                Warehouse = $w.name
                WarehouseId = $w.id
                Type = $w.warehouse_type
                Size = $w.cluster_size
                MinClusters = $w.min_num_clusters
                MaxClusters = $w.max_num_clusters
                AutoStopMins = $w.auto_stop_mins
                Channel = $w.channel.name
                State = $w.state
                Serverless = $isServerless
            })
        }
    }
}

$runDate = (Get-Date).ToString('yyyy-MM-dd HH:mm zzz')
$csvCluster = Join-Path $OutputFolder 'Clusters.csv'
$csvWarehouse = Join-Path $OutputFolder 'Warehouses.csv'
$csvWs = Join-Path $OutputFolder 'Workspaces.csv'
$csvPool = Join-Path $OutputFolder 'Pools.csv'
$reportPath = Join-Path $OutputFolder 'Databricks-Audit-Pro.html'

$clusterRows | Export-Csv -Path $csvCluster -NoTypeInformation -Encoding UTF8
$warehouseRows | Export-Csv -Path $csvWarehouse -NoTypeInformation -Encoding UTF8
$workspaceRows | Export-Csv -Path $csvWs -NoTypeInformation -Encoding UTF8
$poolRows | Export-Csv -Path $csvPool -NoTypeInformation -Encoding UTF8

$html = Build-Html -Workspaces $workspaceRows -Clusters $clusterRows -Warehouses $warehouseRows -Pools $poolRows -RunDate $runDate -Subs $SubscriptionIds -Lookback $EventLookbackDays
[System.IO.File]::WriteAllText($reportPath, $html, [System.Text.Encoding]::UTF8)

Write-Host ""
Write-Host "DONE" -ForegroundColor Green
Write-Host ("Workspaces : " + $workspaceRows.Count)
Write-Host ("Clusters   : " + $clusterRows.Count)
Write-Host ("Warehouses : " + $warehouseRows.Count)
Write-Host ("Pools      : " + $poolRows.Count)
Write-Host ""
if ($clusterRows.Count -eq 0 -and $warehouseRows.Count -eq 0 -and $workspaceRows.Count -gt 0) {
    Write-Host "Workspaces were found but no clusters/warehouses returned." -ForegroundColor Yellow
    Write-Host "This means AAD token was accepted but workspace API returned empty." -ForegroundColor Yellow
    Write-Host "Likely cause: your AAD identity is not provisioned in those workspaces yet." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Fix: generate a Databricks PAT and re-run. From any PYX Databricks workspace UI:" -ForegroundColor Yellow
    Write-Host "  avatar (top right) > User Settings > Developer > Access tokens > Generate new token (90 days)" -ForegroundColor Yellow
    Write-Host "Then run:" -ForegroundColor Yellow
    Write-Host "  .\Databricks-Audit-Pro.ps1 -PersonalAccessToken `"dapi....`"" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "If you have multiple workspaces, generate a PAT per workspace and pass:" -ForegroundColor Yellow
    Write-Host "  .\Databricks-Audit-Pro.ps1 -PatMap @{ 'adb-XXX.azuredatabricks.net' = 'dapi...' ; 'adb-YYY.azuredatabricks.net' = 'dapi...' }" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Output:"
Write-Host ("  " + $reportPath)
Write-Host ("  " + $csvCluster)
Write-Host ("  " + $csvWarehouse)
Write-Host ("  " + $csvWs)
Write-Host ("  " + $csvPool)
Write-Host ""
try { Start-Process $reportPath } catch { }
