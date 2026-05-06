$hosts = @("vm-moveit-auto","vm-moveit-xfr")
Write-Host "Setting TrustedHosts..." -ForegroundColor Cyan
Set-Item WSMan:\localhost\Client\TrustedHosts -Value ($hosts -join ",") -Force -Concatenate
Write-Host "OK" -ForegroundColor Green
foreach ($h in $hosts) {
    Write-Host ""
    Write-Host "Restarting datadogagent on $h ..." -ForegroundColor Cyan
    try {
        $result = Invoke-Command -ComputerName $h -ScriptBlock {
            Restart-Service datadogagent -Force
            Start-Sleep 5
            (Get-Service datadogagent).Status.ToString()
        } -ErrorAction Stop
        Write-Host "OK: $h - service is $result" -ForegroundColor Green
    } catch {
        Write-Host "FAIL: $h - $($_.Exception.Message)" -ForegroundColor Red
    }
}
Write-Host ""
Write-Host "DONE - check Datadog within 5 min for agent metrics resuming" -ForegroundColor Cyan
