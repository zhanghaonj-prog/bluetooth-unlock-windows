[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Username,
    [switch]$IUnderstandThisCanAffectSignIn
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common-P0.ps1")
Assert-P0Administrator
Assert-P0RiskAcknowledgement -IUnderstandThisCanAffectSignIn:$IUnderstandThisCanAffectSignIn

if (-not (Test-Path -LiteralPath $script:P0CredentialProviderKey)) {
    throw "P0 Credential Provider is not registered. Run Install-P0Provider.ps1 first."
}

$account = [Security.Principal.NTAccount]::new($env:COMPUTERNAME, $Username)
try {
    $sid = $account.Translate([Security.Principal.SecurityIdentifier]).Value
} catch {
    throw "Local account '$env:COMPUTERNAME\$Username' was not found."
}

$securePassword = Read-Host "Windows password for $env:COMPUTERNAME\$Username" -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($securePassword)
$clearBytes = $null
try {
    $clearPassword = [Runtime.InteropServices.Marshal]::PtrToStringUni($pointer)
    if ([string]::IsNullOrEmpty($clearPassword)) {
        throw "Empty passwords are not supported."
    }
    $clearBytes = [Text.Encoding]::Unicode.GetBytes($clearPassword + [char]0)
    Add-Type -AssemblyName System.Security
    $protected = [Security.Cryptography.ProtectedData]::Protect(
        $clearBytes,
        $null,
        [Security.Cryptography.DataProtectionScope]::LocalMachine)

    New-Item -Path $script:P0ConfigKey -Force | Out-Null
    New-ItemProperty -Path $script:P0ConfigKey -Name "UserSid" -Value $sid -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $script:P0ConfigKey -Name "Username" -Value $Username -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $script:P0ConfigKey -Name "Domain" -Value $env:COMPUTERNAME -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $script:P0ConfigKey -Name "ProtectedPassword" -Value $protected -PropertyType Binary -Force | Out-Null
    New-ItemProperty -Path $script:P0ConfigKey -Name "AuthorizedUntilUtc" -Value ([long]0) -PropertyType QWord -Force | Out-Null
    New-ItemProperty -Path $script:P0ConfigKey -Name "Enabled" -Value 1 -PropertyType DWord -Force | Out-Null
} finally {
    if ($null -ne $clearBytes) {
        [Array]::Clear($clearBytes, 0, $clearBytes.Length)
    }
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer)
    }
    $securePassword.Dispose()
}

Write-Host "P0 credential enrolled for $env:COMPUTERNAME\$Username ($sid)."
Write-Host "The password was DPAPI LocalMachine encrypted and was not written to project files or logs."
