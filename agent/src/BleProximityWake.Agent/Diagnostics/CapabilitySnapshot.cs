using System;
using System.IO;
using System.ServiceProcess;

namespace BleProximityWake.Agent.Diagnostics
{
    internal sealed class CapabilitySnapshot
    {
        internal string OsVersion { get; private set; }

        internal bool Is64BitOperatingSystem { get; private set; }

        internal bool IsSupportedWindowsBuild { get; private set; }

        internal bool BleAdvertisementApiAvailable { get; private set; }

        internal bool UnlockBrokerAvailable { get; private set; }

        internal static CapabilitySnapshot Capture()
        {
            Version version = Environment.OSVersion.Version;
            return new CapabilitySnapshot
            {
                OsVersion = Environment.OSVersion.VersionString,
                Is64BitOperatingSystem = Environment.Is64BitOperatingSystem,
                IsSupportedWindowsBuild = version.Major > 10 ||
                    (version.Major == 10 && version.Build >= 17763),
                BleAdvertisementApiAvailable = version.Major >= 10 &&
                    HasWinRtMetadata("Windows.Devices.winmd") &&
                    HasWinRtMetadata("Windows.Foundation.winmd") &&
                    HasWinRtMetadata("Windows.Storage.winmd"),
                UnlockBrokerAvailable = IsServiceAvailable("BleProximityUnlockBroker")
            };
        }

        internal bool RefreshUnlockBrokerAvailability()
        {
            UnlockBrokerAvailable = IsServiceAvailable("BleProximityUnlockBroker");
            return UnlockBrokerAvailable;
        }

        internal string ToDiagnosticText()
        {
            return string.Join(
                Environment.NewLine,
                "OS: " + OsVersion,
                "OS x64: " + Is64BitOperatingSystem,
                "Supported Windows build: " + IsSupportedWindowsBuild,
                "BLE advertisement API: " + BleAdvertisementApiAvailable,
                "Unlock Broker: " + UnlockBrokerAvailable);
        }

        private static bool IsServiceAvailable(string name)
        {
            try
            {
                using (var service = new ServiceController(name))
                {
                    ServiceControllerStatus status = service.Status;
                    return status == ServiceControllerStatus.Running ||
                        status == ServiceControllerStatus.StartPending;
                }
            }
            catch
            {
                return false;
            }
        }

        private static bool HasWinRtMetadata(string fileName)
        {
            return File.Exists(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32",
                "WinMetadata",
                fileName));
        }
    }
}
