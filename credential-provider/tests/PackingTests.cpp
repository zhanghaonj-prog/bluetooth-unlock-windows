#include "../provider/CredentialPacking.h"
#include "../provider/Guids.h"

#include <ntsecapi.h>
#include <windows.h>

#include <iostream>
#include <string>

namespace
{
bool CheckPackedString(
    const BYTE* buffer,
    ULONG bufferSize,
    const UNICODE_STRING& value,
    const std::wstring& expected)
{
    const size_t offset = reinterpret_cast<size_t>(value.Buffer);
    const size_t expectedBytes = expected.size() * sizeof(wchar_t);
    if (value.Length != expectedBytes ||
        value.MaximumLength != expectedBytes + sizeof(wchar_t) ||
        offset < sizeof(KERB_INTERACTIVE_UNLOCK_LOGON) ||
        offset + value.MaximumLength > bufferSize)
    {
        return false;
    }

    const wchar_t* text = reinterpret_cast<const wchar_t*>(buffer + offset);
    return std::wstring(text, value.Length / sizeof(wchar_t)) == expected &&
        text[value.Length / sizeof(wchar_t)] == L'\0';
}

bool RunScenario(CREDENTIAL_PROVIDER_USAGE_SCENARIO scenario, KERB_LOGON_SUBMIT_TYPE expectedType)
{
    CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION serialization{};
    HRESULT hr = PackUnlockCredential(
        L"TESTBOX",
        L"test-user",
        L"1357",
        scenario,
        &serialization);
    if (FAILED(hr))
    {
        std::wcerr << L"PackUnlockCredential failed: 0x" << std::hex << hr << std::endl;
        return false;
    }

    const auto* unlockLogon =
        reinterpret_cast<const KERB_INTERACTIVE_UNLOCK_LOGON*>(serialization.rgbSerialization);
    const bool valid = serialization.cbSerialization >= sizeof(*unlockLogon) &&
        unlockLogon->Logon.MessageType == expectedType &&
        CheckPackedString(
            serialization.rgbSerialization,
            serialization.cbSerialization,
            unlockLogon->Logon.LogonDomainName,
            L"TESTBOX") &&
        CheckPackedString(
            serialization.rgbSerialization,
            serialization.cbSerialization,
            unlockLogon->Logon.UserName,
            L"test-user") &&
        CheckPackedString(
            serialization.rgbSerialization,
            serialization.cbSerialization,
            unlockLogon->Logon.Password,
            L"1357");

    SecureZeroMemory(serialization.rgbSerialization, serialization.cbSerialization);
    CoTaskMemFree(serialization.rgbSerialization);
    return valid;
}

bool RunComSmokeTest(const wchar_t* providerPath)
{
    HMODULE module = LoadLibraryW(providerPath);
    if (module == nullptr)
    {
        std::wcerr << L"LoadLibrary failed: " << GetLastError() << std::endl;
        return false;
    }

    using DllGetClassObjectFunction = HRESULT(STDAPICALLTYPE*)(REFCLSID, REFIID, LPVOID*);
    using DllCanUnloadNowFunction = HRESULT(STDAPICALLTYPE*)();
    auto getClassObject = reinterpret_cast<DllGetClassObjectFunction>(
        GetProcAddress(module, "DllGetClassObject"));
    auto canUnloadNow = reinterpret_cast<DllCanUnloadNowFunction>(
        GetProcAddress(module, "DllCanUnloadNow"));
    if (getClassObject == nullptr || canUnloadNow == nullptr)
    {
        FreeLibrary(module);
        return false;
    }

    IClassFactory* factory = nullptr;
    HRESULT hr = getClassObject(
        CLSID_BleProximityCredentialProvider,
        IID_PPV_ARGS(&factory));
    if (FAILED(hr))
    {
        FreeLibrary(module);
        return false;
    }

    ICredentialProvider* provider = nullptr;
    hr = factory->CreateInstance(nullptr, IID_PPV_ARGS(&provider));
    factory->Release();
    if (FAILED(hr))
    {
        FreeLibrary(module);
        return false;
    }

    ICredentialProviderSetUserArray* setUserArray = nullptr;
    const HRESULT setUserArrayResult = provider->QueryInterface(
        IID_PPV_ARGS(&setUserArray));
    if (setUserArray != nullptr)
    {
        setUserArray->Release();
    }

    DWORD fieldCount = 0;
    DWORD credentialCount = 0;
    DWORD defaultCredential = 0;
    BOOL autoLogon = TRUE;
    hr = provider->SetUsageScenario(CPUS_LOGON, 0);
    if (SUCCEEDED(hr)) hr = provider->GetFieldDescriptorCount(&fieldCount);
    if (SUCCEEDED(hr))
    {
        hr = provider->GetCredentialCount(
            &credentialCount,
            &defaultCredential,
            &autoLogon);
    }

    CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR* descriptor = nullptr;
    if (SUCCEEDED(hr)) hr = provider->GetFieldDescriptorAt(0, &descriptor);
    if (descriptor != nullptr)
    {
        CoTaskMemFree(descriptor->pszLabel);
        CoTaskMemFree(descriptor);
    }

    const HRESULT unsupportedResult = provider->SetUsageScenario(CPUS_CREDUI, 0);
    provider->Release();

    const bool valid = SUCCEEDED(hr) &&
        SUCCEEDED(setUserArrayResult) &&
        fieldCount == 3 &&
        credentialCount == 0 &&
        autoLogon == FALSE &&
        unsupportedResult == E_NOTIMPL &&
        canUnloadNow() == S_OK;
    FreeLibrary(module);
    return valid;
}
}

int wmain(int argumentCount, wchar_t** arguments)
{
    if (!RunScenario(CPUS_LOGON, KerbInteractiveLogon))
    {
        std::wcerr << L"CPUS_LOGON packing validation failed." << std::endl;
        return 1;
    }
    if (!RunScenario(CPUS_UNLOCK_WORKSTATION, KerbWorkstationUnlockLogon))
    {
        std::wcerr << L"CPUS_UNLOCK_WORKSTATION packing validation failed." << std::endl;
        return 1;
    }
    if (argumentCount != 2 || !RunComSmokeTest(arguments[1]))
    {
        std::wcerr << L"Credential Provider COM smoke test failed." << std::endl;
        return 1;
    }

    std::wcout << L"Credential serialization packing: OK" << std::endl;
    std::wcout << L"Credential Provider COM lifecycle: OK" << std::endl;
    return 0;
}
