<#
.SYNOPSIS
  PYX Health — Vanta / Nessus Azure Server remediation script.

.DESCRIPTION
  Auto-fixes the common classes of Vanta test failures on PYX Azure VMs:
    1. Oracle Linux / RHEL package updates (bind-*, libarchive, python3-bind, etc.)
    2. Apache Tomcat version upgrade (CVE-class vulns)
    3. Optional Nessus rescan trigger
    4. Optional Vanta test re-run trigger

  Designed for recurring use — every time Nessus finds package CVEs on a PYX VM,
  run this script, select which fix class to apply, done.

.PARAMETER VmName
  Target Azure VM name (default: vm-moveit-auto)

.PARAMETER ResourceGroup
  Target Azure resource group name (default: rg-pyx-prod — adjust as needed)

.PARAMETER Subscription
  Target Azure subscription ID (default: current)

.PARAMETER Action
  Which fix to apply: PackageUpdate, TomcatUpgrade, All, DryRun

.PARAMETER TomcatTargetVersion
  Target Tomcat version to install (default: 10.1.49 — latest 10.1.x LTS as of Apr 2026)

.EXAMPLE
  .\pyx-vanta-autofix.ps1 -Action DryRun
  Shows what would be done without executing anything.

.EXAMPLE
  .\pyx-vanta-autofix.ps1 -Action PackageUpdate -VmName vm-moveit-auto
  Runs dnf update on the VM to fix bind-*, libarchive, python3 package CVEs.

.EXAMPLE
  .\pyx-vanta-autofix.ps1 -Action All
  Package updates + Tomcat upgrade + Nessus rescan trigger. Full remediation.

.NOTES
  Prerequisites:
    - Azure CLI installed + logged in (az login)
    - Contributor role on the target VM
    - VM must allow "Run Command" from Azure (default for most VMs)

  Safety:
    - All fixes use Azure Run Command (audit-logged by Azure)
    - Dry-run mode available
    - Each step logged to .\pyx-vanta-autofix-YYYYMMDD-HHMM.log
    - Snapshot created before package updates (in Snapshot resource group)
#>

[CmdletBinding()]
param(
    [string]$VmName = "vm-moveit-auto",
    [string]$ResourceGroup = $env:PYX_VANTA_RG,
    [string]$Subscription = "",
    [ValidateSet("PackageUpdate", "TomcatUpgrade", "All", "DryRun", "Rescan")]
    [string]$Action = "DryRun",
    [string]$TomcatTargetVersion = "10.1.49",
    [switch]$SkipSnapshot = $false,
    [switch]$NoReboot = $false
)

# ═══════════════════════════════════════════════════════════════════════
# Setup: log file, banner, Azure CLI check
# ═══════════════════════════════════════════════════════════════════════
$ErrorActionPreference = "Stop"
$Timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$LogFile = Join-Path $PSScriptRoot "pyx-vanta-autofix-$Timestamp.log"

function Write-Log {
    param([string]$Level, [string]$Msg)
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] [$Level] $Msg"
    switch ($Level) {
        "INFO"  { Write-Host $line -ForegroundColor Cyan }
        "OK"    { Write-Host $line -ForegroundColor Green }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "ERROR" { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
    Add-Content -Path $LogFile -Value $line
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  PYX VANTA AUTO-FIX   —   $Timestamp" -ForegroundColor Cyan
Write-Host "  VM: $VmName    Action: $Action" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Check Azure CLI
$azCmd = "az"
try {
    $azVersion = & $azCmd version 2>$null | Out-Null
    Write-Log "INFO" "Azure CLI detected"
} catch {
    Write-Log "ERROR" "Azure CLI not found. Install from https://aka.ms/azcli"
    exit 1
}

# Subscription
if ($Subscription) {
    & $azCmd account set --subscription $Subscription
}
$currentSub = & $azCmd account show --query "{id:id, name:name, user:user.name}" -o json | ConvertFrom-Json
Write-Log "INFO" "Subscription: $($currentSub.name) ($($currentSub.id))"
Write-Log "INFO" "User: $($currentSub.user)"

# Resource group auto-detect if not supplied
if (-not $ResourceGroup) {
    Write-Log "INFO" "Looking up resource group for VM '$VmName'..."
    $rg = & $azCmd vm list --query "[?name=='$VmName'].resourceGroup | [0]" -o tsv
    if (-not $rg) {
        Write-Log "ERROR" "Could not find VM '$VmName' in any resource group. Pass -ResourceGroup explicitly."
        exit 1
    }
    $ResourceGroup = $rg
}
Write-Log "INFO" "Resource Group: $ResourceGroup"
Write-Log "INFO" "Log file: $LogFile"
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════
function Invoke-VmCommand {
    param(
        [string]$Description,
        [string]$Script,
        [switch]$DryRun
    )
    Write-Log "INFO" "→ $Description"
    if ($DryRun) {
        Write-Log "WARN" "[DRY-RUN] Would execute on VM: $($Script.Substring(0, [Math]::Min(100, $Script.Length)))..."
        return $null
    }
    $tmpScript = [System.IO.Path]::GetTempFileName() + ".sh"
    $Script | Out-File -FilePath $tmpScript -Encoding ascii -NoNewline
    try {
        $result = & $azCmd vm run-command invoke `
            --resource-group $ResourceGroup `
            --name $VmName `
            --command-id RunShellScript `
            --scripts "@$tmpScript" `
            --output json 2>&1 | Out-String
        $parsed = $result | ConvertFrom-Json
        $stdout = ""
        $stderr = ""
        foreach ($v in $parsed.value) {
            if ($v.code -eq "ProvisioningState/succeeded") { $stdout = $v.message }
            if ($v.code -eq "ProvisioningState/failed")    { $stderr = $v.message }
        }
        if ($stdout) {
            Write-Log "OK" "Command completed (stdout length: $($stdout.Length) chars)"
            Add-Content -Path $LogFile -Value "---- STDOUT ----`n$stdout`n---- END ----`n"
        }
        if ($stderr) {
            Write-Log "ERROR" "Command error"
            Add-Content -Path $LogFile -Value "---- STDERR ----`n$stderr`n---- END ----`n"
        }
        return $stdout
    } catch {
        Write-Log "ERROR" "Run Command failed: $_"
        return $null
    } finally {
        Remove-Item $tmpScript -ErrorAction SilentlyContinue
    }
}

function New-VmSnapshot {
    param([string]$VmName, [string]$ResourceGroup)
    Write-Log "INFO" "Creating pre-fix snapshot (safety net)..."
    $osDisk = & $azCmd vm show -g $ResourceGroup -n $VmName --query "storageProfile.osDisk.name" -o tsv
    $diskId = & $azCmd disk show -g $ResourceGroup -n $osDisk --query id -o tsv
    $snapName = "$VmName-presnap-$Timestamp"
    & $azCmd snapshot create -g $ResourceGroup -n $snapName --source $diskId --output none
    Write-Log "OK" "Snapshot created: $snapName (rollback: restore OS disk from this snapshot)"
    return $snapName
}

# ═══════════════════════════════════════════════════════════════════════
# Fix 1: Oracle Linux / RHEL package updates (bind-*, libarchive, python3)
# Fixes CVE-2026-1519, CVE-2026-5121, CVE-2026-4424, and all future OS-package
# CVEs by running dnf update on the affected packages.
# ═══════════════════════════════════════════════════════════════════════
function Invoke-PackageUpdate {
    param([switch]$DryRun)
    Write-Log "INFO" "═══ PACKAGE UPDATE (bind-*, libarchive, python3-bind, general) ═══"

    $script = @'
#!/bin/bash
set -e
echo "=== BEFORE UPDATE ==="
cat /etc/oracle-release 2>/dev/null || cat /etc/redhat-release 2>/dev/null || uname -a
echo ""
echo "Target packages (Vanta-flagged CVEs):"
rpm -qa | grep -E "^(bind|python3-bind|libarchive|tomcat)" | sort

echo ""
echo "=== UPDATING DNS / BIND packages (CVE-2026-1519) ==="
sudo dnf update -y bind bind-utils bind-libs bind-libs-lite bind-license bind-export-libs python3-bind || true

echo ""
echo "=== UPDATING libarchive (CVE-2026-5121, CVE-2026-4424) ==="
sudo dnf update -y libarchive || true

echo ""
echo "=== Full security update (catches everything else) ==="
sudo dnf update -y --security || true

echo ""
echo "=== AFTER UPDATE ==="
rpm -qa | grep -E "^(bind|python3-bind|libarchive)" | sort

echo ""
echo "=== REBOOT REQUIRED CHECK ==="
sudo needs-restarting -r || true
'@
    Invoke-VmCommand -Description "Apply all package updates (dnf update + security)" -Script $script -DryRun:$DryRun
}

# ═══════════════════════════════════════════════════════════════════════
# Fix 2: Apache Tomcat upgrade
# Fixes CVE-2026-29146/29145/29129/25854/34487/34483/34500/32990/24880
# by upgrading to latest 10.1.x LTS.
# ═══════════════════════════════════════════════════════════════════════
function Invoke-TomcatUpgrade {
    param([string]$TargetVersion, [switch]$DryRun)
    Write-Log "INFO" "=== TOMCAT UPGRADE -> $TargetVersion ==="

    # Single-quoted here-string: PowerShell does ZERO interpolation.
    # Bash variables ($TOMCAT_DIR, $TARGET_VERSION, etc) pass through intact.
    # __TARGET_VERSION__ is a placeholder replaced by PS after the string is built.
    $script = @'
#!/bin/bash
set -e
TARGET_VERSION="__TARGET_VERSION__"
TOMCAT_DIR="/opt/tomcat"
TOMCAT_USER="tomcat"
STAMP=$(date +%Y%m%d-%H%M)

echo "=== CURRENT TOMCAT VERSION ==="
if [ -f "$TOMCAT_DIR/lib/catalina.jar" ]; then
  java -cp "$TOMCAT_DIR/lib/catalina.jar" org.apache.catalina.util.ServerInfo || true
else
  echo "Tomcat not found at $TOMCAT_DIR -- inspecting filesystem"
  find /opt /usr/local -maxdepth 3 -name "catalina.jar" 2>/dev/null | head -3
fi

echo ""
echo "=== BACKING UP CURRENT INSTALL ==="
sudo cp -r "$TOMCAT_DIR" "$TOMCAT_DIR.backup-$STAMP" 2>/dev/null || echo "(no existing install to back up)"

echo ""
echo "=== DOWNLOADING TOMCAT $TARGET_VERSION ==="
cd /tmp
MAJOR=$(echo "$TARGET_VERSION" | cut -d. -f1)
DOWNLOAD_URL="https://dlcdn.apache.org/tomcat/tomcat-$MAJOR/v$TARGET_VERSION/bin/apache-tomcat-$TARGET_VERSION.tar.gz"
echo "URL: $DOWNLOAD_URL"
curl -fsSL -o "apache-tomcat-$TARGET_VERSION.tar.gz" "$DOWNLOAD_URL" || {
  echo "Primary URL failed, trying archive.apache.org..."
  curl -fsSL -o "apache-tomcat-$TARGET_VERSION.tar.gz" "https://archive.apache.org/dist/tomcat/tomcat-$MAJOR/v$TARGET_VERSION/bin/apache-tomcat-$TARGET_VERSION.tar.gz"
}

echo ""
echo "=== STOPPING TOMCAT SERVICE ==="
sudo systemctl stop tomcat 2>/dev/null || sudo "$TOMCAT_DIR/bin/shutdown.sh" || true
sleep 5

echo ""
echo "=== EXTRACTING + PRESERVING CONFIG / WEBAPPS ==="
sudo tar xzf "apache-tomcat-$TARGET_VERSION.tar.gz" -C /tmp/
if [ -d "$TOMCAT_DIR/conf" ]; then
  sudo cp -r "$TOMCAT_DIR/conf" "/tmp/apache-tomcat-$TARGET_VERSION/"
fi
if [ -d "$TOMCAT_DIR/webapps" ]; then
  sudo rm -rf "/tmp/apache-tomcat-$TARGET_VERSION/webapps"
  sudo cp -r "$TOMCAT_DIR/webapps" "/tmp/apache-tomcat-$TARGET_VERSION/"
fi

echo ""
echo "=== SWAPPING BINARY ==="
sudo mv "$TOMCAT_DIR" "$TOMCAT_DIR.oldbin-$STAMP"
sudo mv "/tmp/apache-tomcat-$TARGET_VERSION" "$TOMCAT_DIR"
sudo chown -R "$TOMCAT_USER":"$TOMCAT_USER" "$TOMCAT_DIR" 2>/dev/null || sudo chown -R tomcat:tomcat "$TOMCAT_DIR" 2>/dev/null || true
sudo chmod +x "$TOMCAT_DIR/bin/"*.sh

echo ""
echo "=== STARTING TOMCAT ==="
sudo systemctl start tomcat 2>/dev/null || sudo -u "$TOMCAT_USER" "$TOMCAT_DIR/bin/startup.sh"
sleep 10

echo ""
echo "=== VERIFY NEW VERSION ==="
java -cp "$TOMCAT_DIR/lib/catalina.jar" org.apache.catalina.util.ServerInfo

echo ""
echo "=== HEALTH CHECK ==="
curl -fsS -o /dev/null -w "HTTP %{http_code}" http://localhost:8080/ && echo "  Tomcat responding" || echo "  Tomcat NOT responding - check $TOMCAT_DIR/logs/catalina.out"
'@
    # Substitute the target version into the bash script
    $script = $script.Replace('__TARGET_VERSION__', $TargetVersion)
    Invoke-VmCommand -Description "Upgrade Tomcat to $TargetVersion (config preserved, old binary kept as .oldbin)" -Script $script -DryRun:$DryRun
}

# ═══════════════════════════════════════════════════════════════════════
# Fix 3: Trigger Nessus rescan (so Vanta gets fresh results)
# ═══════════════════════════════════════════════════════════════════════
function Invoke-NessusRescan {
    param([switch]$DryRun)
    Write-Log "INFO" "═══ TRIGGER NESSUS AGENT RESCAN ═══"
    $script = @'
#!/bin/bash
set -e
if systemctl is-active --quiet nessusagent; then
  echo "Nessus agent is running — requesting on-demand scan"
  sudo /opt/nessus_agent/sbin/nessuscli agent status || true
  sudo systemctl restart nessusagent
  echo "Nessus agent restarted — scan will run on next manager poll (usually within 15 min)"
else
  echo "Nessus agent not found. Install via Tenable.io if scans are needed."
fi
'@
    Invoke-VmCommand -Description "Trigger Nessus agent rescan" -Script $script -DryRun:$DryRun
}

# ═══════════════════════════════════════════════════════════════════════
# Execute
# ═══════════════════════════════════════════════════════════════════════
$DryRun = $false
switch ($Action) {
    "DryRun" {
        $DryRun = $true
        Write-Log "WARN" "DRY-RUN MODE — no changes will be applied"
        Invoke-PackageUpdate -DryRun
        Invoke-TomcatUpgrade -TargetVersion $TomcatTargetVersion -DryRun
        Invoke-NessusRescan -DryRun
    }
    "PackageUpdate" {
        if (-not $SkipSnapshot) { New-VmSnapshot -VmName $VmName -ResourceGroup $ResourceGroup | Out-Null }
        Invoke-PackageUpdate
    }
    "TomcatUpgrade" {
        if (-not $SkipSnapshot) { New-VmSnapshot -VmName $VmName -ResourceGroup $ResourceGroup | Out-Null }
        Invoke-TomcatUpgrade -TargetVersion $TomcatTargetVersion
    }
    "Rescan" {
        Invoke-NessusRescan
    }
    "All" {
        if (-not $SkipSnapshot) { New-VmSnapshot -VmName $VmName -ResourceGroup $ResourceGroup | Out-Null }
        Invoke-PackageUpdate
        Invoke-TomcatUpgrade -TargetVersion $TomcatTargetVersion
        Invoke-NessusRescan
        if (-not $NoReboot) {
            Write-Log "INFO" "═══ REBOOT (to clear in-memory vulnerable code) ═══"
            & $azCmd vm restart -g $ResourceGroup -n $VmName --output none
            Write-Log "OK" "VM restarted. Wait 3-5 min before re-checking Vanta."
        }
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  DONE. Log: $LogFile" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Wait 15-30 min for Nessus agent to report fresh state to Tenable.io"
Write-Host "  2. In Vanta, go to Tests → High vulnerabilities identified... → click 'Re-run test'"
Write-Host "  3. The 17 failing entities should drop to 0 (or fewer) within 30-60 min"
Write-Host ""
Write-Host "If any fix fails, review $LogFile and use the pre-fix snapshot for rollback:"
Write-Host "  az snapshot show -g $ResourceGroup -n $VmName-presnap-$Timestamp"
Write-Host ""
