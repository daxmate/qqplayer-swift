//
//  LibraryScanGate.swift
//  QQPlayer
//
//  启动 / 回前台「要不要自动扫曲库」的**唯一决策点**（纯函数，可单测）。
//
//  为什么要有它（2026-09-23 用户诉求：重装/重编译后**打开就该有歌**，不能要求手动刷新）：
//  决策原先在 `AppCoordinator.initialize()` 与 `QQPlayerApp.handleWillEnterForeground()`
//  各写一份（两份同逻辑、各自内联 `Date()` + 各自打日志 ⇒ 不可测、易漂移）。
//  用户实测：`lastLibraryScanDate` 落在**数据容器的 Preferences**（跨「覆盖安装」存活），
//  重装/重编译后它仍是「0.7 小时前」⇒ 1 小时节流判定「最近扫过」⇒ 启动不扫；
//  而库此时可能是空的（新数据容器 / 新 App Group 容器）⇒ 打开一直 0 首，直到用户手点刷新。
//  故新增一条**强制规则**：**曲库为空 ⇒ 无条件扫**（不受 1 小时节流约束）。
//
//  决策穷尽四态（`Decision`）：
//    · `neverScanned`     —— 从未扫过（`lastScanDate == nil`）→ 扫（历史行为）
//    · `intervalElapsed`  —— 距上次 ≥ `minimumIntervalHours` → 扫（历史行为）
//    · `emptyLibrary`     —— **曲库为空 → 强制扫**（本次新增，iOS 收口见下）
//    · `recentlyScanned`  —— 最近 1 小时内扫过且曲库非空 → 跳过（历史节流，保持）
//
//  「曲库为空」的取数口径（**哨兵，不 fail-open**）：入参是 `trackCount: Int`，
//  `0` = 空库（强制扫）；`> 0` = 非空（走节流）；`LibraryScanGate.unknownTrackCount`（`-1`）
//  = **读不到计数**（`getTrackCount()` 抛错）⇒ **不当作空库**，按节流分支处理。
//  为什么不 fail-open（读不到当空）：计数读不到通常是 DB 暂时不可用（挂起/未开连接），
//  若据此判空，会退化成「每次启动/回前台都强制全量扫」——大曲库上就是持续重扫；
//  而真正需要修的场景（重装/换容器后库确实是空的）拿到的是**成功的 0**，走的是 `0` 那条，
//  不依赖这条兜底。
//
//  平台边界（`forcesScanWhenLibraryIsEmpty`）：**iOS 生效、macOS 关闭**。
//  理由：① 事故形态是 iOS 数据容器/App Group 容器与 `lastLibraryScanDate` 的生命周期错位，
//  macOS 无此形态（库 = `~/Music/QQPlayer` + 用户添加的文件夹，DB 落
//  `Application Support/QQPlayerMac`，都不随重装换容器）；② macOS 空库是**合法稳态**
//  （用户还没往曲库目录放歌 / 只用外部来源），加这条会让它每次启动都对全部文件夹做一轮
//  枚举，收益为零；③ 按本仓既有口径「决策上收为纯函数 + 平台差异显式表态」
//  （见 `IndexingGate` / `MacIndexingGate`），这里用编译期常量表态，macOS 行为逐字节不变。
//
//  注意：本文件只做判定，不读 `lastLibraryScanDate`、不写它（语义与落点不变——
//  `DeleteSettings.lastLibraryScanDate`，`Models/SettingsModels.swift`，Widget/后台同步
//  继续读同一份值）。
//
//  target: shared
//

import Foundation

enum LibraryScanGate {
    /// 自动扫描的最小间隔（小时）。**历史值**（两处内联实现里就是 `1.0`）——别改，
    /// 改了会连带影响「后台/回前台」的扫描节奏（那是产品口径，不是本文件的自由）。
    static let minimumIntervalHours: Double = 1.0

    /// 决策结果（穷尽四态；`hoursSinceLastScan` 只服务文案，判定本身不看它的小数）。
    enum Decision: Equatable {
        case neverScanned
        case intervalElapsed(hoursSinceLastScan: Double)
        case emptyLibrary(hoursSinceLastScan: Double)
        case recentlyScanned(hoursSinceLastScan: Double)

        /// 本轮要不要真去扫。**唯一判据**（调用点不得另写条件）。
        var shouldScan: Bool {
            switch self {
            case .neverScanned, .intervalElapsed, .emptyLibrary:
                return true
            case .recentlyScanned:
                return false
            }
        }

        /// 不含小时数的**类别**：给测试与日志分派用（避免比较 Double 关联值）。
        enum Kind: Equatable {
            case neverScanned, intervalElapsed, emptyLibrary, recentlyScanned
        }

        var kind: Kind {
            switch self {
            case .neverScanned: return .neverScanned
            case .intervalElapsed: return .intervalElapsed
            case .emptyLibrary: return .emptyLibrary
            case .recentlyScanned: return .recentlyScanned
            }
        }
    }

    /// 决策日志条目：文案 + 级别（info / warn）——**两处调用点共用的唯一文案来源**。
    struct LogEntry: Equatable {
        let message: String
        let isWarning: Bool
    }

    /// 「曲库为空 ⇒ 无条件扫」是否生效。**iOS 收口**（理由见文件头平台边界）。
    static var forcesScanWhenLibraryIsEmpty: Bool {
        #if os(iOS)
            return true
        #else
            return false
        #endif
    }

    /// 「计数读不到」的哨兵：调用方 `getTrackCount()` 抛错时传它。
    /// **不许**把它折成 `0`（那就等于把「读不到」当「空库」，见文件头口径）。
    static let unknownTrackCount = -1

    /// 决策（唯一实现）。
    /// - Parameters:
    ///   - lastScanDate: `DeleteSettings.lastLibraryScanDate`（nil = 从未扫过）。
    ///   - trackCount: `track` 行数（调用方读 `getTrackCount()`）；`-1` = 读不到（哨兵）。
    ///   - now: 当前时刻（注入以便单测；生产传 `Date()`）。
    static func decision(lastScanDate: Date?, trackCount: Int, now: Date) -> Decision {
        guard let lastScanDate else { return .neverScanned }
        let hoursSinceLastScan = now.timeIntervalSince(lastScanDate) / 3600

        // ① 节流窗口外：照旧扫（与历史 `hoursSinceLastScan >= 1.0` 逐字同义）。
        if hoursSinceLastScan >= minimumIntervalHours {
            return .intervalElapsed(hoursSinceLastScan: hoursSinceLastScan)
        }

        // ② 节流窗口内但**曲库为空**：强制扫（2026-09-23 新增）。
        //    空库没有「刚扫过」可言——上一轮扫描要么没成功、要么扫的是另一个容器；
        //    再扫一轮的代价是一次目录枚举，收益是「打开就有歌」。
        //    注意判据是**恰好 0**：`-1`（读不到）走不到这里，按非空处理。
        if trackCount == 0, forcesScanWhenLibraryIsEmpty {
            return .emptyLibrary(hoursSinceLastScan: hoursSinceLastScan)
        }

        // ③ 节流窗口内且曲库非空（或计数读不到）：跳过（历史行为）。
        return .recentlyScanned(hoursSinceLastScan: hoursSinceLastScan)
    }

    /// 布尔视图（历史调用点语义：`shouldPerformAutoScan(lastScanDate:)`）。
    static func shouldPerformAutoScan(lastScanDate: Date?, trackCount: Int, now: Date) -> Bool {
        decision(lastScanDate: lastScanDate, trackCount: trackCount, now: now).shouldScan
    }

    /// 决策文案（唯一来源；4 态**可区分**：新增的空库那条不与既有两行混）。
    static func logEntry(for decision: Decision) -> LogEntry {
        switch decision {
        case .neverScanned:
            return LogEntry(message: "🆕 Never scanned before - will perform scan", isWarning: false)
        case .intervalElapsed(let hours):
            return LogEntry(
                message: "⏰ Last scan was \(String(format: "%.1f", hours)) hours ago - will scan",
                isWarning: false
            )
        case .emptyLibrary(let hours):
            return LogEntry(
                message: "📚 Library is empty - forcing library scan"
                    + " (last scan \(String(format: "%.1f", hours)) hours ago, 1h throttle bypassed)",
                isWarning: false
            )
        case .recentlyScanned(let hours):
            return LogEntry(
                message: "⏰ Last scan was \(String(format: "%.1f", hours)) hours ago - skipping",
                isWarning: true
            )
        }
    }

    /// 决策落日志（**唯一落点**；AppCoordinator / QQPlayerApp 两处共用，避免文案与级别漂移）。
    static func log(_ decision: Decision) {
        let entry = logEntry(for: decision)
        if entry.isWarning {
            AppLog.warn(.general, entry.message)
        } else {
            AppLog.info(.general, entry.message)
        }
    }
}
