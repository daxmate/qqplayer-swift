//
//  SyncUIState.swift
//  QQPlayer
//
//  M6（T3，2026-09-11）同步界面**决策纯逻辑**（平台无关，可单测）。
//
//  背景：M6 同步页（Mac）要在 View 里做不少判断——能不能点「开始同步」、当前该
//  显示哪个阶段、进度怎么算、选中了多少内容、结果怎么汇总。仓库纪律：
//  **判断逻辑不许散在 View 里**（docs/m6-sync-ui-plan.md §8「新增 UI 决策纯逻辑
//  抽成类型」）。本文件就是那些判断的唯一事实源。
//
//  为什么放共享 Core（`QQPlayer/Services/`）而不是 `QQPlayer/Mac/`：
//  `QQPlayer/Mac/**` 全部被 iOS target 排除 → 任何单测都碰不到（M6 契约 A3）。
//  本文件是**纯值类型 + 纯函数**（零 IO、零 SwiftUI、零 DB），放这里才能被
//  QQPlayerTests 真跑（先例：`SyncHostGate` / `MacShortcutLogic`）。
//
//  ⚠️ 本文件不产生任何用户可见文案：所有需要用词的地方只返回 **enum case** 或
//  **i18n key 字符串**，真正的本地化在 Mac 侧 View 做（文案属于 UI 层）。
//

import Foundation

// MARK: - 能否开始同步

/// 「开始同步」按钮的可用性（不可用 = 各自的阻塞原因）。
enum SyncUIStartAvailability: Equatable, Sendable {
    /// 可开始（已连接 + 会话可用 + 非空选择 + 未在同步中）
    case ready
    /// 一台已配对设备都没有（先配对）
    case notPaired
    /// 有已配对设备，但对端当前未连接（去 iPhone 上连接）
    case notConnected
    /// 已连接，但会话未就绪（Mac 曲库根不存在 → 没接线，见 SyncHostCenter.handleSessionPhase）
    case libraryUnavailable
    /// 正在同步中
    case alreadyRunning
    /// 选择集为空（空选择 = 不推不拉）
    case emptySelection

    /// 能否开始。
    var canStart: Bool { self == .ready }
}

/// 可用性判定（无副作用）。
enum SyncUIStartGate {
    /// 判定顺序（先到先返回）：未配对 → 未连接 → 会话不可用 → 同步中 → 空选择 → 可开始。
    /// 为什么要这个顺序：连接类原因优先——它们对用户来说是「先解决这个」的前置条件，
    /// 未连接时空选择没有意义（提示先连线）。
    static func evaluate(
        hasPairedDevice: Bool,
        isConnected: Bool,
        hasSession: Bool,
        isRunning: Bool,
        isEmptySelection: Bool
    ) -> SyncUIStartAvailability {
        if !isConnected {
            return hasPairedDevice ? .notConnected : .notPaired
        }
        guard hasSession else { return .libraryUnavailable }
        if isRunning { return .alreadyRunning }
        if isEmptySelection { return .emptySelection }
        return .ready
    }
}

// MARK: - 界面阶段

/// 同步页的阶段（协调器状态 + 会话状态的合成结果）。
enum SyncUIPhase: Equatable, Sendable {
    /// 对端未连接
    case disconnected
    /// 空闲（可开始）
    case idle
    /// 对账中（等对端 manifest + 算差集）
    case planning
    /// 推送中（本端 → 对端）
    case pushing
    /// 拉取中（对端 → 本端）
    case pulling
    /// 完成（结果见 reportSummary）
    case done
    /// 失败（原因字符串；`cancelled` = 用户取消）
    case failed(String)

    /// 是否进行中（按钮切「取消」、进度可见）。
    var isBusy: Bool {
        switch self {
        case .planning, .pushing, .pulling: return true
        default: return false
        }
    }

    /// 是否终态。
    var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }

    /// 协调器状态 + 会话状态 → 界面阶段。
    /// 终态（done/failed）**不因掉线被覆盖**：否则用户刚跑完一次同步、对端刚好
    /// 断开，结果区就永远看不到（结果比连接态更值得保留）。
    static func resolve(isConnected: Bool, state: SyncCollectionSyncState) -> SyncUIPhase {
        switch state {
        case .idle: return isConnected ? .idle : .disconnected
        case .planning: return isConnected ? .planning : .disconnected
        case .pushing: return isConnected ? .pushing : .disconnected
        case .pulling: return isConnected ? .pulling : .disconnected
        case .done: return .done
        case let .failed(reason): return .failed(reason)
        }
    }
}

// MARK: - 进度

/// 文件级进度（M6 Q5 决策：N/M 粒度）。
struct SyncUIProgress: Equatable, Sendable {
    /// 当前传输方向。
    enum Direction: String, Equatable, Sendable {
        case none
        case push
        case pull
    }

    /// 界面阶段。
    var phase: SyncUIPhase
    /// 已传文件数。
    var completed: Int
    /// 本次计划传输文件总数（0 = 还没出计划 → 不确定态）。
    var total: Int
    /// 当前正在传的相对路径（nil = 无）。
    var currentPath: String?
    /// 方向。
    var direction: Direction

    static let idle = SyncUIProgress(phase: .idle, completed: 0, total: 0, currentPath: nil, direction: .none)

    /// 是否有确定进度（总数未知时不画确定进度条）。
    var isDeterminate: Bool { total > 0 }

    /// 完成后不越界：协调器有**已知限制**——推送失败会让推送控制器在拉取阶段
    /// 重排一次计划并重试，`onFileTransferred` 回调次数可能超过计划数
    /// （见 `SyncCollectionSyncCoordinator` 头注释）。UI 只按计划数封顶。
    var clampedCompleted: Int {
        guard total > 0 else { return 0 }
        return max(0, min(completed, total))
    }

    /// 进度比例（0…1；总数未知 = 0）。
    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(clampedCompleted) / Double(total)
    }

    /// 是否已跑到计划数。
    var isTransferFinished: Bool { total > 0 && clampedCompleted >= total }
}

/// 进度聚合（从协调器状态 + 账目 + 已传计数组装）。
enum SyncUIProgressAggregator {
    /// 本次计划传输的文件总数（推送 + 拉取）。
    static func total(for report: SyncCollectionSyncReport) -> Int {
        report.plannedPush.count + report.plannedPull.count
    }

    /// 当前方向（阶段决定；非传输阶段 = none）。
    static func direction(for phase: SyncUIPhase) -> SyncUIProgress.Direction {
        switch phase {
        case .pushing: return .push
        case .pulling: return .pull
        default: return .none
        }
    }

    /// 组装：总数取计划值，已传数封顶（见 `SyncUIProgress.clampedCompleted`）。
    static func make(
        phase: SyncUIPhase,
        report: SyncCollectionSyncReport,
        completed: Int,
        currentPath: String?
    ) -> SyncUIProgress {
        let total = total(for: report)
        let safeCompleted = total > 0 ? max(0, min(completed, total)) : 0
        return SyncUIProgress(
            phase: phase,
            completed: safeCompleted,
            total: total,
            currentPath: currentPath,
            direction: direction(for: phase)
        )
    }
}

// MARK: - 选择集行模型（纯值；由 ViewModel 从 DB 装配）

/// 歌单选项（选择区一行）。
struct SyncUIPlaylistOption: Equatable, Sendable, Identifiable {
    /// 本端歌单标识（slug；「收藏」用 `SyncCollectionSelection.favoritesPlaylistID`）
    var id: String
    /// 展示名（已本地化；收藏由调用方给本地化文案）
    var title: String
    /// 曲目数
    var trackCount: Int
    /// 该歌单曲目文件大小合计（已知部分）
    var totalBytes: Int64
    /// 其中文件大小未知（未入库 / 无 file_size）的曲目数
    var missingSizeCount: Int

    init(id: String, title: String, trackCount: Int, totalBytes: Int64 = 0, missingSizeCount: Int = 0) {
        self.id = id
        self.title = title
        self.trackCount = trackCount
        self.totalBytes = totalBytes
        self.missingSizeCount = missingSizeCount
    }

    /// 是否「收藏」伪歌单。
    var isFavorites: Bool { id == SyncCollectionSelection.favoritesPlaylistID }
}

/// 单曲选项（单曲级列表一行）。
struct SyncUITrackOption: Equatable, Sendable, Identifiable {
    /// 曲库内相对路径（选择集对账键口径）
    var relativePath: String
    /// 标题
    var title: String
    /// 歌手展示名（nil = 未知）
    var artistName: String?
    /// 文件大小（nil = 未知）
    var fileSize: Int64?

    var id: String { relativePath }
}

/// 全库规模事实（「全曲库」选择的大小/数量提示用）。
struct SyncUILibraryFacts: Equatable, Sendable {
    var trackCount: Int
    var totalBytes: Int64

    static let empty = SyncUILibraryFacts(trackCount: 0, totalBytes: 0)
}

// MARK: - 选择集模式（三级）

/// 选择区三级模式（Q4 决策：全曲库 / 歌单级（含收藏）/ 单曲级）。
enum SyncUISelectionMode: String, Equatable, Sendable, CaseIterable {
    /// 全曲库（高容量风险，需二次确认）
    case library
    /// 歌单级（含「收藏」伪歌单）
    case playlists
    /// 单曲级
    case tracks

    /// 模式 + 两级勾选池 → 选择集（唯一映射；勾选池跨模式保留，切模式不丢另一级的勾选）。
    static func selection(
        mode: SyncUISelectionMode,
        playlistIDs: Set<String>,
        trackPaths: Set<String>
    ) -> SyncCollectionSelection {
        switch mode {
        case .library: return .all
        case .playlists: return .playlists(playlistIDs.sorted())
        case .tracks: return .relativePaths(trackPaths.sorted())
        }
    }

    /// 选择集 → 模式（载入上次存档时用）。
    static func mode(for selection: SyncCollectionSelection) -> SyncUISelectionMode {
        switch selection {
        case .all: return .library
        case .playlists: return .playlists
        case .relativePaths: return .tracks
        }
    }
}

// MARK: - 选择集摘要

/// 选择集的规模摘要（选择区底部合计 + 全库二次确认文案用）。
struct SyncUISelectionSummary: Equatable, Sendable {
    /// 是否「全曲库」选择（高风险：必须二次确认）
    var isLibraryWide: Bool
    /// 选中歌单数
    var playlistCount: Int
    /// 选中曲目数
    var trackCount: Int
    /// 待传输字节合计（`isBytesPartial` = 下界）
    var totalBytes: Int64
    /// 是否有内容大小未知（未入库 / 未指纹 / 列表尚未加载）
    var isBytesPartial: Bool
    /// 是否空选择（不推不拉）
    var isEmpty: Bool
    /// 已选但本端已不存在的歌单标识（升序）
    var unknownPlaylistIDs: [String]

    static let empty = SyncUISelectionSummary(
        isLibraryWide: false,
        playlistCount: 0,
        trackCount: 0,
        totalBytes: 0,
        isBytesPartial: false,
        isEmpty: true,
        unknownPlaylistIDs: []
    )

    /// 是否需要二次确认（全库 = 高容量风险；用户 09-11 15:45 补充要求）。
    var requiresConfirmation: Bool { isLibraryWide }

    /// 人类可读大小。
    var sizeText: String { SyncUISizeText.humanReadable(bytes: totalBytes) }
}

/// 选择集摘要计算（纯函数）。
enum SyncUISelectionSummarizer {
    /// 按选择集形态汇总。`playlists` / `tracks` / `library` 是调用方从 DB 装配的
    /// 现有选项（会话内已加载的那些）——查不到的按「未知」记账，不编造数字。
    static func make(
        selection: SyncCollectionSelection,
        playlists: [SyncUIPlaylistOption],
        tracks: [SyncUITrackOption],
        library: SyncUILibraryFacts
    ) -> SyncUISelectionSummary {
        switch selection {
        case .all:
            return SyncUISelectionSummary(
                isLibraryWide: true,
                playlistCount: 0,
                trackCount: library.trackCount,
                totalBytes: library.totalBytes,
                isBytesPartial: false,
                isEmpty: false,
                unknownPlaylistIDs: []
            )

        case let .playlists(raw):
            let ids = SyncCollectionSelection.normalizePlaylistIDs(raw)
            guard !ids.isEmpty else { return .empty }
            let byID = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var trackCount = 0
            var bytes: Int64 = 0
            var missing = false
            var unknown: [String] = []
            for id in ids {
                guard let option = byID[id] else {
                    unknown.append(id)
                    continue
                }
                trackCount += option.trackCount
                bytes += option.totalBytes
                if option.missingSizeCount > 0 { missing = true }
            }
            return SyncUISelectionSummary(
                isLibraryWide: false,
                playlistCount: ids.count,
                trackCount: trackCount,
                totalBytes: bytes,
                isBytesPartial: missing || !unknown.isEmpty,
                isEmpty: false,
                unknownPlaylistIDs: unknown.sorted()
            )

        case let .relativePaths(raw):
            let paths = SyncFetchRequest.normalize(raw)
            guard !paths.isEmpty else { return .empty }
            let byPath = Dictionary(tracks.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
            var bytes: Int64 = 0
            var partial = false
            for path in paths {
                guard let option = byPath[path], let size = option.fileSize, size > 0 else {
                    partial = true
                    continue
                }
                bytes += size
            }
            return SyncUISelectionSummary(
                isLibraryWide: false,
                playlistCount: 0,
                trackCount: paths.count,
                totalBytes: bytes,
                isBytesPartial: partial,
                isEmpty: false,
                unknownPlaylistIDs: []
            )
        }
    }
}

// MARK: - 文案数值格式（纯函数；不含本地化）

/// 字节 → 人类可读（1024 进制，最多一位小数；确定性、无 locale 依赖）。
enum SyncUISizeText {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// 例：0 → "0 B"；1024 → "1 KB"；1536 → "1.5 KB"；4.2 GB 量级 → "4.2 GB"。
    static func humanReadable(bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        guard unit > 0 else { return "\(bytes) B" }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(format: "%.0f %@", rounded, units[unit])
        }
        return String(format: "%.1f %@", rounded, units[unit])
    }
}

/// 时长 → 短格式（"12:34" / "1:02:03"；无本地化，纯数字）。
enum SyncUIDurationText {
    static func short(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let minutes = total / 60
        let secs = total % 60
        let hours = minutes / 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes % 60, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - 结果摘要

/// 一条失败记录（结果区可展开清单一行）。
struct SyncUIFailedItem: Equatable, Sendable, Identifiable {
    /// 相对路径（传输级失败无法归属路径时为空串）
    var relativePath: String
    /// 原因（本地字符串常量，见 `SyncPushFailureReason` / `SyncFetchFailureReason`）
    var reason: String
    /// 是否推送方向（false = 拉取方向）
    var isPush: Bool

    var id: String { "\(isPush ? "push" : "pull")|\(relativePath)|\(reason)" }
}

/// 一次同步的结果摘要（数据源 = `SyncCollectionSyncCoordinator.report` **实时值**）。
struct SyncUIReportSummary: Equatable, Sendable {
    /// 推送送达数
    var pushedCount: Int = 0
    /// 拉取落盘数
    var pulledCount: Int = 0
    /// 两侧一致（零传输）数
    var skippedCount: Int = 0
    /// 失败数（= failedItems.count）
    var failedCount: Int = 0
    /// 失败清单（按路径升序；推送在前）
    var failedItems: [SyncUIFailedItem] = []
    /// 未解析曲目数（未指纹 / 未入库，本次跳过）
    var unresolvedCount: Int = 0
    /// 未知 / 已不存在的歌单标识（升序）
    var unknownPlaylistIDs: [String] = []
    /// 选择集为空（不推不拉）
    var isEmptySelection: Bool = false
    /// 全库选择
    var isLibraryWide: Bool = false
    /// 中止原因（推送优先；nil = 未中止）
    var abortReason: String?

    /// 实际传输文件数。
    var transferredCount: Int { pushedCount + pulledCount }

    /// 是否完全成功（无中止、无失败项）。
    var isSuccess: Bool { abortReason == nil && failedCount == 0 }

    /// 从协调器账目映射（唯一数据源；不在这里补算任何数字）。
    static func make(report: SyncCollectionSyncReport) -> SyncUIReportSummary {
        var items = report.pushFailed.map {
            SyncUIFailedItem(relativePath: $0.relativePath, reason: $0.reason, isPush: true)
        }
        items += report.pullFailed.map {
            SyncUIFailedItem(relativePath: $0.relativePath, reason: $0.reason, isPush: false)
        }
        // 排序：路径升序 → 推送在前（确定性，避免两次刷新顺序漂移）
        let sorted = items.sorted {
            ($0.relativePath, $0.isPush ? 0 : 1) < ($1.relativePath, $1.isPush ? 0 : 1)
        }
        return SyncUIReportSummary(
            pushedCount: report.pushed.count,
            pulledCount: report.pulled.count,
            skippedCount: report.skipped.count,
            failedCount: sorted.count,
            failedItems: sorted,
            unresolvedCount: report.unresolvedCount,
            unknownPlaylistIDs: report.unknownPlaylistIDs,
            isEmptySelection: report.isEmptySelection,
            isLibraryWide: report.isLibraryWide,
            abortReason: report.pushAbortReason ?? report.pullAbortReason
        )
    }
}

/// 失败原因码 → i18n key（纯映射；未识别码回落通用文案）。
enum SyncUIFailureReasonText {
    /// 未识别原因的回退 key。
    static let fallbackKey = "sync_passive_reason_other"

    static func key(for reason: String) -> String {
        switch reason {
        case SyncPushFailureReason.sendFailed,
             SyncPushFailureReason.receiveFailed,
             SyncFetchFailureReason.sendFailed,
             SyncFetchFailureReason.sessionClosed:
            return "sync_passive_reason_transfer"
        case SyncPushFailureReason.invalidPath,
             SyncFetchFailureReason.invalidPath,
             SyncFetchFailureReason.outOfRoot,
             SyncFetchFailureReason.notFound,
             SyncFetchFailureReason.notRegularFile:
            return "sync_passive_reason_path"
        case SyncPushFailureReason.landFailed:
            return "sync_passive_reason_save"
        case SyncPushFailureReason.localFileUnavailable:
            return "sync_run_reason_unavailable"
        default:
            return fallbackKey
        }
    }
}

// MARK: - 协调器终态 → 失败提示

/// 协调器失败原因里需要特殊提示的取值（本地常量，跨版本可加不可改）。
enum SyncUIFailureReason {
    /// 用户主动取消（协调器 `cancel()` 的固定取值）
    static let cancelled = "cancelled"
}

/// 会话掉线等原因引起的「进行中同步被中止」提示（纯值）。
enum SyncUIInterruption: Equatable, Sendable {
    /// 无中断
    case none
    /// 同步进行中会话断开（同步已取消）
    case sessionClosed
    /// 用户取消
    case cancelled

    /// 从「终态原因 + 是否同步中掉线」判定。
    static func resolve(phase: SyncUIPhase, didDisconnectWhileRunning: Bool) -> SyncUIInterruption {
        guard case let .failed(reason) = phase else { return .none }
        if didDisconnectWhileRunning { return .sessionClosed }
        return reason == SyncUIFailureReason.cancelled ? .cancelled : .none
    }
}
