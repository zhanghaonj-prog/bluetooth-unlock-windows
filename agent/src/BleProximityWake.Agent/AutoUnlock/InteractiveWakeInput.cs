using System;
using BleProximityWake.Agent.Runtime;

namespace BleProximityWake.Agent.AutoUnlock
{
    internal sealed class InteractiveWakeInput
    {
        internal DateTime NowUtc { get; set; }

        internal bool DetectionPaused { get; set; }

        internal bool SessionKnown { get; set; }

        internal bool SessionLocked { get; set; }

        internal bool AuthorizationAttempted { get; set; }

        internal bool AuthorizationPending { get; set; }

        internal bool NetworkAllowed { get; set; }

        internal bool AcPowerConnected { get; set; }

        internal bool PresenceReady { get; set; }

        internal bool PresenceFresh { get; set; }

        internal long ResumeSequence { get; set; }

        internal long DisplaySequence { get; set; }

        internal DisplayPowerState DisplayState { get; set; }

        internal bool DisplayWasOffSinceLock { get; set; }

        internal double UserIdleSeconds { get; set; }
    }
}
