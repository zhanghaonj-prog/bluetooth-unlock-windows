#pragma once

#include <windows.h>

inline constexpr DWORD kBrokerProtocolMagic = 0x42505742; // BWPB
inline constexpr DWORD kBrokerProtocolVersion = 1;
inline constexpr DWORD kBrokerMaximumPayloadBytes = 4096;
inline constexpr wchar_t kAgentPipeName[] = L"BleProximityWake.UnlockAgent";
inline constexpr wchar_t kProviderPipeName[] = L"BleProximityWake.UnlockProvider";

enum class BrokerMessageType : DWORD
{
    Authorize = 1,
    Peek = 2,
    Consume = 3,
    ReportResult = 4
};

enum class BrokerStatus : DWORD
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
};

#pragma pack(push, 1)
struct BrokerMessageHeader
{
    DWORD magic;
    DWORD version;
    BrokerMessageType type;
    DWORD payloadBytes;
};

struct BrokerResponseHeader
{
    DWORD magic;
    DWORD version;
    BrokerStatus status;
    DWORD payloadBytes;
};

struct BrokerAuthorizePayload
{
    DWORD sessionId;
    DWORD authorizationTtlMilliseconds;
    ULONGLONG lockCycleId;
    GUID requestId;
    DWORD sidCharacters;
};

struct BrokerSidPayload
{
    DWORD sidCharacters;
};

struct BrokerCredentialPayload
{
    GUID authorizationId;
    DWORD domainCharacters;
    DWORD usernameCharacters;
    DWORD passwordCharacters;
};

struct BrokerReportPayload
{
    GUID authorizationId;
    LONG status;
    LONG substatus;
};
#pragma pack(pop)
