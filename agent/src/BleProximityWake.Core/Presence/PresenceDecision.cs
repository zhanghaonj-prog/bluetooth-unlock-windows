namespace BleProximityWake.Core.Presence
{
    public sealed class PresenceDecision
    {
        public PresenceMode Mode { get; set; }

        public bool WatchRequired { get; set; }

        public bool PhoneRequired { get; set; }

        public bool WatchSatisfied { get; set; }

        public bool PhoneSatisfied { get; set; }

        public bool PresenceReady { get; set; }

        public string Reason { get; set; }
    }
}
