[CmdletBinding()]
param(
    [string]$Username = $env:USERNAME,
    [string]$ResultDirectory = "\\vmware-host\Shared Folders\Temp"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common-P1.ps1")

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $PSCommandPath),
        "-Username", ('"{0}"' -f $Username),
        "-ResultDirectory", ('"{0}"' -f $ResultDirectory)
    )
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    return
}

Assert-P1Administrator
Write-Host "Installing the P1 Credential Provider and LocalSystem Broker in this disposable VM..."
& (Join-Path $PSScriptRoot "Install-P1Provider.ps1") `
    -Configuration Release `
    -AgentExecutablePath (Join-Path $PSHOME "powershell.exe") `
    -IUnderstandThisCanAffectSignIn

Write-Host "Enroll the Windows password for local VM account '$Username'."
Write-Host "The next prompt does not echo or log the password."
& (Join-Path $PSScriptRoot "Set-P1Credential.ps1") `
    -Username $Username `
    -IUnderstandThisCanAffectSignIn

Write-Host "Before continuing, confirm that you know the normal VM password/PIN."
Read-Host "Press ENTER to lock the VM and run the Broker automatic unlock test"

& (Join-Path $PSScriptRoot "Invoke-P1LockTest.ps1") `
    -TriggerDelaySeconds 3 `
    -IUnderstandThisCanAffectSignIn

Start-Sleep -Seconds 2
if (-not (Test-Path -LiteralPath $ResultDirectory)) {
    New-Item -ItemType Directory -Path $ResultDirectory -Force | Out-Null
}
foreach ($log in @(
    (Join-Path $env:ProgramData "BleProximityWake\credential-provider-p0.log"),
    (Join-Path $env:ProgramData "BleProximityWake\unlock-broker.log"))) {
    if (Test-Path -LiteralPath $log) {
        Copy-Item -LiteralPath $log -Destination (Join-Path $ResultDirectory (Split-Path $log -Leaf)) -Force
        Write-Host "Diagnostic log copied: $log"
    } else {
        Write-Warning "Diagnostic log was not created: $log"
    }
}
Write-Host "P1 VM test finished. Keep this window open until the host has inspected both logs."
