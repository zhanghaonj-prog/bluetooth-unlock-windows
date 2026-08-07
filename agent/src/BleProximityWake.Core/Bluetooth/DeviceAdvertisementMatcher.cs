using System;

namespace BleProximityWake.Core.Bluetooth
{
    public static class DeviceAdvertisementMatcher
    {
        public static bool IsMatch(BleAdvertisement advertisement, DeviceMatcherOptions options)
        {
            if (advertisement == null)
            {
                throw new ArgumentNullException("advertisement");
            }

            if (options == null)
            {
                throw new ArgumentNullException("options");
            }

            string configuredAddress = BluetoothAddress.Normalize(options.Address);
            if (configuredAddress.Length > 0)
            {
                return string.Equals(
                    BluetoothAddress.Normalize(advertisement.Address),
                    configuredAddress,
                    StringComparison.Ordinal);
            }

            if (!string.IsNullOrWhiteSpace(options.NameContains) &&
                !string.IsNullOrWhiteSpace(advertisement.LocalName) &&
                advertisement.LocalName.IndexOf(
                    options.NameContains,
                    StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return true;
            }

            if (!string.IsNullOrWhiteSpace(options.ServiceUuid))
            {
                foreach (string serviceUuid in advertisement.ServiceUuids)
                {
                    if (string.Equals(
                        serviceUuid,
                        options.ServiceUuid,
                        StringComparison.OrdinalIgnoreCase))
                    {
                        return true;
                    }
                }
            }

            string prefix = HexPatternMatcher.NormalizeHex(options.ManufacturerDataHexPrefix);
            if (prefix.Length > 0)
            {
                foreach (string item in advertisement.ManufacturerData)
                {
                    if (HexPatternMatcher.NormalizeHex(item).StartsWith(
                        prefix,
                        StringComparison.OrdinalIgnoreCase))
                    {
                        return true;
                    }
                }
            }

            if (!string.IsNullOrWhiteSpace(options.ManufacturerDataHexPattern))
            {
                foreach (string item in advertisement.ManufacturerData)
                {
                    if (HexPatternMatcher.IsMatch(
                        item,
                        options.ManufacturerDataHexPattern))
                    {
                        return true;
                    }
                }
            }

            return false;
        }
    }
}
