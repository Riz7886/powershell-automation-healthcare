@echo off
REM ============================================================
REM  EXECUTE — whitelists AzureDatabricks IP ranges on SQL Server
REM  Also removes the obsolete burge-20260421 IP rule.
REM  Safe to re-run (idempotent).
REM ============================================================
cd /d "%~dp0"
set AZURE_CORE_LOGIN_EXPERIENCE_V2=Off

echo.
echo ============================================================
echo  ABOUT TO MODIFY AZURE firewall on sql-qa-datasystems.
echo  Press CTRL-C to cancel, or any key to proceed.
echo ============================================================
pause

pwsh -NoProfile -ExecutionPolicy Bypass -File ".\Fix-Databricks-SQL-Access.ps1" -SqlServerName "sql-qa-datasystems" -RemoveOldRules "burge-20260421" -Execute

echo.
echo ============================================================
echo  DONE. From now on, any Databricks cluster (restart, scale,
echo  new cluster) in westus/westus2/centralus can reach the SQL
echo  server. No per-cluster whitelisting ever again.
echo ============================================================
pause
