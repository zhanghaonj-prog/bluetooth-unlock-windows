using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Threading;

internal static class Protocol
{
    internal const uint Magic = 0x42505742;
    internal const uint Version = 1;
    internal const int MaximumPayloadBytes = 4096;
    internal const string AgentPipeName = "BleProximityWake.UnlockAgent";
    internal const string ProviderPipeName = "BleProximityWake.UnlockProvider";

    internal enum MessageType : uint
    {
        Authorize = 1,
        Peek = 2,
        Consume = 3,
        ReportResult = 4
    }

    internal enum Status : uint
    {
        Ok = 0,
        InvalidRequest = 1,
        AccessDenied = 2,
        NotConfigured = 3,
        SessionNotLocked = 4,
        AlreadyAttempted = 5,
        NoAuthorization = 6,
        AuthorizationExpired = 7,
        ProviderUnavailable = 8,
        CredentialUnavailable = 9,
        InternalError = 10
    }
}

internal sealed class AuthorizationState
{
    internal bool Active;
    internal bool Consuming;
    internal Guid AuthorizationId;
    internal string UserSid;
    internal int SessionId;
    internal ulong LockCycleId;
    internal long ExpiresAtTicks;
    internal long AcceptedAtTicks;
    internal ulong LastConsumedLockCycleId;
    internal Guid LastConsumedAuthorizationId;
    internal long LastConsumedAcceptedAtTicks;
    internal long LastConsumedAtTicks;

    internal void ClearActive()
    {
        Active = false;
        Consuming = false;
        AuthorizationId = Guid.Empty;
        UserSid = null;
        SessionId = 0;
        LockCycleId = 0;
        ExpiresAtTicks = 0;
        AcceptedAtTicks = 0;
    }
}

internal sealed class BrokerService : ServiceBase
{
    private const string ServiceNameValue = "BleProximityUnlockBroker";
    private const string ConfigKey = @"SOFTWARE\BleProximityWake\CredentialProviderP0";
    private const string AuthorizationEventName = @"Global\BleProximityCredentialProvider.P0.Authorization";
    private const int AgentRequestTimeoutMilliseconds = 4000;
    private const int ProviderRequestTimeoutMilliseconds = 1500;
    private const int WtsConnectState = 8;
    private const int WtsActive = 0;
    private static readonly string DataDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "BleProximityWake");
    private static readonly string CredentialFile = Path.Combine(DataDirectory, "credential.dat");
    private static readonly string LogFile = Path.Combine(DataDirectory, "unlock-broker.log");
    private static readonly int ProcessId = Process.GetCurrentProcess().Id;

    private readonly object stateLock = new object();
    private readonly AuthorizationState authorization = new AuthorizationState();
    private readonly ManualResetEvent stopEvent = new ManualResetEvent(false);
    private Thread agentThread;
    private Thread providerThread;

    internal BrokerService()
    {
        ServiceName = ServiceNameValue;
        CanStop = true;
        AutoLog = false;
    }

    protected override void OnStart(string[] args)
    {
        StartWorkers();
    }

    protected override void OnStop()
    {
        StopWorkers();
    }

    internal void RunConsole()
    {
        StartWorkers();
        Console.WriteLine("Broker console mode is running. Press ENTER to stop.");
        Console.ReadLine();
        StopWorkers();
    }

    private void StartWorkers()
    {
        Directory.CreateDirectory(DataDirectory);
        stopEvent.Reset();
        agentThread = new Thread(AgentLoop) { IsBackground = true, Name = "AgentPipe" };
        providerThread = new Thread(ProviderLoop) { IsBackground = true, Name = "ProviderPipe" };
        agentThread.Start();
        providerThread.Start();
        Log("Broker started");
    }

    private void StopWorkers()
    {
        stopEvent.Set();
        WakePipe(Protocol.AgentPipeName);
        WakePipe(Protocol.ProviderPipeName);
        if (agentThread != null) agentThread.Join(5000);
        if (providerThread != null) providerThread.Join(5000);
        lock (stateLock) authorization.ClearActive();
        Log("Broker stopped");
    }

    private static void WakePipe(string name)
    {
        try
        {
            using (var client = new NamedPipeClientStream(".", name, PipeDirection.InOut))
            {
                client.Connect(200);
            }
        }
        catch (Exception)
        {
        }
    }

    private void AgentLoop()
    {
        RunPipeLoop(Protocol.AgentPipeName, false, AgentRequestTimeoutMilliseconds, HandleAgentRequest);
    }

    private void ProviderLoop()
    {
        RunPipeLoop(Protocol.ProviderPipeName, true, ProviderRequestTimeoutMilliseconds, HandleProviderRequest);
    }

    private void RunPipeLoop(
        string pipeName,
        bool systemOnly,
        int requestTimeoutMilliseconds,
        Action<NamedPipeServerStream> handler)
    {
        while (!stopEvent.WaitOne(0))
        {
            try
            {
                using (var pipe = CreatePipe(pipeName, systemOnly))
                {
                    pipe.WaitForConnection();
                    if (stopEvent.WaitOne(0)) continue;

                    Exception handlerException = null;
                    using (var completed = new ManualResetEvent(false))
                    {
                        var requestThread = new Thread(new ThreadStart(delegate
                        {
                            try
                            {
                                handler(pipe);
                            }
                            catch (Exception exception)
                            {
                                handlerException = exception;
                            }
                            finally
                            {
                                try { completed.Set(); }
                                catch (ObjectDisposedException) { }
                            }
                        })) { IsBackground = true, Name = pipeName + ".Request" };
                        requestThread.Start();

                        int waitResult = WaitHandle.WaitAny(
                            new WaitHandle[] { completed, stopEvent },
                            requestTimeoutMilliseconds);
                        if (waitResult != 0)
                        {
                            Log(pipeName + (waitResult == WaitHandle.WaitTimeout
                                ? " request timed out"
                                : " request cancelled during service stop"));
                            pipe.Dispose();
                            requestThread.Join(1000);
                            continue;
                        }
                    }
                    if (handlerException != null) throw handlerException;
                }
            }
            catch (Exception exception)
            {
                if (!stopEvent.WaitOne(0)) Log(pipeName + " error: " + exception.GetType().Name);
            }
        }
    }

    private static NamedPipeServerStream CreatePipe(string name, bool systemOnly)
    {
        var security = new PipeSecurity();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.FullControl,
            AccessControlType.Allow));
        if (!systemOnly)
        {
            security.AddAccessRule(new PipeAccessRule(
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
                PipeAccessRights.FullControl,
                AccessControlType.Allow));
            string configuredSid;
            string ignoredUsername;
            string ignoredDomain;
            if (TryReadConfiguration(out configuredSid, out ignoredUsername, out ignoredDomain))
            {
                security.AddAccessRule(new PipeAccessRule(
                    new SecurityIdentifier(configuredSid),
                    PipeAccessRights.ReadWrite,
                    AccessControlType.Allow));
            }
        }
        return new NamedPipeServerStream(
            name,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous,
            4096,
            4096,
            security);
    }

    private void HandleAgentRequest(NamedPipeServerStream pipe)
    {
        using (var reader = new BinaryReader(pipe, Encoding.Unicode, true))
        using (var writer = new BinaryWriter(pipe, Encoding.Unicode, true))
        {
            string callerSid;
            int callerSession;
            string callerImagePath;
            if (!GetClientIdentity(
                pipe.SafePipeHandle,
                out callerSid,
                out callerSession,
                out callerImagePath))
            {
                WriteResponse(writer, Protocol.Status.AccessDenied, null);
                return;
            }
            string configuredSid;
            string ignoredUsername;
            string ignoredDomain;
            if (!TryReadConfiguration(out configuredSid, out ignoredUsername, out ignoredDomain) ||
                !String.Equals(configuredSid, callerSid, StringComparison.OrdinalIgnoreCase))
            {
                WriteResponse(writer, Protocol.Status.AccessDenied, null);
                return;
            }
            if (!IsTrustedAgentImage(callerImagePath))
            {
                Log("Agent request denied for untrusted process image");
                WriteResponse(writer, Protocol.Status.AccessDenied, null);
                return;
            }

            Protocol.MessageType type;
            byte[] payload;
            if (!ReadMessage(reader, out type, out payload) || type != Protocol.MessageType.Authorize)
            {
                WriteResponse(writer, Protocol.Status.InvalidRequest, null);
                return;
            }

            Protocol.Status status = Authorize(payload, callerSid, callerSession);
            WriteResponse(writer, status, null);
        }
    }

    private Protocol.Status Authorize(byte[] payload, string callerSid, int callerSession)
    {
        try
        {
            using (var reader = new BinaryReader(new MemoryStream(payload), Encoding.Unicode))
            {
                int requestedSession = reader.ReadInt32();
                uint ttl = reader.ReadUInt32();
                ulong lockCycle = reader.ReadUInt64();
                Guid requestId = new Guid(reader.ReadBytes(16));
                string requestedSid = ReadString(reader);
                if (reader.BaseStream.Position != reader.BaseStream.Length ||
                    requestedSession != callerSession ||
                    !String.Equals(requestedSid, callerSid, StringComparison.OrdinalIgnoreCase) ||
                    ttl < 1000 || ttl > 10000 || requestId == Guid.Empty || lockCycle == 0)
                {
                    return Protocol.Status.InvalidRequest;
                }

                string configuredSid;
                string ignoredUsername;
                string ignoredDomain;
                if (!TryReadConfiguration(out configuredSid, out ignoredUsername, out ignoredDomain))
                    return Protocol.Status.NotConfigured;
                if (!String.Equals(configuredSid, requestedSid, StringComparison.OrdinalIgnoreCase))
                    return Protocol.Status.AccessDenied;
                if (!IsSessionLocked(requestedSession))
                    return Protocol.Status.SessionNotLocked;

                lock (stateLock)
                {
                    if (authorization.LastConsumedLockCycleId == lockCycle ||
                        ((authorization.Active || authorization.Consuming) &&
                         authorization.LockCycleId == lockCycle))
                        return Protocol.Status.AlreadyAttempted;
                    authorization.Active = true;
                    authorization.AuthorizationId = Guid.NewGuid();
                    authorization.UserSid = requestedSid;
                    authorization.SessionId = requestedSession;
                    authorization.LockCycleId = lockCycle;
                    authorization.AcceptedAtTicks = DateTime.UtcNow.Ticks;
                    authorization.ExpiresAtTicks = DateTime.UtcNow.AddMilliseconds(ttl).Ticks;
                }

                Guid authorizationId;
                lock (stateLock) authorizationId = authorization.AuthorizationId;
                if (!TrySignalProviderAuthorizationEvent())
                {
                    lock (stateLock) authorization.ClearActive();
                    return Protocol.Status.ProviderUnavailable;
                }

                Log("Authorization accepted Authorization=" + authorizationId +
                    " Session=" + requestedSession + " LockCycle=" + lockCycle);
                QueueProviderAuthorizationRetries(authorizationId);
                return Protocol.Status.Ok;
            }
        }
        catch (Exception)
        {
            return Protocol.Status.InvalidRequest;
        }
    }

    private static bool TrySignalProviderAuthorizationEvent()
    {
        try
        {
            using (var signal = EventWaitHandle.OpenExisting(AuthorizationEventName))
            {
                return signal.Set();
            }
        }
        catch (WaitHandleCannotBeOpenedException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private void QueueProviderAuthorizationRetries(Guid authorizationId)
    {
        ThreadPool.QueueUserWorkItem(delegate
        {
            int[] waits = GetProviderAuthorizationRetryWaits();
            int elapsed = 0;
            foreach (int wait in waits)
            {
                if (stopEvent.WaitOne(wait)) return;
                elapsed += wait;

                lock (stateLock)
                {
                    if (!authorization.Active ||
                        authorization.AuthorizationId != authorizationId ||
                        authorization.ExpiresAtTicks < DateTime.UtcNow.Ticks)
                    {
                        return;
                    }
                }

                if (TrySignalProviderAuthorizationEvent())
                {
                    Log("Provider authorization notification repeated DelayMs=" + elapsed);
                }
            }
        });
    }

    private static int[] GetProviderAuthorizationRetryWaits()
    {
        return new[] { 250, 250, 500, 750, 1000 };
    }

    private void HandleProviderRequest(NamedPipeServerStream pipe)
    {
        using (var reader = new BinaryReader(pipe, Encoding.Unicode, true))
        using (var writer = new BinaryWriter(pipe, Encoding.Unicode, true))
        {
            string callerSid;
            int callerSession;
            string ignoredImagePath;
            if (!GetClientIdentity(
                pipe.SafePipeHandle,
                out callerSid,
                out callerSession,
                out ignoredImagePath) ||
                callerSid != "S-1-5-18")
            {
                WriteResponse(writer, Protocol.Status.AccessDenied, null);
                return;
            }

            Protocol.MessageType type;
            byte[] payload;
            if (!ReadMessage(reader, out type, out payload))
            {
                WriteResponse(writer, Protocol.Status.InvalidRequest, null);
                return;
            }

            if (type == Protocol.MessageType.Peek)
                HandlePeek(writer, payload, callerSession);
            else if (type == Protocol.MessageType.Consume)
                HandleConsume(writer, payload, callerSession);
            else if (type == Protocol.MessageType.ReportResult)
                HandleReport(writer, payload);
            else
                WriteResponse(writer, Protocol.Status.InvalidRequest, null);
        }
    }

    private void HandlePeek(BinaryWriter writer, byte[] payload, int callerSession)
    {
        string sid;
        if (!TryReadOnlyString(payload, out sid))
        {
            WriteResponse(writer, Protocol.Status.InvalidRequest, null);
            return;
        }
        lock (stateLock)
        {
            WriteResponse(writer, GetAuthorizationStatus(sid, callerSession), null);
        }
    }

    private void HandleConsume(BinaryWriter writer, byte[] payload, int callerSession)
    {
        string sid;
        if (!TryReadOnlyString(payload, out sid))
        {
            WriteResponse(writer, Protocol.Status.InvalidRequest, null);
            return;
        }

        Guid authorizationId;
        long acceptedAtTicks;
        bool committed = false;
        lock (stateLock)
        {
            Protocol.Status status = GetAuthorizationStatus(sid, callerSession);
            if (status != Protocol.Status.Ok)
            {
                WriteResponse(writer, status, null);
                return;
            }
            authorizationId = authorization.AuthorizationId;
            acceptedAtTicks = authorization.AcceptedAtTicks;
            authorization.Active = false;
            authorization.Consuming = true;
        }

        string configuredSid;
        string username;
        string domain;
        if (!TryReadConfiguration(out configuredSid, out username, out domain) ||
            !String.Equals(configuredSid, sid, StringComparison.OrdinalIgnoreCase))
        {
            RestoreConsumingAuthorization(authorizationId);
            WriteResponse(writer, Protocol.Status.NotConfigured, null);
            return;
        }

        byte[] clearPassword = null;
        byte[] domainBytes = Encoding.Unicode.GetBytes(domain);
        byte[] usernameBytes = Encoding.Unicode.GetBytes(username);
        try
        {
            byte[] encrypted = File.ReadAllBytes(CredentialFile);
            clearPassword = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.LocalMachine);
            Array.Clear(encrypted, 0, encrypted.Length);
            if (clearPassword.Length < 2 || clearPassword.Length % 2 != 0)
            {
                RestoreConsumingAuthorization(authorizationId);
                WriteResponse(writer, Protocol.Status.CredentialUnavailable, null);
                return;
            }

            int passwordCharacters = clearPassword.Length / 2;
            if (clearPassword[clearPassword.Length - 1] == 0 && clearPassword[clearPassword.Length - 2] == 0)
                passwordCharacters--;

            using (var stream = new MemoryStream())
            using (var payloadWriter = new BinaryWriter(stream, Encoding.Unicode, true))
            {
                payloadWriter.Write(authorizationId.ToByteArray());
                payloadWriter.Write((uint)(domainBytes.Length / 2));
                payloadWriter.Write((uint)(usernameBytes.Length / 2));
                payloadWriter.Write((uint)passwordCharacters);
                payloadWriter.Write(domainBytes);
                payloadWriter.Write(usernameBytes);
                payloadWriter.Write(clearPassword, 0, passwordCharacters * 2);
                byte[] response = stream.ToArray();
                try
                {
                    long consumedAtTicks = DateTime.UtcNow.Ticks;
                    lock (stateLock)
                    {
                        if (!authorization.Consuming ||
                            authorization.AuthorizationId != authorizationId)
                        {
                            throw new InvalidOperationException(
                                "Authorization consume transaction was replaced.");
                        }

                        authorization.LastConsumedLockCycleId = authorization.LockCycleId;
                        authorization.LastConsumedAuthorizationId = authorizationId;
                        authorization.LastConsumedAcceptedAtTicks = acceptedAtTicks;
                        authorization.LastConsumedAtTicks = consumedAtTicks;
                        authorization.ClearActive();
                        committed = true;
                    }
                    WriteResponse(writer, Protocol.Status.Ok, response);
                }
                finally
                {
                    Array.Clear(response, 0, response.Length);
                    Array.Clear(stream.GetBuffer(), 0, checked((int)stream.Length));
                }
            }
            double acceptedToConsumeMilliseconds = acceptedAtTicks <= 0
                ? -1
                : TimeSpan.FromTicks(DateTime.UtcNow.Ticks - acceptedAtTicks).TotalMilliseconds;
            Log("Authorization consumed Authorization=" + authorizationId +
                " AcceptedToConsumeMs=" + acceptedToConsumeMilliseconds.ToString("F0"));
        }
        catch (Exception exception)
        {
            if (!committed)
            {
                RestoreConsumingAuthorization(authorizationId);
            }
            Log("Credential consume failed: " + exception.GetType().Name);
            WriteResponse(writer, Protocol.Status.CredentialUnavailable, null);
        }
        finally
        {
            if (clearPassword != null) Array.Clear(clearPassword, 0, clearPassword.Length);
            Array.Clear(domainBytes, 0, domainBytes.Length);
            Array.Clear(usernameBytes, 0, usernameBytes.Length);
        }
    }

    private void HandleReport(BinaryWriter writer, byte[] payload)
    {
        if (payload.Length != 24)
        {
            WriteResponse(writer, Protocol.Status.InvalidRequest, null);
            return;
        }
        using (var reader = new BinaryReader(new MemoryStream(payload)))
        {
            Guid authorizationId = new Guid(reader.ReadBytes(16));
            int status = reader.ReadInt32();
            int substatus = reader.ReadInt32();
            long acceptedAtTicks = 0;
            long consumedAtTicks = 0;
            lock (stateLock)
            {
                if (authorization.LastConsumedAuthorizationId == authorizationId)
                {
                    acceptedAtTicks = authorization.LastConsumedAcceptedAtTicks;
                    consumedAtTicks = authorization.LastConsumedAtTicks;
                }
            }
            long reportedAtTicks = DateTime.UtcNow.Ticks;
            double acceptedToResultMilliseconds = acceptedAtTicks <= 0
                ? -1
                : TimeSpan.FromTicks(reportedAtTicks - acceptedAtTicks).TotalMilliseconds;
            double consumedToResultMilliseconds = consumedAtTicks <= 0
                ? -1
                : TimeSpan.FromTicks(reportedAtTicks - consumedAtTicks).TotalMilliseconds;
            Log("Authentication result Authorization=" + authorizationId +
                " Status=0x" + status.ToString("X8") +
                " Substatus=0x" + substatus.ToString("X8") +
                " AcceptedToResultMs=" + acceptedToResultMilliseconds.ToString("F0") +
                " ConsumedToResultMs=" + consumedToResultMilliseconds.ToString("F0"));
        }
        WriteResponse(writer, Protocol.Status.Ok, null);
    }

    private Protocol.Status GetAuthorizationStatus(string sid, int sessionId)
    {
        if (!authorization.Active) return Protocol.Status.NoAuthorization;
        if (authorization.ExpiresAtTicks < DateTime.UtcNow.Ticks)
        {
            authorization.ClearActive();
            return Protocol.Status.AuthorizationExpired;
        }
        if (!String.Equals(authorization.UserSid, sid, StringComparison.OrdinalIgnoreCase))
            return Protocol.Status.AccessDenied;
        if (authorization.SessionId != sessionId)
            return Protocol.Status.AccessDenied;
        return Protocol.Status.Ok;
    }

    private void RestoreConsumingAuthorization(Guid authorizationId)
    {
        lock (stateLock)
        {
            if (!authorization.Consuming ||
                authorization.AuthorizationId != authorizationId)
            {
                return;
            }

            if (authorization.ExpiresAtTicks < DateTime.UtcNow.Ticks)
            {
                authorization.ClearActive();
                return;
            }

            authorization.Consuming = false;
            authorization.Active = true;
        }
    }

    private static bool TryReadConfiguration(out string sid, out string username, out string domain)
    {
        sid = username = domain = null;
        using (RegistryKey key = Registry.LocalMachine.OpenSubKey(ConfigKey, false))
        {
            if (key == null || Convert.ToInt32(key.GetValue("Enabled", 0)) != 1) return false;
            sid = key.GetValue("UserSid") as string;
            username = key.GetValue("Username") as string;
            domain = key.GetValue("Domain") as string;
            return !String.IsNullOrWhiteSpace(sid) &&
                !String.IsNullOrWhiteSpace(username) &&
                !String.IsNullOrWhiteSpace(domain) &&
                File.Exists(CredentialFile);
        }
    }

    private static bool IsTrustedAgentImage(string callerImagePath)
    {
        try
        {
            if (String.IsNullOrWhiteSpace(callerImagePath)) return false;

            string trustedPath;
            string trustedHash;
            using (RegistryKey key = Registry.LocalMachine.OpenSubKey(ConfigKey, false))
            {
                if (key == null) return false;
                trustedPath = key.GetValue("TrustedAgentPath") as string;
                trustedHash = key.GetValue("TrustedAgentSha256") as string;
            }

            if (String.IsNullOrWhiteSpace(trustedPath) ||
                String.IsNullOrWhiteSpace(trustedHash) ||
                trustedHash.Length != 64)
            {
                return false;
            }

            string normalizedCallerPath = Path.GetFullPath(callerImagePath);
            string normalizedTrustedPath = Path.GetFullPath(trustedPath);
            if (!String.Equals(
                normalizedCallerPath,
                normalizedTrustedPath,
                StringComparison.OrdinalIgnoreCase) ||
                !File.Exists(normalizedTrustedPath))
            {
                return false;
            }

            using (FileStream stream = File.Open(
                normalizedTrustedPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read | FileShare.Delete))
            {
                string actualHash = ComputeSha256(stream);
                return String.Equals(
                    actualHash,
                    trustedHash,
                    StringComparison.OrdinalIgnoreCase);
            }
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static string ComputeSha256(Stream stream)
    {
        using (SHA256 sha256 = SHA256.Create())
        {
            return BitConverter.ToString(
                sha256.ComputeHash(stream)).Replace("-", String.Empty);
        }
    }

    private static bool IsSessionLocked(int sessionId)
    {
        if (!IsSessionActive(sessionId)) return false;

        foreach (Process process in Process.GetProcessesByName("LogonUI"))
        {
            try
            {
                if (process.SessionId == sessionId) return true;
            }
            catch (InvalidOperationException)
            {
            }
            finally
            {
                process.Dispose();
            }
        }
        return false;
    }

    private static bool IsSessionActive(int sessionId)
    {
        IntPtr buffer = IntPtr.Zero;
        int bytes = 0;
        try
        {
            if (!WTSQuerySessionInformation(
                IntPtr.Zero,
                sessionId,
                WtsConnectState,
                out buffer,
                out bytes) ||
                buffer == IntPtr.Zero ||
                bytes < sizeof(int))
            {
                return false;
            }

            return Marshal.ReadInt32(buffer) == WtsActive;
        }
        finally
        {
            if (buffer != IntPtr.Zero)
            {
                WTSFreeMemory(buffer);
            }
        }
    }

    private static bool ReadMessage(BinaryReader reader, out Protocol.MessageType type, out byte[] payload)
    {
        type = 0;
        payload = null;
        try
        {
            uint magic = reader.ReadUInt32();
            uint version = reader.ReadUInt32();
            type = (Protocol.MessageType)reader.ReadUInt32();
            uint size = reader.ReadUInt32();
            if (magic != Protocol.Magic || version != Protocol.Version || size > Protocol.MaximumPayloadBytes)
                return false;
            payload = reader.ReadBytes((int)size);
            return payload.Length == size;
        }
        catch (EndOfStreamException)
        {
            return false;
        }
    }

    private static void WriteResponse(BinaryWriter writer, Protocol.Status status, byte[] payload)
    {
        byte[] body = payload ?? new byte[0];
        writer.Write(Protocol.Magic);
        writer.Write(Protocol.Version);
        writer.Write((uint)status);
        writer.Write((uint)body.Length);
        writer.Write(body);
        writer.Flush();
    }

    private static string ReadString(BinaryReader reader)
    {
        uint characters = reader.ReadUInt32();
        if (characters == 0 || characters > 256) throw new InvalidDataException();
        byte[] bytes = reader.ReadBytes(checked((int)characters * 2));
        if (bytes.Length != characters * 2) throw new EndOfStreamException();
        return Encoding.Unicode.GetString(bytes);
    }

    private static bool TryReadOnlyString(byte[] payload, out string value)
    {
        value = null;
        try
        {
            using (var reader = new BinaryReader(new MemoryStream(payload), Encoding.Unicode))
            {
                value = ReadString(reader);
                return reader.BaseStream.Position == reader.BaseStream.Length;
            }
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool GetClientIdentity(
        SafePipeHandle pipe,
        out string sid,
        out int sessionId,
        out string imagePath)
    {
        sid = null;
        sessionId = -1;
        imagePath = null;
        uint processId;
        if (!GetNamedPipeClientProcessId(pipe, out processId)) return false;
        try
        {
            using (Process process = Process.GetProcessById((int)processId))
            {
                IntPtr token = IntPtr.Zero;
                if (!OpenProcessToken(process.Handle, 0x0008, out token)) return false;
                try
                {
                    using (WindowsIdentity identity = new WindowsIdentity(token))
                    {
                        sid = identity.User == null ? null : identity.User.Value;
                        sessionId = process.SessionId;
                        imagePath = process.MainModule == null
                            ? null
                            : process.MainModule.FileName;
                        return sid != null && !String.IsNullOrWhiteSpace(imagePath);
                    }
                }
                finally
                {
                    CloseHandle(token);
                }
            }
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(DataDirectory);
            File.AppendAllText(
                LogFile,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " [PID=" +
                ProcessId + "] " + message + Environment.NewLine,
                Encoding.Unicode);
        }
        catch (Exception)
        {
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint clientProcessId);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSQuerySessionInformation(
        IntPtr serverHandle,
        int sessionId,
        int infoClass,
        out IntPtr buffer,
        out int bytesReturned);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr memory);

    private static bool RunSelfTest()
    {
        var state = new AuthorizationState
        {
            Active = true,
            AuthorizationId = Guid.NewGuid(),
            UserSid = "S-1-5-21-test",
            SessionId = 1,
            LockCycleId = 2,
            ExpiresAtTicks = DateTime.UtcNow.AddSeconds(5).Ticks
        };
        state.ClearActive();
        if (state.Active || state.Consuming ||
            state.AuthorizationId != Guid.Empty || state.UserSid != null)
            return false;

        var broker = new BrokerService();
        Guid transactionAuthorizationId = Guid.NewGuid();
        broker.authorization.Active = true;
        broker.authorization.AuthorizationId = transactionAuthorizationId;
        broker.authorization.UserSid = "S-1-5-21-test";
        broker.authorization.SessionId = 7;
        broker.authorization.LockCycleId = 9;
        broker.authorization.ExpiresAtTicks = DateTime.UtcNow.AddSeconds(5).Ticks;
        if (broker.GetAuthorizationStatus("S-1-5-21-test", 7) != Protocol.Status.Ok)
            return false;
        if (broker.GetAuthorizationStatus("S-1-5-21-test", 8) != Protocol.Status.AccessDenied)
            return false;
        broker.authorization.Active = false;
        broker.authorization.Consuming = true;
        broker.RestoreConsumingAuthorization(transactionAuthorizationId);
        if (!broker.authorization.Active || broker.authorization.Consuming)
            return false;

        byte[] clear = Encoding.Unicode.GetBytes("test-password\0");
        byte[] encrypted = ProtectedData.Protect(clear, null, DataProtectionScope.LocalMachine);
        byte[] roundTrip = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.LocalMachine);
        bool equal = clear.Length == roundTrip.Length;
        for (int index = 0; equal && index < clear.Length; index++) equal = clear[index] == roundTrip[index];
        Array.Clear(clear, 0, clear.Length);
        Array.Clear(encrypted, 0, encrypted.Length);
        Array.Clear(roundTrip, 0, roundTrip.Length);
        if (!equal) return false;

        using (var stream = new MemoryStream())
        using (var writer = new BinaryWriter(stream, Encoding.Unicode, true))
        {
            writer.Write(Protocol.Magic);
            writer.Write(Protocol.Version);
            writer.Write((uint)Protocol.MessageType.Peek);
            writer.Write((uint)4);
            writer.Write((uint)0);
            writer.Flush();
            stream.Position = 0;
            using (var reader = new BinaryReader(stream, Encoding.Unicode, true))
            {
                Protocol.MessageType type;
                byte[] payload;
                if (!ReadMessage(reader, out type, out payload) ||
                    type != Protocol.MessageType.Peek || payload.Length != 4)
                    return false;
            }
        }
        int elapsed = 0;
        int[] waits = GetProviderAuthorizationRetryWaits();
        int[] expectedNotifications = { 250, 500, 1000, 1750, 2750 };
        for (int index = 0; index < waits.Length; index++)
        {
            elapsed += waits[index];
            if (elapsed != expectedNotifications[index]) return false;
        }

        string currentImage = Process.GetCurrentProcess().MainModule.FileName;
        using (FileStream stream = File.OpenRead(currentImage))
        {
            string imageHash = ComputeSha256(stream);
            stream.Position = 0;
            string repeatedHash = ComputeSha256(stream);
            if (imageHash.Length != 64 ||
                !String.Equals(imageHash, repeatedHash, StringComparison.Ordinal))
                return false;
        }
        return true;
    }

    internal static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--self-test")
        {
            bool passed = RunSelfTest();
            Console.WriteLine(passed ? "Broker self-test: OK" : "Broker self-test: FAILED");
            return passed ? 0 : 1;
        }
        if (args.Length == 1 && args[0] == "--console")
        {
            new BrokerService().RunConsole();
            return 0;
        }
        ServiceBase.Run(new BrokerService());
        return 0;
    }
}
