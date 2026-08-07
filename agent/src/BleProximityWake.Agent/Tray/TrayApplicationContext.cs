using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using BleProximityWake.Agent.Configuration;
using BleProximityWake.Agent.Diagnostics;
using BleProximityWake.Agent.Runtime;
using BleProximityWake.Core.Presence;

namespace BleProximityWake.Agent.Tray
{
    internal sealed class TrayApplicationContext : ApplicationContext
    {
        private readonly AgentSettings settings;
        private readonly AgentSettingsStore settingsStore;
        private readonly CapabilitySnapshot capabilities;
        private readonly FileLogger logger;
        private readonly string dataDirectory;
        private readonly NotifyIcon notifyIcon;
        private readonly Icon icon;
        private readonly ContextMenuStrip contextMenu;
        private readonly Timer pollTimer;
        private AgentRuntime runtime;
        private AgentRuntimeStatus runtimeStatus;
        private ToolStripItem detectionStatusItem;
        private ToolStripItem deviceStatusItem;
        private ToolStripItem actionStatusItem;
        private ToolStripItem brokerStatusItem;
        private ToolStripMenuItem pauseDetectionItem;
        private ToolStripMenuItem wakeActionItem;
        private ToolStripMenuItem autoUnlockActionItem;
        private ToolStripMenuItem autoLockActionItem;
        private bool trayResourcesDisposed;

        internal TrayApplicationContext(
            AgentSettings settings,
            AgentSettingsStore settingsStore,
            CapabilitySnapshot capabilities,
            FileLogger logger,
            string dataDirectory)
        {
            this.settings = settings ?? throw new ArgumentNullException("settings");
            this.settingsStore = settingsStore ?? throw new ArgumentNullException("settingsStore");
            this.capabilities = capabilities ?? throw new ArgumentNullException("capabilities");
            this.logger = logger ?? throw new ArgumentNullException("logger");
            this.dataDirectory = dataDirectory ?? throw new ArgumentNullException("dataDirectory");

            icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath)
                ?? (Icon)SystemIcons.Application.Clone();
            contextMenu = BuildMenu();
            notifyIcon = new NotifyIcon
            {
                Icon = icon,
                Text = "BLE Proximity Wake | EXE preview",
                Visible = true,
                ContextMenuStrip = contextMenu
            };
            logger.Info("Tray initialized.");

            pollTimer = new Timer
            {
                Interval = settings.Ble.BackgroundPollIntervalMilliseconds
            };
            pollTimer.Tick += (sender, args) => PollRuntime();
            if (settings.Ble.Enabled && capabilities.BleAdvertisementApiAvailable)
            {
                try
                {
                    runtime = new AgentRuntime(settings, logger);
                    pollTimer.Start();
                    PollRuntime();
                }
                catch (Exception exception)
                {
                    runtime?.Dispose();
                    runtime = null;
                    detectionStatusItem.Text = "Detection: initialization failed (see log)";
                    logger.Error("EXE detection initialization failed: " + exception);
                }
            }
            else
            {
                detectionStatusItem.Text = settings.Ble.Enabled
                    ? "Detection: BLE API unavailable"
                    : "Detection: disabled by configuration";
            }
        }

        private ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip
            {
                ShowItemToolTips = true
            };

            ToolStripItem status = menu.Items.Add("BLE Proximity Wake | EXE migration preview");
            status.Enabled = false;
            ToolStripItem osStatus = menu.Items.Add(
                capabilities.IsSupportedWindowsBuild
                    ? "Windows: Supported"
                    : "Windows: Unsupported build");
            osStatus.Enabled = false;
            ToolStripItem bleStatus = menu.Items.Add(
                capabilities.BleAdvertisementApiAvailable
                    ? "BLE API: Available"
                    : "BLE API: Unavailable");
            bleStatus.Enabled = false;
            brokerStatusItem = menu.Items.Add(
                capabilities.UnlockBrokerAvailable
                    ? "Auto unlock Broker: Available"
                    : "Auto unlock Broker: Unavailable");
            brokerStatusItem.Enabled = false;
            detectionStatusItem = menu.Items.Add("Detection: initializing");
            detectionStatusItem.Enabled = false;
            deviceStatusItem = menu.Items.Add("Devices: watch unknown | phone unknown");
            deviceStatusItem.Enabled = false;
            actionStatusItem = menu.Items.Add(
                "Actions: wake off | unlock off | auto-lock off");
            actionStatusItem.Enabled = false;

            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(CreatePolicyMenu("Wake presence", settings.PresencePolicies.Wake));
            menu.Items.Add(CreatePolicyMenu("Auto-unlock presence", settings.PresencePolicies.AutoUnlock));
            menu.Items.Add(CreatePolicyMenu("Auto-lock presence", settings.PresencePolicies.AutoLock));
            menu.Items.Add(CreateSystemActionMenu());

            menu.Items.Add(new ToolStripSeparator());
            ToolStripItem copyDiagnostics = menu.Items.Add("Copy diagnostics");
            copyDiagnostics.Click += (sender, args) =>
            {
                Clipboard.SetText(BuildDiagnosticText());
                logger.Info("Diagnostics copied from tray.");
            };

            ToolStripItem openData = menu.Items.Add("Open data folder");
            openData.Click += (sender, args) =>
                Process.Start("explorer.exe", "\"" + dataDirectory + "\"");

            ToolStripItem openSettings = menu.Items.Add("Open settings file");
            openSettings.Click += (sender, args) =>
                Process.Start("notepad.exe", "\"" + settingsStore.Path + "\"");

            menu.Items.Add(new ToolStripSeparator());
            ToolStripItem redetectDevices = menu.Items.Add("Re-detect devices");
            redetectDevices.Click += (sender, args) =>
            {
                if (runtime != null)
                {
                    runtime.RedetectDevices();
                    PollRuntime();
                }
            };

            pauseDetectionItem = new ToolStripMenuItem("Pause detection");
            pauseDetectionItem.Click += (sender, args) =>
            {
                if (runtime == null)
                {
                    return;
                }

                runtime.SetDetectionPaused(!runtime.DetectionPaused);
                pauseDetectionItem.Checked = runtime.DetectionPaused;
                pauseDetectionItem.Text = runtime.DetectionPaused
                    ? "Resume detection"
                    : "Pause detection";
                PollRuntime();
            };
            menu.Items.Add(pauseDetectionItem);

            menu.Items.Add(new ToolStripSeparator());
            ToolStripItem exit = menu.Items.Add("Exit");
            exit.Click += (sender, args) =>
            {
                logger.Info("Tray exit requested.");
                ExitThread();
            };

            menu.Opening += (sender, args) => RefreshBrokerStatus();

            return menu;
        }

        private ToolStripMenuItem CreatePolicyMenu(string title, PresencePolicy policy)
        {
            var root = new ToolStripMenuItem(title);
            var watchAndPhone = new ToolStripMenuItem("Watch + phone")
            {
                Checked = policy.Mode == PresenceMode.WatchAndPhone
            };
            var phoneOnly = new ToolStripMenuItem("Phone only")
            {
                Checked = policy.Mode == PresenceMode.PhoneOnly
            };

            watchAndPhone.Click += (sender, args) =>
                SetPolicyMode(title, policy, PresenceMode.WatchAndPhone, watchAndPhone, phoneOnly);
            phoneOnly.Click += (sender, args) =>
                SetPolicyMode(title, policy, PresenceMode.PhoneOnly, watchAndPhone, phoneOnly);
            root.DropDownItems.Add(watchAndPhone);
            root.DropDownItems.Add(phoneOnly);
            return root;
        }

        private ToolStripMenuItem CreateSystemActionMenu()
        {
            var root = new ToolStripMenuItem("System actions");
            wakeActionItem = new ToolStripMenuItem("Wake login page")
            {
                Checked = settings.Actions.Wake.Enabled,
                CheckOnClick = false
            };
            autoLockActionItem = new ToolStripMenuItem("Lock when devices leave")
            {
                Checked = settings.Actions.AutoLock.Enabled,
                CheckOnClick = false
            };
            autoUnlockActionItem = new ToolStripMenuItem("Automatic unlock")
            {
                Checked = settings.AutoUnlock.Enabled,
                CheckOnClick = false
            };
            wakeActionItem.Click += (sender, args) =>
                SetActionEnabled("wake", !settings.Actions.Wake.Enabled);
            autoUnlockActionItem.Click += (sender, args) =>
                SetActionEnabled("auto-unlock", !settings.AutoUnlock.Enabled);
            autoLockActionItem.Click += (sender, args) =>
                SetActionEnabled("auto-lock", !settings.Actions.AutoLock.Enabled);
            root.DropDownItems.Add(wakeActionItem);
            root.DropDownItems.Add(autoUnlockActionItem);
            root.DropDownItems.Add(autoLockActionItem);
            return root;
        }

        private void SetActionEnabled(string actionName, bool enabled)
        {
            if (enabled)
            {
                if (actionName == "auto-unlock" &&
                    !capabilities.RefreshUnlockBrokerAvailability())
                {
                    MessageBox.Show(
                        "The LocalSystem automatic-unlock Broker is not running.",
                        "BLE Proximity Wake",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
                    return;
                }

                string consequence;
                if (actionName == "wake")
                {
                    consequence =
                        "The Agent will send display and input requests after a confirmed arrival.";
                }
                else if (actionName == "auto-unlock")
                {
                    consequence =
                        "Windows credentials stored by the installed Broker/Provider may be submitted automatically. " +
                        "Normal password, PIN, and Windows Hello sign-in must already be verified.";
                }
                else
                {
                    consequence =
                        "Windows will lock after all required devices are absent and the idle threshold is met.";
                }

                DialogResult confirmation = MessageBox.Show(
                    consequence + Environment.NewLine + Environment.NewLine +
                    "Enable this system action?",
                    "BLE Proximity Wake",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button2);
                if (confirmation != DialogResult.Yes)
                {
                    return;
                }
            }

            if (actionName == "wake")
            {
                settings.Actions.Wake.Enabled = enabled;
                wakeActionItem.Checked = enabled;
            }
            else if (actionName == "auto-unlock")
            {
                settings.AutoUnlock.Enabled = enabled;
                autoUnlockActionItem.Checked = enabled;
            }
            else
            {
                settings.Actions.AutoLock.Enabled = enabled;
                autoLockActionItem.Checked = enabled;
            }

            settingsStore.Save(settings);
            logger.Info("System action changed. Action=" + actionName + " Enabled=" + enabled);
            RestartRuntime();
        }

        private void SetPolicyMode(
            string policyName,
            PresencePolicy policy,
            PresenceMode mode,
            ToolStripMenuItem watchAndPhone,
            ToolStripMenuItem phoneOnly)
        {
            policy.Mode = mode;
            settingsStore.Save(settings);
            watchAndPhone.Checked = mode == PresenceMode.WatchAndPhone;
            phoneOnly.Checked = mode == PresenceMode.PhoneOnly;
            logger.Info("Presence policy changed. Policy=" + policyName + " Mode=" + mode);
        }

        private string BuildDiagnosticText()
        {
            RefreshBrokerStatus();
            return string.Join(
                Environment.NewLine,
                "BLE Proximity Wake EXE Agent",
                "Time: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
                capabilities.ToDiagnosticText(),
                "Wake presence: " + settings.PresencePolicies.Wake.Mode,
                "Auto-unlock presence: " + settings.PresencePolicies.AutoUnlock.Mode,
                "Auto-lock presence: " + settings.PresencePolicies.AutoLock.Mode,
                "Wake action: " + settings.Actions.Wake.Enabled,
                "Auto-unlock action: " + settings.AutoUnlock.Enabled,
                "Auto-unlock triggers: arrival=" +
                    settings.AutoUnlock.TriggerOnArrival +
                    " interactive=" +
                    settings.AutoUnlock.TriggerOnInteractiveWake,
                "Auto-lock action: " + settings.Actions.AutoLock.Enabled,
                "Action state: " + (runtimeStatus == null
                    ? "unknown"
                    : runtimeStatus.ActionDecision.Action + "/" +
                      runtimeStatus.ActionDecision.Reason +
                      " wakeArmed=" + runtimeStatus.ActionDecision.WakeArmed +
                      " autoLockArmed=" + runtimeStatus.ActionDecision.AutoLockArmed),
                "Auto-unlock state: " + (runtimeStatus == null
                    ? "unknown"
                    : runtimeStatus.AutoUnlock.State +
                      " cycle=" + runtimeStatus.AutoUnlock.LockCycleId +
                      " attempted=" + runtimeStatus.AutoUnlock.Attempted +
                      " retries=" + runtimeStatus.AutoUnlock.RetryCount +
                      " broker=" + runtimeStatus.AutoUnlock.BrokerStatus),
                "Interactive wake: " + (runtimeStatus == null
                    ? "unknown"
                    : runtimeStatus.InteractiveWake.State +
                      " trigger=" + runtimeStatus.InteractiveWake.Trigger +
                      " pending=" + runtimeStatus.InteractiveWake.Pending),
                "Detection: " + (runtimeStatus == null
                    ? "not started"
                    : runtimeStatus.WatcherStatus + "/" + runtimeStatus.ScanProfile.Mode),
                "Network: " + (runtimeStatus == null
                    ? "unknown"
                    : runtimeStatus.Conditions.Network.Allowed + " " +
                      runtimeStatus.Conditions.Network.Reason),
                "Settings: " + settingsStore.Path,
                "Log: " + logger.FilePath);
        }

        private void RefreshBrokerStatus()
        {
            bool available = capabilities.RefreshUnlockBrokerAvailability();
            if (brokerStatusItem != null)
            {
                brokerStatusItem.Text = available
                    ? "Auto unlock Broker: Available"
                    : "Auto unlock Broker: Unavailable";
            }
        }

        private void PollRuntime()
        {
            if (runtime == null || trayResourcesDisposed)
            {
                return;
            }

            try
            {
                runtimeStatus = runtime.Poll();
                pollTimer.Interval = runtimeStatus.ScanProfile.PollIntervalMilliseconds;
                detectionStatusItem.Text = string.Format(
                    "Detection: {0}/{1} | Net={2} AC={3} Display={4}",
                    runtimeStatus.WatcherStatus,
                    runtimeStatus.ScanProfile.Mode,
                    runtimeStatus.Conditions.Network.Allowed,
                    runtimeStatus.Conditions.AcPowerConnected,
                    runtimeStatus.Conditions.DisplayState);
                deviceStatusItem.Text = string.Format(
                    "Devices: watch {0} ({1} dBm) | phone {2} ({3} dBm)",
                    runtimeStatus.Presence.Observation.WatchReady ? "near" : "not ready",
                    runtimeStatus.Presence.LastWatchRssi,
                    runtimeStatus.Presence.Observation.PhoneReady ? "near" : "not ready",
                    runtimeStatus.Presence.LastPhoneRssi);
                actionStatusItem.Text = string.Format(
                    "Actions: wake {0} | unlock {1} | auto-lock {2} | {3}",
                    settings.Actions.Wake.Enabled ? "on" : "off",
                    settings.AutoUnlock.Enabled
                        ? runtimeStatus.AutoUnlock.State
                        : "off",
                     settings.Actions.AutoLock.Enabled ? "on" : "off",
                     runtimeStatus.ActionDecision.Reason);
                pauseDetectionItem.Enabled = runtime.CanPauseDetection;
                pauseDetectionItem.ToolTipText = runtime.CanPauseDetection
                    ? string.Empty
                    : "Wait for the current automatic-unlock request to finish.";
                notifyIcon.Text = string.Format(
                    "BLE Proximity Wake | {0} | W={1} P={2}",
                    runtimeStatus.ScanProfile.Mode,
                    runtimeStatus.Presence.Observation.WatchReady,
                    runtimeStatus.Presence.Observation.PhoneReady);
            }
            catch (Exception exception)
            {
                logger.Error("EXE detection poll failed: " + exception);
                detectionStatusItem.Text = "Detection: error (see log)";
                pollTimer.Interval = 5000;
            }
        }

        private void RestartRuntime()
        {
            pollTimer.Stop();
            runtime?.Dispose();
            runtime = null;
            runtimeStatus = null;
            if (!settings.Ble.Enabled || !capabilities.BleAdvertisementApiAvailable)
            {
                return;
            }

            try
            {
                runtime = new AgentRuntime(settings, logger);
                pollTimer.Interval = settings.Ble.BackgroundPollIntervalMilliseconds;
                pollTimer.Start();
                PollRuntime();
            }
            catch (Exception exception)
            {
                runtime?.Dispose();
                runtime = null;
                detectionStatusItem.Text = "Detection: initialization failed (see log)";
                logger.Error("EXE detection restart failed: " + exception);
            }
        }

        protected override void ExitThreadCore()
        {
            DisposeTrayResources();
            base.ExitThreadCore();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                DisposeTrayResources();
            }

            base.Dispose(disposing);
        }

        private void DisposeTrayResources()
        {
            if (trayResourcesDisposed)
            {
                return;
            }

            trayResourcesDisposed = true;
            pollTimer.Stop();
            pollTimer.Dispose();
            if (runtime != null)
            {
                runtime.Dispose();
                runtime = null;
            }
            notifyIcon.Visible = false;
            notifyIcon.Dispose();
            contextMenu.Dispose();
            icon.Dispose();
        }
    }
}
