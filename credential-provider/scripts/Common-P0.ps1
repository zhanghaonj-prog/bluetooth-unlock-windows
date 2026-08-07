$script:P0Clsid = "{A9E31F6A-4C50-45A1-B74C-02EA28E8613D}"
$script:P0ConfigKey = "HKLM:\SOFTWARE\BleProximityWake\CredentialProviderP0"
$script:P0CredentialProviderKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$script:P0Clsid"
$script:P0ComKey = "HKLM:\SOFTWARE\Classes\CLSID\$script:P0Clsid"
$script:P0EventName = "Global\BleProximityCredentialProvider.P0.Authorization"

function Assert-P0Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated 64-bit Windows PowerShell window."
    }
    if (-not [Environment]::Is64BitProcess) {
        throw "Use 64-bit Windows PowerShell. The Provider is x64 only."
    }
}

function Assert-P0RiskAcknowledgement {
    param([switch]$IUnderstandThisCanAffectSignIn)

    if (-not $IUnderstandThisCanAffectSignIn) {
        throw "This P0 build can affect Windows sign-in. Use only in a disposable VM with a snapshot, then rerun with -IUnderstandThisCanAffectSignIn."
    }
}

function Set-P0RegistryDefaultValue {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-Item -LiteralPath $Path -Value $Value
}
