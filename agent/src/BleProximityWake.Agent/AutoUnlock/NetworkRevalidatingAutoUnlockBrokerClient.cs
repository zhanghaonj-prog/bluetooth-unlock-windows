using System;
using BleProximityWake.Agent.Runtime;

namespace BleProximityWake.Agent.AutoUnlock
{
    internal sealed class NetworkRevalidatingAutoUnlockBrokerClient : IAutoUnlockBrokerClient
    {
        private readonly IAutoUnlockBrokerClient inner;
        private readonly IRuntimeConditionSource conditions;
        private readonly bool requireAllowedNetwork;

        internal NetworkRevalidatingAutoUnlockBrokerClient(
            IAutoUnlockBrokerClient inner,
            IRuntimeConditionSource conditions,
            bool requireAllowedNetwork)
        {
            this.inner = inner ?? throw new ArgumentNullException("inner");
            this.conditions = conditions ?? throw new ArgumentNullException("conditions");
            this.requireAllowedNetwork = requireAllowedNetwork;
        }

        public AutoUnlockBrokerResult Authorize(
            ulong lockCycleId,
            int authorizationTtlMilliseconds)
        {
            if (requireAllowedNetwork)
            {
                NetworkContextSnapshot network = conditions.RefreshNetwork();
                if (network == null || !network.Allowed)
                {
                    return new AutoUnlockBrokerResult
                    {
                        Status = AutoUnlockBrokerStatus.AccessDenied,
                        RequestId = Guid.Empty
                    };
                }
            }

            return inner.Authorize(lockCycleId, authorizationTtlMilliseconds);
        }
    }
}
