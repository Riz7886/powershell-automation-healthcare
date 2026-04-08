Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
cd C:\Users\PC\Downloads\Azure-Infrastructure\
Connect-AzAccount
.\Vanta-Compliance-Remediation.ps1 -Mode Audit
pause
