//
//  SyncFileOverwriteGate.swift
//  QQPlayer
//
//  文件覆盖判定的**生产接线**（批 3）：把纯判定 SyncFileOverwriteJudge 与台账存储
//  PeerFileStateStore 串成「读台账 → 判定 → 落台账」三步。
//
//  规格：docs/lan-sync-design.md §6.1（判定 7 条 + 台账状态机）；契约
//  docs/sync-contract.md §2 G；不变量 docs/sync-invariants.md §H INV-33。
//
//  边界（为什么需要这一层）：
//  - 判定仍然**只有一处实现**（SyncFileOverwriteJudge）；本文件不含任何判定分支，
//    只做 IO 编排 —— 同一语义多处手工维护是 2026-09-15 立的纪律红线；
//  - 本文件**零 GRDB**：只依赖 SyncFileOverwriteLedgering 协议 + PeerFileStateRow
//    （零 GRDB 行模型），因此可被无模拟器 harness 直编；生产实现 = PeerFileStateStore；
//  - 只在 upload（Mac 发起推送）生效；download（用户显式「从设备取回」）**不经过本闸门**
//    —— 契约 G 行唯一例外，见 SyncCollectionSyncCoordinator+Execution.handlePeerManifest。
//

import Foundation

/// 台账读写的最小接口（判官接线只依赖它）。
///
/// 生产实现 = PeerFileStateStore（真 GRDB）；测试 = 内存 fake。
/// 只允许这两个动作：判官需要「按 peer 读全量行」，写入需要「按主键幂等 upsert」。
protocol SyncFileOverwriteLedgering: AnyObject, Sendable {
    /// 某 peer 的全部台账行（按 relative_path 升序）。
    func load(peerId: String) throws -> [PeerFileStateRow]
    /// 幂等 upsert（主键 = (peer_id, relative_path)）。
    func upsert(_ row: PeerFileStateRow) throws
}

/// 覆盖判定的生产闸门：读台账 → 判官 → 按结果落台账。
///
/// 调用形状固定（peerId 在构造时绑定），避免每个调用点各自拼 peerId / 各自读表。
struct SyncFileOverwriteGate: Sendable {
    /// 目标 peer 的 DeviceID（与 sync_cursor / sync_push_cursor 同口径）。
    let peerId: String
    let store: any SyncFileOverwriteLedgering
    /// 落库时刻（毫秒）。判定 7 条**不消费**它（只写 updated_at_ms）；测试注入固定值。
    let nowMs: @Sendable () -> Int64

    init(
        peerId: String,
        store: any SyncFileOverwriteLedgering,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.peerId = peerId
        self.store = store
        self.nowMs = nowMs
    }

    /// 本轮 upload 的判定（读台账 + SyncFileOverwriteJudge.judge）。
    ///
    /// 台账读取失败 ⇒ **本轮全部按冲突处理**（undecidable）：判不了就不覆盖
    /// （§6.1「判不了 = 保守冲突」）。绝不能退化成「空台账」——空台账会走 mtime 兜底，
    /// 那样可能在读表故障时静默覆盖对端文件。
    func decide(
        toPush: [String],
        local: [ManifestEntry],
        remote: [ManifestEntry]
    ) -> SyncFileOverwriteDecision {
        let ledger: [PeerFileStateRow]
        do {
            ledger = try store.load(peerId: peerId)
        } catch {
            AppLog.warn(
                .sync,
                "⚠️ 覆盖确认台账读取失败 → 本轮全部按冲突处理（不覆盖）：\(error)"
            )
            return SyncFileOverwriteDecision(
                conflicts: toPush.map {
                    SyncFileOverwriteConflict(relativePath: $0, reason: .undecidable)
                }
            )
        }
        return SyncFileOverwriteJudge.judge(
            toPush: toPush,
            local: local,
            remote: remote,
            ledger: ledger,
            nowMs: nowMs()
        )
    }

    /// 本轮判为冲突的路径落 pending（content_hash = **对端**指纹，§6.1 写入时机）。
    ///
    /// 对端指纹缺失（nil）时**不写行**：表列 content_hash NOT NULL，写入即崩；
    /// 该路径下一轮仍会按「无台账 + mtime 兜底」重新判定（保守冲突不会因此放行）。
    func recordPending(
        conflicts: [SyncFileOverwriteConflict],
        remote: [ManifestEntry]
    ) {
        guard !conflicts.isEmpty else { return }
        let remoteHashes = Self.hashIndex(remote)
        for conflict in conflicts {
            guard let remoteHash = remoteHashes[conflict.relativePath] else { continue }
            write(
                PeerFileStateRow(
                    peerId: peerId,
                    relativePath: conflict.relativePath,
                    contentHash: remoteHash,
                    state: .pending,
                    localHashAtDecision: nil
                )
            )
        }
    }

    /// 推送成功落 agreed（content_hash = **本次发出的**本端指纹，§6.1 写入时机）。
    ///
    /// 只对控制器确认 completed 的路径调用 —— 失败 / 跳过项不得写 agreed
    /// （否则下一轮会误判「对端未变」而放行覆盖）。
    func recordAgreed(paths: [String], local: [ManifestEntry]) {
        guard !paths.isEmpty else { return }
        let localHashes = Self.hashIndex(local)
        for path in paths {
            guard let localHash = localHashes[path] else { continue }
            write(
                PeerFileStateRow(
                    peerId: peerId,
                    relativePath: path,
                    contentHash: localHash,
                    state: .agreed,
                    localHashAtDecision: nil
                )
            )
        }
    }

    // MARK: - 私有

    private func write(_ row: PeerFileStateRow) {
        do {
            try store.upsert(row)
        } catch {
            // 台账写失败不回滚已经发生的传输：如实记日志，下一轮按「无行 / 旧行」保守判定。
            AppLog.warn(
                .sync,
                "⚠️ 覆盖确认台账写入失败（\(row.relativePath) → \(row.state.rawValue)）：\(error)"
            )
        }
    }

    /// 路径 → 非空 contentHash（同路径多行取后者，与判官 / 既有索引口径一致）。
    private static func hashIndex(_ entries: [ManifestEntry]) -> [String: String] {
        var index: [String: String] = [:]
        for entry in entries {
            if let hash = entry.contentHash {
                index[entry.relativePath] = hash
            }
        }
        return index
    }
}
