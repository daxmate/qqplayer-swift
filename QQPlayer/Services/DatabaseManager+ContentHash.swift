//
//  DatabaseManager+ContentHash.swift
//  QQPlayer
//
//  content_hash（跨端身份键）的流式计算与惰性回填（M3-1）。
//
//  2026-09-19 从 DatabaseManager.swift 原样搬出（纯搬家）。
//
import CryptoKit
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
    // MARK: - content_hash（M3-1）

    /// 文件存在则流式计算 SHA-256；不存在/读失败返回 nil（调用方按"未指纹"
    /// 处理，后续 upsert 或惰性回填会再试）。复用 Sync/SyncFileChecksum（共享实现，
    /// 协议目录只读），不另起哈希逻辑。
    ///
    /// iCloud dataless（云端未下载）文件同样返回 nil 并**不读取内容**——流式读取会
    /// 触发云端下载并长时间阻塞（实测 20+ 分钟不返回），是启动主线程卡死的根因。
    /// 可用性判定注入以便单测；默认走唯一判定 CloudFileAvailability。
    /// 入参接受**绝对路径或存储形态**（`track.path` 两种形态都算）：
    /// 相对形态先经 `LibraryRoot` 解回绝对 URL 再读文件内容。
    static func contentHashIfFilePresent(
        atPath path: String,
        isLocallyAvailable: (URL) -> Bool = CloudFileAvailability.isLocallyAvailable
    ) -> String? {
        let url = LibraryRoot.absoluteURL(forStoredPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard isLocallyAvailable(url) else { return nil }
        return try? SyncFileChecksum.sha256Hex(ofFile: url)
    }

    /// **清单 / 对账取「跨端身份键」的唯一兜底入口**（2026-09-28 批 B）。
    ///
    /// 为什么必须收口到一处（缺陷形状）：清单 / 对账链路上取 `content_hash` 的地方此前
    /// 各自处理「列为空」——`SyncLocalLibraryScanner` / `SyncLocalLibraryDescriptor.contentHash`
    /// 原地现算（复用 `contentHashIfFilePresent`）但**不写回**（每轮重算、且各写一遍同一语义）；
    /// 而「对端内容清单」（`DatabaseSyncPeerLibraryFacts`）**直接读裸列**，`content_hash` 为
    /// NULL 时永远拿不到身份键 ⇒ 同一首歌在两端命名不同（`歌手 - 标题` vs `标题-歌手`）时
    /// 判不出「对端已有同内容」⇒ 重复推送 / 重复落盘。
    ///
    /// 本入口统一口径：列为空且文件本地存在 → 现场计算（**复用** `contentHashIfFilePresent`
    /// 这一唯一哈希实现，不裸调 `SyncFileChecksum.sha256Hex`）**并回填 DB**（避免每轮重算）。
    /// 回填失败只告警、仍返回本轮现算值（取数是只读语义，不因写库失败而丢身份键）。
    ///
    /// - Parameters:
    ///   - track: 该路径的曲目行（查不到传 nil = 无行可回填，只现算）。
    ///   - path: 曲库路径（绝对路径或 `track.path` 存储形态；空串时回落 `track.path`）。
    ///   - isLocallyAvailable: 本地可读性判定（避免读取 dataless iCloud 文件）。
    /// - Returns: 身份键；列为空且文件不可读 / 不存在 → nil（调用方按「未指纹」处理）。
    @discardableResult
    func resolvedContentHash(
        forTrack track: Track?,
        atPath path: String,
        isLocallyAvailable: (URL) -> Bool = CloudFileAvailability.isLocallyAvailable
    ) -> String? {
        if let stored = track?.contentHash, !stored.isEmpty { return stored }
        var candidates: [String] = []
        for candidate in [path, track?.path] {
            guard let candidate, !candidate.isEmpty, !candidates.contains(candidate) else { continue }
            candidates.append(candidate)
        }
        for candidate in candidates {
            guard let computed = Self.contentHashIfFilePresent(
                atPath: candidate,
                isLocallyAvailable: isLocallyAvailable
            ) else { continue }
            if let id = track?.id {
                writeBackContentHash(computed, trackID: id)
            }
            return computed
        }
        return nil
    }

    /// 兜底回填单行（只填空值，不覆盖并发写入的新值）；失败只告警。
    private func writeBackContentHash(_ hash: String, trackID: Int64) {
        do {
            try write { db in
                try db.execute(
                    sql: "UPDATE track SET content_hash = ? WHERE id = ?"
                        + " AND (content_hash IS NULL OR content_hash = '')",
                    arguments: [hash, trackID]
                )
            }
        } catch {
            AppLog.warn(.db, "⚠️ Database: content_hash 兜底回填失败（本轮仍用现算值，下轮重试）：\(error)")
        }
    }

    /// content_hash 存量自愈回填（**无一次性门**，每次启动在后台队列跑一遍）。
    ///
    /// 取舍：旧实现用一次性完成门 database.contentHashBackfillCompleted.v1 挡重复扫描，
    /// 省下的只是「零 NULL 行时的一次索引查询」；代价是只要门被置位（含「文件当时不存在」
    /// 这类非云端跳过），NULL 指纹就**永不重试** → 身份键永久缺失，跨端同步永久对不上。
    /// 改成「上次运行标记」后：每次启动都尝试，零 NULL 行时仅一次索引查询即返回；
    /// dataless/文件未就绪只是本次跳过，下次启动自然重试。
    ///
    /// 补齐后对本次新填的每个 content_hash 调用 SyncChangeLogReplay.replay
    /// ——「因缺身份键而长期挂起的对端播放数据」借此落库。重放失败只打日志。
    ///
    /// ⚠️ 不再在启动主线程调用——见 scheduleContentHashBackfillInBackground()
    /// （dataless iCloud 文件会阻塞主线程）。
    /// - Parameters:
    ///   - defaults: 运行标记所用 UserDefaults（测试注入独立 suite）。
    ///   - isLocallyAvailable: 本地可读性判定（避免读取 dataless 文件触发云端下载）。
    /// - Returns: 本次回填结果（新填指纹列表 + 跳过/候选计数）。
    @discardableResult
    func backfillTrackContentHashesIfNeeded(
        defaults: UserDefaults = .standard,
        isLocallyAvailable: (URL) -> Bool = CloudFileAvailability.isLocallyAvailable
    ) throws -> ContentHashBackfillOutcome {
        if ContentHashBackfillMarker.removeRetiredCompletionGate(defaults: defaults) {
            AppLog.info(.db, "ℹ️ Database: 退役一次性 content_hash 回填门（改为每次启动自愈回填）")
        }

        let outcome = try backfillMissingContentHashesDetailed(isLocallyAvailable: isLocallyAvailable)
        ContentHashBackfillMarker.markRun(defaults: defaults)

        // 身份键补齐 → 重放之前因「本地查不到该 content_hash」而挂起的对端变更。
        for hash in outcome.filledHashes {
            do {
                let replayed = try SyncChangeLogReplay.replay(
                    pendingKey: SyncPendingKey.contentHash(hash),
                    database: self,
                    libraryRoot: DatabaseSyncCollectionFacts.defaultLibraryRoot
                )
                if replayed > 0 {
                    if AppLog.isEnabled(.debug, .db) { AppLog.debug(.db, "🔁 Sync: 回填指纹后重放挂起变更 \(replayed) 条（hash=\(hash.prefix(12))…）") }
                }
            } catch {
                AppLog.warn(.db, "⚠️ Sync: 回填后挂起变更重放失败（下次回填/入库再试）：\(error)")
            }
        }

        if outcome.skippedCloudOnly > 0 {
            AppLog.info(.db, "⏭️ Database: content_hash backfill skipped \(outcome.skippedCloudOnly) cloud-only track(s); will retry next launch")
        }
        return outcome
    }

    /// 回填核心（internal 供测试直调）：扫 content_hash IS NULL 行 → 文件存在且本地已
    /// 实体化则算 SHA-256 → 批量 UPDATE。幂等：再跑一遍无 NULL 行可补，不崩。
    /// - Returns: 因 iCloud 云端未下载被跳过的曲目数（文件不存在的旧行为不计入）。
    @discardableResult
    func backfillMissingContentHashes(
        isLocallyAvailable: (URL) -> Bool = CloudFileAvailability.isLocallyAvailable
    ) throws -> Int {
        try backfillMissingContentHashesDetailed(isLocallyAvailable: isLocallyAvailable).skippedCloudOnly
    }

    /// 回填核心（详版）：与 backfillMissingContentHashes 同一套语义，另外交出本次新填的
    /// content_hash 列表（启动路径据此重放挂起变更）。
    @discardableResult
    func backfillMissingContentHashesDetailed(
        isLocallyAvailable: (URL) -> Bool = CloudFileAvailability.isLocallyAvailable
    ) throws -> ContentHashBackfillOutcome {
        struct PendingFill {
            let id: Int64
            let hash: String
        }

        // Phase 1: 只读事务取候选（无文件 IO）。走 idx_track_content_hash 索引。
        let candidates = try read { db in
            try Track.filter(sql: "content_hash IS NULL").fetchAll(db)
        }
        guard !candidates.isEmpty else {
            // 零 NULL 行：到此为止（一次索引查询），不写库、不触发重放。
            return ContentHashBackfillOutcome(filledHashes: [], skippedCloudOnly: 0, candidateCount: 0)
        }

        // Phase 2: 事务外逐文件哈希（syscalls 不碰 GRDB writer）。
        var pending: [PendingFill] = []
        var skippedCloudOnly = 0
        for track in candidates {
            guard let id = track.id else { continue }
            // 文件真不存在：本次跳过（不计入云端跳过数），下次启动再试。
            let absoluteURL = LibraryRoot.absoluteURL(forStoredPath: track.path)
            guard FileManager.default.fileExists(atPath: absoluteURL.path) else { continue }
            // 云端未下载：不读内容（会阻塞），计入跳过数，下次重试。
            guard isLocallyAvailable(absoluteURL) else {
                skippedCloudOnly += 1
                continue
            }
            guard let hash = Self.contentHashIfFilePresent(
                atPath: absoluteURL.path,
                isLocallyAvailable: isLocallyAvailable
            ) else { continue }
            pending.append(PendingFill(id: id, hash: hash))
        }
        guard !pending.isEmpty else {
            return ContentHashBackfillOutcome(
                filledHashes: [],
                skippedCloudOnly: skippedCloudOnly,
                candidateCount: candidates.count
            )
        }

        // Phase 3: 短写事务批量落库。
        try write { db in
            for fill in pending {
                try db.execute(
                    sql: "UPDATE track SET content_hash = ? WHERE id = ?",
                    arguments: [fill.hash, fill.id]
                )
            }
        }
        AppLog.info(.db, "✅ Database: Backfilled content_hash for \(pending.count) track(s)")
        return ContentHashBackfillOutcome(
            filledHashes: pending.map(\.hash),
            skippedCloudOnly: skippedCloudOnly,
            candidateCount: candidates.count
        )
    }
}
