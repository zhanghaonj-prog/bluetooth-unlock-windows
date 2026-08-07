function Add-BleBridgeType {
    if ("BleAdvertisementBridge" -as [type]) {
        return
    }

    $frameworkDir = Join-Path $env:SystemRoot "Microsoft.NET\Framework64\v4.0.30319"
    if (-not (Test-Path -LiteralPath $frameworkDir)) {
        $frameworkDir = Join-Path $env:SystemRoot "Microsoft.NET\Framework\v4.0.30319"
    }

    $winMetadataDir = Join-Path $env:SystemRoot "System32\WinMetadata"
    $windowsDevices = Join-Path $winMetadataDir "Windows.Devices.winmd"
    $windowsFoundation = Join-Path $winMetadataDir "Windows.Foundation.winmd"
    $windowsStorage = Join-Path $winMetadataDir "Windows.Storage.winmd"
    foreach ($path in @($windowsDevices, $windowsFoundation, $windowsStorage)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Required WinRT metadata not found: $path"
        }
    }

    $compilerParameters = New-Object System.CodeDom.Compiler.CompilerParameters
    [void]$compilerParameters.ReferencedAssemblies.Add((Join-Path $frameworkDir "System.Runtime.dll"))
    [void]$compilerParameters.ReferencedAssemblies.Add((Join-Path $frameworkDir "System.Runtime.InteropServices.WindowsRuntime.dll"))
    [void]$compilerParameters.ReferencedAssemblies.Add((Join-Path $frameworkDir "System.Runtime.WindowsRuntime.dll"))
    $compilerParameters.CompilerOptions = "/reference:`"$windowsDevices`" /reference:`"$windowsFoundation`" /reference:`"$windowsStorage`""

    $code = @"
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Threading;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Foundation;
using Windows.Storage.Streams;

public sealed class BleAdvertisementRecord
{
    public string Address { get; set; }
    public string Name { get; set; }
    public int Rssi { get; set; }
    public string ManufacturerData { get; set; }
    public string ServiceUuids { get; set; }
    public DateTime TimestampUtc { get; set; }
}

public sealed class BleAdvertisementBridge : IDisposable
{
    private const int MaxQueueRecords = 5000;
    private static readonly TimeSpan StoppingRecoveryTimeout = TimeSpan.FromSeconds(5);
    private BluetoothLEAdvertisementWatcher watcher;
    private readonly ConcurrentQueue<BleAdvertisementRecord> queue = new ConcurrentQueue<BleAdvertisementRecord>();
    private readonly object watcherLock = new object();
    private readonly object queueLock = new object();
    private readonly TypedEventHandler<BluetoothLEAdvertisementWatcher, BluetoothLEAdvertisementReceivedEventArgs> receivedHandler;
    private readonly TypedEventHandler<BluetoothLEAdvertisementWatcher, BluetoothLEAdvertisementWatcherStoppedEventArgs> stoppedHandler;
    private EventRegistrationToken receivedToken;
    private EventRegistrationToken stoppedToken;
    private readonly int manufacturerCompanyId;
    private readonly int samplingIntervalMilliseconds;
    private volatile bool disposed;
    private volatile string lastStopError = "";
    private DateTime stoppingSinceUtc = DateTime.MinValue;
    private int queueCount;
    private int droppedQueueRecords;
    private int restartCount;
    private int forcedRecoveryCount;

    public BleAdvertisementBridge()
        : this(-1, 1000)
    {
    }

    public BleAdvertisementBridge(int manufacturerCompanyId, int samplingIntervalMilliseconds)
    {
        this.manufacturerCompanyId = manufacturerCompanyId;
        this.samplingIntervalMilliseconds = samplingIntervalMilliseconds;
        receivedHandler = new TypedEventHandler<BluetoothLEAdvertisementWatcher, BluetoothLEAdvertisementReceivedEventArgs>(OnReceived);
        stoppedHandler = new TypedEventHandler<BluetoothLEAdvertisementWatcher, BluetoothLEAdvertisementWatcherStoppedEventArgs>(OnStopped);
        CreateWatcher(BluetoothLEScanningMode.Passive);
    }

    private void CreateWatcher(BluetoothLEScanningMode mode)
    {
        watcher = new BluetoothLEAdvertisementWatcher();
        watcher.ScanningMode = mode;
        if (samplingIntervalMilliseconds > 0)
        {
            watcher.SignalStrengthFilter.SamplingInterval = TimeSpan.FromMilliseconds(samplingIntervalMilliseconds);
        }
        if (manufacturerCompanyId >= 0 && manufacturerCompanyId <= UInt16.MaxValue)
        {
            BluetoothLEManufacturerData manufacturerFilter = new BluetoothLEManufacturerData();
            manufacturerFilter.CompanyId = (ushort)manufacturerCompanyId;
            watcher.AdvertisementFilter.Advertisement.ManufacturerData.Add(manufacturerFilter);
        }
        receivedToken = (EventRegistrationToken)typeof(BluetoothLEAdvertisementWatcher)
            .GetMethod("add_Received")
            .Invoke(watcher, new object[] { receivedHandler });
        stoppedToken = (EventRegistrationToken)typeof(BluetoothLEAdvertisementWatcher)
            .GetMethod("add_Stopped")
            .Invoke(watcher, new object[] { stoppedHandler });
    }

    public void Start()
    {
        EnsureStarted(false);
    }

    public bool EnsureStarted(bool activeScanning)
    {
        lock (watcherLock)
        {
            if (disposed) throw new ObjectDisposedException("BleAdvertisementBridge");

            BluetoothLEScanningMode desiredMode = activeScanning
                ? BluetoothLEScanningMode.Active
                : BluetoothLEScanningMode.Passive;
            BluetoothLEAdvertisementWatcherStatus status = watcher.Status;

            if (status == BluetoothLEAdvertisementWatcherStatus.Started && watcher.ScanningMode == desiredMode)
            {
                stoppingSinceUtc = DateTime.MinValue;
                return false;
            }
            if (status == BluetoothLEAdvertisementWatcherStatus.Stopping)
            {
                if (stoppingSinceUtc == DateTime.MinValue)
                {
                    stoppingSinceUtc = DateTime.UtcNow;
                    return false;
                }
                if (DateTime.UtcNow - stoppingSinceUtc < StoppingRecoveryTimeout)
                {
                    return false;
                }

                ReplaceWatcher(desiredMode, "ForcedRecoveryFromStopping");
                Interlocked.Increment(ref forcedRecoveryCount);
                Interlocked.Increment(ref restartCount);
                watcher.Start();
                return true;
            }
            if (status == BluetoothLEAdvertisementWatcherStatus.Started)
            {
                watcher.Stop();
                if (watcher.Status == BluetoothLEAdvertisementWatcherStatus.Stopping)
                {
                    stoppingSinceUtc = DateTime.UtcNow;
                    return false;
                }
            }

            stoppingSinceUtc = DateTime.MinValue;
            watcher.ScanningMode = desiredMode;
            watcher.Start();
            Interlocked.Increment(ref restartCount);
            return true;
        }
    }

    private void ReplaceWatcher(BluetoothLEScanningMode desiredMode, string stopReason)
    {
        BluetoothLEAdvertisementWatcher oldWatcher = watcher;
        try
        {
            typeof(BluetoothLEAdvertisementWatcher).GetMethod("remove_Received")
                .Invoke(oldWatcher, new object[] { receivedToken });
            typeof(BluetoothLEAdvertisementWatcher).GetMethod("remove_Stopped")
                .Invoke(oldWatcher, new object[] { stoppedToken });
        }
        catch
        {
            // The old WinRT watcher is abandoned even if event unregistration fails.
        }
        try { oldWatcher.Stop(); } catch { }
        lastStopError = stopReason ?? "";
        stoppingSinceUtc = DateTime.MinValue;
        CreateWatcher(desiredMode);
    }

    public int Restart(bool activeScanning, bool clearQueue)
    {
        lock (watcherLock)
        {
            if (disposed) throw new ObjectDisposedException("BleAdvertisementBridge");

            BluetoothLEScanningMode desiredMode = activeScanning
                ? BluetoothLEScanningMode.Active
                : BluetoothLEScanningMode.Passive;
            ReplaceWatcher(desiredMode, "");
            int cleared = clearQueue ? ClearQueue() : 0;
            watcher.Start();
            Interlocked.Increment(ref restartCount);
            return cleared;
        }
    }

    public string GetStatus()
    {
        return watcher.Status.ToString();
    }

    public string GetScanningMode()
    {
        return watcher.ScanningMode.ToString();
    }

    public string GetLastStopError()
    {
        return lastStopError;
    }

    public int GetRestartCount()
    {
        return Volatile.Read(ref restartCount);
    }

    public int GetForcedRecoveryCount()
    {
        return Volatile.Read(ref forcedRecoveryCount);
    }

    public int GetQueueCount()
    {
        return Volatile.Read(ref queueCount);
    }

    public int GetDroppedQueueRecords()
    {
        return Volatile.Read(ref droppedQueueRecords);
    }

    public void Stop()
    {
        lock (watcherLock)
        {
            if (!disposed) watcher.Stop();
        }
    }

    public BleAdvertisementRecord[] Drain(int maxRecords)
    {
        if (maxRecords <= 0) maxRecords = 500;
        var list = new List<BleAdvertisementRecord>();
        lock (queueLock)
        {
            BleAdvertisementRecord item;
            while (list.Count < maxRecords && queue.TryDequeue(out item))
            {
                Interlocked.Decrement(ref queueCount);
                list.Add(item);
            }
        }
        return list.ToArray();
    }

    public int ClearQueue()
    {
        lock (queueLock)
        {
            int cleared = 0;
            BleAdvertisementRecord item;
            while (queue.TryDequeue(out item)) cleared++;
            Interlocked.Exchange(ref queueCount, 0);
            return cleared;
        }
    }

    public void Dispose()
    {
        lock (watcherLock)
        {
            if (disposed) return;
            disposed = true;
            typeof(BluetoothLEAdvertisementWatcher)
                .GetMethod("remove_Received")
                .Invoke(watcher, new object[] { receivedToken });
            typeof(BluetoothLEAdvertisementWatcher)
                .GetMethod("remove_Stopped")
                .Invoke(watcher, new object[] { stoppedToken });
            watcher.Stop();
        }
    }

    private void OnReceived(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
    {
        if (disposed || !Object.ReferenceEquals(sender, watcher)) return;
        var record = new BleAdvertisementRecord();
        record.Address = FormatAddress(args.BluetoothAddress);
        record.Name = args.Advertisement.LocalName ?? "";
        record.Rssi = args.RawSignalStrengthInDBm;
        record.ManufacturerData = FormatManufacturerData(args.Advertisement);
        record.ServiceUuids = FormatServiceUuids(args.Advertisement);
        record.TimestampUtc = args.Timestamp.UtcDateTime;
        lock (queueLock)
        {
            if (disposed || !Object.ReferenceEquals(sender, watcher)) return;
            BleAdvertisementRecord dropped;
            while (Volatile.Read(ref queueCount) >= MaxQueueRecords && queue.TryDequeue(out dropped))
            {
                Interlocked.Decrement(ref queueCount);
                Interlocked.Increment(ref droppedQueueRecords);
            }
            queue.Enqueue(record);
            Interlocked.Increment(ref queueCount);
        }
    }

    private void OnStopped(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementWatcherStoppedEventArgs args)
    {
        if (disposed || !Object.ReferenceEquals(sender, watcher)) return;
        lastStopError = args.Error.ToString();
    }

    private static string FormatAddress(ulong address)
    {
        string hex = address.ToString("X12");
        return string.Format(
            "{0}:{1}:{2}:{3}:{4}:{5}",
            hex.Substring(0, 2),
            hex.Substring(2, 2),
            hex.Substring(4, 2),
            hex.Substring(6, 2),
            hex.Substring(8, 2),
            hex.Substring(10, 2));
    }

    private static string FormatServiceUuids(BluetoothLEAdvertisement advertisement)
    {
        var items = new List<string>();
        foreach (var uuid in advertisement.ServiceUuids)
        {
            items.Add(uuid.ToString());
        }
        return string.Join(";", items.ToArray());
    }

    private static string FormatManufacturerData(BluetoothLEAdvertisement advertisement)
    {
        var items = new List<string>();
        foreach (var item in advertisement.ManufacturerData)
        {
            byte[] bytes = new byte[(int)item.Data.Length];
            using (DataReader reader = DataReader.FromBuffer(item.Data))
            {
                reader.ReadBytes(bytes);
            }
            items.Add(item.CompanyId.ToString("X4") + ":" + BytesToHex(bytes));
        }
        return string.Join(";", items.ToArray());
    }

    private static string BytesToHex(byte[] bytes)
    {
        char[] chars = new char[bytes.Length * 2];
        const string alphabet = "0123456789ABCDEF";
        for (int i = 0; i < bytes.Length; i++)
        {
            chars[i * 2] = alphabet[bytes[i] >> 4];
            chars[i * 2 + 1] = alphabet[bytes[i] & 0xF];
        }
        return new string(chars);
    }
}
"@

    Add-Type -CompilerParameters $compilerParameters -TypeDefinition $code
}
