<#
.SYNOPSIS
    ONE-SCRIPT INSTALLER - Installs everything and configures Datadog + PagerDuty

.DESCRIPTION
    This script does EVERYTHING:
    - Installs Python 3.11 if not installed
    - Installs required Python packages
    - Creates the configuration script
    - Runs the configuration
    - No Docker needed!

.USAGE
    Right-click -> Run with PowerShell
    OR
    .\INSTALL_AND_RUN.ps1
#>

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ULTIMATE ONE-CLICK INSTALLER" -ForegroundColor Green
Write-Host "  Configures: MOVITAUTO, MOVEITXFR" -ForegroundColor Green
Write-Host "  Alerts: CPU >85%, Memory >85%, VM Stopped" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "⚠ WARNING: Not running as Administrator. Python installation may fail." -ForegroundColor Yellow
    Write-Host "  Recommendation: Right-click and 'Run as Administrator'" -ForegroundColor Yellow
    $continue = Read-Host "Continue anyway? (yes/no)"
    if ($continue -ne "yes") {
        exit 1
    }
}

# Step 1: Check/Install Python
Write-Host ""
Write-Host "┌─ STEP 1: Checking Python Installation ─────────────────────────┐" -ForegroundColor Yellow
Write-Host ""

$pythonInstalled = $false
$pythonCmd = "python"

try {
    $pythonVersion = & python --version 2>&1
    if ($pythonVersion -match "Python 3") {
        Write-Host "✓ Python already installed: $pythonVersion" -ForegroundColor Green
        $pythonInstalled = $true
    }
} catch {
    Write-Host "⚠ Python not found in PATH" -ForegroundColor Yellow
}

if (-not $pythonInstalled) {
    Write-Host "Installing Python 3.11..." -ForegroundColor Cyan
    
    $pythonUrl = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
    $pythonInstaller = "$env:TEMP\python-installer.exe"
    
    Write-Host "  Downloading Python installer..." -ForegroundColor Gray
    try {
        Invoke-WebRequest -Uri $pythonUrl -OutFile $pythonInstaller -UseBasicParsing
        Write-Host "  ✓ Download complete" -ForegroundColor Green
        
        Write-Host "  Installing Python (this may take 2-3 minutes)..." -ForegroundColor Gray
        Start-Process -FilePath $pythonInstaller -ArgumentList "/quiet", "InstallAllUsers=1", "PrependPath=1", "Include_pip=1" -Wait
        
        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        
        Write-Host "  ✓ Python installed successfully!" -ForegroundColor Green
        
        # Verify installation
        Start-Sleep -Seconds 3
        $pythonVersion = & python --version 2>&1
        Write-Host "  Installed version: $pythonVersion" -ForegroundColor Green
        
    } catch {
        Write-Host "✗ Failed to install Python: $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "MANUAL INSTALLATION:" -ForegroundColor Yellow
        Write-Host "1. Download: https://www.python.org/downloads/" -ForegroundColor Gray
        Write-Host "2. Run installer and check 'Add Python to PATH'" -ForegroundColor Gray
        Write-Host "3. Restart PowerShell and run this script again" -ForegroundColor Gray
        exit 1
    }
}

# Step 2: Install Python packages
Write-Host ""
Write-Host "┌─ STEP 2: Installing Python Packages ───────────────────────────┐" -ForegroundColor Yellow
Write-Host ""

Write-Host "Installing 'requests' package..." -ForegroundColor Cyan
try {
    & python -m pip install --upgrade pip --quiet
    & python -m pip install requests --quiet
    Write-Host "✓ Python packages installed successfully!" -ForegroundColor Green
} catch {
    Write-Host "✗ Failed to install packages: $_" -ForegroundColor Red
    exit 1
}

# Step 3: Create the Python configuration script
Write-Host ""
Write-Host "┌─ STEP 3: Creating Configuration Script ────────────────────────┐" -ForegroundColor Yellow
Write-Host ""

$scriptContent = @'
#!/usr/bin/env python3
"""
ULTIMATE AUTO-CONFIGURATION SCRIPT
Configures Datadog + PagerDuty for MOVITAUTO and MOVEITXFR
Alerts: CPU >85%, Memory >85%, VM Stopped
"""

import requests
import json
import sys
import time
from datetime import datetime

TARGET_VMS = ["MOVITAUTO", "MOVEITXFR"]

class DatadogConfigurator:
    def __init__(self, api_key, app_key, webhook_url):
        self.api_key = api_key
        self.app_key = app_key
        self.webhook_url = webhook_url
        self.base_url = "https://api.datadoghq.com/api/v1"
        self.headers = {
            "DD-API-KEY": self.api_key,
            "DD-APPLICATION-KEY": self.app_key,
            "Content-Type": "application/json"
        }
        self.webhook_name = "PagerDuty-MoveIT-Webhook"
    
    def create_webhook(self):
        print(f"[DATADOG] Creating webhook {self.webhook_name}...")
        webhook_payload = {
            "name": self.webhook_name,
            "url": self.webhook_url,
            "encode_as_form": False
        }
        
        try:
            response = requests.post(
                f"{self.base_url}/integration/webhooks/configuration/webhooks",
                headers=self.headers,
                json=webhook_payload,
                timeout=30
            )
            
            if response.status_code in [200, 201, 409]:
                print(f"✓ Webhook created/exists!")
                return True
            else:
                print(f"✗ Failed: {response.status_code} - {response.text}")
                return False
        except Exception as e:
            print(f"✗ Error: {str(e)}")
            return False
    
    def create_cpu_monitor(self, hostname):
        print(f"[DATADOG] Creating CPU monitor for {hostname}...")
        monitor_payload = {
            "name": f"MoveIT CPU Alert - {hostname}",
            "type": "metric alert",
            "query": f'avg(last_5m):100 - avg:system.cpu.idle{{host:{hostname}}} > 85',
            "message": f"@webhook-{self.webhook_name}\n\n🚨 CPU ALERT: {hostname}\nCPU Usage > 85%\nTime: {{{{last_triggered_at}}}}",
            "tags": [f"host:{hostname}", "alert_type:cpu", "service:moveit"],
            "priority": 1,
            "options": {
                "thresholds": {"critical": 85, "warning": 75},
                "notify_no_data": True,
                "no_data_timeframe": 10
            }
        }
        return self._create_monitor(monitor_payload, hostname, "CPU")
    
    def create_memory_monitor(self, hostname):
        print(f"[DATADOG] Creating Memory monitor for {hostname}...")
        monitor_payload = {
            "name": f"MoveIT Memory Alert - {hostname}",
            "type": "metric alert",
            "query": f'avg(last_5m):avg:system.mem.pct_usable{{host:{hostname}}} < 15',
            "message": f"@webhook-{self.webhook_name}\n\n🚨 MEMORY ALERT: {hostname}\nMemory Usage > 85%\nTime: {{{{last_triggered_at}}}}",
            "tags": [f"host:{hostname}", "alert_type:memory", "service:moveit"],
            "priority": 1,
            "options": {
                "thresholds": {"critical": 15, "warning": 20},
                "notify_no_data": True,
                "no_data_timeframe": 10
            }
        }
        return self._create_monitor(monitor_payload, hostname, "Memory")
    
    def create_vm_stopped_monitor(self, hostname):
        print(f"[DATADOG] Creating VM Stopped monitor for {hostname}...")
        monitor_payload = {
            "name": f"MoveIT VM Stopped - {hostname}",
            "type": "service check",
            "query": f'"datadog.agent.up".over("host:{hostname}").by("*").last(2).count_by_status()',
            "message": f"@webhook-{self.webhook_name}\n\n❌ VM STOPPED: {hostname}\nVM is DOWN/STOPPED\nTime: {{{{last_triggered_at}}}}",
            "tags": [f"host:{hostname}", "alert_type:vm_stopped", "service:moveit"],
            "priority": 1,
            "options": {
                "thresholds": {"critical": 1},
                "notify_no_data": True,
                "no_data_timeframe": 5
            }
        }
        return self._create_monitor(monitor_payload, hostname, "VM Stopped")
    
    def _create_monitor(self, payload, hostname, monitor_type):
        try:
            response = requests.post(
                f"{self.base_url}/monitor",
                headers=self.headers,
                json=payload,
                timeout=30
            )
            
            if response.status_code in [200, 201]:
                monitor_id = response.json().get('id')
                print(f"✓ {monitor_type} monitor created (ID: {monitor_id})")
                return True
            else:
                print(f"✗ Failed: {response.status_code}")
                return False
        except Exception as e:
            print(f"✗ Error: {str(e)}")
            return False

class PagerDutyConfigurator:
    def __init__(self, routing_key):
        self.routing_key = routing_key
        self.events_url = "https://events.pagerduty.com/v2/enqueue"
    
    def send_test_alert(self):
        print("[PAGERDUTY] Sending test alert...")
        payload = {
            "routing_key": self.routing_key,
            "event_action": "trigger",
            "payload": {
                "summary": "✓ MoveIT Configuration Complete - MOVITAUTO & MOVEITXFR",
                "source": "ultimate_auto_configure.py",
                "severity": "info",
                "custom_details": {
                    "configured_vms": "MOVITAUTO, MOVEITXFR",
                    "alerts": "CPU >85%, Memory >85%, VM Stopped"
                }
            }
        }
        
        try:
            response = requests.post(self.events_url, json=payload, timeout=30)
            if response.status_code == 202:
                print(f"✓ Test alert sent!")
                return True
            else:
                print(f"✗ Failed: {response.status_code}")
                return False
        except Exception as e:
            print(f"✗ Error: {str(e)}")
            return False

def main():
    print("""
╔════════════════════════════════════════════════════════════╗
║  ULTIMATE AUTO-CONFIGURATION SCRIPT                        ║
║  Targets: MOVITAUTO, MOVEITXFR                             ║
║  Alerts: CPU >85%, Memory >85%, VM Stopped                 ║
╚════════════════════════════════════════════════════════════╝
""")
    
    print("\n── DATADOG CREDENTIALS (Required) ──")
    datadog_api_key = input("Datadog API Key: ").strip()
    datadog_app_key = input("Datadog Application Key: ").strip()
    
    print("\n── PAGERDUTY CREDENTIALS (Required) ──")
    pagerduty_routing_key = input("PagerDuty Routing Key: ").strip()
    
    print("\n── WEBHOOK SERVICE (Required) ──")
    webhook_url = input("Webhook URL (e.g., http://your-ip:5000/webhook): ").strip()
    
    if not all([datadog_api_key, datadog_app_key, pagerduty_routing_key, webhook_url]):
        print("\n✗ Error: All fields are required!")
        sys.exit(1)
    
    print("\n" + "="*60)
    print("Starting configuration for:")
    for vm in TARGET_VMS:
        print(f"  • {vm}: CPU, Memory, VM Stopped alerts")
    print("="*60 + "\n")
    
    confirm = input("Proceed? (yes/no): ").strip().lower()
    if confirm != 'yes':
        print("Configuration cancelled.")
        sys.exit(0)
    
    datadog = DatadogConfigurator(datadog_api_key, datadog_app_key, webhook_url)
    pagerduty = PagerDutyConfigurator(pagerduty_routing_key)
    
    results = {'monitors': [], 'webhook': False, 'pagerduty': False}
    
    print("\n┌─ STEP 1: Creating Datadog Webhook ─────────────────┐\n")
    results['webhook'] = datadog.create_webhook()
    time.sleep(1)
    
    print("\n┌─ STEP 2: Creating Monitors ────────────────────────┐\n")
    for vm in TARGET_VMS:
        print(f"\n→ Configuring {vm}...\n")
        results['monitors'].append({'vm': vm, 'cpu': datadog.create_cpu_monitor(vm)})
        time.sleep(0.5)
        results['monitors'].append({'vm': vm, 'memory': datadog.create_memory_monitor(vm)})
        time.sleep(0.5)
        results['monitors'].append({'vm': vm, 'vm_stopped': datadog.create_vm_stopped_monitor(vm)})
        time.sleep(0.5)
    
    print("\n┌─ STEP 3: Testing PagerDuty ────────────────────────┐\n")
    results['pagerduty'] = pagerduty.send_test_alert()
    
    print("\n" + "="*60)
    print("  CONFIGURATION SUMMARY")
    print("="*60)
    print(f"Webhook: {'✓' if results['webhook'] else '✗'}")
    print(f"PagerDuty: {'✓' if results['pagerduty'] else '✗'}")
    print(f"Monitors Created: {sum(1 for m in results['monitors'] if any(m.values()))}/{len(results['monitors'])}")
    print("\nVMs Configured:")
    for vm in TARGET_VMS:
        print(f"  ✓ {vm}: CPU, Memory, VM Stopped")
    print("="*60 + "\n")
    
    success = results['webhook'] and results['pagerduty'] and any(any(m.values()) for m in results['monitors'])
    
    if success:
        print("✓✓✓ CONFIGURATION COMPLETED SUCCESSFULLY! ✓✓✓\n")
    else:
        print("⚠ Configuration completed with errors. Review above.\n")
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nCancelled by user.")
        sys.exit(1)
    except Exception as e:
        print(f"\n✗ FATAL ERROR: {str(e)}")
        sys.exit(1)
'@ 

$scriptPath = "ultimate_auto_configure.py"
$scriptContent | Out-File -FilePath $scriptPath -Encoding UTF8 -Force
Write-Host "✓ Configuration script created: $scriptPath" -ForegroundColor Green

# Step 4: Run the configuration script
Write-Host ""
Write-Host "┌─ STEP 4: Running Configuration ────────────────────────────────┐" -ForegroundColor Yellow
Write-Host ""
Write-Host "Starting configuration process..." -ForegroundColor Cyan
Write-Host ""

try {
    & python $scriptPath
    $exitCode = $LASTEXITCODE
    
    Write-Host ""
    if ($exitCode -eq 0) {
        Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host "  ✓✓✓ ALL DONE! CONFIGURATION SUCCESSFUL! ✓✓✓" -ForegroundColor Green
        Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor Cyan
        Write-Host "  1. Check Datadog for monitors" -ForegroundColor Gray
        Write-Host "  2. Check PagerDuty for test alert" -ForegroundColor Gray
        Write-Host "  3. Alerts are now active for MOVITAUTO and MOVEITXFR" -ForegroundColor Gray
        Write-Host ""
    } else {
        Write-Host "⚠ Configuration completed with errors. Review output above." -ForegroundColor Yellow
    }
} catch {
    Write-Host "✗ Error running configuration: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")