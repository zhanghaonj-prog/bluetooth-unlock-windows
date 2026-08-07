#pragma once

#include <credentialprovider.h>
#include <windows.h>

class BleCredential;

class BleProvider final :
    public ICredentialProvider,
    public ICredentialProviderSetUserArray
{
public:
    BleProvider();

    IFACEMETHODIMP QueryInterface(REFIID riid, void** object) override;
    IFACEMETHODIMP_(ULONG) AddRef() override;
    IFACEMETHODIMP_(ULONG) Release() override;

    IFACEMETHODIMP SetUsageScenario(CREDENTIAL_PROVIDER_USAGE_SCENARIO scenario, DWORD flags) override;
    IFACEMETHODIMP SetSerialization(const CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* serialization) override;
    IFACEMETHODIMP Advise(ICredentialProviderEvents* events, UINT_PTR adviseContext) override;
    IFACEMETHODIMP UnAdvise() override;
    IFACEMETHODIMP GetFieldDescriptorCount(DWORD* count) override;
    IFACEMETHODIMP GetFieldDescriptorAt(DWORD index, CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR** descriptor) override;
    IFACEMETHODIMP GetCredentialCount(DWORD* count, DWORD* defaultCredential, BOOL* autoLogonWithDefault) override;
    IFACEMETHODIMP GetCredentialAt(DWORD index, ICredentialProviderCredential** credential) override;
    IFACEMETHODIMP SetUserArray(ICredentialProviderUserArray* users) override;

private:
    ~BleProvider();
    static DWORD WINAPI EventThreadEntry(void* context);
    void EventThread(IStream* marshaledEvents);
    void StopEventThread();

    LONG referenceCount_ = 1;
    CREDENTIAL_PROVIDER_USAGE_SCENARIO scenario_ = CPUS_INVALID;
    BleCredential* credential_ = nullptr;
    HANDLE authorizationEvent_ = nullptr;
    HANDLE stopEvent_ = nullptr;
    HANDLE eventThread_ = nullptr;
    UINT_PTR adviseContext_ = 0;
    LONG configuredUserVisible_ = FALSE;
};
