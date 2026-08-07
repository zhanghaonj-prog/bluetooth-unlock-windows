using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace BleProximityWake.Agent.Diagnostics
{
    internal sealed class FileLogger : IDisposable
    {
        private readonly object sync = new object();
        private readonly StreamWriter writer;

        internal FileLogger(string logDirectory)
        {
            Directory.CreateDirectory(logDirectory);
            FilePath = System.IO.Path.Combine(
                logDirectory,
                "ble-proximity-wake-agent-" + DateTime.Now.ToString("yyyyMMdd", CultureInfo.InvariantCulture) + ".log");
            writer = new StreamWriter(FilePath, true, new UTF8Encoding(false))
            {
                AutoFlush = true
            };
        }

        internal string FilePath { get; }

        internal void Info(string message)
        {
            Write("INFO", message);
        }

        internal void Warn(string message)
        {
            Write("WARN", message);
        }

        internal void Error(string message)
        {
            Write("ERROR", message);
        }

        private void Write(string level, string message)
        {
            lock (sync)
            {
                writer.WriteLine(
                    "{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}",
                    DateTime.Now,
                    level,
                    message);
            }
        }

        public void Dispose()
        {
            lock (sync)
            {
                writer.Dispose();
            }
        }
    }
}
