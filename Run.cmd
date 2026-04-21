@echo off
REM ============================================================
REM  Double-click to auto-test and auto-fix pyx-qa SQL firewall.
REM  (That's the REAL target — Brian's notebook connects to
REM   pyx-qa.database.windows.net, not sql-qa-datasystems.)
REM ============================================================
cd /d "%~dp0"
set AZURE_CORE_LOGIN_EXPERIENCE_V2=Off
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\Test-And-Fix-SQL-Access.ps1" -SqlServerName "pyx-qa"
echo.
pause
