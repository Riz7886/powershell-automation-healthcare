param(
    [Parameter(Mandatory=$false)]
    [switch]$AuditOnly,
    [Parameter(Mandatory=$false)]
    [switch]$EnforceAll,
    [Parameter(Mandatory=$false)]
    [switch]$CreateBreakGlass,
    [Parameter(Mandatory=$false)]
    [string]$TenantId,
    [Parameter(Mandatory=$false)]
    [string]$ReportPath = "$env:USERPROFILE\Desktop\MFA-Enforcement-Reports"
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$script:auditResults = @()
$script:actionLog = @()
$script:errorLog = @()
$script:caResults = @()
$script:breakGlassResults = @()
$script:timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:mfaRegistered = 0
$script:mfaNotRegistered = 0
$script:adminsTotal = 0
$script:adminsWithMfa = 0
$script:adminsWithoutMfa = 0
$script:policiesCreated = 0
$script:policiesExisting = 0

function Log {
    param([string]$Msg, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "ERROR"   { Write-Host "[$ts] ERROR: $Msg" -ForegroundColor Red }
        "WARN"    { Write-Host "[$ts] WARN:  $Msg" -ForegroundColor Yellow }
        "SUCCESS" { Write-Host "[$ts] OK:    $Msg" -ForegroundColor Green }
        "FIX"     { Write-Host "[$ts] FIX:   $Msg" -ForegroundColor Magenta }
        "HEADER"  { Write-Host "`n$('='*70)" -ForegroundColor Cyan; Write-Host "  $Msg" -ForegroundColor Cyan; Write-Host "$('='*70)" -ForegroundColor Cyan }
        default   { Write-Host "[$ts] INFO:  $Msg" -ForegroundColor Cyan }
    }
    $script:actionLog += [PSCustomObject]@{Time=$ts;Level=$Level;Message=$Msg}
}

function Install-RequiredModules {
    Log "Checking required PowerShell modules..." "HEADER"
    $modules = @(
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Users',
        'Microsoft.Graph.Identity.DirectoryManagement',
        'Microsoft.Graph.Identity.SignIns',
        'Microsoft.Graph.Reports',
        'Az.Accounts',
        'Az.Resources'
    )
    foreach ($mod in $modules) {
        $installed = Get-Module -ListAvailable -Name $mod | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $installed) {
            Log "Installing $mod..." "WARN"
            try {
                Install-Module -Name $mod -Force -AllowClobber -Scope CurrentUser -Repository PSGallery -SkipPublisherCheck
                Log "$mod installed" "SUCCESS"
            } catch {
                Log "Failed to install $mod - $_" "ERROR"
                $script:errorLog += "Module install failed: $mod - $_"
            }
        } else {
            Log "$mod v$($installed.Version) found" "SUCCESS"
        }
    }
}

function Connect-MicrosoftGraph {
    Log "Connecting to Microsoft Graph..." "HEADER"
    $requiredScopes = @(
        'User.Read.All',
        'UserAuthenticationMethod.Read.All',
        'Directory.Read.All',
        'Policy.Read.All',
        'Policy.ReadWrite.ConditionalAccess',
        'RoleManagement.Read.All',
        'AuditLog.Read.All',
        'Reports.Read.All',
        'IdentityRiskyUser.Read.All'
    )
    try {
        $ctx = Get-MgContext
        if ($ctx) {
            $missing = $requiredScopes | Where-Object { $_ -notin $ctx.Scopes }
            if ($missing.Count -gt 0) {
                Log "Reconnecting with additional scopes..." "WARN"
                Disconnect-MgGraph -ErrorAction SilentlyContinue
                if ($TenantId) {
                    Connect-MgGraph -Scopes $requiredScopes -TenantId $TenantId -NoWelcome
                } else {
                    Connect-MgGraph -Scopes $requiredScopes -NoWelcome
                }
            } else {
                Log "Already connected as $($ctx.Account)" "SUCCESS"
            }
        } else {
            if ($TenantId) {
                Connect-MgGraph -Scopes $requiredScopes -TenantId $TenantId -NoWelcome
            } else {
                Connect-MgGraph -Scopes $requiredScopes -NoWelcome
            }
        }
        $ctx = Get-MgContext
        Log "Connected as $($ctx.Account) to tenant $($ctx.TenantId)" "SUCCESS"
        return $true
    } catch {
        Log "Graph connection failed: $_" "ERROR"
        $script:errorLog += "Graph connection failed: $_"
        return $false
    }
}

function Get-AdminRoleMembers {
    Log "Discovering all privileged role assignments..." "HEADER"
    $adminRoles = @(
        'Global Administrator',
        'Privileged Role Administrator',
        'Security Administrator',
        'Exchange Administrator',
        'SharePoint Administrator',
        'User Administrator',
        'Helpdesk Administrator',
        'Application Administrator',
        'Cloud Application Administrator',
        'Intune Administrator',
        'Compliance Administrator',
        'Billing Administrator',
        'Conditional Access Administrator',
        'Authentication Administrator',
        'Password Administrator',
        'Groups Administrator',
        'License Administrator',
        'Teams Administrator',
        'Power Platform Administrator',
        'Dynamics 365 Administrator',
        'Azure DevOps Administrator',
        'Azure Information Protection Administrator',
        'Privileged Authentication Administrator'
    )
    $adminUsers = @{}
    try {
        $roles = Get-MgDirectoryRole -All
        foreach ($role in $roles) {
            if ($adminRoles -contains $role.DisplayName) {
                $members = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All
                foreach ($member in $members) {
                    if ($member.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user') {
                        $userId = $member.Id
                        if (-not $adminUsers.ContainsKey($userId)) {
                            $adminUsers[$userId] = @{
                                Id = $userId
                                DisplayName = $member.AdditionalProperties.displayName
                                UPN = $member.AdditionalProperties.userPrincipalName
                                Roles = @($role.DisplayName)
                            }
                        } else {
                            $adminUsers[$userId].Roles += $role.DisplayName
                        }
                    }
                }
                Log "$($role.DisplayName): $(@($members).Count) members" "INFO"
            }
        }
    } catch {
        Log "Error fetching roles: $_" "ERROR"
        $script:errorLog += "Role fetch error: $_"
    }
    Log "Found $($adminUsers.Count) unique admin accounts across all privileged roles" "SUCCESS"
    return $adminUsers
}

function Get-UserMfaStatus {
    param([string]$UserId, [string]$UPN)
    $methods = @()
    $mfaRegistered = $false
    try {
        $authMethods = Get-MgUserAuthenticationMethod -UserId $UserId -All
        foreach ($method in $authMethods) {
            $type = $method.AdditionalProperties.'@odata.type'
            switch ($type) {
                '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod' {
                    $methods += 'Microsoft Authenticator'
                    $mfaRegistered = $true
                }
                '#microsoft.graph.phoneAuthenticationMethod' {
                    $methods += "Phone: $($method.AdditionalProperties.phoneType)"
                    $mfaRegistered = $true
                }
                '#microsoft.graph.fido2AuthenticationMethod' {
                    $methods += "FIDO2 Key: $($method.AdditionalProperties.model)"
                    $mfaRegistered = $true
                }
                '#microsoft.graph.windowsHelloForBusinessAuthenticationMethod' {
                    $methods += 'Windows Hello'
                    $mfaRegistered = $true
                }
                '#microsoft.graph.emailAuthenticationMethod' {
                    $methods += "Email: $($method.AdditionalProperties.emailAddress)"
                }
                '#microsoft.graph.passwordAuthenticationMethod' {
                }
                '#microsoft.graph.softwareOathAuthenticationMethod' {
                    $methods += 'Software OATH Token'
                    $mfaRegistered = $true
                }
                '#microsoft.graph.temporaryAccessPassAuthenticationMethod' {
                    $methods += 'Temporary Access Pass'
                }
                default {
                    if ($type -and $type -ne '#microsoft.graph.passwordAuthenticationMethod') {
                        $methods += $type.Split('.')[-1] -replace 'AuthenticationMethod',''
                    }
                }
            }
        }
    } catch {
        Log "Could not read MFA for $UPN - $_" "WARN"
        $methods += "ERROR: Access Denied"
    }
    return @{
        Registered = $mfaRegistered
        Methods = ($methods -join ', ')
        MethodCount = $methods.Count
    }
}

function Invoke-MfaAudit {
    Log "Running complete MFA audit on all users..." "HEADER"
    $allUsers = @()
    try {
        $allUsers = Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,AccountEnabled,UserType,CreatedDateTime,SignInActivity,AssignedLicenses -ConsistencyLevel eventual -CountVariable totalCount
        Log "Retrieved $(@($allUsers).Count) users from directory" "INFO"
    } catch {
        Log "User retrieval failed: $_" "ERROR"
        try {
            $allUsers = Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,AccountEnabled,UserType,CreatedDateTime,AssignedLicenses
            Log "Retrieved $(@($allUsers).Count) users (without sign-in activity)" "WARN"
        } catch {
            Log "Critical failure retrieving users: $_" "ERROR"
            $script:errorLog += "User retrieval failed completely: $_"
            return
        }
    }
    $adminUsers = Get-AdminRoleMembers
    $script:adminsTotal = $adminUsers.Count
    $counter = 0
    $total = @($allUsers).Count
    foreach ($user in $allUsers) {
        $counter++
        if ($counter % 25 -eq 0) {
            Write-Progress -Activity "Auditing MFA Status" -Status "$counter of $total users" -PercentComplete (($counter/$total)*100)
        }
        $mfaInfo = Get-UserMfaStatus -UserId $user.Id -UPN $user.UserPrincipalName
        $isAdmin = $adminUsers.ContainsKey($user.Id)
        $adminRoles = if ($isAdmin) { $adminUsers[$user.Id].Roles -join ', ' } else { '' }
        $lastSignIn = ''
        if ($user.SignInActivity -and $user.SignInActivity.LastSignInDateTime) {
            $lastSignIn = $user.SignInActivity.LastSignInDateTime.ToString('yyyy-MM-dd HH:mm')
        }
        $hasLicense = ($user.AssignedLicenses -and $user.AssignedLicenses.Count -gt 0)
        $result = [PSCustomObject]@{
            DisplayName    = $user.DisplayName
            UPN            = $user.UserPrincipalName
            Enabled        = $user.AccountEnabled
            UserType       = $user.UserType
            IsAdmin        = $isAdmin
            AdminRoles     = $adminRoles
            MfaRegistered  = $mfaInfo.Registered
            MfaMethods     = $mfaInfo.Methods
            MethodCount    = $mfaInfo.MethodCount
            Licensed       = $hasLicense
            LastSignIn     = $lastSignIn
            Created        = if ($user.CreatedDateTime) { $user.CreatedDateTime.ToString('yyyy-MM-dd') } else { '' }
            Risk           = 'LOW'
        }
        if ($isAdmin -and -not $mfaInfo.Registered) {
            $result.Risk = 'CRITICAL'
            $script:adminsWithoutMfa++
        } elseif ($isAdmin -and $mfaInfo.Registered) {
            $result.Risk = 'LOW'
            $script:adminsWithMfa++
        } elseif (-not $isAdmin -and -not $mfaInfo.Registered -and $hasLicense -and $user.AccountEnabled) {
            $result.Risk = 'HIGH'
        } elseif (-not $mfaInfo.Registered -and $user.AccountEnabled) {
            $result.Risk = 'MEDIUM'
        }
        if ($mfaInfo.Registered) { $script:mfaRegistered++ } else { $script:mfaNotRegistered++ }
        $script:auditResults += $result
    }
    Write-Progress -Activity "Auditing MFA Status" -Completed
    Log "Audit complete: $($script:mfaRegistered) with MFA, $($script:mfaNotRegistered) without MFA" "SUCCESS"
    Log "Admins: $($script:adminsWithMfa) protected, $($script:adminsWithoutMfa) EXPOSED" $(if ($script:adminsWithoutMfa -gt 0) { "ERROR" } else { "SUCCESS" })
}

function Get-ExistingConditionalAccessPolicies {
    Log "Checking existing Conditional Access policies..." "HEADER"
    $existingPolicies = @()
    try {
        $policies = Get-MgIdentityConditionalAccessPolicy -All
        foreach ($p in $policies) {
            $existingPolicies += [PSCustomObject]@{
                Name = $p.DisplayName
                State = $p.State
                Id = $p.Id
                GrantControls = ($p.GrantControls.BuiltInControls -join ', ')
                Users = if ($p.Conditions.Users.IncludeUsers -contains 'All') { 'All Users' } else { "$(@($p.Conditions.Users.IncludeUsers).Count) users/groups" }
                Apps = if ($p.Conditions.Applications.IncludeApplications -contains 'All') { 'All Apps' } else { "$(@($p.Conditions.Applications.IncludeApplications).Count) apps" }
            }
            $hasMfa = $p.GrantControls.BuiltInControls -contains 'mfa'
            $state = if ($p.State -eq 'enabled') { 'ACTIVE' } else { $p.State }
            Log "$($p.DisplayName) [$state] $(if ($hasMfa) {'- MFA REQUIRED'} else {'- No MFA'})" $(if ($hasMfa -and $p.State -eq 'enabled') { "SUCCESS" } else { "WARN" })
        }
    } catch {
        Log "Could not read CA policies: $_" "ERROR"
        $script:errorLog += "CA policy read error: $_"
    }
    $script:caResults = $existingPolicies
    return $existingPolicies
}

function New-MfaConditionalAccessPolicies {
    Log "Creating MFA Conditional Access policies..." "HEADER"

    $policiesToCreate = @(
        @{
            DisplayName = "ENFORCE-MFA-All-Admins"
            State = "enabledForReportingButNotEnforced"
            Description = "Require MFA for all admin role holders - Created by MFA Enforcement Script"
            IncludeRoles = @(
                '62e90394-69f5-4237-9190-012177145e10',
                'e8611ab8-c189-46e8-94e1-60213ab1f814',
                '194ae4cb-b126-40b2-bd5b-6091b380977d',
                'f28a1f50-f6e7-4571-818b-6a12f2af6b6c',
                '29232cdf-9323-42fd-ade2-1d097af3e4de',
                'fe930be7-5e62-47db-91af-98c3a49a38b1',
                '729827e3-9c14-49f7-bb1b-9608f156bbb8',
                '966707d0-3269-4727-9be2-8c3a10f19b9d',
                'b0f54661-2d74-4c50-afa3-1ec803f12efe',
                '3a2c62db-5318-420d-8d74-23affee5d9d5',
                'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9'
            )
            IncludeUsers = @()
            IncludeApps = @('All')
        },
        @{
            DisplayName = "ENFORCE-MFA-All-Users-All-Apps"
            State = "enabledForReportingButNotEnforced"
            Description = "Require MFA for all users on all cloud apps - Created by MFA Enforcement Script"
            IncludeRoles = @()
            IncludeUsers = @('All')
            IncludeApps = @('All')
        },
        @{
            DisplayName = "ENFORCE-MFA-Azure-Portal-CLI-API"
            State = "enabledForReportingButNotEnforced"
            Description = "Require MFA for Azure management (portal, CLI, PowerShell, API) - Created by MFA Enforcement Script"
            IncludeRoles = @()
            IncludeUsers = @('All')
            IncludeApps = @('797f4846-ba00-4fd7-ba43-dac1f8f63013')
        },
        @{
            DisplayName = "ENFORCE-MFA-M365-Admin-Center"
            State = "enabledForReportingButNotEnforced"
            Description = "Require MFA for M365 Admin Center access - Feb 9 2026 deadline - Created by MFA Enforcement Script"
            IncludeRoles = @()
            IncludeUsers = @('All')
            IncludeApps = @('00000006-0000-0ff1-ce00-000000000000')
        },
        @{
            DisplayName = "BLOCK-Legacy-Authentication"
            State = "enabledForReportingButNotEnforced"
            Description = "Block legacy auth protocols that bypass MFA - Created by MFA Enforcement Script"
            IncludeRoles = @()
            IncludeUsers = @('All')
            IncludeApps = @('All')
            BlockLegacy = $true
        }
    )

    $existing = Get-MgIdentityConditionalAccessPolicy -All
    $existingNames = $existing | ForEach-Object { $_.DisplayName }

    foreach ($policyDef in $policiesToCreate) {
        if ($policyDef.DisplayName -in $existingNames) {
            Log "$($policyDef.DisplayName) already exists - skipping" "WARN"
            $script:policiesExisting++
            continue
        }

        try {
            $conditions = @{
                Applications = @{ IncludeApplications = $policyDef.IncludeApps }
                Users = @{}
            }

            if ($policyDef.IncludeRoles.Count -gt 0) {
                $conditions.Users.IncludeRoles = $policyDef.IncludeRoles
            }
            if ($policyDef.IncludeUsers.Count -gt 0) {
                $conditions.Users.IncludeUsers = $policyDef.IncludeUsers
            }

            $breakGlassGroup = $existing | Where-Object { $_.DisplayName -like '*BreakGlass*' }
            $bgGroupId = $null
            try {
                $bgGroup = Get-MgGroup -Filter "displayName eq 'BreakGlass-Exclude-MFA'" -Top 1
                if ($bgGroup) { $bgGroupId = $bgGroup.Id }
            } catch {}
            if ($bgGroupId) {
                $conditions.Users.ExcludeGroups = @($bgGroupId)
            }

            $grantControls = @{
                Operator = "OR"
                BuiltInControls = @("mfa")
            }

            if ($policyDef.BlockLegacy) {
                $conditions.ClientAppTypes = @("exchangeActiveSync", "other")
                $grantControls = @{
                    Operator = "OR"
                    BuiltInControls = @("block")
                }
            } else {
                $conditions.ClientAppTypes = @("all")
            }

            $params = @{
                DisplayName = $policyDef.DisplayName
                State = $policyDef.State
                Conditions = $conditions
                GrantControls = $grantControls
            }

            New-MgIdentityConditionalAccessPolicy -BodyParameter $params
            $script:policiesCreated++
            Log "$($policyDef.DisplayName) CREATED (Report-Only mode)" "SUCCESS"
        } catch {
            Log "Failed to create $($policyDef.DisplayName): $_" "ERROR"
            $script:errorLog += "CA policy creation error: $($policyDef.DisplayName) - $_"
        }
    }
    Log "Policies created: $($script:policiesCreated), Already existed: $($script:policiesExisting)" "SUCCESS"
}

function New-BreakGlassAccounts {
    Log "Setting up Break-Glass emergency access accounts..." "HEADER"

    $bgGroupName = "BreakGlass-Exclude-MFA"
    $bgGroup = $null
    try {
        $bgGroup = Get-MgGroup -Filter "displayName eq '$bgGroupName'" -Top 1
    } catch {}

    if (-not $bgGroup) {
        try {
            $bgGroup = New-MgGroup -DisplayName $bgGroupName -MailEnabled:$false -MailNickname "breakglass-exclude-mfa" -SecurityEnabled:$true -Description "Emergency break-glass accounts excluded from Conditional Access MFA policies"
            Log "Created security group: $bgGroupName" "SUCCESS"
        } catch {
            Log "Failed to create break-glass group: $_" "ERROR"
            $script:errorLog += "Break-glass group creation error: $_"
            return
        }
    } else {
        Log "Break-glass group already exists: $bgGroupName" "SUCCESS"
    }

    $bgAccounts = @(
        @{ Name = "BreakGlass-Admin-01"; UPN = "breakglass-admin-01" },
        @{ Name = "BreakGlass-Admin-02"; UPN = "breakglass-admin-02" }
    )

    $ctx = Get-MgContext
    $tenantDomains = Get-MgDomain -All | Where-Object { $_.IsDefault -eq $true }
    $domain = if ($tenantDomains) { $tenantDomains.Id } else { "yourdomain.onmicrosoft.com" }

    foreach ($bg in $bgAccounts) {
        $fullUpn = "$($bg.UPN)@$domain"
        $existingUser = $null
        try {
            $existingUser = Get-MgUser -Filter "userPrincipalName eq '$fullUpn'" -Top 1
        } catch {}

        if ($existingUser) {
            Log "$($bg.Name) already exists ($fullUpn)" "WARN"
            try {
                $isMember = Get-MgGroupMember -GroupId $bgGroup.Id -All | Where-Object { $_.Id -eq $existingUser.Id }
                if (-not $isMember) {
                    New-MgGroupMember -GroupId $bgGroup.Id -DirectoryObjectId $existingUser.Id
                    Log "Added $($bg.Name) to $bgGroupName group" "SUCCESS"
                }
            } catch {}
            $script:breakGlassResults += [PSCustomObject]@{
                Account = $bg.Name
                UPN = $fullUpn
                Status = "Already Exists"
                Password = "N/A - Existing"
                Action = "Verify MFA is configured"
            }
            continue
        }

        $pw = -join ((65..90)+(97..122)+(48..57)+(33,35,36,37,38,42,64) | Get-Random -Count 24 | ForEach-Object {[char]$_})
        try {
            $newUser = New-MgUser -DisplayName $bg.Name -UserPrincipalName $fullUpn -MailNickname $bg.UPN -AccountEnabled:$true -PasswordProfile @{
                Password = $pw
                ForceChangePasswordNextSignIn = $false
                ForceChangePasswordNextSignInWithMfa = $false
            }

            $globalAdminRoleId = (Get-MgDirectoryRole -Filter "displayName eq 'Global Administrator'" -Top 1).Id
            if ($globalAdminRoleId) {
                New-MgDirectoryRoleMemberByRef -DirectoryRoleId $globalAdminRoleId -BodyParameter @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($newUser.Id)"
                }
            }

            New-MgGroupMember -GroupId $bgGroup.Id -DirectoryObjectId $newUser.Id

            Log "$($bg.Name) CREATED with Global Admin role" "SUCCESS"
            Log "UPN: $fullUpn" "FIX"
            Log "PASSWORD: $pw" "FIX"
            Log "ACTION: Register FIDO2 hardware key or Authenticator app NOW" "WARN"

            $script:breakGlassResults += [PSCustomObject]@{
                Account = $bg.Name
                UPN = $fullUpn
                Status = "CREATED"
                Password = $pw
                Action = "REGISTER MFA IMMEDIATELY - Use hardware security key"
            }
        } catch {
            Log "Failed to create $($bg.Name): $_" "ERROR"
            $script:errorLog += "Break-glass creation error: $($bg.Name) - $_"
            $script:breakGlassResults += [PSCustomObject]@{
                Account = $bg.Name
                UPN = $fullUpn
                Status = "FAILED"
                Password = "N/A"
                Action = "Manual creation required"
            }
        }
    }
}

function Enable-SecurityDefaults {
    Log "Checking Security Defaults status..." "HEADER"
    try {
        $policy = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy"
        if ($policy.isEnabled) {
            Log "Security Defaults is ENABLED - this is good for baseline MFA" "SUCCESS"
            Log "NOTE: If using Conditional Access policies, Security Defaults should be DISABLED (CA takes priority)" "WARN"
        } else {
            Log "Security Defaults is DISABLED - Conditional Access policies are managing MFA" "INFO"
        }
    } catch {
        Log "Could not check Security Defaults: $_" "WARN"
    }
}

function Get-SignInRiskReport {
    Log "Checking risky sign-ins and identity protection..." "HEADER"
    try {
        $riskyUsers = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/identityProtection/riskyUsers?`$filter=riskLevel ne 'none'&`$top=50"
        if ($riskyUsers.value.Count -gt 0) {
            Log "FOUND $($riskyUsers.value.Count) users with risk detections" "ERROR"
            foreach ($ru in $riskyUsers.value) {
                Log "  $($ru.userDisplayName) ($($ru.userPrincipalName)) - Risk: $($ru.riskLevel) - State: $($ru.riskState)" "WARN"
            }
        } else {
            Log "No risky users detected" "SUCCESS"
        }
    } catch {
        Log "Identity Protection data not accessible (may require P2 license): $_" "WARN"
    }
}

function New-HtmlReport {
    Log "Generating HTML report..." "HEADER"

    if (-not (Test-Path $ReportPath)) {
        New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
    }

    $criticalAdmins = $script:auditResults | Where-Object { $_.Risk -eq 'CRITICAL' }
    $highRisk = $script:auditResults | Where-Object { $_.Risk -eq 'HIGH' }
    $totalEnabled = @($script:auditResults | Where-Object { $_.Enabled -eq $true }).Count
    $totalMfa = $script:mfaRegistered
    $totalNoMfa = $script:mfaNotRegistered
    $mfaPct = if (($totalMfa + $totalNoMfa) -gt 0) { [math]::Round(($totalMfa / ($totalMfa + $totalNoMfa)) * 100, 1) } else { 0 }
    $adminMfaPct = if ($script:adminsTotal -gt 0) { [math]::Round(($script:adminsWithMfa / $script:adminsTotal) * 100, 1) } else { 0 }
    $deadline = [datetime]"2026-02-09"
    $daysLeft = [math]::Max(0, ($deadline - (Get-Date)).Days)

    $criticalAdminRows = ""
    foreach ($ca in $criticalAdmins) {
        $criticalAdminRows += "<tr><td style='font-weight:bold'>$($ca.DisplayName)</td><td>$($ca.UPN)</td><td>$($ca.AdminRoles)</td><td style='color:#ef4444;font-weight:bold'>NO MFA</td><td>$($ca.MfaMethods)</td><td>$($ca.LastSignIn)</td></tr>"
    }

    $protectedAdmins = $script:auditResults | Where-Object { $_.IsAdmin -and $_.MfaRegistered }
    $protectedAdminRows = ""
    foreach ($pa in $protectedAdmins) {
        $protectedAdminRows += "<tr><td>$($pa.DisplayName)</td><td>$($pa.UPN)</td><td>$($pa.AdminRoles)</td><td style='color:#22c55e;font-weight:bold'>MFA ACTIVE</td><td>$($pa.MfaMethods)</td><td>$($pa.LastSignIn)</td></tr>"
    }

    $highRiskRows = ""
    $hrCounter = 0
    foreach ($hr in ($highRisk | Sort-Object LastSignIn -Descending | Select-Object -First 50)) {
        $hrCounter++
        $highRiskRows += "<tr><td>$hrCounter</td><td>$($hr.DisplayName)</td><td>$($hr.UPN)</td><td>$($hr.UserType)</td><td style='color:#f97316;font-weight:bold'>NO MFA</td><td>$($hr.LastSignIn)</td></tr>"
    }

    $caRows = ""
    foreach ($ca in $script:caResults) {
        $stateColor = switch ($ca.State) { 'enabled' { '#22c55e' } 'enabledForReportingButNotEnforced' { '#f59e0b' } default { '#ef4444' } }
        $caRows += "<tr><td>$($ca.Name)</td><td style='color:$stateColor;font-weight:bold'>$($ca.State)</td><td>$($ca.GrantControls)</td><td>$($ca.Users)</td><td>$($ca.Apps)</td></tr>"
    }

    $bgRows = ""
    foreach ($bg in $script:breakGlassResults) {
        $bgRows += "<tr><td>$($bg.Account)</td><td>$($bg.UPN)</td><td>$($bg.Status)</td><td style='font-family:monospace;font-size:11px'>$($bg.Password)</td><td>$($bg.Action)</td></tr>"
    }

    $actionLogRows = ""
    foreach ($log in ($script:actionLog | Select-Object -Last 100)) {
        $logColor = switch ($log.Level) { 'ERROR' { '#ef4444' } 'WARN' { '#f59e0b' } 'SUCCESS' { '#22c55e' } 'FIX' { '#a855f7' } default { '#94a3b8' } }
        $actionLogRows += "<tr><td style='white-space:nowrap'>$($log.Time)</td><td style='color:$logColor;font-weight:bold'>$($log.Level)</td><td>$($log.Message)</td></tr>"
    }

    $urgencyColor = if ($daysLeft -le 2) { '#ef4444' } elseif ($daysLeft -le 5) { '#f97316' } else { '#22c55e' }
    $overallStatus = if ($script:adminsWithoutMfa -eq 0 -and $mfaPct -ge 90) { "COMPLIANT" } elseif ($script:adminsWithoutMfa -gt 0) { "CRITICAL - ADMIN ACCOUNTS EXPOSED" } else { "AT RISK" }
    $overallColor = if ($overallStatus -eq "COMPLIANT") { '#22c55e' } elseif ($overallStatus -like "CRITICAL*") { '#ef4444' } else { '#f97316' }

    $htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>MFA Enforcement Report - $($script:timestamp)</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;background:#0f172a;color:#e2e8f0;padding:20px}
.container{max-width:1400px;margin:0 auto}
.header{background:linear-gradient(135deg,#1e293b,#334155);border-radius:12px;padding:30px;margin-bottom:20px;border:1px solid #475569}
.header h1{font-size:28px;color:#f1f5f9;margin-bottom:5px}
.header p{color:#94a3b8;font-size:14px}
.deadline-banner{background:linear-gradient(135deg,$urgencyColor,$(if($daysLeft -le 2){'#dc2626'}else{'#ea580c'}));border-radius:12px;padding:20px;margin-bottom:20px;text-align:center}
.deadline-banner h2{font-size:32px;color:#fff}
.deadline-banner p{color:#fef2f2;font-size:16px;margin-top:5px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:15px;margin-bottom:20px}
.card{background:#1e293b;border-radius:10px;padding:20px;border:1px solid #334155}
.card h3{font-size:13px;color:#94a3b8;text-transform:uppercase;letter-spacing:1px;margin-bottom:8px}
.card .value{font-size:36px;font-weight:700}
.card .sub{font-size:12px;color:#64748b;margin-top:4px}
.section{background:#1e293b;border-radius:10px;padding:20px;margin-bottom:20px;border:1px solid #334155}
.section h2{font-size:18px;color:#f1f5f9;margin-bottom:15px;padding-bottom:10px;border-bottom:1px solid #334155}
table{width:100%;border-collapse:collapse;font-size:13px}
th{background:#0f172a;color:#94a3b8;padding:10px 12px;text-align:left;font-weight:600;text-transform:uppercase;font-size:11px;letter-spacing:0.5px}
td{padding:8px 12px;border-bottom:1px solid #1e293b}
tr:hover{background:#334155}
.status-bar{height:8px;border-radius:4px;background:#334155;margin-top:10px;overflow:hidden}
.status-fill{height:100%;border-radius:4px;transition:width 0.5s}
.footer{text-align:center;color:#475569;font-size:12px;margin-top:30px;padding:20px}
.badge{display:inline-block;padding:3px 10px;border-radius:12px;font-size:11px;font-weight:600}
.badge-critical{background:#7f1d1d;color:#fca5a5}
.badge-warn{background:#78350f;color:#fbbf24}
.badge-ok{background:#14532d;color:#86efac}
@media print{body{background:#fff;color:#000}th{background:#f1f5f9;color:#000}td{border-color:#e2e8f0}.card,.section,.header{border-color:#e2e8f0;background:#fff}}
</style>
</head>
<body>
<div class="container">
<div class="header">
<h1>Microsoft Entra ID - MFA Enforcement Report</h1>
<p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | Tenant: $((Get-MgContext).TenantId)</p>
<p style="margin-top:10px;font-size:16px;color:$overallColor;font-weight:bold">Overall Status: $overallStatus</p>
</div>
<div class="deadline-banner">
<h2>$daysLeft DAYS UNTIL MFA ENFORCEMENT DEADLINE</h2>
<p>Microsoft M365 Admin Center mandatory MFA enforcement: February 9, 2026</p>
</div>
<div class="grid">
<div class="card">
<h3>Total Users</h3>
<div class="value" style="color:#60a5fa">$(@($script:auditResults).Count)</div>
<div class="sub">$totalEnabled enabled accounts</div>
</div>
<div class="card">
<h3>MFA Coverage</h3>
<div class="value" style="color:$(if($mfaPct -ge 90){'#22c55e'}elseif($mfaPct -ge 70){'#f59e0b'}else{'#ef4444'})">$mfaPct%</div>
<div class="sub">$totalMfa registered / $totalNoMfa unregistered</div>
<div class="status-bar"><div class="status-fill" style="width:$mfaPct%;background:$(if($mfaPct -ge 90){'#22c55e'}elseif($mfaPct -ge 70){'#f59e0b'}else{'#ef4444'})"></div></div>
</div>
<div class="card">
<h3>Admin Accounts</h3>
<div class="value" style="color:$(if($script:adminsWithoutMfa -eq 0){'#22c55e'}else{'#ef4444'})">$($script:adminsTotal)</div>
<div class="sub">$($script:adminsWithMfa) protected / $($script:adminsWithoutMfa) EXPOSED</div>
<div class="status-bar"><div class="status-fill" style="width:$adminMfaPct%;background:$(if($adminMfaPct -eq 100){'#22c55e'}else{'#ef4444'})"></div></div>
</div>
<div class="card">
<h3>Admin MFA Rate</h3>
<div class="value" style="color:$(if($adminMfaPct -eq 100){'#22c55e'}elseif($adminMfaPct -ge 80){'#f59e0b'}else{'#ef4444'})">$adminMfaPct%</div>
<div class="sub">$(if($adminMfaPct -eq 100){'All admins protected'}else{"$($script:adminsWithoutMfa) admins need MFA NOW"})</div>
</div>
<div class="card">
<h3>CA Policies Created</h3>
<div class="value" style="color:#a855f7">$($script:policiesCreated)</div>
<div class="sub">$($script:policiesExisting) already existed | Total active: $(@($script:caResults | Where-Object {$_.State -eq 'enabled'}).Count)</div>
</div>
<div class="card">
<h3>Break-Glass Accounts</h3>
<div class="value" style="color:#06b6d4">$(@($script:breakGlassResults).Count)</div>
<div class="sub">Emergency access accounts configured</div>
</div>
</div>
$(if ($criticalAdminRows) {
@"
<div class="section" style="border:2px solid #ef4444">
<h2 style="color:#ef4444">CRITICAL: Admin Accounts WITHOUT MFA ($($script:adminsWithoutMfa) accounts)</h2>
<p style="color:#fca5a5;margin-bottom:15px;font-size:14px">These admin accounts will be LOCKED OUT on February 9, 2026. Register MFA immediately at aka.ms/MFASetup</p>
<table>
<tr><th>Name</th><th>UPN</th><th>Admin Roles</th><th>MFA Status</th><th>Methods</th><th>Last Sign-In</th></tr>
$criticalAdminRows
</table>
</div>
"@
})
$(if ($protectedAdminRows) {
@"
<div class="section">
<h2 style="color:#22c55e">Protected Admin Accounts ($($script:adminsWithMfa) accounts)</h2>
<table>
<tr><th>Name</th><th>UPN</th><th>Admin Roles</th><th>MFA Status</th><th>Methods</th><th>Last Sign-In</th></tr>
$protectedAdminRows
</table>
</div>
"@
})
$(if ($highRiskRows) {
@"
<div class="section" style="border:1px solid #f97316">
<h2 style="color:#f97316">High Risk: Licensed Users Without MFA (showing top 50 of $(@($highRisk).Count))</h2>
<table>
<tr><th>#</th><th>Name</th><th>UPN</th><th>Type</th><th>MFA Status</th><th>Last Sign-In</th></tr>
$highRiskRows
</table>
</div>
"@
})
<div class="section">
<h2>Conditional Access Policies</h2>
$(if ($caRows) {
"<table><tr><th>Policy Name</th><th>State</th><th>Grant Controls</th><th>Target Users</th><th>Target Apps</th></tr>$caRows</table>"
} else {
"<p style='color:#f59e0b'>No Conditional Access policies found. Policies will be created when running in enforce mode.</p>"
})
</div>
$(if ($bgRows) {
@"
<div class="section" style="border:1px solid #06b6d4">
<h2 style="color:#06b6d4">Break-Glass Emergency Access Accounts</h2>
<p style="color:#fca5a5;margin-bottom:15px;font-size:13px">SAVE THESE CREDENTIALS IN A SECURE VAULT. Register MFA (hardware key) on these accounts immediately. Store credentials in a physical safe or Azure Key Vault.</p>
<table>
<tr><th>Account</th><th>UPN</th><th>Status</th><th>Password</th><th>Required Action</th></tr>
$bgRows
</table>
</div>
"@
})
<div class="section">
<h2>Execution Log</h2>
<div style="max-height:400px;overflow-y:auto">
<table>
<tr><th style="width:160px">Time</th><th style="width:80px">Level</th><th>Message</th></tr>
$actionLogRows
</table>
</div>
</div>
<div class="section">
<h2>Recommended Next Steps</h2>
<table>
<tr><th>#</th><th>Action</th><th>Priority</th><th>Deadline</th></tr>
<tr><td>1</td><td>Register MFA for all exposed admin accounts at aka.ms/MFASetup</td><td><span class="badge badge-critical">CRITICAL</span></td><td>BEFORE Feb 9, 2026</td></tr>
<tr><td>2</td><td>Configure FIDO2 hardware keys on break-glass accounts</td><td><span class="badge badge-critical">CRITICAL</span></td><td>TODAY</td></tr>
<tr><td>3</td><td>Review CA policies in Report-Only mode, then switch to Enabled</td><td><span class="badge badge-warn">HIGH</span></td><td>Within 48 hours</td></tr>
<tr><td>4</td><td>Enable CA policy ENFORCE-MFA-M365-Admin-Center before Feb 9</td><td><span class="badge badge-critical">CRITICAL</span></td><td>Feb 8, 2026</td></tr>
<tr><td>5</td><td>Roll out MFA registration campaign for all $($script:mfaNotRegistered) unregistered users</td><td><span class="badge badge-warn">HIGH</span></td><td>Within 2 weeks</td></tr>
<tr><td>6</td><td>Store break-glass credentials in Azure Key Vault or physical safe</td><td><span class="badge badge-warn">HIGH</span></td><td>TODAY</td></tr>
<tr><td>7</td><td>Block legacy authentication protocols (enable BLOCK-Legacy-Authentication policy)</td><td><span class="badge badge-warn">HIGH</span></td><td>Within 1 week</td></tr>
<tr><td>8</td><td>Verify Microsoft Authenticator not on jailbroken/rooted devices (auto-wipe in Feb 2026)</td><td><span class="badge badge-ok">MEDIUM</span></td><td>Feb 28, 2026</td></tr>
</table>
</div>
<div class="footer">
<p>MFA Enforcement Report | Generated by MFA-Enforcement-GOD-Script.ps1 | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<p style="margin-top:5px">Microsoft MFA Enforcement Deadline: February 9, 2026 | Days Remaining: $daysLeft</p>
</div>
</div>
</body>
</html>
"@

    $reportFile = Join-Path $ReportPath "MFA-Enforcement-Report-$($script:timestamp).html"
    $htmlContent | Out-File -FilePath $reportFile -Encoding UTF8
    Log "HTML Report saved: $reportFile" "SUCCESS"

    $csvFile = Join-Path $ReportPath "MFA-Audit-AllUsers-$($script:timestamp).csv"
    $script:auditResults | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    Log "CSV Export saved: $csvFile" "SUCCESS"

    $adminCsvFile = Join-Path $ReportPath "MFA-Audit-AdminsOnly-$($script:timestamp).csv"
    $script:auditResults | Where-Object { $_.IsAdmin } | Export-Csv -Path $adminCsvFile -NoTypeInformation -Encoding UTF8
    Log "Admin CSV saved: $adminCsvFile" "SUCCESS"

    $noMfaCsvFile = Join-Path $ReportPath "MFA-Audit-NoMFA-$($script:timestamp).csv"
    $script:auditResults | Where-Object { -not $_.MfaRegistered -and $_.Enabled } | Export-Csv -Path $noMfaCsvFile -NoTypeInformation -Encoding UTF8
    Log "No-MFA CSV saved: $noMfaCsvFile" "SUCCESS"

    try { Start-Process $reportFile } catch {}

    return $reportFile
}

function Show-Menu {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  MFA ENFORCEMENT SCRIPT - February 2026 Deadline" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] AUDIT ONLY      - Scan all users + admins for MFA status" -ForegroundColor White
    Write-Host "  [2] FULL ENFORCE    - Audit + Create CA Policies + Break-Glass" -ForegroundColor Yellow
    Write-Host "  [3] CA POLICIES     - Create Conditional Access policies only" -ForegroundColor White
    Write-Host "  [4] BREAK-GLASS     - Create emergency access accounts only" -ForegroundColor White
    Write-Host "  [5] ENABLE POLICIES - Switch CA policies from Report-Only to Enabled" -ForegroundColor Magenta
    Write-Host "  [6] EXIT" -ForegroundColor Gray
    Write-Host ""
    $choice = Read-Host "Select option (1-6)"
    return $choice
}

function Enable-CaPolicies {
    Log "Switching Conditional Access policies to ENABLED..." "HEADER"
    $policies = Get-MgIdentityConditionalAccessPolicy -All | Where-Object { $_.DisplayName -like 'ENFORCE-MFA*' -or $_.DisplayName -eq 'BLOCK-Legacy-Authentication' }
    foreach ($p in $policies) {
        if ($p.State -eq 'enabledForReportingButNotEnforced') {
            $confirm = Read-Host "Enable '$($p.DisplayName)' (currently Report-Only)? (Y/N)"
            if ($confirm -eq 'Y' -or $confirm -eq 'y') {
                try {
                    Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id -State "enabled"
                    Log "$($p.DisplayName) is now ENABLED and ENFORCING" "SUCCESS"
                } catch {
                    Log "Failed to enable $($p.DisplayName): $_" "ERROR"
                }
            } else {
                Log "Skipped $($p.DisplayName)" "WARN"
            }
        } elseif ($p.State -eq 'enabled') {
            Log "$($p.DisplayName) is already enabled" "SUCCESS"
        }
    }
}

function Main {
    Write-Host ""
    Write-Host "  __  __ _____ _     " -ForegroundColor Cyan
    Write-Host " |  \/  |  ___/ \    " -ForegroundColor Cyan
    Write-Host " | |\/| | |_ / _ \   " -ForegroundColor Cyan
    Write-Host " | |  | |  _/ ___ \  " -ForegroundColor Cyan
    Write-Host " |_|  |_|_|/_/   \_\ " -ForegroundColor Cyan
    Write-Host " ENFORCEMENT ENGINE   " -ForegroundColor Yellow
    Write-Host ""

    Install-RequiredModules

    $connected = Connect-MicrosoftGraph
    if (-not $connected) {
        Log "Cannot proceed without Graph connection" "ERROR"
        return
    }

    if ($AuditOnly) {
        Invoke-MfaAudit
        Get-ExistingConditionalAccessPolicies
        Enable-SecurityDefaults
        Get-SignInRiskReport
        New-HtmlReport
        return
    }

    if ($EnforceAll) {
        Invoke-MfaAudit
        Get-ExistingConditionalAccessPolicies
        New-MfaConditionalAccessPolicies
        Get-ExistingConditionalAccessPolicies
        New-BreakGlassAccounts
        Enable-SecurityDefaults
        Get-SignInRiskReport
        New-HtmlReport
        return
    }

    if ($CreateBreakGlass) {
        New-BreakGlassAccounts
        New-HtmlReport
        return
    }

    while ($true) {
        $choice = Show-Menu
        switch ($choice) {
            '1' {
                Invoke-MfaAudit
                Get-ExistingConditionalAccessPolicies
                Enable-SecurityDefaults
                Get-SignInRiskReport
                New-HtmlReport
            }
            '2' {
                Invoke-MfaAudit
                Get-ExistingConditionalAccessPolicies
                New-MfaConditionalAccessPolicies
                Get-ExistingConditionalAccessPolicies
                New-BreakGlassAccounts
                Enable-SecurityDefaults
                Get-SignInRiskReport
                New-HtmlReport
            }
            '3' {
                Get-ExistingConditionalAccessPolicies
                New-MfaConditionalAccessPolicies
                Get-ExistingConditionalAccessPolicies
                New-HtmlReport
            }
            '4' {
                New-BreakGlassAccounts
                New-HtmlReport
            }
            '5' {
                Enable-CaPolicies
            }
            '6' {
                Log "Exiting..." "INFO"
                return
            }
            default {
                Write-Host "Invalid selection" -ForegroundColor Red
            }
        }
    }
}

Main
