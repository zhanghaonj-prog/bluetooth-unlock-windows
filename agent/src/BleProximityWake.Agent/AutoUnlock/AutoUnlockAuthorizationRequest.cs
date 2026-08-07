using System;

namespace BleProximityWake.Agent.AutoUnlock
{
    internal sealed class AutoUnlockAuthorizationRequest
    {
        internal int SessionId { get; set; }

        internal uint AuthorizationTtlMilliseconds { get; set; }

        internal ulong LockCycleId { get; set; }

        internal Guid RequestId { get; set; }

        internal string UserSid { get; set; }
    }
}
