using System;

namespace BleProximityWake.Core.Presence
{
    public sealed class PresencePolicy
    {
        public PresenceMode Mode { get; set; }

        public bool RequireFreshAfterResume { get; set; }

        public void Validate(string name)
        {
            if (!Enum.IsDefined(typeof(PresenceMode), Mode))
            {
                throw new InvalidOperationException(name + " contains an unsupported presence mode.");
            }
        }
    }
}
