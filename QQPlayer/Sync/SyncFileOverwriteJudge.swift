//
//  SyncFileOverwriteJudge.swift
//  QQPlayer
//
//  局域网同步（S2）「冲突判定 + 待确认覆盖」的判定入口 —— **纯逻辑**（批 1）。
//
//  规格（权威）：`docs/lan-sync-design.md` §6.1「冲突判定 + 待确认覆盖」**判定 7 条**；
//  契约：`docs/sync-contract.md` §2 G；不变量：`docs/sync-invariants.md` §H INV-33。
//
//  职责边界（本文件只出判据，不做任何副作用）：
//  - **零 IO / 零 GRDB / 零网络** —— swiftc 直编可跑，进 `scripts/sync-harness`；
//  - **只判 upload**：`toPush` 里哪些可以推、哪些必须转「待确认覆盖」。download 由调用方
//    原样放行（现状本就不覆盖本端），本文件不参与；
//  - **不写台账**：表 `sync_peer_file_state` 由批 2 落库、批 3 接线；本文件只用台账行的
//    值类型 `PeerFileStateRow`（批 2 未落地，先在此定义最小字段集）；
//  - **排除 `@lyrics/*`**：歌词走 §6.3「只补不覆盖」，判据不落到文件覆盖门上
//    （复用 `SyncLyricsNamespace.isLyricsPath`）；
//  - 插入点（批 3）：差集算完之后、推 / 拉分派之前 —— `SyncCollectionSyncCoordinator+Execution.swift`
//    的 `diff` 之后、`beginTransfers()` 之前。
//
//  判据记法（§6.1）：`L` = 本端 entry、`P` = 对端 entry、`T` = 台账行 `(peer_id, relative_path)`。
//
//  ⚠️ 两处**规格未逐字覆盖的输入形态**，按最小改动 + 保守原则处理，并在代码处注明（已上报）：
//  - A1：`T.state == approved` 但 `T.approvedLocalHash != L.hash`（确认后本端又变了）⇒
//    **不放行**（确认作废，须重新确认）。理由：`approved_local_hash` 字段存在的唯一用途就是
//    「校验确认后本端是否又变了」（§6.1 表结构注释）+ 任务包边界「approved 但本端已再变（不应放行）」。
//  - A2：对端 **没有该路径** ⇒ 落盘是**新建**、不存在「覆盖对端文件」⇒ 覆盖门不适用，**放行**
//    （否则首次同步的每一首新歌都会进「待确认覆盖」，与契约 §2 G「勾选集合里的歌在另一端可播」相悖）。
//

import Foundation

// MARK: - 台账行（批 2 建表前的最小值类型）

/// `sync_peer_file_state` 的一行（每条 `(peer_id, relative_path)` 唯一）。
///
/// 表结构（§6.1）比本类型多 `peer_mtime_ms` / `local_mtime_ms` / `updated_at` 三列，
/// 判据 7 条**不用**它们 ⇒ 批 1 只定义覆盖判定需要的最小字段集；批 2 落库时再补齐
/// （补列是加字段，不改判据）。
struct PeerFileStateRow: Equatable, Sendable {
    /// 台账状态机（§6.1）：`pending` 判为冲突待确认 / `approved` 用户点了覆盖 /
    /// `kept` 用户选保持现状 / `agreed` 双方一致。
    enum State: String, Equatable, Sendable, CaseIterable {
        case agreed
        case pending
        case approved
        case kept
    }

    /// 对端 DeviceID（与 `sync_cursor` / `sync_push_cursor` 同口径）。
    var peerId: String
    /// 对账键（POSIX，相对曲库根）。
    var relativePath: String
    /// 「上次达成一致时」的内容指纹。
    var contentHash: String
    /// 状态机当前态。
    var state: State
    /// `state == approved` 时的本端指纹（校验「确认后本端是否又变了」）。
    var approvedLocalHash: String?

    init(
        peerId: String,
        relativePath: String,
        contentHash: String,
        state: State,
        approvedLocalHash: String? = nil
    ) {
        self.peerId = peerId
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.state = state
        self.approvedLocalHash = approvedLocalHash
    }
}

// MARK: - 判定结果

/// 判定 7 条的原因码（§6.1 逐条对应）。
///
/// 其中 4 条是放行（`contentEqual` / `userApproved` / `peerUntouched` / `noRecordPeerOlder`）、
/// 3 条是冲突（`peerChanged` / `peerNewerByMtime` / `undecidable`）——冲突原因随
/// `SyncFileOverwriteConflict` 回给调用方（进「待确认覆盖」）。
enum SyncFileOverwriteReason: String, Equatable, Sendable, CaseIterable {
    /// 规则 1：两侧内容指纹一致（防御式；正常不应进 `toPush`）。
    case contentEqual
    /// 规则 2：用户已确认覆盖，且本端自确认后没再变。
    case userApproved
    /// 规则 3：台账指纹 == 对端指纹 ⇒ 对端自上次一致后没动过 = 正常更新。
    case peerUntouched
    /// 规则 4：对端自己改过这个文件。
    case peerChanged
    /// 规则 5：无台账，对端 mtime 超出容差地更新。
    case peerNewerByMtime
    /// 规则 6：无台账，对端只是旧副本（容差内 / 更旧）。
    case noRecordPeerOlder
    /// 规则 7：判不了（mtime 缺失 / 相等）⇒ **保守冲突**。
    case undecidable
}

/// 一条「待确认覆盖」项（冲突）。
struct SyncFileOverwriteConflict: Equatable, Sendable {
    /// 对账键（POSIX，相对曲库根）。
    var relativePath: String
    /// 判为冲突的判据（7 条之一；必为冲突类原因）。
    var reason: SyncFileOverwriteReason
}

/// 一次覆盖判定的结果（纯值）。
///
/// 顺序 = `toPush` 的输入顺序（升序），结果内不重排、不去重到别的次序。
struct SyncFileOverwriteDecision: Equatable, Sendable {
    /// 放行的相对路径（可推）。含两类**不经判据**的条目：`@lyrics/*`（§6.3 另走）与
    /// 对端缺路径（新建，无覆盖风险）——见文件头 A2。
    var allowed: [String] = []
    /// 判为冲突的相对路径 + 原因码（本轮跳过、记入「待确认覆盖」，等用户确认）。
    var conflicts: [SyncFileOverwriteConflict] = []
}

// MARK: - 判定入口

/// 文件覆盖判定（纯函数，§6.1 判定 7 条）。
enum SyncFileOverwriteJudge {
    /// 容差（毫秒）：同族文件系统粒度 + 扫描抖动（§6.1 「落成常量便于调」）。
    static let defaultToleranceMs: Int64 = 2000

    /// 判定本轮 upload 里哪些路径放行、哪些须转「待确认覆盖」。
    ///
    /// - Parameters:
    ///   - toPush: 差集算出的待推相对路径（升序，见 `SyncCollectionDiff.toPush`）。
    ///   - local: 本端 manifest（全量）。
    ///   - remote: 对端 manifest（全量）。
    ///   - ledger: **目标 peer** 的台账行；同路径多行按「后者胜」（最终快照，与既有索引口径一致）。
    ///   - nowMs: 本机当前时间（毫秒）。**判定 7 条不消费它**（批 3 记台账 `updated_at` 用），
    ///     保留在签名里以固定调用形状。
    ///   - toleranceMs: mtime 容差（默认 `defaultToleranceMs`）。
    /// - Returns: `allowed`（可推）+ `conflicts`（本轮跳过、待确认）。
    static func judge(
        toPush: [String],
        local: [ManifestEntry],
        remote: [ManifestEntry],
        ledger: [PeerFileStateRow],
        nowMs: Int64,
        toleranceMs: Int64 = defaultToleranceMs
    ) -> SyncFileOverwriteDecision {
        let localByPath = indexByPath(local)
        let remoteByPath = indexByPath(remote)
        let ledgerByPath = indexPath(ledger)

        var decision = SyncFileOverwriteDecision()
        var seen: Set<String> = []

        for path in toPush {
            guard seen.insert(path).inserted else { continue } // 去重（保序）

            // 排除 `@lyrics/*`：歌词走 §6.3「只补不覆盖」，判据不落到覆盖门上 ⇒ 原样放行。
            if SyncLyricsNamespace.isLyricsPath(path) {
                decision.allowed.append(path)
                continue
            }

            guard let localEntry = localByPath[path] else {
                // 本端没有该条目 ⇒ 输入不自洽（`toPush` 由本端 manifest 差集产出）⇒ 保守冲突。
                decision.conflicts.append(
                    SyncFileOverwriteConflict(relativePath: path, reason: .undecidable)
                )
                continue
            }
            guard let remoteEntry = remoteByPath[path] else {
                // A2：对端没有该路径 ⇒ 落盘是新建，不存在「覆盖对端文件」⇒ 放行。
                decision.allowed.append(path)
                continue
            }

            // 规则 1：`P.hash == L.hash` → 放行（防御式）｜contentEqual
            if SyncManifestReconciler.contentMatches(local: localEntry, remote: remoteEntry) {
                decision.allowed.append(path)
                continue
            }

            // 规则 2-4：对端指纹可比时以台账为准；`contentHash == nil`（未指纹）⇒ 视同无台账行，
            // 落到 mtime 兜底（§6.1 明写）。
            if let row = ledgerByPath[path], let remoteHash = remoteEntry.contentHash {
                if row.state == .approved {
                    // 规则 2：`T.state == approved` 且 `T.approvedLocalHash == L.hash` → 放行｜userApproved
                    if let approvedHash = row.approvedLocalHash, approvedHash == localEntry.contentHash {
                        decision.allowed.append(path)
                    } else {
                        // A1：确认后本端又变了（或本端指纹缺失）⇒ 确认作废，不放行（保守）。
                        // 对端若也变了，原因码取更精确的 `peerChanged`。
                        decision.conflicts.append(
                            SyncFileOverwriteConflict(
                                relativePath: path,
                                reason: row.contentHash == remoteHash ? .undecidable : .peerChanged
                            )
                        )
                    }
                    continue
                }
                // 规则 3：`T.contentHash == P.hash` → 放行（对端自上次一致后没动过 = 正常更新）｜peerUntouched
                if row.contentHash == remoteHash {
                    decision.allowed.append(path)
                    continue
                }
                // 规则 4：`T.contentHash != P.hash` → 冲突（对端自己改过这个文件）｜peerChanged
                decision.conflicts.append(
                    SyncFileOverwriteConflict(relativePath: path, reason: .peerChanged)
                )
                continue
            }

            // 规则 5-7：`T` 不存在（或对端指纹不可比）⇒ mtime 兜底。
            let localMtime = localEntry.mtimeMs
            let remoteMtime = remoteEntry.mtimeMs
            guard localMtime > 0, remoteMtime > 0, localMtime != remoteMtime else {
                // 规则 7：任一侧 mtime 不可判（0）/ 两侧相等 → 冲突（保守）｜undecidable
                // （**相等优先于规则 6 的 `<= 容差`**：`相等`属「mtime 不可判」，见 §6.1 规则 7 括注）
                decision.conflicts.append(
                    SyncFileOverwriteConflict(relativePath: path, reason: .undecidable)
                )
                continue
            }
            if remoteMtime > localMtime + toleranceMs {
                // 规则 5：`P.mtimeMs > L.mtimeMs + 容差` → 冲突（对端更新）｜peerNewerByMtime
                decision.conflicts.append(
                    SyncFileOverwriteConflict(relativePath: path, reason: .peerNewerByMtime)
                )
            } else {
                // 规则 6：`P.mtimeMs <= L.mtimeMs + 容差` → 放行（对端只是旧副本）｜noRecordPeerOlder
                decision.allowed.append(path)
            }
        }

        return decision
    }

    // MARK: - 内部索引

    /// 按 `relativePath` 建索引（**后者胜**：同名多条目取最终快照，与既有 planner 口径一致）。
    private static func indexByPath(_ entries: [ManifestEntry]) -> [String: ManifestEntry] {
        var index: [String: ManifestEntry] = [:]
        for entry in entries {
            index[entry.relativePath] = entry
        }
        return index
    }

    /// 按 `relativePath` 建台账索引（后者胜）。
    private static func indexPath(_ rows: [PeerFileStateRow]) -> [String: PeerFileStateRow] {
        var index: [String: PeerFileStateRow] = [:]
        for row in rows {
            index[row.relativePath] = row
        }
        return index
    }
}
