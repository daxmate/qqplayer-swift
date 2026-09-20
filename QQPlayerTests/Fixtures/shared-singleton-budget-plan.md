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
| 批 2（2026-09-19，本批） | `PlaylistCoverLoadFailuresStore`、`IOSPassiveSyncCenter`、`LyricOffsetStore` | 直连棘轮 174 → **165**（真迁 12 处；preview 装配 +3）；口径收紧后再曝光既有存量 4 处 → **169**；迁移棘轮 209 → **193** | iOS 全量 + Mac 构建零警告 + target 门禁 |
| 批 3a（2026-09-19） | `MacLibraryFactsStore`（迁 `@Observable`）+ `MacSearchAnythingState`（只改注入） | 直连棘轮 169 → **158**（真迁 11 处，**0 preview 成本**）；迁移棘轮 193 → **185** | Mac 构建零警告 + 行数/print 预算 + target 门禁 |
| 批 3b（2026-09-19） | `WhatsNewStore` / `StateManager` / `MacFolderMonitor`（非 Observable 入口） | 直连棘轮 158 → **153**（真迁 5 处，0 preview 成本） | Mac 构建零警告 + 行数/print 预算 + target 门禁 |
| 批 4（2026-09-19） | `LocalDeviceNameStore` / `HybridMusicAPIService` / `LyricsSearchProvider` / `NeteaseOnlineClient`（无状态入口 → `AppServices` 容器） | 直连棘轮 153 → **141**（真迁 12 处，0 preview 成本） | iOS 全量 + Mac 构建零警告 + 行数/print 预算 + target 门禁 |
| 批 5（2026-09-19） | `LyricsManager`（**`actor`**，8 处）→ `AppServices` 容器 | 直连棘轮 141 → **133**（真迁 8 处，0 preview 成本） | iOS 全量 + Mac 构建零警告 + 行数/print 预算 + target 门禁 |
| 批 5b-1（2026-09-20） | `DesktopWindowsManager`（`ObservableObject` → `@Observable`，5 处；Mac 专属浮窗） | 直连棘轮 133 → **128**（真迁 5 处，0 preview 成本）；迁移棘轮 184/98 → **180/96** | iOS 全量 + Mac 构建零警告 + 行数/print 预算 + target 门禁 + 长文件行数净零 |
| 批 5b-2（2026-09-20） | `EQManager`（`ObservableObject` → `@Observable`，10 处 / 8 文件 / 9 个 struct） | 直连棘轮 128 → **118**（真迁 10 处，0 preview 成本）；迁移棘轮 180/96 → **164/86** | iOS 全量 1679/211 + Mac 零警告 + 预算/print 双绿 + target 门禁 + `EQManager.swift` 行数净零 |

> 批 4 合入后的**装配缺口热修**（PR #9）也已记账：组合根没装配 `@Environment(T.self)` 是**运行时**致命错，
> 编译器 / 单测 / 本棘轮**三者都看不见** ⇒ 新增 `EnvironmentInjectionContractTests`（形状契约）。
> 本棘轮只保证「没人直连」，**不保证「有人装配」**，两者是互补的两条契约。

> 批 5b-1 补的是**第三个装配点**（与 PR #9 同形状的盲区）：浮窗内容由 `NSHostingView` **手工**承载，
> **不继承 App 场景环境** ⇒ 只改组合根照样运行时崩（证据：唯一的手工 hosting 根
> `MacDesktopWindowsManager.rootView(for:)`）。于是装配点共有三个：
> ① App 场景根（`WindowGroup` / `Settings`、`#Preview` 各算自己的）· ② `#Preview` · ③ **手工 hosting 根**。
> 新增 `ManualHostingEnvironmentContractTests` 守护第三个，判据同款：**剥注释**、泛型写法（`NSHostingView<AnyView>(`）也算、
> fail-closed 自证、**且 `self` 装配必须发生在被消费类型自己身上**（否则随便一个 `.environment(self)` 就能骗绿）。

> 批 5b-2 的三条结论都**先做最小实验才动手**（`@Observable` 迁移的细节不能靠记忆）：
> ① **`@Observable` 保留 `didSet`** —— 合成探针实测：普通 `var` 与 `private(set) var` 的 `didSet` 均照常触发。
>    ⇒ `EQManager` 那 5 个「一改就下发 EQ 设置」的 `@Published` 迁成裸 `var` **不会静默丢掉**
>    `applyEQSettings()` / `saveSettings()`。**带副作用的属性是迁移前必须先验的第一件事。**
> ② **`$object.property` 绑定需 `@Bindable`** —— `@Environment(T.self)` 拿到的是普通引用，`$eqManager.isEnabled` 不再可用；
>    在用到绑定的 computed view 属性里写一行 `@Bindable var eqManager = eqManager`（配 `return`）即可，**无需回退 `@StateObject`**。
> ③ 零行为变化的做法：**只让原先 `@Published` 的属性保持被追踪**，其余存储属性（运行时 EQ 数据 / `audioEngine` / `eqNode` / `databaseManager`）
>    一律 `@ObservationIgnored` —— 它们迁移前就不发通知，迁后也不发（读它们的代码在 `loadInitialGains()` 这类 helper 里，不在 `body`）。

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

### 批 3a：实际范围与延后项（2026-09-19 实测修正）

开工盘点（真实扫描器 + 订阅方 grep 复核）**推翻了「批 3 全是叶子」的假设**，因此只做了净收益部分：

| 目标 | 站点 | 本批 | 原因 |
| --- | ---: | --- | --- |
| `MacLibraryFactsStore` | 9 | ✅ 迁 `@Observable` + 视图/浮层注入 | 无外部 `objectWillChange` 订阅；手工 `send()` ×4 随迁删除（字典就地写入走 `_modify`，按属性追踪生效）；读取面 `albumFacts(forAlbumId:)` 等直接读字典 → 追踪成立 |
| `MacSearchAnythingState` | 2 | ✅ 改注入 | 已是 `@Observable`（批 1），只差注入 |
| `SyncWiringFactsStore` / `MacLyricsResendFactsStore` | 2 | ⏸ 延后 | 唯二消费点都在 `MacSyncRunSection`，而它被 2 个 `#Preview` 覆盖 → 迁 2 处要付 4 处 preview 成本，**净亏 +2** |
| `SyncHostCenter` | 2 | ⏸ 延后 | 被 `MacSyncRunViewModel` / `MacSyncContentModel` / `MacSyncDataViewModel` 以 `center.objectWillChange` 订阅（3 处）→ 迁 `@Observable` 会**静默失效**，需先改订阅机制（属热点批） |
| `WhatsNewStore` / `MacFolderMonitor` / `StateManager` | 5 | ✅ 批 3b | 三者**都不是** Observable 对象（站点全是方法调用）→ 走批 3b 新立的 `AppServices` 容器 |

**纪律（批 3a 实测）**：分批计划里的「叶子」标签必须在开工时用真实扫描器 + 订阅方 grep 复核，
并先算清 **preview 成本**（`#Preview` 里每个 `@Environment` 对象 = +1 预算），
否则会出现「计划 −15、实际净亏」的批次。

**Mac 组合根装配（本批已定）**：`QQPlayerMacApp` 的两个场景根（`WindowGroup` + `Settings`）
各显式注入同一组对象（Settings 是独立场景、不继承主窗环境）；`MacDesktopWindowsManager` 的浮窗
是手工 `NSHostingView`、不继承场景环境，**当前两个浮窗视图（`MacMiniPlayerView` / `MacDesktopLyricView`）
未消费任何被注入对象**，故本批无需在彼处装配（将来浮窗用到时按同一清单补）。

### 批 3b：非 Observable 入口 → `AppServices` 容器（2026-09-19，用户拍板方案 A）

**问题**：`WhatsNewStore` / `StateManager` / `MacFolderMonitor` 这类 App 级对象**不是** `@Observable`
状态源（视图侧站点全是方法调用）→ `@Environment(T.self)` 不适用；而自定义 `EnvironmentKey` 的
默认值必须是真实例，等于把 `.shared` 藏进环境键（§二.3 明令禁止的绕过手法）。两条路都不通。

**决策（用户 2026-09-19 拍板 A）**：组合根提供一个 `@Observable` 服务容器
（`QQPlayer/Services/AppServices.swift`，只读 `let` 持有这些入口），视图 `@Environment(AppServices.self)` 取。

**机制边界（两类依赖、两条通道，各只有一处实现）**：

| 依赖性质 | 通道 | 判据 |
| --- | --- | --- |
| 有状态（视图读其属性，需要按属性追踪） | `@Environment(T.self)` | 类型是 `@Observable` 且视图 `body` 读它的属性 |
| 无状态 / 非 Observable 入口（视图只调方法） | `@Environment(AppServices.self)` | 视图侧站点不产生刷新需求（没有读属性） |

判据是**视图侧是否读属性**，不是「对象重不重要」——这样两条通道的归属不会出现"两边都能放"的模糊地带。

**实施**：`MacLibraryView` 5 处站点（`WhatsNewStore` 2 / `MacFolderMonitor` 2 / `StateManager` 1）
改走容器；容器与两个组合根场景根新增装配行都**不在视图层**（`Services/` + `QQPlayer/` 根）→ 不计预算。
`AppServices` 用 shared `Services/` 文件 + `#if os(macOS)` 收敛 Mac 专属成员（`folderMonitor`），
iOS 侧批 4 的同需求直接复用同一容器（不另建第二份）。

**⚠️ 迁移未覆盖**：`MacImportService.swift:44` 仍有 `StateManager.shared`——该文件是**服务**（未声明
SwiftUI View）故不在棘轮范围内，属批 7「扫描范围补洞」的欠账。

### 批 4：非 Observable 的「无状态入口」——实测完成（2026-09-19）

**机制结论（沿用批 3b 方案 A，未自创第三条道）**：这批 4 个对象在视图侧全是**方法调用或一次性取值**
（`searchArtist` / `search` / `name` 读一次 / `setName`），不产生按属性追踪需求 → 判据命中「无状态入口」
→ 一律走 `AppServices` 容器，不给它们开 `@Environment(T.self)`（它们本就不是 `@Observable`）。

**实测（真实扫描器逐站点表，开工时复核）**：

| 对象 | 站点 | 处置 |
| --- | ---: | --- |
| `HybridMusicAPIService` | 4 | `ArtistDetailScreen`：删 `@StateObject private var hybridAPI = …shared`（**该属性除声明外零引用 = 死代码**），3 处方法调用改 `services.hybridMusicAPI.*` |
| `LocalDeviceNameStore` | 4 | `SyncSettingsView` 2 处 + `SyncQRScannerView` 1 处改 `services.localDeviceName.name`；`SyncDeviceNameEditorView` 的 `store: = .shared` **默认参数改必传**（生产调用方从容器取，`#Preview` 自建实例） |
| `NeteaseOnlineClient` | 2 | `MacOnlineSearchView` / `MacSearchAnythingLayer` 各 1 处改 `services.neteaseOnlineClient.search` |
| `LyricsSearchProvider` | 2 | `LyricsSearchView`（iOS）/ `MacLyricsSearchView` 各 1 处改 `services.lyricsSearchProvider.search` |

**刷新路径核对（§四.2）**：四个对象都**不是**观测源——视图侧读的只有 `LocalDeviceNameStore.name` 这一次性取值，
且它落进 `@State deviceName`（`onAppear` / 保存回调刷新），迁移前后刷新时机逐字一致；
其余三者的返回值本身就落 `@State`（`results` / `onlineSongs` / `unifiedArtist`）。
**无跨对象 `objectWillChange` 订阅、无 Combine publisher 消费点** → 不存在「迁移后不刷新」的静默坑。

**行数预算（§5.4 照抄做法）**：`MacOnlineSearchView`（751，基线内）与 `MacSearchAnythingLayer`（727，基线内）
各需 +1 行注入属性、余量为 0 → 各合并一条既有注释让出等量行（751=751 / 727=727）；
`SyncQRScannerView` 599 → **600**（阈值 `> 600`，未入基线，仍未越线）。
**本批 0 处 preview 成本**：涉及视图中只有 `SyncDeviceNameEditorView` 有 `#Preview`，它自建实例（不引用 `.shared`，不计预算）。

**延后项不变**：`SyncHostCenter`（订阅机制）、`SyncWiringFactsStore` / `MacLyricsResendFactsStore`（preview 成本净亏）
未见批 4 顺手解决，仍按批 3a 结论挂在后续批次。

### 批 5：中频对象（两端共享 Services）

#### 批 5a：`LyricsManager` —— 实测完成（2026-09-19）
8 处站点全在视图层（`LyricsSearchView` 3 · `MacLyricsSearchView` 3 · `PlayerView` 1 · `MacPlayerView` 1），
**全部是 `await LyricsManager.shared.<method>(…)` 方法调用**（`getLyrics` / `hasManualLyrics` / `apply` /
`clearManualLyrics`），无属性读、无 `objectWillChange` 订阅 ⇒ 与批 4 同款**容器通道**。

- **判据关键**：`LyricsManager` 声明为 **`actor`**（不是 `ObservableObject`）—— 天然无「按属性追踪」语义，
  不存在迁 `@Observable` 时的静默失效风险，这是它比同批其余对象都干净的原因。
- **预算**：真迁 8 处 / 0 preview 成本 / 棘轮 141 → **133**。
- **行数棘轮的交互（实测）**：`PlayerView`(985) 与 `MacPlayerView`(617) 都在**行数基线内且零余量**，
  两个文件都要新增 `@Environment(AppServices.self)`（+1 行）⇒ 各合并一处既有两行注释让出等量行，**净零**。
  ⚠️ **再记一次同一个坑：`///` 文档注释 + 声明 = +2 行，不是 +1**（首改就把两个文件各顶超 1 行，被
  `check-structural-budget.sh` 当场抓住）；按批 4 风格改裸声明（「为什么」写在 `AppServices.swift` 容器里）。
  `LyricsSearchView`(418) / `MacLyricsSearchView`(350) 不在超长区间内，无此约束。

#### 批 5b：其余中频对象（**开工前必须逐条判刷新语义**，侦察已完成 2026-09-19）
| 对象 | 处数 | 站点形态 | 结论 |
| --- | ---: | --- | --- |
| `SFBAudioEngineManager` | 4 | `if SFBAudioEngineManager.shared.isCarPlayEnvironment {…}` | ⚠️ 该属性是 **`@Published`** → 先定「视图是否需要刷新追踪」；要追踪则只能 `@Environment(T.self)` + 迁 `@Observable` |
| `MacSpectrumAnalyzer` | 5 | `.onReceive(MacSpectrumAnalyzer.shared.$isActive/.$levels)` | ❌ **Combine 订阅** → 迁 `@Observable` 会静默失效，需先改 `withObservationTracking`/回调 |
| `EQManager` | 10 | 全是 `@StateObject … = EQManager.shared` | ⚠️ 需观察迁移（视图读 EQ 曲线/预设） |
| `DesktopWindowsManager` | 5 | `@ObservedObject … = .shared` + 方法调用 | ⚠️ 需观察迁移（Mac 专属） |
| `LibraryIndexer` | 3 | `@StateObject … = .shared` ×2 + 1 方法调用 | ⚠️ 需观察迁移 |

- 每迁一个对象**单独跑一次全量**（不合并成一批大 diff）；迁 `@Observable` 前必做：
  `grep -rn '<Type>' --include='*.swift' | grep -E 'objectWillChange|\.\$'` 找订阅方。
- 预估剩余：−27 处（不含批 6 的四个热点 −87）。

##### 批 5b-1：`DesktopWindowsManager` —— 实测完成（2026-09-20）

上表五个里最干净的一个（Mac 专属 · 1 个视图可见属性 · 无 Combine 订阅 · 无 `objectWillChange` 订阅）
⇒ 用它把「观察迁移 + 环境注入」流程跑通，后四个照抄：

- **迁移**：`ObservableObject` → `@Observable`；`@Published` → 裸 `private(set) var`；非 UI 状态的
  存储属性（面板句柄 / 观察者 token / 模式状态机 / `didStart`）一律 `@ObservationIgnored`（避免无意义失效）。
- **装配点有两个（本批最大收获）**：App 场景根（WindowGroup + Settings **各一行**）**以及**管理器自己构造
  浮窗时的 `rootView(for:)`（`.environment(self)`）—— 手工 `NSHostingView` 不继承场景环境，
  漏掉后者 = **进迷你模式即运行时致命错**。
- **前置 `grep` 实测**：`grep -rn 'DesktopWindowsManager' | grep -E 'objectWillChange|\.\$'` → **0 处订阅**，
  故迁 `@Observable` 无静默失效风险（对照 `MacSpectrumAnalyzer` / `LibraryIndexer` 各有订阅，仍挂在表上）。
- **行数预算**：`MacLibraryView`(825) 零余量 ⇒ 新增「注释 + 属性」2 行靠合并**两组**既有注释对让出 2 行，净零 825。
- **基线**：直连 133 → 128；迁移 184/98 → 180/96（一批同动两条棘轮，属预期；「已清零行」报红是设计如此）。

##### 批 5b-2：`EQManager` —— 实测完成（2026-09-20）

本批面最大（10 处 / 8 文件 / 9 个 struct），而且踩到两个「和上一批不同」的点，都靠**先做最小实验**解决：

- **① 带 `didSet` 的 `@Published` 是迁移的最大风险点**：`EQManager` 的 5 个 `@Published` 全都带副作用
  （`applyEQSettings()` / `saveSettings()`）—— 若 `@Observable` 丢掉属性观察器，就是**静默行为丢失**
  （EQ 设置永不下发）。合成探针实测：**`@Observable` 完整保留 `didSet`**（普通 `var` 与 `private(set) var` 均触发）
  ⇒ 迁成裸 `var` 语义不变。
- **② `$eqManager.isEnabled` 绑定需 `@Bindable`**：4 处（2 个 Toggle + 2 个 Slider，分布在 3 个 `some View` computed 属性里）
  ⇒ 各写一行局部 `@Bindable var eqManager = eqManager`（配 `return`），**不回退 `@StateObject`**。
- **③ 刷新时机守零变化**：只让原 `@Published` 的 5 个属性保持被追踪；`eqFrequencies/eqGains/eqBandwidths`
  （运行时数据，经 `currentEQGains` 等 getter 读）、`databaseManager`、`audioEngine`、`eqNode` 全 `@ObservationIgnored`
  —— 读它们的唯一视图位置是 `loadInitialGains()`（helper，不在 `body`）。
- **装配点**：iOS 组合根（单一 `WindowGroup`）+ Mac 组合根（`WindowGroup` / `Settings`）各登记 1 行；
  两处都被 `EnvironmentInjectionContractTests` 判绿（这是首例「**两端**同时新增同一对象装配」的批次）。
- **行数预算**：`EQManager.swift`(618) 零余量 ⇒ 压缩 6 行文件头为 4 行让出 2 行（`import Observation` + `@Observable`），净零 618。
- **基线**：直连 128 → 118（7 文件归零删行；`EQSettingsView` 2→1，残留那处是 `UIApplication.shared` —— 系统单例，非债）；
  迁移 180/96 → 164/86（删 1 个 `ObservableObject` + 5 个 `@Published` + 10 处 `@StateObject`）。
- **本批 0 处 preview 成本**：8 个文件均无 `#Preview`。

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
暴露既有存量 4 处（`MacSyncView` 3 / `SyncDeviceNameEditorView` 1）。
**这 4 处本批一处未迁**（MacSyncView 的 `hostCenter` 默认值属热点 `SyncHostCenter`；其余三处需 Mac 链装配，见批 3；
`LocalDeviceNameStore` 的默认参数属非 Observable 读取器，见批 4）——它们已如实计入 169 的预算，不属"看不看得见"问题。

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

### 5.4 与结构预算棘轮的冲突（批 2 实测）
结构预算棘轮（`structural-budget-size-baseline.tsv`）对 **>600 行的文件**规定「只能减不能增」，
于是**迁移本身**就会顶破预算——任何对象迁 `@Observable` 至少要 +2 行（`import Observation`、
`@Observable` 属性行），长文件里再多写一行说明就超。批 2 首版实测：`IOSPassiveSyncCenter.swift`
981 → 990，被行数预算拦下。

处置（已落地，可照抄）：
1. **长文件里不写迁移说明**——迁移理由一律记在本账本 + 提交信息，源文件只留代码（本批因预算为零，
   `IOSPassiveSyncCenter` 的类文档保持原样，一行注释都没加）；
2. **让出等量行数**（无损清理优先）：本批删掉该文件里早已不用的 `import UIKit`、
   把 `defaultClientName` 的 4 行文档合并为 3 行 → 981 = 981，TOTAL 25046 不涨。

纪律：**动 >600 行文件前先算预算余量**（`scripts/check-structural-budget.sh check`）。
余量为 0 而迁移必须 +2 时，要么让出等量行，要么先拆文件（属结构清债批次），
**不要**改基线放行（`emit` 只允许收紧后替换）。

**批 3a 补充（每文件余量为 0 时的两种做法）**：
- `MacLibraryView.swift`（825 行，在基线内）需要**新增** 1 行 `@Environment(MacLibraryFactsStore.self)` 属性，
  余量为 0 → 把原有 3 行注释合并为 2 行让出 1 行（825 = 825）；
- `MacSearchAnythingLayer.swift`（727 行，在基线内）→ 迁移只做 **1:1 行替换**，一行说明都不加。

### 5.5 批 2 的「刷新路径核对」（长文件那份搬到这里）
§四.2 要求逐对象写出「迁移前 vs 迁移后」的刷新对照，但 `IOSPassiveSyncCenter.swift` 受行数预算
约束（§5.4），说明不能内联在源文件里 → 按 §5.4 口径记在此处：

- **`IOSPassiveSyncCenter`**（唯一边界：`IOSPassiveSyncCenter.swift`）
  - 迁移前：视图 `@ObservedObject … = .shared`，靠整对象 `objectWillChange` 失效 → 全量重算；
  - 迁移后：`@Observable` 按属性追踪。视图读的 4 个存储属性
    （`state` / `summary` / `dataSummary` / `pairedHostCount`）全部在设置页 `body` 可达路径上
    （状态行 / 数据区 / 已配对主机行）→ 刷新行为不变；
  - 无跨对象 `objectWillChange` 订阅、无 Combine publisher 消费点（它订阅的是 `LibraryIndexer`，不是自己）
    → 无「迁移后不刷新」的静默坑。
- **`PlaylistCoverLoadFailuresStore`**（消费点 `PlaylistDetailScreen` / `PlaylistCardView` / `SyncSettingsView`）
  - 唯一存储属性 `failures` 只被 `body` 可达路径读（卡片/详情/设置页行）→ 刷新行为不变；
  - 完整说明保留在 `PlaylistCoverLoadFailuresStore.swift` 文件头（该文件 <600 行，不受预算约束）；
    `PlaylistDetailScreen.swift`（640 行，受约束）内的那行重复说明已撒回。
- **`LyricOffsetStore`**（消费点 `SettingsView`）：后 4 个存储属性全在设置页 `body` 可达路径（行文案 + Slider 绑定）；
  路由变化由 `AVAudioSession.routeChangeNotification` 驱动写入，机制未变。
