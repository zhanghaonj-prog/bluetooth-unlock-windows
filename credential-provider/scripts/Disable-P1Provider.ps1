[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common-P1.ps1")
Assert-P1Administrator

if (Test-Path -LiteralPath $script:P1ConfigKey) {
    New-ItemProperty -Path $script:P1ConfigKey -Name "Enabled" -Value 0 -PropertyType DWord -Force | Out-Null
}
Stop-Service -Name $script:P1ServiceName -Force -ErrorAction SilentlyContinue
Write-Host "P1 automatic unlock disabled and Broker stopped. Provider registration is retained."
