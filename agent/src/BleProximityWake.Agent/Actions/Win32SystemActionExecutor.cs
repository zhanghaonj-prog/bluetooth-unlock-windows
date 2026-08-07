using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using BleProximityWake.Agent.Configuration;
using BleProximityWake.Core.Actions;

namespace BleProximityWake.Agent.Actions
{
    internal sealed class Win32SystemActionExecutor : ISystemActionExecutor
    {
        private const uint EsSystemRequired = 0x00000001;
        private const uint EsDisplayRequired = 0x00000002;
        private const uint WmSysCommand = 0x0112;
        private const uint ScMonitorPower = 0xF170;
        private const uint SmtoAbortIfHung = 0x0002;
        private const uint InputMouse = 0;
        private const uint InputKeyboard = 1;
        private const uint KeyEventKeyUp = 0x0002;
        private const ushort VirtualKeySpace = 0x20;
        private static readonly IntPtr HwndBroadcast = new IntPtr(0xffff);

        private readonly WakeActionSettings wake;

        internal Win32SystemActionExecutor(WakeActionSettings wake)
        {
            this.wake = wake ?? throw new ArgumentNullException("wake");
        }

        public SystemActionResult Execute(ProximityActionType action)
        {
            switch (action)
            {
                case ProximityActionType.WakeToLogin:
                    return WakeToLogin();
                case ProximityActionType.LockWorkstation:
                    return LockWorkstation();
                case ProximityActionType.RequestDisplayPower:
                    return RequestDisplayPower();
                default:
                    return new SystemActionResult
                    {
                        Succeeded = true,
                        Detail = "no action"
                    };
            }
        }

        private SystemActionResult WakeToLogin()
        {
            var details = new List<string>();
            uint executionState = SetThreadExecutionState(EsDisplayRequired | EsSystemRequired);
            details.Add("executionState=" + executionState);

            bool anyInputSucceeded = false;
            if (wake.SendMonitorPowerMessage)
            {
                IntPtr messageResult;
                IntPtr result = SendMessageTimeout(
                    HwndBroadcast,
                    WmSysCommand,
                    new IntPtr(ScMonitorPower),
                    new IntPtr(-1),
                    SmtoAbortIfHung,
                    250,
                    out messageResult);
                details.Add("monitorMessage=" + result);
                anyInputSucceeded |= result != IntPtr.Zero;
            }

            if (wake.SendMouseNudge)
            {
                INPUT[] inputs =
                {
                    MouseInput(1),
                    MouseInput(-1)
                };
                uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
                details.Add("mouseInputs=" + sent);
                anyInputSucceeded |= sent == inputs.Length;
            }

            if (wake.SendSpaceKey)
            {
                INPUT[] inputs =
                {
                    KeyboardInput(VirtualKeySpace, 0),
                    KeyboardInput(VirtualKeySpace, KeyEventKeyUp)
                };
                uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
                details.Add("spaceInputs=" + sent);
                anyInputSucceeded |= sent == inputs.Length;
            }

            bool succeeded = executionState != 0 && anyInputSucceeded;
            if (!succeeded)
            {
                details.Add("lastError=" + new Win32Exception(Marshal.GetLastWin32Error()).Message);
            }

            return new SystemActionResult
            {
                Succeeded = succeeded,
                Detail = string.Join(" ", details)
            };
        }

        private SystemActionResult RequestDisplayPower()
        {
            var details = new List<string>();
            uint executionState = SetThreadExecutionState(EsDisplayRequired | EsSystemRequired);
            details.Add("executionState=" + executionState);
            bool messageSucceeded = false;
            if (wake.SendMonitorPowerMessage)
            {
                IntPtr messageResult;
                IntPtr result = SendMessageTimeout(
                    HwndBroadcast,
                    WmSysCommand,
                    new IntPtr(ScMonitorPower),
                    new IntPtr(-1),
                    SmtoAbortIfHung,
                    250,
                    out messageResult);
                messageSucceeded = result != IntPtr.Zero;
                details.Add("monitorMessage=" + result);
            }

            return new SystemActionResult
            {
                Succeeded = executionState != 0 &&
                    (!wake.SendMonitorPowerMessage || messageSucceeded),
                Detail = string.Join(" ", details)
            };
        }

        private static SystemActionResult LockWorkstation()
        {
            bool succeeded = LockWorkStation();
            return new SystemActionResult
            {
                Succeeded = succeeded,
                Detail = succeeded
                    ? "LockWorkStation accepted"
                    : "LockWorkStation failed: " +
                      new Win32Exception(Marshal.GetLastWin32Error()).Message
            };
        }

        private static INPUT MouseInput(int dx)
        {
            return new INPUT
            {
                Type = InputMouse,
                Union = new INPUTUNION
                {
                    Mouse = new MOUSEINPUT
                    {
                        Dx = dx
                    }
                }
            };
        }

        private static INPUT KeyboardInput(ushort virtualKey, uint flags)
        {
            return new INPUT
            {
                Type = InputKeyboard,
                Union = new INPUTUNION
                {
                    Keyboard = new KEYBDINPUT
                    {
                        VirtualKey = virtualKey,
                        Flags = flags
                    }
                }
            };
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT
        {
            internal uint Type;
            internal INPUTUNION Union;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct INPUTUNION
        {
            [FieldOffset(0)]
            internal MOUSEINPUT Mouse;

            [FieldOffset(0)]
            internal KEYBDINPUT Keyboard;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MOUSEINPUT
        {
            internal int Dx;
            internal int Dy;
            internal uint MouseData;
            internal uint Flags;
            internal uint Time;
            internal IntPtr ExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT
        {
            internal ushort VirtualKey;
            internal ushort ScanCode;
            internal uint Flags;
            internal uint Time;
            internal IntPtr ExtraInfo;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint SetThreadExecutionState(uint executionState);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(
            IntPtr window,
            uint message,
            IntPtr wParam,
            IntPtr lParam,
            uint flags,
            uint timeout,
            out IntPtr result);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(
            uint inputCount,
            INPUT[] inputs,
            int inputSize);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool LockWorkStation();
    }
}
