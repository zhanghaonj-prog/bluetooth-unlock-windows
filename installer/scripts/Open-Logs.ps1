$ErrorActionPreference = "Stop"
$logDirectory = Join-Path $env:LOCALAPPDATA "BleProximityWake\logs"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Start-Process -FilePath "explorer.exe" -ArgumentList ('"{0}"' -f $logDirectory)
