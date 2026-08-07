namespace BleProximityWake.Core.Scanning
{
    public sealed class ScanProfile
    {
        public BleScanMode Mode { get; set; }

        public int PollIntervalMilliseconds { get; set; }

        public string Reason { get; set; }
    }
}
