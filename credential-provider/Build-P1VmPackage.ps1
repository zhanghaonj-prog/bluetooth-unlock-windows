[CmdletBinding()]
param(
    [string]$DestinationPath
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    $DestinationPath = Join-Path $PSScriptRoot "bin\ble-cp-p1-vm.zip"
}
$releaseDirectory = Join-Path $PSScriptRoot "bin\Release"
$requiredBinaries = @(
    (Join-Path $releaseDirectory "BleProximityCredentialProvider.dll"),
    (Join-Path $releaseDirectory "BleProximityUnlockBroker.exe"))
foreach ($binary in $requiredBinaries) {
    if (-not (Test-Path -LiteralPath $binary)) { throw "Required P1 binary not found: $binary" }
}

$stage = Join-Path $PSScriptRoot ("bin\vm-package-p1-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmssfff"))
New-Item -ItemType Directory -Path (Join-Path $stage "bin\Release") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage "scripts") -Force | Out-Null
foreach ($binary in $requiredBinaries) {
    Copy-Item -LiteralPath $binary -Destination (Join-Path $stage "bin\Release")
}
Copy-Item -Path (Join-Path $PSScriptRoot "scripts\*.ps1") -Destination (Join-Path $stage "scripts")
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "README.md") -Destination (Join-Path $stage "README.md")

$destinationDirectory = Split-Path -Parent $DestinationPath
if (-not (Test-Path -LiteralPath $destinationDirectory)) {
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
}
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $DestinationPath -Force
Write-Host "Built P1 VM package: $DestinationPath"
