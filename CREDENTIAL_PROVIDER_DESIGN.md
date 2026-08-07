# Credential Provider 自动解锁方案

本文描述自动解锁组件的技术设计。用户启用步骤见
[用户使用手册](docs/USER_GUIDE.md)，端到端状态机见
[架构与业务流程](docs/ARCHITECTURE.md)，恢复排查见
[故障排查手册](docs/TROUBLESHOOTING.md)。

## 1. 目标和范围

在现有 Apple Watch / iPhone BLE 靠近、网络白名单、锁屏状态和外接电源条件全部满足后，自动解锁当前 Windows 会话。

第一版只支持：

- Windows 10/11 x64。
- 一个预先登记的本地账户，或映射到本地用户 SID 的 Microsoft Account。
- 已登录会话的解锁；兼容 Windows 10/11 合并后的 `CPUS_LOGON` 以及策略要求的 `CPUS_UNLOCK_WORKSTATION`。
- 保存并提交本地账户密码，或 Microsoft Account 真实密码。
- 保留微软原有密码、PIN、指纹和人脸登录入口。

第一版不支持：

- 开机首次登录、注销后登录、远程桌面和 UAC 凭据界面。
- Entra ID、域账户和无密码账户；Microsoft Account 已在 2026-07-15 主机实测支持。
- 直接提交 Windows Hello PIN。
- Credential Provider Filter，以及替换或隐藏系统 Provider。

这是便利功能，不是强认证。BLE 广播可被复制或中继，保存静态 Windows 密码也会扩大本机失陷后的影响。用户已明确接受该风险，以快速实现为优先。

## 2. 技术结论

采用 Credential Provider V2，不采用普通 `SendInput`，也不依赖登录页焦点。Provider 将账户域、用户名和密码封装为 `KERB_INTERACTIVE_UNLOCK_LOGON`，由 `GetSerialization` 返回给 LogonUI/LSA 完成认证。本地账户使用计算机名和本地用户名；Microsoft Account 使用 `MicrosoftAccount` 和登录邮箱，并继续用本地用户 SID 绑定 LogonUI 磁贴。

不能把 Windows Hello PIN 当成普通密码提交。MVP 必须登记真实账户密码；若账户平时只使用 PIN，需要先通过 Windows 自带“密码”登录方式确认密码有效。

自动提交存在一个必须先实测的系统边界：`SetSelected` 可通过 `pbAutoLogon=TRUE` 请求立即认证，但 Windows 10/11 在认为自动登录不合适时可能显示“登录”按钮作为 speed bump。因此开发第一步不是完整实现，而是制作最小 Provider 骨架，验证目标 Windows 11 上能否真正零点击解锁。

## 3. 组件设计

### 3.1 现有 Presence Agent

继续使用 `Start-BleProximityWake.ps1`：

- 负责 BLE、手机二次确认、RSSI、网络白名单、锁屏、交流电和冷却状态机。
- 唤醒并顶出登录页后，向 Broker 发送一次 `AUTHORIZE_UNLOCK`。
- 请求只包含当前用户 SID、会话 ID、锁屏周期 ID 和随机请求 ID，不包含密码。
- Broker 返回 `accepted` 后不重试；本次失败必须手工登录，避免密码错误导致账户锁定。

### 3.2 Auto Unlock Broker

新增 LocalSystem Windows 服务 `BleProximityUnlockBroker`：

- 安装时登记一个本地账户 SID 和密码。
- 密码使用 DPAPI LocalMachine 加密，保存到 `%ProgramData%\BleProximityWake\credential.dat`。
- 使用两个带 ACL 的命名管道：Agent 提交授权，Provider 消费授权。Provider 查询和消费时，Broker 从实际客户端进程取得 Windows 会话 ID，并要求与 Agent 授权会话一致。
- 收到 Agent 请求时要求目标 WTS 会话处于 `Active`，并确认该会话中存在 `LogonUI.exe`；同时检查 SID 是否匹配、是否处于冷却期。该组合比只检查进程更严格，但 Windows 公共 API 不提供一个可直接读取的通用“已锁定”布尔值，因此仍属于保守推断。
- 创建内存中的单次授权，默认 5 秒过期，并触发全局命名事件通知 Provider。
- Provider 消费使用 `Active -> Consuming -> Consumed` 事务；读取或解密瞬时失败在原 TTL 内恢复，完整凭据准备后提交消费。每个锁屏周期最多自动尝试一次。
- 不在日志、配置、异常文本或转储友好结构中记录明文密码。

快速 MVP 使用 DPAPI LocalMachine，而不先引入 LSA Private Data。安全性不是本阶段目标，但仍保留最基本的 ACL、单次消费和内存清理，防止普通进程直接读取密码。

### 3.3 Credential Provider V2

新增 x64 C++ COM DLL `BleProximityCredentialProvider.dll`：

- 实现 `ICredentialProvider`、`ICredentialProviderCredential` 和 `ICredentialProviderCredential2`。
- 接受 `CPUS_LOGON` 和 `CPUS_UNLOCK_WORKSTATION`，按系统传入场景分别封装 `KerbInteractiveLogon` 或 `KerbWorkstationUnlockLogon`；没有短期授权时不枚举磁贴，因此不会在开机登录时自动提交。
- 只为登记 SID 枚举一个“靠近自动解锁”磁贴。
- `GetUserSid` 返回登记账户 SID，使磁贴归入正确用户。
- `Advise` 保存 `ICredentialProviderEvents` 和上下文；后台等待 Broker 的全局事件。
- 授权到达后调用 `CredentialsChanged` 触发 LogonUI 重新枚举。
- 有有效授权时 `SetSelected` 返回 `pbAutoLogon=TRUE`。
- `GetSerialization` 从 Broker 单次获取密码，调用 `KerbInteractiveUnlockLogonInit` / `KerbInteractiveUnlockLogonPack`，返回认证包和序列化缓冲区。
- `ReportResult` 记录不含凭据的状态码，并把结果通知 Broker；失败后本锁屏周期禁用自动重试。
- `UnAdvise`、DLL 卸载和错误路径全部停止等待线程、释放 COM 引用并清零敏感缓冲区。

Provider 仅负责凭据呈现和序列化，不做 BLE 扫描、网络判断或长期密码保存。

## 4. 触发时序

1. 用户锁屏，Agent 确认 `Locked=True`，并开始新的锁屏周期。
2. 触发方式二选一：手表先离开再靠近；或者设备持续在场，用户在屏幕关闭/Modern Standby 后通过键鼠唤醒。
3. 靠近触发时 Agent 主动点亮显示器；交互唤醒时由用户输入负责恢复系统。
4. Agent 重新确认白名单网络、交流电、手机、近期手表广播和 LogonUI；真正调用 Broker 前再次绕过周期缓存刷新网络，所有瞬时重试执行同样检查。
5. Broker 验证调用者、用户 SID、会话和锁屏周期，生成 5 秒单次授权并设置全局事件。
6. Provider 收到事件后调用 `CredentialsChanged`。
7. LogonUI 重新枚举并选中磁贴；Provider 请求 `pbAutoLogon=TRUE`。
8. Provider 从 Broker 消费密码；Broker 同时校验 Provider 调用会话，其他控制台或 RDP 会话不能消费本次授权，然后返回 `KERB_INTERACTIVE_UNLOCK_LOGON`。
9. LSA 验证成功后解锁；失败则显示系统错误并要求手工登录。

如果第 7 步在目标 Windows 11 上始终出现必须点击的 speed bump，MVP 降级为“自动准备凭据，用户点击一次登录”。不通过过滤其他 Provider 或模拟安全桌面点击来强行绕过。

## 5. 配置草案

`config.json` 只保存非敏感开关：

```json
{
  "autoUnlock": {
    "enabled": false,
    "brokerPipeName": "BleProximityWake.UnlockAgent",
    "loginPageDelayMilliseconds": 0,
    "authorizationTtlMilliseconds": 5000,
    "brokerResponseTimeoutMilliseconds": 3000,
    "oneAttemptPerLockCycle": true,
    "requireAllowedNetwork": true,
    "requireAcPower": true,
    "requirePhonePresence": true,
    "triggerOnArrival": true,
    "triggerOnInteractiveWake": true,
    "interactiveWakeMinimumPriorIdleSeconds": 1,
    "interactiveWakeInputFreshSeconds": 2,
    "interactiveWakeMaxWatchAgeSeconds": 5,
    "interactiveWakeConfirmationMilliseconds": 6000,
    "interactiveWakeAllowIdleFallback": true,
    "interactiveWakeLoginPageDelayMilliseconds": 0
  }
}
```

SID、加密密码和锁屏周期状态由 Broker 管理，不写入项目配置。

`brokerResponseTimeoutMilliseconds` 限制 Agent 等待 Broker 响应的总时间。管道 payload 必须作为 `byte[]` 返回，避免 PowerShell 函数输出枚举把它变成 `object[]`，造成 Broker 等待未完整 payload、Agent 等待响应的双向阻塞。

交互唤醒通过隐藏消息窗口监听 `GUID_CONSOLE_DISPLAY_STATE` 和系统 Resume 消息，并使用 `GetLastInputInfo` 验证锁屏后确实出现了新的本地输入。显示器 On 和 Resume 只提前清理旧 BLE 队列并重建 Active Watcher，不能单独建立授权候选。输入边沿的最低先前空闲时间为 1 秒，同时 `SessionLock` 后抑制输入 2 秒，兼顾快速唤醒和 `Win + L` 防误触发。锁屏界面仍亮时的新输入、显示器关闭后的新输入和 Modern Standby Resume 后的新输入均可建立候选；睡眠前的旧 BLE 广播不会直接放行。手表时间戳必须满足 `interactiveWakeMaxWatchAgeSeconds`，网络、手机和 LogonUI 必须在确认窗口内重新就绪。确认后立即请求授权；重新靠近路径也取消固定等待，Broker 在授权未被消费时于短时间内重复通知 Provider，覆盖 LogonUI 首次枚举时序。手机通常仍需满足配置的多次命中，只有达到 `strongRssiSingleHitThreshold` 的近距离强信号才采用单次快速确认。没有新输入时不授权。

Broker 还将命名管道客户端的实际进程映像与安装时写入 HKLM 的
`TrustedAgentPath` 和 `TrustedAgentSha256` 比对。仅 SID 相同但进程路径或哈希不匹配
的客户端不能签发授权。Agent 升级必须由安装器同步刷新哈希，否则自动解锁会失败关闭。

托盘暂停只在 Broker 尚未接受授权时生效。Broker 接受请求后，Agent 会暂时拒绝暂停，
直到 Windows 完成本次认证或会话状态结束该请求；已经交给 Windows 的凭据提交不能可靠撤回。

## 6. 注册、恢复和卸载

安装器执行以下动作：

- 复制 x64 DLL 和 Broker 到 `%ProgramFiles%\BleProximityWake`。
- 注册 COM CLSID 和 Credential Provider CLSID。
- 安装 LocalSystem Broker 服务并设置严格文件 ACL。
- 交互式验证本地账户密码后才写入加密数据。
- 默认保持 `autoUnlock.enabled=false`，由用户完成手工登录回退测试后再开启。

必须同时提供离线恢复脚本：删除 Credential Provider 注册项、停止并删除 Broker 服务。系统 Provider 永远保留，因此即使自定义 Provider 崩溃，仍可选择密码、PIN 或生物识别登录。

### 6.1 产品化部署简化方案

最终产品建议简化安装和文件数量，但不合并运行时安全边界：

- 将托盘 Agent、Broker 服务入口、安装、卸载和诊断命令编译到统一的 `BleProximityWake.exe`。
- 通过启动参数区分运行模式，例如 `--tray`、`--service`、`--install` 和 `--uninstall`。
- Credential Provider 继续保留为独立的 x64 COM DLL，由 `LogonUI.exe` 加载。
- 安装包一次完成 DLL 注册、Broker 服务安装、用户启动项创建、ACL 设置和初始配置。

磁盘交付物可收敛为一个主 EXE、一个 Credential Provider DLL 和必要配置。运行时仍然需要两个主 EXE 进程：一个在 Session 0 中以 `LocalSystem` 服务运行，一个在当前用户会话中负责 BLE、网络判断和托盘界面。这是 Windows 会话隔离决定的，不能可靠地合并成单一进程。

不建议取消 Broker，让 Credential Provider 直接读取 DPAPI LocalMachine 密码和用户进程写入的授权状态。该方案虽然能减少一个服务，但会把解密和授权判断放入 `LogonUI.exe`，增加授权伪造、重放、并发错误和登录界面故障风险。

因此推荐的最终形态为：**一个统一 EXE、一个 Credential Provider DLL、一个安装包；运行时保持一个 Windows 服务和一个用户托盘进程。**

## 7. 开发阶段

### P0：零点击可行性验证

- 基于 Windows SDK Credential Provider V2 接口建立 x64 DLL。
- 测试密码由虚拟机脚本交互输入并使用 DPAPI LocalMachine 加密，不硬编码、不进入 Git。
- 验证 `CredentialsChanged -> SetSelected(TRUE) -> GetSerialization` 是否无需点击即可解锁。
- 记录 Windows 版本、策略、调用顺序和是否出现 speed bump。

通过条件：虚拟机连续 20 次锁屏均能自动提交，且原有登录方式始终可用。若失败，先确认降级的一次点击方案，再决定是否继续。

当前状态（2026-07-14）：P0 代码、注册/禁用/卸载脚本、延时锁屏测试触发器和诊断日志已实现。Debug/Release x64 构建、PowerShell 语法、COM 导出、PE 架构、凭据序列化单元测试和 MSVC Native Code Analysis 均通过。一次性 Windows 11 虚拟机已完成真实零点击解锁：LogonUI 枚举到登记 SID，Provider 在授权事件后返回唯一默认凭据和 `AutoLogon=1`，用户观察到系统自动回到桌面。该结果确认技术链路可行，但尚未达到连续 20 次和异常场景验收标准。操作步骤见 `credential-provider/README.md`。

### P1：Broker 和凭据登记

- 实现 Broker、DPAPI 存储、命名管道 ACL、单次授权和一次尝试限制。
- 移除 Provider 中的硬编码密码。
- 增加安装、禁用、卸载和离线恢复脚本。

当前状态（2026-07-15）：P1 代码已实现。LocalSystem Broker 分离 Agent/Provider 两条管道，核验调用者 SID、会话、登记账户和锁屏 LogonUI，凭据改存 `%ProgramData%\BleProximityWake\credential.dat`，Provider 已移除 DPAPI 解密和注册表授权路径。Debug/Release 构建、Broker 自测、Provider Native Code Analysis 和原 BLE 回归均通过；一次性 Windows 11 虚拟机实测中 Broker 成功接受并消费授权，Provider 通过 `SYSTEM` 专用管道取得凭据，LSA 返回 `Status=0x00000000`。

2026-08-07 代码审查后进一步收紧 P1：Provider 查询和消费绑定实际客户端会话；消费改为可恢复事务；EXE Agent 每次 Broker 请求前强制刷新网络；管道名收敛为固定协议常量。新增自测覆盖会话不匹配拒绝和 `Consuming` 恢复。

### P2：接入靠近与交互唤醒状态机

- 在现有靠近唤醒成功路径和新增交互唤醒确认路径后调用 Broker。
- 增加 `autoUnlock` 配置校验和不含凭据的诊断日志。
- 保留自动锁屏、网络白名单、交流电和手表地址学习边界。

当前状态（2026-08-07）：P2 已同时支持重新靠近和交互唤醒。交互模式允许设备持续在场，用户从屏幕关闭或 Modern Standby 通过键鼠恢复后，在默认 6 秒窗口内重新确认网络、交流电、手机、手表和 LogonUI。默认要求真实的显示器关闭或 Resume 证据，宽松 idle fallback 仅作为显式兼容选项。示例配置仍保持 `autoUnlock.enabled=false`。手工 `Wake test`、`-WakeNow`、`-ForceWakeTest` 不会触发自动解锁。Broker 可对同一份未消费授权在 250、500、1000 毫秒时间点重复通知 Provider；Agent 对瞬时授权故障最多短暂重试三次，但不会生成第二份已接受授权、延长 TTL 或再次提交密码。每次请求前均重新读取网络，Provider 查询和消费还必须匹配授权会话。

### P3：验证

- Windows 11 虚拟机：错误密码、密码修改、Broker 停止、Provider 崩溃、待机恢复和重启。
- 备用本地账户实机：先保持自动解锁关闭，只验证 Provider 可见和手工回退。
- 真实账户实机：开启后完成至少 30 次锁屏/靠近测试，再考虑随托盘启动。

当前进度：Windows 11 虚拟机和受控主机已经验证零点击认证链路、原生密码/PIN 回退、
Microsoft Account 身份映射、错误密码失败路径和安装版覆盖升级。公开发布前仍需完成
Windows 10/11 干净环境矩阵、连续 30 次自动解锁、密码变更和 Broker 故障恢复测试。

## 8. 验收标准

- 重新靠近模式满足“锁屏 + 白名单网络 + 交流电 + 手表/手机靠近”后触发一次自动认证。
- 交互唤醒模式允许设备持续在场，但必须检测到屏幕关闭/Resume 后的新本地输入，并在恢复后重新确认所有环境条件。
- 非白名单、使用电池、目标 WTS 会话非 Active、该会话没有 LogonUI、自动亮屏但没有新输入时不触发。
- 每个锁屏周期最多提交一次密码，授权超过 5 秒失效。
- 密码不出现在 `config.json`、Git、普通日志或命令行参数中。
- Broker 或 Provider 不可用时，现有靠近唤醒仍工作，系统登录方式仍可使用。
- 卸载或离线删除注册项后可完全回到原有登录链路。

## 9. 代码布局建议

```text
credential-provider/
  BleProximityCredentialProvider.sln
  provider/                 # C++ Credential Provider V2 DLL
  broker/                   # LocalSystem 服务
  shared/                   # 协议、SID、状态码定义
  installer/                # 安装、登记、禁用、卸载、离线恢复
  tests/                    # Broker 协议和状态机测试
```

## 10. 参考

- Microsoft V2 Credential Provider Sample: https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/credential-provider/
- `ICredentialProviderCredential::SetSelected`: https://learn.microsoft.com/en-us/windows/win32/api/credentialprovider/nf-credentialprovider-icredentialprovidercredential-setselected
- `ICredentialProviderCredential::GetSerialization`: https://learn.microsoft.com/en-us/windows/win32/api/credentialprovider/nf-credentialprovider-icredentialprovidercredential-getserialization
- `ICredentialProviderCredential2`: https://learn.microsoft.com/en-us/windows/win32/api/credentialprovider/nn-credentialprovider-icredentialprovidercredential2
