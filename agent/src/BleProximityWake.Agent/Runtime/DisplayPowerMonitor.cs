using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace BleProximityWake.Agent.Runtime
{
    internal sealed class DisplayPowerMonitor : NativeWindow, IDisposable
    {
        private const int WmPowerBroadcast = 0x0218;
        private const int PbtPowerSettingChange = 0x8013;
        private const int DeviceNotifyWindowHandle = 0;
        private static readonly Guid ConsoleDisplayState =
            new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");
        private static readonly Guid SessionDisplayStatus =
            new Guid("2B84C20E-AD23-4DDF-93DB-05FFBD7EFCA5");
        private IntPtr consoleNotification;
        private IntPtr sessionNotification;
        private bool disposed;

        internal DisplayPowerMonitor()
        {
            CreateHandle(new CreateParams
            {
                Caption = "BleProximityWake.DisplayPowerMonitor"
            });
            try
            {
                consoleNotification = Register(ConsoleDisplayState);
                sessionNotification = Register(SessionDisplayStatus);
            }
            catch
            {
                Unregister(consoleNotification);
                consoleNotification = IntPtr.Zero;
                DestroyHandle();
                throw;
            }
        }

        internal event Action<DisplayPowerState> StateChanged;

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            Unregister(consoleNotification);
            Unregister(sessionNotification);
            consoleNotification = IntPtr.Zero;
            sessionNotification = IntPtr.Zero;
            DestroyHandle();
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == WmPowerBroadcast &&
                message.WParam.ToInt32() == PbtPowerSettingChange &&
                message.LParam != IntPtr.Zero)
            {
                PowerBroadcastSetting setting =
                    Marshal.PtrToStructure<PowerBroadcastSetting>(message.LParam);
                if ((setting.PowerSetting == ConsoleDisplayState ||
                     setting.PowerSetting == SessionDisplayStatus) &&
                    setting.DataLength >= sizeof(int))
                {
                    int value = Marshal.ReadInt32(
                        message.LParam,
                        Marshal.SizeOf(typeof(Guid)) + sizeof(int));
                    Action<DisplayPowerState> handler = StateChanged;
                    handler?.Invoke(ToState(value));
                }
            }

            base.WndProc(ref message);
        }

        private IntPtr Register(Guid setting)
        {
            IntPtr handle = RegisterPowerSettingNotification(
                Handle,
                ref setting,
                DeviceNotifyWindowHandle);
            if (handle == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            return handle;
        }

        private static void Unregister(IntPtr handle)
        {
            if (handle != IntPtr.Zero)
            {
                UnregisterPowerSettingNotification(handle);
            }
        }

        private static DisplayPowerState ToState(int value)
        {
            if (value == 0)
            {
                return DisplayPowerState.Off;
            }

            if (value == 1)
            {
                return DisplayPowerState.On;
            }

            if (value == 2)
            {
                return DisplayPowerState.Dimmed;
            }

            return DisplayPowerState.Unknown;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct PowerBroadcastSetting
        {
            internal Guid PowerSetting;

            internal int DataLength;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr RegisterPowerSettingNotification(
            IntPtr recipient,
            ref Guid powerSettingGuid,
            int flags);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnregisterPowerSettingNotification(IntPtr handle);
    }
}
