[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$StageDirectory,
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$requiredFiles = @(
    "Agent\BleProximityWake.Agent.exe",
    "Agent\BleProximityWake.Core.dll",
    "Defaults\agent-settings.sample.json",
    "CredentialProvider\bin\$Configuration\BleProximityCredentialProvider.dll",
    "CredentialProvider\bin\$Configuration\BleProximityUnlockBroker.exe",
    "CredentialProvider\scripts\Common-P1.ps1",
    "CredentialProvider\scripts\Install-P1Provider.ps1",
    "CredentialProvider\scripts\Set-P1Credential.ps1",
    "CredentialProvider\scripts\Uninstall-P1Provider.ps1",
    "Tools\Enroll-AutoUnlock.ps1",
    "Tools\Disable-AutoUnlock.ps1",
    "Tools\Remove-AllUserData.ps1",
    "Tools\Open-Logs.ps1",
    "Tools\Cleanup-LegacyStartup.ps1",
    "Documentation\INSTALLER_README.md",
    "Documentation\AGENT_README.md",
    "release-manifest.json"
)

foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $StageDirectory $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Installer layout is missing: $relativePath"
    }
}

$forbidden = @(
    Get-ChildItem -LiteralPath $StageDirectory -File -Recurse |
        Where-Object {
            $_.Extension -in @(".pdb", ".exp", ".lib") -or
            $_.Name -in @("config.json", "credential.dat") -or
            $_.FullName -match "[\\/]logs?[\\/]"
        }
)
if ($forbidden.Count -gt 0) {
    throw "Installer layout contains forbidden files: $($forbidden.FullName -join ', ')"
}

$settingsPath = Join-Path $StageDirectory "Defaults\agent-settings.sample.json"
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
if ($settings.actions.wake.enabled -or
    $settings.actions.autoLock.enabled -or
    $settings.autoUnlock.enabled) {
    throw "Release defaults must keep wake, auto-lock, and auto-unlock disabled."
}

$installScript = Get-Content -LiteralPath (
    Join-Path $StageDirectory "CredentialProvider\scripts\Install-P1Provider.ps1") -Raw
if ($installScript -notmatch "PreserveEnrollment") {
    throw "Installer Provider script does not support enrollment-preserving upgrades."
}

$uninstallScript = Get-Content -LiteralPath (
    Join-Path $StageDirectory "CredentialProvider\scripts\Uninstall-P1Provider.ps1") -Raw
if ($uninstallScript -notmatch "RemoveEncryptedCredential" -or
    $uninstallScript -notmatch "RemoveDataDirectory") {
    throw "Installer Provider script does not support complete sensitive-data cleanup."
}

$manifest = Get-Content -LiteralPath (
    Join-Path $StageDirectory "release-manifest.json") -Raw | ConvertFrom-Json
if ($manifest.architecture -ne "x64" -or $manifest.files.Count -lt 10) {
    throw "Release manifest is incomplete."
}
foreach ($file in $manifest.files) {
    $path = Join-Path $StageDirectory ([string]$file.path).Replace("/", "\")
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if (-not $actualHash.Equals([string]$file.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release manifest hash mismatch: $($file.path)"
    }
}

Write-Host "Installer layout validation passed. Files=$($manifest.files.Count)"
