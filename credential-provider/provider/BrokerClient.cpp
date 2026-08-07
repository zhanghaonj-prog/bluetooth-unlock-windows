#include "BrokerClient.h"

#include "../shared/BrokerProtocol.h"

#include <limits>
#include <vector>

namespace
{
constexpr DWORD kPipeTimeoutMilliseconds = 500;
constexpr wchar_t kFullProviderPipeName[] =
    L"\\\\.\\pipe\\BleProximityWake.UnlockProvider";

bool WriteAll(HANDLE pipe, const void* data, DWORD bytes)
{
    const BYTE* cursor = static_cast<const BYTE*>(data);
    while (bytes > 0)
    {
        DWORD written = 0;
        if (!WriteFile(pipe, cursor, bytes, &written, nullptr) || written == 0) return false;
        cursor += written;
        bytes -= written;
    }
    return true;
}

bool ReadAll(HANDLE pipe, void* data, DWORD bytes)
{
    BYTE* cursor = static_cast<BYTE*>(data);
    while (bytes > 0)
    {
        DWORD read = 0;
        if (!ReadFile(pipe, cursor, bytes, &read, nullptr) || read == 0) return false;
        cursor += read;
        bytes -= read;
    }
    return true;
}

HRESULT Exchange(
    BrokerMessageType type,
    const void* payload,
    DWORD payloadBytes,
    BrokerStatus* status,
    std::vector<BYTE>* responsePayload)
{
    if (status == nullptr || responsePayload == nullptr || payloadBytes > kBrokerMaximumPayloadBytes)
        return E_INVALIDARG;
    *status = BrokerStatus::InternalError;
    responsePayload->clear();

    if (!WaitNamedPipeW(kFullProviderPipeName, kPipeTimeoutMilliseconds))
        return HRESULT_FROM_WIN32(GetLastError());
    HANDLE pipe = CreateFileW(
        kFullProviderPipeName,
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        0,
        nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());

    BrokerMessageHeader request{
        kBrokerProtocolMagic,
        kBrokerProtocolVersion,
        type,
        payloadBytes
    };
    bool succeeded = WriteAll(pipe, &request, sizeof(request)) &&
        (payloadBytes == 0 || WriteAll(pipe, payload, payloadBytes));

    BrokerResponseHeader response{};
    if (succeeded) succeeded = ReadAll(pipe, &response, sizeof(response));
    if (succeeded &&
        (response.magic != kBrokerProtocolMagic ||
         response.version != kBrokerProtocolVersion ||
         response.payloadBytes > kBrokerMaximumPayloadBytes))
    {
        succeeded = false;
        SetLastError(ERROR_INVALID_DATA);
    }
    if (succeeded)
    {
        responsePayload->assign(response.payloadBytes, 0);
        succeeded = response.payloadBytes == 0 ||
            ReadAll(pipe, responsePayload->data(), response.payloadBytes);
    }

    DWORD error = succeeded ? ERROR_SUCCESS : GetLastError();
    CloseHandle(pipe);
    if (!succeeded)
    {
        responsePayload->clear();
        return HRESULT_FROM_WIN32(error == ERROR_SUCCESS ? ERROR_READ_FAULT : error);
    }
    *status = response.status;
    return S_OK;
}

HRESULT BuildSidPayload(const std::wstring& sid, std::vector<BYTE>* payload)
{
    if (payload == nullptr || sid.empty() ||
        sid.size() > (kBrokerMaximumPayloadBytes - sizeof(BrokerSidPayload)) / sizeof(wchar_t) ||
        sid.size() > std::numeric_limits<DWORD>::max())
        return E_INVALIDARG;

    const DWORD stringBytes = static_cast<DWORD>(sid.size() * sizeof(wchar_t));
    payload->assign(sizeof(BrokerSidPayload) + stringBytes, 0);
    auto* header = reinterpret_cast<BrokerSidPayload*>(payload->data());
    header->sidCharacters = static_cast<DWORD>(sid.size());
    CopyMemory(payload->data() + sizeof(*header), sid.data(), stringBytes);
    return S_OK;
}
}

bool IsBrokerAuthorizationValid(const std::wstring& userSid)
{
    std::vector<BYTE> request;
    if (FAILED(BuildSidPayload(userSid, &request))) return false;
    BrokerStatus status;
    std::vector<BYTE> response;
    return SUCCEEDED(Exchange(
        BrokerMessageType::Peek,
        request.data(),
        static_cast<DWORD>(request.size()),
        &status,
        &response)) && status == BrokerStatus::Ok;
}

HRESULT ConsumeBrokerCredential(const std::wstring& userSid, BrokerCredential* credential)
{
    if (credential == nullptr) return E_POINTER;
    SecureClearBrokerCredential(credential);

    std::vector<BYTE> request;
    HRESULT hr = BuildSidPayload(userSid, &request);
    if (FAILED(hr)) return hr;

    BrokerStatus status;
    std::vector<BYTE> response;
    hr = Exchange(
        BrokerMessageType::Consume,
        request.data(),
        static_cast<DWORD>(request.size()),
        &status,
        &response);
    if (FAILED(hr)) return hr;
    if (status != BrokerStatus::Ok)
        return HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED + static_cast<DWORD>(status));
    if (response.size() < sizeof(BrokerCredentialPayload))
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);

    const auto* header = reinterpret_cast<const BrokerCredentialPayload*>(response.data());
    const ULONGLONG totalCharacters =
        static_cast<ULONGLONG>(header->domainCharacters) +
        header->usernameCharacters + header->passwordCharacters;
    const ULONGLONG requiredBytes = sizeof(*header) + totalCharacters * sizeof(wchar_t);
    if (requiredBytes != response.size())
    {
        SecureZeroMemory(response.data(), response.size());
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    }

    const wchar_t* cursor = reinterpret_cast<const wchar_t*>(response.data() + sizeof(*header));
    credential->authorizationId = header->authorizationId;
    credential->domain.assign(cursor, header->domainCharacters);
    cursor += header->domainCharacters;
    credential->username.assign(cursor, header->usernameCharacters);
    cursor += header->usernameCharacters;
    credential->password.assign(cursor, header->passwordCharacters);
    SecureZeroMemory(response.data(), response.size());
    return S_OK;
}

void ReportBrokerResult(const GUID& authorizationId, LONG status, LONG substatus)
{
    const GUID nullGuid{};
    if (IsEqualGUID(authorizationId, nullGuid)) return;
    BrokerReportPayload report{ authorizationId, status, substatus };
    BrokerStatus brokerStatus;
    std::vector<BYTE> response;
    Exchange(
        BrokerMessageType::ReportResult,
        &report,
        sizeof(report),
        &brokerStatus,
        &response);
}

void SecureClearBrokerCredential(BrokerCredential* credential)
{
    if (credential == nullptr) return;
    if (!credential->password.empty())
    {
        SecureZeroMemory(
            credential->password.data(),
            credential->password.size() * sizeof(wchar_t));
    }
    credential->password.clear();
    credential->username.clear();
    credential->domain.clear();
    credential->authorizationId = {};
}
