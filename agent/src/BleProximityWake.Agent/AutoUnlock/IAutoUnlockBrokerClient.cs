namespace BleProximityWake.Agent.AutoUnlock
{
    internal interface IAutoUnlockBrokerClient
    {
        AutoUnlockBrokerResult Authorize(ulong lockCycleId, int authorizationTtlMilliseconds);
    }
}
