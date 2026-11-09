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
//  2. 推送批次是**歌维度子集**，帧 9 的 `lastOutboxID` = **max(已推给该 peer 的高水位,
//     本批实际末行 id)**（INV-35，2026-11-09）：高水位按 **(entity, row_key) 逐行**
//     持久化在 `sync_playback_carry_state`，跨重启有效、peer 重新对账时同口径清零。
//     ⇒ 对端把帧 9 记成 `sync_cursor` 后**只增不减**，不会被后到的小批覆盖成更小的值；
//     高水位同时并入 `sync_push_cursor`（`sendIncrement` 已推给该 peer 的增量位置），
//     否则「先推进数据增量、再传歌」这条常见序列仍会把对端游标顶回去；
//     已推过的同一行不再重推（空批 = 不发帧、不动游标、不记账）。
//     ⚠️ 抬升只到「真的推出去过的最大 id」：行 id 落在高水位之内、但从未随任何批次
//     发过的行（别的歌），仍会在**那首歌本轮被传输时**照常带上——判据是逐行账目，
//     不是「id ≤ 游标就跳过」（后者会永久漏推那些行）。
//     carry 本身不是游标驱动：每次传输仍按当前 outbox 重新计算（只是过滤掉已推过的行）。
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

    /// 身份解析的唯一入口（B1b）：路径键取数走它，本类型不再自带 SQL。
    private var identity: any SyncIdentityResolving {
        SyncContentHashResolver(database: database, libraryRoot: libraryRoot)
    }

    /// 参与携带的歌维度实体（= 无条件同步 ∩ 引用歌曲；playlist 不是歌维度）。
    /// **派生自唯一声明处 `SyncEntityRegistry`**，不再在这里手写过滤条件。
    static var trackScopedEntities: [SyncChangeEntity] { SyncEntityRegistry.trackScopedSyncedEntities }

    func trackFact(atRelativePath relativePath: String) -> SyncCollectionTrackFact? {
        guard let normalized = SyncManifestGenerator.normalizeRelativePath(relativePath) else { return nil }
        let absolutePath = libraryRoot.appendingPathComponent(normalized).path
        // 取数失败一律按「查不到」返回（协议约定不抛）。
        guard let row = (try? identity.trackIdentity(atAbsolutePath: absolutePath)) ?? nil else { return nil }
        return SyncCollectionTrackFact(
            stableId: row.stableId,
            relativePath: normalized,
            contentHash: row.contentHash
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
    /// （B1b：本实现搬到唯一身份入口 `SyncIdentityResolving.trackIdentity(atAbsolutePath:)`，
    /// 不再自写 SQL——同步线程约束（不扫全表）由入口一并承接。）
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
    /// carry 推送的已推行账（INV-35）：帧 9 游标下界 + 「不再重推已给过的行」。
    /// 缺省 = 自身 store（表 `sync_playback_carry_state`）；测试可注入内存替身。
    private let pushState: any SyncPlaybackCarryPushStateStoring
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
        facts: SyncPlaybackCarryFactsProviding? = nil,
        pushState: (any SyncPlaybackCarryPushStateStoring)? = nil
    ) {
        self.session = session
        self.peerID = peerID
        self.facts = facts ?? SyncPlaybackCarryDatabaseFacts(database: database, libraryRoot: libraryRoot)
        let store = SyncChangeLogStore(database: database)
        self.store = store
        self.pushState = pushState ?? store
        self.peer = SyncChangeLogPeer(
            session: session,
            store: store,
            applier: SyncChangeLogApplier(database: database),
            peerID: peerID,
            libraryRoot: libraryRoot
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
        // 已推行账。读失败按空处理 = 不过滤：宁可重推（对端 LWW 幂等），
        // 也绝不因为一次读账失败而漏推。
        let pushed = (try? pushState.pushedOutboxIDs(forPeer: peerID)) ?? [:]
        // 高水位 = max(carry 已推最大 id, **本端已推给该 peer 的增量位置**)：
        // 后者由 `sendIncrement` 维护（每个成功批次的帧 9 末行 id）。不并入它的话，
        // 「先推数据增量（游标 500）→ 再传歌触发 carry（批末行 2）」仍会把对端游标
        // 顶回 2 —— 同一类回退，只是换了个写入方。读失败按 0（保守：不抬升）。
        let carryHighWater = (try? pushState.carryHighWater(forPeer: peerID)) ?? 0
        let incrementHighWater = (try? store.pushCursor(forPeer: peerID)) ?? 0
        let highWater = max(carryHighWater, incrementHighWater)
        let plan = SyncPlaybackCarryPlanner.plan(
            scope: scope,
            facts: facts,
            alreadyPushed: pushed
        )
        // 空批（含「本批全部已推过」）= 不发帧（不产生空批次噪音），
        // **也不动对端游标、不记账**（高水位保持原值）。
        guard !plan.entries.isEmpty else { return plan }
        // INV-35（I1）：帧 9 的 `lastOutboxID` 只增不减 = max(已推高水位, 本批末行 id)。
        // 批内末行仍与 `SyncChangeLogPeer.handlePull` 的「本批实际末行」同口径（S3），
        // 只是再与高水位取大：后到的小批不会把对端已记下的位置顶低。
        let batchLastID = plan.entries.map(\.outboxID).max() ?? 0
        let lastOutboxID = SyncPlaybackCarryCursor.lastOutboxID(
            batchLastID: batchLastID,
            highWater: highWater
        )
        let payload = SyncChangeLogPushPayload(
            entries: plan.entries.map(Self.wireEntry),
            lastOutboxID: lastOutboxID
        )
        try session.sendApplicationFrame(
            type: .changeLogPush,
            payload: try JSONEncoder().encode(payload)
        )
        // 发送成功后才记账（失败 = 下一轮重推，幂等由对端 LWW 保证）。
        // 写账失败只告警不抛：帧已经发出去了，把失败翻转成 carry 阶段报错会
        // 掩盖「数据其实到了」这一事实；下轮重推是安全的。
        do {
            try pushState.recordCarryPush(plan.entries, lastOutboxID: lastOutboxID, forPeer: peerID)
        } catch {
            AppLog.warn(.sync, "⚠️ SyncPlaybackCarryPeer: carry 已推行账写入失败（下轮重推，幂等）：\(error)")
        }
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
