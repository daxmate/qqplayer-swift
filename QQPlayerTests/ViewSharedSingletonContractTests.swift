//
//  ViewSharedSingletonContractTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  P1 棘轮：**视图层不得直连单例（`<Type>.shared`）**（2026-09-18 立）。
//
//  问题：视图文件里直接写 `PlayerEngine.shared` / `KaraokeController.shared` /
//  `ArtworkManager.shared` / `AppCoordinator.shared` …，当前 48 个视图文件 / 174 处。
//  后果：视图层自己决定「谁的生命周期归谁」——可测性、替换实现、iOS/Mac 行为一致性
//  都被视图文件锁死；同一语义在多处各自对齐（前例：封面解析散落 5 处）。
//
//  本轮**只立棘轮、不动生产代码**：把存量钉成「只能减不能增」的清单。
//  新写视图直连单例 → 本测试立刻红；清掉一处 → 必须同步改基线行
//  （留陈旧行也红，保证名单不腐烂）。
//
//  四条契约（全部 fail-closed：读不到源码/目录 = 红，绝不静默通过）：
//   (a) 新增违规：检测到的视图文件不在基线里 → 红
//   (b) 计数回涨：某文件出现次数 > 基线 → 红
//   (c) 名单不腐烂：基线里的文件计数下降（含归零）或文件已不存在 → 红（该改/删行了）
//   (d) 总数上限：全部视图文件出现次数之和 > 基线 TOTAL → 红
//
//  视图层判定（与 `ViewDataAccessContractTests` 同一口径）：
//    `QQPlayer/Views/**` 全部 + `QQPlayer/Mac/**` 中声明了 SwiftUI View
//    （`: View` / `some View`）的文件。`QQPlayer/Mac/` 下的服务不在范围内。
//  计数口径：只算**代码行**（`//` 之后剥离、整行注释不计——文档注释里的字面量会误伤自己），
//    粒度为 `<Type>.shared` 的出现次数，与 `grep -oE '[A-Za-z_]+\.shared'` 同口径。
//
//  基线文件：`QQPlayerTests/Fixtures/shared-singleton-baseline.tsv`（`路径<TAB>计数` + `# TOTAL:`）。
//

import Foundation
import Testing

private enum ViewSharedSingletonContract {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// `QQPlayer/Views/**` 全部算视图层。
    static let unfilteredViewDirectory = "QQPlayer/Views"
    /// `QQPlayer/Mac/` 下只有声明了 SwiftUI View 的文件算视图层。
    static let filteredViewDirectory = "QQPlayer/Mac"
    static let baselinePath = "QQPlayerTests/Fixtures/shared-singleton-baseline.tsv"

    struct Baseline {
        var total: Int
        var perFile: [String: Int]
    }

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)
        case baselineMalformed(String)
        case baselineTotalMissing

        var description: String {
            switch self {
            case .directoryUnreadable(let path):
                return "契约测试无法枚举/读取（fail-closed）：\(path)"
            case .baselineMalformed(let line):
                return "基线格式错误（fail-closed）：\(line)"
            case .baselineTotalMissing:
                return "基线缺少 `# TOTAL: <数字>` 行（fail-closed）"
            }
        }
    }

    /// 与用户侧口径一致：`grep -oE '[A-Za-z_]+\.shared'`。
    private static let sharedPattern = try! NSRegularExpression(pattern: "[A-Za-z_]+[.]shared")
    private static let totalPattern = try! NSRegularExpression(pattern: "^#\\s*TOTAL:\\s*([0-9]+)\\s*$")

    /// 是否声明了 SwiftUI View（决定 `QQPlayer/Mac/` 下的文件算不算视图层）。
    static func declaresSwiftUIView(_ source: String) -> Bool {
        if source.contains(": View") { return true }
        if source.contains("some View") { return true }
        return false
    }

    /// 单行代码里的出现次数（先剥掉 `//` 之后的注释部分）。
    static func occurrences(inCodeLine line: String) -> Int {
        let code = line.components(separatedBy: "//").first ?? ""
        let range = NSRange(code.startIndex ..< code.endIndex, in: code)
        return sharedPattern.numberOfMatches(in: code, range: range)
    }

    /// 一份源码里的出现次数（只算代码行）。
    static func occurrenceCount(in source: String) -> Int {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + occurrences(inCodeLine: String($1)) }
    }

    static func swiftFiles(under relativeDirectory: String) throws -> [URL] {
        let directory = repositoryRoot.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractError.directoryUnreadable(relativeDirectory)
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// 实际检测结果：相对路径 → 出现次数（只含 > 0 的文件）。
    static func detectedOccurrences() throws -> [String: Int] {
        var result: [String: Int] = [:]
        let prefix = repositoryRoot.path + "/"

        var scanned: [URL] = []
        for url in try swiftFiles(under: unfilteredViewDirectory) {
            scanned.append(url)
        }
        for url in try swiftFiles(under: filteredViewDirectory) {
            let source = try String(contentsOf: url, encoding: .utf8)
            guard declaresSwiftUIView(source) else { continue }
            scanned.append(url)
        }

        for url in scanned {
            let source = try String(contentsOf: url, encoding: .utf8)
            let count = occurrenceCount(in: source)
            guard count > 0 else { continue }
            let relative = url.path.replacingOccurrences(of: prefix, with: "")
            result[relative] = count
        }
        return result
    }

    /// 基线清单（`路径<TAB>计数`，`#` 开头是注释，`# TOTAL: N` 是总数上限）。
    static func baseline() throws -> Baseline {
        let url = repositoryRoot.appendingPathComponent(baselinePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ContractError.directoryUnreadable(baselinePath)
        }
        let text = try String(contentsOf: url, encoding: .utf8)

        var perFile: [String: Int] = [:]
        var total: Int?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                if let match = totalPattern.firstMatch(in: line, range: range),
                   let valueRange = Range(match.range(at: 1), in: line) {
                    total = Int(line[valueRange])
                }
                continue
            }
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2,
                  let count = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                throw ContractError.baselineMalformed(line)
            }
            perFile[String(parts[0]).trimmingCharacters(in: .whitespaces)] = count
        }
        guard let total else { throw ContractError.baselineTotalMissing }
        return Baseline(total: total, perFile: perFile)
    }
}

@Suite("视图层直连单例契约（P1 棘轮）")
struct ViewSharedSingletonContractTests {
    @Test("(d) 总数只能减不能增：视图层 `<Type>.shared` 总计数 ≤ 基线 TOTAL")
    func totalOccurrencesDoNotGrow() throws {
        let detected = try ViewSharedSingletonContract.detectedOccurrences()
        let baseline = try ViewSharedSingletonContract.baseline()
        let actual = detected.values.reduce(0, +)

        #expect(
            actual <= baseline.total,
            """
            视图层 `<Type>.shared` 总计数回涨：基线 TOTAL \(baseline.total) → 实测 \(actual)。
            请改走已有入口 / 依赖注入，不要新增 `X.shared` 直连；确需登记则同步更新基线并说明理由。
            """
        )
    }

    @Test("(a)(b) 不得新增直连文件，且既有文件计数只能减不能增")
    func noNewOrGrownDirectReferences() throws {
        let detected = try ViewSharedSingletonContract.detectedOccurrences()
        let baseline = try ViewSharedSingletonContract.baseline()

        let added = detected.keys.filter { baseline.perFile[$0] == nil }.sorted()
        #expect(
            added.isEmpty,
            "视图层新增了单例直连（基线里没有这些文件）：\(added)"
        )

        let grown = detected.compactMap { relativePath, count -> String? in
            guard let baseCount = baseline.perFile[relativePath], count > baseCount else { return nil }
            return "\(relativePath): \(baseCount) → \(count)"
        }.sorted()
        #expect(grown.isEmpty, "视图层单例直连计数回涨：\(grown)")
    }

    @Test("(c) 基线名单不腐烂：计数下降（含归零）或文件消失必须同步改行")
    func baselineHasNoStaleEntries() throws {
        let detected = try ViewSharedSingletonContract.detectedOccurrences()
        let baseline = try ViewSharedSingletonContract.baseline()

        var missing: [String] = []
        var decreased: [String] = []
        for (relativePath, baseCount) in baseline.perFile {
            let fileURL = ViewSharedSingletonContract.repositoryRoot.appendingPathComponent(relativePath)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                missing.append(relativePath)
                continue
            }
            let actual = detected[relativePath] ?? 0
            if actual < baseCount {
                decreased.append("\(relativePath): \(baseCount) → \(actual)")
            }
        }
        #expect(
            missing.isEmpty,
            "基线里的文件已不存在，请删行：\(missing.sorted())"
        )
        #expect(
            decreased.isEmpty,
            """
            基线里这些文件的直连已减少/归零，请同步改行（归零则删行）：
            \(decreased.sorted())
            """
        )
        let baselineTotal = baseline.perFile.values.reduce(0, +)
        #expect(
            baselineTotal == baseline.total,
            "基线自相矛盾：行数合计 \(baselineTotal) ≠ TOTAL \(baseline.total)"
        )
    }

    @Test("自证：检测规则本身能抓到合成输入（fail-closed 反向验证）")
    func detectionRuleSelfTest() {
        let viewSource = """
        import SwiftUI
        struct Foo: View {
            // 文档/行尾注释里的 KaraokeController.shared 不算
            var body: some View {
                let engine = PlayerEngine.shared
                _ = KaraokeController.shared.state // 行尾注释 ArtworkManager.shared 也不算
                _ = AppCoordinator.shared
            }
        }
        """
        #expect(ViewSharedSingletonContract.declaresSwiftUIView(viewSource))
        #expect(ViewSharedSingletonContract.occurrenceCount(in: viewSource) == 3)
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "// 整行注释 X.shared") == 0)
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "let x = URLSession.shared") == 1)
        #expect(ViewSharedSingletonContract.occurrences(inCodeLine: "let y = something.sharedThing") == 1)

        let serviceSource = """
        import Foundation
        enum BarService {
            static func load() { _ = PlayerEngine.shared.currentTrack }
        }
        """
        #expect(!ViewSharedSingletonContract.declaresSwiftUIView(serviceSource))
        #expect(ViewSharedSingletonContract.occurrenceCount(in: serviceSource) == 1)
    }
}
