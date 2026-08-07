#pragma once

#include <credentialprovider.h>
#include <string>

HRESULT PackUnlockCredential(
    const std::wstring& domain,
    const std::wstring& username,
    const std::wstring& password,
    CREDENTIAL_PROVIDER_USAGE_SCENARIO scenario,
    CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* serialization);
