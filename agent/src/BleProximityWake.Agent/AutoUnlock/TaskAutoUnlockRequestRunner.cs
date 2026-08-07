using System;
using System.Threading.Tasks;

namespace BleProximityWake.Agent.AutoUnlock
{
    internal sealed class TaskAutoUnlockRequestRunner : IAutoUnlockRequestRunner
    {
        private Task<AutoUnlockBrokerResult> task;

        public bool IsRunning => task != null && !task.IsCompleted;

        public void Start(Func<AutoUnlockBrokerResult> request)
        {
            if (request == null)
            {
                throw new ArgumentNullException("request");
            }

            if (task != null)
            {
                throw new InvalidOperationException(
                    "An auto-unlock Broker request is already pending.");
            }

            task = Task.Factory.StartNew(
                request,
                System.Threading.CancellationToken.None,
                TaskCreationOptions.DenyChildAttach,
                TaskScheduler.Default);
        }

        public bool TryTakeCompleted(
            out AutoUnlockBrokerResult result,
            out Exception exception)
        {
            result = null;
            exception = null;
            if (task == null || !task.IsCompleted)
            {
                return false;
            }

            try
            {
                result = task.GetAwaiter().GetResult();
            }
            catch (Exception caught)
            {
                exception = caught;
            }
            finally
            {
                task = null;
            }

            return true;
        }
    }
}
