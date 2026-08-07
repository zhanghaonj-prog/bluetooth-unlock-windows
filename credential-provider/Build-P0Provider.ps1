[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$project = Join-Path $PSScriptRoot "provider\BleProximityCredentialProvider.vcxproj"
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "Visual Studio Installer (vswhere.exe) was not found."
}

$installationPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if ([string]::IsNullOrWhiteSpace($installationPath)) {
    throw "Visual Studio 2022 C++ x64 build tools are not installed."
}

$msbuild = Join-Path $installationPath "MSBuild\Current\Bin\MSBuild.exe"
if (-not (Test-Path -LiteralPath $msbuild)) {
    throw "MSBuild was not found at $msbuild"
}

& $msbuild $project /t:Rebuild "/p:Configuration=$Configuration" /p:Platform=x64 /m
if ($LASTEXITCODE -ne 0) {
    throw "Credential Provider build failed with exit code $LASTEXITCODE."
}

$dll = Join-Path $PSScriptRoot "bin\$Configuration\BleProximityCredentialProvider.dll"
if (-not (Test-Path -LiteralPath $dll)) {
    throw "Build completed without producing $dll"
}
Write-Host "Built $dll"
