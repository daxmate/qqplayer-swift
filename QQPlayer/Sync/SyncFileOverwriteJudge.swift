//
//  SyncFileOverwriteJudge.swift
//  QQPlayer
//
//  局域网同步（S2）「冲突判定 + 待确认覆盖」的判定入口 —— **纯逻辑**（批 1 落地；
//  批 1b 补 2026-10-17 用户拍板的〔保持现状〕下次同步语义）。
//
//  规格（权威）：`docs/lan-sync-design.md` §6.1「冲突判定 + 待确认覆盖」**判定 7 条**；
//  契约：`docs/sync-contract.md` §2 G；不变量：`docs/sync-invariants.md` §H INV-33。
//
//  职责边界（本文件只出判据，不做任何副作用）：
//  - **零 IO / 零 GRDB / 零网络** —— swiftc 直编可跑，进 `scripts/sync-harness`；
//  - **只判 upload**：`toPush` 里哪些可以推、哪些必须转「待确认覆盖」、哪些**静默跳过**；
//    download 由调用方原样放行（现状本就不覆盖本端），本文件不参与；
//  - **不写台账**：表 `sync_peer_file_state` 的读写归存储层（`PeerFileStateStore`），
//    本文件只消费调用方查出的台账行；调用点在调用方的 `plannedTransfers()` 之前。
//
//  判据记法（§6.1）：`L` = 本端 entry、`P` = 对端 entry、`T` = 台账行 `(peer_id, relative_path)`。
//  `T.localHashAtDecision` = **决策时的本端指纹**（2026-10-17 起 `approved` / `kept` 都写），
//  用于判定「决策后本端是否又变了」。
//
//  ⚠️ 规格未逐字覆盖的输入形态，按最小改动 + 保守原则处理，并在代码处注明（已上报）：
//  - A1：`T.state == approved` 但 `T.localHashAtDecision != L.hash`（确认后本端又变了）⇒
//    **不放行**（确认作废，须重新确认）。理由：`local_hash_at_decision` 字段存在的唯一用途就是
//    「校验决策后本端是否又变了」（§6.1 表结构注释）+ 任务包边界「approved 但本端已再变（不应放行）」。
//  - A2：对端 **没有该路径** ⇒ 落盘是**新建**、不存在「覆盖对端文件」⇒ 覆盖门不适用，**放行**
//    （否则首次同步的每一首新歌都会进「待确认覆盖」，与契约 §2 G「勾选集合里的歌在另一端可播」相悖）。
//  - A3（2026-10-17 用户拍板）：`kept`（〔保持现状〕）的**下次同步**语义 —— 对端 **且** 本端
//    都未变 → **静默跳过**（不推、不弹窗、不计入「待确认」）；任一侧文件再变 → **重新确认**（冲突）。
//    对端又变 = `peerChanged`；本端又变（Mac 重导 / 换版本）= 新原因码 `keptLocalChanged`。

import Foundation

// MARK: - 台账行

// 台账行 `PeerFileStateRow` 的**唯一定义**在 `QQPlayer/Sync/PeerFileStateRow.swift`
// （零 GRDB 的**公共模型文件** —— 判定器与 `PeerFileStateStore` 共用同一类型，不复制；
// GRDB 的 Record 一致性只在存储层补）。本文件只消费它，不重复声明。

// MARK: - 判定结果

/// 判定 7 条的原因码（§6.1 逐条对应）。
///
/// 其中 4 条是放行（`contentEqual` / `userApproved` / `peerUntouched` / `noRecordPeerOlder`）、
/// 4 条是冲突（`peerChanged` / `peerNewerByMtime` / `undecidable` / `keptLocalChanged`）——
/// 冲突原因随 `SyncFileOverwriteConflict` 回给调用方（进「待确认覆盖」）。
/// **静默跳过**（`skipped` 桶）没有原因码：它不是冲突，也不该出现在任何列表里。
enum SyncFileOverwriteReason: String, Equatable, Sendable, CaseIterable {
    /// 规则 1：两侧内容指纹一致（防御式；正常不应进 `toPush`）。
    case contentEqual
    /// 规则 2：用户已确认覆盖，且本端自确认后没再变。
    case userApproved
    /// 规则 5：台账指纹 == 对端指纹 ⇒ 对端自上次一致后没动过 = 正常更新。
    case peerUntouched
    /// 规则 4c / 6：对端自己改过这个文件。
    case peerChanged
    /// 规则 7：无台账，对端 mtime 超出容差地更新。
    case peerNewerByMtime
    /// 规则 7：无台账，对端只是旧副本（容差内 / 更旧）。
    case noRecordPeerOlder
    /// 规则 3 / 7：判不了（mtime 缺失 / 相等；确认后本端又变而对端未动）⇒ **保守冲突**。
    case undecidable
    /// 规则 4b：用户选过〔保持现状〕，但**本端文件后来变了**（Mac 重导 / 换版本）⇒ 重新确认。
    case keptLocalChanged
}

/// 一条「待确认覆盖」项（冲突）。
struct SyncFileOverwriteConflict: Equatable, Sendable {
    /// 对账键（POSIX，相对曲库根）。
    var relativePath: String
    /// 判为冲突的判据（必为冲突类原因）。
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
    /// **静默跳过**的相对路径：不推、**不弹窗**、不计入「待确认」。
    /// 现只来自规则 4a —— `kept` 且对端 + 本端都未变（用户已选〔保持现状〕，不该再打扰）。
    var skipped: [String] = []
}

// MARK: - 判定入口

/// 文件覆盖判定（纯函数，§6.1 判定 7 条）。
enum SyncFileOverwriteJudge {
    /// 容差（毫秒）：同族文件系统粒度 + 扫描抖动（§6.1 「落成常量便于调」）。
    static let defaultToleranceMs: Int64 = 2000

    /// 判定本轮 upload 里哪些路径放行、哪些须转「待确认覆盖」、哪些静默跳过。
    ///
    /// - Parameters:
    ///   - toPush: 差集算出的待推相对路径（升序，见 `SyncCollectionDiff.toPush`）。
    ///   - local: 本端 manifest（全量）。
    ///   - remote: 对端 manifest（全量）。
    ///   - ledger: **目标 peer** 的台账行；同路径多行按「后者胜」（最终快照，与既有索引口径一致）。
    ///   - nowMs: 本机当前时间（毫秒）。**判定 7 条不消费它**（批 3 记台账 `updated_at_ms` 用），
    ///     保留在签名里以固定调用形状。
    ///   - toleranceMs: mtime 容差（默认 `defaultToleranceMs`）。
    /// - Returns: `allowed`（可推）+ `conflicts`（本轮跳过、待确认）+ `skipped`（静默跳过）。
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

            // 规则 2-6：对端指纹可比时以台账为准；`contentHash == nil`（未指纹）⇒ 视同无台账行，
            // 落到 mtime 兜底（§6.1 明写）。
            if let row = ledgerByPath[path], let remoteHash = remoteEntry.contentHash {
                if row.state == .approved {
                    // 规则 2：`T.state == approved` 且 `T.localHashAtDecision == L.hash` → 放行｜userApproved
                    if let decisionHash = row.localHashAtDecision, decisionHash == localEntry.contentHash {
                        decision.allowed.append(path)
                    } else {
                        // 规则 3 / 边界 A1：确认后本端又变了（或本端指纹缺失）⇒ 确认作废，不放行（保守）。
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

                // 规则 4：`T.state == kept`（用户选〔保持现状〕）的**下次同步**语义（2026-10-17 拍板）。
                // ⚠️ 必须排在规则 5/6 之前：`kept` 的「对端未变」不是「正常更新」而是「静默跳过」。
                if row.state == .kept {
                    if row.contentHash != remoteHash {
                        // 规则 4c：对端文件又变了 → 重新确认（冲突）。
                        decision.conflicts.append(
                            SyncFileOverwriteConflict(relativePath: path, reason: .peerChanged)
                        )
                    } else if let decisionHash = row.localHashAtDecision,
                              decisionHash == localEntry.contentHash {
                        // 规则 4a：对端未变 **且** 本端未变 → 静默跳过（不推、不弹窗、不计入「待确认」）。
                        decision.skipped.append(path)
                    } else {
                        // 规则 4b：本端后来变了（Mac 重导 / 换版本），或决策指纹缺失 → 重新确认。
                        decision.conflicts.append(
                            SyncFileOverwriteConflict(relativePath: path, reason: .keptLocalChanged)
                        )
                    }
                    continue
                }

                // 规则 5：其余状态（agreed / pending）且 `T.contentHash == P.hash`
                // → 放行（对端自上次一致后没动过 = 正常更新）｜peerUntouched
                if row.contentHash == remoteHash {
                    decision.allowed.append(path)
                    continue
                }
                // 规则 6：`T.contentHash != P.hash` → 冲突（对端自己改过这个文件）｜peerChanged
                decision.conflicts.append(
                    SyncFileOverwriteConflict(relativePath: path, reason: .peerChanged)
                )
                continue
            }

            // 规则 7：`T` 不存在（或对端指纹不可比）⇒ mtime 兜底。
            let localMtime = localEntry.mtimeMs
            let remoteMtime = remoteEntry.mtimeMs
            guard localMtime > 0, remoteMtime > 0, localMtime != remoteMtime else {
                // 规则 7：任一侧 mtime 不可判（0）/ 两侧相等 → 冲突（保守）｜undecidable
                // （**相等优先于「容差内放行」**：`相等`属「mtime 不可判」，见 §6.1 规则 7）
                decision.conflicts.append(
                    SyncFileOverwriteConflict(relativePath: path, reason: .undecidable)
                )
                continue
            }
            if remoteMtime > localMtime + toleranceMs {
                // 规则 7：`P.mtimeMs > L.mtimeMs + 容差` → 冲突（对端更新）｜peerNewerByMtime
                decision.conflicts.append(
                    SyncFileOverwriteConflict(relativePath: path, reason: .peerNewerByMtime)
                )
            } else {
                // 规则 7：`P.mtimeMs <= L.mtimeMs + 容差` → 放行（对端只是旧副本）｜noRecordPeerOlder
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
