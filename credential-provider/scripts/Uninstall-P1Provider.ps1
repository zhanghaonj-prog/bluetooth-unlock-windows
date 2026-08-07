[CmdletBinding()]
param(
    [switch]$RemoveEncryptedCredential,
    [switch]$RemoveDataDirectory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common-P1.ps1")
Assert-P1Administrator

if (Test-Path -LiteralPath $script:P1ConfigKey) {
    New-ItemProperty -Path $script:P1ConfigKey -Name "Enabled" -Value 0 -PropertyType DWord -Force | Out-Null
}
$service = Get-Service -Name $script:P1ServiceName -ErrorAction SilentlyContinue
if ($null -ne $service -and $service.Status -ne "Stopped") {
    Stop-Service -Name $script:P1ServiceName -Force -ErrorAction Stop
    $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(10))
}
if ($null -ne (Get-Service -Name $script:P1ServiceName -ErrorAction SilentlyContinue)) {
    & sc.exe delete $script:P1ServiceName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to delete Broker service '$script:P1ServiceName'."
    }
    $deleteDeadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 250
        $service = Get-Service -Name $script:P1ServiceName -ErrorAction SilentlyContinue
    } while ($null -ne $service -and [DateTime]::UtcNow -lt $deleteDeadline)
    if ($null -ne $service) {
        throw "Timed out waiting for Broker service '$script:P1ServiceName' to be deleted."
    }
}
foreach ($registrationKey in @($script:P1CredentialProviderKey, $script:P1ComKey)) {
    if (Test-Path -LiteralPath $registrationKey) {
        Remove-Item -LiteralPath $registrationKey -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $registrationKey) {
        throw "Failed to remove registration key: $registrationKey"
    }
}
if ($RemoveEncryptedCredential) {
    if (Test-Path -LiteralPath $script:P1CredentialFile) {
        Remove-Item -LiteralPath $script:P1CredentialFile -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $script:P1ConfigKey) {
        Remove-Item -LiteralPath $script:P1ConfigKey -Recurse -Force -ErrorAction Stop
    }
}
if ($RemoveDataDirectory) {
    $programDataRoot = [IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
    $dataDirectory = [IO.Path]::GetFullPath($script:P1DataDirectory).TrimEnd('\')
    if (-not $dataDirectory.StartsWith(
        $programDataRoot + "\",
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove data directory outside ProgramData: $dataDirectory"
    }
    if (Test-Path -LiteralPath $dataDirectory) {
        Remove-Item -LiteralPath $dataDirectory -Recurse -Force -ErrorAction Stop
    }
}
try {
    Remove-Item -LiteralPath $script:P1InstallDirectory -Recurse -Force -ErrorAction Stop
} catch {
    Write-Warning "P1 files are still loaded. Registration is removed; reboot and delete '$script:P1InstallDirectory'."
}
Write-Host "P1 registration and Broker service removed. Restart Windows before reusing the VM snapshot."
