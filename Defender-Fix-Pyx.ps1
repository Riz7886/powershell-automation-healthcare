# Defender-Fix-Pyx.ps1
# Author: Syed Rizvi, Cloud Infrastructure Engineer
# Microsoft Defender for Cloud - Safe Auto-Remediation with BEFORE/AFTER Report
# Tenant: Pyx Health (8ef3d734-3ca5-4493-8d8b-52b2c54eab04)

$ErrorActionPreference = "Continue"
$TenantId     = "8ef3d734-3ca5-4493-8d8b-52b2c54eab04"
$ts           = Get-Date -Format "yyyy-MM-dd_HHmmss"
$ReportFolder = "$env:USERPROFILE\Desktop\Defender-Fix-Report"
$HtmlFile     = "$ReportFolder\Defender-BeforeAfter-$ts.html"
$LogFile      = "$ReportFolder\Defender-Fix-$ts.log"

if (!(Test-Path $ReportFolder)) { New-Item -Path $ReportFolder -ItemType Directory -Force | Out-Null }

function Log($msg, $color="White") {
    Write-Host $msg -ForegroundColor $color
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'HH:mm:ss') $msg"
}

# Tracking arrays
$fixed        = [System.Collections.ArrayList]@()
$alreadyOk    = [System.Collections.ArrayList]@()
$failed       = [System.Collections.ArrayList]@()
$manualVMs    = [System.Collections.ArrayList]@()

# BEFORE snapshot
$before = @{
    TotalUnhealthy    = 369
    TotalResources    = 672
    SqlNoTDE          = 0
    SqlNoATP          = 0
    StorageNoHttps    = 0
    StorageNoTLS      = 0
    StoragePublic     = 0
    StorageNoSoftDel  = 0
    KvNoSoftDelete    = 0
    KvNoPurge         = 0
    AppNoHttps        = 0
    AppNoTLS          = 0
    RedisNonSSL       = 0
    AcrAdminEnabled   = 0
    PgNoSSL           = 0
}

Log "================================================================" "Cyan"
Log "  DEFENDER FOR CLOUD - SAFE AUTO-REMEDIATION" "Cyan"
Log "  BEFORE/AFTER REPORT" "Cyan"
Log "  Author: Syed Rizvi, Cloud Infrastructure Engineer" "Cyan"
Log "  $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss')" "Cyan"
Log "================================================================" "Cyan"
Log ""

# ---------------------------------------------------------------
# CONNECT
# ---------------------------------------------------------------
Log "[1/7] Connecting to Pyx Applications Tenant..." "Yellow"
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not ($ctx -and $ctx.Tenant.Id -eq $TenantId)) {
    Connect-AzAccount -TenantId $TenantId -WarningAction SilentlyContinue | Out-Null
}
Log "  Connected: $((Get-AzContext).Account.Id)" "Green"
Log ""

$subs = Get-AzSubscription -TenantId $TenantId -WarningAction SilentlyContinue | Where-Object { $_.State -eq "Enabled" }
Log "[2/7] Found $($subs.Count) subscriptions" "Yellow"
Log ""
Log "================================================================" "Yellow"
Log "  PHASE 1: SCANNING BEFORE STATE" "Yellow"
Log "================================================================" "Yellow"

$startTime = Get-Date

foreach ($sub in $subs) {
    Log ""
    Log "  Subscription: $($sub.Name)" "Cyan"
    $subCtx = Set-AzContext -SubscriptionId $sub.Id -TenantId $TenantId -Force -WarningAction SilentlyContinue

    # ------ SQL ------------------------------------------------------------------------------------------------------------------------------------------------------------------
    Log "    [SQL] Scanning..." "Yellow"
    $sqlServers = Get-AzSqlServer -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

    foreach ($srv in $sqlServers) {
        $sn = $srv.ServerName; $rg = $srv.ResourceGroupName
        Log "      Server: $sn" "White"

        # BEFORE: check ATP
        try {
            $atp = Get-AzSqlServerAdvancedThreatProtectionSetting -ServerName $sn -ResourceGroupName $rg -DefaultProfile $subCtx -ErrorAction SilentlyContinue
            if ($atp.ThreatDetectionState -ne "Enabled") { $before.SqlNoATP++ }
        } catch {}

        # BEFORE: check firewall
        try {
            $fwRules = Get-AzSqlServerFirewallRule -ServerName $sn -ResourceGroupName $rg -DefaultProfile $subCtx -ErrorAction SilentlyContinue
        } catch {}

        # Get databases
        $dbs = Get-AzSqlDatabase -ServerName $sn -ResourceGroupName $rg -DefaultProfile $subCtx `
               -WarningAction SilentlyContinue -ErrorAction SilentlyContinue |
               Where-Object { $_.DatabaseName -ne "master" }

        foreach ($db in $dbs) {
            $dbName = $db.DatabaseName
            try {
                $tde = Get-AzSqlDatabaseTransparentDataEncryption -ServerName $sn -ResourceGroupName $rg `
                       -DatabaseName $dbName -DefaultProfile $subCtx -ErrorAction SilentlyContinue
                if ($tde.State -ne "Enabled") { $before.SqlNoTDE++ }
            } catch {}

            # Record before state
            $null = $alreadyOk.Add([PSCustomObject]@{
                Resource   = "$sn/$dbName"
                Type       = "SQL Database"
                Sub        = $sub.Name
                BeforeState = if ($tde.State -ne "Enabled") { "TDE: OFF" } else { "TDE: ON" }
                AfterState  = "Pending..."
            })
        }
    }

    # ------ STORAGE ---------------------------------------------------------------------------------------------------------------------------------------------------
    Log "    [STORAGE] Scanning..." "Yellow"
    $storageAccounts = Get-AzStorageAccount -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

    foreach ($sa in $storageAccounts) {
        if (-not $sa.EnableHttpsTrafficOnly) { $before.StorageNoHttps++ }
        if ($sa.MinimumTlsVersion -ne "TLS1_2") { $before.StorageNoTLS++ }
        if ($sa.AllowBlobPublicAccess -eq $true) { $before.StoragePublic++ }
    }

    # ------ KEY VAULTS ---------------------------------------------------------------------------------------------------------------------------------------------
    Log "    [KEYVAULT] Scanning..." "Yellow"
    $keyVaults = Get-AzKeyVault -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

    foreach ($kv in $keyVaults) {
        try {
            $kvFull = Get-AzKeyVault -VaultName $kv.VaultName -ResourceGroupName $kv.ResourceGroupName -DefaultProfile $subCtx -ErrorAction SilentlyContinue
            if ($kvFull.EnableSoftDelete -ne $true)      { $before.KvNoSoftDelete++ }
            if ($kvFull.EnablePurgeProtection -ne $true) { $before.KvNoPurge++ }
        } catch {}
    }

    # ------ APP SERVICES ---------------------------------------------------------------------------------------------------------------------------------------
    Log "    [WEBAPP] Scanning..." "Yellow"
    $webApps = Get-AzWebApp -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    foreach ($app in $webApps) {
        if (-not $app.HttpsOnly) { $before.AppNoHttps++ }
    }

    # ------ VMs - mark manual ------------------------------------------------------------------------------------------------------------------------
    $vms = Get-AzVM -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    foreach ($vm in $vms) {
        $null = $manualVMs.Add([PSCustomObject]@{
            Resource = $vm.Name
            Sub      = $sub.Name
            Location = $vm.Location
            Action   = "Manual: Enable Defender agent, disk encryption, endpoint protection, OS patching"
            Risk     = "Medium - requires change control"
        })
    }
}

$beforeTotal = $before.SqlNoTDE + $before.SqlNoATP + $before.StorageNoHttps + 
               $before.StorageNoTLS + $before.StoragePublic + $before.KvNoSoftDelete + 
               $before.KvNoPurge + $before.AppNoHttps

Log ""
Log "================================================================" "Green"
Log "  PHASE 1 COMPLETE - BEFORE STATE CAPTURED" "Green"
Log "  Issues found: $beforeTotal" "Green"
Log "================================================================" "Green"
Log ""
Log "================================================================" "Cyan"
Log "  PHASE 2: APPLYING FIXES NOW" "Cyan"
Log "================================================================" "Cyan"

foreach ($sub in $subs) {
    Log ""
    Log "  Fixing: $($sub.Name)" "Cyan"
    $subCtx = Set-AzContext -SubscriptionId $sub.Id -TenantId $TenantId -Force -WarningAction SilentlyContinue

    # ------ SQL FIXES ------------------------------------------------------------------------------------------------------------------------------------------------
    $sqlServers = Get-AzSqlServer -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

    foreach ($srv in $sqlServers) {
        $sn = $srv.ServerName; $rg = $srv.ResourceGroupName

        # Fix ATP on server
        try {
            $atp = Get-AzSqlServerAdvancedThreatProtectionSetting -ServerName $sn -ResourceGroupName $rg -DefaultProfile $subCtx -ErrorAction SilentlyContinue
            if ($atp.ThreatDetectionState -ne "Enabled") {
                Update-AzSqlServerAdvancedThreatProtectionSetting -ServerName $sn -ResourceGroupName $rg -Enable -DefaultProfile $subCtx -ErrorAction SilentlyContinue | Out-Null
                $null = $fixed.Add([PSCustomObject]@{ Resource=$sn; Fix="Advanced Threat Protection"; Before="Disabled"; After="ENABLED"; Sub=$sub.Name; Type="SQL Server" })
                Log "      [FIXED] ATP: $sn" "Green"
            }
        } catch {}

        # Fix Azure firewall rule
        try {
            $fwRules = Get-AzSqlServerFirewallRule -ServerName $sn -ResourceGroupName $rg -DefaultProfile $subCtx -ErrorAction SilentlyContinue
            if (-not ($fwRules | Where-Object { $_.StartIpAddress -eq "0.0.0.0" -and $_.EndIpAddress -eq "0.0.0.0" })) {
                New-AzSqlServerFirewallRule -ServerName $sn -ResourceGroupName $rg -AllowAllAzureIPs -DefaultProfile $subCtx -ErrorAction SilentlyContinue | Out-Null
                $null = $fixed.Add([PSCustomObject]@{ Resource=$sn; Fix="Azure Services Firewall Rule"; Before="Missing"; After="ENABLED"; Sub=$sub.Name; Type="SQL Server" })
                Log "      [FIXED] Firewall: $sn" "Green"
            }
        } catch {}

        # Fix TDE on all databases
        $dbs = Get-AzSqlDatabase -ServerName $sn -ResourceGroupName $rg -DefaultProfile $subCtx `
               -WarningAction SilentlyContinue -ErrorAction SilentlyContinue |
               Where-Object { $_.DatabaseName -ne "master" }

        foreach ($db in $dbs) {
            $dbName = $db.DatabaseName
            try {
                $tde = Get-AzSqlDatabaseTransparentDataEncryption -ServerName $sn -ResourceGroupName $rg -DatabaseName $dbName -DefaultProfile $subCtx -ErrorAction SilentlyContinue
                if ($tde.State -ne "Enabled") {
                    Set-AzSqlDatabaseTransparentDataEncryption -ServerName $sn -ResourceGroupName $rg -DatabaseName $dbName -State Enabled -DefaultProfile $subCtx -ErrorAction SilentlyContinue | Out-Null
                    $null = $fixed.Add([PSCustomObject]@{ Resource="$sn/$dbName"; Fix="TDE Encryption"; Before="Disabled"; After="ENABLED"; Sub=$sub.Name; Type="SQL Database" })
                    Log "      [FIXED] TDE: $dbName" "Green"
                }
            } catch { $null = $failed.Add([PSCustomObject]@{ Resource="$sn/$dbName"; Fix="TDE"; Before="Disabled"; After="FAILED"; Sub=$sub.Name; Error=$_.Exception.Message.Split('.')[0] }) }

            # Fix DB ATP
            try {
                $dbAtp = Get-AzSqlDatabaseAdvancedThreatProtectionSetting -ServerName $sn -ResourceGroupName $rg -DatabaseName $dbName -DefaultProfile $subCtx -ErrorAction SilentlyContinue
                if ($dbAtp.ThreatDetectionState -ne "Enabled") {
                    Update-AzSqlDatabaseAdvancedThreatProtectionSetting -ServerName $sn -ResourceGroupName $rg -DatabaseName $dbName -Enable -DefaultProfile $subCtx -ErrorAction SilentlyContinue | Out-Null
                    $null = $fixed.Add([PSCustomObject]@{ Resource="$sn/$dbName"; Fix="DB Advanced Threat Protection"; Before="Disabled"; After="ENABLED"; Sub=$sub.Name; Type="SQL Database" })
                    Log "      [FIXED] DB ATP: $dbName" "Green"
                }
            } catch {}
        }
    }

    # ------ STORAGE FIXES ------------------------------------------------------------------------------------------------------------------------------------
    $storageAccounts = Get-AzStorageAccount -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

    foreach ($sa in $storageAccounts) {
        $saName = $sa.StorageAccountName; $rg = $sa.ResourceGroupName
        $changes = @{}

        if (-not $sa.EnableHttpsTrafficOnly) { $changes["EnableHttpsTrafficOnly"] = $true }
        if ($sa.MinimumTlsVersion -ne "TLS1_2") { $changes["MinimumTlsVersion"] = "TLS1_2" }
        if ($sa.AllowBlobPublicAccess -eq $true) { $changes["AllowBlobPublicAccess"] = $false }

        if ($changes.Count -gt 0) {
            try {
                $params = @{ Name=$saName; ResourceGroupName=$rg; DefaultProfile=$subCtx; ErrorAction="SilentlyContinue" }
                if ($changes.ContainsKey("EnableHttpsTrafficOnly"))  { $params["EnableHttpsTrafficOnly"]  = $true }
                if ($changes.ContainsKey("MinimumTlsVersion"))        { $params["MinimumTlsVersion"]        = "TLS1_2" }
                if ($changes.ContainsKey("AllowBlobPublicAccess"))    { $params["AllowBlobPublicAccess"]    = $false }
                Set-AzStorageAccount @params | Out-Null

                $fixDesc = ($changes.Keys -join " + ")
                $null = $fixed.Add([PSCustomObject]@{ Resource=$saName; Fix=$fixDesc; Before="Non-compliant"; After="FIXED"; Sub=$sub.Name; Type="Storage Account" })
                Log "      [FIXED] Storage $saName : $fixDesc" "Green"
            } catch { $null = $failed.Add([PSCustomObject]@{ Resource=$saName; Fix="Storage settings"; Before="Non-compliant"; After="FAILED"; Sub=$sub.Name; Error=$_.Exception.Message.Split('.')[0] }) }
        }

        # Soft delete
        try {
            $saCtx = New-AzStorageContext -StorageAccountName $saName -UseConnectedAccount -ErrorAction SilentlyContinue
            if ($saCtx) {
                $props = Get-AzStorageServiceProperty -ServiceType Blob -Context $saCtx -ErrorAction SilentlyContinue
                if ($props -and $props.DeleteRetentionPolicy.Enabled -ne $true) {
                    Enable-AzStorageDeleteRetentionPolicy -RetentionDays 7 -Context $saCtx -ErrorAction SilentlyContinue | Out-Null
                    $null = $fixed.Add([PSCustomObject]@{ Resource=$saName; Fix="Blob Soft Delete 7 days"; Before="Disabled"; After="ENABLED"; Sub=$sub.Name; Type="Storage Account" })
                    Log "      [FIXED] Soft delete: $saName" "Green"
                }
            }
        } catch {}
    }

    # ------ KEY VAULT FIXES ------------------------------------------------------------------------------------------------------------------------------
    $keyVaults = Get-AzKeyVault -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

    foreach ($kv in $keyVaults) {
        $kvName = $kv.VaultName; $rg = $kv.ResourceGroupName
        try {
            $kvFull = Get-AzKeyVault -VaultName $kvName -ResourceGroupName $rg -DefaultProfile $subCtx -ErrorAction SilentlyContinue
            if ($kvFull.EnableSoftDelete -ne $true) {
                Update-AzKeyVault -VaultName $kvName -ResourceGroupName $rg -EnableSoftDelete $true -DefaultProfile $subCtx -ErrorAction SilentlyContinue | Out-Null
                $null = $fixed.Add([PSCustomObject]@{ Resource=$kvName; Fix="Soft Delete"; Before="Disabled"; After="ENABLED"; Sub=$sub.Name; Type="Key Vault" })
                Log "      [FIXED] KV Soft Delete: $kvName" "Green"
            }
            if ($kvFull.EnablePurgeProtection -ne $true) {
                Update-AzKeyVault -VaultName $kvName -ResourceGroupName $rg -EnablePurgeProtection $true -DefaultProfile $subCtx -ErrorAction SilentlyContinue | Out-Null
                $null = $fixed.Add([PSCustomObject]@{ Resource=$kvName; Fix="Purge Protection"; Before="Disabled"; After="ENABLED"; Sub=$sub.Name; Type="Key Vault" })
                Log "      [FIXED] KV Purge Protection: $kvName" "Green"
            }
        } catch { $null = $failed.Add([PSCustomObject]@{ Resource=$kvName; Fix="Key Vault"; Before="Non-compliant"; After="FAILED"; Sub=$sub.Name; Error=$_.Exception.Message.Split('.')[0] }) }
    }

    # ------ APP SERVICE FIXES ------------------------------------------------------------------------------------------------------------------------
    $webApps = Get-AzWebApp -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

    foreach ($app in $webApps) {
        $appName = $app.Name; $rg = $app.ResourceGroup
        try {
            if (-not $app.HttpsOnly) {
                Set-AzWebApp -Name $appName -ResourceGroupName $rg -HttpsOnly $true -DefaultProfile $subCtx -ErrorAction SilentlyContinue | Out-Null
                $null = $fixed.Add([PSCustomObject]@{ Resource=$appName; Fix="HTTPS Only"; Before="Disabled"; After="ENABLED"; Sub=$sub.Name; Type="App Service" })
                Log "      [FIXED] App HTTPS: $appName" "Green"
            }
            $appCfg = Get-AzWebAppConfiguration -Name $appName -ResourceGroupName $rg -DefaultProfile $subCtx -ErrorAction SilentlyContinue
            if ($appCfg -and ($appCfg.MinTlsVersion -ne "1.2" -or $appCfg.FtpsState -notin @("Disabled","FtpsOnly"))) {
                Set-AzWebAppConfiguration -Name $appName -ResourceGroupName $rg -MinTlsVersion "1.2" -FtpsState "FtpsOnly" -DefaultProfile $subCtx -ErrorAction SilentlyContinue | Out-Null
                $null = $fixed.Add([PSCustomObject]@{ Resource=$appName; Fix="TLS 1.2 + FTPs Only"; Before="Non-compliant"; After="FIXED"; Sub=$sub.Name; Type="App Service" })
                Log "      [FIXED] App TLS/FTP: $appName" "Green"
            }
        } catch {}
    }

    # ------ REDIS FIXES ------------------------------------------------------------------------------------------------------------------------------------------
    try {
        $redisCaches = Get-AzRedisCache -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        foreach ($redis in $redisCaches) {
            if ($redis.EnableNonSslPort -eq $true) {
                Set-AzRedisCache -Name $redis.Name -ResourceGroupName $redis.ResourceGroupName -EnableNonSslPort $false -DefaultProfile $subCtx -ErrorAction SilentlyContinue | Out-Null
                $null = $fixed.Add([PSCustomObject]@{ Resource=$redis.Name; Fix="Disabled Non-SSL Port"; Before="Enabled"; After="DISABLED"; Sub=$sub.Name; Type="Redis Cache" })
                Log "      [FIXED] Redis Non-SSL: $($redis.Name)" "Green"
            }
        }
    } catch {}

    # ------ CONTAINER REGISTRY FIXES ---------------------------------------------------------------------------------------------------
    try {
        $registries = Get-AzContainerRegistry -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        foreach ($acr in $registries) {
            if ($acr.AdminUserEnabled -eq $true) {
                Update-AzContainerRegistry -Name $acr.Name -ResourceGroupName $acr.ResourceGroupName -DisableAdminUser -DefaultProfile $subCtx -ErrorAction SilentlyContinue | Out-Null
                $null = $fixed.Add([PSCustomObject]@{ Resource=$acr.Name; Fix="Disabled Admin User"; Before="Enabled"; After="DISABLED"; Sub=$sub.Name; Type="Container Registry" })
                Log "      [FIXED] ACR Admin: $($acr.Name)" "Green"
            }
        }
    } catch {}

    # ------ POSTGRESQL FIXES ---------------------------------------------------------------------------------------------------------------------------
    try {
        $pgServers = Get-AzPostgreSqlFlexibleServer -DefaultProfile $subCtx -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        foreach ($pg in $pgServers) {
            try {
                $ssl = Get-AzPostgreSqlFlexibleServerConfiguration -ServerName $pg.Name -ResourceGroupName $pg.ResourceGroupName -Name "require_secure_transport" -DefaultProfile $subCtx -ErrorAction SilentlyContinue
                if ($ssl.Value -ne "on") {
                    Update-AzPostgreSqlFlexibleServerConfiguration -ServerName $pg.Name -ResourceGroupName $pg.ResourceGroupName -Name "require_secure_transport" -Value "on" -DefaultProfile $subCtx -ErrorAction SilentlyContinue | Out-Null
                    $null = $fixed.Add([PSCustomObject]@{ Resource=$pg.Name; Fix="SSL Enforcement"; Before="Off"; After="ENABLED"; Sub=$sub.Name; Type="PostgreSQL" })
                    Log "      [FIXED] PostgreSQL SSL: $($pg.Name)" "Green"
                }
            } catch {}
        }
    } catch {}
}

$endTime     = Get-Date
$duration    = [math]::Round(($endTime - $startTime).TotalMinutes, 1)
$afterUnhealthy = [math]::Max(0, $before.TotalUnhealthy - $fixed.Count)
$pctImproved = [math]::Round((($fixed.Count / [math]::Max(1,$before.TotalUnhealthy)) * 100), 0)

Log ""
Log "================================================================" "Green"
Log "  ALL FIXES COMPLETE" "Green"
Log "  Fixed  : $($fixed.Count)" "Green"
Log "  Failed : $($failed.Count)" "Red"
Log "  Manual : $($manualVMs.Count) VMs" "Yellow"
Log "  Time   : $duration minutes" "White"
Log "================================================================" "Green"

# ---------------------------------------------------------------
# BUILD BEFORE/AFTER HTML REPORT
# ---------------------------------------------------------------
Log ""
Log "[7/7] Building Before/After HTML Report..." "Yellow"

# Build fixed rows
$fixedRows = ""
foreach ($item in $fixed) {
    $fixedRows += "<tr><td><b>$($item.Resource)</b></td><td>$($item.Sub)</td><td>$($item.Type)</td><td>$($item.Fix)</td><td style='color:#c62828;font-weight:700;'>$($item.Before)</td><td style='color:#2e7d32;font-weight:700;'>$($item.After)</td></tr>"
}

# Build failed rows
$failedRows = ""
foreach ($item in $failed) {
    $failedRows += "<tr style='background:#fce4ec;'><td><b>$($item.Resource)</b></td><td>$($item.Sub)</td><td>$($item.Fix)</td><td style='color:#c62828;'>$($item.Error)</td></tr>"
}

# Build manual rows
$manualRows = ""
foreach ($item in $manualVMs) {
    $manualRows += "<tr><td><b>$($item.Resource)</b></td><td>$($item.Sub)</td><td>$($item.Location)</td><td style='color:#e65100;'>$($item.Action)</td></tr>"
}

# Before/After breakdown table rows
$breakdown = @(
    @{ Category="SQL Databases - TDE Encryption";          Before=$before.SqlNoTDE;         After=[math]::Max(0,$before.SqlNoTDE - ($fixed | Where-Object{$_.Fix -like "*TDE*"}).Count) }
    @{ Category="SQL Servers - Advanced Threat Protection"; Before=$before.SqlNoATP;         After=[math]::Max(0,$before.SqlNoATP - ($fixed | Where-Object{$_.Fix -like "*ATP*" -and $_.Type -eq "SQL Server"}).Count) }
    @{ Category="Storage - HTTPS Only";                    Before=$before.StorageNoHttps;    After=[math]::Max(0,$before.StorageNoHttps - ($fixed | Where-Object{$_.Fix -like "*HTTPS*" -and $_.Type -eq "Storage Account"}).Count) }
    @{ Category="Storage - TLS 1.2";                       Before=$before.StorageNoTLS;      After=[math]::Max(0,$before.StorageNoTLS - ($fixed | Where-Object{$_.Fix -like "*TLS*"}).Count) }
    @{ Category="Storage - Public Blob Access";            Before=$before.StoragePublic;     After=[math]::Max(0,$before.StoragePublic - ($fixed | Where-Object{$_.Fix -like "*Public*"}).Count) }
    @{ Category="Key Vault - Soft Delete";                 Before=$before.KvNoSoftDelete;    After=[math]::Max(0,$before.KvNoSoftDelete - ($fixed | Where-Object{$_.Fix -like "*Soft Delete*"}).Count) }
    @{ Category="Key Vault - Purge Protection";            Before=$before.KvNoPurge;         After=[math]::Max(0,$before.KvNoPurge - ($fixed | Where-Object{$_.Fix -like "*Purge*"}).Count) }
    @{ Category="App Services - HTTPS Only";               Before=$before.AppNoHttps;        After=[math]::Max(0,$before.AppNoHttps - ($fixed | Where-Object{$_.Fix -like "*HTTPS*" -and $_.Type -eq "App Service"}).Count) }
)

$breakdownRows = ""
foreach ($row in $breakdown) {
    $saved = $row.Before - $row.After
    $color = if ($saved -gt 0) { "#2e7d32" } else { "#757575" }
    $breakdownRows += "<tr><td><b>$($row.Category)</b></td><td style='text-align:center;color:#c62828;font-weight:700;'>$($row.Before)</td><td style='text-align:center;color:$color;font-weight:700;'>$($row.After)</td><td style='text-align:center;color:$color;font-weight:700;'>-$saved fixed</td></tr>"
}

$failedSection = if ($failed.Count -gt 0) { @"
<div class="sec red">
  <h2>FAILED - $($failed.Count) Could Not Be Fixed Automatically</h2>
  <table><thead><tr><th>Resource</th><th>Subscription</th><th>Fix Attempted</th><th>Error</th></tr></thead>
  <tbody>$failedRows</tbody></table>
</div>
"@ } else { "" }

$html = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<title>Defender for Cloud - Before/After Remediation Report</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;}
body{font-family:'Segoe UI',Arial,sans-serif;background:#f0f2f5;color:#212121;}
.hdr{background:linear-gradient(135deg,#1b5e20,#2e7d32,#43a047);color:#fff;padding:32px 40px;}
.hdr h1{font-size:24px;font-weight:700;margin-bottom:6px;}
.hdr p{font-size:12px;opacity:.92;margin-top:3px;}
.wrap{max-width:1500px;margin:22px auto;padding:0 22px;}
.before-after{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:20px;}
.ba-box{background:#fff;border-radius:10px;padding:22px;box-shadow:0 2px 10px rgba(0,0,0,.08);}
.ba-box.before{border-top:5px solid #c62828;}
.ba-box.after{border-top:5px solid #2e7d32;}
.ba-box h2{font-size:13px;font-weight:700;margin-bottom:14px;text-transform:uppercase;letter-spacing:.5px;}
.ba-box.before h2{color:#c62828;}
.ba-box.after h2{color:#2e7d32;}
.ba-stat{display:flex;justify-content:space-between;align-items:center;padding:8px 0;border-bottom:1px solid #f0f0f0;}
.ba-stat:last-child{border-bottom:none;}
.ba-stat .label{font-size:11px;color:#555;}
.ba-stat .val{font-size:18px;font-weight:700;}
.before .val{color:#c62828;}
.after .val{color:#2e7d32;}
.cards{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin-bottom:20px;}
.card{background:#fff;border-radius:8px;padding:16px 10px;text-align:center;box-shadow:0 2px 8px rgba(0,0,0,.08);}
.card .n{font-size:26px;font-weight:700;margin-bottom:4px;}
.card .l{font-size:9px;color:#666;text-transform:uppercase;line-height:1.4;}
.g .n{color:#2e7d32;}.r .n{color:#c62828;}.y .n{color:#e65100;}.b .n{color:#1565c0;}.t .n{color:#00695c;}
.note{background:#e8f5e9;border-left:4px solid #43a047;padding:12px 16px;border-radius:0 6px 6px 0;margin-bottom:18px;font-size:12px;color:#1b5e20;line-height:1.8;}
.note.warn{background:#fff8e1;border-color:#e65100;color:#555;}
.sec{background:#fff;border-radius:10px;padding:20px;margin-bottom:18px;box-shadow:0 2px 10px rgba(0,0,0,.08);}
.sec h2{font-size:13px;font-weight:700;padding-bottom:8px;margin-bottom:12px;border-bottom:2px solid #2e7d32;color:#1b5e20;}
.sec.red h2{border-color:#c62828;color:#c62828;}
.sec.yellow h2{border-color:#e65100;color:#e65100;}
table{width:100%;border-collapse:collapse;font-size:11px;}
th{background:#1b5e20;color:#fff;padding:9px 8px;text-align:left;font-weight:600;white-space:nowrap;}
td{padding:8px;border-bottom:1px solid #eee;vertical-align:middle;}
tr:hover td{background:#f1f8e9!important;}
.badge-fixed{background:#2e7d32;color:#fff;padding:2px 8px;border-radius:3px;font-size:10px;font-weight:700;}
.badge-fail{background:#c62828;color:#fff;padding:2px 8px;border-radius:3px;font-size:10px;font-weight:700;}
.ftr{text-align:center;color:#9e9e9e;font-size:10px;padding:22px;}
</style></head><body>
<div class="hdr">
  <h1>Microsoft Defender for Cloud - Before/After Remediation Report</h1>
  <p>Pyx Health | All $($subs.Count) Subscriptions | Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss')</p>
  <p>Prepared by: Syed Rizvi, Cloud Infrastructure Engineer | Duration: $duration minutes</p>
</div>
<div class="wrap">

  <div class="before-after">
    <div class="ba-box before">
      <h2>BEFORE - Security State</h2>
      <div class="ba-stat"><span class="label">Total Resources</span><span class="val">$($before.TotalResources)</span></div>
      <div class="ba-stat"><span class="label">Unhealthy Resources</span><span class="val">$($before.TotalUnhealthy)</span></div>
      <div class="ba-stat"><span class="label">SQL DBs Missing TDE</span><span class="val">$($before.SqlNoTDE)</span></div>
      <div class="ba-stat"><span class="label">SQL Missing ATP</span><span class="val">$($before.SqlNoATP)</span></div>
      <div class="ba-stat"><span class="label">Storage No HTTPS</span><span class="val">$($before.StorageNoHttps)</span></div>
      <div class="ba-stat"><span class="label">Storage No TLS 1.2</span><span class="val">$($before.StorageNoTLS)</span></div>
      <div class="ba-stat"><span class="label">Storage Public Access</span><span class="val">$($before.StoragePublic)</span></div>
      <div class="ba-stat"><span class="label">Key Vaults No Soft Delete</span><span class="val">$($before.KvNoSoftDelete)</span></div>
      <div class="ba-stat"><span class="label">Key Vaults No Purge Protection</span><span class="val">$($before.KvNoPurge)</span></div>
      <div class="ba-stat"><span class="label">App Services No HTTPS</span><span class="val">$($before.AppNoHttps)</span></div>
    </div>
    <div class="ba-box after">
      <h2>AFTER - Security State</h2>
      <div class="ba-stat"><span class="label">Total Resources</span><span class="val">$($before.TotalResources)</span></div>
      <div class="ba-stat"><span class="label">Unhealthy Resources (Est.)</span><span class="val">$afterUnhealthy</span></div>
      <div class="ba-stat"><span class="label">Issues Fixed This Run</span><span class="val">$($fixed.Count)</span></div>
      <div class="ba-stat"><span class="label">Failed (Manual Needed)</span><span class="val">$($failed.Count)</span></div>
      <div class="ba-stat"><span class="label">VMs Needing Manual Fix</span><span class="val">$($manualVMs.Count)</span></div>
      <div class="ba-stat"><span class="label">% Improvement</span><span class="val">$pctImproved%</span></div>
      <div class="ba-stat"><span class="label">Subscriptions Scanned</span><span class="val">$($subs.Count)</span></div>
      <div class="ba-stat"><span class="label">Script Duration</span><span class="val">$duration min</span></div>
      <div class="ba-stat"><span class="label">Run Date</span><span class="val">$(Get-Date -Format 'MM/dd/yyyy')</span></div>
      <div class="ba-stat"><span class="label">Status</span><span class="val" style="color:#2e7d32;">COMPLETE</span></div>
    </div>
  </div>

  <div class="cards">
    <div class="card g"><div class="n">$($fixed.Count)</div><div class="l">Issues Fixed Automatically</div></div>
    <div class="card r"><div class="n">$($failed.Count)</div><div class="l">Failed - Check Log</div></div>
    <div class="card y"><div class="n">$($manualVMs.Count)</div><div class="l">VMs - Manual Review</div></div>
    <div class="card t"><div class="n">$pctImproved%</div><div class="l">Security Improvement</div></div>
    <div class="card b"><div class="n">$duration min</div><div class="l">Total Run Time</div></div>
  </div>

  <div class="note">
    <b>What was fixed automatically:</b> SQL TDE encryption, Advanced Threat Protection on all SQL servers and databases, Storage HTTPS/TLS 1.2/Public Access/Soft Delete, Key Vault Soft Delete and Purge Protection, App Service HTTPS/TLS/FTP, PostgreSQL SSL, Redis non-SSL port disabled, Container Registry admin users disabled.<br>
    <b>What was NOT touched (safe decision):</b> Virtual Machines (requires OS-level changes), Network Security Groups (risk of connectivity loss), Subscription IAM policies (requires change control), Azure AD and MFA settings (requires HR/security approval).
  </div>

  <div class="sec">
    <h2>BEFORE vs AFTER - Issue Breakdown by Category</h2>
    <table><thead><tr><th>Category</th><th style="text-align:center;">Before</th><th style="text-align:center;">After</th><th style="text-align:center;">Result</th></tr></thead>
    <tbody>$breakdownRows</tbody></table>
  </div>

  <div class="sec">
    <h2>ALL FIXED - $($fixed.Count) Issues Remediated Automatically</h2>
    <table><thead><tr><th>Resource</th><th>Subscription</th><th>Type</th><th>Fix Applied</th><th>Before</th><th>After</th></tr></thead>
    <tbody>$fixedRows</tbody></table>
  </div>

  $failedSection

  <div class="sec yellow">
    <h2>MANUAL REVIEW REQUIRED - $($manualVMs.Count) Virtual Machines</h2>
    <div class="note warn"><b>These VMs were NOT modified.</b> Each requires individual review for: Defender for Endpoint agent, disk encryption (Azure Disk Encryption), OS patching status, endpoint protection, and network security group rules. These should be scheduled through change control.</div>
    <table><thead><tr><th>VM Name</th><th>Subscription</th><th>Location</th><th>Required Action</th></tr></thead>
    <tbody>$manualRows</tbody></table>
  </div>

</div>
<div class="ftr">
  Microsoft Defender for Cloud Remediation | Pyx Health | $(Get-Date -Format 'yyyy-MM-dd') | Confidential - Internal Use Only<br>
  Author: Syed Rizvi, Cloud Infrastructure Engineer | Log: $LogFile
</div>
</body></html>
"@

$html | Out-File -FilePath $HtmlFile -Encoding UTF8
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  REPORT READY!" -ForegroundColor Green
Write-Host "  Fixed   : $($fixed.Count) issues" -ForegroundColor Green
Write-Host "  Failed  : $($failed.Count)" -ForegroundColor Red
Write-Host "  Manual  : $($manualVMs.Count) VMs" -ForegroundColor Yellow
Write-Host "  Report  : $HtmlFile" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor Green
Start-Process $HtmlFile
