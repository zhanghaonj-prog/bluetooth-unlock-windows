using System;

namespace BleProximityWake.Core.Bluetooth
{
    public sealed class DeviceMatcherOptions
    {
        public string Address { get; set; } = string.Empty;

        public string NameContains { get; set; } = string.Empty;

        public string ServiceUuid { get; set; } = string.Empty;

        public string ManufacturerDataHexPrefix { get; set; } = string.Empty;

        public string ManufacturerDataHexPattern { get; set; } = string.Empty;

        public void Validate(string name)
        {
            if (!string.IsNullOrWhiteSpace(Address) &&
                BluetoothAddress.Normalize(Address).Length != 12)
            {
                throw new InvalidOperationException(name + " address is invalid.");
            }

            if (!string.IsNullOrWhiteSpace(ServiceUuid) &&
                !Guid.TryParse(ServiceUuid, out Guid ignoredUuid))
            {
                throw new InvalidOperationException(name + " service UUID is invalid.");
            }

            ValidateHexValue(
                ManufacturerDataHexPrefix,
                false,
                name + " manufacturer data prefix");
            ValidateHexValue(
                ManufacturerDataHexPattern,
                true,
                name + " manufacturer data pattern");

            if (!string.IsNullOrWhiteSpace(Address) &&
                (!string.IsNullOrWhiteSpace(NameContains) ||
                 !string.IsNullOrWhiteSpace(ServiceUuid) ||
                 !string.IsNullOrWhiteSpace(ManufacturerDataHexPrefix) ||
                 !string.IsNullOrWhiteSpace(ManufacturerDataHexPattern)))
            {
                throw new InvalidOperationException(
                    name + " address cannot be combined with fallback match conditions.");
            }
        }

        private static void ValidateHexValue(string value, bool allowWildcard, string name)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return;
            }

            foreach (char character in value)
            {
                bool separator = character == ':' ||
                    character == '-' ||
                    char.IsWhiteSpace(character);
                if (!Uri.IsHexDigit(character) &&
                    !(allowWildcard && character == '?') &&
                    !separator)
                {
                    throw new InvalidOperationException(name + " contains invalid characters.");
                }
            }

            string normalized = allowWildcard
                ? NormalizePattern(value)
                : HexPatternMatcher.NormalizeHex(value);
            if (normalized.Length == 0 || normalized.Length % 2 != 0)
            {
                throw new InvalidOperationException(
                    name + " must contain complete hexadecimal bytes.");
            }
        }

        private static string NormalizePattern(string value)
        {
            var result = new System.Text.StringBuilder(value.Length);
            foreach (char character in value)
            {
                if (Uri.IsHexDigit(character))
                {
                    result.Append(char.ToUpperInvariant(character));
                }
                else if (character == '?')
                {
                    result.Append(character);
                }
            }

            return result.ToString();
        }
    }
}
