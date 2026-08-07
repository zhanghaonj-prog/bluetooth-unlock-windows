using System;
using BleProximityWake.Core.Actions;

namespace BleProximityWake.Agent.Configuration
{
    internal sealed class SystemActionSettings
    {
        public WakeActionSettings Wake { get; set; } = new WakeActionSettings();

        public AutoLockActionSettings AutoLock { get; set; } = new AutoLockActionSettings();

        internal void Validate()
        {
            if (Wake == null || AutoLock == null)
            {
                throw new InvalidOperationException("Wake and auto-lock action settings are required.");
            }

            Wake.Validate();
            ToCoordinatorOptions().Validate();
        }

        internal ProximityActionOptions ToCoordinatorOptions()
        {
            return new ProximityActionOptions
            {
                WakeEnabled = Wake.Enabled,
                ArrivalDetectionEnabled = Wake.Enabled,
                WakeCooldownSeconds = Wake.CooldownSeconds,
                WakeRearmSeconds = Wake.RearmSeconds,
                AutoLockEnabled = AutoLock.Enabled,
                AutoLockAbsenceSeconds = AutoLock.AbsenceSeconds,
                AutoLockMinimumIdleSeconds = AutoLock.MinimumUserIdleSeconds,
                AutoLockRetrySeconds = AutoLock.RetrySeconds
            };
        }
    }

    internal sealed class WakeActionSettings
    {
        public bool Enabled { get; set; }

        public int CooldownSeconds { get; set; } = 45;

        public int RearmSeconds { get; set; } = 30;

        public bool SendMonitorPowerMessage { get; set; } = true;

        public bool SendMouseNudge { get; set; } = true;

        public bool SendSpaceKey { get; set; } = true;

        internal void Validate()
        {
            if (Enabled &&
                !SendMonitorPowerMessage &&
                !SendMouseNudge &&
                !SendSpaceKey)
            {
                throw new InvalidOperationException(
                    "At least one wake input mechanism must be enabled.");
            }
        }
    }

    internal sealed class AutoLockActionSettings
    {
        public bool Enabled { get; set; }

        public int AbsenceSeconds { get; set; } = 30;

        public int MinimumUserIdleSeconds { get; set; } = 30;

        public int RetrySeconds { get; set; } = 10;
    }
}
