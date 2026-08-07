# Bluetooth Unlock for Windows

Bluetooth Unlock 是一个 Windows 10/11 x64 托盘工具，通过手机、手表等 BLE 设备的
在场状态实现靠近唤醒、离开锁屏，以及可选的 Credential Provider 自动解锁。

> [!WARNING]
> 自动解锁会在本机保存可逆的 Windows 登录密码。它是便利功能，不是第二因素认证，
> 不能抵御本机管理员、SYSTEM 或 BLE 模拟攻击。该组件默认不安装或保持禁用。

## 功能

- 手机单设备或手表加手机组合检测。
- Apple 厂商数据模式、RSSI 窗口和轮换地址学习。
- 按 Windows 网络 Profile 或 Wi-Fi SSID 限制动作场所。
- 锁屏后设备先离开再靠近时唤醒登录页。
- 设备持续在场时，从关屏或 Modern Standby 交互唤醒后重新确认并自动解锁。
- 设备离开并满足用户空闲时间后自动锁屏。
- Windows 10/11 x64 安装器、托盘诊断和隔离测试脚本。

所有系统动作默认关闭。配置迁移不会自动启用唤醒、锁屏或自动解锁。

## 安全边界

自动解锁链路分为：

```text
用户会话 Agent -> LocalSystem Broker -> LogonUI Credential Provider -> Windows LSA
```

Agent 只负责 BLE、网络、电源和会话判断，不读取密码。Broker 验证 Agent、SID、会话和
锁屏周期，并管理短时一次性授权。Credential Provider 只向 Windows 正式认证链路提交
已登记凭据。

BLE 和网络名称不是密码学身份。详细限制见 [威胁模型](docs/THREAT_MODEL.md) 和
[安全策略](SECURITY.md)。

## 支持状态

- 目标平台：Windows 10 1809 及以后版本、Windows 11 x64。
- 架构：x64。
- Agent：.NET Framework 4.8 WinForms。
- Credential Provider：Visual C++ x64。
- 安装器：Inno Setup 6。
- 当前阶段：`0.x` 实验版本，尚无签名公开 Release。

## 从源码验证

要求安装 Visual Studio 2022、.NET Framework 4.8 Developer Pack、Windows SDK 和 C++
桌面开发工具。在 Windows PowerShell 5.1 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-BleProximityWake.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent\Test-Agent.ps1 -Configuration Release
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\credential-provider\Test-P0Provider.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer.ps1 -Configuration Release -Version 0.1.0 -SkipBuild -StageOnly
```

不要在日常使用的主账户上直接安装未经验证的 Credential Provider。优先使用带快照的
Windows 虚拟机，并保留第二个管理员账户。

## 文档

- [用户使用手册](docs/USER_GUIDE.md)
- [架构与业务流程](docs/ARCHITECTURE.md)
- [故障排查](docs/TROUBLESHOOTING.md)
- [测试与发布](docs/TESTING_AND_RELEASE.md)
- [Credential Provider 设计](CREDENTIAL_PROVIDER_DESIGN.md)
- [威胁模型](docs/THREAT_MODEL.md)
- [开源发布清单](docs/OPEN_SOURCE_RELEASE_CHECKLIST.md)
- [贡献指南](CONTRIBUTING.md)
- [安全策略](SECURITY.md)

## 隐私

项目不需要云服务或遥测。BLE 标识、网络名称、配置和日志保存在本机。提交 Issue 或诊断
材料前必须删除设备地址、SSID/Profile、用户名、SID、主机名和绝对路径。

## 许可证

项目采用 [MIT License](LICENSE)。第三方来源与归属见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。Windows、Microsoft、Apple、iPhone
和 Apple Watch 是各自权利人的商标，本项目与这些公司没有隶属或背书关系。
