[CmdletBinding()]
param(
    [string]$DatabricksWorkspaceUrl = "https://adb-3248848193480666.6.azuredatabricks.net",
    [string]$ResourceGroupName = "",
    [string]$WorkspaceName = ""
)

Write-Host ""
Write-Host "DATABRICKS SERVICE PRINCIPAL FIX" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan
Write-Host ""

$acct = az account show 2>$null | ConvertFrom-Json
if (-not $acct) {
    az login
    $acct = az account show | ConvertFrom-Json
}
Write-Host "Logged in as: $($acct.user.name)" -ForegroundColor Green
Write-Host "Subscription: $($acct.name)" -ForegroundColor Green
$subId = $acct.id
Write-Host ""

Write-Host "Step 1: Finding Databricks workspace..." -ForegroundColor Yellow
$workspaces = az databricks workspace list --query "[?contains(workspaceUrl, '3248848193480666')]" -o json 2>$null | ConvertFrom-Json

if (-not $workspaces -or $workspaces.Count -eq 0) {
    Write-Host "Searching all workspaces..." -ForegroundColor Yellow
    $workspaces = az databricks workspace list -o json 2>$null | ConvertFrom-Json
    Write-Host "Found $($workspaces.Count) workspace(s):" -ForegroundColor White
    $workspaces | ForEach-Object { Write-Host "  - $($_.name) : $($_.workspaceUrl)" -ForegroundColor Gray }
}

if ($workspaces -and $workspaces.Count -gt 0) {
    $ws = $workspaces[0]
    $ResourceGroupName = $ws.resourceGroup
    $WorkspaceName = $ws.name
    Write-Host "Using workspace: $WorkspaceName" -ForegroundColor Green
    Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Green
}
Write-Host ""

Write-Host "Step 2: Creating Service Principal for Databricks..." -ForegroundColor Yellow
$spName = "sp-databricks-sqlwarehouse"

$existingSp = az ad sp list --display-name $spName --query "[0]" -o json 2>$null | ConvertFrom-Json

if ($existingSp) {
    Write-Host "Service Principal already exists: $($existingSp.appId)" -ForegroundColor Green
    $spAppId = $existingSp.appId
    $spObjectId = $existingSp.id
} else {
    Write-Host "Creating new Service Principal..." -ForegroundColor Yellow
    $newSp = az ad sp create-for-rbac --name $spName --skip-assignment -o json 2>$null | ConvertFrom-Json
    $spAppId = $newSp.appId
    $spObjectId = (az ad sp show --id $spAppId --query id -o tsv)
    Write-Host "Created Service Principal: $spAppId" -ForegroundColor Green
}
Write-Host ""

Write-Host "Step 3: Assigning Contributor role to Databricks workspace..." -ForegroundColor Yellow
if ($ResourceGroupName -and $WorkspaceName) {
    $wsResourceId = "/subscriptions/$subId/resourceGroups/$ResourceGroupName/providers/Microsoft.Databricks/workspaces/$WorkspaceName"
    
    az role assignment create --assignee $spAppId --role "Contributor" --scope $wsResourceId 2>$null
    Write-Host "Assigned Contributor role" -ForegroundColor Green
    
    az role assignment create --assignee $spAppId --role "Owner" --scope $wsResourceId 2>$null
    Write-Host "Assigned Owner role" -ForegroundColor Green
}
Write-Host ""

Write-Host "Step 4: Getting Databricks access token..." -ForegroundColor Yellow
$databricksResourceId = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
$token = az account get-access-token --resource $databricksResourceId --query accessToken -o tsv 2>$null

if (-not $token) {
    Write-Host "Getting token via management API..." -ForegroundColor Yellow
    $token = az account get-access-token --query accessToken -o tsv
}
Write-Host "Got access token" -ForegroundColor Green
Write-Host ""

Write-Host "Step 5: Adding Service Principal to Databricks workspace..." -ForegroundColor Yellow

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

$spBody = @{
    schemas = @("urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal")
    applicationId = $spAppId
    displayName = $spName
    active = $true
} | ConvertTo-Json -Depth 10

try {
    $response = Invoke-RestMethod -Uri "$DatabricksWorkspaceUrl/api/2.0/preview/scim/v2/ServicePrincipals" -Method Post -Headers $headers -Body $spBody -ErrorAction Stop
    Write-Host "Added Service Principal to Databricks" -ForegroundColor Green
    Write-Host "Databricks SP ID: $($response.id)" -ForegroundColor White
} catch {
    if ($_.Exception.Response.StatusCode -eq 409) {
        Write-Host "Service Principal already exists in Databricks" -ForegroundColor Green
    } else {
        Write-Host "Note: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
Write-Host ""

Write-Host "Step 6: Adding Service Principal to admins group..." -ForegroundColor Yellow

$groupsResponse = Invoke-RestMethod -Uri "$DatabricksWorkspaceUrl/api/2.0/preview/scim/v2/Groups?filter=displayName+eq+admins" -Method Get -Headers $headers -ErrorAction SilentlyContinue

if ($groupsResponse -and $groupsResponse.Resources) {
    $adminGroupId = $groupsResponse.Resources[0].id
    Write-Host "Found admins group: $adminGroupId" -ForegroundColor White
    
    $spList = Invoke-RestMethod -Uri "$DatabricksWorkspaceUrl/api/2.0/preview/scim/v2/ServicePrincipals?filter=applicationId+eq+$spAppId" -Method Get -Headers $headers -ErrorAction SilentlyContinue
    
    if ($spList -and $spList.Resources) {
        $dbSpId = $spList.Resources[0].id
        
        $patchBody = @{
            schemas = @("urn:ietf:params:scim:api:messages:2.0:PatchOp")
            Operations = @(
                @{
                    op = "add"
                    path = "members"
                    value = @(
                        @{
                            value = $dbSpId
                        }
                    )
                }
            )
        } | ConvertTo-Json -Depth 10
        
        try {
            Invoke-RestMethod -Uri "$DatabricksWorkspaceUrl/api/2.0/preview/scim/v2/Groups/$adminGroupId" -Method Patch -Headers $headers -Body $patchBody -ErrorAction Stop
            Write-Host "Added to admins group" -ForegroundColor Green
        } catch {
            Write-Host "Note: May already be in group" -ForegroundColor Yellow
        }
    }
}
Write-Host ""

Write-Host "Step 7: Granting SQL Warehouse permissions..." -ForegroundColor Yellow

$warehousesResponse = Invoke-RestMethod -Uri "$DatabricksWorkspaceUrl/api/2.0/sql/warehouses" -Method Get -Headers $headers -ErrorAction SilentlyContinue

if ($warehousesResponse -and $warehousesResponse.warehouses) {
    foreach ($wh in $warehousesResponse.warehouses) {
        Write-Host "  Warehouse: $($wh.name) - $($wh.id)" -ForegroundColor White
        
        $permBody = @{
            access_control_list = @(
                @{
                    service_principal_name = $spAppId
                    permission_level = "CAN_MANAGE"
                }
            )
        } | ConvertTo-Json -Depth 10
        
        try {
            Invoke-RestMethod -Uri "$DatabricksWorkspaceUrl/api/2.0/permissions/sql/warehouses/$($wh.id)" -Method Patch -Headers $headers -Body $permBody -ErrorAction SilentlyContinue
            Write-Host "    Granted CAN_MANAGE permission" -ForegroundColor Green
        } catch {
            Write-Host "    Permission update skipped" -ForegroundColor Yellow
        }
    }
}
Write-Host ""

Write-Host "Step 8: Restarting SQL Warehouses..." -ForegroundColor Yellow

if ($warehousesResponse -and $warehousesResponse.warehouses) {
    foreach ($wh in $warehousesResponse.warehouses) {
        Write-Host "  Stopping: $($wh.name)..." -ForegroundColor White
        try {
            Invoke-RestMethod -Uri "$DatabricksWorkspaceUrl/api/2.0/sql/warehouses/$($wh.id)/stop" -Method Post -Headers $headers -ErrorAction SilentlyContinue
        } catch {}
        
        Start-Sleep -Seconds 5
        
        Write-Host "  Starting: $($wh.name)..." -ForegroundColor White
        try {
            Invoke-RestMethod -Uri "$DatabricksWorkspaceUrl/api/2.0/sql/warehouses/$($wh.id)/start" -Method Post -Headers $headers -ErrorAction SilentlyContinue
            Write-Host "    Started" -ForegroundColor Green
        } catch {
            Write-Host "    Start command sent" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "=================================" -ForegroundColor Cyan
Write-Host "COMPLETE" -ForegroundColor Green
Write-Host "=================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Service Principal: $spName" -ForegroundColor White
Write-Host "App ID: $spAppId" -ForegroundColor White
Write-Host ""
Write-Host "Next: Go to Databricks and check if warehouse is starting" -ForegroundColor Yellow
Write-Host "URL: $DatabricksWorkspaceUrl" -ForegroundColor Cyan
Write-Host ""
