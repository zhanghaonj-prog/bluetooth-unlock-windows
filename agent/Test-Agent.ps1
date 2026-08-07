param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
& (Join-Path $PSScriptRoot "Build-Agent.ps1") -Configuration $Configuration

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$installationPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
$msbuild = Join-Path $installationPath "MSBuild\Current\Bin\MSBuild.exe"
$testProject = Join-Path $PSScriptRoot "tests\BleProximityWake.Agent.Tests\BleProximityWake.Agent.Tests.csproj"
$referencePack = "${env:ProgramFiles(x86)}\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8"
if (Test-Path -LiteralPath $referencePack) {
    & $msbuild $testProject /t:Rebuild "/p:Configuration=$Configuration" /p:Platform=x64 /m
    if ($LASTEXITCODE -ne 0) {
        throw "EXE Agent test MSBuild failed with exit code $LASTEXITCODE."
    }
}
else {
    $compiler = Join-Path $installationPath "MSBuild\Current\Bin\Roslyn\csc.exe"
    $framework = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319"
    $testOutputDirectory = Join-Path $PSScriptRoot "bin\tests"
    New-Item -ItemType Directory -Path $testOutputDirectory -Force | Out-Null
    $testExecutable = Join-Path $testOutputDirectory "BleProximityWake.Agent.Tests.exe"
    $testSources = @(Get-ChildItem (Join-Path $PSScriptRoot "tests\BleProximityWake.Agent.Tests") -Filter *.cs -Recurse | ForEach-Object FullName)
    $agentOutputDirectory = Join-Path $PSScriptRoot "bin\$Configuration"
    Copy-Item (Join-Path $agentOutputDirectory "BleProximityWake.Agent.exe") $testOutputDirectory -Force
    Copy-Item (Join-Path $agentOutputDirectory "BleProximityWake.Core.dll") $testOutputDirectory -Force
    & $compiler /nologo /langversion:latest /target:exe /platform:x64 /optimize+ /warnaserror+ `
        "/out:$testExecutable" `
        "/reference:$(Join-Path $testOutputDirectory 'BleProximityWake.Agent.exe')" `
        "/reference:$(Join-Path $testOutputDirectory 'BleProximityWake.Core.dll')" `
        "/reference:$(Join-Path $framework 'System.dll')" `
        "/reference:$(Join-Path $framework 'System.Core.dll')" `
        $testSources
    if ($LASTEXITCODE -ne 0) {
        throw "EXE Agent test build failed with exit code $LASTEXITCODE."
    }
}

$testExecutable = Join-Path $PSScriptRoot "bin\tests\BleProximityWake.Agent.Tests.exe"
& $testExecutable
if ($LASTEXITCODE -ne 0) {
    throw "EXE Agent tests failed with exit code $LASTEXITCODE."
}

$smokeDirectory = Join-Path $env:TEMP ("BleProximityWake.Agent.Smoke." + [Guid]::NewGuid().ToString("N"))
$previousDataDirectory = $env:BLE_PROXIMITY_WAKE_DATA_DIR
try {
    $env:BLE_PROXIMITY_WAKE_DATA_DIR = $smokeDirectory
    $agentExecutable = Join-Path $PSScriptRoot "bin\$Configuration\BleProximityWake.Agent.exe"
    $process = Start-Process -FilePath $agentExecutable -ArgumentList "--smoke-test" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "EXE Agent smoke test failed with exit code $($process.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $smokeDirectory "agent-settings.json"))) {
        throw "EXE Agent smoke test did not create its settings file."
    }
    if (-not (Get-ChildItem (Join-Path $smokeDirectory "logs") -Filter *.log -ErrorAction SilentlyContinue)) {
        throw "EXE Agent smoke test did not create its log file."
    }
    $smokeLog = Get-ChildItem (Join-Path $smokeDirectory "logs") -Filter *.log |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (
        (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\WinMetadata\Windows.Devices.winmd")) -and
        -not ((Get-Content -LiteralPath $smokeLog.FullName -Raw) -match "BLE advertisement API: True")
    ) {
        throw "EXE Agent capability detection did not recognize split WinRT metadata."
    }
    Write-Host "EXE Agent smoke test passed."

    $legacyConfig = Join-Path (Split-Path -Parent $PSScriptRoot) "config.sample.json"
    $process = Start-Process -FilePath $agentExecutable -ArgumentList @(
        "--import-legacy-config",
        "`"$legacyConfig`"",
        "--import-only"
    ) -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Get-ChildItem (Join-Path $smokeDirectory "logs") -Filter *.log -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc |
            ForEach-Object {
                Write-Host "Agent failure log: $($_.FullName)"
                Get-Content -LiteralPath $_.FullName
            }
        throw "EXE Agent legacy import smoke test failed with exit code $($process.ExitCode)."
    }
    $importedSettings = Get-Content -LiteralPath (Join-Path $smokeDirectory "agent-settings.json") -Raw | ConvertFrom-Json
    if ([int]$importedSettings.schemaVersion -ne 5) {
        throw "EXE Agent legacy import did not write schema version 5."
    }
    if ([bool]$importedSettings.actions.wake.enabled -or [bool]$importedSettings.actions.autoLock.enabled) {
        throw "EXE Agent legacy import unexpectedly enabled a system action."
    }
    if ([bool]$importedSettings.autoUnlock.enabled) {
        throw "EXE Agent legacy import unexpectedly enabled automatic unlock."
    }
    if ([string]$importedSettings.detection.phoneMatcher.address -ne [string](Get-Content -LiteralPath $legacyConfig -Raw | ConvertFrom-Json).phone.address) {
        throw "EXE Agent legacy import did not preserve the configured phone address."
    }
    Write-Host "EXE Agent legacy import smoke test passed."
}
finally {
    $env:BLE_PROXIMITY_WAKE_DATA_DIR = $previousDataDirectory
    Remove-Item -LiteralPath $smokeDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
