param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "Visual Studio Installer vswhere.exe was not found."
}

$installationPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
if ([string]::IsNullOrWhiteSpace($installationPath)) {
    throw "Visual Studio with MSBuild was not found."
}

$msbuild = Join-Path $installationPath "MSBuild\Current\Bin\MSBuild.exe"
$project = Join-Path $PSScriptRoot "src\BleProximityWake.Agent\BleProximityWake.Agent.csproj"
$referencePack = "${env:ProgramFiles(x86)}\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8"
if (Test-Path -LiteralPath $referencePack) {
    & $msbuild $project /t:Rebuild "/p:Configuration=$Configuration" /p:Platform=x64 /m
    if ($LASTEXITCODE -ne 0) {
        throw "EXE Agent MSBuild failed with exit code $LASTEXITCODE."
    }
}
else {
    $compiler = Join-Path $installationPath "MSBuild\Current\Bin\Roslyn\csc.exe"
    if (-not (Test-Path -LiteralPath $compiler)) {
        throw ".NET Framework 4.8 Developer Pack and the Visual Studio Roslyn compiler are both unavailable."
    }

    $framework = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319"
    $outputDirectory = Join-Path $PSScriptRoot "bin\$Configuration"
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $optimize = if ($Configuration -eq "Release") { "/optimize+" } else { "/optimize-" }

    $coreOutput = Join-Path $outputDirectory "BleProximityWake.Core.dll"
    $coreSources = @(Get-ChildItem (Join-Path $PSScriptRoot "src\BleProximityWake.Core") -Filter *.cs -Recurse | ForEach-Object FullName)
    & $compiler /nologo /langversion:latest /target:library /platform:x64 $optimize /warnaserror+ `
        "/out:$coreOutput" `
        "/reference:$(Join-Path $framework 'System.dll')" `
        "/reference:$(Join-Path $framework 'System.Core.dll')" `
        $coreSources
    if ($LASTEXITCODE -ne 0) {
        throw "EXE Agent Core build failed with exit code $LASTEXITCODE."
    }

    $output = Join-Path $outputDirectory "BleProximityWake.Agent.exe"
    $agentSources = @(Get-ChildItem (Join-Path $PSScriptRoot "src\BleProximityWake.Agent") -Filter *.cs -Recurse | ForEach-Object FullName)
    $icon = Join-Path (Split-Path -Parent $PSScriptRoot) "assets\ble-proximity-wake.ico"
    $manifest = Join-Path $PSScriptRoot "src\BleProximityWake.Agent\app.manifest"
    $winMetadata = Join-Path $env:WINDIR "System32\WinMetadata"
    & $compiler /nologo /langversion:latest /target:winexe /platform:x64 $optimize /warnaserror+ `
        "/out:$output" `
        "/win32icon:$icon" `
        "/win32manifest:$manifest" `
        "/reference:$coreOutput" `
        "/reference:$(Join-Path $framework 'System.dll')" `
        "/reference:$(Join-Path $framework 'System.Core.dll')" `
        "/reference:$(Join-Path $framework 'System.Drawing.dll')" `
        "/reference:$(Join-Path $framework 'System.Management.dll')" `
        "/reference:$(Join-Path $framework 'System.ServiceProcess.dll')" `
        "/reference:$(Join-Path $framework 'System.Web.Extensions.dll')" `
        "/reference:$(Join-Path $framework 'System.Windows.Forms.dll')" `
        "/reference:$(Join-Path $framework 'System.Runtime.dll')" `
        "/reference:$(Join-Path $framework 'System.Runtime.InteropServices.WindowsRuntime.dll')" `
        "/reference:$(Join-Path $framework 'System.Runtime.WindowsRuntime.dll')" `
        "/reference:$(Join-Path $winMetadata 'Windows.Devices.winmd')" `
        "/reference:$(Join-Path $winMetadata 'Windows.Foundation.winmd')" `
        "/reference:$(Join-Path $winMetadata 'Windows.Networking.winmd')" `
        "/reference:$(Join-Path $winMetadata 'Windows.Storage.winmd')" `
        $agentSources
    if ($LASTEXITCODE -ne 0) {
        throw "EXE Agent build failed with exit code $LASTEXITCODE."
    }
}

$output = Join-Path $PSScriptRoot "bin\$Configuration\BleProximityWake.Agent.exe"
if (-not (Test-Path -LiteralPath $output)) {
    throw "EXE Agent output was not created: $output"
}

Write-Host "EXE Agent built: $output"
