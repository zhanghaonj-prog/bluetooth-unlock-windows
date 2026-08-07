param(
    [ValidateRange(45, 300)]
    [int]$Seconds = 120,
    [ValidateRange(5, 60)]
    [int]$RearmSeconds = 10,
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

$conflictingProcesses = @(
    Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object {
            $_.ProcessId -ne $PID -and (
                $_.Name -ieq "BleProximityWake.Agent.exe" -or
                $_.CommandLine -match "Start-BleProximityWake\.ps1"
            )
        }
)
if ($conflictingProcesses.Count -gt 0) {
    $details = $conflictingProcesses |
        ForEach-Object { "$($_.Name) PID=$($_.ProcessId)" }
    throw "Stop the existing BLE proximity process before the isolated wake test: $($details -join ', ')"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$dataDirectory = Join-Path $env:LOCALAPPDATA "BleProximityWake\diagnostics\wake-action-$timestamp"
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
    $settings.network.allowedProfileNames = $currentProfiles
    $settings.network.allowedSsids = $currentSsids
    $settings.actions.wake.enabled = $true
    $settings.actions.wake.rearmSeconds = $RearmSeconds
    $settings.actions.autoLock.enabled = $false
    $settings |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $settingsPath -Encoding UTF8

    Write-Host "Isolated wake test directory: $dataDirectory"
    Write-Host "Wake action: enabled; auto-lock: disabled; auto-unlock: not connected."
    Write-Host "Current profiles: $($currentProfiles -join ' | ')"
    Write-Host "Current SSIDs: $($currentSsids -join ' | ')"
    Write-Host ""
    Write-Host "1. Keep the watch/phone away from the computer."
    Write-Host "2. Press Win+L."
    Write-Host "3. Wait at least $($RearmSeconds + 2) seconds."
    Write-Host "4. Bring the configured device(s) near the computer."
    Write-Host "5. Confirm that the login page appears, then sign in manually."
    if (-not $SkipPrompt) {
        [void](Read-Host "Press ENTER to start the $Seconds-second isolated test")
    }

    $process = Start-Process -FilePath $executable -ArgumentList @(
        "--observe-seconds",
        $Seconds
    ) -Wait -PassThru
    $log = Get-ChildItem -LiteralPath (Join-Path $dataDirectory "logs") -Filter *.log |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $log) {
        throw "Wake action test did not produce a log."
    }

    Get-Content -LiteralPath $log.FullName
    Write-Host "Wake action test retained: $dataDirectory"
    if ($process.ExitCode -ne 0) {
        throw "Wake action test failed with exit code $($process.ExitCode)."
    }
}
finally {
    $env:BLE_PROXIMITY_WAKE_DATA_DIR = $previousDataDirectory
}
