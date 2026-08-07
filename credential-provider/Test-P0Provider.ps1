[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

$scripts = Get-ChildItem -LiteralPath $root -Recurse -Filter "*.ps1" |
    Where-Object { $_.FullName -notmatch "[\\/](bin|obj)[\\/]" }
$parseErrors = @()
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $script.FullName,
        [ref]$tokens,
        [ref]$errors) | Out-Null
    $parseErrors += $errors
}
if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Error $_.Message }
    throw "PowerShell syntax validation failed."
}
Write-Host "PowerShell syntax: OK ($($scripts.Count) files)"

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$installationPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
$msbuild = Join-Path $installationPath "MSBuild\Current\Bin\MSBuild.exe"

foreach ($configuration in @("Debug", "Release")) {
    & (Join-Path $root "Build-P1Broker.ps1") -Configuration $configuration
    if ($LASTEXITCODE -ne 0) {
        throw "$configuration Broker build failed."
    }
    & (Join-Path $root "Build-P0Provider.ps1") -Configuration $configuration
    if ($LASTEXITCODE -ne 0) {
        throw "$configuration build failed."
    }
}

$broker = Join-Path $root "bin\Release\BleProximityUnlockBroker.exe"
& $broker --self-test
if ($LASTEXITCODE -ne 0) {
    throw "Broker self-test failed with exit code $LASTEXITCODE."
}

$packingProject = Join-Path $root "tests\PackingTests.vcxproj"
& $msbuild $packingProject /t:Rebuild /p:Configuration=Release /p:Platform=x64 /m
if ($LASTEXITCODE -ne 0) {
    throw "Credential packing test build failed."
}
$packingTest = Join-Path $root "bin\tests\PackingTests.exe"
$dll = Join-Path $root "bin\Release\BleProximityCredentialProvider.dll"
& $packingTest $dll
if ($LASTEXITCODE -ne 0) {
    throw "Credential packing test failed with exit code $LASTEXITCODE."
}

$dumpbin = Get-ChildItem `
    (Join-Path $installationPath "VC\Tools\MSVC") `
    -Recurse `
    -Filter dumpbin.exe | Where-Object { $_.FullName -match "Hostx64\\x64" } | Select-Object -First 1
if ($null -eq $dumpbin) {
    throw "x64 dumpbin.exe was not found."
}

$headers = & $dumpbin.FullName /headers $dll | Out-String
if ($headers -notmatch "8664 machine \(x64\)") {
    throw "Provider DLL is not x64."
}
$exports = & $dumpbin.FullName /exports $dll | Out-String
foreach ($requiredExport in @("DllCanUnloadNow", "DllGetClassObject")) {
    if ($exports -notmatch [regex]::Escape($requiredExport)) {
        throw "Required COM export is missing: $requiredExport"
    }
}

$source = Get-Content (Join-Path $root "provider\Credential.cpp") -Raw -Encoding UTF8
if ($source -match "ProtectedPassword.*WriteDiagnostic|password.*WriteDiagnostic") {
    throw "Diagnostic logging appears to reference password data."
}
$providerSources = Get-Content (Join-Path $root "provider\*.cpp") -Raw -Encoding UTF8
if ($providerSources -match "ProtectedPassword|CryptUnprotectData|AuthorizedUntilUtc") {
    throw "Provider still contains direct credential storage or authorization access."
}
$brokerSource = Get-Content (Join-Path $root "broker\BrokerService.cs") -Raw -Encoding UTF8
foreach ($requiredBrokerBoundary in @(
    "TrustedAgentPath",
    "TrustedAgentSha256",
    "IsTrustedAgentImage",
    "GetNamedPipeClientProcessId",
    "WTSQuerySessionInformation")) {
    if ($brokerSource.IndexOf($requiredBrokerBoundary, [StringComparison]::Ordinal) -lt 0) {
        throw "Broker is missing trusted Agent verification: $requiredBrokerBoundary"
    }
}
$installSource = Get-Content (Join-Path $root "scripts\Install-P1Provider.ps1") -Raw -Encoding UTF8
foreach ($requiredInstallBehavior in @(
    "AgentExecutablePath",
    "Get-FileHash",
    "previousUserSid",
    "previousUsername",
    "previousDomain",
    "Remove-P1PartialRegistration")) {
    if ($installSource.IndexOf($requiredInstallBehavior, [StringComparison]::Ordinal) -lt 0) {
        throw "P1 installer is missing trusted Agent or rollback behavior: $requiredInstallBehavior"
    }
}

Write-Host "Provider architecture and COM exports: OK"
Write-Host "P1 Broker boundary and P0/P1 Provider static verification passed."
