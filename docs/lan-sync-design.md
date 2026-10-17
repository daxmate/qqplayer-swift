# QQPlayer 局域网配对与同步设计（S2）

> 2026-09-08 定稿方向：配对 = Ed25519 TOFU + QR 扫码（主）/ 手动输 ID（备）；
> 同步 = 主机(Host)-移动端(Client) 模型，纯 Swift 闭环（不依赖 Python）。
> 本文档为 v1（iOS ↔ macOS）可执行设计；协议层平台无关，为 Windows/Android/web(NAS) 留插槽。

## 0. 目标与范围

- v1：iOS ↔ macOS 真机 —— 配对、双向文件同步、播放数据同步、对齐歌词同步
- 移动端是瘦客户端（无下载/刮削 UI）；主机是内容生产端
- 前置工作并入本阶段：iOS 音乐存储迁到本地沙盒 Documents（原 iCloud 容器退出）

## 1. 角色与拓扑

```
macOS QQPlayer（Host / 服务端）        iOS QQPlayer（Client / 移动端）
├─ 曲库 ~/Music/QQPlayer（内容源）      ├─ 本地沙盒 Documents 曲库（镜像/子集）
├─ 内嵌 SyncServer（App 运行即服务）    ├─ SyncClient（活跃时自动同步）
├─ 同步 UI（设备/集合/推送拉取）        ├─ 配对管理（多台主机）
└─ 本地 DB（真源）                      └─ 本地 DB（同 schema）
```

- 一个 Client 可配对多台 Host；每台 Host 独立同步
- 同一份协议契约；Swift 端协议层（模型 + 逻辑）为共享 Core 代码
- 未来 web/NAS 主机按同契约另行实现（FastAPI 侧），客户端不感知

## 2. 身份与信任（配对核心）

- 每端安装生成长期 **Ed25519 密钥对**，私钥存 Keychain（重装/换机 = 新身份）
- **Device ID = 公钥 SHA-256 指纹**，展示为可读格式（分组短码）；QR 与存储用全量值
- 配对记录 = 互信的对方公钥列表：
  `{peerID, peerPubKey, displayName, pairedAt, lastSeenAt, notes, isHost}`
- 撤销配对 = 删除对方记录；此后任何连接验指纹失败即拒

安全特性：无密码（无字典攻击面）、无 CA、离线可用、防冒充/中间人/重放。
（参考：Syncthing 设备 ID 模型，Ed25519 指纹互认 + TLS pinning，多年跨平台验证）

## 3. 发现（mDNS / Bonjour）

- 服务类型 `_qqplayer-sync._tcp`；Host 广播：设备名 + 协议版本（**不广播完整 Device ID**）
- Client 活跃时浏览并解析；连接后以指纹验证身份（广播内容本身不可信）
- Bonjour 为跨平台标准（未来 Android NsdManager / 手动 IP 兜底）

## 4. 配对流程

### 4.1 QR 扫码（主路径）
```
Host（macOS）                           Client（iOS）
1. 同步中心 →「添加设备」→ 显示 QR ──►  2. 同步设置 → 扫描
   QR 内容: {protoVer, hostName,         3. 展示 主机名 + ID 短格式
   deviceID, pubKey, sessionNonce}          → 用户确认
                                         4. POST /pair/request
                                            (clientID, clientPubKey,
                                             sessionNonce 签名)
5. 弹窗确认（显示设备名+ID 短格式）◄──────┘
6. 用户批准 → 双向存配对记录 → 完成
```
- 信任根 = 扫码瞬间的物理在场（QR 即带外可信通道）；QR 含一次性 nonce 防重放
- 移动端需先有自身密钥（首次启动生成）

### 4.2 手动输入（备选路径）
- Host 显示设备 ID 文本（分组），Client 手动输入 → 同一握手流程
- 输入后双方 UI 展示指纹分组供二次核对（比较首/尾组），防输错

### 4.3 撤销 / 重配对
- 任一方删除配对记录即断；重配对走同一流程
- 设备丢失：在其它已配对端撤销该设备

## 5. 传输与会话

- **传输选型（待拍板）**：
  - A. Network.framework（NWListener/NWConnection）+ 长度前缀帧协议 —— 零新依赖，Swift 原生，TLS 内建
  - B. 内嵌 HTTP server（SwiftNIO）+ REST —— 与 web 生态天然兼容，但引入 SPM 依赖 + 服务端实现重
  - 推荐 A：v1 两端都是 Swift，帧协议简单可控；同步操作在逻辑层抽象为原语，未来给 web 主机做 HTTP 映射即可
- **加密**：TLS 1.3 + 自签 Ed25519 证书，**每次连接 pinning 对端公钥 == 配对记录**（防中间人）
- **帧**：`长度(4B) | type(1B) | payload`；控制帧 JSON，文件帧二进制流
- **大文件**：分块流式 + offset 断点（`.part` 原子落盘，沿用下载链路语义）+ SHA-256 完整性校验
- 原语集（逻辑层，与传输解耦）：`pairRequest/pairConfirm`、`manifestFetch`、`filePull(fileID, offset)`、`filePush`、`changeLogPull(cursor)`、`changeLogPush(batch)`、`deviceList`

## 6. 同步内容

### 6.1 文件同步（Host 发起 · 不传播删除）
- **跨端歌曲身份 = content SHA-256（`content_hash`）**——现状 stableId 是绝对路径哈希，跨端必不一致，不能作对账键（详见 9-06 分析）
- Track 表加列 `content_hash`；入库时计算一次，惰性回填存量曲库
- **发起方恒为桌面端（Host）**，两个操作都在 Mac 上（2026-09-10 拍板）：
  - **推送到设备**（Host→Client）：选歌单/歌曲 → manifest（相对路径、大小、mtime、content_hash）→ Client 对账 → 取缺失/差异 → 断点传输 → 校验 → 入库
  - **从设备下载**（Client→Host）：Host 浏览 Client 曲库 manifest → 勾选 → Host 拉取入库（手机导入的内容也能取回）
  - 移动端不主动发起同步（纯被动端）
- **不传播删除（2026-09-10 拍板）**：任一端删除歌曲都是**本地事务**——iPhone 删歌不影响 Mac，Mac 删歌不影响 iPhone；同步只做「补齐缺失 + 内容不同则更新」（**对端文件更新的冲突场景见本节「冲突判定 + 待确认覆盖」**），**永不因对端 manifest 变化而删任何一端文件**
- **同步集合 = 用户显式选择**（歌单 / 歌曲勾选）；**不做全库自动镜像**——移动端容量有限，全库自动推送会把设备充爆（2026-09-10 拍板）
- **歌单同步**：可选（勾选要同步的歌单）；同步时目标端缺的歌**自动上传补齐**（收藏视为特殊歌单，同规则）

**冲突判定 + 待确认覆盖（2026-10-16 用户拍板 · 契约见 `docs/sync-contract.md` §2 G）**

> 本节是**设计**（批 0 只落文档；实现按批推进）。**零协议变更**：不新增帧、不新增帧字段。

- **判定入口**：新增纯函数 `SyncFileOverwriteJudge`（零 IO / 零 GRDB，可进 harness）——输入 = `toPush` + 本端 manifest `local` + 对端 manifest `remote` + 每 peer 台账行 + `nowMs`；输出 = `(allowed, conflicts, skipped)`（`skipped` = **本批新增**：静默跳过桶——不推、不弹窗、不计入「待确认」）。
  - **只在 `direction == .upload` 生效**；`download` 原样放行（现状本就不覆盖，冲突项进 `conflictingKept`）。
  - **插入点** = 差集算完之后、推 / 拉分派之前（`SyncCollectionSyncCoordinator+Execution.swift` 的 `diff` 之后、`beginTransfers()` 之前）。
  - **排除 `@lyrics/*`**：歌词走 §6.3 的「只补不覆盖」，用现成 `SyncLyricsNamespace.isLyricsPath` 排除（判据不落到文件覆盖门上）。
- **判定 7 条**（记 `L` = 本端 entry、`P` = 对端 entry、`T` = 台账行 `(peer_id, relative_path)`；`T.localHashAtDecision` = **决策时的本端指纹**）：
  1. `P.hash == L.hash` → 放行（防御式；本不应进 `toPush`）｜`contentEqual`
  2. `T` 存在 且 `T.state == "approved"` 且 `T.localHashAtDecision == L.hash` → 放行（用户已确认且本端未再变）｜`userApproved`
  3. `T` 存在 且 `T.state == "approved"` 但 `T.localHashAtDecision != L.hash`（确认后本端又变）→ **冲突**（确认作废，须重新确认；对端未变 `undecidable` / 对端也变 `peerChanged`）｜边界 A1
  4. `T` 存在 且 `T.state == "kept"`（用户上次选〔保持现状〕，**本批新增**）：
     a. `T.contentHash == P.hash` 且 `T.localHashAtDecision == L.hash`（对端未变 **且** 本端未变）→ **静默跳过**：不推、**不弹窗**、不计入「待确认」｜`skipped`
     b. `T.contentHash == P.hash` 但本端已变（用户在 Mac 重导 / 换版本）→ **冲突**（重新确认）｜`keptLocalChanged`（新原因码）
     c. `T.contentHash != P.hash`（对端文件又变了）→ **冲突**（重新确认）｜`peerChanged`
  5. `T` 存在（非 `approved` / 非 `kept`）且 `T.contentHash == P.hash` → 放行（对端自上次一致后没动过 = 正常更新）｜`peerUntouched`
  6. `T` 存在（非 `approved` / 非 `kept`）且 `T.contentHash != P.hash` → **冲突**（对端自己改过这个文件）｜`peerChanged`
  7. `T` 不存在 → mtime 兜底：两侧 `mtimeMs > 0` 且 `P.mtimeMs > L.mtimeMs + 容差` → **冲突**（对端更新）｜`peerNewerByMtime`；`P.mtimeMs <= L.mtimeMs + 容差` → 放行（对端只是旧副本）｜`noRecordPeerOlder`；mtime 不可判（任一侧为 0 / 相等）→ **冲突（保守）**｜`undecidable`
  - 容差 = **2000 ms**（同族文件系统粒度 + 扫描抖动），落成常量便于调。
  - `contentHash == nil`（未指纹）的条目无法比对台账 → 一律走「`T` 不存在」分支（mtime 兜底）。
- **台账表 `sync_peer_file_state`**（本端 Mac DB，每端一份；`CREATE TABLE IF NOT EXISTS`，不动既有表结构 ⇒ 不需要完成门）：

  ```sql
  CREATE TABLE IF NOT EXISTS sync_peer_file_state (
      peer_id             TEXT    NOT NULL,   -- 对端 DeviceID（与 sync_cursor / sync_push_cursor 同口径）
      relative_path       TEXT    NOT NULL,   -- 对账键（POSIX，相对曲库根）
      content_hash        TEXT    NOT NULL,   -- 「上次达成一致时」的内容指纹
      state               TEXT    NOT NULL,   -- agreed | pending | approved | kept
      local_hash_at_decision TEXT,            -- **决策时的本端指纹**（state = approved / kept 都写；校验「决策后本端是否又变了」）
      updated_at_ms       INTEGER NOT NULL,   -- 落库时刻（epoch 毫秒）
      PRIMARY KEY (peer_id, relative_path)
  );
  CREATE INDEX IF NOT EXISTS idx_sync_peer_file_state_state ON sync_peer_file_state(state);
  ```

- **状态机**：`pending`（判为冲突，待确认）/ `approved`（用户点了覆盖）/ `kept`（用户选〔保持现状〕：后续每轮**静默跳过**，仅当对端或本端文件再变才重新确认）/ `agreed`（双方一致）。
  - 写入时机：推送成功或拉取落盘成功 → `agreed`（`content_hash` = 本次发出的 hash）；判为冲突 → `pending`（`content_hash` = `P.hash`）；点「保持现状」→ `kept`（`content_hash` = `P.hash`，`local_hash_at_decision` = `L.hash`）；点「覆盖」→ `approved`（`content_hash` = `P.hash`，`local_hash_at_decision` = `L.hash`）。
   - **`kept` 的下次行为（本批补齐 · 2026-10-17 用户拍板）**：`kept` 行在后续每轮 upload 都过判定表**规则 4**——对端未变 **且** 本端未变 → **静默跳过**（不推、不弹窗、不计入「待确认」）；对端文件又变 → 重新弹窗（`peerChanged`）；本端文件又变（Mac 重导 / 换版本）→ 重新弹窗（`keptLocalChanged`）。「本端是否又变」靠 `local_hash_at_decision`（决策时落的本端指纹），与 `approved` 同口径。
- **交互（三选项）**：手动一轮判出冲突 → 冲突项移出本轮 `plannedPush` 并写 `pending`，**本轮照常推其余文件**；结果区出现「待确认覆盖 (N)」并**弹确认对话框** ——〔覆盖全部〕〔逐条勾选〕〔保持现状〕；点覆盖 → 写 `approved` → **立即重跑一轮 upload**（复用同一入口）。
- **自动通道**：将来若加内容自动同步，走**同一条 judge**；判为冲突 → **只写 `pending` + 计数上屏，不弹窗**（自动通道不阻塞用户）。
- **手机被动端**：**不加阻塞式确认**（被动端不发起，也不该让用户在手机上等点确认）；本期只做 Mac 侧。
- **形状守卫（P2，可下一批）**：`SyncLibraryPullController` 在 `selection == .all` 时会覆盖本端（未来误用即回归）→ 加形状测试（该控制器不得以 `.all` 构造）。
### 6.2 播放数据（双向 LWW · 仅共有歌曲 · 不传播删除）
- 范围：收藏、播放历史/次数（自动歌单数据源）、歌单结构、播放位置上下文、设置白名单
- 机制：本地变更日志表（outbox）+ 每 peer 游标；对端拉取/推送增量；**LWW（updated_at 大者胜）**
- **仅同步两端都有的歌（2026-09-10 拍板）**：播放数据以 content_hash 配对——一端独有的歌，其播放数据传输到对端没有意义，不传
- **跟歌走**：推送/下载歌曲时跟随同步该歌的播放数据（歌到哪，数据到哪）
- **不传播删除**：取消收藏/删歌单等删除操作**只在本地生效**，不跨端
- 冲突：v1 简单 LWW + 变更留痕；歌单"来源主机"归属留 v2
- **B1 时钟偏差防护（2026-10-16 用户拍板）**：应用远端行前判 `remote.updatedAtMs > localNowMs + 容差`（**5 分钟**）→ **不应用、计数上屏、丢弃本轮**（fail-closed：宁可暂不应用，也不让「来自未来」的旧行压过本端新行）。反方向（对端时钟滞后）本期无解，作为已知限制写入文档。
- **B2 播放位置 carry 单调（2026-10-16 用户拍板）**：新增反向记录表 `sync_playback_carry_state(peer_id, entity, row_key, last_pushed_outbox_id, last_pushed_updated_at, pushed_at, PRIMARY KEY (peer_id, entity, row_key))`；帧 9 的 `lastOutboxID` 取 `max(高水位, batchLastID)` ⇒ `sync_push_cursor` **单调不回退**、少推已给过的行。⚠️ B2 与 B1 是**配套**关系：台账只证明「我推过什么」，防「旧冲新」仍靠 LWW，而 LWW 需 B1 的 skew guard 才不被时钟偏差击穿。
- **零协议变更（2026-10-16 结论）**：A / B1 / B2 所需数据（`contentHash` + `mtimeMs` 已在帧 11 manifest 载荷里；`updated_at` 已在帧 8/9 载荷里；台账存本端 DB）→ **不新增帧、不新增帧字段**，旧端互通安全。若将来必须新增帧：帧号取 17，且**必须先做握手能力协商**（旧端收到未知帧类型会走解码失败路径，不是无声忽略，会打断会话）。
- 引用映射：UI/本地外键用 `stable_id`；跨端同步载荷引用 `content_hash`，同步层做双向映射

### 6.3 歌词（仅对齐歌词同步，2026-09-08 拍板 B 方案）
- 存储：**独立歌词库**（延续现状 `Documents/lyrics-manual/{stableId}.json` 形态，不散落到音乐目录；键 = 本地 stableId，同步层经 content_hash 映射）
- 歌词引入类型标记：`aligned`（对齐产物）/ `manual`（手动指定）/ `network`（网络缓存）——**只有 `aligned` 参与同步**；`manual` 与 `network` 默认不同步
- 同步语义：歌词作为"依附歌曲的内容"随歌曲复制——歌同步了 aligned 歌词跟着到；**不传播删除**（任一端删歌/删歌词都是本地事务，2026-09-10 拍板）
- **未来 AI 对齐功能（桌面版）产物自动保存为 `aligned` 类型入歌词库** → 随歌自动同步到移动端
- 网络歌词缓存：两端各自下载，不同步

## 7. Schema 变更

- `track` + `content_hash TEXT`（索引）；迁移 = 后台惰性计算
- 新表：`sync_device`（配对记录）、`sync_outbox`（变更日志）、`sync_cursor`（每 peer 游标）
- 迁移兼容：旧库打开自动加列，无数据丢失；iCloud 容器数据迁移走内容指纹映射（见 §8）

## 8. iOS 本地沙盒改造（前置，并入本阶段）

1. LibraryIndexer iOS 分支：NSMetadataQuery(ubiquity) → FileManager 目录扫描（参考 macOS 实现）
2. 音乐目标位置 = 沙盒 `Documents/`（UIFileSharingEnabled 已开）；DB 仍在 App Group（不动）
3. 迁移：iCloud 容器有歌 && 沙盒空 → 实体化 dataless → 分批复制 → content_hash 映射旧引用 → 校验 → 切索引 → 清 iCloud 副本（幂等可断点）
4. 退役：CloudDownloadManager(688)/AppCoordinator+iCloud(532)/FileCleanupManager iCloud 逻辑 ~2000 行
5. UI：移除 iCloud 设置项；防"双位置重复"（同 content_hash 判同）

## 9. 安全与合规

- 威胁模型：
  | 威胁 | 防御 |
  |---|---|
  | 局域网窃听 | TLS 加密 |
  | 中间人 | 证书 pinning（公钥 = 配对记录） |
  | 冒充已配对设备 | 指纹验证，无私钥连不上 |
  | 恶意配对请求 | 人工 approve + 限流 + nonce |
  | 设备丢失 | 撤销配对 |
- iOS：`NSLocalNetworkUsageDescription` 文案（App Store 审核）+ Bonjour 服务类型声明
- Keychain 存私钥；私钥不出设备
- 隐私：播放历史属敏感数据，UI 明示同步范围，默认仅同步用户选择内容

## 10. UI 草案

- **Host（macOS）**：设置/侧栏 → 同步中心：已配对设备（在线/离线）、添加设备（QR/手输）、**同步内容选择（歌单/歌曲勾选 + 容量提示）**、推送/拉取、同步历史
- **Client（iOS）**：设置 → 同步：主机列表、**被同步状态与进度/占用**（被动端，不发起同步）
- **发起方恒为 Mac（2026-09-10 拍板）**：自动同步 = Mac 侧控制（设备在线时由 Mac 发起，仅针对已选内容；**不做全库自动推送**——移动端容量约束）；iOS 无后台自动同步

## 11. 任务拆分（里程碑，各自可独立验证）

- **M1 身份 + 配对**：密钥对/Keychain、Device ID、QR 生成与扫码、手输路径、配对握手与 approve、mDNS 发现
- **M2 传输通道**：NWConnection 帧、TLS pinning、断点文件流、SHA-256 校验
- **M3 文件同步**：manifest 对账、双向传输、同步集合、iOS 沙盒接入收尾
- **M4 数据同步**：outbox/游标/LWW、收藏/历史/播放位置/歌词
- **M5 存量迁移**：content_hash 惰性回填、iCloud → 沙盒数据迁移
- **M6 UI + 真机验收**（用户验收）

依赖顺序：M1 → M2 → M3/M4 并行 → M5 可提前与 M3 并行；每 M 结束编译 + 单测（CI 通道），UI 验收交用户真机。

## 12. 决策记录（2026-09-08 已拍板）

1. 传输选型：**A（NWConnection + 长度前缀帧）** ✅
2. Host approve UX：**弹窗确认** ✅（延续旧版配对习惯）
3. 歌词存储：**B（独立歌词库 + 内容通道同步）**，且**仅 aligned（对齐）歌词参与同步** ✅
4. 自动同步：**默认开 + 仅 Wi-Fi** ✅
5. 配对 UX：**QR 扫码为主 + 手动输 ID 兜底** ✅

## 12b. 同步语义修订（2026-09-10 用户拍板，覆盖 §6 旧"双向/镜像"表述）

6. **发起方恒为桌面端（Mac）**：推送（Mac→移动）与下载（移动→Mac）都由 Mac 发起；移动端被动 ✅
7. **不传播删除**：任一端删除歌曲/收藏/歌单都只在本地生效，**绝不跨端删除** ✅
8. **播放数据仅同步两端共有的歌**（content_hash 配对）+ **跟歌走**（推/拉歌时带该歌播放数据）✅
9. **歌单/收藏可选同步**：勾选要同步的歌单；同步时目标端缺歌**自动上传补齐** ✅
10. **不做全库自动镜像**：移动端容量有限，自动同步只针对用户已选内容 ✅

## 12b. 开放问题

1. 手动指定歌词（manual）后续是否需要纳入同步（当前默认不同步）——待产品反馈
2. 歌单"来源主机"归属（v2 候选）
## 12c. 内容来源标识命名空间（`@smart:*`，2026-09-13）

**背景**：同步页内容选择区原来只有「全曲库 / 歌单 / 单曲」三级，单曲级只有搜索框 + 全库
分页逐首勾选（用户反馈「要一首一首搜索」）；播放列表页已有的自动歌单在同步页完全用不上。
本期把「来源」提成一等概念：**单曲 tab 先选来源再搜索/分页；歌单 tab 的行可下钻到该来源
的单曲列表**。本期只做 3 个自动歌单来源（最近添加 / 最近播放 / 常听排行），年代留待后续。

**命名空间（冻结；纯 ID 空间扩展——帧 15/16 的帧号与载荷结构一律不变）**：

| 标识 | 含义 | 发帧 15 时的 `playlistID` |
| --- | --- | --- |
| `@library` | 全部曲库（**仅本端 UI 合成项**，不出现在对端清单里） | `nil`（= 既有「不过滤」语义） |
| `@favorites` | 收藏（既有保留标识） | `@favorites` |
| `<slug>` | 真实歌单（既有） | `<slug>` |
| `@smart:recentAdded` | 最近添加 | `@smart:recentAdded` |
| `@smart:recentPlayed` | 最近播放 | 同左 |
| `@smart:topPlayed` | 常听排行 | 同左 |

- **非法 / 未知标识 = 空集**：沿用 `SyncCollectionSelection.isValidPlaylistID` 口径
  （长度上限 128、拒点段 / 路径分隔符 / 控制字符）；`@smart:` 后不是已知种类、未知 `@` 前缀
  一律**解析失败 → 不产生任何来源**，**绝不回落全库**（选不出内容比误给全库安全）。
- **自动歌单成员口径与播放列表页同一数据层**：`SmartPlaylistStore` 的
  `recentAddedTracks` / `recentPlayedTracks` / `topPlayedTracks`，条数上限同为
  `SmartPlaylistStore.limit`（50）；两端同一份实现（`SmartPlaylistSourceResolver`）。
- **数字自洽纪律**：对端清单里 `@smart:*` 条目的 `trackCount` 恒等于「按该 id 筛 tracks」
  的条数（成员集先与曲目清单求交；既有 `@favorites` 同款纪律）。
- 年代（`@smart:decades`）本期不做（解析为 `nil` = 空集）。

**向后兼容（关键）**：

- **老对端（不认识 `@smart:*`）** 不会在清单里返回这些条目 → Mac 侧表现仅为
  「来源下拉里没有自动歌单分组」，**不报错、不影响**全库 / 收藏 / 真实歌单的既有路径。
- **新 Mac → 老移动端**：老移动端收到未知 `@smart:*` playlistID 时按既有「未知歌单 =
  空集」语义处理（`SyncPeerLibraryCatalog.memberPaths`），**不回全库、不崩、不误删**。

### 12c.1 来源内曲目顺序（2026-09-13 统一）

**规则：来源内列表顺序 = 来源自身顺序**（两端一致）。

| 来源 | 顺序 |
| --- | --- |
| 全部曲库 | `relativePath` 升序（既有契约，未变） |
| 收藏 / 真实歌单 | 成员表顺序（收藏顺序 / 歌单成员序） |
| 最近添加 | `modification_date` 降序（最新在前） |
| 最近播放 | 最近播放时间倒序（同曲去重） |
| 常听排行 | 播放次数降序（并列按累计时长） |

- 发起端（Mac）本端列表：`SmartPlaylistSourceResolver.tracks(for:)` 保持来源序（`orderedRelativePaths(for:)` 是该序的相对路径版）。
- 被动端（帧 15/16）：`SyncPeerLibraryCatalog.trackPathsByPlaylist` 存**有序**成员表；tracks 范围带 playlistID 收窄时按该序返回（`matchedTracks`），**未带 playlistID 时仍是 relativePath 升序**（既有契约不动）。
- 来源内搜索（query）只做过滤、**不重排**。
- `trackCount` 恒等于「按该 id 筛 tracks」的条数（保存自洽纪律）。

## 13. 变更记录

| 日期 | 变更 | 依据 |
| --- | --- | --- |
| 2026-10-16 | §6.1 新增「冲突判定 + 待确认覆盖」（`SyncFileOverwriteJudge` 判定 7 条 + 新表 `sync_peer_file_state` + 状态机 `pending`/`approved`/`kept`/`agreed` + 三选项交互 + 自动通道只写 `pending` 不弹窗 + 只做 upload 方向 + P2 形状守卫 + 排除 `@lyrics/*`）；§6.2 新增 B1（对端时间戳超前 > 5 分钟 → 不应用 + 计数上屏）与 B2（`sync_playback_carry_state` + 游标单调不回退）；明确**零协议变更** | 用户 2026-10-16 拍板（契约 = `docs/sync-contract.md` §4） |
| 2026-10-17 | §6.1 补齐〔保持现状〕(`kept`) 的**下次同步**语义：判定表新增 `kept` 分支（对端 + 本端都未变 → **静默跳过**，新增 `skipped` 输出桶；本端又变 → 冲突 `keptLocalChanged`（新原因码）；对端又变 → 冲突 `peerChanged`）；台账「决策时的本端指纹」字段统一为 `local_hash_at_decision`（`approved` / `kept` 都写），表列同批对齐（`updated_at_ms`；批 2 不落未被判据消费的 `peer_mtime_ms` / `local_mtime_ms`） | 用户 2026-10-17 拍板（契约 = `docs/sync-contract.md` §4） |
