namespace BleProximityWake.Core.Presence
{
    public sealed class PresenceObservation
    {
        public bool WatchReady { get; set; }

        public bool PhoneReady { get; set; }

        public bool WatchFreshAfterResume { get; set; }

        public bool PhoneFreshAfterResume { get; set; }
    }
}
