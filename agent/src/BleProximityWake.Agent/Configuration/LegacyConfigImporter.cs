using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Web.Script.Serialization;
using BleProximityWake.Core.Bluetooth;
using BleProximityWake.Core.Presence;

namespace BleProximityWake.Agent.Configuration
{
    internal static class LegacyConfigImporter
    {
        internal static AgentSettings Import(string path, AgentSettings settings)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                throw new ArgumentNullException("path");
            }

            if (settings == null)
            {
                throw new ArgumentNullException("settings");
            }

            var serializer = new JavaScriptSerializer();
            IDictionary<string, object> root = AsDictionary(
                serializer.DeserializeObject(File.ReadAllText(path)),
                "legacy config");
            if (TryDictionary(root, "target", out IDictionary<string, object> target))
            {
                settings.Detection.WatchMatcher = ReadMatcher(
                    target,
                    settings.Detection.WatchMatcher);
            }

            if (TryDictionary(root, "proximity", out IDictionary<string, object> proximity))
            {
                settings.Detection.WatchRssiThreshold = ReadInt(
                    proximity,
                    "rssiThreshold",
                    settings.Detection.WatchRssiThreshold);
                settings.Detection.LearnedWatchRssiThreshold = ReadInt(
                    proximity,
                    "learnedAddressRssiThreshold",
                    settings.Detection.LearnedWatchRssiThreshold);
                settings.Detection.WatchHitCount = ReadInt(
                    proximity,
                    "hitCount",
                    settings.Detection.WatchHitCount);
                settings.Detection.WatchHitWindowSeconds = ReadInt(
                    proximity,
                    "hitWindowSeconds",
                    settings.Detection.WatchHitWindowSeconds);
                settings.Detection.WatchLostSeconds = ReadInt(
                    proximity,
                    "lostSeconds",
                    settings.Detection.WatchLostSeconds);
                settings.Detection.AddressLearningWindowSeconds = ReadInt(
                    proximity,
                    "addressLearningWindowSeconds",
                    settings.Detection.AddressLearningWindowSeconds);
                settings.Detection.AddressLearningMinimumHits = ReadInt(
                    proximity,
                    "addressLearningMinimumHits",
                    settings.Detection.AddressLearningMinimumHits);
                settings.Actions.Wake.CooldownSeconds = ReadInt(
                    proximity,
                    "cooldownSeconds",
                    settings.Actions.Wake.CooldownSeconds);
                settings.Actions.Wake.RearmSeconds = settings.Detection.WatchLostSeconds;
            }

            if (TryDictionary(root, "phone", out IDictionary<string, object> phone))
            {
                settings.Detection.PhoneEnabled = ReadBool(
                    phone,
                    "enabled",
                    settings.Detection.PhoneEnabled);
                settings.Detection.PhoneMatcher = new DeviceMatcherOptions
                {
                    Address = ReadString(
                        phone,
                        "address",
                        settings.Detection.PhoneMatcher.Address),
                    NameContains = ReadString(
                        phone,
                        "nameContains",
                        settings.Detection.PhoneMatcher.NameContains)
                };
                settings.Detection.PhoneRssiThreshold = ReadInt(
                    phone,
                    "rssiThreshold",
                    settings.Detection.PhoneRssiThreshold);
                settings.Detection.PhoneStrongRssiSingleHitThreshold = ReadInt(
                    phone,
                    "strongRssiSingleHitThreshold",
                    settings.Detection.PhoneStrongRssiSingleHitThreshold);
                settings.Detection.PhoneHitCount = ReadInt(
                    phone,
                    "hitCount",
                    settings.Detection.PhoneHitCount);
                settings.Detection.PhoneHitWindowSeconds = ReadInt(
                    phone,
                    "hitWindowSeconds",
                    settings.Detection.PhoneHitWindowSeconds);
                settings.Detection.PhonePresenceTimeoutSeconds = ReadInt(
                    phone,
                    "presenceTimeoutSeconds",
                    settings.Detection.PhonePresenceTimeoutSeconds);
            }

            if (TryDictionary(root, "network", out IDictionary<string, object> network))
            {
                settings.Network.Enabled = ReadBool(
                    network,
                    "enabled",
                    settings.Network.Enabled);
                settings.Network.AllowedProfileNames = ReadStringArray(
                    network,
                    "allowedProfileNames",
                    settings.Network.AllowedProfileNames);
                settings.Network.AllowedSsids = ReadStringArray(
                    network,
                    "allowedSsids",
                    settings.Network.AllowedSsids);
            }

            if (TryDictionary(root, "diagnostics", out IDictionary<string, object> diagnostics))
            {
                settings.Detection.MaximumAdvertisementAgeSeconds = ReadInt(
                    diagnostics,
                    "maxAdvertisementAgeSeconds",
                    settings.Detection.MaximumAdvertisementAgeSeconds);
                settings.Ble.SamplingIntervalMilliseconds = ReadInt(
                    diagnostics,
                    "bleSamplingIntervalMilliseconds",
                    settings.Ble.SamplingIntervalMilliseconds);
                settings.Ble.LockedPollIntervalMilliseconds = ReadInt(
                    diagnostics,
                    "lockedPollIntervalMilliseconds",
                    settings.Ble.LockedPollIntervalMilliseconds);
                settings.Ble.BackgroundPollIntervalMilliseconds = ReadInt(
                    diagnostics,
                    "unlockedPollIntervalMilliseconds",
                    settings.Ble.BackgroundPollIntervalMilliseconds);
                settings.Ble.HeartbeatSeconds = ReadInt(
                    diagnostics,
                    "heartbeatSeconds",
                    settings.Ble.HeartbeatSeconds);
            }

            if (TryDictionary(root, "wake", out IDictionary<string, object> wake))
            {
                settings.Actions.Wake.SendMonitorPowerMessage = ReadBool(
                    wake,
                    "enableMonitorPowerMessage",
                    settings.Actions.Wake.SendMonitorPowerMessage);
                settings.Actions.Wake.SendMouseNudge = ReadBool(
                    wake,
                    "enableMouseNudge",
                    settings.Actions.Wake.SendMouseNudge);
                settings.Actions.Wake.SendSpaceKey =
                    ReadBool(wake, "enableScanCodeKey", true) ||
                    ReadBool(wake, "enableVirtualKey", true) ||
                    ReadBool(wake, "enableLegacyInput", true);
            }

            if (TryDictionary(root, "autoLock", out IDictionary<string, object> actionAutoLock))
            {
                settings.Actions.AutoLock.AbsenceSeconds = ReadInt(
                    actionAutoLock,
                    "absenceSeconds",
                    settings.Actions.AutoLock.AbsenceSeconds);
                settings.Actions.AutoLock.MinimumUserIdleSeconds = ReadInt(
                    actionAutoLock,
                    "minimumUserIdleSeconds",
                    settings.Actions.AutoLock.MinimumUserIdleSeconds);
                settings.Actions.AutoLock.RetrySeconds = ReadInt(
                    actionAutoLock,
                    "retrySeconds",
                    settings.Actions.AutoLock.RetrySeconds);
            }

            if (TryDictionary(root, "autoUnlock", out IDictionary<string, object> autoUnlock))
            {
                settings.AutoUnlock.AuthorizationTtlMilliseconds = ReadInt(
                    autoUnlock,
                    "authorizationTtlMilliseconds",
                    settings.AutoUnlock.AuthorizationTtlMilliseconds);
                settings.AutoUnlock.ResponseTimeoutMilliseconds = ReadInt(
                    autoUnlock,
                    "brokerResponseTimeoutMilliseconds",
                    settings.AutoUnlock.ResponseTimeoutMilliseconds);
                settings.AutoUnlock.RequireAllowedNetwork = ReadBool(
                    autoUnlock,
                    "requireAllowedNetwork",
                    settings.AutoUnlock.RequireAllowedNetwork);
                settings.AutoUnlock.RequireAcPower = ReadBool(
                    autoUnlock,
                    "requireAcPower",
                    settings.AutoUnlock.RequireAcPower);
                settings.AutoUnlock.TriggerOnArrival = ReadBool(
                    autoUnlock,
                    "triggerOnArrival",
                    settings.AutoUnlock.TriggerOnArrival);
                settings.AutoUnlock.TriggerOnInteractiveWake = ReadBool(
                    autoUnlock,
                    "triggerOnInteractiveWake",
                    settings.AutoUnlock.TriggerOnInteractiveWake);
                settings.AutoUnlock.InteractiveWakeMinimumPriorIdleMilliseconds =
                    SecondsToMilliseconds(
                        ReadDouble(
                            autoUnlock,
                            "interactiveWakeMinimumPriorIdleSeconds",
                            settings.AutoUnlock.InteractiveWakeMinimumPriorIdleMilliseconds /
                                1000.0));
                settings.AutoUnlock.InteractiveWakeInputFreshMilliseconds =
                    SecondsToMilliseconds(
                        ReadDouble(
                            autoUnlock,
                            "interactiveWakeInputFreshSeconds",
                            settings.AutoUnlock.InteractiveWakeInputFreshMilliseconds /
                                1000.0));
                settings.AutoUnlock.InteractiveWakeMaximumPresenceAgeMilliseconds =
                    SecondsToMilliseconds(
                        ReadDouble(
                            autoUnlock,
                            "interactiveWakeMaxWatchAgeSeconds",
                            settings.AutoUnlock.InteractiveWakeMaximumPresenceAgeMilliseconds /
                                1000.0));
                settings.AutoUnlock.InteractiveWakeConfirmationMilliseconds = ReadInt(
                    autoUnlock,
                    "interactiveWakeConfirmationMilliseconds",
                    settings.AutoUnlock.InteractiveWakeConfirmationMilliseconds);
                settings.AutoUnlock.InteractiveWakeAllowIdleFallback = ReadBool(
                    autoUnlock,
                    "interactiveWakeAllowIdleFallback",
                    settings.AutoUnlock.InteractiveWakeAllowIdleFallback);
            }

            // Legacy import never activates system actions. Enabling wake or auto-lock
            // requires an explicit schema 3 configuration change after migration.
            settings.Actions.Wake.Enabled = false;
            settings.Actions.AutoLock.Enabled = false;
            settings.AutoUnlock.Enabled = false;
            ApplyLegacyPresencePolicies(root, settings);
            settings.SchemaVersion = AgentSettings.CurrentSchemaVersion;
            settings.Validate();
            return settings;
        }

        private static int SecondsToMilliseconds(double seconds)
        {
            return checked((int)Math.Round(
                seconds * 1000.0,
                MidpointRounding.AwayFromZero));
        }

        private static void ApplyLegacyPresencePolicies(
            IDictionary<string, object> root,
            AgentSettings settings)
        {
            if (settings.Detection.PhoneEnabled)
            {
                settings.PresencePolicies.Wake.Mode = PresenceMode.WatchAndPhone;
            }

            if (TryDictionary(root, "autoUnlock", out IDictionary<string, object> autoUnlock) &&
                ReadBool(autoUnlock, "requirePhonePresence", true))
            {
                settings.PresencePolicies.AutoUnlock.Mode = PresenceMode.WatchAndPhone;
            }

            if (TryDictionary(root, "autoLock", out IDictionary<string, object> autoLock))
            {
                bool watch = ReadBool(autoLock, "requireWatchAbsent", true);
                bool phone = ReadBool(autoLock, "requirePhoneAbsent", true);
                if (watch && phone)
                {
                    settings.PresencePolicies.AutoLock.Mode = PresenceMode.WatchAndPhone;
                }
                else if (phone)
                {
                    settings.PresencePolicies.AutoLock.Mode = PresenceMode.PhoneOnly;
                }
            }
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

        private static bool TryDictionary(
            IDictionary<string, object> values,
            string name,
            out IDictionary<string, object> result)
        {
            result = null;
            if (!values.TryGetValue(name, out object value) || value == null)
            {
                return false;
            }

            result = AsDictionary(value, name);
            return true;
        }

        private static IDictionary<string, object> AsDictionary(object value, string name)
        {
            if (value is IDictionary<string, object> dictionary)
            {
                return dictionary;
            }

            throw new InvalidOperationException(name + " must be a JSON object.");
        }

        private static string ReadString(
            IDictionary<string, object> values,
            string name,
            string fallback)
        {
            return values.TryGetValue(name, out object value) && value != null
                ? Convert.ToString(value, CultureInfo.InvariantCulture)
                : fallback;
        }

        private static int ReadInt(
            IDictionary<string, object> values,
            string name,
            int fallback)
        {
            return values.TryGetValue(name, out object value) && value != null
                ? Convert.ToInt32(value, CultureInfo.InvariantCulture)
                : fallback;
        }

        private static double ReadDouble(
            IDictionary<string, object> values,
            string name,
            double fallback)
        {
            return values.TryGetValue(name, out object value) && value != null
                ? Convert.ToDouble(value, CultureInfo.InvariantCulture)
                : fallback;
        }

        private static bool ReadBool(
            IDictionary<string, object> values,
            string name,
            bool fallback)
        {
            return values.TryGetValue(name, out object value) && value != null
                ? Convert.ToBoolean(value, CultureInfo.InvariantCulture)
                : fallback;
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
