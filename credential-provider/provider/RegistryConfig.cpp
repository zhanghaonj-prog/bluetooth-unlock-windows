#include "RegistryConfig.h"

#include <vector>

namespace
{
constexpr wchar_t kConfigKey[] =
    L"SOFTWARE\\BleProximityWake\\CredentialProviderP0";

HRESULT ReadString(HKEY key, const wchar_t* name, std::wstring* value)
{
    DWORD type = 0;
    DWORD byteCount = 0;
    LONG result = RegQueryValueExW(key, name, nullptr, &type, nullptr, &byteCount);
    if (result != ERROR_SUCCESS) return HRESULT_FROM_WIN32(result);
    if (type != REG_SZ && type != REG_EXPAND_SZ)
        return HRESULT_FROM_WIN32(ERROR_DATATYPE_MISMATCH);

    std::vector<wchar_t> buffer(byteCount / sizeof(wchar_t) + 1, L'\0');
    result = RegQueryValueExW(
        key,
        name,
        nullptr,
        &type,
        reinterpret_cast<BYTE*>(buffer.data()),
        &byteCount);
    if (result != ERROR_SUCCESS) return HRESULT_FROM_WIN32(result);
    *value = buffer.data();
    return S_OK;
}
}

HRESULT LoadProviderConfig(ProviderConfig* config)
{
    if (config == nullptr) return E_INVALIDARG;
    *config = ProviderConfig{};

    HKEY key = nullptr;
    LONG result = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kConfigKey, 0, KEY_QUERY_VALUE, &key);
    if (result != ERROR_SUCCESS) return HRESULT_FROM_WIN32(result);

    DWORD enabled = 0;
    DWORD enabledBytes = sizeof(enabled);
    DWORD type = 0;
    result = RegQueryValueExW(
        key,
        L"Enabled",
        nullptr,
        &type,
        reinterpret_cast<BYTE*>(&enabled),
        &enabledBytes);
    HRESULT hr = result == ERROR_SUCCESS && type == REG_DWORD
        ? S_OK
        : HRESULT_FROM_WIN32(result == ERROR_SUCCESS ? ERROR_DATATYPE_MISMATCH : result);
    if (SUCCEEDED(hr)) hr = ReadString(key, L"UserSid", &config->userSid);
    if (SUCCEEDED(hr)) hr = ReadString(key, L"Username", &config->username);
    if (SUCCEEDED(hr)) hr = ReadString(key, L"Domain", &config->domain);

    config->enabled = enabled != 0;
    RegCloseKey(key);
    return hr;
}
