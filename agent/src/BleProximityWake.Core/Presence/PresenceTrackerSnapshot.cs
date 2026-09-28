using System;

namespace BleProximityWake.Core.Presence
{
    public sealed class PresenceTrackerSnapshot
    {
        public PresenceObservation Observation { get; set; }

        public bool WakeWatchReady { get; set; }

        public string PreferredWatchAddress { get; set; }

        public int PreferredWatchHits { get; set; }

        public string LastWatchAddress { get; set; }

        public int LastWatchRssi { get; set; }

        public DateTime LastWatchSeenUtc { get; set; }

        public int WatchHits { get; set; }

        public string LastPhoneAddress { get; set; }

        public int LastPhoneRssi { get; set; }

        public DateTime LastPhoneSeenUtc { get; set; }

        public int PhoneHits { get; set; }

        public bool PhoneFastPath { get; set; }

        public bool PhoneConfirmedByHitCount { get; set; }

        public bool WatchPresentForDeparture { get; set; }

        public DateTime LastWatchDepartureSeenUtc { get; set; }

        public bool PhonePresentForDeparture { get; set; }

        public DateTime LastPhoneDepartureSeenUtc { get; set; }

        public int DroppedStaleAdvertisements { get; set; }
    }
}
