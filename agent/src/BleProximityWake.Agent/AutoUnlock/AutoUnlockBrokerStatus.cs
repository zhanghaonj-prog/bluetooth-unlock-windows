namespace BleProximityWake.Agent.AutoUnlock
{
    internal enum AutoUnlockBrokerStatus : uint
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
