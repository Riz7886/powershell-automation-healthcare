# PYX Vanta Auto-Fix Script

Reusable PowerShell script that fixes the common Vanta test failures on
PYX Azure VMs without opening 17 tickets one at a time.

## When to use
Any Vanta test like:
- "High vulnerabilities identified in packages are addressed (Azure Server)"
- "Critical vulnerabilities identified..."
- OS-package CVEs on Oracle Linux / RHEL VMs
- Apache Tomcat CVEs

## Prerequisites (one-time)
1. Azure CLI installed: https://aka.ms/azcli
2. Logged in: `az login`
3. Contributor role on the target VM (you already have this for PYX)

## Quick start

Open PowerShell in this folder.

### Step 1 — Dry run first (see what would happen, no changes)
```powershell
.\pyx-vanta-autofix.ps1 -Action DryRun
```

### Step 2 — Apply the fix

**Package updates only (safest, covers ~40% of Vanta package CVEs):**
```powershell
.\pyx-vanta-autofix.ps1 -Action PackageUpdate
```

**Tomcat only (covers all Apache Tomcat CVEs):**
```powershell
.\pyx-vanta-autofix.ps1 -Action TomcatUpgrade
```

**Everything + reboot (fastest path to zero failing entities):**
```powershell
.\pyx-vanta-autofix.ps1 -Action All
```

### Step 3 — Re-run Vanta test
1. Wait 15–30 minutes for Nessus agent to report fresh state to Tenable.io
2. Go to Vanta → Tests → the failing test → click **"Re-run test"**
3. Failing entities should drop to 0

## What it actually does

### 1. PackageUpdate action
Runs on the VM via `az vm run-command invoke`:
- `dnf update -y bind bind-utils bind-libs bind-libs-lite bind-license bind-export-libs python3-bind`
- `dnf update -y libarchive`
- `dnf update -y --security` (catches everything else Nessus might flag)
- Shows before/after package versions
- Reports whether a reboot is required (`needs-restarting -r`)

### 2. TomcatUpgrade action
- Downloads latest Tomcat 10.1.x from dlcdn.apache.org (fallback: archive.apache.org)
- Backs up current install to `/opt/tomcat.backup-YYYYMMDD-HHMM`
- Stops the service
- Extracts new binary, preserves your `conf/` and `webapps/`
- Starts the service, verifies version + HTTP 200 on localhost

### 3. Rescan action
- Restarts the Nessus agent so it re-reports the now-patched state
- Optional; can also wait for the next scheduled scan (typically 24h)

### 4. All action
- Creates a **pre-fix snapshot** of the OS disk (rollback safety net)
- PackageUpdate
- TomcatUpgrade
- Nessus rescan trigger
- Reboots the VM

## Rollback (if something goes wrong)

Every run creates a snapshot named `{vmname}-presnap-{timestamp}` in the same
resource group. To restore:

```powershell
# Create a new disk from the snapshot
az disk create -g rg-pyx-prod -n vm-moveit-auto-restored --source vm-moveit-auto-presnap-20260419-2130

# Stop the VM
az vm stop -g rg-pyx-prod -n vm-moveit-auto

# Swap the OS disk
az vm update -g rg-pyx-prod -n vm-moveit-auto --os-disk vm-moveit-auto-restored

# Start it
az vm start -g rg-pyx-prod -n vm-moveit-auto
```

Or use Azure Portal → VM → Disks → Swap OS Disk.

## Logs
Every run writes to `pyx-vanta-autofix-YYYYMMDD-HHMM.log` in the script folder.
Contains full stdout/stderr of every Run Command, timestamps, and which
snapshots were created.

## Customization

### Default VM name
Edit line ~33 of the script, or pass `-VmName`:
```powershell
.\pyx-vanta-autofix.ps1 -VmName vm-production-app-01 -Action PackageUpdate
```

### Default resource group
Set an environment variable once:
```powershell
[System.Environment]::SetEnvironmentVariable("PYX_VANTA_RG", "rg-pyx-prod", "User")
```

### Tomcat target version
Check the current latest at https://tomcat.apache.org/download-10.cgi and pass:
```powershell
.\pyx-vanta-autofix.ps1 -Action TomcatUpgrade -TomcatTargetVersion 10.1.50
```

## Handling new Vanta findings over time

When Nessus surfaces new CVEs:

| Finding type | Fix | Action |
|---|---|---|
| Any OS package CVE (bind/libarchive/openssl/curl/etc.) | `dnf update` catches it | `-Action PackageUpdate` |
| Apache Tomcat CVE | Version upgrade | `-Action TomcatUpgrade` |
| nginx / apache httpd | Add to PackageUpdate | Script already covers via `--security` flag |
| Java / JRE CVE | Add a Java update step | Extend the script (add JavaUpgrade function) |

The script is structured so new fix types (Java, nginx, custom app) are
easy to add as additional functions alongside `Invoke-PackageUpdate`.
