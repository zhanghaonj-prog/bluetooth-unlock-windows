param(
    [ValidateRange(60, 600)]
    [int]$Seconds = 180,
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
    throw "Stop the existing BLE proximity process before the isolated auto-unlock test: $($details -join ', ')"
}

$brokerService = Get-Service -Name "BleProximityUnlockBroker" -ErrorAction SilentlyContinue
if ($null -eq $brokerService -or $brokerService.Status -ne "Running") {
    throw "BleProximityUnlockBroker must be installed and running before this test."
}

$providerClsid = "{A9E31F6A-4C50-45A1-B74C-02EA28E8613D}"
$providerKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$providerClsid"
$configKey = "HKLM:\SOFTWARE\BleProximityWake\CredentialProviderP0"
if (-not (Test-Path -LiteralPath $providerKey) -or -not (Test-Path -LiteralPath $configKey)) {
    throw "The registered P1 Credential Provider configuration was not found."
}

$providerConfig = Get-ItemProperty -LiteralPath $configKey
if ([int]$providerConfig.Enabled -ne 1) {
    throw "The P1 Credential Provider is installed but disabled."
}
if ([string]::IsNullOrWhiteSpace([string]$providerConfig.UserSid)) {
    throw "No enrolled Windows account was found in the P1 configuration."
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$dataDirectory = Join-Path $env:LOCALAPPDATA "BleProximityWake\diagnostics\auto-unlock-arrival-$timestamp"
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
    $settings.actions.wake.enabled = $false
    $settings.actions.wake.rearmSeconds = $RearmSeconds
    $settings.actions.autoLock.enabled = $false
    $settings.autoUnlock.enabled = $true
    $settings.autoUnlock.triggerOnArrival = $true
    $settings.autoUnlock.triggerOnInteractiveWake = $false
    $settings.autoUnlock.requireAllowedNetwork = $true
    $settings.autoUnlock.requireAcPower = $true
    $settings |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $settingsPath -Encoding UTF8

    Write-Host "Isolated auto-unlock test directory: $dataDirectory"
    Write-Host "Automatic unlock: enabled for this isolated run only."
    Write-Host "Wake action: disabled; auto-lock: disabled."
    Write-Host "Presence mode: $($settings.presencePolicies.autoUnlock.mode)"
    Write-Host "Current profiles: $($currentProfiles -join ' | ')"
    Write-Host "Current SSIDs: $($currentSsids -join ' | ')"
    Write-Host ""
    Write-Host "This test uses the already enrolled Broker credential."
    Write-Host "It does not read, register, or modify the Windows password."
    Write-Host ""
    Write-Host "1. Keep the required watch/phone away from the computer."
    Write-Host "2. Keep the computer connected to external power."
    Write-Host "3. Press Win+L."
    Write-Host "4. Wait at least $($RearmSeconds + 2) seconds."
    Write-Host "5. Bring the required device(s) near the computer."
    Write-Host "6. Windows should show the login UI and enter the desktop automatically."
    Write-Host "7. If it fails, sign in normally. Do not repeat the test before collecting logs."
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
        throw "Auto-unlock test did not produce an Agent log."
    }

    foreach ($source in @(
        (Join-Path $env:ProgramData "BleProximityWake\unlock-broker.log"),
        (Join-Path $env:ProgramData "BleProximityWake\credential-provider-p0.log")
    )) {
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $dataDirectory -Force -ErrorAction SilentlyContinue
        }
    }

    Get-Content -LiteralPath $log.FullName
    Write-Host "Auto-unlock test retained: $dataDirectory"
    if ($process.ExitCode -ne 0) {
        throw "Auto-unlock test failed with exit code $($process.ExitCode)."
    }
}
finally {
    $env:BLE_PROXIMITY_WAKE_DATA_DIR = $previousDataDirectory
}
