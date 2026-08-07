$ErrorActionPreference = "Stop"

$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "BLE Proximity Wake.lnk"

if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath
    Write-Host "Startup shortcut removed: $shortcutPath"
}
else {
    Write-Host "Startup shortcut not found: $shortcutPath"
}
