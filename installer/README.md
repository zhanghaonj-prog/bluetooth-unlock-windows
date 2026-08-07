# Bluetooth Unlock 安装包（P5A）

用户安装、首次配置和安全回退见 [用户使用手册](../docs/USER_GUIDE.md)；完整安装、升级、
卸载验收矩阵见 [测试与发布指南](../docs/TESTING_AND_RELEASE.md)。

产品名称：**蓝牙解锁 / Bluetooth Unlock**。安装目录和文件名继续使用 `BleProximityWake`，用于兼容已有安装、配置和升级流程。

本目录生成 Windows 10/11 x64 的 BLE Proximity Wake 安装包。P5A 只解决
可重复安装、升级和卸载，不包含图形化设备校准。

## 组件

- 托盘 Agent：必选，安装到 `%ProgramFiles%\BleProximityWake\Agent`。
- 自动解锁：可选，包含 Credential Provider 和 LocalSystem Broker。
- 用户配置：Agent 在每个登录用户首次运行时写入
  `%LocalAppData%\BleProximityWake\agent-settings.json`，升级不覆盖。
- 可逆密码：仅在用户主动运行“登记自动解锁凭据”后写入
  `%ProgramData%\BleProximityWake\credential.dat`。
- 已登记升级：同时保留 `Enabled`、用户 SID、用户名、域和加密密码文件，并刷新
  可信 Agent 路径与 SHA-256；安装时清理旧 PowerShell 版本遗留的同名启动快捷方式。

所有实际动作默认关闭。选择自动解锁组件只完成注册，Provider 初始保持禁用，
安装器不会索取或保存 Windows 密码。

## 构建

构建并验证发布目录：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer.ps1 -StageOnly
```

安装 Inno Setup 6 后生成安装包：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer.ps1
```

输出：

```text
installer\output\BleProximityWake-0.1.0-win-x64.exe
```

构建脚本只收集明确列出的 Release 文件，不打包 PDB、主机配置、凭据、日志和诊断目录，
并生成包含 SHA-256 的 `release-manifest.json`。

## 安装行为

默认只安装托盘 Agent，并创建机器级登录启动项；每个登录用户运行独立的托盘实例和
用户配置。选择“自定义安装”后才能
勾选自动解锁组件。自动解锁安装脚本会：

1. 注册 x64 Credential Provider；
2. 安装并启动 LocalSystem Broker；
3. 初次安装保持 Provider 禁用；
4. 升级时保留已有登记和启用状态。

覆盖安装时取消选择自动解锁组件，会先撤销旧 Provider 和 Broker，再删除组件二进制
和加密凭据；不会留下仍可接受授权的旧服务。

安装完成后，先确认 Windows 原生 PIN、密码和 Windows Hello 登录正常，再从开始菜单
运行“登记自动解锁凭据”。Microsoft Account 必须输入真实账户密码，不能输入 PIN。
Agent 的 `autoUnlock.enabled` 仍是独立开关。

## 卸载

卸载程序先禁用并撤销 Credential Provider 注册、停止并删除 Broker 服务，再清除
DPAPI 密文、Provider 配置、所有本地用户的 Agent 数据、诊断数据和程序文件。

自动解锁组件安装时会把 Agent 的完整路径和 SHA-256 写入受管理员保护的 HKLM 配置，
Broker 只接受该映像发出的授权。升级必须通过本安装器完成，以同步刷新哈希。自动解锁
注册或卸载任一步失败时，安装器会中止并保留安装标记和文件，避免留下指向已删除 DLL
的 Credential Provider 注册。
Agent 运行时会在打开托盘菜单及启用自动解锁时重新查询 Broker 服务；服务重启不再要求
重启 Agent 才能刷新可用状态。Broker 协议管道名固定在程序内部，不提供安装或用户配置项。
Provider DLL 可能仍被
LogonUI 加载；这种情况下注册已经撤销，文件会在重启后完成清理。

## P5A 虚拟机验收

1. 准备 Windows 10 x64 和 Windows 11 x64 快照，并保留第二个管理员账户。
2. 默认安装，确认托盘启动、重启后自启动、普通锁屏登录正常。
3. 卸载，确认启动项、用户配置和程序目录清除。
4. 自定义安装自动解锁组件，确认 Provider 初始禁用且 Broker 正常运行。
5. 登记测试账户密码，确认原生密码/PIN仍可登录，再启用 Agent 自动解锁。
6. 覆盖安装同版本，确认配置、凭据和启用状态保留。
7. 完整卸载并重启，确认服务、Provider 注册、凭据和文件全部移除。
