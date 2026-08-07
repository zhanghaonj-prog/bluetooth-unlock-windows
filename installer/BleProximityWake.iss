#define MyAppName "BLE Proximity Wake"
#define MyAppPublisher "BLE Proximity Wake contributors"
#define MyAppExeName "BleProximityWake.Agent.exe"
#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#ifndef StageDir
  #define StageDir "staging"
#endif
#ifndef OutputDir
  #define OutputDir "output"
#endif

[Setup]
AppId={{76EC3DFD-7F89-4FE4-B75E-A14A99378FE3}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\BleProximityWake
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.14393
OutputDir={#OutputDir}
OutputBaseFilename=BleProximityWake-{#MyAppVersion}-win-x64
SetupIconFile=..\assets\ble-proximity-wake.ico
UninstallDisplayIcon={app}\Agent\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
UsePreviousTasks=yes
VersionInfoVersion={#MyAppVersion}.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} installer
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Types]
Name: "agentonly"; Description: "托盘 Agent（推荐）"
Name: "custom"; Description: "自定义安装"; Flags: iscustom

[Components]
Name: "agent"; Description: "BLE 靠近检测托盘 Agent"; Types: agentonly custom; Flags: fixed
Name: "autounlock"; Description: "自动解锁组件（Credential Provider 和 LocalSystem Broker）"; Types: custom

[Tasks]
Name: "startup"; Description: "登录 Windows 后自动启动托盘 Agent"; Components: agent; Flags: checkedonce
Name: "desktopicon"; Description: "创建桌面快捷方式"; Components: agent; Flags: unchecked

[Files]
Source: "{#StageDir}\Agent\*"; DestDir: "{app}\Agent"; Components: agent; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\Defaults\agent-settings.sample.json"; DestDir: "{app}\Defaults"; Components: agent; Flags: ignoreversion
Source: "{#StageDir}\Documentation\*"; DestDir: "{app}\Documentation"; Components: agent; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\Tools\*"; DestDir: "{app}\Tools"; Components: agent; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\release-manifest.json"; DestDir: "{app}"; Components: agent; Flags: ignoreversion
Source: "{#StageDir}\CredentialProvider\scripts\*"; DestDir: "{app}\CredentialProvider\scripts"; Components: agent; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\CredentialProvider\bin\Release\*"; DestDir: "{app}\CredentialProvider\bin\Release"; Components: autounlock; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: filesandordirs; Name: "{app}\CredentialProvider\bin"

[Icons]
Name: "{autoprograms}\BLE Proximity Wake"; Filename: "{app}\Agent\{#MyAppExeName}"; WorkingDir: "{app}\Agent"; Components: agent
Name: "{autodesktop}\BLE Proximity Wake"; Filename: "{app}\Agent\{#MyAppExeName}"; WorkingDir: "{app}\Agent"; Components: agent; Tasks: desktopicon
Name: "{autoprograms}\BLE Proximity Wake\打开日志目录"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Tools\Open-Logs.ps1"""; WorkingDir: "{app}"; Components: agent
Name: "{autoprograms}\BLE Proximity Wake\登记自动解锁凭据"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Tools\Enroll-AutoUnlock.ps1"""; WorkingDir: "{app}"; Components: autounlock
Name: "{autoprograms}\BLE Proximity Wake\立即禁用自动解锁"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Tools\Disable-AutoUnlock.ps1"""; WorkingDir: "{app}"; Components: autounlock

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{app}\Tools\Cleanup-LegacyStartup.ps1"""; WorkingDir: "{app}"; Components: agent; Flags: runasoriginaluser waituntilterminated runhidden
Filename: "{app}\Agent\{#MyAppExeName}"; Description: "启动 BLE Proximity Wake 托盘 Agent"; WorkingDir: "{app}\Agent"; Components: agent; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallDelete]
Type: filesandordirs; Name: "{app}\CredentialProviderP1"

[Code]
const
  DotNet48Release = 528040;
  InstallerRegistryKey = 'Software\BleProximityWake\Installer';

function IsDotNet48Installed: Boolean;
var
  Release: Cardinal;
begin
  Result :=
    RegQueryDWordValue(
      HKLM64,
      'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full',
      'Release',
      Release) and
    (Release >= DotNet48Release);
end;

function InitializeSetup: Boolean;
begin
  Result := IsDotNet48Installed;
  if not Result then
    MsgBox(
      '需要安装 Microsoft .NET Framework 4.8 后才能继续。',
      mbCriticalError,
      MB_OK);
end;

function RunPowerShell(const ScriptPath, Arguments: String): Boolean;
var
  ResultCode: Integer;
  Parameters: String;
begin
  Parameters :=
    '-NoProfile -ExecutionPolicy Bypass -File "' +
    ScriptPath + '" ' + Arguments;
  Result :=
    Exec(
      ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      Parameters,
      ExpandConstant('{app}'),
      SW_HIDE,
      ewWaitUntilTerminated,
      ResultCode) and
    (ResultCode = 0);
end;

procedure InstallAutoUnlockComponent;
var
  ScriptPath: String;
begin
  ScriptPath :=
    ExpandConstant('{app}\CredentialProvider\scripts\Install-P1Provider.ps1');
  if not RunPowerShell(
    ScriptPath,
    '-Configuration Release -AgentExecutablePath "' +
    ExpandConstant('{app}\Agent\{#MyAppExeName}') +
    '" -PreserveEnrollment -IUnderstandThisCanAffectSignIn') then
    RaiseException(
      '自动解锁组件注册失败。安装已中止，请检查 Windows 事件和安装日志。');

  RegWriteDWordValue(HKLM64, InstallerRegistryKey, 'AutoUnlockInstalled', 1);
end;

function RemoveAutoUnlockComponent: Boolean;
var
  ScriptPath: String;
begin
  ScriptPath :=
    ExpandConstant('{app}\CredentialProvider\scripts\Uninstall-P1Provider.ps1');
  Result :=
    FileExists(ScriptPath) and
    RunPowerShell(
      ScriptPath,
      '-RemoveEncryptedCredential -RemoveDataDirectory');
  if Result then
    RegDeleteValue(HKLM64, InstallerRegistryKey, 'AutoUnlockInstalled');
end;

function IsManagedAutoUnlockInstalled: Boolean;
var
  Installed: Cardinal;
begin
  Result :=
    RegQueryDWordValue(
      HKLM64,
      InstallerRegistryKey,
      'AutoUnlockInstalled',
      Installed) and
    (Installed = 1);
end;

procedure ConfigureStartup;
var
  RunKey: String;
begin
  RunKey := 'Software\Microsoft\Windows\CurrentVersion\Run';
  if WizardIsTaskSelected('startup') then
    RegWriteStringValue(
      HKLM64,
      RunKey,
      'BleProximityWake.Agent',
      '"' + ExpandConstant('{app}\Agent\{#MyAppExeName}') + '"')
  else
    RegDeleteValue(HKLM64, RunKey, 'BleProximityWake.Agent');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    ConfigureStartup;
    if WizardIsComponentSelected('autounlock') then
      InstallAutoUnlockComponent
    else if IsManagedAutoUnlockInstalled and
      not RemoveAutoUnlockComponent then
      RaiseException(
        '自动解锁组件卸载失败。安装已中止，注册标记和程序文件已保留。');
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    if IsManagedAutoUnlockInstalled and
      not RemoveAutoUnlockComponent then
      RaiseException(
        '自动解锁组件卸载失败。卸载已中止，注册标记和程序文件已保留。');

    RunPowerShell(
      ExpandConstant('{app}\Tools\Remove-AllUserData.ps1'),
      '');
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    RegDeleteValue(
      HKLM64,
      'Software\Microsoft\Windows\CurrentVersion\Run',
      'BleProximityWake.Agent');
    RegDeleteKeyIncludingSubkeys(HKLM64, InstallerRegistryKey);
  end;
end;
