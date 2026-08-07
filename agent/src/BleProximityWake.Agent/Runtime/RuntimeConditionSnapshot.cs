using System;

namespace BleProximityWake.Agent.Runtime
{
    internal sealed class RuntimeConditionSnapshot
    {
        internal bool SessionLocked { get; set; }

        internal bool SessionKnown { get; set; }

        internal bool AcPowerConnected { get; set; }

        internal NetworkContextSnapshot Network { get; set; }

        internal long ResumeSequence { get; set; }

        internal DateTime LastResumeUtc { get; set; }

        internal DisplayPowerState DisplayState { get; set; }

        internal long DisplaySequence { get; set; }

        internal bool DisplayWasOffSinceLock { get; set; }

        internal long InputSequence { get; set; }

        internal DateTime LastInputUtc { get; set; }

        internal double UserIdleSeconds { get; set; }
    }
}
