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
| A favorite | ✓ | ✓ | ✓ | ✓ | ✓ | △ | ✓ | ✓(帧8/9) |
| B playHistory | ✓ | ✓ | ✓ | ✓ | ✓ | △ | ✓ | ✓(帧8/9) |
| C playlist | ✓ | — | ✓ | — | **✗** | **✗** | △ | ✓(帧8/9) |
| D playlistItem | ✓ | ✓ | ✓ | ✓ | ✓ | △ | ✓ | ✓(帧8/9) |
| E playbackPosition | **✗** | **✗** | △ | **✗** | **✗** | **✗** | **✗** | ✓(帧8/9) |
| F aligned 歌词 | — | ✓ | ✓ | △ | **✗** | △ | ✓ | △ |
| G 曲库文件 | — | ✓ | ✓ | ✓ | △ | ✓ | ✓ | △ |
| H 封面 | — | **✗** | △ | **✗** | **✗** | **✗** | **✗** | ✗ |

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
| ② | 有 | `SyncChangeLogMapping.swift`（row_key = `stableId\|playedAt`，复合键解析失败回落 payload 快照）；身份键同 A②（指纹优先 → 相对路径兑底），入口 `localizeRemoteTrack(_:)` |
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
| ⑤ | **✗ 空格** | `reconcilableEntities` `SyncChangeLogMapping.swift:571` = `[.favorite, .playHistory, .playlistItem]`，**不含 `.playlist`**；`repairableEntities` `:464` 同样不含；`rowKey(entity:stableId:payloadJSON:)` `:706` 对 `.playlist` **显式 `return nil`**。⇒ **在 outbox 机制建立之前创建的歌单**，其 upsert 行从来不存在，而**没有任何重建入口**（T15b 只覆盖 favorite/playHistory/playlistItem）。**缺什么**：`reconcileLocalTruth` 缺一条 `SELECT slug, title, ... FROM playlist WHERE is_folder_synced = 0` → `emit(entity: .playlist, ...)` 分支 |
| ⑥ | **✗ 空格** | 「歌单结构没进 outbox」这件事**没有任何计数**：`SyncChangeLogDanglingRepair.Report`（`SyncChangeLogMapping.swift:437-460`）只有 repaired/cleaned/skipped/emitted/emittedWithoutIdentity/skippedLocalDangling，**没有 playlist 维度**；两个调用点（`QQPlayer/Mac/MacSyncDataViewModel.swift:156`、`QQPlayer/Services/IOSPassiveSyncCenter.swift:537`）也只打印这些字段 |
| ⑦ | 部分 | 写入点：`SyncChangeLogStoreTests.swift:167`「createPlaylist/rename/delete → playlist upsert/delete」；applier：`SyncLWWReconcileTests.swift:224`「Applier playlist」。**缺什么**：**没有补发用例**（该通道不存在，无法测） |
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
| ① | 不适用 | 不走 outbox，走**文件帧**：`SyncCollectionSyncCoordinator.swift:540` `descriptor.lyricsEntries()`；命名空间 `SyncLyricsNamespace` `QQPlayer/Sync/SyncAlignedLyrics.swift:35-79`。**方向决策（2026-09-15 用户拍板）**：对齐歌词**单向（桌面 → 移动）**——AI 对齐只在桌面端做，移动端不生成；功能本身尚未实现，所以「移动端没有补发通道」**不是待补空格，而是设计边界**（实现时按单向接，不做双向补发） |
| ② | 有 | `SyncLyricsNamespace.wirePath(songContentHash:)` `SyncAlignedLyrics.swift:48`（`@lyrics/{歌曲 content_hash}.json`）；生产映射 `SyncLyricsContentMapping.live(database:)` `SyncChangeLogMapping.swift:134`（复用 M4-2a resolver，不新写 SQL） |
| ③ | 有 | `SyncLyricsReceiver`（install / pending / discarded / failed 四态）；测试 `QQPlayerTests/AlignedLyricsSyncTests.swift:348` |
| ④ | 部分 | **无挂起表**，只有**会话内暂存**：`SyncLyricsReceiver.swift:96-111`（收尾再试一次映射，仍不行 → 丢弃 + 记账）；自愈靠「下次同步从对端 manifest 重新拉」（`:13`） |
| ⑤ | **✗ 空格** | 无对账/补发通道。歌词只在「该歌被选中传输」时随行；**不选就永远不来**，且没有任何入口能把已有歌词补进传输集 |
| ⑥ | 部分 | **计了数，但没上屏**：被动端 `SyncLibraryPassiveHost.swift:51` `discardedLyrics`（`:411` 追加）；拉取端 `SyncLibraryPullController.swift:451-453` `orphanLyricsSkipped`；但 `SyncUIReportSummary`（`QQPlayer/Services/SyncUIState.swift:449-500`）**没有**这两个字段 ⇒ UI 消费者看不到 |
| ⑦ | 有 | `AlignedLyricsSyncTests.swift:138/149/160/181/234/348/374/394/426`；无模拟器 harness `scripts/sync-harness/main.swift:1194` |
| ⑧ | △ | 无「歌词接收器已装配」的静态断言（`SyncWiringContractTests` 不含）；只有 `SyncLibraryPassiveTests.swift:355` 行为用例 |

### G. 曲库音频文件（不在枚举）

| 列 | 结论 | 证据 |
| --- | --- | --- |
| ① | 不适用 | 不走 outbox |
| ② | 有 | content_hash 为跨端身份（`docs/lan-sync-design.md` §6.1）；`SyncManifestGenerator` / `SyncTransferIdentity`；`QQPlayerTests/SyncTransferIdentityTests.swift` |
| ③ | 有 | `QQPlayer/Sync/SyncManifestReconciler.swift`、`SyncFileReceiver.swift`；`SyncManifestReconcileTests.swift:34-96` |
| ④ | 有 | 断点续传 `.part`：`SyncFileTransferTests.swift:158`「断点续传」、`:235`「resume 不匹配」 |
| ⑤ | 部分 | 无「本地真值补发」概念，靠**每次重算选择集 manifest**（`SyncCollectionSyncCoordinator.swift:540`）。已选歌但 manifest 缺条目时**无专门告警** |
| ⑥ | 有 | `SyncUIReportSummary`（`SyncUIState.swift:449`）经 `MacSyncRunViewModel.swift:304` 上屏（含失败清单 `failedItems`） |
| ⑦ | 有 | `SyncFileTransferTests`(7)、`SyncManifestReconcileTests`(11)、`SyncTransferIdentityTests`、`SyncLibrarySyncE2ETests`、`SyncLibraryPlanTests` |
| ⑧ | △ | 无静态装配断言；有 `mac-playback-carry-attached`（`SyncWiringContractTests.swift:71`）间接覆盖跟歌走 |

### H. 歌单自定义封面（不在枚举，搭 C 的 payload）

| 列 | 结论 | 证据 |
| --- | --- | --- |
| ① | 不适用 | 随 playlist upsert payload 走：`DatabaseManager+Playlists.swift:591` `updatePlaylistCustomCover`（record `:605`） |
| ② | **✗ 空格** | 载荷携带的是**发送端本地相对路径**（`SyncDataSnapshots.swift:69` `customCoverImagePath`，键 `:79` `custom_cover_image_path`）——**不是跨端身份键，也没有文件传输通道**（`grep -rn "cover" QQPlayer/Sync/` 无任何传输点）。**缺什么**：封面文件本身的跨端通道（可仿歌词做 `@cover/{content_hash}`）或明确「封面不同步」并把对端来源的路径在落库时清空 |
| ③ | 部分 | `SyncChangeLogApplier.applyPlaylist` `SyncChangeLogApplier.swift:166`（更新）/ `:179`（插入）**原样写入** ⇒ 接收端歌单行里的路径指向对端设备的文件；消费点 `QQPlayer/Views/Playlists/PlaylistCardView.swift:189-196`（拼 App Group 容器路径 `try? Data(contentsOf:)`），读不到就静默 return |
| ④ | **✗ 空格** | 无（封面没有独立挂起概念） |
| ⑤ | **✗ 空格** | 无 |
| ⑥ | **✗ 空格** | 封面加载失败**无任何计数/披露**（消费点 `guard let ... else { return }` 静默） |
| ⑦ | **✗ 空格** | 无跨端封面用例（`grep cover QQPlayerTests/Sync*` 无） |

---

## 3. 披露细则（⑥ 列为什么大多是「部分」）

**Mac 端**（唯一有 UI 披露的面板）：
`QQPlayer/Mac/MacSyncView.swift:983-1026` 显示 6 个数字
（`pushedEntries` / `appliedEntries` / `suspendedEntries` / `unresolvedEntries` /
`pushedMissingIdentityEntries` / `ignoredDeletes`），
字段来源 `SyncDataSyncReport`（`QQPlayer/Sync/SyncDataSyncCoordinator.swift:64-83`）。

⇒ **全部是总数，没有任何实体维度**。用户看到「未定位 110」不可能知道是收藏、歌单项、
还是播放历史出的问题；也无法据此判断该修哪条通道。

**2026-09-18 身份兑底包起**：两端面板多了「身份歧义 N 条」（仅 N > 0 显示，5 语）；
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
| 1 | **C⑤ playlist 结构无对账补发通道** | `reconcilableEntities` `SyncChangeLogMapping.swift:571` 不含 `.playlist`；`rowKey` `:706` 显式 nil | outbox 机制之前创建的歌单（名 / 封面 / 结构）**永不同步到对端**；面板全绿、日志无异常。用户看到的是「另一台设备上就是没这个歌单」 |
| 2 | **E① playbackPosition 生产端 0 写点** | `grep -rn "entity: \.playbackPosition" QQPlayer/` 无输出；`v1Synced` `SyncDataSyncModels.swift:38` 不含 | 「播放位置上下文」这一整类**从未同步过**（设计文档 §6.2 承诺的范围里的一项，实际不存在） |
| 3 | **H② 封面路径当跨端值传输** | `SyncDataSnapshots.swift:69/79`；`SyncChangeLogApplier.swift:166/179` 原样落库 | 对端歌单封面**必然加载不出**（路径指向发送端设备），静默回落自动封面，零报错 |
| 4 | **F⑤ aligned 歌词无补发通道** | 无（歌词只随「被选中传输的歌」走） | 已有的对齐歌词，只要没跟歌一起传过，就**永不到达对端** |

### 二级：数字误导（看着在干活，其实没干）

| # | 空格 | 证据 | 用户可见后果 |
| --- | --- | --- | --- |
| 5 | ~~**E③ 静默丢弃被计入「已应用」**~~ **已收（2026-09-15）** | 修法：`applyPlaybackPosition` 三条未落地路径（开关关 / 无落点 / 落点未接受）一律 `return false` + `onPlaybackPositionUnsupported` → `unsupportedEntries` → 面板「未支持」行 | 面板不再报「已应用 N」而本地零变化（INV-20 有守护） |
| 6 | **C⑥ 歌单结构缺口无计数** | `Report`（`SyncChangeLogMapping.swift:437-460`）无 playlist 字段 | 一级第 1 条的静默失效**没有任何可观测信号** |

### 三级：同不同步看运气（依赖用户手动触发）

| # | 空格 | 证据 | 用户可见后果 |
| --- | --- | --- | --- |
| 7 | ~~**补发通道的三个触发点都是「用户动作」**~~ **已收（2026-09-15）** | 修法：Mac 侧**会话 ready 自动跑一轮**（`SyncHostCenter.handleSessionPhase(.ready)` → `MacDataSyncAutoRunner.sessionDidBecomeReady`，含「本地真值对账补发」）；手动（面板按钮）与自动共用 `SyncDataRunGate`（同一会话只允许一轮，取不到=放弃本轮）；iOS 仍在会话装配时跑一次 | 不点也会补（用户 2026-09-15 拍板「触发时机 = 连接后自动」）；不再出现「点过的设备同步了、没点的没有」 |
| 8 | ~~**D 链式依赖无守护**：playlist_item 要求 playlist 结构先行落地~~ **已收（2026-09-15）** | 修法：applier 新增 `onSkippedMissingParent`，三种“父行/被引用行不存在”路径（歌单结构未到 / 收藏·播放历史·歌单项引用的歌本地查无）全部返回 false + **计数**；peer 累加 → `SyncDataSyncReport.skippedMissingParentEntries` → Mac 面板「缺依赖」行（>0 橙）+ hint（5 语） | 以前这三种静默失败（面板不计、「已应用」也不含），现在可见；不会再出现“同步完了但什么都没发生、没人报警” |

### 四级：只影响诊断

| # | 空格 | 证据 | 用户可见后果 |
| --- | --- | --- | --- |
| 9 | **⑥ 披露不区分实体** | `MacSyncView.swift:983-1026` 全是总数 | 用户只能看到「有 110 条没定位」，无法判断该修哪条通道 |
| 10 | **F⑥ 歌词丢弃计了数没上屏** | `SyncUIState.swift:449-500` 无 `discardedLyrics`/`orphanLyricsSkipped` | 歌词没到，用户不知道为什么 |
| 11 | ~~**iOS 端零 UI 披露**~~ **已收（2026-09-15）** | 修法：`IOSPassiveSyncCenter.dataSummary`（帧 8/9 回调累加，主线程）+ `IOSPassiveDataSyncPresenter`（`countRows`/`gapRows` 纯逻辑）+ iOS「设置 → 同步」新增「播放数据」账目区（计数行 + 缺口行 + 说明，>0 橙色；**复用 Mac 既有 key，无新增文案**）；未同步过 = 空态 | 手机侧也能看见「同步了什么 / 丢了多少」 |
| 12 | **E⑦ 无 applier 用例** | `grep "Applier playback" QQPlayerTests/` 无 | 上述 5 号的误导行为不会被 CI 抓到 |

---

## 5. 复现本表的命令（自检可用）

```bash
# ① outbox 写点总表
grep -rn "SyncChangeLogStore.record" --include="*.swift" QQPlayer/ | grep -v SyncChangeLogStore.swift

# ② 身份键填充（发送侧）：两把键（指纹优先 → 相对路径兑底）
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
