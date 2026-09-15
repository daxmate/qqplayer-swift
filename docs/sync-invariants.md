# 局域网同步不变量清单

> 2026-09-14 只读审计产出。基线 commit `7a2566b`。
> 配套：`docs/sync-matrix.md`（实体 × 能力矩阵 + 空格清单）。
>
> 每条格式：**不变量（一句话，可验证）** → 现有守护 → 建议的守护形式。
> `✗ 无守护` = 目前**只活在文档或注释里**（今天的事故基本全是这一类）。
> **今天的事故基本全是这一类**——这一点就是本文件存在的理由。

---

## A. 存储与真值

### INV-1　outbox 必须是本地真值的**可重建派生**（业务表是唯一真值，outbox 只是变更流；业务表有一行而 outbox 没有对应 upsert ⇒ 该事实永不同步）

- **现有守护**：`✗ 无守护`（**只活在文档里**）
  - 只有部分实体的**运行时**补救：`SyncChangeLogDanglingRepair.reconcileLocalTruth`（`QQPlayer/Sync/SyncChangeLogMapping.swift:588`），覆盖 `.favorite / .playHistory / .playlistItem`（`reconcilableEntities` `:571`）——**不含 `.playlist`**。
  - 行为用例只覆盖已覆盖的三类：`QQPlayerTests/SyncChangeLogContentMapTests.swift:793/:821/:843/:861/:881`。
- **建议**：**静态契约**（新增）+ 行为用例（补齐）
  - 静态：断言 `SyncChangeEntity.allCases` 的每个 case 都能被回答「本地真值在哪张表 / 由谁补发」——在 `SyncWiringContract.requirements` 里加一条，或在 `QQPlayerTests` 加「实体 × 补发归属表」全覆盖用例（`#expect` 每个 `allCases` 都有归属，防止新增实体漏通道）。
  - 行为：为 `.playlist` 补 `reconcileLocalTruth` 分支 + 用例（现无，见矩阵 C⑤）。

### INV-2　本地写入点必须与 outbox 记录**同一事务**（绝不先改业务行后补 outbox，或反之）

- **现有守护**：**行为用例**，部分覆盖：`SyncChangeLogStoreTests.swift:73/:101/:167/:203/:237`
  （断言「调一次业务 API → outbox 出现一行」）；无「事务原子性」的故障注入用例（无法证明失败时不写 outbox）。
- **建议**：**行为用例**：write 事务内抛错 → 断言业务行与 outbox 行**都没有**（用 GRDB 内存库注入一次失败的事务）。

### INV-3　outbox 行引用的歌曲必须在本端 `track` 表可解析（悬空引用 = 废行，必须修或清，不得每轮重发）

- **现有守护**：**行为用例**：`SyncChangeLogContentMapTests.swift:593`（按 `played_at` 改写救回）、`:632`（不可修复 → 清理 + 计数）、`:674`（幂等）、`:707`（不误伤业务行）。
- **建议**：保持；补一条**面板披露**要求（清理数当前只在日志里 `logText`，`MacSyncView.swift` 未展示）。

---

## B. 跨端身份（content_hash）

### INV-4　引用歌曲的实体行，**没有可用身份键就不许落库**（落库会写出 `JOIN track` 永不匹配的孤儿行：界面无变化而面板显示「已应用 N」）

- **现有守护**：**行为用例**：`SyncChangeLogContentMapTests.swift:412`（缺身份键的 play_history 不落库、计数回调收到 1）；`SyncLWWReconcileTests.swift:276`（applier 身份兜底：favorite / play_history / playlist_item 一律跳过）；实现 `SyncChangeLogApplier.trackRowExists` `SyncChangeLogApplier.swift:96`。
- **形状守护（2026-09-15 身份入口包，B1b 扩到三方向）**：`SyncIdentityContractTests.productionHasSingleIdentityImplementation`（静态扫描：生产码里 `stable_id ↔ content_hash` 与「曲库路径 → 身份」都**只有一处**实现，白名单只留 `QQPlayer/Sync/SyncChangeLogMapping.swift`；并且生产码里不得再用闭包构造身份映射）+ `SyncWiringContractTests` 的 `identity-entry-implemented-and-wired`（入口遵守声明与映射构造点存在）——防止「新增消费点各自写一套解析」，那正是「不落库也看不出来」的上游。
- **建议**：保持；**静态契约**补一条：`SyncChangeLogApplier` 的五个 `apply*` 分支中，凡 `SyncTrackReference.referencesTrack(entity) == true` 的必须在写业务行前调用 `trackRowExists`（防止新增实体漏查）。

### INV-5　引用歌曲的行上不了线时**必须被计数并披露**，不得静默填 nil

- **现有守护**：**行为用例**：`SyncDataSyncCoreTests.swift:284`（拉取侧未定位 + 推送侧缺指纹各自计数，且不提前收尾）；实现 `SyncWireMissingIdentity` `SyncChangeLogMapping.swift:210`、`wireEntriesDetailed` `:257`。
- **形状守护（2026-09-15 身份入口包，B1b 扩到三方向）**：`SyncIdentityContractTests.productionHasSingleIdentityImplementation` + `SyncWiringContractTests` 的 `identity-entry-implemented-and-wired`——身份解析收口到唯一入口 `SyncIdentityResolving`（生产实现 `SyncContentHashResolver`；三方向 = stableId → content_hash / content_hash → stableId / 曲库路径 → 身份）；「拿不到身份键」只可能发生在**一个**解析点上，不再有「某一路径忘了接线、于是静默返回 nil」的第二种成因。
- **建议**：保持；补**面板披露**强约束（见 INV-12）。

### INV-6　不引用歌曲的实体（`playlist`）不得被要求提供身份键（必须走 passThrough，不许被判「未定位」）

- **现有守护**：**行为用例**：`SyncChangeLogContentMapTests.swift:208`（歌单行 contentHash = nil 且 row_key 不改写）、`:338`（歌单行 → 透传）；实现 `SyncTrackReference.referencesTrack` `SyncChangeLogMapping.swift:152`。
- **建议**：保持。**风险点**：新增实体（如未来 `setting`）忘了在 `referencesTrack` 里表态 → 默认 `true` → 被判「未定位」静默丢弃。建议加**静态契约**：`referencesTrack` 必须对 `SyncChangeEntity.allCases` 全覆盖（`switch` 无 `default` 分支即编译期强制）。

### INV-7　对端行必须先**本地化**才能进 LWW（LWW 键 = `(entity, row_key)`，两端 stableId 不同；不本地化 = 各记一条、永不收敛）

- **现有守护**：**行为用例**：`SyncChangeLogContentMapTests.swift:266`（命中映射 → row_key + payload 改写）、`:338`（无此歌 → 挂起）、`:446`（跨端 roundtrip 落地）；`SyncDataSyncCoreTests.swift:152`（推增量 → 对端按 contentHash 落库）。
- **建议**：保持。

### INV-8　本地缺歌时必须**挂起**而不是丢弃；且挂起行必须有重放触发点

- **现有守护**：**行为用例**：`SyncChangeLogContentMapTests.swift:471`（挂起 → 歌带 `content_hash` 入库 → 自动补上）、`:504`（重放幂等）、`:522`（重放走 LWW）、`:549`（挂起幂等）。
- **装配守护**：重放触发点两处（`DatabaseManager+Tracks.swift:87`、`DatabaseManager.swift:999`）**无静态断言** → `✗ 无守护`。若哪天 `upsertTrack` 的 replay 调用被删，挂起行会永久积压且零报错。
- **建议**：**静态契约**：在 `SyncWiringContract.requirements` 加一条「track 入库路径必须调用 `SyncChangeLogReplay.replay`」（路径 `QQPlayer/Services/DatabaseManager*.swift`，标记 `SyncChangeLogReplay.replay(`）。

---

## C. 游标

### INV-9　游标越过即不回头 ⇒ **必须**有重置入口（否则身份键修复后，被越过的行永不再同步）

- **现有守护**：**行为用例**：`SyncChangeLogStoreTests.swift:300`（`resetCursors` 同时清零两个方向、不碰其它 peer、可重复调用）；UI 入口 `MacSyncView.swift:918`（按钮）+ `:100`（二次确认）；编排 `MacSyncDataViewModel.resetCursorsForPeer` `QQPlayer/Mac/MacSyncDataViewModel.swift:189`。
- **缺口**：**iOS 端无重置入口**（`grep -rn resetCursors QQPlayer/` → 只有 Mac 侧调用点 + store 定义）→ 被动端一旦被越过就**没有任何自救手段**。
- **建议**：**面板披露 + 行为用例**：iOS 被动端补一个「重新对账」入口（或在文档中显式声明「被动端不支持，需在 Mac 侧重置」并断言该声明）。

### INV-10　游标推进值必须 = **本批实际发出去的最后一行 id**，且与取批在同一读事务（否则分页下第 N+1 行起被永久越过）

- **现有守护**：**行为用例**：`SyncChangeLogStoreTests.swift:336`（page 的 `lastOutboxID` = 本批末行、批外行不被越过、空批/越末尾不动游标）；`SyncDataSyncCoreTests.swift:209`（超 batch 分批，每批末行 id）；`SyncPlaybackCarryTests.swift:369`（carry 方向同口径）。
- **建议**：保持（这是少数已收口得很好的不变量）。

### INV-11　推送游标与拉取游标**绝不可复用同一张表**（方向相反，合表 = 推/拉互把对方位置当自己起点）

- **现有守护**：**行为用例**：`SyncDataSyncCoreTests.swift:130`（推送游标不串 peer、与拉取游标互不干扰）；表分离 `SyncPeerCursor` / `SyncPeerPushCursor`（`SyncDataSyncModels.swift:93/:117`）。
- **建议**：保持。

### INV-12　推送批次**全部成功**才推进 pushCursor（任一批失败 ⇒ 整体失败、游标不动）

- **现有守护**：**行为用例**：`SyncDataSyncCoreTests.swift:152`（重推 0 条不发帧）。
- **缺口**：**无「中途失败游标不动」用例** → `△ 部分守护`。
- **建议**：**行为用例**：第 2 批发帧失败 → 断言 pushCursor 仍是原值、重跑能补上。

---

## D. 语义（删除 / 抑制）

### INV-13　删除不跨端传播：`delete` 变更不上线、收到一律忽略、且**绝不在接收侧挂起**

- **现有守护**：**行为用例**：`SyncDataSyncCoreTests.swift:179`（同键本批末行是 delete → 其更早 upsert 也不上线）、`:343`（帧 9 里的 delete 被忽略并计数）；`SyncLWWReconcileTests.swift:142/:177/:224`（applier 层 delete 被忽略、不删本地行）；`SyncPlaybackCarryTests.swift:248`。
- **单一事实源**：`SyncChangeLogDeletionPolicy`（`QQPlayer/Sync/SyncChangeLogDeletionPolicy.swift`，5 个消费点，刻意不 import GRDB 以进 harness）。
- **建议**：保持。补**静态契约**：断言 `delete` 判定只出现在该文件（`grep "op == \"delete\"\|isDelete"` 命中数上限），防未来多写一处判定而漂移。
  - 现在这条**只活在文件头注释里**（「散落实现必然漂移」），尚未变成断言。

### INV-14　同键「批内末行是 delete」⇒ 该键**更早的 upsert 也不上线**（否则对端复活一个本端已删的状态，且 delete 永不上线无法纠正）

- **现有守护**：**行为用例**：`SyncDataSyncCoreTests.swift:179`。
- **建议**：保持。

### INV-15　挂起表里**不得**存在 delete 行（历史遗留库也必须被防御性清理）

- **现有守护**：**行为用例**：`SyncLWWReconcileTests.swift` 的 delete 忽略组 + 重放防御实现 `SyncChangeLogPendingStore.swift:151-161`。
- **缺口**：**无「历史 delete 挂起行被清理」的专门用例** → `△`。
- **建议**：**行为用例**：手工插一条 delete 挂起行 → `replay` → 断言挂起行消失且本地业务行未删。

---

## E. 装配与披露（今天事故的策源地）

### INV-16　每个跨端能力必须有**平台装配断言**（协议支持 ≠ 有实现 ≠ 已装配；每包自测全绿也能让接线掉进缝里）

- **现有守护**：**静态契约**：`QQPlayerTests/SyncWiringContractTests.swift`（5 条断言 + 合成源码自证 `:193/:207`，fail-closed `:123`）。
- **缺口**：只覆盖帧 8/9 处理器与 Mac 入口，**粒度是「类型被构造」而不是「每个实体都被处理」**；且 `QQPlayer/Mac/*` 属 Mac target（iOS 单测 target 看不到，仓库无 macOS 单测 target）→ Mac 侧行为**只能靠编译 + 契约扫源码**（`MacSyncDataViewModel.swift:29-31` 自述）。
- **建议**：**静态契约**扩展：
  1. `ios-lyrics-receiver-attached`（`SyncLyricsReceiver` 在被动端被构造）
  2. `ios-data-sync-reset-reachable`（或显式断言 iOS 不支持重置，见 INV-9）
  3. `replay-trigger-attached`（见 INV-8）

### INV-17　同一会话只装一个 changeLog 处理器（重复装配 = 帧被处理两次 / 游标错乱）

- **现有守护**：**行为用例（间接）**：`SyncDataSyncCoreTests.swift:325/:396`；实现层用 `dataSyncPeer == nil` 守卫（`IOSPassiveSyncCenter.swift:521`）。
- **建议**：**静态契约**：`SyncChangeLogPeer(` 的构造点计数上限（Mac 1 处 + iOS 1 处，防止未来复制粘贴出第三个）。

### INV-18　缺口必须**计数并上屏**，且**区分实体**

- **现有守护**：`△` 计数有、上屏有（两端）、实体维度**仍然没有**。
  - 计数：`SyncDataSyncReport`（`QQPlayer/Sync/SyncDataSyncCoordinator.swift:68`）——L6 起账目 = `SyncOutcomeTally`（`QQPlayer/Sync/SyncOutcomeTally.swift`）。
  - 上屏：Mac `QQPlayer/Mac/MacSyncView.swift`（8 个总数）、iOS `IOSPassiveDataSyncPresenter`（4 缺口行 + 4 计数行，`QQPlayer/Services/IOSPassiveSyncCenter.swift`）。
  - `✗` 歌词丢弃计了数没进 `SyncUIReportSummary`（`QQPlayer/Services/SyncUIState.swift` 无该字段）。
- **L6 守护（2026-09-15 立，可执行名字）**：
  - `QQPlayerTests/SyncDataSyncCoreTests.swift` → `outcomeTallySlotsAreOneToOne`（`SyncRowOutcome.allCases` 每类恰一个槽位、互不串台；类别数变了先红）
  - `QQPlayerTests/SyncWiringContractTests.swift` → `productionHasSingleOutcomeTally`（静态：结果计数**只准**声明/改写于 `QQPlayer/Sync/SyncOutcomeTally.swift`，别处分类 `+=` / `=` 即红）
  - `QQPlayerTests/SyncWiringContractTests.swift` → `syntheticSecondLedgerIsCaught`（合成「第二处账目」必须被抓到——契约定自证不空转，fail-closed）
  - `QQPlayerTests/SyncDataSyncCoreTests.swift` → `presenterPlacementCoversAllOutcomes`（新增类别不给展示归宿就红）+ `passiveDataSyncPresenterRowsArePure`（缺口行只列 >0、顺序 = 严重度、每条都有 hint）
- **建议**：**面板披露** + **静态契约**
  - 面板：`SyncDataSyncReport` 按实体分桶（`[SyncChangeEntity: Int]`）→ 面板分实体展示（**仍未做**）；歌词 `discardedLyrics` / `orphanLyricsSkipped` 进 `SyncUIReportSummary`（**仍未做**）。
  - 静态：✅ 已落（见上 `productionHasSingleOutcomeTally`）。

### INV-19　面板数字必须来自**协调器账目单一数据源**（不在 UI 层补算）

- **现有守护**：**行为用例**：`SyncUIStateTests.swift`（`SyncUIReportSummary.make` 唯一映射）；注释纪律 `SyncUIState.swift:478`「唯一数据源；不在这里补算任何数字」。
- **L6 守护（2026-09-15 立）**：两端账目**持有同一个** `SyncOutcomeTally`（Mac `SyncDataSyncReport.tally` / iOS `IOSPassiveDataSyncSummary.tally`），面板/纯逻辑读的是它的投影——L6 之前 iOS 那套是**自己声明**的一份计数（同一账目两个结构）。
  - 行为用例：`QQPlayerTests/SyncDataSyncCoreTests.swift` → `bothLedgersShareOneTally`（同样写入 → 同一份账目；旧读数名 = 槽位口径）+ `tallyAccumulateAndOverwriteSemantics`（累加 / 「最近一批」覆盖写）
  - 静态：`QQPlayerTests/SyncWiringContractTests.swift` → `productionHasSingleOutcomeTally`（别处不得分类 `+=` / `=`；**只读投影与比较放行**——Mac 面板 / iOS 纯逻辑就是只读）
- **建议**：保持；若要更严，可再补「`MacSync*View` 里 `report.` 之外的算术」白名单（本轮未做）。

### INV-20　「已应用 N」必须真的是落库行数（静默丢弃不算应用）

- **现有守护：✅ 已收（2026-09-15）**
  - `SyncChangeLogApplier.applyPlaybackPosition`：开关关 / 无落点 / 落点未接受（不同曲 / 远端更旧 / 位置差 < 3s）——三条路径一律 `return false`，并触发 `onPlaybackPositionUnsupported` → `SyncChangeLogPeer.onPushUnsupported` → `SyncDataSyncReport.unsupportedEntries` → 面板「未支持」行。
  - 用例：`SyncDataSyncCoreTests`（开关关 → 不计「已应用」+ 计未支持；开但无落点 → 同；落点未接受 → 同）。
- **L6 守护（2026-09-15 立）**：`.applied` 与 `.unsupported` / `.unresolved` / `.skippedMissingParent` / `.ignoredDelete` 是**互不相干的槽位**（`QQPlayerTests/SyncDataSyncCoreTests.swift` → `outcomeTallySlotsAreOneToOne`）——「没落库的不许算进已应用」在枚举层就是形状，不再靠「每处对账」。
- **建议**：已落；后续任何新增 `apply*` 分支都必须守「没落库就不 return true」。

---

## F. 依附内容（歌词 / 封面）

### INV-21　依附内容必须用**同一跨端身份键**定位（歌词用歌曲 `content_hash`，不得用本端 stableId）

- **现有守护**：**行为用例**：`AlignedLyricsSyncTests.swift:149`（命名空间双向）、`:160`（manifest 以歌曲 content_hash 为键）、`:234`（生产映射复用 resolver）、`:348`（端到端按 content_hash 映射落本端 stableId）；**无模拟器 harness** `scripts/sync-harness/main.swift`。
- **建议**：保持。

### INV-22　依附内容在目标端定位不到时不得写孤儿（歌词丢弃 + 记账；封面同理）

- **现有守护**：歌词：`AlignedLyricsSyncTests.swift:374`（无对应歌曲 → 丢弃不落库）、`:394`（删除不传播）。封面：`✗ 无守护`（`SyncChangeLogApplier.swift:166/179` 原样写入对端本地路径）。
- **建议**：**行为用例**：封面路径来自对端时必须被清空或改写；**面板披露**：封面加载失败计数。

### INV-23　歌单自定义封面**不是**可跨端直接引用的值（`custom_cover_image_path` 是设备本地相对路径）

- **现有守护**：`✗ 无守护`（**只活在「文件传输不含封面」这一事实里，没有任何地方声明它**）
  - 证据：`SyncDataSnapshots.swift:69/79`；`grep -rn "cover" QQPlayer/Sync/` 无传输点。
- **建议**：**静态契约** + **面板披露**：明确二选一——① 封面文件走文件通道（仿 `@lyrics/{content_hash}` 做 `@cover/{content_hash}`）；② 声明「封面不同步」并在 `applyPlaylist` 落库时把对端来源的 `customCoverImagePath` 置 nil。断言「`applyPlaylist` 不会写入非本端路径」。

---

## G. 映射与未知输入

### INV-24　未知实体 / 未知歌单标识一律**空集**，绝不回落全库

- **现有守护**：**行为用例**：`SyncPeerLibraryTests.swift`（`memberPaths` 未知 → 空集）、`SyncCollectionSelectionTests.swift`（`isValidPlaylistID` 口径）、`SyncBrowseSourceTests.swift`（`@smart:*` 解析失败 → 无来源）；文档 `docs/lan-sync-design.md` §12c。
- **建议**：保持。

### INV-25　对端来的载荷一律按不可信输入处理（不得用于拼路径）

- **现有守护**：**行为用例**：`AlignedLyricsSyncTests.swift:107`（非法 stableId 拒）、`:181`（越界 / 软链逃逸拒）、`:149`（hash 形态校验）；`SyncPeerLibraryTests.swift`（路径包含性）。
- **建议**：保持。

---

## 8. 汇总：目前**只活在文档或注释里**的不变量（今天事故的类别）

| 不变量 | 只活在何处 | 建议立刻补的守护 |
| --- | --- | --- |
| INV-1 outbox = 本地真值派生 | `docs/lan-sync-design.md` §6.2 文字 + `SyncChangeLogMapping.swift:37-48` 注释 | **静态契约**（allCases × 补发归属全覆盖） |
| INV-4 无身份键不得落库 | 实现有、注释有 | 静态契约（applier 分支全覆盖） |
| INV-8 挂起必须有重放触发点 | `SyncChangeLogPendingStore.swift` 文件头 | **静态契约**（`SyncChangeLogReplay.replay(` 必须出现在 track 入库路径） |
| INV-9 游标越过即不回头 ⇒ 必须有重置入口 | `SyncChangeLogStore.swift:134-147` 注释 | iOS 侧入口 or 显式「不支持」断言 |
| INV-13 删除不传播收口到单一事实源 | `SyncChangeLogDeletionPolicy.swift:13-18` 注释 | **静态契约**（delete 判定只准出现在该文件） |
| INV-17 同一会话只装一个 changeLog 处理器 | `IOSPassiveSyncCenter.swift:21-32` 注释 | 静态契约（构造点计数上限） |
| INV-18 缺口必须计数并上屏 | `MacSyncView.swift:978` 注释 | **面板披露**（按实体分桶）+ 静态契约 |
| INV-20 「已应用」= 真的落库 | `SyncChangeLogApplier.swift:223-255` 注释自承「v1 不落库」 | **行为用例**（sink nil ⇒ 不算 applied）+ 面板披露 |
| INV-23 封面路径不可跨端引用 | **无处声明** | 静态契约或面板披露（见上） |

### INV-26　跳端续播（`playback_position`）必须由**同一个开关**门控，且**默认关**（关 = 零出站零入站）

- **现有守护：✅ 已收（2026-09-15）**
  - 设置：`DeleteSettings.syncPlaybackPositionEnabled` 默认 **false**（`decodeIfPresent ?? false` 兜底旧设置）；
  - 出站：`PlaybackPositionCapture.recordIfEnabled` 开关关 → **直接 return（零 DB 访问）**；开 → 换歌必记 / 同曲 60s 节流；
  - 入站：`SyncChangeLogApplier.playbackPositionSyncEnabled` 关 → 不落点 + 计 `unsupportedEntries`；开且同曲才落（`PlaybackPositionResumeSink`，LWW，**绝不改 isPlaying**）；
  - 用例：`SyncDataSyncCoreTests`（旧设置无 key → false；开关关 → 不落点不计「已应用」；开但无落点 / 落点未接受 → 同）。
- **建议**：两端门控读**同一设置项**这条事实源不要漂移（捕获/落点/装配三处）；补静态契约前先保持。

### INV-27　连接就绪后必须**自动**跑一轮「同步数据」（补发不得依赖用户动作）

- **现有守护：✅ 已收（2026-09-15）**
  - 触发：`SyncHostCenter.handleSessionPhase(.ready)` → `MacDataSyncAutoRunner.sessionDidBecomeReady`
    （App 级：面板没打开也跑）；会话关闭 → `sessionDidClose()` 清「一次连接一次」标记。
  - 互斥：手动（面板按钮）与自动**共用一个在飞门** `SyncDataRunGate`（同一会话只允许一轮；
    取不到 = 放弃本轮，不排队）。
  - 判定纯逻辑：`SyncDataAutoRunDecision.shouldStart(isConnected:hasActiveSession:isBusy:didAutoRunForCurrentConnection:)`。
  - 用例：`SyncDataSyncCoreTests`（`autoRunDecisionIsPure` / `runGateIsExclusive`）。
- **建议**：保持；以后任何新增的「自动触发」都走同一个门，别再写第二个 busy 标记。

### INV-28　父行 / 被引用行不存在时：不落库、**必须计数上屏**（静默失败不允许）

- **现有守护：✅ 已收（2026-09-15）**
  - applier 侧：`SyncChangeLogApplier.onSkippedMissingParent`（三种成因：`playlist_item` 的歌单结构未到、
    收藏 / 播放历史 / 歌单项引用的歌在本地 `track` 查无）——一律 `return false`（**不计「已应用」**）+ 计数；
  - peer → `SyncChangeLogPeer.onPushSkippedMissingParent`（按批累加）→ `SyncDataSyncReport.skippedMissingParentEntries`
    → Mac 面板「缺依赖」行 + hint（5 语）。
  - 用例：`SyncDataSyncCoreTests`（`applyPlaylistItemCountsMissingPlaylistParent` / `applyFavoriteCountsMissingTrack`）。
- **建议**：以后任何新增的 `return false` 分支都要配一个计数字段；「没落库就不许算已应用，也不许无声无息」。

### INV-29　账目必须在**两端都可见**（不能只有一端有面板、另一端只 `print`）

- **现有守护：✅ 已收（2026-09-15）**
  - Mac：`MacSyncView` 同步数据区（计数行 + 缺口行 + hint，5 语）。
  - iOS：`IOSPassiveSyncCenter.dataSummary`（帧 8/9 回调累加，主线程）+ `IOSPassiveDataSyncPresenter`
    （`countRows` / `gapRows` 纯逻辑）+ `SyncSettingsView` 的「播放数据」账目区；未同步过 = 空态。
  - 用例：`SyncDataSyncCoreTests.passiveDataSyncPresenterRowsArePure`。
- **建议**：新增任何跨端能力时，**两端的账目面都要有落点**（只 `print` 不算披露）。

## 9. 判断标准（新增能力时怎么自检）

新加一个同步实体 / 一个跨端能力时，**逐条回答这 8 个问题**，任一题答不出就是空格：

1. 本地哪个写点记 outbox？与业务行同一事务吗？（INV-1 / INV-2）
2. 它引用歌曲吗？引用则身份键从哪来、拿不到时怎么办？（INV-4 / INV-5 / INV-6）
3. 接收侧有本地化 + 应用分支吗？（INV-7）
4. 本地缺依赖（歌 / 歌单结构）时挂起还是丢弃？重放触发点在哪？（INV-8）
5. 游标越过后还能回来吗？（INV-9 / INV-10 / INV-11 / INV-12）
6. 它与 delete 语义的关系是什么？（INV-13 / INV-14 / INV-15）
7. **每个平台**都装配了吗？有断言吗？（INV-16 / INV-17）
8. 缺口计数了吗？**上屏了吗？区分实体吗？**（INV-18 / INV-19 / INV-20）

> 第 7、8 两题是今天 6 条 commit 反复在两个侧面上打转的根源：
> 「协议支持 + 有实现」都做了，**装配与披露**没人问。
