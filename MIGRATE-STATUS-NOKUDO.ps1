# MIGRATE STATUS PAGE - NO KUDU API VERSION
# Uses az webapp deploy - works without Basic Auth

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  MIGRATE STATUS PAGE TO AZURE" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Azure Login
Write-Host "Step 1: Checking Azure login..." -ForegroundColor Yellow

try {
    $accountJson = az account show
    $account = $accountJson | ConvertFrom-Json
} catch {
    $account = $null
}

if (-not $account) {
    Write-Host "Not logged in..." -ForegroundColor Yellow
    az login
    $accountJson = az account show
    $account = $accountJson | ConvertFrom-Json
}
Write-Host "Logged in as: $($account.user.name)" -ForegroundColor Green

# Step 2: List subscriptions
Write-Host ""
Write-Host "Step 2: Getting subscriptions..." -ForegroundColor Yellow

$subscriptions = az account list --query "[].{Name:name, Id:id, State:state}" -o json | ConvertFrom-Json
$activeSubscriptions = $subscriptions | Where-Object { $_.State -eq "Enabled" }

Write-Host ""
$i = 1
foreach ($sub in $activeSubscriptions) {
    Write-Host "  $i. $($sub.Name)" -ForegroundColor White
    $i++
}

Write-Host ""
$selection = Read-Host "Select subscription number"
$selectedSub = $activeSubscriptions[$selection - 1]
Write-Host "Selected: $($selectedSub.Name)" -ForegroundColor Green

# Step 3: Switch subscription
az account set --subscription $selectedSub.Id

# Step 4: Find App Service
Write-Host ""
Write-Host "Step 3: Finding PYXHEALTHFOWARDING..." -ForegroundColor Yellow

$appService = az webapp list --query "[?contains(name,'PYXHEALTHFOWARDING')].{name:name, rg:resourceGroup}" -o json | ConvertFrom-Json

if (-not $appService -or $appService.Count -eq 0) {
    $allApps = az webapp list --query "[].{name:name, rg:resourceGroup}" -o json | ConvertFrom-Json
    Write-Host "Select App Service:" -ForegroundColor Cyan
    $j = 1
    foreach ($app in $allApps) {
        Write-Host "  $j. $($app.name)" -ForegroundColor White
        $j++
    }
    $appSelection = Read-Host "Select number"
    $appService = $allApps[$appSelection - 1]
} else {
    $appService = $appService[0]
}

$AppServiceName = $appService.name
$ResourceGroupName = $appService.rg

Write-Host "Found: $AppServiceName" -ForegroundColor Green

# Step 5: Get URL
$webappUrl = az webapp show --name $AppServiceName --resource-group $ResourceGroupName --query "defaultHostName" -o tsv
Write-Host "URL: $webappUrl" -ForegroundColor Cyan

# Step 6: Create temp folder
Write-Host ""
Write-Host "Step 4: Creating files..." -ForegroundColor Yellow

$tempFolder = Join-Path $env:TEMP "status-deploy"
if (Test-Path $tempFolder) { Remove-Item $tempFolder -Recurse -Force }
New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null

# Create status.html
$htmlContent = @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Pyx Health System Status</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 0;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            background-color: #ffffff;
        }
        .container {
            text-align: center;
            padding: 40px;
        }
        h1 {
            color: #000000;
            font-size: 28px;
            font-weight: bold;
            margin-bottom: 20px;
        }
        p {
            color: #000000;
            font-size: 16px;
            margin-bottom: 15px;
        }
        .operational {
            color: #006400;
            font-weight: bold;
        }
        a {
            color: #0066cc;
            text-decoration: none;
            font-weight: bold;
        }
        a:hover {
            text-decoration: underline;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Pyx Health System Status</h1>
        <p class="operational">All Systems Are Operational, with no current reported incidents.</p>
        <p>Click <a href="https://pyxhealth.samanage.com">HERE</a> to return to the Pyx Health Service Portal</p>
    </div>
</body>
</html>
'@

$statusHtmlPath = Join-Path $tempFolder "status.html"
$htmlContent | Out-File -FilePath $statusHtmlPath -Encoding UTF8
Write-Host "status.html created!" -ForegroundColor Green

# Step 7: Upload using az webapp deploy
Write-Host ""
Write-Host "Step 5: Uploading status.html..." -ForegroundColor Yellow

az webapp deploy --resource-group $ResourceGroupName --name $AppServiceName --src-path $statusHtmlPath --target-path "status.html" --type static --restart false

if ($LASTEXITCODE -eq 0) {
    Write-Host "status.html uploaded!" -ForegroundColor Green
} else {
    Write-Host "Trying ZIP deploy method..." -ForegroundColor Yellow
    
    $zipPath = Join-Path $env:TEMP "status.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    
    Compress-Archive -Path $statusHtmlPath -DestinationPath $zipPath -Force
    
    az webapp deployment source config-zip --resource-group $ResourceGroupName --name $AppServiceName --src $zipPath
    
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Write-Host "status.html uploaded via ZIP!" -ForegroundColor Green
}

# Cleanup temp
Remove-Item $tempFolder -Recurse -Force -ErrorAction SilentlyContinue

# Step 8: Add custom domain
Write-Host ""
Write-Host "Step 6: Adding custom domain..." -ForegroundColor Yellow

az webapp config hostname add --webapp-name $AppServiceName --resource-group $ResourceGroupName --hostname "status.pyxhealth.com"

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "STATUS.HTML UPLOADED!" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "NOW YOU NEED TO ADD THE RULE TO WEB.CONFIG MANUALLY:" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. Go to Azure Portal" -ForegroundColor White
Write-Host "2. Open: $AppServiceName" -ForegroundColor White
Write-Host "3. Click: Advanced Tools (Kudu) > Go" -ForegroundColor White
Write-Host "4. Click: Debug console > CMD" -ForegroundColor White
Write-Host "5. Navigate: site > wwwroot" -ForegroundColor White
Write-Host "6. Click EDIT on web.config" -ForegroundColor White
Write-Host "7. Add this rule at TOP inside <rules>:" -ForegroundColor White
Write-Host ""
Write-Host '  <rule name="status-page" stopProcessing="true">' -ForegroundColor Cyan
Write-Host '    <match url=".*" />' -ForegroundColor Cyan
Write-Host '    <conditions>' -ForegroundColor Cyan
Write-Host '      <add input="{HTTP_HOST}" pattern="^status\.pyxhealth\.com$" />' -ForegroundColor Cyan
Write-Host '    </conditions>' -ForegroundColor Cyan
Write-Host '    <action type="Rewrite" url="status.html" />' -ForegroundColor Cyan
Write-Host '  </rule>' -ForegroundColor Cyan
Write-Host ""
Write-Host "8. SAVE the file" -ForegroundColor White
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Yellow
Write-Host "DNS CNAME FOR CLIENT:" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Host:  status" -ForegroundColor White
Write-Host "  Type:  CNAME" -ForegroundColor White
Write-Host "  Value: $webappUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
