using System;

namespace BleProximityWake.Agent.Configuration
{
    internal sealed class AutoUnlockSettings
    {
        public bool Enabled { get; set; }

        public int AuthorizationTtlMilliseconds { get; set; } = 5000;

        public int ResponseTimeoutMilliseconds { get; set; } = 3000;

        public bool RequireAllowedNetwork { get; set; } = true;

        public bool RequireAcPower { get; set; } = true;

        public bool TriggerOnArrival { get; set; } = true;

        public bool TriggerOnInteractiveWake { get; set; } = true;

        public int InteractiveWakeMinimumPriorIdleMilliseconds { get; set; } = 1000;

        public int InteractiveWakeInputFreshMilliseconds { get; set; } = 2000;

        public int InteractiveWakeMaximumPresenceAgeMilliseconds { get; set; } = 5000;

        public int InteractiveWakeConfirmationMilliseconds { get; set; } = 6000;

        public bool InteractiveWakeAllowIdleFallback { get; set; } = true;

        internal void Validate()
        {
            if (AuthorizationTtlMilliseconds < 1000 ||
                AuthorizationTtlMilliseconds > 10000)
            {
                throw new InvalidOperationException(
                    "Auto-unlock authorization TTL must be between 1000 and 10000 ms.");
            }

            if (ResponseTimeoutMilliseconds < 500 ||
                ResponseTimeoutMilliseconds > 10000)
            {
                throw new InvalidOperationException(
                    "Auto-unlock Broker response timeout must be between 500 and 10000 ms.");
            }

            if (Enabled && !TriggerOnArrival && !TriggerOnInteractiveWake)
            {
                throw new InvalidOperationException(
                    "Auto-unlock requires at least one trigger mode.");
            }

            if (InteractiveWakeMinimumPriorIdleMilliseconds < 1000 ||
                InteractiveWakeMinimumPriorIdleMilliseconds > 3600000)
            {
                throw new InvalidOperationException(
                    "Interactive wake prior idle must be between 1000 and 3600000 ms.");
            }

            if (InteractiveWakeInputFreshMilliseconds < 100 ||
                InteractiveWakeInputFreshMilliseconds > 10000)
            {
                throw new InvalidOperationException(
                    "Interactive wake input freshness must be between 100 and 10000 ms.");
            }

            if (InteractiveWakeMaximumPresenceAgeMilliseconds < 500 ||
                InteractiveWakeMaximumPresenceAgeMilliseconds > 30000)
            {
                throw new InvalidOperationException(
                    "Interactive wake presence age must be between 500 and 30000 ms.");
            }

            if (InteractiveWakeConfirmationMilliseconds < 500 ||
                InteractiveWakeConfirmationMilliseconds > 15000)
            {
                throw new InvalidOperationException(
                    "Interactive wake confirmation must be between 500 and 15000 ms.");
            }
        }
    }
}
