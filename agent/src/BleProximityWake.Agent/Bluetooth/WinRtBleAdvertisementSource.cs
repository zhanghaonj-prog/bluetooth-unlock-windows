using System;
using System.Collections.Generic;
using System.Threading;
using BleProximityWake.Core.Bluetooth;
using BleProximityWake.Core.Scanning;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Storage.Streams;

namespace BleProximityWake.Agent.Bluetooth
{
    internal sealed class WinRtBleAdvertisementSource : IBleAdvertisementSource
    {
        private const int MaximumQueueRecords = 5000;
        private static readonly TimeSpan StartProtectionDuration =
            TimeSpan.FromMilliseconds(750);
        private static readonly TimeSpan StoppingRecoveryTimeout = TimeSpan.FromSeconds(5);
        private readonly object watcherGate = new object();
        private readonly object queueGate = new object();
        private readonly Queue<BleAdvertisement> queue = new Queue<BleAdvertisement>();
        private readonly int companyId;
        private readonly int samplingIntervalMilliseconds;
        private BluetoothLEAdvertisementWatcher watcher;
        private DateTime startProtectedUntilUtc = DateTime.MinValue;
        private DateTime stoppingSinceUtc = DateTime.MinValue;
        private bool disposed;
        private int droppedQueueRecords;
        private int restartCount;
        private int forcedRecoveryCount;
        private string lastStopError = string.Empty;

        internal WinRtBleAdvertisementSource(int companyId, int samplingIntervalMilliseconds)
        {
            this.companyId = companyId;
            this.samplingIntervalMilliseconds = samplingIntervalMilliseconds;
            CreateWatcher(BleScanMode.Passive);
        }

        public string Status
        {
            get
            {
                lock (watcherGate)
                {
                    return watcher.Status.ToString();
                }
            }
        }

        public BleScanMode Mode
        {
            get
            {
                lock (watcherGate)
                {
                    return watcher.ScanningMode == BluetoothLEScanningMode.Active
                        ? BleScanMode.Active
                        : BleScanMode.Passive;
                }
            }
        }

        public int QueueCount
        {
            get
            {
                lock (queueGate)
                {
                    return queue.Count;
                }
            }
        }

        public int DroppedQueueRecords => Volatile.Read(ref droppedQueueRecords);

        public int RestartCount => Volatile.Read(ref restartCount);

        public int ForcedRecoveryCount => Volatile.Read(ref forcedRecoveryCount);

        public string LastStopError => lastStopError;

        public bool EnsureStarted(BleScanMode mode)
        {
            lock (watcherGate)
            {
                ThrowIfDisposed();
                BluetoothLEScanningMode desiredMode = ToWinRtMode(mode);
                BluetoothLEAdvertisementWatcherStatus status = watcher.Status;
                DateTime nowUtc = DateTime.UtcNow;
                if (status == BluetoothLEAdvertisementWatcherStatus.Started &&
                    watcher.ScanningMode == desiredMode)
                {
                    startProtectedUntilUtc = DateTime.MinValue;
                    stoppingSinceUtc = DateTime.MinValue;
                    return false;
                }

                if (status == BluetoothLEAdvertisementWatcherStatus.Started)
                {
                    ReplaceWatcher(mode, string.Empty);
                    StartWatcher(nowUtc);
                    return true;
                }

                if (status == BluetoothLEAdvertisementWatcherStatus.Stopping)
                {
                    if (stoppingSinceUtc == DateTime.MinValue)
                    {
                        stoppingSinceUtc = DateTime.UtcNow;
                        return false;
                    }

                    if (nowUtc - stoppingSinceUtc < StoppingRecoveryTimeout)
                    {
                        return false;
                    }

                    ReplaceWatcher(mode, "ForcedRecoveryFromStopping");
                    Interlocked.Increment(ref forcedRecoveryCount);
                    StartWatcher(nowUtc);
                    return true;
                }

                if (IsStartProtected(
                    nowUtc,
                    startProtectedUntilUtc,
                    watcher.ScanningMode == desiredMode))
                {
                    return false;
                }

                stoppingSinceUtc = DateTime.MinValue;
                watcher.ScanningMode = desiredMode;
                StartWatcher(nowUtc);
                return true;
            }
        }

        public bool Restart(BleScanMode mode)
        {
            lock (watcherGate)
            {
                ThrowIfDisposed();
                ReplaceWatcher(mode, "InteractiveWakeRecovery");
                StartWatcher(DateTime.UtcNow);
                return true;
            }
        }

        internal static bool IsStartProtected(
            DateTime nowUtc,
            DateTime protectedUntilUtc,
            bool scanningModeMatches)
        {
            return scanningModeMatches && nowUtc < protectedUntilUtc;
        }

        public BleAdvertisement[] Drain(int maximumRecords)
        {
            if (maximumRecords <= 0)
            {
                maximumRecords = 500;
            }

            lock (queueGate)
            {
                int count = Math.Min(maximumRecords, queue.Count);
                var result = new BleAdvertisement[count];
                for (int index = 0; index < count; index++)
                {
                    result[index] = queue.Dequeue();
                }

                return result;
            }
        }

        public int Clear()
        {
            lock (queueGate)
            {
                int count = queue.Count;
                queue.Clear();
                return count;
            }
        }

        public void Dispose()
        {
            lock (watcherGate)
            {
                if (disposed)
                {
                    return;
                }

                disposed = true;
                DetachWatcher(watcher);
                try
                {
                    watcher.Stop();
                }
                catch
                {
                }
            }

            Clear();
        }

        private void CreateWatcher(BleScanMode mode)
        {
            watcher = new BluetoothLEAdvertisementWatcher
            {
                ScanningMode = ToWinRtMode(mode)
            };
            if (samplingIntervalMilliseconds > 0)
            {
                watcher.SignalStrengthFilter.SamplingInterval =
                    TimeSpan.FromMilliseconds(samplingIntervalMilliseconds);
            }

            if (companyId >= 0 && companyId <= ushort.MaxValue)
            {
                watcher.AdvertisementFilter.Advertisement.ManufacturerData.Add(
                    new BluetoothLEManufacturerData
                    {
                        CompanyId = (ushort)companyId
                    });
            }

            watcher.Received += OnReceived;
            watcher.Stopped += OnStopped;
        }

        private void ReplaceWatcher(BleScanMode mode, string reason)
        {
            BluetoothLEAdvertisementWatcher previous = watcher;
            DetachWatcher(previous);
            try
            {
                previous.Stop();
            }
            catch
            {
            }

            lastStopError = reason ?? string.Empty;
            stoppingSinceUtc = DateTime.MinValue;
            CreateWatcher(mode);
        }

        private void StartWatcher(DateTime nowUtc)
        {
            watcher.Start();
            startProtectedUntilUtc = nowUtc.Add(StartProtectionDuration);
            Interlocked.Increment(ref restartCount);
        }

        private void DetachWatcher(BluetoothLEAdvertisementWatcher value)
        {
            if (value == null)
            {
                return;
            }

            value.Received -= OnReceived;
            value.Stopped -= OnStopped;
        }

        private void OnReceived(
            BluetoothLEAdvertisementWatcher sender,
            BluetoothLEAdvertisementReceivedEventArgs args)
        {
            lock (watcherGate)
            {
                if (disposed || !object.ReferenceEquals(sender, watcher))
                {
                    return;
                }
            }

            var record = new BleAdvertisement
            {
                Address = BluetoothAddress.Format(args.BluetoothAddress),
                LocalName = args.Advertisement.LocalName ?? string.Empty,
                Rssi = args.RawSignalStrengthInDBm,
                TimestampUtc = args.Timestamp.UtcDateTime,
                ManufacturerData = ReadManufacturerData(args.Advertisement),
                ServiceUuids = ReadServiceUuids(args.Advertisement)
            };
            lock (queueGate)
            {
                if (disposed)
                {
                    return;
                }

                while (queue.Count >= MaximumQueueRecords)
                {
                    queue.Dequeue();
                    Interlocked.Increment(ref droppedQueueRecords);
                }

                queue.Enqueue(record);
            }
        }

        private void OnStopped(
            BluetoothLEAdvertisementWatcher sender,
            BluetoothLEAdvertisementWatcherStoppedEventArgs args)
        {
            lock (watcherGate)
            {
                if (!disposed && object.ReferenceEquals(sender, watcher))
                {
                    lastStopError = args.Error.ToString();
                }
            }
        }

        private static IList<string> ReadManufacturerData(
            BluetoothLEAdvertisement advertisement)
        {
            var result = new List<string>();
            foreach (BluetoothLEManufacturerData item in advertisement.ManufacturerData)
            {
                byte[] bytes = new byte[(int)item.Data.Length];
                using (DataReader reader = DataReader.FromBuffer(item.Data))
                {
                    reader.ReadBytes(bytes);
                }

                result.Add(item.CompanyId.ToString("X4") + ":" + ToHex(bytes));
            }

            return result;
        }

        private static IList<string> ReadServiceUuids(
            BluetoothLEAdvertisement advertisement)
        {
            var result = new List<string>();
            foreach (Guid serviceUuid in advertisement.ServiceUuids)
            {
                result.Add(serviceUuid.ToString());
            }

            return result;
        }

        private static string ToHex(byte[] bytes)
        {
            const string alphabet = "0123456789ABCDEF";
            char[] result = new char[bytes.Length * 2];
            for (int index = 0; index < bytes.Length; index++)
            {
                result[index * 2] = alphabet[bytes[index] >> 4];
                result[index * 2 + 1] = alphabet[bytes[index] & 0x0F];
            }

            return new string(result);
        }

        private static BluetoothLEScanningMode ToWinRtMode(BleScanMode mode)
        {
            return mode == BleScanMode.Active
                ? BluetoothLEScanningMode.Active
                : BluetoothLEScanningMode.Passive;
        }

        private void ThrowIfDisposed()
        {
            if (disposed)
            {
                throw new ObjectDisposedException("WinRtBleAdvertisementSource");
            }
        }
    }
}
