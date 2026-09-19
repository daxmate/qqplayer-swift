//
//  DatabaseMigrationSupport.swift
//  QQPlayer
//
//  迁移完成门与诊断数据类型：LegacyTrackMigrationGate / ContentHashBackfillMarker /
//  ContentHashBackfillOutcome / IdentityCensus。
//
//  2026-09-19 从 DatabaseManager.swift 原样搬出（纯搬家）。
//

import Foundation

// MARK: - 旧库迁移完成门（审计 2026-09-12 D1）

/// `migrateDatabaseIfNeeded` 的两步全表迁移（同路径去重 + filename→path stableId）
/// 的完成门 —— **唯一决策点**。
///
/// 语义：只有两步都成功才允许上锁。此前只要进入过迁移块就置位，任一步失败
/// （例如 stable_id 更新撞 `idx_track_stable_id` 中断循环）都会被永久固化，
/// 之后不再重试 → 半迁移状态：部分行停在旧 filename id，其 favorite /
/// playlist_item / play_history 与后续新入库的 path id 分叉。
///
/// 键提到 v3：v2 时代可能已被失败路径误置位的库因此重跑一次
/// （两步迁移均幂等，重跑只多一次启动成本）。
enum LegacyTrackMigrationGate {
    static let completionKey = "database.legacyTrackMigrationsCompleted.v3"

    /// 完成门判定（纯函数，可单测）。
    static func shouldMarkCompleted(pathDedupSucceeded: Bool, stableIdMigrationSucceeded: Bool) -> Bool {
        pathDedupSucceeded && stableIdMigrationSucceeded
    }

    static func isCompleted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completionKey)
    }

    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completionKey)
    }
}

// MARK: - content_hash 回填运行标记（替代已退役的一次性完成门）

/// content_hash 回填的**运行标记**（非完成门）：只记录「上次跑过的时间」，
/// **不参与跳过判定** —— 回填每次启动都跑（零 NULL 行时只是一次索引查询）。
///
/// 为何退役一次性门：该门一旦置位，NULL 指纹永不重试；而指纹缺失的成因不止
/// 「存量老库」（还有入库时文件尚未就绪、云端未下载等），这些行即使文件一直在
/// 本地也永远拿不到身份键 → 跨端同步永久把对端 stableId 落成孤儿行。省下的却是
/// 可忽略的一次索引查询。故改为「每次都试 + 只跳过读不了的文件」。
/// 保留标记键仅为诊断（排查「回填上次何时跑、跑没跑」）。
/// 旧 key `database.contentHashBackfillCompleted.v1` 已退役，启动时由
/// `removeRetiredCompletionGate` 清理，避免历史遗留的 true 误导排查。
enum ContentHashBackfillMarker {
    /// 上次回填时间（Unix 秒；0/缺失 = 本机从未跑过）。
    static let lastRunKey = "database.contentHashBackfillLastRun.v1"
    /// 已退役的一次性完成门（仅用于启动清理，任何路径都不得再回读它做判定）。
    static let retiredCompletionKey = "database.contentHashBackfillCompleted.v1"

    static func lastRunDate(defaults: UserDefaults = .standard) -> Date? {
        let seconds = defaults.double(forKey: lastRunKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    static func markRun(defaults: UserDefaults = .standard, at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: lastRunKey)
    }

    /// 清理旧一次性门。
    /// - Returns: 是否真的清了（旧库升级后第一次启动为 true，仅打印用）。
    @discardableResult
    static func removeRetiredCompletionGate(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: retiredCompletionKey) != nil else { return false }
        defaults.removeObject(forKey: retiredCompletionKey)
        return true
    }
}

// MARK: - content_hash 回填结果

/// 一次 content_hash 回填的结果。
struct ContentHashBackfillOutcome: Equatable, Sendable {
    /// 本次新填入的 content_hash（顺序 = 扫描顺序）。启动路径据此重放挂起变更。
    let filledHashes: [String]
    /// 因 iCloud 云端未下载跳过的曲目数（下次启动重试，不置任何永久门）。
    let skippedCloudOnly: Int
    /// 本次扫到的 NULL 指纹候选行数（诊断用；0 = 零 NULL 行，只花了一次索引查询）。
    let candidateCount: Int
}

// MARK: - 身份缺失普查

/// 身份缺失普查结果（只读诊断）：身份键缺口的三个面。
struct IdentityCensus: Equatable, Sendable {
    /// ① track.content_hash 为 NULL/空 的行数。
    var nullHash: Int
    /// ② play_history.track_stable_id 在 track 表找不到的行数（孤儿）。
    var danglingHistory: Int
    /// ③ favorite.track_stable_id 悬空行数。
    var danglingFavorite: Int
    /// ③ playlist_item.track_stable_id 悬空行数。
    var danglingItem: Int

    var summaryLine: String {
        "🔎 Identity census: nullHash=\(nullHash) danglingHistory=\(danglingHistory) "
            + "danglingFavorite=\(danglingFavorite) danglingItem=\(danglingItem)"
    }
}
