# Contributing

## Before opening a change

- Discuss changes to Credential Provider, Broker protocol, password storage, installer registration, or
  authentication policy in an Issue before implementation.
- Never commit a real `config.json`, device address, network name, SID, username, log, dump, credential
  file, registry export, PDB, certificate, or signing key.
- Keep automatic unlock disabled in all samples and tests that create user-facing configuration.

## Development environment

Use Windows 10/11 x64 with Visual Studio 2022, .NET Framework 4.8 Developer Pack, Windows SDK, C++
desktop development tools, and Windows PowerShell 5.1.

Run the baseline checks sequentially:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-BleProximityWake.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Test-Agent.ps1 -Configuration Release
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\credential-provider\Test-P0Provider.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer.ps1 -Configuration Release -Version 0.1.0 -SkipBuild -StageOnly
```

Do not run multiple Provider builds concurrently because MSVC processes can contend for the same PDB.

## Pull requests

- Keep changes focused and explain the user-visible behavior and security impact.
- Add tests for state-machine, protocol, session, network, or installer changes.
- State which Windows versions and power models were tested.
- Confirm that password, PIN, and Windows Hello fallback remain available.
- Update user, architecture, troubleshooting, and security documentation when contracts change.

Contributions are accepted under the repository's MIT License. By submitting a contribution, you confirm
that you have the right to license it under those terms.
