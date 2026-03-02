[CmdletBinding()]
param(
    [string]$Location = "westus",
    [int]$NewQuota = 64
)

Write-Host ""
Write-Host "AZURE QUOTA SUPPORT REQUEST" -ForegroundColor Cyan
Write-Host ""

$acct = az account show 2>$null | ConvertFrom-Json
if (-not $acct) {
    az login
    $acct = az account show | ConvertFrom-Json
}

$subId = $acct.id
$subName = $acct.name
Write-Host "Subscription: $subName" -ForegroundColor Green
Write-Host "Subscription ID: $subId" -ForegroundColor Green
Write-Host ""

Write-Host "Registering Microsoft.Support provider..." -ForegroundColor Yellow
az provider register --namespace Microsoft.Support 2>$null

Write-Host "Creating support ticket for quota increase..." -ForegroundColor Yellow

$ticketName = "QuotaRequest-EDSv4-" + (Get-Date -Format "yyyyMMddHHmmss")

$result = az support tickets create `
    --ticket-name $ticketName `
    --title "URGENT: Increase Standard EDSv4 Family vCPUs quota in West US to 64" `
    --description "We need to increase the Standard EDSv4 Family vCPUs quota from 10 to 64 in West US region. This is required for Databricks SQL Warehouse which is failing to start with QuotaExceeded error. This is blocking production workloads. Please expedite." `
    --problem-classification "/providers/Microsoft.Support/services/06bfd9d3-516b-d5c6-5802-169c800dec89/problemClassifications/e12e3d1d-7fa0-af33-c6d0-3c50df9658a3" `
    --severity "moderate" `
    --contact-first-name "Support" `
    --contact-last-name "Request" `
    --contact-method "email" `
    --contact-email "syed.rizvi@pyxhealth.com" `
    --contact-timezone "Central Standard Time" `
    --contact-country "USA" `
    --contact-language "en-us" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "SUPPORT TICKET CREATED" -ForegroundColor Green
    Write-Host $result
} else {
    Write-Host "Support ticket API failed. Trying direct quota request..." -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "Method 2: Direct quota API..." -ForegroundColor Yellow
    
    az extension add --name quota 2>$null
    
    $quotaResult = az quota create `
        --resource-name "standardEDSv4Family" `
        --scope "/subscriptions/$subId/providers/Microsoft.Compute/locations/$Location" `
        --limit-object value=$NewQuota limit-object-type=LimitValue `
        --resource-type dedicated 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "QUOTA REQUEST SUBMITTED" -ForegroundColor Green
        Write-Host $quotaResult
    } else {
        Write-Host ""
        Write-Host "Opening Azure Portal for manual submission..." -ForegroundColor Yellow
        Start-Process "https://portal.azure.com/#blade/Microsoft_Azure_Support/HelpAndSupportBlade/newsupportrequest"
        
        Write-Host ""
        Write-Host "MANUAL STEPS:" -ForegroundColor Cyan
        Write-Host "1. Issue type: Service and subscription limits (quotas)" -ForegroundColor White
        Write-Host "2. Subscription: $subName" -ForegroundColor White
        Write-Host "3. Quota type: Compute-VM (cores-vCPUs)" -ForegroundColor White
        Write-Host "4. Click Next" -ForegroundColor White
        Write-Host "5. Location: West US" -ForegroundColor White
        Write-Host "6. VM Series: Standard EDSv4 Family" -ForegroundColor White
        Write-Host "7. New limit: 64" -ForegroundColor White
        Write-Host "8. Click Create" -ForegroundColor White
    }
}

Write-Host ""
Write-Host "Checking current quota status..." -ForegroundColor Yellow
az vm list-usage --location $Location --query "[?contains(name.value, 'EDSv4')].{Name:name.localizedValue,Used:currentValue,Limit:limit}" -o table

Write-Host ""
Write-Host "Done" -ForegroundColor Green
