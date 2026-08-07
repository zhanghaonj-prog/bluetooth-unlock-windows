[CmdletBinding()]
param(
    [string]$Username = $env:USERNAME,
    [string]$IdentityName = ""
)

$ErrorActionPreference = "Stop"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $PSCommandPath),
        "-Username", ('"{0}"' -f $Username)
    )
    if (-not [string]::IsNullOrWhiteSpace($IdentityName)) {
        $arguments += @("-IdentityName", ('"{0}"' -f $IdentityName))
    }
    Start-Process -FilePath "powershell.exe" -ArgumentList ($arguments -join " ") -Verb RunAs
    return
}

$setCredential = Join-Path (Split-Path -Parent $PSScriptRoot) `
    "CredentialProvider\scripts\Set-P1Credential.ps1"
if (-not (Test-Path -LiteralPath $setCredential -PathType Leaf)) {
    throw "Automatic unlock component is not installed."
}

Write-Host ""
Write-Host "BLE Proximity Wake automatic unlock enrollment" -ForegroundColor Cyan
Write-Host "This stores a reversible DPAPI LocalMachine-encrypted Windows password."
Write-Host "Enter the real local/Microsoft account password, not the Windows PIN."
Write-Host "Normal password/PIN/Windows Hello sign-in must remain available."
Write-Host ""
$answer = Read-Host "Type YES to continue"
if ($answer -cne "YES") {
    Write-Host "Enrollment cancelled."
    return
}

$parameters = @{
    Username = $Username
    IUnderstandThisCanAffectSignIn = $true
}
if (-not [string]::IsNullOrWhiteSpace($IdentityName)) {
    $parameters.IdentityName = $IdentityName
}
& $setCredential @parameters

Write-Host ""
Write-Host "Enrollment completed. Lock Windows and verify normal password/PIN sign-in first."
Write-Host "The Agent autoUnlock.enabled setting remains a separate user-controlled switch."
Read-Host "Press ENTER to close"
