//
//  SyncPlaybackCarryPeer.swift
//  QQPlayer
//
//  R3b（2026-09-11）同步方向改造 · **播放数据「跟歌走」的生产接线**（帧 8/9 原语）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  分工（谁负责什么）
//  ════════════════════════════════════════════════════════════════════════════
//  - **计划**（带哪些歌、带哪些行）= `SyncPlaybackCarryPlanner`（纯逻辑，见
//    SyncPlaybackCarryPlan.swift）：本次传输的歌 ∩ 两端共有（content_hash 配对）
//    → 本端这批歌的播放数据行（delete 不上线）。
//  - **取数**（本端曲库事实）= `SyncPlaybackCarryDatabaseFacts`（本文件）：track 表
//    路径 → (stableId, content_hash)；sync_outbox → 该歌的播放数据行。行内歌曲引用
//    的判定复用 `SyncTrackReference`（M4-2a 单一事实源），**不新写解析**。
//  - **收发**（帧 8/9）= 既有 `SyncChangeLogPeer`（M4-1/M4-2a）：
//    · 推送方向：本类发 `change_log_push`（帧 9）携带本批条目；对端 `SyncChangeLogPeer`
//      收到后按 contentHash 本地化 → LWW → `SyncChangeLogApplier` 落库（本地缺歌挂起，
//      歌到位后 `SyncChangeLogReplay` 重放）。**不新造落库路径**。
//    · 拉取方向：本类发 `change_log_pull`（帧 8）；对端应答帧 9，由本类持有的
//      `SyncChangeLogPeer` 按同一套本地化/LWW/落库路径处理。
//
//  ⚠️ 已知边界（如实记录，不隐藏）：
//  1. 帧 8/9 **没有歌维度字段**，且 §12b 修订不允许改帧语义 → 「只带这次传输的歌」
//     在**发送侧**强制（推送方向由计划器收口）；拉取方向沿用既有**游标增量**语义
//     （对端 outbox 中 > 本端游标的行），按 content_hash 本地化，本地缺歌挂起不丢。
//  2. 推送批次是**歌维度子集**，帧 9 的 `lastOutboxID` 只有「本批实际末行 id」一种口径
//     （S3，2026-09-12 审计修复：与 `SyncChangeLogPeer.handlePull` 应答同口径；
//     空批不发帧、不动游标）→ 回执方（设备）的游标被推进到本批末行。
//     ⚠️ 批内末行可能小于对端已记下的位置（早先的批推得更靠后）→ 游标会回退；
//     本端没有「已推给该 peer 的位置」的反向记录，无法做单调保护。
//     v1 该游标是**惰性的**（移动端纯被动、永不主动 pull，§12b 决策 6）；若 v2 引入
//     移动端主动 pull，必须把 carry 与游标语义分开（见报告「遗留问题」）。
//     carry 本身不是游标驱动：每次传输按当前 outbox 重新计算。
//  3. `playback_position` 不在 `SyncChangeEntity.v1Synced`（本地载体 = UserDefaults），
//     不参与本携带；歌单结构（playlist 行）非歌维度，走决策 9 的选择集同步。
//
//  线程：会话线程（NW 队列）同步驱动；本类不持有可变状态（每次调用现算现发）。
//

import Foundation
@preconcurrency import GRDB

// MARK: - 本端曲库事实（生产的 facts 实现）

/// 生产实现：track 表（路径 → stableId/content_hash）+ sync_outbox（该歌的播放数据行）。
///
/// 取数失败一律按「查不到」返回（协议约定不抛）：单条跳过，绝不炸整车。
struct SyncPlaybackCarryDatabaseFacts: SyncPlaybackCarryFactsProviding {
    let database: DatabaseManager
    /// 曲库根（相对路径 → 绝对路径；track.path 存绝对路径）。
    let libraryRoot: URL

    /// 参与携带的歌维度实体（与 `SyncChangeEntity.v1Synced` 一致，去掉非歌维度的 playlist）。
    static let trackScopedEntities: [SyncChangeEntity] = SyncChangeEntity.v1Synced.filter { $0 != .playlist }

    func trackFact(atRelativePath relativePath: String) -> SyncCollectionTrackFact? {
        guard let normalized = SyncManifestGenerator.normalizeRelativePath(relativePath) else { return nil }
        let absolutePath = libraryRoot.appendingPathComponent(normalized).path
        let row: (String, String?)? = try? database.read { db in
            try Self.trackRow(db, atAbsolutePath: absolutePath)
        }
        guard let row else { return nil }
        return SyncCollectionTrackFact(
            stableId: row.0,
            relativePath: normalized,
            contentHash: row.1
        )
    }

    func playbackRows(forTrackStableId stableId: String) -> [SyncPlaybackCarryRow] {
        guard !stableId.isEmpty else { return [] }
        let rows: [SyncChangeLogRow] = (try? database.read { db in
            try SyncChangeLogRow
                .filter(Self.trackScopedEntities.map(\.rawValue).contains(Column("entity")))
                .order(Column("id"))
                .fetchAll(db)
        }) ?? []
        return rows.compactMap { row in
            // 行内歌曲引用判定走 M4-2a 单一事实源（favorite 行键 / 复合行键 / 快照回落）。
            guard let entity = row.entityValue,
                  SyncTrackReference.trackStableId(
                      entity: entity,
                      rowKey: row.rowKey,
                      payloadJSON: row.payloadJSON
                  ) == stableId
            else { return nil }
            return SyncPlaybackCarryRow(
                outboxID: row.id ?? 0,
                entity: row.entity,
                rowKey: row.rowKey,
                op: row.op,
                updatedAtMs: row.updatedAtMs,
                payloadJSON: row.payloadJSON
            )
        }
    }

    /// 按绝对路径取 (stable_id, content_hash)：先精确匹配，再退标准形态。
    /// 不做 `getTrack(byPath:)` 的全表回落（同步线程上不能容忍 O(库) 扫描）——
    /// 曲库清单里的路径与 track.path 同源（`SyncLocalLibraryScanner`），精确匹配即命中。
    private static func trackRow(_ db: Database, atAbsolutePath path: String) throws -> (String, String?)? {
        if let row = try query(db, path: path) { return row }
        let standardized = DatabaseManager.standardizedPath(path)
        if standardized != path, let row = try query(db, path: standardized) { return row }
        return nil
    }

    private static func query(_ db: Database, path: String) throws -> (String, String?)? {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT stable_id, content_hash FROM track WHERE path = ? LIMIT 1",
            arguments: [path]
        )
        guard let row else { return nil }
        let stableId: String = row["stable_id"]
        let contentHash: String? = row["content_hash"]
        return (stableId, contentHash)
    }
}

// MARK: - 会话级携带驱动（R3a 编排注入）

/// 播放数据「跟歌走」的会话级驱动：把携带接进 R3a 编排（推送/拉取阶段结束时调用）。
///
/// 协议刻意活在平台无关层、且**不依赖 GRDB**（`SyncCollectionSyncCoordinator` 与
/// 无模拟器 harness 都编得到）；注入缺省 = 不携带（R3a 行为零变化）。
final class SyncPlaybackCarryPeer: SyncPlaybackCarryDriving, @unchecked Sendable {
    private let session: SyncPeerSession
    private let facts: SyncPlaybackCarryFactsProviding
    private let store: SyncChangeLogStore
    /// 帧 8/9 的既有处理器：接收对端 carry（帧 9）+ 发起增量拉取（帧 8）。
    /// ⚠️ 必须强持有：它以 `[weak self]` 挂接会话回调，弃之则永不处理入站帧。
    private let peer: SyncChangeLogPeer

    /// 本端视角的对端 Device ID（游标键）。
    let peerID: String

    init(
        session: SyncPeerSession,
        libraryRoot: URL,
        peerID: String,
        database: DatabaseManager = .shared,
        facts: SyncPlaybackCarryFactsProviding? = nil
    ) {
        self.session = session
        self.peerID = peerID
        self.facts = facts ?? SyncPlaybackCarryDatabaseFacts(database: database, libraryRoot: libraryRoot)
        let store = SyncChangeLogStore(database: database)
        self.store = store
        self.peer = SyncChangeLogPeer(
            session: session,
            store: store,
            applier: SyncChangeLogApplier(database: database),
            peerID: peerID
        )
    }

    // MARK: 推送方向（本端 → 对端）

    /// 推送阶段结束：把本端这批歌的播放数据带给对端（帧 9）。
    /// 无条目 = 不发帧（不产生空批次噪音），仍返回计划供记账。
    @discardableResult
    func carryPush(
        transferredPaths: [String],
        peerEntries: [ManifestEntry]
    ) throws -> SyncPlaybackCarryPlan {
        let scope = SyncPlaybackCarryScope.afterTransfer(
            direction: .push,
            transferredPaths: transferredPaths,
            peerEntries: peerEntries,
            facts: facts
        )
        let plan = SyncPlaybackCarryPlanner.plan(scope: scope, facts: facts)
        // 空批 = 不发帧（不产生空批次噪音），**也不动对端游标**。
        guard !plan.entries.isEmpty else { return plan }
        // S3（2026-09-12 审计修复）：`lastOutboxID` = **本批实际最后一行 outbox id**，
        // 与 `SyncChangeLogPeer.handlePull` 应答同口径（不再取 outbox 全局末尾——
        // 那会把本批没带的行的游标越过去）。
        // ⚠️ 已知边界（v1 惰性游标下无影响）：批内末行可能**小于**对端已记下的位置
        // （早先的批推得更靠后）→ 游标会回退；`sync_cursor` 的键是「该游标描述的是
        // **谁**的 outbox」，本端查不到「已推给该 peer 的位置」这种反向记录，
        // 因此无法在本端做单调保护。v2 若引入移动端主动 pull，须把 carry 与游标
        // 语义分开（见文件头边界 2）。
        let batchLastID = plan.entries.map(\.outboxID).max() ?? 0
        let payload = SyncChangeLogPushPayload(
            entries: plan.entries.map(Self.wireEntry),
            lastOutboxID: batchLastID
        )
        try session.sendApplicationFrame(
            type: .changeLogPush,
            payload: try JSONEncoder().encode(payload)
        )
        return plan
    }

    // MARK: 拉取方向（对端 → 本端）

    /// 拉取阶段结束：请求对端把这批歌的播放数据带过来（帧 8）。
    /// 应答帧 9 由持有的 `SyncChangeLogPeer` 处理（本地化 → LWW → 落库 / 挂起）。
    /// 返回「这批歌里两端共有」的范围（`songs[].entryCount` 恒 0：本端不发出条目）。
    @discardableResult
    func carryPull(
        transferredPaths: [String],
        peerEntries: [ManifestEntry]
    ) throws -> SyncPlaybackCarryPlan {
        let scope = SyncPlaybackCarryScope.afterTransfer(
            direction: .pull,
            transferredPaths: transferredPaths,
            peerEntries: peerEntries,
            facts: facts
        )
        let plan = SyncPlaybackCarryPlanner.pairingPlan(scope: scope, facts: facts)
        try peer.sendPull()
        return plan
    }

    /// 携带条目 → 线上 entry（字段一一对应；`contentHash` = 身份键）。
    static func wireEntry(_ entry: SyncPlaybackCarryEntry) -> SyncChangeLogWireEntry {
        SyncChangeLogWireEntry(
            id: entry.outboxID,
            entity: entry.entity,
            rowKey: entry.rowKey,
            op: entry.op,
            updatedAtMs: entry.updatedAtMs,
            contentHash: entry.contentHash,
            payloadJSON: entry.payloadJSON
        )
    }
}
