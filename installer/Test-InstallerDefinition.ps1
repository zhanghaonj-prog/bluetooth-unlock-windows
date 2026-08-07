[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DefinitionPath
)

$ErrorActionPreference = "Stop"
$definition = Get-Content -LiteralPath $DefinitionPath -Raw
$requiredPatterns = @(
    "PrivilegesRequired=admin",
    "ArchitecturesAllowed=x64compatible",
    "ArchitecturesInstallIn64BitMode=x64compatible",
    'Name: "agentonly"',
    'Name: "autounlock"',
    "Install-P1Provider.ps1",
    "-AgentExecutablePath",
    "-PreserveEnrollment",
    "Cleanup-LegacyStartup.ps1",
    "runasoriginaluser waituntilterminated runhidden",
    "Uninstall-P1Provider.ps1",
    "-RemoveEncryptedCredential -RemoveDataDirectory",
    "if Result then",
    "自动解锁组件卸载失败",
    "Remove-AllUserData.ps1",
    "DotNet48Release"
)
foreach ($pattern in $requiredPatterns) {
    if ($definition.IndexOf($pattern, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Installer definition is missing required behavior: $pattern"
    }
}

$forbiddenPatterns = @(
    "{localappdata}",
    "credential.dat",
    "config.json"
)
foreach ($pattern in $forbiddenPatterns) {
    if ($definition.IndexOf($pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "Installer definition directly handles forbidden per-user or host data: $pattern"
    }
}

Write-Host "Installer definition validation passed."
