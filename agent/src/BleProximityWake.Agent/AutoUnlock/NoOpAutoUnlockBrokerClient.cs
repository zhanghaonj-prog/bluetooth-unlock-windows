namespace BleProximityWake.Agent.AutoUnlock
{
    internal sealed class NoOpAutoUnlockBrokerClient : IAutoUnlockBrokerClient
    {
        public AutoUnlockBrokerResult Authorize(
            ulong lockCycleId,
            int authorizationTtlMilliseconds)
        {
            return new AutoUnlockBrokerResult
            {
                Status = AutoUnlockBrokerStatus.InternalError
            };
        }
    }
}
