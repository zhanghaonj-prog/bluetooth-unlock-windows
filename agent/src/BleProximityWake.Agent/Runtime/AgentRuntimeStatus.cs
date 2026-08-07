using BleProximityWake.Agent.Actions;
using BleProximityWake.Agent.AutoUnlock;
using BleProximityWake.Core.Actions;
using BleProximityWake.Core.Presence;
using BleProximityWake.Core.Scanning;

namespace BleProximityWake.Agent.Runtime
{
    internal sealed class AgentRuntimeStatus
    {
        internal RuntimeConditionSnapshot Conditions { get; set; }

        internal ScanProfile ScanProfile { get; set; }

        internal PresenceTrackerSnapshot Presence { get; set; }

        internal PresenceDecision WakePresence { get; set; }

        internal PresenceDecision AutoUnlockPresence { get; set; }

        internal ProximityActionDecision AutoUnlockArrivalDecision { get; set; }

        internal AutoUnlockRuntimeStatus AutoUnlock { get; set; }

        internal InteractiveWakeRuntimeStatus InteractiveWake { get; set; }

        internal PresenceDecision AutoLockPresence { get; set; }

        internal ProximityActionDecision ActionDecision { get; set; }

        internal SystemActionResult ActionResult { get; set; }

        internal string WatcherStatus { get; set; }

        internal int QueueCount { get; set; }

        internal int DroppedQueueRecords { get; set; }

        internal int RestartCount { get; set; }

        internal int ForcedRecoveryCount { get; set; }
    }
}
