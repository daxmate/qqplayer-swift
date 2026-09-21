//
//  SyncCollectionPlanLogTests.swift
//  QQPlayerTests
//
//  E-1（2026-09-21）：同步「计划阶段」日志 + 「对端已一致」账目映射的 fail-closed 用例。
//
//  背景（真机实测）：Mac 选 3 首点「上传到 iPhone」→ UI 秒报完成、手机端零字节。
//  根因是差集判「对端已一致」→ 计划 0 条 → 空计划静默收尾；且计划阶段**零日志**，
//  于是「真的传完了」与「零字节」在诊断日志上完全同形。本批补可观测性。
//
//  为什么断言不直接抄一行期望字符串：
//  日志格式的唯一事实源是 `SyncCollectionPlanLog.lines`。在测试里复制一份完整模板
//  就是同一语义的第二份手工维护（改一处忘一处 → 测试自己先腐烂）。所以这里**按字段解析**
//  （空格切词 + 按 `=` 取值），再逐字段断言值 + 断言字段集合完整：
//  任何字段被删、改名、改值 → 断言必红（fail-closed）。
//
//  覆盖面（每条分支独立一条用例）：
//    - upload 空计划（对端已一致）→ 第二行 + 例举一致路径
//    - upload 有推送 → 只有计划行，不多落空计划行
//    - download 有拉取 → 只有计划行
//    - download 的 localOnlySkipped（本端有、对端没有）→ 空计划，不误报成传输
//    - 对端多（remoteOnlyIgnored）→ 字段 Y
//    - 两侧无（missingBoth）→ 字段 X
//    - 一致项为空 → 不追加样本（不落一串空路径）
//    - 一致样本超 3 条 → 折叠 `…(+n)`
//    - SyncUIReportSummary.make：对端已一致数/样本只从既有账目映射（升序前 3），
//      有失败/有中止/有实际传输时保持既有优先级（不判成「对端已一致」）
//

import Testing

@testable import QQPlayer

// MARK: - 夹具

/// 差集一律走**既有 planner**（不在测试里手搓 diff：差集口径的唯一实现是它）。
private func plan(
    expected: [String],
    local: [ManifestEntry],
    remote: [ManifestEntry],
    direction: SyncTransferDirection
) -> SyncCollectionDiff {
    SyncCollectionDiffPlanner.plan(expected: expected, local: local, remote: remote, direction: direction)
}

/// manifest 条目夹具（同路径默认给同一个 hash = 两侧一致；要造「内容不同」显式传 hash）。
private func manifestEntry(_ path: String, hash: String? = nil) -> ManifestEntry {
    ManifestEntry(relativePath: path, size: 10, mtimeMs: 0, contentHash: hash ?? "h|\(path)")
}

/// 计划行字段解析（只按空白切词、按 `=` 取值；**不复制模板**）。
private func planFields(_ line: String) -> [String: String] {
    var fields: [String: String] = [:]
    for token in line.split(separator: " ") {
        guard let separator = token.firstIndex(of: "=") else { continue }
        fields[String(token[token.startIndex ..< separator])] = String(token[token.index(after: separator)...])
    }
    return fields
}

/// 计划行契约：前缀 + 字段集合 + 每个字段的值。返回全部不符项（**空 = 通过**）。
///
/// 字段集合也断言：删字段、改名、新增未登记字段都算改坏契约（计划行是给人看的确诊依据）。
/// 计数走字典而不是 9 个位置参数：字段名本身就是断言对象，少传一个键也会被判出来。
private func planLineProblems(_ line: String, direction: String, counts: [String: Int]) -> [String] {
    var problems: [String] = []
    if !line.hasPrefix("📋 同步计划 ") {
        problems.append("缺少计划行前缀：\(line)")
    }
    let countKeys: Set<String> = ["选择", "本端", "对端", "推送", "拉取", "一致", "两侧无", "对端多"]
    if Set(counts.keys) != countKeys {
        problems.append("断言自身漏项（用例必须给全计数字段）：\(counts.keys.sorted())")
    }
    let fields = planFields(line)
    if Set(fields.keys) != countKeys.union(["方向"]) {
        problems.append("字段集合不符（删/改名/新增都要同步契约）：\(fields.keys.sorted())")
    }
    if fields["方向"] != direction {
        problems.append("字段 方向=\(fields["方向"] ?? "缺失")，期望 \(direction)")
    }
    for key in countKeys.sorted() where fields[key] != "\(counts[key] ?? -1)" {
        problems.append("字段 \(key)=\(fields[key] ?? "缺失")，期望 \(counts[key] ?? -1)")
    }
    return problems
}

// MARK: - 计划行（唯一格式化入口）

struct SyncCollectionPlanLogTests {
    @Test("upload 空计划：额外落一行『不传输』并例举对端已一致的路径")
    func uploadEmptyPlan() {
        let local = [manifestEntry("Album/a.flac")]
        let remote = [manifestEntry("Album/a.flac")]
        let diff = plan(expected: ["Album/a.flac"], local: local, remote: remote, direction: .upload)
        let lines = SyncCollectionPlanLog.lines(
            direction: .upload,
            selectionCount: 1,
            localCount: local.count,
            peerCount: remote.count,
            diff: diff
        )

        #expect(lines.count == 2, "空计划必须额外落一行（否则仍与「真传完了」同形）：\(lines)")
        let problems = planLineProblems(
            lines[0],
            direction: "upload",
            counts: ["选择": 1, "本端": 1, "对端": 1, "推送": 0, "拉取": 0, "一致": 1, "两侧无": 0, "对端多": 0]
        )
        #expect(problems.isEmpty, "\(problems)")
        #expect(
            lines[1].hasPrefix("⏭️ 计划为空 → 不传输（对端自报已一致 1 项）"),
            "空计划行必须明说「不传输」与一致项数：\(lines[1])"
        )
        #expect(lines[1].contains("Album/a.flac"), "空计划行必须例举一致路径：\(lines[1])")
    }

    @Test("upload 有推送：只落计划行，不多落空计划行")
    func uploadWithPush() {
        let local = [manifestEntry("Album/a.flac"), manifestEntry("Album/b.flac")]
        let remote = [manifestEntry("Album/a.flac")]
        let diff = plan(expected: ["Album/a.flac", "Album/b.flac"], local: local, remote: remote, direction: .upload)
        let lines = SyncCollectionPlanLog.lines(
            direction: .upload,
            selectionCount: 2,
            localCount: local.count,
            peerCount: remote.count,
            diff: diff
        )

        #expect(diff.toPush == ["Album/b.flac"])
        #expect(lines.count == 1, "有计划内容时不得多落一行：\(lines)")
        let problems = planLineProblems(
            lines[0],
            direction: "upload",
            counts: ["选择": 2, "本端": 2, "对端": 1, "推送": 1, "拉取": 0, "一致": 1, "两侧无": 0, "对端多": 0]
        )
        #expect(problems.isEmpty, "\(problems)")
        #expect(!lines.contains { $0.hasPrefix("⏭️") }, "有推送时不得落空计划行：\(lines)")
    }

    @Test("download 有拉取：方向与计数如实（推送必为 0）")
    func downloadWithPull() {
        let local = [manifestEntry("Album/a.flac")]
        let remote = [manifestEntry("Album/a.flac"), manifestEntry("Album/b.flac")]
        let diff = plan(expected: ["Album/a.flac", "Album/b.flac"], local: local, remote: remote, direction: .download)
        let lines = SyncCollectionPlanLog.lines(
            direction: .download,
            selectionCount: 2,
            localCount: local.count,
            peerCount: remote.count,
            diff: diff
        )

        #expect(diff.toPull == ["Album/b.flac"])
        #expect(lines.count == 1, "\(lines)")
        let problems = planLineProblems(
            lines[0],
            direction: "download",
            counts: ["选择": 2, "本端": 1, "对端": 2, "推送": 0, "拉取": 1, "一致": 1, "两侧无": 0, "对端多": 0]
        )
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test("download 的 localOnlySkipped（本端有、对端没有）：计划为空且不误报成传输")
    func downloadLocalOnlySkipped() {
        let local = [manifestEntry("Album/a.flac"), manifestEntry("Album/c.flac")]
        let remote = [manifestEntry("Album/a.flac")]
        let diff = plan(expected: ["Album/a.flac", "Album/c.flac"], local: local, remote: remote, direction: .download)
        let lines = SyncCollectionPlanLog.lines(
            direction: .download,
            selectionCount: 2,
            localCount: local.count,
            peerCount: remote.count,
            diff: diff
        )

        #expect(diff.localOnlySkipped == ["Album/c.flac"], "前置事实：本端独有走 localOnlySkipped")
        #expect(diff.toPush.isEmpty, "下载方向绝不产生推送")
        #expect(diff.toPull.isEmpty, "对端没有的条目不该产生拉取")
        #expect(lines.count == 2, "零传输必须落空计划行：\(lines)")
        let problems = planLineProblems(
            lines[0],
            direction: "download",
            counts: ["选择": 2, "本端": 2, "对端": 1, "推送": 0, "拉取": 0, "一致": 1, "两侧无": 0, "对端多": 0]
        )
        #expect(problems.isEmpty, "\(problems)")
        #expect(lines[1].hasPrefix("⏭️ 计划为空 → 不传输（对端自报已一致 1 项）"), "\(lines[1])")
    }

    @Test("对端多（remoteOnlyIgnored）：字段如实记账，且不影响「不传播删除」")
    func remoteOnlyIgnored() {
        let local = [manifestEntry("Album/a.flac")]
        let remote = [manifestEntry("Album/a.flac"), manifestEntry("Album/extra.flac")]
        let diff = plan(expected: ["Album/a.flac"], local: local, remote: remote, direction: .upload)
        let lines = SyncCollectionPlanLog.lines(
            direction: .upload,
            selectionCount: 1,
            localCount: local.count,
            peerCount: remote.count,
            diff: diff
        )

        #expect(diff.remoteOnlyIgnored == ["Album/extra.flac"])
        let problems = planLineProblems(
            lines[0],
            direction: "upload",
            counts: ["选择": 1, "本端": 1, "对端": 2, "推送": 0, "拉取": 0, "一致": 1, "两侧无": 0, "对端多": 1]
        )
        #expect(problems.isEmpty, "\(problems)")
        #expect(lines.count == 2, "零传输仍是空计划：\(lines)")
        #expect(!lines[1].contains("…"), "样本只有 1 条，不该折叠：\(lines[1])")
    }

    @Test("两侧无（missingBoth）：字段如实记账（不伪造、不动手）")
    func missingBoth() {
        let local = [manifestEntry("Album/a.flac")]
        let remote = [manifestEntry("Album/a.flac")]
        let diff = plan(expected: ["Album/a.flac", "Album/gone.flac"], local: local, remote: remote, direction: .upload)
        let lines = SyncCollectionPlanLog.lines(
            direction: .upload,
            selectionCount: 2,
            localCount: local.count,
            peerCount: remote.count,
            diff: diff
        )

        #expect(diff.missingBoth == ["Album/gone.flac"])
        let problems = planLineProblems(
            lines[0],
            direction: "upload",
            counts: ["选择": 2, "本端": 1, "对端": 1, "推送": 0, "拉取": 0, "一致": 1, "两侧无": 1, "对端多": 0]
        )
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test("空计划且一致项为 0：不追加样本（不落一串空路径）")
    func emptyPlanWithoutSample() {
        let local = [manifestEntry("Album/c.flac")]
        let diff = plan(expected: ["Album/c.flac"], local: local, remote: [], direction: .download)
        let lines = SyncCollectionPlanLog.lines(
            direction: .download,
            selectionCount: 1,
            localCount: local.count,
            peerCount: 0,
            diff: diff
        )

        #expect(lines.count == 2, "\(lines)")
        #expect(lines[1].hasPrefix("⏭️ 计划为空 → 不传输（对端自报已一致 0 项）"), "\(lines[1])")
        #expect(!lines[1].contains("Album/"), "无一致项时不得追加空样本：\(lines[1])")
    }

    @Test("一致样本超 3 条：只留升序前 3 条，其余折叠成 …(+n)")
    func sampleOverflow() {
        let paths = (1 ... 5).map { "Album/s\($0).flac" }
        let local = paths.map { manifestEntry($0) }
        let remote = paths.map { manifestEntry($0) }
        let diff = plan(expected: paths, local: local, remote: remote, direction: .upload)
        let lines = SyncCollectionPlanLog.lines(
            direction: .upload,
            selectionCount: paths.count,
            localCount: local.count,
            peerCount: remote.count,
            diff: diff
        )

        #expect(diff.unchanged.count == 5)
        #expect(lines.count == 2, "\(lines)")
        #expect(lines[1].contains("Album/s1.flac"), "\(lines[1])")
        #expect(lines[1].contains("Album/s2.flac"), "\(lines[1])")
        #expect(lines[1].contains("Album/s3.flac"), "\(lines[1])")
        #expect(!lines[1].contains("Album/s4.flac"), "第 4 条不该出现（只留前 3）：\(lines[1])")
        #expect(!lines[1].contains("Album/s5.flac"), "第 5 条不该出现（只留前 3）：\(lines[1])")
        #expect(lines[1].contains("…(+2)"), "超出部分必须折叠成 …(+n)：\(lines[1])")
    }

    @Test("方向标签与既有代码/协议同词（upload / download），便于 grep 诊断")
    func directionLabel() {
        #expect(SyncCollectionPlanLog.directionLabel(.upload) == "upload")
        #expect(SyncCollectionPlanLog.directionLabel(.download) == "download")
    }
}

// MARK: - 结果摘要：「对端已一致」只从既有账目映射

struct SyncUIReportSummaryPeerIdenticalTests {
    @Test("空计划：对端已一致数 = 账目 skip 数，样本 = 升序前 3")
    func peerAlreadyHasMappedFromReport() {
        var report = SyncCollectionSyncReport()
        report.skipped = ["Album/s1.flac", "Album/s2.flac", "Album/s3.flac", "Album/s4.flac", "Album/s5.flac"]

        let summary = SyncUIReportSummary.make(report: report)
        #expect(summary.peerAlreadyHasCount == report.skipped.count, "只从既有账目映射，UI 不补算")
        #expect(summary.peerAlreadyHasCount == 5)
        #expect(summary.peerAlreadyHasSample == ["Album/s1.flac", "Album/s2.flac", "Album/s3.flac"])
        #expect(summary.transferredCount == 0)
        #expect(summary.isEmptyPlanAlreadyIdentical, "零传输 + 对端已有内容 + 无失败无中止 = 必须明说")
    }

    @Test("样本不足 3 条：按实际条数给（不补位、不报错）")
    func sampleShorterThanLimit() {
        var report = SyncCollectionSyncReport()
        report.skipped = ["Album/s1.flac", "Album/s2.flac"]

        let summary = SyncUIReportSummary.make(report: report)
        #expect(summary.peerAlreadyHasSample == ["Album/s1.flac", "Album/s2.flac"])
        #expect(summary.isEmptyPlanAlreadyIdentical)
    }

    @Test("有实际传输 / 有失败 / 有中止：不得判成「对端已一致」（既有优先级文案不变）")
    func notIdenticalWhenTransferFailsOrAborts() {
        var transferring = SyncCollectionSyncReport()
        transferring.skipped = ["Album/s1.flac"]
        transferring.pushed = ["Album/s2.flac"]
        #expect(!SyncUIReportSummary.make(report: transferring).isEmptyPlanAlreadyIdentical)

        var failing = SyncCollectionSyncReport()
        failing.skipped = ["Album/s1.flac"]
        failing.pushFailed = [
            SyncPushFailure(relativePath: "Album/x.m4a", reason: SyncPushFailureReason.sendFailed, detail: nil),
        ]
        let failed = SyncUIReportSummary.make(report: failing)
        #expect(failed.peerAlreadyHasCount == 1, "计数照记（账目如实）")
        #expect(!failed.isEmptyPlanAlreadyIdentical, "有失败项时优先显示失败，不换成「无需传输」")

        var aborted = SyncCollectionSyncReport()
        aborted.skipped = ["Album/s1.flac"]
        aborted.pullAbortReason = "中止"
        #expect(!SyncUIReportSummary.make(report: aborted).isEmptyPlanAlreadyIdentical)
    }

    @Test("空选择集：没有「对端已一致」可说明（保持既有空选择文案）")
    func emptySelectionKeepsOwnCopy() {
        var report = SyncCollectionSyncReport()
        report.isEmptySelection = true

        let summary = SyncUIReportSummary.make(report: report)
        #expect(summary.peerAlreadyHasCount == 0)
        #expect(!summary.isEmptyPlanAlreadyIdentical)
    }
}
