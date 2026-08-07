# Bluetooth Unlock 用户使用手册

本文面向安装和日常使用，不包含开发构建细节。当前推荐使用 Windows 10/11 x64
安装包和 EXE Agent；根目录 PowerShell 脚本只用于兼容和诊断。

## 1. 功能模式

软件提供三个彼此独立的动作：

| 功能 | 触发条件 | 默认状态 |
| --- | --- | --- |
| 靠近唤醒 | 锁屏、白名单网络、设备先离开再靠近 | 关闭 |
| 自动解锁 | 上述靠近事件，或锁屏后的交互唤醒，并重新确认设备在场 | 关闭 |
| 离开锁屏 | 已解锁、设备曾在场、设备持续离开且用户空闲 | 关闭 |

自动解锁使用 Credential Provider 提交真实 Windows 密码，不会模拟键盘输入 PIN。
该功能会在本机保存可逆密码，启用前必须阅读“安全与回退”章节。

## 2. 安装

运行：

```text
installer\output\BleProximityWake-0.1.0-win-x64.exe
```

安装类型：

- 默认安装：只安装托盘 Agent，适合先验证 BLE 检测和靠近唤醒。
- 自定义安装：额外选择“自动解锁”，安装 Broker 和 Credential Provider。

安装后 Agent 随用户登录自动启动，任务栏通知区域出现托盘图标。安装自动解锁组件
不会自动启用它，也不会在安装过程中保存密码。

## 3. 首次配置

当前版本没有完整设置窗口。Agent 首次启动后生成：

```text
%LOCALAPPDATA%\BleProximityWake\agent-settings.json
```

可以从托盘菜单打开配置文件。修改前先退出 Agent，修改后重新启动。

建议配置顺序：

1. 配置手机和手表匹配规则。
2. 配置实际连接网络的 Profile 名称或 Wi-Fi SSID。
3. 先保持三个系统动作关闭，观察托盘状态和日志。
4. 分别启用靠近唤醒、离开锁屏并做隔离测试。
5. 最后登记密码并启用自动解锁。

完整配置样例见 `agent/agent-settings.sample.json`。关键规则：

- `presencePolicies` 可为每个动作选择 `WatchAndPhone` 或 `PhoneOnly`。
- `network.allowedProfileNames` 和 `allowedSsids` 支持大小写不敏感的 `*` 通配符。
- 网络过滤开启但两个白名单都为空时，所有受网络约束的动作都被拒绝。
- Agent 不使用网卡别名、DNS 后缀或用户可配置的 Broker 管道名。
- `actions.wake.enabled`、`actions.autoLock.enabled` 和 `autoUnlock.enabled` 默认均为
  `false`。

配置示例：

```json
{
  "presencePolicies": {
    "wake": { "mode": "PhoneOnly", "requireFreshAfterResume": false },
    "autoUnlock": { "mode": "WatchAndPhone", "requireFreshAfterResume": true },
    "autoLock": { "mode": "PhoneOnly", "requireFreshAfterResume": false }
  },
  "network": {
    "enabled": true,
    "allowedProfileNames": ["Example-WiFi", "Office-*"],
    "allowedSsids": ["Example-WiFi"]
  }
}
```

## 4. 托盘菜单

- 状态区：显示会话、网络、电源、BLE、设备和 Broker 状态。
- `Test wake to sign-in`：只测试点亮屏幕和打开登录页，不自动解锁。
- `Re-detect devices`：清空短期 BLE 状态并重新识别设备。
- `Pause detection`：暂停所有检测和系统动作；再次选择可恢复。
- `System actions`：临时开启或关闭靠近唤醒、自动解锁、离开锁屏。
- `Copy diagnostics`：复制当前诊断摘要。
- `Open current log` / `Open log folder`：查看运行日志。
- `Exit`：退出当前用户的 Agent。

托盘开关只影响当前进程，不修改配置文件。配置文件原本关闭的高风险能力不能依靠
托盘绕过安全确认强行启用。

## 5. 自动解锁启用顺序

自动解锁组件安装后，以管理员身份登记凭据。Microsoft Account 必须输入真实账户密码，
不能输入 Windows Hello PIN。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:ProgramFiles\BleProximityWake\CredentialProvider\scripts\Set-P1Credential.ps1" `
  -Username <Windows配置文件用户名> -IUnderstandThisCanAffectSignIn
```

然后按以下顺序验证：

1. 保持 `autoUnlock.enabled=false`。
2. 按 `Win + L`，确认 PIN、密码或 Windows Hello 手工登录正常。
3. 运行主机注册检查，确认 Broker、Provider、可信 Agent 哈希和凭据文件正常。
4. 将 `autoUnlock.enabled` 改为 `true`，重启 Agent。
5. 先测试“设备远离后重新靠近”，再测试“设备持续在场时按键唤醒”。

主机注册检查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:ProgramFiles\BleProximityWake\CredentialProvider\scripts\Test-P1HostRegistration.ps1"
```

## 6. 两种自动解锁流程

重新靠近自动解锁：

1. 手表或手机先离开，等待状态重新布防，并保持外接电源连接。
2. 按 `Win + L` 锁屏。
3. 设备重新靠近。
4. Agent 点亮屏幕、重新检查网络并向 Broker 提交一次授权。
5. Provider 只在同一 Windows 会话内消费该授权并进入桌面。

持续在场的交互唤醒：

1. 设备保持在电脑旁。
2. 锁屏并让屏幕关闭或进入 Modern Standby。
3. 按一次键盘或移动鼠标。
4. Agent 清除睡眠前 BLE 证据，要求设备提供新的广播。
5. 条件在确认窗口内全部满足后自动进入桌面。

系统自行亮屏但没有新的本地输入时，不会执行交互自动解锁。

## 7. 安全与回退

- 密码使用 DPAPI LocalMachine 加密，保存于
  `%PROGRAMDATA%\BleProximityWake\credential.dat`。
- 文件 ACL 限制为 `SYSTEM` 和本机管理员，但本机管理员仍有能力解密，因此不能把它
  视为不可逆或硬件保护凭据。
- 自动解锁必须同时满足锁屏、白名单网络、交流电和所选设备在场。
- 每次 Broker 请求都会刷新网络；缓存网络状态不用于最终授权。
- 授权绑定用户 SID、Windows 会话和锁屏周期，并且只能消费一次。
- 必须保留已验证的 PIN、密码或 Windows Hello 手工登录方式。

发生异常时优先手工登录，然后在托盘中关闭自动解锁。无法进入桌面时，可使用备用管理
员账户或安全模式运行卸载脚本。不要删除 Provider DLL 后再处理注册表。

## 8. 日志与数据

```text
用户配置  %LOCALAPPDATA%\BleProximityWake\agent-settings.json
Agent日志 %LOCALAPPDATA%\BleProximityWake\logs
Broker日志 %PROGRAMDATA%\BleProximityWake\unlock-broker.log
Provider日志 %PROGRAMDATA%\BleProximityWake\credential-provider-p0.log
```

故障定位见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。
