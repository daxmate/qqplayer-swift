//
//  StartupOrderContractTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  契约守护（B1）：`docs/library-storage-contract.md` §6 第 3 条「v2 迁移的启动顺序不变量」
//  此前**只活在注释里**（`QQPlayer/Services/LibraryLayoutMigrationV2Migrator.swift:36-63` 的
//  「启动时机不变量」段），改启动顺序不会被任何用例抓住。本文件把两条顺序不变量变成**形状契约**：
//
//  ① `AppDelegate.application(_:didFinishLaunchingWithOptions:)` 里，**忽略注释与预处理指示行**后的
//     第一条**可执行语句** = `_ = LibraryLayoutMigrationV2Migrator.shared.runStartupPrepass()`
//     （依据：`QQPlayer/QQPlayerApp.swift:27-40`，那儿写着「**必须是本函数首句**」），
//     且该调用必须落在 `#if os(iOS)` 块内（平台收口，不许裸调）。
//  ② `AppCoordinator.initialize()` 里 v1（`runLibraryLayoutMigration`）必须先于 v2 收尾
//     （`runHiddenLayoutMigration`）（依据：`QQPlayer/Services/AppCoordinator.swift:64-83`）。
//
//  写法照 `QQPlayerTests/AppLogShapeContractTests.swift` / `QQPlayerTests/TrackDeletionReclaimAreaTests.swift`：
//  **读源码文本 → 剥注释 → 断言结构**，失败信息里给「期望 / 实际」原文片段。
//  判据必须是**结构**（函数体切片 → 取第一条可执行语句 / `#if os(iOS)` 块切片），不能是
//  「字符串在不在文件里」：「文件里出现过 `runStartupPrepass()`」这种判据在「调用点被挪到
//  函数末尾」时照样绿，等于没守。
//
//  ⚠️ 每条判据都自带**反向自证**：合成本文里的坏序源码喂给同一套解析/断言逻辑 ⇒ 必须被抓住；
//  合成合法源码 ⇒ 绿。只测「当前源码通过」的守卫会退化成永远绿（AGENTS.md 2026-09-19 §3）。
//

import Foundation
import Testing

private enum StartupOrderContract {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 被守护的两个生产文件（相对仓库根）。
    static let appDelegatePath = "QQPlayer/QQPlayerApp.swift"
    static let appCoordinatorPath = "QQPlayer/Services/AppCoordinator.swift"

    /// 不变量①期望的**逐字原文**（含 `_ =` 前缀与调用形态）。
    static let startupPrepassCall = "_ = LibraryLayoutMigrationV2Migrator.shared.runStartupPrepass()"
    /// 函数签名片段（用于定位函数体）。
    static let didFinishLaunchingFragment = "didFinishLaunchingWithOptions"
    /// 不变量②：`initialize()` 里的两个调用名（v1 先、v2 后）。
    static let v1Call = "runLibraryLayoutMigration"
    static let v2Call = "runHiddenLayoutMigration"
    static let initializeFragment = "initialize()"

    enum ContractError: Error, CustomStringConvertible {
        case unreadable(String)
        case functionNotFound(String)
        case unbalancedBraces(String)
        case missingGuardBlock(String)

        var description: String {
            switch self {
            case .unreadable(let path):
                "契约测试无法读取（fail-closed）：\(path)"
            case .functionNotFound(let fragment):
                "找不到函数体（fail-closed）：`\(fragment)`"
            case .unbalancedBraces(let context):
                "花括号不配对（fail-closed）：\(context)"
            case .missingGuardBlock(let context):
                "找不到 `#if os(iOS)` 块（fail-closed）：\(context)"
            }
        }
    }

    // MARK: - 读取与剥注释

    static func source(at relativePath: String, repositoryRoot root: URL) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContractError.unreadable(relativePath)
        }
        return text
    }

    /// 逐行剥掉 `//` 之后的内容（与 `StructuralBudgetRule.printCalls` / `AppLogShapeContract.codeOnly`
    /// 同款行内口径）：注释/文档里「提到」某个符号不算调用点。
    static func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    // MARK: - 结构切片

    /// 取「签名含 `fragment` 的函数」的**函数体内文本**（不含签名与最外层花括号）。
    /// 花括号配对按字符扫描，字符串字面量内的 `{}` 不计。
    static func functionBody(matching fragment: String, in source: String) throws -> String {
        let code = codeOnly(source)
        var searchStart = code.startIndex
        while let funcRange = code.range(of: "func ", range: searchStart ..< code.endIndex) {
            guard let braceIndex = code[funcRange.upperBound...].firstIndex(of: "{") else { break }
            let signature = String(code[funcRange.lowerBound ..< braceIndex])
            if signature.contains(fragment) {
                return try blockBody(startingAt: braceIndex, in: code, context: fragment)
            }
            searchStart = code.index(after: funcRange.upperBound)
        }
        throw ContractError.functionNotFound(fragment)
    }

    /// 从 `start`（指向最外层 `{`）起配对到对应 `}`，返回**内部**文本。
    /// 字符串字面量（含转义）内的花括号不参与配对。
    static func blockBody(startingAt start: String.Index, in code: String, context: String) throws -> String {
        let innerStart = code.index(after: start)
        var depth = 1
        var index = innerStart
        var inString = false
        var isEscaped = false
        while index < code.endIndex {
            let character = code[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(code[innerStart ..< index])
                }
            }
            index = code.index(after: index)
        }
        throw ContractError.unbalancedBraces(context)
    }

    /// 函数体里第一条**可执行**行（剥注释后、去掉空行与预处理指示行）。已剥过注释。
    /// `#if os(iOS)` 是**预处理指示行**、不是语句 ⇒ 一律跳过（判据与解析实现必须同一口径）。
    static func firstCodeLine(in code: String) -> String? {
        for rawLine in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return line
        }
        return nil
    }

    /// 取 `#if os(iOS)` 块的**块内文本**（到配对的 `#endif` 或 `#else` 为止；内层指令行跳过）。
    /// 入参必须是已剥注释的代码。
    static func iOSGuardBlock(in code: String) -> String? {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "#if os(iOS)" })
        else { return nil }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "#endif" || trimmed == "#else" { return body.joined(separator: "\n") }
            if trimmed.hasPrefix("#") { continue }
            body.append(line)
        }
        return nil
    }

    // MARK: - 判据（返回违规清单；空 = 绿）

    /// 不变量①：忽略注释与预处理指示行后，`didFinishLaunchingWithOptions` 的**第一条可执行语句**
    /// 必须是启动预处理调用；且该调用必须落在 `#if os(iOS)` 块内（平台收口，不许裸调）。
    ///
    /// 口径说明：`#if os(iOS)` 是**预处理指示行**，不是语句 —— 判据只比「可执行语句」，
    /// 但结构上用 `iOSGuardBlock` 再确认它确实被平台墙包着。（早先一版把「首句」定义成
    /// 指示行本身，断言与解析实现自相矛盾，是测试自身写错，已改正。）
    static func startupPrepassProblems(source: String) -> [String] {
        var problems: [String] = []
        guard let body = try? functionBody(matching: didFinishLaunchingFragment, in: source) else {
            return ["[\(didFinishLaunchingFragment)] \(ContractError.functionNotFound(didFinishLaunchingFragment))"]
        }
        // 主判据：函数体第一条**可执行**语句 = 启动预处理调用。
        let firstStatement = firstCodeLine(in: body)
        if firstStatement != startupPrepassCall {
            problems.append(
                "函数体第一条可执行语句不是启动预处理 —— 期望：`\(startupPrepassCall)`；实际：`\(firstStatement ?? "<无>")`"
            )
        }
        // 结构判据：该调用必须落在 `#if os(iOS)` 块内（平台收口，不许裸调）。
        guard let block = iOSGuardBlock(in: body) else {
            problems.append("函数体里没有可解析的 `#if os(iOS)` 块（启动预处理必须在平台块内）")
            return problems
        }
        let blockFirstStatement = firstCodeLine(in: block)
        if blockFirstStatement != startupPrepassCall {
            problems.append(
                "`#if os(iOS)` 块内首条可执行语句不是启动预处理 —— 期望：`\(startupPrepassCall)`；"
                    + "实际：`\(blockFirstStatement ?? "<无>")`"
            )
        }
        return problems
    }

    /// 不变量②：`AppCoordinator.initialize()` 里 v1 调用必须先于 v2 收尾调用。
    static func layoutMigrationOrderProblems(source: String) -> [String] {
        guard let body = try? functionBody(matching: initializeFragment, in: source) else {
            return ["[initialize] \(ContractError.functionNotFound(initializeFragment))"]
        }
        let code = codeOnly(body)
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        guard let v1Line = lines.firstIndex(where: { $0.contains(v1Call) }) else {
            return ["`initialize()` 里找不到 v1 调用 `\(v1Call)`（fail-closed：顺序判据会退化成永远绿）"]
        }
        guard let v2Line = lines.firstIndex(where: { $0.contains(v2Call) }) else {
            return ["`initialize()` 里找不到 v2 收尾调用 `\(v2Call)`（fail-closed）"]
        }
        guard v1Line < v2Line else {
            return [
                "v2 收尾必须晚于 v1 —— 期望：`\(v1Call)` 早于 `\(v2Call)`；"
                    + "实际：v1 在函数体内第 \(v1Line + 1) 行、v2 在第 \(v2Line + 1) 行"
                    + "（片段 v1=`\(lines[v1Line].trimmingCharacters(in: .whitespaces))`、"
                    + "v2=`\(lines[v2Line].trimmingCharacters(in: .whitespaces))`）",
            ]
        }
        return []
    }

    // MARK: - 合成源码（自证用）

    /// 合成 `didFinishLaunchingWithOptions`：`prepassPlacement` 决定那道 `#if os(iOS)` 块放哪。
    static func syntheticAppDelegate(prepassPlacement: PrepassPlacement) -> String {
        let guardBlock = """
            #if os(iOS)
                _ = LibraryLayoutMigrationV2Migrator.shared.runStartupPrepass()
            #endif
        """
        let header = """
        class AppDelegate: NSObject, UIApplicationDelegate {
            func application(
                _ application: UIApplication,
                didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
            ) -> Bool {
        """
        let footer = """
                return true
            }
        }
        """
        switch prepassPlacement {
        case .first:
            return header + "\n" + guardBlock + "\n    recordResolvedDisplayLanguage()\n" + footer
        case .last:
            return header + "\n    recordResolvedDisplayLanguage()\n    // 说明：启动预处理\n" + guardBlock + "\n" + footer
        case .firstBlockButSecondStatement:
            return header + "\n" + """
            #if os(iOS)
                recordResolvedDisplayLanguage()
                _ = LibraryLayoutMigrationV2Migrator.shared.runStartupPrepass()
            #endif
            """ + "\n" + footer
        case .commentOnly:
            return header + "\n    // _ = LibraryLayoutMigrationV2Migrator.shared.runStartupPrepass()\n" + footer
        }
    }

    enum PrepassPlacement {
        /// 合法：首句就是 `#if os(iOS)` 块、块内首条语句 = 预处理调用。
        case first
        /// 坏序：块被挪到函数末尾（`#if os(iOS)` 不再是首句）。
        case last
        /// 坏序：块在首句，但块内被别的语句抢了第一条。
        case firstBlockButSecondStatement
        /// 坏序：调用只出现在注释里（剥注释口径必须抓住）。
        case commentOnly
    }

    /// 合成 `AppCoordinator.initialize()`：`swapped` = 故意把 v2 收尾放到 v1 之前。
    static func syntheticAppCoordinator(swapped: Bool) -> String {
        let v1 = "            let layoutSummary = await Self.runLibraryLayoutMigration()"
        let v2 = "            let hiddenSummary = await Self.runHiddenLayoutMigration()"
        let ordered = swapped ? [v2, v1] : [v1, v2]
        return """
        class AppCoordinator {
            func initialize() async {
                #if os(iOS)
        \(ordered.joined(separator: "\n"))
                #endif
            }

            private static func runLibraryLayoutMigration() async -> Int { 0 }
            private static func runHiddenLayoutMigration() async -> Int { 0 }
        }
        """
    }
}

@Suite("启动顺序不变量（v2 迁移 · 形状契约）")
struct StartupOrderContractTests {
    @Test("不变量①：`didFinishLaunchingWithOptions` 的 `#if os(iOS)` 块首句 = `runStartupPrepass()`")
    func startupPrepassIsFirstStatementOfDidFinishLaunching() throws {
        let source = try StartupOrderContract.source(
            at: StartupOrderContract.appDelegatePath,
            repositoryRoot: StartupOrderContract.repositoryRoot
        )
        let problems = StartupOrderContract.startupPrepassProblems(source: source)
        #expect(
            problems.isEmpty,
            """
            \(StartupOrderContract.appDelegatePath)：启动预处理不再是 `didFinishLaunchingWithOptions` 的
            `#if os(iOS)` 块首句（「早于组件建目录」的不变量被破坏，见迁移器文件头「启动时机不变量」）：
            \(problems.joined(separator: "\n"))
            """
        )
    }

    @Test("不变量②：`AppCoordinator.initialize()` 里 v2 收尾（`runHiddenLayoutMigration`）在 v1 之后")
    func hiddenLayoutMigrationRunsAfterV1() throws {
        let source = try StartupOrderContract.source(
            at: StartupOrderContract.appCoordinatorPath,
            repositoryRoot: StartupOrderContract.repositoryRoot
        )
        let problems = StartupOrderContract.layoutMigrationOrderProblems(source: source)
        #expect(
            problems.isEmpty,
            """
            \(StartupOrderContract.appCoordinatorPath)：v1/v2 迁移顺序被改（v1 会无条件建出
            `Documents/{Music,Lyrics,Artwork,Logs}`，v2 收尾必须等它建完）：
            \(problems.joined(separator: "\n"))
            """
        )
    }

    @Test("自证①：首句不变量必须能抓住坏序（块挪到末尾 / 块内非首条 / 只在注释里）")
    func startupPrepassGuardHasTeeth() {
        // 合法：绿
        #expect(
            StartupOrderContract.startupPrepassProblems(
                source: StartupOrderContract.syntheticAppDelegate(prepassPlacement: .first)
            ).isEmpty
        )

        // 块被挪到函数末尾 → 必须红
        let movedToEnd = StartupOrderContract.startupPrepassProblems(
            source: StartupOrderContract.syntheticAppDelegate(prepassPlacement: .last)
        )
        #expect(!movedToEnd.isEmpty, "块被挪到末尾却没红")
        #expect(
            movedToEnd.contains { $0.contains("第一条可执行语句不是启动预处理") },
            "\(movedToEnd)"
        )
        #expect(
            movedToEnd.contains { $0.contains("recordResolvedDisplayLanguage") },
            "失败信息里没给出实际首句片段：\(movedToEnd)"
        )

        // 块在首句、但块内首条语句不是它 → 必须红
        let secondStatement = StartupOrderContract.startupPrepassProblems(
            source: StartupOrderContract.syntheticAppDelegate(prepassPlacement: .firstBlockButSecondStatement)
        )
        #expect(!secondStatement.isEmpty, "块内首条语句被抢却没红")
        #expect(
            secondStatement.contains { $0.contains(StartupOrderContract.startupPrepassCall) },
            "\(secondStatement)"
        )

        // 调用只出现在注释里 → 必须红（剥注释口径不许把注释当调用）
        let commentOnly = StartupOrderContract.startupPrepassProblems(
            source: StartupOrderContract.syntheticAppDelegate(prepassPlacement: .commentOnly)
        )
        #expect(!commentOnly.isEmpty, "注释里的调用被当成了真调用")

        // 函数不存在 → fail-closed（不静默通过）
        #expect(!StartupOrderContract.startupPrepassProblems(source: "class Nothing {}\n").isEmpty)
    }

    @Test("自证②：v1/v2 顺序判据必须能抓住颠倒；且「函数不存在」不许静默通过")
    func layoutMigrationOrderGuardHasTeeth() {
        #expect(
            StartupOrderContract.layoutMigrationOrderProblems(
                source: StartupOrderContract.syntheticAppCoordinator(swapped: false)
            ).isEmpty
        )

        let swapped = StartupOrderContract.layoutMigrationOrderProblems(
            source: StartupOrderContract.syntheticAppCoordinator(swapped: true)
        )
        #expect(!swapped.isEmpty, "v2 抢在 v1 之前却没红")
        #expect(swapped.contains { $0.contains(StartupOrderContract.v2Call) }, "\(swapped)")

        #expect(!StartupOrderContract.layoutMigrationOrderProblems(source: "class Nothing {}\n").isEmpty)
    }

    @Test("自证③：切片器本身——花括号配对、字符串内的花括号、块内首条语句")
    func slicingHasTeeth() throws {
        // 字符串里的 `{}` 不参与配对
        let source = """
        class A {
            func initialize() {
                let s = "}{"
                let t = "\\""
            }
        }
        """
        let body = try StartupOrderContract.functionBody(matching: "func initialize()", in: source)
        #expect(body.contains(#"let s = "}{""#), "花括号配对被字符串字面量带偏：\(body)")
        #expect(!body.contains("class A"), "函数体切片越界：\(body)")

        // `#if os(iOS)` 块内的首条语句（跳过内层指令行）
        let block = StartupOrderContract.iOSGuardBlock(in: """
        #if os(iOS)
            let first = 1
            let second = 2
        #endif
        let after = 3
        """)
        #expect(StartupOrderContract.firstCodeLine(in: block ?? "") == "let first = 1")
        #expect(StartupOrderContract.iOSGuardBlock(in: "let x = 1\n") == nil, "没有块时必须返回 nil")
    }
}
