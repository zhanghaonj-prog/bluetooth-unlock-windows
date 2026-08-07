#pragma once

#include <windows.h>
#include <string>

struct BrokerCredential
{
    GUID authorizationId{};
    std::wstring domain;
    std::wstring username;
    std::wstring password;
};

bool IsBrokerAuthorizationValid(const std::wstring& userSid);
HRESULT ConsumeBrokerCredential(const std::wstring& userSid, BrokerCredential* credential);
void ReportBrokerResult(const GUID& authorizationId, LONG status, LONG substatus);
void SecureClearBrokerCredential(BrokerCredential* credential);
