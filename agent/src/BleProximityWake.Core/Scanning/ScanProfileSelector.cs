using System;

namespace BleProximityWake.Core.Scanning
{
    public static class ScanProfileSelector
    {
        public static ScanProfile Select(
            ScanContext context,
            int lockedPollIntervalMilliseconds,
            int backgroundPollIntervalMilliseconds)
        {
            if (context == null)
            {
                throw new ArgumentNullException("context");
            }

            if (lockedPollIntervalMilliseconds <= 0 ||
                backgroundPollIntervalMilliseconds <= 0)
            {
                throw new ArgumentOutOfRangeException(
                    "Scan intervals must be positive.");
            }

            bool active = !context.DetectionPaused &&
                context.SessionLocked &&
                context.NetworkAllowed &&
                context.AcPowerConnected;
            return new ScanProfile
            {
                Mode = active ? BleScanMode.Active : BleScanMode.Passive,
                PollIntervalMilliseconds = active
                    ? lockedPollIntervalMilliseconds
                    : backgroundPollIntervalMilliseconds,
                Reason = BuildReason(context, active)
            };
        }

        private static string BuildReason(ScanContext context, bool active)
        {
            if (active)
            {
                return "locked-network-ac";
            }

            if (context.DetectionPaused)
            {
                return "detection-paused";
            }

            if (!context.SessionLocked)
            {
                return "session-unlocked";
            }

            if (!context.NetworkAllowed)
            {
                return "network-not-allowed";
            }

            return "battery-or-power-unknown";
        }
    }
}
