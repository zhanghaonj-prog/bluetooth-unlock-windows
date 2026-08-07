using System;

namespace BleProximityWake.Agent.AutoUnlock
{
    internal interface IAutoUnlockRequestRunner
    {
        bool IsRunning { get; }

        void Start(Func<AutoUnlockBrokerResult> request);

        bool TryTakeCompleted(
            out AutoUnlockBrokerResult result,
            out Exception exception);
    }
}
