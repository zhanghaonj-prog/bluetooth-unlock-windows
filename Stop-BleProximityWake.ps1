$ErrorActionPreference = "Stop"

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$pidFile = Join-Path $scriptRoot "ble-proximity-wake.pid"

if (-not (Test-Path -LiteralPath $pidFile)) {
    Write-Host "PID file not found. BLE Proximity Wake may not be running from this directory."
    return
}

$pidText = (Get-Content -LiteralPath $pidFile -Encoding UTF8 -Raw).Trim()
$metadata = $null
if ($pidText -match '^\d+$') {
    $metadata = [pscustomobject]@{
        version = 1
        pid = [int]$pidText
        startedUtc = ""
        scriptPath = (Join-Path $scriptRoot "Start-BleProximityWake.ps1")
    }
}
else {
    try {
        $metadata = $pidText | ConvertFrom-Json
    }
    catch {
        throw "Invalid PID file content: $($_.Exception.Message)"
    }
}

$targetPid = [int]$metadata.pid
if ($targetPid -le 0) {
    throw "Invalid PID in PID file: $targetPid"
}
$process = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
if ($null -eq $process) {
    Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
    Write-Host "Process $targetPid is not running. Removed stale PID file."
    return
}

$expectedScriptPath = [string]$metadata.scriptPath
if ([string]::IsNullOrWhiteSpace($expectedScriptPath)) {
    $expectedScriptPath = Join-Path $scriptRoot "Start-BleProximityWake.ps1"
}
$expectedScriptPath = [IO.Path]::GetFullPath($expectedScriptPath)

if (-not ([string]$process.ProcessName).Equals("powershell", [StringComparison]::OrdinalIgnoreCase) -and
    -not ([string]$process.ProcessName).Equals("pwsh", [StringComparison]::OrdinalIgnoreCase)) {
    throw "PID $targetPid belongs to '$($process.ProcessName)', not BLE Proximity Wake. Refusing to stop it."
}

if (-not [string]::IsNullOrWhiteSpace([string]$metadata.startedUtc)) {
    $expectedStartedUtc = [DateTime]::Parse([string]$metadata.startedUtc).ToUniversalTime()
    $actualStartedUtc = $process.StartTime.ToUniversalTime()
    if ([Math]::Abs(($actualStartedUtc - $expectedStartedUtc).TotalSeconds) -gt 5) {
        throw "PID $targetPid start time does not match the PID file. Refusing to stop a reused PID."
    }
}

$commandLine = ""
try {
    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $targetPid" -ErrorAction Stop
    $commandLine = [string]$processInfo.CommandLine
}
catch {
    throw "Unable to verify PID $targetPid command line. Run this stop script with the same privileges as the tray process."
}
if ([string]::IsNullOrWhiteSpace($commandLine) -or $commandLine.IndexOf($expectedScriptPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw "PID $targetPid command line does not contain '$expectedScriptPath'. Refusing to stop it."
}

Write-Host "Stopping BLE Proximity Wake process: $targetPid"
try {
    Stop-Process -Id $targetPid -ErrorAction Stop
    Wait-Process -Id $targetPid -Timeout 5 -ErrorAction SilentlyContinue
    if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
        throw "Process $targetPid did not exit after Stop-Process."
    }
    Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
    Write-Host "Stopped process $targetPid."
}
catch {
    Write-Warning "Stop-Process failed: $($_.Exception.Message)"
    Write-Host "Trying taskkill /F..."
    & taskkill.exe /PID $targetPid /T /F
    if ($LASTEXITCODE -eq 0) {
        Wait-Process -Id $targetPid -Timeout 5 -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
        Write-Host "Stopped process $targetPid."
    }
    else {
        Write-Warning "Unable to stop process $targetPid automatically."
        Write-Host "Open Task Manager as administrator, go to Details, and end powershell.exe PID $targetPid."
        Write-Host "Do not remove $pidFile until the process is stopped."
        exit 1
    }
}
