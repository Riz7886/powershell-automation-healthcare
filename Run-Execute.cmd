@echo off
REM ============================================================
REM  Databricks -> SQL whitelist fix — EXECUTE (modifies Azure)
REM  Double-click only AFTER Run-DryRun.cmd output looks right.
REM  Removes the old IP rule 'burge-20260421' and swaps in
REM  subnet-based VNet firewall rules.
REM ============================================================
cd /d "%~dp0"

echo.
echo ============================================================
echo  ABOUT TO MODIFY AZURE (SQL Server firewall + subnets)
echo  Press CTRL-C to cancel, or any key to proceed...
echo ============================================================
pause

pwsh -NoProfile -ExecutionPolicy Bypass -File ".\Fix-Databricks-SQL-Whitelist.ps1" -SqlServerName "sql-qa-datasystems" -RemoveIpRuleName "burge-20260421" -Execute

echo.
echo ============================================================
echo  DONE. Test from a Databricks notebook:
echo      %%sql  SELECT 1
echo  Then restart the cluster and test again.
echo ============================================================
pause
