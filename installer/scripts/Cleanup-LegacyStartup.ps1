$ErrorActionPreference = "Stop"

$startupDirectory = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::Startup)
$shortcutPath = Join-Path $startupDirectory "BLE Proximity Wake.lnk"
if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
    exit 0
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$expectedHost = Join-Path $env:SystemRoot "System32\wscript.exe"
$isLegacyShortcut =
    [string]::Equals(
        $shortcut.TargetPath,
        $expectedHost,
        [StringComparison]::OrdinalIgnoreCase) -and
    $shortcut.Arguments.IndexOf(
        "Start-BleProximityWake.vbs",
        [StringComparison]::OrdinalIgnoreCase) -ge 0

if ($isLegacyShortcut) {
    Remove-Item -LiteralPath $shortcutPath -Force
}
