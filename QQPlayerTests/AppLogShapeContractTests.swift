//
//  AppLogShapeContractTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  日志治理批 1（地基）的 fail-closed 形状守卫 + 自证测试（2026-09-20）。
//  设计源：`tmp/docs/logging.md` §一 / §二 / §五。
//
//  为什么需要形状守卫：`AppLog` / `LogRotation` 的语义就是「唯一出口」「唯一轮转实现」，
//  行为测试只能证「今天这版对」，挡不住下一个人再抄一份（AGENTS.md 2026-09-15：
//  共享语义防第二实现必须靠形状测试，不能靠人记得）。
//
//  三条守卫（全部 fail-closed：目录/文件/基线读不到 = 红，绝不静默通过）：
//   ① `AppLogSink` 的实现只允许出现在 `QQPlayer/Services/AppLog.swift`
//      （白名单只留入口本身；名单里的文件不存在、或已不再实现 sink = 红）
//   ② `rotateIfNeeded` / `trimTailIfNeeded` 只允许**定义**在 `LogRotation.swift`；
//      调用点白名单制（名单里的文件不存在、或不真的调用 = 红）
//   ③ 复用**既有裸 print 棘轮**（`StructuralBudgetRule` + 既有 TSV 基线），不另建第二套口径：
//      (a) `migratedChains`（批 2 起非空：sync 链路 5 文件 / 14 处）里的文件裸 `print(` == 0 且 `NSLog(` == 0
//      (b) `migratedChains` 里的文件不得同时出现在既有 print 基线 TSV 里（两处口径打架 = 红）
//      (c) 既有棘轮仍在且可用：口径文件 + 两份基线存在/可读/可解析且 TOTAL 自洽
//
//  ⚠️ 任务包原字面要求「新建 TSV 基线 + 自建 print 计数口径」，与仓库现实冲突
//  （仓库已存在裸 print 棘轮：`StructuralBudgetRule.swift` + `Fixtures/structural-budget-print-baseline.tsv`
//  + `StructuralBudgetContractTests.swift`；再建一份 = 同一语义第二实现）——
//  maintainer 定案「复用既有棘轮」，本文件照此实现，计数一律走 `StructuralBudgetRule`。
//
//  为什么三条守卫都要自证：只测「当前通过」的守卫会退化成永远绿。每条都在**临时目录里合成
//  假文件**做反向验证（能变红），再做真实仓库正向断言。
//

import Foundation
import Testing

@testable import QQPlayer

private enum AppLogShapeContract {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 扫描范围（相对仓库根）。
    static let scannedDirectory = "QQPlayer"

    /// 守卫①白名单：`AppLogSink` 实现的唯一允许位置（只留入口本身）。
    static let sinkImplementationWhitelist: Set<String> = ["QQPlayer/Services/AppLog.swift"]
    /// 守卫②白名单：两个轮转入口的**定义**位置。
    static let rotationDefinitionWhitelist: Set<String> = ["QQPlayer/Services/LogRotation.swift"]
    /// 守卫②白名单：轮转入口的**调用点**（路径 → 允许调用的入口名）。
    static let rotationCallSites: [String: Set<String>] = [
        "QQPlayer/Services/AppLog.swift": ["rotateIfNeeded"],
    ]
    /// 本批**尚无生产调用点**的入口：`trimTailIfNeeded` 服务的是既有 256KB/64KB 环形截断，
    /// 那些调用点（`SyncConnectDiag` / `DatabaseManager.dbDiag`）属「不迁移」清单，批 2/3 接入时
    /// 把调用点逐个登记进 `rotationCallSites`。此集合只用于「口径完整性」自证，不是豁免：
    /// 谁在别处调 `trimTailIfNeeded` 一样会被调用点检查判红。
    static let rotationEntriesWithoutCallSites: Set<String> = ["trimTailIfNeeded"]

    /// 受管的轮转入口名（定义唯一 + 调用点白名单制都按这份清单查）。
    static let rotationEntries: Set<String> = ["rotateIfNeeded", "trimTailIfNeeded"]

    /// 守卫③(a)：已迁到 `AppLog` 的链路文件清单（迁移完成的文件逐个登记）。
    /// 当前 = 批 2 sync 链路 5 文件 / 14 处 + 批 3 migration/DB 链路 9 文件 / 141 处，共 14 文件。
    /// 批 2 起把迁移完成的文件逐个加进来：加进来的文件必须零裸 `print(` / 零 `NSLog(`。
    /// 清单只此一处——不在基线 TSV 里再维护一份（那是同一语义第二实现）。
    static let migratedChains: Set<String> = [
        "QQPlayer/Services/DatabaseManager+ContentHash.swift",
        "QQPlayer/Services/DatabaseManager+Library.swift",
        "QQPlayer/Services/DatabaseManager+Migration.swift",
        "QQPlayer/Services/DatabaseManager+Playlists.swift",
        "QQPlayer/Services/DatabaseManager+Schema.swift",
        "QQPlayer/Services/DatabaseManager+Tracks.swift",
        "QQPlayer/Services/DatabaseManager.swift",
        "QQPlayer/Services/SandboxMigration.swift",
        "QQPlayer/Services/TrackIdentityMigration.swift",
        "QQPlayer/Sync/SyncChangeLogApplier.swift",
        "QQPlayer/Sync/SyncChangeLogPeer.swift",
        "QQPlayer/Sync/SyncChangeLogPendingStore.swift",
        "QQPlayer/Sync/SyncFileReceiver.swift",
        "QQPlayer/Sync/SyncWiringSelfCheck.swift",
    ]

    /// 守卫③(c)：既有棘轮的文件（缺一即红，防「名单腐烂 / 守卫被删」）。
    static let ratchetRulePath = "QQPlayerTests/StructuralBudgetRule.swift"
    static let printBaselinePath = StructuralBudgetRule.printBaselinePath
    static let sizeBaselinePath = StructuralBudgetRule.sizeBaselinePath

    // MARK: - 扫描

    struct SourceFile {
        var relativePath: String
        var source: String
    }

    enum ContractError: Error, CustomStringConvertible {
        case unreadable(String)

        var description: String {
            switch self {
            case .unreadable(let path):
                "契约测试无法枚举/读取（fail-closed）：\(path)"
            }
        }
    }

    /// 仓库内 `QQPlayer/**/*.swift`（相对路径 + 源码；读不到即抛错，绝不静默跳过）。
    static func repositoryFiles(repositoryRoot root: URL) throws -> [SourceFile] {
        let directory = root.appendingPathComponent(scannedDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractError.unreadable(scannedDirectory)
        }
        let prefix = root.resolvingSymlinksInPath().path + "/"
        var files: [SourceFile] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "")
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw ContractError.unreadable(relative)
            }
            files.append(SourceFile(relativePath: relative, source: source))
        }
        guard !files.isEmpty else { throw ContractError.unreadable("\(scannedDirectory)（枚举为空）") }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    /// 逐行剥掉 `//` 之后的内容（与 `StructuralBudgetRule.printCalls` 同款口径）：
    /// 注释/文档里「提到」某个符号不算第二实现。
    static func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        StructuralBudgetRule.occurrences(of: needle, in: haystack)
    }

    static func count(_ pattern: NSRegularExpression, in haystack: String) -> Int {
        pattern.numberOfMatches(in: haystack, range: NSRange(haystack.startIndex ..< haystack.endIndex, in: haystack))
    }

    /// `: AppLogSink` 一致性声明（`protocol AppLogSink: Sendable` 这种「冒号在后」不匹配）。
    private static let sinkConformancePattern = try! NSRegularExpression(pattern: "[:]\\s*AppLogSink\\b")

    // MARK: - 守卫①

    static func sinkImplementationViolations(files: [SourceFile], whitelist: Set<String>) -> [String] {
        var problems: [String] = []
        for file in files {
            let hits = count(sinkConformancePattern, in: codeOnly(file.source))
            guard hits > 0 else { continue }
            guard !whitelist.contains(file.relativePath) else { continue }
            problems.append(
                "\(file.relativePath)：出现 `: AppLogSink` 实现（\(hits) 处）——"
                    + "实现只允许写在 \(whitelist.sorted().joined(separator: ", "))"
            )
        }
        // 名单不许腐烂/空转：名单文件必须存在且真的实现 sink（否则守卫退化成永远绿）。
        for path in whitelist.sorted() {
            guard let file = files.first(where: { $0.relativePath == path }) else {
                problems.append("白名单文件不存在（fail-closed）：\(path)")
                continue
            }
            if count(sinkConformancePattern, in: codeOnly(file.source)) == 0 {
                problems.append("白名单文件已不再实现 `AppLogSink`（名单腐烂）：\(path)")
            }
        }
        return problems
    }

    // MARK: - 守卫②

    /// 入口的**定义**判定：`func <入口>(` 出现次数。
    static func definitionCount(of entry: String, in source: String) -> Int {
        occurrences(of: "func " + entry + "(", in: codeOnly(source))
    }

    /// 入口的**调用**判定：`<入口>(` 出现次数 − 定义行（`func <入口>(`）。
    static func callCount(of entry: String, in source: String) -> Int {
        let code = codeOnly(source)
        return max(
            occurrences(of: entry + "(", in: code) - occurrences(of: "func " + entry + "(", in: code),
            0
        )
    }

    static func rotationViolations(
        files: [SourceFile],
        definitionWhitelist: Set<String>,
        callSites: [String: Set<String>]
    ) -> [String] {
        var problems: [String] = []

        // 定义：受管入口只允许在定义白名单文件里定义；且必须真的有人定义（否则守卫空转）。
        for entry in rotationEntries.sorted() {
            let definers = files.filter { definitionCount(of: entry, in: $0.source) > 0 }
            if definers.isEmpty {
                problems.append("没有任何文件定义 `\(entry)`（fail-closed：守卫会退化成永远绿）")
            }
            for file in definers where !definitionWhitelist.contains(file.relativePath) {
                problems.append(
                    "\(file.relativePath)：定义了 `\(entry)`——只允许定义在 "
                        + definitionWhitelist.sorted().joined(separator: ", ")
                )
            }
        }
        for path in definitionWhitelist.sorted() {
            guard let file = files.first(where: { $0.relativePath == path }) else {
                problems.append("定义白名单文件不存在（fail-closed）：\(path)")
                continue
            }
            for entry in rotationEntries.sorted() where definitionCount(of: entry, in: file.source) == 0 {
                problems.append("定义白名单文件已不再定义 `\(entry)`（名单腐烂）：\(path)")
            }
        }

        // 调用点：白名单外任何文件调受管入口 = 红；白名单条目不许空转。
        for file in files {
            let called = rotationEntries.sorted().filter { callCount(of: $0, in: file.source) > 0 }
            guard !called.isEmpty else { continue }
            let allowed = callSites[file.relativePath] ?? []
            let unexpected = called.filter { !allowed.contains($0) }
            if !unexpected.isEmpty {
                problems.append(
                    "\(file.relativePath)：调用了 \(unexpected) —— 调用点未登记（白名单制，"
                        + "需显式改 `rotationCallSites`）"
                )
            }
        }
        for (path, entries) in callSites.sorted(by: { $0.key < $1.key }) {
            guard let file = files.first(where: { $0.relativePath == path }) else {
                problems.append("调用点白名单文件不存在（fail-closed）：\(path)")
                continue
            }
            for entry in entries.sorted() where callCount(of: entry, in: file.source) == 0 {
                problems.append("调用点白名单已空转（不再调用 `\(entry)`）：\(path)")
            }
        }
        for entry in rotationEntriesWithoutCallSites.sorted()
            where !rotationEntries.contains(entry) {
            problems.append("`rotationEntriesWithoutCallSites` 里的 `\(entry)` 不在受管入口清单里")
        }
        return problems
    }

    // MARK: - 守卫③

    /// `NSLog(` 计数：复用 `StructuralBudgetRule.occurrences` 的行内计数口径
    /// （**不另写一份 print 计数正则**；剥注释口径与 `StructuralBudgetRule.printCalls` 一致）。
    static func nsLogCalls(in source: String) -> Int {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { partial, rawLine in
                let code = String(rawLine).components(separatedBy: "//").first ?? ""
                return partial + occurrences(of: "NSLog(", in: code)
            }
    }

    /// 守卫③(a)：已迁链路必须零裸 `print(` / 零 `NSLog(`（本批清单为空集 ⇒ 恒真，批 2 起有约束力）。
    static func migratedChainViolations(migratedChains: Set<String>, files: [SourceFile]) -> [String] {
        var problems: [String] = []
        for path in migratedChains.sorted() {
            guard let file = files.first(where: { $0.relativePath == path }) else {
                problems.append("已迁清单里的文件不存在/读不到（fail-closed）：\(path)")
                continue
            }
            let prints = StructuralBudgetRule.printCalls(in: file.source)
            if prints > 0 {
                problems.append("\(path)：已迁链路仍有裸 `print(` \(prints) 处（诊断输出必须走 `AppLog`）")
            }
            let logs = nsLogCalls(in: file.source)
            if logs > 0 {
                problems.append("\(path)：已迁链路仍有 `NSLog(` \(logs) 处（诊断输出必须走 `AppLog`）")
            }
        }
        return problems
    }

    /// 守卫③(b)：已迁清单与既有 print 基线 TSV 不得重叠（两处口径打架 = 红）。
    static func migratedChainBaselineOverlap(
        migratedChains: Set<String>,
        baseline: StructuralBudgetBaseline
    ) -> [String] {
        migratedChains.sorted().compactMap { path in
            guard baseline.perFile[path] != nil else { return nil }
            return "\(path)：同时在已迁清单（要求零 print）与既有 print 基线 TSV（点数 \(baseline.perFile[path] ?? 0)）里"
        }
    }

    /// 守卫③(c)：既有棘轮仍在且可用（口径文件 + 两份基线存在/可读/可解析/自洽）。
    static func ratchetAvailabilityViolations(repositoryRoot root: URL) -> [String] {
        var problems: [String] = []
        let ruleURL = root.appendingPathComponent(ratchetRulePath)
        if !FileManager.default.fileExists(atPath: ruleURL.path) {
            problems.append("既有棘轮口径文件不存在：\(ratchetRulePath)")
        } else if let text = try? String(contentsOf: ruleURL, encoding: .utf8), text.isEmpty {
            problems.append("既有棘轮口径文件为空：\(ratchetRulePath)")
        } else if (try? String(contentsOf: ruleURL, encoding: .utf8)) == nil {
            problems.append("既有棘轮口径文件读不到：\(ratchetRulePath)")
        }
        for path in [printBaselinePath, sizeBaselinePath] {
            do {
                let baseline = try StructuralBudgetRule.baseline(at: path, repositoryRoot: root)
                let sum = baseline.perFile.values.reduce(0, +)
                if sum != baseline.total {
                    problems.append("\(path)：基线 TOTAL 不自洽（各行合计 \(sum) ≠ TOTAL \(baseline.total)）")
                }
            } catch {
                problems.append("\(path)：基线缺失/不可解析（fail-closed）：\(error)")
            }
        }
        return problems
    }

    // MARK: - 合成输入（自证用）

    /// 合成仓库：把给定文件写进临时目录，返回根 URL（调用方负责删除）。
    static func makeSyntheticRepository(_ files: [String: String]) throws -> URL {
        let root = try makeSyntheticDirectory()
        for (relativePath, content) in files {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    static func makeSyntheticDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppLogShapeSelfTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 既有棘轮的两份基线在合成仓库里的最小可用形态（TOTAL 自洽）。
    static var syntheticRatchetFiles: [String: String] {
        [
            ratchetRulePath: "// 合成口径文件（自证用）\n",
            printBaselinePath: "QQPlayer/Sync/Other.swift\t3\n# TOTAL: 3\n",
            sizeBaselinePath: "# TOTAL: 0\n",
        ]
    }
}

@Suite("AppLog 统一出口形状守卫（批 1 地基）")
struct AppLogShapeContractTests {
    @Test("守卫①：`AppLogSink` 实现只允许在 AppLog.swift")
    func sinkImplementationsAreUnique() throws {
        let files = try AppLogShapeContract.repositoryFiles(repositoryRoot: AppLogShapeContract.repositoryRoot)
        let problems = AppLogShapeContract.sinkImplementationViolations(
            files: files,
            whitelist: AppLogShapeContract.sinkImplementationWhitelist
        )
        #expect(
            problems.isEmpty,
            """
            `AppLogSink` 实现散到了别处（同一语义第二实现）：
            \(problems.joined(separator: "\n"))
            """
        )
    }

    @Test("守卫②：轮转入口只允许定义在 LogRotation.swift，调用点白名单制")
    func rotationEntryPointsAreUnique() throws {
        let files = try AppLogShapeContract.repositoryFiles(repositoryRoot: AppLogShapeContract.repositoryRoot)
        let problems = AppLogShapeContract.rotationViolations(
            files: files,
            definitionWhitelist: AppLogShapeContract.rotationDefinitionWhitelist,
            callSites: AppLogShapeContract.rotationCallSites
        )
        #expect(
            problems.isEmpty,
            """
            轮转语义出现第二实现 / 未登记调用点：
            \(problems.joined(separator: "\n"))
            """
        )
    }

    @Test("守卫③(a)：已迁链路零裸 `print(` / 零 `NSLog(`")
    func migratedChainsArePrintFree() throws {
        let files = try AppLogShapeContract.repositoryFiles(repositoryRoot: AppLogShapeContract.repositoryRoot)
        let problems = AppLogShapeContract.migratedChainViolations(
            migratedChains: AppLogShapeContract.migratedChains,
            files: files
        )
        #expect(
            problems.isEmpty,
            """
            已迁到 `AppLog` 的链路里还有裸 print / NSLog：
            \(problems.joined(separator: "\n"))
            """
        )
    }

    @Test("守卫③(b)：已迁清单不得与既有 print 基线 TSV 重叠")
    func migratedChainsDoNotOverlapBaseline() throws {
        let baseline = try StructuralBudgetRule.baseline(at: AppLogShapeContract.printBaselinePath)
        let problems = AppLogShapeContract.migratedChainBaselineOverlap(
            migratedChains: AppLogShapeContract.migratedChains,
            baseline: baseline
        )
        #expect(
            problems.isEmpty,
            """
            两处口径打架（已迁清单要求零 print，基线却还记着点数）：
            \(problems.joined(separator: "\n"))
            """
        )
    }

    @Test("守卫③(c)：既有裸 print 棘轮仍在且可用（口径文件 + 两份基线）")
    func existingRatchetIsPresentAndParseable() {
        let problems = AppLogShapeContract.ratchetAvailabilityViolations(
            repositoryRoot: AppLogShapeContract.repositoryRoot
        )
        #expect(
            problems.isEmpty,
            """
            既有棘轮缺失/不可解析（守卫③ 赖以生效的口径源没了）：
            \(problems.joined(separator: "\n"))
            """
        )
    }

    @Test("自证①：`AppLogSink` 第二个实现必须变红（合成仓库）")
    func sinkImplementationGuardHasTeeth() throws {
        let root = try AppLogShapeContract.makeSyntheticRepository([
            "QQPlayer/Services/AppLog.swift": "protocol AppLogSink: Sendable {}\nstruct OSLogSink: AppLogSink {}\n",
            "QQPlayer/Services/Sneaky.swift": "struct SneakySink: AppLogSink {}\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let files = try AppLogShapeContract.repositoryFiles(repositoryRoot: root)
        let whitelist: Set<String> = ["QQPlayer/Services/AppLog.swift"]

        let problems = AppLogShapeContract.sinkImplementationViolations(files: files, whitelist: whitelist)
        #expect(problems.contains { $0.contains("QQPlayer/Services/Sneaky.swift") }, "没抓到第二实现：\(problems)")

        // 名单腐烂也要红：白名单文件不实现 sink / 白名单文件不存在
        #expect(!AppLogShapeContract.sinkImplementationViolations(
            files: [AppLogShapeContract.SourceFile(relativePath: "QQPlayer/Services/AppLog.swift", source: "enum AppLog {}\n")],
            whitelist: whitelist
        ).isEmpty)
        #expect(AppLogShapeContract.sinkImplementationViolations(files: [], whitelist: whitelist)
            .contains { $0.contains("白名单文件不存在") })
    }

    @Test("自证②：轮转入口第二定义 / 未登记调用点必须变红（合成仓库）")
    func rotationGuardHasTeeth() throws {
        let definitionWhitelist: Set<String> = ["QQPlayer/Services/LogRotation.swift"]
        let callSites = ["QQPlayer/Services/AppLog.swift": Set(["rotateIfNeeded"])]
        let whitelistSource = """
        enum LogRotation {
            static func rotateIfNeeded() {}
            static func trimTailIfNeeded() {}
        }
        """
        let callerSource = "let _ = LogRotation.rotateIfNeeded()\n"

        // 正向：定义在白名单文件 + 调用点在白名单 → 无违规
        #expect(AppLogShapeContract.rotationViolations(
            files: [
                .init(relativePath: "QQPlayer/Services/LogRotation.swift", source: whitelistSource),
                .init(relativePath: "QQPlayer/Services/AppLog.swift", source: callerSource),
            ],
            definitionWhitelist: definitionWhitelist,
            callSites: callSites
        ).isEmpty)

        // 第二定义（别处又写一份）→ 红
        let secondDefinition = AppLogShapeContract.rotationViolations(
            files: [
                .init(relativePath: "QQPlayer/Services/LogRotation.swift", source: whitelistSource),
                .init(relativePath: "QQPlayer/Services/AppLog.swift", source: callerSource),
                .init(
                    relativePath: "QQPlayer/Sync/SneakySync.swift",
                    source: "enum Sneaky { static func rotateIfNeeded() {} }\n"
                ),
            ],
            definitionWhitelist: definitionWhitelist,
            callSites: callSites
        )
        #expect(secondDefinition.contains { $0.contains("QQPlayer/Sync/SneakySync.swift") }, "\(secondDefinition)")

        // 未登记调用点（白名单外文件调用）→ 红
        let unregisteredCall = AppLogShapeContract.rotationViolations(
            files: [
                .init(relativePath: "QQPlayer/Services/LogRotation.swift", source: whitelistSource),
                .init(relativePath: "QQPlayer/Services/AppLog.swift", source: callerSource),
                .init(relativePath: "QQPlayer/Sync/Other.swift", source: "LogRotation.trimTailIfNeeded()\n"),
            ],
            definitionWhitelist: definitionWhitelist,
            callSites: callSites
        )
        #expect(unregisteredCall.contains { $0.contains("QQPlayer/Sync/Other.swift") }, "\(unregisteredCall)")

        // 空转：定义白名单文件不再定义 / 调用点白名单不再调用 / 受管入口无人定义 → 红
        #expect(!AppLogShapeContract.rotationViolations(
            files: [
                .init(relativePath: "QQPlayer/Services/LogRotation.swift", source: "enum LogRotation {}\n"),
                .init(relativePath: "QQPlayer/Services/AppLog.swift", source: callerSource),
            ],
            definitionWhitelist: definitionWhitelist,
            callSites: callSites
        ).isEmpty)
        #expect(!AppLogShapeContract.rotationViolations(
            files: [
                .init(relativePath: "QQPlayer/Services/LogRotation.swift", source: whitelistSource),
                .init(relativePath: "QQPlayer/Services/AppLog.swift", source: "// 不再调用\n"),
            ],
            definitionWhitelist: definitionWhitelist,
            callSites: callSites
        ).isEmpty)
        #expect(AppLogShapeContract.rotationViolations(
            files: [.init(relativePath: "QQPlayer/Services/AppLog.swift", source: callerSource)],
            definitionWhitelist: definitionWhitelist,
            callSites: callSites
        ).contains { $0.contains("没有任何文件定义") })
    }

    @Test("自证③：已迁链路带 print / 与基线重叠 / 棘轮缺失都必须变红（合成仓库）")
    func printRatchetGuardHasTeeth() throws {
        let ratchet = AppLogShapeContract.syntheticRatchetFiles
        var files = ratchet
        files["QQPlayer/Sync/Migrated.swift"] = "func f() {\n    print(\"x\")\n}\n"
        let root = try AppLogShapeContract.makeSyntheticRepository(files)
        defer { try? FileManager.default.removeItem(at: root) }

        let scanned = try AppLogShapeContract.repositoryFiles(repositoryRoot: root)
        let migrated: Set<String> = ["QQPlayer/Sync/Migrated.swift"]

        // (a) 清单里的文件带裸 print → 红
        let migratedProblems = AppLogShapeContract.migratedChainViolations(
            migratedChains: migrated,
            files: scanned
        )
        #expect(migratedProblems.contains { $0.contains("QQPlayer/Sync/Migrated.swift") }, "\(migratedProblems)")

        // (b) 清单文件同时出现在既有基线 TSV → 红
        let baseline = try StructuralBudgetRule.baseline(
            at: AppLogShapeContract.printBaselinePath,
            repositoryRoot: root
        )
        #expect(AppLogShapeContract.migratedChainBaselineOverlap(
            migratedChains: migrated.union(["QQPlayer/Sync/Other.swift"]),
            baseline: baseline
        ).contains { $0.contains("QQPlayer/Sync/Other.swift") })

        // (c) 棘轮可用性：合成仓库里完整 → 绿；删掉口径文件 / 基线 → 红
        #expect(AppLogShapeContract.ratchetAvailabilityViolations(repositoryRoot: root).isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent(AppLogShapeContract.ratchetRulePath))
        try FileManager.default.removeItem(at: root.appendingPathComponent(AppLogShapeContract.printBaselinePath))
        let broken = AppLogShapeContract.ratchetAvailabilityViolations(repositoryRoot: root)
        #expect(broken.contains { $0.contains("口径文件不存在") }, "\(broken)")
        #expect(broken.contains { $0.contains(AppLogShapeContract.printBaselinePath) }, "\(broken)")

        // (d) 清单文件不存在 → 红（fail-closed，不静默跳过）
        #expect(AppLogShapeContract.migratedChainViolations(
            migratedChains: ["QQPlayer/Sync/Gone.swift"],
            files: scanned
        ).contains { $0.contains("不存在") })

        // 计数口径复用既有棘轮（不在本文件另写 print 正则）：NSLog 也走同一行内计数
        #expect(AppLogShapeContract.nsLogCalls(in: "NSLog(\"x\")\nprint(1)\n") == 1)
        #expect(AppLogShapeContract.nsLogCalls(in: "// NSLog(\"注释里提一下\")\n") == 0)
        #expect(StructuralBudgetRule.printCalls(in: "// print(x)\nprint(y)\n") == 1)
    }
}

// MARK: - 行为（AppLog 行格式 / 阈值 / LogRotation 三个入口）

//  `.serialized`：套件内多个用例共享全局状态（`AppLog.logFileURLOverride` / UserDefaults），
//  并行会互相改写落点（swift-testing 默认并行）——串行是这里唯一安全的形状。
@Suite("AppLog 出口与 LogRotation 行为（批 1 地基）", .serialized)
struct AppLogBehaviorTests {
    @Test("行格式：UTC ISO8601 + 级别 + 分类 + emoji；消息内换行折叠为 ⏎")
    func lineFormatAndNewlineFolding() {
        let line = AppLog.formatLine(
            timestamp: Date(timeIntervalSince1970: 0),
            level: .warn,
            category: .db,
            message: "⚠️ 打开失败 error=disk full"
        )
        #expect(line == "[1970-01-01T00:00:00Z] [WARN] [db] ⚠️ 打开失败 error=disk full")
        #expect(AppLog.foldNewlines("a\nb") == "a⏎b")
        #expect(AppLog.foldNewlines("a\r\nb") == "a⏎b")
        #expect(AppLog.foldNewlines("a\rb") == "a⏎b")
        #expect(AppLogLevel.error.label == "ERROR")
        #expect(AppLogLevel.debug.label == "DEBUG")
    }

    @Test("级别顺序：debug < info < warn < error；解析大小写不敏感、非法值 nil")
    func levelOrderingAndParsing() {
        #expect(AppLogLevel.debug < AppLogLevel.info)
        #expect(AppLogLevel.info < AppLogLevel.warn)
        #expect(AppLogLevel.warn < AppLogLevel.error)
        #expect(AppLogLevel.parse(" WARN ") == .warn)
        #expect(AppLogLevel.parse("Error") == .error)
        #expect(AppLogLevel.parse("bogus") == nil)
        #expect(AppLogLevel.allCases.count == 4)
    }

    @Test("阈值优先级：env → UserDefaults → 构建默认（非法值忽略）")
    func thresholdPriority() {
        #expect(AppLog.resolveLevel(
            environment: [AppLog.levelEnvironmentKey: "warn"],
            defaultsValue: "debug",
            buildDefault: .info
        ) == .warn)
        #expect(AppLog.resolveLevel(
            environment: [:],
            defaultsValue: "error",
            buildDefault: .info
        ) == .error)
        #expect(AppLog.resolveLevel(environment: [:], defaultsValue: nil, buildDefault: .info) == .info)
        #expect(AppLog.resolveLevel(
            environment: [AppLog.levelEnvironmentKey: "bogus"],
            defaultsValue: nil,
            buildDefault: .info
        ) == .info)
        #expect(AppLog.resolveLevel(
            environment: [AppLog.levelEnvironmentKey: "WARN"],
            defaultsValue: nil,
            buildDefault: .debug
        ) == .warn)
    }

    @Test("上限来源：env 可临时放大，非法值忽略")
    func limitsFromEnvironment() {
        #expect(LogRotation.currentLimits(environment: [
            "QQPLAYER_LOG_MAX_MB": "1",
            "QQPLAYER_LOG_MAX_FILES": "2",
        ]) == LogRotation.Limits(maxBytes: 1024 * 1024, maxFiles: 2))
        #expect(LogRotation.currentLimits(environment: [:]).maxBytes == LogRotation.defaultMaxBytes)
        #expect(LogRotation.currentLimits(environment: [:]).maxFiles == LogRotation.defaultMaxFiles)
        #expect(LogRotation.currentLimits(environment: ["QQPLAYER_LOG_MAX_MB": "0"]).maxBytes == LogRotation.defaultMaxBytes)
        #expect(LogRotation.currentLimits(environment: ["QQPLAYER_LOG_MAX_FILES": "abc"]).maxFiles == LogRotation.defaultMaxFiles)
    }

    @Test("归档轮转：app.log → .1 → .2……，份数含当前文件，最老份被删")
    func archiveRotation() throws {
        let directory = try AppLogShapeContract.makeSyntheticDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("app.log")
        let limits = LogRotation.Limits(maxBytes: 100, maxFiles: 3)

        let first = String(repeating: "a", count: 150)
        try first.write(to: url, atomically: true, encoding: .utf8)
        #expect(LogRotation.rotateIfNeeded(at: url, limits: limits) == .archived(bytes: 150))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(LogRotation.fileSize(at: LogRotation.archiveURL(for: url, index: 1)) == 150)

        let second = String(repeating: "b", count: 150)
        try second.write(to: url, atomically: true, encoding: .utf8)
        #expect(LogRotation.rotateIfNeeded(at: url, limits: limits) == .archived(bytes: 150))
        #expect(try String(contentsOf: LogRotation.archiveURL(for: url, index: 2), encoding: .utf8) == first)
        #expect(try String(contentsOf: LogRotation.archiveURL(for: url, index: 1), encoding: .utf8) == second)

        // 第 3 次：maxFiles = 3 ⇒ 归档位 2 个，最老的（内容 first）被删、second 退到 .2
        let third = String(repeating: "c", count: 150)
        try third.write(to: url, atomically: true, encoding: .utf8)
        #expect(LogRotation.rotateIfNeeded(at: url, limits: limits) == .archived(bytes: 150))
        #expect(try String(contentsOf: LogRotation.archiveURL(for: url, index: 2), encoding: .utf8) == second)
        #expect(try String(contentsOf: LogRotation.archiveURL(for: url, index: 1), encoding: .utf8) == third)

        // 未超上限 → 不动
        try String(repeating: "d", count: 50).write(to: url, atomically: true, encoding: .utf8)
        #expect(LogRotation.rotateIfNeeded(at: url, limits: limits) == .unchanged)
        #expect(LogRotation.fileSize(at: url) == 50)
    }

    @Test("环形截断：超阈值只留尾部 keepBytes（保既有 256KB/64KB 语义）")
    func ringTrim() throws {
        let directory = try AppLogShapeContract.makeSyntheticDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ring.log")
        let content = String(repeating: "0123456789", count: 100) // 1000 字节

        try content.write(to: url, atomically: true, encoding: .utf8)
        #expect(LogRotation.trimTailIfNeeded(at: url, thresholdBytes: 900, keepBytes: 30))
        let trimmed = try String(contentsOf: url, encoding: .utf8)
        #expect(trimmed.utf8.count == 30)
        #expect(content.hasSuffix(trimmed))

        // 未超阈值 / 保留量非法 → 不动
        #expect(!LogRotation.trimTailIfNeeded(at: url, thresholdBytes: 900, keepBytes: 30))
        #expect(!LogRotation.trimTailIfNeeded(at: url, thresholdBytes: 1, keepBytes: 0))
    }

    @Test("丢历史：文件远超总预算（maxBytes × maxFiles）→ 截空且不留归档")
    func discardHistoryBeyondTotalBudget() throws {
        let directory = try AppLogShapeContract.makeSyntheticDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("app.log")
        let limits = LogRotation.Limits(maxBytes: 100, maxFiles: 4) // 总预算 400

        // 存量归档 + 遗留大文件（49MB 形态的缩样）
        try String(repeating: "z", count: 150).write(to: LogRotation.archiveURL(for: url, index: 1), atomically: true, encoding: .utf8)
        try String(repeating: "y", count: 5_000).write(to: url, atomically: true, encoding: .utf8)

        #expect(LogRotation.shouldDiscardHistory(at: url, limits: limits))
        #expect(LogRotation.rotateIfNeeded(at: url, limits: limits) == .discardedHistory(bytes: 5_000))
        #expect(LogRotation.fileSize(at: url) == 0)
        #expect(!FileManager.default.fileExists(atPath: LogRotation.archiveURL(for: url, index: 1).path))

        // 预算内不丢
        try String(repeating: "x", count: 300).write(to: url, atomically: true, encoding: .utf8)
        #expect(!LogRotation.shouldDiscardHistory(at: url, limits: limits))
    }

    @Test("落点：override 优先；平台默认落点为 app.log")
    func logFileURLResolution() throws {
        let directory = try AppLogShapeContract.makeSyntheticDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let override = directory.appendingPathComponent("custom/app.log")
        AppLog.logFileURLOverride = override
        defer { AppLog.logFileURLOverride = nil }
        #expect(AppLog.logFileURL() == override)

        AppLog.logFileURLOverride = nil
        let resolved = AppLog.logFileURL()
        #expect(resolved?.lastPathComponent == "app.log")
        #if os(macOS)
            #expect(resolved?.path.contains("/Library/Logs/QQPlayerMac/") == true)
        #else
            #expect(resolved?.path.contains("/Documents/") == true)
        #endif
    }

    @Test("端到端：阈值过滤（@autoclosure 被滤掉即零成本）+ 写一行落到 app.log")
    func endToEndThresholdAndWrite() throws {
        try #require(
            ProcessInfo.processInfo.environment[AppLog.levelEnvironmentKey] == nil,
            "环境变量已设置阈值，无法断言 UserDefaults 路径"
        )
        let directory = try AppLogShapeContract.makeSyntheticDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("app.log")
        AppLog.logFileURLOverride = url
        defer { AppLog.logFileURLOverride = nil }
        UserDefaults.standard.set("warn", forKey: AppLog.levelDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: AppLog.levelDefaultsKey) }

        #expect(AppLog.threshold == .warn)
        #expect(AppLog.isEnabled(.warn, .general))
        #expect(!AppLog.isEnabled(.debug, .transfer))

        let flag = ExpensiveMessageFlag()
        AppLog.debug(.transfer, AppLogShapeContract.expensiveMessage(flag))
        #expect(!flag.evaluated, "被阈值滤掉的消息不许求值（@autoclosure 短路失效）")
        #expect(!FileManager.default.fileExists(atPath: url.path))

        AppLog.warn(.db, "⚠️ 打开失败\nerror=disk full")
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.split(separator: "\n", omittingEmptySubsequences: false).count == 2)
        #expect(written.contains("[WARN] [db] ⚠️ 打开失败⏎error=disk full"))
        #expect(written.hasPrefix("[") && written.hasSuffix("error=disk full\n"))
    }
}

/// 昂贵消息求值探测（端到端测 @autoclosure 短路用）。
private final class ExpensiveMessageFlag {
    var evaluated = false
}

private extension AppLogShapeContract {
    static func expensiveMessage(_ flag: ExpensiveMessageFlag) -> String {
        flag.evaluated = true
        return "expensive"
    }
}
