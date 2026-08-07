using System;
using BleProximityWake.Core.Presence;

namespace BleProximityWake.Core.Actions
{
    public sealed class ProximityActionCoordinator
    {
        private readonly ProximityActionOptions options;
        private bool initialized;
        private bool previousLocked;
        private bool wakeArmed;
        private bool autoLockArmed;
        private DateTime wakeNotReadySinceUtc = DateTime.MinValue;
        private DateTime autoLockAbsentSinceUtc = DateTime.MinValue;
        private DateTime lastWakeAttemptUtc = DateTime.MinValue;
        private DateTime lastAutoLockAttemptUtc = DateTime.MinValue;
        private DateTime wakeFailureRetryAfterUtc = DateTime.MinValue;
        private int wakeFailureRetryCount;

        public ProximityActionCoordinator(ProximityActionOptions options)
        {
            this.options = options ?? throw new ArgumentNullException("options");
            options.Validate();
        }

        public ProximityActionDecision Evaluate(ProximityActionInput input)
        {
            if (input == null)
            {
                throw new ArgumentNullException("input");
            }

            DateTime nowUtc = input.NowUtc == DateTime.MinValue
                ? DateTime.UtcNow
                : input.NowUtc;
            if (input.DetectionPaused)
            {
                Reset();
                return Decision(ProximityActionType.None, "detection-paused");
            }

            HandleSessionTransition(input, nowUtc);

            if (!input.SessionKnown)
            {
                return Decision(ProximityActionType.None, "session-unknown");
            }

            if (!input.NetworkAllowed)
            {
                ResetForDisallowedNetwork();
                return Decision(ProximityActionType.None, "network-not-allowed");
            }

            if (input.SessionLocked)
            {
                autoLockArmed = false;
                autoLockAbsentSinceUtc = DateTime.MinValue;
                return EvaluateWake(input, nowUtc);
            }

            wakeArmed = false;
            wakeNotReadySinceUtc = DateTime.MinValue;
            return EvaluateAutoLock(input, nowUtc);
        }

        public void Reset()
        {
            initialized = false;
            previousLocked = false;
            wakeArmed = false;
            autoLockArmed = false;
            wakeNotReadySinceUtc = DateTime.MinValue;
            autoLockAbsentSinceUtc = DateTime.MinValue;
            wakeFailureRetryAfterUtc = DateTime.MinValue;
            wakeFailureRetryCount = 0;
        }

        public void ReportActionResult(
            ProximityActionType action,
            bool succeeded,
            DateTime nowUtc)
        {
            if (action != ProximityActionType.WakeToLogin)
            {
                return;
            }

            if (succeeded)
            {
                wakeFailureRetryAfterUtc = DateTime.MinValue;
                wakeFailureRetryCount = 0;
                return;
            }

            if (wakeFailureRetryCount >= options.WakeFailureMaximumRetries)
            {
                wakeFailureRetryAfterUtc = DateTime.MinValue;
                return;
            }

            wakeFailureRetryCount++;
            wakeArmed = true;
            wakeFailureRetryAfterUtc = nowUtc.AddSeconds(options.WakeFailureRetrySeconds);
        }

        private void HandleSessionTransition(ProximityActionInput input, DateTime nowUtc)
        {
            if (!initialized)
            {
                initialized = true;
                previousLocked = input.SessionLocked;
                if (input.SessionLocked)
                {
                    wakeNotReadySinceUtc = input.WakePresenceReady
                        ? DateTime.MinValue
                        : nowUtc;
                }
                return;
            }

            if (previousLocked == input.SessionLocked)
            {
                return;
            }

            previousLocked = input.SessionLocked;
            wakeArmed = false;
            autoLockArmed = false;
            wakeNotReadySinceUtc = input.SessionLocked && !input.WakePresenceReady
                ? nowUtc
                : DateTime.MinValue;
            autoLockAbsentSinceUtc = DateTime.MinValue;
            wakeFailureRetryAfterUtc = DateTime.MinValue;
            wakeFailureRetryCount = 0;
        }

        private ProximityActionDecision EvaluateWake(
            ProximityActionInput input,
            DateTime nowUtc)
        {
            if (!options.WakeEnabled && !options.ArrivalDetectionEnabled)
            {
                return Decision(ProximityActionType.None, "arrival-disabled");
            }

            if (!input.WakePresenceReady)
            {
                wakeFailureRetryAfterUtc = DateTime.MinValue;
                wakeFailureRetryCount = 0;
                if (wakeNotReadySinceUtc == DateTime.MinValue)
                {
                    wakeNotReadySinceUtc = nowUtc;
                }

                if ((nowUtc - wakeNotReadySinceUtc).TotalSeconds >= options.WakeRearmSeconds)
                {
                    wakeArmed = true;
                }

                return Decision(
                    ProximityActionType.None,
                    wakeArmed ? "wake-armed-waiting-for-arrival" : "wake-waiting-for-far");
            }

            wakeNotReadySinceUtc = DateTime.MinValue;
            if (!wakeArmed)
            {
                return Decision(ProximityActionType.None, "wake-not-armed");
            }

            bool failureRetryReady = wakeFailureRetryAfterUtc != DateTime.MinValue &&
                nowUtc >= wakeFailureRetryAfterUtc;
            if (wakeFailureRetryAfterUtc != DateTime.MinValue && !failureRetryReady)
            {
                return Decision(ProximityActionType.None, "wake-failure-retry-wait");
            }

            if (!failureRetryReady &&
                !Elapsed(lastWakeAttemptUtc, nowUtc, options.WakeCooldownSeconds))
            {
                return Decision(ProximityActionType.None, "wake-cooldown");
            }

            wakeArmed = false;
            wakeFailureRetryAfterUtc = DateTime.MinValue;
            lastWakeAttemptUtc = nowUtc;
            ProximityActionDecision decision = Decision(
                options.WakeEnabled
                    ? ProximityActionType.WakeToLogin
                    : ProximityActionType.None,
                "arrival-confirmed");
            decision.ArrivalConfirmed = true;
            return decision;
        }

        private ProximityActionDecision EvaluateAutoLock(
            ProximityActionInput input,
            DateTime nowUtc)
        {
            if (!options.AutoLockEnabled)
            {
                return Decision(ProximityActionType.None, "auto-lock-disabled");
            }

            bool allRequiredPresent = input.AutoLockMode == PresenceMode.WatchAndPhone
                ? input.WatchPresentForDeparture && input.PhonePresentForDeparture
                : input.PhonePresentForDeparture;
            bool allRequiredAbsent = input.AutoLockMode == PresenceMode.WatchAndPhone
                ? !input.WatchPresentForDeparture && !input.PhonePresentForDeparture
                : !input.PhonePresentForDeparture;

            if (allRequiredPresent)
            {
                autoLockArmed = true;
                autoLockAbsentSinceUtc = DateTime.MinValue;
                return Decision(ProximityActionType.None, "auto-lock-armed");
            }

            if (!autoLockArmed)
            {
                return Decision(ProximityActionType.None, "auto-lock-not-armed");
            }

            if (!allRequiredAbsent)
            {
                autoLockAbsentSinceUtc = DateTime.MinValue;
                return Decision(ProximityActionType.None, "auto-lock-required-device-still-present");
            }

            DateTime evidenceUtc = LatestRequiredSeen(input);
            if (evidenceUtc == DateTime.MinValue)
            {
                if (autoLockAbsentSinceUtc == DateTime.MinValue)
                {
                    autoLockAbsentSinceUtc = nowUtc;
                }

                evidenceUtc = autoLockAbsentSinceUtc;
            }

            if ((nowUtc - evidenceUtc).TotalSeconds < options.AutoLockAbsenceSeconds)
            {
                return Decision(ProximityActionType.None, "auto-lock-waiting-for-absence");
            }

            if (input.UserIdleSeconds < options.AutoLockMinimumIdleSeconds)
            {
                return Decision(ProximityActionType.None, "auto-lock-user-active");
            }

            if (!Elapsed(lastAutoLockAttemptUtc, nowUtc, options.AutoLockRetrySeconds))
            {
                return Decision(ProximityActionType.None, "auto-lock-retry-delay");
            }

            lastAutoLockAttemptUtc = nowUtc;
            return Decision(ProximityActionType.LockWorkstation, "departure-confirmed");
        }

        private DateTime LatestRequiredSeen(ProximityActionInput input)
        {
            if (input.AutoLockMode == PresenceMode.PhoneOnly)
            {
                return input.LastPhoneDepartureSeenUtc;
            }

            return input.LastWatchDepartureSeenUtc > input.LastPhoneDepartureSeenUtc
                ? input.LastWatchDepartureSeenUtc
                : input.LastPhoneDepartureSeenUtc;
        }

        private void ResetForDisallowedNetwork()
        {
            wakeArmed = false;
            autoLockArmed = false;
            wakeNotReadySinceUtc = DateTime.MinValue;
            autoLockAbsentSinceUtc = DateTime.MinValue;
            wakeFailureRetryAfterUtc = DateTime.MinValue;
            wakeFailureRetryCount = 0;
        }

        private ProximityActionDecision Decision(ProximityActionType action, string reason)
        {
            return new ProximityActionDecision
            {
                Action = action,
                Reason = reason,
                WakeArmed = wakeArmed,
                AutoLockArmed = autoLockArmed
            };
        }

        private static bool Elapsed(DateTime previousUtc, DateTime nowUtc, int seconds)
        {
            return previousUtc == DateTime.MinValue ||
                (nowUtc - previousUtc).TotalSeconds >= seconds;
        }
    }
}
