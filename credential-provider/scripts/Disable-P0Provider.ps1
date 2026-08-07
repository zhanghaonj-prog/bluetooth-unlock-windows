[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common-P0.ps1")
Assert-P0Administrator

if (Test-Path -LiteralPath $script:P0ConfigKey) {
    New-ItemProperty -Path $script:P0ConfigKey -Name "Enabled" -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $script:P0ConfigKey -Name "AuthorizedUntilUtc" -Value ([long]0) -PropertyType QWord -Force | Out-Null
}
Write-Host "P0 automatic unlock disabled. Provider registration is retained for troubleshooting."
