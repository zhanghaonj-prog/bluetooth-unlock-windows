#pragma once

#include <credentialprovider.h>
#include <windows.h>

enum FieldId : DWORD
{
    FieldIdTitle = 0,
    FieldIdStatus = 1,
    FieldIdSubmit = 2,
    FieldIdCount = 3
};

class BleCredential final : public ICredentialProviderCredential2
{
public:
    BleCredential();
    void SetUsageScenario(CREDENTIAL_PROVIDER_USAGE_SCENARIO scenario);

    IFACEMETHODIMP QueryInterface(REFIID riid, void** object) override;
    IFACEMETHODIMP_(ULONG) AddRef() override;
    IFACEMETHODIMP_(ULONG) Release() override;

    IFACEMETHODIMP Advise(ICredentialProviderCredentialEvents* events) override;
    IFACEMETHODIMP UnAdvise() override;
    IFACEMETHODIMP SetSelected(BOOL* autoLogon) override;
    IFACEMETHODIMP SetDeselected() override;
    IFACEMETHODIMP GetFieldState(
        DWORD fieldId,
        CREDENTIAL_PROVIDER_FIELD_STATE* fieldState,
        CREDENTIAL_PROVIDER_FIELD_INTERACTIVE_STATE* fieldInteractiveState) override;
    IFACEMETHODIMP GetStringValue(DWORD fieldId, PWSTR* value) override;
    IFACEMETHODIMP GetBitmapValue(DWORD fieldId, HBITMAP* bitmap) override;
    IFACEMETHODIMP GetCheckboxValue(DWORD fieldId, BOOL* checked, PWSTR* label) override;
    IFACEMETHODIMP GetSubmitButtonValue(DWORD fieldId, DWORD* adjacentTo) override;
    IFACEMETHODIMP GetComboBoxValueCount(DWORD fieldId, DWORD* itemCount, DWORD* selectedItem) override;
    IFACEMETHODIMP GetComboBoxValueAt(DWORD fieldId, DWORD item, PWSTR* itemValue) override;
    IFACEMETHODIMP SetStringValue(DWORD fieldId, PCWSTR value) override;
    IFACEMETHODIMP SetCheckboxValue(DWORD fieldId, BOOL checked) override;
    IFACEMETHODIMP SetComboBoxSelectedValue(DWORD fieldId, DWORD selectedItem) override;
    IFACEMETHODIMP CommandLinkClicked(DWORD fieldId) override;
    IFACEMETHODIMP GetSerialization(
        CREDENTIAL_PROVIDER_GET_SERIALIZATION_RESPONSE* response,
        CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* serialization,
        PWSTR* optionalStatusText,
        CREDENTIAL_PROVIDER_STATUS_ICON* optionalStatusIcon) override;
    IFACEMETHODIMP ReportResult(
        NTSTATUS status,
        NTSTATUS substatus,
        PWSTR* optionalStatusText,
        CREDENTIAL_PROVIDER_STATUS_ICON* optionalStatusIcon) override;
    IFACEMETHODIMP GetUserSid(PWSTR* sid) override;

private:
    ~BleCredential();

    LONG referenceCount_ = 1;
    CREDENTIAL_PROVIDER_USAGE_SCENARIO scenario_ = CPUS_INVALID;
    ICredentialProviderCredentialEvents* events_ = nullptr;
    GUID authorizationId_{};
};
