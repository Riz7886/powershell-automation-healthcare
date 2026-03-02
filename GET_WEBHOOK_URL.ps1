# EDIT THESE 2 LINES
$PAGERDUTY_API_TOKEN = "YOUR_PAGERDUTY_API_TOKEN_HERE"
$PAGERDUTY_SERVICE_ID = "YOUR_PAGERDUTY_SERVICE_ID_HERE"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  PAGERDUTY WEBHOOK URL GENERATOR" -ForegroundColor Green
Write-Host "  This script creates a webhook integration automatically" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Validate keys are filled in
if ($PAGERDUTY_API_TOKEN -eq "YOUR_PAGERDUTY_API_TOKEN_HERE" -or $PAGERDUTY_SERVICE_ID -eq "YOUR_PAGERDUTY_SERVICE_ID_HERE") {
    Write-Host "ERROR: You must edit the keys at the top of this script!" -ForegroundColor Red
    Write-Host ""
    Write-Host "1. Get PagerDuty API Token from: Configuration > API Access > Create API Key" -ForegroundColor Yellow
    Write-Host "2. Get Service ID from: Services > Your Service > Copy the ID from URL" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Host "Creating PagerDuty webhook integration..." -ForegroundColor Cyan
Write-Host ""

$headers = @{
    "Authorization" = "Token token=$PAGERDUTY_API_TOKEN"
    "Content-Type" = "application/json"
    "Accept" = "application/vnd.pagerduty+json;version=2"
}

$body = @{
    "integration" = @{
        "type" = "events_api_v2_inbound_integration"
        "name" = "MoveIT Datadog Webhook Integration"
        "service" = @{
            "id" = $PAGERDUTY_SERVICE_ID
            "type" = "service_reference"
        }
    }
} | ConvertTo-Json -Depth 10

try {
    $response = Invoke-RestMethod -Uri "https://api.pagerduty.com/services/$PAGERDUTY_SERVICE_ID/integrations" -Method Post -Headers $headers -Body $body
    
    $integrationKey = $response.integration.integration_key
    $webhookUrl = "https://events.pagerduty.com/v2/enqueue"
    
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  SUCCESS! WEBHOOK CREATED!" -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "COPY THESE VALUES:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "PAGERDUTY ROUTING KEY:" -ForegroundColor Cyan
    Write-Host $integrationKey -ForegroundColor White
    Write-Host ""
    Write-Host "WEBHOOK URL:" -ForegroundColor Cyan
    Write-Host $webhookUrl -ForegroundColor White
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Use these values in SETUP_WITH_KEYS.ps1" -ForegroundColor Yellow
    Write-Host ""
    
} catch {
    Write-Host "ERROR: Failed to create webhook integration" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "Make sure:" -ForegroundColor Yellow
    Write-Host "  1. Your API token is valid" -ForegroundColor Gray
    Write-Host "  2. Your Service ID is correct" -ForegroundColor Gray
    Write-Host "  3. The API token has write permissions" -ForegroundColor Gray
    exit 1
}

Write-Host "Press any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
