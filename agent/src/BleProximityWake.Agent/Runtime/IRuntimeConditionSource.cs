using System;

namespace BleProximityWake.Agent.Runtime
{
    internal interface IRuntimeConditionSource : IDisposable
    {
        RuntimeConditionSnapshot Capture();

        NetworkContextSnapshot RefreshNetwork();
    }
}
