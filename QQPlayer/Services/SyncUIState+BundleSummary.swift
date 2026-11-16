//
//  SyncUIState+BundleSummary.swift
//  QQPlayer
//
//  P1b（2026-11-16）：从 `SyncUIState.swift` 原样搬出的「结果摘要 / 失败提示」一族
//  （结构预算：单文件 ≤ 600 行，语义零变化）。
//
//  仍是**纯值类型 + 纯函数**（零 IO / 零 SwiftUI / 零 DB），与主文件同口径：
//  不产生用户可见文案，只给 enum case 或 i18n key，本地化在 Mac 侧 View 做。
//

import Foundation

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
    /// 对端自报已一致（两侧同名同内容 → 本次零传输）的条目数
    var peerAlreadyHasCount: Int = 0
    /// 对端自报已一致的前 `peerAlreadyHasSampleLimit` 条路径（升序；超出的不截断地丢）
    var peerAlreadyHasSample: [String] = []
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
    /// F2：拉取方向收到但本端无对应歌曲的 aligned 歌词（丢弃；下一轮自动补发）
    var lyricsDiscarded: [String] = []
    /// F2：拉取方向收到但本端已有对齐结果 → 保留本端（只补不覆盖，未覆盖）
    var lyricsKeptLocal: [String] = []

    /// 实际传输文件数。
    var transferredCount: Int { pushedCount + pulledCount }

    /// 「对端已一致」例举条数上限（UI 只例举前 N 条，不刷屏）。
    static let peerAlreadyHasSampleLimit = 3

    /// 是否属于「对端已一致，无需传输」：计划里一条要传的都没有（零传输）、
    /// 但对端确实已有内容，且本次无失败/无中止。
    /// 为什么必须单独判：这套组合此前在结果区与「普通完成」长得一模一样。
    var isEmptyPlanAlreadyIdentical: Bool {
        isSuccess && transferredCount == 0 && peerAlreadyHasCount > 0
    }

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
            // 对端已一致：只从既有账目映射（`skipped` = 差集的 unchanged），UI 不补算。
            peerAlreadyHasCount: report.skipped.count,
            peerAlreadyHasSample: Array(report.skipped.prefix(peerAlreadyHasSampleLimit)),
            failedCount: sorted.count,
            failedItems: sorted,
            unresolvedCount: report.unresolvedCount,
            unknownPlaylistIDs: report.unknownPlaylistIDs,
            isEmptySelection: report.isEmptySelection,
            isLibraryWide: report.isLibraryWide,
            abortReason: report.pushAbortReason ?? report.pullAbortReason,
            lyricsDiscarded: report.lyricsDiscarded,
            lyricsKeptLocal: report.lyricsKeptLocal
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
