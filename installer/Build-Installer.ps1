[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [ValidatePattern("^\d+\.\d+\.\d+$")]
    [string]$Version = "0.1.0",
    [switch]$SkipBuild,
    [switch]$StageOnly,
    [string]$InnoCompilerPath = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$stageDirectory = Join-Path $PSScriptRoot "staging"
$outputDirectory = Join-Path $PSScriptRoot "output"

function Reset-Directory {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$ExpectedParent
    )

    $resolvedParent = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\')
    $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $resolvedPath.StartsWith($resolvedParent + "\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to reset directory outside '$resolvedParent': $resolvedPath"
    }

    if (Test-Path -LiteralPath $resolvedPath) {
        Remove-Item -LiteralPath $resolvedPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $resolvedPath -Force | Out-Null
}

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory)]
        [string]$Source,
        [Parameter(Mandatory)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required release file was not found: $Source"
    }

    $destinationDirectory = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

if (-not $SkipBuild) {
    & (Join-Path $repoRoot "agent\Build-Agent.ps1") -Configuration $Configuration
    & (Join-Path $repoRoot "credential-provider\Test-P0Provider.ps1")
    & (Join-Path $repoRoot "credential-provider\Build-P1Broker.ps1") -Configuration $Configuration
}

Reset-Directory -Path $stageDirectory -ExpectedParent $PSScriptRoot
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$agentOutput = Join-Path $repoRoot "agent\bin\$Configuration"
$providerOutput = Join-Path $repoRoot "credential-provider\bin\$Configuration"

Copy-RequiredFile `
    -Source (Join-Path $agentOutput "BleProximityWake.Agent.exe") `
    -Destination (Join-Path $stageDirectory "Agent\BleProximityWake.Agent.exe")
Copy-RequiredFile `
    -Source (Join-Path $agentOutput "BleProximityWake.Core.dll") `
    -Destination (Join-Path $stageDirectory "Agent\BleProximityWake.Core.dll")
Copy-RequiredFile `
    -Source (Join-Path $repoRoot "agent\agent-settings.sample.json") `
    -Destination (Join-Path $stageDirectory "Defaults\agent-settings.sample.json")

Copy-RequiredFile `
    -Source (Join-Path $providerOutput "BleProximityCredentialProvider.dll") `
    -Destination (Join-Path $stageDirectory "CredentialProvider\bin\$Configuration\BleProximityCredentialProvider.dll")
Copy-RequiredFile `
    -Source (Join-Path $providerOutput "BleProximityUnlockBroker.exe") `
    -Destination (Join-Path $stageDirectory "CredentialProvider\bin\$Configuration\BleProximityUnlockBroker.exe")

$providerScripts = @(
    "Common-P1.ps1",
    "Disable-P1Provider.ps1",
    "Install-P1Provider.ps1",
    "Set-P1Credential.ps1",
    "Test-P1HostRegistration.ps1",
    "Uninstall-P1Provider.ps1"
)
foreach ($scriptName in $providerScripts) {
    Copy-RequiredFile `
        -Source (Join-Path $repoRoot "credential-provider\scripts\$scriptName") `
        -Destination (Join-Path $stageDirectory "CredentialProvider\scripts\$scriptName")
}

Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot "scripts\Enroll-AutoUnlock.ps1") `
    -Destination (Join-Path $stageDirectory "Tools\Enroll-AutoUnlock.ps1")
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot "scripts\Disable-AutoUnlock.ps1") `
    -Destination (Join-Path $stageDirectory "Tools\Disable-AutoUnlock.ps1")
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot "scripts\Remove-AllUserData.ps1") `
    -Destination (Join-Path $stageDirectory "Tools\Remove-AllUserData.ps1")
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot "scripts\Open-Logs.ps1") `
    -Destination (Join-Path $stageDirectory "Tools\Open-Logs.ps1")
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot "scripts\Cleanup-LegacyStartup.ps1") `
    -Destination (Join-Path $stageDirectory "Tools\Cleanup-LegacyStartup.ps1")
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot "README.md") `
    -Destination (Join-Path $stageDirectory "Documentation\INSTALLER_README.md")
Copy-RequiredFile `
    -Source (Join-Path $repoRoot "agent\README.md") `
    -Destination (Join-Path $stageDirectory "Documentation\AGENT_README.md")

$manifestFiles = @(
    Get-ChildItem -LiteralPath $stageDirectory -File -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            [ordered]@{
                path = $_.FullName.Substring($stageDirectory.Length + 1).Replace("\", "/")
                size = $_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
)
$manifest = [ordered]@{
    product = "BLE Proximity Wake"
    version = $Version
    configuration = $Configuration
    architecture = "x64"
    generatedUtc = [DateTime]::UtcNow.ToString("o")
    files = $manifestFiles
}
$manifest | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $stageDirectory "release-manifest.json") -Encoding UTF8

& (Join-Path $PSScriptRoot "Test-InstallerLayout.ps1") `
    -StageDirectory $stageDirectory `
    -Configuration $Configuration
& (Join-Path $PSScriptRoot "Test-InstallerDefinition.ps1") `
    -DefinitionPath (Join-Path $PSScriptRoot "BleProximityWake.iss")

if ($StageOnly) {
    Write-Host "Installer staging completed: $stageDirectory"
    return
}

if ([string]::IsNullOrWhiteSpace($InnoCompilerPath)) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
    )
    $InnoCompilerPath = $candidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($InnoCompilerPath) -or
    -not (Test-Path -LiteralPath $InnoCompilerPath -PathType Leaf)) {
    throw "Inno Setup 6 compiler was not found. Install it or rerun with -StageOnly."
}

& $InnoCompilerPath `
    "/DMyAppVersion=$Version" `
    "/DStageDir=$stageDirectory" `
    "/DOutputDir=$outputDirectory" `
    (Join-Path $PSScriptRoot "BleProximityWake.iss")
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
}

$installer = Join-Path $outputDirectory "BleProximityWake-$Version-win-x64.exe"
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "Installer compilation did not produce the expected file: $installer"
}

$installerHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
$hashPath = $installer + ".sha256"
"$($installerHash.ToLowerInvariant())  $([IO.Path]::GetFileName($installer))" |
    Set-Content -LiteralPath $hashPath -Encoding ASCII
Write-Host "Installer built: $installer"
Write-Host "SHA256: $installerHash"
