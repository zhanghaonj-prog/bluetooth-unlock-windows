[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common-P1.ps1")
Assert-P1Administrator

$service = Get-CimInstance Win32_Service -Filter "Name='$script:P1ServiceName'"
$config = Get-ItemProperty -LiteralPath $script:P1ConfigKey
$credentialFile = Get-Item -LiteralPath $script:P1CredentialFile
$credentialAcl = Get-Acl -LiteralPath $script:P1CredentialFile
$trustedAgent = Get-P1TrustedAgentStatus
$result = [pscustomobject]@{
    ServiceState = [string]$service.State
    ServiceStartMode = [string]$service.StartMode
    ServiceStartName = [string]$service.StartName
    Enabled = [int]$config.Enabled
    UserSid = [string]$config.UserSid
    Username = [string]$config.Username
    Domain = [string]$config.Domain
    TrustedAgentPath = $trustedAgent.Path
    TrustedAgentExists = $trustedAgent.Exists
    TrustedAgentHashValid = $trustedAgent.Valid
    HasProtectedPassword = ($null -ne $config.ProtectedPassword)
    HasAuthorizedUntil = ($null -ne $config.AuthorizedUntilUtc)
    CredentialFileLength = [long]$credentialFile.Length
    CredentialFileSddl = [string]$credentialAcl.Sddl
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $result | Format-List
} else {
    $result | ConvertTo-Json | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}
if (-not $trustedAgent.Valid) {
    throw "Trusted Agent path or SHA-256 is missing or does not match. Reinstall or upgrade the automatic-unlock component."
}
