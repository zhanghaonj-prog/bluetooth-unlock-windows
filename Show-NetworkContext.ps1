$ErrorActionPreference = "Stop"

Write-Host "NetConnectionProfile:"
try {
    Get-NetConnectionProfile |
        Select-Object Name, InterfaceAlias, NetworkCategory, IPv4Connectivity, IPv6Connectivity, DnsSuffix |
        Format-Table -AutoSize
}
catch {
    Write-Warning "Get-NetConnectionProfile failed: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "Wi-Fi interfaces:"
try {
    netsh.exe wlan show interfaces
}
catch {
    Write-Warning "netsh wlan show interfaces failed: $($_.Exception.Message)"
}
