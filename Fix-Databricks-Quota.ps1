$ErrorActionPreference = "Continue"
$ts = Get-Date -Format "yyyyMMdd_HHmmss"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Red
Write-Host "  DATABRICKS QUOTA FIX - EDSv4 FAMILY" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""

$location = "westus"
$vmFamily = "standardEDSv4Family"
$newQuota = 64

Write-Host "Location: $location" -ForegroundColor Cyan
Write-Host "VM Family: $vmFamily" -ForegroundColor Cyan
Write-Host "New Quota: $newQuota vCPUs" -ForegroundColor Cyan
Write-Host ""

Write-Host "Checking Azure login..." -ForegroundColor Yellow
$acctRaw = az account show 2>$null
if (-not $acctRaw) {
    Write-Host "Not logged in. Running az login..." -ForegroundColor Yellow
    az login
    $acctRaw = az account show 2>$null
}

$acct = $acctRaw | ConvertFrom-Json
Write-Host "Logged in as: $($acct.user.name)" -ForegroundColor Green
Write-Host "Subscription: $($acct.name)" -ForegroundColor Green
Write-Host ""

$subId = $acct.id

Write-Host "Checking current quota..." -ForegroundColor Yellow
$currentRaw = az vm list-usage --location $location --query "[?contains(name.value, 'standardEDSv4Family')]" -o json 2>$null
if ($currentRaw) {
    $current = $currentRaw | ConvertFrom-Json
    if ($current.Count -gt 0) {
        Write-Host "Current Limit: $($current[0].limit)" -ForegroundColor White
        Write-Host "Current Usage: $($current[0].currentValue)" -ForegroundColor White
        Write-Host ""
    }
}

Write-Host "Registering Microsoft.Quota provider..." -ForegroundColor Yellow
az provider register --namespace Microsoft.Quota 2>$null

Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  METHOD 1: az quota update" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow

$quotaRequested = $false

try {
    $quotaResult = az quota update `
        --resource-name $vmFamily `
        --scope "/subscriptions/$subId/providers/Microsoft.Compute/locations/$location" `
        --limit-object value=$newQuota `
        --resource-type "dedicated" 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Quota increase requested via az quota" -ForegroundColor Green
        $quotaRequested = $true
    } else {
        Write-Host "az quota failed: $quotaResult" -ForegroundColor Yellow
    }
} catch {
    Write-Host "az quota exception: $($_.Exception.Message)" -ForegroundColor Yellow
}

if (-not $quotaRequested) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  METHOD 2: REST API" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    
    try {
        $mgmtRaw = az account get-access-token --resource "https://management.azure.com/" 2>$null
        if ($mgmtRaw) {
            $mgmtToken = ($mgmtRaw | ConvertFrom-Json).accessToken
            
            $quotaUri = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Compute/locations/$location/quotas/$($vmFamily)?api-version=2023-02-01"
            
            $quotaBody = @{
                properties = @{
                    limit = @{
                        limitObjectType = "LimitValue"
                        value = $newQuota
                    }
                    name = @{
                        value = $vmFamily
                    }
                }
            } | ConvertTo-Json -Depth 5
            
            $mgmtHeaders = @{
                "Authorization" = "Bearer $mgmtToken"
                "Content-Type" = "application/json"
            }
            
            $qr = Invoke-RestMethod -Uri $quotaUri -Method Put -Headers $mgmtHeaders -Body $quotaBody -TimeoutSec 60
            Write-Host "Quota request submitted via REST API" -ForegroundColor Green
            Write-Host $qr -ForegroundColor Gray
            $quotaRequested = $true
        }
    } catch {
        Write-Host "REST API error: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if (-not $quotaRequested) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  METHOD 3: az rest" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    
    try {
        $scope = "/subscriptions/$subId/providers/Microsoft.Compute/locations/$location"
        $body = "{`"properties`":{`"limit`":{`"limitObjectType`":`"LimitValue`",`"value`":$newQuota},`"name`":{`"value`":`"$vmFamily`"}}}"
        
        $result = az rest --method put `
            --url "https://management.azure.com$scope/quotas/$($vmFamily)?api-version=2023-02-01" `
            --body $body `
            --headers "Content-Type=application/json" 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Quota request submitted via az rest" -ForegroundColor Green
            $quotaRequested = $true
        } else {
            Write-Host "az rest failed: $result" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "az rest exception: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  VERIFYING QUOTA" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

Start-Sleep -Seconds 5

$updatedRaw = az vm list-usage --location $location --query "[?contains(name.value, 'standardEDSv4Family')]" -o json 2>$null
if ($updatedRaw) {
    $updated = $updatedRaw | ConvertFrom-Json
    if ($updated.Count -gt 0) {
        Write-Host ""
        Write-Host "VM Family: $($updated[0].name.localizedValue)" -ForegroundColor White
        Write-Host "Limit: $($updated[0].limit)" -ForegroundColor White
        Write-Host "Usage: $($updated[0].currentValue)" -ForegroundColor White
        Write-Host ""
        
        if ($updated[0].limit -ge $newQuota) {
            Write-Host "QUOTA APPROVED - READY TO DEPLOY DATABRICKS" -ForegroundColor Green
        } elseif ($quotaRequested) {
            Write-Host "QUOTA REQUEST SUBMITTED - PENDING APPROVAL" -ForegroundColor Yellow
            Write-Host "Check status: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" -ForegroundColor Cyan
        } else {
            Write-Host "MANUAL REQUEST REQUIRED" -ForegroundColor Red
            Write-Host ""
            Write-Host "1. Go to: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" -ForegroundColor White
            Write-Host "2. Click Compute" -ForegroundColor White
            Write-Host "3. Filter Region: $location" -ForegroundColor White
            Write-Host "4. Find: Standard EDSv4 Family vCPUs" -ForegroundColor White
            Write-Host "5. Click pencil icon" -ForegroundColor White
            Write-Host "6. Enter: $newQuota" -ForegroundColor White
            Write-Host "7. Submit" -ForegroundColor White
        }
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  DONE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
