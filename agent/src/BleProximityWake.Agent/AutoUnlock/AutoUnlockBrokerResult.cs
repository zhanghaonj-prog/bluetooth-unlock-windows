using System;

namespace BleProximityWake.Agent.AutoUnlock
{
    internal sealed class AutoUnlockBrokerResult
    {
        internal AutoUnlockBrokerStatus Status { get; set; }

        internal Guid RequestId { get; set; }

        internal double ElapsedMilliseconds { get; set; }
    }
}
