using System;
using BleProximityWake.Core.Presence;

namespace BleProximityWake.Core.Actions
{
    public sealed class ProximityActionInput
    {
        public DateTime NowUtc { get; set; }

        public bool SessionKnown { get; set; }

        public bool SessionLocked { get; set; }

        public bool NetworkAllowed { get; set; }

        public bool DetectionPaused { get; set; }

        public bool WakePresenceReady { get; set; }

        public PresenceMode AutoLockMode { get; set; }

        public bool WatchPresentForDeparture { get; set; }

        public bool PhonePresentForDeparture { get; set; }

        public DateTime LastWatchDepartureSeenUtc { get; set; }

        public DateTime LastPhoneDepartureSeenUtc { get; set; }

        public double UserIdleSeconds { get; set; }
    }
}
