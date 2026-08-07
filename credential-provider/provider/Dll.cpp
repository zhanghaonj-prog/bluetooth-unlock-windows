#include "Guids.h"
#include "Diagnostics.h"
#include "Module.h"
#include "Provider.h"

#include <new>
#include <windows.h>

namespace
{
LONG g_moduleReferenceCount = 0;

class ClassFactory final : public IClassFactory
{
public:
    ClassFactory()
    {
        ModuleAddRef();
    }

    IFACEMETHODIMP QueryInterface(REFIID riid, void** object) override
    {
        if (object == nullptr)
        {
            return E_POINTER;
        }
        *object = nullptr;
        if (riid == IID_IUnknown || riid == IID_IClassFactory)
        {
            *object = static_cast<IClassFactory*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    IFACEMETHODIMP_(ULONG) AddRef() override
    {
        return static_cast<ULONG>(InterlockedIncrement(&referenceCount_));
    }

    IFACEMETHODIMP_(ULONG) Release() override
    {
        const LONG count = InterlockedDecrement(&referenceCount_);
        if (count == 0)
        {
            delete this;
        }
        return static_cast<ULONG>(count);
    }

    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** object) override
    {
        if (outer != nullptr)
        {
            return CLASS_E_NOAGGREGATION;
        }
        if (object == nullptr)
        {
            return E_POINTER;
        }
        *object = nullptr;

        auto* provider = new (std::nothrow) BleProvider();
        if (provider == nullptr)
        {
            return E_OUTOFMEMORY;
        }
        HRESULT hr = provider->QueryInterface(riid, object);
        provider->Release();
        return hr;
    }

    IFACEMETHODIMP LockServer(BOOL lock) override
    {
        lock ? ModuleAddRef() : ModuleRelease();
        return S_OK;
    }

private:
    ~ClassFactory()
    {
        ModuleRelease();
    }

    LONG referenceCount_ = 1;
};
}

void ModuleAddRef()
{
    InterlockedIncrement(&g_moduleReferenceCount);
}

void ModuleRelease()
{
    InterlockedDecrement(&g_moduleReferenceCount);
}

__control_entrypoint(DllExport)
STDAPI DllCanUnloadNow(void)
{
    return g_moduleReferenceCount == 0 ? S_OK : S_FALSE;
}

_Check_return_
STDAPI DllGetClassObject(
    _In_ REFCLSID clsid,
    _In_ REFIID riid,
    _Outptr_ LPVOID* object)
{
    WriteDiagnostic(L"DllGetClassObject");
    if (clsid != CLSID_BleProximityCredentialProvider)
    {
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    if (object == nullptr)
    {
        return E_POINTER;
    }
    *object = nullptr;

    auto* factory = new (std::nothrow) ClassFactory();
    if (factory == nullptr)
    {
        return E_OUTOFMEMORY;
    }
    HRESULT hr = factory->QueryInterface(riid, object);
    factory->Release();
    return hr;
}

BOOL WINAPI DllMain(HINSTANCE, DWORD, LPVOID)
{
    return TRUE;
}
