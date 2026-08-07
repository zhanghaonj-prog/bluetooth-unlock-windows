#pragma once

#include <windows.h>
#include <string>

struct ProviderConfig
{
    bool enabled = false;
    std::wstring userSid;
    std::wstring username;
    std::wstring domain;
};

HRESULT LoadProviderConfig(ProviderConfig* config);
