//
//  SyncChangeLogMapper.swift
//  QQPlayer
//
//  局域网同步（S2, M4-2a）**收发两侧的映射变换**：行内歌曲引用提取（`SyncTrackReference`）、
//  未定位原因 / 本地化结果 / 发送侧身份缺口诊断（`SyncEntryUnresolvedReason` /
//  `SyncEntryLocalization` / `SyncWireMissingIdentity` / `SyncWireEntryBatch`），以及
//  发送侧 wire 打包与接收侧本地化（`SyncChangeLogMapper`：outbox 行 → wire entry；
//  wire entry → 本地 stableId）。
//
//  2026-09-21 从 SyncChangeLogMapping.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Sync/SyncChangeLogMapping.swift            — 身份唯一入口（SyncContentHashResolver）+ 歌词映射生产实现
//    · Services/SyncChangeLogDanglingRepair.swift — T15b 出站悬空引用对账修复
//
import Foundation
@preconcurrency import GRDB

// MARK: - 行内歌曲引用提取

/// 从被同步实体行里提取"它引用的歌曲本地 stableId"；不引用歌曲的实体（歌单）返回 nil。
enum SyncTrackReference {
    /// 该实体是否引用歌曲（playlist 只是结构，不含歌曲键）。
    /// **派生自唯一声明处 `SyncEntityRegistry`**（每个实体的身份键要求登记在注册表里，
    /// 不再在这里手写判定表达式——INV-6 的风险点正是「新增实体忘表态 → 默认 true 被
    /// 判未定位」，现在漏登记会被 CI 的 `everyEntityCaseIsRegistered` 抓住）。
    static func referencesTrack(_ entity: SyncChangeEntity) -> Bool {
        SyncEntityRegistry.referencesTrack(entity)
    }

    /// 行内歌曲引用：优先取 row_key（跨端行键即承载引用），row_key 形态不符时回落
    /// 读 payload 快照。两者都取不到 = nil（该行没有可用歌曲键）。
    static func trackStableId(entity: SyncChangeEntity, rowKey: String, payloadJSON: String?) -> String? {
        switch entity {
        case .favorite, .playbackPosition:
            return rowKey.isEmpty ? nil : rowKey
        case .playHistory:
            // row_key = "\(trackStableId)|\(playedAt)"
            if let parsed = SyncChangeLogApplier.parseCompositeRowKey(rowKey) { return parsed.0 }
            return (try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: payloadJSON))?.trackStableId
        case .playlistItem:
            // row_key = "\(playlistSlug)|\(trackStableId)"
            if let parsed = SyncChangeLogApplier.splitRowKey(rowKey) { return parsed.1 }
            return (try? SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: payloadJSON))?.trackStableId
        case .playlist:
            return nil
        }
    }
}

// MARK: - 本地化结果

/// 接收侧「未定位」的成因（面板/诊断用，单一事实源）。
enum SyncEntryUnresolvedReason: String, Equatable, Sendable {
    /// 该行引用歌曲，但线上 entry 没有可用身份键（contentHash nil/空）——无法定位
    /// 到本地歌曲（发送侧拿不到本地指纹，或对端是老 peer）。
    case missingIdentityKey = "missing_identity_key"
}

/// 接收侧一条线上 entry 的本地化结果。
enum SyncEntryLocalization: Equatable {
    /// 命中身份键（内容指纹或曲库相对路径）：row_key 与 payload 歌曲引用已改写为
    /// **本地 stableId**。
    case mapped(SyncChangeLogRow)
    /// 无需映射：该行不引用歌曲（歌单）/ 未知实体 → M4-1 原样透传应用。
    case passThrough(SyncChangeLogRow)
    /// 本地还没有这首歌（两把键都定位不到本地 stableId）→ 挂起，歌到后重放。
    /// `pendingKey` = 挂起表行键（命名空间见 `SyncPendingKey`；内容指纹 / `rel:{路径}`）。
    case suspended(pendingKey: String, remoteRow: SyncChangeLogRow)
    /// 第二身份（相对路径）命中**多行**（歧义）→ **不落库、不挂起**，只计数披露：
    /// 两首本地曲目同路径，选哪首都是猜；挂起也没意义（歌已在，再等也不会变唯一）。
    case ambiguous(key: SyncRemoteKey, candidateCount: Int, remoteRow: SyncChangeLogRow)
    /// 两把键都拿不到 → **不落库、不挂起**，只计数：落库会写出 JOIN track 永不匹配的
    /// 孤儿业务行（界面毫无变化却显示「应用 N 条」），挂起又无键可挂。
    case unresolved(reason: SyncEntryUnresolvedReason, remoteRow: SyncChangeLogRow)

    /// 本地化后的行（挂起/歧义/未定位分支 = 未改写的远端行，供挂起存储 / 诊断使用）。
    var row: SyncChangeLogRow {
        switch self {
        case .mapped(let row), .passThrough(let row), .suspended(_, let row),
             .ambiguous(_, _, let row), .unresolved(_, let row):
            return row
        }
    }
}

// MARK: - 发送侧身份缺口诊断

/// 发送侧一行「缺身份键」的诊断（只用于计数 / 日志，不上线）。
///
/// ⚠️ 口径（2026-09-15 身份兜底包）：**缺身份键 = 两把键都拿不到**。
/// 「有 track 行、指纹为空但相对路径算得出」**不再算缺键**——那时 wire entry 会带上
/// `relativePath`，对端靠第二身份照样能落库。
struct SyncWireMissingIdentity: Equatable, Sendable {
    /// 缺键成因（必须可区分，面板与修复手段都不同）。
    enum Reason: String, Equatable, Sendable {
        /// ① 行引用的 stableId 在本地 `track` 表里**没有行**（两把键都无从谈起）。
        case unknownTrack = "unknown_track"
        /// ② 有行，但指纹为空**且**相对路径也算不出（`track.path` 不在曲库根内 / 为空）。
        /// 修复手段 = 等指纹回填（或把文件放回曲库根），故与 ① 分开报。
        case emptyContentHash = "empty_content_hash"
    }

    var entity: String
    var rowKey: String
    var trackStableId: String
    var reason: Reason
}

/// 发送侧取数结果：wire 条目 + 缺身份键明细（`wireEntries` 签名不变，这是带诊断的入口）。
struct SyncWireEntryBatch: Equatable, Sendable {
    var entries: [SyncChangeLogWireEntry] = []
    var missingIdentity: [SyncWireMissingIdentity] = []
}

// MARK: - 收发两侧的映射变换

/// changeLog 帧的跨端映射变换（发送侧填身份键 / 接收侧本地化）。
struct SyncChangeLogMapper {
    let database: DatabaseManager
    /// 曲库根（**必传**）：相对路径第二身份的换算基准（传给唯一身份入口）。
    let libraryRoot: URL

    init(database: DatabaseManager, libraryRoot: URL) {
        self.database = database
        self.libraryRoot = libraryRoot
    }

    private var resolver: SyncContentHashResolver {
        SyncContentHashResolver(database: database, libraryRoot: libraryRoot)
    }

    // MARK: 发送侧

    /// outbox 行批 → wire entry 批（逐行按歌曲引用查 track 取 content_hash）。
    /// 一个读事务内完成，避免逐行开关事务。
    ///
    /// ⚠️ 签名保持（两端调用点都在用）；需要「哪些行缺身份键」时用
    /// `wireEntriesDetailed`（本方法就是它的 `.entries`，同一事实源）。
    func wireEntries(_ rows: [SyncChangeLogRow]) throws -> [SyncChangeLogWireEntry] {
        try wireEntriesDetailed(rows).entries
    }

    /// 带诊断的发送侧取数：wire 条目 + **缺身份键明细**（区分「本地没有该 track 行」
    /// 与「有行但指纹空且相对路径算不出」）。原实现静默填 nil、零计数，调用方（handlePull /
    /// sendIncrement）完全看不见缺口——这正是「同步成功但界面毫无变化」的发送侧成因。
    ///
    /// 取键一律走唯一身份入口 `remoteTrackIdentity`（不在此另写 track SQL）：
    /// - 入口返 nil（无 track 行） → 缺键（`.unknownTrack`）
    /// - 指纹可用 → 只填 `contentHash`（与今天逐字一致）
    /// - 指纹空但相对路径可用 → 只填 `relativePath`（**不算缺键**）
    /// - 两把键都无 → 缺键（`.emptyContentHash`）
    func wireEntriesDetailed(_ rows: [SyncChangeLogRow]) throws -> SyncWireEntryBatch {
        try database.read { db in
            var batch = SyncWireEntryBatch()
            batch.entries.reserveCapacity(rows.count)
            for row in rows {
                var identity: SyncRemoteTrackIdentity?
                if let entity = row.entityValue,
                   let trackStableId = SyncTrackReference.trackStableId(
                       entity: entity,
                       rowKey: row.rowKey,
                       payloadJSON: row.payloadJSON
                   ) {
                    identity = try SyncContentHashResolver.remoteTrackIdentity(
                        db,
                        forTrackStableId: trackStableId,
                        libraryRoot: libraryRoot
                    )
                    if let identity, identity.isEmpty {
                        batch.missingIdentity.append(SyncWireMissingIdentity(
                            entity: row.entity,
                            rowKey: row.rowKey,
                            trackStableId: trackStableId,
                            reason: .emptyContentHash
                        ))
                    } else if identity == nil {
                        batch.missingIdentity.append(SyncWireMissingIdentity(
                            entity: row.entity,
                            rowKey: row.rowKey,
                            trackStableId: trackStableId,
                            reason: .unknownTrack
                        ))
                    }
                }
                batch.entries.append(Self.wireEntry(
                    row,
                    contentHash: identity?.contentHash,
                    relativePath: identity?.relativePath
                ))
            }
            return batch
        }
    }

    /// 纯变换（无 IO；发送侧与测试共用）。
    /// `relativePath` 只在**第一身份缺失**时传入（调用方已按此收口；入口也不会同时给两把）。
    static func wireEntry(
        _ row: SyncChangeLogRow,
        contentHash: String?,
        relativePath: String? = nil
    ) -> SyncChangeLogWireEntry {
        SyncChangeLogWireEntry(
            id: row.id ?? 0,
            entity: row.entity,
            rowKey: row.rowKey,
            op: row.op,
            updatedAtMs: row.updatedAtMs,
            contentHash: contentHash,
            relativePath: contentHash == nil ? relativePath : nil,
            payloadJSON: row.payloadJSON
        )
    }

    // MARK: 接收侧

    /// 线上 entry → 本地化结果（见 SyncEntryLocalization）。
    ///
    /// 判定**全部**发生在唯一身份入口内部（`SyncIdentityResolving.localizeRemoteTrack`），
    /// 这里只把 (contentHash, relativePath) 打包交给入口、把 verdict 映射成落库动作。
    func localize(_ entry: SyncChangeLogWireEntry) throws -> SyncEntryLocalization {
        let remoteRow = Self.remoteRow(entry)
        guard let entity = SyncChangeEntity(rawValue: entry.entity) else {
            return .passThrough(remoteRow) // 未知实体：交对账/应用层按未知忽略
        }
        // 不引用歌曲（歌单）→ 没有跨端身份键也无所谓，原样透传
        guard SyncTrackReference.referencesTrack(entity) else {
            return .passThrough(remoteRow)
        }
        let identity = SyncRemoteTrackIdentity(
            contentHash: entry.contentHash,
            relativePath: entry.relativePath
        )
        switch try resolver.localizeRemoteTrack(identity) {
        case let .resolved(stableId, _):
            // 两把键命中都走同一改写（相对路径命中也必须改写 row_key/payload）。
            return .mapped(Self.rewrite(remoteRow, entity: entity, localStableId: stableId))
        case let .suspended(pendingKey):
            return .suspended(pendingKey: pendingKey, remoteRow: remoteRow)
        case let .ambiguous(key, candidateCount):
            return .ambiguous(key: key, candidateCount: candidateCount, remoteRow: remoteRow)
        case .unresolved:
            return .unresolved(reason: .missingIdentityKey, remoteRow: remoteRow)
        }
    }

    /// wire entry → 远端 outbox 行（保留远端 id：merge 排序键 (updated_at, id) 需要它）。
    static func remoteRow(_ entry: SyncChangeLogWireEntry) -> SyncChangeLogRow {
        SyncChangeLogRow(
            id: entry.id > 0 ? entry.id : nil,
            entity: SyncChangeEntity(rawValue: entry.entity) ?? .favorite,
            rowKey: entry.rowKey,
            op: SyncChangeOp(rawValue: entry.op) ?? .upsert,
            updatedAtMs: entry.updatedAtMs,
            payloadJSON: entry.payloadJSON
        )
    }

    // MARK: 本地化改写（row_key + payload 歌曲引用 → 本地 stableId）

    /// 把远端行的歌曲引用改写成本地 stableId。playlist 不改（无歌曲键）。
    /// 复合 row_key 的构造段（playedAt / playlistSlug）优先取 row_key，取不到时回落
    /// payload 快照；两者都取不到则只改写 payload 能改的部分（row_key 保持远端值，
    /// 应用层会因解析不出本地键而幂等跳过）。
    static func rewrite(
        _ row: SyncChangeLogRow,
        entity: SyncChangeEntity,
        localStableId: String
    ) -> SyncChangeLogRow {
        var rewritten = row
        switch entity {
        case .favorite:
            rewritten.rowKey = localStableId
            rewritten.payloadJSON = rewriteFavoritePayload(row.payloadJSON, localStableId)
        case .playHistory:
            let playedAt = SyncChangeLogApplier.parseCompositeRowKey(row.rowKey)?.1
                ?? (try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: row.payloadJSON))?.playedAt
            guard let playedAt else { break }
            rewritten.rowKey = "\(localStableId)|\(playedAt)"
            rewritten.payloadJSON = rewritePlayHistoryPayload(row.payloadJSON, localStableId)
        case .playlistItem:
            let slug = SyncChangeLogApplier.splitRowKey(row.rowKey)?.0
                ?? (try? SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: row.payloadJSON))?.playlistSlug
            guard let slug else { break }
            rewritten.rowKey = "\(slug)|\(localStableId)"
            rewritten.payloadJSON = rewritePlaylistItemPayload(row.payloadJSON, localStableId)
        case .playbackPosition:
            rewritten.rowKey = localStableId
            rewritten.payloadJSON = rewritePlaybackPositionPayload(row.payloadJSON, localStableId)
        case .playlist:
            break
        }
        return rewritten
    }

    /// 以下 rewrite* 均：payload 存在且能解码 → 改歌曲引用后重编码；payload 为 nil
    /// （delete 行）或解码失败 → 原值返回（应用层已有对应错误处理，不在此吞掉语义）。
    private static func rewriteFavoritePayload(_ payloadJSON: String?, _ localStableId: String) -> String? {
        guard var snapshot = try? SyncSnapshotCodec.decode(SyncFavoriteSnapshot.self, from: payloadJSON) else {
            return payloadJSON
        }
        snapshot.trackStableId = localStableId
        return (try? SyncSnapshotCodec.encode(snapshot)) ?? payloadJSON
    }

    private static func rewritePlayHistoryPayload(_ payloadJSON: String?, _ localStableId: String) -> String? {
        guard var snapshot = try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: payloadJSON) else {
            return payloadJSON
        }
        snapshot.trackStableId = localStableId
        return (try? SyncSnapshotCodec.encode(snapshot)) ?? payloadJSON
    }

    private static func rewritePlaylistItemPayload(_ payloadJSON: String?, _ localStableId: String) -> String? {
        guard var snapshot = try? SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: payloadJSON) else {
            return payloadJSON
        }
        snapshot.trackStableId = localStableId
        return (try? SyncSnapshotCodec.encode(snapshot)) ?? payloadJSON
    }

    private static func rewritePlaybackPositionPayload(_ payloadJSON: String?, _ localStableId: String) -> String? {
        guard var snapshot = try? SyncSnapshotCodec.decode(SyncPlaybackPositionSnapshot.self, from: payloadJSON) else {
            return payloadJSON
        }
        snapshot.trackStableId = localStableId
        return (try? SyncSnapshotCodec.encode(snapshot)) ?? payloadJSON
    }
}
