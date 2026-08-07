param(
    [ValidateRange(15, 600)]
    [int]$Seconds = 75,
    [string]$LegacyConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "config.json"),
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [switch]$SkipPrompt
)

$ErrorActionPreference = "Stop"
$executable = Join-Path $PSScriptRoot "bin\$Configuration\BleProximityWake.Agent.exe"
if (-not (Test-Path -LiteralPath $executable)) {
    & (Join-Path $PSScriptRoot "Build-Agent.ps1") -Configuration $Configuration
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$dataDirectory = Join-Path $env:LOCALAPPDATA "BleProximityWake\diagnostics\lock-observe-$timestamp"
$previousDataDirectory = $env:BLE_PROXIMITY_WAKE_DATA_DIR
try {
    $env:BLE_PROXIMITY_WAKE_DATA_DIR = $dataDirectory
    $resolvedConfig = (Resolve-Path -LiteralPath $LegacyConfigPath).Path
    $import = Start-Process -FilePath $executable -ArgumentList @(
        "--import-legacy-config",
        "`"$resolvedConfig`"",
        "--import-only"
    ) -Wait -PassThru
    if ($import.ExitCode -ne 0) {
        throw "Isolated configuration import failed with exit code $($import.ExitCode)."
    }

    $settingsPath = Join-Path $dataDirectory "agent-settings.json"
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $networkInformation = [Windows.Networking.Connectivity.NetworkInformation, Windows, ContentType = WindowsRuntime]
    $connectedProfiles = @(
        $networkInformation::GetConnectionProfiles() |
            Where-Object { $_.GetNetworkConnectivityLevel().ToString() -ne "None" }
    )
    $currentProfiles = @(
        $connectedProfiles |
            ForEach-Object { [string]$_.ProfileName } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    $currentSsids = @(
        $connectedProfiles |
            Where-Object { $_.IsWlanConnectionProfile } |
            ForEach-Object { [string]$_.WlanConnectionProfileDetails.GetConnectedSsid() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    if ($currentProfiles.Count -eq 0) {
        throw "No connected network profile was found for the isolated whitelist."
    }

    $settings.network.enabled = $true
    $settings.network.allowedProfileNames = @(
        @($settings.network.allowedProfileNames) + $currentProfiles |
            Select-Object -Unique
    )
    $settings.network.allowedSsids = @(
        @($settings.network.allowedSsids) + $currentSsids |
            Select-Object -Unique
    )
    $settings |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $settingsPath -Encoding UTF8

    Write-Host "Isolated profile whitelist: $($currentProfiles -join ' | ')"
    Write-Host "Isolated SSID whitelist: $($currentSsids -join ' | ')"
    Write-Host "Test steps: start observation, press Win+L, wait 10 seconds, then unlock manually."
    Write-Host "No wake, lock, or automatic-unlock action will be executed by the EXE."
    if (-not $SkipPrompt) {
        [void](Read-Host "Press ENTER when ready")
    }

    $process = Start-Process -FilePath $executable -ArgumentList @(
        "--observe-seconds",
        $Seconds
    ) -Wait -PassThru
    $log = Get-ChildItem -LiteralPath (Join-Path $dataDirectory "logs") -Filter *.log |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $log) {
        throw "Lock-cycle observation did not produce a log."
    }

    Get-Content -LiteralPath $log.FullName
    Write-Host "Lock-cycle observation retained: $dataDirectory"
    if ($process.ExitCode -ne 0) {
        throw "Lock-cycle observation failed with exit code $($process.ExitCode)."
    }
}
finally {
    $env:BLE_PROXIMITY_WAKE_DATA_DIR = $previousDataDirectory
}
