using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;
using BleProximityWake.Agent.Configuration;
using BleProximityWake.Agent.Diagnostics;
using BleProximityWake.Agent.Tray;

namespace BleProximityWake.Agent
{
    internal static class Program
    {
        private const string MutexName = "Local\\BleProximityWake.Agent.UserSession";

        [STAThread]
        private static int Main(string[] args)
        {
            bool createdNew;
            using (var mutex = new Mutex(true, MutexName, out createdNew))
            {
                if (!createdNew)
                {
                    return 2;
                }

                try
                {
                    string dataDirectory = Environment.GetEnvironmentVariable("BLE_PROXIMITY_WAKE_DATA_DIR");
                    if (string.IsNullOrWhiteSpace(dataDirectory))
                    {
                        dataDirectory = Path.Combine(
                            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                            "BleProximityWake");
                    }
                    string settingsPath = Path.Combine(dataDirectory, "agent-settings.json");
                    string logDirectory = Path.Combine(dataDirectory, "logs");
                    bool smokeTest = args.Any(
                        value => string.Equals(value, "--smoke-test", StringComparison.OrdinalIgnoreCase));
                    bool importOnly = args.Any(
                        value => string.Equals(value, "--import-only", StringComparison.OrdinalIgnoreCase));
                    int observeSeconds = ReadPositiveIntArgument(args, "--observe-seconds");
                    bool headless = smokeTest || importOnly || observeSeconds > 0;
                    int exitCode = 0;

                    using (var logger = new FileLogger(logDirectory))
                    {
                        try
                        {
                            logger.Info("EXE Agent starting. Settings=" + settingsPath);
                            var settingsStore = new AgentSettingsStore(settingsPath);
                            AgentSettings settings = settingsStore.Load();
                            string legacyConfigPath = ReadArgumentValue(
                                args,
                                "--import-legacy-config");
                            if (!string.IsNullOrWhiteSpace(legacyConfigPath))
                            {
                                settings = LegacyConfigImporter.Import(legacyConfigPath, settings);
                                settingsStore.Save(settings);
                                logger.Info("Legacy PowerShell configuration imported: " + legacyConfigPath);
                            }
                            else if (importOnly)
                            {
                                throw new InvalidOperationException(
                                    "--import-only requires --import-legacy-config <path>.");
                            }

                            CapabilitySnapshot capabilities = CapabilitySnapshot.Capture();
                            logger.Info("Capabilities: " + capabilities.ToDiagnosticText().Replace(Environment.NewLine, "; "));

                            if (observeSeconds > 0)
                            {
                                if (!capabilities.BleAdvertisementApiAvailable)
                                {
                                    throw new InvalidOperationException(
                                        "BLE advertisement API is unavailable.");
                                }

                                RunObservation(settings, logger, observeSeconds);
                            }
                            else if (smokeTest || importOnly)
                            {
                                logger.Info(importOnly
                                    ? "Legacy configuration import completed."
                                    : "Smoke test completed.");
                            }
                            else
                            {
                                Application.EnableVisualStyles();
                                Application.SetCompatibleTextRenderingDefault(false);
                                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                                Application.ThreadException += (sender, eventArgs) =>
                                    logger.Error("UI exception: " + eventArgs.Exception);

                                using (var context = new TrayApplicationContext(
                                    settings,
                                    settingsStore,
                                    capabilities,
                                    logger,
                                    dataDirectory))
                                {
                                    Application.Run(context);
                                }
                            }
                        }
                        catch (Exception exception)
                        {
                            exitCode = 1;
                            logger.Error("Fatal startup error: " + exception);
                            if (!headless)
                            {
                                MessageBox.Show(
                                    "BLE Proximity Wake Agent could not start." +
                                    Environment.NewLine + exception.Message,
                                    "BLE Proximity Wake",
                                    MessageBoxButtons.OK,
                                    MessageBoxIcon.Error);
                            }
                        }
                        finally
                        {
                            logger.Info("EXE Agent stopped.");
                        }
                    }

                    return exitCode;
                }
                finally
                {
                    mutex.ReleaseMutex();
                }
            }
        }

        private static string ReadArgumentValue(string[] args, string name)
        {
            for (int index = 0; index < args.Length - 1; index++)
            {
                if (string.Equals(args[index], name, StringComparison.OrdinalIgnoreCase))
                {
                    return args[index + 1];
                }
            }

            return string.Empty;
        }

        private static int ReadPositiveIntArgument(string[] args, string name)
        {
            string value = ReadArgumentValue(args, name);
            if (string.IsNullOrWhiteSpace(value))
            {
                return 0;
            }

            if (!int.TryParse(value, out int result) || result <= 0 || result > 3600)
            {
                throw new InvalidOperationException(
                    name + " must be an integer between 1 and 3600.");
            }

            return result;
        }

        private static void RunObservation(
            AgentSettings settings,
            FileLogger logger,
            int seconds)
        {
            logger.Info("EXE BLE observation starting. DurationSeconds=" + seconds);
            DateTime deadlineUtc = DateTime.UtcNow.AddSeconds(seconds);
            using (var runtime = new Runtime.AgentRuntime(settings, logger))
            {
                while (DateTime.UtcNow < deadlineUtc)
                {
                    Runtime.AgentRuntimeStatus status = runtime.Poll();
                    Application.DoEvents();
                    Thread.Sleep(Math.Min(status.ScanProfile.PollIntervalMilliseconds, 250));
                }
            }

            logger.Info("EXE BLE observation completed.");
        }
    }
}
