@echo off
REM ============================================================
REM  DRY RUN — shows what would be whitelisted, changes NOTHING
REM ============================================================
cd /d "%~dp0"
set AZURE_CORE_LOGIN_EXPERIENCE_V2=Off
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\Fix-Databricks-SQL-Access.ps1" -SqlServerName "sql-qa-datasystems"
echo.
echo ============================================================
echo  DRY-RUN DONE. If it looks right, double-click Run-Execute.cmd
echo ============================================================
pause
