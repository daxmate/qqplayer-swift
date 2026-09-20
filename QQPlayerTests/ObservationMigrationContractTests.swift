//
//  ObservationMigrationContractTests.swift
//  QQPlayerTests
//
//  @Observable 迁移棘轮（2026-09-18 立，批 1「叶子」之前先立的规矩）。
//
//  背景：方案（memory/2026-09-18.md §二）定了「@Observable 分批迁移、叶子先动、热点最后」。
//  迁移是**只许减不许增**的方向性整改 —— 若没有机械守卫，下一批人（或下一个我）
//  随手在新视图里写 `@StateObject` 就会把进度吃掉，且 CI 不会响。
//  所以先把存量变成**棘轮基线**：新写旧写法立刻红；整改干净一个文件就必须删掉基线行
//  （留陈旧行也红，保证名单不腐烂）。
//
//  计数的五类标记（= 迁移家族的完整名单）：
//    `ObservableObject`、`@StateObject`、`@ObservedObject`、`@EnvironmentObject`、`@Published`
//  （`@EnvironmentObject` 一并计入：方案 §二的机械替换规则里同样要把它换成 `@Environment(T.self)`。）
//
//  三条契约 + 一条自证（全部 fail-closed）：
//   (a) 新增违规：检测到的 (文件, 标记) 不在基线里 → 红
//   (b) 计数回涨：某 (文件, 标记) 实际数 > 基线 → 红
//   (c) 名单不腐烂：基线行的实际数 < 基线（含清零/文件已删）→ 红，必须删行或改小
//   (d) 自证：扫描器必须把「注释 / 字符串字面量」排除在外（注释不算代码），
//       且词边界正确（`ObservableObjectX` 不算）；扫描不到任何标记 → 判定规则写坏 → 红
//
//  扫描范围：`QQPlayer/**/*.swift`（iOS + Mac 共享同一批源文件）。
//  基线文件：`QQPlayerTests/Fixtures/observation-migration-baseline.tsv`（`路径<TAB>标记<TAB>计数`）。
//

import Foundation
import Testing

private enum ObservationRatchet {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let scannedDirectory = "QQPlayer"
    static let baselinePath = "QQPlayerTests/Fixtures/observation-migration-baseline.tsv"

    static let kinds: [String] = [
        "ObservableObject",
        "@StateObject",
        "@ObservedObject",
        "@EnvironmentObject",
        "@Published",
    ]

    /// 基线/检测结果的键：文件（仓库相对路径） + 标记种类。
    struct Entry: Hashable {
        let path: String
        let kind: String
    }

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)
        case sourceUnreadable(String)
        case baselineUnreadable(String)
        case baselineMalformed(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path): return "契约测试无法枚举目录（fail-closed）：\(path)"
            case .sourceUnreadable(let path): return "契约测试无法读取源码（fail-closed）：\(path)"
            case .baselineUnreadable(let path): return "契约测试无法读取基线（fail-closed）：\(path)"
            case .baselineMalformed(let line): return "基线格式错误（应为 路径<TAB>标记<TAB>计数）：\(line)"
            }
        }
    }

    // MARK: - 扫描器

    /// 去掉注释与字符串字面量（**注释/字符串不算代码**）。
    /// 处理：`//`、可嵌套 `/* */`、`"…"`（含 `\` 转义）、`"""…"""`、`#"…"#`、`#"""…"""#`。
    static func stripped(_ source: String) -> String {
        let chars = Array(source)
        let count = chars.count
        var output = String()
        output.reserveCapacity(count)
        var index = 0

        while index < count {
            let character = chars[index]

            // 行注释
            if character == "/", index + 1 < count, chars[index + 1] == "/" {
                while index < count, chars[index] != "\n" { index += 1 }
                continue
            }

            // 块注释（Swift 允许嵌套）
            if character == "/", index + 1 < count, chars[index + 1] == "*" {
                var depth = 1
                index += 2
                while index < count, depth > 0 {
                    if chars[index] == "/", index + 1 < count, chars[index + 1] == "*" {
                        depth += 1
                        index += 2
                    } else if chars[index] == "*", index + 1 < count, chars[index + 1] == "/" {
                        depth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                }
                output.append(" ")
                continue
            }

            // 字符串（含 raw `#` 前缀与多行 `"""`）
            var hashes = 0
            var probe = index
            while probe < count, chars[probe] == "#" {
                hashes += 1
                probe += 1
            }
            let quoteCount = stringQuoteCount(chars, at: probe)
            if quoteCount > 0, hashes > 0 || character == "\"" {
                let terminator = Array(
                    String(repeating: "#", count: hashes) + String(repeating: "\"", count: quoteCount)
                )
                var cursor = probe + quoteCount
                while cursor < count {
                    if matches(chars, at: cursor, terminator) {
                        cursor += terminator.count
                        break
                    }
                    // 非 raw 单行字符串里 `\` 转义（`\"` 不结束字符串）
                    if hashes == 0, quoteCount == 1, chars[cursor] == "\\" {
                        cursor += 2
                        continue
                    }
                    cursor += 1
                }
                output.append(" ")
                index = cursor
                continue
            }

            output.append(character)
            index += 1
        }
        return output
    }

    /// 该位置是否是字符串起始的引号（单行 1 个 / 多行 3 个）；0 = 不是。
    private static func stringQuoteCount(_ chars: [Character], at index: Int) -> Int {
        guard index < chars.count, chars[index] == "\"" else { return 0 }
        if index + 2 < chars.count, chars[index + 1] == "\"", chars[index + 2] == "\"" { return 3 }
        return 1
    }

    private static func matches(_ chars: [Character], at index: Int, _ terminator: [Character]) -> Bool {
        guard index + terminator.count <= chars.count else { return false }
        for offset in 0 ..< terminator.count where chars[index + offset] != terminator[offset] {
            return false
        }
        return true
    }

    // MARK: - 计数

    /// 某个标记的出现次数（词边界匹配：`ObservableObjectX` / `NotAnObservableObject` 不算）。
    static func occurrences(of needle: String, in text: String) -> Int {
        var total = 0
        var searchStart = text.startIndex
        while let range = text.range(of: needle, range: searchStart ..< text.endIndex) {
            let before = range.lowerBound > text.startIndex
                ? text[text.index(before: range.lowerBound)]
                : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if !isIdentifierCharacter(before), !isIdentifierCharacter(after) { total += 1 }
            searchStart = range.upperBound
        }
        return total
    }

    private static func isIdentifierCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    static func counts(in source: String) -> [String: Int] {
        let code = stripped(source)
        var result: [String: Int] = [:]
        for kind in kinds {
            let total = occurrences(of: kind, in: code)
            if total > 0 { result[kind] = total }
        }
        return result
    }

    // MARK: - 检测与基线

    static func swiftFiles() throws -> [URL] {
        let directory = repositoryRoot.appendingPathComponent(scannedDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractError.directoryUnreadable(scannedDirectory)
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// 实际检测结果：文件相对路径 + 标记 → 计数。
    static func detected() throws -> [Entry: Int] {
        var result: [Entry: Int] = [:]
        let prefix = repositoryRoot.path + "/"
        for url in try swiftFiles() {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw ContractError.sourceUnreadable(url.path)
            }
            let relative = url.path.replacingOccurrences(of: prefix, with: "")
            for (kind, count) in counts(in: source) {
                result[Entry(path: relative, kind: kind)] = count
            }
        }
        return result
    }

    /// 基线清单；文件不存在 → 空表（等价于「全部算新增」，仍然红，fail-closed）。
    static func baseline() throws -> [Entry: Int] {
        let url = repositoryRoot.appendingPathComponent(baselinePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContractError.baselineUnreadable(baselinePath)
        }
        var result: [Entry: Int] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, let count = Int(parts[2]) else {
                throw ContractError.baselineMalformed(line)
            }
            result[Entry(path: parts[0], kind: parts[1])] = count
        }
        return result
    }

    static func sortedEntries(_ entries: [Entry]) -> [Entry] {
        entries.sorted { ($0.path, $0.kind) < ($1.path, $1.kind) }
    }

    /// 直接可粘贴的基线正文（`路径<TAB>标记<TAB>计数`，按路径/标记排序）。
    static func tsvBody(_ rows: [Entry: Int]) -> String {
        sortedEntries(Array(rows.keys))
            .map { "\($0.path)\t\($0.kind)\t\(rows[$0] ?? 0)" }
            .joined(separator: "\n")
    }
}

@Suite("@Observable 迁移棘轮（批 1：叶子）")
struct ObservationMigrationContractTests {
    @Test("(a)(b) 不得新增迁移家族标记，且既有计数只能减不能增")
    func noNewOrGrownMarkers() throws {
        let detected = try ObservationRatchet.detected()
        let baseline = try ObservationRatchet.baseline()

        #expect(
            !detected.isEmpty,
            "扫描不到任何迁移标记 —— 判定规则写坏了（fail-closed），不是「已迁移干净」"
        )

        let added = ObservationRatchet.sortedEntries(detected.keys.filter { baseline[$0] == nil })
            .map { "\($0.path)\t\($0.kind)" }

        let grown = detected.compactMap { entry, count -> String? in
            guard let baseCount = baseline[entry], count > baseCount else { return nil }
            return "\(entry.path)\t\(entry.kind): \(baseCount) → \(count)"
        }.sorted()

        #expect(
            added.isEmpty && grown.isEmpty,
            """
            迁移标记新增/回涨（@Observable 迁移只许减不许增）：
              新增行（\(added.count)）：\(added)
              回涨行（\(grown.count)）：\(grown)
            —— 期望基线正文（可直接覆盖 \(ObservationRatchet.baselinePath)）——
            \(ObservationRatchet.tsvBody(detected))
            """
        )
    }

    @Test("(c) 基线名单不腐烂：已清零/已消失的行必须删掉")
    func baselineHasNoStaleEntries() throws {
        let detected = try ObservationRatchet.detected()
        let baseline = try ObservationRatchet.baseline()

        let stale = baseline.compactMap { entry, count -> String? in
            let now = detected[entry] ?? 0
            guard now < count else { return nil }
            return "\(entry.path)\t\(entry.kind): \(count) → \(now)"
        }.sorted()

        #expect(stale.isEmpty, "基线里这些行已整改到更少/清零，请同步删行或改小：\(stale)")
    }

    @Test("(d) 扫描器自证：注释/字符串不算代码，词边界正确（fail-closed 反向验证）")
    func scannerSelfTest() {
        let realCode = """
        import SwiftUI
        @MainActor final class Foo: ObservableObject {
            @Published var step = 0
            @StateObject private var child = Bar()
        }
        """
        #expect(
            ObservationRatchet.counts(in: realCode)
                == ["ObservableObject": 1, "@Published": 1, "@StateObject": 1]
        )

        let commentedOut = """
        // @Published var old = 0
        /// 注释里提到 ObservableObject、@StateObject、@EnvironmentObject、@ObservedObject
        /*
           @Published 块注释
           /* 嵌套块注释里的 @StateObject */
         */
        let untouched = 1
        """
        #expect(ObservationRatchet.counts(in: commentedOut).isEmpty)

        let quoted = """
        let a = "@Published"
        let b = "ObservableObject"
        let c = #"@EnvironmentObject"#
        let d = \"\"\"
        @StateObject
        \"\"\"
        """
        #expect(ObservationRatchet.counts(in: quoted).isEmpty)

        let boundary = "NotAnObservableObjectHolder ObservableObjectX ObservableObject"
        #expect(ObservationRatchet.occurrences(of: "ObservableObject", in: boundary) == 1)
    }
}

// MARK: - 非视图消费者的观察入口（批 6-3）

/// 「观察入口唯一」形状契约（批 6-3 立）。
///
/// 判据：迁移目标对象的**跨文件观察**只允许走对象自己声明的 façade publisher —— 生产码里
/// 不得出现 `<Target>.shared.$…`（`@Published` 的合成投影）或 `<Target>.shared.objectWillChange`。
/// 为什么：前者迁 `@Observable` 后**编译期**消失、后者 `@Observable` 根本没有；不立规矩的话，
/// 消费者只能各自造第二套订阅 ⇒ 迁移时必漏一处（2026-09-15 形状纪律：同一语义只有一个入口，
/// 靠 CI 不靠人记得）。对象**自己的文件**（同名前缀，如 `PlayerEngine*.swift`）不受限：
/// 那是实现内芯，迁移那天由编译器盯着。
private enum NonViewObservationRatchet {
    /// 迁移目标（与 `QQPlayerTests/Fixtures/shared-singleton-budget-plan.md` 批 6+ 热点一致）。
    static let migrationTargets = [
        "PlayerEngine", "KaraokeController", "ArtworkManager", "AppCoordinator",
        "SyncHostCenter", "SyncWiringFactsStore", "LibraryIndexer",
    ]

    /// 已知跨文件消费者（白名单空转检查：这些入口必须真的被用上）。
    static let knownConsumers: [(path: String, entry: String)] = [
        ("QQPlayer/CarPlay+PlayerPage.swift", "PlayerEngine.shared.currentTrackPublisher"),
        ("QQPlayer/Services/DatabaseSuspensionCoordinator.swift", "PlayerEngine.shared.isPlayingPublisher"),
    ]

    /// 一份源码里的违禁观察形态（空 = 该文件合规）。
    static func violations(inSource source: String, relativePath: String) -> [String] {
        let fileName = (relativePath as NSString).lastPathComponent
        // 对象自己的文件 = 实现内芯（含同名前缀的 extension 文件），本契约不管
        if migrationTargets.contains(where: { fileName.hasPrefix($0) }) { return [] }

        let code = ObservationRatchet.stripped(source)
        var result: [String] = []
        for target in migrationTargets {
            let base = "\(target).shared."
            var searchStart = code.startIndex
            while let range = code.range(of: base, range: searchStart ..< code.endIndex) {
                let tail = code[range.upperBound...]
                if tail.hasPrefix("$") {
                    result.append(
                        "\(relativePath)：`\(target).shared.$…` → 改用 façade publisher（如 `\(target).shared.<prop>Publisher`）"
                    )
                } else if tail.hasPrefix("objectWillChange") {
                    result.append("\(relativePath)：`\(target).shared.objectWillChange` → 改用 façade publisher")
                }
                searchStart = range.upperBound
            }
        }
        return result
    }
}

@Suite("非视图消费者的观察入口契约（批 6-3）")
struct NonViewObservationContractTests {
    @Test("(a) 迁移目标的跨文件观察一律走 façade（生产码全量扫描，fail-closed）")
    func noCrossFilePublishedProjection() throws {
        var scanned = 0
        var violations: [String] = []
        let prefix = ObservationRatchet.repositoryRoot.path + "/"
        for url in try ObservationRatchet.swiftFiles() {
            let relative = url.path.replacingOccurrences(of: prefix, with: "")
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                violations.append("\(relative)：读取失败（fail-closed，不跳过）")
                continue
            }
            scanned += 1
            violations += NonViewObservationRatchet.violations(inSource: source, relativePath: relative)
        }

        #expect(scanned > 0, "扫描不到任何生产源文件 = 判定规则写坏（fail-closed）")
        #expect(
            violations.isEmpty,
            """
            生产码里出现对迁移目标的跨文件 `@Published` 投影 / `objectWillChange` 订阅：
            \(violations.sorted().joined(separator: "\n"))

            修法：在对象自己的文件里声明 façade publisher（如 `PlayerEngine.currentTrackPublisher`），
            非视图消费者只订阅它 —— 迁 `@Observable` 之日只换内芯，消费者一行不动。
            """
        )
    }

    @Test("(b) 已知消费者真的在走 façade（白名单空转 → 必须失败）")
    func knownConsumersUseFacade() throws {
        let prefix = ObservationRatchet.repositoryRoot.path + "/"
        var sources: [String: String] = [:]
        for url in try ObservationRatchet.swiftFiles() {
            sources[url.path.replacingOccurrences(of: prefix, with: "")] =
                try String(contentsOf: url, encoding: .utf8)
        }
        for consumer in NonViewObservationRatchet.knownConsumers {
            let source = sources[consumer.path]
            #expect(source != nil, "已知消费者文件不存在：\(consumer.path)（契约白名单空转）")
            #expect(
                source?.contains(consumer.entry) == true,
                "\(consumer.path) 必须通过 façade `\(consumer.entry)` 观察（空转 = 契约失效）"
            )
        }
    }

    @Test("(c) 扫描器自证：合成违例必被抓、对象自己文件放行、注释不算（fail-closed 反向验证）")
    func scannerSelfTest() {
        let projectionBypass = "PlayerEngine.shared.$isPlaying.removeDuplicates().sink { _ in }"
        #expect(
            NonViewObservationRatchet.violations(
                inSource: projectionBypass,
                relativePath: "QQPlayer/CarPlay+X.swift"
            ).count == 1,
            "跳文件写 `X.shared.$…` 必须被抓到"
        )
        let willChangeBypass = "PlayerEngine.shared.objectWillChange.sink { _ in }"
        #expect(
            NonViewObservationRatchet.violations(
                inSource: willChangeBypass,
                relativePath: "QQPlayer/Mac/SomeVM.swift"
            ).count == 1,
            "跳文件订阅 `X.shared.objectWillChange` 必须被抓到"
        )
        #expect(
            NonViewObservationRatchet.violations(
                inSource: projectionBypass,
                relativePath: "QQPlayer/Services/PlayerEngine.swift"
            ).isEmpty,
            "对象自己的文件（实现内芯）必须放行，否则契约不可用"
        )
        #expect(
            NonViewObservationRatchet.violations(
                inSource: projectionBypass,
                relativePath: "QQPlayer/Services/PlayerEngine+NowPlaying.swift"
            ).isEmpty,
            "同名前缀的 extension 文件（实现内芯）必须放行"
        )
        #expect(
            NonViewObservationRatchet.violations(
                inSource: "// PlayerEngine.shared.$isPlaying",
                relativePath: "QQPlayer/CarPlay+X.swift"
            ).isEmpty,
            "注释里提到不算代码"
        )
        #expect(
            NonViewObservationRatchet.violations(
                inSource: "let playing = PlayerEngine.shared.isPlaying",
                relativePath: "QQPlayer/CarPlay+X.swift"
            ).isEmpty,
            "普通状态读取（无 `$` / `objectWillChange`）不算违例"
        )
        #expect(
            NonViewObservationRatchet.violations(
                inSource: "DatabaseManager.shared.$x",
                relativePath: "QQPlayer/CarPlay+X.swift"
            ).isEmpty,
            "非迁移目标对象不误伤"
        )
    }
}
