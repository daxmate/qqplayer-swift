# 曲库存储形态与扫描决策契约（L0：文字契约）

> **状态**：2026-09-23 首次落仓。基线 = `origin/main` @ `38cfb35`。
> **地位**：iOS 曲库「文件放哪 / 什么算曲库内 / 什么时候扫 / 什么算真删除 / 旧位置还认不认」的**文字契约**。
> 每条规则附**源文件（唯一实现处 + 行号）+ 守护测试名**；凡代码与测试都没给出确定语义的，写进 §6「未定义 / 待定」，**不臆造**。
> **配套**：`docs/sync-contract.md`（同步需求真相）、`docs/sync-invariants.md`（同步不变量）、`docs/logging.md`（日志落点）。
> **入库方式**：`docs/` 在 `.gitignore:109`（本地产物不入库），本文件属**强制入库**的规格文件 → `git add -f`。

## 0. 怎么用这份文件

1. 每条规则三段式：**规则（一句话）/ 源文件（唯一实现处 + 行号）/ 守护（测试名）**。没有守护的显式标 `✗ 无守护`。
2. 改任何一条语义前先读 §5「变更规则」：那里写了改哪一类必须同步更新哪些守护测试。
3. 平台分栏：iOS = 隐藏布局（本文主体）；macOS = 现状布局，本契约对它**逐字节透传**（不做跨平台统一）。
4. **只写 `origin/main` 里查得到的**。在途分支上的改动不算契约（见 §6）。

---

## 1. 布局与根

### 1.1 曲库根 = `Documents/Music`（iOS）

| 项 | 内容 |
| --- | --- |
| 规则 | 曲库根 = `<Documents>/Music`，是**路径解析的唯一基准**；`track.path` 存**相对 Music 根**的 POSIX 相对路径 |
| 源文件 | `QQPlayer/Services/LibraryRoot.swift:40`（`musicDirectoryName = "Music"`）、`:308-316`（`musicRootURL`）、`:12-15`（`track.path` 两种形态）、`:39-46`（可见目录常量）、`:56-59`（`plannedDirectoryNames`） |
| 守护 | `QQPlayerTests/LibraryHiddenLayoutMigrationTests.swift:83`「类目落点全部在隐藏根下；曲库根仍是 Documents/Music（唯一可见）」；`:124`「track.path 相对语义不变：相对路径仍解到 Documents/Music 之下」；`QQPlayerTests/LibraryLayoutMigrationTests.swift:95`「曲库根下文件存相对路径，曲库外文件仍存绝对路径」 |

可见区（发现/展示口径）：只会看到 `Documents/Music`（曲库）与 `Documents/.qqplayer`（隐藏根）。

### 1.2 `track.path` 的两种形态（判据 = 首字符是否 `/`）

| 形态 | 语义 | 源文件 | 守护 |
| --- | --- | --- | --- |
| 相对路径（不以 `/` 开头） | **曲库内文件**，相对曲库根 `Music/` | `LibraryRoot.swift:326-327`（`isRelativeStoredPath`）、`:335-352`（`normalizedRelativePath`，拒绝对路径与 `..` 逃逸）、`:354-364`（`relativePath(of:baseDirectory:)`） | `LibraryLayoutMigrationTests.swift:95`、`:119`「换容器：同一相对路径在不同 Documents 根下解析到各自的新根」 |
| 绝对路径（`/` 开头） | **曲库外文件**——Documents 之外的安全域/书签文件，或未规划的 Documents 根文件；语义与文件夹化之前一致（绝对路径 + security-scoped bookmark） | `LibraryRoot.swift:429-447`（`isExternalPath` / `isInsideDocuments`）、`:388-397`（`absoluteURL(forStoredPath:)`） | `LibraryLayoutMigrationTests.swift:95`；`QQPlayerTests/DatabasePathResolverTests.swift` 系列（DB 落点，见 1.4） |

**换算唯一入口**：`LibraryRoot.storedPath(forAbsolutePath:)`（绝对 → 存储形态，**幂等**，`LibraryRoot.swift:372-385`）与 `LibraryRoot.absoluteURL(forStoredPath:)`（存储形态 → 绝对，`:388-397`）。同步层的 `SyncManifestGenerator.normalizeRelativePath` / `relativePath(of:baseDirectory:)` 只是**转发**到本文件（依赖方向 Sync → LibraryRoot，`LibraryRoot.swift:17-21`、`:329-334`、`:354-356`）。

### 1.3 隐藏根 `Documents/.qqplayer/`（iOS）——派生内容落点

| 类目 | 落点（iOS） | 源文件 | macOS 现状（透传） |
| --- | --- | --- | --- |
| 隐藏根 | `<Documents>/.qqplayer` | `LibraryRoot.swift:65`、`:100-108`（`hiddenRootURL`） | `<Documents>` 本身（不引入隐藏层） |
| DB | `.qqplayer/db/` | `:68`、`:143-146`（`databaseDirectoryURL`） | `Application Support/QQPlayerMac/qqplayer.db`（见 1.4） |
| 状态（favorites / player-state / pairing / 书签 / 歌单） | `.qqplayer/state/…` | `:69`、`:148-186`（`stateDirectoryURL` / `favoritesFileURL` / `playlistsDirectoryURL` / `playerStateFileURL` / `pairingFileURL` / `externalBookmarksFileURL`）、`:77-78`（`playlists`） | `Documents/` 根平铺（`qqplayer-favorites.json` / `qqplayer-playlists` / `qqplayer-player-state.json` …） |
| 封面缓存 + 映射表 | `.qqplayer/artwork/` | `:70`、`:188-203` | `Documents/Artwork/` |
| 歌词（手工 / 对齐 / 逐曲缓存 / 搜索缓存） | `.qqplayer/lyrics/{manual,aligned,cache/{tracks,search}}` | `:71`、`:79-83`、`:224-254` | `Documents/Lyrics` / `Documents/lyrics-aligned` / `Documents/lyrics-cache/{tracks,search}` |
| 日志 | `.qqplayer/logs/` | `:72`、`:256-263` | `Documents/Logs/`（AppLog 主日志另有 `~/Library/Logs/QQPlayerMac/app.log`） |
| 元数据 | `.qqplayer/meta/` | `:73`、`:265-271` | `Documents/meta` |
| 各类网络缓存 | `.qqplayer/cache/<name>` | `:74`、`:273-282`（`cacheDirectoryURL` / `namedCacheDirectoryURL`） | `Documents/<name>`（平铺） |
| 回收区（**旧根残留**） | `.qqplayer/trash/` | `:75`、`:284-292`（`trashDirectoryURL`）；⚠️ **生产删除落点不在这里**（见 1.5） | `Documents/.Trash` |

**换算唯一实现** = `LibraryRoot.scopedURL(hidden:macOS:isFile:)`（`LibraryRoot.swift:110-139`）：iOS 拼 `.qqplayer/<hidden…>`、macOS 拼 `<macOS…>`（空列表 = Documents 根本身，`:130-132`）。

### 1.4 数据库落点

| 平台 | 规则 | 源文件 | 守护 |
| --- | --- | --- | --- |
| iOS | 优先 App Group 容器 `group.com.daxmate.qqplayer.ios` 下的 `qqplayer.db`；无容器 → 回落 `.qqplayer/db/MusicLibrary.sqlite` | `QQPlayer/Services/DatabasePathResolver.swift:21-33`、`QQPlayer/Services/DatabaseManager.swift:504-519` | `QQPlayerTests/DatabasePathResolverTests.swift`（iOS 有容器 → 容器内 `qqplayer.db`；无容器 → Documents 兜底） |
| macOS | `Application Support/QQPlayerMac/qqplayer.db` | `DatabasePathResolver.swift:13-19` | 同上（macOS 两例） |
| iOS 旧库搬迁 | `<Documents>/MusicLibrary.sqlite(+ -shm/-wal)` → `.qqplayer/db/`，在**打开连接之前**（移动打开中的 WAL/SHM 有一致性风险）；幂等、只搬不删、失败保留原件下次重试 | `QQPlayer/Services/DatabaseHiddenLayoutRelocation.swift:26-58`、`DatabaseManager.swift:498-503`（调用点） | ✗ 无独立用例（仅在迁移套件里间接覆盖） |

### 1.5 回收区（删除落点）

| 项 | 内容 |
| --- | --- |
| 规则 | 生产删除落点 = **曲库根内**的隐藏目录 `<曲库根>/.Trash/<64位hex>.<ext>`（差集语义要求文件移出曲库根才对扫描不可见）；`Documents/.Trash` 是**旧根残留**，`trashDirectoryURL` 只解析它 |
| 源文件 | `LibraryRoot.swift:47-50`（`trashDirectoryName` 注释）、`:284-292`；实现 = `DeleteReclaimArea` |
| 守护 | `QQPlayerTests/TrackDeletionReclaimAreaTests.swift:468`「应用回收区 · 路径唯一入口（形状契约）」→ `:470`「回收区目录名字面量只准出现在唯一入口文件；白名单不许空转」、`:491`「自证：剥注释后字面量仍被抓住，注释里的提及不算数」 |

### 1.6 隐藏布局迁移（v1 → v2/v2.1，iOS only）

| 阶段 | 规则 | 源文件 | 守护 |
| --- | --- | --- | --- |
| v1（文件夹化） | 把 Documents 根**规划类**文件搬进 `Documents/{Music,Lyrics,Artwork,Logs}`，并改写 `track.path` 为相对 Music 根 | `QQPlayer/Services/LibraryLayoutMigrationPlan.swift`（规则）、`QQPlayer/Services/LibraryLayoutMigrator.swift:138-142`（建规划目录） | `LibraryLayoutMigrationTests.swift:199`（扫描单层）、`:299`（根音频搬进 Music + DB 行改相对）、`:332`（规划目录 + 旧目录内容搬入）、`:372`（幂等）、`:403`（同名不覆盖）、`:427`（失败不中断） |
| v2/v2.1（只留 `Music/` 可见） | `Documents/` 下除 `Music/` 以外的一切收进 `.qqplayer/`；**只搬不删**、冲突**不覆盖**（目录递归合并、同名项改名后缀 `<name>.legacy-<yyyyMMdd-HHmmss>` 搬入、空壳目录搬进 `trash/`）；**不改 `track.path`** | 纯逻辑 `QQPlayer/Services/LibraryLayoutMigrationV2Plan.swift`（映射表 + 冲突改名规则）、执行器 `QQPlayer/Services/LibraryLayoutMigrationV2Migrator.swift` | `LibraryHiddenLayoutMigrationTests.swift:153`（Music/隐藏根/`.sync-incoming` 保留原位）、`:174`（搬进隐藏根、根只剩 Music）、`:229`（幂等）、`:257`（冲突不覆盖：同名文件改名搬入）、`:288`（目录冲突递归合并、空壳搬进回收区）、`:326`（启动期已建同名日志文件 ⇒ 改名搬入）、`:467`（失败不中断）、`:540`（被 DB 绝对路径引用的根条目跳过不搬） |
| 完成门 | v2.1 门 key `library.layoutMigrationV2_1Completed.v1`；**仅当「根上已无可搬条目且失败 = 0」才置位**，否则下次启动重试；旧门 key `…V2Completed.v1` **刻意不再读取** | `LibraryLayoutMigrationV2Migrator.swift:75-95`（门 key 常量 + 语义注释）、下同 | `LibraryHiddenLayoutMigrationTests.swift:362`（有残留不置位 / 无残留才置位）、`:522`（成功才置位；置位后跳过） |
| 启动时机 | 生产顺序写死两轮：① `runStartupPrepass()`（`LibraryLayoutMigrationV2Migrator.swift:143`）在 `QQPlayerApp.didFinishLaunching` **首句、同步**跑（`QQPlayer/QQPlayerApp.swift:35`，不置门）② `runInBackground()`（`AppCoordinator.swift:138-140`，v1 之后）收尾并置门 | `LibraryLayoutMigrationV2Migrator.swift:36-45`（不变量注释） | ✗ 无守护（顺序靠注释固化） |
| 干跑 | `run(dryRun: true)` 或启动参数 `--hidden-layout-dry-run`：只统计不搬、不置门 | `LibraryLayoutMigrationV2Migrator.swift:80-86` | `LibraryHiddenLayoutMigrationTests.swift:394`、`:500` |
| DB 引用保守例外 | DB 绝对存储路径指向某待搬根条目 ⇒ **跳过该条目不搬**（宁可留根上也不让引用悬空）；不计入残留、不阻塞置门 | `LibraryLayoutMigrationV2Migrator.swift:24-27` | `LibraryHiddenLayoutMigrationTests.swift:540` |

---

## 2. 派生路径规则与守卫

| 项 | 内容 |
| --- | --- |
| 规则 | **任何 Documents 派生路径都必须在「Documents 根 / 曲库根」之内解析**：① 各 `LibraryRoot` 便捷入口的落点在（注入的）Documents 根内、且不得落到真机容器；② 存储形态换算（相对 ↔ 绝对）在注入根内闭合；③ 派生链（DB identity / storedPath / StateManager 保存）内部不得绕回 `FileManager.default` |
| 源文件 | `LibraryRoot.swift:296-306`（`documentsRootURL`：**测试注入一律经 `fileManager` 缝**，不再有进程级全局静态覆盖）、`:311-316`（`musicRootURL` 永不返回 nil） |
| 守护 | `QQPlayerTests/DocumentsDerivedPathGuardTests.swift:36`（套件）→ `:66`「各 Documents 派生落点都在注入根内、且不在真机容器里」、`:109`「存储形态换算在注入根内闭合（相对 ↔ 绝对）」、`:132`「身份基准根与 stableId 派生走注入 FM（不经 `.default`）」（iOS）、`:160`「`migrateTrackForMovedFile`：注入根内闭合，且真的走了注入 FM」、`:206`「StateManager 保存链：落在注入根内、父目录缺失也能保存、注入 FM 真被走到」 |
| 测试缝 | `QQPlayerTests/DocumentsRootTestSupport.swift`（`DocumentsRootFileManager`：把 `.documentDirectory` 重定向到临时根，并计 `documentDirectoryResolutionCount`——**内部绕回 `.default` 时该计数零增长**，是「注入真有生效」的最强判据） |

**为什么这条语法这么严**（事故档案）：2026-09-22 CI 事故 `35707598276` —— `DatabaseManager.migrateTrackForMovedFile` 内部用硬 `.default` 的 `LibraryRoot.storedPath` + `generatePathStableId` ⇒ 临时根里的文件被判「曲库外绝对路径」、行查不到。**这类回归不让编译失败、也不让别的用例红**，只让某几条用例「莫名其妙」（见 `DocumentsDerivedPathGuardTests.swift:5-27`）。

---

## 3. 扫描决策

### 3.1 要不要自动扫 = `LibraryScanGate`（唯一决策点，纯函数）

| 项 | 内容 |
| --- | --- |
| 规则 | 启动 / 回前台的自动扫描决策收口到 `LibraryScanGate.decision(lastScanDate:trackCount:now:)`，**穷尽五态**：`neverScanned`（从未扫过）→ 扫；`intervalElapsed`（≥ 1 小时）→ 扫；`emptyLibrary`（**取到 0**）→ 强制扫；`unknownTrackCount`（**计数读不到**，哨兵 `-1`）→ 强制扫（fail-open）；`recentlyScanned` → 跳过 |
| 源文件 | `QQPlayer/Services/LibraryScanGate.swift:46`（类型）、`:49`（`minimumIntervalHours = 1.0`，历史值别改）、`:52-83`（五态 + `shouldScan` **唯一判据**）、`:103`（`unknownTrackCount = -1` 哨兵）、`:110-136`（`decision` 唯一实现）、`:144-171`（文案/级别唯一来源） |
| 调用点 | `QQPlayer/Services/AppCoordinator.swift:96`（启动）、`QQPlayer/QQPlayerApp.swift:274`（回前台）——两处都只调 `decision` + `log`，不得另写条件 |
| 守护 | `QQPlayerTests/LibraryScanGateTests.swift:41`（套件）→ `:67`「空库：0.7 小时前扫过也必须扫」、`:89`「非空库：0.7 小时前扫过仍跳过」、`:103`「窗口外 ⇒ 扫（三种取数形态都一样）」、`:115`「计数读不到 ⇒ 也扫（fail-open），且与「空库」是两态」、`:143`「读不到与空库可分辨：文案不同 + 级别不同（warn vs info）」、`:161`「从未扫过 ⇒ 扫」、`:171`「恰好 1.0 小时 ⇒ 扫（>= 语义不变）」、`:182`「时钟回拨」、`:196`「穷尽五态：kind 两两不同，shouldScan 与口径一致」、`:214`「空库那条是新文案」 |

**语义来源**：`emptyLibrary` 与 `unknownTrackCount` 都来自 2026-09-23 的「**打开就该有歌**」事故——`lastLibraryScanDate` 落在**数据容器的 Preferences**（跨「覆盖安装」存活），重装后仍是「0.7 小时前」⇒ 1 小时节流判定「最近扫过」⇒ 启动不扫，而库其实是空的。

**取数口径（入参 `trackCount` 三值语义）**：`0` = 空库；`> 0` = 非空；`-1` = 读不到。返回 `-1` 的两个地方都在代码里显式表态，**不许折成 `0`**：`AppCoordinator.swift:148-151`、`QQPlayerApp.swift:291-293`（都是 `(try? getTrackCount()) ?? LibraryScanGate.unknownTrackCount`）。

### 3.2 平台边界

| 平台 | 规则 | 源文件 | 守护 |
| --- | --- | --- | --- |
| iOS | 「空库 ⇒ 强制扫」「计数读不到 ⇒ 强制扫」生效 | `LibraryScanGate.swift:91-98`（`forcesScanWhenLibraryIsEmpty` 编译期常量） | `LibraryScanGateTests.swift:239`「平台边界：空库强制扫规则 iOS 生效、macOS 关闭」 |
| macOS | **关闭**：空库是合法稳态（用户还没往曲库放歌 / 只用外部来源），加这条会让它每次启动全量枚举，收益为零 | 同上（理由在 `LibraryScanGate.swift:29-35`） | 同上 |

### 3.3 扫描口径（iOS 曲库根）

| 项 | 内容 |
| --- | --- |
| 规则 | 只认 `Documents/Music`；**单层不递归**（`Music/<子目录>/*.flac` 不收录，历史子目录本批不递归也不搬平）；**根不存在 ⇒ 不 reconcile**（扫不到 ≠ 空库） |
| 源文件 | `QQPlayer/Services/LibraryIndexer+Scanning.swift:110-117`（口径注释 + `rootExists`）、`:122`（`findMusicFiles(…, recursive: false)`）、`:161`（iOS reconcile 传 `rootExists ? [musicDirectory] : []`）；`QQPlayer/Services/MusicDirectoryScanner.swift:36-68`（`recursive: false` = 只列根下第一层，隐藏项跳过，仅常规文件） |
| 守护 | `LibraryLayoutMigrationTests.swift:199`「扫描单层：Music 一层收录，Music 子目录不收录（递归模式仍收录）」 |
| macOS 附加口径 | 多文件夹曲库（`getMusicFolderURLs()`）、iCloud dataless 文件本轮不 parse（只索引已本地化文件） | `LibraryIndexer+Scanning.swift:211-258` | ✗ 无独立用例 |

### 3.4 什么算「文件真没了」= 扫描尾部调和（唯一授权点）

| 项 | 内容 |
| --- | --- |
| 规则 | 删行**唯一授权点** = `FileCleanupManager.reconcileMissingFiles(in:)`，两条前提缺一不可：① 该行解析出的绝对 URL 落在**本轮成功枚举过的根**内（根不可用 ≠ 空库）；② 时机在**主扫之后**（那时主扫已按 stableId 修好重装后的悬空 path，剩下的「不存在」才是真删除）。`roots` 为空 ⇒ 早退，一条不删 |
| 源文件 | `QQPlayer/Services/FileCleanupManager.swift:36-50`（授权点口径 + `guard !roots.isEmpty else { return }`）、`:51-90`（两类移除：文件真没了 → 全量删除；格式被取消收录 → 只移除曲目行、文件与用户数据保留）；调用点 `LibraryIndexer+Scanning.swift:161`（iOS）、`:309`（macOS） |
| 守护 | `QQPlayerTests/FileCleanupManagerTests.swift:156`（套件）→ `:161`「空 successfullyScannedRoots → 直接返回，一条不删」、`:177`「文件不存在 → deleteTrack（含收藏/歌单/历史）」、`:203`「文件在但扩展名未收录 → 只移除曲目行」、`:232`「根枚举失败但库里有该根曲目 → 不删」、`:253`「混合：恰删 1、移除 1、保留 1」 |

### 3.5 后置孤儿清扫「不得删曲库内行」+ 重装自愈（回归契约）

| 规则 | 源文件 | 守护 |
| --- | --- | --- |
| **曲库内行**删不删只由 3.4 判；后置维护（`FileCleanupManager.checkForOrphanedFiles`，`FileCleanupManager.swift:127`）**没有扫描上下文**，**不得**因「入库 path 解出来不存在」删曲库内行 | 触发链 `QQPlayer/Services/AppCoordinator+iCloud.swift:15`（`onIndexingCompleted`，由 `isIndexingPublisher` sink 触发，`CurrentValueSubject` **订阅即送 false** ⇒ 跳过主扫的启动 15s 后照样跑；形态见 `ReinstallLibraryPurgeTests.swift:11-25`） | `QQPlayerTests/ReinstallLibraryPurgeTests.swift:365`「后置孤儿清扫：曲库内行不得被判删除」→ `:370`「B-1：跳过主扫的启动里，后置清扫不得删任何曲库内行（含引用四表）」、`:419`「B-2：曲库外文件不可达仍清」 |
| 重装（数据容器 UUID 变化）后**修 path、不删行**：走唯一入口链（`LibraryIndexer` 判定 → `migrateTrackForMovedFile` → `migrateTrackStableIdAndPath`），不新开平行入口 | `DocumentsDerivedPathGuardTests.swift:160`（该链的注入根闭合）；旧容器前缀归一化 `LibraryRoot.swift:449-486` | `ReinstallLibraryPurgeTests.swift:210`「重装后悬空 path：修 path 不删行」→ `:215`「A-1」、`:258`「A-2：旧容器 Documents 根形态 ⇒ 判定 resyncPathOnly 并按 stableId 修 path（不删行）」、`:322`「A-3：主扫入口 indexFile 对悬空行只修 path、不删行（端到端）」 |
| 扫描尾部调和**只**删「本轮枚举过的根」里真的没了的行；根外/其它根的悬空行原样保留；主扫自愈之后才判「文件不存在」 | 同上（3.4） | `ReinstallLibraryPurgeTests.swift:447`「扫描尾部调和：只删「本轮枚举过的根」里真的没了的行」→ `:451`「C-1」、`:496`「C-2：主扫自愈之后才判」、`:538`「C-3：roots 为空 → 早退，一条不删」 |

**真机事故档案**（本节的来源）：2026-09-23 00:43Z 一次启动，App Group 容器里 `qqplayer.db` 的 `track` 225 → 0、`play_history` 882 → 2、`favorite` 1 → 0、`playlist_item` 443 → 0。两条成因形态都在 `ReinstallLibraryPurgeTests.swift:9-31` 里钉死（① 已修 `6dcab50`；② 本节的 `checkForOrphanedFiles` 洞）。

---

## 4. 旧位置（**只读兼容**；`origin/main` 现状）

写入口一律只落**新位置**；旧位置只在**新位置未命中时**被读，且**绝不被覆盖/写回**（例外见 4.2 封面映射表）。

### 4.1 iOS：v2/v1 迁移未跑到时的只读兜底

| 类目 | 旧位置（只读） | 源文件 | 守护 |
| --- | --- | --- | --- |
| 收藏 | `Documents/qqplayer-favorites.json` | `QQPlayer/Services/StateManager.swift:86`（旧位置 URL）、`:135`（新位置优先，旧位置只读兜底） | `QQPlayerTests/StateManagerTests.swift`（同名系列用例） |
| 歌单 | `Documents/qqplayer-playlists` | `StateManager.swift:96`、`:195`（同一 slug 新位置权威，不覆盖）；`:274`（删歌单时新旧两处都删） | 同上 |
| 播放状态 | `Documents/qqplayer-player-state.json` | `StateManager.swift:106`、`:368` | 同上 |
| 手工歌词 | `Documents/Lyrics/`（v1）+ `Documents/lyrics-manual/` | `QQPlayer/Services/LyricsManager.swift:268-269`（只读兼容注释）、`:316`（新位置优先）；`:305`（清除手工歌词时新旧两处都删） | ✗ 无独立用例 |
| 对齐歌词 | `Documents/lyrics-aligned/` | `QQPlayer/Services/AlignedLyricsStore.swift:120-122`、`:176`、`:212`（同一 stableId 新位置权威） | `QQPlayerTests/AlignedLyricsSyncTests.swift`（相关用例） |
| 逐曲歌词缓存 | `Documents/lyrics-cache/tracks/` | `QQPlayer/Services/LyricsSearch.swift:302-313`、`:334`（新位置优先；命中后仍以新位置为准） | ✗ 无独立用例 |
| 封面映射表 | `Documents/Artwork/ArtworkMapping.plist`（v1）与 `Documents/ArtworkMapping.plist`（改名前的旧位置） | `LibraryRoot.swift:205-222`（`legacyArtworkMappingFileURLs`，顺序 = 优先级；新位置仍高于全部旧位置）、`QQPlayer/Services/ArtworkManager.swift:43-44` | `QQPlayerTests/ArtworkCacheSafetyTests.swift`（相关用例） |
| DB 三件套 | `Documents/MusicLibrary.sqlite(+ -shm/-wal)` | `DatabaseHiddenLayoutRelocation.swift:26-58`（打开连接前搬迁，只搬不删） | ✗ 无独立用例 |

### 4.2 唯一的「旧位置内容被并入新位置」

| 项 | 内容 |
| --- | --- |
| 规则 | 封面映射表是**元数据**不是缓存：`ArtworkCache.loadMapping()` 把「新位置 > 旧位置」合并（键冲突新位置优先）；只要旧位置贡献了新位置没有的条目，**立刻把合并结果落回新位置**，否则映射表可能只存在于旧位置，而旧位置恰是清理/迁移的作用域。**旧位置只读兼容必须在任何清理动作之前生效** |
| 源文件 | `QQPlayer/Services/ArtworkCache.swift:39-51`（合并规则 + 顺序不变量）、`:52-79`（`loadMapping`）、`LibraryLayoutMigrationPlan.swift:62-70`（为什么一次性迁移器**不得**把映射表当普通文件搬——搬进 `Artwork/` 会被缓存清理当孤儿删；目标已存在而整项跳过 ⇒ 旧位置成「读不到的死文件」） |
| 守护 | `QQPlayerTests/LibraryHiddenLayoutMigrationTests.swift:137`「封面映射表永不被当缓存；映射为空/读失败 ⇒ 不清理（改路径后契约仍成立）」；`ArtworkCacheSafetyTests.swift`（合并与 fail-safe 相关用例） |

### 4.3 旧数据容器前缀归一化（重装后路径自愈的上游）

| 项 | 内容 |
| --- | --- |
| 规则 | `…/Containers/Data/Application/<容器 ID>/Documents/<rest>` → `<现 Documents>/<rest>`；**保守判据**（防误伤）三条件同时满足才归一化：① 含 `/Containers/Data/Application/`；② 紧跟容器 ID 的那一层**就是** `Documents`；③ 不在现 Documents 之下。非数据容器绝对路径原样返回（**不**动 `/tmp/xxx/Documents/…`、也不动 App Group 共享容器） |
| 源文件 | `LibraryRoot.swift:449-486`（`rebasedFromLegacyContainer`，含误伤两类的说明） |
| 守护 | `LibraryLayoutMigrationTests.swift:139`「旧数据容器前缀归一化：换 UUID 的旧路径解回现容器」；`ReinstallLibraryPurgeTests.swift:258`（A-2 端到端用它） |

---

## 5. 变更规则（改哪一类 → 必须同步更新哪些守护）

| 改什么 | 必须同步 | 对应守护（红了就是漏改） |
| --- | --- | --- |
| `LibraryRoot` 的目录常量 / 新增落点类目 | `DocumentsDerivedPathGuardTests.everyLibraryRootCategoryConfinedToInjectedRoot` 的类目清单；`LibraryHiddenLayoutMigrationTests` 的落点断言 | `DocumentsDerivedPathGuardTests.swift:66`、`LibraryHiddenLayoutMigrationTests.swift:83` |
| 曲库根 / 隐藏根位置 | 迁移器映射表（`LibraryLayoutMigrationV2Plan`）+ 完成门语义 + 本节所有落点 | `LibraryHiddenLayoutMigrationTests.swift:174`、`:362` |
| `track.path` 语义（相对/绝对判据） | 同步第二身份与 manifest 的转发点（`SyncManifestGenerator`）+ 换容器解析 | `LibraryLayoutMigrationTests.swift:95`、`:119` |
| 派生路径解析链（新增热路径 / 改 DB identity / 改 StateManager 保存链） | 所有新落点必须显式传 `fileManager` 缝（**不得**内部硬 `.default`） | `DocumentsDerivedPathGuardTests.swift:132`、`:160`、`:206`（「注入 FM 真被走到」判据 = `documentDirectoryResolutionCount` 增长） |
| 扫描决策（新增一态 / 改节流 / 改平台边界） | `LibraryScanGate.Decision`（穷尽五态）+ `logEntry` 文案 + `shouldScan`；两处调用点只调 `decision`/`log` | `LibraryScanGateTests.swift:196`（穷尽五态）、`:214`（新文案）、`:239`（平台边界） |
| 调和语义（`roots` 判据 / 删除授权） | `FileCleanupManager.reconcileMissingFiles` 的两条前提；后置清扫不得获得曲库内删除权 | `FileCleanupManagerTests.swift:161`、`:232`；`ReinstallLibraryPurgeTests.swift:370`、`:538` |
| 删除落点 / 回收区路径 | `DeleteReclaimArea` 仍是唯一持有 `".Trash"` 字面量的生产文件（白名单） | `TrackDeletionReclaimAreaTests.swift:470`、`:491` |
| 迁移规则（冲突处理 / 改名后缀 / 完成门 key） | `LibraryLayoutMigrationV2Plan` 的规则函数 + 执行器账目（`Summary`） | `LibraryHiddenLayoutMigrationTests.swift:257`、`:288`、`:362`、`:467` |
| 新增 `.swift` 文件 / 新测试文件 | 仓库门禁：`scripts/check-target-membership.py`（target 全量成员）、`scripts/add-test-file.py`（登记测试 target）、`scripts/check-structural-budget.sh`（结构预算） | 见 §7 验证命令（本地自跑；CI 同样跑） |

---

## 6. 未定义 / 待定

1. **在途分支的「旧位置写入」改动不算契约**：`fix/legacy-write-paths`（`7ffe1ad`）尚未入库。本文件 §4 只描述 `origin/main` 现状；该分支若合入，§4 必须重写。
2. **macOS 布局无专属契约**：本文件对 macOS 只写「透传 + 现状」（`LibraryRoot.swift:28-29`、`:100-108`、`:143`、`:110-139`）。macOS 曲库根 = `~/Music/QQPlayer`（`MusicFolderResolver.macDefaultFolderURL`）+ 用户添加的外部文件夹 ⇒ 与 iOS 隐藏布局不同构，**不承诺跨平台同构**。
3. **v2 迁移的启动顺序不变量的守护**：`runStartupPrepass()` 必须早于组件建目录——目前只活在 `LibraryLayoutMigrationV2Migrator.swift:38-63` 注释里，**无守护**（改启动顺序不会被任何用例抓住）。
4. **后置孤儿清扫对「曲库外文件」的删除口径**：`ReinstallLibraryPurgeTests.swift:419`（B-2）只覆盖了「曲库外不可达仍清」，**未**定义「曲库外文件可达但已改名」的语义。
5. **`.sync-incoming/`**：属同步链路语义（曲库根内隐藏目录），v2 迁移保留原位（`LibraryLayoutMigrationV2Plan.swift` 的 `keepInPlaceReasons`）；其生命周期**不在本契约范围**（见 `docs/lan-sync-design.md`）。
6. **Siri / Widget 扩展的 DB 可见性**：iOS DB 优先落 App Group 容器（`DatabasePathResolver.swift:21-33`），Widget 扩展的落点解析（`AppLog` → `LibraryRoot`）只依赖常量、不依赖 DB——跨进程一致性**未定义**。

---

## 7. 变更记录

| 日期 | 变更 | 依据 |
| --- | --- | --- |
| 2026-09-23 | 首次落仓：布局与根（§1）、派生路径守卫（§2）、扫描决策与调和（§3）、旧位置只读兼容（§4）、变更规则（§5）、未定义清单（§6） | 基线 `origin/main` @ `38cfb35`；逐条取证 `LibraryRoot` / `LibraryScanGate` / `FileCleanupManager` / `LibraryLayoutMigration*` / `LibraryHiddenLayoutMigrationTests` 等 |
