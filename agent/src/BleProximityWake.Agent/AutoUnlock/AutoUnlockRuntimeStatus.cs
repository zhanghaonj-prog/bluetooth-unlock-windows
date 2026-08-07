using System;

namespace BleProximityWake.Agent.AutoUnlock
{
    internal sealed class AutoUnlockRuntimeStatus
    {
        internal string State { get; set; }

        internal ulong LockCycleId { get; set; }

        internal bool Attempted { get; set; }

        internal bool RequestPending { get; set; }

        internal bool RequestStarted { get; set; }

        internal int RetryCount { get; set; }

        internal AutoUnlockBrokerStatus? BrokerStatus { get; set; }

        internal Guid RequestId { get; set; }

        internal string Error { get; set; }
    }
}
