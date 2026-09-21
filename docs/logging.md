# 日志与同步状态可见 🔎

> 为什么有这份文档：诊断日志此前基本靠 `print()` 落到 `~/Library/Logs/QQPlayerMac/stdout.log`，
> 该文件一度涨到 **49MB 且没有任何轮转**——排查同步问题时只能 grep 一个大文件；而
> 「为什么停住了」这类关键信息只存在于日志里，界面上只能感觉到「慢」。

## 一、统一出口：`AppLog`

`QQPlayer/Services/AppLog.swift` 是**唯一**的结构化日志出口：

- **级别**：`debug` < `info` < `warn` < `error`（低于阈值的记录不落盘）
- **分类**：`sync` / `transfer` / `migration` / `db` / `scrape` / `ui` / `general`
- **行格式**（一行一记录，消息内换行折叠成 `⏎`）：

  ```
  [2026-09-19T00:21:33Z] [WARN] [db] ⚠️ 打开失败 error=disk full
  ```

- **扇出到两个 sink**：
  1. `os.Logger`（subsystem `com.daxmate.qqplayer`，category = 分类）→ 可用 `log show` 结构化过滤
  2. 轮转文件 `app.log`（**有体积上限**，见下）

阈值来源（优先级从高到低）：环境变量 `QQPLAYER_LOG_LEVEL` → `UserDefaults` 键
`qqplayer.log.level` → 构建默认（Debug = `debug`，Release = `info`）。

### 分类与级别的权威映射（迁移时照这份，不各自发挥）

**分类**（按文件所属链路定，同一文件内不得混用）：

| 文件/目录 | category |
|---|---|
| `QQPlayer/Sync/**`（变更日志、配对、会话） | `.sync` |
| 文件传输实现（`SyncFileReceiver` / `SyncFileSender` / 分块、断点对齐） | `.transfer` |
| `SandboxMigration` / `TrackIdentityMigration` | `.migration` |
| `DatabaseManager*.swift` | `.db` |
| 在线抓取类（`HybridMusicAPI` / `QuarkClient` / `SpotifyAPI` / `LyricsSearch` / 在线搜索） | `.scrape` |
| `QQPlayer/Views/**`、`QQPlayer/Mac/**` 的 UI 层、`AppIntents` 用户交互 | `.ui` |
| 其余（播放引擎 `SFBAudioEngine*`/`PlayerEngine*`、音频元数据/封面、索引/扫描/清理、`AppCoordinator`/`StateManager`/`EQManager`、`Models/**`、启动链路） | `.general` |

**级别**（emoji 优先，两者冲突以 emoji 为准）：

| 原消息特征 | level |
|---|---|
| `⚠️` | `.warn` |
| `ℹ️` / `✅` | `.info` |
| `❌` | `.error` |
| 无 emoji + 带 `failed`/`error`/`失败` 语义 | `.error` |
| 无 emoji + 降级/跳过/超时类决策点 | `.warn` |
| 无 emoji + 其余状态事实 | `.info` |
| 逐条/逐帧追踪（如逐文件 copied、逐块进度） | `.debug` + 必须 `if AppLog.isEnabled(...)` 短路 |

> **两条条款冲突时以「逐条/逐帧追踪」优先**：emoji 只表示消息语气，**逐条 dump 类**
> （如 `dictionaryRepresentation().keys`、逐文件 copied、逐块进度）一律 `.debug` + 必须短路 ——
> 理由是**开销优先**，且全仓既有短路口径统一如此（截至 2026-09-21 全仓 133 处短路点，无一处用 `.info` 守卫）。
> 先例：`Models/WidgetData.swift` 的 `dictionaryRepresentation().keys` 那处（原 `ℹ️`，按本条定 `.debug` + 短路）。

> 禁止用「无 emoji ⇒ 删」当判据：无 emoji 的 108 行里 57 行（53%）带 `error/Failed`。

### 新增日志怎么写

```swift
AppLog.warn(.db, "⚠️ 打开失败 error=\(error)")           // 常规
if AppLog.isEnabled(.debug, .transfer) { … }             // 昂贵消息先短路
```

- **不要再 `print()`**（形状测试会红，见下）；
- 消息文本**保留既有 emoji 标记**（`✅/❌/⚠️/ℹ️`）——老 grep 习惯继续有效；
- **不进逐块热路径**：文件传输按**每文件一行**记（`SyncTransferMetrics`），别每块写日志。

## 二、落点与体积上限

判定/命名/归档的唯一实现是 `QQPlayer/Services/LogRotation.swift`
（`rotateIfNeeded` 归档轮转 / `trimTailIfNeeded` 环形截断）。**不要再手写第二套。**

| 文件 | 内容 | 上限 |
|---|---|---|
| `~/Library/Logs/QQPlayerMac/app.log` | `AppLog` 全部记录（分级/分类） | 8MB × 4 份 |
| `~/Library/Logs/QQPlayerMac/stdout.log` | 尚未迁移的 `print()`（重定向） | 8MB × 2 份 |
| `~/Library/Logs/QQPlayerMac/stderr.log` | fatal / 运行时错误 | 8MB × 2 份 |
| `~/Library/Logs/QQPlayerMac/scan.log` | 扫描/导入诊断（`MacScanLogger`） | 4MB × 2 份 |
| `~/Library/Logs/QQPlayerMac/trash.log` | 删除/废纸篓诊断（`MacTrashLogger`） | 4MB × 2 份 |
| iPhone 容器 `Documents/app.log` | `AppLog`（真机 print 取不到，必须落盘） | 8MB × 4 份 |
| iPhone 容器 `Documents/sync-diag.log` | 同步链路诊断（`SyncConnectDiag`，环形截断） | 超 256KB 留尾部 64KB |
| iPhone 容器 `Documents/db-debug.log` | 库打开/降级诊断（`dbDiag`） | 超 256KB 留尾部 64KB |

- macOS 的检查时机：**启动时**（重定向前先轮转）+ **每 10 分钟复查**
  （`MacScanLogger.startPeriodicRotation()`，桌面端 App 常驻数天，只在启动检查等于没有上限）。
- 环境变量可临时放大取证：`QQPLAYER_LOG_MAX_MB` / `QQPLAYER_LOG_MAX_FILES`。
- 首次接入时若文件已远超总预算（`maxBytes × maxFiles`，如遗留的 49MB），
  **直接丢历史**而不是把大文件改个名（`LogRotation.shouldDiscardHistory`）——磁盘立刻回到有界。

## 三、怎么读（排查入口）

```bash
# 通用日志：按级别/分类 grep（app.log 是有界文件，随便 grep）
grep "\[WARN\]\|\[ERROR\]" ~/Library/Logs/QQPlayerMac/app.log
grep "\[transfer\]" ~/Library/Logs/QQPlayerMac/app.log | tail -20

# 文件传输计时（每文件一行，含 rate=MB/s；两端各一行，同 fileID 可对照）
grep "transfer send"   ~/Library/Logs/QQPlayerMac/app.log   # 或 stdout.log（既有通道保留）
grep "transfer receive" ~/Library/Logs/QQPlayerMac/app.log

# 结构化过滤（macOS 系统日志通道，按 subsystem + category）
log show --last 10m --predicate 'subsystem == "com.daxmate.qqplayer" && category == "sync"'

# iPhone：拉容器文件回本地再读
xcrun devicectl device copy from --domain-type appDataContainer \
  --domain-identifier com.daxmate.qqplayer.ios \
  --source Documents/app.log --destination /tmp/ios-app.log
```

## 四、同步状态可见（用户价值最大的一条）

以前速率与停住原因**只在日志里**；现在同步页直接显示：

- **进度**：已完成/计划文件数（`SyncUIProgress`）
- **实际速率**：`Rate 3.42 MB/s`——数据来源是**既有的每文件一行** `SyncTransferMetrics`
  （不另造计量），累计口径 = 成功轮字节 ÷ 成功轮耗时（加权平均）
- **为什么停住了**：`SyncStallReason` 把既有失败原因串分类成可读结论
  （对端无应答 / 前台限制 / 校验不符 / 断点不符 / 磁盘满 / 文件不可读 / IO 失败 /
  设备断开 / 协议不一致 / 未归类），并保留**原始原因串**作为详情

速率的**唯一实现**是 `SyncTransferRate`（`QQPlayer/Services/SyncTransferStatus.swift`）：
日志行与 UI 共用同一份换算与格式（有契约测试锁住，禁止日志侧再算一套）。

## 五、迁移状态与守卫

### 当前状态（截至 2026-09-21）

- **小组件扩展已纳入日志栈**（2026-09-21 用户拍板方案 b）：`PlayerWidgetExtension` 的共享文件名单
  现在含 `Services/AppLog.swift` + `Services/LogRotation.swift`（登记走
  `scripts/pbxproj-membership.py --target widget-extension`）——因此 `Models/WidgetData.swift`
  得以迁到 `AppLog`，**不留第 3 处政策例外**：扩展内日志与 App 走同一出口、同一轮转实现。
- `print` → `AppLog` 迁移**已完成**：`Models/WidgetData.swift` 的 30 处是最后一块可迁的存量，
  已随「小组件扩展接入批」迁完。
  剩下 `Mac/MacScanLogger.swift`、`Services/SyncConnectDiag.swift` 各 **1 处**是**政策保留的落点本体**，
  即终态（**剩余 = 2 处**，不是漏网）。
- 批次推进（每批独立分支 + 门禁 + FF 合入 main）：
  批 1 地基（`AppLog` 出口 + `LogRotation` + 形状守卫）→ 批 2/3（sync、migration/DB）→
  批 4a/4b（播放引擎）→ 批 5（音频元数据/封面/歌词）→ 批 6（索引/扫描/清理）→
  批 7（服务/协调/网络）→ 批 8（Views）→ 收口批（计数口径/类别对齐/漏删/测试加固）→
  批 9（Mac/Models/root）→ 小组件扩展接入批（`Models/WidgetData.swift` + 扩展纳入日志栈）
- **进度不要在本文件里手抄数字**：唯一权威是
  `QQPlayerTests/Fixtures/structural-budget-print-baseline.tsv` 的 `# TOTAL:` 与
  `QQPlayerTests/AppLogShapeContractTests.swift` 的守卫（两者由 CI 把关）。

### 政策（用户 2026-09-20 拍板，最终版）

1. **存量 `print` 主体全部迁移**到 `AppLog`（抽样调研 89 条：迁 89% / 删 9% / 保留 2%；
   1228 处里没有一处是用户可见输出、CLI 输出或能被脚本/测试解析的 → 迁 = 无风险等量替换，删 = 删证据）。
2. **例外「保留」2 处**（不迁、不删，永不动）：`Mac/MacScanLogger.swift:68`（日志器自身写盘失败的
   兜底）、`Services/SyncConnectDiag.swift:59`（`SyncConnectDiag` 的 macOS 落点本体，现有 12 个调用点）。
3. **删除 10 处「排查完忘了撤」的零价值 print**（用户拍板「删」；数量由 maintainer 复核后从 8 订正为 10，见下）：
   **R1 冗余镜像 ×2**（`print(x)` 与 `environment.log(x)` 同变量相邻，同一消息双路重复）：
   `Services/TrackDeletionService.swift:280`、`Services/TrackDeletionService.swift:301`
   （注：抽样只报了 `:280`，`:301` 是 maintainer 复核时发现的同款；删 `print` 保留 `environment.log`）
   **R2 零载荷开发痕迹 ×6**：`Views/Playlists/PlaylistSelectionView.swift:185,198,211`（三条重复的
   `Error: ... has no ID`）、`Views/Library/BulkPlaylistSelectionView.swift:131`、
   `Views/AppCoordinator.swift:74`、`Services/AudioMetadataParser+Basic.swift:103`
   ⚠️ `AudioMetadataParser+Basic.swift:103` 在 `99-104` 的多行控制台块内 → 按第 4 条「合并为一条」处理，
   **删掉的是该行内容（`Sample Rate: Unknown`），不是单独删一行**；合并后该块 = 一次 `AppLog` 调用。
   **R3 UI 打点 ×2**：`Views/TutorialView.swift:106`、`Views/Utility/SettingsView.swift:297`
   ⚠️ **禁用「无 emoji ⇒ 删」判据**：无 emoji 的 108 行里 57 行（53%）带 `error/Failed`，删了就丢错误证据。
   ✂️ **不在删除范围**：`Views/Library/LibraryView.swift:240`（`Failed to resolve documents directory`
   是真失败路径，抽样已剔除）；`Services/InterruptionDiagnostics.swift:12` 是**陈旧注释**（声称「调用点
   的 `print()` 一直保留」但该文件已无 print 调用点）——属后续独立清理，不塞进本批。
   ⚠️ **实测补充（2026-09-21）**：政策里那条 `Views/AppCoordinator.swift:74` **本仓不存在**
   （全仓只有 `Services/AppCoordinator{,+ImportExport,+iCloud,Models}.swift`），实指
   `Services/AppCoordinator.swift:74`；批 7 曾把它**迁移**而非删除，已由收口批补删。
   `AudioMetadataParser+Basic.swift:103` 与 `TrackDeletionService` 两处已由批 5 处理。
4. **多行 print 块**（如 `AudioMetadataParser+Basic.swift:99-104` 的「标题 + 缩进明细」）**合并为一次
   `AppLog` 调用**（AppLog 把换行折叠成 `⏎`，保住「一块」语义）。
5. 切批：**按子系统、单批上限约 200 处**（批 4a/4b 播放引擎 · 5 音频元数据/封面 · 6 索引/扫描/清理 ·
   7 服务/协调/网络 · 8 Views+Mac+其它 · 9 Mac/Models/root）。
6. 门禁：**全量测试只在批尾跑一次**；批内只跑编译 + 形状契约 + 结构预算。
7. 收官：全部清零后 **print 基线 TSV 退役**（`StructuralBudgetRule` 只留行数预算）；
   同时评估把 `SyncConnectDiag` 的 macOS 落点并进 `AppLog`，让 `MacScanLogger.redirectStdout()` 退役。
8. 并行度 2 批：两批都碰 `AppLogShapeContractTests.swift` 的 `migratedChains` 与 print 基线 TSV
   → 约定「同基分支 + 只写自己那部分 + 基线一律 `emit-prints` 重出」，后合的一方 rebase 后重出。

### 计数口径（唯一口径，核数一律用它）

- **规则口径**（`StructuralBudgetRule.printCalls`，权威）：先剥掉 `//` 之后的**行尾注释**，
  再只把处于**词边界**的 `print(` 计为调用（**标识符内出现的 `print(` 不算**，如 `fileFingerprint(`）；
  扫描范围 `QQPlayer/**/*.swift`；不计 `NSLog(`。
  - **2026-09-21 修正**：旧口径是朴素子串匹配，把 `Services/LibraryIndexer.swift`(3) 与
    `Services/LibraryIndexer+Parsing.swift`(1) 的 `fileFingerprint(` 误计为「不可迁的 print」——
    后果是这 4 处永远清不掉、且这两个文件**无法登记进形状守卫**（一登记就红）。
    改为词边界后这 4 处归零，两文件已正常登记；配套 `selftest` 增了「标识符必须计 0 处」的反向案例。
- **裸 `grep -c "print("` 会偏大**：多计「注释文本里提到的 `print(`」「标识符里的 `print(`」等。
  核数一律用规则口径，别用 grep 下结论。
- 每批收紧基线**只能**用 `scripts/check-structural-budget.sh emit-prints` 重出，禁手工加减数字。
- **形状守卫**：`QQPlayerTests/AppLogShapeContractTests.swift` 静态断言
  ① 两条链路及其目录里没有 `print()`/`NSLog()`；
  ② `AppLogSink` 的实现只允许在 `AppLog.swift`；
  ③ `rotateIfNeeded`/`trimTailIfNeeded` 只允许定义在 `LogRotation.swift`，调用点白名单制。
  新增调用点必须显式改白名单（fail-closed：名单里的文件不存在 = 红）。
