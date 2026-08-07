using System;
using BleProximityWake.Agent.Configuration;

namespace BleProximityWake.Agent.AutoUnlock
{
    internal sealed class AutoUnlockController
    {
        private static readonly int[] RetryDelaysMilliseconds = { 250, 500, 1000 };
        private readonly AutoUnlockSettings settings;
        private readonly IAutoUnlockBrokerClient client;
        private readonly IAutoUnlockRequestRunner runner;
        private bool initialized;
        private bool previousLocked;
        private ulong lockCycleId;
        private ulong pendingLockCycleId;
        private string pendingTrigger = string.Empty;
        private bool attempted;
        private int retryCount;
        private DateTime retryAfterUtc = DateTime.MinValue;
        private string retryTrigger = string.Empty;
        private string state = "disabled";
        private AutoUnlockBrokerStatus? lastBrokerStatus;
        private Guid lastRequestId;
        private string lastError = string.Empty;
        private bool requestStartedThisPoll;

        internal AutoUnlockController(
            AutoUnlockSettings settings,
            IAutoUnlockBrokerClient client,
            IAutoUnlockRequestRunner runner)
        {
            this.settings = settings ?? throw new ArgumentNullException("settings");
            this.client = client ?? throw new ArgumentNullException("client");
            this.runner = runner ?? throw new ArgumentNullException("runner");
            settings.Validate();
        }

        internal AutoUnlockRuntimeStatus Poll(AutoUnlockInput input)
        {
            if (input == null)
            {
                throw new ArgumentNullException("input");
            }

            DateTime nowUtc = input.NowUtc == DateTime.MinValue
                ? DateTime.UtcNow
                : input.NowUtc;
            requestStartedThisPoll = false;
            HandleSession(input, nowUtc);
            CollectCompletedRequest(input, nowUtc);

            if (!settings.Enabled)
            {
                state = "disabled";
                return Snapshot();
            }

            if (input.DetectionPaused)
            {
                state = "detection-paused";
                return Snapshot();
            }

            if (!input.SessionKnown)
            {
                state = "session-unknown";
                return Snapshot();
            }

            if (!input.SessionLocked)
            {
                state = "unlocked";
                return Snapshot();
            }

            if (runner.IsRunning)
            {
                state = "requesting";
                return Snapshot();
            }

            if (attempted)
            {
                return Snapshot();
            }

            bool gatesReady = GatesReady(input);
            if (retryAfterUtc != DateTime.MinValue)
            {
                if (nowUtc < retryAfterUtc)
                {
                    state = "retry-wait";
                    return Snapshot();
                }

                if (!gatesReady)
                {
                    attempted = true;
                    retryAfterUtc = DateTime.MinValue;
                    retryTrigger = string.Empty;
                    state = "retry-cancelled-conditions";
                    return Snapshot();
                }

                StartRequest(retryTrigger);
                return Snapshot();
            }

            if (settings.TriggerOnInteractiveWake &&
                input.InteractiveWakeConfirmed)
            {
                StartRequest(string.IsNullOrWhiteSpace(input.InteractiveWakeTrigger)
                    ? "interactive-wake"
                    : input.InteractiveWakeTrigger);
                return Snapshot();
            }

            if (!settings.TriggerOnArrival)
            {
                state = "arrival-trigger-disabled";
                return Snapshot();
            }

            if (!input.ArrivalConfirmed)
            {
                state = gatesReady ? "waiting-arrival" : GateReason(input);
                return Snapshot();
            }

            if (!gatesReady)
            {
                state = GateReason(input);
                return Snapshot();
            }

            StartRequest("arrival");
            return Snapshot();
        }

        internal void Reset()
        {
            initialized = false;
            previousLocked = false;
            lockCycleId = 0;
            pendingLockCycleId = 0;
            pendingTrigger = string.Empty;
            attempted = false;
            retryCount = 0;
            retryAfterUtc = DateTime.MinValue;
            retryTrigger = string.Empty;
            state = settings.Enabled ? "waiting-lock" : "disabled";
            lastBrokerStatus = null;
            lastRequestId = Guid.Empty;
            lastError = string.Empty;
        }

        private void HandleSession(AutoUnlockInput input, DateTime nowUtc)
        {
            if (!input.SessionKnown)
            {
                return;
            }

            if (!initialized)
            {
                initialized = true;
                previousLocked = input.SessionLocked;
                if (input.SessionLocked)
                {
                    BeginLockCycle(nowUtc);
                }
                return;
            }

            if (previousLocked == input.SessionLocked)
            {
                return;
            }

            previousLocked = input.SessionLocked;
            if (input.SessionLocked)
            {
                BeginLockCycle(nowUtc);
            }
            else
            {
                lockCycleId = 0;
                pendingLockCycleId = 0;
                pendingTrigger = string.Empty;
                attempted = false;
                retryCount = 0;
                retryAfterUtc = DateTime.MinValue;
                retryTrigger = string.Empty;
                state = "unlocked";
            }
        }

        private void BeginLockCycle(DateTime nowUtc)
        {
            lockCycleId = checked((ulong)nowUtc.Ticks);
            if (lockCycleId == 0)
            {
                lockCycleId = 1;
            }

            attempted = false;
            pendingLockCycleId = 0;
            pendingTrigger = string.Empty;
            retryCount = 0;
            retryAfterUtc = DateTime.MinValue;
            retryTrigger = string.Empty;
            state = settings.Enabled ? "waiting-arrival" : "disabled";
            lastBrokerStatus = null;
            lastRequestId = Guid.Empty;
            lastError = string.Empty;
        }

        private void StartRequest(string trigger)
        {
            ulong cycle = lockCycleId;
            pendingLockCycleId = cycle;
            pendingTrigger = trigger;
            state = "requesting:" + trigger;
            lastError = string.Empty;
            runner.Start(() => client.Authorize(
                cycle,
                settings.AuthorizationTtlMilliseconds));
            requestStartedThisPoll = true;
        }

        private void CollectCompletedRequest(AutoUnlockInput input, DateTime nowUtc)
        {
            if (!runner.TryTakeCompleted(
                out AutoUnlockBrokerResult result,
                out Exception exception))
            {
                return;
            }

            if (pendingLockCycleId == 0 ||
                pendingLockCycleId != lockCycleId ||
                !input.SessionKnown ||
                !input.SessionLocked)
            {
                pendingLockCycleId = 0;
                pendingTrigger = string.Empty;
                state = input.SessionLocked ? "stale-response" : "unlocked";
                return;
            }

            pendingLockCycleId = 0;
            string completedTrigger = pendingTrigger;
            pendingTrigger = string.Empty;
            if (exception != null)
            {
                lastError = exception.GetBaseException().Message;
                ScheduleRetry(nowUtc, completedTrigger.Length > 0
                    ? completedTrigger
                    : "auto-unlock", null);
                return;
            }

            if (result == null)
            {
                lastError = "Broker request returned no result.";
                ScheduleRetry(nowUtc, completedTrigger.Length > 0
                    ? completedTrigger
                    : "auto-unlock", null);
                return;
            }

            lastBrokerStatus = result.Status;
            lastRequestId = result.RequestId;
            if (result.Status == AutoUnlockBrokerStatus.Ok)
            {
                attempted = true;
                retryCount = 0;
                retryAfterUtc = DateTime.MinValue;
                retryTrigger = string.Empty;
                state = "accepted";
                return;
            }

            if (IsTransient(result.Status))
            {
                ScheduleRetry(nowUtc, completedTrigger.Length > 0
                    ? completedTrigger
                    : "auto-unlock", result.Status);
                return;
            }

            attempted = true;
            retryAfterUtc = DateTime.MinValue;
            retryTrigger = string.Empty;
            state = "rejected:" + result.Status;
        }

        private void ScheduleRetry(
            DateTime nowUtc,
            string trigger,
            AutoUnlockBrokerStatus? status)
        {
            if (retryCount >= RetryDelaysMilliseconds.Length)
            {
                attempted = true;
                retryAfterUtc = DateTime.MinValue;
                retryTrigger = string.Empty;
                state = status.HasValue
                    ? "retry-exhausted:" + status.Value
                    : "retry-exhausted:error";
                return;
            }

            int delay = RetryDelaysMilliseconds[retryCount];
            retryCount++;
            retryAfterUtc = nowUtc.AddMilliseconds(delay);
            retryTrigger = trigger;
            state = status.HasValue
                ? "retry:" + status.Value + ":" + retryCount
                : "retry:error:" + retryCount;
        }

        private bool GatesReady(AutoUnlockInput input)
        {
            return input.SessionKnown &&
                input.SessionLocked &&
                (!settings.RequireAllowedNetwork || input.NetworkAllowed) &&
                (!settings.RequireAcPower || input.AcPowerConnected) &&
                input.PresenceReady;
        }

        private string GateReason(AutoUnlockInput input)
        {
            if (settings.RequireAllowedNetwork && !input.NetworkAllowed)
            {
                return "network-not-allowed";
            }

            if (settings.RequireAcPower && !input.AcPowerConnected)
            {
                return "ac-power-required";
            }

            return input.PresenceReady ? "conditions-ready" : "presence-not-ready";
        }

        private AutoUnlockRuntimeStatus Snapshot()
        {
            return new AutoUnlockRuntimeStatus
            {
                State = state,
                LockCycleId = lockCycleId,
                Attempted = attempted,
                RequestPending = runner.IsRunning,
                RequestStarted = requestStartedThisPoll,
                RetryCount = retryCount,
                BrokerStatus = lastBrokerStatus,
                RequestId = lastRequestId,
                Error = lastError
            };
        }

        private static bool IsTransient(AutoUnlockBrokerStatus status)
        {
            return status == AutoUnlockBrokerStatus.SessionNotLocked ||
                status == AutoUnlockBrokerStatus.ProviderUnavailable ||
                status == AutoUnlockBrokerStatus.InternalError;
        }
    }
}
