param(
    [string]$ConfigPath = "",
    [switch]$NoTray,
    [switch]$ForceWakeTest,
    [switch]$WakeNow,
    [switch]$VerboseMatches,
    [int]$RunSeconds = 0
)

$ErrorActionPreference = "Stop"

function Get-ScriptRoot {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

$scriptRoot = Get-ScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptRoot "config.json"
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $sample = Join-Path $scriptRoot "config.sample.json"
    if (Test-Path -LiteralPath $sample) {
        Copy-Item -LiteralPath $sample -Destination $ConfigPath
    }
    else {
        throw "Config file not found: $ConfigPath"
    }
}

$config = Get-Content -LiteralPath $ConfigPath -Encoding UTF8 -Raw | ConvertFrom-Json
$logDir = Join-Path $scriptRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}
$logFile = Join-Path $logDir ("ble-proximity-wake-{0}.log" -f (Get-Date -Format "yyyyMMdd"))
$pidFile = Join-Path $scriptRoot "ble-proximity-wake.pid"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Level, $Message
    Add-Content -LiteralPath $logFile -Encoding UTF8 -Value $line
    if ($NoTray) {
        Write-Host $line
    }
}

function Initialize-BleTypes {
    . (Join-Path $scriptRoot "lib\BleBridge.ps1")
    Add-BleBridgeType
}

function Format-BluetoothAddress {
    param([UInt64]$Address)
    $hex = "{0:X12}" -f $Address
    return (($hex -split "(.{2})" | Where-Object { $_ }) -join ":")
}

function Normalize-BluetoothAddress {
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) {
        return ""
    }
    return ($Address -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
}

function Test-HexPattern {
    param(
        [string]$Hex,
        [string]$Pattern
    )

    $normalizedHex = ($Hex -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
    $normalizedPattern = ($Pattern -replace "[^0-9A-Fa-f?]", "").ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedPattern) -or $normalizedHex.Length -lt $normalizedPattern.Length) {
        return $false
    }

    for ($i = 0; $i -lt $normalizedPattern.Length; $i++) {
        if ($normalizedPattern[$i] -ne '?' -and $normalizedPattern[$i] -ne $normalizedHex[$i]) {
            return $false
        }
    }
    return $true
}

function Test-AdvertisementMatch {
    param(
        $Record,
        $Config
    )

    $target = $Config.target
    $address = Normalize-BluetoothAddress $Record.Address
    $targetAddress = Normalize-BluetoothAddress $target.address
    if (-not [string]::IsNullOrWhiteSpace($targetAddress)) {
        return $address -eq $targetAddress
    }

    $nameContains = [string]$target.nameContains
    if (-not [string]::IsNullOrWhiteSpace($nameContains)) {
        $localName = [string]$Record.Name
        if (-not [string]::IsNullOrWhiteSpace($localName) -and $localName.IndexOf($nameContains, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    $serviceUuid = [string]$target.serviceUuid
    if (-not [string]::IsNullOrWhiteSpace($serviceUuid)) {
        foreach ($uuid in ([string]$Record.ServiceUuids -split ";")) {
            if ($uuid.Equals($serviceUuid, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }

    $prefix = [string]$target.manufacturerDataHexPrefix
    if (-not [string]::IsNullOrWhiteSpace($prefix)) {
        $normalizedPrefix = ($prefix -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
        foreach ($item in ([string]$Record.ManufacturerData -split ";")) {
            $hex = ($item -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
            if ($hex.StartsWith($normalizedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }

    $pattern = [string]$target.manufacturerDataHexPattern
    if (-not [string]::IsNullOrWhiteSpace($pattern)) {
        foreach ($item in ([string]$Record.ManufacturerData -split ";")) {
            if (Test-HexPattern -Hex $item -Pattern $pattern) {
                return $true
            }
        }
    }

    return $false
}

function Test-PhoneAdvertisementMatch {
    param(
        $Record,
        $Config
    )

    if ($null -eq $Config.phone -or $Config.phone.enabled -ne $true) {
        return $false
    }

    $phoneAddress = Normalize-BluetoothAddress ([string]$Config.phone.address)
    if (-not [string]::IsNullOrWhiteSpace($phoneAddress)) {
        return (Normalize-BluetoothAddress ([string]$Record.Address)) -eq $phoneAddress
    }

    $nameContains = [string]$Config.phone.nameContains
    if (-not [string]::IsNullOrWhiteSpace($nameContains)) {
        $localName = [string]$Record.Name
        return (-not [string]::IsNullOrWhiteSpace($localName) -and $localName.IndexOf($nameContains, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }

    return $false
}

function Add-TargetCandidateObservation {
    param(
        [hashtable]$Candidates,
        [string]$Address,
        [DateTime]$TimestampUtc,
        [int]$Rssi
    )

    $key = Normalize-BluetoothAddress $Address
    if ([string]::IsNullOrWhiteSpace($key)) {
        return
    }
    if (-not $Candidates.ContainsKey($key)) {
        $Candidates[$key] = [pscustomobject]@{
            Address = $Address
            Observations = [System.Collections.Generic.Queue[object]]::new()
        }
    }
    $Candidates[$key].Address = $Address
    $Candidates[$key].Observations.Enqueue([pscustomobject]@{
        TimestampUtc = $TimestampUtc
        Rssi = $Rssi
    })
}

function Get-PreferredTargetCandidate {
    param(
        [hashtable]$Candidates,
        [DateTime]$NowUtc,
        [int]$WindowSeconds,
        [int]$MinimumHits
    )

    $cutoff = $NowUtc.AddSeconds(-$WindowSeconds)
    $ranked = New-Object System.Collections.Generic.List[object]
    foreach ($key in @($Candidates.Keys)) {
        $entry = $Candidates[$key]
        while ($entry.Observations.Count -gt 0 -and ([DateTime]$entry.Observations.Peek().TimestampUtc) -lt $cutoff) {
            [void]$entry.Observations.Dequeue()
        }
        if ($entry.Observations.Count -eq 0) {
            $Candidates.Remove($key)
            continue
        }
        $items = @($entry.Observations.ToArray())
        $last = $items[$items.Count - 1]
        $maxRssi = [int](($items | Measure-Object -Property Rssi -Maximum).Maximum)
        $ranked.Add([pscustomobject]@{
            Address = [string]$entry.Address
            Count = [int]$items.Count
            LastSeenUtc = [DateTime]$last.TimestampUtc
            LastRssi = [int]$last.Rssi
            MaxRssi = $maxRssi
        })
    }

    $selected = @($ranked | Sort-Object @{ Expression = "Count"; Descending = $true }, @{ Expression = "LastSeenUtc"; Descending = $true }, @{ Expression = "MaxRssi"; Descending = $true } | Select-Object -First 1)
    if ($selected.Count -eq 0 -or $selected[0].Count -lt $MinimumHits) {
        return $null
    }
    return $selected[0]
}

$nativeCode = @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class BleProximityWakeNative
{
    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;

    public const int HWND_BROADCAST = 0xffff;
    public const int WM_SYSCOMMAND = 0x0112;
    public const int SC_MONITORPOWER = 0xF170;
    public const uint SMTO_ABORTIFHUNG = 0x0002;

    public const int INPUT_MOUSE = 0;
    public const int INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_SCANCODE = 0x0008;
    public const uint MOUSEEVENTF_MOVE = 0x0001;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private static ConsoleCtrlHandler consoleCtrlHandler;

    public delegate bool ConsoleCtrlHandler(uint ctrlType);

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public int type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion
    {
        [FieldOffset(0)]
        public KEYBDINPUT ki;
        [FieldOffset(0)]
        public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        int msg,
        IntPtr wParam,
        IntPtr lParam,
        uint fuFlags,
        uint uTimeout,
        out IntPtr lpdwResult);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LockWorkStation();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(ConsoleCtrlHandler handler, bool add);

    public static int GetLastWin32Error()
    {
        return Marshal.GetLastWin32Error();
    }

    public static double GetIdleSeconds()
    {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref info)) return -1;
        uint now = unchecked((uint)Environment.TickCount);
        return unchecked(now - info.dwTime) / 1000.0;
    }

    public static int GetAcLineStatus()
    {
        SYSTEM_POWER_STATUS status;
        if (!GetSystemPowerStatus(out status)) return -1;
        return status.ACLineStatus == 1 ? 1 : (status.ACLineStatus == 0 ? 0 : -1);
    }

    public static void RegisterConsoleCtrlHandler()
    {
        consoleCtrlHandler = delegate(uint ctrlType)
        {
            Application.Exit();
            return true;
        };
        SetConsoleCtrlHandler(consoleCtrlHandler, true);
    }

    public static void UnregisterConsoleCtrlHandler()
    {
        if (consoleCtrlHandler != null)
        {
            SetConsoleCtrlHandler(consoleCtrlHandler, false);
            consoleCtrlHandler = null;
        }
    }

    public static uint SendVirtualKey(ushort virtualKey)
    {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = virtualKey;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = virtualKey;
        inputs[1].U.ki.dwFlags = KEYEVENTF_KEYUP;
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    public static uint SendScanCode(ushort scanCode)
    {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki.wScan = scanCode;
        inputs[0].U.ki.dwFlags = KEYEVENTF_SCANCODE;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki.wScan = scanCode;
        inputs[1].U.ki.dwFlags = KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP;
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    public static uint MouseNudge()
    {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_MOUSE;
        inputs[0].U.mi.dx = 1;
        inputs[0].U.mi.dy = 0;
        inputs[0].U.mi.dwFlags = MOUSEEVENTF_MOVE;
        inputs[1].type = INPUT_MOUSE;
        inputs[1].U.mi.dx = -1;
        inputs[1].U.mi.dy = 0;
        inputs[1].U.mi.dwFlags = MOUSEEVENTF_MOVE;
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    public static uint MouseLeftClick()
    {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_MOUSE;
        inputs[0].U.mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
        inputs[1].type = INPUT_MOUSE;
        inputs[1].U.mi.dwFlags = MOUSEEVENTF_LEFTUP;
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void LegacyKey(byte virtualKey, byte scanCode)
    {
        keybd_event(virtualKey, scanCode, 0, UIntPtr.Zero);
        keybd_event(virtualKey, scanCode, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    public static void LegacyMouseNudge()
    {
        mouse_event(MOUSEEVENTF_MOVE, 1, 0, 0, UIntPtr.Zero);
        mouse_event(MOUSEEVENTF_MOVE, unchecked((uint)-1), 0, 0, UIntPtr.Zero);
    }

    public static void LegacyMouseLeftClick()
    {
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
    }
}

public sealed class BlePowerNotificationWindow : NativeWindow, IDisposable
{
    private const int WM_POWERBROADCAST = 0x0218;
    private const int PBT_APMSUSPEND = 0x0004;
    private const int PBT_APMRESUMESUSPEND = 0x0007;
    private const int PBT_APMRESUMEAUTOMATIC = 0x0012;
    private const int PBT_POWERSETTINGCHANGE = 0x8013;
    private const int DEVICE_NOTIFY_WINDOW_HANDLE = 0x00000000;
    private static readonly Guid ConsoleDisplayState = new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");

    private IntPtr notificationHandle;
    private int displayState = -1;
    private int displaySequence;
    private int resumeSequence;
    private int suspendSequence;
    private bool disposed;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr RegisterPowerSettingNotification(
        IntPtr recipient,
        ref Guid powerSettingGuid,
        int flags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterPowerSettingNotification(IntPtr handle);

    public BlePowerNotificationWindow()
    {
        CreateParams parameters = new CreateParams();
        parameters.Caption = "BleProximityWake.PowerNotifications";
        parameters.Parent = new IntPtr(-3); // HWND_MESSAGE
        CreateHandle(parameters);
        Guid setting = ConsoleDisplayState;
        notificationHandle = RegisterPowerSettingNotification(Handle, ref setting, DEVICE_NOTIFY_WINDOW_HANDLE);
    }

    public bool IsRegistered { get { return notificationHandle != IntPtr.Zero; } }
    public int DisplayState { get { return displayState; } }
    public int DisplaySequence { get { return displaySequence; } }
    public int ResumeSequence { get { return resumeSequence; } }
    public int SuspendSequence { get { return suspendSequence; } }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WM_POWERBROADCAST)
        {
            int powerEvent = message.WParam.ToInt32();
            if (powerEvent == PBT_POWERSETTINGCHANGE && message.LParam != IntPtr.Zero)
            {
                Guid setting = (Guid)Marshal.PtrToStructure(message.LParam, typeof(Guid));
                int dataLength = Marshal.ReadInt32(message.LParam, 16);
                if (setting == ConsoleDisplayState && dataLength >= 4)
                {
                    displayState = Marshal.ReadInt32(message.LParam, 20);
                    displaySequence++;
                }
            }
            else if (powerEvent == PBT_APMRESUMEAUTOMATIC || powerEvent == PBT_APMRESUMESUSPEND)
            {
                resumeSequence++;
            }
            else if (powerEvent == PBT_APMSUSPEND)
            {
                suspendSequence++;
            }
        }
        base.WndProc(ref message);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (notificationHandle != IntPtr.Zero)
        {
            UnregisterPowerSettingNotification(notificationHandle);
            notificationHandle = IntPtr.Zero;
        }
        DestroyHandle();
        GC.SuppressFinalize(this);
    }
}
"@

Add-Type -ReferencedAssemblies "System.Windows.Forms" -TypeDefinition $nativeCode

function Invoke-DisplayPowerRequest {
    param($Config)

    if ($Config.wake.enableExecutionState -eq $false) {
        return
    }

    $executionStateResult = [BleProximityWakeNative]::SetThreadExecutionState(
        [BleProximityWakeNative]::ES_DISPLAY_REQUIRED -bor
        [BleProximityWakeNative]::ES_SYSTEM_REQUIRED
    )
    $executionStateError = if ($executionStateResult -eq 0) { [BleProximityWakeNative]::GetLastWin32Error() } else { 0 }
    Write-Log "Display power requested. SetThreadExecutionState result=$executionStateResult LastError=$executionStateError"
}

function Invoke-WakeToLogin {
    param($Config)

    Write-Log "Wake requested."
    Invoke-DisplayPowerRequest -Config $Config

    if ($Config.wake.enableMonitorPowerMessage -ne $false) {
        $monitorTimeoutMilliseconds = 250
        if ($null -ne $Config.wake.monitorPowerMessageTimeoutMilliseconds) {
            $monitorTimeoutMilliseconds = [int]$Config.wake.monitorPowerMessageTimeoutMilliseconds
        }
        $monitorMessageResult = [IntPtr]::Zero
        $monitorResult = [BleProximityWakeNative]::SendMessageTimeout(
            [IntPtr][BleProximityWakeNative]::HWND_BROADCAST,
            [BleProximityWakeNative]::WM_SYSCOMMAND,
            [IntPtr][BleProximityWakeNative]::SC_MONITORPOWER,
            [IntPtr](-1),
            [BleProximityWakeNative]::SMTO_ABORTIFHUNG,
            [uint32]$monitorTimeoutMilliseconds,
            [ref]$monitorMessageResult
        )
        $monitorError = [BleProximityWakeNative]::GetLastWin32Error()
        Write-Log "Monitor power message timeout result=$monitorResult MessageResult=$monitorMessageResult LastError=$monitorError"
    }

    $keyName = [string]$Config.wake.key
    $virtualKey = 0x10
    $scanCode = 0x2A
    if ($keyName.Equals("Space", [StringComparison]::OrdinalIgnoreCase)) {
        $virtualKey = 0x20
        $scanCode = 0x39
    }
    elseif ($keyName.Equals("Enter", [StringComparison]::OrdinalIgnoreCase)) {
        $virtualKey = 0x0D
        $scanCode = 0x1C
    }

    if ($Config.wake.enableMouseNudge -ne $false) {
        $mouseResult = [BleProximityWakeNative]::MouseNudge()
        $mouseError = [BleProximityWakeNative]::GetLastWin32Error()
        Write-Log "Mouse nudge SendInput result=$mouseResult LastError=$mouseError"
        Start-Sleep -Milliseconds 40
    }

    if ($Config.wake.enableScanCodeKey -ne $false) {
        $scanResult = [BleProximityWakeNative]::SendScanCode([UInt16]$scanCode)
        $scanError = [BleProximityWakeNative]::GetLastWin32Error()
        Write-Log "ScanCode key SendInput result=$scanResult LastError=$scanError Key=$keyName ScanCode=$scanCode"
        Start-Sleep -Milliseconds 40
    }

    if ($Config.wake.enableVirtualKey -ne $false) {
        $keyResult = [BleProximityWakeNative]::SendVirtualKey([UInt16]$virtualKey)
        $keyError = [BleProximityWakeNative]::GetLastWin32Error()
        Write-Log "Virtual key SendInput result=$keyResult LastError=$keyError Key=$keyName VirtualKey=$virtualKey"
    }

    if ($Config.wake.enableLegacyInput -ne $false) {
        Start-Sleep -Milliseconds 40
        [BleProximityWakeNative]::LegacyMouseNudge()
        Write-Log "Legacy mouse nudge requested"
        Start-Sleep -Milliseconds 40
        [BleProximityWakeNative]::LegacyKey([Byte]$virtualKey, [Byte]$scanCode)
        Write-Log "Legacy key requested Key=$keyName VirtualKey=$virtualKey ScanCode=$scanCode"
    }

    if ($Config.wake.enableMouseClick -eq $true) {
        Start-Sleep -Milliseconds 40
        $clickResult = [BleProximityWakeNative]::MouseLeftClick()
        $clickError = [BleProximityWakeNative]::GetLastWin32Error()
        Write-Log "Mouse click SendInput result=$clickResult LastError=$clickError"
        if ($Config.wake.enableLegacyInput -ne $false) {
            Start-Sleep -Milliseconds 40
            [BleProximityWakeNative]::LegacyMouseLeftClick()
            Write-Log "Legacy mouse click requested"
        }
    }
}

function Invoke-AutoLock {
    $result = [BleProximityWakeNative]::LockWorkStation()
    $errorCode = if ($result) { 0 } else { [BleProximityWakeNative]::GetLastWin32Error() }
    Write-Log "Auto-lock requested. Result=$result LastError=$errorCode"
    return $result
}

function Test-LogonUiPresent {
    try {
        return $null -ne (Get-Process -Name LogonUI -ErrorAction SilentlyContinue | Select-Object -First 1)
    }
    catch {
        return $false
    }
}

function New-AutoUnlockAuthorizationPayload {
    param(
        [int]$SessionId,
        [uint32]$AuthorizationTtlMilliseconds,
        [uint64]$LockCycleId,
        [Guid]$RequestId,
        [string]$UserSid
    )

    if ($SessionId -lt 0 -or $AuthorizationTtlMilliseconds -lt 1000 -or
        $AuthorizationTtlMilliseconds -gt 10000 -or $LockCycleId -eq 0 -or
        $RequestId -eq [Guid]::Empty -or [string]::IsNullOrWhiteSpace($UserSid)) {
        throw "Invalid auto-unlock authorization payload values."
    }

    $sidBytes = [Text.Encoding]::Unicode.GetBytes($UserSid)
    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([int]$SessionId)
        $writer.Write([uint32]$AuthorizationTtlMilliseconds)
        $writer.Write([uint64]$LockCycleId)
        $writer.Write($RequestId.ToByteArray())
        $writer.Write([uint32]$UserSid.Length)
        $writer.Write($sidBytes)
        $writer.Flush()
        return ,$stream.ToArray()
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
        [Array]::Clear($sidBytes, 0, $sidBytes.Length)
    }
}

function Read-PipeBytesWithTimeout {
    param(
        [IO.Stream]$Pipe,
        [int]$Count,
        [int]$TimeoutMilliseconds
    )

    if ($Count -lt 0 -or $TimeoutMilliseconds -le 0) {
        throw "Invalid pipe read arguments."
    }

    $buffer = New-Object byte[] $Count
    $offset = 0
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($offset -lt $Count) {
        $remaining = $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds
        if ($remaining -le 0) {
            throw "Timed out waiting for the Broker response."
        }
        $readTask = $Pipe.ReadAsync($buffer, $offset, $Count - $offset)
        if (-not $readTask.Wait($remaining)) {
            throw "Timed out waiting for the Broker response."
        }
        $read = $readTask.Result
        if ($read -le 0) {
            throw "Broker closed the pipe before returning a complete response."
        }
        $offset += $read
    }
    return ,$buffer
}

function Request-AutoUnlockAuthorization {
    param(
        [string]$PipeName,
        [uint32]$AuthorizationTtlMilliseconds,
        [uint64]$LockCycleId,
        [int]$ResponseTimeoutMilliseconds
    )

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $identity.User.Value
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $requestId = [Guid]::NewGuid()
    $payload = New-AutoUnlockAuthorizationPayload `
        -SessionId $sessionId `
        -AuthorizationTtlMilliseconds $AuthorizationTtlMilliseconds `
        -LockCycleId $LockCycleId `
        -RequestId $requestId `
        -UserSid $sid

    $pipe = [IO.Pipes.NamedPipeClientStream]::new(
        ".",
        $PipeName,
        [IO.Pipes.PipeDirection]::InOut,
        [IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect(2000)
        $writer = [IO.BinaryWriter]::new($pipe, [Text.Encoding]::Unicode, $true)
        try {
            $writer.Write([uint32]0x42505742)
            $writer.Write([uint32]1)
            $writer.Write([uint32]1)
            $writer.Write([uint32]$payload.Length)
            $writer.Write($payload)
            $writer.Flush()

            $response = Read-PipeBytesWithTimeout `
                -Pipe $pipe `
                -Count 16 `
                -TimeoutMilliseconds $ResponseTimeoutMilliseconds
            $responseStream = [IO.MemoryStream]::new($response, $false)
            $reader = [IO.BinaryReader]::new($responseStream)
            try {
                $magic = $reader.ReadUInt32()
                $version = $reader.ReadUInt32()
                $status = $reader.ReadUInt32()
                $responseBytes = $reader.ReadUInt32()
            }
            finally {
                $reader.Dispose()
                $responseStream.Dispose()
                [Array]::Clear($response, 0, $response.Length)
            }
            if ($magic -ne 0x42505742 -or $version -ne 1 -or $responseBytes -ne 0) {
                throw "Broker returned an invalid protocol response."
            }
            return [pscustomobject]@{
                Accepted = ($status -eq 0)
                Status = $status
                RequestId = $requestId
            }
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $pipe.Dispose()
        [Array]::Clear($payload, 0, $payload.Length)
    }
}

function Test-InteractiveWakeInputEdge {
    param(
        [double]$PreviousIdleSeconds,
        [double]$CurrentIdleSeconds,
        [double]$MinimumPriorIdleSeconds,
        [double]$InputFreshSeconds
    )

    return (
        $PreviousIdleSeconds -ge $MinimumPriorIdleSeconds -and
        $CurrentIdleSeconds -ge 0 -and
        $CurrentIdleSeconds -le $InputFreshSeconds -and
        $CurrentIdleSeconds -lt $PreviousIdleSeconds
    )
}

function Test-RecentUtcTimestamp {
    param(
        [DateTime]$TimestampUtc,
        [DateTime]$NowUtc,
        [double]$MaximumAgeSeconds
    )

    if ($TimestampUtc -eq [DateTime]::MinValue) {
        return $false
    }
    $ageSeconds = ($NowUtc - $TimestampUtc).TotalSeconds
    return $ageSeconds -ge -2 -and $ageSeconds -le $MaximumAgeSeconds
}

function Test-PhonePresenceReady {
    param(
        [int]$MatchCount,
        [int]$RequiredHits,
        [DateTime]$LastSeenUtc,
        [DateTime]$StrongSignalSeenUtc,
        [DateTime]$NowUtc,
        [double]$PresenceTimeoutSeconds
    )

    $normalReady = $MatchCount -ge $RequiredHits -and
        (Test-RecentUtcTimestamp -TimestampUtc $LastSeenUtc -NowUtc $NowUtc -MaximumAgeSeconds $PresenceTimeoutSeconds)
    $strongSignalReady = Test-RecentUtcTimestamp `
        -TimestampUtc $StrongSignalSeenUtc `
        -NowUtc $NowUtc `
        -MaximumAgeSeconds $PresenceTimeoutSeconds
    return $normalReady -or $strongSignalReady
}

function Test-AutoUnlockTransientStatus {
    param([uint32]$Status)

    return @(4, 8, 10) -contains [int]$Status
}

function Get-AutoUnlockRetryDelayMilliseconds {
    param([int]$RetryNumber)

    $delays = @(250, 500, 1000)
    if ($RetryNumber -lt 1 -or $RetryNumber -gt $delays.Count) {
        return -1
    }
    return $delays[$RetryNumber - 1]
}

function Invoke-AutoUnlockAttempt {
    param(
        [hashtable]$State,
        [string]$Trigger,
        [bool]$NetworkReady,
        [bool]$PowerReady,
        [bool]$PhoneReady,
        [string]$PipeName,
        [int]$LoginPageDelayMilliseconds,
        [uint32]$AuthorizationTtlMilliseconds,
        [int]$ResponseTimeoutMilliseconds
    )

    $lockReady = [bool]$State.IsLocked -and [bool]$State.SessionKnown
    if ([bool]$State.AutoUnlockAttempted -or -not $lockReady -or -not $NetworkReady -or -not $PowerReady -or -not $PhoneReady) {
        $State.AutoUnlockLastStatus = "conditions-not-met"
        Write-Log ("Auto-unlock skipped. Trigger={0} Attempted={1} Locked={2} Known={3} NetworkReady={4} PowerReady={5} PhoneReady={6}" -f $Trigger, $State.AutoUnlockAttempted, $State.IsLocked, $State.SessionKnown, $NetworkReady, $PowerReady, $PhoneReady)
        return $false
    }

    if ([uint64]$State.LockCycleId -eq 0) {
        $State.LockCycleId = [uint64]([DateTime]::UtcNow.Ticks)
    }
    if ($LoginPageDelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $LoginPageDelayMilliseconds
    }

    try {
        $requestStartedUtc = [DateTime]::UtcNow
        $State.AutoUnlockAuthorizationStartedUtc = $requestStartedUtc
        $triggerDetectedUtc = [DateTime]$State.AutoUnlockTriggerDetectedUtc
        $triggerToRequestMilliseconds = if ($triggerDetectedUtc -eq [DateTime]::MinValue) { -1 } else { ($requestStartedUtc - $triggerDetectedUtc).TotalMilliseconds }
        Write-Log ("Auto-unlock authorization request starting. Trigger={0} Pipe={1} PayloadType=Byte[] ResponseTimeoutMs={2} TriggerToRequestMs={3:N0}" -f $Trigger, $PipeName, $ResponseTimeoutMilliseconds, $triggerToRequestMilliseconds)
        $authorization = Request-AutoUnlockAuthorization `
            -PipeName $PipeName `
            -AuthorizationTtlMilliseconds $AuthorizationTtlMilliseconds `
            -LockCycleId ([uint64]$State.LockCycleId) `
            -ResponseTimeoutMilliseconds $ResponseTimeoutMilliseconds
        if ($authorization.Accepted) {
            $acceptedUtc = [DateTime]::UtcNow
            $State.AutoUnlockAttempted = $true
            $State.AutoUnlockRetryCount = 0
            $State.AutoUnlockRetryAfterUtc = [DateTime]::MinValue
            $State.AutoUnlockRetryTrigger = ""
            $State.AutoUnlockLastStatus = "accepted:$Trigger"
            $State.AutoUnlockAuthorizationAcceptedUtc = $acceptedUtc
            $State.AutoUnlockLastRequestId = [string]$authorization.RequestId
        }
        elseif (Test-AutoUnlockTransientStatus -Status ([uint32]$authorization.Status)) {
            $retryNumber = [int]$State.AutoUnlockRetryCount + 1
            $retryDelay = Get-AutoUnlockRetryDelayMilliseconds -RetryNumber $retryNumber
            if ($retryDelay -ge 0) {
                $State.AutoUnlockRetryCount = $retryNumber
                $State.AutoUnlockRetryAfterUtc = [DateTime]::UtcNow.AddMilliseconds($retryDelay)
                $State.AutoUnlockRetryTrigger = $Trigger
                $State.AutoUnlockLastStatus = "retry:$($authorization.Status):$retryNumber"
            }
            else {
                $State.AutoUnlockAttempted = $true
                $State.AutoUnlockRetryAfterUtc = [DateTime]::MinValue
                $State.AutoUnlockRetryTrigger = ""
                $State.AutoUnlockLastStatus = "retry-exhausted:$($authorization.Status)"
            }
        }
        else {
            $State.AutoUnlockAttempted = $true
            $State.AutoUnlockRetryAfterUtc = [DateTime]::MinValue
            $State.AutoUnlockRetryTrigger = ""
            $State.AutoUnlockLastStatus = "rejected:$($authorization.Status)"
        }
        $responseUtc = [DateTime]::UtcNow
        $requestElapsedMilliseconds = ($responseUtc - $requestStartedUtc).TotalMilliseconds
        $triggerElapsedMilliseconds = if ($triggerDetectedUtc -eq [DateTime]::MinValue) { -1 } else { ($responseUtc - $triggerDetectedUtc).TotalMilliseconds }
        Write-Log ("Auto-unlock authorization. Trigger={0} Accepted={1} Status={2} RequestId={3} LockCycleId={4} RequestElapsedMs={5:N0} TriggerElapsedMs={6:N0}" -f $Trigger, $authorization.Accepted, $authorization.Status, $authorization.RequestId, $State.LockCycleId, $requestElapsedMilliseconds, $triggerElapsedMilliseconds)
    }
    catch {
        $retryNumber = [int]$State.AutoUnlockRetryCount + 1
        $retryDelay = Get-AutoUnlockRetryDelayMilliseconds -RetryNumber $retryNumber
        if ($retryDelay -ge 0) {
            $State.AutoUnlockRetryCount = $retryNumber
            $State.AutoUnlockRetryAfterUtc = [DateTime]::UtcNow.AddMilliseconds($retryDelay)
            $State.AutoUnlockRetryTrigger = $Trigger
            $State.AutoUnlockLastStatus = "retry:error:$retryNumber"
            Write-Log ("Auto-unlock authorization failed; retry scheduled. Trigger={0} Retry={1} DelayMs={2} Error={3}" -f $Trigger, $retryNumber, $retryDelay, $_.Exception.Message) "WARN"
        }
        else {
            $State.AutoUnlockAttempted = $true
            $State.AutoUnlockRetryAfterUtc = [DateTime]::MinValue
            $State.AutoUnlockRetryTrigger = ""
            $State.AutoUnlockLastStatus = "retry-exhausted:error"
            Write-Log ("Auto-unlock authorization failed; retries exhausted. Trigger={0} Error={1}" -f $Trigger, $_.Exception.Message) "WARN"
        }
    }
    return $true
}

function Convert-ToStringArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [System.Array]) {
        return @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }
    return @($text)
}

function Test-AnyWildcardMatch {
    param(
        [string[]]$Values,
        [string[]]$Patterns
    )

    foreach ($value in $Values) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        foreach ($pattern in $Patterns) {
            if ([string]::IsNullOrWhiteSpace($pattern)) {
                continue
            }
            if ($value -like $pattern) {
                return $true
            }
        }
    }
    return $false
}

function Get-WifiSsid {
    try {
        $output = & netsh.exe wlan show interfaces 2>$null
        foreach ($line in $output) {
            if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$' -and $line -notmatch 'BSSID') {
                return $Matches[1].Trim()
            }
        }
    }
    catch {
        return ""
    }
    return ""
}

function Get-NetworkContext {
    $profiles = @()
    try {
        $profiles = @(Get-NetConnectionProfile -ErrorAction Stop)
    }
    catch {
        $profiles = @()
    }

    return [pscustomobject]@{
        ProfileNames = @($profiles | ForEach-Object { [string]$_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        InterfaceAliases = @($profiles | ForEach-Object { [string]$_.InterfaceAlias } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        DnsSuffixes = @($profiles | ForEach-Object { [string]$_.DnsSuffix } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Ssid = Get-WifiSsid
    }
}

function Test-NetworkAllowed {
    param($Config)

    if ($null -eq $Config.network -or $Config.network.enabled -ne $true) {
        return [pscustomobject]@{
            Allowed = $true
            Reason = "network filter disabled"
        }
    }

    $allowedProfileNames = Convert-ToStringArray $Config.network.allowedProfileNames
    $allowedSsids = Convert-ToStringArray $Config.network.allowedSsids
    $allowedDnsSuffixes = Convert-ToStringArray $Config.network.allowedDnsSuffixes

    if (($allowedProfileNames.Count + $allowedSsids.Count + $allowedDnsSuffixes.Count) -eq 0) {
        return [pscustomobject]@{
            Allowed = $false
            Reason = "network filter enabled but no allow rules configured"
        }
    }

    $context = Get-NetworkContext
    if (Test-AnyWildcardMatch -Values $context.ProfileNames -Patterns $allowedProfileNames) {
        return [pscustomobject]@{ Allowed = $true; Reason = "profile match: $($context.ProfileNames -join '|')" }
    }
    if (Test-AnyWildcardMatch -Values @($context.Ssid) -Patterns $allowedSsids) {
        return [pscustomobject]@{ Allowed = $true; Reason = "ssid match: $($context.Ssid)" }
    }
    if (Test-AnyWildcardMatch -Values $context.DnsSuffixes -Patterns $allowedDnsSuffixes) {
        return [pscustomobject]@{ Allowed = $true; Reason = "dns suffix match: $($context.DnsSuffixes -join '|')" }
    }

    return [pscustomobject]@{
        Allowed = $false
        Reason = "no network match; profiles=$($context.ProfileNames -join '|'); ssid=$($context.Ssid); interfaces=$($context.InterfaceAliases -join '|'); dns=$($context.DnsSuffixes -join '|')"
    }
}

function Set-ConditionalPowerHold {
    param(
        [hashtable]$State,
        [bool]$ShouldHold
    )

    if ($ShouldHold -and -not [bool]$State.PowerHoldActive) {
        $result = [BleProximityWakeNative]::SetThreadExecutionState(
            [BleProximityWakeNative]::ES_CONTINUOUS -bor
            [BleProximityWakeNative]::ES_SYSTEM_REQUIRED
        )
        $State.PowerHoldActive = $true
        Write-Log "Power hold enabled while locked on allowed network. SetThreadExecutionState result=$result"
    }
    elseif ((-not $ShouldHold) -and [bool]$State.PowerHoldActive) {
        $result = [BleProximityWakeNative]::SetThreadExecutionState([BleProximityWakeNative]::ES_CONTINUOUS)
        $State.PowerHoldActive = $false
        Write-Log "Power hold released. SetThreadExecutionState result=$result"
    }
}

if ($WakeNow) {
    Invoke-WakeToLogin -Config $config
    return
}

$createdNewInstance = $false
$instanceMutex = New-Object System.Threading.Mutex($true, "Local\BleProximityWake.UserSession", [ref]$createdNewInstance)
if (-not $createdNewInstance) {
    Write-Log "Another BLE Proximity Wake instance is already running; exiting duplicate start."
    $instanceMutex.Dispose()
    return
}

Initialize-BleTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$state = [hashtable]::Synchronized(@{
    IsLocked = $false
    SessionKnown = $false
    LastMatchedUtc = [DateTime]::MinValue
    MatchCount = 0
    LastMatchName = ""
    LastMatchAddress = ""
    LastMatchRssi = -999
    LastMatchFastPath = $false
    PreferredTargetAddress = ""
    PreferredTargetLastSeenUtc = [DateTime]::MinValue
    PreferredTargetHits = 0
    LockedTargetAddress = ""
    LastTriggerUtc = [DateTime]::MinValue
    LastHeartbeatUtc = [DateTime]::MinValue
    LastNetworkCheckUtc = [DateTime]::MinValue
    NetworkAllowed = $true
    NetworkReason = "not checked"
    LastPhoneSeenUtc = [DateTime]::MinValue
    PhoneMatchCount = 0
    PhoneAllowed = $false
    LastPhoneAddress = ""
    LastPhoneRssi = -999
    PhoneFirstHitUtc = [DateTime]::MinValue
    PhoneStrongSignalSeenUtc = [DateTime]::MinValue
    AutoLockArmed = $false
    AutoLockWatchAddress = ""
    LastAutoLockWatchSeenUtc = [DateTime]::MinValue
    AutoLockDepartureAgeSeconds = -1
    LastAutoLockAttemptUtc = [DateTime]::MinValue
    LastUserIdleSeconds = -1
    AutoUnlockAttempted = $false
    AutoUnlockRetryCount = 0
    AutoUnlockRetryAfterUtc = [DateTime]::MinValue
    AutoUnlockRetryTrigger = ""
    AutoUnlockLastStatus = "disabled"
    AutoUnlockTriggerDetectedUtc = [DateTime]::MinValue
    AutoUnlockAuthorizationStartedUtc = [DateTime]::MinValue
    AutoUnlockAuthorizationAcceptedUtc = [DateTime]::MinValue
    AutoUnlockLastRequestId = ""
    PendingSessionUnlockTimingLog = $false
    SessionUnlockElapsedMilliseconds = -1
    LockCycleId = [uint64]0
    LockStartedUtc = [DateTime]::MinValue
    PreviousUserIdleSeconds = -1
    DisplayWasOffSinceLock = $false
    LastDisplayState = -1
    LastDisplaySequence = 0
    LastDisplayWakeUtc = [DateTime]::MinValue
    LastResumeSequence = 0
    LastResumeUtc = [DateTime]::MinValue
    ResumePresenceRequired = $false
    LastPostResumeWatchSeenUtc = [DateTime]::MinValue
    LastPostResumePhoneSeenUtc = [DateTime]::MinValue
    InteractiveWakePending = $false
    InteractiveWakeDetectedUtc = [DateTime]::MinValue
    InteractiveWakeDeadlineUtc = [DateTime]::MinValue
    InteractiveBleRecoveryRequested = $false
    InteractiveBleRecoveryActive = $false
    InteractiveBleRecoveryUtc = [DateTime]::MinValue
    InteractiveBleRecoveryReason = ""
    LastArrivalTriggerUtc = [DateTime]::MinValue
    IgnoreInteractiveInputUntilUtc = [DateTime]::MinValue
    DroppedStaleAdvertisements = 0
    WatcherStatus = "Created"
    WatcherMode = "Passive"
    WatcherLastStopError = ""
    WatcherRestartCount = 0
    WatcherForcedRecoveryCount = 0
    LastWatcherRestartUtc = [DateTime]::MinValue
    WatcherQueueCount = 0
    WatcherDroppedQueueRecords = 0
    PowerHoldActive = $false
    DetectionPaused = $false
    RuntimeWakeEnabled = $true
    RuntimeAutoUnlockEnabled = $false
    RuntimeAutoLockEnabled = $false
    WasFarSinceLastTrigger = $true
    LastSessionReason = ""
    LastStatus = "Starting"
})

$rssiThreshold = [int]$config.proximity.rssiThreshold
$learnedAddressRssiThreshold = $rssiThreshold
if ($null -ne $config.proximity.learnedAddressRssiThreshold) {
    $learnedAddressRssiThreshold = [int]$config.proximity.learnedAddressRssiThreshold
}
$hitWindowSeconds = [int]$config.proximity.hitWindowSeconds
$hitCount = [int]$config.proximity.hitCount
$lostSeconds = [int]$config.proximity.lostSeconds
$cooldownSeconds = [int]$config.proximity.cooldownSeconds
$addressLearningWindowSeconds = 20
$addressLearningMinimumHits = 3
if ($null -ne $config.proximity.addressLearningWindowSeconds) { $addressLearningWindowSeconds = [int]$config.proximity.addressLearningWindowSeconds }
if ($null -ne $config.proximity.addressLearningMinimumHits) { $addressLearningMinimumHits = [int]$config.proximity.addressLearningMinimumHits }
$heartbeatSeconds = 10
if ($null -ne $config.diagnostics.heartbeatSeconds) {
    $heartbeatSeconds = [int]$config.diagnostics.heartbeatSeconds
}
$maxAdvertisementAgeSeconds = 5
$activeScanWhenLocked = $true
$bleSamplingIntervalMilliseconds = 1000
$lockedPollIntervalMilliseconds = 250
$unlockedPollIntervalMilliseconds = 1000
if ($null -ne $config.diagnostics.maxAdvertisementAgeSeconds) { $maxAdvertisementAgeSeconds = [int]$config.diagnostics.maxAdvertisementAgeSeconds }
if ($null -ne $config.diagnostics.activeScanWhenLocked) { $activeScanWhenLocked = [bool]$config.diagnostics.activeScanWhenLocked }
if ($null -ne $config.diagnostics.bleSamplingIntervalMilliseconds) { $bleSamplingIntervalMilliseconds = [int]$config.diagnostics.bleSamplingIntervalMilliseconds }
if ($null -ne $config.diagnostics.lockedPollIntervalMilliseconds) { $lockedPollIntervalMilliseconds = [int]$config.diagnostics.lockedPollIntervalMilliseconds }
if ($null -ne $config.diagnostics.unlockedPollIntervalMilliseconds) { $unlockedPollIntervalMilliseconds = [int]$config.diagnostics.unlockedPollIntervalMilliseconds }
$networkCheckIntervalSeconds = 15
if ($null -ne $config.network -and $null -ne $config.network.checkIntervalSeconds) {
    $networkCheckIntervalSeconds = [int]$config.network.checkIntervalSeconds
}
$networkFilterEnabled = ($null -ne $config.network -and $config.network.enabled -eq $true)
$phoneFilterEnabled = ($null -ne $config.phone -and $config.phone.enabled -eq $true)
$phoneRssiThreshold = -75
$phoneStrongRssiSingleHitThreshold = -60
$phoneHitCount = 2
$phoneHitWindowSeconds = 10
$phonePresenceTimeoutSeconds = 20
if ($phoneFilterEnabled) {
    if ($null -ne $config.phone.rssiThreshold) { $phoneRssiThreshold = [int]$config.phone.rssiThreshold }
    if ($null -ne $config.phone.strongRssiSingleHitThreshold) { $phoneStrongRssiSingleHitThreshold = [int]$config.phone.strongRssiSingleHitThreshold }
    if ($null -ne $config.phone.hitCount) { $phoneHitCount = [int]$config.phone.hitCount }
    if ($null -ne $config.phone.hitWindowSeconds) { $phoneHitWindowSeconds = [int]$config.phone.hitWindowSeconds }
    if ($null -ne $config.phone.presenceTimeoutSeconds) { $phonePresenceTimeoutSeconds = [int]$config.phone.presenceTimeoutSeconds }
}
$autoLockEnabled = ($null -ne $config.autoLock -and $config.autoLock.enabled -eq $true)
$autoLockAbsenceSeconds = 45
$autoLockRequireWatchAbsent = $true
$autoLockRequirePhoneAbsent = $true
$autoLockRequireAllowedNetwork = $true
$autoLockMinimumUserIdleSeconds = 30
$autoLockRetrySeconds = 10
if ($autoLockEnabled) {
    if ($null -ne $config.autoLock.absenceSeconds) { $autoLockAbsenceSeconds = [int]$config.autoLock.absenceSeconds }
    if ($null -ne $config.autoLock.requireWatchAbsent) { $autoLockRequireWatchAbsent = [bool]$config.autoLock.requireWatchAbsent }
    if ($null -ne $config.autoLock.requirePhoneAbsent) { $autoLockRequirePhoneAbsent = [bool]$config.autoLock.requirePhoneAbsent }
    if ($null -ne $config.autoLock.requireAllowedNetwork) { $autoLockRequireAllowedNetwork = [bool]$config.autoLock.requireAllowedNetwork }
    if ($null -ne $config.autoLock.minimumUserIdleSeconds) { $autoLockMinimumUserIdleSeconds = [int]$config.autoLock.minimumUserIdleSeconds }
    if ($null -ne $config.autoLock.retrySeconds) { $autoLockRetrySeconds = [int]$config.autoLock.retrySeconds }
    if (-not $autoLockRequireWatchAbsent -and -not $autoLockRequirePhoneAbsent) {
        throw "autoLock requires at least one departure signal."
    }
    if ($autoLockRequirePhoneAbsent -and -not $phoneFilterEnabled) {
        throw "autoLock.requirePhoneAbsent requires phone.enabled=true."
    }
}

function Update-NetworkAllowedState {
    param(
        [hashtable]$State,
        $Config,
        [DateTime]$NowUtc
    )

    $networkCheck = Test-NetworkAllowed -Config $Config
    $State.LastNetworkCheckUtc = $NowUtc
    $State.NetworkAllowed = [bool]$networkCheck.Allowed
    $State.NetworkReason = [string]$networkCheck.Reason
    return [bool]$networkCheck.Allowed
}

function Get-NetworkDisplayName {
    param([string]$Reason)

    if ([string]::IsNullOrWhiteSpace($Reason)) { return "unknown network" }
    if ($Reason -match '^ssid match:\s*(.+)$') { return $Matches[1].Trim() }
    if ($Reason -match '^profile match:\s*(.+)$') { return (($Matches[1] -split '\|')[0]).Trim() }
    if ($Reason -match '(?:^|;)\s*ssid=([^;]+)') {
        $ssid = $Matches[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($ssid)) { return $ssid }
    }
    if ($Reason -match '(?:^|;)\s*profiles=([^;]+)') {
        $profile = (($Matches[1] -split '\|')[0]).Trim()
        if (-not [string]::IsNullOrWhiteSpace($profile)) { return $profile }
    }
    if ($Reason -eq "network filter disabled") { return "any network" }
    return "unknown network"
}

function Reset-DeviceDetectionState {
    param(
        [hashtable]$State,
        [hashtable]$Candidates
    )

    $Candidates.Clear()
    $State.LastMatchedUtc = [DateTime]::MinValue
    $State.MatchCount = 0
    $State.LastMatchName = ""
    $State.LastMatchAddress = ""
    $State.LastMatchRssi = -999
    $State.LastMatchFastPath = $false
    $State.PreferredTargetAddress = ""
    $State.PreferredTargetLastSeenUtc = [DateTime]::MinValue
    $State.PreferredTargetHits = 0
    $State.LastPhoneSeenUtc = [DateTime]::MinValue
    $State.PhoneMatchCount = 0
    $State.PhoneAllowed = $false
    $State.LastPhoneAddress = ""
    $State.LastPhoneRssi = -999
    $State.PhoneFirstHitUtc = [DateTime]::MinValue
    $State.PhoneStrongSignalSeenUtc = [DateTime]::MinValue
    $State.AutoLockArmed = $false
    $State.AutoLockWatchAddress = ""
    $State.LastAutoLockWatchSeenUtc = [DateTime]::MinValue
    $State.AutoLockDepartureAgeSeconds = -1
    $State.LastAutoLockAttemptUtc = [DateTime]::MinValue
    $State.LastPostResumeWatchSeenUtc = [DateTime]::MinValue
    $State.LastPostResumePhoneSeenUtc = [DateTime]::MinValue
    $State.WasFarSinceLastTrigger = $true
}

function Start-InteractiveBleRecovery {
    param(
        [hashtable]$State,
        $Bridge,
        [DateTime]$NowUtc,
        [string]$Reason
    )

    if ([bool]$State.InteractiveBleRecoveryActive) {
        return $false
    }

    $State.InteractiveBleRecoveryRequested = $false
    $State.InteractiveBleRecoveryActive = $true
    $State.InteractiveBleRecoveryUtc = $NowUtc
    $State.InteractiveBleRecoveryReason = $Reason
    $State.LastResumeUtc = $NowUtc
    $State.ResumePresenceRequired = $true
    $State.LastPostResumeWatchSeenUtc = [DateTime]::MinValue
    $State.LastPostResumePhoneSeenUtc = [DateTime]::MinValue
    $State.PhoneMatchCount = 0
    $State.LastPhoneSeenUtc = [DateTime]::MinValue
    $State.PhoneFirstHitUtc = [DateTime]::MinValue
    $State.PhoneStrongSignalSeenUtc = [DateTime]::MinValue

    try {
        $cleared = $Bridge.Restart($true, $true)
        Write-Log ("Interactive BLE recovery started. Reason={0} ClearedQueue={1} Mode={2} RestartCount={3}" -f $Reason, $cleared, $Bridge.GetScanningMode(), $Bridge.GetRestartCount())
        return $true
    }
    catch {
        $State.InteractiveBleRecoveryActive = $false
        $State.InteractiveBleRecoveryRequested = $true
        Write-Log ("Interactive BLE recovery failed. Reason={0} Error={1}" -f $Reason, $_.Exception.Message) "WARN"
        return $false
    }
}
$autoUnlockEnabled = ($null -ne $config.autoUnlock -and $config.autoUnlock.enabled -eq $true)
$autoUnlockPipeName = "BleProximityWake.UnlockAgent"
$autoUnlockLoginPageDelayMilliseconds = 0
$autoUnlockAuthorizationTtlMilliseconds = 5000
$autoUnlockResponseTimeoutMilliseconds = 3000
$autoUnlockRequireAllowedNetwork = $true
$autoUnlockRequireAcPower = $true
$autoUnlockRequirePhonePresence = $true
$autoUnlockTriggerOnArrival = $true
$autoUnlockInvokeWakeToLoginOnArrival = $false
$autoUnlockTriggerOnInteractiveWake = $false
$interactiveWakeMinimumPriorIdleSeconds = 1
$interactiveWakeInputFreshSeconds = 2
$interactiveWakeMaxWatchAgeSeconds = 5
$interactiveWakeConfirmationMilliseconds = 6000
$interactiveWakeAllowIdleFallback = $true
$interactiveWakeLoginPageDelayMilliseconds = 0
if ($autoUnlockEnabled) {
    if (-not [string]::IsNullOrWhiteSpace([string]$config.autoUnlock.brokerPipeName) -and
        -not [string]::Equals(
            [string]$config.autoUnlock.brokerPipeName,
            $autoUnlockPipeName,
            [StringComparison]::Ordinal)) {
        throw "autoUnlock.brokerPipeName is a fixed internal protocol name and cannot be changed."
    }
    if ($null -ne $config.autoUnlock.loginPageDelayMilliseconds) { $autoUnlockLoginPageDelayMilliseconds = [int]$config.autoUnlock.loginPageDelayMilliseconds }
    if ($null -ne $config.autoUnlock.authorizationTtlMilliseconds) { $autoUnlockAuthorizationTtlMilliseconds = [int]$config.autoUnlock.authorizationTtlMilliseconds }
    if ($null -ne $config.autoUnlock.brokerResponseTimeoutMilliseconds) { $autoUnlockResponseTimeoutMilliseconds = [int]$config.autoUnlock.brokerResponseTimeoutMilliseconds }
    if ($null -ne $config.autoUnlock.requireAllowedNetwork) { $autoUnlockRequireAllowedNetwork = [bool]$config.autoUnlock.requireAllowedNetwork }
    if ($null -ne $config.autoUnlock.requireAcPower) { $autoUnlockRequireAcPower = [bool]$config.autoUnlock.requireAcPower }
    if ($null -ne $config.autoUnlock.requirePhonePresence) { $autoUnlockRequirePhonePresence = [bool]$config.autoUnlock.requirePhonePresence }
    if ($null -ne $config.autoUnlock.triggerOnArrival) { $autoUnlockTriggerOnArrival = [bool]$config.autoUnlock.triggerOnArrival }
    if ($null -ne $config.autoUnlock.invokeWakeToLoginOnArrival) { $autoUnlockInvokeWakeToLoginOnArrival = [bool]$config.autoUnlock.invokeWakeToLoginOnArrival }
    if ($null -ne $config.autoUnlock.triggerOnInteractiveWake) { $autoUnlockTriggerOnInteractiveWake = [bool]$config.autoUnlock.triggerOnInteractiveWake }
    if ($null -ne $config.autoUnlock.interactiveWakeMinimumPriorIdleSeconds) { $interactiveWakeMinimumPriorIdleSeconds = [double]$config.autoUnlock.interactiveWakeMinimumPriorIdleSeconds }
    if ($null -ne $config.autoUnlock.interactiveWakeInputFreshSeconds) { $interactiveWakeInputFreshSeconds = [double]$config.autoUnlock.interactiveWakeInputFreshSeconds }
    if ($null -ne $config.autoUnlock.interactiveWakeMaxWatchAgeSeconds) { $interactiveWakeMaxWatchAgeSeconds = [double]$config.autoUnlock.interactiveWakeMaxWatchAgeSeconds }
    if ($null -ne $config.autoUnlock.interactiveWakeConfirmationMilliseconds) { $interactiveWakeConfirmationMilliseconds = [int]$config.autoUnlock.interactiveWakeConfirmationMilliseconds }
    if ($null -ne $config.autoUnlock.interactiveWakeAllowIdleFallback) { $interactiveWakeAllowIdleFallback = [bool]$config.autoUnlock.interactiveWakeAllowIdleFallback }
    if ($null -ne $config.autoUnlock.interactiveWakeLoginPageDelayMilliseconds) { $interactiveWakeLoginPageDelayMilliseconds = [int]$config.autoUnlock.interactiveWakeLoginPageDelayMilliseconds }
    if ($autoUnlockLoginPageDelayMilliseconds -lt 0 -or $autoUnlockLoginPageDelayMilliseconds -gt 5000) { throw "autoUnlock.loginPageDelayMilliseconds must be between 0 and 5000." }
    if ($autoUnlockAuthorizationTtlMilliseconds -lt 1000 -or $autoUnlockAuthorizationTtlMilliseconds -gt 10000) { throw "autoUnlock.authorizationTtlMilliseconds must be between 1000 and 10000." }
    if ($autoUnlockResponseTimeoutMilliseconds -lt 500 -or $autoUnlockResponseTimeoutMilliseconds -gt 10000) { throw "autoUnlock.brokerResponseTimeoutMilliseconds must be between 500 and 10000." }
    if (-not $autoUnlockTriggerOnArrival -and -not $autoUnlockTriggerOnInteractiveWake) { throw "autoUnlock requires at least one trigger mode." }
    if ($interactiveWakeMinimumPriorIdleSeconds -lt 1 -or $interactiveWakeMinimumPriorIdleSeconds -gt 3600) { throw "autoUnlock.interactiveWakeMinimumPriorIdleSeconds must be between 1 and 3600." }
    if ($interactiveWakeInputFreshSeconds -le 0 -or $interactiveWakeInputFreshSeconds -gt 10) { throw "autoUnlock.interactiveWakeInputFreshSeconds must be greater than zero and at most 10." }
    if ($interactiveWakeMaxWatchAgeSeconds -le 0 -or $interactiveWakeMaxWatchAgeSeconds -gt 30) { throw "autoUnlock.interactiveWakeMaxWatchAgeSeconds must be greater than zero and at most 30." }
    if ($interactiveWakeConfirmationMilliseconds -lt 500 -or $interactiveWakeConfirmationMilliseconds -gt 15000) { throw "autoUnlock.interactiveWakeConfirmationMilliseconds must be between 500 and 15000." }
    if ($interactiveWakeLoginPageDelayMilliseconds -lt 0 -or $interactiveWakeLoginPageDelayMilliseconds -gt 5000) { throw "autoUnlock.interactiveWakeLoginPageDelayMilliseconds must be between 0 and 5000." }
    if ($autoUnlockRequireAllowedNetwork -and -not $networkFilterEnabled) { throw "autoUnlock.requireAllowedNetwork requires network.enabled=true." }
    if ($autoUnlockRequirePhonePresence -and -not $phoneFilterEnabled) { throw "autoUnlock.requirePhonePresence requires phone.enabled=true." }
}
$state.RuntimeAutoUnlockEnabled = $autoUnlockEnabled
$state.RuntimeAutoLockEnabled = $autoLockEnabled
$positiveSettings = @{
    "proximity.hitWindowSeconds" = $hitWindowSeconds
    "proximity.hitCount" = $hitCount
    "proximity.lostSeconds" = $lostSeconds
    "proximity.cooldownSeconds" = $cooldownSeconds
    "proximity.addressLearningWindowSeconds" = $addressLearningWindowSeconds
    "proximity.addressLearningMinimumHits" = $addressLearningMinimumHits
    "diagnostics.maxAdvertisementAgeSeconds" = $maxAdvertisementAgeSeconds
    "diagnostics.bleSamplingIntervalMilliseconds" = $bleSamplingIntervalMilliseconds
    "diagnostics.lockedPollIntervalMilliseconds" = $lockedPollIntervalMilliseconds
    "diagnostics.unlockedPollIntervalMilliseconds" = $unlockedPollIntervalMilliseconds
    "phone.hitCount" = $phoneHitCount
    "phone.hitWindowSeconds" = $phoneHitWindowSeconds
    "phone.presenceTimeoutSeconds" = $phonePresenceTimeoutSeconds
}
if ($null -ne $config.wake.monitorPowerMessageTimeoutMilliseconds -and [int]$config.wake.monitorPowerMessageTimeoutMilliseconds -le 0) {
    throw "wake.monitorPowerMessageTimeoutMilliseconds must be greater than zero."
}
if ($autoLockEnabled) {
    $positiveSettings["autoLock.absenceSeconds"] = $autoLockAbsenceSeconds
    $positiveSettings["autoLock.retrySeconds"] = $autoLockRetrySeconds
}
foreach ($setting in $positiveSettings.GetEnumerator()) {
    if ([int]$setting.Value -le 0) { throw "$($setting.Key) must be greater than zero." }
}
if ($autoLockMinimumUserIdleSeconds -lt 0) { throw "autoLock.minimumUserIdleSeconds cannot be negative." }
foreach ($rssiSetting in @{
    "proximity.rssiThreshold" = $rssiThreshold
    "proximity.learnedAddressRssiThreshold" = $learnedAddressRssiThreshold
    "phone.rssiThreshold" = $phoneRssiThreshold
    "phone.strongRssiSingleHitThreshold" = $phoneStrongRssiSingleHitThreshold
}.GetEnumerator()) {
    if ([int]$rssiSetting.Value -lt -127 -or [int]$rssiSetting.Value -gt 0) {
        throw "$($rssiSetting.Key) must be between -127 and 0 dBm."
    }
}
$powerHoldMode = "AlwaysOnAc"
if ($null -ne $config.power -and -not [string]::IsNullOrWhiteSpace([string]$config.power.holdMode)) {
    $powerHoldMode = [string]$config.power.holdMode
}
elseif ($null -ne $config.power -and $null -ne $config.power.preventSleepWhenLockedOnAllowedNetwork) {
    $powerHoldMode = if ([bool]$config.power.preventSleepWhenLockedOnAllowedNetwork) { "AlwaysOnAc" } else { "Disabled" }
}
if ($phoneFilterEnabled -and $phoneStrongRssiSingleHitThreshold -lt $phoneRssiThreshold) {
    throw "phone.strongRssiSingleHitThreshold must be greater than or equal to phone.rssiThreshold."
}
$normalizedPowerHoldMode = $powerHoldMode.ToLowerInvariant()
switch ($normalizedPowerHoldMode) {
    "disabled" { $powerHoldMode = "Disabled" }
    "timedonac" { $powerHoldMode = "TimedOnAc" }
    "alwaysonac" { $powerHoldMode = "AlwaysOnAc" }
    default { throw "power.holdMode must be Disabled, TimedOnAc, or AlwaysOnAc." }
}
$powerHoldTimedMinutes = 15
if ($null -ne $config.power -and $null -ne $config.power.timedHoldMinutes) {
    $powerHoldTimedMinutes = [int]$config.power.timedHoldMinutes
}
if ($powerHoldMode -eq "TimedOnAc" -and ($powerHoldTimedMinutes -lt 1 -or $powerHoldTimedMinutes -gt 1440)) {
    throw "power.timedHoldMinutes must be between 1 and 1440 for TimedOnAc mode."
}

$scanManufacturerCompanyId = -1
$targetManufacturerPattern = ([string]$config.target.manufacturerDataHexPattern -replace "[^0-9A-Fa-f?]", "")
$targetManufacturerPrefix = ([string]$config.target.manufacturerDataHexPrefix -replace "[^0-9A-Fa-f]", "")
$companyIdHex = if ($targetManufacturerPattern.Length -ge 4 -and $targetManufacturerPattern.Substring(0, 4) -notmatch '\?') { $targetManufacturerPattern.Substring(0, 4) } elseif ($targetManufacturerPrefix.Length -ge 4) { $targetManufacturerPrefix.Substring(0, 4) } else { "" }
if (-not [string]::IsNullOrWhiteSpace($companyIdHex)) {
    $scanManufacturerCompanyId = [Convert]::ToInt32($companyIdHex, 16)
}
$bridge = [BleAdvertisementBridge]::new($scanManufacturerCompanyId, $bleSamplingIntervalMilliseconds)
$targetCandidates = @{}

$sessionSourceId = "BleProximityWake.Session.$PID"

$sessionSub = Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName SessionSwitch -SourceIdentifier $sessionSourceId -MessageData $state -Action {
    $state = $Event.MessageData
    $reason = $Event.SourceEventArgs.Reason.ToString()
    if ($reason -eq "SessionLock") {
        if ([bool]$state.IsLocked -and [bool]$state.SessionKnown) {
            $state.LastSessionReason = $reason
            return
        }
        $nowUtc = [DateTime]::UtcNow
        $state.IsLocked = $true
        $state.SessionKnown = $true
        $state.LockedTargetAddress = if ([string]::IsNullOrWhiteSpace([string]$state.PreferredTargetAddress)) { [string]$state.LastMatchAddress } else { [string]$state.PreferredTargetAddress }
        $state.WasFarSinceLastTrigger = $false
        $state.MatchCount = 0
        $state.AutoLockArmed = $false
        $state.AutoLockWatchAddress = ""
        $state.LastAutoLockWatchSeenUtc = [DateTime]::MinValue
        $state.AutoLockDepartureAgeSeconds = -1
        $state.LastAutoLockAttemptUtc = [DateTime]::MinValue
        $state.LastSessionReason = $reason
        $state.AutoUnlockAttempted = $false
        $state.AutoUnlockRetryCount = 0
        $state.AutoUnlockRetryAfterUtc = [DateTime]::MinValue
        $state.AutoUnlockRetryTrigger = ""
        $state.AutoUnlockLastStatus = "waiting"
        $state.AutoUnlockTriggerDetectedUtc = [DateTime]::MinValue
        $state.AutoUnlockAuthorizationStartedUtc = [DateTime]::MinValue
        $state.AutoUnlockAuthorizationAcceptedUtc = [DateTime]::MinValue
        $state.AutoUnlockLastRequestId = ""
        $state.PendingSessionUnlockTimingLog = $false
        $state.SessionUnlockElapsedMilliseconds = -1
        $state.LockCycleId = [uint64]$nowUtc.Ticks
        $state.LockStartedUtc = $nowUtc
        $state.PreviousUserIdleSeconds = -1
        $displayStateAtLock = [int]$state.LastDisplayState
        $state.DisplayWasOffSinceLock = ($displayStateAtLock -eq 0 -or $displayStateAtLock -eq 2)
        $state.LastDisplayWakeUtc = [DateTime]::MinValue
        $state.LastResumeUtc = [DateTime]::MinValue
        $state.ResumePresenceRequired = $false
        $state.LastPostResumeWatchSeenUtc = [DateTime]::MinValue
        $state.LastPostResumePhoneSeenUtc = [DateTime]::MinValue
        $state.InteractiveWakePending = $false
        $state.InteractiveWakeDetectedUtc = [DateTime]::MinValue
        $state.InteractiveWakeDeadlineUtc = [DateTime]::MinValue
        $state.InteractiveBleRecoveryRequested = $false
        $state.InteractiveBleRecoveryActive = $false
        $state.InteractiveBleRecoveryUtc = [DateTime]::MinValue
        $state.InteractiveBleRecoveryReason = ""
        $state.LastArrivalTriggerUtc = [DateTime]::MinValue
        $state.IgnoreInteractiveInputUntilUtc = $nowUtc.AddSeconds(2)
        $state.LastNetworkCheckUtc = [DateTime]::MinValue
        $state.LastStatus = "Session locked; waiting for target to become far"
    }
    elseif ($reason -eq "SessionUnlock") {
        $nowUtc = [DateTime]::UtcNow
        $acceptedUtc = [DateTime]$state.AutoUnlockAuthorizationAcceptedUtc
        if ($acceptedUtc -ne [DateTime]::MinValue) {
            $state.SessionUnlockElapsedMilliseconds = ($nowUtc - $acceptedUtc).TotalMilliseconds
            $state.PendingSessionUnlockTimingLog = $true
        }
        $state.IsLocked = $false
        $state.SessionKnown = $true
        $state.LockedTargetAddress = ""
        $state.AutoLockArmed = $false
        $state.AutoLockWatchAddress = ""
        $state.LastAutoLockWatchSeenUtc = [DateTime]::MinValue
        $state.AutoLockDepartureAgeSeconds = -1
        $state.LastAutoLockAttemptUtc = [DateTime]::MinValue
        $state.LastSessionReason = $reason
        $state.AutoUnlockAttempted = $false
        $state.AutoUnlockRetryCount = 0
        $state.AutoUnlockRetryAfterUtc = [DateTime]::MinValue
        $state.AutoUnlockRetryTrigger = ""
        $state.AutoUnlockLastStatus = "unlocked"
        $state.AutoUnlockTriggerDetectedUtc = [DateTime]::MinValue
        $state.AutoUnlockAuthorizationStartedUtc = [DateTime]::MinValue
        $state.AutoUnlockAuthorizationAcceptedUtc = [DateTime]::MinValue
        $state.LockCycleId = [uint64]0
        $state.LockStartedUtc = [DateTime]::MinValue
        $state.PreviousUserIdleSeconds = -1
        $state.DisplayWasOffSinceLock = $false
        $state.LastDisplayWakeUtc = [DateTime]::MinValue
        $state.LastResumeUtc = [DateTime]::MinValue
        $state.ResumePresenceRequired = $false
        $state.LastPostResumeWatchSeenUtc = [DateTime]::MinValue
        $state.LastPostResumePhoneSeenUtc = [DateTime]::MinValue
        $state.InteractiveWakePending = $false
        $state.InteractiveWakeDetectedUtc = [DateTime]::MinValue
        $state.InteractiveWakeDeadlineUtc = [DateTime]::MinValue
        $state.InteractiveBleRecoveryRequested = $false
        $state.InteractiveBleRecoveryActive = $false
        $state.InteractiveBleRecoveryUtc = [DateTime]::MinValue
        $state.InteractiveBleRecoveryReason = ""
        $state.LastArrivalTriggerUtc = [DateTime]::MinValue
        $state.IgnoreInteractiveInputUntilUtc = [DateTime]::MinValue
        $state.LastStatus = "Session unlocked"
    }
    else {
        $state.LastSessionReason = $reason
    }
}

$notifyIcon = $null
$trayIcon = $null
$timer = $null
$powerMonitor = $null

try {
    $processStartedUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime()
    $pidMetadata = [ordered]@{
        version = 2
        pid = $PID
        startedUtc = $processStartedUtc.ToString("o")
        scriptPath = (Resolve-Path -LiteralPath $PSCommandPath).Path
    }
    $pidMetadata | ConvertTo-Json -Compress | Set-Content -LiteralPath $pidFile -Encoding UTF8
    [BleProximityWakeNative]::RegisterConsoleCtrlHandler()
    $powerMonitor = [BlePowerNotificationWindow]::new()
    $state.LastDisplaySequence = $powerMonitor.DisplaySequence
    $state.LastDisplayState = $powerMonitor.DisplayState
    $state.LastResumeSequence = $powerMonitor.ResumeSequence
    Write-Log ("Power notification monitor initialized. Registered={0} DisplayState={1}" -f $powerMonitor.IsRegistered, $powerMonitor.DisplayState)

    if (-not $NoTray) {
        Write-Host "BLE Proximity Wake is running in tray mode. Logs: $logFile"
        Write-Host "Right-click the tray icon and choose Exit to stop, or run .\Stop-BleProximityWake.ps1 from another PowerShell window."
        if ($VerboseMatches) {
            Write-Host "Verbose match logs are written to the log file in tray mode. Use -NoTray to print them in this console."
        }

        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $trayIconPath = Join-Path $PSScriptRoot "assets\ble-proximity-wake.ico"
        if (Test-Path -LiteralPath $trayIconPath) {
            $trayIcon = [System.Drawing.Icon]::new($trayIconPath)
            $notifyIcon.Icon = $trayIcon
        }
        else {
            $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
            Write-Log ("Tray icon not found; using system fallback. Path={0}" -f $trayIconPath) "WARN"
        }
        $notifyIcon.Visible = $true
        $notifyIcon.Text = "BLE Proximity Wake | Starting"

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $menu.ShowItemToolTips = $true

        $appStatusItem = $menu.Items.Add("BLE Proximity Wake | Starting")
        $sessionStatusItem = $menu.Items.Add("Session: Starting")
        $deviceStatusItem = $menu.Items.Add("Devices: Detecting")
        $environmentStatusItem = $menu.Items.Add("Environment: Checking")
        $bleStatusItem = $menu.Items.Add("Scanning: Starting")
        $unlockStatusItem = $menu.Items.Add("Auto unlock: Starting")
        foreach ($item in @($appStatusItem, $sessionStatusItem, $deviceStatusItem, $environmentStatusItem, $bleStatusItem, $unlockStatusItem)) {
            $item.Enabled = $false
        }

        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        $wakeTestItem = $menu.Items.Add("Test wake to sign-in")
        $wakeTestItem.ToolTipText = "Wake the display and sign-in page without requesting automatic unlock."
        $wakeTestItem.add_Click({
            Write-Log "Tray wake test requested."
            $state.IgnoreInteractiveInputUntilUtc = [DateTime]::UtcNow.AddSeconds(3)
            Invoke-WakeToLogin -Config $config
        })

        $redetectItem = $menu.Items.Add("Re-detect devices")
        $redetectItem.ToolTipText = "Clear recent watch and phone observations, then restart the BLE scan."
        $redetectItem.add_Click({
            Reset-DeviceDetectionState -State $state -Candidates $targetCandidates
            $redetectActive = $activeScanWhenLocked -and [bool]$state.IsLocked -and [bool]$state.NetworkAllowed -and ([BleProximityWakeNative]::GetAcLineStatus() -eq 1)
            try {
                $cleared = $bridge.Restart($redetectActive, $true)
                $state.LastStatus = "Device detection reset"
                Write-Log ("Tray device re-detection requested. Active={0} ClearedQueue={1}" -f $redetectActive, $cleared)
            }
            catch {
                Write-Log ("Tray device re-detection failed. Error={0}" -f $_.Exception.Message) "WARN"
            }
        })

        $pauseItem = $menu.Items.Add("Pause detection")
        $pauseItem.ToolTipText = "Temporarily ignore BLE observations and disable all automatic actions."
        $pauseItem.add_Click({
            $state.DetectionPaused = -not [bool]$state.DetectionPaused
            if ([bool]$state.DetectionPaused) {
                $state.InteractiveWakePending = $false
                $state.InteractiveBleRecoveryRequested = $false
                $state.AutoUnlockRetryAfterUtc = [DateTime]::MinValue
                $state.AutoUnlockRetryTrigger = ""
                $state.AutoLockArmed = $false
                $state.AutoLockWatchAddress = ""
                Set-ConditionalPowerHold -State $state -ShouldHold $false
                $state.LastStatus = "Detection paused"
                Write-Log "BLE detection paused from tray. Automatic actions are disabled."
            }
            else {
                Reset-DeviceDetectionState -State $state -Candidates $targetCandidates
                $state.LastStatus = "Detection resumed"
                try {
                    $cleared = $bridge.Restart($false, $true)
                    Write-Log ("BLE detection resumed from tray. Device presence must be confirmed again. ClearedQueue={0}" -f $cleared)
                }
                catch {
                    Write-Log ("BLE detection resume restart failed. Error={0}" -f $_.Exception.Message) "WARN"
                }
            }
        })

        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        $featuresMenu = [System.Windows.Forms.ToolStripMenuItem]::new("Features")
        [void]$menu.Items.Add($featuresMenu)

        $wakeFeatureItem = $featuresMenu.DropDownItems.Add("Wake on approach")
        $wakeFeatureItem.add_Click({
            $state.RuntimeWakeEnabled = -not [bool]$state.RuntimeWakeEnabled
            Write-Log ("Tray feature changed. WakeOnApproach={0}" -f $state.RuntimeWakeEnabled)
        })

        $autoUnlockFeatureItem = $featuresMenu.DropDownItems.Add("Automatic unlock")
        $autoUnlockFeatureItem.Enabled = $autoUnlockEnabled
        $autoUnlockFeatureItem.ToolTipText = if ($autoUnlockEnabled) { "Temporarily enable or disable automatic unlock." } else { "Disabled in config.json." }
        $autoUnlockFeatureItem.add_Click({
            $state.RuntimeAutoUnlockEnabled = -not [bool]$state.RuntimeAutoUnlockEnabled
            $state.InteractiveWakePending = $false
            $state.AutoUnlockRetryCount = 0
            $state.AutoUnlockRetryAfterUtc = [DateTime]::MinValue
            $state.AutoUnlockRetryTrigger = ""
            if ([bool]$state.RuntimeAutoUnlockEnabled) {
                $state.AutoUnlockAttempted = $false
                $state.AutoUnlockLastStatus = if ([bool]$state.IsLocked) { "waiting" } else { "unlocked" }
            }
            else {
                $state.AutoUnlockLastStatus = "temporarily-disabled"
            }
            Write-Log ("Tray feature changed. AutoUnlock={0}" -f $state.RuntimeAutoUnlockEnabled)
        })

        $autoLockFeatureItem = $featuresMenu.DropDownItems.Add("Lock when away")
        $autoLockFeatureItem.Enabled = $autoLockEnabled
        $autoLockFeatureItem.ToolTipText = if ($autoLockEnabled) { "Temporarily enable or disable departure locking." } else { "Disabled in config.json." }
        $autoLockFeatureItem.add_Click({
            $state.RuntimeAutoLockEnabled = -not [bool]$state.RuntimeAutoLockEnabled
            $state.AutoLockArmed = $false
            $state.AutoLockWatchAddress = ""
            $state.LastAutoLockWatchSeenUtc = [DateTime]::MinValue
            $state.AutoLockDepartureAgeSeconds = -1
            Write-Log ("Tray feature changed. LockWhenAway={0}" -f $state.RuntimeAutoLockEnabled)
        })

        $diagnosticsMenu = [System.Windows.Forms.ToolStripMenuItem]::new("Diagnostics")
        [void]$menu.Items.Add($diagnosticsMenu)

        $openCurrentLogItem = $diagnosticsMenu.DropDownItems.Add("Open current log")
        $openCurrentLogItem.add_Click({
            if (Test-Path -LiteralPath $logFile) {
                Start-Process notepad.exe -ArgumentList ('"{0}"' -f $logFile)
            }
        })

        $openLogItem = $diagnosticsMenu.DropDownItems.Add("Open log folder")
        $openLogItem.add_Click({
            Start-Process explorer.exe -ArgumentList $logDir
        })

        $copyStatusItem = $diagnosticsMenu.DropDownItems.Add("Copy diagnostic summary")
        $copyStatusItem.add_Click({
            $summary = @(
                "BLE Proximity Wake diagnostic summary"
                "Time: $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))"
                $appStatusItem.Text
                $sessionStatusItem.Text
                $deviceStatusItem.Text
                $environmentStatusItem.Text
                $bleStatusItem.Text
                $unlockStatusItem.Text
                "Runtime: paused=$($state.DetectionPaused); wake=$($state.RuntimeWakeEnabled); autoUnlock=$($state.RuntimeAutoUnlockEnabled); autoLock=$($state.RuntimeAutoLockEnabled)"
                "Details: $($state.LastStatus)"
                "Network: $($state.NetworkReason)"
            ) -join [Environment]::NewLine
            [System.Windows.Forms.Clipboard]::SetText($summary)
            Write-Log "Tray diagnostic summary copied to clipboard."
        })

        $openConfigItem = $diagnosticsMenu.DropDownItems.Add("Open configuration")
        $openConfigItem.ToolTipText = "Open the active config.json in Notepad. Restart the program after editing."
        $openConfigItem.add_Click({
            Start-Process notepad.exe -ArgumentList ('"{0}"' -f $ConfigPath)
        })

        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        $exitItem = $menu.Items.Add("Exit")
        $exitItem.add_Click({
            Write-Log "Tray exit requested."
            [System.Windows.Forms.Application]::Exit()
        })

        $menu.add_Opening({
            $menuNow = [DateTime]::UtcNow
            $runText = if ([bool]$state.DetectionPaused) {
                "Detection paused"
            }
            elseif ([string]$state.WatcherStatus -ne "Started") {
                "BLE scanner issue"
            }
            elseif (-not [bool]$state.NetworkAllowed) {
                "Waiting for allowed network"
            }
            else {
                "Running normally"
            }
            $appStatusItem.Text = "BLE Proximity Wake | $runText"

            $sessionText = if (-not [bool]$state.SessionKnown) { "Unknown" } elseif ([bool]$state.IsLocked) { "Locked" } else { "Unlocked" }
            $sessionStatusItem.Text = "Session: $sessionText"

            $watchAgeSeconds = if ([DateTime]$state.LastMatchedUtc -eq [DateTime]::MinValue) { -1 } else { ($menuNow - [DateTime]$state.LastMatchedUtc).TotalSeconds }
            $watchNearby = $watchAgeSeconds -ge 0 -and $watchAgeSeconds -le $interactiveWakeMaxWatchAgeSeconds
            $watchText = if ($watchNearby) { "watch near ($($state.LastMatchRssi) dBm)" } elseif ($watchAgeSeconds -lt 0) { "watch not detected" } else { "watch away" }

            $phoneAgeSeconds = if ([DateTime]$state.LastPhoneSeenUtc -eq [DateTime]::MinValue) { -1 } else { ($menuNow - [DateTime]$state.LastPhoneSeenUtc).TotalSeconds }
            $phoneText = if ([bool]$state.PhoneAllowed) { "phone near ($($state.LastPhoneRssi) dBm)" } elseif ($phoneAgeSeconds -lt 0) { "phone not detected" } else { "phone away" }
            $deviceStatusItem.Text = "Devices: $watchText | $phoneText"

            $networkName = Get-NetworkDisplayName -Reason ([string]$state.NetworkReason)
            $networkText = if ([bool]$state.NetworkAllowed) { $networkName } else { "$networkName (not allowed)" }
            $acStatus = [BleProximityWakeNative]::GetAcLineStatus()
            $powerText = if ($acStatus -eq 1) { "AC power" } elseif ($acStatus -eq 0) { "battery" } else { "power unknown" }
            $environmentStatusItem.Text = "Environment: $networkText | $powerText"
            $environmentStatusItem.ToolTipText = [string]$state.NetworkReason

            $bleStatusItem.Text = if ([bool]$state.DetectionPaused) { "Scanning: Paused | low power" } else { "Scanning: $($state.WatcherMode) | queue $($state.WatcherQueueCount)" }
            $unlockStatusItem.Text = if (-not $autoUnlockEnabled) { "Auto unlock: Disabled in config" } elseif (-not [bool]$state.RuntimeAutoUnlockEnabled) { "Auto unlock: Temporarily disabled" } else { "Auto unlock: $($state.AutoUnlockLastStatus)" }

            $pauseItem.Text = if ([bool]$state.DetectionPaused) { "Resume detection" } else { "Pause detection" }
            $redetectItem.Enabled = -not [bool]$state.DetectionPaused
            $wakeFeatureItem.Checked = [bool]$state.RuntimeWakeEnabled
            $autoUnlockFeatureItem.Checked = [bool]$state.RuntimeAutoUnlockEnabled
            $autoLockFeatureItem.Checked = [bool]$state.RuntimeAutoLockEnabled
        })

        $notifyIcon.ContextMenuStrip = $menu
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $unlockedPollIntervalMilliseconds
    $timer.add_Tick({
        try {
            $now = [DateTime]::UtcNow
            if ([bool]$state.PendingSessionUnlockTimingLog) {
                Write-Log ("Auto-unlock session completed. RequestId={0} AcceptedToSessionUnlockMs={1:N0}" -f $state.AutoUnlockLastRequestId, $state.SessionUnlockElapsedMilliseconds)
                $state.PendingSessionUnlockTimingLog = $false
            }

            $displaySequence = $powerMonitor.DisplaySequence
            if ($displaySequence -ne [int]$state.LastDisplaySequence) {
                $displayState = $powerMonitor.DisplayState
                $previousDisplayState = [int]$state.LastDisplayState
                $state.LastDisplaySequence = $displaySequence
                $state.LastDisplayState = $displayState
                if ([bool]$state.IsLocked -and ($displayState -eq 0 -or $displayState -eq 2)) {
                    $state.DisplayWasOffSinceLock = $true
                    $state.InteractiveBleRecoveryRequested = $false
                    $state.InteractiveBleRecoveryActive = $false
                    $state.InteractiveBleRecoveryUtc = [DateTime]::MinValue
                    $state.InteractiveBleRecoveryReason = ""
                    Write-Log ("Console display is no longer on. Previous={0} Current={1} Sequence={2}" -f $previousDisplayState, $displayState, $displaySequence)
                }
                elseif ([bool]$state.IsLocked -and $displayState -eq 1) {
                    $state.LastDisplayWakeUtc = $now
                    $lastArrivalTriggerUtc = [DateTime]$state.LastArrivalTriggerUtc
                    $arrivalWakeInProgress = $lastArrivalTriggerUtc -ne [DateTime]::MinValue -and ($now - $lastArrivalTriggerUtc).TotalSeconds -le 10
                    if ($autoUnlockEnabled -and [bool]$state.RuntimeAutoUnlockEnabled -and -not [bool]$state.DetectionPaused -and $autoUnlockTriggerOnInteractiveWake -and [bool]$state.DisplayWasOffSinceLock -and -not [bool]$state.InteractiveBleRecoveryActive -and -not $arrivalWakeInProgress) {
                        $state.InteractiveBleRecoveryRequested = $true
                        $state.InteractiveBleRecoveryReason = "display-on"
                    }
                    Write-Log ("Console display turned on while locked. Previous={0} Sequence={1} WasOff={2}" -f $previousDisplayState, $displaySequence, $state.DisplayWasOffSinceLock)
                }
            }
            if ([bool]$state.IsLocked -and
                ([int]$state.LastDisplayState -eq 0 -or [int]$state.LastDisplayState -eq 2)) {
                $state.DisplayWasOffSinceLock = $true
            }

            $resumeSequence = $powerMonitor.ResumeSequence
            if ($resumeSequence -ne [int]$state.LastResumeSequence) {
                $state.LastResumeSequence = $resumeSequence
                $state.DisplayWasOffSinceLock = [bool]$state.IsLocked
                $state.LastNetworkCheckUtc = [DateTime]::MinValue
                if ([bool]$state.IsLocked -and -not [bool]$state.InteractiveBleRecoveryActive) {
                    $state.LastResumeUtc = $now
                    $state.ResumePresenceRequired = $true
                    $state.LastPostResumeWatchSeenUtc = [DateTime]::MinValue
                    $state.LastPostResumePhoneSeenUtc = [DateTime]::MinValue
                    $state.InteractiveBleRecoveryRequested = $autoUnlockEnabled -and [bool]$state.RuntimeAutoUnlockEnabled -and -not [bool]$state.DetectionPaused -and $autoUnlockTriggerOnInteractiveWake
                    $state.InteractiveBleRecoveryUtc = [DateTime]::MinValue
                    $state.InteractiveBleRecoveryReason = "system-resume"
                    $state.PhoneMatchCount = 0
                    $state.LastPhoneSeenUtc = [DateTime]::MinValue
                    $state.PhoneFirstHitUtc = [DateTime]::MinValue
                    $state.PhoneStrongSignalSeenUtc = [DateTime]::MinValue
                }
                Write-Log ("System resume observed. Sequence={0} Locked={1}; network and BLE presence must be confirmed again." -f $resumeSequence, $state.IsLocked)
            }

            $lastNetworkCheck = [DateTime]$state.LastNetworkCheckUtc
            if (($now - $lastNetworkCheck).TotalSeconds -ge $networkCheckIntervalSeconds) {
                [void](Update-NetworkAllowedState -State $state -Config $config -NowUtc $now)
            }

            $scanNetworkAllowed = (-not $networkFilterEnabled) -or [bool]$state.NetworkAllowed
            $acLineStatus = [BleProximityWakeNative]::GetAcLineStatus()
            $pluggedIn = $acLineStatus -eq 1
            $powerSource = if ($acLineStatus -eq 1) { "AC" } elseif ($acLineStatus -eq 0) { "Battery" } else { "Unknown" }
            $useLockedPerformanceMode = -not [bool]$state.DetectionPaused -and ($ForceWakeTest -or ([bool]$state.IsLocked -and $scanNetworkAllowed -and $pluggedIn))
            $desiredActiveScan = $activeScanWhenLocked -and $useLockedPerformanceMode
            $desiredPollInterval = if ($useLockedPerformanceMode) { $lockedPollIntervalMilliseconds } else { $unlockedPollIntervalMilliseconds }
            if ($timer.Interval -ne $desiredPollInterval) {
                $timer.Interval = $desiredPollInterval
            }
            $watcherRestarted = $false
            if ($autoUnlockEnabled -and [bool]$state.RuntimeAutoUnlockEnabled -and -not [bool]$state.DetectionPaused -and $autoUnlockTriggerOnInteractiveWake -and [bool]$state.InteractiveBleRecoveryRequested -and $desiredActiveScan -and -not [bool]$state.InteractiveBleRecoveryActive) {
                $watcherRestarted = Start-InteractiveBleRecovery -State $state -Bridge $bridge -NowUtc $now -Reason ([string]$state.InteractiveBleRecoveryReason)
            }
            if (-not $watcherRestarted) {
                $watcherRestarted = $bridge.EnsureStarted($desiredActiveScan)
            }
            $state.WatcherStatus = $bridge.GetStatus()
            $state.WatcherMode = $bridge.GetScanningMode()
            $state.WatcherLastStopError = $bridge.GetLastStopError()
            $state.WatcherRestartCount = $bridge.GetRestartCount()
            $previousForcedRecoveryCount = [int]$state.WatcherForcedRecoveryCount
            $state.WatcherForcedRecoveryCount = $bridge.GetForcedRecoveryCount()
            $state.WatcherQueueCount = $bridge.GetQueueCount()
            $state.WatcherDroppedQueueRecords = $bridge.GetDroppedQueueRecords()
            if ([int]$state.WatcherForcedRecoveryCount -gt $previousForcedRecoveryCount) {
                Write-Log ("BLE watcher was stuck in Stopping and was replaced. ForcedRecoveryCount={0} Mode={1}" -f $state.WatcherForcedRecoveryCount, $state.WatcherMode) "WARN"
            }
            if ($watcherRestarted) {
                $state.LastWatcherRestartUtc = $now
                Write-Log ("BLE watcher started/restarted. Status={0} Mode={1} LastStopError={2} RestartCount={3}" -f $state.WatcherStatus, $state.WatcherMode, $state.WatcherLastStopError, $state.WatcherRestartCount)
                if ($autoLockEnabled -and [bool]$state.RuntimeAutoLockEnabled -and -not [bool]$state.IsLocked -and [bool]$state.AutoLockArmed) {
                    $state.AutoLockArmed = $false
                    $state.AutoLockWatchAddress = ""
                    $state.LastAutoLockWatchSeenUtc = [DateTime]::MinValue
                    $state.AutoLockDepartureAgeSeconds = -1
                    Write-Log "Auto-lock disarmed because the BLE watcher restarted; devices must be observed again." "WARN"
                }
            }

            if ([bool]$state.DetectionPaused) {
                $discardedWhilePaused = @($bridge.Drain(1000)).Count
                $state.WatcherQueueCount = $bridge.GetQueueCount()
                Set-ConditionalPowerHold -State $state -ShouldHold $false
                $state.LastStatus = "DetectionPaused=True Watcher=$($state.WatcherStatus)/$($state.WatcherMode) Discarded=$discardedWhilePaused"
                $lastPausedHeartbeat = [DateTime]$state.LastHeartbeatUtc
                if ($heartbeatSeconds -gt 0 -and (($now - $lastPausedHeartbeat).TotalSeconds -ge $heartbeatSeconds)) {
                    $state.LastHeartbeatUtc = $now
                    Write-Log ("Heartbeat. DetectionPaused=True Watcher={0}/{1} Queue={2} Discarded={3}" -f $state.WatcherStatus, $state.WatcherMode, $state.WatcherQueueCount, $discardedWhilePaused)
                }
                if ($notifyIcon) {
                    $notifyIcon.Text = "BLE Proximity Wake | Detection paused"
                }
                return
            }

            foreach ($record in $bridge.Drain(1000)) {
                $recordTime = [DateTime]$record.TimestampUtc
                if ($recordTime.Kind -eq [DateTimeKind]::Unspecified) {
                    $recordTime = [DateTime]::SpecifyKind($recordTime, [DateTimeKind]::Utc)
                }
                $recordAgeSeconds = ($now - $recordTime).TotalSeconds
                if ($recordAgeSeconds -gt $maxAdvertisementAgeSeconds -or $recordAgeSeconds -lt -2) {
                    $state.DroppedStaleAdvertisements = [int]$state.DroppedStaleAdvertisements + 1
                    continue
                }
                if ($recordTime -gt $now) { $recordTime = $now }

                if ($phoneFilterEnabled -and (Test-PhoneAdvertisementMatch -Record $record -Config $config)) {
                    if ($record.Rssi -ge $phoneRssiThreshold) {
                        $lastPhone = [DateTime]$state.LastPhoneSeenUtc
                        if (($recordTime - $lastPhone).TotalSeconds -gt $phoneHitWindowSeconds) {
                            $state.PhoneMatchCount = 0
                            $state.PhoneFirstHitUtc = [DateTime]::MinValue
                        }
                        if ($lastPhone -eq [DateTime]::MinValue -or $recordTime -ge $lastPhone) {
                            if ([int]$state.PhoneMatchCount -eq 0 -or [DateTime]$state.PhoneFirstHitUtc -eq [DateTime]::MinValue) {
                                $state.PhoneFirstHitUtc = $recordTime
                                Write-Log ("Phone first qualifying advertisement. Address={0} RSSI={1}" -f $record.Address, $record.Rssi)
                            }
                            $state.LastPhoneSeenUtc = $recordTime
                            $state.PhoneMatchCount = [int]$state.PhoneMatchCount + 1
                            $state.LastPhoneAddress = [string]$record.Address
                            $state.LastPhoneRssi = [int]$record.Rssi
                            if ($record.Rssi -ge $phoneStrongRssiSingleHitThreshold) {
                                $previousStrongSeenUtc = [DateTime]$state.PhoneStrongSignalSeenUtc
                                $state.PhoneStrongSignalSeenUtc = $recordTime
                                if (-not (Test-RecentUtcTimestamp -TimestampUtc $previousStrongSeenUtc -NowUtc $recordTime -MaximumAgeSeconds $phonePresenceTimeoutSeconds)) {
                                    Write-Log ("Phone strong-signal fast path observed. Address={0} RSSI={1} Threshold={2}" -f $record.Address, $record.Rssi, $phoneStrongRssiSingleHitThreshold)
                                }
                            }
                            if ([bool]$state.ResumePresenceRequired -and $recordTime -ge ([DateTime]$state.LastResumeUtc).AddMilliseconds(-250)) {
                                $state.LastPostResumePhoneSeenUtc = $recordTime
                            }
                            if ($VerboseMatches) {
                                Write-Log ("Phone matched. Address={0} RSSI={1} Count={2} RecordAgeSec={3:N1}" -f $state.LastPhoneAddress, $state.LastPhoneRssi, $state.PhoneMatchCount, $recordAgeSeconds)
                            }
                        }
                    }
                    elseif ($VerboseMatches) {
                        Write-Log ("Phone seen below threshold. Address={0} RSSI={1} Threshold={2}" -f $record.Address, $record.Rssi, $phoneRssiThreshold)
                    }
                }

                $matchedTarget = Test-AdvertisementMatch -Record $record -Config $config
                if (-not $matchedTarget) {
                    continue
                }
                $recordAddress = Normalize-BluetoothAddress ([string]$record.Address)
                $autoLockWatchAddress = Normalize-BluetoothAddress ([string]$state.AutoLockWatchAddress)
                if (
                    [bool]$state.AutoLockArmed -and
                    -not [string]::IsNullOrWhiteSpace($autoLockWatchAddress) -and
                    $recordAddress -eq $autoLockWatchAddress -and
                    $record.Rssi -ge $learnedAddressRssiThreshold
                ) {
                    if ($recordTime -ge [DateTime]$state.LastAutoLockWatchSeenUtc) {
                        $state.LastAutoLockWatchSeenUtc = $recordTime
                    }
                }
                $lockedTargetAddress = Normalize-BluetoothAddress ([string]$state.LockedTargetAddress)
                $useLearnedFastPath = (
                    [bool]$state.IsLocked -and
                    ([bool]$state.WasFarSinceLastTrigger -or $autoUnlockTriggerOnInteractiveWake) -and
                    -not [string]::IsNullOrWhiteSpace($lockedTargetAddress) -and
                    $recordAddress -eq $lockedTargetAddress
                )
                $effectiveRssiThreshold = if ($useLearnedFastPath) { $learnedAddressRssiThreshold } else { $rssiThreshold }
                if ($record.Rssi -lt $effectiveRssiThreshold) {
                    if ($VerboseMatches) {
                        Write-Log ("Target seen below threshold. Address={0} Name={1} RSSI={2} Threshold={3} FastPath={4} ManufacturerData={5}" -f $record.Address, $record.Name, $record.Rssi, $effectiveRssiThreshold, $useLearnedFastPath, $record.ManufacturerData)
                    }
                    continue
                }

                $last = [DateTime]$state.LastMatchedUtc
                if (($recordTime - $last).TotalSeconds -gt $hitWindowSeconds) {
                    $state.MatchCount = 0
                }

                if ($last -eq [DateTime]::MinValue -or $recordTime -ge $last) {
                    $state.LastMatchedUtc = $recordTime
                    $state.MatchCount = [int]$state.MatchCount + 1
                    $state.LastMatchName = [string]$record.Name
                    $state.LastMatchAddress = [string]$record.Address
                    $state.LastMatchRssi = [int]$record.Rssi
                    $state.LastMatchFastPath = [bool]$useLearnedFastPath
                    if ([bool]$state.ResumePresenceRequired -and $recordTime -ge ([DateTime]$state.LastResumeUtc).AddMilliseconds(-250)) {
                        $state.LastPostResumeWatchSeenUtc = $recordTime
                    }
                    if (-not [bool]$state.IsLocked -and $record.Rssi -ge $rssiThreshold) {
                        Add-TargetCandidateObservation -Candidates $targetCandidates -Address ([string]$record.Address) -TimestampUtc $recordTime -Rssi ([int]$record.Rssi)
                    }
                    if ($VerboseMatches) {
                        Write-Log ("Matched target. Address={0} Name={1} RSSI={2} Count={3} FastPath={4} RecordAgeSec={5:N1}" -f $state.LastMatchAddress, $state.LastMatchName, $state.LastMatchRssi, $state.MatchCount, $useLearnedFastPath, $recordAgeSeconds)
                    }
                }
            }

            $preferredTarget = Get-PreferredTargetCandidate -Candidates $targetCandidates -NowUtc $now -WindowSeconds $addressLearningWindowSeconds -MinimumHits $addressLearningMinimumHits
            if ($null -eq $preferredTarget) {
                $state.PreferredTargetAddress = ""
                $state.PreferredTargetLastSeenUtc = [DateTime]::MinValue
                $state.PreferredTargetHits = 0
            }
            else {
                if ((Normalize-BluetoothAddress ([string]$state.PreferredTargetAddress)) -ne (Normalize-BluetoothAddress ([string]$preferredTarget.Address))) {
                    Write-Log ("Preferred watch address changed. Address={0} Hits={1} WindowSec={2}" -f $preferredTarget.Address, $preferredTarget.Count, $addressLearningWindowSeconds)
                }
                $state.PreferredTargetAddress = [string]$preferredTarget.Address
                $state.PreferredTargetLastSeenUtc = [DateTime]$preferredTarget.LastSeenUtc
                $state.PreferredTargetHits = [int]$preferredTarget.Count
            }

            $lastMatched = [DateTime]$state.LastMatchedUtc
            $lastTrigger = [DateTime]$state.LastTriggerUtc
            $lastHeartbeat = [DateTime]$state.LastHeartbeatUtc
            $lastPhoneSeen = [DateTime]$state.LastPhoneSeenUtc
            $logonUiPresent = $false
            if ($config.wake.assumeLockedWhenLogonUiPresent -eq $true) {
                $logonUiPresent = Test-LogonUiPresent
            }

            if (($now - $lastMatched).TotalSeconds -gt $lostSeconds) {
                if (-not $state.WasFarSinceLastTrigger) {
                    Write-Log "Target considered far after $lostSeconds seconds without match."
                }
                $state.WasFarSinceLastTrigger = $true
                $state.MatchCount = 0
            }
            elseif (($now - $lastMatched).TotalSeconds -gt $hitWindowSeconds) {
                $state.MatchCount = 0
            }

            $lockedAllowed = $state.IsLocked -or (($config.wake.allowWhenSessionUnknown -eq $true) -and (-not $state.SessionKnown)) -or $ForceWakeTest
            if (-not $lockedAllowed -and $logonUiPresent -and $config.wake.assumeLockedWhenLogonUiPresent -eq $true) {
                $lockedAllowed = $true
            }
            $networkAllowed = [bool]$state.NetworkAllowed
            if ($phoneFilterEnabled -and ($now - $lastPhoneSeen).TotalSeconds -gt $phonePresenceTimeoutSeconds) {
                $state.PhoneMatchCount = 0
            }
            $phonePresenceReady = Test-PhonePresenceReady `
                -MatchCount ([int]$state.PhoneMatchCount) `
                -RequiredHits $phoneHitCount `
                -LastSeenUtc $lastPhoneSeen `
                -StrongSignalSeenUtc ([DateTime]$state.PhoneStrongSignalSeenUtc) `
                -NowUtc $now `
                -PresenceTimeoutSeconds $phonePresenceTimeoutSeconds
            $phoneAllowed = ((-not $phoneFilterEnabled) -or $phonePresenceReady -or $ForceWakeTest)
            if ([bool]$state.PhoneAllowed -ne $phoneAllowed) {
                $firstPhoneHitUtc = [DateTime]$state.PhoneFirstHitUtc
                $firstHitToReadyMilliseconds = if (-not $phoneAllowed -or $firstPhoneHitUtc -eq [DateTime]::MinValue) { -1 } else { ($now - $firstPhoneHitUtc).TotalMilliseconds }
                $phoneFastPath = $phoneAllowed -and (Test-RecentUtcTimestamp -TimestampUtc ([DateTime]$state.PhoneStrongSignalSeenUtc) -NowUtc $now -MaximumAgeSeconds $phonePresenceTimeoutSeconds)
                Write-Log ("Phone presence changed. Allowed={0} Address={1} RSSI={2} Hits={3}/{4} FastPath={5} FirstHitToReadyMs={6:N0}" -f $phoneAllowed, $state.LastPhoneAddress, $state.LastPhoneRssi, $state.PhoneMatchCount, $phoneHitCount, $phoneFastPath, $firstHitToReadyMilliseconds)
                $state.PhoneAllowed = $phoneAllowed
                if (-not $phoneAllowed) {
                    $state.PhoneFirstHitUtc = [DateTime]::MinValue
                    $state.PhoneStrongSignalSeenUtc = [DateTime]::MinValue
                }
            }

            if (
                $autoLockEnabled -and [bool]$state.RuntimeAutoLockEnabled -and
                [bool]$state.AutoLockArmed -and
                $phoneAllowed -and
                -not [string]::IsNullOrWhiteSpace([string]$state.PreferredTargetAddress) -and
                (Normalize-BluetoothAddress ([string]$state.AutoLockWatchAddress)) -ne (Normalize-BluetoothAddress ([string]$state.PreferredTargetAddress))
            ) {
                $previousAutoLockWatch = [string]$state.AutoLockWatchAddress
                $state.AutoLockWatchAddress = [string]$state.PreferredTargetAddress
                $state.LastAutoLockWatchSeenUtc = [DateTime]$state.PreferredTargetLastSeenUtc
                Write-Log ("Auto-lock watch address refreshed after rotation. Previous={0} Current={1} Hits={2}" -f $previousAutoLockWatch, $state.AutoLockWatchAddress, $state.PreferredTargetHits)
            }

            $lastAutoLockWatchSeen = [DateTime]$state.LastAutoLockWatchSeenUtc
            $genericWatchAgeSeconds = if ($lastMatched -eq [DateTime]::MinValue) { [double]::PositiveInfinity } else { ($now - $lastMatched).TotalSeconds }
            $watchAgeSeconds = if ([bool]$state.AutoLockArmed -and $lastAutoLockWatchSeen -ne [DateTime]::MinValue) { ($now - $lastAutoLockWatchSeen).TotalSeconds } else { $genericWatchAgeSeconds }
            $phoneAgeSeconds = if ($lastPhoneSeen -eq [DateTime]::MinValue) { [double]::PositiveInfinity } else { ($now - $lastPhoneSeen).TotalSeconds }
            $preferredWatchReady = -not [string]::IsNullOrWhiteSpace([string]$state.PreferredTargetAddress)
            $watchPresentForAutoLock = (-not $autoLockRequireWatchAbsent) -or $(if ([bool]$state.AutoLockArmed) { $watchAgeSeconds -le $lostSeconds } else { $preferredWatchReady -and (([DateTime]$state.PreferredTargetLastSeenUtc) -ne [DateTime]::MinValue) -and (($now - [DateTime]$state.PreferredTargetLastSeenUtc).TotalSeconds -le $lostSeconds) })
            $phonePresentForAutoLock = (-not $autoLockRequirePhoneAbsent) -or $phoneAllowed
            $autoLockNetworkReady = (-not $autoLockRequireAllowedNetwork) -or $networkAllowed
            $previousUserIdleSeconds = [double]$state.PreviousUserIdleSeconds
            $userIdleSeconds = [BleProximityWakeNative]::GetIdleSeconds()
            $state.LastUserIdleSeconds = $userIdleSeconds
            $state.PreviousUserIdleSeconds = $userIdleSeconds
            $autoLockIdleReady = ($autoLockMinimumUserIdleSeconds -le 0) -or ($userIdleSeconds -ge $autoLockMinimumUserIdleSeconds)

            if ($autoLockEnabled -and [bool]$state.RuntimeAutoLockEnabled) {
                if ([bool]$state.IsLocked -or -not $autoLockNetworkReady) {
                    $state.AutoLockArmed = $false
                    $state.AutoLockWatchAddress = ""
                    $state.LastAutoLockWatchSeenUtc = [DateTime]::MinValue
                    $state.AutoLockDepartureAgeSeconds = -1
                    $state.LastAutoLockAttemptUtc = [DateTime]::MinValue
                }
                elseif ($watchPresentForAutoLock -and $phonePresentForAutoLock) {
                    if (-not [bool]$state.AutoLockArmed) {
                        $state.AutoLockWatchAddress = [string]$state.PreferredTargetAddress
                        $state.LastAutoLockWatchSeenUtc = [DateTime]$state.PreferredTargetLastSeenUtc
                        $state.LastAutoLockAttemptUtc = [DateTime]::MinValue
                        Write-Log ("Auto-lock armed after required devices were observed present. WatchAddress={0} PreferredHits={1}" -f $state.AutoLockWatchAddress, $state.PreferredTargetHits)
                    }
                    $state.AutoLockArmed = $true
                    $state.AutoLockDepartureAgeSeconds = 0
                }
                elseif ([bool]$state.AutoLockArmed) {
                    $departureAges = @()
                    if ($autoLockRequireWatchAbsent) { $departureAges += $watchAgeSeconds }
                    if ($autoLockRequirePhoneAbsent) { $departureAges += $phoneAgeSeconds }
                    $departureAgeSeconds = [double](($departureAges | Measure-Object -Minimum).Minimum)
                    $state.AutoLockDepartureAgeSeconds = $departureAgeSeconds
                    $lastAutoLockAttempt = [DateTime]$state.LastAutoLockAttemptUtc
                    $retryReady = $lastAutoLockAttempt -eq [DateTime]::MinValue -or (($now - $lastAutoLockAttempt).TotalSeconds -ge $autoLockRetrySeconds)
                    if ($departureAgeSeconds -ge $autoLockAbsenceSeconds -and $autoLockIdleReady -and $retryReady) {
                        Write-Log ("Auto-lock departure confirmed. AbsenceSec={0:N1} Threshold={1} WatchAgeSec={2:N1} PhoneAgeSec={3:N1} UserIdleSec={4:N1} NetworkReason={5}" -f $departureAgeSeconds, $autoLockAbsenceSeconds, $watchAgeSeconds, $phoneAgeSeconds, $userIdleSeconds, $state.NetworkReason)
                        $state.LastAutoLockAttemptUtc = $now
                        $lockResult = Invoke-AutoLock
                        if ($lockResult) {
                            $state.AutoLockArmed = $false
                            $state.AutoLockWatchAddress = ""
                            $state.LastAutoLockWatchSeenUtc = [DateTime]::MinValue
                            $state.AutoLockDepartureAgeSeconds = -1
                        }
                        else {
                            Write-Log "Auto-lock failed; keeping departure state armed for retry." "WARN"
                        }
                    }
                }
            }

            if ($autoUnlockEnabled -and [bool]$state.RuntimeAutoUnlockEnabled -and $autoUnlockTriggerOnInteractiveWake -and [bool]$state.IsLocked -and -not [bool]$state.AutoUnlockAttempted) {
                $inputEdge = Test-InteractiveWakeInputEdge `
                    -PreviousIdleSeconds $previousUserIdleSeconds `
                    -CurrentIdleSeconds $userIdleSeconds `
                    -MinimumPriorIdleSeconds $interactiveWakeMinimumPriorIdleSeconds `
                    -InputFreshSeconds $interactiveWakeInputFreshSeconds
                $ignoreInput = $now -lt [DateTime]$state.IgnoreInteractiveInputUntilUtc
                $displayEvidence = [bool]$state.DisplayWasOffSinceLock -or $interactiveWakeAllowIdleFallback
                if ($inputEdge -and -not $ignoreInput -and $displayEvidence -and -not [bool]$state.InteractiveWakePending) {
                    if (-not [bool]$state.InteractiveBleRecoveryActive) {
                        $state.InteractiveBleRecoveryRequested = $true
                        $state.InteractiveBleRecoveryReason = "interactive-input"
                        if ($desiredActiveScan) {
                            [void](Start-InteractiveBleRecovery -State $state -Bridge $bridge -NowUtc $now -Reason "interactive-input")
                        }
                    }
                    $state.AutoUnlockTriggerDetectedUtc = $now
                    $state.InteractiveWakePending = $true
                    $state.InteractiveWakeDetectedUtc = $now
                    $state.InteractiveWakeDeadlineUtc = $now.AddMilliseconds($interactiveWakeConfirmationMilliseconds)
                    $state.DisplayWasOffSinceLock = $false
                    $state.LastNetworkCheckUtc = [DateTime]::MinValue
                    $state.AutoUnlockLastStatus = "interactive-confirming"
                    Write-Log ("Interactive wake detected. PreviousIdleSec={0:N1} CurrentIdleSec={1:N1} DisplayState={2} LastResumeAgeSec={3:N1} ConfirmationMs={4}" -f $previousUserIdleSeconds, $userIdleSeconds, $state.LastDisplayState, $(if ([DateTime]$state.LastResumeUtc -eq [DateTime]::MinValue) { -1 } else { ($now - [DateTime]$state.LastResumeUtc).TotalSeconds }), $interactiveWakeConfirmationMilliseconds)
                }
            }

            $cooldownOk = (($now - $lastTrigger).TotalSeconds -ge $cooldownSeconds)
            $hitOk = ([int]$state.MatchCount -ge $hitCount)
            $holdModeAllows = $false
            if ($powerHoldMode -eq "AlwaysOnAc") {
                $holdModeAllows = $true
            }
            elseif ($powerHoldMode -eq "TimedOnAc") {
                $lockStarted = [DateTime]$state.LockStartedUtc
                $holdModeAllows = $lockStarted -ne [DateTime]::MinValue -and ($now - $lockStarted).TotalMinutes -lt $powerHoldTimedMinutes
            }
            $shouldHoldPower = $holdModeAllows -and $networkFilterEnabled -and [bool]$state.IsLocked -and $networkAllowed -and $pluggedIn
            Set-ConditionalPowerHold -State $state -ShouldHold $shouldHoldPower

            if ($heartbeatSeconds -gt 0 -and (($now - $lastHeartbeat).TotalSeconds -ge $heartbeatSeconds)) {
                $state.LastHeartbeatUtc = $now
                Write-Log ("Heartbeat. Locked={0} Known={1} Allowed={2} NetworkAllowed={3} PhoneAllowed={4} PhoneHits={5}/{6} PhoneRSSI={7} PreferredWatch={8} PreferredHits={9} AutoLockArmed={10} DepartureAgeSec={11:N1} UserIdleSec={12:N1} AutoLockWatch={13} PowerSource={14} PowerHold={15}/{16} Interactive={17} Display={18} Armed={19} Hits={20}/{21} LastRSSI={22} LastMatchAgeSec={23:N1} LockedTarget={24} Watcher={25}/{26} Restarts={27} ForcedRecoveries={28} Queue={29} StaleDropped={30} QueueDropped={31} SessionReason={32} NetworkReason={33}" -f $state.IsLocked, $state.SessionKnown, $lockedAllowed, $networkAllowed, $phoneAllowed, $state.PhoneMatchCount, $phoneHitCount, $state.LastPhoneRssi, $state.PreferredTargetAddress, $state.PreferredTargetHits, $state.AutoLockArmed, $state.AutoLockDepartureAgeSeconds, $userIdleSeconds, $state.AutoLockWatchAddress, $powerSource, $state.PowerHoldActive, $powerHoldMode, $state.InteractiveWakePending, $state.LastDisplayState, $state.WasFarSinceLastTrigger, $state.MatchCount, $hitCount, $state.LastMatchRssi, $(if ($lastMatched -eq [DateTime]::MinValue) { -1 } else { ($now - $lastMatched).TotalSeconds }), $state.LockedTargetAddress, $state.WatcherStatus, $state.WatcherMode, $state.WatcherRestartCount, $state.WatcherForcedRecoveryCount, $state.WatcherQueueCount, $state.DroppedStaleAdvertisements, $state.WatcherDroppedQueueRecords, $state.LastSessionReason, $state.NetworkReason)
            }

            if ([bool]$state.RuntimeWakeEnabled -and $hitOk -and $lockedAllowed -and $networkAllowed -and $phoneAllowed -and $cooldownOk -and $state.WasFarSinceLastTrigger) {
                $state.AutoUnlockTriggerDetectedUtc = $now
                $state.LastArrivalTriggerUtc = $now
                $state.InteractiveBleRecoveryRequested = $false
                if ($autoUnlockEnabled -and [bool]$state.RuntimeAutoUnlockEnabled -and $autoUnlockTriggerOnArrival -and [bool]$state.InteractiveWakePending) {
                    $state.InteractiveWakePending = $false
                    Write-Log "Arrival trigger superseded the pending interactive-wake candidate."
                }
                Write-Log ("Triggering wake. Address={0} Name={1} RSSI={2} Count={3} FastPath={4} Locked={5} Known={6} PhoneAllowed={7} PhoneRSSI={8} NetworkReason={9}" -f $state.LastMatchAddress, $state.LastMatchName, $state.LastMatchRssi, $state.MatchCount, $state.LastMatchFastPath, $state.IsLocked, $state.SessionKnown, $phoneAllowed, $state.LastPhoneRssi, $state.NetworkReason)
                $pureCredentialProviderArrival = $autoUnlockEnabled -and [bool]$state.RuntimeAutoUnlockEnabled -and $autoUnlockTriggerOnArrival -and -not $autoUnlockInvokeWakeToLoginOnArrival -and -not $ForceWakeTest
                if (-not $pureCredentialProviderArrival) {
                    $state.IgnoreInteractiveInputUntilUtc = $now.AddSeconds(3)
                    Invoke-WakeToLogin -Config $config
                }
                else {
                    Invoke-DisplayPowerRequest -Config $config
                    Write-Log "Credential Provider arrival path: wake-to-login simulation skipped."
                }
                if ($autoUnlockEnabled -and [bool]$state.RuntimeAutoUnlockEnabled -and $autoUnlockTriggerOnArrival -and -not $ForceWakeTest) {
                    $networkAllowed = Update-NetworkAllowedState -State $state -Config $config -NowUtc ([DateTime]::UtcNow)
                    $autoUnlockNetworkReady = (-not $autoUnlockRequireAllowedNetwork) -or $networkAllowed
                    $autoUnlockPowerReady = (-not $autoUnlockRequireAcPower) -or $pluggedIn
                    $autoUnlockPhoneReady = (-not $autoUnlockRequirePhonePresence) -or $phoneAllowed
                    [void](Invoke-AutoUnlockAttempt `
                        -State $state `
                        -Trigger "arrival" `
                        -NetworkReady $autoUnlockNetworkReady `
                        -PowerReady $autoUnlockPowerReady `
                        -PhoneReady $autoUnlockPhoneReady `
                        -PipeName $autoUnlockPipeName `
                        -LoginPageDelayMilliseconds $autoUnlockLoginPageDelayMilliseconds `
                        -AuthorizationTtlMilliseconds ([uint32]$autoUnlockAuthorizationTtlMilliseconds) `
                        -ResponseTimeoutMilliseconds $autoUnlockResponseTimeoutMilliseconds)
                }
                $state.LastTriggerUtc = $now
                $state.WasFarSinceLastTrigger = $false
                $state.MatchCount = 0
            }

            if ([bool]$state.InteractiveWakePending) {
                if (-not [bool]$state.IsLocked -or [bool]$state.AutoUnlockAttempted) {
                    $state.InteractiveWakePending = $false
                }
                else {
                    $interactiveRecoveryReady = [bool]$state.InteractiveBleRecoveryActive
                    $watchPresenceTimestamp = if ([bool]$state.ResumePresenceRequired) { [DateTime]$state.LastPostResumeWatchSeenUtc } else { [DateTime]$state.LastMatchedUtc }
                    $watchFresh = Test-RecentUtcTimestamp -TimestampUtc $watchPresenceTimestamp -NowUtc $now -MaximumAgeSeconds $interactiveWakeMaxWatchAgeSeconds
                    $interactiveNetworkReady = (-not $autoUnlockRequireAllowedNetwork) -or $networkAllowed
                    $interactivePowerReady = (-not $autoUnlockRequireAcPower) -or $pluggedIn
                    $postResumePhoneReady = (-not [bool]$state.ResumePresenceRequired) -or ([DateTime]$state.LastPostResumePhoneSeenUtc -ne [DateTime]::MinValue)
                    $interactivePhoneReady = (-not $autoUnlockRequirePhonePresence) -or ($phoneAllowed -and $postResumePhoneReady)
                    $interactiveLogonUiReady = Test-LogonUiPresent
                    if ($interactiveRecoveryReady -and $watchFresh -and $interactivePowerReady -and $interactivePhoneReady -and $interactiveLogonUiReady) {
                        $networkAllowed = Update-NetworkAllowedState -State $state -Config $config -NowUtc ([DateTime]::UtcNow)
                        $interactiveNetworkReady = (-not $autoUnlockRequireAllowedNetwork) -or $networkAllowed
                        if ($interactiveNetworkReady) {
                            Write-Log ("Interactive wake presence confirmed. WatchAgeSec={0:N1} PhoneAgeSec={1:N1} PostResume={2} RSSI={3} NetworkReason={4}" -f ($now - $watchPresenceTimestamp).TotalSeconds, $(if ([DateTime]$state.LastPhoneSeenUtc -eq [DateTime]::MinValue) { -1 } else { ($now - [DateTime]$state.LastPhoneSeenUtc).TotalSeconds }), $state.ResumePresenceRequired, $state.LastMatchRssi, $state.NetworkReason)
                            $state.InteractiveWakePending = $false
                            [void](Invoke-AutoUnlockAttempt `
                                -State $state `
                                -Trigger "interactive-wake" `
                                -NetworkReady $interactiveNetworkReady `
                                -PowerReady $interactivePowerReady `
                                -PhoneReady $interactivePhoneReady `
                                -PipeName $autoUnlockPipeName `
                                -LoginPageDelayMilliseconds $interactiveWakeLoginPageDelayMilliseconds `
                                -AuthorizationTtlMilliseconds ([uint32]$autoUnlockAuthorizationTtlMilliseconds) `
                                -ResponseTimeoutMilliseconds $autoUnlockResponseTimeoutMilliseconds)
                        }
                    }
                    if ([bool]$state.InteractiveWakePending -and $now -ge [DateTime]$state.InteractiveWakeDeadlineUtc) {
                        $state.InteractiveWakePending = $false
                        $state.AutoUnlockLastStatus = "interactive-timeout"
                        Write-Log ("Interactive wake confirmation timed out. RecoveryReady={0} RecoveryReason={1} WatchFresh={2} WatchAgeSec={3:N1} PhoneReady={4} PostResume={5} NetworkReady={6} PowerReady={7} LogonUI={8}" -f $interactiveRecoveryReady, $state.InteractiveBleRecoveryReason, $watchFresh, $(if ($watchPresenceTimestamp -eq [DateTime]::MinValue) { -1 } else { ($now - $watchPresenceTimestamp).TotalSeconds }), $interactivePhoneReady, $state.ResumePresenceRequired, $interactiveNetworkReady, $interactivePowerReady, $interactiveLogonUiReady) "WARN"
                    }
                }
            }

            $retryTrigger = [string]$state.AutoUnlockRetryTrigger
            $retryAfterUtc = [DateTime]$state.AutoUnlockRetryAfterUtc
            if ($autoUnlockEnabled -and [bool]$state.RuntimeAutoUnlockEnabled -and -not [bool]$state.AutoUnlockAttempted -and
                -not [string]::IsNullOrWhiteSpace($retryTrigger) -and
                $retryAfterUtc -ne [DateTime]::MinValue -and $now -ge $retryAfterUtc) {
                $networkAllowed = Update-NetworkAllowedState -State $state -Config $config -NowUtc ([DateTime]::UtcNow)
                $retryNetworkReady = (-not $autoUnlockRequireAllowedNetwork) -or $networkAllowed
                $retryPowerReady = (-not $autoUnlockRequireAcPower) -or $pluggedIn
                $retryPhoneReady = (-not $autoUnlockRequirePhonePresence) -or $phoneAllowed
                if ([bool]$state.IsLocked -and [bool]$state.SessionKnown -and $retryNetworkReady -and $retryPowerReady -and $retryPhoneReady) {
                    [void](Invoke-AutoUnlockAttempt `
                        -State $state `
                        -Trigger $retryTrigger `
                        -NetworkReady $retryNetworkReady `
                        -PowerReady $retryPowerReady `
                        -PhoneReady $retryPhoneReady `
                        -PipeName $autoUnlockPipeName `
                        -LoginPageDelayMilliseconds 0 `
                        -AuthorizationTtlMilliseconds ([uint32]$autoUnlockAuthorizationTtlMilliseconds) `
                        -ResponseTimeoutMilliseconds $autoUnlockResponseTimeoutMilliseconds)
                }
                else {
                    $state.AutoUnlockAttempted = $true
                    $state.AutoUnlockRetryAfterUtc = [DateTime]::MinValue
                    $state.AutoUnlockRetryTrigger = ""
                    $state.AutoUnlockLastStatus = "retry-cancelled:conditions"
                    Write-Log ("Auto-unlock retry cancelled because conditions changed. Locked={0} Known={1} NetworkReady={2} PowerReady={3} PhoneReady={4}" -f $state.IsLocked, $state.SessionKnown, $retryNetworkReady, $retryPowerReady, $retryPhoneReady) "WARN"
                }
            }

            $status = "Locked={0} Net={1} AC={2} AutoLock={3} Unlock={4} Hold={5}/{6} Hits={7}/{8} RSSI={9}" -f $state.IsLocked, $networkAllowed, $pluggedIn, $state.AutoLockArmed, $state.AutoUnlockLastStatus, $state.PowerHoldActive, $powerHoldMode, $state.MatchCount, $hitCount, $state.LastMatchRssi
            $state.LastStatus = $status
            if ($notifyIcon) {
                $traySessionText = if (-not [bool]$state.SessionKnown) { "Unknown" } elseif ([bool]$state.IsLocked) { "Locked" } else { "Unlocked" }
                $trayNetworkText = if ($networkAllowed) { "Net OK" } else { "Net blocked" }
                $trayText = "BLE Proximity Wake | $traySessionText | $trayNetworkText | RSSI $($state.LastMatchRssi)"
                $notifyIcon.Text = if ($trayText.Length -gt 63) { $trayText.Substring(0, 63) } else { $trayText }
            }
        }
        catch {
            Write-Log $_.Exception.Message "ERROR"
        }
    })

    Write-Log "Starting BLE watcher. Config=$ConfigPath Log=$logFile"
    $bridge.Start()
    $timer.Start()

    if ($NoTray) {
        Write-Log "Running without tray. Press Ctrl+C to stop."
        $startedUtc = [DateTime]::UtcNow
        while ($RunSeconds -le 0 -or ([DateTime]::UtcNow - $startedUtc).TotalSeconds -lt $RunSeconds) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }
    }
    else {
        [System.Windows.Forms.Application]::Run()
    }
}
finally {
    Write-Log "Stopping."
    Set-ConditionalPowerHold -State $state -ShouldHold $false
    [void][BleProximityWakeNative]::SetThreadExecutionState([BleProximityWakeNative]::ES_CONTINUOUS)
    [BleProximityWakeNative]::UnregisterConsoleCtrlHandler()
    if ($timer) {
        $timer.Stop()
        $timer.Dispose()
    }
    if ($bridge) {
        $bridge.Dispose()
    }
    if ($notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
    if ($trayIcon) {
        $trayIcon.Dispose()
    }
    if ($powerMonitor) {
        $powerMonitor.Dispose()
    }
    Unregister-Event -SourceIdentifier $sessionSourceId -ErrorAction SilentlyContinue
    Get-Event -SourceIdentifier $sessionSourceId -ErrorAction SilentlyContinue | Remove-Event
    Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
    if ($createdNewInstance) {
        $instanceMutex.ReleaseMutex()
    }
    $instanceMutex.Dispose()
}
