#include "Credential.h"

#include "BrokerClient.h"
#include "CredentialPacking.h"
#include "Diagnostics.h"
#include "Module.h"
#include "RegistryConfig.h"

#include <shlwapi.h>

namespace
{
bool IsCredentialAuthorized()
{
    ProviderConfig config;
    return SUCCEEDED(LoadProviderConfig(&config)) &&
        config.enabled &&
        !config.userSid.empty() &&
        IsBrokerAuthorizationValid(config.userSid);
}
}

BleCredential::BleCredential()
{
    ModuleAddRef();
}

BleCredential::~BleCredential()
{
    UnAdvise();
    ModuleRelease();
}

void BleCredential::SetUsageScenario(CREDENTIAL_PROVIDER_USAGE_SCENARIO scenario)
{
    scenario_ = scenario;
}

HRESULT BleCredential::QueryInterface(REFIID riid, void** object)
{
    if (object == nullptr)
    {
        return E_POINTER;
    }
    *object = nullptr;

    if (riid == IID_IUnknown ||
        riid == IID_ICredentialProviderCredential ||
        riid == IID_ICredentialProviderCredential2)
    {
        *object = static_cast<ICredentialProviderCredential2*>(this);
        AddRef();
        return S_OK;
    }
    return E_NOINTERFACE;
}

ULONG BleCredential::AddRef()
{
    return static_cast<ULONG>(InterlockedIncrement(&referenceCount_));
}

ULONG BleCredential::Release()
{
    const LONG count = InterlockedDecrement(&referenceCount_);
    if (count == 0)
    {
        delete this;
    }
    return static_cast<ULONG>(count);
}

HRESULT BleCredential::Advise(ICredentialProviderCredentialEvents* events)
{
    if (events == nullptr)
    {
        return E_INVALIDARG;
    }
    UnAdvise();
    events_ = events;
    events_->AddRef();
    return S_OK;
}

HRESULT BleCredential::UnAdvise()
{
    if (events_ != nullptr)
    {
        events_->Release();
        events_ = nullptr;
    }
    return S_OK;
}

HRESULT BleCredential::SetSelected(BOOL* autoLogon)
{
    if (autoLogon == nullptr)
    {
        return E_POINTER;
    }
    *autoLogon = IsCredentialAuthorized() ? TRUE : FALSE;
    WriteDiagnostic(L"Credential.SetSelected AutoLogon=%d", *autoLogon);
    return S_OK;
}

HRESULT BleCredential::SetDeselected()
{
    return S_OK;
}

HRESULT BleCredential::GetFieldState(
    DWORD fieldId,
    CREDENTIAL_PROVIDER_FIELD_STATE* fieldState,
    CREDENTIAL_PROVIDER_FIELD_INTERACTIVE_STATE* fieldInteractiveState)
{
    if (fieldState == nullptr || fieldInteractiveState == nullptr)
    {
        return E_POINTER;
    }

    switch (fieldId)
    {
    case FieldIdTitle:
        *fieldState = CPFS_DISPLAY_IN_BOTH;
        *fieldInteractiveState = CPFIS_NONE;
        return S_OK;
    case FieldIdStatus:
    case FieldIdSubmit:
        *fieldState = CPFS_DISPLAY_IN_SELECTED_TILE;
        *fieldInteractiveState = CPFIS_NONE;
        return S_OK;
    default:
        return E_INVALIDARG;
    }
}

HRESULT BleCredential::GetStringValue(DWORD fieldId, PWSTR* value)
{
    if (value == nullptr)
    {
        return E_POINTER;
    }
    *value = nullptr;

    PCWSTR text = nullptr;
    switch (fieldId)
    {
    case FieldIdTitle:
        text = L"BLE Proximity Unlock";
        break;
    case FieldIdStatus:
        text = IsCredentialAuthorized()
            ? L"Proximity authorized. Signing in..."
            : L"Waiting for proximity authorization";
        break;
    case FieldIdSubmit:
        text = L"Unlock";
        break;
    default:
        return E_INVALIDARG;
    }
    return SHStrDupW(text, value);
}

HRESULT BleCredential::GetBitmapValue(DWORD, HBITMAP*)
{
    return E_NOTIMPL;
}

HRESULT BleCredential::GetCheckboxValue(DWORD, BOOL*, PWSTR*)
{
    return E_NOTIMPL;
}

HRESULT BleCredential::GetSubmitButtonValue(DWORD fieldId, DWORD* adjacentTo)
{
    if (adjacentTo == nullptr)
    {
        return E_POINTER;
    }
    if (fieldId != FieldIdSubmit)
    {
        return E_INVALIDARG;
    }
    *adjacentTo = FieldIdStatus;
    return S_OK;
}

HRESULT BleCredential::GetComboBoxValueCount(DWORD, DWORD*, DWORD*)
{
    return E_NOTIMPL;
}

HRESULT BleCredential::GetComboBoxValueAt(DWORD, DWORD, PWSTR*)
{
    return E_NOTIMPL;
}

HRESULT BleCredential::SetStringValue(DWORD, PCWSTR)
{
    return E_NOTIMPL;
}

HRESULT BleCredential::SetCheckboxValue(DWORD, BOOL)
{
    return E_NOTIMPL;
}

HRESULT BleCredential::SetComboBoxSelectedValue(DWORD, DWORD)
{
    return E_NOTIMPL;
}

HRESULT BleCredential::CommandLinkClicked(DWORD)
{
    return E_NOTIMPL;
}

HRESULT BleCredential::GetSerialization(
    CREDENTIAL_PROVIDER_GET_SERIALIZATION_RESPONSE* response,
    CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* serialization,
    PWSTR* optionalStatusText,
    CREDENTIAL_PROVIDER_STATUS_ICON* optionalStatusIcon)
{
    if (response == nullptr || serialization == nullptr ||
        optionalStatusText == nullptr || optionalStatusIcon == nullptr)
    {
        return E_POINTER;
    }

    *response = CPGSR_NO_CREDENTIAL_NOT_FINISHED;
    ZeroMemory(serialization, sizeof(*serialization));
    *optionalStatusText = nullptr;
    *optionalStatusIcon = CPSI_NONE;
    WriteDiagnostic(L"Credential.GetSerialization called");

    ProviderConfig config;
    HRESULT hr = LoadProviderConfig(&config);
    if (FAILED(hr) || !config.enabled)
    {
        WriteDiagnostic(L"Credential.GetSerialization config failed Hr=0x%08X", hr);
        SHStrDupW(L"Automatic unlock is not configured.", optionalStatusText);
        *optionalStatusIcon = CPSI_ERROR;
        return S_OK;
    }

    BrokerCredential brokerCredential;
    if (SUCCEEDED(hr))
    {
        hr = ConsumeBrokerCredential(config.userSid, &brokerCredential);
    }
    if (SUCCEEDED(hr))
    {
        authorizationId_ = brokerCredential.authorizationId;
        hr = PackUnlockCredential(
            brokerCredential.domain,
            brokerCredential.username,
            brokerCredential.password,
            scenario_,
            serialization);
    }

    SecureClearBrokerCredential(&brokerCredential);

    if (FAILED(hr))
    {
        WriteDiagnostic(L"Credential.GetSerialization broker or packing failed Hr=0x%08X", hr);
        SHStrDupW(L"Unable to prepare the unlock credential.", optionalStatusText);
        *optionalStatusIcon = CPSI_ERROR;
        return S_OK;
    }

    *response = CPGSR_RETURN_CREDENTIAL_FINISHED;
    WriteDiagnostic(L"Credential.GetSerialization returning credential");
    return S_OK;
}

HRESULT BleCredential::ReportResult(
    NTSTATUS status,
    NTSTATUS substatus,
    PWSTR* optionalStatusText,
    CREDENTIAL_PROVIDER_STATUS_ICON* optionalStatusIcon)
{
    WriteDiagnostic(
        L"Credential.ReportResult Status=0x%08X Substatus=0x%08X",
        status,
        substatus);
    ReportBrokerResult(authorizationId_, status, substatus);
    authorizationId_ = {};
    if (optionalStatusText != nullptr)
    {
        *optionalStatusText = nullptr;
    }
    if (optionalStatusIcon != nullptr)
    {
        *optionalStatusIcon = CPSI_NONE;
    }
    return S_OK;
}

HRESULT BleCredential::GetUserSid(PWSTR* sid)
{
    if (sid == nullptr)
    {
        return E_POINTER;
    }
    *sid = nullptr;

    ProviderConfig config;
    HRESULT hr = LoadProviderConfig(&config);
    if (FAILED(hr) || config.userSid.empty())
    {
        WriteDiagnostic(L"Credential.GetUserSid failed Hr=0x%08X", hr);
        return FAILED(hr) ? hr : E_UNEXPECTED;
    }
    hr = SHStrDupW(config.userSid.c_str(), sid);
    WriteDiagnostic(L"Credential.GetUserSid Hr=0x%08X", hr);
    return hr;
}
