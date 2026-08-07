$ErrorActionPreference = "Stop"

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mainScript = Join-Path $scriptRoot "Start-BleProximityWake.ps1"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

Write-Host "Parsing PowerShell and JSON files..."
foreach ($file in Get-ChildItem -Path $scriptRoot -Filter *.ps1 -Recurse) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True ($errors.Count -eq 0) "PowerShell parse failed: $($file.FullName)"
}
$configFiles = @("config.sample.json")
if (Test-Path -LiteralPath (Join-Path $scriptRoot "config.json")) {
    $configFiles += "config.json"
}
foreach ($name in $configFiles) {
    Get-Content (Join-Path $scriptRoot $name) -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
}
$sampleConfig = Get-Content (Join-Path $scriptRoot "config.sample.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($sampleConfig.autoUnlock.triggerOnInteractiveWake -eq $true) "Sample config must expose interactive-wake auto-unlock."
Assert-True ($sampleConfig.autoUnlock.invokeWakeToLoginOnArrival -eq $false) "Credential Provider arrival must skip wake-to-login simulation by default."
Assert-True ([double]$sampleConfig.autoUnlock.interactiveWakeMinimumPriorIdleSeconds -eq 1) "Interactive wake must accept prompt input after the lock-input suppression window."
Assert-True ([int]$sampleConfig.autoUnlock.interactiveWakeLoginPageDelayMilliseconds -eq 0) "Interactive wake must not add a fixed Provider delay."
Assert-True ([int]$sampleConfig.autoUnlock.interactiveWakeConfirmationMilliseconds -eq 6000) "Interactive wake must allow six seconds for post-wake BLE recovery."
Assert-True ([int]$sampleConfig.autoUnlock.loginPageDelayMilliseconds -eq 0) "Arrival auto-unlock must not add a fixed Provider delay."
Assert-True ($sampleConfig.autoUnlock.interactiveWakeAllowIdleFallback -eq $true) "Interactive wake must support fresh input while the locked display remains on."
Assert-True ($null -eq $sampleConfig.autoUnlock.PSObject.Properties['brokerPipeName']) "Sample config must not expose the fixed internal Broker pipe name."
Assert-True ([int]$sampleConfig.phone.strongRssiSingleHitThreshold -eq -60) "Sample config must expose the phone strong-signal fast path."
Assert-True ([string]$sampleConfig.power.holdMode -eq "Disabled") "Sample config must allow Modern Standby by default."
Assert-True ($sampleConfig.wake.enableVirtualKey -eq $true) "Sample config must expose the virtual-key diagnostic switch."

Write-Host "Testing preferred watch address learning..."
$tokens = $null
$errors = $null
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref]$tokens, [ref]$errors)
$mainSource = Get-Content $mainScript -Raw -Encoding UTF8
Assert-True ($mainSource -match '\$displayStateAtLock\s*=\s*\[int\]\$state\.LastDisplayState') "SessionLock must capture the current display state."
Assert-True ($mainSource -match '\$state\.DisplayWasOffSinceLock\s*=\s*\(\$displayStateAtLock\s+-eq\s+0\s+-or\s+\$displayStateAtLock\s+-eq\s+2\)') "SessionLock must preserve existing off/dimmed display evidence."
foreach ($trayLabel in @("BLE Proximity Wake |", "Session:", "Devices:", "Environment:", "Scanning:", "Auto unlock:", "Test wake to sign-in", "Re-detect devices", "Pause detection", "Features", "Wake on approach", "Automatic unlock", "Lock when away", "Diagnostics", "Open current log", "Copy diagnostic summary", "Open configuration", "Exit")) {
    Assert-True ($mainSource.Contains($trayLabel)) "Tray menu label is missing: $trayLabel"
}
Assert-True ($mainSource.Contains('[bool]$state.RuntimeWakeEnabled -and $hitOk')) "Wake-on-approach runtime switch must guard the arrival trigger."
Assert-True ($mainSource.Contains('$autoUnlockEnabled -and [bool]$state.RuntimeAutoUnlockEnabled')) "Automatic-unlock runtime switch must guard unlock paths."
Assert-True ($mainSource.Contains('$autoLockEnabled -and [bool]$state.RuntimeAutoLockEnabled')) "Departure-lock runtime switch must guard lock paths."
Assert-True ($mainSource.Contains('if ([bool]$state.DetectionPaused)')) "Paused detection must have a runtime guard."
Assert-True ($mainSource.Contains('assets\ble-proximity-wake.ico')) "Tray icon path is missing from the main script"
Assert-True ($mainSource.Contains('brokerPipeName is a fixed internal protocol name and cannot be changed')) "PowerShell runtime must reject a custom Broker pipe name."

$trayIconPath = Join-Path $PSScriptRoot 'assets\ble-proximity-wake.ico'
Assert-True (Test-Path -LiteralPath $trayIconPath -PathType Leaf) "Tray icon asset exists"
Add-Type -AssemblyName System.Drawing
$trayIcon = [System.Drawing.Icon]::new($trayIconPath)
try {
    Assert-True ($trayIcon.Width -ge 16 -and $trayIcon.Height -ge 16) "Tray icon contains a usable size"
}
finally {
    $trayIcon.Dispose()
}
$wantedFunctions = "Normalize-BluetoothAddress", "Add-TargetCandidateObservation", "Get-PreferredTargetCandidate", "Get-NetworkDisplayName", "Reset-DeviceDetectionState", "New-AutoUnlockAuthorizationPayload", "Read-PipeBytesWithTimeout", "Test-InteractiveWakeInputEdge", "Test-RecentUtcTimestamp", "Test-PhonePresenceReady", "Test-AutoUnlockTransientStatus", "Get-AutoUnlockRetryDelayMilliseconds", "Start-InteractiveBleRecovery"
$definitions = $mainAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wantedFunctions -contains $node.Name
}, $true)
foreach ($name in $wantedFunctions) {
    $definition = $definitions | Where-Object Name -eq $name | Select-Object -First 1
    Assert-True ($null -ne $definition) "Function not found: $name"
    Invoke-Expression $definition.Extent.Text
}

Assert-True ((Get-NetworkDisplayName "ssid match: Example-Wired") -eq "Example-Wired") "SSID match display name failed."
Assert-True ((Get-NetworkDisplayName "profile match: Example-Wired|Example-Wired-2") -eq "Example-Wired") "Profile match display name failed."
Assert-True ((Get-NetworkDisplayName "no network match; profiles=Example-WiFi 2; ssid=Example-WiFi; interfaces=WLAN; dns=") -eq "Example-WiFi") "Blocked network display name failed."

$candidates = @{}
$now = [DateTime]::UtcNow
1..5 | ForEach-Object { Add-TargetCandidateObservation $candidates "AA:AA:AA:AA:AA:AA" $now.AddSeconds(-$_) -55 }
1..2 | ForEach-Object { Add-TargetCandidateObservation $candidates "BB:BB:BB:BB:BB:BB" $now.AddSeconds(-$_) -50 }
$first = Get-PreferredTargetCandidate $candidates $now 20 3
Assert-True ($first.Address -eq "AA:AA:AA:AA:AA:AA") "Dominant watch address selection failed."

$later = $now.AddSeconds(25)
1..4 | ForEach-Object { Add-TargetCandidateObservation $candidates "BB:BB:BB:BB:BB:BB" $later.AddMilliseconds($_) -60 }
$rotated = Get-PreferredTargetCandidate $candidates $later.AddSeconds(1) 20 3
Assert-True ($rotated.Address -eq "BB:BB:BB:BB:BB:BB") "Rotated watch address selection failed."

Write-Host "Testing interactive-wake edge and presence checks..."
Assert-True (Test-InteractiveWakeInputEdge 30 0.5 5 2) "Fresh input after a long idle period should trigger interactive wake."
Assert-True (-not (Test-InteractiveWakeInputEdge 1 0.2 5 2)) "Recent lock input must not trigger interactive wake."
Assert-True (-not (Test-InteractiveWakeInputEdge 30 4 5 2)) "Stale input must not trigger interactive wake."
Assert-True (Test-InteractiveWakeInputEdge 1.2 0.2 1 2) "Prompt input after lock suppression should trigger interactive wake."
Assert-True (-not (Test-InteractiveWakeInputEdge 0.5 0.2 1 2)) "Input without the configured prior-idle edge must not trigger interactive wake."
$presenceNow = [DateTime]::UtcNow
Assert-True (Test-RecentUtcTimestamp $presenceNow.AddSeconds(-2) $presenceNow 5) "Recent watch presence should be accepted."
Assert-True (-not (Test-RecentUtcTimestamp $presenceNow.AddSeconds(-10) $presenceNow 5)) "Stale watch presence must be rejected."
Assert-True (Test-PhonePresenceReady 2 2 $presenceNow.AddSeconds(-1) ([DateTime]::MinValue) $presenceNow 20) "Normal phone presence must accept the configured hit count."
Assert-True (-not (Test-PhonePresenceReady 1 2 $presenceNow.AddSeconds(-1) ([DateTime]::MinValue) $presenceNow 20)) "One ordinary phone hit must not bypass the configured hit count."
Assert-True (Test-PhonePresenceReady 1 2 $presenceNow.AddSeconds(-1) $presenceNow.AddSeconds(-1) $presenceNow 20) "One recent strong phone hit must enable the fast path."
Assert-True (-not (Test-PhonePresenceReady 1 2 $presenceNow.AddSeconds(-1) $presenceNow.AddSeconds(-21) $presenceNow 20)) "A stale strong phone hit must not enable the fast path."
Assert-True (Test-AutoUnlockTransientStatus 4) "Session-not-locked must be retried because LogonUI can still be starting."
Assert-True (Test-AutoUnlockTransientStatus 8) "Provider-unavailable must be retried."
Assert-True (-not (Test-AutoUnlockTransientStatus 3)) "A missing Broker configuration must remain a permanent rejection."
Assert-True ((1..4 | ForEach-Object { Get-AutoUnlockRetryDelayMilliseconds $_ }) -join "," -eq "250,500,1000,-1") "Auto-unlock retry delays are invalid."

Write-Host "Testing auto-unlock Broker authorization payload..."
$requestId = [Guid]::NewGuid()
$payload = New-AutoUnlockAuthorizationPayload `
    -SessionId 7 `
    -AuthorizationTtlMilliseconds 5000 `
    -LockCycleId ([uint64]123456) `
    -RequestId $requestId `
    -UserSid "S-1-5-21-1000"
Assert-True ($payload.GetType() -eq [byte[]]) "Broker payload must remain a byte array across the PowerShell function boundary."
$stream = [IO.MemoryStream]::new($payload, $false)
$reader = [IO.BinaryReader]::new($stream)
try {
    Assert-True ($reader.ReadInt32() -eq 7) "Broker payload session ID is invalid."
    Assert-True ($reader.ReadUInt32() -eq 5000) "Broker payload TTL is invalid."
    Assert-True ($reader.ReadUInt64() -eq 123456) "Broker payload lock-cycle ID is invalid."
    Assert-True (([Guid]::new($reader.ReadBytes(16))) -eq $requestId) "Broker payload request ID is invalid."
    $sidCharacters = $reader.ReadUInt32()
    $sid = [Text.Encoding]::Unicode.GetString($reader.ReadBytes([int]$sidCharacters * 2))
    Assert-True ($sid -eq "S-1-5-21-1000") "Broker payload SID is invalid."
    Assert-True ($reader.BaseStream.Position -eq $reader.BaseStream.Length) "Broker payload contains trailing data."
}
finally {
    $reader.Dispose()
    $stream.Dispose()
    [Array]::Clear($payload, 0, $payload.Length)
}

$expectedResponse = [byte[]](1, 2, 3, 4)
$responseStream = [IO.MemoryStream]::new($expectedResponse, $false)
try {
    $actualResponse = Read-PipeBytesWithTimeout -Pipe $responseStream -Count 4 -TimeoutMilliseconds 1000
    Assert-True ($actualResponse.GetType() -eq [byte[]]) "Timed pipe read must return a byte array."
    Assert-True (($actualResponse -join ",") -eq ($expectedResponse -join ",")) "Timed pipe read returned incorrect bytes."
}
finally {
    $responseStream.Dispose()
}

Write-Host "Compiling BLE bridge..."
$bridgeSource = Get-Content (Join-Path $scriptRoot "lib\BleBridge.ps1") -Raw -Encoding UTF8
Assert-True ($bridgeSource -match 'record\.TimestampUtc\s*=\s*args\.Timestamp\.UtcDateTime') "BLE records must preserve the advertisement event timestamp."
Assert-True ($bridgeSource -match 'public int Restart\(bool activeScanning, bool clearQueue\)') "BLE bridge must expose explicit watcher recovery."
Assert-True ($bridgeSource -match 'public int ClearQueue\(\)') "BLE bridge must expose queue clearing."
Assert-True ($mainSource -match '\$state\.InteractiveBleRecoveryRequested\s*=\s*\$true') "Interactive wake must request BLE recovery."
Assert-True ($mainSource -match '\$state\.LastArrivalTriggerUtc\s*=\s*\$now') "Arrival must mark its own display-wake cycle."
. (Join-Path $scriptRoot "lib\BleBridge.ps1")
Add-BleBridgeType
$bridge = [BleAdvertisementBridge]::new(0x004C, 1000)
try {
    Assert-True ($bridge.GetScanningMode() -eq "Passive") "BLE bridge should default to passive scanning."
    Assert-True ($bridge.GetQueueCount() -eq 0) "New BLE bridge queue should be empty."
    Assert-True ($bridge.ClearQueue() -eq 0) "Clearing a new BLE bridge queue should remove no records."
    $bridge.Start()
    Start-Sleep -Milliseconds 300
    1..4 | ForEach-Object {
        [void]$bridge.EnsureStarted($true)
        Start-Sleep -Milliseconds 300
    }
    Assert-True ($bridge.GetStatus() -eq "Started") "BLE watcher did not start."
    Assert-True ($bridge.GetScanningMode() -eq "Active") "BLE watcher did not switch to active scanning."
    Assert-True ($bridge.GetForcedRecoveryCount() -eq 0) "BLE watcher unexpectedly required forced recovery during a normal mode switch."
    $restartCountBeforeRecovery = $bridge.GetRestartCount()
    [void]$bridge.Restart($true, $true)
    Start-Sleep -Milliseconds 300
    Assert-True ($bridge.GetStatus() -eq "Started") "Explicit BLE recovery did not restart the watcher."
    Assert-True ($bridge.GetScanningMode() -eq "Active") "Explicit BLE recovery did not preserve active scanning."
    Assert-True ($bridge.GetRestartCount() -eq ($restartCountBeforeRecovery + 1)) "Explicit BLE recovery must count exactly one restart."
}
finally {
    $bridge.Dispose()
}

Write-Host "Compiling native wake/lock API..."
if (-not ("BleProximityWakeNative" -as [type])) {
    $nativeAssignment = $mainAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq "nativeCode"
    }, $true)
    $nativeExtent = $nativeAssignment.Right.Extent.Text
    $nativeCode = $nativeExtent -replace '^@"\r?\n', '' -replace '\r?\n"@$', ''
    Add-Type -ReferencedAssemblies "System.Windows.Forms" -TypeDefinition $nativeCode
}
Assert-True ($null -ne [BleProximityWakeNative].GetMethod("LockWorkStation")) "LockWorkStation API is missing."
Assert-True ($mainSource -match 'function Invoke-DisplayPowerRequest') "Display-only power request helper is missing."
Assert-True ($mainSource -match '(?s)else\s*\{\s*Invoke-DisplayPowerRequest -Config \$config\s*Write-Log "Credential Provider arrival path: wake-to-login simulation skipped\."') "Credential Provider arrival must request display power without wake input simulation."
Assert-True ([BleProximityWakeNative]::GetIdleSeconds() -ge 0) "GetIdleSeconds failed."
$acLineStatus = [BleProximityWakeNative]::GetAcLineStatus()
Assert-True (@(-1, 0, 1) -contains $acLineStatus) "GetAcLineStatus returned an invalid value."
$powerMonitor = [BlePowerNotificationWindow]::new()
try {
    Assert-True ($powerMonitor.DisplayState -ge -1 -and $powerMonitor.DisplayState -le 2) "Power monitor returned an invalid display state."
    Assert-True ($powerMonitor.DisplaySequence -ge 0) "Power monitor returned an invalid display sequence."
    Assert-True ($powerMonitor.ResumeSequence -ge 0) "Power monitor returned an invalid resume sequence."
}
finally {
    $powerMonitor.Dispose()
}

Write-Host "All BLE Proximity Wake tests passed."
