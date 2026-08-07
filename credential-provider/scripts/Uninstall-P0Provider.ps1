[CmdletBinding()]
param(
    [switch]$RemoveEncryptedCredential
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common-P0.ps1")
Assert-P0Administrator

if (Test-Path -LiteralPath $script:P0ConfigKey) {
    New-ItemProperty -Path $script:P0ConfigKey -Name "Enabled" -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $script:P0ConfigKey -Name "AuthorizedUntilUtc" -Value ([long]0) -PropertyType QWord -Force | Out-Null
}

Remove-Item -LiteralPath $script:P0CredentialProviderKey -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $script:P0ComKey -Recurse -Force -ErrorAction SilentlyContinue
if ($RemoveEncryptedCredential) {
    Remove-Item -LiteralPath $script:P0ConfigKey -Recurse -Force -ErrorAction SilentlyContinue
}

$installDirectory = Join-Path $env:ProgramFiles "BleProximityWake\CredentialProviderP0"
try {
    Remove-Item -LiteralPath $installDirectory -Recurse -Force -ErrorAction Stop
} catch {
    Write-Warning "Provider files are still loaded. Registration is removed; reboot and delete '$installDirectory'."
}

Write-Host "P0 Credential Provider registration removed. Restart Windows before reusing the VM snapshot."
