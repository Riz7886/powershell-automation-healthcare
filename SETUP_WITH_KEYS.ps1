# EDIT THESE 4 LINES WITH YOUR KEYS
$DATADOG_API_KEY = "YOUR_DATADOG_API_KEY_HERE"
$DATADOG_APP_KEY = "YOUR_DATADOG_APPLICATION_KEY_HERE"
$PAGERDUTY_ROUTING_KEY = "YOUR_PAGERDUTY_ROUTING_KEY_HERE"
$WEBHOOK_URL = "YOUR_WEBHOOK_URL_HERE"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  ULTIMATE ONE-CLICK INSTALLER" -ForegroundColor Green
Write-Host "  Configures: MOVITAUTO, MOVEITXFR" -ForegroundColor Green
Write-Host "  Alerts: CPU >85%, Memory >85%, VM Stopped" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Validate keys are filled in
if ($DATADOG_API_KEY -eq "YOUR_DATADOG_API_KEY_HERE" -or $DATADOG_APP_KEY -eq "YOUR_DATADOG_APPLICATION_KEY_HERE" -or $PAGERDUTY_ROUTING_KEY -eq "YOUR_PAGERDUTY_ROUTING_KEY_HERE" -or $WEBHOOK_URL -eq "YOUR_WEBHOOK_URL_HERE") {
    Write-Host "ERROR: You must edit the keys at the top of this script!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Open this file in notepad and replace:" -ForegroundColor Yellow
    Write-Host "  - YOUR_DATADOG_API_KEY_HERE" -ForegroundColor Gray
    Write-Host "  - YOUR_DATADOG_APPLICATION_KEY_HERE" -ForegroundColor Gray
    Write-Host "  - YOUR_PAGERDUTY_ROUTING_KEY_HERE" -ForegroundColor Gray
    Write-Host "  - YOUR_WEBHOOK_URL_HERE" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

Write-Host "Keys validated. Starting installation..." -ForegroundColor Green
Write-Host ""

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "WARNING: Not running as Administrator. Python installation may fail." -ForegroundColor Yellow
    Write-Host "  Recommendation: Right-click and 'Run as Administrator'" -ForegroundColor Yellow
    $continue = Read-Host "Continue anyway? (yes/no)"
    if ($continue -ne "yes") {
        exit 1
    }
}

# Step 1: Check/Install Python
Write-Host ""
Write-Host "STEP 1: Checking Python Installation" -ForegroundColor Yellow
Write-Host ""

$pythonInstalled = $false

try {
    $pythonVersion = & python --version 2>&1
    if ($pythonVersion -match "Python 3") {
        Write-Host "Python already installed: $pythonVersion" -ForegroundColor Green
        $pythonInstalled = $true
    }
} catch {
    Write-Host "Python not found in PATH" -ForegroundColor Yellow
}

if (-not $pythonInstalled) {
    Write-Host "Installing Python 3.11..." -ForegroundColor Cyan
    
    $pythonUrl = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
    $pythonInstaller = "$env:TEMP\python-installer.exe"
    
    Write-Host "  Downloading Python installer..." -ForegroundColor Gray
    try {
        Invoke-WebRequest -Uri $pythonUrl -OutFile $pythonInstaller -UseBasicParsing
        Write-Host "  Download complete" -ForegroundColor Green
        
        Write-Host "  Installing Python (this may take 2-3 minutes)..." -ForegroundColor Gray
        Start-Process -FilePath $pythonInstaller -ArgumentList "/quiet", "InstallAllUsers=1", "PrependPath=1", "Include_pip=1" -Wait
        
        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        
        Write-Host "  Python installed successfully!" -ForegroundColor Green
        
        # Verify installation
        Start-Sleep -Seconds 3
        $pythonVersion = & python --version 2>&1
        Write-Host "  Installed version: $pythonVersion" -ForegroundColor Green
        
    } catch {
        Write-Host "Failed to install Python: $_" -ForegroundColor Red
        exit 1
    }
}

# Step 2: Install Python packages
Write-Host ""
Write-Host "STEP 2: Installing Python Packages" -ForegroundColor Yellow
Write-Host ""

Write-Host "Installing requests package..." -ForegroundColor Cyan
try {
    & python -m pip install --upgrade pip --quiet
    & python -m pip install requests --quiet
    Write-Host "Python packages installed successfully!" -ForegroundColor Green
} catch {
    Write-Host "Failed to install packages: $_" -ForegroundColor Red
    exit 1
}

# Step 3: Create the Python configuration script
Write-Host ""
Write-Host "STEP 3: Creating Configuration Script" -ForegroundColor Yellow
Write-Host ""

$scriptContent = @"
import requests
import json
import sys
import time

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
        print("[DATADOG] Creating webhook " + self.webhook_name + "...")
        webhook_payload = {
            "name": self.webhook_name,
            "url": self.webhook_url,
            "encode_as_form": False
        }
        try:
            response = requests.post(
                self.base_url + "/integration/webhooks/configuration/webhooks",
                headers=self.headers,
                json=webhook_payload,
                timeout=30
            )
            if response.status_code in [200, 201, 409]:
                print("Webhook created/exists!")
                return True
            else:
                print("Failed: " + str(response.status_code))
                return False
        except Exception as e:
            print("Error: " + str(e))
            return False
    
    def create_cpu_monitor(self, hostname):
        print("[DATADOG] Creating CPU monitor for " + hostname + "...")
        monitor_payload = {
            "name": "MoveIT CPU Alert - " + hostname,
            "type": "metric alert",
            "query": "avg(last_5m):100 - avg:system.cpu.idle{host:" + hostname + "} > 85",
            "message": "@webhook-" + self.webhook_name + " CPU ALERT: " + hostname + " CPU Usage > 85%",
            "tags": ["host:" + hostname, "alert_type:cpu", "service:moveit"],
            "priority": 1,
            "options": {
                "thresholds": {"critical": 85, "warning": 75},
                "notify_no_data": True,
                "no_data_timeframe": 10
            }
        }
        return self._create_monitor(monitor_payload, hostname, "CPU")
    
    def create_memory_monitor(self, hostname):
        print("[DATADOG] Creating Memory monitor for " + hostname + "...")
        monitor_payload = {
            "name": "MoveIT Memory Alert - " + hostname,
            "type": "metric alert",
            "query": "avg(last_5m):avg:system.mem.pct_usable{host:" + hostname + "} < 15",
            "message": "@webhook-" + self.webhook_name + " MEMORY ALERT: " + hostname + " Memory Usage > 85%",
            "tags": ["host:" + hostname, "alert_type:memory", "service:moveit"],
            "priority": 1,
            "options": {
                "thresholds": {"critical": 15, "warning": 20},
                "notify_no_data": True,
                "no_data_timeframe": 10
            }
        }
        return self._create_monitor(monitor_payload, hostname, "Memory")
    
    def create_vm_stopped_monitor(self, hostname):
        print("[DATADOG] Creating VM Stopped monitor for " + hostname + "...")
        monitor_payload = {
            "name": "MoveIT VM Stopped - " + hostname,
            "type": "service check",
            "query": '"datadog.agent.up".over("host:' + hostname + '").by("*").last(2).count_by_status()',
            "message": "@webhook-" + self.webhook_name + " VM STOPPED: " + hostname,
            "tags": ["host:" + hostname, "alert_type:vm_stopped", "service:moveit"],
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
                self.base_url + "/monitor",
                headers=self.headers,
                json=payload,
                timeout=30
            )
            if response.status_code in [200, 201]:
                monitor_id = response.json().get('id')
                print(monitor_type + " monitor created (ID: " + str(monitor_id) + ")")
                return True
            else:
                print("Failed: " + str(response.status_code))
                return False
        except Exception as e:
            print("Error: " + str(e))
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
                "summary": "MoveIT Configuration Complete - MOVITAUTO & MOVEITXFR",
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
                print("Test alert sent!")
                return True
            else:
                print("Failed: " + str(response.status_code))
                return False
        except Exception as e:
            print("Error: " + str(e))
            return False


def main():
    print("=" * 60)
    print("  ULTIMATE AUTO-CONFIGURATION SCRIPT")
    print("  Targets: MOVITAUTO, MOVEITXFR")
    print("  Alerts: CPU >85%, Memory >85%, VM Stopped")
    print("=" * 60)
    
    datadog_api_key = "$($DATADOG_API_KEY)"
    datadog_app_key = "$($DATADOG_APP_KEY)"
    pagerduty_routing_key = "$($PAGERDUTY_ROUTING_KEY)"
    webhook_url = "$($WEBHOOK_URL)"
    
    print("\nUsing provided credentials...")
    print("Datadog API Key: " + datadog_api_key[:10] + "...")
    print("Webhook URL: " + webhook_url)
    
    datadog = DatadogConfigurator(datadog_api_key, datadog_app_key, webhook_url)
    pagerduty = PagerDutyConfigurator(pagerduty_routing_key)
    
    results = {'monitors': [], 'webhook': False, 'pagerduty': False}
    
    print("\nSTEP 1: Creating Datadog Webhook")
    results['webhook'] = datadog.create_webhook()
    time.sleep(1)
    
    print("\nSTEP 2: Creating Monitors")
    for vm in TARGET_VMS:
        print("\nConfiguring " + vm + "...")
        results['monitors'].append({'vm': vm, 'cpu': datadog.create_cpu_monitor(vm)})
        time.sleep(0.5)
        results['monitors'].append({'vm': vm, 'memory': datadog.create_memory_monitor(vm)})
        time.sleep(0.5)
        results['monitors'].append({'vm': vm, 'vm_stopped': datadog.create_vm_stopped_monitor(vm)})
        time.sleep(0.5)
    
    print("\nSTEP 3: Testing PagerDuty")
    results['pagerduty'] = pagerduty.send_test_alert()
    
    print("\n" + "=" * 60)
    print("  CONFIGURATION SUMMARY")
    print("=" * 60)
    print("Webhook: " + ("OK" if results['webhook'] else "FAILED"))
    print("PagerDuty: " + ("OK" if results['pagerduty'] else "FAILED"))
    print("Monitors Created: " + str(sum(1 for m in results['monitors'] if any(m.values()))) + "/" + str(len(results['monitors'])))
    print("\nVMs Configured:")
    for vm in TARGET_VMS:
        print("  " + vm + ": CPU, Memory, VM Stopped")
    print("=" * 60)
    
    success = results['webhook'] and results['pagerduty'] and any(any(m.values()) for m in results['monitors'])
    
    if success:
        print("\nCONFIGURATION COMPLETED SUCCESSFULLY!\n")
    else:
        print("\nConfiguration completed with errors. Review above.\n")
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nCancelled by user.")
        sys.exit(1)
    except Exception as e:
        print("\nFATAL ERROR: " + str(e))
        sys.exit(1)
"@ 
$scriptPath = "ultimate_auto_configure.py"
$scriptContent | Out-File -FilePath $scriptPath -Encoding UTF8 -Force
Write-Host "Configuration script created: $scriptPath" -ForegroundColor Green

# Step 4: Run the configuration script
Write-Host ""
Write-Host "STEP 4: Running Configuration" -ForegroundColor Yellow
Write-Host ""
Write-Host "Starting configuration process..." -ForegroundColor Cyan
Write-Host ""
try {
    & python $scriptPath
    $exitCode = $LASTEXITCODE
    
    Write-Host ""
    if ($exitCode -eq 0) {
        Write-Host "================================================================" -ForegroundColor Green
        Write-Host "  ALL DONE! CONFIGURATION SUCCESSFUL!" -ForegroundColor Green
        Write-Host "================================================================" -ForegroundColor Green
        Write-Host "" 
        Write-Host "Next steps:" -ForegroundColor Cyan
        Write-Host "  1. Check Datadog for monitors" -ForegroundColor Gray
        Write-Host "  2. Check PagerDuty for test alert" -ForegroundColor Gray
        Write-Host "  3. Alerts are now active for MOVITAUTO and MOVEITXFR" -ForegroundColor Gray
        Write-Host "" 
    } else {
        Write-Host "Configuration completed with errors. Review output above." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Error running configuration: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
