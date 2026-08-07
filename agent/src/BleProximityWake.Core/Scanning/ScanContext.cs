namespace BleProximityWake.Core.Scanning
{
    public sealed class ScanContext
    {
        public bool DetectionPaused { get; set; }

        public bool SessionLocked { get; set; }

        public bool NetworkAllowed { get; set; }

        public bool AcPowerConnected { get; set; }
    }
}
