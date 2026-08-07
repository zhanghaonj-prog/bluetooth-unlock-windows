using System;
using System.Collections.Generic;
using System.Linq;
using BleProximityWake.Core.Bluetooth;

namespace BleProximityWake.Core.Presence
{
    public sealed class DevicePresenceTracker
    {
        private readonly PresenceDetectionOptions options;
        private readonly Dictionary<string, List<CandidateObservation>> watchCandidates =
            new Dictionary<string, List<CandidateObservation>>(StringComparer.Ordinal);
        private bool locked;
        private string lockedWatchAddress = string.Empty;
        private DateTime resumeUtc = DateTime.MinValue;
        private DateTime lastWatchSeenUtc = DateTime.MinValue;
        private DateTime lastPostResumeWatchSeenUtc = DateTime.MinValue;
        private string lastWatchAddress = string.Empty;
        private int lastWatchRssi = -999;
        private int watchHits;
        private string watchHitAddress = string.Empty;
        private DateTime lastPhoneSeenUtc = DateTime.MinValue;
        private DateTime lastPhoneStrongSeenUtc = DateTime.MinValue;
        private DateTime lastPostResumePhoneSeenUtc = DateTime.MinValue;
        private string lastPhoneAddress = string.Empty;
        private int lastPhoneRssi = -999;
        private int phoneHits;
        private string preferredWatchAddress = string.Empty;
        private DateTime preferredWatchLastSeenUtc = DateTime.MinValue;
        private int preferredWatchHits;
        private string learnedWatchAddress = string.Empty;
        private DateTime lastLearnedWatchSeenUtc = DateTime.MinValue;
        private int droppedStaleAdvertisements;

        public DevicePresenceTracker(PresenceDetectionOptions options)
        {
            this.options = options ?? throw new ArgumentNullException("options");
            options.Validate();
        }

        public void SetLocked(bool value)
        {
            if (value && !locked)
            {
                lockedWatchAddress = BluetoothAddress.Normalize(preferredWatchAddress);
            }
            else if (!value)
            {
                lockedWatchAddress = string.Empty;
            }

            locked = value;
        }

        public void BeginResume(DateTime timestampUtc)
        {
            resumeUtc = EnsureUtc(timestampUtc);
            lastPostResumeWatchSeenUtc = DateTime.MinValue;
            lastPostResumePhoneSeenUtc = DateTime.MinValue;
        }

        public void ClearResumeRequirement()
        {
            resumeUtc = DateTime.MinValue;
        }

        public void Reset()
        {
            watchCandidates.Clear();
            lockedWatchAddress = string.Empty;
            resumeUtc = DateTime.MinValue;
            lastWatchSeenUtc = DateTime.MinValue;
            lastPostResumeWatchSeenUtc = DateTime.MinValue;
            lastWatchAddress = string.Empty;
            lastWatchRssi = -999;
            watchHits = 0;
            watchHitAddress = string.Empty;
            lastPhoneSeenUtc = DateTime.MinValue;
            lastPhoneStrongSeenUtc = DateTime.MinValue;
            lastPostResumePhoneSeenUtc = DateTime.MinValue;
            lastPhoneAddress = string.Empty;
            lastPhoneRssi = -999;
            phoneHits = 0;
            preferredWatchAddress = string.Empty;
            preferredWatchLastSeenUtc = DateTime.MinValue;
            preferredWatchHits = 0;
            learnedWatchAddress = string.Empty;
            lastLearnedWatchSeenUtc = DateTime.MinValue;
            droppedStaleAdvertisements = 0;
        }

        public void Process(BleAdvertisement advertisement, DateTime nowUtc)
        {
            if (advertisement == null)
            {
                throw new ArgumentNullException("advertisement");
            }

            nowUtc = EnsureUtc(nowUtc);
            DateTime recordUtc = EnsureUtc(advertisement.TimestampUtc);
            double ageSeconds = (nowUtc - recordUtc).TotalSeconds;
            if (ageSeconds > options.MaximumAdvertisementAgeSeconds || ageSeconds < -2)
            {
                droppedStaleAdvertisements++;
                return;
            }

            if (recordUtc > nowUtc)
            {
                recordUtc = nowUtc;
            }

            ProcessPhone(advertisement, recordUtc);
            ProcessWatch(advertisement, recordUtc);
        }

        public PresenceTrackerSnapshot Evaluate(DateTime nowUtc)
        {
            nowUtc = EnsureUtc(nowUtc);
            UpdatePreferredWatch(nowUtc);

            if (!IsRecent(lastWatchSeenUtc, nowUtc, options.WatchHitWindowSeconds))
            {
                watchHits = 0;
            }

            if (!IsRecent(lastPhoneSeenUtc, nowUtc, options.PhonePresenceTimeoutSeconds))
            {
                phoneHits = 0;
            }

            bool watchReady = watchHits >= options.WatchHitCount &&
                IsRecent(lastWatchSeenUtc, nowUtc, options.WatchLostSeconds);
            bool phoneFastPath = IsRecent(
                lastPhoneStrongSeenUtc,
                nowUtc,
                options.PhonePresenceTimeoutSeconds);
            bool phoneConfirmedByHitCount =
                phoneHits >= options.PhoneHitCount &&
                IsRecent(lastPhoneSeenUtc, nowUtc, options.PhonePresenceTimeoutSeconds);
            bool phoneReady = phoneConfirmedByHitCount || phoneFastPath;
            bool resumeRequired = resumeUtc != DateTime.MinValue;

            return new PresenceTrackerSnapshot
            {
                Observation = new PresenceObservation
                {
                    WatchReady = watchReady,
                    PhoneReady = phoneReady,
                    WatchFreshAfterResume = !resumeRequired ||
                        IsOnOrAfterResume(lastPostResumeWatchSeenUtc),
                    PhoneFreshAfterResume = !resumeRequired ||
                        IsOnOrAfterResume(lastPostResumePhoneSeenUtc)
                },
                PreferredWatchAddress = preferredWatchAddress,
                PreferredWatchHits = preferredWatchHits,
                LastWatchAddress = lastWatchAddress,
                LastWatchRssi = lastWatchRssi,
                LastWatchSeenUtc = lastWatchSeenUtc,
                WatchHits = watchHits,
                LastPhoneAddress = lastPhoneAddress,
                LastPhoneRssi = lastPhoneRssi,
                LastPhoneSeenUtc = lastPhoneSeenUtc,
                PhoneHits = phoneHits,
                PhoneFastPath = phoneFastPath,
                PhoneConfirmedByHitCount = phoneConfirmedByHitCount,
                WatchPresentForDeparture =
                    learnedWatchAddress.Length > 0 &&
                    IsRecent(lastLearnedWatchSeenUtc, nowUtc, options.WatchLostSeconds),
                LastWatchDepartureSeenUtc = learnedWatchAddress.Length > 0
                    ? lastLearnedWatchSeenUtc
                    : lastWatchSeenUtc,
                PhonePresentForDeparture = phoneReady,
                LastPhoneDepartureSeenUtc = lastPhoneSeenUtc,
                DroppedStaleAdvertisements = droppedStaleAdvertisements
            };
        }

        private void ProcessPhone(BleAdvertisement advertisement, DateTime recordUtc)
        {
            if (!options.PhoneEnabled ||
                !DeviceAdvertisementMatcher.IsMatch(advertisement, options.PhoneMatcher) ||
                advertisement.Rssi < options.PhoneRssiThreshold)
            {
                return;
            }

            if ((recordUtc - lastPhoneSeenUtc).TotalSeconds > options.PhoneHitWindowSeconds)
            {
                phoneHits = 0;
            }

            if (lastPhoneSeenUtc != DateTime.MinValue && recordUtc < lastPhoneSeenUtc)
            {
                return;
            }

            lastPhoneSeenUtc = recordUtc;
            phoneHits++;
            lastPhoneAddress = advertisement.Address ?? string.Empty;
            lastPhoneRssi = advertisement.Rssi;
            if (advertisement.Rssi >= options.PhoneStrongRssiSingleHitThreshold)
            {
                lastPhoneStrongSeenUtc = recordUtc;
            }

            if (IsOnOrAfterResume(recordUtc))
            {
                lastPostResumePhoneSeenUtc = recordUtc;
            }
        }

        private void ProcessWatch(BleAdvertisement advertisement, DateTime recordUtc)
        {
            if (!DeviceAdvertisementMatcher.IsMatch(advertisement, options.WatchMatcher))
            {
                return;
            }

            string address = BluetoothAddress.Normalize(advertisement.Address);
            if (address.Length == 0)
            {
                return;
            }
            if (learnedWatchAddress.Length > 0 &&
                string.Equals(address, learnedWatchAddress, StringComparison.Ordinal) &&
                advertisement.Rssi >= options.LearnedWatchRssiThreshold &&
                recordUtc >= lastLearnedWatchSeenUtc)
            {
                lastLearnedWatchSeenUtc = recordUtc;
            }

            bool learnedFastPath = locked &&
                lockedWatchAddress.Length > 0 &&
                string.Equals(address, lockedWatchAddress, StringComparison.Ordinal);
            int threshold = learnedFastPath
                ? options.LearnedWatchRssiThreshold
                : options.WatchRssiThreshold;
            if (advertisement.Rssi < threshold)
            {
                return;
            }

            if ((recordUtc - lastWatchSeenUtc).TotalSeconds >
                    options.WatchHitWindowSeconds ||
                !string.Equals(address, watchHitAddress, StringComparison.Ordinal))
            {
                watchHits = 0;
            }

            if (lastWatchSeenUtc != DateTime.MinValue && recordUtc < lastWatchSeenUtc)
            {
                return;
            }

            lastWatchSeenUtc = recordUtc;
            watchHitAddress = address;
            watchHits++;
            lastWatchAddress = advertisement.Address ?? string.Empty;
            lastWatchRssi = advertisement.Rssi;
            if (IsOnOrAfterResume(recordUtc))
            {
                lastPostResumeWatchSeenUtc = recordUtc;
            }

            if (!locked && advertisement.Rssi >= options.WatchRssiThreshold && address.Length > 0)
            {
                if (!watchCandidates.TryGetValue(address, out List<CandidateObservation> observations))
                {
                    observations = new List<CandidateObservation>();
                    watchCandidates.Add(address, observations);
                }

                observations.Add(new CandidateObservation
                {
                    Address = advertisement.Address ?? string.Empty,
                    TimestampUtc = recordUtc,
                    Rssi = advertisement.Rssi
                });
            }
        }

        private void UpdatePreferredWatch(DateTime nowUtc)
        {
            DateTime cutoff = nowUtc.AddSeconds(-options.AddressLearningWindowSeconds);
            foreach (string address in watchCandidates.Keys.ToArray())
            {
                watchCandidates[address].RemoveAll(item => item.TimestampUtc < cutoff);
                if (watchCandidates[address].Count == 0)
                {
                    watchCandidates.Remove(address);
                }
            }

            CandidateRank selected = watchCandidates.Values
                .Where(items => items.Count > 0)
                .Select(items => new CandidateRank
                {
                    Address = items[items.Count - 1].Address,
                    Count = items.Count,
                    LastSeenUtc = items[items.Count - 1].TimestampUtc,
                    MaxRssi = items.Max(item => item.Rssi)
                })
                .OrderByDescending(item => item.Count)
                .ThenByDescending(item => item.LastSeenUtc)
                .ThenByDescending(item => item.MaxRssi)
                .FirstOrDefault();

            if (selected == null || selected.Count < options.AddressLearningMinimumHits)
            {
                preferredWatchAddress = string.Empty;
                preferredWatchLastSeenUtc = DateTime.MinValue;
                preferredWatchHits = 0;
                return;
            }

            preferredWatchAddress = selected.Address;
            preferredWatchLastSeenUtc = selected.LastSeenUtc;
            preferredWatchHits = selected.Count;
            learnedWatchAddress = BluetoothAddress.Normalize(selected.Address);
            lastLearnedWatchSeenUtc = selected.LastSeenUtc;
        }

        private bool IsOnOrAfterResume(DateTime timestampUtc)
        {
            return resumeUtc != DateTime.MinValue &&
                timestampUtc >= resumeUtc.AddMilliseconds(-250);
        }

        private static bool IsRecent(DateTime timestampUtc, DateTime nowUtc, double maximumAgeSeconds)
        {
            if (timestampUtc == DateTime.MinValue)
            {
                return false;
            }

            double ageSeconds = (nowUtc - timestampUtc).TotalSeconds;
            return ageSeconds >= -2 && ageSeconds <= maximumAgeSeconds;
        }

        private static DateTime EnsureUtc(DateTime value)
        {
            if (value == DateTime.MinValue)
            {
                return value;
            }

            return value.Kind == DateTimeKind.Utc
                ? value
                : value.ToUniversalTime();
        }

        private sealed class CandidateObservation
        {
            internal string Address { get; set; }

            internal DateTime TimestampUtc { get; set; }

            internal int Rssi { get; set; }
        }

        private sealed class CandidateRank
        {
            internal string Address { get; set; }

            internal int Count { get; set; }

            internal DateTime LastSeenUtc { get; set; }

            internal int MaxRssi { get; set; }
        }
    }
}
