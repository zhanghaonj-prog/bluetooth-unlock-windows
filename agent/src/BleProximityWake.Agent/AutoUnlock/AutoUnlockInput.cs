using System;

namespace BleProximityWake.Agent.AutoUnlock
{
    internal sealed class AutoUnlockInput
    {
        internal DateTime NowUtc { get; set; }

        internal bool DetectionPaused { get; set; }

        internal bool SessionKnown { get; set; }

        internal bool SessionLocked { get; set; }

        internal bool NetworkAllowed { get; set; }

        internal bool AcPowerConnected { get; set; }

        internal bool PresenceReady { get; set; }

        internal bool ArrivalConfirmed { get; set; }

        internal bool InteractiveWakeConfirmed { get; set; }

        internal string InteractiveWakeTrigger { get; set; }
    }
}
