$script:P1Clsid = "{A9E31F6A-4C50-45A1-B74C-02EA28E8613D}"
$script:P1ServiceName = "BleProximityUnlockBroker"
$script:P1ConfigKey = "HKLM:\SOFTWARE\BleProximityWake\CredentialProviderP0"
$script:P1CredentialProviderKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$script:P1Clsid"
$script:P1ComKey = "HKLM:\SOFTWARE\Classes\CLSID\$script:P1Clsid"
$script:P1DataDirectory = Join-Path $env:ProgramData "BleProximityWake"
$script:P1CredentialFile = Join-Path $script:P1DataDirectory "credential.dat"
$script:P1InstallDirectory = Join-Path $env:ProgramFiles "BleProximityWake\CredentialProviderP1"
$script:P1AgentPipeName = "BleProximityWake.UnlockAgent"

function Assert-P1Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated 64-bit Windows PowerShell window."
    }
    if (-not [Environment]::Is64BitProcess) {
        throw "Use 64-bit Windows PowerShell. P1 is x64 only."
    }
}

function Assert-P1RiskAcknowledgement {
    param([switch]$IUnderstandThisCanAffectSignIn)
    if (-not $IUnderstandThisCanAffectSignIn) {
        throw "P1 can affect Windows sign-in. Use only in a disposable VM, then rerun with -IUnderstandThisCanAffectSignIn."
    }
}

function Set-P1RegistryDefaultValue {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Value
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-Item -LiteralPath $Path -Value $Value
}

function Set-P1DataAcl {
    if (-not (Test-Path -LiteralPath $script:P1DataDirectory)) {
        New-Item -ItemType Directory -Path $script:P1DataDirectory -Force | Out-Null
    }
    & icacls.exe $script:P1DataDirectory /inheritance:r `
        /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to secure $script:P1DataDirectory"
    }
}

function Get-P1TrustedAgentStatus {
    $path = ""
    $expectedHash = ""
    if (Test-Path -LiteralPath $script:P1ConfigKey) {
        $config = Get-ItemProperty -LiteralPath $script:P1ConfigKey
        $path = [string]$config.TrustedAgentPath
        $expectedHash = [string]$config.TrustedAgentSha256
    }

    $exists =
        -not [string]::IsNullOrWhiteSpace($path) -and
        (Test-Path -LiteralPath $path -PathType Leaf)
    $actualHash = if ($exists) {
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    } else {
        ""
    }
    $valid =
        $exists -and
        -not [string]::IsNullOrWhiteSpace($expectedHash) -and
        $actualHash.Equals($expectedHash, [StringComparison]::OrdinalIgnoreCase)

    return [pscustomobject]@{
        Path = $path
        ExpectedHash = $expectedHash
        ActualHash = $actualHash
        Exists = $exists
        Valid = $valid
    }
}
