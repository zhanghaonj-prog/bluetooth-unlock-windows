using System;
using BleProximityWake.Core.Bluetooth;
using BleProximityWake.Core.Scanning;

namespace BleProximityWake.Agent.Bluetooth
{
    internal interface IBleAdvertisementSource : IDisposable
    {
        bool EnsureStarted(BleScanMode mode);

        bool Restart(BleScanMode mode);

        BleAdvertisement[] Drain(int maximumRecords);

        int Clear();

        string Status { get; }

        BleScanMode Mode { get; }

        int QueueCount { get; }

        int DroppedQueueRecords { get; }

        int RestartCount { get; }

        int ForcedRecoveryCount { get; }

        string LastStopError { get; }
    }
}
