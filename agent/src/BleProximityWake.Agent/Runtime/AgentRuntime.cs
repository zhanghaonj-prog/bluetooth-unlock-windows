using System;
using BleProximityWake.Agent.Actions;
using BleProximityWake.Agent.AutoUnlock;
using BleProximityWake.Agent.Bluetooth;
using BleProximityWake.Agent.Configuration;
using BleProximityWake.Agent.Diagnostics;
using BleProximityWake.Core.Bluetooth;
using BleProximityWake.Core.Actions;
using BleProximityWake.Core.Presence;
using BleProximityWake.Core.Scanning;

namespace BleProximityWake.Agent.Runtime
{
    internal sealed class AgentRuntime : IDisposable
    {
        private readonly AgentSettings settings;
        private readonly FileLogger logger;
        private readonly IBleAdvertisementSource source;
        private readonly IRuntimeConditionSource conditions;
        private readonly DevicePresenceTracker tracker;
        private readonly ProximityActionCoordinator actionCoordinator;
        private readonly ProximityActionCoordinator autoUnlockArrivalCoordinator;
        private readonly InteractiveWakeController interactiveWakeController;
        private readonly ISystemActionExecutor actionExecutor;
        private readonly AutoUnlockController autoUnlockController;
        private bool detectionPaused;
        private bool disposed;
        private long lastResumeSequence;
        private bool lastAutoUnlockAttempted;
        private bool lastAutoUnlockRequestPending;
        private DateTime lastHeartbeatUtc = DateTime.MinValue;
        private string lastSummary = string.Empty;

        internal AgentRuntime(AgentSettings settings, FileLogger logger)
        {
            this.settings = settings ?? throw new ArgumentNullException("settings");
            this.logger = logger ?? throw new ArgumentNullException("logger");
            settings.Validate();

            IBleAdvertisementSource createdSource = null;
            IRuntimeConditionSource createdConditions = null;
            try
            {
                createdSource = new WinRtBleAdvertisementSource(
                    settings.Ble.ManufacturerCompanyId,
                    settings.Ble.SamplingIntervalMilliseconds);
                createdConditions = new RuntimeConditionMonitor(settings.Network);
                source = createdSource;
                conditions = createdConditions;
                tracker = new DevicePresenceTracker(settings.Detection);
                actionCoordinator = CreateActionCoordinator(settings);
                autoUnlockArrivalCoordinator = CreateAutoUnlockArrivalCoordinator(settings);
                actionExecutor = new Win32SystemActionExecutor(settings.Actions.Wake);
                autoUnlockController = new AutoUnlockController(
                    settings.AutoUnlock,
                    new NetworkRevalidatingAutoUnlockBrokerClient(
                        new NamedPipeAutoUnlockBrokerClient(settings.AutoUnlock),
                        conditions,
                        settings.AutoUnlock.RequireAllowedNetwork),
                    new TaskAutoUnlockRequestRunner());
                interactiveWakeController = new InteractiveWakeController(
                    settings.AutoUnlock);
            }
            catch
            {
                createdConditions?.Dispose();
                createdSource?.Dispose();
                throw;
            }
        }

        internal AgentRuntime(
            AgentSettings settings,
            FileLogger logger,
            IBleAdvertisementSource source,
            IRuntimeConditionSource conditions)
            : this(settings, logger, source, conditions, new NoOpSystemActionExecutor())
        {
        }

        internal AgentRuntime(
            AgentSettings settings,
            FileLogger logger,
            IBleAdvertisementSource source,
            IRuntimeConditionSource conditions,
            ISystemActionExecutor actionExecutor)
            : this(
                settings,
                logger,
                source,
                conditions,
                actionExecutor,
                new NoOpAutoUnlockBrokerClient(),
                new TaskAutoUnlockRequestRunner())
        {
        }

        internal AgentRuntime(
            AgentSettings settings,
            FileLogger logger,
            IBleAdvertisementSource source,
            IRuntimeConditionSource conditions,
            ISystemActionExecutor actionExecutor,
            IAutoUnlockBrokerClient autoUnlockBrokerClient,
            IAutoUnlockRequestRunner autoUnlockRequestRunner)
        {
            this.settings = settings ?? throw new ArgumentNullException("settings");
            this.logger = logger ?? throw new ArgumentNullException("logger");
            this.source = source ?? throw new ArgumentNullException("source");
            this.conditions = conditions ?? throw new ArgumentNullException("conditions");
            this.actionExecutor = actionExecutor ?? throw new ArgumentNullException("actionExecutor");
            settings.Validate();
            tracker = new DevicePresenceTracker(settings.Detection);
            actionCoordinator = CreateActionCoordinator(settings);
            autoUnlockArrivalCoordinator = CreateAutoUnlockArrivalCoordinator(settings);
            autoUnlockController = new AutoUnlockController(
                settings.AutoUnlock,
                new NetworkRevalidatingAutoUnlockBrokerClient(
                    autoUnlockBrokerClient,
                    conditions,
                    settings.AutoUnlock.RequireAllowedNetwork),
                autoUnlockRequestRunner);
            interactiveWakeController = new InteractiveWakeController(
                settings.AutoUnlock);
        }

        internal bool DetectionPaused => detectionPaused;

        internal bool CanPauseDetection =>
            detectionPaused || !lastAutoUnlockRequestPending;

        internal void SetDetectionPaused(bool value)
        {
            if (value == detectionPaused)
            {
                return;
            }

            if (value && lastAutoUnlockRequestPending)
            {
                logger.Warn(
                    "EXE detection pause refused while an auto-unlock request is pending.");
                return;
            }

            detectionPaused = value;
            if (value)
            {
                int cleared = source.Clear();
                tracker.Reset();
                actionCoordinator.Reset();
                autoUnlockArrivalCoordinator.Reset();
                interactiveWakeController.Reset();
                logger.Info("EXE detection paused. ClearedQueue=" + cleared);
            }
            else
            {
                tracker.Reset();
                actionCoordinator.Reset();
                autoUnlockArrivalCoordinator.Reset();
                interactiveWakeController.Reset();
                logger.Info("EXE detection resumed; device presence must be observed again.");
            }
        }

        internal void RedetectDevices()
        {
            int cleared = source.Clear();
            tracker.Reset();
            actionCoordinator.Reset();
            autoUnlockArrivalCoordinator.Reset();
            interactiveWakeController.Reset();
            logger.Info("EXE device re-detection requested. ClearedQueue=" + cleared);
        }

        internal AgentRuntimeStatus Poll()
        {
            ThrowIfDisposed();
            RuntimeConditionSnapshot condition = conditions.Capture();
            tracker.SetLocked(condition.SessionLocked);
            if (condition.ResumeSequence != lastResumeSequence)
            {
                lastResumeSequence = condition.ResumeSequence;
                tracker.BeginResume(condition.LastResumeUtc);
                actionCoordinator.Reset();
                autoUnlockArrivalCoordinator.Reset();
                int cleared = source.Clear();
                logger.Info(
                    "EXE resume observed. Sequence=" + condition.ResumeSequence +
                    " ClearedQueue=" + cleared);
            }

            ScanProfile profile = ScanProfileSelector.Select(
                new ScanContext
                {
                    DetectionPaused = detectionPaused,
                    SessionLocked = condition.SessionLocked,
                    NetworkAllowed = condition.Network.Allowed,
                    AcPowerConnected = condition.AcPowerConnected
                },
                settings.Ble.LockedPollIntervalMilliseconds,
                settings.Ble.BackgroundPollIntervalMilliseconds);
            bool restarted = source.EnsureStarted(profile.Mode);
            if (restarted)
            {
                logger.Info(
                    "EXE BLE watcher started/restarted. Mode=" + profile.Mode +
                    " RestartCount=" + source.RestartCount);
            }

            BleAdvertisement[] records = source.Drain(1000);
            // Any operation above can straddle Modern Standby. Start freshness
            // checks and confirmation deadlines only after execution resumes.
            DateTime nowUtc = DateTime.UtcNow;
            if (!detectionPaused)
            {
                foreach (BleAdvertisement record in records)
                {
                    tracker.Process(record, nowUtc);
                }
            }

            PresenceTrackerSnapshot presence = tracker.Evaluate(nowUtc);
            PresenceObservation autoUnlockObservation = presence.Observation;
            if (settings.PresencePolicies.AutoUnlock.Mode == PresenceMode.PhoneOnly)
            {
                autoUnlockObservation = new PresenceObservation
                {
                    WatchReady = presence.Observation.WatchReady,
                    PhoneReady = presence.PhoneConfirmedByHitCount,
                    WatchFreshAfterResume = presence.Observation.WatchFreshAfterResume,
                    PhoneFreshAfterResume = presence.Observation.PhoneFreshAfterResume
                };
            }

            var status = new AgentRuntimeStatus
            {
                Conditions = condition,
                ScanProfile = profile,
                Presence = presence,
                WakePresence = PresenceDecisionEvaluator.Evaluate(
                    settings.PresencePolicies.Wake,
                    new PresenceObservation
                    {
                        WatchReady = presence.WakeWatchReady,
                        PhoneReady = presence.Observation.PhoneReady,
                        WatchFreshAfterResume = presence.Observation.WatchFreshAfterResume,
                        PhoneFreshAfterResume = presence.Observation.PhoneFreshAfterResume
                    }),
                AutoUnlockPresence = PresenceDecisionEvaluator.Evaluate(
                    settings.PresencePolicies.AutoUnlock,
                    autoUnlockObservation),
                AutoLockPresence = PresenceDecisionEvaluator.Evaluate(
                    settings.PresencePolicies.AutoLock,
                    new PresenceObservation
                    {
                        WatchReady = presence.WatchPresentForDeparture,
                        PhoneReady = presence.PhonePresentForDeparture,
                        WatchFreshAfterResume = true,
                        PhoneFreshAfterResume = true
                    }),
                WatcherStatus = source.Status,
                QueueCount = source.QueueCount,
                DroppedQueueRecords = source.DroppedQueueRecords,
                RestartCount = source.RestartCount,
                ForcedRecoveryCount = source.ForcedRecoveryCount
            };
            status.ActionDecision = actionCoordinator.Evaluate(
                new ProximityActionInput
                {
                    NowUtc = nowUtc,
                    SessionKnown = condition.SessionKnown,
                    SessionLocked = condition.SessionLocked,
                    NetworkAllowed = condition.Network.Allowed,
                    DetectionPaused = detectionPaused,
                    WakePresenceReady = status.WakePresence.PresenceReady,
                    AutoLockMode = settings.PresencePolicies.AutoLock.Mode,
                    WatchPresentForDeparture = presence.WatchPresentForDeparture,
                    PhonePresentForDeparture = presence.PhonePresentForDeparture,
                    LastWatchDepartureSeenUtc = presence.LastWatchDepartureSeenUtc,
                    LastPhoneDepartureSeenUtc = presence.LastPhoneDepartureSeenUtc,
                    UserIdleSeconds = condition.UserIdleSeconds
                });
            status.AutoUnlockArrivalDecision = autoUnlockArrivalCoordinator.Evaluate(
                new ProximityActionInput
                {
                    NowUtc = nowUtc,
                    SessionKnown = condition.SessionKnown,
                    SessionLocked = condition.SessionLocked,
                    NetworkAllowed = !settings.AutoUnlock.RequireAllowedNetwork ||
                        condition.Network.Allowed,
                    DetectionPaused = detectionPaused,
                    WakePresenceReady = status.AutoUnlockPresence.PresenceReady,
                    AutoLockMode = settings.PresencePolicies.AutoLock.Mode
                });
            status.InteractiveWake = interactiveWakeController.Poll(
                new InteractiveWakeInput
                {
                    NowUtc = nowUtc,
                    DetectionPaused = detectionPaused,
                    SessionKnown = condition.SessionKnown,
                    SessionLocked = condition.SessionLocked,
                    AuthorizationAttempted = lastAutoUnlockAttempted,
                    AuthorizationPending = lastAutoUnlockRequestPending,
                    NetworkAllowed = condition.Network.Allowed,
                    AcPowerConnected = condition.AcPowerConnected,
                    PresenceReady = status.AutoUnlockPresence.PresenceReady,
                    PresenceFresh = IsInteractivePresenceFresh(presence, nowUtc),
                    ResumeSequence = condition.ResumeSequence,
                    DisplaySequence = condition.DisplaySequence,
                    DisplayState = condition.DisplayState,
                    DisplayWasOffSinceLock = condition.DisplayWasOffSinceLock,
                    UserIdleSeconds = condition.UserIdleSeconds
                });
            if (status.InteractiveWake.RecoveryRequested)
            {
                int cleared = source.Clear();
                tracker.Reset();
                tracker.SetLocked(condition.SessionLocked);
                if (condition.ResumeSequence > 0)
                {
                    tracker.BeginResume(condition.LastResumeUtc);
                }
                bool recoveryRestarted = source.Restart(profile.Mode);
                logger.Info(
                    "EXE interactive BLE recovery. Trigger=" +
                    status.InteractiveWake.Trigger +
                    " ClearedQueue=" + cleared +
                    " Restarted=" + recoveryRestarted +
                    " Mode=" + profile.Mode);
            }
            status.AutoUnlock = autoUnlockController.Poll(
                new AutoUnlockInput
                {
                    NowUtc = nowUtc,
                    DetectionPaused = detectionPaused,
                    SessionKnown = condition.SessionKnown,
                    SessionLocked = condition.SessionLocked,
                    NetworkAllowed = condition.Network.Allowed,
                    AcPowerConnected = condition.AcPowerConnected,
                    PresenceReady = status.AutoUnlockPresence.PresenceReady,
                    ArrivalConfirmed =
                        status.AutoUnlockArrivalDecision.ArrivalConfirmed,
                    InteractiveWakeConfirmed = status.InteractiveWake.Confirmed,
                    InteractiveWakeTrigger = status.InteractiveWake.Trigger
            });
            lastAutoUnlockAttempted = status.AutoUnlock.Attempted;
            lastAutoUnlockRequestPending = status.AutoUnlock.RequestPending;
            ProximityActionType systemAction = ResolveSystemAction(
                status.ActionDecision.Action,
                status.AutoUnlockArrivalDecision.ArrivalConfirmed,
                status.InteractiveWake.Confirmed,
                status.AutoUnlock.RequestStarted);
            if (systemAction != ProximityActionType.None)
            {
                status.ActionResult = actionExecutor.Execute(systemAction);
                actionCoordinator.ReportActionResult(
                    systemAction,
                    status.ActionResult.Succeeded,
                    nowUtc);
                logger.Info(
                    "EXE system action. Action=" + systemAction +
                    " RequestedAction=" + status.ActionDecision.Action +
                    " Reason=" + status.ActionDecision.Reason +
                    " Succeeded=" + status.ActionResult.Succeeded +
                    " Detail=" + status.ActionResult.Detail);
            }
            LogStatus(status, records.Length, nowUtc);
            return status;
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            conditions.Dispose();
            source.Dispose();
        }

        private void LogStatus(AgentRuntimeStatus status, int drained, DateTime nowUtc)
        {
            string summary = string.Format(
                "Locked={0} Network={1} AC={2} Scan={3}/{4} WatchReady={5} PhoneReady={6} WakePresence={7} UnlockPresence={8} AutoLockPresence={9} Action={10}/{11} AutoUnlock={12} Interactive={13} UnlockCycle={14} UnlockAttempted={15} UnlockRetry={16} UnlockBroker={17} UnlockRequest={18} UnlockError={19} WakeWatchReady={20}",
                status.Conditions.SessionLocked,
                status.Conditions.Network.Allowed,
                status.Conditions.AcPowerConnected,
                status.WatcherStatus,
                status.ScanProfile.Mode,
                status.Presence.Observation.WatchReady,
                status.Presence.Observation.PhoneReady,
                status.WakePresence.PresenceReady,
                status.AutoUnlockPresence.PresenceReady,
                status.AutoLockPresence.PresenceReady,
                status.ActionDecision.Action,
                status.ActionDecision.Reason,
                status.AutoUnlock.State,
                status.InteractiveWake.State,
                status.AutoUnlock.LockCycleId,
                status.AutoUnlock.Attempted,
                status.AutoUnlock.RetryCount,
                status.AutoUnlock.BrokerStatus,
                status.AutoUnlock.RequestId,
                status.AutoUnlock.Error,
                status.Presence.WakeWatchReady);
            bool heartbeat = lastHeartbeatUtc == DateTime.MinValue ||
                (nowUtc - lastHeartbeatUtc).TotalSeconds >= settings.Ble.HeartbeatSeconds;
            if (!string.Equals(summary, lastSummary, StringComparison.Ordinal) || heartbeat)
            {
                lastSummary = summary;
                lastHeartbeatUtc = nowUtc;
                logger.Info(
                    "EXE detection. " + summary +
                    " NetworkReason=" + status.Conditions.Network.Reason +
                    " PreferredWatch=" + status.Presence.PreferredWatchAddress +
                    " WatchHits=" + status.Presence.WatchHits +
                    " WatchRssi=" + status.Presence.LastWatchRssi +
                    " PhoneHits=" + status.Presence.PhoneHits +
                    " PhoneRssi=" + status.Presence.LastPhoneRssi +
                    " PhoneFastPath=" + status.Presence.PhoneFastPath +
                    " Drained=" + drained +
                    " Queue=" + status.QueueCount +
                    " Profiles=" + string.Join(
                        "|",
                        status.Conditions.Network.ProfileNames ?? new string[0]) +
                    " Ssids=" + string.Join(
                        "|",
                        status.Conditions.Network.Ssids ?? new string[0]) +
                    " Display=" + status.Conditions.DisplayState +
                    " DisplayWasOff=" + status.Conditions.DisplayWasOffSinceLock +
                    " InputSequence=" + status.Conditions.InputSequence +
                    " IdleSec=" + status.Conditions.UserIdleSeconds.ToString("N1") +
                    " StaleDropped=" + status.Presence.DroppedStaleAdvertisements +
                    " QueueDropped=" + status.DroppedQueueRecords);
            }
        }

        private static ProximityActionCoordinator CreateActionCoordinator(
            AgentSettings settings)
        {
            return new ProximityActionCoordinator(settings.Actions.ToCoordinatorOptions());
        }

        private static ProximityActionCoordinator CreateAutoUnlockArrivalCoordinator(
            AgentSettings settings)
        {
            return new ProximityActionCoordinator(
                new ProximityActionOptions
                {
                    ArrivalDetectionEnabled =
                        settings.AutoUnlock.Enabled &&
                        settings.AutoUnlock.TriggerOnArrival,
                    WakeCooldownSeconds = settings.Actions.Wake.CooldownSeconds,
                    WakeRearmSeconds = settings.Actions.Wake.RearmSeconds
                });
        }

        internal static ProximityActionType ResolveSystemAction(
            ProximityActionType requestedAction,
            bool arrivalConfirmed,
            bool interactiveWakeConfirmed,
            bool autoUnlockRequestStarted)
        {
            if (!autoUnlockRequestStarted)
            {
                return requestedAction;
            }

            if (arrivalConfirmed &&
                (requestedAction == ProximityActionType.None ||
                 requestedAction == ProximityActionType.WakeToLogin))
            {
                return ProximityActionType.RequestDisplayPower;
            }

            if (interactiveWakeConfirmed &&
                requestedAction == ProximityActionType.WakeToLogin)
            {
                return ProximityActionType.None;
            }

            return requestedAction;
        }

        private bool IsInteractivePresenceFresh(
            PresenceTrackerSnapshot presence,
            DateTime nowUtc)
        {
            double maximumAge = settings.AutoUnlock
                .InteractiveWakeMaximumPresenceAgeMilliseconds / 1000.0;
            bool phoneFresh = IsRecent(
                presence.LastPhoneSeenUtc,
                nowUtc,
                maximumAge);
            if (settings.PresencePolicies.AutoUnlock.Mode == PresenceMode.PhoneOnly)
            {
                return phoneFresh;
            }

            return phoneFresh && IsRecent(
                presence.LastWatchSeenUtc,
                nowUtc,
                maximumAge);
        }

        private static bool IsRecent(
            DateTime timestampUtc,
            DateTime nowUtc,
            double maximumAgeSeconds)
        {
            if (timestampUtc == DateTime.MinValue)
            {
                return false;
            }

            double age = (nowUtc - timestampUtc).TotalSeconds;
            return age >= -2 && age <= maximumAgeSeconds;
        }

        private void ThrowIfDisposed()
        {
            if (disposed)
            {
                throw new ObjectDisposedException("AgentRuntime");
            }
        }
    }
}
