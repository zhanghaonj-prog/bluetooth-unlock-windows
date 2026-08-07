[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Start-Process -FilePath "powershell.exe" -ArgumentList (
        '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath) -Verb RunAs
    return
}

$disableProvider = Join-Path (Split-Path -Parent $PSScriptRoot) `
    "CredentialProvider\scripts\Disable-P1Provider.ps1"
if (-not (Test-Path -LiteralPath $disableProvider -PathType Leaf)) {
    throw "Automatic unlock component is not installed."
}

& $disableProvider
Write-Host "Automatic unlock is disabled. Normal Windows sign-in providers remain registered."
Read-Host "Press ENTER to close"
