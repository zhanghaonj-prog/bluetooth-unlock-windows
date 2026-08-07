using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using BleProximityWake.Agent.Configuration;
using Microsoft.Win32;

namespace BleProximityWake.Agent.Runtime
{
    internal sealed class RuntimeConditionMonitor : IRuntimeConditionSource
    {
        private const uint DesktopSwitchDesktop = 0x0100;
        private readonly object stateGate = new object();
        private readonly NetworkContextProvider networkProvider;
        private readonly DisplayPowerMonitor displayMonitor;
        private bool disposed;
        private bool sessionLocked;
        private bool sessionKnown;
        private long resumeSequence;
        private DateTime lastResumeUtc = DateTime.MinValue;
        private DisplayPowerState displayState = DisplayPowerState.Unknown;
        private long displaySequence;
        private bool displayWasOffSinceLock;
        private long inputSequence;
        private uint lastInputTick;

        internal RuntimeConditionMonitor(NetworkSettings networkSettings)
        {
            networkProvider = new NetworkContextProvider(networkSettings);
            sessionLocked = !CanOpenInputDesktop();
            sessionKnown = true;
            displayMonitor = new DisplayPowerMonitor();
            displayMonitor.StateChanged += OnDisplayStateChanged;
            SystemEvents.SessionSwitch += OnSessionSwitch;
            SystemEvents.PowerModeChanged += OnPowerModeChanged;
        }

        public RuntimeConditionSnapshot Capture()
        {
            DateTime nowUtc = DateTime.UtcNow;
            LastInputInfo input = new LastInputInfo
            {
                Size = (uint)Marshal.SizeOf(typeof(LastInputInfo))
            };
            bool inputAvailable = GetLastInputInfo(ref input);
            uint currentTick = unchecked((uint)Environment.TickCount);
            double idleSeconds = inputAvailable
                ? unchecked(currentTick - input.Tick) / 1000.0
                : -1;
            DateTime lastInputUtc = inputAvailable
                ? nowUtc.AddSeconds(-idleSeconds)
                : DateTime.MinValue;
            lock (stateGate)
            {
                if (inputAvailable && lastInputTick != 0 && input.Tick != lastInputTick)
                {
                    inputSequence++;
                }
                if (inputAvailable)
                {
                    lastInputTick = input.Tick;
                }

                return new RuntimeConditionSnapshot
                {
                    SessionLocked = sessionLocked,
                    SessionKnown = sessionKnown,
                    AcPowerConnected =
                        SystemInformation.PowerStatus.PowerLineStatus == PowerLineStatus.Online,
                    Network = networkProvider.Capture(),
                    ResumeSequence = resumeSequence,
                    LastResumeUtc = lastResumeUtc,
                    DisplayState = displayState,
                    DisplaySequence = displaySequence,
                    DisplayWasOffSinceLock = displayWasOffSinceLock,
                    InputSequence = inputSequence,
                    LastInputUtc = lastInputUtc,
                    UserIdleSeconds = idleSeconds
                };
            }
        }

        public NetworkContextSnapshot RefreshNetwork()
        {
            return networkProvider.CaptureFresh();
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            SystemEvents.SessionSwitch -= OnSessionSwitch;
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
            displayMonitor.StateChanged -= OnDisplayStateChanged;
            displayMonitor.Dispose();
        }

        private void OnSessionSwitch(object sender, SessionSwitchEventArgs args)
        {
            if (args.Reason == SessionSwitchReason.SessionLock)
            {
                lock (stateGate)
                {
                    sessionLocked = true;
                    sessionKnown = true;
                    displayWasOffSinceLock = false;
                }
            }
            else if (args.Reason == SessionSwitchReason.SessionUnlock)
            {
                lock (stateGate)
                {
                    sessionLocked = false;
                    sessionKnown = true;
                    displayWasOffSinceLock = false;
                }
            }
        }

        private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs args)
        {
            if (args.Mode == PowerModes.Resume)
            {
                lock (stateGate)
                {
                    resumeSequence++;
                    lastResumeUtc = DateTime.UtcNow;
                }
            }
        }

        private void OnDisplayStateChanged(DisplayPowerState state)
        {
            lock (stateGate)
            {
                if (state != displayState)
                {
                    displayState = state;
                    displaySequence++;
                }

                if (sessionLocked && state == DisplayPowerState.Off)
                {
                    displayWasOffSinceLock = true;
                }
            }
        }

        private static bool CanOpenInputDesktop()
        {
            IntPtr desktop = OpenInputDesktop(0, false, DesktopSwitchDesktop);
            if (desktop == IntPtr.Zero)
            {
                return false;
            }

            CloseDesktop(desktop);
            return true;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr OpenInputDesktop(
            uint flags,
            bool inherit,
            uint desiredAccess);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseDesktop(IntPtr desktop);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetLastInputInfo(ref LastInputInfo information);

        [StructLayout(LayoutKind.Sequential)]
        private struct LastInputInfo
        {
            internal uint Size;

            internal uint Tick;
        }
    }
}
