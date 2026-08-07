using BleProximityWake.Core.Actions;

namespace BleProximityWake.Agent.Actions
{
    internal interface ISystemActionExecutor
    {
        SystemActionResult Execute(ProximityActionType action);
    }
}
