# ============================================================================
# ACTIVE DIRECTORY COMPLETE SECURITY AUDIT
# Checks On-Premises AD + Azure AD (Entra ID)
# Auto-detects subscriptions, generates detailed security report
# ============================================================================

param(
    [switch]$IncludeOnPremAD,
    [switch]$IncludeAzureAD,
    [switch]$AllSubscriptions,
    [string]$OutputPath = "$env:USERPROFILE\Desktop"
)

$ErrorActionPreference = "Continue"

# ============================================================================
# INITIALIZATION
# ============================================================================

$script:findings = @()
$script:userStats = @{}
$script:groupStats = @{}
$script:securityIssues = @()
$script:costAnalysis = @{}
$script:resources = @()

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "ACTIVE DIRECTORY COMPLETE SECURITY AUDIT" -ForegroundColor Cyan
Write-Host "On-Premises AD + Azure AD (Entra ID)" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

function Write-Status {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Add-Finding {
    param(
        [string]$Category,
        [string]$Severity,
        [string]$Finding,
        [string]$Recommendation
    )
    $script:findings += [PSCustomObject]@{
        Category       = $Category
        Severity       = $Severity
        Finding        = $Finding
        Recommendation = $Recommendation
        Timestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
}

function Add-SecurityIssue {
    param(
        [string]$Type,
        [string]$Description,
        [string]$Risk,
        [string]$Remediation
    )
    $script:securityIssues += [PSCustomObject]@{
        Type        = $Type
        Description = $Description
        Risk        = $Risk
        Remediation = $Remediation
    }
}

# ============================================================================
# MODULE CHECKS
# ============================================================================

Write-Status "[1/10] Checking required modules..." "Yellow"

$requiredModules = @(
    @{Name = "ActiveDirectory"; Description = "On-Premises AD" },
    @{Name = "AzureAD"; Description = "Azure AD (Legacy)" },
    @{Name = "Microsoft.Graph"; Description = "Microsoft Graph" },
    @{Name = "Az.Accounts"; Description = "Azure Subscriptions" },
    @{Name = "Az.Resources"; Description = "Azure Resources" }
)

$availableModules = @{}
foreach ($module in $requiredModules) {
    $installed = Get-Module -ListAvailable -Name $module.Name
    $availableModules[$module.Name] = $installed -ne $null
    
    if ($installed) {
        Write-Status "  ✓ $($module.Description) module available" "Green"
    } else {
        Write-Status "  ✗ $($module.Description) module not installed" "Yellow"
    }
}

# Auto-detect environment
$hasOnPremAD = $availableModules["ActiveDirectory"] -and (Test-Connection -ComputerName $env:USERDNSDOMAIN -Count 1 -Quiet 2>$null)
$hasAzureAccess = $availableModules["Az.Accounts"]

Write-Host ""
Write-Status "Environment Detection:" "Cyan"
if ($hasOnPremAD) {
    Write-Status "  ✓ On-Premises AD detected" "Green"
    $IncludeOnPremAD = $true
}
if ($hasAzureAccess) {
    Write-Status "  ✓ Azure access available" "Green"
    $IncludeAzureAD = $true
}

# ============================================================================
# ON-PREMISES ACTIVE DIRECTORY AUDIT
# ============================================================================

if ($IncludeOnPremAD -and $hasOnPremAD) {
    Write-Host ""
    Write-Status "[2/10] Auditing On-Premises Active Directory..." "Yellow"
    
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        
        # Get Domain Info
        Write-Status "  Getting domain information..." "White"
        $domain = Get-ADDomain
        $forest = Get-ADForest
        
        $script:userStats["OnPrem"] = @{
            Domain          = $domain.DNSRoot
            ForestLevel     = $forest.ForestMode
            DomainLevel     = $domain.DomainMode
            DomainControllers = @()
        }
        
        # Domain Controllers
        Write-Status "  Checking domain controllers..." "White"
        $dcs = Get-ADDomainController -Filter *
        foreach ($dc in $dcs) {
            $script:userStats["OnPrem"].DomainControllers += [PSCustomObject]@{
                Name            = $dc.Name
                IPAddress       = $dc.IPv4Address
                Site            = $dc.Site
                OperatingSystem = $dc.OperatingSystem
                IsGlobalCatalog = $dc.IsGlobalCatalog
                IsReadOnly      = $dc.IsReadOnly
            }
        }
        
        Write-Status "    Found $($dcs.Count) domain controller(s)" "Green"
        
        # Users Audit
        Write-Status "  Auditing users..." "White"
        $allUsers = Get-ADUser -Filter * -Properties *
        
        $enabledUsers = $allUsers | Where-Object { $_.Enabled -eq $true }
        $disabledUsers = $allUsers | Where-Object { $_.Enabled -eq $false }
        $staleUsers = $enabledUsers | Where-Object { 
            $_.LastLogonDate -and $_.LastLogonDate -lt (Get-Date).AddDays(-90) 
        }
        $neverLoggedIn = $enabledUsers | Where-Object { -not $_.LastLogonDate }
        $noPasswordExpiry = $enabledUsers | Where-Object { $_.PasswordNeverExpires -eq $true }
        $adminUsers = Get-ADGroupMember -Identity "Domain Admins" -Recursive
        
        $script:userStats["OnPrem"].TotalUsers = $allUsers.Count
        $script:userStats["OnPrem"].EnabledUsers = $enabledUsers.Count
        $script:userStats["OnPrem"].DisabledUsers = $disabledUsers.Count
        $script:userStats["OnPrem"].StaleUsers = $staleUsers.Count
        $script:userStats["OnPrem"].NeverLoggedIn = $neverLoggedIn.Count
        $script:userStats["OnPrem"].NoPasswordExpiry = $noPasswordExpiry.Count
        $script:userStats["OnPrem"].DomainAdmins = $adminUsers.Count
        
        Write-Status "    Total users: $($allUsers.Count)" "White"
        Write-Status "    Enabled: $($enabledUsers.Count)" "Green"
        Write-Status "    Disabled: $($disabledUsers.Count)" "Yellow"
        Write-Status "    Stale (90+ days): $($staleUsers.Count)" "Red"
        Write-Status "    Domain Admins: $($adminUsers.Count)" "Cyan"
        
        # Security Issues
        if ($staleUsers.Count -gt 0) {
            Add-Finding -Category "Users" -Severity "High" `
                -Finding "$($staleUsers.Count) stale user accounts (inactive 90+ days)" `
                -Recommendation "Review and disable/delete inactive accounts"
        }
        
        if ($noPasswordExpiry.Count -gt 0) {
            Add-SecurityIssue -Type "Password Policy" `
                -Description "$($noPasswordExpiry.Count) accounts with non-expiring passwords" `
                -Risk "High - Increases attack surface" `
                -Remediation "Enable password expiration for all accounts except service accounts"
        }
        
        if ($adminUsers.Count -gt 5) {
            Add-SecurityIssue -Type "Privileged Access" `
                -Description "$($adminUsers.Count) Domain Admin accounts (recommended: <5)" `
                -Risk "Critical - Too many privileged accounts" `
                -Remediation "Reduce number of Domain Admins, use RBAC and JIT access"
        }
        
        # Groups Audit
        Write-Status "  Auditing groups..." "White"
        $allGroups = Get-ADGroup -Filter * -Properties *
        $emptyGroups = $allGroups | Where-Object { 
            -not (Get-ADGroupMember -Identity $_.DistinguishedName)
        }
        
        $script:groupStats["OnPrem"] = @{
            TotalGroups  = $allGroups.Count
            EmptyGroups  = $emptyGroups.Count
            SecurityGroups = ($allGroups | Where-Object { $_.GroupCategory -eq "Security" }).Count
        }
        
        Write-Status "    Total groups: $($allGroups.Count)" "White"
        Write-Status "    Empty groups: $($emptyGroups.Count)" "Yellow"
        
        if ($emptyGroups.Count -gt 0) {
            Add-Finding -Category "Groups" -Severity "Low" `
                -Finding "$($emptyGroups.Count) empty groups found" `
                -Recommendation "Remove unused groups to reduce clutter"
        }
        
        # Password Policy
        Write-Status "  Checking password policy..." "White"
        $defaultPolicy = Get-ADDefaultDomainPasswordPolicy
        
        if ($defaultPolicy.MaxPasswordAge.Days -gt 90) {
            Add-SecurityIssue -Type "Password Policy" `
                -Description "Password expiration set to $($defaultPolicy.MaxPasswordAge.Days) days" `
                -Risk "Medium - Long password age" `
                -Remediation "Set password expiration to 60-90 days"
        }
        
        if ($defaultPolicy.MinPasswordLength -lt 12) {
            Add-SecurityIssue -Type "Password Policy" `
                -Description "Minimum password length: $($defaultPolicy.MinPasswordLength) characters" `
                -Risk "High - Weak password requirements" `
                -Remediation "Set minimum password length to 12+ characters"
        }
        
        Write-Status "  On-Premises AD audit complete" "Green"
        
    } catch {
        Write-Status "  ERROR: Failed to audit On-Premises AD - $_" "Red"
    }
}

# ============================================================================
# AZURE AD (ENTRA ID) AUDIT
# ============================================================================

if ($IncludeAzureAD -and $hasAzureAccess) {
    Write-Host ""
    Write-Status "[3/10] Connecting to Azure..." "Yellow"
    
    try {
        # Azure Login
        $account = Get-AzContext
        if (-not $account) {
            Write-Status "  Not logged in, starting authentication..." "Yellow"
            Connect-AzAccount
            $account = Get-AzContext
        }
        
        Write-Status "  ✓ Connected as: $($account.Account.Id)" "Green"
        
        # Get Subscriptions
        Write-Status ""
        Write-Status "[4/10] Loading Azure subscriptions..." "Yellow"
        $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
        
        Write-Status "  Found $($subscriptions.Count) active subscription(s)" "Green"
        
        foreach ($sub in $subscriptions) {
            Write-Status "    - $($sub.Name)" "White"
        }
        
        # Connect to Microsoft Graph
        Write-Status ""
        Write-Status "[5/10] Connecting to Microsoft Graph..." "Yellow"
        
        try {
            if ($availableModules["Microsoft.Graph"]) {
                Import-Module Microsoft.Graph.Users -ErrorAction Stop
                Import-Module Microsoft.Graph.Groups -ErrorAction Stop
                Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
                
                Connect-MgGraph -Scopes "User.Read.All", "Group.Read.All", "Directory.Read.All" -NoWelcome -ErrorAction Stop
                
                Write-Status "  ✓ Connected to Microsoft Graph" "Green"
                
                # Azure AD Users
                Write-Status ""
                Write-Status "[6/10] Auditing Azure AD users..." "Yellow"
                
                $azureUsers = Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,AccountEnabled,CreatedDateTime,SignInActivity,AssignedLicenses
                
                $azureEnabledUsers = $azureUsers | Where-Object { $_.AccountEnabled -eq $true }
                $azureDisabledUsers = $azureUsers | Where-Object { $_.AccountEnabled -eq $false }
                $azureStaleUsers = $azureEnabledUsers | Where-Object {
                    $_.SignInActivity.LastSignInDateTime -and 
                    $_.SignInActivity.LastSignInDateTime -lt (Get-Date).AddDays(-90)
                }
                $azureNeverSignedIn = $azureEnabledUsers | Where-Object { -not $_.SignInActivity.LastSignInDateTime }
                $azureLicensedUsers = $azureUsers | Where-Object { $_.AssignedLicenses.Count -gt 0 }
                
                $script:userStats["Azure"] = @{
                    TotalUsers      = $azureUsers.Count
                    EnabledUsers    = $azureEnabledUsers.Count
                    DisabledUsers   = $azureDisabledUsers.Count
                    StaleUsers      = $azureStaleUsers.Count
                    NeverSignedIn   = $azureNeverSignedIn.Count
                    LicensedUsers   = $azureLicensedUsers.Count
                }
                
                Write-Status "    Total users: $($azureUsers.Count)" "White"
                Write-Status "    Enabled: $($azureEnabledUsers.Count)" "Green"
                Write-Status "    Disabled: $($azureDisabledUsers.Count)" "Yellow"
                Write-Status "    Stale (90+ days): $($azureStaleUsers.Count)" "Red"
                Write-Status "    Licensed: $($azureLicensedUsers.Count)" "Cyan"
                
                # Azure AD Groups
                Write-Status ""
                Write-Status "[7/10] Auditing Azure AD groups..." "Yellow"
                
                $azureGroups = Get-MgGroup -All
                $script:groupStats["Azure"] = @{
                    TotalGroups = $azureGroups.Count
                }
                
                Write-Status "    Total groups: $($azureGroups.Count)" "White"
                
                # Security Findings
                if ($azureStaleUsers.Count -gt 0) {
                    Add-Finding -Category "Azure AD Users" -Severity "High" `
                        -Finding "$($azureStaleUsers.Count) stale Azure AD accounts (inactive 90+ days)" `
                        -Recommendation "Review and disable inactive Azure AD accounts"
                }
                
                $unusedLicenses = $azureUsers.Count - $azureLicensedUsers.Count
                if ($unusedLicenses -gt 0) {
                    $estimatedMonthlySavings = $unusedLicenses * 20
                    Add-Finding -Category "Cost Optimization" -Severity "Medium" `
                        -Finding "$unusedLicenses users without licenses (potential unused licenses)" `
                        -Recommendation "Review license assignment, potential savings: `$$estimatedMonthlySavings/month"
                    
                    $script:costAnalysis["UnusedLicenses"] = @{
                        Count            = $unusedLicenses
                        MonthlySavings   = $estimatedMonthlySavings
                        AnnualSavings    = $estimatedMonthlySavings * 12
                    }
                }
                
            } else {
                Write-Status "  Microsoft Graph module not available, skipping detailed Azure AD audit" "Yellow"
            }
        } catch {
            Write-Status "  WARNING: Could not connect to Microsoft Graph - $_" "Yellow"
        }
        
        # RBAC Audit across subscriptions
        Write-Status ""
        Write-Status "[8/10] Auditing RBAC roles across subscriptions..." "Yellow"
        
        $allRoleAssignments = @()
        foreach ($sub in $subscriptions) {
            Set-AzContext -Subscription $sub.Id | Out-Null
            Write-Status "  Checking subscription: $($sub.Name)" "White"
            
            $roleAssignments = Get-AzRoleAssignment
            $allRoleAssignments += $roleAssignments
            
            # Check for Owner assignments
            $owners = $roleAssignments | Where-Object { $_.RoleDefinitionName -eq "Owner" }
            if ($owners.Count -gt 5) {
                Add-SecurityIssue -Type "RBAC" `
                    -Description "Subscription '$($sub.Name)' has $($owners.Count) Owner role assignments" `
                    -Risk "High - Too many privileged accounts" `
                    -Remediation "Reduce Owner assignments, use Contributor or custom roles"
            }
        }
        
        $uniqueRoles = $allRoleAssignments | Select-Object -ExpandProperty RoleDefinitionName -Unique
        Write-Status "    Total role assignments: $($allRoleAssignments.Count)" "White"
        Write-Status "    Unique roles: $($uniqueRoles.Count)" "White"
        
        # Resource Inventory
        Write-Status ""
        Write-Status "[9/10] Inventorying Azure resources..." "Yellow"
        
        foreach ($sub in $subscriptions) {
            Set-AzContext -Subscription $sub.Id | Out-Null
            $resources = Get-AzResource
            
            foreach ($resource in $resources) {
                $script:resources += [PSCustomObject]@{
                    Subscription = $sub.Name
                    Name         = $resource.Name
                    Type         = $resource.ResourceType
                    Location     = $resource.Location
                    ResourceGroup = $resource.ResourceGroupName
                }
            }
        }
        
        Write-Status "    Total resources across subscriptions: $($script:resources.Count)" "White"
        
    } catch {
        Write-Status "  ERROR: Failed to audit Azure - $_" "Red"
    }
}

# ============================================================================
# GENERATE REPORT
# ============================================================================

Write-Host ""
Write-Status "[10/10] Generating security report..." "Yellow"

$reportDate = Get-Date -Format "yyyy-MM-dd_HHmmss"
$reportPath = Join-Path $OutputPath "AD-Security-Audit-Report-$reportDate.html"

$htmlReport = @"
<!DOCTYPE html>
<html>
<head>
    <title>Active Directory Security Audit Report</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
        }
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 10px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        .header h1 { font-size: 2.5em; margin-bottom: 10px; }
        .header p { font-size: 1.2em; opacity: 0.9; }
        .content { padding: 30px; }
        .section {
            margin-bottom: 40px;
            background: #f8f9fa;
            padding: 25px;
            border-radius: 8px;
            border-left: 5px solid #667eea;
        }
        .section h2 {
            color: #667eea;
            margin-bottom: 20px;
            font-size: 1.8em;
            border-bottom: 2px solid #e0e0e0;
            padding-bottom: 10px;
        }
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin: 20px 0;
        }
        .stat-card {
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
            text-align: center;
        }
        .stat-number {
            font-size: 2.5em;
            font-weight: bold;
            color: #667eea;
            margin: 10px 0;
        }
        .stat-label {
            color: #666;
            font-size: 0.9em;
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        .findings-table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
            background: white;
            border-radius: 8px;
            overflow: hidden;
        }
        .findings-table th {
            background: #667eea;
            color: white;
            padding: 15px;
            text-align: left;
            font-weight: 600;
        }
        .findings-table td {
            padding: 12px 15px;
            border-bottom: 1px solid #e0e0e0;
        }
        .findings-table tr:hover { background: #f5f5f5; }
        .severity-critical { color: #dc3545; font-weight: bold; }
        .severity-high { color: #fd7e14; font-weight: bold; }
        .severity-medium { color: #ffc107; font-weight: bold; }
        .severity-low { color: #28a745; font-weight: bold; }
        .cost-savings {
            background: #d4edda;
            border: 2px solid #28a745;
            padding: 20px;
            border-radius: 8px;
            margin: 20px 0;
        }
        .cost-savings h3 {
            color: #155724;
            margin-bottom: 15px;
        }
        .cost-number {
            font-size: 3em;
            color: #28a745;
            font-weight: bold;
        }
        .footer {
            background: #f8f9fa;
            padding: 20px;
            text-align: center;
            color: #666;
            border-top: 2px solid #e0e0e0;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔒 Active Directory Security Audit Report</h1>
            <p>Generated: $(Get-Date -Format "MMMM dd, yyyy HH:mm:ss")</p>
        </div>
        
        <div class="content">
"@

# Executive Summary
$htmlReport += @"
            <div class="section">
                <h2>📊 Executive Summary</h2>
                <div class="stats-grid">
"@

if ($script:userStats.ContainsKey("OnPrem")) {
    $htmlReport += @"
                    <div class="stat-card">
                        <div class="stat-label">On-Prem Domain</div>
                        <div class="stat-number">$($script:userStats["OnPrem"].Domain)</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-label">Domain Controllers</div>
                        <div class="stat-number">$($script:userStats["OnPrem"].DomainControllers.Count)</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-label">On-Prem Users</div>
                        <div class="stat-number">$($script:userStats["OnPrem"].TotalUsers)</div>
                    </div>
"@
}

if ($script:userStats.ContainsKey("Azure")) {
    $htmlReport += @"
                    <div class="stat-card">
                        <div class="stat-label">Azure AD Users</div>
                        <div class="stat-number">$($script:userStats["Azure"].TotalUsers)</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-label">Azure Subscriptions</div>
                        <div class="stat-number">$($subscriptions.Count)</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-label">Azure Resources</div>
                        <div class="stat-number">$($script:resources.Count)</div>
                    </div>
"@
}

$htmlReport += @"
                    <div class="stat-card">
                        <div class="stat-label">Security Findings</div>
                        <div class="stat-number" style="color: #dc3545;">$($script:findings.Count)</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-label">Security Issues</div>
                        <div class="stat-number" style="color: #fd7e14;">$($script:securityIssues.Count)</div>
                    </div>
                </div>
            </div>
"@

# Cost Savings
if ($script:costAnalysis.Count -gt 0) {
    $totalAnnualSavings = ($script:costAnalysis.Values | Measure-Object -Property AnnualSavings -Sum).Sum
    $htmlReport += @"
            <div class="section">
                <h2>💰 Cost Optimization Opportunities</h2>
                <div class="cost-savings">
                    <h3>Potential Annual Savings</h3>
                    <div class="cost-number">`$$totalAnnualSavings</div>
                    <p>Based on identified unused licenses and resources</p>
                </div>
            </div>
"@
}

# Security Findings
if ($script:findings.Count -gt 0) {
    $htmlReport += @"
            <div class="section">
                <h2>🔍 Security Findings</h2>
                <table class="findings-table">
                    <thead>
                        <tr>
                            <th>Category</th>
                            <th>Severity</th>
                            <th>Finding</th>
                            <th>Recommendation</th>
                        </tr>
                    </thead>
                    <tbody>
"@
    foreach ($finding in $script:findings) {
        $severityClass = "severity-" + $finding.Severity.ToLower()
        $htmlReport += @"
                        <tr>
                            <td>$($finding.Category)</td>
                            <td class="$severityClass">$($finding.Severity)</td>
                            <td>$($finding.Finding)</td>
                            <td>$($finding.Recommendation)</td>
                        </tr>
"@
    }
    $htmlReport += @"
                    </tbody>
                </table>
            </div>
"@
}

# Security Issues
if ($script:securityIssues.Count -gt 0) {
    $htmlReport += @"
            <div class="section">
                <h2>⚠️ Security Issues Requiring Attention</h2>
                <table class="findings-table">
                    <thead>
                        <tr>
                            <th>Type</th>
                            <th>Description</th>
                            <th>Risk</th>
                            <th>Remediation</th>
                        </tr>
                    </thead>
                    <tbody>
"@
    foreach ($issue in $script:securityIssues) {
        $htmlReport += @"
                        <tr>
                            <td>$($issue.Type)</td>
                            <td>$($issue.Description)</td>
                            <td class="severity-high">$($issue.Risk)</td>
                            <td>$($issue.Remediation)</td>
                        </tr>
"@
    }
    $htmlReport += @"
                    </tbody>
                </table>
            </div>
"@
}

# Resource Inventory
if ($script:resources.Count -gt 0) {
    $resourcesByLocation = $script:resources | Group-Object Location | Sort-Object Count -Descending
    $htmlReport += @"
            <div class="section">
                <h2>🌍 Resource Distribution by Location</h2>
                <div class="stats-grid">
"@
    foreach ($location in $resourcesByLocation | Select-Object -First 6) {
        $htmlReport += @"
                    <div class="stat-card">
                        <div class="stat-label">$($location.Name)</div>
                        <div class="stat-number" style="font-size: 2em;">$($location.Count)</div>
                    </div>
"@
    }
    $htmlReport += @"
                </div>
            </div>
"@
}

$htmlReport += @"
        </div>
        
        <div class="footer">
            <p>Report generated by AD Security Audit Script</p>
            <p>© $(Get-Date -Format yyyy) - Confidential</p>
        </div>
    </div>
</body>
</html>
"@

$htmlReport | Out-File -FilePath $reportPath -Encoding UTF8

# Open Report
Start-Process $reportPath

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Green
Write-Host "AUDIT COMPLETE" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Report saved to:" -ForegroundColor Cyan
Write-Host $reportPath -ForegroundColor White
Write-Host ""
Write-Host "Summary:" -ForegroundColor Yellow

if ($script:userStats.ContainsKey("OnPrem")) {
    Write-Host "  On-Prem Users: $($script:userStats["OnPrem"].TotalUsers)" -ForegroundColor White
}
if ($script:userStats.ContainsKey("Azure")) {
    Write-Host "  Azure AD Users: $($script:userStats["Azure"].TotalUsers)" -ForegroundColor White
}
Write-Host "  Security Findings: $($script:findings.Count)" -ForegroundColor Red
Write-Host "  Security Issues: $($script:securityIssues.Count)" -ForegroundColor Yellow

if ($script:costAnalysis.Count -gt 0) {
    $totalSavings = ($script:costAnalysis.Values | Measure-Object -Property AnnualSavings -Sum).Sum
    Write-Host "  Potential Annual Savings: `$$totalSavings" -ForegroundColor Green
}

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Green
