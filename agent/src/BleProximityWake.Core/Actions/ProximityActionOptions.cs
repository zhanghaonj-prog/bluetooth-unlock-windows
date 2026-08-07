using System;

namespace BleProximityWake.Core.Actions
{
    public sealed class ProximityActionOptions
    {
        public bool WakeEnabled { get; set; }

        public bool ArrivalDetectionEnabled { get; set; }

        public int WakeCooldownSeconds { get; set; } = 45;

        public int WakeRearmSeconds { get; set; } = 30;

        public int WakeFailureRetrySeconds { get; set; } = 2;

        public int WakeFailureMaximumRetries { get; set; } = 3;

        public bool AutoLockEnabled { get; set; }

        public int AutoLockAbsenceSeconds { get; set; } = 30;

        public int AutoLockMinimumIdleSeconds { get; set; } = 30;

        public int AutoLockRetrySeconds { get; set; } = 10;

        public void Validate()
        {
            ValidateRange(WakeCooldownSeconds, 1, 3600, "WakeCooldownSeconds");
            ValidateRange(WakeRearmSeconds, 1, 600, "WakeRearmSeconds");
            ValidateRange(WakeFailureRetrySeconds, 1, 60, "WakeFailureRetrySeconds");
            ValidateRange(WakeFailureMaximumRetries, 0, 10, "WakeFailureMaximumRetries");
            ValidateRange(AutoLockAbsenceSeconds, 5, 3600, "AutoLockAbsenceSeconds");
            ValidateRange(AutoLockMinimumIdleSeconds, 0, 3600, "AutoLockMinimumIdleSeconds");
            ValidateRange(AutoLockRetrySeconds, 1, 600, "AutoLockRetrySeconds");
        }

        private static void ValidateRange(int value, int minimum, int maximum, string name)
        {
            if (value < minimum || value > maximum)
            {
                throw new InvalidOperationException(
                    name + " must be between " + minimum + " and " + maximum + ".");
            }
        }
    }
}
