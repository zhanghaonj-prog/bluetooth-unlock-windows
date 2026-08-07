using System;

namespace BleProximityWake.Agent.AutoUnlock
{
    internal sealed class InteractiveWakeRuntimeStatus
    {
        internal string State { get; set; }

        internal bool Pending { get; set; }

        internal bool RecoveryRequested { get; set; }

        internal bool Confirmed { get; set; }

        internal string Trigger { get; set; }

        internal DateTime DeadlineUtc { get; set; }
    }
}
