using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Threading;
using BleProximityWake.Agent.Actions;
using BleProximityWake.Agent.AutoUnlock;
using BleProximityWake.Agent.Bluetooth;
using BleProximityWake.Agent.Configuration;
using BleProximityWake.Agent.Diagnostics;
using BleProximityWake.Agent.Runtime;
using BleProximityWake.Core.Actions;
using BleProximityWake.Core.Bluetooth;
using BleProximityWake.Core.Presence;
using BleProximityWake.Core.Scanning;

namespace BleProximityWake.Agent.Tests
{
    internal static class Program
    {
        private static int failures;

        private static int Main()
        {
            Run("Default policy set", TestDefaults);
            Run("Watch and phone policy", TestWatchAndPhone);
            Run("Phone-only policy", TestPhoneOnly);
            Run("Fresh resume evidence", TestFreshAfterResume);
            Run("Settings round trip", TestSettingsRoundTrip);
            Run("Network profile name matching", TestNetworkProfileNameMatching);
            Run("Network wildcard matching", TestNetworkWildcardMatching);
            Run("Invalid mode rejected", TestInvalidMode);
            Run("Hex wildcard matching", TestHexWildcardMatching);
            Run("Matcher configuration validation", TestMatcherConfigurationValidation);
            Run("Configured address is authoritative", TestConfiguredAddressPrecedence);
            Run("Watch hits require one address", TestWatchHitsRequireOneAddress);
            Run("Watch address learning and rotation", TestWatchAddressLearningAndRotation);
            Run("Learned watch weak-signal path", TestLearnedWatchWeakSignalPath);
            Run("Phone strong-signal fast path", TestPhoneStrongSignalFastPath);
            Run("Stale advertisement rejected", TestStaleAdvertisementRejected);
            Run("Resume freshness evidence", TestTrackerResumeFreshness);
            Run("Scan profile conditions", TestScanProfileConditions);
            Run("Schema 1 settings migration", TestSchemaOneMigration);
            Run("Agent runtime pipeline", TestAgentRuntimePipeline);
            Run("Agent runtime resume reset", TestAgentRuntimeResumeReset);
            Run("Agent runtime interactive wake pipeline", TestAgentRuntimeInteractiveWake);
            Run("BLE watcher start protection", TestBleWatcherStartProtection);
            Run("Interactive deadline starts after blocked capture", TestInteractiveDeadlineAfterCapture);
            Run("Departure presence uses lost window", TestDeparturePresenceWindow);
            Run("Legacy configuration import", TestLegacyConfigurationImport);
            Run("Phone-only unlock rejects single strong hit", TestPhoneOnlyUnlockStrongHit);
            Run("Disabled phone detection rejected", TestDisabledPhoneDetectionRejected);
            Run("System actions disabled by default", TestActionsDisabledByDefault);
            Run("Wake requires far then arrival", TestWakeRequiresFarThenArrival);
            Run("Wake failure retries are bounded", TestWakeFailureRetries);
            Run("Auto-lock requires all devices absent", TestAutoLockRequiresAllDevicesAbsent);
            Run("Disabled runtime actions never execute", TestDisabledRuntimeActionsNeverExecute);
            Run("Paused detection clears action state", TestPausedDetectionClearsActionState);
            Run("Manual unlock does not repeat auto-lock", TestManualUnlockDoesNotRepeatAutoLock);
            Run("Auto-unlock disabled by default", TestAutoUnlockDisabledByDefault);
            Run("Arrival detection works without wake action", TestArrivalWithoutWakeAction);
            Run("Arrival auto-unlock avoids wake input", TestArrivalAutoUnlockAvoidsWakeInput);
            Run("Interactive auto-unlock avoids wake input", TestInteractiveAutoUnlockAvoidsWakeInput);
            Run("Auto-unlock authorization payload", TestAutoUnlockAuthorizationPayload);
            Run("Auto-unlock named pipe exchange", TestAutoUnlockNamedPipeExchange);
            Run("Auto-unlock refreshes network before Broker", TestAutoUnlockFreshNetworkGate);
            Run("Auto-unlock gates", TestAutoUnlockGates);
            Run("Auto-unlock accepted once per lock cycle", TestAutoUnlockAcceptedOnce);
            Run("Auto-unlock pause preserves consumed cycle", TestAutoUnlockPausePreservesCycle);
            Run("Auto-unlock permanent rejection", TestAutoUnlockPermanentRejection);
            Run("Auto-unlock transient retries", TestAutoUnlockTransientRetries);
            Run("Auto-unlock errors exhaust retries", TestAutoUnlockErrorRetriesExhausted);
            Run("Interactive wake input suppression", TestInteractiveWakeInputSuppression);
            Run("Interactive wake resume deduplication", TestInteractiveWakeResumeDeduplication);
            Run("Interactive wake timeout and rearm", TestInteractiveWakeTimeoutAndRearm);
            Run("Interactive wake authorizes once", TestInteractiveWakeAuthorizesOnce);
            Run("Interactive wake ignores input during authorization", TestInteractiveWakeAuthorizationPending);

            if (failures == 0)
            {
                Console.WriteLine("All EXE Agent tests passed.");
                return 0;
            }

            Console.Error.WriteLine(failures + " EXE Agent test(s) failed.");
            return 1;
        }

        private static void TestDefaults()
        {
            PresencePolicySet policies = PresencePolicySet.CreateDefaults();
            Equal(PresenceMode.PhoneOnly, policies.Wake.Mode, "wake default");
            Equal(PresenceMode.WatchAndPhone, policies.AutoUnlock.Mode, "auto-unlock default");
            Equal(PresenceMode.PhoneOnly, policies.AutoLock.Mode, "auto-lock default");
            True(policies.AutoUnlock.RequireFreshAfterResume, "auto-unlock fresh resume default");
        }

        private static void TestWatchAndPhone()
        {
            var policy = new PresencePolicy
            {
                Mode = PresenceMode.WatchAndPhone,
                RequireFreshAfterResume = false
            };
            var observation = new PresenceObservation
            {
                WatchReady = true,
                PhoneReady = false
            };

            PresenceDecision first = PresenceDecisionEvaluator.Evaluate(policy, observation);
            False(first.PresenceReady, "phone must be required");
            Equal("phone-not-ready", first.Reason, "failure reason");

            observation.PhoneReady = true;
            True(
                PresenceDecisionEvaluator.Evaluate(policy, observation).PresenceReady,
                "both devices should satisfy policy");
        }

        private static void TestPhoneOnly()
        {
            var policy = new PresencePolicy
            {
                Mode = PresenceMode.PhoneOnly,
                RequireFreshAfterResume = false
            };
            var observation = new PresenceObservation
            {
                WatchReady = false,
                PhoneReady = true
            };

            PresenceDecision decision = PresenceDecisionEvaluator.Evaluate(policy, observation);
            True(decision.PresenceReady, "phone should be sufficient");
            False(decision.WatchRequired, "watch must not be required");
        }

        private static void TestFreshAfterResume()
        {
            var policy = new PresencePolicy
            {
                Mode = PresenceMode.WatchAndPhone,
                RequireFreshAfterResume = true
            };
            var observation = new PresenceObservation
            {
                WatchReady = true,
                PhoneReady = true,
                WatchFreshAfterResume = false,
                PhoneFreshAfterResume = true
            };

            False(
                PresenceDecisionEvaluator.Evaluate(policy, observation).PresenceReady,
                "stale watch evidence must be rejected");
            observation.WatchFreshAfterResume = true;
            True(
                PresenceDecisionEvaluator.Evaluate(policy, observation).PresenceReady,
                "fresh evidence should satisfy policy");
        }

        private static void TestSettingsRoundTrip()
        {
            string directory = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                "BleProximityWake.Agent.Tests",
                Guid.NewGuid().ToString("N"));
            string path = System.IO.Path.Combine(directory, "agent-settings.json");

            try
            {
                var store = new AgentSettingsStore(path);
                AgentSettings settings = AgentSettings.CreateDefaults();
                settings.PresencePolicies.AutoUnlock.Mode = PresenceMode.PhoneOnly;
                settings.Detection.PhoneMatcher.Address = "02:00:00:00:00:01";
                settings.Network.AllowedSsids = new[] { "Example-Wired" };
                settings.Actions.Wake.Enabled = true;
                settings.AutoUnlock.InteractiveWakeConfirmationMilliseconds = 7000;
                store.Save(settings);

                AgentSettings loaded = store.Load();
                Equal(PresenceMode.PhoneOnly, loaded.PresencePolicies.AutoUnlock.Mode, "saved mode");
                True(
                    loaded.PresencePolicies.AutoUnlock.RequireFreshAfterResume,
                    "saved freshness requirement");
                Equal(
                    "02:00:00:00:00:01",
                    loaded.Detection.PhoneMatcher.Address,
                    "saved phone address");
                Equal("Example-Wired", loaded.Network.AllowedSsids[0], "saved SSID");
                True(loaded.Actions.Wake.Enabled, "saved wake action");
                False(loaded.Actions.AutoLock.Enabled, "auto-lock remains disabled");
                False(loaded.AutoUnlock.Enabled, "auto-unlock remains disabled");
                Equal(
                    7000,
                    loaded.AutoUnlock.InteractiveWakeConfirmationMilliseconds,
                    "saved interactive confirmation");
                True(File.ReadAllText(path).Contains("\"mode\":\"PhoneOnly\""), "readable mode value");
            }
            finally
            {
                if (Directory.Exists(directory))
                {
                    Directory.Delete(directory, true);
                }
            }
        }

        private static void TestNetworkProfileNameMatching()
        {
            AgentSettings settings = AgentSettings.CreateDefaults();
            settings.Network.AllowedProfileNames = new[] { "Example-Wired" };
            settings.Network.AllowedSsids = new[] { "Example-WiFi" };
            var provider = new NetworkContextProvider(settings.Network);

            NetworkContextSnapshot wired = provider.Evaluate(
                new[] { "Example-Wired" },
                new string[0]);
            True(wired.Allowed, "Windows network profile name should match");
            Equal("profile-match:Example-Wired", wired.Reason, "profile match reason");

            NetworkContextSnapshot interfaceAlias = provider.Evaluate(
                new[] { "以太网 6" },
                new string[0]);
            False(
                interfaceAlias.Allowed,
                "interface alias must not be treated as the network profile name");

            NetworkContextSnapshot wireless = provider.Evaluate(
                new[] { "Unidentified network" },
                new[] { "Example-WiFi" });
            True(wireless.Allowed, "connected Wi-Fi SSID should match");
            Equal("ssid-match:Example-WiFi", wireless.Reason, "SSID match reason");
        }

        private static void TestNetworkWildcardMatching()
        {
            AgentSettings settings = AgentSettings.CreateDefaults();
            settings.Network.AllowedProfileNames = new[] { "Example-Wired*" };
            settings.Network.AllowedSsids = new[] { "Example-*-5G" };
            var provider = new NetworkContextProvider(settings.Network);

            True(
                provider.Evaluate(new[] { "Example-Wired-2" }, new string[0]).Allowed,
                "profile wildcard should match");
            True(
                provider.Evaluate(new string[0], new[] { "Example-WiFi-5G" }).Allowed,
                "SSID wildcard should match");
            False(
                provider.Evaluate(new[] { "Guest" }, new[] { "Example-WiFi-2G" }).Allowed,
                "different network must not match wildcard");
        }

        private static void TestHexWildcardMatching()
        {
            True(
                HexPatternMatcher.IsMatch(
                    "004C:10052018A1B2C3",
                    "004C10052?18??????"),
                "Apple manufacturer data should match wildcard pattern");
            False(
                HexPatternMatcher.IsMatch(
                    "004C:10062018A1B2C3",
                    "004C10052?18??????"),
                "different subtype must not match");
        }

        private static void TestConfiguredAddressPrecedence()
        {
            var options = new DeviceMatcherOptions
            {
                Address = "AA:AA:AA:AA:AA:AA",
                ManufacturerDataHexPrefix = "004C"
            };
            BleAdvertisement wrongAddress = Advertisement(
                "BB:BB:BB:BB:BB:BB",
                -40,
                DateTime.UtcNow,
                "004C:10052018A1B2C3");
            False(
                DeviceAdvertisementMatcher.IsMatch(wrongAddress, options),
                "manufacturer data must not bypass an explicit address");

            wrongAddress.Address = "AA-AA-AA-AA-AA-AA";
            True(
                DeviceAdvertisementMatcher.IsMatch(wrongAddress, options),
                "normalized configured address should match");
        }

        private static void TestMatcherConfigurationValidation()
        {
            new DeviceMatcherOptions
            {
                ManufacturerDataHexPattern = "004C:1005:2?:18:??????"
            }.Validate("watch");

            Throws<InvalidOperationException>(
                () => new DeviceMatcherOptions
                {
                    Address = "AA:BB"
                }.Validate("watch"),
                "short Bluetooth addresses must be rejected");
            Throws<InvalidOperationException>(
                () => new DeviceMatcherOptions
                {
                    ServiceUuid = "not-a-uuid"
                }.Validate("watch"),
                "invalid service UUID must be rejected");
            Throws<InvalidOperationException>(
                () => new DeviceMatcherOptions
                {
                    ManufacturerDataHexPattern = "004CZZ1005"
                }.Validate("watch"),
                "invalid pattern characters must be rejected");
            Throws<InvalidOperationException>(
                () => new DeviceMatcherOptions
                {
                    Address = "AA:BB:CC:DD:EE:FF",
                    NameContains = "Watch"
                }.Validate("watch"),
                "authoritative address cannot be combined with ignored conditions");
        }

        private static void TestWatchHitsRequireOneAddress()
        {
            PresenceDetectionOptions options = DetectionOptions();
            options.WatchHitCount = 2;
            var tracker = new DevicePresenceTracker(options);
            DateTime start = DateTime.UtcNow;

            tracker.Process(
                Advertisement("AA:AA:AA:AA:AA:AA", -60, start, "004C10052018AABBCC"),
                start);
            tracker.Process(
                Advertisement(
                    "BB:BB:BB:BB:BB:BB",
                    -60,
                    start.AddMilliseconds(100),
                    "004C10052018DDEEFF"),
                start.AddMilliseconds(100));
            False(
                tracker.Evaluate(start.AddMilliseconds(100)).Observation.WatchReady,
                "different addresses must not combine watch hits");

            tracker.Process(
                Advertisement(
                    "BB:BB:BB:BB:BB:BB",
                    -60,
                    start.AddMilliseconds(200),
                    "004C10052018DDEEFF"),
                start.AddMilliseconds(200));
            True(
                tracker.Evaluate(start.AddMilliseconds(200)).Observation.WatchReady,
                "two hits from the same address should confirm the watch");
        }

        private static void TestWatchAddressLearningAndRotation()
        {
            PresenceDetectionOptions options = DetectionOptions();
            var tracker = new DevicePresenceTracker(options);
            DateTime start = DateTime.UtcNow;
            for (int index = 0; index < 3; index++)
            {
                DateTime timestamp = start.AddMilliseconds(index * 100);
                tracker.Process(
                    Advertisement("AA:AA:AA:AA:AA:AA", -55, timestamp, "004C:10052018A1B2C3"),
                    timestamp);
            }

            PresenceTrackerSnapshot first = tracker.Evaluate(start.AddMilliseconds(300));
            Equal("AA:AA:AA:AA:AA:AA", first.PreferredWatchAddress, "first learned address");
            Equal(3, first.PreferredWatchHits, "first learned hits");

            DateTime rotatedAt = start.AddSeconds(21);
            for (int index = 0; index < 3; index++)
            {
                DateTime timestamp = rotatedAt.AddMilliseconds(index * 100);
                tracker.Process(
                    Advertisement("BB:BB:BB:BB:BB:BB", -58, timestamp, "004C:10052018A1B2C3"),
                    timestamp);
            }

            PresenceTrackerSnapshot rotated = tracker.Evaluate(rotatedAt.AddMilliseconds(300));
            Equal("BB:BB:BB:BB:BB:BB", rotated.PreferredWatchAddress, "rotated learned address");
        }

        private static void TestLearnedWatchWeakSignalPath()
        {
            PresenceDetectionOptions options = DetectionOptions();
            options.WatchHitCount = 1;
            var tracker = new DevicePresenceTracker(options);
            DateTime start = DateTime.UtcNow;
            for (int index = 0; index < 3; index++)
            {
                DateTime timestamp = start.AddMilliseconds(index * 100);
                tracker.Process(
                    Advertisement("AA:AA:AA:AA:AA:AA", -55, timestamp, "004C:10052018A1B2C3"),
                    timestamp);
            }

            tracker.Evaluate(start.AddMilliseconds(300));
            tracker.SetLocked(true);
            DateTime weakAt = start.AddSeconds(11);
            tracker.Process(
                Advertisement("AA:AA:AA:AA:AA:AA", -78, weakAt, "004C:10052018A1B2C3"),
                weakAt);
            True(
                tracker.Evaluate(weakAt).Observation.WatchReady,
                "learned locked address should accept weaker signal");

            var unknownTracker = new DevicePresenceTracker(options);
            unknownTracker.SetLocked(true);
            unknownTracker.Process(
                Advertisement("BB:BB:BB:BB:BB:BB", -78, weakAt, "004C:10052018A1B2C3"),
                weakAt);
            False(
                unknownTracker.Evaluate(weakAt).Observation.WatchReady,
                "unknown weak address must not use learned threshold");
        }

        private static void TestPhoneStrongSignalFastPath()
        {
            PresenceDetectionOptions options = DetectionOptions();
            var tracker = new DevicePresenceTracker(options);
            DateTime now = DateTime.UtcNow;
            tracker.Process(
                Advertisement("02:00:00:00:00:01", -58, now, string.Empty),
                now);
            PresenceTrackerSnapshot snapshot = tracker.Evaluate(now);
            True(snapshot.Observation.PhoneReady, "one strong phone hit should be sufficient");
            True(snapshot.PhoneFastPath, "strong phone path should be reported");

            var ordinaryTracker = new DevicePresenceTracker(options);
            ordinaryTracker.Process(
                Advertisement("02:00:00:00:00:01", -70, now, string.Empty),
                now);
            False(
                ordinaryTracker.Evaluate(now).Observation.PhoneReady,
                "one ordinary phone hit should not be sufficient");
            ordinaryTracker.Process(
                Advertisement(
                    "02:00:00:00:00:01",
                    -70,
                    now.AddSeconds(1),
                    string.Empty),
                now.AddSeconds(1));
            True(
                ordinaryTracker.Evaluate(now.AddSeconds(1)).Observation.PhoneReady,
                "two ordinary phone hits should be sufficient");
        }

        private static void TestStaleAdvertisementRejected()
        {
            PresenceDetectionOptions options = DetectionOptions();
            var tracker = new DevicePresenceTracker(options);
            DateTime now = DateTime.UtcNow;
            tracker.Process(
                Advertisement(
                    "02:00:00:00:00:01",
                    -50,
                    now.AddSeconds(-10),
                    string.Empty),
                now);
            PresenceTrackerSnapshot snapshot = tracker.Evaluate(now);
            False(snapshot.Observation.PhoneReady, "stale phone evidence must be rejected");
            Equal(1, snapshot.DroppedStaleAdvertisements, "stale drop count");
        }

        private static void TestTrackerResumeFreshness()
        {
            PresenceDetectionOptions options = DetectionOptions();
            options.WatchHitCount = 1;
            options.PhoneHitCount = 1;
            var tracker = new DevicePresenceTracker(options);
            DateTime now = DateTime.UtcNow;
            tracker.Process(
                Advertisement("AA:AA:AA:AA:AA:AA", -50, now, "004C:10052018A1B2C3"),
                now);
            tracker.Process(
                Advertisement("02:00:00:00:00:01", -65, now, string.Empty),
                now);
            tracker.BeginResume(now.AddSeconds(1));

            PresenceTrackerSnapshot stale = tracker.Evaluate(now.AddSeconds(1));
            False(stale.Observation.WatchFreshAfterResume, "old watch evidence must be stale");
            False(stale.Observation.PhoneFreshAfterResume, "old phone evidence must be stale");

            DateTime freshAt = now.AddSeconds(1.1);
            tracker.Process(
                Advertisement("AA:AA:AA:AA:AA:AA", -50, freshAt, "004C:10052018A1B2C3"),
                freshAt);
            tracker.Process(
                Advertisement("02:00:00:00:00:01", -65, freshAt, string.Empty),
                freshAt);
            PresenceTrackerSnapshot fresh = tracker.Evaluate(freshAt);
            True(fresh.Observation.WatchFreshAfterResume, "new watch evidence should be fresh");
            True(fresh.Observation.PhoneFreshAfterResume, "new phone evidence should be fresh");
        }

        private static void TestScanProfileConditions()
        {
            var context = new ScanContext
            {
                SessionLocked = true,
                NetworkAllowed = true,
                AcPowerConnected = true
            };
            ScanProfile active = ScanProfileSelector.Select(context, 250, 1000);
            Equal(BleScanMode.Active, active.Mode, "all conditions should enable active scan");
            Equal(250, active.PollIntervalMilliseconds, "locked interval");

            context.NetworkAllowed = false;
            Equal(
                BleScanMode.Passive,
                ScanProfileSelector.Select(context, 250, 1000).Mode,
                "non-whitelisted network must be passive");
            context.NetworkAllowed = true;
            context.AcPowerConnected = false;
            Equal(
                BleScanMode.Passive,
                ScanProfileSelector.Select(context, 250, 1000).Mode,
                "battery power must be passive");
            context.AcPowerConnected = true;
            context.SessionLocked = false;
            Equal(
                1000,
                ScanProfileSelector.Select(context, 250, 1000).PollIntervalMilliseconds,
                "unlocked session must use background interval");
        }

        private static void TestSchemaOneMigration()
        {
            string directory = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                "BleProximityWake.Agent.Tests",
                Guid.NewGuid().ToString("N"));
            string path = System.IO.Path.Combine(directory, "agent-settings.json");
            try
            {
                Directory.CreateDirectory(directory);
                File.WriteAllText(
                    path,
                    "{\"schemaVersion\":1,\"presencePolicies\":{\"wake\":{\"mode\":\"PhoneOnly\"}}}");
                AgentSettings settings = new AgentSettingsStore(path).Load();
                Equal(PresenceMode.PhoneOnly, settings.PresencePolicies.Wake.Mode, "old policy");
                True(settings.Ble.Enabled, "new BLE defaults should be supplied");
                True(settings.Detection.PhoneEnabled, "new detection defaults should be supplied");
            }
            finally
            {
                if (Directory.Exists(directory))
                {
                    Directory.Delete(directory, true);
                }
            }
        }

        private static void TestAgentRuntimePipeline()
        {
            string directory = TemporaryDirectory();
            try
            {
                AgentSettings settings = AgentSettings.CreateDefaults();
                settings.Detection = DetectionOptions();
                var source = new FakeBleSource();
                var conditions = new FakeConditionSource
                {
                    Snapshot = Conditions(false, true, true, 0, DateTime.MinValue)
                };
                using (var logger = new FileLogger(directory))
                using (var runtime = new AgentRuntime(settings, logger, source, conditions))
                {
                    AgentRuntimeStatus background = runtime.Poll();
                    Equal(BleScanMode.Passive, source.Mode, "unlocked runtime scan mode");
                    Equal(1000, background.ScanProfile.PollIntervalMilliseconds, "background poll");

                    conditions.Snapshot = Conditions(true, true, true, 0, DateTime.MinValue);
                    DateTime now = DateTime.UtcNow;
                    source.Enqueue(
                        Advertisement("AA:AA:AA:AA:AA:AA", -50, now, "004C:10052018A1B2C3"));
                    source.Enqueue(
                        Advertisement("02:00:00:00:00:01", -50, now, string.Empty));
                    AgentRuntimeStatus active = runtime.Poll();
                    Equal(BleScanMode.Active, source.Mode, "locked runtime scan mode");
                    Equal(250, active.ScanProfile.PollIntervalMilliseconds, "active poll");
                    True(active.Presence.Observation.WatchReady, "runtime watch presence");
                    True(active.Presence.Observation.PhoneReady, "runtime phone presence");
                    True(active.AutoUnlockPresence.PresenceReady, "runtime auto-unlock policy");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void TestAgentRuntimeResumeReset()
        {
            string directory = TemporaryDirectory();
            try
            {
                AgentSettings settings = AgentSettings.CreateDefaults();
                settings.Detection = DetectionOptions();
                var source = new FakeBleSource();
                var conditions = new FakeConditionSource
                {
                    Snapshot = Conditions(true, true, true, 0, DateTime.MinValue)
                };
                using (var logger = new FileLogger(directory))
                using (var runtime = new AgentRuntime(settings, logger, source, conditions))
                {
                    DateTime initial = DateTime.UtcNow;
                    source.Enqueue(
                        Advertisement("AA:AA:AA:AA:AA:AA", -50, initial, "004C:10052018A1B2C3"));
                    source.Enqueue(
                        Advertisement("02:00:00:00:00:01", -50, initial, string.Empty));
                    True(runtime.Poll().AutoUnlockPresence.PresenceReady, "initial presence");

                    DateTime resume = DateTime.UtcNow.AddMilliseconds(10);
                    conditions.Snapshot = Conditions(true, true, true, 1, resume);
                    source.Enqueue(
                        Advertisement("AA:AA:AA:AA:AA:AA", -50, initial, "004C:10052018A1B2C3"));
                    AgentRuntimeStatus cleared = runtime.Poll();
                    False(
                        cleared.AutoUnlockPresence.PresenceReady,
                        "resume must invalidate pre-resume evidence");
                    True(source.ClearCount > 0, "resume should clear queued advertisements");

                    DateTime fresh = resume.AddMilliseconds(100);
                    source.Enqueue(
                        Advertisement("AA:AA:AA:AA:AA:AA", -50, fresh, "004C:10052018A1B2C3"));
                    source.Enqueue(
                        Advertisement("02:00:00:00:00:01", -50, fresh, string.Empty));
                    True(
                        runtime.Poll().AutoUnlockPresence.PresenceReady,
                        "fresh post-resume evidence should satisfy policy");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void TestAgentRuntimeInteractiveWake()
        {
            string directory = TemporaryDirectory();
            try
            {
                AgentSettings settings = AgentSettings.CreateDefaults();
                settings.Detection = DetectionOptions();
                settings.PresencePolicies.AutoUnlock.Mode = PresenceMode.PhoneOnly;
                settings.PresencePolicies.AutoUnlock.RequireFreshAfterResume = true;
                settings.AutoUnlock.Enabled = true;
                settings.AutoUnlock.TriggerOnArrival = false;
                settings.AutoUnlock.TriggerOnInteractiveWake = true;
                var source = new FakeBleSource();
                RuntimeConditionSnapshot snapshot =
                    Conditions(false, true, true, 0, DateTime.MinValue);
                snapshot.UserIdleSeconds = 10;
                snapshot.DisplayState = DisplayPowerState.On;
                var conditions = new FakeConditionSource { Snapshot = snapshot };
                var broker = new FakeAutoUnlockBrokerClient(AutoUnlockBrokerStatus.Ok);
                var requestRunner = new ControlledAutoUnlockRequestRunner();
                using (var logger = new FileLogger(directory))
                using (var runtime = new AgentRuntime(
                    settings,
                    logger,
                    source,
                    conditions,
                    new FakeActionExecutor(),
                    broker,
                    requestRunner))
                {
                    DateTime initial = DateTime.UtcNow;
                    source.Enqueue(
                        Advertisement("02:00:00:00:00:01", -70, initial, string.Empty));
                    source.Enqueue(
                        Advertisement(
                            "02:00:00:00:00:01",
                            -70,
                            initial.AddMilliseconds(100),
                            string.Empty));
                    True(
                        runtime.Poll().AutoUnlockPresence.PresenceReady,
                        "device is present before locking");

                    snapshot.SessionLocked = true;
                    snapshot.UserIdleSeconds = 0;
                    runtime.Poll();
                    snapshot.UserIdleSeconds = 3;
                    runtime.Poll();
                    Thread.Sleep(2100);
                    snapshot.UserIdleSeconds = 0.1;
                    AgentRuntimeStatus triggered = runtime.Poll();
                    True(
                        triggered.InteractiveWake.RecoveryRequested,
                        "input edge must request BLE recovery");
                    int restartCountAfterRecovery = source.RestartCount;
                    Equal(0, broker.Count, "old presence must not authorize");

                    DateTime fresh = DateTime.UtcNow;
                    source.Enqueue(
                        Advertisement("02:00:00:00:00:01", -70, fresh, string.Empty));
                    source.Enqueue(
                        Advertisement(
                            "02:00:00:00:00:01",
                            -70,
                            fresh.AddMilliseconds(100),
                            string.Empty));
                    AgentRuntimeStatus confirmed = runtime.Poll();
                    Equal(
                        restartCountAfterRecovery,
                        source.RestartCount,
                        "same interaction must not force a second BLE recovery");
                    True(
                        confirmed.InteractiveWake.Confirmed,
                        "post-trigger presence must confirm interaction");
                    Equal(1, broker.Count, "fresh presence authorizes Broker once");
                    True(confirmed.AutoUnlock.RequestPending, "Broker request remains pending");
                    False(runtime.CanPauseDetection, "pending authorization disables pause");
                    runtime.SetDetectionPaused(true);
                    False(runtime.DetectionPaused, "pending authorization refuses pause");

                    requestRunner.Complete();
                    runtime.Poll();
                    Equal(1, broker.Count, "same lock cycle must stay single-use");
                    True(runtime.CanPauseDetection, "completed authorization restores pause");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void TestBleWatcherStartProtection()
        {
            DateTime now = DateTime.UtcNow;
            DateTime protectedUntil = now.AddMilliseconds(750);
            True(
                WinRtBleAdvertisementSource.IsStartProtected(
                    now.AddMilliseconds(500),
                    protectedUntil,
                    true),
                "same-mode start must be suppressed during protection");
            False(
                WinRtBleAdvertisementSource.IsStartProtected(
                    now.AddMilliseconds(500),
                    protectedUntil,
                    false),
                "mode changes must bypass start protection");
            False(
                WinRtBleAdvertisementSource.IsStartProtected(
                    protectedUntil,
                    protectedUntil,
                    true),
                "start may be retried when protection expires");
        }

        private static void TestInteractiveDeadlineAfterCapture()
        {
            string directory = TemporaryDirectory();
            try
            {
                AgentSettings settings = AgentSettings.CreateDefaults();
                settings.Detection = DetectionOptions();
                settings.AutoUnlock.Enabled = true;
                settings.AutoUnlock.TriggerOnArrival = false;
                settings.AutoUnlock.TriggerOnInteractiveWake = true;
                settings.AutoUnlock.InteractiveWakeConfirmationMilliseconds = 500;
                RuntimeConditionSnapshot snapshot =
                    Conditions(true, true, true, 0, DateTime.MinValue);
                snapshot.UserIdleSeconds = 10;
                snapshot.DisplayState = DisplayPowerState.Off;
                snapshot.DisplaySequence = 0;
                var conditions = new FakeConditionSource { Snapshot = snapshot };
                var source = new FakeBleSource();
                using (var logger = new FileLogger(directory))
                using (var runtime = new AgentRuntime(settings, logger, source, conditions))
                {
                    runtime.Poll();
                    snapshot.DisplayState = DisplayPowerState.On;
                    snapshot.DisplaySequence = 1;
                    snapshot.DisplayWasOffSinceLock = true;
                    snapshot.UserIdleSeconds = 3;
                    Thread.Sleep(2100);
                    runtime.Poll();
                    snapshot.UserIdleSeconds = 0.1;
                    conditions.DelayMilliseconds = 700;
                    AgentRuntimeStatus triggered = runtime.Poll();
                    False(
                        triggered.InteractiveWake.RecoveryRequested,
                        "input must reuse the display-on recovery");
                    True(
                        triggered.InteractiveWake.Pending,
                        "input must establish the confirmation candidate");

                    conditions.DelayMilliseconds = 0;
                    AgentRuntimeStatus next = runtime.Poll();
                    True(
                        next.InteractiveWake.Pending,
                        "confirmation deadline must start after capture returns");
                    False(
                        next.InteractiveWake.State.StartsWith("timeout:"),
                        "resume delay must not expire the new confirmation window");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void TestDeparturePresenceWindow()
        {
            PresenceDetectionOptions options = DetectionOptions();
            var tracker = new DevicePresenceTracker(options);
            DateTime start = DateTime.UtcNow;
            for (int index = 0; index < 3; index++)
            {
                DateTime timestamp = start.AddMilliseconds(index * 100);
                tracker.Process(
                    Advertisement("AA:AA:AA:AA:AA:AA", -55, timestamp, "004C:10052018A1B2C3"),
                    timestamp);
            }

            tracker.Evaluate(start.AddMilliseconds(300));
            PresenceTrackerSnapshot afterHitWindow = tracker.Evaluate(start.AddSeconds(11));
            False(
                afterHitWindow.Observation.WatchReady,
                "arrival readiness should expire after hit window");
            True(
                afterHitWindow.WatchPresentForDeparture,
                "departure presence should remain through lost window");
            False(
                tracker.Evaluate(start.AddSeconds(31)).WatchPresentForDeparture,
                "departure presence should expire after lost window");
        }

        private static void TestLegacyConfigurationImport()
        {
            string directory = TemporaryDirectory();
            string path = System.IO.Path.Combine(directory, "config.json");
            try
            {
                File.WriteAllText(
                    path,
                    "{" +
                    "\"target\":{\"manufacturerDataHexPattern\":\"004C10052?18??????\"}," +
                    "\"proximity\":{\"rssiThreshold\":-70,\"learnedAddressRssiThreshold\":-84,\"hitCount\":2}," +
                    "\"phone\":{\"enabled\":true,\"address\":\"02:00:00:00:00:01\",\"rssiThreshold\":-80}," +
                    "\"network\":{\"enabled\":true,\"allowedProfileNames\":[\"Example-Wired\"],\"allowedSsids\":[\"Home\"]}," +
                    "\"diagnostics\":{\"bleSamplingIntervalMilliseconds\":500,\"lockedPollIntervalMilliseconds\":250,\"unlockedPollIntervalMilliseconds\":1000}," +
                    "\"autoUnlock\":{\"requirePhonePresence\":true}," +
                    "\"autoLock\":{\"requireWatchAbsent\":true,\"requirePhoneAbsent\":true}" +
                    "}");

                AgentSettings imported = LegacyConfigImporter.Import(
                    path,
                    AgentSettings.CreateDefaults());
                Equal(
                    "004C10052?18??????",
                    imported.Detection.WatchMatcher.ManufacturerDataHexPattern,
                    "watch pattern");
                Equal(-70, imported.Detection.WatchRssiThreshold, "watch RSSI");
                Equal(-84, imported.Detection.LearnedWatchRssiThreshold, "learned RSSI");
                Equal(2, imported.Detection.WatchHitCount, "watch hits");
                Equal(
                    "02:00:00:00:00:01",
                    imported.Detection.PhoneMatcher.Address,
                    "phone address");
                Equal("Example-Wired", imported.Network.AllowedProfileNames[0], "network profile");
                Equal("Home", imported.Network.AllowedSsids[0], "network SSID");
                Equal(
                    PresenceMode.WatchAndPhone,
                    imported.PresencePolicies.Wake.Mode,
                    "legacy wake policy");
                Equal(
                    PresenceMode.WatchAndPhone,
                    imported.PresencePolicies.AutoLock.Mode,
                    "legacy auto-lock policy");
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void TestPhoneOnlyUnlockStrongHit()
        {
            string directory = TemporaryDirectory();
            try
            {
                AgentSettings settings = AgentSettings.CreateDefaults();
                settings.Detection = DetectionOptions();
                settings.PresencePolicies.AutoUnlock.Mode = PresenceMode.PhoneOnly;
                var source = new FakeBleSource();
                var conditions = new FakeConditionSource
                {
                    Snapshot = Conditions(true, true, true, 0, DateTime.MinValue)
                };
                using (var logger = new FileLogger(directory))
                using (var runtime = new AgentRuntime(settings, logger, source, conditions))
                {
                    DateTime now = DateTime.UtcNow;
                    source.Enqueue(
                        Advertisement("02:00:00:00:00:01", -50, now, string.Empty));
                    AgentRuntimeStatus oneHit = runtime.Poll();
                    True(oneHit.Presence.Observation.PhoneReady, "strong presence fast path");
                    False(
                        oneHit.AutoUnlockPresence.PresenceReady,
                        "single strong hit must not authorize phone-only unlock");

                    source.Enqueue(
                        Advertisement(
                            "02:00:00:00:00:01",
                            -70,
                            now.AddMilliseconds(100),
                            string.Empty));
                    True(
                        runtime.Poll().AutoUnlockPresence.PresenceReady,
                        "configured phone hit count should authorize phone-only unlock");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void TestDisabledPhoneDetectionRejected()
        {
            PresenceDetectionOptions options = DetectionOptions();
            options.PhoneEnabled = false;
            Throws<InvalidOperationException>(
                () => options.Validate(),
                "all supported modes require phone detection");
        }

        private static PresenceDetectionOptions DetectionOptions()
        {
            return new PresenceDetectionOptions
            {
                WatchMatcher = new DeviceMatcherOptions
                {
                    ManufacturerDataHexPattern = "004C10052?18??????"
                },
                WatchRssiThreshold = -68,
                LearnedWatchRssiThreshold = -82,
                WatchHitCount = 1,
                WatchHitWindowSeconds = 10,
                WatchLostSeconds = 30,
                AddressLearningWindowSeconds = 20,
                AddressLearningMinimumHits = 3,
                PhoneEnabled = true,
                PhoneMatcher = new DeviceMatcherOptions
                {
                    Address = "02:00:00:00:00:01"
                },
                PhoneRssiThreshold = -82,
                PhoneStrongRssiSingleHitThreshold = -60,
                PhoneHitCount = 2,
                PhoneHitWindowSeconds = 10,
                PhonePresenceTimeoutSeconds = 20,
                MaximumAdvertisementAgeSeconds = 5
            };
        }

        private static BleAdvertisement Advertisement(
            string address,
            int rssi,
            DateTime timestampUtc,
            string manufacturerData)
        {
            var advertisement = new BleAdvertisement
            {
                Address = address,
                Rssi = rssi,
                TimestampUtc = timestampUtc
            };
            if (!string.IsNullOrWhiteSpace(manufacturerData))
            {
                advertisement.ManufacturerData.Add(manufacturerData);
            }

            return advertisement;
        }

        private static RuntimeConditionSnapshot Conditions(
            bool locked,
            bool networkAllowed,
            bool acPower,
            long resumeSequence,
            DateTime resumeUtc)
        {
            return new RuntimeConditionSnapshot
            {
                SessionLocked = locked,
                SessionKnown = true,
                AcPowerConnected = acPower,
                ResumeSequence = resumeSequence,
                LastResumeUtc = resumeUtc,
                Network = new NetworkContextSnapshot
                {
                    Allowed = networkAllowed,
                    Reason = networkAllowed ? "test-match" : "test-no-match",
                    ProfileNames = new string[0],
                    Ssids = new string[0]
                }
            };
        }

        private static void TestActionsDisabledByDefault()
        {
            AgentSettings settings = AgentSettings.CreateDefaults();
            False(settings.Actions.Wake.Enabled, "wake must be opt-in");
            False(settings.Actions.AutoLock.Enabled, "auto-lock must be opt-in");
        }

        private static void TestWakeRequiresFarThenArrival()
        {
            var coordinator = new ProximityActionCoordinator(
                new ProximityActionOptions
                {
                    WakeEnabled = true,
                    WakeRearmSeconds = 30,
                    WakeCooldownSeconds = 45
                });
            DateTime start = DateTime.UtcNow;
            var input = ActionInput(start, true, true, true);

            Equal(
                ProximityActionType.None,
                coordinator.Evaluate(input).Action,
                "near device at lock must not wake");
            input.WakePresenceReady = false;
            input.NowUtc = start.AddSeconds(1);
            coordinator.Evaluate(input);
            input.NowUtc = start.AddSeconds(31);
            ProximityActionDecision armed = coordinator.Evaluate(input);
            True(armed.WakeArmed, "far interval should arm wake");

            input.WakePresenceReady = true;
            input.NowUtc = start.AddSeconds(32);
            Equal(
                ProximityActionType.WakeToLogin,
                coordinator.Evaluate(input).Action,
                "arrival after far interval should wake");
            input.NowUtc = start.AddSeconds(90);
            Equal(
                ProximityActionType.None,
                coordinator.Evaluate(input).Action,
                "continuous presence must not repeat wake");
        }

        private static void TestWakeFailureRetries()
        {
            var coordinator = new ProximityActionCoordinator(
                new ProximityActionOptions
                {
                    WakeEnabled = true,
                    WakeRearmSeconds = 1,
                    WakeCooldownSeconds = 45,
                    WakeFailureRetrySeconds = 2,
                    WakeFailureMaximumRetries = 2
                });
            DateTime start = DateTime.UtcNow;
            ProximityActionInput input = ActionInput(start, true, false, true);
            coordinator.Evaluate(input);
            input.NowUtc = start.AddSeconds(1);
            coordinator.Evaluate(input);
            input.WakePresenceReady = true;
            input.NowUtc = start.AddSeconds(2);
            Equal(
                ProximityActionType.WakeToLogin,
                coordinator.Evaluate(input).Action,
                "first arrival should wake");
            coordinator.ReportActionResult(
                ProximityActionType.WakeToLogin,
                false,
                input.NowUtc);

            input.NowUtc = start.AddSeconds(3);
            Equal(
                "wake-failure-retry-wait",
                coordinator.Evaluate(input).Reason,
                "failed wake must wait before retry");
            input.NowUtc = start.AddSeconds(4);
            Equal(
                ProximityActionType.WakeToLogin,
                coordinator.Evaluate(input).Action,
                "failed wake should retry without a new departure");
            coordinator.ReportActionResult(
                ProximityActionType.WakeToLogin,
                false,
                input.NowUtc);
            input.NowUtc = start.AddSeconds(6);
            Equal(
                ProximityActionType.WakeToLogin,
                coordinator.Evaluate(input).Action,
                "second bounded retry should run");
            coordinator.ReportActionResult(
                ProximityActionType.WakeToLogin,
                false,
                input.NowUtc);
            input.NowUtc = start.AddSeconds(20);
            Equal(
                ProximityActionType.None,
                coordinator.Evaluate(input).Action,
                "retry limit must stop repeated wake input");
        }

        private static void TestAutoLockRequiresAllDevicesAbsent()
        {
            var coordinator = new ProximityActionCoordinator(
                new ProximityActionOptions
                {
                    AutoLockEnabled = true,
                    AutoLockAbsenceSeconds = 30,
                    AutoLockMinimumIdleSeconds = 30,
                    AutoLockRetrySeconds = 10
                });
            DateTime start = DateTime.UtcNow;
            var input = ActionInput(start, false, false, true);
            input.AutoLockMode = PresenceMode.WatchAndPhone;
            input.WatchPresentForDeparture = true;
            input.PhonePresentForDeparture = true;
            ProximityActionDecision armed = coordinator.Evaluate(input);
            True(armed.AutoLockArmed, "both present should arm auto-lock");

            input.PhonePresentForDeparture = false;
            input.NowUtc = start.AddSeconds(31);
            input.UserIdleSeconds = 31;
            Equal(
                ProximityActionType.None,
                coordinator.Evaluate(input).Action,
                "watch still present must block lock");

            input.WatchPresentForDeparture = false;
            input.LastWatchDepartureSeenUtc = start;
            input.LastPhoneDepartureSeenUtc = start;
            input.NowUtc = start.AddSeconds(31);
            input.UserIdleSeconds = 29;
            Equal(
                ProximityActionType.None,
                coordinator.Evaluate(input).Action,
                "recent user activity must block lock");
            input.UserIdleSeconds = 31;
            Equal(
                ProximityActionType.LockWorkstation,
                coordinator.Evaluate(input).Action,
                "all required devices absent and idle should lock");
            input.NowUtc = start.AddSeconds(35);
            Equal(
                ProximityActionType.None,
                coordinator.Evaluate(input).Action,
                "failed lock attempts must respect retry interval");
        }

        private static void TestDisabledRuntimeActionsNeverExecute()
        {
            string directory = TemporaryDirectory();
            try
            {
                AgentSettings settings = AgentSettings.CreateDefaults();
                settings.Detection = DetectionOptions();
                var source = new FakeBleSource();
                var conditions = new FakeConditionSource
                {
                    Snapshot = Conditions(true, true, true, 0, DateTime.MinValue)
                };
                var executor = new FakeActionExecutor();
                using (var logger = new FileLogger(directory))
                using (var runtime = new AgentRuntime(
                    settings,
                    logger,
                    source,
                    conditions,
                    executor))
                {
                    runtime.Poll();
                    Equal(0, executor.Count, "disabled actions must never reach Win32 executor");
                }
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        private static void TestPausedDetectionClearsActionState()
        {
            var coordinator = new ProximityActionCoordinator(
                new ProximityActionOptions
                {
                    WakeEnabled = true,
                    WakeRearmSeconds = 5,
                    WakeCooldownSeconds = 45
                });
            DateTime start = DateTime.UtcNow;
            ProximityActionInput input = ActionInput(start, true, false, true);
            coordinator.Evaluate(input);
            input.NowUtc = start.AddSeconds(5);
            True(coordinator.Evaluate(input).WakeArmed, "wake should first arm");

            input.DetectionPaused = true;
            input.NowUtc = start.AddSeconds(6);
            Equal(
                "detection-paused",
                coordinator.Evaluate(input).Reason,
                "paused reason");
            input.DetectionPaused = false;
            input.WakePresenceReady = true;
            input.NowUtc = start.AddSeconds(7);
            Equal(
                ProximityActionType.None,
                coordinator.Evaluate(input).Action,
                "resume with a nearby device must not reuse the old arm state");
        }

        private static void TestManualUnlockDoesNotRepeatAutoLock()
        {
            var coordinator = new ProximityActionCoordinator(
                new ProximityActionOptions
                {
                    AutoLockEnabled = true,
                    AutoLockAbsenceSeconds = 10,
                    AutoLockMinimumIdleSeconds = 5,
                    AutoLockRetrySeconds = 10
                });
            DateTime start = DateTime.UtcNow;
            ProximityActionInput input = ActionInput(start, false, false, true);
            input.AutoLockMode = PresenceMode.WatchAndPhone;
            input.WatchPresentForDeparture = true;
            input.PhonePresentForDeparture = true;
            coordinator.Evaluate(input);

            input.WatchPresentForDeparture = false;
            input.PhonePresentForDeparture = false;
            input.LastWatchDepartureSeenUtc = start;
            input.LastPhoneDepartureSeenUtc = start;
            input.UserIdleSeconds = 20;
            input.NowUtc = start.AddSeconds(20);
            Equal(
                ProximityActionType.LockWorkstation,
                coordinator.Evaluate(input).Action,
                "armed departure should lock");

            input.SessionLocked = true;
            input.NowUtc = start.AddSeconds(21);
            coordinator.Evaluate(input);
            input.SessionLocked = false;
            input.UserIdleSeconds = 20;
            input.NowUtc = start.AddSeconds(40);
            ProximityActionDecision afterManualUnlock = coordinator.Evaluate(input);
            Equal(
                ProximityActionType.None,
                afterManualUnlock.Action,
                "manual unlock while devices remain absent must not lock again");
            False(
                afterManualUnlock.AutoLockArmed,
                "manual unlock must require devices to return before rearming");
            Equal(
                "auto-lock-not-armed",
                afterManualUnlock.Reason,
                "manual unlock blocking reason");
        }

        private static void TestAutoUnlockDisabledByDefault()
        {
            AgentSettings settings = AgentSettings.CreateDefaults();
            False(settings.AutoUnlock.Enabled, "automatic unlock must be opt-in");
            Equal(
                "BleProximityWake.UnlockAgent",
                AutoUnlockBrokerProtocol.AgentPipeName,
                "fixed Broker pipe");
        }

        private static void TestArrivalWithoutWakeAction()
        {
            var coordinator = new ProximityActionCoordinator(
                new ProximityActionOptions
                {
                    ArrivalDetectionEnabled = true,
                    WakeEnabled = false,
                    WakeRearmSeconds = 5,
                    WakeCooldownSeconds = 45
                });
            DateTime start = DateTime.UtcNow;
            ProximityActionInput input = ActionInput(start, true, false, true);
            coordinator.Evaluate(input);
            input.NowUtc = start.AddSeconds(5);
            True(coordinator.Evaluate(input).WakeArmed, "arrival should arm");
            input.WakePresenceReady = true;
            input.NowUtc = start.AddSeconds(6);
            ProximityActionDecision arrival = coordinator.Evaluate(input);
            True(arrival.ArrivalConfirmed, "arrival event must be exposed");
            Equal(
                ProximityActionType.None,
                arrival.Action,
                "automatic unlock arrival must not require wake input action");
        }

        private static void TestArrivalAutoUnlockAvoidsWakeInput()
        {
            Equal(
                ProximityActionType.RequestDisplayPower,
                AgentRuntime.ResolveSystemAction(
                    ProximityActionType.WakeToLogin,
                    true,
                    false,
                    true),
                "arrival auto-unlock must replace wake input with display power");
            Equal(
                ProximityActionType.RequestDisplayPower,
                AgentRuntime.ResolveSystemAction(
                    ProximityActionType.None,
                    true,
                    false,
                    true),
                "arrival auto-unlock must still request display power");
            Equal(
                ProximityActionType.WakeToLogin,
                AgentRuntime.ResolveSystemAction(
                    ProximityActionType.WakeToLogin,
                    true,
                    false,
                    false),
                "ordinary wake must remain available without auto-unlock");
            Equal(
                ProximityActionType.LockWorkstation,
                AgentRuntime.ResolveSystemAction(
                    ProximityActionType.LockWorkstation,
                    true,
                    false,
                    true),
                "auto-unlock routing must not replace unrelated system actions");
        }

        private static void TestInteractiveAutoUnlockAvoidsWakeInput()
        {
            Equal(
                ProximityActionType.None,
                AgentRuntime.ResolveSystemAction(
                    ProximityActionType.WakeToLogin,
                    false,
                    true,
                    true),
                "interactive auto-unlock must not inject another wake input");
            Equal(
                ProximityActionType.None,
                AgentRuntime.ResolveSystemAction(
                    ProximityActionType.None,
                    false,
                    true,
                    true),
                "interactive auto-unlock should rely on the user's input");
        }

        private static void TestAutoUnlockAuthorizationPayload()
        {
            Guid requestId = Guid.NewGuid();
            string sid = "S-1-5-21-1000";
            byte[] payload = AutoUnlockBrokerProtocol.BuildAuthorizePayload(
                new AutoUnlockAuthorizationRequest
                {
                    SessionId = 7,
                    AuthorizationTtlMilliseconds = 5000,
                    LockCycleId = 123456789,
                    RequestId = requestId,
                    UserSid = sid
                });
            using (var stream = new MemoryStream(payload, false))
            using (var reader = new BinaryReader(stream))
            {
                Equal(7, reader.ReadInt32(), "payload session");
                Equal((uint)5000, reader.ReadUInt32(), "payload TTL");
                Equal((ulong)123456789, reader.ReadUInt64(), "payload lock cycle");
                Equal(requestId, new Guid(reader.ReadBytes(16)), "payload request ID");
                Equal((uint)sid.Length, reader.ReadUInt32(), "payload SID characters");
                Equal(
                    sid,
                    System.Text.Encoding.Unicode.GetString(
                        reader.ReadBytes(sid.Length * 2)),
                    "payload SID");
                Equal(stream.Length, stream.Position, "payload must have no trailing data");
            }
        }

        private static void TestAutoUnlockNamedPipeExchange()
        {
            string pipeName = "BleProximityWake.Agent.Tests." + Guid.NewGuid().ToString("N");
            Exception serverException = null;
            var serverReady = new ManualResetEventSlim(false);
            var server = new Thread(() =>
            {
                try
                {
                    using (var pipe = new NamedPipeServerStream(
                        pipeName,
                        PipeDirection.InOut,
                        1,
                        PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous))
                    {
                        serverReady.Set();
                        pipe.WaitForConnection();
                        using (var reader = new BinaryReader(
                            pipe,
                            System.Text.Encoding.Unicode,
                            true))
                        using (var writer = new BinaryWriter(
                            pipe,
                            System.Text.Encoding.Unicode,
                            true))
                        {
                            Equal(
                                AutoUnlockBrokerProtocol.Magic,
                                reader.ReadUInt32(),
                                "pipe request magic");
                            Equal(
                                AutoUnlockBrokerProtocol.Version,
                                reader.ReadUInt32(),
                                "pipe request version");
                            Equal(
                                AutoUnlockBrokerProtocol.AuthorizeMessageType,
                                reader.ReadUInt32(),
                                "pipe request type");
                            uint payloadBytes = reader.ReadUInt32();
                            True(payloadBytes > 36, "pipe payload length");
                            Equal(
                                (int)payloadBytes,
                                reader.ReadBytes((int)payloadBytes).Length,
                                "complete pipe payload");

                            writer.Write(AutoUnlockBrokerProtocol.Magic);
                            writer.Write(AutoUnlockBrokerProtocol.Version);
                            writer.Write((uint)AutoUnlockBrokerStatus.Ok);
                            writer.Write((uint)0);
                            writer.Flush();
                        }
                    }
                }
                catch (Exception exception)
                {
                    serverException = exception;
                    serverReady.Set();
                }
            })
            {
                IsBackground = true
            };
            server.Start();
            True(serverReady.Wait(2000), "pipe server start");

            var client = new NamedPipeAutoUnlockBrokerClient(pipeName, 2000);
            AutoUnlockBrokerResult result = client.Authorize(12345, 5000);
            True(server.Join(2000), "pipe server completion");
            if (serverException != null)
            {
                throw new InvalidOperationException(
                    "pipe server failed",
                    serverException);
            }

            Equal(AutoUnlockBrokerStatus.Ok, result.Status, "pipe response status");
            False(result.RequestId == Guid.Empty, "pipe request ID");
        }

        private static void TestAutoUnlockFreshNetworkGate()
        {
            var conditions = new FakeConditionSource
            {
                Snapshot = Conditions(true, true, true, 0, DateTime.MinValue),
                FreshNetwork = new NetworkContextSnapshot
                {
                    Allowed = false,
                    Reason = "fresh-network-denied",
                    ProfileNames = new string[0],
                    Ssids = new string[0]
                }
            };
            var broker = new FakeAutoUnlockBrokerClient(AutoUnlockBrokerStatus.Ok);
            var guarded = new NetworkRevalidatingAutoUnlockBrokerClient(
                broker,
                conditions,
                true);

            AutoUnlockBrokerResult denied = guarded.Authorize(1, 5000);
            Equal(AutoUnlockBrokerStatus.AccessDenied, denied.Status, "fresh network gate");
            Equal(0, broker.Count, "stale allowed snapshot must not reach Broker");
            Equal(1, conditions.NetworkRefreshCount, "authorization must refresh network");

            conditions.FreshNetwork.Allowed = true;
            AutoUnlockBrokerResult accepted = guarded.Authorize(1, 5000);
            Equal(AutoUnlockBrokerStatus.Ok, accepted.Status, "fresh allowed network");
            Equal(1, broker.Count, "fresh allowed network should reach Broker");
            Equal(2, conditions.NetworkRefreshCount, "every authorization attempt must refresh");
        }

        private static void TestAutoUnlockGates()
        {
            var broker = new FakeAutoUnlockBrokerClient(AutoUnlockBrokerStatus.Ok);
            var controller = AutoUnlockControllerForTest(broker);
            DateTime now = DateTime.UtcNow;
            AutoUnlockInput input = UnlockInput(now, true);
            input.NetworkAllowed = false;
            controller.Poll(input);
            Equal(0, broker.Count, "network gate");

            input.NetworkAllowed = true;
            input.AcPowerConnected = false;
            input.NowUtc = now.AddSeconds(1);
            controller.Poll(input);
            Equal(0, broker.Count, "AC power gate");

            input.AcPowerConnected = true;
            input.PresenceReady = false;
            input.NowUtc = now.AddSeconds(2);
            controller.Poll(input);
            Equal(0, broker.Count, "presence gate");
        }

        private static void TestAutoUnlockAcceptedOnce()
        {
            var broker = new FakeAutoUnlockBrokerClient(
                AutoUnlockBrokerStatus.Ok,
                AutoUnlockBrokerStatus.Ok);
            var controller = AutoUnlockControllerForTest(broker);
            DateTime start = DateTime.UtcNow;
            AutoUnlockInput input = UnlockInput(start, true);
            controller.Poll(input);
            Equal(1, broker.Count, "first authorization request");
            input.NowUtc = start.AddMilliseconds(1);
            AutoUnlockRuntimeStatus accepted = controller.Poll(input);
            True(accepted.Attempted, "accepted cycle must be consumed");
            Equal("accepted", accepted.State, "accepted state");

            input.ArrivalConfirmed = true;
            input.NowUtc = start.AddSeconds(1);
            controller.Poll(input);
            Equal(1, broker.Count, "same lock cycle must not submit twice");

            input.SessionLocked = false;
            input.ArrivalConfirmed = false;
            input.NowUtc = start.AddSeconds(2);
            controller.Poll(input);
            input.SessionLocked = true;
            input.ArrivalConfirmed = true;
            input.NowUtc = start.AddSeconds(3);
            controller.Poll(input);
            Equal(2, broker.Count, "new lock cycle may authorize again");
            False(
                broker.LockCycleIds[0] == broker.LockCycleIds[1],
                "lock cycle IDs must differ");
        }

        private static void TestAutoUnlockPermanentRejection()
        {
            var broker = new FakeAutoUnlockBrokerClient(
                AutoUnlockBrokerStatus.AccessDenied);
            var controller = AutoUnlockControllerForTest(broker);
            DateTime start = DateTime.UtcNow;
            AutoUnlockInput input = UnlockInput(start, true);
            controller.Poll(input);
            input.NowUtc = start.AddMilliseconds(1);
            AutoUnlockRuntimeStatus rejected = controller.Poll(input);
            True(rejected.Attempted, "permanent rejection must end the cycle");
            Equal("rejected:AccessDenied", rejected.State, "rejection state");
            input.NowUtc = start.AddSeconds(10);
            controller.Poll(input);
            Equal(1, broker.Count, "permanent rejection must not retry");
        }

        private static void TestAutoUnlockPausePreservesCycle()
        {
            var broker = new FakeAutoUnlockBrokerClient(
                AutoUnlockBrokerStatus.Ok,
                AutoUnlockBrokerStatus.Ok);
            var controller = AutoUnlockControllerForTest(broker);
            DateTime start = DateTime.UtcNow;
            AutoUnlockInput input = UnlockInput(start, true);
            controller.Poll(input);
            input.NowUtc = start.AddMilliseconds(1);
            AutoUnlockRuntimeStatus accepted = controller.Poll(input);
            True(accepted.Attempted, "accepted cycle must be consumed");

            input.DetectionPaused = true;
            input.ArrivalConfirmed = false;
            input.NowUtc = start.AddSeconds(1);
            AutoUnlockRuntimeStatus paused = controller.Poll(input);
            True(paused.Attempted, "pause must preserve consumed cycle");

            input.DetectionPaused = false;
            input.ArrivalConfirmed = true;
            input.NowUtc = start.AddSeconds(2);
            AutoUnlockRuntimeStatus resumed = controller.Poll(input);
            True(resumed.Attempted, "resume must preserve consumed cycle");
            Equal(1, broker.Count, "pause and resume must not authorize twice");
            Equal(accepted.LockCycleId, resumed.LockCycleId, "lock cycle must remain stable");
        }

        private static void TestAutoUnlockTransientRetries()
        {
            var broker = new FakeAutoUnlockBrokerClient(
                AutoUnlockBrokerStatus.ProviderUnavailable,
                AutoUnlockBrokerStatus.InternalError,
                AutoUnlockBrokerStatus.Ok);
            var controller = AutoUnlockControllerForTest(broker);
            DateTime start = DateTime.UtcNow;
            AutoUnlockInput input = UnlockInput(start, true);
            controller.Poll(input);

            input.ArrivalConfirmed = false;
            input.NowUtc = start.AddMilliseconds(1);
            AutoUnlockRuntimeStatus firstRetry = controller.Poll(input);
            Equal(1, firstRetry.RetryCount, "first retry count");
            Equal(1, broker.Count, "first Broker request");

            input.NowUtc = start.AddMilliseconds(300);
            controller.Poll(input);
            Equal(2, broker.Count, "250 ms retry");
            input.NowUtc = start.AddMilliseconds(301);
            AutoUnlockRuntimeStatus secondRetry = controller.Poll(input);
            Equal(2, secondRetry.RetryCount, "second retry count");

            input.NowUtc = start.AddMilliseconds(850);
            controller.Poll(input);
            Equal(3, broker.Count, "500 ms retry");
            input.NowUtc = start.AddMilliseconds(851);
            AutoUnlockRuntimeStatus accepted = controller.Poll(input);
            True(accepted.Attempted, "successful retry must consume cycle");
            Equal("accepted", accepted.State, "retry accepted state");
        }

        private static void TestAutoUnlockErrorRetriesExhausted()
        {
            var broker = new ThrowingAutoUnlockBrokerClient();
            var controller = AutoUnlockControllerForTest(broker);
            DateTime start = DateTime.UtcNow;
            AutoUnlockInput input = UnlockInput(start, true);
            controller.Poll(input);

            input.ArrivalConfirmed = false;
            input.NowUtc = start.AddMilliseconds(1);
            controller.Poll(input);
            input.NowUtc = start.AddMilliseconds(300);
            controller.Poll(input);
            input.NowUtc = start.AddMilliseconds(301);
            controller.Poll(input);
            input.NowUtc = start.AddMilliseconds(850);
            controller.Poll(input);
            input.NowUtc = start.AddMilliseconds(851);
            controller.Poll(input);
            input.NowUtc = start.AddMilliseconds(1900);
            controller.Poll(input);
            input.NowUtc = start.AddMilliseconds(1901);
            AutoUnlockRuntimeStatus exhausted = controller.Poll(input);

            Equal(4, broker.Count, "initial request plus three retries");
            True(exhausted.Attempted, "exhausted errors must consume cycle");
            Equal("retry-exhausted:error", exhausted.State, "exhausted error state");
            True(
                exhausted.Error.Contains("simulated Broker failure"),
                "last communication error retained");

            input.ArrivalConfirmed = true;
            input.NowUtc = start.AddSeconds(10);
            controller.Poll(input);
            Equal(4, broker.Count, "exhausted cycle must not restart");
        }

        private static void TestInteractiveWakeInputSuppression()
        {
            var controller = InteractiveWakeControllerForTest();
            DateTime start = DateTime.UtcNow;
            InteractiveWakeInput input = InteractiveInput(start, 0);
            controller.Poll(input);

            input.NowUtc = start.AddSeconds(1);
            input.UserIdleSeconds = 0.1;
            False(
                controller.Poll(input).RecoveryRequested,
                "lock input must be suppressed");

            input.NowUtc = start.AddSeconds(2.5);
            input.UserIdleSeconds = 2.5;
            controller.Poll(input);
            input.NowUtc = start.AddSeconds(2.7);
            input.UserIdleSeconds = 0.1;
            InteractiveWakeRuntimeStatus detected = controller.Poll(input);
            True(detected.RecoveryRequested, "fresh input edge should trigger recovery");
            True(detected.Pending, "interactive confirmation should be pending");
            Equal("interactive-input", detected.Trigger, "input trigger");

            input.NowUtc = start.AddSeconds(2.9);
            input.PresenceReady = true;
            input.PresenceFresh = true;
            InteractiveWakeRuntimeStatus confirmed = controller.Poll(input);
            True(confirmed.Confirmed, "fresh presence should confirm interactive wake");
            False(confirmed.Pending, "confirmed candidate is no longer pending");
        }

        private static void TestInteractiveWakeResumeDeduplication()
        {
            var controller = InteractiveWakeControllerForTest();
            DateTime start = DateTime.UtcNow;
            InteractiveWakeInput input = InteractiveInput(start, 10);
            controller.Poll(input);

            input.NowUtc = start.AddSeconds(1);
            input.ResumeSequence = 1;
            input.DisplaySequence = 1;
            input.DisplayState = DisplayPowerState.On;
            input.DisplayWasOffSinceLock = true;
            InteractiveWakeRuntimeStatus detected = controller.Poll(input);
            True(detected.RecoveryRequested, "resume should request one recovery");
            False(detected.Pending, "resume alone must not establish an unlock candidate");
            Equal(string.Empty, detected.Trigger, "resume alone has no unlock trigger");

            input.NowUtc = start.AddSeconds(1.1);
            input.DisplaySequence = 2;
            InteractiveWakeRuntimeStatus duplicate = controller.Poll(input);
            False(duplicate.RecoveryRequested, "display edge must reuse prepared recovery");
            False(duplicate.Pending, "display-on alone must not establish a candidate");

            input.NowUtc = start.AddSeconds(2.2);
            input.UserIdleSeconds = 0.1;
            InteractiveWakeRuntimeStatus inputDetected = controller.Poll(input);
            False(
                inputDetected.RecoveryRequested,
                "input after resume must not restart the prepared BLE recovery");
            True(inputDetected.Pending, "new input establishes the unlock candidate");
            Equal("interactive-input", inputDetected.Trigger, "input remains the only trigger");
        }

        private static void TestInteractiveWakeTimeoutAndRearm()
        {
            var controller = InteractiveWakeControllerForTest();
            DateTime start = DateTime.UtcNow;
            InteractiveWakeInput input = InteractiveInput(start, 10);
            controller.Poll(input);
            input.NowUtc = start.AddSeconds(2.1);
            input.UserIdleSeconds = 0.1;
            True(controller.Poll(input).RecoveryRequested, "first input trigger");

            input.NowUtc = start.AddSeconds(8.2);
            input.UserIdleSeconds = 6.2;
            InteractiveWakeRuntimeStatus timedOut = controller.Poll(input);
            Equal("timeout:interactive-input", timedOut.State, "confirmation timeout");

            input.NowUtc = start.AddSeconds(9);
            input.UserIdleSeconds = 7;
            controller.Poll(input);
            input.NowUtc = start.AddSeconds(9.1);
            input.UserIdleSeconds = 0.1;
            InteractiveWakeRuntimeStatus rearmed = controller.Poll(input);
            False(
                rearmed.RecoveryRequested,
                "new input after timeout must reuse the prepared recovery");
            True(rearmed.Pending, "new input edge may rearm after timeout");
        }

        private static void TestInteractiveWakeAuthorizesOnce()
        {
            var broker = new FakeAutoUnlockBrokerClient(
                AutoUnlockBrokerStatus.Ok,
                AutoUnlockBrokerStatus.Ok);
            var controller = AutoUnlockControllerForTest(broker);
            DateTime start = DateTime.UtcNow;
            AutoUnlockInput input = UnlockInput(start, false);
            input.InteractiveWakeConfirmed = true;
            input.InteractiveWakeTrigger = "interactive-input";
            controller.Poll(input);
            Equal(1, broker.Count, "interactive authorization request");

            input.NowUtc = start.AddMilliseconds(1);
            input.InteractiveWakeConfirmed = false;
            AutoUnlockRuntimeStatus accepted = controller.Poll(input);
            True(accepted.Attempted, "interactive cycle must be consumed");
            Equal("accepted", accepted.State, "interactive accepted state");

            input.NowUtc = start.AddSeconds(1);
            input.InteractiveWakeConfirmed = true;
            controller.Poll(input);
            Equal(1, broker.Count, "interactive trigger must not repeat in cycle");
        }

        private static void TestInteractiveWakeAuthorizationPending()
        {
            var controller = InteractiveWakeControllerForTest();
            DateTime start = DateTime.UtcNow;
            InteractiveWakeInput input = InteractiveInput(start, 10);
            controller.Poll(input);
            input.NowUtc = start.AddSeconds(2.1);
            input.UserIdleSeconds = 0.1;
            True(controller.Poll(input).RecoveryRequested, "first input trigger");

            input.NowUtc = start.AddSeconds(3);
            input.UserIdleSeconds = 2;
            input.AuthorizationPending = true;
            controller.Poll(input);
            input.NowUtc = start.AddSeconds(3.1);
            input.UserIdleSeconds = 0.1;
            InteractiveWakeRuntimeStatus suppressed = controller.Poll(input);
            False(
                suppressed.RecoveryRequested,
                "input during Broker request must not restart BLE");
            Equal(
                "authorization-requesting",
                suppressed.State,
                "authorization pending state");
        }

        private static InteractiveWakeController InteractiveWakeControllerForTest()
        {
            return new InteractiveWakeController(
                new AutoUnlockSettings
                {
                    Enabled = true,
                    TriggerOnArrival = true,
                    TriggerOnInteractiveWake = true,
                    RequireAllowedNetwork = true,
                    RequireAcPower = true,
                    InteractiveWakeMinimumPriorIdleMilliseconds = 1000,
                    InteractiveWakeInputFreshMilliseconds = 2000,
                    InteractiveWakeMaximumPresenceAgeMilliseconds = 5000,
                    InteractiveWakeConfirmationMilliseconds = 6000,
                    InteractiveWakeAllowIdleFallback = true
                });
        }

        private static InteractiveWakeInput InteractiveInput(
            DateTime nowUtc,
            double idleSeconds)
        {
            return new InteractiveWakeInput
            {
                NowUtc = nowUtc,
                SessionKnown = true,
                SessionLocked = true,
                NetworkAllowed = true,
                AcPowerConnected = true,
                UserIdleSeconds = idleSeconds,
                DisplayState = DisplayPowerState.Off
            };
        }

        private static AutoUnlockController AutoUnlockControllerForTest(
            IAutoUnlockBrokerClient broker)
        {
            return new AutoUnlockController(
                new AutoUnlockSettings
                {
                    Enabled = true,
                    RequireAllowedNetwork = true,
                    RequireAcPower = true,
                    TriggerOnArrival = true
                },
                broker,
                new ImmediateAutoUnlockRequestRunner());
        }

        private static AutoUnlockInput UnlockInput(DateTime nowUtc, bool arrival)
        {
            return new AutoUnlockInput
            {
                NowUtc = nowUtc,
                SessionKnown = true,
                SessionLocked = true,
                NetworkAllowed = true,
                AcPowerConnected = true,
                PresenceReady = true,
                ArrivalConfirmed = arrival
            };
        }

        private static ProximityActionInput ActionInput(
            DateTime nowUtc,
            bool locked,
            bool wakeReady,
            bool networkAllowed)
        {
            return new ProximityActionInput
            {
                NowUtc = nowUtc,
                SessionKnown = true,
                SessionLocked = locked,
                NetworkAllowed = networkAllowed,
                WakePresenceReady = wakeReady,
                AutoLockMode = PresenceMode.PhoneOnly
            };
        }

        private static string TemporaryDirectory()
        {
            string directory = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                "BleProximityWake.Agent.Tests",
                Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            return directory;
        }

        private sealed class FakeConditionSource : IRuntimeConditionSource
        {
            internal RuntimeConditionSnapshot Snapshot { get; set; }

            internal int DelayMilliseconds { get; set; }

            internal int NetworkRefreshCount { get; private set; }

            internal NetworkContextSnapshot FreshNetwork { get; set; }

            public RuntimeConditionSnapshot Capture()
            {
                if (DelayMilliseconds > 0)
                {
                    Thread.Sleep(DelayMilliseconds);
                }

                return Snapshot;
            }

            public NetworkContextSnapshot RefreshNetwork()
            {
                NetworkRefreshCount++;
                return FreshNetwork ?? Snapshot.Network;
            }

            public void Dispose()
            {
            }
        }

        private sealed class FakeBleSource : IBleAdvertisementSource
        {
            private readonly Queue<BleAdvertisement> records = new Queue<BleAdvertisement>();
            private bool started;

            public string Status => started ? "Started" : "Created";

            public BleScanMode Mode { get; private set; } = BleScanMode.Passive;

            public int QueueCount => records.Count;

            public int DroppedQueueRecords => 0;

            public int RestartCount { get; private set; }

            public int ForcedRecoveryCount => 0;

            public string LastStopError => string.Empty;

            internal int ClearCount { get; private set; }

            internal void Enqueue(BleAdvertisement advertisement)
            {
                records.Enqueue(advertisement);
            }

            public bool EnsureStarted(BleScanMode mode)
            {
                bool changed = !started || mode != Mode;
                Mode = mode;
                started = true;
                if (changed)
                {
                    RestartCount++;
                }

                return changed;
            }

            public bool Restart(BleScanMode mode)
            {
                Mode = mode;
                started = true;
                RestartCount++;
                return true;
            }

            public BleAdvertisement[] Drain(int maximumRecords)
            {
                var result = new List<BleAdvertisement>();
                while (result.Count < maximumRecords && records.Count > 0)
                {
                    result.Add(records.Dequeue());
                }

                return result.ToArray();
            }

            public int Clear()
            {
                int count = records.Count;
                records.Clear();
                ClearCount += count;
                return count;
            }

            public void Dispose()
            {
                records.Clear();
            }
        }

        private sealed class FakeActionExecutor : ISystemActionExecutor
        {
            internal int Count { get; private set; }

            public SystemActionResult Execute(ProximityActionType action)
            {
                Count++;
                return new SystemActionResult
                {
                    Succeeded = true,
                    Detail = "fake"
                };
            }
        }

        private sealed class FakeAutoUnlockBrokerClient : IAutoUnlockBrokerClient
        {
            private readonly Queue<AutoUnlockBrokerStatus> statuses =
                new Queue<AutoUnlockBrokerStatus>();

            internal FakeAutoUnlockBrokerClient(params AutoUnlockBrokerStatus[] values)
            {
                foreach (AutoUnlockBrokerStatus value in values)
                {
                    statuses.Enqueue(value);
                }
            }

            internal int Count { get; private set; }

            internal List<ulong> LockCycleIds { get; } = new List<ulong>();

            public AutoUnlockBrokerResult Authorize(
                ulong lockCycleId,
                int authorizationTtlMilliseconds)
            {
                Count++;
                LockCycleIds.Add(lockCycleId);
                return new AutoUnlockBrokerResult
                {
                    Status = statuses.Count == 0
                        ? AutoUnlockBrokerStatus.Ok
                        : statuses.Dequeue(),
                    RequestId = Guid.NewGuid()
                };
            }
        }

        private sealed class ImmediateAutoUnlockRequestRunner :
            IAutoUnlockRequestRunner
        {
            private AutoUnlockBrokerResult result;
            private Exception exception;
            private bool completed;

            public bool IsRunning => false;

            public void Start(Func<AutoUnlockBrokerResult> request)
            {
                try
                {
                    result = request();
                }
                catch (Exception caught)
                {
                    exception = caught;
                }

                completed = true;
            }

            public bool TryTakeCompleted(
                out AutoUnlockBrokerResult completedResult,
                out Exception completedException)
            {
                completedResult = null;
                completedException = null;
                if (!completed)
                {
                    return false;
                }

                completedResult = result;
                completedException = exception;
                result = null;
                exception = null;
                completed = false;
                return true;
            }
        }

        private sealed class ControlledAutoUnlockRequestRunner :
            IAutoUnlockRequestRunner
        {
            private AutoUnlockBrokerResult result;
            private Exception exception;
            private bool completed;
            private bool running;

            public bool IsRunning => running;

            public void Start(Func<AutoUnlockBrokerResult> request)
            {
                running = true;
                try
                {
                    result = request();
                }
                catch (Exception caught)
                {
                    exception = caught;
                }
            }

            internal void Complete()
            {
                completed = true;
                running = false;
            }

            public bool TryTakeCompleted(
                out AutoUnlockBrokerResult completedResult,
                out Exception completedException)
            {
                completedResult = null;
                completedException = null;
                if (!completed)
                {
                    return false;
                }

                completedResult = result;
                completedException = exception;
                result = null;
                exception = null;
                completed = false;
                return true;
            }
        }

        private sealed class ThrowingAutoUnlockBrokerClient :
            IAutoUnlockBrokerClient
        {
            internal int Count { get; private set; }

            public AutoUnlockBrokerResult Authorize(
                ulong lockCycleId,
                int authorizationTtlMilliseconds)
            {
                Count++;
                throw new InvalidOperationException("simulated Broker failure");
            }
        }

        private static void TestInvalidMode()
        {
            string directory = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                "BleProximityWake.Agent.Tests",
                Guid.NewGuid().ToString("N"));
            string path = System.IO.Path.Combine(directory, "agent-settings.json");

            try
            {
                Directory.CreateDirectory(directory);
                File.WriteAllText(
                    path,
                    "{\"schemaVersion\":1,\"presencePolicies\":{\"autoUnlock\":{\"mode\":\"AnyDevice\"}}}");
                var store = new AgentSettingsStore(path);
                Throws<InvalidOperationException>(() => store.Load(), "unsupported mode");
            }
            finally
            {
                if (Directory.Exists(directory))
                {
                    Directory.Delete(directory, true);
                }
            }
        }

        private static void Run(string name, Action test)
        {
            try
            {
                test();
                Console.WriteLine("[PASS] " + name);
            }
            catch (Exception exception)
            {
                failures++;
                Console.Error.WriteLine("[FAIL] " + name + ": " + exception.Message);
            }
        }

        private static void True(bool condition, string message)
        {
            if (!condition)
            {
                throw new InvalidOperationException(message);
            }
        }

        private static void False(bool condition, string message)
        {
            True(!condition, message);
        }

        private static void Equal<T>(T expected, T actual, string message)
        {
            if (!object.Equals(expected, actual))
            {
                throw new InvalidOperationException(
                    message + "; expected=" + expected + "; actual=" + actual);
            }
        }

        private static void Throws<T>(Action action, string message)
            where T : Exception
        {
            try
            {
                action();
            }
            catch (T)
            {
                return;
            }

            throw new InvalidOperationException(message);
        }
    }
}
