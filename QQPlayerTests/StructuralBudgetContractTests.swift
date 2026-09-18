//
//  StructuralBudgetContractTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  结构预算棘轮（2026-09-19 立）。口径与判定实现在 `StructuralBudgetRule.swift`
//  （单独成文件是为了能脱离模拟器直编——基线由它自己生成，不手抄）。
//
//  为什么立这条棘轮：可维护性上最大的三处存量债没有任何机器守卫——
//   ① 34 个文件 > 600 行（最大 1460 行）
//   ② 101 个文件 / 1379 处裸 `print(`（统一日志出口 `AppLog` 尚未落地）
//   ③ `.swiftlint.yml` 主动关掉了 `file_length` / `function_body_length` /
//      `cyclomatic_complexity` / `line_length` —— 结构规则全关，等于「涨多少都没人管」
//  （③ 的根治要开回 SwiftLint 规则，属后续批次；本文件先把①②钉成「只能减不能增」，
//   并按 2026-09-17 的教训把结论落到**机器会红的机制**上。）
//
//  四条契约（全部 fail-closed：读不到源码/基线、基线自相矛盾 = 红）：
//   (a) 新增违规：检测到基线里没有的条目 → 红（新写一个 800 行文件、新写裸 print 都拦）
//   (b) 计数回涨：某文件 > 基线值 → 红
//   (c) 名单不腐烂：基线条目下降/归零/文件消失 → 必须同步改行或删行，否则红
//   (d) 总数上限：合计 > 基线 TOTAL → 红
//
//  清债方式：把文件拆到 600 行以内、把 `print(` 换成统一出口，然后**同步改小/删掉基线行**
//  （只减不增；留陈旧行会红）。
//

import Foundation
import Testing

@Suite("结构预算棘轮（超长文件 / 裸 print）")
struct StructuralBudgetContractTests {
    @Test("超长文件预算：不得新增、不得回涨、名单不腐烂、TOTAL 自洽")
    func fileSizeBudgetHolds() throws {
        let baseline = try StructuralBudgetRule.baseline(at: StructuralBudgetRule.sizeBaselinePath)
        let problems = StructuralBudgetRule.violations(
            detected: try StructuralBudgetRule.detectedOversizedFiles(),
            baseline: baseline,
            name: "超长文件（> \(StructuralBudgetRule.fileSizeThreshold) 行）",
            unit: " 行"
        )
        #expect(
            problems.isEmpty,
            """
            结构预算被击穿（超长文件，基线 \(baseline.perFile.count) 个文件 / TOTAL \(baseline.total)）：
            \(problems.joined(separator: "\n"))

            修法：拆文件（推荐）或把行加进基线并在提交信息说明理由；清债后必须同步改小/删掉基线行。
            """
        )
    }

    @Test("裸 print 预算：不得新增、不得回涨、名单不腐烂、TOTAL 自洽")
    func printBudgetHolds() throws {
        let baseline = try StructuralBudgetRule.baseline(at: StructuralBudgetRule.printBaselinePath)
        let problems = StructuralBudgetRule.violations(
            detected: try StructuralBudgetRule.detectedPrintCalls(),
            baseline: baseline,
            name: "裸 print(",
            unit: " 处"
        )
        #expect(
            problems.isEmpty,
            """
            结构预算被击穿（裸 print(，基线 \(baseline.perFile.count) 个文件 / TOTAL \(baseline.total)）：
            \(problems.joined(separator: "\n"))

            修法：诊断输出走统一出口（`AppLog`）；确需登记则把行加进基线并在提交信息说明理由。
            """
        )
    }

    @Test("fail-closed：基线缺失 / 格式错必须报错，绝不静默通过")
    func baselineFailuresAreFatal() {
        #expect(throws: (any Error).self) {
            _ = try StructuralBudgetRule.baseline(at: "QQPlayerTests/Fixtures/__missing-baseline__.tsv")
        }
        #expect(throws: (any Error).self) {
            _ = try StructuralBudgetBaseline.parse("QQPlayer/Services/X.swift\tNaN\n# TOTAL: 1\n")
        }
        #expect(throws: (any Error).self) {
            _ = try StructuralBudgetBaseline.parse("QQPlayer/Services/X.swift\t1\n")
        }
    }

    @Test("自证：口径与四条判定能抓到合成输入（反向验证，防止棘轮变成永远绿）")
    func ruleSelfTest() throws {
        // 口径
        #expect(StructuralBudgetRule.lines(in: "a\nb\n") == 2)
        #expect(StructuralBudgetRule.lines(in: "a\nb") == 2)
        #expect(StructuralBudgetRule.lines(in: "") == 0)
        #expect(StructuralBudgetRule.printCalls(in: "// print(x)\n") == 0)
        #expect(StructuralBudgetRule.printCalls(in: "print(a) // print(b)\n") == 1)
        #expect(StructuralBudgetRule.printCalls(in: "print(a); print(b)\n") == 2)

        // 合成仓库：一个 700 行文件 + 一个带 print 的文件
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StructuralBudgetSelfTest-\(UUID().uuidString)")
        let services = root.appendingPathComponent("QQPlayer/Services")
        try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bigPath = "QQPlayer/Services/Big.swift"
        try String(repeating: "let a = 1\n", count: 700)
            .write(to: services.appendingPathComponent("Big.swift"), atomically: true, encoding: .utf8)
        try "print(1)\n"
            .write(to: services.appendingPathComponent("Small.swift"), atomically: true, encoding: .utf8)

        let detected = try StructuralBudgetRule.detectedOversizedFiles(repositoryRoot: root)
        #expect(detected == [bigPath: 700])

        let baseline = StructuralBudgetBaseline(total: 700, perFile: [bigPath: 700])
        #expect(StructuralBudgetRule.violations(
            detected: detected, baseline: baseline,
            name: "超长文件", unit: " 行", repositoryRoot: root
        ).isEmpty)

        // (a) 新增未登记 → 红
        #expect(StructuralBudgetRule.violations(
            detected: detected.merging(["QQPlayer/Services/New.swift": 800]) { _, new in new },
            baseline: baseline, name: "超长文件", unit: " 行", repositoryRoot: root
        ).contains { $0.contains("新增了") })

        // (b) 回涨 → 红
        #expect(StructuralBudgetRule.violations(
            detected: [bigPath: 701], baseline: baseline,
            name: "超长文件", unit: " 行", repositoryRoot: root
        ).contains { $0.contains("回涨") })

        // (c) 下降未改基线 / 文件消失 → 红
        #expect(StructuralBudgetRule.violations(
            detected: [bigPath: 500], baseline: baseline,
            name: "超长文件", unit: " 行", repositoryRoot: root
        ).contains { $0.contains("腐烂") })
        #expect(StructuralBudgetRule.violations(
            detected: detected,
            baseline: StructuralBudgetBaseline(total: 700, perFile: ["QQPlayer/Services/Gone.swift": 700]),
            name: "超长文件", unit: " 行", repositoryRoot: root
        ).contains { $0.contains("已不存在") })

        // (d) TOTAL 自相矛盾 / 总数回涨 → 红
        #expect(StructuralBudgetRule.violations(
            detected: detected,
            baseline: StructuralBudgetBaseline(total: 999, perFile: [bigPath: 700]),
            name: "超长文件", unit: " 行", repositoryRoot: root
        ).contains { $0.contains("自相矛盾") })
        #expect(StructuralBudgetRule.violations(
            detected: detected,
            baseline: StructuralBudgetBaseline(total: 600, perFile: [bigPath: 600]),
            name: "超长文件", unit: " 行", repositoryRoot: root
        ).contains { $0.contains("总数回涨") })
    }
}
