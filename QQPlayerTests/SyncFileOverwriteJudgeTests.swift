//
//  SyncFileOverwriteJudgeTests.swift
//  QQPlayerTests
//
//  批 1：文件覆盖判定纯逻辑（`SyncFileOverwriteJudge`，§6.1 判定 7 条）单测。
//
//  规格：`docs/lan-sync-design.md` §6.1（判定 7 条 + 台账状态机）；
//  契约：`docs/sync-contract.md` §2 G；不变量：`docs/sync-invariants.md` §H INV-33。
//
//  覆盖映射（规则 → 用例）：
//  1 `contentEqual`       → `规则 1 ……`
//  2 `userApproved`       → `规则 2 ……` + 边界 A1 两条
//  3 `peerUntouched`      → `规则 5 ……`
//  4 `peerChanged`        → `规则 4c / 6 ……`
//  4 `keptLocalChanged`   → `规则 4b ……` ×2（本端又变 / 决策指纹缺失，后者为边界）
//  5 `peerNewerByMtime`   → `规则 7 ……`
//  6 `noRecordPeerOlder`  → `规则 6 ……` ×2（更旧 / 容差内）
//  7 `undecidable`        → `规则 7 ……` ×3（相等 / 本端缺失 / 对端缺失）
//  另：排除 `@lyrics/*`、空 `toPush`、对端缺路径（A2）、未指纹落 mtime、顺序与去重、状态机取值。
//
//  说明：判定 7 条里 4 条是**放行**原因、4 条是**冲突**原因；公开输出为三段
//  `allowed`（路径）+ `conflicts`（路径 + 冲突原因）+ `skipped`（静默跳过，无原因码）⇒
//  放行类规则靠**对照用例**区分（同一输入只改一个变量 → 结果由放行翻成特定原因的冲突）。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite("批 1 文件覆盖判定（§6.1 判定 7 条）")
struct SyncFileOverwriteJudgeTests {
    // MARK: - 夹具

    private static let nowMs: Int64 = 1_700_000_000_000

    private static func entry(_ path: String, hash: String?, mtime: Int64 = 0) -> ManifestEntry {
        ManifestEntry(relativePath: path, size: 10, mtimeMs: mtime, contentHash: hash)
    }

    private static func row(
        _ path: String,
        hash: String,
        state: PeerFileStateRow.State,
        localHashAtDecision: String? = nil
    ) -> PeerFileStateRow {
        PeerFileStateRow(
            peerId: "peer-1",
            relativePath: path,
            contentHash: hash,
            state: state,
            localHashAtDecision: localHashAtDecision
        )
    }

    private static func judge(
        toPush: [String],
        local: [ManifestEntry] = [],
        remote: [ManifestEntry] = [],
        ledger: [PeerFileStateRow] = [],
        toleranceMs: Int64 = SyncFileOverwriteJudge.defaultToleranceMs
    ) -> SyncFileOverwriteDecision {
        SyncFileOverwriteJudge.judge(
            toPush: toPush,
            local: local,
            remote: remote,
            ledger: ledger,
            nowMs: nowMs,
            toleranceMs: toleranceMs
        )
    }

    // MARK: - 规则 1 contentEqual

    @Test("规则 1：两侧内容指纹一致 → 放行（contentEqual，防御式，正常不应进 toPush）")
    func contentEqualAllows() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H1")],
            remote: [Self.entry("Album/A.flac", hash: "H1")]
        )
        #expect(decision.allowed == ["Album/A.flac"])
        #expect(decision.conflicts.isEmpty)
    }

    // MARK: - 规则 2 userApproved + 边界 A1

    @Test("规则 2：approved 且 localHashAtDecision == 本端指纹 → 放行（userApproved，确认后本端未再变）")
    func userApprovedAllows() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H2")],
            remote: [Self.entry("Album/A.flac", hash: "P1")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .approved, localHashAtDecision: "H2")]
        )
        #expect(decision.allowed == ["Album/A.flac"])
        #expect(decision.conflicts.isEmpty)
    }

    @Test("规则 2：approved 且本端指纹缺失 → 无法证明「确认后未再变」→ 不放行")
    func userApprovedWithUnknownLocalHashDoesNotAllow() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: nil)],
            remote: [Self.entry("Album/A.flac", hash: "P1")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .approved, localHashAtDecision: "H2")]
        )
        #expect(decision.allowed.isEmpty)
        #expect(decision.conflicts.map(\.reason) == [.undecidable])
    }

    @Test("边界 A1：台账 approved 但本端已再变（对端未动）→ **不应放行**（保守冲突）")
    func approvedButLocalChangedWithPeerUnchangedConflicts() {
        // 用户确认的是 H1；本端现在是 H2（又变了）⇒ 确认作废，须重新确认。
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H2")],
            remote: [Self.entry("Album/A.flac", hash: "P1")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .approved, localHashAtDecision: "H1")]
        )
        #expect(decision.allowed.isEmpty)
        #expect(decision.conflicts.map(\.reason) == [.undecidable])
    }

    @Test("边界 A1：approved 但本端已再变、对端也变了 → 冲突且原因取更精确的 peerChanged")
    func approvedButBothChangedConflictsAsPeerChanged() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H2")],
            remote: [Self.entry("Album/A.flac", hash: "P2")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .approved, localHashAtDecision: "H1")]
        )
        #expect(decision.allowed.isEmpty)
        #expect(decision.conflicts.map(\.reason) == [.peerChanged])
    }

    // MARK: - 规则 3 peerUntouched

    @Test("规则 3：台账指纹 == 对端指纹 → 放行（peerUntouched = 对端没动过，属正常更新）")
    func peerUntouchedAllows() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H9")],
            remote: [Self.entry("Album/A.flac", hash: "P1")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .agreed)]
        )
        #expect(decision.allowed == ["Album/A.flac"])
        #expect(decision.conflicts.isEmpty)
    }

    // 批 1 遗留的「kept 未特判 ⇒ 与 agreed 同口径放行」对照用例（原 `keptRowWithPeerUnchangedAllows`）
    // 已按 2026-10-17 用户拍板**作废**：kept 现在走规则 4 —— 对端 + 本端都未变 → **静默跳过**；
    // 任一侧文件再变 → 重新确认（`keptLocalChanged` / `peerChanged`），不再按规则 5 放行。
    // 新口径用例见下方「规则 4 kept」一节。

    // MARK: - 规则 4 peerChanged

    @Test("规则 4：台账指纹 != 对端指纹 → 冲突（peerChanged，对端自己改过这个文件）")
    func peerChangedConflicts() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H9")],
            remote: [Self.entry("Album/A.flac", hash: "P2")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .agreed)]
        )
        #expect(decision.allowed.isEmpty)
        #expect(decision.conflicts == [SyncFileOverwriteConflict(relativePath: "Album/A.flac", reason: .peerChanged)])
    }

    // MARK: - 规则 5 peerNewerByMtime

    @Test("规则 5：无台账，对端 mtime 超出容差地更新 → 冲突（peerNewerByMtime）")
    func peerNewerBeyondToleranceConflicts() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H9", mtime: 1_000_000)],
            remote: [Self.entry("Album/A.flac", hash: "P2", mtime: 1_000_000 + 2_001)]
        )
        #expect(decision.allowed.isEmpty)
        #expect(decision.conflicts.map(\.reason) == [.peerNewerByMtime])
    }

    // MARK: - 规则 6 noRecordPeerOlder

    @Test("规则 6：无台账，对端 mtime 更旧 → 放行（noRecordPeerOlder，对端只是旧副本）")
    func peerOlderAllows() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H9", mtime: 2_000_000)],
            remote: [Self.entry("Album/A.flac", hash: "P2", mtime: 1_000_000)]
        )
        #expect(decision.allowed == ["Album/A.flac"])
        #expect(decision.conflicts.isEmpty)
    }

    @Test("规则 6：无台账，对端略新但在容差内 → 放行（noRecordPeerOlder，同族文件系统粒度）")
    func peerSlightlyNewerWithinToleranceAllows() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H9", mtime: 1_000_000)],
            remote: [Self.entry("Album/A.flac", hash: "P2", mtime: 1_000_000 + 2_000)]
        )
        #expect(decision.allowed == ["Album/A.flac"])
    }

    // MARK: - 规则 7 undecidable

    @Test("规则 7：无台账且两侧 mtime 相等 → 冲突（undecidable，加不进「对端更新」的证据）")
    func equalMtimeConflicts() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H9", mtime: 1_000_000)],
            remote: [Self.entry("Album/A.flac", hash: "P2", mtime: 1_000_000)]
        )
        #expect(decision.allowed.isEmpty)
        #expect(decision.conflicts.map(\.reason) == [.undecidable])
    }

    @Test("规则 7：无台账且本端 mtime 缺失（=0）→ 冲突（undecidable，保守）")
    func missingLocalMtimeConflicts() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H9", mtime: 0)],
            remote: [Self.entry("Album/A.flac", hash: "P2", mtime: 1_000_000)]
        )
        #expect(decision.conflicts.map(\.reason) == [.undecidable])
    }

    @Test("规则 7：无台账且对端 mtime 缺失（=0）→ 冲突（undecidable，保守）")
    func missingRemoteMtimeConflicts() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H9", mtime: 1_000_000)],
            remote: [Self.entry("Album/A.flac", hash: "P2", mtime: 0)]
        )
        #expect(decision.conflicts.map(\.reason) == [.undecidable])
    }

    // MARK: - 未指纹（contentHash == nil）→ 台账不适用

    @Test("对端指纹缺失（未指纹）→ 台账不参与比对，落 mtime 兜底")
    func unfingerprintedPeerFallsBackToMtime() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H9", mtime: 1_000_000)],
            remote: [Self.entry("Album/A.flac", hash: nil, mtime: 1_000_000 - 5_000)],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .agreed)]
        )
        #expect(decision.allowed == ["Album/A.flac"])
    }

    // MARK: - 排除 @lyrics/*

    @Test("排除 @lyrics/*：不经判据、原样放行（即使两侧 mtime 与指纹都不可判）")
    func lyricsPathsBypassJudge() {
        let decision = Self.judge(
            toPush: ["@lyrics/hA.json", "Album/A.flac"],
            local: [
                Self.entry("@lyrics/hA.json", hash: "H1"),
                Self.entry("Album/A.flac", hash: "H9"),
            ],
            remote: [
                Self.entry("@lyrics/hA.json", hash: "P1"),
                Self.entry("Album/A.flac", hash: "P2"),
            ]
        )
        #expect(decision.allowed == ["@lyrics/hA.json"])
        #expect(decision.conflicts.map(\.relativePath) == ["Album/A.flac"])
    }

    @Test("排除 @lyrics/*：规范化（`./@lyrics/…`）同样不经判据")
    func normalizedLyricsPathBypassesJudge() {
        let decision = Self.judge(
            toPush: ["./@lyrics/hA.json"],
            local: [Self.entry("./@lyrics/hA.json", hash: "H1")],
            remote: [Self.entry("./@lyrics/hA.json", hash: "P1")]
        )
        #expect(decision.allowed == ["./@lyrics/hA.json"])
        #expect(decision.conflicts.isEmpty)
    }

    // MARK: - A2 对端缺路径（新建）

    @Test("A2：对端无此路径（新建，无覆盖风险）→ 放行（见报告假设 A2）")
    func peerMissingPathAllows() {
        let decision = Self.judge(
            toPush: ["Album/New.flac"],
            local: [Self.entry("Album/New.flac", hash: "H1")],
            remote: []
        )
        #expect(decision.allowed == ["Album/New.flac"])
        #expect(decision.conflicts.isEmpty)
    }

    // MARK: - 空输入 / 顺序 / 去重 / 不自洽输入

    @Test("空 toPush → 空决策（allowed / conflicts 皆空）")
    func emptyToPushYieldsEmptyDecision() {
        let decision = Self.judge(toPush: [])
        #expect(decision == SyncFileOverwriteDecision())
    }

    @Test("结果顺序 = toPush 输入顺序；重复路径只判一次")
    func orderPreservedAndDeduplicated() {
        let decision = Self.judge(
            toPush: ["b.flac", "a.flac", "b.flac"],
            local: [
                Self.entry("a.flac", hash: "HA", mtime: 2_000),
                Self.entry("b.flac", hash: "HB", mtime: 2_000),
            ],
            remote: [
                Self.entry("a.flac", hash: "PA", mtime: 1_000),
                Self.entry("b.flac", hash: "PB", mtime: 1_000),
            ]
        )
        #expect(decision.allowed == ["b.flac", "a.flac"])
    }

    @Test("输入不自洽（toPush 里的路径本端没有）→ 保守冲突（undecidable）")
    func localEntryMissingConflicts() {
        let decision = Self.judge(
            toPush: ["Album/Ghost.flac"],
            local: [],
            remote: [Self.entry("Album/Ghost.flac", hash: "P1")]
        )
        #expect(decision.allowed.isEmpty)
        #expect(decision.conflicts.map(\.reason) == [.undecidable])
    }

    // MARK: - 规则 4 kept（〔保持现状〕的下次同步语义 · 2026-10-17 用户拍板）

    @Test("规则 4a kept：对端 + 本端都未变 → **静默跳过**（skipped 桶：不推、不弹窗、不计入「待确认」）")
    func keptUnchangedIsSkippedSilently() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H2")],
            remote: [Self.entry("Album/A.flac", hash: "P1")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .kept, localHashAtDecision: "H2")]
        )
        #expect(decision.skipped == ["Album/A.flac"])
        #expect(decision.allowed.isEmpty)
        #expect(decision.conflicts.isEmpty)
    }

    @Test("规则 4b kept：本端文件后来变了（Mac 重导 / 换版本）→ 冲突（keptLocalChanged，重新确认）")
    func keptButLocalChangedConflicts() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H3")],
            remote: [Self.entry("Album/A.flac", hash: "P1")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .kept, localHashAtDecision: "H2")]
        )
        #expect(decision.allowed.isEmpty)
        #expect(decision.skipped.isEmpty)
        #expect(decision.conflicts.map(\.reason) == [.keptLocalChanged])
    }

    @Test("规则 4b kept 边界：决策指纹缺失（旧行 / 未落库）→ 保守冲突（keptLocalChanged），绝不静默跳过")
    func keptWithoutDecisionHashConflicts() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H2")],
            remote: [Self.entry("Album/A.flac", hash: "P1")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .kept)]
        )
        #expect(decision.skipped.isEmpty)
        #expect(decision.conflicts.map(\.reason) == [.keptLocalChanged])
    }

    @Test("规则 4c kept：对端文件又变了 → 冲突（peerChanged，重新确认）")
    func keptButPeerChangedConflicts() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H2")],
            remote: [Self.entry("Album/A.flac", hash: "P9")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .kept, localHashAtDecision: "H2")]
        )
        #expect(decision.skipped.isEmpty)
        #expect(decision.conflicts.map(\.reason) == [.peerChanged])
    }

    @Test("kept 分支不吞下 approved / agreed 的行为（回归锚：state 互斥，插在规则 5/6 之前也不改旧状态）")
    func keptBranchDoesNotAffectOtherStates() {
        let approved = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H2")],
            remote: [Self.entry("Album/A.flac", hash: "P1")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .approved, localHashAtDecision: "H2")]
        )
        #expect(approved.allowed == ["Album/A.flac"])
        #expect(approved.skipped.isEmpty)

        let agreed = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "H9")],
            remote: [Self.entry("Album/A.flac", hash: "P1")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .agreed)]
        )
        #expect(agreed.allowed == ["Album/A.flac"])
        #expect(agreed.skipped.isEmpty)
    }
    // MARK: - 规则 5 收窄：pending 必须等显式确认（2026-10-17 复核修正）

    @Test("规则 5：pending + 对端未变 + 本端未变 → 冲突 pendingConfirmation（不得静默放行）")
    func pendingUnchangedRequiresConfirmation() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "L1")],
            remote: [Self.entry("Album/A.flac", hash: "P1")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .pending)]
        )
        #expect(decision.allowed.isEmpty, "pending = 还没确认，绝不能按「对端未动」放行")
        #expect(decision.conflicts.map(\.reason) == [.pendingConfirmation])
        #expect(decision.skipped.isEmpty, "pending 不是〔保持现状〕，不进 skipped")
    }

    @Test("规则 2：pending 后用户点覆盖（approved）→ 放行 userApproved（显式确认生效）")
    func pendingThenApprovedAllows() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "L1")],
            remote: [Self.entry("Album/A.flac", hash: "P1")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .approved, localHashAtDecision: "L1")]
        )
        #expect(decision.allowed == ["Album/A.flac"])
        #expect(decision.conflicts.isEmpty)
    }

    @Test("规则 6：pending + 对端又变 → 冲突 peerChanged（原因码更精确）")
    func pendingPeerChangedConflicts() {
        let decision = Self.judge(
            toPush: ["Album/A.flac"],
            local: [Self.entry("Album/A.flac", hash: "L1")],
            remote: [Self.entry("Album/A.flac", hash: "P2")],
            ledger: [Self.row("Album/A.flac", hash: "P1", state: .pending)]
        )
        #expect(decision.allowed.isEmpty)
        #expect(decision.conflicts.map(\.reason) == [.peerChanged])
    }

    // MARK: - 状态机取值（落库口径）

    @Test("台账状态机取值：pending / approved / kept / agreed（rawValue 落库口径稳定）")
    func ledgerStateRawValues() {
        #expect(PeerFileStateRow.State.allCases.map(\.rawValue) == ["agreed", "pending", "approved", "kept"])
        #expect(PeerFileStateRow.State(rawValue: "approved") == .approved)
        #expect(PeerFileStateRow.State(rawValue: "unknown") == nil)
    }

    @Test("判定原因码取值：9 条（4 放行 + 5 冲突，含 keptLocalChanged / pendingConfirmation）rawValue 稳定")
    func reasonRawValues() {
        #expect(SyncFileOverwriteReason.allCases.map(\.rawValue) == [
            "contentEqual", "userApproved", "peerUntouched",
            "peerChanged", "peerNewerByMtime", "noRecordPeerOlder", "undecidable",
            "keptLocalChanged", "pendingConfirmation",
        ])
    }
}
