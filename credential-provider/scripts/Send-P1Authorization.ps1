[CmdletBinding()]
param(
    [ValidateRange(1, 10)]
    [int]$AuthorizationSeconds = 5,
    [UInt64]$LockCycleId = [UInt64]([DateTime]::UtcNow.Ticks)
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common-P1.ps1")

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$sid = $identity.User.Value
$sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
$requestId = [Guid]::NewGuid()
$sidBytes = [Text.Encoding]::Unicode.GetBytes($sid)

$payloadStream = [IO.MemoryStream]::new()
$payloadWriter = [IO.BinaryWriter]::new($payloadStream)
try {
    $payloadWriter.Write([int]$sessionId)
    $payloadWriter.Write([uint32]($AuthorizationSeconds * 1000))
    $payloadWriter.Write([uint64]$LockCycleId)
    $payloadWriter.Write($requestId.ToByteArray())
    $payloadWriter.Write([uint32]$sid.Length)
    $payloadWriter.Write($sidBytes)
    $payloadWriter.Flush()
    $payload = $payloadStream.ToArray()
} finally {
    $payloadWriter.Dispose()
    $payloadStream.Dispose()
}

$pipe = [IO.Pipes.NamedPipeClientStream]::new(
    ".",
    $script:P1AgentPipeName,
    [IO.Pipes.PipeDirection]::InOut,
    [IO.Pipes.PipeOptions]::None)
try {
    $pipe.Connect(2000)
    $writer = [IO.BinaryWriter]::new($pipe, [Text.Encoding]::Unicode, $true)
    $reader = [IO.BinaryReader]::new($pipe, [Text.Encoding]::Unicode, $true)
    try {
        $writer.Write([uint32]0x42505742)
        $writer.Write([uint32]1)
        $writer.Write([uint32]1)
        $writer.Write([uint32]$payload.Length)
        $writer.Write($payload)
        $writer.Flush()

        $magic = $reader.ReadUInt32()
        $version = $reader.ReadUInt32()
        $status = $reader.ReadUInt32()
        $responseBytes = $reader.ReadUInt32()
        if ($magic -ne 0x42505742 -or $version -ne 1 -or $responseBytes -ne 0) {
            throw "Broker returned an invalid response."
        }
        if ($status -ne 0) {
            $statusNames = @(
                "Ok", "InvalidRequest", "AccessDenied", "NotConfigured",
                "SessionNotLocked", "AlreadyAttempted", "NoAuthorization",
                "AuthorizationExpired", "ProviderUnavailable",
                "CredentialUnavailable", "InternalError")
            $statusName = if ($status -lt $statusNames.Count) { $statusNames[$status] } else { "Unknown" }
            throw "Broker rejected authorization with status $status ($statusName)."
        }
    } finally {
        $reader.Dispose()
        $writer.Dispose()
    }
} finally {
    $pipe.Dispose()
    [Array]::Clear($payload, 0, $payload.Length)
    [Array]::Clear($sidBytes, 0, $sidBytes.Length)
}
Write-Host "P1 one-use authorization accepted. RequestId=$requestId LockCycleId=$LockCycleId"
