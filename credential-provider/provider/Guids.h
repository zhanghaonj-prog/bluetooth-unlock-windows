#pragma once

#include <guiddef.h>

// {A9E31F6A-4C50-45A1-B74C-02EA28E8613D}
inline constexpr GUID CLSID_BleProximityCredentialProvider =
{ 0xa9e31f6a, 0x4c50, 0x45a1, { 0xb7, 0x4c, 0x02, 0xea, 0x28, 0xe8, 0x61, 0x3d } };

inline constexpr wchar_t kProviderClsidString[] =
    L"{A9E31F6A-4C50-45A1-B74C-02EA28E8613D}";

inline constexpr wchar_t kAuthorizationEventName[] =
    L"Global\\BleProximityCredentialProvider.P0.Authorization";
