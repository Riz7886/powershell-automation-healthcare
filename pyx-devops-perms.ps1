# ============================================================
# PYX DEVOPS PERMISSIONS MANAGER
# Interactive script for pipeline + group permissions
# Org: techmodgroup | Project: Pyx.DriversHealth
# Prepared by: Syed
# ============================================================
# Prereqs:
#   1. Azure CLI: https://aka.ms/installazcli
#   2. azure-devops extension (auto-installed below if missing)
#   3. az login (auto-prompted below)
#
# To run:
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\pyx-devops-perms.ps1
# ============================================================

$ErrorActionPreference = 'Stop'

# --- Config ---
$Org     = "https://dev.azure.com/techmodgroup"
$Project = "Pyx.DriversHealth"

# Azure DevOps "Build" security namespace - same GUID everywhere
$BuildNamespace = "33344D9C-FC72-4D6F-ABA2-FA30C578BBE7"

# Permission presets for pipelines (bit values from Azure DevOps Build namespace)
$PresetPermissions = @{
    "Reader"        = 17     # ViewBuildDefinition(1) + ViewBuilds(16)
    "Contributor"   = 145    # Reader + QueueBuilds(128)
    "Editor"        = 147    # Contributor + EditBuildDefinition(2)
    "Administrator" = 16535  # Full access including delete + manage
}

# ============================================================
# HELPERS
# ============================================================

function Test-Prereqs {
    Write-Host "Checking prerequisites..." -ForegroundColor Yellow

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI not installed. Get it: https://aka.ms/installazcli"
    }

    $ext = az extension list --query "[?name=='azure-devops']" 2>$null | ConvertFrom-Json
    if (-not $ext) {
        Write-Host "  Installing azure-devops extension..." -ForegroundColor Yellow
        az extension add --name azure-devops --only-show-errors | Out-Null
    }

    $account = az account show --query user.name -o tsv 2>$null
    if (-not $account) {
        Write-Host "  Not logged in. Running az login..." -ForegroundColor Yellow
        az login | Out-Null
        $account = az account show --query user.name -o tsv
    }

    az devops configure --defaults organization=$Org project=$Project 2>&1 | Out-Null

    Write-Host "  Logged in as: $account" -ForegroundColor Green
    Write-Host "  Target org:   $Org" -ForegroundColor Green
    Write-Host "  Project:      $Project" -ForegroundColor Green
}

function Get-ProjectId {
    return (az devops project show --project $Project --org $Org --query id -o tsv)
}

function Show-Menu {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "  PYX DEVOPS PERMISSIONS MANAGER" -ForegroundColor Cyan
    Write-Host "  Org: techmodgroup  |  Project: Pyx.DriversHealth" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  1. List all pipelines"
    Write-Host "  2. List security groups in the project"
    Write-Host "  3. Grant a user or group DIRECT permissions on a pipeline"
    Write-Host "  4. Create a new security group, add users, grant it pipeline access"
    Write-Host "  5. Show current permissions on a pipeline"
    Write-Host "  6. Exit"
    Write-Host "============================================================" -ForegroundColor Cyan
    return (Read-Host "Choose [1-6]")
}

function List-Pipelines {
    Write-Host "`nPipelines in ${Project}:" -ForegroundColor Cyan
    az pipelines list --org $Org --project $Project `
        --query "[].{ID:id, Name:name, Folder:path, Status:queueStatus}" -o table
}

function List-Groups {
    Write-Host "`nProject-scoped security groups:" -ForegroundColor Cyan
    $projectId = Get-ProjectId
    az devops security group list --scope project --project-id $projectId --org $Org `
        --query "graphGroups[].{Name:displayName, Principal:principalName, Descriptor:descriptor}" -o table
}

function Show-PipelinePermissions {
    param([string]$PipelineId)
    $projectId = Get-ProjectId
    $token = "$projectId/$PipelineId"
    Write-Host "`nCurrent ACL for pipeline ${PipelineId}:" -ForegroundColor Cyan
    Write-Host "Token: $token" -ForegroundColor DarkGray
    az devops security permission list --id $BuildNamespace --token $token --org $Org -o table
}

function Select-Preset {
    Write-Host "`nPermission presets:" -ForegroundColor Cyan
    Write-Host "  Reader        - view pipeline + builds (no run)"
    Write-Host "  Contributor   - Reader + queue new builds"
    Write-Host "  Editor        - Contributor + edit pipeline definition"
    Write-Host "  Administrator - full control"
    $p = Read-Host "Preset [Reader/Contributor/Editor/Administrator]"
    if (-not $PresetPermissions.ContainsKey($p)) { throw "Invalid preset: $p" }
    return $p
}

function Grant-PipelinePermission {
    param(
        [string]$PipelineId,
        [string]$IdentitySubject,
        [int]$AllowBit,
        [string]$PresetName
    )
    $projectId = Get-ProjectId
    $token = "$projectId/$PipelineId"

    Write-Host "`n--- PREVIEW ---" -ForegroundColor Yellow
    Write-Host "  Pipeline ID:  $PipelineId"
    Write-Host "  Identity:     $IdentitySubject"
    Write-Host "  Preset:       $PresetName (allow-bit $AllowBit)"
    Write-Host "  Token:        $token"

    $confirm = Read-Host "`nApply? [y/N]"
    if ($confirm -notmatch '^[yY]$') {
        Write-Host "  Cancelled" -ForegroundColor Red
        return
    }

    az devops security permission update `
        --id $BuildNamespace `
        --subject $IdentitySubject `
        --token $token `
        --allow-bit $AllowBit `
        --org $Org | Out-Null

    Write-Host "  Permission applied" -ForegroundColor Green
}

# ============================================================
# ACTIONS
# ============================================================

function Action-GrantDirect {
    List-Pipelines
    $pipelineId = Read-Host "`nPipeline ID to modify (e.g. 83 for 'hi pyx API')"

    Write-Host "`nWho gets the permission?"
    Write-Host "  - For a USER: enter their email"
    Write-Host "  - For a GROUP: enter the group descriptor from option 2"
    $subject = Read-Host "Subject"

    $preset = Select-Preset

    Grant-PipelinePermission `
        -PipelineId $pipelineId `
        -IdentitySubject $subject `
        -AllowBit $PresetPermissions[$preset] `
        -PresetName $preset
}

function Action-CreateGroupAndGrant {
    $groupName   = Read-Host "New group name (e.g. 'Pyx API Contributors')"
    $description = Read-Host "Description (optional, press Enter to skip)"

    $projectId = Get-ProjectId

    Write-Host "`nCreating group '$groupName'..." -ForegroundColor Yellow
    $groupArgs = @(
        "--name", $groupName,
        "--scope", "project",
        "--project-id", $projectId,
        "--org", $Org
    )
    if ($description) { $groupArgs += @("--description", $description) }

    $group = az devops security group create @groupArgs | ConvertFrom-Json
    $groupDescriptor = $group.descriptor
    Write-Host "  Created: $groupName" -ForegroundColor Green
    Write-Host "  Descriptor: $groupDescriptor" -ForegroundColor DarkGray

    $users = Read-Host "`nComma-separated user emails to add to the group (Enter to skip)"
    if ($users) {
        foreach ($email in $users -split ',') {
            $email = $email.Trim()
            if (-not $email) { continue }
            Write-Host "  Adding $email..." -ForegroundColor Yellow
            az devops security group membership add `
                --group-id $groupDescriptor `
                --member-id $email `
                --org $Org | Out-Null
        }
        Write-Host "  Members added" -ForegroundColor Green
    }

    Write-Host "`nNow grant this group access to a pipeline." -ForegroundColor Cyan
    List-Pipelines
    $pipelineId = Read-Host "`nPipeline ID (or Enter to skip)"
    if (-not $pipelineId) {
        Write-Host "  Skipped. Run option 3 later with the group descriptor above as the subject." -ForegroundColor Yellow
        return
    }

    $preset = Select-Preset
    Grant-PipelinePermission `
        -PipelineId $pipelineId `
        -IdentitySubject $groupDescriptor `
        -AllowBit $PresetPermissions[$preset] `
        -PresetName $preset
}

# ============================================================
# MAIN LOOP
# ============================================================

Test-Prereqs

while ($true) {
    $choice = Show-Menu
    try {
        switch ($choice) {
            "1" { List-Pipelines }
            "2" { List-Groups }
            "3" { Action-GrantDirect }
            "4" { Action-CreateGroupAndGrant }
            "5" {
                List-Pipelines
                $p = Read-Host "`nPipeline ID"
                Show-PipelinePermissions -PipelineId $p
            }
            "6" { Write-Host "`nDone." -ForegroundColor Cyan; exit 0 }
            default { Write-Host "Invalid choice" -ForegroundColor Red }
        }
    } catch {
        Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
    Read-Host "`nPress Enter to continue"
}
