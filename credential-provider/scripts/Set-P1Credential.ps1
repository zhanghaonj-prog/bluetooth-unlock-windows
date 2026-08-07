[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Username,
    [string]$IdentityName = "",
    [switch]$IUnderstandThisCanAffectSignIn
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common-P1.ps1")
Assert-P1Administrator
Assert-P1RiskAcknowledgement -IUnderstandThisCanAffectSignIn:$IUnderstandThisCanAffectSignIn

if (-not (Test-Path -LiteralPath $script:P1CredentialProviderKey)) {
    throw "P1 is not installed. Run Install-P1Provider.ps1 first."
}
$trustedAgent = Get-P1TrustedAgentStatus
if (-not $trustedAgent.Valid) {
    throw "Trusted Agent path or SHA-256 is missing or does not match. Reinstall or upgrade the automatic-unlock component before enrolling a credential."
}
New-ItemProperty -Path $script:P1ConfigKey -Name "Enabled" -Value 0 -PropertyType DWord -Force | Out-Null

$account = [Security.Principal.NTAccount]::new($env:COMPUTERNAME, $Username)
try {
    $sid = $account.Translate([Security.Principal.SecurityIdentifier]).Value
} catch {
    throw "Local account '$env:COMPUTERNAME\$Username' was not found."
}

$localUser = Get-LocalUser -Name $Username -ErrorAction Stop
$credentialDomain = $env:COMPUTERNAME
$credentialUsername = $Username
$accountSource = [string]$localUser.PrincipalSource
if ($accountSource.Equals("MicrosoftAccount", [StringComparison]::OrdinalIgnoreCase)) {
    if ([string]::IsNullOrWhiteSpace($IdentityName)) {
        $logonCache = "HKLM:\SOFTWARE\Microsoft\IdentityStore\LogonCache"
        $identities = @(
            Get-ChildItem -LiteralPath $logonCache -Recurse -ErrorAction Stop |
                ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue } |
                Where-Object {
                    ([string]$_.AuthenticatingAuthority).Equals("MicrosoftAccount", [StringComparison]::OrdinalIgnoreCase) -and
                    -not [string]::IsNullOrWhiteSpace([string]$_.IdentityName)
                } |
                Select-Object -ExpandProperty IdentityName -Unique
        )
        if ($identities.Count -ne 1) {
            throw "Unable to uniquely determine the Microsoft account identity. Rerun with -IdentityName '<Microsoft account email>'."
        }
        $IdentityName = [string]$identities[0]
    }
    $credentialDomain = "MicrosoftAccount"
    $credentialUsername = $IdentityName
}
elseif (-not [string]::IsNullOrWhiteSpace($IdentityName)) {
    throw "-IdentityName is only valid when the local profile is backed by a Microsoft account."
}

$credentialLabel = "$credentialDomain\$credentialUsername"
if ($accountSource.Equals("MicrosoftAccount", [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "Enroll the Microsoft account password for '$credentialLabel'. Do not enter the Windows PIN."
} else {
    Write-Host "Enroll the Windows password for '$credentialLabel'. Do not enter the Windows PIN."
}
$securePassword = Read-Host "Password for $credentialLabel" -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($securePassword)
$clearBytes = $null
$protected = $null
try {
    $clearPassword = [Runtime.InteropServices.Marshal]::PtrToStringUni($pointer)
    if ([string]::IsNullOrEmpty($clearPassword)) { throw "Empty passwords are not supported." }
    $clearBytes = [Text.Encoding]::Unicode.GetBytes($clearPassword + [char]0)
    Add-Type -AssemblyName System.Security
    $protected = [Security.Cryptography.ProtectedData]::Protect(
        $clearBytes,
        $null,
        [Security.Cryptography.DataProtectionScope]::LocalMachine)

    Set-P1DataAcl
    [IO.File]::WriteAllBytes($script:P1CredentialFile, $protected)
    & icacls.exe $script:P1CredentialFile /inheritance:r `
        /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to secure the credential file." }

    New-ItemProperty -Path $script:P1ConfigKey -Name "UserSid" -Value $sid -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $script:P1ConfigKey -Name "Username" -Value $credentialUsername -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $script:P1ConfigKey -Name "Domain" -Value $credentialDomain -PropertyType String -Force | Out-Null
    Remove-ItemProperty -Path $script:P1ConfigKey -Name "ProtectedPassword" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $script:P1ConfigKey -Name "AuthorizedUntilUtc" -ErrorAction SilentlyContinue
    New-ItemProperty -Path $script:P1ConfigKey -Name "Enabled" -Value 1 -PropertyType DWord -Force | Out-Null
} finally {
    if ($null -ne $protected) { [Array]::Clear($protected, 0, $protected.Length) }
    if ($null -ne $clearBytes) { [Array]::Clear($clearBytes, 0, $clearBytes.Length) }
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer)
    }
    $securePassword.Dispose()
}

Write-Host "P1 credential enrolled for $credentialLabel and bound to local SID $sid."
Write-Host "The DPAPI LocalMachine blob is stored in $script:P1CredentialFile with SYSTEM/Administrators ACL."
