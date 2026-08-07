namespace BleProximityWake.Core.Presence
{
    public sealed class PresencePolicySet
    {
        public PresencePolicy Wake { get; set; }

        public PresencePolicy AutoUnlock { get; set; }

        public PresencePolicy AutoLock { get; set; }

        public static PresencePolicySet CreateDefaults()
        {
            return new PresencePolicySet
            {
                Wake = new PresencePolicy
                {
                    Mode = PresenceMode.PhoneOnly,
                    RequireFreshAfterResume = false
                },
                AutoUnlock = new PresencePolicy
                {
                    Mode = PresenceMode.WatchAndPhone,
                    RequireFreshAfterResume = true
                },
                AutoLock = new PresencePolicy
                {
                    Mode = PresenceMode.PhoneOnly,
                    RequireFreshAfterResume = false
                }
            };
        }

        public void Validate()
        {
            if (Wake == null || AutoUnlock == null || AutoLock == null)
            {
                throw new System.InvalidOperationException("All presence policies must be configured.");
            }

            Wake.Validate("wake");
            AutoUnlock.Validate("autoUnlock");
            AutoLock.Validate("autoLock");
        }
    }
}
