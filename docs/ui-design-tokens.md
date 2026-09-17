# macOS / iOS UI 设计令牌 · L0 契约表（QQPlayer-swift）

- 日期：2026-09-15 · 状态：**已拍板（用户 22:48：几何令牌做、B1→B2→B3 全做）**
- 范围：**macOS `QQPlayer/Mac/**` + iOS `QQPlayer/Views/**`**。Web 端各自成文，见 `qqplayer/docs/ui-design-tokens.md`。
- 起源：同步子系统「反屎山」（同一语义多处手工维护 → 唯一入口 + 形状测试）推广到 UI 层。

## 0. 前提（用户已拍板）

1. **macOS / iOS 配色不必与 Web 一致**（苹果自有风格）⇒ **不做跨端色值对拍测试**；每端内部唯一入口即可。
   - 追加（2026-09-17）：**字段名唯一、色表按端独立**——「当前跟的是哪一套配色」在两端是**同一个设置语义** ⇒ 共享同一字段
     `DeleteSettings.accentColorName`（token 名，iOS 8 色 / macOS 6 色各自解析）；**不做** token→色值的跨端对拍（承本条）。见 §3 A1。
2. **C3–C5 语义状态色（危险/成功/警告）不在 Apple 端做自造令牌**。理由（本轮取证）：
   - 现状已统一在 Apple 系统语义色：`role: .destructive` 34 处、`.red` 34 处、`.green` 14 处、`.orange` 15 处；
   - 自造颜色字面量全仓仅 3 处，且都是**品牌色**（`MacLyricsSearchView.swift:303` / `Views/Player/LyricsSearchView.swift:355` 网易云品牌红、`Models/SettingsModels.swift:97` 灰色）——不是语义状态色；
   - Apple 系统语义色自带明暗自适应、增强对比度/色彩滤镜等无障碍适配；自造令牌会丢掉这些能力，还会引入**第三份颜色来源**。
   - ⇒ 契约表登记为「已达标」，仅保留一句「新增删除类控件用 `role: .destructive`」的约定。
3. 判据：改完后同类问题的**发生面变小（收口）**，不是被盖住（补丁）。

## 1. 结论一句话

强调色的**名单是唯一的**（`MacAppearance.accentPresets` / iOS `IOSAppearance`），问题在**传递机制**：macOS 有第二注入路径（桌面歌词/迷你窗）、iOS 根本没有环境值（148 处直读 + 18 处 prop 透传）；另有一个**已修复缺陷在新代码里复发**（MacSyncView 3 处 `Color.accentColor`，现网可见）；几何/排版**完全没有令牌**。

## 2. L0 契约表

| # | 语义角色 | macOS 现状 | iOS 现状 | 目标唯一入口 | 缺口 |
|---|---|---|---|---|---|
| C1 | 强调色主值 | `MacAppearance.accentPresets`（6 预设）+ `.environment(\.appAccentColor)` 注入 ✅，18 文件消费 | `IOSAppearance` 名单（8 色，violet `b11491` 默认）✅，但**传递两套** | macOS：`appAccentColor` 环境值；iOS：**新建同名环境值** | **M1 / M2 / I1**（字段层 2026-09-17 已收口，见 A1） |
| C2 | 强调色衍生 | 无令牌，各写 `.opacity(x)` | 同 macOS | 需要时补派生函数（低优先） | — |
| C3–C5 | 危险/成功/警告 | 系统语义色 ✅（**不做自造令牌**，见 §0.2） | 同 macOS | 保持系统语义色 | 已达标 |
| C6–C9 | 中性面/文字/描边/阴影 | 系统语义色 ✅ | 同 | 保持 | — |
| C10 | 圆角 | ✅ 令牌化（B2a）+ **归一（B2b）：11 种 / 152 处** | 同（同一张令牌表） | `DesignTokens.radius*` | M4（B2a ✅ / B2b ✅ 2026-09-16） |
| C11 | 间距 | ✅ 令牌化（B2c-a）：`DesignTokens.space*`（**33 种 / 829 处**，按值命名；padding 376 / spacing 434 / Spacer.minLength 19） | 同（同一张令牌表） | `DesignTokens.space*` | M4（B2c-a ✅ 零视觉变化；归一 B2c-b 待拍板） |
| C12 | 字号 | ✅ 令牌化（B2a）+ **归一（B2b）：24 种 / 116 处**（小数档已清零） | 同（同一张令牌表） | `DesignTokens.font*` | M4（B2a ✅ / B2b ✅ 2026-09-16） |
| C13 | 主题解析 | 三态 `appearanceTheme` → `MacAppearance.apply(theme:)`（NSApp.appearance）✅ | `forceDarkMode` + `AppearanceTheme.resolved`（含旧数据迁移）✅ | **各自保持**（不统一，用户已定） | — |
| C14 | 强调色传递 | 环境值 ✅ + **桌面窗/迷你窗第二路径** ⚠️ | **无环境值**：直读 settings 148 处 + prop 透传 18 处 ❌ | macOS：环境值 + 单一刷新点；iOS：新建环境值 | **M2 / I1** |
| C15 | 第二窗口注入 | `MacDesktopWindowsManager` 自读 settings 再转色 | — | 与主窗同源 | M2 |
| C16 | hex→Color 解析 | 两套：`MacAppearance.color(hex:)`（私有）+ `Views/Player/PlayerProgressViews.swift:50 init(hex:)` | 同 | 唯一工具 | **M3** |

## 3. 缺口清单

### M1 · 已修复缺陷在新代码里复发（**现网可见 bug**，B1）✅ 已收口（2026-09-15）
- 证据：2026-09-05 `35c7b99` 把 22 处 `Color.accentColor` 换成自定义环境值 `appAccentColor`（原因见 `MacAppearance.swift:50-53`：macOS 上 `Color.accentColor` 跟系统强调色、不跟 App tint）。**2026-09-11 新增的 `MacSyncView.swift:227/241/356` 又出现 3 处 `Color.accentColor`**（同步页方向选择卡选中态）。
- 可见条件：用户系统强调色与 App 强调色不同时才看得见。
- 复发机制：**干净上下文分包 = 结构性失忆机**——新包不知道已有唯一入口（UI 层复现同步那次的形状）。
- 收口：3 处改 `@Environment(\.appAccentColor)`。
- **实施记录（实测比清单多 3 处同类点）**：`MacSyncCenterView.swift:182/192/211`（2026-09-12 `3e88c19` 新增设备区时同样复发）一并改掉 → `QQPlayer/Mac/**` 代码内 `.accentColor` 归零。
- 测试：静态扫描禁 `QQPlayer/Mac/**` 出现 `Color.accentColor`，白名单只留 `MacAppearance.swift`（环境值 `defaultValue`）与 `QQPlayerMacApp.swift`（注入点）。
  - ⚠️ **实施偏差**：环境值定义连同 `defaultValue` 一起移到了共享文件 `Models/AppearanceTheme.swift`（iOS 也要用同一环境值名，不能定义在 Mac 专属文件里）；`QQPlayerMacApp.swift` 代码里只有注释出现该字样 → 若把它列入白名单会因「白名单必须命中真实源码」的用例转红。故白名单实为 1 条：`Models/AppearanceTheme.swift` 的 `static let defaultValue: Color = .accentColor`（该文件已纳入扫描范围）。

### M2 · 桌面歌词 / 迷你窗走第二条注入路径（B1）✅ 已收口（2026-09-15）
- 证据：`MacDesktopWindowsManager.swift:79/145/200` 自读 `DeleteSettings.load().accentColorName` → `MacAppearance.accentColor(forKey:)` 再注入，与主窗环境值并行，刷新点也是两处。
- 历史复发：曾出现「迷你窗不跟随强调色」（memory 2026-09-05）。
- 收口：把「当前强调色」收成**一处读取 + 一处刷新通知**，两个窗口注入都从它取（不改视觉）。
- **实施记录（未动窗口生命周期/通知机制，在范围内）**：`MacAppearance` 新增唯一读取入口 `currentAccentKey` / `currentAccentColor`；`DesktopWindowsManager`（3 处自读）与 `MacVisualizerView`（2 处自读，清单外同类点）全部改从该入口取；刷新点仍唯一（`.qqplayerSettingsDidChange` → `reconcile()` → `refreshPanelRootViews()`）。`QQPlayerMacApp` 主窗/设置窗注入也改从同一入口取。桌面歌词窗不消费强调色（只用白色文字），无需注入（实测）。
- 测试：形状断言「桌面窗注入点唯一」。

### M3 · 两套 hex 解析（B1）✅ 已收口（2026-09-15）
- 证据：`MacAppearance.swift:42 private static func color(hex:)` 与 `Views/Player/PlayerProgressViews.swift:50 init(hex:)`。原迁移方案是把其中一个定为唯一入口；实际实现是**两者合并**：唯一实现 = `Models/AppearanceTheme.swift` 的 `Color(hex: String)`（共享文件，两端都编），`MacAppearance.accentPresets` 改用字符串色值（值不变），`PlayerProgressViews.swift` 的扩展删除，`SettingsModels.BackgroundColor.color` 去掉 `#if os(iOS)` 双分支（macOS 不再落到灰色占位）。

### I1 · iOS 无环境值，强调色传递两套并存（B1）✅ 已收口（2026-09-15）
- 证据：直读 `settings.backgroundColorChoice.color` ≈148 处（`Views/Player/LyricsView.swift` 一个文件 46 处、`Views/Utility/BackgroundTextureView.swift` 14 处、`Views/Library/SearchResultsViews.swift` 11 处…）+ `accentColor: Color` prop 透传 18 处（`CollapsiblePlayerControls`、`TrackBulkSelection`、`PlayerView`、`AlbumViews`、`ArtistDetailScreen`…）。全仓唯一的 `EnvironmentKey` 是 macOS 那个。
- 用户可见后果：同一屏可能出现两种强调色；改一处忘一处；每层重读 settings，刷新时机不一致。
- 收口：iOS 侧也引入 `appAccentColor` 环境值（在 iOS App 根注入），视图统一读环境值；`accentColor:` prop 与 148 处直读迁移过去（**不新增第二实现**）。
- 测试：静态扫描禁 `QQPlayer/Views/**` 出现 `backgroundColorChoice.color`（白名单注入点）。
- **实施记录**：实测直读 142 处（清单写 148，含 `deleteSettings.` 变体与注释）/ 22 个文件 → 全部改读 `@Environment(\.appAccentColor)`；注入点 = `ContentView`（App 根，唯一）；`accentColor:` prop 9 处声明 → 8 处删除改读环境值，仅 `HintCardView` 保留（表现层参数 + 预览注入 `.blue` 的 seam，调用方全部传环境值）。`PlaylistsScreen.swift:168` 原有 1 处 `Color.accentColor`（iOS 侧的第三条路径）一并改读环境值。预览改用 `.environment(\.appAccentColor, …)` 显式注入。

### A1 · 配色设置字段层收口（2026-09-17）✅ 已实现
- 背景（审计 2026-09-16 报「`.backgroundColorChanged` 1 发 11 收」，09-17 复核改判）：**不是静默失败 bug**，是
  **两套配色设置字段并存**——iOS 用 `DeleteSettings.backgroundColorChoice`（枚举 rawValue = hex，8 色），
  macOS 用 `DeleteSettings.accentColorName`（String token，6 色，对齐 web `ACCENT_OPTIONS`）；macOS 侧无人写旧字段
  ⇒ 旧字段在 macOS 上是死值，11 个订阅方在 macOS 侧是死订阅。
- 另一处取证（审计未提）：`.backgroundColorChanged` **是 100% 冗余事件**——iOS 设置页本就在 post 前调
  `deleteSettings.save()`，而 `save()` 每次写入都发 `.qqplayerSettingsDidChange`；11 个订阅方里 3 个
  （`LibraryView` / `PlayerView` / `QueueManagementView`）甚至**同时订阅两个事件、动作逐字相同**；
  `BackgroundTextureView` 还有个只赋值、从不读取的 `@State settings`（死状态）。
- 用户拍板（2026-09-17）：走「**iOS 迁到 `accentColorName`**」（而非让 macOS 改用 iOS 的 8 色枚举——那会让 macOS
  与 web 的 pastel 视觉语言分裂）。已按此实现（见下）。
- 收口三点：
  1. **字段唯一**：iOS 名单收成 `IOSAppearance`（token → hex，色值逐字未改）+ 唯一读取入口
     `currentAccentKey` / `currentAccentColor` / `accentColor(forKey:)`（对称 macOS 的 `MacAppearance`）；
     旧字段退役，老数据在 `DeleteSettings.init(from:)` 按 hex → token 迁移（**旧字段优先**：老 plist 里那个 iOS
     从未写入过的 `accentColorName = "orange"` 占位值不作数），**iOS 用户视觉零变化**；
     默认值按端不同（`AppAccentDefault`：iOS `violet` / macOS `orange`，= 各自色表首项）。
  2. **事件唯一**：删 `.backgroundColorChanged`（已登记进 `AppNotificationContractTests.retiredValues`）；
     订阅方收回唯一设置信号 `.qqplayerSettingsDidChange`；widget 主题刷新收成一个**带去重的刷新点**
     （`AppCoordinator` 比较上次已同步的 token——无关设置项不再触发写盘同步）。
  3. **形状契约**：旧字段禁复活 / 字段声明唯一 + 两端设置页写同一字段 / iOS 视图禁直读 `accentColorName`
     （白名单 = iOS 设置页两行）——见第 5 节表格。
- 消费点全查（承 2026-08-27 纪律「修一个 bug 先 grep 同类消费点」）：设置页色块、App 根注入（`.accentColor` +
  `appAccentColor`）、锁屏 Now Playing 取 hex、iCloud widget 备份取 hex、模板/预览——一次性全改。
- 回归测试：`AppearanceThemeTests` 新增 5 条（8 色逐一迁移 / 旧字段优先 / 新格式 / 未知 hex 回落本端默认 /
  迁移单向不回写）+ 名单自洽 1 条（token / hex 不重复、默认 token 可解、共用 token 名齐全）。

### I2 · 主题模型与 macOS 不同（保持）
- iOS `forceDarkMode` + `AppearanceTheme.resolved`（有迁移测试 `AppearanceThemeTests`）；macOS 三态 + `NSApp.appearance`。按用户指示**不做统一**。

### M4 / I3 · 几何与排版无令牌（**B2**）

- C10/C11/C12。`DesignTokens`（放 `QQPlayer/Models/AppearanceTheme.swift`，两端共用）承载 radius / space / font 刻度。
- 做法三步：**B2a 零视觉变化**（每个现有取值映射为同值令牌，替换裸值，取值集合收成一处可列）→ **B2b 归一**（把 5/7/9/11/14 这类零散值归一，并档口径 + 映射表见 `#### B2b 实施记录`）→ **B2c 间距**（先清单后迁移）。
- 测试：静态扫描禁裸 `cornerRadius:` / `.system(size:` 字面量（B2a 已落地，白名单为空，见第 5 节）。

#### B2a 实施记录（2026-09-15，同值令牌化，零视觉变化）✅

- **令牌表**：`QQPlayer/Models/AppearanceTheme.swift` 末尾新增 `enum DesignTokens`（本轮禁新增 Swift 文件，故写进 B1 已建立的共享基础设施文件）。按值命名、小数点写 `_`：`radius12_5 = 12.5`。
- **实测取值分布（先 grep 全量，别信本文档旧记录）**——旧记录「圆角 135 处 / 12 种、字号 116 处 / 25 种」**是漏项版**：
  - 圆角：**152 处 / 15 种** —— 12×43 / 8×32 / 6×19 / 28×14 / 10×11 / 16×10 / 4×8 / 5×3 / 14×3 / 2×2 / 7×2 / 25×2 / 20×1 / 0×1 / **0.5×1**。漏项成因：旧记录只统计了 `cornerRadius: <数>` 带冒号写法，**漏了 `.cornerRadius(<数>)` 旧修饰符写法**（17 处，含 `20` / `25` 两档），也没记 `0.5`。
  - 字号：**115 处 / 26 种** —— 40×21 / 16×11 / 14×9 / 20×7 / 36×7 / 26×6 / 13×5 / 18×5 / 22×5 / 15×4 / 17×4 / 50×4 / 60×4 / 12×3 / 30×3 / 44×3 / 11×2 / **12.5×2** / 24×2 / 52×2 / 8×1 / 9×1 / 19×1 / 32×1 / 64×1 / 70×1。漏的是 `.5` 小数档。
  - **机械证据（零视觉变化）**：迁移后令牌引用 152 + 115 条，**值分布与迁移前逐项相同**（逐值计数比对，非抽样）。
- **未迁移项（刻意不动，非漏做）**：① 圆角非字面量——`cornerRadius: cornerRadius`（6 处，`MacArtworkThumbnail` 参数透传）、`var cornerRadius: CGFloat = 8`（4 处默认值）、`cornerRadius: barWidth / 2`（1 处）、`cornerRadius: index < 4 && … ? 6 : 12` 一类三元（4 处）；② 字号表达式 19 处——`size: fontSize` / `size: 17 * fontScale` / `size * fontScale` / `min(80, …)` / `max(size * 0.3, …)` / `size != nil ? size! / 4 : 40` / `isActive ? 22 : 19`。**后两类里藏在表达式中的字号字面量（`? 22 : 19`、`: 40`）是 B2b 要一起处理的对象**；守卫正则要求「数字后紧跟 `,`/`)`」，故不覆盖它们（避免把表达式误判成裸值）。
  - ✅ **B2b 已处理**：三元 `? 6 : 12`（4 处）与 `? 22 : 19`（1 处）、`: 40`（1 处）——同值令牌化，零视觉变化。
  - ❌ **B2b 仍未动（已登记为例外）**：夹取边界（`min(80, …)` 的 80、`max(size * 0.3, 10)` 的 10）与参数默认值 / 透传；理由见 `#### B2b 实施记录`。
- **守卫**：`QQPlayerTests/UIAccentContractTests.swift` 追加 `UIGeometryContract` + `UIGeometryContractTests`（3 条用例：合成源码正反例 / 真实源码零裸值 / 令牌名值自洽 + 定义↔引用一一对应）。**白名单为空**——令牌定义行 `static let radius12: CGFloat = 12` 不匹配调用点模式（`cornerRadius:` / `.cornerRadius(`），实测命中 0 次，故不需要条目（不是漏配）。
- **fail-closed 反证**：临时把一处圆角改回裸值 → `UIGeometryContractTests` 转红并打印精确 `路径:行号` → 撤销 → 复跑转绿。
- **已知边界**：扫描是 line-based（与 B1 同款），`cornerRadius:` 与数字**分行**的写法抓不到（当前代码 0 处，已实测）。

#### B2b 实施记录（2026-09-16，圆角 / 字号归一，**有视觉变化，用户已拍板**）

> ⚠️ **口径来源更正（诚实记录）**：用户口中的「§B2b 表」在本仓库文档里**从未落盘**（只有 Web 仓库 `~/codes/qqplayer/docs/ui-design-tokens.md` §9.6 有一份 Web 版表）。本轮执行时按用户**消息里给出的口径** + Web 表的同形决策重建了 Swift 版表（下表即重建结果），并已回写进本文档。以后这类「表」必须在实施前落盘，否则口径无法复现。

**归一规则（用户 2026-09-16 拍板）**
1. 字号：`11 / 11.5 / 12 / 12.5` 四档统一到 `12`（方案 B；Swift 侧实际只存在 `11 / 12 / 12.5`）。
2. 其余小数档 → 就近取整；遇 `.5` 时若两侧等距，取**较小**整数（本仓库唯一小数档 `radius0_5` 即按此处理）。
3. 「两侧等距取较小」同口径推广到整数档的等距情形（`5`（4|6）、`7`（6|8）、`14`（12|16））。
4. 目标刻度 = 去掉零散值的粗刻度集合；大卡面/大字号档（`radius28`）**保持**。

**机制：改指向 + 删定义（不留死令牌）**。并档一律把用点改指向保留档的令牌，并删除被并掉的令牌定义——契约测试里「定义集合 == 引用集合 + 名值自洽」会兜住漏删/漏改。

**圆角映射表（15 种 → 11 种 / 152 处）**

| 旧值 | 处数 | 新值 | 依据 | 视觉影响 | 需肉眼确认 |
|---|---|---|---|---|---|
| 0 | 1 | `radius0` 保持 | — | 无 | 否 |
| 0.5 | 1 | → `radius0` | 小数档就近取整，0\|1 等距取较小 | 极微（均衡器细条 1.5–2pt 宽，角几乎不可见） | 否 |
| 2 | 2 | 保持 | — | 无 | 否 |
| 4 | 8 | 保持 | — | 无 | 否 |
| 5 | 3 | → 4 | 4\|6 等距取较小 | 微（−1pt） | **是**（Mac 快捷键/在线搜索卡） |
| 6 | 19 | 保持 | — | 无 | 否 |
| 7 | 2 | → 6 | 6\|8 等距取较小 | 微（−1pt） | **是**（Mac 搜索条 / 歌单详情） |
| 8 | 32 | 保持 | — | 无 | 否 |
| 10 | 11 | 保持 | — | 无 | 否 |
| 12 | 43 | 保持（并接 14） | — | 无 | 否 |
| 14 | 3 | → 12 | 12\|16 等距取较小 | 微（−2pt） | **是**（Mac/iOS 歌词搜索结果、同步配对卡） |
| 16 | 10 | 保持 | — | 无 | 否 |
| 20 | 1 | 保持 | — | 无 | 否 |
| 25 | 2 | → 24（**新增档位**） | 就近取整（\|25−24\|=1 < \|25−28\|=3） | 微（−1pt） | **是**（艺人页头图） |
| 28 | 14 | 保持 | 大卡面刻度（专辑/歌单/歌词卡片） | 无（本轮未动） | **是（重点）**：请顺手确认大卡面圆角仍满意 |

**字号映射表（26 种 → 24 种 / 116 处）**

| 旧值 | 处数 | 新值 | 依据 | 视觉影响 | 需肉眼确认 |
|---|---|---|---|---|---|
| 11 | 2 | → 12 | 方案 B | +1pt | **是**（Mac 卡拉OK控制条、桌面歌词窗） |
| 12 | 3 | 保持（并接 11 / 12.5） | — | 无 | 否 |
| 12.5 | 2 | → 12 | 方案 B | −0.5pt | **是**（Mac 卡拉OK控制条 ×2） |
| 其余 23 档（8/9/13/14/15/16/17/18/19/20/22/24/26/30/32/36/40/44/50/52/60/64/70） | 109 | 保持 | 口径未授权归并 | 无 | 否 |

**表达式内字面量（同值令牌化，零视觉变化）**：
- 圆角三元 `? 6 : 12` ×4（`SmartPlaylistCardView` ×2 / `PlaylistCardView` ×2）→ `? DesignTokens.radius6 : DesignTokens.radius12`
- 字号三元 `? 22 : 19` ×1（`LyricsView` 跟唱）→ `? DesignTokens.font22 : DesignTokens.font19`
- 字号三元 `size! / 4 : 40` ×1（`PlaylistCardView` 无封面占位）→ `: DesignTokens.font40`

**令牌引用总数（归一+三元令牌化后实测）**：圆角 **160 条**（152 + 三元新增 8）、字号 **119 条**（116 + 三元新增 3）。

> ⚠️ **本轮踩到的坑（已修，写下来防复发）**：三元令牌化最初用字符替换做，`?: 40)` 因实际文本是 `: 40))`（多一层括号）**静默未命中**，而当时只 grep 了 `font40`（该文件另有一处合法 `font40`）就误判为“已改” —— 差点在报告里写下未执行的改动。教训：**改完后必须用「改动前 vs 改动后逐值计数」对比，而非「grep 名存在」**（这正是 B2a/B2c-a 立下的口径）。本轮收尾按此复查：`grep 圆角/字号上下文里剩余数字字面量` 逐条判定，确认只剩下表登记的自适应/透传项。

**刻意保留（登记为例外，不是漏做）**：
- 圆角：`cornerRadius: cornerRadius` 参数透传 6 处、`var cornerRadius: CGFloat = 8` 默认值 4 处、`barWidth / 2` 1 处（都是「值来自别处」，不是选择题）；`radius28` 大卡面档。
- 字号：`min(80, size * 0.2)` 的 80（夹取上限）、`max(size * 0.3, 10)` 的 10（夹取下限 ×2）——**夹取边界随容器尺寸变化，属自适应语义**，且 `10` 不在刻度上；若要令牌化需先拍板「是否允许 10 这一档」，本轮不动。比例常数（0.45/0.3/0.55/0.7/0.2）与变量透传（`size: fontSize` 等）同理。

**门禁**：见本轮报告（iOS 套件 / Mac build / swiftlint / swiftformat / target 成员守卫，警告 0）。

**fail-closed 反证**：见测试文件里 `normalizedScaleMatchesExpectedSet` —— 只要刻度集合与验收物不一致（多出零散档或误删档位）即转红，并打印多出/缺失两个方向的具体令牌名。

#### C11 间距盘点（逐条被 B2c-a 实施记录取代，保留作对照）

> ⚠️ **本节数字是初版盘点（漏项）**：只数了部分写法 → `padding` 记 30 种（实测 39 种）、`spacing:` 记 416 处（实测 434）、`Spacer` 记 21 处（实测 19 处字面量 + 2 处表达式）。**以 `#### B2c-a 实施记录` 的实测为准。**

- `padding`：**376 处数值 / 30 种取值**。top20：8×62、16×58、12×41、4×32、20×28、2×24、10×19、6×19、14×15、24×13、5×10、40×8、32×7、100×7、1×5、3×3、60×3、9×3、44×3、26×2。另有空参 20 处（= 系统默认 16）、仅边参数 21 处（`.horizontal` 17 / `.leading` 2 / `.vertical` 2）、表达式 4 处。
- 容器 `spacing:`：**416 处 / 18 种**。top：8×82、12×61、0×57、10×45、2×39、4×32、16×30、6×24、14×13、20×11、3×8、1×3、24×3、32×3、5×2。
- `Spacer(minLength:)`：21 处（0×12、20×2、24×2、4 / 6 / 12 各 1、表达式 2）。
- **建议刻度（B2c 拍板用）**：现状用到了 1/2/3/4/5/6/7/8/9/10/11/12/14/15/16/20/24/26/28/32/40/44/52/60/100。建议归一到 **`2 / 4 / 6 / 8 / 10 / 12 / 16 / 20 / 24 / 32 / 40 / 48 / 64`**（4pt 基准），映射：5→4|6、7→8、9→8|10、11→12、13→12、14→12|16、15→16、18→20|16、22→20|24、26→24、28→24|32、44→40|48、52→48、60→64、100→保留（大留白，语义特殊）。
- **迁移风险**：① padding 的「边参数 + 数值」是两个维度，归一只能动数值；② `100`（×7）多为给底部播放条留白，视觉敏感；③ 同一屏的多个组件常共用 `spacing`/`padding`，归一会有可见位移，**需逐屏出图给用户确认**；④ 空参 `.padding()` 实质等于 16，若与显式 16 混用，可顺手统一（属视觉变化，归 B2b）。

#### B2c-a 实施记录（2026-09-16，同值令牌化，零视觉变化）✅

- **范围**：C11 间距的三类调用点——`.padding(<数>)` / `.padding(.<边>, <数>)`、容器 `spacing:`（含 `VStack/HStack/LazyVStack` 与 `GridItem(spacing:)`，`horizontalSpacing`/`verticalSpacing` 全仓 0 处）、`Spacer(minLength: <数>)`。
- **实测取值分布（先 grep 全量，别信本文档旧记录）**：
  - `.padding(<数>)`：**33 处 / 10 种**；`.padding(.<边>, <数>)`：**343 处 / 29 种**（合计 padding 376 处 / 39 种，旧记录写「30 种」）
  - 容器 `spacing:`：**434 处 / 18 种**（旧记录 416 处）
  - `Spacer(minLength:)`：**19 处 / 6 种**（旧记录 21 处，含 2 处三元表达式）
  - 合并去重后 **829 处 / 33 种取值**：0×69、1×11、1.5×1、2×63、3×11、4×65、5×12、6×44、7×2、8×154、9×3、10×64、12×103、14×28、16×92、18×2、20×42、22×1、24×18、25×1、26×3、28×1、30×2、32×10、40×8、44×3、50×1、56×1、60×3、64×1、100×7、110×1、120×2
  - **机械证据（零视觉变化）**：迁移后 `DesignTokens.space*` 引用 **829 条**，**值分布与迁移前逐项相同**（逐值计数比对，非抽样；度量与替换用同一套正则——B2a 那次就是栽在这上面：基线口径漏了第二种写法会假报不一致）。
- **令牌**：`enum DesignTokens` 末尾追加 `space*` 33 条（仍写 `QQPlayer/Models/AppearanceTheme.swift`，**不新增 Swift 文件**）；按值命名、小数点写 `_`（`space1_5 = 1.5`）。每行注释带「改前 N 处」，B2c-b 直接读数、不必再 grep。
- **未迁移项（刻意不动，非漏做；合计 61 处）**：
  - **无值可令牌化 41 处**：`.padding()` 空参 20 处（= 系统默认 16）、`.padding(.<边>)` 仅边参数 21 处；
  - **表达式 13 处（其中的字面量是 B2c-b 的输入）**：`.padding(compact ? 20 : 44)`、`.padding(.top, disc.discNumber > 1 ? 16 : 0)`、`.padding(.vertical, karaoke.isKaraokeOn ? 18 : (isActive ? 24 : 16))`、`.padding(.horizontal, max(16, min(20, …*0.05)))`、`spacing: compact ? 14 : 32`、`spacing: UIScreen.main.scale < … ? 12 : 16`（2 处）、`spacing: … ? 20 : 25`、`spacing: … ? 16 : 20`、`Spacer(minLength: … ? 16 : 20)`（2 处）；
  - **变量 / 声明 7 处**：`.padding(.vertical, LyricLineEmphasis.linePadding(…))`、`.padding(.horizontal, Self.horizontalPadding)`、`spacing: Self.spacing`（3 处）、`let spacing: CGFloat = 2`（`MacVisualizerView`）、`static let spacing: CGFloat = 12`（`SmartPlaylistStore`）、`spacing: CGFloat = spacing`（形参默认值）。
- **守卫**：`QQPlayerTests/UIAccentContractTests.swift` 追加 `UISpacingContract`（5 条规则）+ `UISpacingContractTests`（3 条用例：合成源码正反例 / 真实源码零裸值 / 令牌名值自洽 + 有引用）。规则 5「实参开头的字面量参与运算」（`padding(8 * scale)`）实测当前 0 处，属**预防性**（与 B2a 圆角同形规则对称）。**白名单为空**——令牌定义行 `static let space8: CGFloat = 8` 不匹配调用点模式，实测命中 0 次（不是漏配）。
- **fail-closed 反证**：把 `Mac/MacTagEditorView.swift:179` 的 `.padding(DesignTokens.space16)` 还原成 `.padding(7)` → `UISpacingContractTests` 转红并打印 `QQPlayer/Mac/MacTagEditorView.swift:179`（`EXIT=65`）→ 撤销（md5 与备份逐字节一致）→ 复跑 `EXIT=0`。
- **已知边界**：扫描是 line-based（与 B1/B2a 同款），`spacing:` 与数字**分行**的写法抓不到（当前代码 0 处，已实测）。

#### 间距归一对照表（B2c-b 拍板用，**只出表、不改值**）

建议刻度（4pt 基准）：`0 / 2 / 4 / 6 / 8 / 10 / 12 / 16 / 20 / 24 / 32 / 40 / 48 / 64`（大留白 100/110/120 建议保留）。

| 当前取值 | 处数 | 建议档位 | 视觉影响 | 批次 |
|---|---|---|---|---|
| 0 | 69 | 0（保留） | 无（语义 = 无间距） | — |
| 1 | 11 | 2 | 微（分隔/图标贴合间隙 +1pt） | 第 1 批 |
| 1.5 | 1 | 2 | 微 | 第 1 批 |
| 2 | 63 | 2（保留） | 无 | — |
| 3 | 11 | 4 | 微 | 第 1 批 |
| 4 | 65 | 4（保留） | 无 | — |
| 5 | 12 | 4 或 6 | 微（±1pt） | 第 1 批 |
| 6 | 44 | 6（保留） | 无 | — |
| 7 | 2 | 8 | 微 | 第 1 批 |
| 8 | 154 | 8（保留） | 无 | — |
| 9 | 3 | 8 或 10 | 微 | 第 1 批 |
| 10 | 64 | 10（保留） | 无 | — |
| 12 | 103 | 12（保留） | 无 | — |
| 14 | 28 | 12 或 16 | **中**（成组出现 28 处，整块节奏变化） | 第 2 批 |
| 16 | 92 | 16（保留） | 无 | — |
| 18 | 2 | 16 或 20 | 微 | 第 1 批 |
| 20 | 42 | 20（保留） | 无 | — |
| 22 | 1 | 20 或 24 | 微 | 第 1 批 |
| 24 | 18 | 24（保留） | 无 | — |
| 25 | 1 | 24 | 微 | 第 1 批 |
| 26 | 3 | 24 | 微（2pt） | 第 1 批 |
| 28 | 1 | 24 或 32 | 微 | 第 1 批 |
| 30 | 2 | 32 | 微 | 第 1 批 |
| 32 | 10 | 32（保留） | 无 | — |
| 40 | 8 | 40（保留） | 无 | — |
| 44 | 3 | 40 或 48 | 微 | 第 1 批 |
| 50 | 1 | 48 | 微 | 第 1 批 |
| 56 | 1 | 48 或 64 | 微 | 第 1 批 |
| 60 | 3 | 64 | 微 | 第 1 批 |
| 64 | 1 | 64（保留） | 无 | — |
| 100 | 7 | 100（保留） | **敏感**（底部播放条/大留白） | 第 3 批 |
| 110 | 1 | 112 或保留 | 敏感 | 第 3 批 |
| 120 | 2 | 保留 | 敏感 | 第 3 批 |

- **批次**：第 1 批 = 并档位移 ≤2pt 的微调档（约 16 种 / 约 60 处）；第 2 批 = `14 → 12|16`（28 处，常与 12/16 同屏，改用后整块节奏变化）；第 3 批 = 大留白（建议**维持不动**）。
- **顺序（padding vs spacing）**：**先 `spacing:` 后 `.padding`**。`spacing:` 改的是容器内子视图之间的节奏，同容器内子视图同步位移、不改变单个元素尺寸与命中区；`.padding(<数>)` 改的是元素自身内边距（卡片变胖变瘦、命中区变化、可能触发换行/截断），且同屏常多处叠加。`Spacer(minLength:)` 仅 19 处（12 处为 0）、与弹性布局耦合，可随 padding 同批。
- **表达式类的处理（三步）**：① 先做「字面量 → 令牌」的零视觉替换（`compact ? 20 : 44` → `compact ? DesignTokens.space20 : DesignTokens.space44`），让分支只表达「哪个档位」；② `UIScreen.main.scale < UIScreen.main.nativeScale ? …` 一类是**刻意的设备差异**（7 处同一个判据）→ 归一时必须**整组同进同退**，否则同屏出现两套节奏；③ `max(16, min(20, width * 0.05))` 是自适应夹取 → **建议保留为例外**（它刻意随屏幕宽度变化），列入白名单并写理由。
- **验收**：本阶段（B2c-a）零视觉变化，无需验收；B2c-b 有可见位移 ⇒ 按屏幕分批 + **用户真机验收**（不自己截图）。

## 4. 已做对的地方（保持，别改坏）

- 强调色名单唯一：`MacAppearance.accentPresets`（6）；iOS `IOSAppearance`（8，值不同是**有意**的，见 §0.1）；
  且**配色设置字段唯一** = `DeleteSettings.accentColorName`（两端设置页写同一个字段，A1 2026-09-17）
- 主题应用唯一：`MacAppearance.apply(theme:)`（NSApp.appearance，所有窗口跟随）
- 系统语义色用得好：`.destructive`/`.red`/`.green`/`.orange`，几乎无自造色
- macOS 18 个文件已统一消费 `appAccentColor`（M1 只是 3 处例外）

## 5. 形状测试清单（B3）

| 断言 | 白名单 |
|---|---|
| 禁 `QQPlayer/Mac/**` 出现 `Color.accentColor`（含裸 `.accentColor` 字面量；正则排除 `self.accentColor` / `Localized.accentColor` / `.accentColorName` / `.accentColor(forKey:)`） | `Models/AppearanceTheme.swift` 的 `defaultValue`（环境值定义随 M3 移到共享文件） |
| 禁 `QQPlayer/Views/**` 直读 `accentColorName`（A1：字段名随收口改为两端共用的那个） | iOS 设置页读写两行（`Views/Utility/SettingsView.swift`）；非空转佐证 = 注入点 `ContentView.swift` 仍命中 |
| 配色字段唯一：`var accentColorName` 声明恰好 1 处 + 写点恰好 2 处（iOS / macOS 设置页） | 无（写点即白名单本身） |
| 禁旧配色字段 `backgroundColorChoice` 复活（A1 退役） | `Models/SettingsModels.swift` 的 `LegacyCodingKeys` 声明行 + 迁移读取行 |
| 禁 `.backgroundColorChanged` 事件复活（A1 退役：与 `.qqplayerSettingsDidChange` 冗余） | 无——由 `AppNotificationContractTests.retiredValues` 兜（常量清单里也不得有它） |
| macOS 当前强调色只由 `MacAppearance` 唯一读取 | `MacAppearance.swift`（读）+ `MacSettingsView.swift`（设置页读写） |
| hex→Color 解析唯一（`init(hex:)` 恰好 1 处，无第二套 `color(hex:)`） | 唯一工具 `Models/AppearanceTheme.swift` |
| 强调色环境值定义唯一 + iOS 注入点唯一（`ContentView`） | `Models/AppearanceTheme.swift`；预览注入算 seam |
| 禁裸 `cornerRadius: <数字>` / `.cornerRadius(<数字>)` / `.system(size: <数字>`（B2a 已落地） | 白名单为空（令牌定义 `static let radius12: CGFloat = 12` 不匹配该模式，实测命中 0 次） |
| 令牌名 ↔ 值自洽 + 定义集合 == 引用集合（B2a 已落地） | 令牌表 `Models/AppearanceTheme.swift` |
| **归一后刻度集合 == 预期集合**（圆角 11 种 / 字号 24 种；B2b 2026-09-16 落地） | 令牌表 `Models/AppearanceTheme.swift`；改动刻度必须同步改断言 |
| 禁裸间距字面量 `.padding(<数>)` / `.padding(.<边>, <数>)` / `spacing: <数>` / `Spacer(minLength: <数>)`（B2c-a 已落地） | 白名单为空（令牌定义行 `static let space8: CGFloat = 8` 不匹配调用点模式，实测命中 0 次） |
| 间距令牌名 ↔ 值自洽 + 每条都有引用（B2c-a 已落地） | 令牌表 `Models/AppearanceTheme.swift` |

> B1 形状测试实现在 `QQPlayerTests/UIAccentContractTests.swift`（9 个用例；含合成源码自证与白名单腐烂检测；已反证：临时把一处改回 `Color.accentColor` → 套件转红并打印精确行号）。
> B2a 同文件追加 `UIGeometryContract` + `UIGeometryContractTests`；B2c-a 再追加 `UISpacingContract` + `UISpacingContractTests`（3 条用例）——**三章共用同一套扫描纯函数，不另起测试文件**。B2c-a 已反证：`MacTagEditorView.swift:179` 的 `.padding(DesignTokens.space16)` 还原成 `.padding(7)` → 套件转红并打印精确路径:行号 → 撤销复跑转绿。
> 先例：`SyncIdentityContract` / `SyncOutcomeContract` / `SyncEntityRegistry`（同步）、`DisplayScriptContractTests`（UI 显示层）、`AppearanceThemeTests`（主题迁移）。
> A1（2026-09-17 配色设置字段层收口）在 `UIAccentContractTests` 追加 2 条（字段唯一 + 旧字段禁复活），并改了 iOS 直读规则盯的字段名。

## 6. 分批

| 阶段 | 内容 | 状态 |
|---|---|---|
| B1 | M1 / M2 / M3 / I1 | **已实现（2026-09-15，未 push，待用户真机验收）** |
| B2a | M4 第一步：圆角 152 处 + 字号 115 处**同值令牌化**（零视觉变化）+ 防裸值守卫 | **已实现（2026-09-15，未提交，待用户复核）** |
| B2b | M4 第二步：**归一**（C10/C12 值并档 + 表达式内字面量；圆角 15→11 种、字号 26→24 种） | **已实现（2026-09-16，待用户真机验收）** |
| B2c-a | M4 第三步之一：C11 间距**同值令牌化**（829 处 → `DesignTokens.space*`，零视觉变化）+ 防裸值守卫 | **已实现（2026-09-16，已提交，待用户复核）** |
| B2c-b | M4 第三步之二：间距**归一对照表**（33 种取值并档 + 表达式内字面量） | 待用户拍板（有视觉变化；对照表见 M4） |
| B3 | 第 5 节形状测试 | B1 相关 6 条已落地；B2 的几何/字号断言随 B2 |
| C | 控件层抽象（卡片/行/按钮/空态） | **暂缓，需用户单独拍板** |

## 7. 待用户确认

1. ~~B2b 归一对照表~~ → **已完成（2026-09-16）**：圆角 15→11 种、字号 26→24 种，映射表见 `#### B2b 实施记录`；等真机验收（重点：`radius5/7/14/25` 并档处 + `font11/12.5 → 12` + 大卡面 `radius28` 保持是否仍满意）。
2. M2 收口若超出「单点读取 + 单点刷新」范围（例如需要改窗口生命周期），先报告再动。
