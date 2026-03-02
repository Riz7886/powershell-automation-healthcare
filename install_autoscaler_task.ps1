$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  DATABRICKS AUTO-SCALER - TASK SCHEDULER SETUP" -ForegroundColor Cyan
Write-Host "  Installs 24/7 monitoring every 5 minutes" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

$taskName = "Databricks-AutoScaler"
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$scalerScript = Join-Path $scriptDir "databricks_autoscaler.ps1"

# ---------------------------------------------------------------
# STEP 1: Verify auto-scaler script exists
# ---------------------------------------------------------------
Write-Host "[1/4] Checking auto-scaler script..." -ForegroundColor Yellow

if (-not (Test-Path $scalerScript)) {
    Write-Host "  ERROR: $scalerScript not found!" -ForegroundColor Red
    Write-Host "  Place databricks_autoscaler.ps1 in the same folder as this script." -ForegroundColor Red
    exit 1
}

Write-Host "  Found: $scalerScript" -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------
# STEP 2: Set up client secret
# ---------------------------------------------------------------
Write-Host "[2/4] Setting up service principal secret..." -ForegroundColor Yellow

$secretFile = Join-Path $scriptDir ".sp-secret"

if (Test-Path $secretFile) {
    Write-Host "  Secret file exists: $secretFile" -ForegroundColor Green
}
else {
    $hasEnvVar = $env:DATABRICKS_SP_SECRET
    if ($hasEnvVar) {
        Write-Host "  Using DATABRICKS_SP_SECRET environment variable." -ForegroundColor Green
    }
    else {
        Write-Host "  No secret found. Choose an option:" -ForegroundColor Yellow
        Write-Host "  1. Enter the client secret now (saved to .sp-secret file)" -ForegroundColor White
        Write-Host "  2. Set DATABRICKS_SP_SECRET environment variable later" -ForegroundColor White
        Write-Host "  3. Skip for now (script will use Azure CLI fallback)" -ForegroundColor White
        Write-Host ""

        $choice = Read-Host "  Choice (1/2/3)"

        switch ($choice) {
            "1" {
                $secret = Read-Host "  Enter the client secret" -AsSecureString
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
                $plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

                $plainSecret | Out-File -FilePath $secretFile -Encoding UTF8 -NoNewline

                # Restrict file permissions
                $acl = Get-Acl $secretFile
                $acl.SetAccessRuleProtection($true, $false)
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                    "FullControl",
                    "Allow"
                )
                $acl.AddAccessRule($rule)
                try { Set-Acl -Path $secretFile -AclObject $acl } catch {}

                Write-Host "  Secret saved to $secretFile (restricted permissions)" -ForegroundColor Green
            }
            "2" {
                Write-Host "  Set the environment variable:" -ForegroundColor Yellow
                Write-Host '  [System.Environment]::SetEnvironmentVariable("DATABRICKS_SP_SECRET", "YOUR_SECRET", "Machine")' -ForegroundColor White
                Write-Host "  Then re-run this setup." -ForegroundColor Yellow
            }
            "3" {
                Write-Host "  Skipped. Auto-scaler will try Azure CLI token as fallback." -ForegroundColor Yellow
            }
        }
    }
}
Write-Host ""

# ---------------------------------------------------------------
# STEP 3: Create/Update Scheduled Task
# ---------------------------------------------------------------
Write-Host "[3/4] Setting up Windows Task Scheduler..." -ForegroundColor Yellow

# Remove existing task if present
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host "  Removing existing task '$taskName'..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# Build the action
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scalerScript`"" `
    -WorkingDirectory $scriptDir

# Trigger: every 5 minutes, indefinitely
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)

# Settings
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 4) `
    -MultipleInstances IgnoreNew

# Principal - run whether logged in or not
$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType S4U `
    -RunLevel Highest

try {
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description "Databricks SQL Warehouse Auto-Scaler. Checks latency and queue depth every 5 minutes. Scales up when slow, scales down when idle. Uses service principal for auth." `
        | Out-Null

    Write-Host "  Task '$taskName' created successfully!" -ForegroundColor Green
    Write-Host "  Schedule: Every 5 minutes, 24/7" -ForegroundColor Green
    Write-Host "  Runs as: $env:USERDOMAIN\$env:USERNAME" -ForegroundColor Green
}
catch {
    Write-Host "  ERROR creating scheduled task: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "  MANUAL SETUP:" -ForegroundColor Yellow
    Write-Host "  1. Open Task Scheduler (taskschd.msc)" -ForegroundColor White
    Write-Host "  2. Create Basic Task: '$taskName'" -ForegroundColor White
    Write-Host "  3. Trigger: Repeat every 5 minutes" -ForegroundColor White
    Write-Host "  4. Action: Start a program" -ForegroundColor White
    Write-Host "     Program: powershell.exe" -ForegroundColor White
    Write-Host "     Arguments: -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scalerScript`"" -ForegroundColor White
    Write-Host "     Start in: $scriptDir" -ForegroundColor White
    Write-Host "  5. Check 'Run whether user is logged on or not'" -ForegroundColor White
    $allErrors += "Could not create scheduled task automatically"
}
Write-Host ""

# ---------------------------------------------------------------
# STEP 4: Test run
# ---------------------------------------------------------------
Write-Host "[4/4] Running initial test..." -ForegroundColor Yellow
Write-Host ""

try {
    & $scalerScript
    Write-Host ""
    Write-Host "  Test run complete!" -ForegroundColor Green
}
catch {
    Write-Host "  Test run had errors (expected if secret not set yet): $_" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  SETUP COMPLETE" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Task: $taskName" -ForegroundColor Green
Write-Host "  Schedule: Every 5 minutes, 24/7" -ForegroundColor Green
Write-Host "  Script: $scalerScript" -ForegroundColor Green
Write-Host "  Logs: $scriptDir\autoscaler-logs\" -ForegroundColor Green
Write-Host "  Reports: $scriptDir\autoscaler-reports\" -ForegroundColor Green
Write-Host ""
Write-Host "  MANAGE:" -ForegroundColor Yellow
Write-Host "  View task:    Get-ScheduledTask -TaskName '$taskName'" -ForegroundColor White
Write-Host "  Run now:      Start-ScheduledTask -TaskName '$taskName'" -ForegroundColor White
Write-Host "  Stop:         Stop-ScheduledTask -TaskName '$taskName'" -ForegroundColor White
Write-Host "  Disable:      Disable-ScheduledTask -TaskName '$taskName'" -ForegroundColor White
Write-Host "  Remove:       Unregister-ScheduledTask -TaskName '$taskName'" -ForegroundColor White
Write-Host ""
Write-Host "  The auto-scaler will:" -ForegroundColor Yellow
Write-Host "    - Check every 5 minutes" -ForegroundColor White
Write-Host "    - Scale UP if avg latency > 30s or queue > 5" -ForegroundColor White
Write-Host "    - Scale DOWN if avg latency < 5s and no queue" -ForegroundColor White
Write-Host "    - Do NOTHING if performance is OK" -ForegroundColor White
Write-Host "    - Never scale more than 3x per hour (safety)" -ForegroundColor White
Write-Host "    - 10 min cooldown between actions" -ForegroundColor White
Write-Host ""
