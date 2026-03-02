# ============================================================================
# AZURE FRONT DOOR MIGRATION AUDIT SCRIPT
# ============================================================================
# Purpose: Scan all subscriptions and find Front Door resources needing migration
# Deadline: August 15, 2025 - Migrate to Standard or Premium
# Date: December 31, 2025
# ============================================================================

#Requires -Version 5.1

# Set error handling
$ErrorActionPreference = "Continue"

# ============================================================================
# BANNER
# ============================================================================
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "============================================================================" -ForegroundColor Cyan
    Write-Host "       AZURE FRONT DOOR MIGRATION AUDIT" -ForegroundColor Cyan
    Write-Host "       Deadline: August 15, 2025" -ForegroundColor Yellow
    Write-Host "============================================================================" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================================
# LOGGING FUNCTION
# ============================================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    switch ($Level) {
        "SUCCESS" { Write-Host "[$timestamp] $Message" -ForegroundColor Green }
        "ERROR"   { Write-Host "[$timestamp] $Message" -ForegroundColor Red }
        "WARN"    { Write-Host "[$timestamp] $Message" -ForegroundColor Yellow }
        "INFO"    { Write-Host "[$timestamp] $Message" -ForegroundColor White }
        "HEADER"  { Write-Host "[$timestamp] $Message" -ForegroundColor Cyan }
        default   { Write-Host "[$timestamp] $Message" -ForegroundColor White }
    }
}

# ============================================================================
# AUTO-INSTALL REQUIRED MODULES
# ============================================================================
function Install-RequiredModules {
    Write-Log "Checking required PowerShell modules..." "HEADER"
    
    $requiredModules = @(
        @{Name = "Az.Accounts"; MinVersion = "2.0.0" },
        @{Name = "Az.FrontDoor"; MinVersion = "1.0.0" },
        @{Name = "Az.Cdn"; MinVersion = "2.0.0" },
        @{Name = "Az.Resources"; MinVersion = "6.0.0" }
    )
    
    foreach ($module in $requiredModules) {
        $installed = Get-Module -ListAvailable -Name $module.Name | 
            Sort-Object Version -Descending | 
            Select-Object -First 1
        
        if ($null -eq $installed) {
            Write-Log "  Installing $($module.Name)..." "WARN"
            try {
                Install-Module -Name $module.Name -Force -AllowClobber -Scope CurrentUser -Repository PSGallery -ErrorAction Stop
                Write-Log "  SUCCESS: $($module.Name) installed" "SUCCESS"
            }
            catch {
                Write-Log "  ERROR: Failed to install $($module.Name): $($_.Exception.Message)" "ERROR"
            }
        }
        else {
            Write-Log "  OK: $($module.Name) (v$($installed.Version))" "SUCCESS"
        }
    }
    Write-Host ""
}

# ============================================================================
# CONNECT TO AZURE
# ============================================================================
function Connect-ToAzure {
    Write-Log "Connecting to Azure..." "HEADER"
    
    try {
        $context = Get-AzContext -ErrorAction SilentlyContinue
        if ($null -eq $context) {
            Write-Log "  Opening browser for Azure login..." "WARN"
            Connect-AzAccount -ErrorAction Stop | Out-Null
        }
        else {
            Write-Log "  Already connected as: $($context.Account.Id)" "INFO"
            $useExisting = Read-Host "  Use existing connection? (Y/N)"
            if ($useExisting -ne "Y" -and $useExisting -ne "y") {
                Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
                Connect-AzAccount -ErrorAction Stop | Out-Null
            }
        }
        
        $context = Get-AzContext
        Write-Log "  Connected as: $($context.Account.Id)" "SUCCESS"
        Write-Host ""
        return $true
    }
    catch {
        Write-Log "  ERROR: Failed to connect: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# ============================================================================
# GET ALL SUBSCRIPTIONS
# ============================================================================
function Get-AllSubscriptions {
    Write-Log "Getting all subscriptions..." "HEADER"
    
    try {
        $subscriptions = Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq "Enabled" }
        Write-Log "  Found $($subscriptions.Count) active subscription(s)" "SUCCESS"
        Write-Host ""
        return $subscriptions
    }
    catch {
        Write-Log "  ERROR: Failed to get subscriptions: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# ============================================================================
# SCAN FOR FRONT DOOR RESOURCES
# ============================================================================
function Get-FrontDoorResources {
    param (
        [object[]]$Subscriptions
    )
    
    $allFrontDoors = @()
    $subscriptionCount = $Subscriptions.Count
    $currentSub = 0
    
    Write-Log "Scanning $subscriptionCount subscription(s) for Front Door resources..." "HEADER"
    Write-Host ""
    
    foreach ($sub in $Subscriptions) {
        $currentSub++
        Write-Log "[$currentSub/$subscriptionCount] Scanning: $($sub.Name)" "INFO"
        
        try {
            # Set subscription context
            Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
            
            # ============================================
            # Check for Front Door CLASSIC (Az.FrontDoor)
            # ============================================
            try {
                $classicFrontDoors = Get-AzFrontDoor -ErrorAction SilentlyContinue
                
                if ($classicFrontDoors) {
                    foreach ($fd in $classicFrontDoors) {
                        Write-Log "    FOUND (CLASSIC): $($fd.Name)" "WARN"
                        
                        $allFrontDoors += [PSCustomObject]@{
                            SubscriptionName = $sub.Name
                            SubscriptionId   = $sub.Id
                            ResourceGroup    = $fd.ResourceGroupName
                            Name             = $fd.Name
                            Type             = "Front Door Classic"
                            SKU              = "Classic"
                            State            = $fd.EnabledState
                            NeedsMigration   = "YES - URGENT"
                            Deadline         = "August 15, 2025"
                            ResourceId       = $fd.Id
                        }
                    }
                }
            }
            catch {
                # No classic Front Doors or error - continue
            }
            
            # ============================================
            # Check for Front Door Standard/Premium (Az.Cdn)
            # ============================================
            try {
                $cdnProfiles = Get-AzFrontDoorCdnProfile -ErrorAction SilentlyContinue
                
                if ($cdnProfiles) {
                    foreach ($profile in $cdnProfiles) {
                        $sku = $profile.SkuName
                        $needsMigration = if ($sku -match "Standard|Premium") { "NO - Already migrated" } else { "YES" }
                        $urgency = if ($sku -match "Standard|Premium") { "None" } else { "URGENT" }
                        
                        $status = if ($needsMigration -eq "NO - Already migrated") { "SUCCESS" } else { "WARN" }
                        Write-Log "    FOUND ($sku): $($profile.Name)" $status
                        
                        $allFrontDoors += [PSCustomObject]@{
                            SubscriptionName = $sub.Name
                            SubscriptionId   = $sub.Id
                            ResourceGroup    = $profile.ResourceGroupName
                            Name             = $profile.Name
                            Type             = "Front Door CDN Profile"
                            SKU              = $sku
                            State            = $profile.ProvisioningState
                            NeedsMigration   = $needsMigration
                            Deadline         = if ($needsMigration -like "YES*") { "August 15, 2025" } else { "N/A" }
                            ResourceId       = $profile.Id
                        }
                    }
                }
            }
            catch {
                # No CDN profiles or error - continue
            }
            
            # ============================================
            # Also check via Resource Graph for any missed
            # ============================================
            try {
                $resources = Get-AzResource -ResourceType "Microsoft.Network/frontDoors" -ErrorAction SilentlyContinue
                
                foreach ($res in $resources) {
                    # Check if already captured
                    $exists = $allFrontDoors | Where-Object { $_.ResourceId -eq $res.ResourceId }
                    if (-not $exists) {
                        Write-Log "    FOUND (Network): $($res.Name)" "WARN"
                        
                        $allFrontDoors += [PSCustomObject]@{
                            SubscriptionName = $sub.Name
                            SubscriptionId   = $sub.Id
                            ResourceGroup    = $res.ResourceGroupName
                            Name             = $res.Name
                            Type             = "Microsoft.Network/frontDoors"
                            SKU              = "Classic (Legacy)"
                            State            = "Active"
                            NeedsMigration   = "YES - URGENT"
                            Deadline         = "August 15, 2025"
                            ResourceId       = $res.ResourceId
                        }
                    }
                }
                
                # Check for CDN Front Door profiles
                $cdnResources = Get-AzResource -ResourceType "Microsoft.Cdn/profiles" -ErrorAction SilentlyContinue
                
                foreach ($res in $cdnResources) {
                    # Only include if it's a Front Door profile
                    if ($res.Kind -match "frontdoor" -or $res.Sku.Name -match "Standard_AzureFrontDoor|Premium_AzureFrontDoor") {
                        $exists = $allFrontDoors | Where-Object { $_.ResourceId -eq $res.ResourceId }
                        if (-not $exists) {
                            $skuName = if ($res.Sku) { $res.Sku.Name } else { "Unknown" }
                            $needsMigration = if ($skuName -match "Standard|Premium") { "NO - Already migrated" } else { "CHECK MANUALLY" }
                            
                            Write-Log "    FOUND (CDN): $($res.Name) [$skuName]" "INFO"
                            
                            $allFrontDoors += [PSCustomObject]@{
                                SubscriptionName = $sub.Name
                                SubscriptionId   = $sub.Id
                                ResourceGroup    = $res.ResourceGroupName
                                Name             = $res.Name
                                Type             = "Microsoft.Cdn/profiles"
                                SKU              = $skuName
                                State            = "Active"
                                NeedsMigration   = $needsMigration
                                Deadline         = if ($needsMigration -like "YES*") { "August 15, 2025" } else { "N/A" }
                                ResourceId       = $res.ResourceId
                            }
                        }
                    }
                }
            }
            catch {
                # Continue on error
            }
            
        }
        catch {
            Write-Log "    ERROR scanning subscription: $($_.Exception.Message)" "ERROR"
        }
    }
    
    Write-Host ""
    return $allFrontDoors
}

# ============================================================================
# GENERATE REPORT
# ============================================================================
function Generate-Report {
    param (
        [object[]]$FrontDoors
    )
    
    $reportDate = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $reportPath = "$env:USERPROFILE\Desktop\FrontDoor-Migration-Report_$reportDate.csv"
    
    Write-Log "============================================" "HEADER"
    Write-Log "FRONT DOOR MIGRATION REPORT" "HEADER"
    Write-Log "============================================" "HEADER"
    Write-Host ""
    
    if ($FrontDoors.Count -eq 0) {
        Write-Log "No Front Door resources found in any subscription." "SUCCESS"
        Write-Log "Nothing needs to be migrated!" "SUCCESS"
        return
    }
    
    # Summary counts
    $totalCount = $FrontDoors.Count
    $needMigration = ($FrontDoors | Where-Object { $_.NeedsMigration -like "YES*" }).Count
    $alreadyMigrated = ($FrontDoors | Where-Object { $_.NeedsMigration -like "NO*" }).Count
    
    Write-Log "SUMMARY:" "HEADER"
    Write-Log "  Total Front Door resources: $totalCount" "INFO"
    Write-Log "  Need Migration (URGENT):    $needMigration" $(if ($needMigration -gt 0) { "WARN" } else { "SUCCESS" })
    Write-Log "  Already Migrated:           $alreadyMigrated" "SUCCESS"
    Write-Host ""
    
    # Display details
    Write-Log "DETAILS:" "HEADER"
    Write-Host ""
    
    foreach ($fd in $FrontDoors) {
        $color = if ($fd.NeedsMigration -like "YES*") { "WARN" } else { "SUCCESS" }
        
        Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor Gray
        Write-Log "  Name: $($fd.Name)" "INFO"
        Write-Log "  Subscription: $($fd.SubscriptionName)" "INFO"
        Write-Log "  Resource Group: $($fd.ResourceGroup)" "INFO"
        Write-Log "  Type: $($fd.Type)" "INFO"
        Write-Log "  SKU: $($fd.SKU)" "INFO"
        Write-Log "  Needs Migration: $($fd.NeedsMigration)" $color
        if ($fd.NeedsMigration -like "YES*") {
            Write-Log "  DEADLINE: $($fd.Deadline)" "ERROR"
        }
        Write-Host ""
    }
    
    # Export to CSV
    try {
        $FrontDoors | Export-Csv -Path $reportPath -NoTypeInformation -Force
        Write-Host ""
        Write-Log "============================================" "SUCCESS"
        Write-Log "REPORT EXPORTED!" "SUCCESS"
        Write-Log "File: $reportPath" "SUCCESS"
        Write-Log "============================================" "SUCCESS"
    }
    catch {
        Write-Log "ERROR exporting report: $($_.Exception.Message)" "ERROR"
    }
    
    # Action items
    if ($needMigration -gt 0) {
        Write-Host ""
        Write-Log "============================================" "WARN"
        Write-Log "ACTION REQUIRED!" "WARN"
        Write-Log "============================================" "WARN"
        Write-Log "$needMigration resource(s) need migration before August 15, 2025" "WARN"
        Write-Host ""
        Write-Log "Migration options:" "INFO"
        Write-Log "  1. Migrate to Azure Front Door Standard" "INFO"
        Write-Log "  2. Migrate to Azure Front Door Premium" "INFO"
        Write-Host ""
        Write-Log "Documentation:" "INFO"
        Write-Log "  https://learn.microsoft.com/en-us/azure/frontdoor/migrate-tier" "INFO"
    }
}

# ============================================================================
# MAIN MENU
# ============================================================================
function Show-MainMenu {
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "              SELECT OPTION" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] Scan ALL subscriptions" -ForegroundColor Yellow
    Write-Host "  [2] Scan specific subscription" -ForegroundColor White
    Write-Host "  [3] Exit" -ForegroundColor White
    Write-Host ""
    
    $selection = Read-Host "  Select option (1-3)"
    return $selection
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Show banner
Show-Banner

# Install modules
Install-RequiredModules

# Connect to Azure
$connected = Connect-ToAzure
if (-not $connected) {
    Write-Log "Failed to connect to Azure. Exiting." "ERROR"
    Read-Host "Press Enter to exit"
    exit 1
}

# Get subscriptions
$subscriptions = Get-AllSubscriptions
if (-not $subscriptions) {
    Write-Log "No subscriptions found. Exiting." "ERROR"
    Read-Host "Press Enter to exit"
    exit 1
}

# Show menu
$choice = Show-MainMenu

switch ($choice) {
    "1" {
        # Scan all subscriptions
        Write-Host ""
        $frontDoors = Get-FrontDoorResources -Subscriptions $subscriptions
        Generate-Report -FrontDoors $frontDoors
    }
    "2" {
        # Select specific subscription
        Write-Host ""
        Write-Host "  Available subscriptions:" -ForegroundColor Cyan
        Write-Host ""
        
        $index = 1
        foreach ($sub in $subscriptions) {
            Write-Host "  [$index] $($sub.Name)" -ForegroundColor White
            $index++
        }
        
        Write-Host ""
        $subChoice = Read-Host "  Select subscription number"
        $selectedIndex = [int]$subChoice - 1
        
        if ($selectedIndex -ge 0 -and $selectedIndex -lt $subscriptions.Count) {
            $selectedSub = @($subscriptions[$selectedIndex])
            Write-Host ""
            $frontDoors = Get-FrontDoorResources -Subscriptions $selectedSub
            Generate-Report -FrontDoors $frontDoors
        }
        else {
            Write-Log "Invalid selection" "ERROR"
        }
    }
    "3" {
        Write-Log "Exiting..." "INFO"
        exit 0
    }
    default {
        Write-Log "Invalid selection" "ERROR"
    }
}

Write-Host ""
Read-Host "Press Enter to exit"
