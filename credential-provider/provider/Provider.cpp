#include "Provider.h"

#include "BrokerClient.h"
#include "Credential.h"
#include "Diagnostics.h"
#include "Guids.h"
#include "Module.h"
#include "RegistryConfig.h"

#include <objbase.h>
#include <sddl.h>
#include <shlwapi.h>

namespace
{
const CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR kFieldDescriptors[] =
{
    { FieldIdTitle, CPFT_LARGE_TEXT, const_cast<PWSTR>(L"BLE Proximity Unlock"), GUID_NULL },
    { FieldIdStatus, CPFT_SMALL_TEXT, const_cast<PWSTR>(L"Status"), GUID_NULL },
    { FieldIdSubmit, CPFT_SUBMIT_BUTTON, const_cast<PWSTR>(L"Unlock"), GUID_NULL }
};

HRESULT CopyFieldDescriptor(
    const CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR& source,
    CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR** destination)
{
    *destination = static_cast<CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR*>(
        CoTaskMemAlloc(sizeof(CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR)));
    if (*destination == nullptr)
    {
        return E_OUTOFMEMORY;
    }
    **destination = source;
    (*destination)->pszLabel = nullptr;
    HRESULT hr = SHStrDupW(source.pszLabel, &(*destination)->pszLabel);
    if (FAILED(hr))
    {
        CoTaskMemFree(*destination);
        *destination = nullptr;
    }
    return hr;
}

struct EventThreadContext
{
    BleProvider* provider;
    IStream* marshaledEvents;
};

HANDLE CreateAuthorizationEvent()
{
    // LogonUI creates this object as SYSTEM. Grant only SYSTEM and elevated
    // local administrators enough access to signal the P0 test event.
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;;GA;;;SY)(A;;GA;;;BA)",
            SDDL_REVISION_1,
            &descriptor,
            nullptr))
    {
        return nullptr;
    }

    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.lpSecurityDescriptor = descriptor;
    attributes.bInheritHandle = FALSE;
    HANDLE eventHandle = CreateEventW(
        &attributes,
        FALSE,
        FALSE,
        kAuthorizationEventName);
    LocalFree(descriptor);
    return eventHandle;
}
}

BleProvider::BleProvider()
{
    ModuleAddRef();
    credential_ = new (std::nothrow) BleCredential();
}

BleProvider::~BleProvider()
{
    StopEventThread();
    if (credential_ != nullptr)
    {
        credential_->Release();
        credential_ = nullptr;
    }
    ModuleRelease();
}

HRESULT BleProvider::QueryInterface(REFIID riid, void** object)
{
    if (object == nullptr)
    {
        return E_POINTER;
    }
    *object = nullptr;
    if (riid == IID_IUnknown || riid == IID_ICredentialProvider)
    {
        *object = static_cast<ICredentialProvider*>(this);
        AddRef();
        return S_OK;
    }
    if (riid == IID_ICredentialProviderSetUserArray)
    {
        *object = static_cast<ICredentialProviderSetUserArray*>(this);
        AddRef();
        return S_OK;
    }
    return E_NOINTERFACE;
}

ULONG BleProvider::AddRef()
{
    return static_cast<ULONG>(InterlockedIncrement(&referenceCount_));
}

ULONG BleProvider::Release()
{
    const LONG count = InterlockedDecrement(&referenceCount_);
    if (count == 0)
    {
        delete this;
    }
    return static_cast<ULONG>(count);
}

HRESULT BleProvider::SetUsageScenario(CREDENTIAL_PROVIDER_USAGE_SCENARIO scenario, DWORD)
{
    WriteDiagnostic(L"Provider.SetUsageScenario Scenario=%u", scenario);
    if (scenario != CPUS_LOGON && scenario != CPUS_UNLOCK_WORKSTATION)
    {
        scenario_ = CPUS_INVALID;
        return E_NOTIMPL;
    }
    scenario_ = scenario;
    if (credential_ != nullptr)
    {
        credential_->SetUsageScenario(scenario);
    }
    return S_OK;
}

HRESULT BleProvider::SetUserArray(ICredentialProviderUserArray* users)
{
    if (users == nullptr)
    {
        return E_INVALIDARG;
    }

    InterlockedExchange(&configuredUserVisible_, FALSE);

    ProviderConfig config;
    HRESULT hr = LoadProviderConfig(&config);
    if (FAILED(hr) || config.userSid.empty())
    {
        WriteDiagnostic(L"Provider.SetUserArray configuration unavailable Hr=0x%08X", hr);
        return S_OK;
    }

    DWORD userCount = 0;
    hr = users->GetCount(&userCount);
    if (FAILED(hr))
    {
        WriteDiagnostic(L"Provider.SetUserArray GetCount failed Hr=0x%08X", hr);
        return hr;
    }

    bool configuredUserVisible = false;
    for (DWORD index = 0; index < userCount; ++index)
    {
        ICredentialProviderUser* user = nullptr;
        hr = users->GetAt(index, &user);
        if (FAILED(hr) || user == nullptr)
        {
            WriteDiagnostic(
                L"Provider.SetUserArray GetAt failed Index=%lu Hr=0x%08X",
                index,
                hr);
            continue;
        }

        PWSTR sid = nullptr;
        hr = user->GetSid(&sid);
        if (SUCCEEDED(hr) && sid != nullptr &&
            _wcsicmp(sid, config.userSid.c_str()) == 0)
        {
            configuredUserVisible = true;
        }
        CoTaskMemFree(sid);
        user->Release();

        if (configuredUserVisible)
        {
            break;
        }
    }

    InterlockedExchange(&configuredUserVisible_, configuredUserVisible ? TRUE : FALSE);
    WriteDiagnostic(
        L"Provider.SetUserArray Count=%lu ConfiguredSidVisible=%d",
        userCount,
        configuredUserVisible);
    return S_OK;
}

HRESULT BleProvider::SetSerialization(const CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION*)
{
    return E_NOTIMPL;
}

HRESULT BleProvider::Advise(ICredentialProviderEvents* events, UINT_PTR adviseContext)
{
    WriteDiagnostic(L"Provider.Advise");
    if (events == nullptr)
    {
        return E_INVALIDARG;
    }
    StopEventThread();
    adviseContext_ = adviseContext;

    authorizationEvent_ = CreateAuthorizationEvent();
    stopEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (authorizationEvent_ == nullptr || stopEvent_ == nullptr)
    {
        StopEventThread();
        return HRESULT_FROM_WIN32(GetLastError());
    }

    IStream* marshaledEvents = nullptr;
    HRESULT hr = CoMarshalInterThreadInterfaceInStream(
        IID_ICredentialProviderEvents,
        events,
        &marshaledEvents);
    if (FAILED(hr))
    {
        StopEventThread();
        return hr;
    }

    auto* context = static_cast<EventThreadContext*>(
        HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(EventThreadContext)));
    if (context == nullptr)
    {
        marshaledEvents->Release();
        StopEventThread();
        return E_OUTOFMEMORY;
    }
    context->provider = this;
    context->marshaledEvents = marshaledEvents;

    AddRef();
    eventThread_ = CreateThread(nullptr, 0, EventThreadEntry, context, 0, nullptr);
    if (eventThread_ == nullptr)
    {
        Release();
        marshaledEvents->Release();
        HeapFree(GetProcessHeap(), 0, context);
        StopEventThread();
        return HRESULT_FROM_WIN32(GetLastError());
    }
    return S_OK;
}

HRESULT BleProvider::UnAdvise()
{
    WriteDiagnostic(L"Provider.UnAdvise");
    StopEventThread();
    return S_OK;
}

HRESULT BleProvider::GetFieldDescriptorCount(DWORD* count)
{
    if (count == nullptr)
    {
        return E_POINTER;
    }
    *count = ARRAYSIZE(kFieldDescriptors);
    return S_OK;
}

HRESULT BleProvider::GetFieldDescriptorAt(
    DWORD index,
    CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR** descriptor)
{
    if (descriptor == nullptr)
    {
        return E_POINTER;
    }
    *descriptor = nullptr;
    if (index >= ARRAYSIZE(kFieldDescriptors))
    {
        return E_INVALIDARG;
    }
    return CopyFieldDescriptor(kFieldDescriptors[index], descriptor);
}

HRESULT BleProvider::GetCredentialCount(
    DWORD* count,
    DWORD* defaultCredential,
    BOOL* autoLogonWithDefault)
{
    if (count == nullptr || defaultCredential == nullptr || autoLogonWithDefault == nullptr)
    {
        return E_POINTER;
    }

    ProviderConfig config;
    const bool configured =
        (scenario_ == CPUS_LOGON || scenario_ == CPUS_UNLOCK_WORKSTATION) &&
        credential_ != nullptr &&
        SUCCEEDED(LoadProviderConfig(&config)) &&
        config.enabled &&
        !config.userSid.empty() &&
        InterlockedCompareExchange(&configuredUserVisible_, FALSE, FALSE) != FALSE;

    const bool authorized = configured && IsBrokerAuthorizationValid(config.userSid);
    *count = authorized ? 1 : 0;
    *defaultCredential = authorized ? 0 : CREDENTIAL_PROVIDER_NO_DEFAULT;
    *autoLogonWithDefault = authorized ? TRUE : FALSE;
    WriteDiagnostic(
        L"Provider.GetCredentialCount Configured=%d UserVisible=%d Authorized=%d Count=%lu Default=%lu AutoLogon=%d",
        configured,
        InterlockedCompareExchange(&configuredUserVisible_, FALSE, FALSE) != FALSE,
        authorized,
        *count,
        *defaultCredential,
        *autoLogonWithDefault);
    return S_OK;
}

HRESULT BleProvider::GetCredentialAt(DWORD index, ICredentialProviderCredential** credential)
{
    WriteDiagnostic(L"Provider.GetCredentialAt Index=%lu", index);
    if (credential == nullptr)
    {
        return E_POINTER;
    }
    *credential = nullptr;
    if (index != 0 || credential_ == nullptr)
    {
        return E_INVALIDARG;
    }
    return credential_->QueryInterface(IID_PPV_ARGS(credential));
}

DWORD WINAPI BleProvider::EventThreadEntry(void* rawContext)
{
    auto* context = static_cast<EventThreadContext*>(rawContext);
    BleProvider* provider = context->provider;
    IStream* marshaledEvents = context->marshaledEvents;
    HeapFree(GetProcessHeap(), 0, context);

    provider->EventThread(marshaledEvents);
    provider->Release();
    return 0;
}

void BleProvider::EventThread(IStream* marshaledEvents)
{
    HRESULT initialization = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ICredentialProviderEvents* events = nullptr;
    HRESULT hr = CoGetInterfaceAndReleaseStream(
        marshaledEvents,
        IID_ICredentialProviderEvents,
        reinterpret_cast<void**>(&events));

    if (SUCCEEDED(hr))
    {
        HANDLE handles[] = { stopEvent_, authorizationEvent_ };
        for (;;)
        {
            DWORD result = WaitForMultipleObjects(ARRAYSIZE(handles), handles, FALSE, INFINITE);
            if (result == WAIT_OBJECT_0)
            {
                break;
            }
            if (result == WAIT_OBJECT_0 + 1)
            {
                ProviderConfig config;
                const bool authorized =
                    SUCCEEDED(LoadProviderConfig(&config)) &&
                    config.enabled &&
                    IsBrokerAuthorizationValid(config.userSid);
                WriteDiagnostic(L"Provider authorization event Authorized=%d", authorized);
                if (authorized)
                {
                    HRESULT changeResult = events->CredentialsChanged(adviseContext_);
                    WriteDiagnostic(L"Provider.CredentialsChanged Hr=0x%08X", changeResult);
                }
                continue;
            }
            break;
        }
        events->Release();
    }

    if (SUCCEEDED(initialization))
    {
        CoUninitialize();
    }
}

void BleProvider::StopEventThread()
{
    if (stopEvent_ != nullptr)
    {
        SetEvent(stopEvent_);
    }
    if (eventThread_ != nullptr)
    {
        WaitForSingleObject(eventThread_, 5000);
        CloseHandle(eventThread_);
        eventThread_ = nullptr;
    }
    if (authorizationEvent_ != nullptr)
    {
        CloseHandle(authorizationEvent_);
        authorizationEvent_ = nullptr;
    }
    if (stopEvent_ != nullptr)
    {
        CloseHandle(stopEvent_);
        stopEvent_ = nullptr;
    }
    adviseContext_ = 0;
}
