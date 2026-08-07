using System;
using BleProximityWake.Agent.Configuration;
using BleProximityWake.Agent.Runtime;

namespace BleProximityWake.Agent.AutoUnlock
{
    internal sealed class InteractiveWakeController
    {
        private readonly AutoUnlockSettings settings;
        private bool initialized;
        private bool previousLocked;
        private long previousResumeSequence;
        private long previousDisplaySequence;
        private double previousIdleSeconds = -1;
        private DateTime ignoreInputUntilUtc = DateTime.MinValue;
        private bool recoveryPrepared;
        private bool pending;
        private DateTime deadlineUtc = DateTime.MinValue;
        private string trigger = string.Empty;
        private string state = "disabled";

        internal InteractiveWakeController(AutoUnlockSettings settings)
        {
            this.settings = settings ?? throw new ArgumentNullException("settings");
            settings.Validate();
        }

        internal InteractiveWakeRuntimeStatus Poll(InteractiveWakeInput input)
        {
            if (input == null)
            {
                throw new ArgumentNullException("input");
            }

            DateTime nowUtc = input.NowUtc == DateTime.MinValue
                ? DateTime.UtcNow
                : input.NowUtc;
            bool recoveryRequested = false;
            bool confirmed = false;

            if (!initialized)
            {
                initialized = true;
                previousLocked = input.SessionLocked;
                previousResumeSequence = input.ResumeSequence;
                previousDisplaySequence = input.DisplaySequence;
                previousIdleSeconds = input.UserIdleSeconds;
                if (input.SessionLocked)
                {
                    ignoreInputUntilUtc = nowUtc.AddSeconds(2);
                }
            }

            if (input.SessionKnown && previousLocked != input.SessionLocked)
            {
                previousLocked = input.SessionLocked;
                pending = false;
                deadlineUtc = DateTime.MinValue;
                trigger = string.Empty;
                if (input.SessionLocked)
                {
                    ignoreInputUntilUtc = nowUtc.AddSeconds(2);
                    recoveryPrepared = false;
                    state = "waiting-interaction";
                }
                else
                {
                    recoveryPrepared = false;
                    state = "unlocked";
                }
            }

            bool resumeEdge = input.ResumeSequence != previousResumeSequence;
            bool displayEdge = input.DisplaySequence != previousDisplaySequence;
            bool inputEdge = IsInputEdge(previousIdleSeconds, input.UserIdleSeconds);
            previousResumeSequence = input.ResumeSequence;
            previousDisplaySequence = input.DisplaySequence;
            previousIdleSeconds = input.UserIdleSeconds;

            if (!settings.Enabled || !settings.TriggerOnInteractiveWake)
            {
                state = "disabled";
                pending = false;
                return Snapshot(false, false);
            }

            if (input.DetectionPaused)
            {
                state = "detection-paused";
                pending = false;
                return Snapshot(false, false);
            }

            if (!input.SessionKnown)
            {
                state = "session-unknown";
                pending = false;
                return Snapshot(false, false);
            }

            if (!input.SessionLocked)
            {
                state = "unlocked";
                pending = false;
                return Snapshot(false, false);
            }

            if (input.AuthorizationAttempted)
            {
                state = "cycle-consumed";
                pending = false;
                return Snapshot(false, false);
            }

            if (input.AuthorizationPending)
            {
                state = "authorization-requesting";
                pending = false;
                return Snapshot(false, false);
            }

            if (displayEdge && input.DisplayState != DisplayPowerState.On)
            {
                recoveryPrepared = false;
            }

            bool displayRecoveryEdge = displayEdge &&
                input.DisplayState == DisplayPowerState.On &&
                input.DisplayWasOffSinceLock;
            if (!pending && !recoveryPrepared &&
                (resumeEdge || displayRecoveryEdge))
            {
                recoveryPrepared = true;
                recoveryRequested = true;
                state = "waiting-input";
            }

            if (!pending)
            {
                string detectedTrigger = DetectTrigger(
                    input,
                    nowUtc,
                    inputEdge);
                if (detectedTrigger.Length > 0)
                {
                    pending = true;
                    trigger = detectedTrigger;
                    deadlineUtc = nowUtc.AddMilliseconds(
                        settings.InteractiveWakeConfirmationMilliseconds);
                    state = "confirming:" + trigger;
                    if (!recoveryPrepared)
                    {
                        recoveryPrepared = true;
                        recoveryRequested = true;
                    }
                }
            }

            if (pending && !recoveryRequested)
            {
                if (GatesReady(input) && input.PresenceFresh)
                {
                    confirmed = true;
                    pending = false;
                    state = "confirmed:" + trigger;
                }
                else if (nowUtc >= deadlineUtc)
                {
                    pending = false;
                    state = "timeout:" + trigger;
                }
                else
                {
                    state = "confirming:" + trigger;
                }
            }

            return Snapshot(recoveryRequested, confirmed);
        }

        internal void Reset()
        {
            initialized = false;
            previousLocked = false;
            previousResumeSequence = 0;
            previousDisplaySequence = 0;
            previousIdleSeconds = -1;
            ignoreInputUntilUtc = DateTime.MinValue;
            recoveryPrepared = false;
            pending = false;
            deadlineUtc = DateTime.MinValue;
            trigger = string.Empty;
            state = settings.Enabled && settings.TriggerOnInteractiveWake
                ? "waiting-lock"
                : "disabled";
        }

        private string DetectTrigger(
            InteractiveWakeInput input,
            DateTime nowUtc,
            bool inputEdge)
        {
            bool displayEvidence = input.DisplayWasOffSinceLock ||
                settings.InteractiveWakeAllowIdleFallback;
            if (inputEdge && nowUtc >= ignoreInputUntilUtc && displayEvidence)
            {
                return "interactive-input";
            }

            return string.Empty;
        }

        private bool IsInputEdge(double previousIdle, double currentIdle)
        {
            return previousIdle * 1000.0 >=
                    settings.InteractiveWakeMinimumPriorIdleMilliseconds &&
                currentIdle >= 0 &&
                currentIdle * 1000.0 <=
                    settings.InteractiveWakeInputFreshMilliseconds &&
                currentIdle < previousIdle;
        }

        private bool GatesReady(InteractiveWakeInput input)
        {
            return (!settings.RequireAllowedNetwork || input.NetworkAllowed) &&
                (!settings.RequireAcPower || input.AcPowerConnected) &&
                input.PresenceReady;
        }

        private InteractiveWakeRuntimeStatus Snapshot(
            bool recoveryRequested,
            bool confirmed)
        {
            return new InteractiveWakeRuntimeStatus
            {
                State = state,
                Pending = pending,
                RecoveryRequested = recoveryRequested,
                Confirmed = confirmed,
                Trigger = trigger,
                DeadlineUtc = deadlineUtc
            };
        }
    }
}
