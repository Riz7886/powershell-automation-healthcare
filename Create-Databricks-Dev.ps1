param(
    [Parameter(Mandatory=$false)]
    [string]$TargetRegion = "eastus",
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "rg-databricks-dev",
    
    [Parameter(Mandatory=$false)]
    [string]$WorkspaceName = "databricks-dev-optimized",
    
    [Parameter(Mandatory=$false)]
    [switch]$CreateWorkspace,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "$env:TEMP"
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportFile = Join-Path $OutputPath "Databricks_Dev_Setup_$timestamp.html"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DATABRICKS DEV ENVIRONMENT - COST OPTIMIZED SETUP" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$modules = @('Az.Accounts', 'Az.Resources', 'Az.Databricks', 'Az.Compute')
foreach ($mod in $modules) {
    if (!(Get-Module -ListAvailable -Name $mod)) {
        Write-Host "Installing $mod..." -ForegroundColor Yellow
        Install-Module -Name $mod -Force -AllowClobber -Scope CurrentUser -ErrorAction SilentlyContinue
    }
    Import-Module $mod -ErrorAction SilentlyContinue
}

Write-Host "Connecting to Azure..." -ForegroundColor Yellow
try {
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount | Out-Null
        $context = Get-AzContext
    }
    Write-Host "Connected: $($context.Account.Id)" -ForegroundColor Green
    Write-Host "Subscription: $($context.Subscription.Name)" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Cannot connect to Azure" -ForegroundColor Red
    exit
}

Write-Host ""
Write-Host "STEP 1: Finding regions with available quota..." -ForegroundColor Yellow
Write-Host ""

$regionsToCheck = @(
    @{Name="East US"; Location="eastus"},
    @{Name="East US 2"; Location="eastus2"},
    @{Name="Central US"; Location="centralus"},
    @{Name="North Central US"; Location="northcentralus"},
    @{Name="South Central US"; Location="southcentralus"},
    @{Name="West US 3"; Location="westus3"},
    @{Name="Canada Central"; Location="canadacentral"},
    @{Name="UK South"; Location="uksouth"}
)

$viableRegions = @()

foreach ($region in $regionsToCheck) {
    Write-Host "Checking: $($region.Name)..." -ForegroundColor Cyan
    
    try {
        $usage = Get-AzVMUsage -Location $region.Location -ErrorAction SilentlyContinue
        $quotaInfo = $usage | Where-Object { 
            $_.Name.LocalizedValue -like "*Standard*v3*" -or 
            $_.Name.LocalizedValue -like "*Total Regional*" 
        } | Select-Object -First 1
        
        if ($quotaInfo) {
            $available = $quotaInfo.Limit - $quotaInfo.CurrentValue
            
            if ($available -ge 16) {
                Write-Host "  FOUND QUOTA: $available cores available!" -ForegroundColor Green
                
                $viableRegions += [PSCustomObject]@{
                    Name = $region.Name
                    Location = $region.Location
                    Available = $available
                    Limit = $quotaInfo.Limit
                    Used = $quotaInfo.CurrentValue
                }
            } else {
                Write-Host "  Not enough: only $available cores" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "  ERROR checking region" -ForegroundColor Red
    }
}

if ($viableRegions.Count -eq 0) {
    Write-Host ""
    Write-Host "NO REGIONS FOUND WITH QUOTA!" -ForegroundColor Red
    Write-Host "Must request quota increase before creating dev environment." -ForegroundColor Red
    exit
}

$bestRegion = $viableRegions | Sort-Object -Property Available -Descending | Select-Object -First 1

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  RECOMMENDED REGION: $($bestRegion.Name)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Available cores: $($bestRegion.Available)" -ForegroundColor White
Write-Host "  Location: $($bestRegion.Location)" -ForegroundColor White
Write-Host ""

$TargetRegion = $bestRegion.Location

Write-Host "STEP 2: Calculating cost-optimized cluster configuration..." -ForegroundColor Yellow
Write-Host ""

$clusterConfigs = @(
    @{
        Name = "dev-small-cluster"
        Purpose = "Development & Testing"
        DriverType = "Standard_DS3_v2"
        DriverCores = 4
        WorkerType = "Standard_DS3_v2"
        WorkerCores = 4
        MinWorkers = 1
        MaxWorkers = 3
        AutoScale = $true
        Spot = $true
        EstimatedCostPerHour = 0.60
        EstimatedMonthly = 432
        Description = "Small cluster for development work"
    },
    @{
        Name = "dev-single-node"
        Purpose = "Individual Development"
        DriverType = "Standard_DS3_v2"
        DriverCores = 4
        WorkerType = "None"
        WorkerCores = 0
        MinWorkers = 0
        MaxWorkers = 0
        AutoScale = $false
        Spot = $false
        EstimatedCostPerHour = 0.20
        EstimatedMonthly = 144
        Description = "Single-node cluster for solo dev work - cheapest option"
    },
    @{
        Name = "dev-spot-cluster"
        Purpose = "Non-critical batch jobs"
        DriverType = "Standard_DS3_v2"
        DriverCores = 4
        WorkerType = "Standard_DS3_v2"
        WorkerCores = 4
        MinWorkers = 2
        MaxWorkers = 8
        AutoScale = $true
        Spot = $true
        EstimatedCostPerHour = 0.80
        EstimatedMonthly = 576
        Description = "Spot instances for batch processing - up to 80% savings"
    }
)

$totalDevCost = ($clusterConfigs | Measure-Object -Property EstimatedMonthly -Sum).Sum
$currentProdCost = 1000

Write-Host "Recommended Dev Cluster Configurations:" -ForegroundColor Green
Write-Host ""
foreach ($config in $clusterConfigs) {
    Write-Host "  $($config.Name):" -ForegroundColor Cyan
    Write-Host "    Purpose: $($config.Purpose)" -ForegroundColor White
    Write-Host "    Cost: `$$($config.EstimatedMonthly)/mo (if running 24/7)" -ForegroundColor White
    Write-Host "    Cores: Driver $($config.DriverCores) + Workers $(if ($config.WorkerCores -gt 0) { "$($config.MinWorkers)-$($config.MaxWorkers) x $($config.WorkerCores)" } else { "None" })" -ForegroundColor White
    Write-Host ""
}

Write-Host "COST COMPARISON:" -ForegroundColor Yellow
Write-Host "  Current Prod Databricks: `$$currentProdCost/mo" -ForegroundColor White
Write-Host "  New Dev Environment: `$$totalDevCost/mo (worst case - 24/7 usage)" -ForegroundColor White
Write-Host "  Realistic Dev Cost: `$$([math]::Round($totalDevCost * 0.3, 2))/mo (30% uptime)" -ForegroundColor Green
Write-Host ""

if ($CreateWorkspace) {
    Write-Host ""
    Write-Host "STEP 3: Creating Databricks Dev Workspace..." -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "Creating resource group: $ResourceGroupName..." -ForegroundColor Cyan
    try {
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -Location $TargetRegion -ErrorAction SilentlyContinue
        if (-not $rg) {
            New-AzResourceGroup -Name $ResourceGroupName -Location $TargetRegion -Tag @{
                Environment = "Development"
                CostCenter = "Engineering"
                Purpose = "Databricks Dev"
                CreatedBy = "Syed Rizvi"
            } | Out-Null
            Write-Host "  Created resource group" -ForegroundColor Green
        } else {
            Write-Host "  Resource group already exists" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit
    }
    
    Write-Host ""
    Write-Host "Creating Databricks workspace: $WorkspaceName..." -ForegroundColor Cyan
    Write-Host "  Location: $TargetRegion" -ForegroundColor White
    Write-Host "  SKU: Premium (for cost controls)" -ForegroundColor White
    Write-Host ""
    
    try {
        $workspace = New-AzDatabricksWorkspace `
            -Name $WorkspaceName `
            -ResourceGroupName $ResourceGroupName `
            -Location $TargetRegion `
            -Sku premium `
            -Tag @{
                Environment = "Development"
                CostCenter = "Engineering"
                Purpose = "Cost-Optimized Dev Environment"
                CreatedBy = "Syed Rizvi"
                CreatedDate = (Get-Date -Format "yyyy-MM-dd")
            }
        
        Write-Host "  Workspace created successfully!" -ForegroundColor Green
        Write-Host "  Workspace URL: https://$($workspace.WorkspaceUrl)" -ForegroundColor Cyan
        Write-Host ""
        
    } catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  If error is 'Databricks not registered', run:" -ForegroundColor Yellow
        Write-Host "  Register-AzResourceProvider -ProviderNamespace Microsoft.Databricks" -ForegroundColor White
        exit
    }
}

Write-Host ""
Write-Host "STEP 4: Generating setup documentation..." -ForegroundColor Yellow
Write-Host ""

$clusterScripts = @"
# DATABRICKS CLUSTER CREATION SCRIPTS
# Run these in Databricks UI after workspace is created

## 1. DEV SMALL CLUSTER (Recommended for most dev work)
{
  "cluster_name": "dev-small-cluster",
  "spark_version": "13.3.x-scala2.12",
  "node_type_id": "Standard_DS3_v2",
  "driver_node_type_id": "Standard_DS3_v2",
  "autoscale": {
    "min_workers": 1,
    "max_workers": 3
  },
  "azure_attributes": {
    "first_on_demand": 1,
    "availability": "SPOT_WITH_FALLBACK_AZURE",
    "spot_bid_max_price": -1
  },
  "autotermination_minutes": 30,
  "enable_elastic_disk": true,
  "cluster_source": "UI",
  "init_scripts": [],
  "spark_conf": {
    "spark.databricks.cluster.profile": "singleNode"
  },
  "custom_tags": {
    "Environment": "Development",
    "CostOptimized": "true"
  }
}

## 2. DEV SINGLE NODE (Cheapest - for solo work)
{
  "cluster_name": "dev-single-node",
  "spark_version": "13.3.x-scala2.12",
  "node_type_id": "Standard_DS3_v2",
  "driver_node_type_id": "Standard_DS3_v2",
  "num_workers": 0,
  "autotermination_minutes": 20,
  "enable_elastic_disk": true,
  "cluster_source": "UI",
  "spark_conf": {
    "spark.master": "local[*]",
    "spark.databricks.cluster.profile": "singleNode"
  },
  "custom_tags": {
    "ResourceClass": "SingleNode",
    "Environment": "Development"
  }
}

## 3. DEV SPOT CLUSTER (For batch jobs)
{
  "cluster_name": "dev-spot-cluster",
  "spark_version": "13.3.x-scala2.12",
  "node_type_id": "Standard_DS3_v2",
  "driver_node_type_id": "Standard_DS3_v2",
  "autoscale": {
    "min_workers": 2,
    "max_workers": 8
  },
  "azure_attributes": {
    "availability": "SPOT_AZURE",
    "spot_bid_max_price": -1
  },
  "autotermination_minutes": 15,
  "enable_elastic_disk": true,
  "custom_tags": {
    "Environment": "Development",
    "WorkloadType": "Batch"
  }
}
"@

$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Databricks Dev Environment Setup</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); }
        .container { background: white; padding: 30px; border-radius: 10px; max-width: 1200px; margin: 0 auto; }
        h1 { color: #333; border-bottom: 3px solid #28a745; padding-bottom: 10px; }
        .success { background: #d4edda; border-left: 5px solid #28a745; padding: 20px; margin: 20px 0; }
        .info { background: #d1ecf1; border-left: 5px solid #0c5460; padding: 20px; margin: 20px 0; }
        .cost-savings { background: linear-gradient(135deg, #28a745 0%, #20c997 100%); color: white; padding: 25px; border-radius: 8px; margin: 20px 0; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 12px; text-align: left; }
        td { padding: 10px; border-bottom: 1px solid #ddd; }
        .highlight { background: #fff3cd; }
        code { background: #f4f4f4; padding: 2px 6px; border-radius: 3px; font-family: monospace; }
        pre { background: #f4f4f4; padding: 15px; border-radius: 5px; overflow-x: auto; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Databricks Dev Environment - Cost Optimized Setup</h1>
        <p><strong>Created:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | <strong>By:</strong> Syed Rizvi</p>
        
        <div class="success">
            <h2>SUCCESS: Solution Found!</h2>
            <p><strong>Recommended Region:</strong> $($bestRegion.Name) ($($bestRegion.Location))</p>
            <p><strong>Available Quota:</strong> $($bestRegion.Available) vCPUs</p>
            <p><strong>Strategy:</strong> Create separate dev environment with cost-optimized clusters</p>
        </div>
        
        <div class="cost-savings">
            <h2>Cost Savings Analysis</h2>
            <table style="color: white; margin: 0;">
                <tr>
                    <td><strong>Current Prod Databricks:</strong></td>
                    <td style="text-align: right;"><strong>`$$currentProdCost/month</strong></td>
                </tr>
                <tr>
                    <td><strong>New Dev Environment (24/7):</strong></td>
                    <td style="text-align: right;"><strong>`$$totalDevCost/month</strong></td>
                </tr>
                <tr>
                    <td><strong>Realistic Dev Cost (30% uptime):</strong></td>
                    <td style="text-align: right;"><strong>`$$([math]::Round($totalDevCost * 0.3, 2))/month</strong></td>
                </tr>
                <tr style="border-top: 2px solid white;">
                    <td><strong>MONTHLY SAVINGS:</strong></td>
                    <td style="text-align: right;"><strong>`$$([math]::Round($currentProdCost - ($totalDevCost * 0.3), 2))</strong></td>
                </tr>
            </table>
        </div>
        
        <h2>Recommended Cluster Configurations</h2>
        <table>
            <tr>
                <th>Cluster Name</th>
                <th>Purpose</th>
                <th>Cores</th>
                <th>Type</th>
                <th>Cost/Month</th>
            </tr>
"@

foreach ($config in $clusterConfigs) {
    $coresDesc = if ($config.WorkerCores -gt 0) {
        "$($config.DriverCores) + $($config.MinWorkers)-$($config.MaxWorkers) workers"
    } else {
        "$($config.DriverCores) (single node)"
    }
    
    $typeDesc = if ($config.Spot) { "Spot instances" } else { "On-demand" }
    
    $html += @"
            <tr>
                <td><strong>$($config.Name)</strong></td>
                <td>$($config.Purpose)</td>
                <td>$coresDesc</td>
                <td>$typeDesc</td>
                <td>`$$($config.EstimatedMonthly) (24/7)</td>
            </tr>
"@
}

$html += @"
        </table>
        
        <div class="info">
            <h3>Key Benefits of This Approach</h3>
            <ul>
                <li><strong>Immediate:</strong> Can create dev environment TODAY in region with quota</li>
                <li><strong>Cost Effective:</strong> Dev clusters use spot instances + auto-termination</li>
                <li><strong>Best Practice:</strong> Separates dev from prod (compliance/security)</li>
                <li><strong>Scalable:</strong> Auto-scaling from 1-8 workers based on workload</li>
                <li><strong>Safe:</strong> Prod environment untouched, zero risk</li>
            </ul>
        </div>
        
        <h2>Implementation Steps</h2>
        <ol>
            <li><strong>Create Workspace:</strong> Run script with <code>-CreateWorkspace</code> flag</li>
            <li><strong>Access Workspace:</strong> Navigate to Databricks UI</li>
            <li><strong>Create Clusters:</strong> Use provided JSON configurations</li>
            <li><strong>Configure Policies:</strong> Set auto-termination and cost controls</li>
            <li><strong>Migrate Dev Work:</strong> Move non-prod workloads to new environment</li>
        </ol>
        
        <h2>Cluster Configuration Scripts</h2>
        <p>Copy these into Databricks UI → Compute → Create Cluster → JSON</p>
        <pre>$clusterScripts</pre>
        
        <div class="info">
            <h3>Cost Control Features Enabled</h3>
            <ul>
                <li><strong>Auto-termination:</strong> Clusters shut down after 15-30 minutes of inactivity</li>
                <li><strong>Spot Instances:</strong> Up to 80% savings on compute costs</li>
                <li><strong>Auto-scaling:</strong> Scale down to 1 worker when idle</li>
                <li><strong>Single-node option:</strong> $144/month for solo development</li>
            </ul>
        </div>
        
        <h2>Next Steps</h2>
        <ol>
            <li>Present this solution to Tony showing cost savings</li>
            <li>Get approval to create dev environment</li>
            <li>Run script with <code>-CreateWorkspace</code> flag</li>
            <li>Create optimized clusters in new workspace</li>
            <li>Migrate dev/test workloads</li>
            <li>Monitor costs and adjust as needed</li>
        </ol>
        
        <p style="margin-top: 40px; text-align: center; color: #666;">
            <strong>Prepared by Syed Rizvi</strong><br>
            Cost-optimized Databricks development environment solution
        </p>
    </div>
</body>
</html>
"@

$html | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host "Report generated: $reportFile" -ForegroundColor Green
Write-Host "Opening report..." -ForegroundColor Cyan

Start-Process $reportFile

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  NEXT STEPS" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "1. Review the HTML report" -ForegroundColor White
Write-Host "2. Present to Tony showing cost savings" -ForegroundColor White
Write-Host "3. To create workspace, run:" -ForegroundColor White
Write-Host "   .\Create-Databricks-Dev.ps1 -CreateWorkspace" -ForegroundColor Cyan
Write-Host ""
Write-Host "Recommended region: $($bestRegion.Name)" -ForegroundColor Green
Write-Host "Estimated savings: `$$([math]::Round($currentProdCost - ($totalDevCost * 0.3), 2))/month" -ForegroundColor Green
Write-Host ""
