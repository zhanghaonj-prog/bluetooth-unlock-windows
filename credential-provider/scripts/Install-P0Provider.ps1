[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [switch]$IUnderstandThisCanAffectSignIn
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common-P0.ps1")
Assert-P0Administrator
Assert-P0RiskAcknowledgement -IUnderstandThisCanAffectSignIn:$IUnderstandThisCanAffectSignIn

$sourceDll = Join-Path (Split-Path -Parent $PSScriptRoot) "bin\$Configuration\BleProximityCredentialProvider.dll"
if (-not (Test-Path -LiteralPath $sourceDll)) {
    throw "Provider DLL not found. Run Build-P0Provider.ps1 first: $sourceDll"
}

$installDirectory = Join-Path $env:ProgramFiles "BleProximityWake\CredentialProviderP0"
$installedDll = Join-Path $installDirectory "BleProximityCredentialProvider.dll"
New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceDll -Destination $installedDll -Force

Set-P0RegistryDefaultValue -Path $script:P0ComKey -Value "BLE Proximity Credential Provider P0"
$inProcKey = Join-Path $script:P0ComKey "InprocServer32"
Set-P0RegistryDefaultValue -Path $inProcKey -Value $installedDll
New-ItemProperty -Path $inProcKey -Name "ThreadingModel" -Value "Apartment" -PropertyType String -Force | Out-Null

Set-P0RegistryDefaultValue -Path $script:P0CredentialProviderKey -Value "BLE Proximity Credential Provider P0"
New-Item -Path $script:P0ConfigKey -Force | Out-Null
New-ItemProperty -Path $script:P0ConfigKey -Name "Enabled" -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $script:P0ConfigKey -Name "AuthorizedUntilUtc" -Value ([long]0) -PropertyType QWord -Force | Out-Null

Write-Host "P0 Credential Provider registered in disabled state."
Write-Host "Next: run Set-P0Credential.ps1, then confirm normal password/PIN sign-in still works."
