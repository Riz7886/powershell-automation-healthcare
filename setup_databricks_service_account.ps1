$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  DATABRICKS SERVICE ACCOUNT SETUP" -ForegroundColor Cyan
Write-Host "  Fully Automated with Permission Pre-Checks" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

$spName = "databricks-service-principal"
$dbResource = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
$allErrors = @()
$allWarnings = @()

$reportData = @{
    date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    spName = $spName
    appId = ""
    objectId = ""
    tenantId = ""
    secretValue = ""
    secretExpiry = ""
    subscription = ""
    subscriptionId = ""
    userName = ""
    workspaces = @()
}

# ===============================================================
# STEP 1: Azure Login
# ===============================================================
Write-Host "[1/8] Checking Azure login..." -ForegroundColor Yellow

try {
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) { throw "not logged in" }
}
catch {
    Write-Host "  Not logged in. Opening browser..." -ForegroundColor Yellow
    az login -o json 2>$null | Out-Null
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) {
        Write-Host "  FATAL: Cannot log in to Azure. Exiting." -ForegroundColor Red
        exit 1
    }
}

Write-Host "  Logged in as: $($acct.user.name)" -ForegroundColor Green
Write-Host "  Subscription: $($acct.name) ($($acct.id))" -ForegroundColor Green
Write-Host "  Tenant: $($acct.tenantId)" -ForegroundColor Green

$reportData.subscription = $acct.name
$reportData.subscriptionId = $acct.id
$reportData.tenantId = $acct.tenantId
$reportData.userName = $acct.user.name
Write-Host ""

# ===============================================================
# STEP 2: Pre-Check Azure AD Permissions
# ===============================================================
Write-Host "[2/8] Checking Azure AD permissions..." -ForegroundColor Yellow

$canCreateApps = $false
try {
    $testResult = az ad app list --filter "displayName eq 'permission-test-delete-me'" -o json 2>$null | ConvertFrom-Json
    $canCreateApps = $true
    Write-Host "  Azure AD read access: OK" -ForegroundColor Green
}
catch {
    Write-Host "  WARNING: Cannot query Azure AD. You may not have permission to create apps." -ForegroundColor Yellow
    $allWarnings += "Cannot verify Azure AD permissions"
}

# Check if we can create apps by looking at current user's roles
try {
    $myRoles = az role assignment list --assignee $acct.user.name --all -o json 2>$null | ConvertFrom-Json
    $isOwner = $myRoles | Where-Object { $_.roleDefinitionName -eq "Owner" }
    $isUAA = $myRoles | Where-Object { $_.roleDefinitionName -eq "User Access Administrator" }

    if ($isOwner) {
        Write-Host "  Role: Owner (can assign roles)" -ForegroundColor Green
    }
    elseif ($isUAA) {
        Write-Host "  Role: User Access Administrator (can assign roles)" -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: You may not have Owner/UAA role. Role assignment might fail." -ForegroundColor Yellow
        Write-Host "  The script will try anyway and report results." -ForegroundColor Yellow
        $allWarnings += "No Owner or User Access Administrator role detected. Role assignments may fail."
    }
}
catch {
    Write-Host "  Could not check roles. Will try and report results." -ForegroundColor Yellow
}
Write-Host ""

# ===============================================================
# STEP 3: Create or Find Azure AD App Registration
# ===============================================================
Write-Host "[3/8] Setting up Azure AD App Registration..." -ForegroundColor Yellow

$appId = $null
$appObjectId = $null
$appCreated = $false

try {
    $existingApp = az ad app list --display-name $spName -o json 2>&1 | ConvertFrom-Json

    if ($existingApp -and $existingApp.Count -gt 0) {
        $appId = $existingApp[0].appId
        $appObjectId = $existingApp[0].id
        Write-Host "  App '$spName' already exists." -ForegroundColor Yellow
        Write-Host "  App ID: $appId" -ForegroundColor Green
    }
}
catch {
    Write-Host "  No existing app found. Will create new." -ForegroundColor Gray
}

if (-not $appId) {
    try {
        Write-Host "  Creating new app: $spName..." -ForegroundColor Yellow
        $newAppJson = az ad app create --display-name $spName -o json 2>&1
        $newApp = $newAppJson | ConvertFrom-Json
        $appId = $newApp.appId
        $appObjectId = $newApp.id
        $appCreated = $true
        Write-Host "  Created App ID: $appId" -ForegroundColor Green
    }
    catch {
        Write-Host "  FATAL: Cannot create Azure AD App. Check permissions." -ForegroundColor Red
        Write-Host "  You need Application Administrator or Global Administrator role." -ForegroundColor Red
        Write-Host "  Error: $_" -ForegroundColor Red
        $allErrors += "Cannot create Azure AD App Registration. Missing Application Administrator role."
        Write-Host ""
        Write-Host "  WORKAROUND: Ask your Azure AD admin to run:" -ForegroundColor Yellow
        Write-Host "  az ad app create --display-name $spName" -ForegroundColor White
        Write-Host "  Then re-run this script." -ForegroundColor Yellow
        exit 1
    }
}

$reportData.appId = $appId
Write-Host ""

# ===============================================================
# STEP 4: Create Service Principal
# ===============================================================
Write-Host "[4/8] Creating Service Principal..." -ForegroundColor Yellow

$spObjectId = $null

try {
    $existingSp = az ad sp list --filter "appId eq '$appId'" -o json 2>&1 | ConvertFrom-Json

    if ($existingSp -and $existingSp.Count -gt 0) {
        $spObjectId = $existingSp[0].id
        Write-Host "  Service Principal already exists." -ForegroundColor Yellow
        Write-Host "  SP Object ID: $spObjectId" -ForegroundColor Green
    }
}
catch {}

if (-not $spObjectId) {
    try {
        Write-Host "  Creating service principal..." -ForegroundColor Yellow
        $newSpJson = az ad sp create --id $appId -o json 2>&1
        $newSp = $newSpJson | ConvertFrom-Json
        $spObjectId = $newSp.id
        Write-Host "  Created SP Object ID: $spObjectId" -ForegroundColor Green
    }
    catch {
        Write-Host "  FATAL: Cannot create Service Principal." -ForegroundColor Red
        Write-Host "  Error: $_" -ForegroundColor Red
        $allErrors += "Cannot create Service Principal"
        exit 1
    }
}

$reportData.objectId = $spObjectId
Write-Host ""

# ===============================================================
# STEP 5: Add Client Secret (non-destructive)
# ===============================================================
Write-Host "[5/8] Adding client secret (non-destructive)..." -ForegroundColor Yellow
Write-Host "  Using 'credential add' - existing secrets are NOT touched." -ForegroundColor Green

$secretValue = $null
$secretExpiry = (Get-Date).AddYears(1).ToString("yyyy-MM-ddTHH:mm:ssZ")

try {
    $credJson = az ad app credential list --id $appId -o json 2>$null | ConvertFrom-Json
    $existingCount = 0
    if ($credJson) { $existingCount = $credJson.Count }
    Write-Host "  Existing credentials: $existingCount (will not be modified)" -ForegroundColor Green

    $secretDisplayName = "databricks-sp-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    $newCredJson = az ad app credential reset --id $appId --display-name $secretDisplayName --end-date $secretExpiry --append -o json 2>&1
    $newCred = $newCredJson | ConvertFrom-Json
    $secretValue = $newCred.password

    if ($secretValue) {
        Write-Host "  Secret created: $secretDisplayName" -ForegroundColor Green
        Write-Host "  Expires: $secretExpiry" -ForegroundColor Green
        Write-Host ""
        Write-Host "  ============================================" -ForegroundColor Red
        Write-Host "  CLIENT SECRET (SAVE THIS NOW):" -ForegroundColor Red
        Write-Host "  $secretValue" -ForegroundColor Red
        Write-Host "  ============================================" -ForegroundColor Red
        Write-Host "  This will NOT be shown again!" -ForegroundColor Red

        $reportData.secretValue = $secretValue
        $reportData.secretExpiry = $secretExpiry
    }
    else {
        throw "Empty secret returned"
    }
}
catch {
    Write-Host "  WARNING: Could not create secret automatically." -ForegroundColor Yellow
    Write-Host "  Error: $_" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Manual step needed:" -ForegroundColor Yellow
    Write-Host "  1. Go to portal.azure.com > Azure Active Directory > App registrations" -ForegroundColor White
    Write-Host "  2. Find '$spName'" -ForegroundColor White
    Write-Host "  3. Certificates and secrets > New client secret" -ForegroundColor White
    $allWarnings += "Client secret could not be created automatically. Create manually in Azure Portal."
    $reportData.secretValue = "MANUAL CREATION REQUIRED"
    $reportData.secretExpiry = "N/A"
}
Write-Host ""

# ===============================================================
# STEP 6: Find all Databricks workspaces and assign roles
# ===============================================================
Write-Host "[6/8] Finding Databricks workspaces and assigning roles..." -ForegroundColor Yellow

$allSubs = az account list --query "[?state=='Enabled']" -o json 2>$null | ConvertFrom-Json
$allWorkspaces = @()

foreach ($sub in $allSubs) {
    Write-Host "  Subscription: $($sub.name)..." -ForegroundColor Gray -NoNewline

    try {
        $resources = az resource list --subscription $sub.id --resource-type "Microsoft.Databricks/workspaces" -o json 2>$null | ConvertFrom-Json

        if (-not $resources -or $resources.Count -eq 0) {
            Write-Host " no workspaces" -ForegroundColor Gray
            continue
        }

        Write-Host " $($resources.Count) workspace(s)" -ForegroundColor Green

        foreach ($r in $resources) {
            $wsInfo = @{
                name = $r.name
                url = ""
                subscription = $sub.name
                subscriptionId = $sub.id
                sku = ""
                location = $r.location
                resourceGroup = $r.resourceGroup
                resourceId = $r.id
                roleAssigned = $false
                spAdded = $false
                spAdmin = $false
                warehouseCount = 0
                error = ""
            }

            try {
                $detail = az resource show --ids $r.id -o json 2>$null | ConvertFrom-Json
                $wsInfo.url = "https://$($detail.properties.workspaceUrl)"
                $wsInfo.sku = $detail.sku.name
            }
            catch {
                $wsInfo.url = "unknown"
                $wsInfo.error = "Could not get workspace details"
            }

            # Assign Contributor role
            Write-Host "    $($r.name): Assigning Contributor..." -ForegroundColor Gray -NoNewline
            try {
                az role assignment create --assignee $appId --role "Contributor" --scope $r.id --subscription $sub.id -o none 2>$null
                $wsInfo.roleAssigned = $true
                Write-Host " OK" -ForegroundColor Green
            }
            catch {
                # Check if already assigned
                try {
                    $existing = az role assignment list --assignee $appId --scope $r.id --subscription $sub.id -o json 2>$null | ConvertFrom-Json
                    if ($existing -and $existing.Count -gt 0) {
                        $wsInfo.roleAssigned = $true
                        Write-Host " already assigned" -ForegroundColor Green
                    }
                    else {
                        Write-Host " FAILED (need Owner role)" -ForegroundColor Yellow
                        $wsInfo.error = "Role assignment failed - need Owner/UAA permissions"
                        $allWarnings += "Could not assign Contributor on $($r.name). Need Owner or User Access Administrator."
                    }
                }
                catch {
                    Write-Host " FAILED" -ForegroundColor Yellow
                    $wsInfo.error = "Role assignment failed"
                }
            }

            $allWorkspaces += $wsInfo
        }
    }
    catch {
        Write-Host " error scanning" -ForegroundColor Yellow
    }
}

Write-Host ""

# ===============================================================
# STEP 7: Add SP to each Databricks workspace via SCIM API
# ===============================================================
Write-Host "[7/8] Adding Service Principal to Databricks workspaces via API..." -ForegroundColor Yellow
Write-Host ""

for ($i = 0; $i -lt $allWorkspaces.Count; $i++) {
    $ws = $allWorkspaces[$i]
    if ($ws.url -eq "unknown") {
        Write-Host "  $($ws.name): Skipping (no URL)" -ForegroundColor Yellow
        continue
    }

    Write-Host "  $($ws.name) ($($ws.url))" -ForegroundColor White

    # Get token for this subscription
    try {
        az account set --subscription $ws.subscriptionId 2>$null
        $tokenRaw = az account get-access-token --resource $dbResource --query accessToken -o tsv 2>$null
        if (-not $tokenRaw) { throw "no token" }
        $token = $tokenRaw.Trim()
    }
    catch {
        Write-Host "    Could not get API token. Skipping." -ForegroundColor Yellow
        $ws.error = "Could not get Databricks API token"
        continue
    }

    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
    }

    # Check if SP already exists in workspace
    try {
        $encodedAppId = [System.Uri]::EscapeDataString("applicationId eq `"$appId`"")
        $scimCheck = Invoke-RestMethod -Uri "$($ws.url)/api/2.0/preview/scim/v2/ServicePrincipals?filter=$encodedAppId" -Headers $headers -Method Get

        if ($scimCheck.Resources -and $scimCheck.Resources.Count -gt 0) {
            $wsSpId = $scimCheck.Resources[0].id
            $ws.spAdded = $true
            Write-Host "    SP already in workspace. ID: $wsSpId" -ForegroundColor Yellow
        }
    }
    catch {}

    # Add SP if not present
    if (-not $ws.spAdded) {
        try {
            $scimBody = @{
                schemas = @("urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal")
                applicationId = $appId
                displayName = $spName
                active = $true
            } | ConvertTo-Json -Depth 5

            $scimResult = Invoke-RestMethod -Uri "$($ws.url)/api/2.0/preview/scim/v2/ServicePrincipals" -Headers $headers -Method Post -Body $scimBody
            $wsSpId = $scimResult.id
            $ws.spAdded = $true
            Write-Host "    Added to workspace. ID: $wsSpId" -ForegroundColor Green
        }
        catch {
            $errMsg = $_.Exception.Message
            try {
                $errDetail = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($errDetail.detail) { $errMsg = $errDetail.detail }
                elseif ($errDetail.message) { $errMsg = $errDetail.message }
            } catch {}
            Write-Host "    Could not add SP: $errMsg" -ForegroundColor Yellow
            if (-not $ws.error) { $ws.error = "SCIM add failed: $errMsg" }
        }
    }

    # Grant admin if SP was added
    if ($ws.spAdded -and $wsSpId) {
        try {
            $adminGroupResp = Invoke-RestMethod -Uri "$($ws.url)/api/2.0/preview/scim/v2/Groups?filter=displayName%20eq%20%22admins%22" -Headers $headers -Method Get

            if ($adminGroupResp.Resources -and $adminGroupResp.Resources.Count -gt 0) {
                $adminGrpId = $adminGroupResp.Resources[0].id

                $patchBody = @{
                    schemas = @("urn:ietf:params:scim:api:messages:2.0:PatchOp")
                    Operations = @(
                        @{
                            op = "add"
                            value = @{
                                members = @(
                                    @{ value = $wsSpId }
                                )
                            }
                        }
                    )
                } | ConvertTo-Json -Depth 10

                Invoke-RestMethod -Uri "$($ws.url)/api/2.0/preview/scim/v2/Groups/$adminGrpId" -Headers $headers -Method Patch -Body $patchBody | Out-Null
                $ws.spAdmin = $true
                Write-Host "    Admin access granted." -ForegroundColor Green
            }
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host "    Admin grant failed (may already be admin): $errMsg" -ForegroundColor Yellow
        }
    }

    # Count warehouses
    if ($ws.spAdded) {
        try {
            $whResp = Invoke-RestMethod -Uri "$($ws.url)/api/2.0/sql/warehouses" -Headers $headers -Method Get
            if ($whResp.warehouses) { $ws.warehouseCount = $whResp.warehouses.Count }
            Write-Host "    SQL Warehouses visible: $($ws.warehouseCount)" -ForegroundColor Green
        }
        catch {}
    }

    Write-Host ""
    $allWorkspaces[$i] = $ws
}

$reportData.workspaces = $allWorkspaces

# ===============================================================
# STEP 8: Generate HTML Report
# ===============================================================
Write-Host "[8/8] Generating HTML report..." -ForegroundColor Yellow

$wsRows = ""
foreach ($ws in $allWorkspaces) {
    $roleColor = if ($ws.roleAssigned) { "#4ade80" } else { "#f87171" }
    $roleText = if ($ws.roleAssigned) { "Contributor" } else { "Failed" }
    $spColor = if ($ws.spAdded) { "#4ade80" } else { "#f87171" }
    $spText = if ($ws.spAdded) { "Added" } else { "Failed" }
    $adminColor = if ($ws.spAdmin) { "#4ade80" } else { "#fbbf24" }
    $adminText = if ($ws.spAdmin) { "Admin" } else { "Pending" }
    $errText = if ($ws.error) { $ws.error } else { "-" }

    $wsRows += "<tr>"
    $wsRows += "<td>$($ws.name)</td>"
    $wsRows += "<td><a href=`"$($ws.url)`" target=`"_blank`">$($ws.url)</a></td>"
    $wsRows += "<td>$($ws.subscription)</td>"
    $wsRows += "<td>$($ws.sku)</td>"
    $wsRows += "<td>$($ws.location)</td>"
    $wsRows += "<td style=`"color:$roleColor;font-weight:bold`">$roleText</td>"
    $wsRows += "<td style=`"color:$spColor;font-weight:bold`">$spText</td>"
    $wsRows += "<td style=`"color:$adminColor;font-weight:bold`">$adminText</td>"
    $wsRows += "<td>$($ws.warehouseCount)</td>"
    $wsRows += "<td style=`"font-size:11px`">$errText</td>"
    $wsRows += "</tr>`n"
}

$warningsHtml = ""
if ($allWarnings.Count -gt 0) {
    $warnItems = ""
    foreach ($w in $allWarnings) { $warnItems += "<li>$w</li>`n" }
    $warningsHtml = "<div class=`"section`"><h2>Warnings</h2><ul style=`"color:#fbbf24`">$warnItems</ul></div>"
}

$errorsHtml = ""
if ($allErrors.Count -gt 0) {
    $errItems = ""
    foreach ($e in $allErrors) { $errItems += "<li>$e</li>`n" }
    $errorsHtml = "<div class=`"section`"><h2>Errors</h2><ul style=`"color:#f87171`">$errItems</ul></div>"
}

$secretDisplay = $reportData.secretValue
if (-not $secretDisplay) { $secretDisplay = "COULD NOT CREATE - SEE WARNINGS" }

$addedCount = ($allWorkspaces | Where-Object { $_.spAdded }).Count
$totalCount = $allWorkspaces.Count
$roleCount = ($allWorkspaces | Where-Object { $_.roleAssigned }).Count
$adminCount = ($allWorkspaces | Where-Object { $_.spAdmin }).Count

$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Databricks Service Account Report</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',Tahoma,sans-serif;background:#0f172a;color:#e2e8f0;padding:40px}
.container{max-width:1300px;margin:0 auto}
.header{background:linear-gradient(135deg,#1e3a5f,#0f172a);border:1px solid #334155;border-radius:12px;padding:30px;margin-bottom:30px;text-align:center}
.header h1{font-size:28px;color:#60a5fa;margin-bottom:8px}
.header p{color:#94a3b8;font-size:14px}
.summary-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin-bottom:20px}
.summary-card{background:#1e293b;border:1px solid #334155;border-radius:12px;padding:20px;text-align:center}
.summary-card .num{font-size:36px;font-weight:bold;color:#60a5fa}
.summary-card .lbl{font-size:12px;color:#94a3b8;text-transform:uppercase;margin-top:4px}
.section{background:#1e293b;border:1px solid #334155;border-radius:12px;padding:24px;margin-bottom:20px}
.section h2{color:#60a5fa;font-size:20px;margin-bottom:16px;border-bottom:1px solid #334155;padding-bottom:8px}
.cred-grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}
.cred-item{background:#0f172a;border:1px solid #334155;border-radius:8px;padding:16px}
.cred-item .label{font-size:12px;color:#94a3b8;text-transform:uppercase;letter-spacing:1px;margin-bottom:4px}
.cred-item .value{font-size:14px;color:#f1f5f9;word-break:break-all;font-family:Consolas,monospace}
.secret-box{background:#7f1d1d;border:2px solid #dc2626;border-radius:8px;padding:20px;margin-top:16px}
.secret-box .label{color:#fca5a5;font-size:14px;font-weight:bold;margin-bottom:8px}
.secret-box .value{color:#fef2f2;font-size:16px;font-family:Consolas,monospace;word-break:break-all}
.secret-box .warning{color:#fca5a5;font-size:12px;margin-top:8px}
table{width:100%;border-collapse:collapse;margin-top:12px}
th{background:#334155;color:#e2e8f0;padding:10px;text-align:left;font-size:12px}
td{padding:10px;border-bottom:1px solid #334155;font-size:12px}
tr:hover{background:#334155}
a{color:#60a5fa;text-decoration:none}
a:hover{text-decoration:underline}
pre{background:#0f172a;border:1px solid #334155;border-radius:8px;padding:16px;overflow-x:auto;font-family:Consolas,monospace;font-size:13px;color:#e2e8f0;margin-top:8px}
code{background:#0f172a;padding:2px 6px;border-radius:4px;font-family:Consolas,monospace;font-size:13px;color:#fbbf24}
.footer{text-align:center;color:#64748b;font-size:12px;margin-top:30px;padding:20px}
@media print{body{background:#fff;color:#000}.section{border-color:#ccc}th{background:#eee;color:#000}.header{background:#f0f0f0}.header h1{color:#1e40af}}
</style>
</head>
<body>
<div class="container">

<div class="header">
<h1>Databricks Service Account Report</h1>
<p>Generated: $($reportData.date) | Created by: $($reportData.userName)</p>
<p>Purpose: Replace personal user accounts (Shaun Raj) with service principal for production Databricks workloads</p>
</div>

<div class="summary-grid">
<div class="summary-card"><div class="num">$totalCount</div><div class="lbl">Workspaces Found</div></div>
<div class="summary-card"><div class="num">$roleCount</div><div class="lbl">Roles Assigned</div></div>
<div class="summary-card"><div class="num">$addedCount</div><div class="lbl">SP Added</div></div>
<div class="summary-card"><div class="num">$adminCount</div><div class="lbl">Admin Access</div></div>
</div>

<div class="section">
<h2>Service Principal Credentials</h2>
<div class="cred-grid">
<div class="cred-item"><div class="label">Display Name</div><div class="value">$($reportData.spName)</div></div>
<div class="cred-item"><div class="label">Application (Client) ID</div><div class="value">$($reportData.appId)</div></div>
<div class="cred-item"><div class="label">Object ID</div><div class="value">$($reportData.objectId)</div></div>
<div class="cred-item"><div class="label">Tenant ID</div><div class="value">$($reportData.tenantId)</div></div>
<div class="cred-item"><div class="label">Subscription</div><div class="value">$($reportData.subscription)</div></div>
<div class="cred-item"><div class="label">Secret Expires</div><div class="value">$($reportData.secretExpiry)</div></div>
</div>
<div class="secret-box">
<div class="label">CLIENT SECRET</div>
<div class="value">$secretDisplay</div>
<div class="warning">Save immediately. Azure will not show this again. Store in Azure Key Vault or a secure password manager.</div>
</div>
</div>

<div class="section">
<h2>Workspace Details</h2>
<table>
<thead><tr>
<th>Workspace</th><th>URL</th><th>Subscription</th><th>SKU</th><th>Region</th><th>Role</th><th>SP</th><th>Admin</th><th>Warehouses</th><th>Notes</th>
</tr></thead>
<tbody>
$wsRows
</tbody>
</table>
</div>

<div class="section">
<h2>Usage: Python OAuth Token</h2>
<pre>
import requests

token_url = "https://login.microsoftonline.com/$($reportData.tenantId)/oauth2/v2.0/token"
data = {
    "grant_type": "client_credentials",
    "client_id": "$($reportData.appId)",
    "client_secret": "YOUR_SECRET_HERE",
    "scope": "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d/.default"
}
response = requests.post(token_url, data=data)
access_token = response.json()["access_token"]
</pre>
</div>

<div class="section">
<h2>Usage: Databricks SQL Connection (Python)</h2>
<pre>
from databricks import sql

connection = sql.connect(
    server_hostname = "adb-XXXXX.X.azuredatabricks.net",
    http_path       = "/sql/1.0/warehouses/WAREHOUSE_ID",
    access_token    = access_token  # from OAuth above
)

cursor = connection.cursor()
cursor.execute("SELECT 1")
print(cursor.fetchall())
cursor.close()
connection.close()
</pre>
</div>

<div class="section">
<h2>Usage: PowerShell OAuth Token</h2>
<pre>
$body = @{
    grant_type    = "client_credentials"
    client_id     = "$($reportData.appId)"
    client_secret = "YOUR_SECRET_HERE"
    scope         = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d/.default"
}
$resp = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$($reportData.tenantId)/oauth2/v2.0/token" -Method Post -Body $body
$resp.access_token
</pre>
</div>

<div class="section">
<h2>Usage: Store Secret in Azure Key Vault</h2>
<pre>
az keyvault secret set --vault-name YOUR_VAULT_NAME --name databricks-sp-secret --value "YOUR_SECRET_HERE"
</pre>
</div>

<div class="section">
<h2>Next Steps</h2>
<table>
<thead><tr><th>#</th><th>Action</th><th>Owner</th><th>Priority</th></tr></thead>
<tbody>
<tr><td>1</td><td>Save client secret to Azure Key Vault or secure vault</td><td>Syed Rizvi</td><td style="color:#f87171;font-weight:bold">IMMEDIATE</td></tr>
<tr><td>2</td><td>Update SQL Python connector scripts to use this service principal instead of Shaun Raj's account</td><td>Dev Team</td><td style="color:#f87171;font-weight:bold">HIGH</td></tr>
<tr><td>3</td><td>Test all warehouse connections using the new service principal</td><td>Brian Burge</td><td style="color:#fbbf24;font-weight:bold">HIGH</td></tr>
<tr><td>4</td><td>Remove Shaun Raj's personal account from production scripts</td><td>Admin</td><td style="color:#fbbf24;font-weight:bold">MEDIUM</td></tr>
<tr><td>5</td><td>Set calendar reminder for secret rotation ($($reportData.secretExpiry))</td><td>Syed Rizvi</td><td style="color:#fbbf24;font-weight:bold">MEDIUM</td></tr>
<tr><td>6</td><td>Document service principal in team runbook / wiki</td><td>Syed Rizvi</td><td style="color:#4ade80;font-weight:bold">LOW</td></tr>
</tbody>
</table>
</div>

<div class="section">
<h2>Context</h2>
<p style="line-height:1.8">
On Feb 3, 2026, John Pinto identified that SQL Python connector scripts on pyx-warehouse-prod were running
under <strong>Shaun Raj's personal user account</strong>. This is a risk because if the user account is
disabled, locked, or the employee leaves, all production Databricks workloads would break.
This service principal (<code>$($reportData.spName)</code>) was created to replace the personal account.
Service principals are not tied to any individual and will continue running regardless of personnel changes.
</p>
</div>

$warningsHtml

$errorsHtml

<div class="footer">
<p>Databricks Service Account Setup Report | $($reportData.date)</p>
</div>

</div>
</body>
</html>
"@

$reportPath = Join-Path $PSScriptRoot "databricks_service_account_report.html"
if (-not $PSScriptRoot) { $reportPath = "databricks_service_account_report.html" }

$htmlContent | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host "  Report saved: $reportPath" -ForegroundColor Green

# Also try to open it
try { Start-Process $reportPath } catch {}

Write-Host ""

# ===============================================================
# SUMMARY
# ===============================================================
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  COMPLETE" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Service Principal: $spName" -ForegroundColor Green
Write-Host "  App (Client) ID:  $($reportData.appId)" -ForegroundColor Green
Write-Host "  Object ID:        $spObjectId" -ForegroundColor Green
Write-Host "  Tenant ID:        $($reportData.tenantId)" -ForegroundColor Green
Write-Host ""

if ($secretValue) {
    Write-Host "  CLIENT SECRET:    $secretValue" -ForegroundColor Red
    Write-Host "  SAVE THIS NOW!" -ForegroundColor Red
}

Write-Host ""
Write-Host "  Workspaces: $addedCount / $totalCount configured" -ForegroundColor Green
Write-Host "  Roles assigned: $roleCount / $totalCount" -ForegroundColor Green
Write-Host "  Admin access: $adminCount / $totalCount" -ForegroundColor Green
Write-Host ""

if ($allWarnings.Count -gt 0) {
    Write-Host "  Warnings: $($allWarnings.Count)" -ForegroundColor Yellow
    foreach ($w in $allWarnings) { Write-Host "    - $w" -ForegroundColor Yellow }
    Write-Host ""
}

if ($allErrors.Count -gt 0) {
    Write-Host "  Errors: $($allErrors.Count)" -ForegroundColor Red
    foreach ($e in $allErrors) { Write-Host "    - $e" -ForegroundColor Red }
    Write-Host ""
}

Write-Host "  Report: $reportPath" -ForegroundColor Green
Write-Host ""
