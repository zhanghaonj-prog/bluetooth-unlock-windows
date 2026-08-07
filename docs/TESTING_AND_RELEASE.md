# Bluetooth Unlock 测试与发布指南

## 1. 测试原则

测试分为四层：静态和纯逻辑测试、组件构建与协议自测、隔离系统动作测试、真实登录链路
验收。前三层通过不等于自动解锁实机通过；涉及 Credential Provider 的测试必须保留备用
管理员账户和 Windows 原生登录方式。

## 2. 自动化回归

从仓库根目录依次执行，避免多个 MSBuild 进程同时写同一个 PDB：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-BleProximityWake.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Test-Agent.ps1 -Configuration Release
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\credential-provider\Test-P0Provider.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer.ps1 -Configuration Release -Version 0.1.0 -SkipBuild -StageOnly
```

覆盖范围：

- PowerShell 配置、匹配和核心状态机回归。
- EXE Agent Release 构建、纯逻辑测试、启动冒烟和旧配置迁移。
- Provider Debug/Release 构建、Broker 自测、序列化、COM 生命周期、PE/导出检查。
- 发布目录白名单、文件清单、敏感文件排除和安装定义。
- 网络通配、授权前网络刷新、会话隔离、消费失败恢复和唤醒有限重试。

## 3. 隔离动作测试

运行前退出已安装的 Agent 和旧 PowerShell 常驻程序。脚本使用独立诊断目录，不覆盖正式
用户配置。

```powershell
# 靠近唤醒
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Test-WakeAction.ps1

# 离开锁屏
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Test-AutoLockAction.ps1

# 重新靠近自动解锁
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Test-AutoUnlockArrival.ps1

# 持续在场时的交互唤醒自动解锁
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Test-AutoUnlockInteractiveWake.ps1
```

后两个脚本要求 Broker 正在运行、Provider 已登记启用、正常密码/PIN 回退已验证。

## 4. 实机功能矩阵

| 场景 | 预期结果 |
| --- | --- |
| 未锁屏，设备靠近 | 不唤醒、不自动解锁 |
| 锁屏，非白名单网络 | 不执行系统动作 |
| 锁屏，使用电池 | 不进入 Active 快速扫描，不自动解锁 |
| 锁屏，设备未先离开 | 靠近流程不触发 |
| 锁屏，设备远离后靠近 | 点亮登录页；启用自动解锁时进入桌面 |
| 设备持续在场，屏幕关闭后按键 | 恢复后用新 BLE 广播确认，最多授权一次 |
| 系统自行亮屏，无新本地输入 | 不执行交互自动解锁 |
| 登录后设备仍缺席 | 不立即自动锁屏，等待重新观察到在场后布防 |
| 网络在授权前切换 | 最终网络检查拒绝授权 |
| Broker 停止 | 手工登录可用，靠近唤醒不受影响 |
| 密码错误 | 一次失败后停止重复提交，允许手工登录 |
| Provider 客户端会话不匹配 | Broker 拒绝查询和消费 |

Windows 10 和 Windows 11 均需测试；Modern Standby 与传统 S3 应在实际支持对应电源模型
的机器上分别验收。

## 5. 安装、升级和卸载验收

建议在可回滚虚拟机快照中执行：

1. 默认安装，只安装 Agent，确认托盘和登录自启动。
2. 重启，确认配置保留且三个系统动作仍按配置执行。
3. 自定义安装自动解锁组件，确认 Provider 初始禁用。
4. 登记测试账户，验证原生密码/PIN，再启用自动解锁。
5. 覆盖升级，确认用户配置、登记 SID、启用状态和凭据保留。
6. 运行 `Test-P1HostRegistration.ps1`，确认可信 Agent 哈希已刷新。
7. 取消自动解锁组件，确认 Broker、Provider 和凭据被清理。
8. 完整卸载并重启，确认启动项、服务、注册项、用户数据和残留文件清除。

## 6. 构建发布包

安装 Inno Setup 6 后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\installer\Build-Installer.ps1 -Configuration Release -Version 0.1.0
```

输出：

```text
installer\output\BleProximityWake-0.1.0-win-x64.exe
installer\output\BleProximityWake-0.1.0-win-x64.exe.sha256
installer\staging\release-manifest.json
```

构建脚本只收集显式白名单文件，禁止打包 PDB、主机配置、凭据、日志和诊断数据。发布前
重新计算安装包 SHA-256，并与 `.sha256` 文件核对。

## 7. 发布准入

公开发布前至少满足：

- 自动化回归和四类隔离动作测试全部通过。
- Windows 10/11 安装、升级、卸载和回滚矩阵通过。
- 原生 PIN、密码、Windows Hello 在启用和故障场景始终可用。
- Modern Standby 恢复通过；S3 在支持设备上完成验证或明确标记未验证。
- 完成 24 小时稳定运行和不少于 30 次自动解锁循环。
- 安装包和二进制完成代码签名。
- 发布 SBOM、SHA-256、隐私说明、安全风险和恢复步骤。
- 确认仓库、安装包和日志不包含真实设备地址、网络名、用户名或凭据。

当前 `0.1.0` 安装包未签名，适合受控测试，不应直接作为公开正式版本。

## 8. 测试记录模板

```text
版本/提交：
Windows版本：
设备型号与电源模型：
网络Profile/SSID：
PresenceMode：
测试时间：
测试场景：
预期结果：
实际结果：
Agent日志时间范围：
Broker/Provider状态：
是否可正常手工登录：
结论：通过 / 失败 / 未验证
```
