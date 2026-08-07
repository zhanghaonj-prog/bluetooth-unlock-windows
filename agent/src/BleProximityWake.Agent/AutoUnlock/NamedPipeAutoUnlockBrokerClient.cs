using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using BleProximityWake.Agent.Configuration;

namespace BleProximityWake.Agent.AutoUnlock
{
    internal sealed class NamedPipeAutoUnlockBrokerClient : IAutoUnlockBrokerClient
    {
        private readonly string pipeName;
        private readonly int responseTimeoutMilliseconds;

        internal NamedPipeAutoUnlockBrokerClient(AutoUnlockSettings settings)
            : this(
                AutoUnlockBrokerProtocol.AgentPipeName,
                settings == null ? 0 : settings.ResponseTimeoutMilliseconds)
        {
            if (settings == null)
            {
                throw new ArgumentNullException("settings");
            }
        }

        internal NamedPipeAutoUnlockBrokerClient(
            string pipeName,
            int responseTimeoutMilliseconds)
        {
            if (string.IsNullOrWhiteSpace(pipeName))
            {
                throw new ArgumentException("Pipe name is required.", "pipeName");
            }

            this.pipeName = pipeName;
            this.responseTimeoutMilliseconds = responseTimeoutMilliseconds;
        }

        public AutoUnlockBrokerResult Authorize(
            ulong lockCycleId,
            int authorizationTtlMilliseconds)
        {
            Guid requestId = Guid.NewGuid();
            var request = new AutoUnlockAuthorizationRequest
            {
                SessionId = Process.GetCurrentProcess().SessionId,
                AuthorizationTtlMilliseconds = checked((uint)authorizationTtlMilliseconds),
                LockCycleId = lockCycleId,
                RequestId = requestId,
                UserSid = WindowsIdentity.GetCurrent().User.Value
            };
            byte[] payload = AutoUnlockBrokerProtocol.BuildAuthorizePayload(request);
            var stopwatch = Stopwatch.StartNew();
            try
            {
                using (var pipe = new NamedPipeClientStream(
                    ".",
                    pipeName,
                    PipeDirection.InOut,
                    PipeOptions.Asynchronous,
                    TokenImpersonationLevel.Impersonation))
                {
                    pipe.Connect(Math.Min(2000, responseTimeoutMilliseconds));
                    using (var writer = new BinaryWriter(pipe, Encoding.Unicode, true))
                    {
                        writer.Write(AutoUnlockBrokerProtocol.Magic);
                        writer.Write(AutoUnlockBrokerProtocol.Version);
                        writer.Write(AutoUnlockBrokerProtocol.AuthorizeMessageType);
                        writer.Write((uint)payload.Length);
                        writer.Write(payload);
                        writer.Flush();
                    }

                    byte[] response = ReadExactly(
                        pipe,
                        16,
                        responseTimeoutMilliseconds);
                    try
                    {
                        using (var stream = new MemoryStream(response, false))
                        using (var reader = new BinaryReader(stream))
                        {
                            uint magic = reader.ReadUInt32();
                            uint version = reader.ReadUInt32();
                            uint status = reader.ReadUInt32();
                            uint responseBytes = reader.ReadUInt32();
                            if (magic != AutoUnlockBrokerProtocol.Magic ||
                                version != AutoUnlockBrokerProtocol.Version ||
                                responseBytes != 0 ||
                                !Enum.IsDefined(typeof(AutoUnlockBrokerStatus), status))
                            {
                                throw new InvalidDataException(
                                    "Broker returned an invalid protocol response.");
                            }

                            return new AutoUnlockBrokerResult
                            {
                                Status = (AutoUnlockBrokerStatus)status,
                                RequestId = requestId,
                                ElapsedMilliseconds = stopwatch.Elapsed.TotalMilliseconds
                            };
                        }
                    }
                    finally
                    {
                        Array.Clear(response, 0, response.Length);
                    }
                }
            }
            finally
            {
                Array.Clear(payload, 0, payload.Length);
            }
        }

        private static byte[] ReadExactly(
            Stream stream,
            int count,
            int timeoutMilliseconds)
        {
            var result = new byte[count];
            int offset = 0;
            var stopwatch = Stopwatch.StartNew();
            while (offset < count)
            {
                int remaining = timeoutMilliseconds - (int)stopwatch.ElapsedMilliseconds;
                if (remaining <= 0)
                {
                    throw new TimeoutException("Timed out waiting for the Broker response.");
                }

                var task = stream.ReadAsync(result, offset, count - offset);
                if (!task.Wait(remaining))
                {
                    throw new TimeoutException("Timed out waiting for the Broker response.");
                }

                int read = task.Result;
                if (read <= 0)
                {
                    throw new EndOfStreamException(
                        "Broker closed the pipe before returning a complete response.");
                }

                offset += read;
            }

            return result;
        }
    }
}
