$DATADOG_API_KEY = "YOUR_DATADOG_API_KEY_HERE"
$DATADOG_APP_KEY = "YOUR_DATADOG_APPLICATION_KEY_HERE"

if ($DATADOG_API_KEY -eq "YOUR_DATADOG_API_KEY_HERE" -or $DATADOG_APP_KEY -eq "YOUR_DATADOG_APPLICATION_KEY_HERE") {
    Write-Host "ERROR: Please configure API keys at the top of this script."
    exit 1
}

Write-Host "Updating Monitor Hostnames"
Write-Host "Changing: MOVITAUTO -> vm-moveit-auto"
Write-Host "Changing: MOVEITXFR -> vm-moveit-xfr"
Write-Host ""

$scriptContent = @"
import requests
import json
import sys

api_key = "$DATADOG_API_KEY"
app_key = "$DATADOG_APP_KEY"
base_url = "https://api.us3.datadoghq.com/api/v1"

headers = {
    "DD-API-KEY": api_key,
    "DD-APPLICATION-KEY": app_key,
    "Content-Type": "application/json"
}

print("Fetching all monitors...")
response = requests.get(base_url + "/monitor", headers=headers)
monitors = response.json()

updated_count = 0
for monitor in monitors:
    if "MoveIT" in monitor.get("name", ""):
        monitor_id = monitor["id"]
        name = monitor["name"]
        query = monitor["query"]
        message = monitor["message"]
        
        original_query = query
        original_message = message
        
        query = query.replace("MOVITAUTO", "vm-moveit-auto")
        query = query.replace("MOVEITXFR", "vm-moveit-xfr")
        message = message.replace("MOVITAUTO", "vm-moveit-auto")
        message = message.replace("MOVEITXFR", "vm-moveit-xfr")
        name = name.replace("MOVITAUTO", "vm-moveit-auto")
        name = name.replace("MOVEITXFR", "vm-moveit-xfr")
        
        if query != original_query or message != original_message:
            print(f"Updating monitor {monitor_id}: {name}")
            
            update_payload = {
                "name": name,
                "query": query,
                "message": message,
                "tags": monitor.get("tags", []),
                "options": monitor.get("options", {})
            }
            
            update_response = requests.put(
                base_url + f"/monitor/{monitor_id}",
                headers=headers,
                json=update_payload
            )
            
            if update_response.status_code == 200:
                print(f"  Updated successfully")
                updated_count += 1
            else:
                print(f"  Failed: {update_response.status_code}")
                print(f"  {update_response.text}")

print(f"\nUpdated {updated_count} monitors")
"@

$pythonScript = "update_monitors.py"
$scriptContent | Out-File -FilePath $pythonScript -Encoding UTF8 -Force

python $pythonScript
$exitCode = $LASTEXITCODE

Remove-Item $pythonScript -Force

if ($exitCode -eq 0) {
    Write-Host ""
    Write-Host "Monitor update complete!"
    Write-Host "Monitors are now configured for vm-moveit-auto and vm-moveit-xfr"
} else {
    Write-Host ""
    Write-Host "Update failed. Check output above."
}