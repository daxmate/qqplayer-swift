// 结构预算棘轮 · 本地工具（无模拟器、无 Testing）
//
// 为什么存在：基线（QQPlayerTests/Fixtures/structural-budget-*.tsv）必须能**重新生成与自检**，
// 否则只能手抄，而与检测口径漂移是迟早的事。本工具**直接编译口径实现**
// QQPlayerTests/StructuralBudgetRule.swift（单一事实源，不重写一份计数逻辑），
// 仓库根由口径文件的 `#filePath` 推出 → 在任意 worktree 里跑都作用于该 worktree。
//
// 用法（见 scripts/check-structural-budget.sh）：
//   check       用 fixture 基线校验当前仓库（CI 之外的第一道闸）
//   selftest    合成输入正反验证（四条规则必须各自变红）
//   emit        重新生成「超长文件」基线到 stdout
//   emit-prints 重新生成「裸 print」基线到 stdout
//
// 重新生成基线**只允许收紧**：把输出里的行换成对应行、并按需改 `# TOTAL:`；
// 别把新出现的违规文件顺手写进基线（那等于把棘轮拆了）。

import Foundation

func emitSizeBaseline() throws {
    let size = try StructuralBudgetRule.detectedOversizedFiles()
    print("""
    # 超长文件存量清单（单文件 > \(StructuralBudgetRule.fileSizeThreshold) 行）—— 结构预算棘轮基线，只能减不能增
    #
    # 由 QQPlayerTests/StructuralBudgetContractTests.swift 守护（口径实现 StructuralBudgetRule.swift）：
    #   - 出现基线里没有的超长文件（新增未登记） → 红
    #   - 既有文件行数回涨（> 本行数值）         → 红
    #   - 某文件行数下降/已退出超长区间           → 必须同步改/删本行，否则红（名单不腐烂）
    #   - 合计 > TOTAL                            → 红
    #
    # 重新生成（口径由 StructuralBudgetRule 唯一实现，禁止手抄）：
    #   scripts/check-structural-budget.sh emit
    """)
    print(size.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n"))
    print("# TOTAL: \(size.values.reduce(0, +))")
    FileHandle.standardError.write(Data("size=\(size.count) files total=\(size.values.reduce(0, +))\n".utf8))
}

func emitPrintBaseline() throws {
    let prints = try StructuralBudgetRule.detectedPrintCalls()
    print("""
    # 裸 `print(` 存量清单 —— 结构预算棘轮基线，只能减不能增
    #
    # 口径：剥掉 `//` 之后的行尾注释再数 `print(`（与 `grep 'print('` 同口径；
    #       整行注释不计；字符串字面量里的 `print(` 会误计，已知且可接受）。
    # 守护：QQPlayerTests/StructuralBudgetContractTests.swift
    #   诊断输出必须走统一出口（`AppLog`）；存量钉基线，只能减不能增；
    #   新文件带裸 print → 红（确需登记则加行并在提交信息说明理由）。
    #
    # 重新生成：scripts/check-structural-budget.sh emit-prints
    """)
    print(prints.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n"))
    print("# TOTAL: \(prints.values.reduce(0, +))")
    FileHandle.standardError.write(Data("print=\(prints.count) files total=\(prints.values.reduce(0, +))\n".utf8))
}

func runCheck() throws {
    var failed = false

    let sizeBaseline = try StructuralBudgetRule.baseline(at: StructuralBudgetRule.sizeBaselinePath)
    let sizeProblems = StructuralBudgetRule.violations(
        detected: try StructuralBudgetRule.detectedOversizedFiles(),
        baseline: sizeBaseline,
        name: "超长文件",
        unit: " 行"
    )
    print(sizeProblems.isEmpty
        ? "✅ [行数预算] 通过（基线 \(sizeBaseline.perFile.count) 文件 / TOTAL \(sizeBaseline.total)）"
        : "❌ [行数预算] \(sizeProblems.joined(separator: " | "))")
    failed = failed || !sizeProblems.isEmpty

    let printBaseline = try StructuralBudgetRule.baseline(at: StructuralBudgetRule.printBaselinePath)
    let printProblems = StructuralBudgetRule.violations(
        detected: try StructuralBudgetRule.detectedPrintCalls(),
        baseline: printBaseline,
        name: "裸 print(",
        unit: " 处"
    )
    print(printProblems.isEmpty
        ? "✅ [print 预算] 通过（基线 \(printBaseline.perFile.count) 文件 / TOTAL \(printBaseline.total)）"
        : "❌ [print 预算] \(printProblems.joined(separator: " | "))")
    failed = failed || !printProblems.isEmpty

    exit(failed ? 1 : 0)
}

var failures: [String] = []

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        print("  ✅ \(name)")
    } else {
        print("  ❌ \(name) \(detail)")
        failures.append(name)
    }
}

func runSelfTest() throws {    check("行数：结尾换行不计额外行", StructuralBudgetRule.lines(in: "a\nb\n") == 2)
    check("行数：无结尾换行", StructuralBudgetRule.lines(in: "a\nb") == 2)
    check("行数：空文件 0", StructuralBudgetRule.lines(in: "") == 0)
    check("print：整行注释不计", StructuralBudgetRule.printCalls(in: "// print(x)\n") == 0)
    check("print：行尾注释不计", StructuralBudgetRule.printCalls(in: "print(a) // print(b)\n") == 1)
    check("print：一行两处都算", StructuralBudgetRule.printCalls(in: "print(a); print(b)\n") == 2)
    check("print：无 print 为 0", StructuralBudgetRule.printCalls(in: "let x = 1\n") == 0)

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("StructuralBudgetToolSelfTest-\(UUID().uuidString)")
    let services = root.appendingPathComponent("QQPlayer/Services")
    try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let bigPath = "QQPlayer/Services/Big.swift"
    try String(repeating: "let a = 1\n", count: 700)
        .write(to: services.appendingPathComponent("Big.swift"), atomically: true, encoding: .utf8)
    try "print(1)\n".write(to: services.appendingPathComponent("Small.swift"), atomically: true, encoding: .utf8)

    let detected = try StructuralBudgetRule.detectedOversizedFiles(repositoryRoot: root)
    check("检测：抓到 700 行文件", detected == [bigPath: 700], "\(detected)")

    let baseline = StructuralBudgetBaseline(total: 700, perFile: [bigPath: 700])
    check("规则：合规输入无违规", StructuralBudgetRule.violations(
        detected: detected, baseline: baseline, name: "超长文件", unit: " 行", repositoryRoot: root
    ).isEmpty)

    check("规则(a)：新增未登记超长文件 → 红", StructuralBudgetRule.violations(
        detected: detected.merging(["QQPlayer/Services/New.swift": 800]) { _, new in new },
        baseline: baseline, name: "超长文件", unit: " 行", repositoryRoot: root
    ).contains { $0.contains("新增了") })

    check("规则(b)：行数回涨 → 红", StructuralBudgetRule.violations(
        detected: [bigPath: 701], baseline: baseline, name: "超长文件", unit: " 行", repositoryRoot: root
    ).contains { $0.contains("回涨") })

    check("规则(c)：行数下降未改基线 → 红（名单不腐烂）", StructuralBudgetRule.violations(
        detected: [bigPath: 500], baseline: baseline, name: "超长文件", unit: " 行", repositoryRoot: root
    ).contains { $0.contains("腐烂") })

    check("规则(c2)：基线文件已消失 → 红", StructuralBudgetRule.violations(
        detected: detected,
        baseline: StructuralBudgetBaseline(total: 700, perFile: ["QQPlayer/Services/Gone.swift": 700]),
        name: "超长文件", unit: " 行", repositoryRoot: root
    ).contains { $0.contains("已不存在") })

    check("规则(d)：TOTAL 自相矛盾 → 红", StructuralBudgetRule.violations(
        detected: detected,
        baseline: StructuralBudgetBaseline(total: 999, perFile: [bigPath: 700]),
        name: "超长文件", unit: " 行", repositoryRoot: root
    ).contains { $0.contains("自相矛盾") })

    check("规则(d2)：总数回涨 → 红", StructuralBudgetRule.violations(
        detected: detected,
        baseline: StructuralBudgetBaseline(total: 600, perFile: [bigPath: 600]),
        name: "超长文件", unit: " 行", repositoryRoot: root
    ).contains { $0.contains("总数回涨") })

    print(failures.isEmpty ? "✅ ALL PASS" : "❌ FAILED: \(failures.joined(separator: ", "))")
    exit(failures.isEmpty ? 0 : 1)
}

// 入口：用 @main 而非顶层语句——多文件编译时只有 `main.swift` 允许顶层语句，
// 本文件在仓库里叫 `structural-budget-tool.swift`，顶层语句会被 swiftc 拒绝（实测踩到）。
@main
struct StructuralBudgetTool {
    static func main() {
        do {
            switch CommandLine.arguments.dropFirst().first ?? "check" {
            case "emit": try emitSizeBaseline()
            case "emit-prints": try emitPrintBaseline()
            case "selftest": try runSelfTest()
            case "check": try runCheck()
            default:
                print("unknown mode（可用：check / selftest / emit / emit-prints）")
                exit(2)
            }
        } catch {
            print("❌ \(error)")
            exit(1)
        }
    }
}
