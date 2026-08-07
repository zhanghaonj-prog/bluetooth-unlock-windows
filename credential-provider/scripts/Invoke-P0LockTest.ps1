[CmdletBinding()]
param(
    [ValidateRange(1, 30)]
    [int]$TriggerDelaySeconds = 3,
    [ValidateRange(3, 30)]
    [int]$AuthorizationSeconds = 10,
    [switch]$IUnderstandThisCanAffectSignIn
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common-P0.ps1")
Assert-P0Administrator
Assert-P0RiskAcknowledgement -IUnderstandThisCanAffectSignIn:$IUnderstandThisCanAffectSignIn

$config = Get-ItemProperty -LiteralPath $script:P0ConfigKey -ErrorAction Stop
if ([int]$config.Enabled -ne 1 -or $null -eq $config.ProtectedPassword) {
    throw "P0 Provider is not enabled or has no enrolled credential."
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class P0NativeMethods
{
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LockWorkStation();
}
"@

Write-Host "Locking now. Test authorization will fire in $TriggerDelaySeconds seconds."
Write-Host "If automatic unlock fails, use the normal Windows password/PIN tile."
if (-not [P0NativeMethods]::LockWorkStation()) {
    throw "LockWorkStation failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
}

Start-Sleep -Seconds $TriggerDelaySeconds
$authorizedUntil = [DateTime]::UtcNow.AddSeconds($AuthorizationSeconds).ToFileTimeUtc()
New-ItemProperty -Path $script:P0ConfigKey -Name "AuthorizedUntilUtc" -Value $authorizedUntil -PropertyType QWord -Force | Out-Null

$event = $null
$deadline = [DateTime]::UtcNow.AddSeconds(5)
do {
    try {
        $event = [Threading.EventWaitHandle]::OpenExisting($script:P0EventName)
    } catch [Threading.WaitHandleCannotBeOpenedException] {
        Start-Sleep -Milliseconds 200
    } catch [UnauthorizedAccessException] {
        throw "Credential Provider event exists but its ACL denies the elevated test process. Install the latest P0 Provider build and retry."
    }
} while ($null -eq $event -and [DateTime]::UtcNow -lt $deadline)

if ($null -eq $event) {
    throw "Credential Provider event was not found. The Provider may not be loaded by LogonUI."
}
try {
    if (-not $event.Set()) {
        throw "Failed to signal the Credential Provider authorization event."
    }
} finally {
    $event.Dispose()
}
