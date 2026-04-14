Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
cd C:\Users\PC\Downloads\Azure-Infrastructure\
Connect-AzAccount
.\Vanta-Evidence-Collector-V2.ps1 -EnvironmentName "TEST"
pause
