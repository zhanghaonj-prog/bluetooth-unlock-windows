using System;

namespace BleProximityWake.Core.Bluetooth
{
    public static class BluetoothAddress
    {
        public static string Normalize(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return string.Empty;
            }

            char[] buffer = new char[12];
            int count = 0;
            foreach (char character in value)
            {
                if (!Uri.IsHexDigit(character))
                {
                    continue;
                }

                if (count >= buffer.Length)
                {
                    return string.Empty;
                }

                buffer[count++] = char.ToUpperInvariant(character);
            }

            return count == buffer.Length ? new string(buffer) : string.Empty;
        }

        public static string Format(ulong value)
        {
            string hex = value.ToString("X12");
            return string.Format(
                "{0}:{1}:{2}:{3}:{4}:{5}",
                hex.Substring(0, 2),
                hex.Substring(2, 2),
                hex.Substring(4, 2),
                hex.Substring(6, 2),
                hex.Substring(8, 2),
                hex.Substring(10, 2));
        }
    }
}
