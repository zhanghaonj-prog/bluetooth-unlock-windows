[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator privileges are required to remove all user data."
}

$profileList = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$removed = 0
foreach ($profileKey in Get-ChildItem -LiteralPath $profileList) {
    $profile = Get-ItemProperty -LiteralPath $profileKey.PSPath
    if ([string]::IsNullOrWhiteSpace([string]$profile.ProfileImagePath)) {
        continue
    }

    $profilePath = [IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables([string]$profile.ProfileImagePath)
    ).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) {
        continue
    }

    $dataDirectory = [IO.Path]::GetFullPath(
        (Join-Path $profilePath "AppData\Local\BleProximityWake")
    ).TrimEnd('\')
    if (-not $dataDirectory.StartsWith(
        $profilePath + "\",
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove data outside user profile: $dataDirectory"
    }

    if (Test-Path -LiteralPath $dataDirectory -PathType Container) {
        Remove-Item -LiteralPath $dataDirectory -Recurse -Force
        $removed++
    }
}

Write-Host "Removed BLE Proximity Wake data directories for $removed user profile(s)."
