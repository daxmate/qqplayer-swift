# 局域网同步能力矩阵（实体 × 能力）

> 2026-09-14 只读审计产出。基线 commit `7a2566b`。
> 目的：把「局域网同步」子系统的能力一次性查清，**不靠真机逐条试**。
> 每格都给出证据（符号 / 文件:行 / 测试名）。查不到就是空格：`✗ 空格：<具体缺什么>`。
>
> **五件事不是一回事**，本表的列就是按这个拆的：
> ①协议支持 ②有实现 ③已装配 ④有测试 ⑤有披露。
> 今天的事故（跨端身份键 / outbox 悬空引用 / 本地真值补发 / 披露）**全部是
> 「协议支持 + 有实现，但没装配 / 没披露」**。

## 0. 被同步的内容清单（按代码为准，不按枚举为准）

| 行 | 载体 | 是否在 `SyncChangeEntity` |
| --- | --- | --- |
| A favorite | `favorite` 表 | ✅ `case favorite` |
| B playHistory | `play_history` 表 | ✅ `case playHistory = "play_history"` |
| C playlist（结构） | `playlist` 表 | ✅ `case playlist` |
| D playlistItem | `playlist_item` 表 | ✅ `case playlistItem = "playlist_item"` |
| E playbackPosition | `UserDefaults` PlayerState（**非 DB 行**） | ✅ `case playbackPosition = "playback_position"` |
| F aligned 歌词 | `Documents/lyrics-manual/{stableId}.json` | ❌ 不在枚举（走**文件帧**） |
| G 曲库音频文件 | 曲库根文件系统 | ❌ 不在枚举（走**文件帧**） |
| H 歌单自定义封面 | `custom_cover_image_path`（搭 C 的 payload） | ❌ 不在枚举（**没有独立通道**） |

`SyncChangeEntity.v1Synced`（`QQPlayer/Sync/SyncDataSyncModels.swift:38`）=
`[.favorite, .playHistory, .playlist, .playlistItem]` —— **E 不在其中**。

---

## 1. 总览（✓ 有 / △ 部分 / ✗ 空格 / — 不适用）

| 行 | ①记 outbox | ②填身份键 | ③本地化+应用 | ④挂起/重放 | ⑤对账补发 | ⑥计数并上屏 | ⑦单测 | ⑧装配静态守护 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A favorite | ✓ | ✓ | ✓ | ✓ | ✓ | ✓(按实体) | ✓ | ✓(帧8/9) |
| B playHistory | ✓ | ✓ | ✓ | ✓ | ✓ | ✓(按实体) | ✓ | ✓(帧8/9) |
| C playlist | ✓ | — | ✓ | — | ✓ | ✓(按实体) | ✓ | ✓(帧8/9) |
| D playlistItem | ✓ | ✓ | ✓ | ✓ | ✓ | ✓(按实体) | ✓ | ✓(帧8/9) |
| E playbackPosition | ✓ | ✓ | ✓ | — | — | ✓ | ✓ | ✓(帧8/9) |
| F aligned 歌词 | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | △ |
| G 曲库文件 | — | ✓ | ✓ | ✓ | △ | ✓ | ✓ | △ |
| H 封面 | — | — | ✓ | — | — | ✓ | ✓ | ✗ |

> **表头口径与最近复核**（2026-09-16）：`—` = 该能力对本行**不适用**（设计边界，不是缺口）。
> H 行 ②④⑤ 为「—」＝契约 §2 H 已定：歌单封面由歌单内歌曲封面自动合成（派生数据），
> **不跨端同步**，故无身份键 / 无挂起 / 无补发通道；其 ③ 列 = 落库永不对端路径（INV-23 已收）。
> H 行 ⑥ 也已收（2026-09-16：封面加载失败计数 + 上屏，见 §2 H⑥ / INV-22）。
> 本表 2026-09-16 逐格与代码复核过一次，凡标 ✓ 的格子都能在「§2 逐格证据」里指到实现与用例。

**⑧ 列说明**：全仓唯一的「装配可达性」静态守护是
`QQPlayerTests/SyncWiringContractTests.swift`（5 条断言：`ios-data-sync-peer-attached` /
`mac-data-sync-entry-attached` / `mac-playback-carry-attached` /
`frame-8-9-handler-present` / `frame-8-9-numbers-frozen`）。
它断言的是**帧 8/9 处理器在两端都被装配**——对 A–E 五行共享（都在帧 8/9 上），
**不区分实体**；F/G 走文件帧，只有 `SyncCollectionSyncCoordinator` 的装配被间接覆盖，
**没有**「歌词接收器在被动端被装配」这类断言。

---

## 2. 逐格证据

### A. favorite

| 列 | 结论 | 证据 |
| --- | --- | --- |
| ① | 有 | `DatabaseManager.addToFavorites(trackStableId:)` `QQPlayer/Services/DatabaseManager+Tracks.swift:393`（record `:399`）；`addToFavorites(trackStableIds:)` `:413`（`:419`）；`removeFromFavorites` `:431`（delete `:437`）；`deleteTrack(byStableId:)` `:466`（级联 delete `:516`） |
| ② | 有 | `SyncChangeLogMapper.wireEntriesDetailed` `QQPlayer/Sync/SyncChangeLogMapping.swift`（行内引用 `SyncTrackReference.trackStableId`；**两把身份键**：指纹可用只填 `contentHash`，指纹缺失则填 `relativePath`（曲库相对路径，第二身份））；入口 `SyncIdentityResolving.remoteTrackIdentity(forTrackStableId:)` |
| ③ | 有 | `SyncChangeLogApplier.applyFavorite(rowKey:)` `QQPlayer/Sync/SyncChangeLogApplier.swift:114-123`；本地化改写 `SyncChangeLogMapper.rewrite` `SyncChangeLogMapping.swift:355-357` |
| ④ | 有 | `SyncChangeLogPendingStore.suspend` `QQPlayer/Sync/SyncChangeLogPendingStore.swift:73`；`SyncChangeLogReplay.replay` `:142`（触发点 `QQPlayer/Services/DatabaseManager+Tracks.swift:87`、`QQPlayer/Services/DatabaseManager.swift:999`） |
| ⑤ | 有 | `SyncChangeLogDanglingRepair.reconcileLocalTruth` `SyncChangeLogMapping.swift:588`，favorite 分支 `:626-637`；`reconcilableEntities` `:571` 含 `.favorite` |
| ⑥ | 部分 | 见 §3「披露细则」——只有**总数**，不分实体 |
| ⑦ | 有 | `QQPlayerTests/SyncChangeLogStoreTests.swift:73`「收藏 upsert/delete → outbox」、`:101`「批量收藏恢复」、`:113`；`QQPlayerTests/SyncLWWReconcileTests.swift:142`「Applier favorite」、`:276`「Applier 身份兜底」；`QQPlayerTests/SyncChangeLogContentMapTests.swift:446`「跨端 roundtrip」、`:793`「T15b-2 补发」 |

### B. playHistory

| 列 | 结论 | 证据 |
| --- | --- | --- |
| ① | 有 | `PlayHistoryRecorder.playbackBegan` `QQPlayer/Services/PlayHistoryRecorder.swift:62`（record `:96`，初始态时长 0）；`settleSession(endingAt:)` `:166`（record `:183`，最终态含累计时长）；`deleteTrack` 级联 delete `QQPlayer/Services/DatabaseManager+Tracks.swift:466`（`:539`） |
| ② | 有 | `SyncChangeLogMapping.swift`（row_key = `stableId\|playedAt`，复合键解析失败回落 payload 快照）；身份键同 A②（指纹优先 → 相对路径兜底），入口 `localizeRemoteTrack(_:)` |
| ③ | 有 | `SyncChangeLogApplier.applyPlayHistory(payloadJSON:)` `SyncChangeLogApplier.swift:129-152`（按 `(track_stable_id, played_at)` 匹配，存在更新时长 / 不存在插入） |
| ④ | 有 | 同 A ④ |
| ⑤ | 有 | `reconcileLocalTruth` 播放历史分支 `SyncChangeLogMapping.swift:665-685`；**且**悬空修复有专属对账键：`currentPlayHistoryTrackStableId` `:550`（按 `played_at` 把旧引用接回当前曲目） |
| ⑥ | 部分 | 同 A ⑥ |
| ⑦ | 有 | `SyncChangeLogStoreTests.swift:125`；`SyncLWWReconcileTests.swift:177`、`:276`；`SyncChangeLogContentMapTests.swift:471`「挂起 + 重放」、`:593`「T15b played_at 命中改写」、`:632`「不可修复 → 清理」、`:707`「不误伤业务行」 |

### C. playlist（歌单结构）

| 列 | 结论 | 证据 |
| --- | --- | --- |
| ① | 有 | `DatabaseManager+Playlists.swift:125` `createPlaylist(title:)`（record `:154`）；`:419` `deletePlaylist`（delete `:426`）；`:480` `renamePlaylist`（record `:495`）；`:591` `updatePlaylistCustomCover`（record `:605`） |
| ② | 不适用 | `SyncTrackReference.referencesTrack` `SyncChangeLogMapping.swift:152` 对 `.playlist` 返回 **false** → `localize` `:316` 走 `.passThrough`；`wireEntriesDetailed` 也不会为其取指纹（`:264` 的 `trackStableId` 为 nil）。**这是设计正确**，不是空格 |
| ③ | 有 | `SyncChangeLogApplier.applyPlaylist(payloadJSON:)` `SyncChangeLogApplier.swift:158-184`（按 slug 存在则更新字段、不存在则 INSERT） |
| ④ | 不适用 | 无缺歌概念（passThrough 直达），不需要挂起 |
| ⑤ | **✅ 有（2026-09-16 复核）** | 补发通道已在：注册表 C 条目 `writesOutbox: true` + `reconcilesLocalTruth: true`（`SyncEntityRegistry.swift` 的 `.playlist` 登记，localTruth 表 = `playlist`、行键 = slug）；补发行键分支 `rowKey(entity:stableId:payloadJSON:)` 的 `.playlist` → `SyncPlaylistSnapshot.rowKey`（`SyncChangeLogMapping.swift`）。⚠️ 旧格子引的「`:706` 对 `.playlist` 显式 nil」是**另一处**（`SyncTrackReference.trackStableId`：playlist 不引用歌曲 → nil，语义正确），别再当缺口读。**旧文（保留）**：`reconcilableEntities` `SyncChangeLogMapping.swift:571` = `[.favorite, .playHistory, .playlistItem]`，**不含 `.playlist`**；`repairableEntities` `:464` 同样不含；`rowKey(entity:stableId:payloadJSON:)` `:706` 对 `.playlist` **显式 `return nil`**。⇒ **在 outbox 机制建立之前创建的歌单**，其 upsert 行从来不存在，而**没有任何重建入口**（T15b 只覆盖 favorite/playHistory/playlistItem）。**缺什么**：`reconcileLocalTruth` 缺一条 `SELECT slug, title, ... FROM playlist WHERE is_folder_synced = 0` → `emit(entity: .playlist, ...)` 分支 |
| ⑥ | **△ 部分（2026-09-16 复核）** | **计数有了、上屏还是没有**：「歌单结构补进 outbox」计入 `SyncChangeLogDanglingRepair.Report.emitted`（`SyncChangeLogMapping.swift:628`），但消费点只有 `print`（`MacSyncDataViewModel.swift:208` / `IOSPassiveSyncCenter.swift:707`）——**面板没有这一行**。「歌单行应用失败/缺依赖」那一半已按实体上屏（见 §4 第 6 行）。**旧文（保留）**：「歌单结构没进 outbox」这件事**没有任何计数**：`SyncChangeLogDanglingRepair.Report`（`SyncChangeLogMapping.swift:437-460`）只有 repaired/cleaned/skipped/emitted/emittedWithoutIdentity/skippedLocalDangling，**没有 playlist 维度**；两个调用点（`QQPlayer/Mac/MacSyncDataViewModel.swift:156`、`QQPlayer/Services/IOSPassiveSyncCenter.swift:537`）也只打印这些字段 |
| ⑦ | **✅ 有（2026-09-16 复核）** | 写入点：`SyncChangeLogStoreTests.swift:167`「createPlaylist/rename/delete → playlist upsert/delete」；applier：`SyncLWWReconcileTests.swift:224`「Applier playlist」；**补发**：`SyncChangeLogContentMapTests.swift:864`「T15b-2 补发」用例里 `playlist|pl` 就是被补发的行之一（`report.emitted == 4`）。**旧文（保留）**：写入点：`SyncChangeLogStoreTests.swift:167`「createPlaylist/rename/delete → playlist upsert/delete」；applier：`SyncLWWReconcileTests.swift:224`「Applier playlist」。**缺什么**：**没有补发用例**（该通道不存在，无法测） |
| ⑧ | ✓(帧8/9) | `SyncWiringContractTests.swift:50-101` 的 5 条断言共享（不区分实体） |

### D. playlistItem

| 列 | 结论 | 证据 |
| --- | --- | --- |
| ① | 有 | `DatabaseManager+Playlists.swift:257` `addToPlaylist`（record `:284`）；`:304` `removeFromPlaylist`（delete `:313`）；`:328` `reorderPlaylistItems`（逐项 upsert `:388`）；`deleteTrack` 级联 delete `DatabaseManager+Tracks.swift:466`（`:526`） |
| ② | 有 | `SyncChangeLogMapping.swift`（row_key = `playlistSlug\|trackStableId`）；身份键同 A② |
| ③ | 有 | `SyncChangeLogApplier.applyPlaylistItem(payloadJSON:)` `SyncChangeLogApplier.swift:192-221`；两条跳过：歌单未同步到本地 `:195-198`、歌不存在 `:199-202` |
| ④ | 有 | 同 A ④ |
| ⑤ | 有 | `reconcileLocalTruth` 歌单成员分支 `SyncChangeLogMapping.swift:639-663`（`JOIN playlist WHERE p.is_folder_synced = 0`，与写入侧同口径） |
| ⑥ | 部分 | 同 A ⑥ |
| ⑦ | 有 | `SyncChangeLogStoreTests.swift:203`、`:237`「folder-synced 歌单不入 outbox」；`SyncLWWReconcileTests.swift:276`；`SyncChangeLogContentMapTests.swift:793`、`:861`「悬空行清掉后按业务表补回」、`:881` |

### E. playbackPosition

| 列 | 结论 | 证据 |
| --- | --- | --- |
| ① | **✅ 有**（2026-09-15，开关门控） | 捕获挂点 = `PlayerEngine.savePlayerState()` 末尾 → `PlaybackPositionCapture.recordIfEnabled`（换歌必记 / 同曲 60s 节流；**开关关 = 直接 return：零 DB 访问**）。rowKey = `stableId`，载荷 = `SyncPlaybackPositionSnapshot` |
| ② | **✅ 有** | 有行可发：映射分支 `SyncChangeLogMapping.swift:160`（`case .favorite, .playbackPosition: return rowKey`）现拿到真实输入 |
| ③ | **✅ 有**（开关开 + 同曲才落地） | `SyncChangeLogApplier.applyPlaybackPosition` **不再虚报**：关 / 无落点 / 落点未接受（不同曲 / 远端更旧 / 位置差 < 3s）一律 `return false` + `onPlaybackPositionUnsupported` → `unsupportedEntries`；开关开 + 同曲 + 远端更新 → `PlaybackPositionResumeSink.apply` 只改写本机 `QQPlayerState.playbackTime`（LWW；绝不改 isPlaying） |
| ④ | 不适用 | 播放位置没有「本地缺歌」概念（业务载体不是 DB 行）；开关关 = 不接受、不挂起 |
| ⑤ | 不适用 | 本地载体 = `UserDefaults QQPlayerState`（非 DB 行），不进 `reconcilableEntities`（那套是「业务表 → outbox」补发） |
| ⑥ | **✅ 有** | `SyncDataSyncReport.unsupportedEntries` → `MacSyncView` 「未支持」账目行（>0 橙）+ hint（5 语） |
| ⑦ | **✅ 有** | `SyncDataSyncCoreTests`：开关关 / 开但无落点 / 落点未接受 → 不计「已应用」；`PlaybackPositionResumeSink.shouldApply` 与 `PlaybackPositionCapture.shouldRecord` 纯逻辑用例 |

### F. aligned 歌词（不在枚举）

| 列 | 结论 | 证据 |
| --- | --- | --- |
| ① | 不适用 | 不走 outbox，走**文件帧**：`SyncCollectionSyncCoordinator+Execution.swift:60` `descriptor.lyricsEntries()`；命名空间 `SyncLyricsNamespace` `QQPlayer/Sync/SyncAlignedLyrics.swift:35-79`。**方向决策（2026-09-15 用户拍板）**：对齐歌词**单向（桌面 → 移动）**——AI 对齐只在桌面端做，移动端不生成；功能本身尚未实现，所以「移动端没有补发通道」**不是待补空格，而是设计边界**（实现时按单向接，不做双向补发） |
| ② | 有 | `SyncLyricsNamespace.wirePath(songContentHash:)` `SyncAlignedLyrics.swift:48`（`@lyrics/{歌曲 content_hash}.json`）；生产映射 `SyncLyricsContentMapping.live(database:)` `SyncChangeLogMapping.swift:134`（复用 M4-2a resolver，不新写 SQL） |
| ③ | 有 | `SyncLyricsReceiver`（install / pending / discarded / failed 四态）；测试 `QQPlayerTests/AlignedLyricsSyncTests.swift:348` |
| ④ | **✅ 有（2026-09-16）** | **会话内暂存**（同轮歌后到 → 收尾重试，`SyncLyricsReceiver.flushPending`）+ **丢弃记账**（`discardedLyrics` / `orphanLyricsSkipped`）+ **下一轮自动补发**：补发轮每轮重新对账「对端缺什么」（`SyncLyricsResendPlanner`），未送达的进 `pendingResend` 并上屏 → 歌一到位，下一次连接就补上 |
| ⑤ | ~~✗ 空格~~ **✅ 有（2026-09-16）** | 补发通道：`SyncLyricsResendController`（连接就绪自动一轮 `@lyrics/*` 对账 → 帧 10/11 → 14 → 4/5/6，**不新增帧 / 不加字段**）+ `MacLyricsResendAutoRunner`（一次连接一次，前置门 = 索引终态）；触发点 `SyncHostCenter.handleSessionPhase(.ready)`。**只推不拉**（方向 = F① 的单向） |
| ⑥ | ~~部分~~ **✅ 有（2026-09-16）** | 计数 → 上屏（唯一投影 `SyncEntityOutcomeDisclosure.lyricsRows`，五语文案）：iOS「设置 → 同步 → 接收同步」区（`discardedLyrics` / `keptLocalLyrics`）+ Mac 同步面板（E 结果区 `SyncUIReportSummary.lyricsDiscarded` / `.lyricsKeptLocal`；补发区 `pendingResend` / `keptLocal`） |
| ⑦ | 有 | `AlignedLyricsSyncTests.swift`（2026-09-16 新增：`resendPlanOnlyFills` / `resendPlanGatesOnSongPresence` / `resendPlanLyricsNamespaceOnly…` / `resendStateMachineAndAutoRunDecision` / `receiverKeepsLocalLyrics` / `lyricsDisclosureRows` / `lyricsResendRoundPushesMissingLyrics` / `lyricsResendRoundKeepsBothSides`）；无模拟器 harness `scripts/sync-harness/main.swift` ㊻ 节 |
| ⑧ | △ | 无「歌词接收器已装配」的静态断言（`SyncWiringContractTests` 不含）；只有 `SyncLibraryPassiveTests.swift:355` 行为用例。**F2 的「只补不覆盖」同样只有行为用例**（`receiverKeepsLocalLyrics`），无静态断言 |

### G. 曲库音频文件（不在枚举）

| 列 | 结论 | 证据 |
| --- | --- | --- |
| ① | 不适用 | 不走 outbox |
| ② | 有 | content_hash 为跨端身份（`docs/lan-sync-design.md` §6.1）；`SyncManifestGenerator` / `SyncTransferIdentity`；`QQPlayerTests/SyncTransferIdentityTests.swift` |
| ③ | 有 | `QQPlayer/Sync/SyncManifestReconciler.swift`、`SyncFileReceiver.swift`；`SyncManifestReconcileTests.swift:34-96` |
| ④ | 有 | 断点续传 `.part`：`SyncFileTransferTests.swift:158`「断点续传」、`:235`「resume 不匹配」 |
| ⑤ | 部分 | 无「本地真值补发」概念，靠**每次重算选择集 manifest**（`SyncCollectionSyncCoordinator+Execution.swift:60`）。已选歌但 manifest 缺条目时**无专门告警** |
| ⑥ | 有 | `SyncUIReportSummary`（`SyncUIState.swift:449`）经 `MacSyncRunViewModel.swift:304` 上屏（含失败清单 `failedItems`） |
| ⑦ | 有 | `SyncFileTransferTests`(7)、`SyncManifestReconcileTests`(11)、`SyncTransferIdentityTests`、`SyncLibrarySyncE2ETests`、`SyncLibraryPlanTests` |
| ⑧ | △ | 无静态装配断言；有 `mac-playback-carry-attached`（`SyncWiringContractTests.swift:71`）间接覆盖跟歌走 |

### H. 歌单自定义封面（不在枚举，搭 C 的 payload）

| 列 | 结论 | 证据 |
| --- | --- | --- |
| ① | 不适用 | 随 playlist upsert payload 走：`DatabaseManager+Playlists.swift:591` `updatePlaylistCustomCover`（record `:605`） |
| ② | **— 不适用（2026-09-16 改判）** | 契约 §2 H 已定：歌单封面由**歌单内歌曲封面自动合成** = 派生数据 → **不承诺跨端**、两端各自合成，**无可同步之物**（所以这不是「等着补的空格」）。**旧文（保留，供对照）**：载荷携带的是**发送端本地相对路径**（`SyncDataSnapshots.swift:69` `customCoverImagePath`，键 `:79` `custom_cover_image_path`）——**不是跨端身份键，也没有文件传输通道**（`grep -rn "cover" QQPlayer/Sync/` 无任何传输点）。**缺什么**：封面文件本身的跨端通道（可仿歌词做 `@cover/{content_hash}`）或明确「封面不同步」并把对端来源的路径在落库时清空 |
| ③ | **✓ 已收（2026-09-16 复核）** | INV-23（2026-09-15）：落库**不采用对端路径**——`SyncChangeLogApplier.swift:230` `customCoverImagePath: nil`；守护用例 `playlistCoverNeverComesFromPeer`（`SyncLWWReconcileTests.swift`）+ `SyncCoverValueContract`（`SyncWiringContractTests.swift`）。**旧文（保留，行为已改）**：`SyncChangeLogApplier.applyPlaylist` `SyncChangeLogApplier.swift:166`（更新）/ `:179`（插入）**原样写入** ⇒ 接收端歌单行里的路径指向对端设备的文件；消费点 `QQPlayer/Views/Playlists/PlaylistCardView.swift:189-196`（拼 App Group 容器路径 `try? Data(contentsOf:)`），读不到就静默 return |
| ④ | — 不适用（封面没有独立挂起概念；且不跨端同步） | 无 |
| ⑤ | — 不适用（不跨端同步 ⇒ 没有补发通道这回事） | 无 |
| ⑥ | **✅ 有（2026-09-16）** | 封面加载失败**计数 + 上屏**：唯一解析入口 `PlaylistCoverResolver`（4 个消费点全改走它：歌单卡片 / 歌单详情 / 详情移除 / CarPlay）+ 登记处 `PlaylistCoverLoadFailuresStore`（按歌单去重、读到清除）+ 投影 `SyncEntityOutcomeDisclosure.coverRows`（五语）→ iOS「设置 → 同步 → 接收同步」区一行 + **歌单详情页就地提示**。守护 `PlaylistCoverLoadTests.swift` |
| ⑦ | **△ 部分（2026-09-16 复核）** | INV-23 契约用例在场（`playlistCoverNeverComesFromPeer` / `SyncCoverValueContract`）；**没有**「封面跨端」用例——设计上不跨端，故不算缺口 |

---

## 3. 披露细则（⑥ 列为什么大多是「部分」）

**Mac 端**（唯一有 UI 披露的面板）：
`QQPlayer/Mac/MacSyncView.swift:983-1026` 显示 6 个数字
（`pushedEntries` / `appliedEntries` / `suspendedEntries` / `unresolvedEntries` /
`pushedMissingIdentityEntries` / `ignoredDeletes`），
字段来源 `SyncDataSyncReport`（`QQPlayer/Sync/SyncDataSyncCoordinator.swift:64-83`）。

⇒ **全部是总数，没有任何实体维度**。用户看到「未定位 110」不可能知道是收藏、歌单项、
还是播放历史出的问题；也无法据此判断该修哪条通道。

**2026-09-15（INV-18 剩余项起）**：账目升级为 **(实体, 结果) 二维**，两端面板都多了
「按类别明细」区（未定位 / 应用失败 / 身份歧义 / 缺依赖 / 未支持 / 缺指纹 / 挂起，
**>0 才显示**，正常实体不占行），形如「未定位 · 收藏  3」。明细行的和 = 汇总行的数
（同一份账目派生）；新增的「应用失败」类别让**歌单级失败**（载荷解不开 / 落库抛错）
从「只进日志」变成上屏。汇总行的口径与旧读数名保持不变。

**2026-09-15 身份兜底包起**：两端面板多了「身份歧义 N 条」（仅 N > 0 显示，5 语）；
「缺指纹」口径也变了——**有曲库相对路径可用的行不再算缺键**（`SyncWireMissingIdentity.Reason` 只区分
「无 track 行」与「有行但两把键都算不出」）。

i18n 键确认三个缺口口径：`sync_run_data_result_unresolved` = 未定位、
`sync_run_data_result_missing_identity` = 缺指纹、`sync_run_data_ambiguous_identity` = 身份歧义
（`QQPlayer/Resources/zh-Hans.lproj/Localizable.strings`）。

**iOS 端**：**没有面板**。全部披露是 `print`（`QQPlayer/Services/IOSPassiveSyncCenter.swift:549-578`）：
`onPushUnresolved` → `print("⚠️ ... 跳过未定位的远端行")`、`onIncrementMissingIdentity` /
`onPullMissingIdentity` → `print("⚠️ ... 缺身份键")`。
⇒ 被动端**结构性暴露**（谁被静默跳过）在设备上**用户完全看不到**。

**歌词**：`discardedLyrics` / `orphanLyricsSkipped` **计了数但没进 `SyncUIReportSummary`**（见 F⑥）。

---

## 4. 空格清单（按「用户可见后果」排序）

### 一级：数据永不同步，且零报错（最危险）

| # | 空格 | 证据 | 用户可见后果 |
| --- | --- | --- | --- |
| 1 | ~~**C⑤ playlist 结构无对账补发通道**~~ **已收（2026-09-16 复核）** | 注册表 C 条目 `writesOutbox: true` + `reconcilesLocalTruth: true`（localTruth 表 = `playlist`、行键 = slug）+ 补发行键分支 `.playlist` → `SyncPlaylistSnapshot.rowKey`；用例 `SyncChangeLogContentMapTests.swift:864`（T15b-2，`playlist|pl` 在补发之列）。⚠️ 旧格引的 `rowKey :706 显式 nil` 是另一处（`SyncTrackReference.trackStableId`，playlist 不引用歌曲 ⇒ nil 语义正确），别再当缺口读 | outbox 之前创建的歌单现在会被「本地真值补发」补上（补进 outbox → 随帧 8/9 过去） |
| 2 | ~~**E① playbackPosition 生产端 0 写点**~~ **已收（2026-09-15，2026-09-16 复核）** | 写点在场：`StateManager.swift:425`（捕获挂点 `PlaybackPositionCapture.recordIfEnabled`，换歌必记 / 同曲 60s 节流、**开关关 = 零 DB 访问**）+ 注册表 `writesOutbox: true`；`grep -rn "entity: \.playbackPosition"` 现有 2 处（`SyncEntityRegistry.swift` / `StateManager.swift`）。**旧格子的 grep 当时确实为空**（那一包才接上生产端） | 跨端续播（默认关）现在真能两端走通；关 = 零出站零入站 |
| 3 | ~~**H② 封面路径当跨端值传输**~~ **改判 + 已收（2026-09-16 复核）** | 两件事分开：① **封面不跨端**是契约 §2 H 的**设计边界**（派生数据、两端各自合成）——不是待补空格；② 「对端路径当跨端值落库」已由 INV-23 收口（`SyncChangeLogApplier.swift:230` `customCoverImagePath: nil` + 两个契约用例）。**加载侧也已收（2026-09-16）**：封面读不到 → 计数（按歌单去重）+ iOS 面板一行 + 歌单详情页就地提示（`PlaylistCoverResolver` / `PlaylistCoverLoadFailuresStore` / `SyncEntityOutcomeDisclosure.coverRows`） | 对端封面不再显示为「必然加载不出」的坏路径；本机封面文件失效时用户能看到原因 |
| 4 | ~~**F⑤ aligned 歌词无补发通道**~~ **已收（2026-09-16）** | 修法：连接就绪自动跑一轮 `@lyrics/*` 补发（`SyncLyricsResendController`，Mac 发起、不新增帧）；歌不在对端不推（避免丢弃噪音），未送达进 `pendingResend` 上屏 | 已有的对齐歌词不再要等用户手动「开始同步」 |

### 二级：数字误导（看着在干活，其实没干）

| # | 空格 | 证据 | 用户可见后果 |
| --- | --- | --- | --- |
| 5 | ~~**E③ 静默丢弃被计入「已应用」**~~ **已收（2026-09-15）** | 修法：`applyPlaybackPosition` 三条未落地路径（开关关 / 无落点 / 落点未接受）一律 `return false` + `onPlaybackPositionUnsupported` → `unsupportedEntries` → 面板「未支持」行 | 面板不再报「已应用 N」而本地零变化（INV-20 有守护） |
| 6 | ~~**C⑥ 歌单结构缺口无计数**~~ **已收（2026-09-15）** | 歌单行应用失败 / 缺依赖按实体计数并上屏（`SyncEntityOutcomeDisclosure` 明细行「歌单结构 · 应用失败 N」） | 歌单级失败不再只进日志 |

### 三级：同不同步看运气（依赖用户手动触发）

| # | 空格 | 证据 | 用户可见后果 |
| --- | --- | --- | --- |
| 7 | ~~**补发通道的三个触发点都是「用户动作」**~~ **已收（2026-09-15）** | 修法：Mac 侧**会话 ready 自动跑一轮**（`SyncHostCenter.handleSessionPhase(.ready)` → `MacDataSyncAutoRunner.sessionDidBecomeReady`，含「本地真值对账补发」）；手动（面板按钮）与自动共用 `SyncDataRunGate`（同一会话只允许一轮，取不到=放弃本轮）；iOS 仍在会话装配时跑一次 | 不点也会补（用户 2026-09-15 拍板「触发时机 = 连接后自动」）；不再出现「点过的设备同步了、没点的没有」 |
| 8 | ~~**D 链式依赖无守护**：playlist_item 要求 playlist 结构先行落地~~ **已收（2026-09-15）** | 修法：applier 新增 `onSkippedMissingParent`，三种“父行/被引用行不存在”路径（歌单结构未到 / 收藏·播放历史·歌单项引用的歌本地查无）全部返回 false + **计数**；peer 累加 → `SyncDataSyncReport.skippedMissingParentEntries` → Mac 面板「缺依赖」行（>0 橙）+ hint（5 语） | 以前这三种静默失败（面板不计、「已应用」也不含），现在可见；不会再出现“同步完了但什么都没发生、没人报警” |

### 四级：只影响诊断

| # | 空格 | 证据 | 用户可见后果 |
| --- | --- | --- | --- |
| 9 | ~~**⑥ 披露不区分实体**~~ **已收（2026-09-15，2026-09-16 复核）** | 唯一投影 `SyncEntityOutcomeDisclosure`（(实体 × 结果) 二维分桶 + 只出 >0 的行），两端面板都只从它取数（`MacSyncView.swift` / `SyncSettingsView.swift`）；形状契约 `SyncEntityDisclosureContract`（界面层不得自算数字/自行枚举实体）+ 五语 key 齐全性断言 | 面板现在按类别明细列出「哪条通道的哪类异常各多少条」 |
| 10 | ~~**F⑥ 歌词丢弃计了数没上屏**~~ **已收（2026-09-16）** | 修法：`SyncUIReportSummary` 加 `lyricsDiscarded` / `lyricsKeptLocal`（编排 report 从拉取控制器 summary 合并）+ `SyncEntityOutcomeDisclosure.lyricsRows` 唯一投影 + 两端面板行（含「待补发」） | 歌词没到时，用户能看到「丢弃几条 / 待补发几条 / 保留本端几条」 |
| 11 | ~~**iOS 端零 UI 披露**~~ **已收（2026-09-15）** | 修法：`IOSPassiveSyncCenter.dataSummary`（帧 8/9 回调累加，主线程）+ `IOSPassiveDataSyncPresenter`（`countRows`/`gapRows` 纯逻辑）+ iOS「设置 → 同步」新增「播放数据」账目区（计数行 + 缺口行 + 说明，>0 橙色；**复用 Mac 既有 key，无新增文案**）；未同步过 = 空态 | 手机侧也能看见「同步了什么 / 丢了多少」 |
| 12 | ~~**E⑦ 无 applier 用例**~~ **已收（2026-09-15，2026-09-16 复核）** | `SyncDataSyncCoreTests.swift` 五条：`:532` 落点未接受 → 未支持、`:609` 开关关 → 不落点不计已应用、`:627` 开关开 + 落点 → 已应用、`:645` 开关开但无落点 → 未支持、`:658` 端到端开关关 | 「静默丢弃被计入已应用」这类误导行为 CI 能抓到（INV-20） |

---

## 5. 复现本表的命令（自检可用）

```bash
# ① outbox 写点总表
grep -rn "SyncChangeLogStore.record" --include="*.swift" QQPlayer/ | grep -v SyncChangeLogStore.swift

# ② 身份键填充（发送侧）：两把键（指纹优先 → 相对路径兜底）
grep -n "remoteTrackIdentity\|relativePath" QQPlayer/Sync/SyncChangeLogMapping.swift

# ⑤ 补发覆盖的实体（关键空格证据）
grep -n "reconcilableEntities\|repairableEntities" QQPlayer/Sync/SyncChangeLogMapping.swift

# E① playback_position 有无生产写点（应为空）
grep -rn "entity: \.playbackPosition" --include="*.swift" QQPlayer/ || echo "NONE"

# ⑥ 披露面
grep -rn "unresolvedEntries\|pushedMissingIdentityEntries" --include="*.swift" QQPlayer/

# ⑧ 装配静态守护
grep -n "id: \"" QQPlayerTests/SyncWiringContractTests.swift
```
