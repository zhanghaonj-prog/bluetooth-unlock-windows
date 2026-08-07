param(
    [string]$LegacyConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "config.json"),
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$executable = Join-Path $PSScriptRoot "bin\$Configuration\BleProximityWake.Agent.exe"
if (-not (Test-Path -LiteralPath $executable)) {
    & (Join-Path $PSScriptRoot "Build-Agent.ps1") -Configuration $Configuration
}

$resolvedConfig = (Resolve-Path -LiteralPath $LegacyConfigPath).Path
$process = Start-Process -FilePath $executable -ArgumentList @(
    "--import-legacy-config",
    "`"$resolvedConfig`"",
    "--import-only"
) -Wait -PassThru
if ($process.ExitCode -ne 0) {
    throw "Legacy configuration import failed with exit code $($process.ExitCode)."
}

$settingsPath = Join-Path $env:LOCALAPPDATA "BleProximityWake\agent-settings.json"
Write-Host "Legacy configuration imported: $settingsPath"
