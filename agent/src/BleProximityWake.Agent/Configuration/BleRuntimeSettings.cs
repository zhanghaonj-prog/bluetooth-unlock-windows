namespace BleProximityWake.Agent.Configuration
{
    public sealed class BleRuntimeSettings
    {
        public bool Enabled { get; set; } = true;

        public int ManufacturerCompanyId { get; set; } = 0x004C;

        public int SamplingIntervalMilliseconds { get; set; } = 500;

        public int LockedPollIntervalMilliseconds { get; set; } = 250;

        public int BackgroundPollIntervalMilliseconds { get; set; } = 1000;

        public int HeartbeatSeconds { get; set; } = 10;

        public void Validate()
        {
            if (ManufacturerCompanyId < -1 || ManufacturerCompanyId > ushort.MaxValue)
            {
                throw new System.InvalidOperationException(
                    "ManufacturerCompanyId must be -1 or a valid UInt16 value.");
            }

            RequirePositive(SamplingIntervalMilliseconds, "SamplingIntervalMilliseconds");
            RequirePositive(LockedPollIntervalMilliseconds, "LockedPollIntervalMilliseconds");
            RequirePositive(BackgroundPollIntervalMilliseconds, "BackgroundPollIntervalMilliseconds");
            RequirePositive(HeartbeatSeconds, "HeartbeatSeconds");
        }

        private static void RequirePositive(int value, string name)
        {
            if (value <= 0)
            {
                throw new System.InvalidOperationException(name + " must be positive.");
            }
        }
    }
}
