# Windows 凭据提供程序自动解锁

首次安装和日常操作见 [用户使用手册](../docs/USER_GUIDE.md)，端到端业务链路见
[架构与业务流程](../docs/ARCHITECTURE.md)，测试和发布准入见
[测试与发布指南](../docs/TESTING_AND_RELEASE.md)。本文聚焦 Credential Provider、Broker、
凭据登记和紧急恢复。

本目录包含 Windows 自动解锁的 P0 可行性实现，并有意与当前 BLE 靠近唤醒路径隔离。

2026-07-14 已在一次性 Windows 11 虚拟机中确认 P0 零点击方案可行。测试将凭据绑定到 LogonUI 当前用户的 SID；获得授权后，枚举出的凭据数量从零变为一；请求默认自动登录凭据，并在无需点击的情况下返回桌面。这只是可行性结论，并不代表已达到生产可用标准，仍需验证重复执行能力和失败路径。

## P1 Broker 安全边界

P1 将可逆凭据和一次性授权从 LogonUI DLL 移至以 `LocalSystem` 身份运行的 `BleProximityUnlockBroker` 服务：

- Agent 管道接收已认证用户发出的授权请求，然后校验管道客户端的 SID 和会话、已登记 SID，以及该会话内是否存在 `LogonUI.exe`。
- Provider 管道仅允许 `SYSTEM` 访问，支持查看授权、一次性消费凭据和报告认证结果；查看和消费同时要求 Provider 进程所在会话与 Agent 授权会话一致。
- 授权只保存在 Broker 内存中，最长十秒后过期；服务运行期间，已消费的锁屏周期 ID 不能再次获得授权。
- 凭据消费采用 `Active -> Consuming -> Consumed` 事务。读取凭据或 DPAPI 解密在提交消费前失败时，授权会在原 TTL 内恢复；完整凭据准备后即保守地提交消费，即使客户端随后断开也不会重复发放密码。
- DPAPI LocalMachine 密文保存在 `%ProgramData%\BleProximityWake\credential.dat`，禁用权限继承，仅允许 `SYSTEM` 和本地管理员访问。
- Provider 只从注册表读取非敏感的 SID 和账户元数据，不包含 DPAPI 解密逻辑，也不通过注册表传递授权。

2026-07-15 已在一次性 Windows 11 虚拟机中完成 P1 验证。Broker 接受一次授权，Provider 通过仅限 `SYSTEM` 的管道消费授权，LSA 返回 `Status=0x00000000`。

随后于 2026-07-15 在使用 Microsoft Account 的 Windows 11 主机上完成 P2 验证。14:55，BLE Agent 触发唤醒，Broker 接受并消费一次授权，Provider 返回已登记的 Microsoft Account 凭据，LSA 报告 `Status=0x00000000`，会话随后变为 `SessionUnlock`。`config.sample.json` 默认保持禁用；纳入版本控制的主机 `config.json` 只能在完成下述分阶段检查后启用。

2026-07-17，Agent 增加“设备持续在场时由用户唤醒”入口。显示器关闭或 Modern Standby 后，只有检测到新的本地键鼠输入，并重新确认白名单网络、交流电、手机、近期手表广播和 LogonUI，才会向同一个 Broker 发放一次授权。该改动不改变 Provider 的凭据序列化和一次消费边界。

## 主机凭据登记

在管理员权限的 64 位 Windows PowerShell 中构建并安装 P1，然后登记本地配置文件用户名：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-P0Provider.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-P1Provider.ps1 -Configuration Release -IUnderstandThisCanAffectSignIn
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Set-P1Credential.ps1 -Username <profile-user> -IUnderstandThisCanAffectSignIn
```

对于本地账户，登记过程保存计算机名和本地用户名。对于关联 Microsoft Account 的配置文件，脚本读取当前 IdentityStore 映射，保存 `MicrosoftAccount\<login-email>`，同时将 Provider 磁贴绑定到该配置文件的本地 SID。此处必须输入真实账户密码，不能输入 Windows Hello PIN。Microsoft Account 密码可在本机之外重复使用，因此可逆保存该密码的影响范围大于保存专用本地账户密码。

启用 BLE 授权前，先锁定 Windows，确认普通 PIN 和密码登录均正常。使用以下命令检查非敏感登记元数据和 ACL：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-P1HostRegistration.ps1
```

凭据文件的预期 DACL 只向 `SYSTEM` 和本地管理员授予完全控制权限。诊断脚本不会读取或解密 `credential.dat`。

如果 Windows 返回 `Status=0xC000006D`，修改 Provider 代码前，应先在系统内置的密码登录选项中验证同一密码。主机排查中，该状态先后由两个原因引起：Microsoft Account 被错误登记为本地账户，以及输入了错误的 Microsoft Account 密码。`Status=0x00000000` 表示认证成功。

Agent 协议载荷经过 PowerShell 函数边界时必须保持为真正的 `byte[]`。当前实现会阻止数组展开，并采用异步管道读取和 3000 毫秒总响应超时。因此，Broker 通信故障会写入日志，而不会冻结 BLE 定时器和心跳。

EXE Agent 在首次授权和所有瞬时重试前都会绕过周期缓存重新读取网络白名单。Broker 管道名是固定内部协议，不接受用户自定义，避免 Agent 与 Broker 配置分叉。

Broker 接受单次授权后会立即通知 Provider；如果授权仍未被消费，会在 250、500 和 1000 毫秒后再次设置通知事件。重复通知不会生成新授权、延长有效期或再次读取密码，Provider 一旦消费授权即停止，用于降低 LogonUI 首次枚举时错过通知造成的延时。

2026-07-17 11:27 至 11:28，主机使用零固定等待连续测试 5 次，全部返回 `Status=0x00000000`。Provider 在 Broker 接受授权后 39 至 66 毫秒内消费，认证结果在 73 至 108 毫秒内返回，没有触发重复通知。重复通知因此保留为异常时序容错，而不是正常路径的固定步骤。

构建并打包 P1：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-P0Provider.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-P1VmPackage.ps1
```

在一次性虚拟机中解压 `ble-cp-p1-vm.zip`，然后在管理员权限的 Windows PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-P1VmEndToEnd.ps1
```

该脚本会安装 Provider 和 Broker，登记本地测试密码，锁定 Windows，三秒后发送一次性 Broker 授权，并将两份诊断日志复制到 VMware 共享的 `Temp` 目录。

## P0 验证内容

P0 用于验证 Windows 10/11 是否接受以下无需点击的事件驱动流程：

1. 工作站处于锁定状态。
2. 创建一个短期有效的注册表授权。
3. 通过命名事件唤醒 Provider。
4. Provider 调用 `ICredentialProviderEvents::CredentialsChanged`。
5. LogonUI 提供用户数组，Provider 将凭据绑定到已登记 SID。
6. `GetCredentialCount` 将索引 `0` 的凭据设为默认凭据，并启用自动登录。
7. `GetSerialization` 返回基于密码的 `KERB_INTERACTIVE_UNLOCK_LOGON` 缓冲区。

Windows 10 及更高版本可能使用 `CPUS_LOGON` 或 `CPUS_UNLOCK_WORKSTATION` 调用锁定工作站的 Provider。P0 同时支持两种场景，并根据实际场景选择 Kerberos 消息类型。

P0 尚未连接 BLE 监视器，而是使用延迟执行的管理员 PowerShell 测试触发器。P1 使用 LocalSystem Broker 和一次性 IPC 授权，替代注册表授权和直接 DPAPI 访问。

## 安全边界

P0 只能在满足以下条件的一次性 Windows 11 虚拟机中使用：

- 已创建虚拟机快照。
- 使用密码已知的专用本地测试账户。
- 准备第二个管理员账户。
- 已确认普通密码或 PIN 登录正常。
- 未配置 Credential Provider Filter 策略。

Provider 不会禁用 Microsoft 登录提供程序。即便如此，错误实现的 Credential Provider 仍可能干扰 LogonUI。不要在主力计算机上安装 P0。

## 构建

在普通的 64 位 Windows PowerShell 窗口中运行：

```powershell
cd C:\src\bluetooth-unlock-windows\credential-provider
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-P0Provider.ps1
```

测试会构建 Debug 和 Release 两种 x64 DLL，校验 PowerShell 语法、PE 架构、必需的 COM 导出函数、Provider 会话绑定和 Broker 消费事务恢复。

## 虚拟机安装

将仓库或 `credential-provider` 目录复制到虚拟机，在管理员权限的 64 位 Windows PowerShell 中运行：

```powershell
cd <repo>\credential-provider
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-P0Provider.ps1 -Configuration Release
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-P0Provider.ps1 -Configuration Release -IUnderstandThisCanAffectSignIn
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Set-P0Credential.ps1 -Username <local-user> -IUnderstandThisCanAffectSignIn
```

脚本以安全字符串方式读取密码，使用 DPAPI LocalMachine 加密，并保存到：

```text
HKLM\SOFTWARE\BleProximityWake\CredentialProviderP0
```

密码不会通过命令行传递，也不会写入项目文件或日志。

执行一次 `Win+L`，确认普通 Windows 密码或 PIN 磁贴仍可使用，然后再运行自动化测试。

对于启用了 `Temp` 共享目录的 VMware 测试机，主机测试包还包含一键端到端脚本。在虚拟机中解压测试包，然后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-P0VmEndToEnd.ps1
```

该脚本会请求管理员权限、安装 Release DLL、提示输入一次当前本地账户密码、执行延迟锁屏测试，并将诊断日志复制到 VMware 共享的 `Temp` 目录。密码始终留在虚拟机内，不会复制到共享目录。

## 零点击测试

在已解锁虚拟机的管理员窗口中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-P0LockTest.ps1 -TriggerDelaySeconds 3 -IUnderstandThisCanAffectSignIn
```

脚本调用 `LockWorkStation`，在锁定会话中继续等待三秒，创建十秒有效的授权，然后触发 Provider 事件。预期结果：虚拟机无需点击即可返回桌面。

全局授权事件的 ACL 只允许 `SYSTEM` 和已提升权限的本地管理员访问。这足以支持 P0 的管理员测试触发器；P1 使用由 Broker 控制的 IPC 替代该事件授权，以供普通用户 Agent 使用。

手工或自动登录后，检查：

```text
%ProgramData%\BleProximityWake\credential-provider-p0.log
```

成功调用序列应包含：

```text
Provider.SetUsageScenario
Provider.SetUserArray Count=1 ConfiguredSidVisible=1
Provider.Advise
Provider authorization event Authorized=1
Provider.CredentialsChanged Hr=0x00000000
Provider.GetCredentialCount Configured=1 UserVisible=1 Authorized=1 Count=1 Default=0 AutoLogon=1
Provider.GetCredentialAt Index=0
Credential.GetUserSid Hr=0x00000000
Credential.SetSelected AutoLogon=1
Credential.GetSerialization returning credential
Credential.ReportResult Status=0x00000000
```

只有已登记 SID 存在于 LogonUI 当前用户数组中时，Provider 才会枚举其凭据。该限制可防止过期或不匹配的登记信息被提交给其他账户。

如果系统改为显示登录按钮，应记录操作系统版本和日志。这表示 Windows 触发了额外确认机制，此时应将 P0 视为一次点击方案，而不是零点击方案。

## 禁用与卸载

立即禁用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Disable-P0Provider.ps1
```

删除注册信息和加密测试凭据：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Uninstall-P0Provider.ps1 -RemoveEncryptedCredential
```

卸载后重启虚拟机。如果 DLL 仍被加载，注册信息实际上已经删除；重启后再删除 `%ProgramFiles%\BleProximityWake\CredentialProviderP0`。
