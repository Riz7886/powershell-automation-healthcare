@echo off
REM ============================================================
REM  Databricks -> SQL whitelist fix — DRY RUN (safe, no changes)
REM  Double-click to run. Shows what the real fix would do.
REM ============================================================
cd /d "%~dp0"
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\Fix-Databricks-SQL-Whitelist.ps1" -SqlServerName "sql-qa-datasystems"
echo.
echo ============================================================
echo  DRY-RUN DONE. If it looked right, double-click:
echo     Run-Execute.cmd
echo ============================================================
pause
