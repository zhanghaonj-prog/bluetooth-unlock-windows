[CmdletBinding()]
param(
    [string]$SourceDirectory = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
    $SourceDirectory = Join-Path $PSScriptRoot 'bin\Release'
}
$transcriptPath = Join-Path $env:TEMP 'BleProximityWake-upgrade-last.log'
Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run from an elevated 64-bit Windows PowerShell window.'
}
if (-not [Environment]::Is64BitProcess) {
    throw 'The Agent upgrade requires 64-bit Windows PowerShell.'
}

$installedDirectory = Join-Path $env:ProgramFiles 'BleProximityWake\Agent'
$installedExe = Join-Path $installedDirectory 'BleProximityWake.Agent.exe'
$sourceExe = Join-Path $SourceDirectory 'BleProximityWake.Agent.exe'
$sourceCore = Join-Path $SourceDirectory 'BleProximityWake.Core.dll'
$installedCore = Join-Path $installedDirectory 'BleProximityWake.Core.dll'
$configKey = 'HKLM:\SOFTWARE\BleProximityWake\CredentialProviderP0'
foreach ($path in @($installedExe, $installedCore, $sourceExe, $sourceCore, $configKey)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required upgrade path is missing: $path"
    }
}
$registration = Get-ItemProperty -LiteralPath $configKey
$trustedPath = [IO.Path]::GetFullPath([string]$registration.TrustedAgentPath)
if (-not $trustedPath.Equals(
    [IO.Path]::GetFullPath($installedExe),
    [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Broker trusted Agent path does not match the installed Agent.'
}
$oldHash = (Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash
if (-not $oldHash.Equals(
    [string]$registration.TrustedAgentSha256,
    [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Installed Agent already differs from the Broker trusted hash.'
}

$sessionId = (Get-Process -Id $PID).SessionId
$runningAgents = @(Get-Process -Name 'BleProximityWake.Agent' -ErrorAction SilentlyContinue |
    Where-Object { $_.SessionId -eq $sessionId })
foreach ($agent in $runningAgents) {
    Stop-Process -Id $agent.Id -Force -ErrorAction Stop
    $agent.WaitForExit(5000) | Out-Null
}
try {
    & (Join-Path $PSScriptRoot 'Test-Agent.ps1') -Configuration Release
    if ($LASTEXITCODE -ne 0) {
        throw 'Agent tests failed.'
    }

$backupDirectory = Join-Path $env:TEMP ('BleProximityWake-upgrade-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $backupDirectory | Out-Null
Copy-Item -LiteralPath $installedExe -Destination $backupDirectory
Copy-Item -LiteralPath $installedCore -Destination $backupDirectory
try {
    Copy-Item -LiteralPath $sourceCore -Destination $installedCore -Force
    Copy-Item -LiteralPath $sourceExe -Destination $installedExe -Force
    $newHash = (Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash
    if (-not $newHash.Equals(
        (Get-FileHash -LiteralPath $sourceExe -Algorithm SHA256).Hash,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Installed Agent hash differs from the build output.'
    }
    Set-ItemProperty -LiteralPath $configKey -Name TrustedAgentSha256 -Value $newHash
    Write-Host "Agent upgraded. Trusted hash: $newHash"
    Write-Host "Rollback binaries retained at: $backupDirectory"
}
catch {
    Copy-Item -LiteralPath (Join-Path $backupDirectory 'BleProximityWake.Agent.exe') -Destination $installedExe -Force
    Copy-Item -LiteralPath (Join-Path $backupDirectory 'BleProximityWake.Core.dll') -Destination $installedCore -Force
    Set-ItemProperty -LiteralPath $configKey -Name TrustedAgentSha256 -Value $oldHash
    throw
}
}
finally {
    if ($runningAgents.Count -gt 0 -and
        -not (Get-Process -Name 'BleProximityWake.Agent' -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $sessionId })) {
        Start-Process -FilePath $installedExe -WindowStyle Hidden
        Write-Host 'Agent restarted.'
    }
}
Stop-Transcript | Out-Null
