[CmdletBinding()]
param(
    [string]$Location = "westus",
    [int]$NewQuota = 64
)

Write-Host ""
Write-Host "DATABRICKS QUOTA FIX - EDSv4 FAMILY" -ForegroundColor Cyan
Write-Host ""
Write-Host "Location: $Location" -ForegroundColor White
Write-Host "VM Family: standardEDSv4Family" -ForegroundColor White
Write-Host "New Quota: $NewQuota vCPUs" -ForegroundColor White
Write-Host ""

$acctRaw = az account show 2>$null
if (-not $acctRaw) {
    Write-Host "Not logged in. Running az login..." -ForegroundColor Yellow
    az login
    $acctRaw = az account show 2>$null
}

$acct = $acctRaw | ConvertFrom-Json
Write-Host "Logged in as: $($acct.user.name)" -ForegroundColor Green
Write-Host "Subscription: $($acct.name)" -ForegroundColor Green
$subId = $acct.id
Write-Host ""

Write-Host "Current quota..." -ForegroundColor Yellow
az vm list-usage --location $Location --query "[?contains(name.value, 'standardEDSv4Family')].{Name:name.localizedValue,Limit:limit,Used:currentValue}" -o table

Write-Host ""
Write-Host "Submitting quota increase request..." -ForegroundColor Yellow

az provider register --namespace Microsoft.Quota 2>$null

$body = @"
{
  "properties": {
    "limit": {
      "limitObjectType": "LimitValue",
      "value": $NewQuota
    },
    "name": {
      "value": "standardEDSv4Family"
    }
  }
}
"@

$tempFile = "$env:TEMP\quota-request.json"
$body | Out-File -FilePath $tempFile -Encoding ASCII -Force

$url = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Compute/locations/$Location/quotas/standardEDSv4Family?api-version=2023-02-01"

Write-Host "Calling Azure REST API..." -ForegroundColor Yellow
$result = az rest --method put --url $url --body "@$tempFile" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "REQUEST SUBMITTED SUCCESSFULLY" -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "API Response: $result" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "If auto-approval failed, open portal manually:" -ForegroundColor Yellow
    Write-Host "https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" -ForegroundColor Cyan
    Write-Host ""
}

Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

Write-Host "Waiting 10 seconds..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

Write-Host ""
Write-Host "FINAL STATUS:" -ForegroundColor Cyan
az vm list-usage --location $Location --query "[?contains(name.value, 'standardEDSv4Family')].{Name:name.localizedValue,Limit:limit,Used:currentValue}" -o table

Write-Host ""
Write-Host "If quota is now 64+, go restart the Databricks SQL Warehouse" -ForegroundColor Green
Write-Host "Done" -ForegroundColor Green
