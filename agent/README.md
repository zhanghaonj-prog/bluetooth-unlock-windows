# Bluetooth Unlock EXE Agent

面向普通用户的安装和操作流程见 [用户使用手册](../docs/USER_GUIDE.md)，业务状态机见
[架构与业务流程](../docs/ARCHITECTURE.md)，异常定位见
[故障排查手册](../docs/TROUBLESHOOTING.md)。本文重点描述 Agent 构建、配置和内部行为。

产品名称：**蓝牙解锁 / Bluetooth Unlock**。`BleProximityWake` 保留为程序、配置和协议的内部兼容标识。

该目录是将现有 PowerShell 常驻程序迁移为 Windows 10/11 x64 EXE 的实现。

## 当前状态

已经实现：

- `.NET Framework 4.8`、WinForms、x64 工程骨架。
- Windows 10/11 应用兼容清单和 Per-Monitor V2 DPI。
- 当前用户单实例 Mutex。
- 托盘图标、退出、诊断复制和数据目录入口。
- Windows 和 BLE API 能力快照；自动解锁 Broker 状态在打开托盘菜单及启用功能时实时刷新。
- 独立用户配置和日志目录。
- `WatchAndPhone`、`PhoneOnly` 两种设备在场策略。
- 靠近唤醒、自动解锁、离开锁屏分别选择设备组合。
- 自动解锁默认要求手机和手表，并要求恢复后的新鲜广播。
- 原生 WinRT BLE watcher、5000 条队列上限、模式切换和卡死恢复。
- Apple 厂商数据通配匹配、临时地址学习和已学习地址弱信号路径；手表多次命中必须来自同一临时地址。
- 手机固定地址/名称识别、普通双命中和强信号单次快速路径。
- 靠近命中窗口与离开丢失窗口分离。
- `SessionSwitch`、系统 Resume、真实网络名称、SSID 和交流电判断。
- 网络 Profile 和 SSID 支持不区分大小写的精确匹配及 `*` 通配匹配。
- 只有“锁屏 + 白名单网络 + 外接电源”使用 Active + 250ms，其余 Passive + 1000ms。
- 托盘实时显示扫描、网络、设备及动作状态，支持暂停与重新检测。
- schema 5 动作状态机：支持重新靠近与用户交互唤醒两种自动解锁触发。
- 离开锁屏先在设备在场时武装，要求所选设备全部持续离开且用户达到空闲门槛。
- 一次性显示/输入唤醒和 `LockWorkStation` 执行器。
- 唤醒、离开锁屏默认均关闭，旧配置导入也不会自动开启。
- P4A 靠近自动解锁：复用 LocalSystem Broker 协议，按锁屏周期一次性授权，
  默认要求白名单网络、外接电源和 `WatchAndPhone`。
- 每次自动解锁请求和瞬时重试前都强制刷新网络白名单，周期状态缓存只用于显示和扫描模式。
- P4B 交互自动解锁：设备一直在旁边时，显示器 On 和系统 Resume 边沿只负责提前
  恢复 BLE；新的本地输入才建立自动解锁候选，
  清除旧 BLE 证据后在 6 秒内重新确认设备。
- 自动解锁默认关闭，旧配置导入不会开启；Agent 不读取或保存 Windows 密码。
- Broker 管道名是固定内部协议，不再暴露为 EXE 用户配置。
- 唤醒调用失败后按 2 秒间隔最多重试 3 次，不要求设备再次离开，也不会无限发送输入。
- 现有 PowerShell `config.json` 显式导入。
- 无第三方测试框架的状态机、运行链、配置和启动烟雾测试。

尚未迁移：

- Apple Watch/iPhone 图形化登记和校准。
- PowerHold。
- 靠近唤醒和离开锁屏的正式机稳定性验收。
- P4B 的传统 S3 睡眠实机恢复验收。
- P5A 安装包的 Win10/Win11 虚拟机安装、升级、卸载和故障恢复验收。

当前 EXE 已完成本机安装升级、靠近唤醒、离开锁屏、重新靠近自动解锁和交互唤醒自动解锁验证，可用于受控测试和本机日常验证。面向公开发布前仍需完成多机型、Win10/Win11 VM、密码变更和长期连续稳定性验收。

## 构建

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Build-Agent.ps1 -Configuration Release
```

输出：

```text
agent\bin\Release\BleProximityWake.Agent.exe
agent\bin\Release\BleProximityWake.Core.dll
```

标准开发机可以通过 Visual Studio/MSBuild 和 `.NET Framework 4.8 Developer Pack` 构建。
当前机器没有 4.8 Developer Pack，构建脚本会自动使用 Visual Studio 2022 自带的
Roslyn 编译器和系统 `.NET Framework 4.8` 运行程序集，不需要下载额外依赖。

## 测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Test-Agent.ps1 -Configuration Release
```

测试包括：

- 默认设备组合。
- 手机和手表共同在场。
- 仅手机在场。
- 待机恢复后的新鲜广播要求。
- Apple 厂商数据通配和显式地址优先级。
- matcher 配置严格校验：地址、UUID、十六进制前缀和通配模式非法时拒绝启动，不静默修正。
- 手表地址学习、轮换和已学习地址弱信号路径。
- 手机强信号单次路径、普通双命中和过期广播拒绝。
- 靠近命中窗口与离开丢失窗口。
- Passive/Active 扫描条件。
- 伪 BLE 源驱动的完整 Agent 运行链和 Resume 清队列。
- 旧配置函数导入和 EXE 命令行导入。
- 设置保存和重新加载。
- 非法模式拒绝。
- EXE 无托盘启动、配置创建和日志创建。
- Broker 协议载荷、真实命名管道收发、授权门槛、同周期防重复、永久拒绝和有限重试。
- 网络 Profile/SSID 通配匹配及每次 Broker 请求前的强制网络刷新。
- 唤醒动作失败后的 2 秒间隔、最多 3 次有限重试。
- Broker 自测覆盖 Provider 会话绑定和消费事务恢复；Provider 测试覆盖凭据序列化与 COM 生命周期。

## 用户数据

默认目录：

```text
%LOCALAPPDATA%\BleProximityWake\
  agent-settings.json
  logs\
```

调试或测试时可以设置：

```text
BLE_PROXIMITY_WAKE_DATA_DIR
```

EXE 配置与现有 PowerShell `config.json` 隔离，避免迁移未完成时覆盖正式运行参数。

EXE 配置契约：

- `network.allowedProfileNames` 和 `network.allowedSsids` 是 EXE 支持的网络标识，均支持不区分大小写的精确值或 `*` 通配；不支持旧 PowerShell 的 DNS 后缀和网卡别名字段。
- `network.enabled=true` 且两个白名单数组都为空时失败关闭，扫描保持低功耗且不执行系统动作。
- 周期网络结果缓存 5 秒用于托盘状态和扫描模式；自动解锁真正提交 Broker 前以及每次重试前都强制刷新。
- `autoUnlock.requireAllowedNetwork` 和 `requireAcPower` 控制自动解锁硬门槛；自动锁屏在启用网络过滤时同样要求白名单命中，没有独立的 `autoLock.requireAllowedNetwork` 字段。
- `brokerPipeName` 不是 EXE 配置。Agent、Broker 和 Provider 使用固定内部协议名；旧配置中的同名字段导入时忽略，后续保存会移除。

显式导入现有配置：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Import-LegacyConfig.ps1
```

导入会写入 `%LOCALAPPDATA%\BleProximityWake\agent-settings.json`，不会修改
`config.json`。它会迁移设备匹配、RSSI、地址学习、网络白名单和扫描周期；
现有配置同时要求手表与手机时，会将对应策略设为 `WatchAndPhone`。动作参数会迁移，
但 `actions.wake.enabled` 和 `actions.autoLock.enabled` 始终保持 `false`，必须显式启用。

不显示托盘、只运行真实 BLE 观察后自动退出：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Observe-Agent.ps1 -Seconds 15
```

观察模式使用隔离的临时配置目录，只输出检测日志，不执行唤醒、锁屏或自动解锁。

锁屏/解锁观察：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Observe-LockCycle.ps1
```

脚本会把当前连接的真实网络配置文件名临时加入隔离测试白名单。启动后按提示执行
`Win + L`，等待 10 秒，再手工解锁。日志应显示：

- 解锁时 `Passive`。
- 锁屏、测试白名单命中且接通电源时 `Active`。
- 锁屏/解锁、Display 和输入序列变化。
- 手表和手机在场状态。

隔离测试结果保存在
`%LOCALAPPDATA%\BleProximityWake\diagnostics\lock-observe-<时间>\`。

隔离靠近唤醒实测：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Test-WakeAction.ps1
```

该脚本只在独立数据目录中临时启用唤醒，自动锁屏保持关闭，也不连接自动解锁
Broker。按提示先让设备离开、锁屏、等待武装，再将设备靠近；成功日志应包含：

```text
Action=WakeToLogin Reason=arrival-confirmed Succeeded=True
```

结果保存在 `%LOCALAPPDATA%\BleProximityWake\diagnostics\wake-action-<时间>\`。
如果正式 PowerShell 常驻程序或其他 EXE Agent 仍在运行，脚本会列出冲突 PID 并拒绝
启动测试。

隔离离开锁屏实测：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Test-AutoLockAction.ps1
```

该脚本只临时启用离开锁屏。先让手机和手表都在电脑旁约 20 秒完成武装，再将二者
同时拿远且不要操作键鼠。Windows 锁定后手工登录，并让设备继续保持远离 15 秒；
系统不应再次锁定。结果保存在
`%LOCALAPPDATA%\BleProximityWake\diagnostics\auto-lock-action-<时间>\`。

隔离靠近自动解锁实测：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Test-AutoUnlockArrival.ps1
```

该脚本要求现有 P1 Broker 和 Credential Provider 已安装、启用并已正确登记密码。
它只在独立数据目录临时启用 P4A 自动解锁，不读取或修改登记凭据，同时关闭普通唤醒
和离开锁屏。测试时先让所需设备远离，锁屏并等待武装，再将设备靠近。成功时应直接
进入桌面，Agent 日志应出现：

```text
AutoUnlock=accepted
UnlockAttempted=True
UnlockBroker=Ok
```

失败时使用正常密码/PIN 登录，不要连续重试；测试目录会保留 Agent 日志，并尽可能
复制 Broker 与 Credential Provider 诊断日志。

隔离交互唤醒自动解锁实测：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Test-AutoUnlockInteractiveWake.ps1
```

测试期间手机和手表始终放在电脑旁。脚本关闭“重新靠近”触发、普通唤醒和离开锁屏，
只启用 P4B。启动后等待约 15 秒，按 `Win + L`，再等待至少 5 秒并按一次 Space。
交互边沿会清空旧在场证据并重启 Active 扫描；只有触发后重新收到所选设备的新广播
才会调用 Broker。成功日志应依次包含：

```text
Interactive=confirming:interactive-input
Interactive=confirmed:interactive-input
AutoUnlock=accepted
```

2026-07-26 本机锁屏测试已经确认：

- 解锁状态为 Passive。
- 锁屏、测试白名单命中且接通电源时切换为 Active。
- 手表和手机在锁屏 Active 模式下均能达到在场条件。
- 手工登录后立即切回 Passive。
- 测试周期没有队列丢弃或过期广播。

2026-07-26 16:20 隔离靠近唤醒实测已经确认：

- 锁屏后先进入 `wake-armed-waiting-for-arrival`。
- `16:20:28.771` 手表和手机满足靠近策略并触发一次 `WakeToLogin`。
- Win32 执行结果成功，ExecutionState、显示器消息、鼠标和 Space 输入均已发送。
- `16:20:29.059` 显示状态变为 On，动作请求到屏幕状态变化约 288 ms。
- 后续状态为 `wake-not-armed`，没有重复唤醒。
- 用户感知约 5 秒主要是等待手表广播达到 RSSI 门槛，不是 Win32 动作延迟。

2026-07-26 16:29 隔离离开锁屏实测已经确认：

- `16:27:57.632` 手机和手表都在场后进入 `auto-lock-armed`。
- 两类设备均超过离开窗口后，`16:29:09.376` 调用 `LockWorkStation` 成功。
- `16:29:09.983` 会话报告 `Locked=True`。
- 锁屏期间未再次调用锁屏动作。
- 用户确认手工登录后没有重复锁屏；自动化测试同时覆盖“解锁后设备仍缺席时保持
  未武装”，必须等设备重新回到电脑旁才允许再次武装。

2026-07-26 17:07 P4A 隔离靠近自动解锁实测已经确认：

- 锁屏、白名单网络和外接电源三个门槛均命中，扫描切换为 Active。
- `17:07:55.422` 手机和手表同时满足 `WatchAndPhone`，提交一次 Broker 授权。
- Broker 接受并消费授权，Credential Provider 返回凭据，认证结果
  `Status=0x00000000`、`Substatus=0x00000000`。
- `17:07:55.799` Agent 收到 `Broker=Ok`，无重试、无错误。
- `17:07:56.108` 会话变为解锁；从在场条件满足到解锁约 686 ms。
- 用户确认直接进入桌面，体感延迟约 2 秒；差值主要是设备靠近后的 BLE 广播等待。

2026-07-26 17:29 P4B 锁屏后按键自动解锁实测已经确认：

- 手机和手表在锁屏前已经在场，P4A 重新靠近触发保持关闭。
- `17:29:38.536` Space 输入形成 `interactive-input`，清空旧证据并重启 Active 扫描。
- `17:29:39.094` 触发后的手机和手表新广播通过确认，BLE 重新确认约 558 ms。
- Broker 接受并消费授权到 Windows 认证成功约 76 ms，认证状态和子状态均为
  `0x00000000`，没有重试或错误。
- `17:29:39.785` 会话报告解锁；从交互触发到会话解锁约 1.25 秒。
- 用户确认直接进入桌面，用户可见延迟约 0.5 秒。

2026-07-26 17:45 P4B Modern Standby 恢复自动解锁实测已经确认：

- 手机和手表始终在电脑旁，锁屏后手工进入 Modern Standby。
- 第一次 Space 点亮屏幕；`17:45:55.549` 的 `display-on` 边沿形成交互候选，
  清空休眠前证据并重启 Active 扫描。
- `17:45:56.840` 收到触发后的手机和手表新广播，约 1.29 秒完成 BLE 重新确认。
- Broker 在 `17:45:56.887` 接受授权，`17:45:57.140` 返回 Windows 认证成功，
  状态和子状态均为 `0x00000000`。
- `17:45:57.840` Agent 确认会话已解锁；从首次显示器点亮事件到解锁约 2.29 秒。
- 整个锁屏周期只有一次 BLE 恢复和一次授权，没有确认超时、重复授权或第二次按键。
- 用户确认第一次 Space 直接进入桌面，体感约 1 秒。

## 设备组合

支持值：

```text
WatchAndPhone
PhoneOnly
```

默认值：

```text
靠近唤醒：PhoneOnly
自动解锁：WatchAndPhone
离开锁屏：PhoneOnly
```

托盘菜单可以分别修改三个策略，修改后立即持久化到 `agent-settings.json`。

## 系统动作与自动解锁

schema 3 新增 `actions.wake` 和 `actions.autoLock`；schema 4 新增 P4A，
schema 5 新增 P4B 交互触发参数。三个动作默认都为 `false`。
靠近唤醒仅在“会话已确认锁定 + 白名单网络 + 已持续离开 + 重新满足 Wake
presence”时触发一次，持续在场不会重复触发。离开锁屏仅在解锁状态下先观察到
全部所需设备在场后武装，随后要求全部所需设备持续缺席且用户空闲才调用
`LockWorkStation`。

唤醒使用一次性 `SetThreadExecutionState` 和输入请求，不建立持续 PowerHold。
托盘的 `System actions` 菜单可显式启用动作，启用前会显示确认对话框。

P4A 自动解锁只处理“锁屏后设备先离开，再重新靠近”。Agent 向
`BleProximityWake.UnlockAgent` 命名管道提交锁屏周期 ID、当前会话和当前用户 SID，
不传输密码。Broker 返回成功、永久拒绝或重试耗尽后，当前锁屏周期不会再次提交。
`SessionNotLocked`、`ProviderUnavailable`、`InternalError` 和通信异常最多按
250/500/1000 ms 重试三次。

P4B 使用系统 Resume、显示器 Off 到 On 提前清理 BLE 队列并重建 Active Watcher，
但这两个边沿本身不建立授权候选。只有“此前至少空闲 1 秒、当前输入不超过 2 秒”的
新输入边沿才建立候选。锁屏动作后的前 2 秒输入会被忽略，并在 6 秒确认窗口内要求
新鲜 BLE 广播；超时不会授权，新的用户输入可以重新开始确认。

Broker 接受一次自动解锁请求后，Agent 不再允许暂停检测，直到本次请求完成。该边界避免
托盘显示“已暂停”但 Windows 仍在消费已提交凭据；已接受的凭据提交不能由 Agent 可靠撤回。

## 安全边界

- Agent 不读取或保存 Windows 密码。
- 密码继续由 LocalSystem Broker 和 Credential Provider 边界管理。
- 自动解锁保留一次性授权、锁屏周期 ID、防重放和每周期一次提交。
- EXE 迁移期间禁止同时启用 PowerShell 和 EXE 的实际唤醒/解锁动作。
- `Observe-Agent.ps1` 和 `Observe-LockCycle.ps1` 不会开启系统动作。
- `Test-WakeAction.ps1` 会在隔离目录临时开启唤醒，运行时必须关闭正式 PowerShell
  常驻程序和其他 EXE Agent，避免两个进程同时发送唤醒输入。
