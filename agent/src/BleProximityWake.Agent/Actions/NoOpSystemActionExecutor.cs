using BleProximityWake.Core.Actions;

namespace BleProximityWake.Agent.Actions
{
    internal sealed class NoOpSystemActionExecutor : ISystemActionExecutor
    {
        public SystemActionResult Execute(ProximityActionType action)
        {
            return new SystemActionResult
            {
                Succeeded = false,
                Detail = "no-op executor"
            };
        }
    }
}
