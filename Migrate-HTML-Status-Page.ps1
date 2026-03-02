# ============================================================================
# HTML STATUS PAGE MIGRATION TO AZURE APP SERVICE
# Deploys status.html to existing Azure App Service
# ============================================================================

param(
    [string]$AppServiceName = "PYXHEALTHFOWARDING",
    [string]$CustomDomain = "status.pyxhealth.com"
)

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "HTML STATUS PAGE MIGRATION" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Azure Login Check
Write-Host "[1/7] Verifying Azure authentication..." -ForegroundColor Yellow
try {
    $account = az account show | ConvertFrom-Json
    Write-Host "Authenticated as: $($account.user.name)" -ForegroundColor Green
} catch {
    Write-Host "Not authenticated. Initiating login..." -ForegroundColor Yellow
    az login
    $account = az account show | ConvertFrom-Json
}

# Step 2: List and Select Subscription
Write-Host ""
Write-Host "[2/7] Loading available subscriptions..." -ForegroundColor Yellow
$subscriptions = az account list | ConvertFrom-Json
$activeSubscriptions = $subscriptions | Where-Object { $_.state -eq "Enabled" }

Write-Host ""
Write-Host "Available Subscriptions:" -ForegroundColor Cyan
for ($i = 0; $i -lt $activeSubscriptions.Count; $i++) {
    Write-Host "  [$($i + 1)] $($activeSubscriptions[$i].name)" -ForegroundColor White
}

Write-Host ""
$selection = Read-Host "Select subscription number (1-$($activeSubscriptions.Count))"
$selectedSub = $activeSubscriptions[[int]$selection - 1]
Write-Host "Using subscription: $($selectedSub.name)" -ForegroundColor Green

az account set --subscription $selectedSub.id

# Step 3: Locate App Service
Write-Host ""
Write-Host "[3/7] Locating App Service: $AppServiceName..." -ForegroundColor Yellow
$appServices = az webapp list | ConvertFrom-Json
$targetApp = $appServices | Where-Object { $_.name -eq $AppServiceName }

if (-not $targetApp) {
    Write-Host "ERROR: App Service '$AppServiceName' not found" -ForegroundColor Red
    Write-Host ""
    Write-Host "Available App Services:" -ForegroundColor Yellow
    $appServices | ForEach-Object { Write-Host "  - $($_.name)" -ForegroundColor White }
    exit 1
}

Write-Host "Found: $($targetApp.name)" -ForegroundColor Green
Write-Host "Resource Group: $($targetApp.resourceGroup)" -ForegroundColor White
$resourceGroup = $targetApp.resourceGroup

# Step 4: Create status.html Content
Write-Host ""
Write-Host "[4/7] Generating status.html content..." -ForegroundColor Yellow

$statusHtmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>System Status</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #ffffff;
        }
        .container {
            max-width: 900px;
            width: 90%;
            background: rgba(255, 255, 255, 0.1);
            backdrop-filter: blur(10px);
            border-radius: 20px;
            padding: 40px;
            box-shadow: 0 8px 32px 0 rgba(31, 38, 135, 0.37);
            border: 1px solid rgba(255, 255, 255, 0.18);
        }
        h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            text-align: center;
        }
        .subtitle {
            text-align: center;
            font-size: 1.1em;
            margin-bottom: 40px;
            opacity: 0.9;
        }
        .status-badge {
            background: #10b981;
            color: white;
            padding: 12px 30px;
            border-radius: 50px;
            font-size: 1.2em;
            font-weight: bold;
            text-align: center;
            margin: 30px 0;
            box-shadow: 0 4px 15px rgba(16, 185, 129, 0.4);
        }
        .services-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-top: 30px;
        }
        .service-card {
            background: rgba(255, 255, 255, 0.15);
            padding: 25px;
            border-radius: 15px;
            text-align: center;
            transition: transform 0.3s ease;
        }
        .service-card:hover {
            transform: translateY(-5px);
        }
        .service-icon {
            font-size: 2.5em;
            margin-bottom: 15px;
        }
        .service-name {
            font-size: 1.1em;
            font-weight: 600;
            margin-bottom: 10px;
        }
        .service-status {
            color: #10b981;
            font-weight: bold;
        }
        .footer {
            text-align: center;
            margin-top: 40px;
            opacity: 0.7;
            font-size: 0.9em;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>System Status</h1>
        <p class="subtitle">All systems operational</p>
        
        <div class="status-badge">
            ALL SERVICES ONLINE
        </div>

        <div class="services-grid">
            <div class="service-card">
                <div class="service-icon">🌐</div>
                <div class="service-name">Web Application</div>
                <div class="service-status">Operational</div>
            </div>
            
            <div class="service-card">
                <div class="service-icon">🔐</div>
                <div class="service-name">Authentication</div>
                <div class="service-status">Operational</div>
            </div>
            
            <div class="service-card">
                <div class="service-icon">💾</div>
                <div class="service-name">Database</div>
                <div class="service-status">Operational</div>
            </div>
            
            <div class="service-card">
                <div class="service-icon">📡</div>
                <div class="service-name">API Services</div>
                <div class="service-status">Operational</div>
            </div>
        </div>

        <div class="footer">
            Last updated: <span id="timestamp"></span>
        </div>
    </div>

    <script>
        document.getElementById('timestamp').textContent = new Date().toLocaleString();
        setInterval(() => {
            document.getElementById('timestamp').textContent = new Date().toLocaleString();
        }, 60000);
    </script>
</body>
</html>
"@

$tempFolder = $env:TEMP
$statusHtmlPath = Join-Path $tempFolder "status.html"
$statusHtmlContent | Out-File -FilePath $statusHtmlPath -Encoding UTF8 -Force

Write-Host "Status page created: $statusHtmlPath" -ForegroundColor Green

# Step 5: Create Deployment Package
Write-Host ""
Write-Host "[5/7] Creating deployment package..." -ForegroundColor Yellow
$zipPath = Join-Path $tempFolder "status-deploy.zip"
if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}
Compress-Archive -Path $statusHtmlPath -DestinationPath $zipPath -Force
Write-Host "Deployment package ready" -ForegroundColor Green

# Step 6: Deploy to App Service
Write-Host ""
Write-Host "[6/7] Deploying to Azure App Service..." -ForegroundColor Yellow
Write-Host "App Service: $AppServiceName" -ForegroundColor White
Write-Host "Resource Group: $resourceGroup" -ForegroundColor White
Write-Host ""

az webapp deployment source config-zip --resource-group $resourceGroup --name $AppServiceName --src $zipPath --output none

if ($LASTEXITCODE -eq 0) {
    Write-Host "Deployment successful" -ForegroundColor Green
} else {
    Write-Host "Deployment failed" -ForegroundColor Red
    exit 1
}

# Step 7: Add Custom Domain
Write-Host ""
Write-Host "[7/7] Configuring custom domain..." -ForegroundColor Yellow

$existingDomains = az webapp config hostname list --resource-group $resourceGroup --webapp-name $AppServiceName | ConvertFrom-Json
$domainExists = $existingDomains | Where-Object { $_.name -eq $CustomDomain }

if ($domainExists) {
    Write-Host "Custom domain already configured: $CustomDomain" -ForegroundColor Yellow
} else {
    Write-Host "Adding custom domain: $CustomDomain" -ForegroundColor White
    az webapp config hostname add --resource-group $resourceGroup --webapp-name $AppServiceName --hostname $CustomDomain --output none
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Custom domain added successfully" -ForegroundColor Green
    } else {
        Write-Host "Custom domain addition failed (verify DNS first)" -ForegroundColor Yellow
    }
}

# Cleanup
Remove-Item $statusHtmlPath -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

# Get App Service URL
$appUrl = az webapp show --resource-group $resourceGroup --name $AppServiceName --query "defaultHostName" --output tsv

# Final Output
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Green
Write-Host "MIGRATION COMPLETE" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "App Service URL:" -ForegroundColor Cyan
Write-Host "  https://$appUrl" -ForegroundColor White
Write-Host ""
Write-Host "Custom Domain:" -ForegroundColor Cyan
Write-Host "  https://$CustomDomain" -ForegroundColor White
Write-Host ""
Write-Host "REQUIRED DNS CONFIGURATION:" -ForegroundColor Yellow
Write-Host "  Host:  status" -ForegroundColor White
Write-Host "  Type:  CNAME" -ForegroundColor White
Write-Host "  Value: $appUrl" -ForegroundColor White
Write-Host ""
Write-Host "NEXT STEP:" -ForegroundColor Yellow
Write-Host "Add URL rewrite rule to web.config for custom domain routing" -ForegroundColor White
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Green
