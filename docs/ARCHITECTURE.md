# Bluetooth Unlock 架构与业务流程

## 1. 设计目标

软件把“设备在场判断”“一次性授权”和“Windows 登录认证”拆成三个安全边界，既支持
只点亮登录页，也支持用户明确启用后的自动解锁。目标平台为 Windows 10 1809 及以后
版本、Windows 11 x64。

## 2. 组件边界

```text
BLE 广播 + Windows 会话/网络/电源/输入事件
                    |
                    v
        用户会话 BleProximityWake.Agent.exe
        - 设备识别与在场状态机
        - 网络、电源和锁屏条件
        - 靠近唤醒、离开锁屏
        - 生成一次性自动解锁授权
                    |
          固定 Agent 命名管道
                    v
        LocalSystem BleProximityUnlockBroker.exe
        - 验证 Agent 映像路径和 SHA-256
        - 验证调用者 SID、会话和锁屏状态
        - 管理短时、单次授权
        - 解密登记凭据
                    |
         SYSTEM 专用 Provider 管道
                    v
        LogonUI Credential Provider DLL
        - 查询当前登录会话授权
        - 获取 Kerberos 凭据序列化
        - 交给 Windows LSA 正式认证
```

Agent 不读取保存的密码；Provider 不负责 BLE、网络或距离判断；Broker 是两者之间唯一
可信桥梁。

## 3. 设备在场模型

每个动作有独立 `PresenceMode`：

- `WatchAndPhone`：手表和手机都必须满足条件。
- `PhoneOnly`：只要求手机，且自动解锁不会使用单次强信号快速确认。

Apple Watch 可能轮换 BLE 地址，因此识别主要依靠厂家数据模式、RSSI、命中窗口和临时
地址学习。手机可使用配对后 Windows 暴露的稳定身份地址。两者都属于启发式近场判断，
不是密码学设备认证。

手表达到 `watchHitCount` 后，普通靠近唤醒可在 `wakeWatchPresenceSeconds`（默认 20 秒）
内沿用这次确认，且最长不超过 `watchLostSeconds`。这只用于点亮登录页；自动解锁仍须
满足原有 `watchHitWindowSeconds`（默认 10 秒）和其余新鲜度条件，不复用延长的亮屏
证据。这样手机广播晚于手表到达时可先点亮屏幕，但不会因此放宽密码授权条件。

## 4. 运行状态

核心状态包括：

- `SessionKnown/SessionLocked`：Windows 会话是否可判定、是否锁屏。
- `NetworkAllowed`：连接 Profile 或 SSID 是否命中白名单。
- `AcPower`：是否接入外接电源。
- `WatchPresent/PhonePresent`：设备在场判断。
- `WakeArmed`：锁屏后是否已经观察到一次有效离开。
- `AutoLockArmed`：解锁状态下是否已经观察到所需设备在场。
- `LockCycleId`：当前锁屏周期的唯一标识。
- `AuthorizationState`：Broker 内部的 `Active -> Consuming -> Consumed` 状态。

暂停、会话切换、离开白名单或 BLE watcher 重启都会清理相应的短期状态，避免旧广播
跨场景复用。

## 5. 靠近唤醒流程

```text
锁屏 + 网络允许
        |
观察设备持续离开，WakeArmed=True
        |
设备重新靠近并满足命中窗口
        |
执行显示器电源请求和必要输入
        |
成功后进入冷却；失败时 2 秒后重试，最多 3 次
```

未锁屏、网络不允许、没有完成离开布防或处于暂停状态时均不触发。交流电决定是否使用
Active 快速扫描，但不是普通唤醒动作的硬门槛；在电池状态下仍可由 Passive 扫描命中，
响应时间可能增加。唤醒失败重试只针对普通“唤醒登录页”，不重复创建自动解锁授权。

## 6. 靠近自动解锁流程

```text
靠近状态满足
  -> 请求显示登录页
  -> 强制刷新网络上下文
  -> Agent 发送 SID + SessionId + LockCycleId + TTL
  -> Broker 验证 Agent 身份、会话、LogonUI、登记账户
  -> 建立短时一次性授权并通知 Provider
  -> Provider 用自身会话查询并消费
  -> Broker 准备完整凭据响应后提交消费
  -> Provider 返回序列化凭据给 LSA
```

网络在 Agent 发起请求前变化会立即拒绝。Provider 会话与授权会话不一致时，Broker
拒绝查询和消费。凭据文件读取或 DPAPI 解密发生瞬时故障时，授权在原 TTL 内恢复为
Active；完整响应准备成功后才标记为已消费。

## 7. 交互唤醒自动解锁流程

该流程解决设备一直在旁边、电脑因长期未使用而关屏或进入 Modern Standby 的场景：

1. Agent 记录锁屏后的显示器关闭或系统 Resume 证据。
2. 新的本地键鼠输入形成交互候选；`Win + L` 后短时间输入被抑制。
3. Agent 清空旧 BLE 队列和设备在场状态，并重建 Active watcher。
4. 在默认 6 秒窗口内重新收到所需设备的新鲜广播。
5. 网络、交流电、锁屏、LogonUI 和设备条件同时成立后进入 Broker 流程。

Display On 或 Resume 可以提前恢复 BLE，但没有新的本地输入时不会自动提交密码。靠近
触发与交互候选重叠时，靠近触发优先；同一锁屏周期仍最多成功授权一次。

## 8. 离开自动锁屏流程

```text
会话已解锁
  -> 所需设备全部在场，AutoLockArmed=True
  -> 所需设备持续缺席达到 absenceSeconds
  -> 用户空闲达到 minimumUserIdleSeconds
  -> 网络仍允许
  -> LockWorkStation
```

登录后设备仍缺席不会立即锁屏，因为必须先重新观察到设备在场。锁屏调用失败后按配置
间隔有限重试。

## 9. 扫描与功耗策略

- 非白名单网络：Passive 扫描，后台轮询默认 1000 ms。
- 白名单但未锁屏：Passive 扫描，后台轮询默认 1000 ms。
- 白名单、锁屏且接通电源：Active 扫描，锁屏轮询默认 250 ms。
- 暂停检测：丢弃观测并回到低功耗状态。

默认不通过 PowerHold 阻止 Modern Standby。交互唤醒流程依靠恢复后的新广播完成确认。

## 10. 失败与降级原则

- BLE、网络、会话或 Broker 条件不明确时拒绝高风险动作。
- Broker/Provider 不可用时，靠近唤醒和手工 Windows 登录仍可工作。
- 自动解锁永久拒绝、凭据错误或重试耗尽后，不在同一锁屏周期无限提交。
- 配置迁移不会自动开启系统动作。
- 管道名称是内部协议常量，不属于用户配置。

Credential Provider 的详细协议和恢复设计见
[../CREDENTIAL_PROVIDER_DESIGN.md](../CREDENTIAL_PROVIDER_DESIGN.md)。
