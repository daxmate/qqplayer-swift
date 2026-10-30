# 6 位配对码 + Mac 对等客户端（局域网同步 · 批 1）

> 2026-10-30 立项（用户拍板：**A 方案 / 角色对等 / 最终含资料库同步**）。本文只覆盖批 1：
> **发现 + 6 位码配对 + 会话可用**。曲库数据变更流属批 2，本文不涉及。

## 1. 背景与目标

- 现状（2026-10-30 实测）：两台 Mac 的 QQPlayerMac 都在 `_qqplayer-sync._tcp` 广播、双向
  Bonjour 可见，但 Mac 只有 **host 半边**（`SyncHostCenter` 装 `SyncListener`），客户端角色
  只有 iOS 在用；Mac「设备」页没有发现列表、没有码输入，配对只能靠二维码（iOS 扫码）。
- 批 1 要达成的三件事：
  1. Mac 侧客户端角色（**对等**）：listener 常驻 + 浏览独立开关，同一台 Mac 可同时是 host 与 client；
  2. 6 位配对码（**A 方案**）：取代二维码作为 Mac↔Mac 的带外信任入口；
  3. 会话可用：配对成功后能建立 `SyncPeerSession`，连接状态 / 断开 / 重连与 host 侧对称。

## 2. Mac 侧客户端角色（对等）

- 新装配：`QQPlayer/Mac/MacPeerClientCenter.swift`（`@MainActor @Observable`，组合根注入）。
  - 发现层固定用 `SyncBrowser`（**DNS-SD C API**）。⚠️ 不要换回 `NWBrowser`：2026-09-17 真机实测
    同网同进程下 `NWBrowser` 一条结果都不交付（依据见 `SyncBrowser.swift` 文件头）。
  - 对等约束：`SyncHostCenter`（host）与 `MacPeerClientCenter`（client）互不依赖，各自独立开关；
    浏览默认开（`sync.peerBrowsingEnabled.v1`），host 监听仍由既有 `sync.allowsLANConnections.v1` 控制。
  - 自过滤：发现列表剔除与 `LocalDeviceNameStore` 同名的广播（本机自己）。
  - 「已配对」标记为**启发式**：client 侧落库的 `PeerDevice.displayName` = host 展示名 =
    Bonjour 服务名，故按名字匹配；连接成功后以 hello 里的 Device ID 为准。
- 列表加工是**纯逻辑**：`QQPlayer/Sync/SyncPeerDiscoveryList.swift`（剔除本机 / 去重 / 已配对标注 /
  本地化标序），UI 只拿值 ⇒ 发现列表增删可单测（`SyncPeerDiscoveryListTests`）。
- 状态：`idle / browsing / connecting(name) / pairing(name) / connected(name) / failed(key)`，
  `failed` 携带本地化 key（见 §5）。

## 3. 6 位配对码（A 方案）

### 3.1 语义

| 维度 | 口径 |
| --- | --- |
| 码空间 | `000000`–`999999`（6 位十进制，前导零保留，系统 CSPRNG） |
| 同时有效 | **1 张**（生成新码即作废旧码） |
| 一次性 | 校验成功即标记 used；同码再提交 → `already_used` |
| TTL | **120s**（`SyncPairingCodeStore.defaultTTL`） |
| 关联 nonce | 每次生成 16B 随机 nonce，注册进 host nonce 池**带 120s 单项 TTL** |
| 比较 | `constantTimeEquals`（等长逐字节 XOR 累积，不提前返回） |
| 限速 | 同一对端 Device ID，60s 窗口内**失败** ≤ 5 次；超限一律 `rate_limited`（即使随后输入正确码） |

码只是**扫码的替代入口**，不引入新信任根：码通过后 host 把 `hostDeviceID + hostPublicKey +
sessionNonce` 交给 client，client 仍走标准 `PairRequest`（对 nonce 签名），host 现有 nonce 池验签
→ 批准卡 → `approvePairing` → 双方落库。**落库语义与 QR 路径完全一致**。

### 3.2 帧（协议扩展，帧号 17/18，先查占用：0–16 已用）

两处同改（`SyncFrameType` / 收帧分发表），均为**明文**、只在配对阶段出现：

| 帧 | 方向 | 载荷 |
| --- | --- | --- |
| `pairCodeSubmit = 17` | client → host | `PairCodeSubmit{clientDeviceID, clientPublicKey, clientName?, code}` |
| `pairCodeResponse = 18` | host → client | `PairCodeResponsePayload{accepted, reason?, hostDeviceID?, hostPublicKey?, sessionNonce?, detail?}` |

时序：

```
client: hello ─▶ pairCodeSubmit ─▶ [pairCodeResponse] ─▶ pairRequest(签 nonce) ─▶ pairResponse ─▶ ready
host  : hello ─▶ 校验码 ─▶ pairCodeResponse(+nonce) ─▶ pairRequest 验签 ─▶ 批准卡 ─▶ approve ─▶ ready
```

实现落点：
- 码库 / 限速 / 失败原因：`QQPlayer/Sync/SyncPairingCode.swift`
- 帧载荷与结构校验：`QQPlayer/Sync/SyncPairingCodeMessages.swift`
- host 处理：`SyncPeerSession+Frames.swift` 的 `processPairCodeSubmitLocked`（与 `processPairRequestLocked` 同阶段）
- client 处理：`processPairCodeResponseLocked`（用应答里的 host 公钥**补验 hello 签名**后再发 PairRequest）

### 3.3 状态与阶段

- 码阶段**复用** `waitingForPairResponse`（不新增 `SyncSessionPhase`，避免 UI/状态映射改动）；
- 帧分发按 `frame.type` 区分 `pairCodeResponse` 与 `pairResponse`；
- `ready` 阶段收到任一码帧 → `protocolViolation`。

## 4. 失败原因（明确区分）

`reason` 即 `SyncPairingCodeFailure.rawValue`，client 侧映射为本地化 key：

| reason | 含义 | UI key |
| --- | --- | --- |
| `no_active_code` | 对方从未生成 / 已作废 | `sync_pair_code_failed_no_active` |
| `expired` | 生成过但超过 120s | `sync_pair_code_failed_expired` |
| `already_used` | 该码已被成功使用（重放） | `sync_pair_code_failed_used` |
| `mismatch` | 码不匹配（含穷举/输错） | `sync_pair_code_failed_mismatch` |
| `rate_limited` | 同对端 60s 内失败 > 5 次 | `sync_pair_code_failed_rate_limited` |
| `protocol_error` | 提交帧本身不合法（ID/公钥/指纹/格式） | `sync_pair_code_failed_generic` |

失败一律**关闭该连接**（client 可重连再试）；限速计数按 Device ID 跨连接保留（在 host 进程内）。

## 5. 会话级失败文案（客户端角色）

`MacPeerClientCenter.errorKey(for:)` 把 `SyncSessionCloseReason` 映射为 UI key：
`sync_peer_untrusted` / `sync_peer_handshake_timeout` / `sync_peer_handshake_failed` /
`sync_peer_storage_failed` / `sync_peer_protocol_violation` / `sync_peer_transport_error` /
`sync_peer_pairing_rejected`；用户主动断开 / 对端正常关闭不提示。

## 6. 不变量核对（`docs/sync-invariants.md`）

- **INV-16（平台装配断言）**：本批新增 Mac 装配点 `MacPeerClientCenter`，并把它登记进
  `QQPlayerMac` 白名单（`SyncBrowser.swift` 首次进 Mac target）；`scripts/check-target-membership.py` 覆盖。
- **INV-25（对端载荷按不可信输入）**：码提交只做结构校验 + 常量时间比较；`detail` 仅诊断用，不参与判定。
- **INV-17（同一会话只装一个 changeLog 处理器）**：本批不碰 ready 后的业务帧与 changeLog 装配。
- 批 1 **不改** 数据同步语义（INV-1…INV-35 的落库/身份键/LWW 规则均不变）。

## 7. 测试覆盖（批 1）

- `QQPlayerTests/SyncPairingCodeTests.swift`：生成格式 / 前导零 / 兜底、单次使用（重放）、错码、
  过期 vs 从未生成、输入归一、限速（含其它对端不受影响、窗口恢复）、作废、常量时间比较。
- `QQPlayerTests/SyncPairingCodeFlowTests.swift`：会话级端到端（码 → nonce → PairRequest → 批准 →
  双 ready + 双向落库；错码 / 无码 / 过期三条失败路径的 reason key）。

## 8. 变更记录

| 日期 | 变更 |
| --- | --- |
| 2026-10-30 | 初版：Mac 对等客户端角色 + 6 位配对码（帧 17/18）、TTL 120s、限速 5/60s、失败原因表 |
