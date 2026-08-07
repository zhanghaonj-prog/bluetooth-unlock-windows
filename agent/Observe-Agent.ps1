param(
    [ValidateRange(1, 3600)]
    [int]$Seconds = 15,
    [string]$LegacyConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "config.json"),
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [switch]$KeepData
)

$ErrorActionPreference = "Stop"
$executable = Join-Path $PSScriptRoot "bin\$Configuration\BleProximityWake.Agent.exe"
if (-not (Test-Path -LiteralPath $executable)) {
    & (Join-Path $PSScriptRoot "Build-Agent.ps1") -Configuration $Configuration
}

$dataDirectory = Join-Path $env:TEMP ("BleProximityWake.Agent.Observe." + [Guid]::NewGuid().ToString("N"))
$previousDataDirectory = $env:BLE_PROXIMITY_WAKE_DATA_DIR
try {
    $env:BLE_PROXIMITY_WAKE_DATA_DIR = $dataDirectory
    $resolvedConfig = (Resolve-Path -LiteralPath $LegacyConfigPath).Path
    $process = Start-Process -FilePath $executable -ArgumentList @(
        "--import-legacy-config",
        "`"$resolvedConfig`"",
        "--observe-seconds",
        $Seconds
    ) -Wait -PassThru

    $log = Get-ChildItem -LiteralPath (Join-Path $dataDirectory "logs") -Filter *.log |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $log) {
        throw "EXE Agent observation did not produce a log."
    }

    Get-Content -LiteralPath $log.FullName
    if ($process.ExitCode -ne 0) {
        $KeepData = $true
        Write-Host "Failed observation data retained: $dataDirectory"
        throw "EXE Agent observation failed with exit code $($process.ExitCode)."
    }
    if ($KeepData) {
        Write-Host "Observation data retained: $dataDirectory"
    }
}
finally {
    $env:BLE_PROXIMITY_WAKE_DATA_DIR = $previousDataDirectory
    if (-not $KeepData) {
        Remove-Item -LiteralPath $dataDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
