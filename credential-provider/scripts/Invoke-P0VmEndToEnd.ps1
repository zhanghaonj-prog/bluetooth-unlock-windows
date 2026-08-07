[CmdletBinding()]
param(
    [string]$Username = $env:USERNAME,
    [string]$ResultDirectory = "\\vmware-host\Shared Folders\Temp"
)

$ErrorActionPreference = "Stop"
$commonScript = Join-Path $PSScriptRoot "Common-P0.ps1"
. $commonScript

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

Assert-P0Administrator

Write-Host "Installing the P0 Credential Provider in this disposable VM..."
& (Join-Path $PSScriptRoot "Install-P0Provider.ps1") `
    -Configuration Release `
    -IUnderstandThisCanAffectSignIn

Write-Host "Enroll the Windows password for local VM account '$Username'."
Write-Host "The next prompt does not echo or log the password."
& (Join-Path $PSScriptRoot "Set-P0Credential.ps1") `
    -Username $Username `
    -IUnderstandThisCanAffectSignIn

Write-Host "Before continuing, confirm that you know the normal VM password/PIN."
Read-Host "Press ENTER to lock the VM and run the automatic unlock test"

& (Join-Path $PSScriptRoot "Invoke-P0LockTest.ps1") `
    -TriggerDelaySeconds 3 `
    -AuthorizationSeconds 10 `
    -IUnderstandThisCanAffectSignIn

# Let LogonUI finish serialization and ReportResult before copying diagnostics.
Start-Sleep -Seconds 2

$logPath = Join-Path $env:ProgramData "BleProximityWake\credential-provider-p0.log"
if (Test-Path -LiteralPath $logPath) {
    if (-not (Test-Path -LiteralPath $ResultDirectory)) {
        New-Item -ItemType Directory -Path $ResultDirectory -Force | Out-Null
    }
    $destination = Join-Path $ResultDirectory "credential-provider-p0.log"
    Copy-Item -LiteralPath $logPath -Destination $destination -Force
    Write-Host "Diagnostic log copied to $destination"
} else {
    Write-Warning "The Provider diagnostic log was not created: $logPath"
}

Write-Host "P0 VM test finished. Keep this window open until the host has inspected the log."
