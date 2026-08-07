using System;
using System.Collections.Generic;
using System.Linq;
using System.Management;
using System.Runtime.InteropServices;
using BleProximityWake.Agent.Configuration;
using Windows.Networking.Connectivity;

namespace BleProximityWake.Agent.Runtime
{
    internal sealed class NetworkContextProvider
    {
        private static readonly TimeSpan CacheDuration = TimeSpan.FromSeconds(5);
        private readonly object cacheGate = new object();
        private readonly NetworkSettings settings;
        private DateTime cacheExpiresUtc = DateTime.MinValue;
        private NetworkContextSnapshot cachedSnapshot;

        internal NetworkContextProvider(NetworkSettings settings)
        {
            this.settings = settings ?? throw new ArgumentNullException("settings");
        }

        internal NetworkContextSnapshot Capture()
        {
            return Capture(false);
        }

        internal NetworkContextSnapshot CaptureFresh()
        {
            return Capture(true);
        }

        private NetworkContextSnapshot Capture(bool forceRefresh)
        {
            if (!settings.Enabled)
            {
                return new NetworkContextSnapshot
                {
                    Allowed = true,
                    Reason = "network-filter-disabled",
                    ProfileNames = new string[0],
                    Ssids = new string[0]
                };
            }

            DateTime nowUtc = DateTime.UtcNow;
            lock (cacheGate)
            {
                if (!forceRefresh && cachedSnapshot != null && nowUtc < cacheExpiresUtc)
                {
                    return cachedSnapshot;
                }
            }

            try
            {
                NetworkContextSnapshot snapshot = CaptureConnectedProfiles();
                lock (cacheGate)
                {
                    cachedSnapshot = snapshot;
                    cacheExpiresUtc = nowUtc.Add(CacheDuration);
                }

                return snapshot;
            }
            catch (Exception exception)
            {
                return new NetworkContextSnapshot
                {
                    Allowed = false,
                    Reason = "network-query-error:" + exception.GetType().Name,
                    ProfileNames = new string[0],
                    Ssids = new string[0]
                };
            }
        }

        private NetworkContextSnapshot CaptureConnectedProfiles()
        {
            var profiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var ssids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            bool profileQuerySucceeded = TryAddWindowsNetworkProfileNames(profiles);
            foreach (ConnectionProfile profile in NetworkInformation.GetConnectionProfiles())
            {
                if (profile.GetNetworkConnectivityLevel() != NetworkConnectivityLevel.None)
                {
                    AddWinRtProfile(
                        profile,
                        profiles,
                        ssids,
                        !profileQuerySucceeded || profiles.Count == 0);
                }
            }

            return Evaluate(profiles, ssids);
        }

        internal NetworkContextSnapshot Evaluate(
            IEnumerable<string> profileNames,
            IEnumerable<string> connectedSsids)
        {
            var profiles = new HashSet<string>(
                profileNames ?? Enumerable.Empty<string>(),
                StringComparer.OrdinalIgnoreCase);
            var ssids = new HashSet<string>(
                connectedSsids ?? Enumerable.Empty<string>(),
                StringComparer.OrdinalIgnoreCase);
            string profileMatch = profiles.FirstOrDefault(
                current => settings.AllowedProfileNames.Any(
                    allowed => WildcardEquals(current, allowed)));
            if (!string.IsNullOrWhiteSpace(profileMatch))
            {
                return Snapshot(true, "profile-match:" + profileMatch, profiles, ssids);
            }

            string ssidMatch = ssids.FirstOrDefault(
                current => settings.AllowedSsids.Any(
                    allowed => WildcardEquals(current, allowed)));
            if (!string.IsNullOrWhiteSpace(ssidMatch))
            {
                return Snapshot(true, "ssid-match:" + ssidMatch, profiles, ssids);
            }

            return Snapshot(false, "no-network-match", profiles, ssids);
        }

        internal static bool WildcardEquals(string value, string pattern)
        {
            if (value == null || pattern == null)
            {
                return false;
            }

            int valueIndex = 0;
            int patternIndex = 0;
            int starIndex = -1;
            int valueAfterStar = -1;
            while (valueIndex < value.Length)
            {
                if (patternIndex < pattern.Length &&
                    char.ToUpperInvariant(value[valueIndex]) ==
                    char.ToUpperInvariant(pattern[patternIndex]))
                {
                    valueIndex++;
                    patternIndex++;
                }
                else if (patternIndex < pattern.Length && pattern[patternIndex] == '*')
                {
                    starIndex = patternIndex++;
                    valueAfterStar = valueIndex;
                }
                else if (starIndex >= 0)
                {
                    patternIndex = starIndex + 1;
                    valueIndex = ++valueAfterStar;
                }
                else
                {
                    return false;
                }
            }

            while (patternIndex < pattern.Length && pattern[patternIndex] == '*')
            {
                patternIndex++;
            }

            return patternIndex == pattern.Length;
        }

        private static bool TryAddWindowsNetworkProfileNames(ISet<string> profiles)
        {
            try
            {
                var scope = new ManagementScope(@"\\.\root\StandardCimv2");
                var query = new ObjectQuery(
                    "SELECT Name, IPv4Connectivity, IPv6Connectivity " +
                    "FROM MSFT_NetConnectionProfile");
                using (var searcher = new ManagementObjectSearcher(scope, query))
                using (ManagementObjectCollection results = searcher.Get())
                {
                    foreach (ManagementObject profile in results)
                    {
                        using (profile)
                        {
                            uint ipv4 = ReadConnectivity(profile, "IPv4Connectivity");
                            uint ipv6 = ReadConnectivity(profile, "IPv6Connectivity");
                            string name = Convert.ToString(profile["Name"]);
                            if ((ipv4 > 0 || ipv6 > 0) &&
                                !string.IsNullOrWhiteSpace(name))
                            {
                                profiles.Add(name);
                            }
                        }
                    }
                }

                return true;
            }
            catch (ManagementException)
            {
                return false;
            }
            catch (UnauthorizedAccessException)
            {
                return false;
            }
            catch (COMException)
            {
                return false;
            }
        }

        private static uint ReadConnectivity(
            ManagementBaseObject profile,
            string propertyName)
        {
            object value = profile[propertyName];
            return value == null ? 0 : Convert.ToUInt32(value);
        }

        private static void AddWinRtProfile(
            ConnectionProfile profile,
            ISet<string> profiles,
            ISet<string> ssids,
            bool includeProfileNameFallback)
        {
            if (includeProfileNameFallback &&
                !string.IsNullOrWhiteSpace(profile.ProfileName))
            {
                profiles.Add(profile.ProfileName);
            }

            if (profile.IsWlanConnectionProfile)
            {
                string ssid = profile.WlanConnectionProfileDetails.GetConnectedSsid();
                if (!string.IsNullOrWhiteSpace(ssid))
                {
                    ssids.Add(ssid);
                }
            }
        }

        private static NetworkContextSnapshot Snapshot(
            bool allowed,
            string reason,
            IEnumerable<string> profiles,
            IEnumerable<string> ssids)
        {
            return new NetworkContextSnapshot
            {
                Allowed = allowed,
                Reason = reason,
                ProfileNames = profiles.OrderBy(value => value).ToArray(),
                Ssids = ssids.OrderBy(value => value).ToArray()
            };
        }
    }
}
