//
//  SyncPlaybackCarryPlan.swift
//  QQPlayer
//
//  R3b（2026-09-11）同步方向改造 · **播放数据「跟歌走」计划器**（纯逻辑，零 IO）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  语义（docs/lan-sync-design.md §6.2 + §12b 决策 7/8）
//  ════════════════════════════════════════════════════════════════════════════
//  决策 8：播放数据**仅同步两端共有的歌**（content_hash 配对）+ **跟歌走**
//          （推/拉歌时把**这首歌的**播放数据一并带过去）。
//  决策 7：**绝不跨端删除**——取消收藏/删歌单等本地操作只在本地生效，
//          delete 变更不上线（判定走 SyncChangeLogDeletionPolicy 单一事实源）。
//
//  一次「携带」= 给定**本轮刚传输完的歌曲相对路径集合** + 本端曲库事实，
//  产出要随歌带走的播放数据条目（对账键 = entity + row_key；身份键 = content_hash）。
//
//  三条硬规则（本文件是唯一实现点）：
//  1. **只覆盖这次传输的歌**：不传的路径一律不带 —— 不做全库播放数据对账
//     （决策 10 的同一取向：同步集合 = 用户显式选择，不自动镜像）。
//  2. **只带两端都有的歌**：歌曲身份 = content_hash；对端在传输完成后没有该
//     content_hash（未配对）→ 跳过并记账，不伪造身份键。
//  3. **删除不上线**：delete 行一律不进携带批；同一键在本批末尾是 delete 时，
//     其更早的 upsert 也不带（复用 `SyncChangeLogDeletionPolicy.transmittableIndexes`，
//     不新写判定）。
//
//  为什么是纯逻辑：携带对象的取数是 DB 侧事实（stableId ↔ content_hash ↔ outbox 行），
//  与 R3a 的 `SyncCollectionFactsProviding` 同一取向——经注入协议取，绝不直连
//  `DatabaseManager.shared`。这样无模拟器 harness 与单测能真跑同一份实现。
//
//  ⚠️ 不做的事：本文件**不落库、不发送**。落库复用既有
//  `SyncChangeLogMapping` / `SyncChangeLogApplier` / LWW 语义，发送走既有帧 8/9
//  原语（见 SyncPlaybackCarryPeer.swift）。
//

import Foundation

// MARK: - 方向

/// 携带方向（两条线对称：推歌带本端数据走，拉歌带对端数据回）。
enum SyncPlaybackCarryDirection: String, Equatable, Sendable, CaseIterable {
    /// 本端 → 对端（推送阶段结束后：本端这批歌的播放数据带给对端）
    case push
    /// 对端 → 本端（拉取阶段结束后：对端这批歌的播放数据带回本端）
    case pull
}

// MARK: - 本端播放数据行（注入）

/// 本端一条**待携带**的播放数据变更行（facts 注入的最小视图；未过滤 delete）。
/// 字段与 `SyncChangeLogRow` 对齐，但**不依赖 GRDB**（本文件可进无模拟器 harness）。
struct SyncPlaybackCarryRow: Equatable, Sendable {
    /// 本端 outbox 行 id（升序 = 变更序；0 = 无 id 的合成行）。
    var outboxID: Int64
    /// 被同步实体（`SyncChangeEntity.rawValue`）。
    var entity: String
    /// 对账键第二段（本端形态：stableId / "stableId|playedAt" / "slug|stableId"）。
    var rowKey: String
    /// 变更类型（`SyncChangeOp.rawValue`）。
    var op: String
    /// 变更时刻（毫秒 since 1970；LWW 判据）。
    var updatedAtMs: Int64
    /// 行快照（JSON 字符串；delete 行为 nil）。
    var payloadJSON: String?

    init(
        outboxID: Int64 = 0,
        entity: String,
        rowKey: String,
        op: String,
        updatedAtMs: Int64,
        payloadJSON: String? = nil
    ) {
        self.outboxID = outboxID
        self.entity = entity
        self.rowKey = rowKey
        self.op = op
        self.updatedAtMs = updatedAtMs
        self.payloadJSON = payloadJSON
    }
}

/// 携带所需的**全部**本端曲库事实（注入）。
/// 实现方必须**不抛**（查询失败按「查不到」返回，单条跳过而不是炸整车）。
protocol SyncPlaybackCarryFactsProviding {
    /// 相对路径 → 曲目事实（stableId + content_hash）；不在本端曲库 / 未入库 → nil。
    func trackFact(atRelativePath relativePath: String) -> SyncCollectionTrackFact?
    /// 本端某首歌的全部播放数据变更行（**未过滤**；plan 自己按决策 7/8 过滤）。
    /// 顺序不作要求（plan 内部按 outboxID 排序）。
    func playbackRows(forTrackStableId stableId: String) -> [SyncPlaybackCarryRow]
}

// MARK: - 携带范围

/// 一次携带的范围（本轮传输了什么 + 传输完成后对端拥有哪些歌曲身份）。
struct SyncPlaybackCarryScope: Equatable, Sendable {
    var direction: SyncPlaybackCarryDirection
    /// 本轮**成功传输**的相对路径（两方向都可能是歌曲或歌词 wire 路径）。
    var transferredPaths: [String]
    /// 传输完成后**对端持有**的 content_hash 集合（配对判据，见 `afterTransfer`）。
    var peerContentHashes: Set<String>

    /// 传输完成后的对端身份集合 = 对端本轮 manifest 的 content_hash ∪ 本轮成功传输
    /// 歌曲的本地指纹（歌刚送过去/刚取回来，两端同时拥有 → 满足决策 8 的配对前提）。
    ///
    /// 为什么必须并上「传输歌曲的本地指纹」：对端 manifest 是**传输前**取的快照，
    /// 本轮补过去的歌在它里面要么缺席（对端此前没有）、要么指纹不同（内容不同被覆盖），
    /// 只看 manifest 会把「刚同步过去的歌」全部误判成未配对，携带永远为空。
    static func afterTransfer(
        direction: SyncPlaybackCarryDirection,
        transferredPaths: [String],
        peerEntries: [ManifestEntry],
        facts: SyncPlaybackCarryFactsProviding
    ) -> SyncPlaybackCarryScope {
        var hashes = Set(peerEntries.compactMap { entry -> String? in
            guard let hash = entry.contentHash, SyncLyricsNamespace.isValidContentHash(hash) else { return nil }
            return hash
        })
        for path in SyncFetchRequest.normalize(transferredPaths) {
            guard let fact = facts.trackFact(atRelativePath: path),
                  let hash = fact.contentHash,
                  SyncLyricsNamespace.isValidContentHash(hash)
            else { continue }
            hashes.insert(hash)
        }
        return SyncPlaybackCarryScope(
            direction: direction,
            transferredPaths: transferredPaths,
            peerContentHashes: hashes
        )
    }
}

// MARK: - 携带条目

/// 一条待携带的播放数据（对账键 + 身份键齐备；发送侧直接映射成 wire entry）。
struct SyncPlaybackCarryEntry: Equatable, Sendable {
    /// 本端 outbox 行 id（线上 `id`；0 = 无 id）。
    var outboxID: Int64
    /// 对账键第一段（实体）。
    var entity: String
    /// 对账键第二段（**本端形态** row_key；接收端按 contentHash 本地化改写）。
    var rowKey: String
    /// 变更类型（恒 upsert：delete 不上线，见决策 7）。
    var op: String
    /// 变更时刻（毫秒；对端 LWW 判据）。
    var updatedAtMs: Int64
    /// **身份键**：跨端歌曲 content_hash（配对/本地化用，非空）。
    var contentHash: String
    /// 行快照 JSON。
    var payloadJSON: String?

    /// 对账键（entity + row_key；与 LWW 键同口径）。
    var reconciliationKey: String { "\(entity)\u{1F}\(rowKey)" }
}

/// 一首被携带的歌（判定依据；诊断/UI/测试用）。
struct SyncPlaybackCarrySong: Equatable, Sendable {
    /// 本端曲库内相对路径（对账键口径）。
    var relativePath: String
    /// 本端 stableId。
    var stableId: String
    /// 身份键（content_hash）。
    var contentHash: String
    /// 随这首歌携带的播放数据条目数。
    var entryCount: Int
}

// MARK: - 计划

/// 一次携带的完整计划（纯值；空 `entries` = 本次无可携带数据）。
struct SyncPlaybackCarryPlan: Equatable, Sendable {
    var direction: SyncPlaybackCarryDirection
    /// 规范化后的本轮传输路径（升序；含被忽略的歌词路径）。
    var scopePaths: [String] = []
    /// 要携带的播放数据条目（按 outboxID 升序 = 变更序）。
    var entries: [SyncPlaybackCarryEntry] = []
    /// 被携带的歌曲（按 relativePath 升序）。
    var songs: [SyncPlaybackCarrySong] = []

    // ── 跳过明细（一律记账，不静默丢） ──────────────────────────────
    /// 歌词 wire 路径（播放数据以**歌曲**为单位，歌词条目不参与）
    var lyricsPathsIgnored: [String] = []
    /// 本端曲库查不到该路径（未入库 / 不在曲库根内）
    var skippedUnknownPath: [String] = []
    /// 本端未指纹（拿不到 content_hash → 无法配对）
    var skippedUnfingerprinted: [String] = []
    /// 对端没有该 content_hash（两端不共有 → 按决策 8 不带）
    var skippedNotPaired: [String] = []
    /// 两端都有、但本端这首歌没有可携带的播放数据（无变更 / 只有 delete 行）
    var skippedNoPlaybackData: [String] = []

    /// 是否无可携带内容。
    var isEmpty: Bool { entries.isEmpty }
    /// 携带的歌曲数。
    var songCount: Int { songs.count }
    /// 携带的条目数。
    var entryCount: Int { entries.count }
    /// 被携带歌曲的相对路径（升序）。
    var carriedPaths: [String] { songs.map(\.relativePath) }
}

// MARK: - 携带驱动（编排注入）

/// 播放数据「跟歌走」的会话级驱动（R3a 编排在推送/拉取阶段结束时调用）。
///
/// 生产实现 = `SyncPlaybackCarryPeer`（帧 8/9 原语 + 既有映射/LWW/落库）；
/// 注入缺省 = 不携带（编排行为与 R3a 完全一致）。协议本身不依赖 GRDB，
/// 因此无模拟器 harness 可直接注入替身真跑编排。
protocol SyncPlaybackCarryDriving: AnyObject {
    /// 推送阶段结束：本端这批歌的播放数据带给对端。返回携带计划（记账/诊断）。
    func carryPush(transferredPaths: [String], peerEntries: [ManifestEntry]) throws -> SyncPlaybackCarryPlan
    /// 拉取阶段结束：请求对端把这批歌的播放数据带过来。返回请求范围（两端共有歌曲）。
    func carryPull(transferredPaths: [String], peerEntries: [ManifestEntry]) throws -> SyncPlaybackCarryPlan
}

// MARK: - 计划器

enum SyncPlaybackCarryPlanner {
    /// 制定一次**推送方向**的携带计划（见文件头三条硬规则；纯函数，可单测）。
    ///
    /// 判定顺序（每条跳过的路径都记进对应的 `skipped*` 明细，绝不静默丢）：
    /// ① 路径规范化（非法路径丢弃）；歌词 wire 路径 → `lyricsPathsIgnored`
    /// ② 本端曲目事实：查不到 → `skippedUnknownPath`；`content_hash` 为空/非法 →
    ///    `skippedUnfingerprinted`
    /// ③ 配对（决策 8）：`content_hash` 不在 `scope.peerContentHashes` → `skippedNotPaired`
    /// ④ 同 content_hash 去重（一首歌多个路径只带一次，按路径升序取先到者）
    /// ⑤ 本端播放数据行 → 按 outboxID 升序 → 过滤 delete（决策 7，含批次抑制）→ 附着身份键
    ///    过滤后为空 → `skippedNoPlaybackData`
    static func plan(
        scope: SyncPlaybackCarryScope,
        facts: SyncPlaybackCarryFactsProviding
    ) -> SyncPlaybackCarryPlan {
        var plan = pairingPlan(scope: scope, facts: facts)
        guard !plan.songs.isEmpty else { return plan }

        var carriedSongs: [SyncPlaybackCarrySong] = []
        var entries: [SyncPlaybackCarryEntry] = []
        for song in plan.songs {
            let carried = carryEntries(
                rows: facts.playbackRows(forTrackStableId: song.stableId),
                contentHash: song.contentHash
            )
            guard !carried.isEmpty else {
                plan.skippedNoPlaybackData.append(song.relativePath)
                continue
            }
            var withCount = song
            withCount.entryCount = carried.count
            carriedSongs.append(withCount)
            entries.append(contentsOf: carried)
        }
        plan.songs = carriedSongs.sorted { $0.relativePath < $1.relativePath }
        plan.skippedNoPlaybackData.sort()
        plan.entries = entries.sorted { $0.outboxID < $1.outboxID }
        return plan
    }

    /// 只做**配对范围**（不取本端播放数据）：拉取方向用它确定「哪几首歌值得让
    /// 对端把数据带过来」——载荷由数据所有者（对端）产生，本端只负责给出共有歌曲集。
    /// 返回的 `songs[].entryCount` 恒为 0（本端不发出任何条目）。
    static func pairingPlan(
        scope: SyncPlaybackCarryScope,
        facts: SyncPlaybackCarryFactsProviding
    ) -> SyncPlaybackCarryPlan {
        var plan = SyncPlaybackCarryPlan(direction: scope.direction)
        let paths = SyncFetchRequest.normalize(scope.transferredPaths)
        plan.scopePaths = paths

        var songs: [SyncPlaybackCarrySong] = []
        var seenHashes: Set<String> = []

        for path in paths {
            // ① 歌词条目不承载播放数据（播放数据以歌曲为单位）
            if SyncLyricsNamespace.isLyricsPath(path) {
                plan.lyricsPathsIgnored.append(path)
                continue
            }
            // ② 本端曲库事实
            guard let fact = facts.trackFact(atRelativePath: path) else {
                plan.skippedUnknownPath.append(path)
                continue
            }
            guard let hash = fact.contentHash, SyncLyricsNamespace.isValidContentHash(hash) else {
                plan.skippedUnfingerprinted.append(path)
                continue
            }
            // ③ 两端共有（决策 8）
            guard scope.peerContentHashes.contains(hash) else {
                plan.skippedNotPaired.append(path)
                continue
            }
            // ④ 同一首歌只带一次（首见路径获胜；paths 已升序 = 确定性）
            guard seenHashes.insert(hash).inserted else { continue }

            songs.append(
                SyncPlaybackCarrySong(
                    relativePath: path,
                    stableId: fact.stableId,
                    contentHash: hash,
                    entryCount: 0
                )
            )
        }

        plan.songs = songs.sorted { $0.relativePath < $1.relativePath }
        return plan
    }

    /// 一批本端行 → 可携带条目（delete 不上线；身份键统一为歌曲 content_hash）。
    private static func carryEntries(
        rows: [SyncPlaybackCarryRow],
        contentHash: String
    ) -> [SyncPlaybackCarryEntry] {
        let ordered = rows.sorted { $0.outboxID < $1.outboxID }
        let transmittable = SyncChangeLogDeletionPolicy
            .transmittableIndexes(rows: ordered.map {
                SyncChangeLogPolicyRow(entity: $0.entity, rowKey: $0.rowKey, op: $0.op)
            })
            .map { ordered[$0] }
        return transmittable.map {
            SyncPlaybackCarryEntry(
                outboxID: $0.outboxID,
                entity: $0.entity,
                rowKey: $0.rowKey,
                op: $0.op,
                updatedAtMs: $0.updatedAtMs,
                contentHash: contentHash,
                payloadJSON: $0.payloadJSON
            )
        }
    }
}
