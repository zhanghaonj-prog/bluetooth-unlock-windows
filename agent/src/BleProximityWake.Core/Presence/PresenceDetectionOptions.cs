using BleProximityWake.Core.Bluetooth;

namespace BleProximityWake.Core.Presence
{
    public sealed class PresenceDetectionOptions
    {
        public DeviceMatcherOptions WatchMatcher { get; set; } = new DeviceMatcherOptions();

        public int WatchRssiThreshold { get; set; } = -68;

        public int LearnedWatchRssiThreshold { get; set; } = -82;

        public int WatchHitCount { get; set; } = 1;

        public int WatchHitWindowSeconds { get; set; } = 10;

        public int WatchLostSeconds { get; set; } = 30;

        public int AddressLearningWindowSeconds { get; set; } = 20;

        public int AddressLearningMinimumHits { get; set; } = 3;

        public bool PhoneEnabled { get; set; }

        public DeviceMatcherOptions PhoneMatcher { get; set; } = new DeviceMatcherOptions();

        public int PhoneRssiThreshold { get; set; } = -82;

        public int PhoneStrongRssiSingleHitThreshold { get; set; } = -60;

        public int PhoneHitCount { get; set; } = 2;

        public int PhoneHitWindowSeconds { get; set; } = 10;

        public int PhonePresenceTimeoutSeconds { get; set; } = 20;

        public int MaximumAdvertisementAgeSeconds { get; set; } = 5;

        public void Validate()
        {
            if (WatchMatcher == null || PhoneMatcher == null)
            {
                throw new System.InvalidOperationException("Device matchers are required.");
            }

            WatchMatcher.Validate("watch");
            PhoneMatcher.Validate("phone");
            if (!PhoneEnabled)
            {
                throw new System.InvalidOperationException(
                    "Phone detection is required by all supported presence modes.");
            }
            RequirePositive(WatchHitCount, "WatchHitCount");
            RequirePositive(WatchHitWindowSeconds, "WatchHitWindowSeconds");
            RequirePositive(WatchLostSeconds, "WatchLostSeconds");
            RequirePositive(AddressLearningWindowSeconds, "AddressLearningWindowSeconds");
            RequirePositive(AddressLearningMinimumHits, "AddressLearningMinimumHits");
            RequirePositive(PhoneHitCount, "PhoneHitCount");
            RequirePositive(PhoneHitWindowSeconds, "PhoneHitWindowSeconds");
            RequirePositive(PhonePresenceTimeoutSeconds, "PhonePresenceTimeoutSeconds");
            RequirePositive(MaximumAdvertisementAgeSeconds, "MaximumAdvertisementAgeSeconds");
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
