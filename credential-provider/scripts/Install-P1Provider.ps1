[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [string]$AgentExecutablePath = "",
    [switch]$PreserveEnrollment,
    [switch]$IUnderstandThisCanAffectSignIn
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common-P1.ps1")
Assert-P1Administrator
Assert-P1RiskAcknowledgement -IUnderstandThisCanAffectSignIn:$IUnderstandThisCanAffectSignIn

$previousEnabled = 0
$previousUserSid = ""
$previousUsername = ""
$previousDomain = ""
$hasExistingEnrollment = $false
if ($PreserveEnrollment -and
    (Test-Path -LiteralPath $script:P1ConfigKey) -and
    (Test-Path -LiteralPath $script:P1CredentialFile -PathType Leaf)) {
    $previousConfig = Get-ItemProperty -LiteralPath $script:P1ConfigKey
    $previousEnabled = [int]$previousConfig.Enabled
    $previousUserSid = [string]$previousConfig.UserSid
    $previousUsername = [string]$previousConfig.Username
    $previousDomain = [string]$previousConfig.Domain
    $hasExistingEnrollment =
        -not [string]::IsNullOrWhiteSpace($previousUserSid) -and
        -not [string]::IsNullOrWhiteSpace($previousUsername) -and
        -not [string]::IsNullOrWhiteSpace($previousDomain)
}

$root = Split-Path -Parent $PSScriptRoot
$sourceDll = Join-Path $root "bin\$Configuration\BleProximityCredentialProvider.dll"
$sourceBroker = Join-Path $root "bin\$Configuration\BleProximityUnlockBroker.exe"
foreach ($source in @($sourceDll, $sourceBroker)) {
    if (-not (Test-Path -LiteralPath $source)) {
        throw "P1 binary not found: $source"
    }
}

if ([string]::IsNullOrWhiteSpace($AgentExecutablePath)) {
    $repositoryRoot = Split-Path -Parent $root
    $agentCandidates = @(
        (Join-Path $repositoryRoot "Agent\BleProximityWake.Agent.exe"),
        (Join-Path $repositoryRoot "agent\bin\$Configuration\BleProximityWake.Agent.exe")
    )
    $AgentExecutablePath = $agentCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($AgentExecutablePath) -or
    -not (Test-Path -LiteralPath $AgentExecutablePath -PathType Leaf)) {
    throw "Trusted Agent executable not found. Pass -AgentExecutablePath explicitly."
}
$trustedAgentPath = [IO.Path]::GetFullPath($AgentExecutablePath)
$trustedAgentSha256 = (Get-FileHash -LiteralPath $trustedAgentPath -Algorithm SHA256).Hash

function Remove-P1PartialRegistration {
    try {
        if (Test-Path -LiteralPath $script:P1ConfigKey) {
            New-ItemProperty -Path $script:P1ConfigKey -Name "Enabled" -Value 0 -PropertyType DWord -Force | Out-Null
        }
    } catch {}
    try { Stop-Service -Name $script:P1ServiceName -Force -ErrorAction SilentlyContinue } catch {}
    try {
        if ($null -ne (Get-Service -Name $script:P1ServiceName -ErrorAction SilentlyContinue)) {
            & sc.exe delete $script:P1ServiceName | Out-Null
        }
    } catch {}
    try { Remove-Item -LiteralPath $script:P1CredentialProviderKey -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item -LiteralPath $script:P1ComKey -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

try {
    $service = Get-Service -Name $script:P1ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $service) {
        if ($service.Status -ne "Stopped") {
            Stop-Service -Name $script:P1ServiceName -Force
            $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(10))
        }
        & sc.exe delete $script:P1ServiceName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to replace the existing Broker service." }
        $deleteDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 250
            $service = Get-Service -Name $script:P1ServiceName -ErrorAction SilentlyContinue
        } while ($null -ne $service -and [DateTime]::UtcNow -lt $deleteDeadline)
        if ($null -ne $service) { throw "Timed out waiting for the old Broker service to be deleted." }
    }

    New-Item -ItemType Directory -Path $script:P1InstallDirectory -Force | Out-Null
    $installedDll = Join-Path $script:P1InstallDirectory "BleProximityCredentialProvider.dll"
    $installedBroker = Join-Path $script:P1InstallDirectory "BleProximityUnlockBroker.exe"
    Copy-Item -LiteralPath $sourceDll -Destination $installedDll -Force
    Copy-Item -LiteralPath $sourceBroker -Destination $installedBroker -Force

    Set-P1DataAcl
    Set-P1RegistryDefaultValue -Path $script:P1ComKey -Value "BLE Proximity Credential Provider P1"
    $inProcKey = Join-Path $script:P1ComKey "InprocServer32"
    Set-P1RegistryDefaultValue -Path $inProcKey -Value $installedDll
    New-ItemProperty -Path $inProcKey -Name "ThreadingModel" -Value "Apartment" -PropertyType String -Force | Out-Null
    Set-P1RegistryDefaultValue -Path $script:P1CredentialProviderKey -Value "BLE Proximity Credential Provider P1"
    New-Item -Path $script:P1ConfigKey -Force | Out-Null
    New-ItemProperty -Path $script:P1ConfigKey -Name "Enabled" -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $script:P1ConfigKey -Name "TrustedAgentPath" -Value $trustedAgentPath -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $script:P1ConfigKey -Name "TrustedAgentSha256" -Value $trustedAgentSha256 -PropertyType String -Force | Out-Null

    $quotedBroker = '"{0}"' -f $installedBroker
    New-Service -Name $script:P1ServiceName `
        -BinaryPathName $quotedBroker `
        -DisplayName "BLE Proximity Unlock Broker" `
        -Description "Issues one-use Windows unlock credentials to the BLE proximity Credential Provider." `
        -StartupType Automatic | Out-Null

    if ($hasExistingEnrollment) {
        foreach ($entry in @(
            @{ Name = "UserSid"; Value = $previousUserSid; Type = "String" },
            @{ Name = "Username"; Value = $previousUsername; Type = "String" },
            @{ Name = "Domain"; Value = $previousDomain; Type = "String" },
            @{ Name = "Enabled"; Value = $previousEnabled; Type = "DWord" }
        )) {
            New-ItemProperty `
                -Path $script:P1ConfigKey `
                -Name $entry.Name `
                -Value $entry.Value `
                -PropertyType $entry.Type `
                -Force | Out-Null
        }
    }
    Start-Service -Name $script:P1ServiceName
} catch {
    Remove-P1PartialRegistration
    throw
}

if ($hasExistingEnrollment) {
    Write-Host "P1 Provider and LocalSystem Broker upgraded."
    Write-Host "Existing enrollment was preserved. Enabled=$previousEnabled"
}
else {
    Write-Host "P1 Provider and LocalSystem Broker installed in disabled state."
    Write-Host "Next: run Set-P1Credential.ps1, then verify normal password/PIN sign-in."
}
