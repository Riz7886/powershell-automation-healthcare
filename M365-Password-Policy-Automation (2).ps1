# M365 PASSWORD POLICY AUTOMATION
# Finds expired passwords, excludes service accounts, forces reset on users only
# 100% Safe - Runs report first, requires confirmation before changes

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  M365 PASSWORD POLICY AUTOMATION" -ForegroundColor Cyan
Write-Host "  Find Expired Passwords - Reset User Accounts Only" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

# Configuration
$PasswordAgeDays = 90
$ReportPath = "$env:USERPROFILE\Desktop\M365-Password-Reports"
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# Create report folder
if (-not (Test-Path $ReportPath)) {
    New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
}

# Service account patterns to EXCLUDE (will NOT reset these)
$ServiceAccountPatterns = @(
    "^svc_",
    "^srv_",
    "^service_",
    "^sa_",
    "^admin_",
    "^sys_",
    "^app_",
    "^sync_",
    "^task_",
    "^job_",
    "^api_",
    "^bot_",
    "^auto_",
    "^scheduled_",
    "^noreply",
    "^no-reply",
    "^donotreply",
    "^mailbox_",
    "^room_",
    "^conf_",
    "^resource_",
    "^shared_",
    "^breakglass",
    "^emergency",
    "^azure",
    "^microsoft",
    "^onmicrosoft",
    "^cclibrary",
    "^library",
    "^ccl",
    "^scanner",
    "^printer",
    "^fax",
    "^copier",
    "^kiosk",
    "^display",
    "^signage",
    "^test_",
    "^dev_",
    "^staging_",
    "^prod_",
    "^integration",
    "^connector",
    "^webhook",
    "^reporting",
    "^analytics",
    "^dashboard",
    "^monitor",
    "^alert",
    "^backup",
    "^archive",
    "^migration",
    "^import",
    "^export"
)

# ============================================================
# WHITELIST - These are REAL HUMANS, NOT service accounts
# Add names here if they got incorrectly flagged
# ============================================================
$HumanAccountWhitelist = @(
    "Chelsey Clauson",
    "Franchesa Tailbot",
    "chelsey.clauson",
    "franchesa.tailbot",
    "cclauson",
    "ftailbot"
)

# ============================================================
# FUNCTION: Install Required Modules
# ============================================================
function Install-RequiredModules {
    Write-Host "Checking required modules..." -ForegroundColor Yellow
    
    $modules = @(
        "Microsoft.Graph.Authentication",
        "Microsoft.Graph.Users",
        "Microsoft.Graph.Identity.DirectoryManagement",
        "Az.Accounts",
        "Az.Resources"
    )
    
    foreach ($module in $modules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Host "  Installing $module..." -ForegroundColor Yellow
            Install-Module -Name $module -Force -AllowClobber -Scope CurrentUser
        }
    }
    Write-Host "All modules ready!" -ForegroundColor Green
}

# ============================================================
# FUNCTION: Connect to Azure
# ============================================================
function Connect-ToAzure {
    Write-Host ""
    Write-Host "Step 1: Connecting to Azure..." -ForegroundColor Yellow
    
    try {
        $context = Get-AzContext
        if (-not $context) {
            Connect-AzAccount
            $context = Get-AzContext
        }
        Write-Host "Connected as: $($context.Account.Id)" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "ERROR: Could not connect to Azure - $_" -ForegroundColor Red
        return $false
    }
}

# ============================================================
# FUNCTION: Select Subscription
# ============================================================
function Select-AzureSubscription {
    Write-Host ""
    Write-Host "Step 2: Getting subscriptions..." -ForegroundColor Yellow
    
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
    
    Write-Host ""
    Write-Host "Available Subscriptions:" -ForegroundColor Cyan
    Write-Host ""
    
    $i = 1
    foreach ($sub in $subscriptions) {
        Write-Host "  $i. $($sub.Name)" -ForegroundColor White
        $i++
    }
    
    Write-Host ""
    $selection = Read-Host "Select subscription number (1-$($subscriptions.Count))"
    
    $selectedSub = $subscriptions[$selection - 1]
    Set-AzContext -Subscription $selectedSub.Id | Out-Null
    
    Write-Host "Selected: $($selectedSub.Name)" -ForegroundColor Green
    return $selectedSub
}

# ============================================================
# FUNCTION: Connect to Microsoft Graph
# ============================================================
function Connect-ToGraph {
    Write-Host ""
    Write-Host "Step 3: Connecting to Microsoft Graph..." -ForegroundColor Yellow
    
    try {
        $scopes = @(
            "User.ReadWrite.All",
            "Directory.ReadWrite.All",
            "UserAuthenticationMethod.ReadWrite.All"
        )
        
        Connect-MgGraph -Scopes $scopes -NoWelcome
        
        $context = Get-MgContext
        Write-Host "Connected to Graph as: $($context.Account)" -ForegroundColor Green
        Write-Host "Tenant: $($context.TenantId)" -ForegroundColor Cyan
        return $true
    } catch {
        Write-Host "ERROR: Could not connect to Graph - $_" -ForegroundColor Red
        return $false
    }
}

# ============================================================
# FUNCTION: Check if Service Account
# ============================================================
function Test-IsServiceAccount {
    param([string]$UserPrincipalName, [string]$DisplayName)
    
    # CHECK WHITELIST FIRST - These are confirmed HUMAN accounts
    foreach ($humanName in $HumanAccountWhitelist) {
        if ($DisplayName -like "*$humanName*" -or $UserPrincipalName -like "*$humanName*") {
            return $false  # NOT a service account - it's a real human
        }
    }
    
    foreach ($pattern in $ServiceAccountPatterns) {
        if ($UserPrincipalName -match $pattern -or $DisplayName -match $pattern) {
            return $true
        }
    }
    
    # Check for common service account keywords in display name
    $serviceKeywords = @(
        "service", 
        "svc", 
        "system", 
        "sync", 
        "connector", 
        "api", 
        "bot", 
        "app registration", 
        "mailbox", 
        "room", 
        "conference", 
        "resource", 
        "shared", 
        "noreply", 
        "do not reply", 
        "automated", 
        "scheduled",
        "library",
        "cclibrary",
        "scanner",
        "printer",
        "fax",
        "copier",
        "kiosk",
        "display",
        "signage",
        "test account",
        "dev account",
        "integration",
        "webhook",
        "reporting",
        "analytics",
        "dashboard",
        "monitor",
        "backup",
        "archive",
        "migration",
        "application",
        "non-human",
        "nonhuman",
        "machine",
        "device"
    )
    
    foreach ($keyword in $serviceKeywords) {
        if ($DisplayName -like "*$keyword*") {
            return $true
        }
    }
    
    return $false
}

# ============================================================
# FUNCTION: Get All Users with Password Info
# ============================================================
function Get-AllUsersPasswordInfo {
    Write-Host ""
    Write-Host "Step 4: Retrieving all users..." -ForegroundColor Yellow
    Write-Host "This may take a few minutes..." -ForegroundColor Gray
    
    $allUsers = @()
    $currentDate = Get-Date
    
    try {
        # Get all users with required properties
        $users = Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, AccountEnabled, UserType, LastPasswordChangeDateTime, PasswordPolicies, CreatedDateTime, Mail, AssignedLicenses
        
        $total = $users.Count
        $count = 0
        
        foreach ($user in $users) {
            $count++
            if ($count % 50 -eq 0) {
                Write-Host "  Processing $count of $total users..." -ForegroundColor Gray
            }
            
            # Calculate password age
            $passwordAge = $null
            $passwordExpired = $false
            
            if ($user.LastPasswordChangeDateTime) {
                $passwordAge = ($currentDate - $user.LastPasswordChangeDateTime).Days
                $passwordExpired = $passwordAge -gt $PasswordAgeDays
            } else {
                $passwordAge = 9999
                $passwordExpired = $true
            }
            
            # Determine account type
            $isServiceAccount = Test-IsServiceAccount -UserPrincipalName $user.UserPrincipalName -DisplayName $user.DisplayName
            $isGuest = $user.UserType -eq "Guest"
            $isDisabled = -not $user.AccountEnabled
            $hasLicense = ($user.AssignedLicenses.Count -gt 0)
            $passwordNeverExpires = $user.PasswordPolicies -like "*DisablePasswordExpiration*"
            
            # Determine account category
            $accountCategory = "User"
            if ($isServiceAccount) { $accountCategory = "Service Account" }
            elseif ($isGuest) { $accountCategory = "Guest" }
            elseif (-not $hasLicense -and -not $isDisabled) { $accountCategory = "Unlicensed" }
            elseif ($user.UserPrincipalName -like "*#EXT#*") { $accountCategory = "External" }
            
            # Should we reset this account?
            $shouldReset = $false
            $skipReason = ""
            
            if ($passwordExpired) {
                if ($isServiceAccount) {
                    $skipReason = "Service Account - DO NOT RESET"
                } elseif ($isGuest) {
                    $skipReason = "Guest Account"
                } elseif ($isDisabled) {
                    $skipReason = "Account Disabled"
                } elseif ($passwordNeverExpires) {
                    $skipReason = "Password Never Expires Policy"
                } elseif (-not $hasLicense) {
                    $skipReason = "No License Assigned"
                } else {
                    $shouldReset = $true
                    $skipReason = "WILL RESET"
                }
            }
            
            $userInfo = [PSCustomObject]@{
                DisplayName = $user.DisplayName
                UserPrincipalName = $user.UserPrincipalName
                Email = $user.Mail
                AccountEnabled = $user.AccountEnabled
                UserType = $user.UserType
                AccountCategory = $accountCategory
                HasLicense = $hasLicense
                PasswordNeverExpires = $passwordNeverExpires
                LastPasswordChange = $user.LastPasswordChangeDateTime
                PasswordAgeDays = $passwordAge
                PasswordExpired = $passwordExpired
                IsServiceAccount = $isServiceAccount
                ShouldReset = $shouldReset
                Action = $skipReason
                UserId = $user.Id
            }
            
            $allUsers += $userInfo
        }
        
        Write-Host "Retrieved $($allUsers.Count) users!" -ForegroundColor Green
        return $allUsers
        
    } catch {
        Write-Host "ERROR retrieving users: $_" -ForegroundColor Red
        return $null
    }
}

# ============================================================
# FUNCTION: Generate Reports
# ============================================================
function Export-PasswordReports {
    param($AllUsers)
    
    Write-Host ""
    Write-Host "Step 5: Generating reports..." -ForegroundColor Yellow
    
    # All users report
    $allUsersReport = Join-Path $ReportPath "ALL-Users-Password-Status-$Timestamp.csv"
    $AllUsers | Export-Csv -Path $allUsersReport -NoTypeInformation
    Write-Host "  All Users Report: $allUsersReport" -ForegroundColor Cyan
    
    # Expired passwords only
    $expiredUsers = $AllUsers | Where-Object { $_.PasswordExpired -eq $true }
    $expiredReport = Join-Path $ReportPath "EXPIRED-Passwords-$Timestamp.csv"
    $expiredUsers | Export-Csv -Path $expiredReport -NoTypeInformation
    Write-Host "  Expired Passwords: $expiredReport" -ForegroundColor Cyan
    
    # Users to reset (excludes service accounts)
    $usersToReset = $AllUsers | Where-Object { $_.ShouldReset -eq $true }
    $resetReport = Join-Path $ReportPath "USERS-To-Reset-$Timestamp.csv"
    $usersToReset | Export-Csv -Path $resetReport -NoTypeInformation
    Write-Host "  Users to Reset: $resetReport" -ForegroundColor Cyan
    
    # Service accounts found
    $serviceAccounts = $AllUsers | Where-Object { $_.IsServiceAccount -eq $true }
    $serviceReport = Join-Path $ReportPath "SERVICE-Accounts-Excluded-$Timestamp.csv"
    $serviceAccounts | Export-Csv -Path $serviceReport -NoTypeInformation
    Write-Host "  Service Accounts (Excluded): $serviceReport" -ForegroundColor Cyan
    
    return @{
        AllUsers = $AllUsers
        ExpiredUsers = $expiredUsers
        UsersToReset = $usersToReset
        ServiceAccounts = $serviceAccounts
        ReportPath = $ReportPath
    }
}

# ============================================================
# FUNCTION: Show Summary
# ============================================================
function Show-Summary {
    param($Reports)
    
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  SUMMARY REPORT" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""
    
    $allCount = $Reports.AllUsers.Count
    $expiredCount = $Reports.ExpiredUsers.Count
    $resetCount = $Reports.UsersToReset.Count
    $serviceCount = $Reports.ServiceAccounts.Count
    $skippedCount = $expiredCount - $resetCount
    
    Write-Host "  Total Accounts:              $allCount" -ForegroundColor White
    Write-Host "  Passwords Expired (>90 days): $expiredCount" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Service Accounts (EXCLUDED):  $serviceCount" -ForegroundColor Magenta
    Write-Host "  Other Skipped:               $skippedCount" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  USERS TO RESET:              $resetCount" -ForegroundColor Green
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Reports saved to: $($Reports.ReportPath)" -ForegroundColor Cyan
    Write-Host ""
    
    # Show breakdown of skipped accounts
    Write-Host "SKIPPED ACCOUNTS BREAKDOWN:" -ForegroundColor Yellow
    $Reports.ExpiredUsers | Where-Object { $_.ShouldReset -eq $false } | Group-Object Action | ForEach-Object {
        Write-Host "  $($_.Name): $($_.Count)" -ForegroundColor Gray
    }
    Write-Host ""
}

# ============================================================
# FUNCTION: Force Password Reset
# ============================================================
function Invoke-PasswordReset {
    param($UsersToReset)
    
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "  PASSWORD RESET - MANUAL REVIEW REQUIRED" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "USERS TO BE RESET: $($UsersToReset.Count)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "SERVICE ACCOUNTS ARE ALREADY EXCLUDED." -ForegroundColor Green
    Write-Host ""
    
    # Show ALL users that will be reset for review
    Write-Host "FULL LIST OF USERS TO BE RESET:" -ForegroundColor Cyan
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host ""
    
    $i = 1
    foreach ($user in $UsersToReset) {
        Write-Host "  $i. $($user.DisplayName) | $($user.UserPrincipalName)" -ForegroundColor White
        $i++
    }
    
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host ""
    
    # Ask if user wants to exclude any additional accounts
    Write-Host "Do you want to EXCLUDE any additional accounts from this list?" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. NO - The list looks correct, proceed to reset" -ForegroundColor White
    Write-Host "  2. YES - I need to exclude some accounts first" -ForegroundColor White
    Write-Host "  3. CANCEL - Do not reset any passwords" -ForegroundColor White
    Write-Host ""
    
    $reviewChoice = Read-Host "Enter choice (1-3)"
    
    if ($reviewChoice -eq "3") {
        Write-Host ""
        Write-Host "CANCELLED - No passwords were reset." -ForegroundColor Yellow
        return
    }
    
    # Manual exclusion process
    if ($reviewChoice -eq "2") {
        Write-Host ""
        Write-Host "Enter the NUMBERS of accounts to EXCLUDE (comma separated)" -ForegroundColor Yellow
        Write-Host "Example: 5,12,23,45" -ForegroundColor Gray
        Write-Host ""
        
        $excludeInput = Read-Host "Accounts to exclude"
        
        if ($excludeInput) {
            $excludeNumbers = $excludeInput -split "," | ForEach-Object { [int]$_.Trim() }
            
            $filteredUsers = @()
            $excludedUsers = @()
            
            $i = 1
            foreach ($user in $UsersToReset) {
                if ($excludeNumbers -contains $i) {
                    $excludedUsers += $user
                    Write-Host "  EXCLUDED: $($user.DisplayName)" -ForegroundColor Magenta
                } else {
                    $filteredUsers += $user
                }
                $i++
            }
            
            $UsersToReset = $filteredUsers
            
            Write-Host ""
            Write-Host "Excluded $($excludedUsers.Count) accounts." -ForegroundColor Magenta
            Write-Host "Remaining accounts to reset: $($UsersToReset.Count)" -ForegroundColor Cyan
            Write-Host ""
            
            # Save excluded accounts to report
            $excludedReport = Join-Path $ReportPath "MANUALLY-Excluded-$Timestamp.csv"
            $excludedUsers | Export-Csv -Path $excludedReport -NoTypeInformation
            Write-Host "Manually excluded accounts saved to: $excludedReport" -ForegroundColor Cyan
            Write-Host ""
        }
    }
    
    if ($UsersToReset.Count -eq 0) {
        Write-Host "No users left to reset." -ForegroundColor Yellow
        return
    }
    
    # Final confirmation
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host "  FINAL CONFIRMATION" -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "You are about to force password reset for $($UsersToReset.Count) users." -ForegroundColor White
    Write-Host ""
    Write-Host "These users will be required to change their password at next login." -ForegroundColor White
    Write-Host ""
    Write-Host "THIS ACTION CANNOT BE UNDONE." -ForegroundColor Red
    Write-Host ""
    
    $confirm = Read-Host "Type YES to proceed with password reset"
    
    if ($confirm -ne "YES") {
        Write-Host ""
        Write-Host "CANCELLED - No changes made." -ForegroundColor Yellow
        return
    }
    
    Write-Host ""
    Write-Host "Resetting passwords..." -ForegroundColor Yellow
    
    $successCount = 0
    $failCount = 0
    $results = @()
    
    foreach ($user in $UsersToReset) {
        try {
            # Force password change at next login
            Update-MgUser -UserId $user.UserId -PasswordProfile @{
                ForceChangePasswordNextSignIn = $true
            }
            
            $successCount++
            $results += [PSCustomObject]@{
                UserPrincipalName = $user.UserPrincipalName
                DisplayName = $user.DisplayName
                Status = "SUCCESS"
                Error = ""
            }
            
            Write-Host "  [OK] $($user.DisplayName)" -ForegroundColor Green
            
        } catch {
            $failCount++
            $results += [PSCustomObject]@{
                UserPrincipalName = $user.UserPrincipalName
                DisplayName = $user.DisplayName
                Status = "FAILED"
                Error = $_.Exception.Message
            }
            
            Write-Host "  [FAILED] $($user.DisplayName) - $_" -ForegroundColor Red
        }
    }
    
    # Export results
    $resultsReport = Join-Path $ReportPath "PASSWORD-Reset-Results-$Timestamp.csv"
    $results | Export-Csv -Path $resultsReport -NoTypeInformation
    
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host "  PASSWORD RESET COMPLETE" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Successful: $successCount" -ForegroundColor Green
    Write-Host "  Failed:     $failCount" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Results saved to: $resultsReport" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================
# FUNCTION: Set Password Policy
# ============================================================
function Set-PasswordExpirationPolicy {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "  SET 90-DAY PASSWORD EXPIRATION POLICY" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This will configure M365 password policy:" -ForegroundColor White
    Write-Host ""
    Write-Host "  - Passwords expire after: 90 DAYS" -ForegroundColor Cyan
    Write-Host "  - Users notified: 14 DAYS before expiration" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "NOTE: Service accounts with 'Password Never Expires' will NOT be affected." -ForegroundColor Green
    Write-Host ""
    
    Write-Host ""
    $confirm = Read-Host "Type YES to set 90-day password policy for ALL USERS"
    
    if ($confirm -ne "YES") {
        Write-Host "CANCELLED - Policy not changed." -ForegroundColor Yellow
        return
    }
    
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "  SET PASSWORD POLICY VIA ADMIN CENTER" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "The password policy must be set in Microsoft 365 Admin Center." -ForegroundColor White
    Write-Host ""
    Write-Host "Opening Admin Center now..." -ForegroundColor Yellow
    Write-Host ""
    
    # Open the admin center
    Start-Process "https://admin.microsoft.com/#/Settings/SecurityPrivacy/:/Settings/L1/PasswordPolicy"
    
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  FOLLOW THESE STEPS IN THE BROWSER:" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Sign in with Global Admin account" -ForegroundColor White
    Write-Host ""
    Write-Host "  2. UNCHECK 'Set passwords to never expire'" -ForegroundColor White
    Write-Host ""
    Write-Host "  3. Set 'Days before passwords expire': 90" -ForegroundColor Green
    Write-Host ""
    Write-Host "  4. Set 'Days before user is notified': 14" -ForegroundColor Green
    Write-Host ""
    Write-Host "  5. Click SAVE" -ForegroundColor White
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "After saving, ALL users will have 90-day password expiration." -ForegroundColor Green
    Write-Host "Service accounts with 'Password Never Expires' are NOT affected." -ForegroundColor Green
    Write-Host ""
}

# ============================================================
# FUNCTION: Create Exclusion Group
# ============================================================
function New-PasswordPolicyExclusionGroup {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "  CREATE PASSWORD POLICY EXCLUSION GROUP" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This will create a security group for accounts that should" -ForegroundColor White
    Write-Host "be excluded from password expiration policies." -ForegroundColor White
    Write-Host ""
    
    $groupName = "Password-Policy-Exclusions"
    $groupDescription = "Accounts in this group are excluded from password expiration policies. Add service accounts, sync accounts, and break-glass accounts here."
    
    $confirm = Read-Host "Type YES to create exclusion group"
    
    if ($confirm -ne "YES") {
        Write-Host "CANCELLED" -ForegroundColor Yellow
        return
    }
    
    try {
        # Check if group exists
        $existingGroup = Get-MgGroup -Filter "displayName eq '$groupName'"
        
        if ($existingGroup) {
            Write-Host "Group already exists: $groupName" -ForegroundColor Yellow
            Write-Host "Group ID: $($existingGroup.Id)" -ForegroundColor Cyan
        } else {
            # Create group
            $newGroup = New-MgGroup -DisplayName $groupName -Description $groupDescription -MailEnabled:$false -MailNickname "PasswordPolicyExclusions" -SecurityEnabled:$true
            
            Write-Host "Group created: $groupName" -ForegroundColor Green
            Write-Host "Group ID: $($newGroup.Id)" -ForegroundColor Cyan
        }
        
        Write-Host ""
        Write-Host "Add service accounts to this group to exclude them from future resets." -ForegroundColor White
        Write-Host ""
        
    } catch {
        Write-Host "ERROR creating group: $_" -ForegroundColor Red
    }
}

# ============================================================
# MAIN MENU
# ============================================================
function Show-MainMenu {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  MAIN MENU - SELECT AN OPTION" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. RUN FULL REPORT (No changes - Safe)" -ForegroundColor White
    Write-Host "     - Find all expired passwords" -ForegroundColor Gray
    Write-Host "     - Identify service accounts" -ForegroundColor Gray
    Write-Host "     - Export to Excel/CSV" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. FORCE PASSWORD RESET (User accounts only)" -ForegroundColor White
    Write-Host "     - Reset expired user passwords" -ForegroundColor Gray
    Write-Host "     - Excludes service accounts" -ForegroundColor Gray
    Write-Host "     - Requires confirmation" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3. CREATE EXCLUSION GROUP" -ForegroundColor White
    Write-Host "     - Create security group for exclusions" -ForegroundColor Gray
    Write-Host "     - Add service accounts to skip them" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  4. VIEW PASSWORD POLICY INFO" -ForegroundColor White
    Write-Host "     - Show how to set 90-day policy" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  5. EXIT" -ForegroundColor White
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    
    $choice = Read-Host "Enter your choice (1-5)"
    return $choice
}

# ============================================================
# MAIN SCRIPT
# ============================================================

# Install modules
Install-RequiredModules

# Connect to Azure
$azureConnected = Connect-ToAzure
if (-not $azureConnected) {
    Write-Host "Cannot proceed without Azure connection." -ForegroundColor Red
    exit 1
}

# Select subscription
$subscription = Select-AzureSubscription

# Connect to Microsoft Graph
$graphConnected = Connect-ToGraph
if (-not $graphConnected) {
    Write-Host "Cannot proceed without Graph connection." -ForegroundColor Red
    exit 1
}

# Main loop
$continue = $true
$reports = $null

while ($continue) {
    $choice = Show-MainMenu
    
    switch ($choice) {
        "1" {
            # Run report
            $allUsers = Get-AllUsersPasswordInfo
            if ($allUsers) {
                $reports = Export-PasswordReports -AllUsers $allUsers
                Show-Summary -Reports $reports
                
                Write-Host "Press Enter to continue..."
                Read-Host
            }
        }
        "2" {
            # Force password reset
            if (-not $reports) {
                Write-Host ""
                Write-Host "Running report first..." -ForegroundColor Yellow
                $allUsers = Get-AllUsersPasswordInfo
                if ($allUsers) {
                    $reports = Export-PasswordReports -AllUsers $allUsers
                    Show-Summary -Reports $reports
                }
            }
            
            if ($reports -and $reports.UsersToReset.Count -gt 0) {
                Invoke-PasswordReset -UsersToReset $reports.UsersToReset
            } else {
                Write-Host "No users to reset!" -ForegroundColor Yellow
            }
            
            Write-Host "Press Enter to continue..."
            Read-Host
        }
        "3" {
            # Create exclusion group
            New-PasswordPolicyExclusionGroup
            
            Write-Host "Press Enter to continue..."
            Read-Host
        }
        "4" {
            # Show policy info
            Set-PasswordExpirationPolicy
            
            Write-Host "Press Enter to continue..."
            Read-Host
        }
        "5" {
            $continue = $false
            Write-Host ""
            Write-Host "Disconnecting..." -ForegroundColor Yellow
            Disconnect-MgGraph -ErrorAction SilentlyContinue
            Write-Host "Goodbye!" -ForegroundColor Green
        }
        default {
            Write-Host "Invalid choice. Please select 1-5." -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  REPORTS SAVED TO: $ReportPath" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""
