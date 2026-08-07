#include "Diagnostics.h"

#include <strsafe.h>
#include <windows.h>

#include <cstdarg>
#include <cwchar>
#include <string>

namespace
{
SRWLOCK g_logLock = SRWLOCK_INIT;

std::wstring GetLogPath()
{
    wchar_t programData[MAX_PATH]{};
    DWORD length = GetEnvironmentVariableW(L"ProgramData", programData, ARRAYSIZE(programData));
    if (length == 0 || length >= ARRAYSIZE(programData))
    {
        StringCchCopyW(programData, ARRAYSIZE(programData), L"C:\\ProgramData");
    }

    wchar_t directory[MAX_PATH]{};
    StringCchPrintfW(directory, ARRAYSIZE(directory), L"%s\\BleProximityWake", programData);
    CreateDirectoryW(directory, nullptr);

    wchar_t path[MAX_PATH]{};
    StringCchPrintfW(
        path,
        ARRAYSIZE(path),
        L"%s\\credential-provider-p0.log",
        directory);
    return path;
}
}

void WriteDiagnostic(const wchar_t* format, ...)
{
    if (format == nullptr)
    {
        return;
    }

    wchar_t message[1024]{};
    va_list arguments;
    va_start(arguments, format);
    HRESULT hr = StringCchVPrintfW(message, ARRAYSIZE(message), format, arguments);
    va_end(arguments);
    if (FAILED(hr))
    {
        return;
    }

    SYSTEMTIME time{};
    GetLocalTime(&time);
    wchar_t line[1280]{};
    hr = StringCchPrintfW(
        line,
        ARRAYSIZE(line),
        L"%04u-%02u-%02u %02u:%02u:%02u.%03u [PID=%lu] %s\r\n",
        time.wYear,
        time.wMonth,
        time.wDay,
        time.wHour,
        time.wMinute,
        time.wSecond,
        time.wMilliseconds,
        GetCurrentProcessId(),
        message);
    if (FAILED(hr))
    {
        return;
    }

    AcquireSRWLockExclusive(&g_logLock);
    HANDLE file = CreateFileW(
        GetLogPath().c_str(),
        FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        nullptr);
    if (file != INVALID_HANDLE_VALUE)
    {
        const DWORD byteCount = static_cast<DWORD>(wcslen(line) * sizeof(wchar_t));
        DWORD written = 0;
        WriteFile(file, line, byteCount, &written, nullptr);
        CloseHandle(file);
    }
    ReleaseSRWLockExclusive(&g_logLock);
}
