# macOS 单测 target 评估（2026-09-13）

> 背景：2026-09-12 全量审计 🟡-7「macOS 无单测 target，CI 的 macOS job 只到编译级」。
> 本文档**只做评估，不实施**（任务包明确要求）。结论在第 5 节。
> 证据形式：`文件:行号` / 命令 + 原始输出。基线 `main@5752b2f`。

## 1. 现状（事实）

**CI 两个 job，没有一个在 macOS 上跑测试**

- `.github/workflows/ci.yml:50-141`：iOS job（`xcodebuild test -only-testing:QQPlayerTests`，
  跑在 iOS 模拟器）＋ macOS job（`build QQPlayerMac` + 资源产物断言）。
- macOS job 的步骤只有：checkout → 缓存 → Build → 警告门禁 → 产物断言，**无 test 步骤**。
- `.github/workflows/ci.yml:90-93` 自述：
  > 编译级验证无法覆盖布局/行为，macOS 单测 target 后续补齐。

**工程里没有 Mac 测试 target**

- test bundle target 只有一个：`QQPlayer.xcodeproj/project.pbxproj:1045`
  （`productType = "com.apple.product-type.bundle.unit-test"`，`name = QQPlayerTests`）。
- 另有 `QQPlayerSiriTests`（`project.pbxproj:1021`），但不被任何 scheme 引用 → 不构建不运行。
- `QQPlayerMac`（`project.pbxproj:1059`）无 test 依赖；`xcschemes/` 只有
  `QQPlayer / Share / SiriIntentsExtension` 三个 scheme，**没有 Mac 测试 scheme**。

**Mac 代码的分布决定了「其实已经覆盖了多少」**

| 位置 | 文件数 | 是否进 iOS target | 测试现状 |
|---|---|---|---|
| `QQPlayer/Services/Mac*.swift`（纯决策/算法） | 见下 | **是** | 已被 QQPlayerTests 覆盖，CI 真跑 |
| `QQPlayer/Mac/**`（视图与 Mac 装配） | 48 | **否** | 无任何自动化验证 |

- `QQPlayer/Mac/**` 被 iOS target 显式排除：`project.pbxproj` 的 iOS
  `membershipExceptions`（50 条，含 `Info.plist`）逐条列出 `Mac/*.swift`。
- 但「Mac 专属**逻辑**」并不都在 `QQPlayer/Mac/`：`MacPlaybackGate.swift`、
  `MacIndexingGate.swift`、`MacShortcutLogic.swift`、`MacSpectrumDSP.swift` 都在
  `QQPlayer/Services/`（**iOS target 内**），因此它们的测试
  （`QQPlayerTests/MacPlaybackGateTests.swift`、`MacIndexingGateTests.swift`、
  `MacShortcutLogicTests.swift`、`MacSpectrumDSPTests.swift`、`MacAria2ClientTests.swift`
  等 11 个 `Mac*Tests.swift`）**当前就在 CI 里真跑**——只是跑在 iOS 模拟器上。

- `QQPlayer/Mac/**` 48 个文件的构成（命令：`grep -l 'import SwiftUI'` /
  `grep -qE ': View'`）：

```
$ ls QQPlayer/Mac/*.swift | wc -l
48
$ grep -l 'import AppKit' QQPlayer/Mac/*.swift | wc -l
14
$ for f in QQPlayer/Mac/*.swift; do grep -q 'import SwiftUI' "$f" || echo "  $f"; done
  MacFolderMonitor.swift  MacHelpers.swift  MacImportService.swift  MacScanLogger.swift
  MacSearchHistoryStore.swift  MacSpectrumAnalyzer.swift  MacSyncContentModel.swift
  MacSyncCoordinatorFactory.swift  MacSyncLibraryHost.swift  MacSyncLocalContentProvider.swift
  MacSyncPeerContentProvider.swift  MacSyncRunViewModel.swift  SyncHostCenter.swift
$ for f in QQPlayer/Mac/*.swift; do grep -qE ': View' "$f" || echo "  $f"; done
  （14 个非 View 文件，与上表同集）
```

即：**34/48 是 SwiftUI 视图**（测试价值低、且需要宿主 App 才能渲染），
14 个非 View 文件里又以 Mac 装配/IO（`MacSyncLibraryHost`、`MacImportService`、
`MacFolderMonitor`、`SyncHostCenter`）为主，纯逻辑占比很小——纯逻辑大多已被上收
到 `QQPlayer/Services/`（这正是 2026-08-31「能编译但行为错」教训后的既定做法）。

## 2. 可行做法

### 方案 A：新建 macOS 单测 target（`QQPlayerMacTests`）

- 形态：新 `PBXNativeTarget`（unit-test bundle）+ `TEST_HOST` 指向 `QQPlayerMac.app`；
  新 build configuration list；`QQPlayerMac` 加 target dependency；新 shared scheme
  （含 `Testables`，否则重蹈 `QQPlayerSiriTests` 不被任何 scheme 引用的覆辙）；
  CI 的 macOS job 加一步 `xcodebuild test`。
- 改动面：**pbxproj 手术**（新 target / 配置 / 依赖 / phase / 分组，5-8 处插入，
  本仓是手写 pbxproj，`scripts/add-test-file.py` 只解决「文件进既有 target」，
  不解决「新建 target」）＋ 新 scheme 文件 ＋ ci.yml 一处。
- 风险：
  - 测试包要 `@testable import QQPlayerMac`，会**全量重编 Mac target**（195 个文件）
    一次；CI 的 mac job 时长上升（当前无 `timeout-minutes` 之外的预算，见 🟡-8）。
  - `QQPlayer/Mac/**` 的视图文件需要宿主 App 起来才有意义，能断言的多是
    「装配是否接线」「纯数据结构」，与直接把这些逻辑挪进 `Services/` 后可测的收益重叠。
  - 新增 CI 面 = 新增一类会连红的东西（签名/沙盒/宿主启动），维护成本实打实。

### 方案 B：复用 iOS 测试文件 + 条件编译

把现有 `QQPlayerTests/*.swift` 加进 Mac target 并用 `#if os(macOS)` 守卫。

- 问题：本仓 iOS target 与 Mac target 的**编译文件集是两张不同的表**
  （iOS 排除 `Mac/`，Mac 是 197/205 条白名单），共享测试文件等于把「两边都能编过」
  变成新约束：任何 iOS 专属 API（UIKit、`UIApplication`、iOS 单测里大量存在的
  `@MainActor` 视图逻辑）都要逐个加守卫。改动面比方案 A 更大，收益相同。

### 方案 C：XcodeGen 之类的工程生成

- 本仓 pbxproj 是手工维护的（含两张 membership 例外表、`add-test-file.py` 手工注册
  流程），换成工程生成器 = 全工程重写，且要重放所有 target 设置差异。
  **不建议**（收益仅是「加 target 容易」，代价是整仓工程定义换血）。

### 方案 D：继续「逻辑上收到 `Services/`」的既定路线（零新 target）

- macOS 专属决策逻辑继续写在 `QQPlayer/Services/`（iOS target 内），用现有的
  `QQPlayerTests` 覆盖——已有 11 个 `Mac*Tests.swift` 正在 CI 真跑，就是这条路的产物。
- 代价：0（无 pbxproj 手术、无新 scheme、无新 CI 步骤）。
- 边界：只能覆盖**能上收为纯逻辑**的部分；`QQPlayer/Mac/**` 里真正依赖 AppKit/SwiftUI
  运行时的部分（视图布局、宿主装配）仍然要人工验证。

## 3. 改动面与风险对照

| 方案 | pbxproj 改动 | 新 scheme | CI 改动 | 可覆盖对象 | 主要风险 |
|---|---|---|---|---|---|
| A 新 Mac test target | 5-8 处插入（新 target/依赖/配置） | 要（否则不执行） | mac job 加 `test` + 时长↑ | `QQPlayer/Mac/**` 中可断言的装配/数据 | 工程文件手改易错；宿主启动类失败面；重编 195 文件 |
| B 共享测试 + 条件编译 | 大量（两张表对齐） | 复用 | 同 A | 同 A | 每个 iOS 专属 API 都要守卫，长期维护负担 |
| C XcodeGen | 全工程重写 | — | 可能要调 | 同 A | 整仓工程定义换血，回归面不可控 |
| D 逻辑上收（现状路线） | 0 | 不涉及 | 0 | 能上收为纯逻辑的 Mac 决策 | 视图/宿主装配仍无自动化 |

## 4. 与既有覆盖的衔接（避免重复投入）

已经在 `Services/` 里、已有测试的 Mac 逻辑（**不需要**新 target）：
`MacPlaybackGate`、`MacIndexingGate`、`MacShortcutLogic`、`MacSpectrumDSP`、
`MacAria2Client`、`MacFolderWatchPolicy`、`MacImportNaming`、`MacTrashService`、
`MacLibraryFactsStore`、`MacOnlineDownloadService`、`MacSyncClientPoolPolicy`。

仍无自动化验证、且**看起来值得有**的一类（都在 `QQPlayer/Mac/`）：
`MacSyncContentModel`、`MacSyncRunViewModel`、`MacSearchHistoryStore`、
`SyncHostCenter`、`MacSyncCoordinatorFactory`（同步面板的数据/状态模型）。
其中前三个是纯数据结构/存储，按方案 D 挪进 `Services/` 即可被 CI 覆盖；
后两个是装配与视图模型，需要宿主才能测。

## 5. 结论与建议

**建议：暂不新建 macOS 单测 target（不实施方案 A/B/C），继续走方案 D。**

理由：

1. **性价比**：`QQPlayer/Mac/**` 48 个文件中 34 个是 SwiftUI 视图，测试价值低；
   真正有回归价值的纯逻辑（11 个 `Mac*Tests.swift` 覆盖的那些）已经在
   `QQPlayer/Services/` 里被 CI 真跑，新建 target 的边际收益集中在少数几个
   装配/视图模型文件上。
2. **成本与风险**：新 target 要手改 pbxproj（本仓无工程生成器）＋ 新 scheme ＋ 新 CI 步骤
   ＋ 重编 195 个 Mac 文件；这些都会永久增加 CI 的失败面与时长。
3. **有更便宜的等价手段**：把 `MacSyncContentModel` / `MacSyncRunViewModel` /
   `MacSearchHistoryStore` 这类**纯逻辑**从 `QQPlayer/Mac/` 上收到
   `QQPlayer/Services/`，即可用现有 `QQPlayerTests` 覆盖，零工程改动
   （这正是 2026-08-31 之后 MacPlaybackGate 等文件的既有做法）。

**重新评估的触发条件**（满足任一再考虑方案 A）：

- 出现「只在 macOS 上能复现、且无法上收为纯逻辑」的行为回归（例如 AppKit 事件链、
  窗口/菜单装配、宿主生命周期）；
- 视图层开始承载实质决策逻辑（届时更该做的是先上收，而不是加 target）；
- CI 的 mac job 已经有富余时长预算（例如已补 `timeout-minutes` 与并发控制，见 🟡-8）。

**如果将来要做方案 A**，落地顺序建议（本文档不实施）：先建 target + scheme（不接 CI）
→ 只放 1 个 `SyncHostCenter` 装配冒烟用例验证宿主能起 → 再接进 macOS job
→ 最后才补视图模型断言。同时务必在 `ci.yml` 的 mac job 里加 `timeout-minutes`
（当前两个 job 都无超时，见审计 🟡-8）。
