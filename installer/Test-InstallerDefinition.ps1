[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DefinitionPath
)

$ErrorActionPreference = "Stop"
$definition = Get-Content -LiteralPath $DefinitionPath -Raw -Encoding UTF8
$autoUnlockUninstallFailureText = -join [char[]](
    0x81EA, 0x52A8, 0x89E3, 0x9501, 0x7EC4,
    0x4EF6, 0x5378, 0x8F7D, 0x5931, 0x8D25
)
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
    $autoUnlockUninstallFailureText,
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
