#include "CredentialPacking.h"

#include "Guids.h"

#include <ntsecapi.h>
#include <limits>

namespace
{
void InitializePackedString(
    UNICODE_STRING* target,
    BYTE* base,
    size_t offset,
    const std::wstring& value)
{
    const USHORT byteLength = static_cast<USHORT>(value.size() * sizeof(wchar_t));
    target->Length = byteLength;
    target->MaximumLength = byteLength + sizeof(wchar_t);
    target->Buffer = reinterpret_cast<PWSTR>(offset);
    CopyMemory(base + offset, value.c_str(), target->MaximumLength);
}

HRESULT RetrieveNegotiateAuthenticationPackage(ULONG* authenticationPackage)
{
    if (authenticationPackage == nullptr)
    {
        return E_INVALIDARG;
    }

    HANDLE lsaHandle = nullptr;
    NTSTATUS status = LsaConnectUntrusted(&lsaHandle);
    if (status != 0)
    {
        return HRESULT_FROM_NT(status);
    }

    LSA_STRING packageName{};
    packageName.Buffer = const_cast<PCHAR>("Negotiate");
    packageName.Length = static_cast<USHORT>(strlen(packageName.Buffer));
    packageName.MaximumLength = packageName.Length + 1;
    status = LsaLookupAuthenticationPackage(lsaHandle, &packageName, authenticationPackage);
    LsaDeregisterLogonProcess(lsaHandle);
    return status == 0 ? S_OK : HRESULT_FROM_NT(status);
}
}

HRESULT PackUnlockCredential(
    const std::wstring& domain,
    const std::wstring& username,
    const std::wstring& password,
    CREDENTIAL_PROVIDER_USAGE_SCENARIO scenario,
    CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* serialization)
{
    if (serialization == nullptr || domain.empty() || username.empty() || password.empty())
    {
        return E_INVALIDARG;
    }

    const size_t domainBytes = (domain.size() + 1) * sizeof(wchar_t);
    const size_t usernameBytes = (username.size() + 1) * sizeof(wchar_t);
    const size_t passwordBytes = (password.size() + 1) * sizeof(wchar_t);
    const size_t totalBytes = sizeof(KERB_INTERACTIVE_UNLOCK_LOGON) +
        domainBytes + usernameBytes + passwordBytes;

    if (totalBytes > std::numeric_limits<ULONG>::max())
    {
        return HRESULT_FROM_WIN32(ERROR_ARITHMETIC_OVERFLOW);
    }

    BYTE* buffer = static_cast<BYTE*>(CoTaskMemAlloc(totalBytes));
    if (buffer == nullptr)
    {
        return E_OUTOFMEMORY;
    }
    ZeroMemory(buffer, totalBytes);

    auto* unlockLogon = reinterpret_cast<KERB_INTERACTIVE_UNLOCK_LOGON*>(buffer);
    unlockLogon->Logon.MessageType = scenario == CPUS_UNLOCK_WORKSTATION
        ? KerbWorkstationUnlockLogon
        : KerbInteractiveLogon;

    size_t offset = sizeof(KERB_INTERACTIVE_UNLOCK_LOGON);
    InitializePackedString(&unlockLogon->Logon.LogonDomainName, buffer, offset, domain);
    offset += domainBytes;
    InitializePackedString(&unlockLogon->Logon.UserName, buffer, offset, username);
    offset += usernameBytes;
    InitializePackedString(&unlockLogon->Logon.Password, buffer, offset, password);

    ULONG authenticationPackage = 0;
    HRESULT hr = RetrieveNegotiateAuthenticationPackage(&authenticationPackage);
    if (FAILED(hr))
    {
        SecureZeroMemory(buffer, totalBytes);
        CoTaskMemFree(buffer);
        return hr;
    }

    serialization->ulAuthenticationPackage = authenticationPackage;
    serialization->clsidCredentialProvider = CLSID_BleProximityCredentialProvider;
    serialization->cbSerialization = static_cast<ULONG>(totalBytes);
    serialization->rgbSerialization = buffer;
    return S_OK;
}
