[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$framework = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319"
$compiler = Join-Path $framework "csc.exe"
if (-not (Test-Path -LiteralPath $compiler)) {
    throw "64-bit .NET Framework C# compiler was not found: $compiler"
}

$outputDirectory = Join-Path $PSScriptRoot "bin\$Configuration"
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$output = Join-Path $outputDirectory "BleProximityUnlockBroker.exe"
$optimize = if ($Configuration -eq "Release") { "/optimize+" } else { "/optimize-" }

& $compiler /nologo /target:exe /platform:x64 $optimize /warnaserror+ `
    "/out:$output" `
    /reference:System.ServiceProcess.dll `
    /reference:System.Security.dll `
    (Join-Path $PSScriptRoot "broker\BrokerService.cs")
if ($LASTEXITCODE -ne 0) {
    throw "Broker build failed with exit code $LASTEXITCODE."
}
Write-Host "Built $output"
