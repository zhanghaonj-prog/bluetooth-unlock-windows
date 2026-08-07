# Bluetooth Unlock 故障排查手册

## 1. 先收集信息

从托盘菜单依次执行：

1. `Copy diagnostics`。
2. `Open current log`。
3. 记录问题发生的本地时间，至少精确到分钟。

常用路径：

```text
Agent配置   %LOCALAPPDATA%\BleProximityWake\agent-settings.json
Agent日志   %LOCALAPPDATA%\BleProximityWake\logs
Broker日志  %PROGRAMDATA%\BleProximityWake\unlock-broker.log
Provider日志 %PROGRAMDATA%\BleProximityWake\credential-provider-p0.log
```

排查时同时说明：当时是否锁屏、是否接交流电、当前网络名、手表/手机是否移动、屏幕是关屏
还是 Modern Standby、是否由键盘唤醒。

## 2. 托盘没有出现

检查进程：

```powershell
Get-Process BleProximityWake.Agent -ErrorAction SilentlyContinue
```

检查 Agent 最新日志。单实例互斥会让第二个实例立即退出；不要同时运行 EXE Agent 和
`Start-BleProximityWake.ps1`。安装版程序通常位于：

```text
%ProgramFiles%\BleProximityWake\Agent\BleProximityWake.Agent.exe
```

## 3. 网络显示不允许

EXE Agent 只匹配 Windows 网络 Profile 名称和 Wi-Fi SSID，不匹配网卡名，例如
`WLAN`、`以太网 6`。

检查配置：

```json
"network": {
  "enabled": true,
  "allowedProfileNames": ["Example-WiFi"],
  "allowedSsids": ["Example-WiFi"]
}
```

允许使用 `Office-*` 形式的通配符。若启用网络过滤但白名单为空，属于 fail closed，
不会触发动作。自动解锁每次请求前还会绕过缓存重新读取网络，因此托盘刚显示允许但网络
已经切换时，授权仍可能被拒绝，这是预期行为。

## 4. 检测不到手表或手机

先选择 `Re-detect devices`，观察 20 至 30 秒。检查：

- Windows 蓝牙是否开启。
- 设备是否真的发送 BLE 广播。
- 地址是否轮换，固定地址规则是否已经失效。
- 厂商数据模式和 RSSI 阈值是否过严。
- 当前动作的 `PresenceMode` 是否要求另一台设备同时在场。
- 日志是否出现过期广告丢弃或 watcher 重启。

Apple Watch 地址会轮换，不应仅凭某次扫描地址长期识别。手机重新配对后也可能需要更新
身份地址。设备识别是启发式规则，换电脑、蓝牙适配器或佩戴位置后应重新校准。

## 5. 靠近但屏幕不亮

依次确认：

1. `actions.wake.enabled=true`。
2. Windows 已锁屏，而不是仅打开屏保。
3. 当前网络命中白名单。交流电不是普通唤醒硬门槛，但决定是否启用 Active 快速扫描；
   使用电池时响应可能更慢。
4. 日志中 `WakeArmed=True`；若为 `False`，需要先让设备持续远离达到 `rearmSeconds`。
5. `Pause detection` 未启用。
6. 当前动作所需设备全部满足在场条件。

系统调用失败时程序会按 2 秒间隔最多重试 3 次。查看日志中的动作结果；达到上限后需
等待新的有效触发条件，不会无限制造输入。

## 6. 屏幕亮了但没有自动进入桌面

先确认普通唤醒和自动解锁是两个独立动作。需要同时满足：

- `autoUnlock.enabled=true`。
- Broker 服务正在运行。
- Credential Provider 已登记并启用。
- 可信 Agent 路径和 SHA-256 与当前安装文件一致。
- 当前锁屏会话、SID、网络、交流电和设备组合均匹配。

管理员运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:ProgramFiles\BleProximityWake\CredentialProvider\scripts\Test-P1HostRegistration.ps1"
```

若覆盖复制了 Agent EXE 而没有通过安装器升级，Broker 保存的可信哈希会失效。应重新
运行安装包升级，不要手工修改注册表哈希。

## 7. 用户名或密码不正确

Provider 日志中的常见状态：

- `Status=0x00000000`：Windows 认证成功。
- `Status=0xC000006D`：Windows 拒绝用户名或密码。

Microsoft Account 必须登记真实账户密码，不是 PIN。先在 Windows 登录页切换到“密码”
方式手工验证同一密码；确认成功后再重新登记。密码修改后必须重新登记。

不要通过反复自动提交验证密码，这可能触发账户锁定策略。

## 8. 交互唤醒偶尔超时

交互模式会主动清空睡眠前 BLE 证据，默认只等待 6 秒的新广播。日志应依次出现交互候选、
BLE 重新确认和 Broker 授权。如果只出现候选：

- 确认按键发生在显示器恢复后，且不是刚按下的 `Win + L` 残留输入。
- 确认锁屏后仍接交流电且网络没有切换。
- 检查 Active watcher 是否成功重建。
- 检查手表和手机哪个没有在窗口内发送新广播。

不要直接扩大确认窗口掩盖设备识别问题；先判断是 BLE 广播延迟、网络最终检查，还是
LogonUI 尚未就绪。

## 9. 锁屏后意外进入 Modern Standby

默认策略允许 Modern Standby，这是为了降低长期锁屏耗电。软件不应持续阻止系统睡眠。
从 Modern Standby 由键盘唤醒后，交互模式重新确认设备并自动解锁。

Windows 设置中的“睡眠时间”和锁屏后的 Modern Standby 空闲策略可能不同。需要分析时
结合 `powercfg /a`、`powercfg /sleepstudy` 和系统事件日志，不能仅依据设置页面的睡眠
分钟数判断。

## 10. 离开后没有自动锁屏

确认：

- `actions.autoLock.enabled=true`。
- 登录后曾观察到所需设备在场，使 `AutoLockArmed=True`。
- 所需设备全部缺席达到 `absenceSeconds`。
- 用户空闲达到 `minimumUserIdleSeconds`。
- 网络仍命中白名单。

如果手机一直留在电脑旁，而模式为 `WatchAndPhone`，离开条件不会成立。可按风险需要把
离开锁屏单独配置成 `PhoneOnly` 或调整设备组合，但不要误以为三类动作必须使用相同模式。

## 11. 恢复与卸载

优先保留 Windows 原生登录入口。自动解锁异常时：

1. 使用 PIN、密码或 Windows Hello 手工登录。
2. 从托盘关闭自动解锁并退出 Agent。
3. 使用安装器执行修复或卸载自动解锁组件。
4. 无法正常登录时使用备用管理员账户或安全模式运行项目提供的卸载脚本。

不要直接删除 DLL、Broker EXE 或凭据文件后保留注册信息，否则可能形成不完整安装状态。
