using System;
using System.IO;
using System.Text;

namespace BleProximityWake.Agent.AutoUnlock
{
    internal static class AutoUnlockBrokerProtocol
    {
        internal const string AgentPipeName = "BleProximityWake.UnlockAgent";

        internal const uint Magic = 0x42505742;
        internal const uint Version = 1;
        internal const uint AuthorizeMessageType = 1;
        internal const int MaximumPayloadBytes = 4096;

        internal static byte[] BuildAuthorizePayload(AutoUnlockAuthorizationRequest request)
        {
            if (request == null)
            {
                throw new ArgumentNullException("request");
            }

            if (request.SessionId < 0 ||
                request.AuthorizationTtlMilliseconds < 1000 ||
                request.AuthorizationTtlMilliseconds > 10000 ||
                request.LockCycleId == 0 ||
                request.RequestId == Guid.Empty ||
                string.IsNullOrWhiteSpace(request.UserSid))
            {
                throw new InvalidOperationException("Invalid auto-unlock authorization request.");
            }

            byte[] sidBytes = Encoding.Unicode.GetBytes(request.UserSid);
            try
            {
                if (36 + sidBytes.Length > MaximumPayloadBytes)
                {
                    throw new InvalidOperationException("Auto-unlock SID payload is too large.");
                }

                using (var stream = new MemoryStream())
                using (var writer = new BinaryWriter(stream, Encoding.Unicode))
                {
                    writer.Write(request.SessionId);
                    writer.Write(request.AuthorizationTtlMilliseconds);
                    writer.Write(request.LockCycleId);
                    writer.Write(request.RequestId.ToByteArray());
                    writer.Write((uint)request.UserSid.Length);
                    writer.Write(sidBytes);
                    writer.Flush();
                    return stream.ToArray();
                }
            }
            finally
            {
                Array.Clear(sidBytes, 0, sidBytes.Length);
            }
        }
    }
}
