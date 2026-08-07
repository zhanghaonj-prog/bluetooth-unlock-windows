param(
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$launcher = Join-Path $scriptRoot "Start-BleProximityWake.vbs"
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Silent launcher not found: $launcher"
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptRoot "config.json"
}

$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "BLE Proximity Wake.lnk"
$wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
$arguments = "`"$launcher`" `"$ConfigPath`""

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $wscript
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $scriptRoot
$shortcut.WindowStyle = 1
$shortcut.Description = "BLE proximity wake to Windows login screen"
$shortcut.Save()

Write-Host "Startup shortcut created: $shortcutPath"
