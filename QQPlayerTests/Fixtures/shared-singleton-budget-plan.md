# 视图层单例收口「下降预算」分批计划

**立项（2026-09-19）**：视图层直连单例（`<Type>.shared`）与 `@Observable` 迁移两条棘轮此前
只有**上限**、没有**下调机制**——`ViewSharedSingletonContractTests` 断言总数 ≤ 174、
`ObservationMigrationContractTests` 断言各标记 ≤ 基线，但没人规定"下一批迁哪个、迁完降到多少"。
后果：棘轮只能防止变差，永远不变好，174 与基线会长期原地不动。

本文件是**预算账本 + 批次计划**：每迁完一批，上限下调到当前实际值（收紧，不是放宽），
并在批次表里留下"迁了什么 / 从 X 降到 Y"的可核对记录。

> 棘轮本身（测试 + 基线 TSV）仍是唯一执行者：本文件只描述**计划与账目**，
> 任何"计划迁了但基线没降"的批次都算未完成（测试的"名单不腐烂"契约会替我们盯着）。

---

## 一、现状盘点（2026-09-19，卡在 HEAD `625ae43`）

**口径**（与 `ViewSharedSingletonContractTests` 逐字一致）：视图层 = `QQPlayer/Views/**` 全部
+ `QQPlayer/Mac/**` 中声明了 SwiftUI View（`: View` / `some View`）的文件；只算代码行
（`//` 之后剥离），粒度为 `<Type>.shared` 的出现次数。

- **174 处 / 48 个视图文件 / 29 个对象**
- 其中 **11 处是 Apple 的系统单例**（`UIApplication` 4 / `WidgetCenter` 3 / `URLSession` 2 /
  `NSWorkspace` 2）——**不可迁移**，它们是系统入口，不是我们的生命周期问题。
  故**可迁预算 = 174 − 11 = 163 处**（后续账目以可迁数为准，总数仍以 174 口径记）。

### 1.1 按对象归组（可迁数降序）

| 对象 | 处数 | 文件数 | 类别 | 备注 |
| --- | ---: | ---: | --- | --- |
| `PlayerEngine` | 24 | 17 | 热点 | 播放核心，最后迁 |
| `ArtworkManager` | 23 | 14 | 热点 | 封面解析，最后迁 |
| `KaraokeController` | 23 | 7 | 热点 | 卡拉OK 状态，最后迁 |
| `AppCoordinator` | 17 | 8 | 热点 | App 级容器，最后迁 |
| `EQManager` | 10 | 8 | 中频 | 两端都用（共享 Services） |
| `PlaylistCoverLoadFailuresStore` | 10 | 3 | 叶子（账目） | **批 2** |
| `MacLibraryFactsStore` | 9 | 4 | 叶子（账目） | 批 3 |
| `LyricsManager` | 8 | 4 | 中频 | 两端都用 |
| `DesktopWindowsManager` | 5 | 2 | 中频 | Mac 专属 |
| `MacSpectrumAnalyzer` | 5 | 2 | 中频 | Mac 专属 |
| `SFBAudioEngineManager` | 4 | 4 | 中频 | 音频引擎门面 |
| `HybridMusicAPIService` | 4 | 1 | 叶子（无状态入口） | 批 4（需非 Observable 注入机制） |
| `LibraryIndexer` | 3 | 3 | 中频 | 索引状态源 |
| `LocalDeviceNameStore` | 3 | 2 | 叶子（无状态读取器） | 批 4（同上） |
| `MacSearchAnythingState` | 2 | 2 | 叶子 | 批 3（已是 @Observable，仅剩注入） |
| `WhatsNewStore` | 2 | 1 | 叶子 | 批 3 |
| `MacFolderMonitor` | 2 | 1 | 叶子 | 批 3 |
| `LyricsSearchProvider` | 2 | 2 | 叶子（无状态） | 批 4 |
| `NeteaseOnlineClient` | 2 | 2 | 叶子（无状态客户端） | 批 4 |
| `StateManager` | 1 | 1 | 叶子 | 批 3 |
| `SyncHostCenter` | 1 | 1 | 中频 | 批 3（与 Mac facts 家族同批） |
| `LyricOffsetStore` | 1 | 1 | 叶子 | **批 2** |
| `IOSPassiveSyncCenter` | 1 | 1 | 叶子（iOS-only） | **批 2** |
| `SyncWiringFactsStore` | 1 | 1 | 叶子（账目） | 批 3（Mac 侧同批） |

### 1.2 剩余文件热点（Top 10，迁移顺序的反面清单）

| 文件 | 处数 | 主要对象 |
| --- | ---: | --- |
| `QQPlayer/Mac/MacLibraryView.swift` | 13 | PlayerEngine×2, WhatsNewStore×2, MacFolderMonitor×2, MacLibraryFactsStore×2 … |
| `QQPlayer/Mac/MacPlayerView.swift` | 13 | KaraokeController×5, AppCoordinator×3, ArtworkManager×2 … |
| `QQPlayer/Views/Player/PlayerView.swift` | 9 | KaraokeController×6, PlayerEngine, ArtworkManager, LyricsManager |
| `QQPlayer/Views/Playlists/PlaylistDetailScreen.swift` | 9 → **4** | PlaylistCoverLoadFailuresStore（批 2 已迁 ×5）… |
| `QQPlayer/Mac/MacTrackListView.swift` | 8 | AppCoordinator×6, MacLibraryFactsStore, PlayerEngine |
| `QQPlayer/Views/Artists/ArtistDetailScreen.swift` | 8 | HybridMusicAPIService×4（无状态客户端）… |
| `QQPlayer/Mac/MacDesktopWindowViews.swift` | 7 | DesktopWindowsManager×4, PlayerEngine×2 |
| `QQPlayer/Views/Playlists/PlaylistCardView.swift` | 7 → **3** | PlaylistCoverLoadFailuresStore（批 2 已迁 ×4）… |
| `QQPlayer/Views/Player/KaraokeControlBar.swift` | 5 | KaraokeController×3, PlayerEngine×2 |
| `QQPlayer/Views/Utility/SyncSettingsView.swift` | 5 | LocalDeviceNameStore×2, IOSPassiveSyncCenter, SyncWiringFactsStore, PlaylistCoverLoadFailuresStore |

**热点集中度**：`PlayerEngine + ArtworkManager + KaraokeController + AppCoordinator`
= 87 处 / 174 ≈ **50%**，涉及 21 个视图文件 —— 这四类必须放最后（它们一动，
iOS/Mac 两端 + CarPlay + 锁屏/Control Center 的刷新路径都要重新核对）。

---

## 二、「下降预算」机制（三条纪律）

1. **上限只降不升**：每批迁移完成后，把 `QQPlayerTests/Fixtures/shared-singleton-baseline.tsv`
   的 `# TOTAL` 与该批涉及文件的行值**下调到当前实测值**（合同测试的"名单不腐烂"契约
   会在忘了改时直接红——机制上不可漏）。
2. **口径只紧不松**：`@Observable` 迁移棘轮（`observation-migration-baseline.tsv`）同批同步；
   扫描器自身的**盲区只能收紧**（见 §五.1：前导点 `.shared` 简写已补进检测）。
3. **每批必须真迁移**：`@Observable` + `@State`/`@Environment` 注入，行为零变化。
   禁止两种"变绿"手法：
   - ✗ 换写法绕过扫描（`Foo.shared` → `.shared` 简写、把直连塞进默认参数/环境键默认值）；
   - ✗ 删掉 `.shared` 使用点但把状态藏在别处（例如视图自己新建实例、把账目挪进 `@State`）。
   判据：**同类问题发生面变小了，还是只是被盖住了**——盖住 = 补丁，变小 = 收口。

### 2.1 批次账本

| 批次 | 对象 | 结果（上限 X → Y） | 验证 |
| --- | --- | --- | --- |
| 批 1（2026-09-18，历史） | `TutorialViewModel`、`MacSearchAnythingState`（迁移棘轮 213 → 209） | 迁移棘轮 213 → 209 | iOS 全量 1627 绿 + Mac 构建零警告 |
| 批 2（2026-09-19，本批） | `PlaylistCoverLoadFailuresStore`、`IOSPassiveSyncCenter`、`LyricOffsetStore` | 直连棘轮 174 → **165**（真迁 12 处；preview 装配 +3）；口径收紧后再曝光既有存量 4 处 → **169**；迁移棘轮 209 → **195** | iOS 全量 + Mac 构建零警告 + target 门禁 |

> 批 2 的两个数字要说清：**口径收紧（前导点简写）与真迁移是两个方向的动作**——
> 前者让 4 处此前看不见的既有直连显形（`MacSyncView` 3 / `SyncDeviceNameEditorView` 1），
> 所以账本必须同时记"真迁多少"和"口径变了多少"，否则数字会骗人。

---

## 三、分批计划（叶子先动、热点最后）

排序口径：**对象是否被视图观察（@Observable 可迁） × 消费点数量 × 是否跨端共享**。
叶子 = 单文件定义、状态属性少、消费点集中在少数视图、无跨对象订阅。

### 批 3：Mac 侧「账目 store」家族 + 组合根装配（Mac 面）
目标：`SyncWiringFactsStore`（1 iOS + 3 Mac 处，含 2 处简写）、`MacLyricsResendFactsStore`、
`MacSearchAnythingState`（已是 @Observable，只差注入）、`MacLibraryFactsStore`（9 处）、
`WhatsNewStore`、`MacFolderMonitor`、`StateManager`、`SyncHostCenter`（1 处）。
- **前置**：Mac 组合根装配点（`QQPlayerMacApp` 的 `WindowGroup` + `Settings` 两个 scene 根，
  以及 `MacDesktopWindowsManager` 的手工 `NSHostingView` 浮窗根）必须一次性定好注入清单——
  浮窗不继承 App 场景环境（`MacDesktopWindowsManager.swift` 已有同因注释）；
- **同时处理**：`MacSyncView` 的 `#Preview` 装配（preview 是组合根之外的第二个合法装配点，
  见 §五.2 的预算成本）；
- 预估：−15 处左右（含 2 处简写）。

### 批 4：非 Observable 的「无状态入口」（需要注入机制决策）
目标：`LocalDeviceNameStore`（3 处 + `SyncDeviceNameEditorView` 的 `= .shared` 默认参数）、
`HybridMusicAPIService`（4 处）、`LyricsSearchProvider`（2 处）、`NeteaseOnlineClient`（2 处）。
- **前置（本批真正的决策项）**：这类对象**不是** `@Observable` 状态源，`@Environment(T.self)`
  不适用，需要在两种机制里拍板：
  1. 自定义 `EnvironmentKey` + 默认值 —— 默认值必须**不能**是 `.shared`（否则就是把直连
     藏进环境键，属 §二.3 禁止的"换写法绕过"）；
  2. 组合根暴露一个 App 级服务容器对象（`@Observable`，只读持有这些无状态入口），
     视图 `@Environment(AppServices.self)` 取——代价是引入一层容器。
- 预估：−11 处。

### 批 5：中频对象（两端共享 Services）
目标：`EQManager`（10）、`LyricsManager`（8）、`SFBAudioEngineManager`（4）、
`LibraryIndexer`（3）、`DesktopWindowsManager`（5）、`MacSpectrumAnalyzer`（5）。
- 这些对象**跨端共享且有实时刷新语义**（EQ 曲线 / 歌词行 / 频谱），迁移前必须逐条核对
  "谁在订阅 `objectWillChange`"（`MacSyncRunViewModel` 那种 `center.objectWillChange` 用法
  在 @Observable 下会失效，需改成 `withObservationTracking` 或显式回调）；
- 每迁一个对象单独跑一次全量（不合并成一批大 diff）。
- 预估：−35 处。

### 批 6+：四个热点（最后）
`AppCoordinator`（17）、`PlayerEngine`（24）、`KaraokeController`（23）、`ArtworkManager`（23）。
- 前置：先补齐"组合根 + 环境注入"在 **CarPlay 场景 / 锁屏与控制中心 / Widget 扩展** 三条
  非 SwiftUI App 场景根上的取值路径（这些场景不在 `WindowGroup` 环境链上）；
- 这四类一动，涉及 21 个视图文件 + 跨端行为一致性，必须分批、每批真机验收。
- 预估：−87 处（可迁预算清零）。

### 批 7：扫描范围补洞（收尾）
把 `QQPlayer/` 根目录下的**真实视图文件**纳入扫描（现在 `QQPlayer/ContentView.swift`、
`QQPlayer/CarPlay+PlayerPage.swift` 等不在 `Views/**` 也不在 `Mac/**`，`ContentView` 里
`@StateObject private var libraryIndexer = LibraryIndexer.shared` 这类直连**完全没被计数**）。
- 需要先测出这些文件的实际存量，再一次性并进 TOTAL（属"口径收紧"，账本同样要记账）。

---

## 四、每批验收清单（不可省项）

1. **真迁移**：`ObservableObject` → `@Observable`（去掉 `@Published`），视图改
   `@Environment(T.self)`；App 组合根（`QQPlayer/QQPlayerApp.swift` / Mac 两个 scene 根）
   显式 `.environment(...)` 注入唯一实例。
2. **刷新路径逐条核对**：写出"迁移前靠整对象失效、迁移后靠按属性追踪"的对照，
   确认被读属性都在 `body` 可达路径上（不能有"读非存储属性导致不刷新"的静默坑）。
3. **全量测试**：iOS `xcodebuild test -scheme QQPlayer -only-testing:QQPlayerTests` 全绿
   （含两条棘轮契约）。
4. **Mac 零警告**：`xcodebuild build -scheme QQPlayerMac -configuration Debug`，
   按 CI 同一口径过筛（源码警告 + target 级警告零容忍）。
5. **target 成员归属门禁**：`python3 scripts/check-target-membership.py --files <改到的文件>`
   （共享 Services 文件被 Mac 用必须登记 Mac 白名单；iOS-only 文件头必须 `// target: ios-only`）。
6. **基线随批下调**：两条基线 TSV 同步（`# TOTAL` + 行值），提交信息写明"迁了哪几个、上限 X → Y"。
7. **UI 由用户真机验收**：不做模拟器视觉验证（纪律：用户在电脑前时功能/UI 验证交用户）。

---

## 五、已知盲区与欠账（下一步的输入，不是免责声明）

### 5.1 前导点简写盲区（本批已修）
原扫描器正则 `[A-Za-z_]+\.shared` **要求点号前有标识符**，于是下面这种写法完全不计入：

```swift
store: LocalDeviceNameStore = .shared          // SyncDeviceNameEditorView.swift:39
_wiringFacts = ObservedObject(wrappedValue: .shared)   // MacSyncView.swift:74
let center = hostCenter ?? .shared                     // MacSyncView.swift:68
```

即"把直连换个写法就能压低上限"。批 2 已把 `.shared` 简写并入检测（含自证用例），
暴露既有存量 4 处（`MacSyncView` 3 / `SyncDeviceNameEditorView` 1），其中 2 处随批 3 迁移。

### 5.2 `#Preview` 装配点的预算成本
视图的 `@Environment(T.self)` 一旦上收，`#Preview` 也必须显式装配，而 preview 只能拿真实实例
（store 是 `private init` 的单例）→ **每处 preview 注入 = 预算 +1**。批 2 因此付出 3 处
（`SyncSettingsView` +2 / `SettingsView` +1）。

两条路留给后续批次，本批不做：
- (a) 组合根 helper（`.appEnvironment()` 之类）——但任何返回 `some View` 的 helper 会让所在
  文件被判定为"视图文件"而进入扫描范围，需要先明确"组合根文件不算视图层"的判定规则；
- (b) 扫描口径把 `#Preview` 块排除（**属放宽，须先把当前 preview 内的存量单独记账**，
  不能变成"数字变小的免费午餐"）。

### 5.3 系统单例不是债
`UIApplication` / `WidgetCenter` / `URLSession` / `NSWorkspace` 共 11 处，永远留在基线里，
账本按"可迁预算 163"看进度，而不是把 174 当成 100%。
