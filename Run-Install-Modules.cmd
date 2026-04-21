@echo off
REM ============================================================
REM  Force-install Azure PowerShell sub-modules.
REM  Run this ONCE if Run-DryRun.cmd complains about
REM  'Get-AzResource' or similar cmdlets not being recognized.
REM ============================================================
cd /d "%~dp0"

echo.
echo ============================================================
echo  Installing Az.Accounts, Az.Resources, Az.Network, Az.Sql
echo  (~2-3 minutes one-time, will not reinstall next time)
echo ============================================================
echo.

pwsh -NoProfile -ExecutionPolicy Bypass -Command "Install-Module -Name Az.Accounts,Az.Resources,Az.Network,Az.Sql -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop; Write-Host '  [OK] All Az sub-modules installed.' -ForegroundColor Green"

echo.
echo ============================================================
echo  Modules installed. Now double-click Run-DryRun.cmd
echo ============================================================
pause
