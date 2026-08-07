using System;
using System.Text;

namespace BleProximityWake.Core.Bluetooth
{
    public static class HexPatternMatcher
    {
        public static bool IsMatch(string hex, string pattern)
        {
            string normalizedHex = Normalize(hex, false);
            string normalizedPattern = Normalize(pattern, true);
            if (normalizedPattern.Length == 0 || normalizedHex.Length < normalizedPattern.Length)
            {
                return false;
            }

            for (int index = 0; index < normalizedPattern.Length; index++)
            {
                char expected = normalizedPattern[index];
                if (expected != '?' && expected != normalizedHex[index])
                {
                    return false;
                }
            }

            return true;
        }

        public static string NormalizeHex(string value)
        {
            return Normalize(value, false);
        }

        private static string Normalize(string value, bool allowWildcard)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return string.Empty;
            }

            var result = new StringBuilder(value.Length);
            foreach (char character in value)
            {
                if (Uri.IsHexDigit(character))
                {
                    result.Append(char.ToUpperInvariant(character));
                }
                else if (allowWildcard && character == '?')
                {
                    result.Append(character);
                }
            }

            return result.ToString();
        }
    }
}
