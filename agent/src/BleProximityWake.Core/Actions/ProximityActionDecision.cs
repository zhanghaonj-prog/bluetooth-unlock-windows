namespace BleProximityWake.Core.Actions
{
    public sealed class ProximityActionDecision
    {
        public ProximityActionType Action { get; set; }

        public bool ArrivalConfirmed { get; set; }

        public string Reason { get; set; }

        public bool WakeArmed { get; set; }

        public bool AutoLockArmed { get; set; }
    }
}
