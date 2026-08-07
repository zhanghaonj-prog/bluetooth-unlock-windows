[CmdletBinding()]
param(
    [ValidateRange(1, 30)]
    [int]$TriggerDelaySeconds = 3,
    [switch]$IUnderstandThisCanAffectSignIn
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common-P1.ps1")
Assert-P1Administrator
Assert-P1RiskAcknowledgement -IUnderstandThisCanAffectSignIn:$IUnderstandThisCanAffectSignIn

$config = Get-ItemProperty -LiteralPath $script:P1ConfigKey -ErrorAction Stop
if ([int]$config.Enabled -ne 1 -or -not (Test-Path -LiteralPath $script:P1CredentialFile)) {
    throw "P1 is disabled or has no enrolled credential."
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class P1NativeMethods
{
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LockWorkStation();
}
"@

$lockCycleId = [UInt64]([DateTime]::UtcNow.Ticks)
Write-Host "Locking now. Broker authorization will fire in $TriggerDelaySeconds seconds."
Write-Host "If automatic unlock fails, use the normal Windows password/PIN tile."
if (-not [P1NativeMethods]::LockWorkStation()) {
    throw "LockWorkStation failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
}
Start-Sleep -Seconds $TriggerDelaySeconds
& (Join-Path $PSScriptRoot "Send-P1Authorization.ps1") `
    -AuthorizationSeconds 5 `
    -LockCycleId $lockCycleId
