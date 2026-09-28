using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Web.Script.Serialization;
using BleProximityWake.Core.Bluetooth;
using BleProximityWake.Core.Presence;

namespace BleProximityWake.Agent.Configuration
{
    internal sealed class AgentSettingsStore
    {
        private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();

        internal AgentSettingsStore(string path)
        {
            Path = path ?? throw new ArgumentNullException("path");
        }

        internal string Path { get; }

        internal AgentSettings Load()
        {
            if (!File.Exists(Path))
            {
                AgentSettings defaults = AgentSettings.CreateDefaults();
                Save(defaults);
                return defaults;
            }

            string json = File.ReadAllText(Path);
            object rootObject = serializer.DeserializeObject(json);
            IDictionary<string, object> root = AsDictionary(rootObject, "settings root");
            AgentSettings settings = AgentSettings.CreateDefaults();
            settings.SchemaVersion = ReadInt(root, "schemaVersion", AgentSettings.CurrentSchemaVersion);

            if (root.TryGetValue("presencePolicies", out object policiesObject))
            {
                IDictionary<string, object> policies = AsDictionary(policiesObject, "presencePolicies");
                settings.PresencePolicies.Wake = ReadPolicy(policies, "wake", settings.PresencePolicies.Wake);
                settings.PresencePolicies.AutoUnlock = ReadPolicy(policies, "autoUnlock", settings.PresencePolicies.AutoUnlock);
                settings.PresencePolicies.AutoLock = ReadPolicy(policies, "autoLock", settings.PresencePolicies.AutoLock);
            }

            if (root.TryGetValue("ble", out object bleObject))
            {
                settings.Ble = ReadBleSettings(AsDictionary(bleObject, "ble"), settings.Ble);
            }

            if (root.TryGetValue("detection", out object detectionObject))
            {
                settings.Detection = ReadDetectionSettings(
                    AsDictionary(detectionObject, "detection"),
                    settings.Detection);
            }

            if (root.TryGetValue("network", out object networkObject))
            {
                settings.Network = ReadNetworkSettings(
                    AsDictionary(networkObject, "network"),
                    settings.Network);
            }

            if (root.TryGetValue("actions", out object actionsObject))
            {
                settings.Actions = ReadActionSettings(
                    AsDictionary(actionsObject, "actions"),
                    settings.Actions);
            }

            if (root.TryGetValue("autoUnlock", out object autoUnlockObject))
            {
                settings.AutoUnlock = ReadAutoUnlockSettings(
                    AsDictionary(autoUnlockObject, "autoUnlock"),
                    settings.AutoUnlock);
            }

            settings.Validate();
            return settings;
        }

        internal void Save(AgentSettings settings)
        {
            if (settings == null)
            {
                throw new ArgumentNullException("settings");
            }

            settings.Validate();
            string directory = System.IO.Path.GetDirectoryName(Path);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var root = new Dictionary<string, object>
            {
                ["schemaVersion"] = AgentSettings.CurrentSchemaVersion,
                ["presencePolicies"] = new Dictionary<string, object>
                {
                    ["wake"] = WritePolicy(settings.PresencePolicies.Wake),
                    ["autoUnlock"] = WritePolicy(settings.PresencePolicies.AutoUnlock),
                    ["autoLock"] = WritePolicy(settings.PresencePolicies.AutoLock)
                },
                ["ble"] = WriteBleSettings(settings.Ble),
                ["detection"] = WriteDetectionSettings(settings.Detection),
                ["network"] = WriteNetworkSettings(settings.Network),
                ["actions"] = WriteActionSettings(settings.Actions),
                ["autoUnlock"] = WriteAutoUnlockSettings(settings.AutoUnlock)
            };

            string temporaryPath = Path + ".tmp";
            File.WriteAllText(temporaryPath, serializer.Serialize(root));
            if (File.Exists(Path))
            {
                File.Replace(temporaryPath, Path, null);
            }
            else
            {
                File.Move(temporaryPath, Path);
            }
        }

        private static PresencePolicy ReadPolicy(
            IDictionary<string, object> policies,
            string name,
            PresencePolicy fallback)
        {
            if (!policies.TryGetValue(name, out object policyObject))
            {
                return fallback;
            }

            IDictionary<string, object> policy = AsDictionary(policyObject, name);
            string modeText = ReadString(policy, "mode", fallback.Mode.ToString());
            if (!Enum.TryParse(modeText, true, out PresenceMode mode) ||
                !Enum.IsDefined(typeof(PresenceMode), mode))
            {
                throw new InvalidOperationException(name + " contains an unsupported presence mode: " + modeText);
            }

            return new PresencePolicy
            {
                Mode = mode,
                RequireFreshAfterResume = ReadBool(
                    policy,
                    "requireFreshAfterResume",
                    fallback.RequireFreshAfterResume)
            };
        }

        private static IDictionary<string, object> WritePolicy(PresencePolicy policy)
        {
            return new Dictionary<string, object>
            {
                ["mode"] = policy.Mode.ToString(),
                ["requireFreshAfterResume"] = policy.RequireFreshAfterResume
            };
        }

        private static BleRuntimeSettings ReadBleSettings(
            IDictionary<string, object> values,
            BleRuntimeSettings fallback)
        {
            return new BleRuntimeSettings
            {
                Enabled = ReadBool(values, "enabled", fallback.Enabled),
                ManufacturerCompanyId = ReadInt(
                    values,
                    "manufacturerCompanyId",
                    fallback.ManufacturerCompanyId),
                SamplingIntervalMilliseconds = ReadInt(
                    values,
                    "samplingIntervalMilliseconds",
                    fallback.SamplingIntervalMilliseconds),
                LockedPollIntervalMilliseconds = ReadInt(
                    values,
                    "lockedPollIntervalMilliseconds",
                    fallback.LockedPollIntervalMilliseconds),
                BackgroundPollIntervalMilliseconds = ReadInt(
                    values,
                    "backgroundPollIntervalMilliseconds",
                    fallback.BackgroundPollIntervalMilliseconds),
                HeartbeatSeconds = ReadInt(
                    values,
                    "heartbeatSeconds",
                    fallback.HeartbeatSeconds)
            };
        }

        private static IDictionary<string, object> WriteBleSettings(BleRuntimeSettings settings)
        {
            return new Dictionary<string, object>
            {
                ["enabled"] = settings.Enabled,
                ["manufacturerCompanyId"] = settings.ManufacturerCompanyId,
                ["samplingIntervalMilliseconds"] = settings.SamplingIntervalMilliseconds,
                ["lockedPollIntervalMilliseconds"] = settings.LockedPollIntervalMilliseconds,
                ["backgroundPollIntervalMilliseconds"] = settings.BackgroundPollIntervalMilliseconds,
                ["heartbeatSeconds"] = settings.HeartbeatSeconds
            };
        }

        private static PresenceDetectionOptions ReadDetectionSettings(
            IDictionary<string, object> values,
            PresenceDetectionOptions fallback)
        {
            var result = new PresenceDetectionOptions
            {
                WatchMatcher = fallback.WatchMatcher,
                WatchRssiThreshold = ReadInt(
                    values,
                    "watchRssiThreshold",
                    fallback.WatchRssiThreshold),
                LearnedWatchRssiThreshold = ReadInt(
                    values,
                    "learnedWatchRssiThreshold",
                    fallback.LearnedWatchRssiThreshold),
                WatchHitCount = ReadInt(values, "watchHitCount", fallback.WatchHitCount),
                WatchHitWindowSeconds = ReadInt(
                    values,
                    "watchHitWindowSeconds",
                    fallback.WatchHitWindowSeconds),
                WakeWatchPresenceSeconds = ReadInt(
                    values,
                    "wakeWatchPresenceSeconds",
                    fallback.WakeWatchPresenceSeconds),
                WatchLostSeconds = ReadInt(
                    values,
                    "watchLostSeconds",
                    fallback.WatchLostSeconds),
                AddressLearningWindowSeconds = ReadInt(
                    values,
                    "addressLearningWindowSeconds",
                    fallback.AddressLearningWindowSeconds),
                AddressLearningMinimumHits = ReadInt(
                    values,
                    "addressLearningMinimumHits",
                    fallback.AddressLearningMinimumHits),
                PhoneEnabled = ReadBool(values, "phoneEnabled", fallback.PhoneEnabled),
                PhoneMatcher = fallback.PhoneMatcher,
                PhoneRssiThreshold = ReadInt(
                    values,
                    "phoneRssiThreshold",
                    fallback.PhoneRssiThreshold),
                PhoneStrongRssiSingleHitThreshold = ReadInt(
                    values,
                    "phoneStrongRssiSingleHitThreshold",
                    fallback.PhoneStrongRssiSingleHitThreshold),
                PhoneHitCount = ReadInt(values, "phoneHitCount", fallback.PhoneHitCount),
                PhoneHitWindowSeconds = ReadInt(
                    values,
                    "phoneHitWindowSeconds",
                    fallback.PhoneHitWindowSeconds),
                PhonePresenceTimeoutSeconds = ReadInt(
                    values,
                    "phonePresenceTimeoutSeconds",
                    fallback.PhonePresenceTimeoutSeconds),
                MaximumAdvertisementAgeSeconds = ReadInt(
                    values,
                    "maximumAdvertisementAgeSeconds",
                    fallback.MaximumAdvertisementAgeSeconds)
            };

            if (values.TryGetValue("watchMatcher", out object watchMatcher))
            {
                result.WatchMatcher = ReadMatcher(
                    AsDictionary(watchMatcher, "watchMatcher"),
                    fallback.WatchMatcher);
            }

            if (values.TryGetValue("phoneMatcher", out object phoneMatcher))
            {
                result.PhoneMatcher = ReadMatcher(
                    AsDictionary(phoneMatcher, "phoneMatcher"),
                    fallback.PhoneMatcher);
            }

            return result;
        }

        private static IDictionary<string, object> WriteDetectionSettings(
            PresenceDetectionOptions settings)
        {
            return new Dictionary<string, object>
            {
                ["watchMatcher"] = WriteMatcher(settings.WatchMatcher),
                ["watchRssiThreshold"] = settings.WatchRssiThreshold,
                ["learnedWatchRssiThreshold"] = settings.LearnedWatchRssiThreshold,
                ["watchHitCount"] = settings.WatchHitCount,
                ["watchHitWindowSeconds"] = settings.WatchHitWindowSeconds,
                ["wakeWatchPresenceSeconds"] = settings.WakeWatchPresenceSeconds,
                ["watchLostSeconds"] = settings.WatchLostSeconds,
                ["addressLearningWindowSeconds"] = settings.AddressLearningWindowSeconds,
                ["addressLearningMinimumHits"] = settings.AddressLearningMinimumHits,
                ["phoneEnabled"] = settings.PhoneEnabled,
                ["phoneMatcher"] = WriteMatcher(settings.PhoneMatcher),
                ["phoneRssiThreshold"] = settings.PhoneRssiThreshold,
                ["phoneStrongRssiSingleHitThreshold"] =
                    settings.PhoneStrongRssiSingleHitThreshold,
                ["phoneHitCount"] = settings.PhoneHitCount,
                ["phoneHitWindowSeconds"] = settings.PhoneHitWindowSeconds,
                ["phonePresenceTimeoutSeconds"] = settings.PhonePresenceTimeoutSeconds,
                ["maximumAdvertisementAgeSeconds"] = settings.MaximumAdvertisementAgeSeconds
            };
        }

        private static DeviceMatcherOptions ReadMatcher(
            IDictionary<string, object> values,
            DeviceMatcherOptions fallback)
        {
            return new DeviceMatcherOptions
            {
                Address = ReadString(values, "address", fallback.Address),
                NameContains = ReadString(values, "nameContains", fallback.NameContains),
                ServiceUuid = ReadString(values, "serviceUuid", fallback.ServiceUuid),
                ManufacturerDataHexPrefix = ReadString(
                    values,
                    "manufacturerDataHexPrefix",
                    fallback.ManufacturerDataHexPrefix),
                ManufacturerDataHexPattern = ReadString(
                    values,
                    "manufacturerDataHexPattern",
                    fallback.ManufacturerDataHexPattern)
            };
        }

        private static IDictionary<string, object> WriteMatcher(DeviceMatcherOptions matcher)
        {
            return new Dictionary<string, object>
            {
                ["address"] = matcher.Address,
                ["nameContains"] = matcher.NameContains,
                ["serviceUuid"] = matcher.ServiceUuid,
                ["manufacturerDataHexPrefix"] = matcher.ManufacturerDataHexPrefix,
                ["manufacturerDataHexPattern"] = matcher.ManufacturerDataHexPattern
            };
        }

        private static NetworkSettings ReadNetworkSettings(
            IDictionary<string, object> values,
            NetworkSettings fallback)
        {
            return new NetworkSettings
            {
                Enabled = ReadBool(values, "enabled", fallback.Enabled),
                AllowedProfileNames = ReadStringArray(
                    values,
                    "allowedProfileNames",
                    fallback.AllowedProfileNames),
                AllowedSsids = ReadStringArray(
                    values,
                    "allowedSsids",
                    fallback.AllowedSsids)
            };
        }

        private static IDictionary<string, object> WriteNetworkSettings(NetworkSettings settings)
        {
            return new Dictionary<string, object>
            {
                ["enabled"] = settings.Enabled,
                ["allowedProfileNames"] = settings.AllowedProfileNames,
                ["allowedSsids"] = settings.AllowedSsids
            };
        }

        private static SystemActionSettings ReadActionSettings(
            IDictionary<string, object> values,
            SystemActionSettings fallback)
        {
            var result = new SystemActionSettings
            {
                Wake = fallback.Wake,
                AutoLock = fallback.AutoLock
            };
            if (values.TryGetValue("wake", out object wakeObject))
            {
                IDictionary<string, object> wake = AsDictionary(wakeObject, "actions.wake");
                result.Wake = new WakeActionSettings
                {
                    Enabled = ReadBool(wake, "enabled", fallback.Wake.Enabled),
                    CooldownSeconds = ReadInt(
                        wake,
                        "cooldownSeconds",
                        fallback.Wake.CooldownSeconds),
                    RearmSeconds = ReadInt(
                        wake,
                        "rearmSeconds",
                        fallback.Wake.RearmSeconds),
                    SendMonitorPowerMessage = ReadBool(
                        wake,
                        "sendMonitorPowerMessage",
                        fallback.Wake.SendMonitorPowerMessage),
                    SendMouseNudge = ReadBool(
                        wake,
                        "sendMouseNudge",
                        fallback.Wake.SendMouseNudge),
                    SendSpaceKey = ReadBool(
                        wake,
                        "sendSpaceKey",
                        fallback.Wake.SendSpaceKey)
                };
            }

            if (values.TryGetValue("autoLock", out object autoLockObject))
            {
                IDictionary<string, object> autoLock =
                    AsDictionary(autoLockObject, "actions.autoLock");
                result.AutoLock = new AutoLockActionSettings
                {
                    Enabled = ReadBool(
                        autoLock,
                        "enabled",
                        fallback.AutoLock.Enabled),
                    AbsenceSeconds = ReadInt(
                        autoLock,
                        "absenceSeconds",
                        fallback.AutoLock.AbsenceSeconds),
                    MinimumUserIdleSeconds = ReadInt(
                        autoLock,
                        "minimumUserIdleSeconds",
                        fallback.AutoLock.MinimumUserIdleSeconds),
                    RetrySeconds = ReadInt(
                        autoLock,
                        "retrySeconds",
                        fallback.AutoLock.RetrySeconds)
                };
            }

            return result;
        }

        private static IDictionary<string, object> WriteActionSettings(
            SystemActionSettings settings)
        {
            return new Dictionary<string, object>
            {
                ["wake"] = new Dictionary<string, object>
                {
                    ["enabled"] = settings.Wake.Enabled,
                    ["cooldownSeconds"] = settings.Wake.CooldownSeconds,
                    ["rearmSeconds"] = settings.Wake.RearmSeconds,
                    ["sendMonitorPowerMessage"] = settings.Wake.SendMonitorPowerMessage,
                    ["sendMouseNudge"] = settings.Wake.SendMouseNudge,
                    ["sendSpaceKey"] = settings.Wake.SendSpaceKey
                },
                ["autoLock"] = new Dictionary<string, object>
                {
                    ["enabled"] = settings.AutoLock.Enabled,
                    ["absenceSeconds"] = settings.AutoLock.AbsenceSeconds,
                    ["minimumUserIdleSeconds"] =
                        settings.AutoLock.MinimumUserIdleSeconds,
                    ["retrySeconds"] = settings.AutoLock.RetrySeconds
                }
            };
        }

        private static AutoUnlockSettings ReadAutoUnlockSettings(
            IDictionary<string, object> values,
            AutoUnlockSettings fallback)
        {
            return new AutoUnlockSettings
            {
                Enabled = ReadBool(values, "enabled", fallback.Enabled),
                AuthorizationTtlMilliseconds = ReadInt(
                    values,
                    "authorizationTtlMilliseconds",
                    fallback.AuthorizationTtlMilliseconds),
                ResponseTimeoutMilliseconds = ReadInt(
                    values,
                    "responseTimeoutMilliseconds",
                    fallback.ResponseTimeoutMilliseconds),
                RequireAllowedNetwork = ReadBool(
                    values,
                    "requireAllowedNetwork",
                    fallback.RequireAllowedNetwork),
                RequireAcPower = ReadBool(
                    values,
                    "requireAcPower",
                    fallback.RequireAcPower),
                TriggerOnArrival = ReadBool(
                    values,
                    "triggerOnArrival",
                    fallback.TriggerOnArrival),
                TriggerOnInteractiveWake = ReadBool(
                    values,
                    "triggerOnInteractiveWake",
                    fallback.TriggerOnInteractiveWake),
                InteractiveWakeMinimumPriorIdleMilliseconds = ReadInt(
                    values,
                    "interactiveWakeMinimumPriorIdleMilliseconds",
                    fallback.InteractiveWakeMinimumPriorIdleMilliseconds),
                InteractiveWakeInputFreshMilliseconds = ReadInt(
                    values,
                    "interactiveWakeInputFreshMilliseconds",
                    fallback.InteractiveWakeInputFreshMilliseconds),
                InteractiveWakeMaximumPresenceAgeMilliseconds = ReadInt(
                    values,
                    "interactiveWakeMaximumPresenceAgeMilliseconds",
                    fallback.InteractiveWakeMaximumPresenceAgeMilliseconds),
                InteractiveWakeConfirmationMilliseconds = ReadInt(
                    values,
                    "interactiveWakeConfirmationMilliseconds",
                    fallback.InteractiveWakeConfirmationMilliseconds),
                InteractiveWakeAllowIdleFallback = ReadBool(
                    values,
                    "interactiveWakeAllowIdleFallback",
                    fallback.InteractiveWakeAllowIdleFallback)
            };
        }

        private static IDictionary<string, object> WriteAutoUnlockSettings(
            AutoUnlockSettings settings)
        {
            return new Dictionary<string, object>
            {
                ["enabled"] = settings.Enabled,
                ["authorizationTtlMilliseconds"] =
                    settings.AuthorizationTtlMilliseconds,
                ["responseTimeoutMilliseconds"] =
                    settings.ResponseTimeoutMilliseconds,
                ["requireAllowedNetwork"] = settings.RequireAllowedNetwork,
                ["requireAcPower"] = settings.RequireAcPower,
                ["triggerOnArrival"] = settings.TriggerOnArrival,
                ["triggerOnInteractiveWake"] = settings.TriggerOnInteractiveWake,
                ["interactiveWakeMinimumPriorIdleMilliseconds"] =
                    settings.InteractiveWakeMinimumPriorIdleMilliseconds,
                ["interactiveWakeInputFreshMilliseconds"] =
                    settings.InteractiveWakeInputFreshMilliseconds,
                ["interactiveWakeMaximumPresenceAgeMilliseconds"] =
                    settings.InteractiveWakeMaximumPresenceAgeMilliseconds,
                ["interactiveWakeConfirmationMilliseconds"] =
                    settings.InteractiveWakeConfirmationMilliseconds,
                ["interactiveWakeAllowIdleFallback"] =
                    settings.InteractiveWakeAllowIdleFallback
            };
        }

        private static IDictionary<string, object> AsDictionary(object value, string name)
        {
            if (value is IDictionary<string, object> dictionary)
            {
                return dictionary;
            }

            throw new InvalidOperationException(name + " must be a JSON object.");
        }

        private static int ReadInt(IDictionary<string, object> values, string name, int fallback)
        {
            if (!values.TryGetValue(name, out object value) || value == null)
            {
                return fallback;
            }

            return Convert.ToInt32(value, CultureInfo.InvariantCulture);
        }

        private static string ReadString(
            IDictionary<string, object> values,
            string name,
            string fallback)
        {
            if (!values.TryGetValue(name, out object value) || value == null)
            {
                return fallback;
            }

            return Convert.ToString(value, CultureInfo.InvariantCulture);
        }

        private static bool ReadBool(
            IDictionary<string, object> values,
            string name,
            bool fallback)
        {
            if (!values.TryGetValue(name, out object value) || value == null)
            {
                return fallback;
            }

            return Convert.ToBoolean(value, CultureInfo.InvariantCulture);
        }

        private static string[] ReadStringArray(
            IDictionary<string, object> values,
            string name,
            string[] fallback)
        {
            if (!values.TryGetValue(name, out object value) || value == null)
            {
                return fallback;
            }

            if (!(value is object[] items))
            {
                throw new InvalidOperationException(name + " must be a JSON array.");
            }

            var result = new string[items.Length];
            for (int index = 0; index < items.Length; index++)
            {
                result[index] = Convert.ToString(items[index], CultureInfo.InvariantCulture);
            }

            return result;
        }
    }
}
