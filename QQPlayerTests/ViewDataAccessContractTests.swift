//
//  ViewDataAccessContractTests.swift
//  QQPlayerTests
//
//  P0 收口契约：**视图层不得直连 DatabaseManager**（2026-09-17）。
//
//  问题（审计 2026-08-29 / 2026-09-12 两轮都写了、两轮都没落地）：
//  视图文件里直接 `DatabaseManager.shared.xxx`，共 33 个视图文件 / 108 处引用。
//  后果：UI 层知道表结构 → 业务规则散在视图里（同一段「删除曲目」仪式抄了 7 份）、
//  换存储要动视图、UI 无法单测。
//
//  为什么这次能落地：把「整改」变成 CI 里的**棘轮**——存量清单只能减不能增。
//  新写视图想直连数据库 → 本测试立刻红；整改完一个文件 → 必须把基线行删掉
//  （留陈旧行也红，保证名单不腐烂）。
//
//  四条契约（全部 fail-closed：读不到源码/目录 = 红，绝不静默通过）：
//   (a) 新增违规：检测到的视图文件不在基线里 → 红
//   (b) 计数回涨：某文件引用数 > 基线 → 红
//   (c) 名单不腐烂：基线里的文件已降为 0 或已不存在 → 红（该删行了）
//   (d) 入口存在：`LibraryReads` / `TrackDeletionService` 两个唯一入口必须在位
//
//  「视图文件」的判定：`QQPlayer/Views/**` 全部 + `QQPlayer/Mac/**` 中声明了
//  SwiftUI View（`: View` / `some View`）的文件。`QQPlayer/Mac/` 下的服务
//  （MacImportService / MacSync* / MacLyricsResendAutoRunner 等）不在范围内。
//
//  基线文件：`QQPlayerTests/Fixtures/view-data-access-baseline.tsv`（`路径<TAB>计数`）。
//

import Foundation
import Testing

private enum ViewDataAccessContract {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let scannedDirectories: [String] = ["QQPlayer/Views", "QQPlayer/Mac"]
    static let baselinePath: String = "QQPlayerTests/Fixtures/view-data-access-baseline.tsv"
    static let entryPointPaths: [String] = [
        "QQPlayer/Services/LibraryReads.swift",
        "QQPlayer/Services/TrackDeletionService.swift",
    ]

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path): return "契约测试无法枚举目录（fail-closed）：\(path)"
            }
        }
    }

    /// 出现次数（按字面量数，不解析语法——只做「有没有第二处在直连」的形状判断）。
    static func referenceCount(in source: String) -> Int {
        source.components(separatedBy: "DatabaseManager").count - 1
    }

    /// 是否声明了 SwiftUI View（决定该文件算不算「视图层」）。
    static func declaresSwiftUIView(_ source: String) -> Bool {
        if source.contains(": View") { return true }
        if source.contains("some View") { return true }
        return false
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

    /// 实际检测结果：相对路径 → 引用数。
    static func detectedOffenders() throws -> [String: Int] {
        var result: [String: Int] = [:]
        let prefix = repositoryRoot.path + "/"
        for directory in scannedDirectories {
            for url in try swiftFiles(under: directory) {
                let source = try String(contentsOf: url, encoding: .utf8)
                guard declaresSwiftUIView(source) else { continue }
                let count = referenceCount(in: source)
                guard count > 0 else { continue }
                let relative = url.path.replacingOccurrences(of: prefix, with: "")
                result[relative] = count
            }
        }
        return result
    }

    /// 基线清单（`路径<TAB>计数`）；文件不存在 → 抛错（红）。
    static func baseline() throws -> [String: Int] {
        let url = repositoryRoot.appendingPathComponent(baselinePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        var result: [String: Int] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let count = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                throw ContractError.directoryUnreadable("基线格式错误：\(line)")
            }
            result[String(parts[0]).trimmingCharacters(in: .whitespaces)] = count
        }
        return result
    }
}

@Suite("视图层数据访问契约（P0 收口棘轮）")
struct ViewDataAccessContractTests {
    @Test("(a)(b) 视图层不得新增 DatabaseManager 直连，且既有引用数只能减不能增")
    func noNewDirectDatabaseAccess() throws {
        let detected = try ViewDataAccessContract.detectedOffenders()
        let baseline = try ViewDataAccessContract.baseline()

        let added = detected.keys.filter { baseline[$0] == nil }.sorted()
        #expect(
            added.isEmpty,
            "视图层新增了 DatabaseManager 直连（应改走 LibraryReads / TrackDeletionService）：\(added)"
        )

        let grown = detected.compactMap { relativePath, count -> String? in
            guard let baseCount = baseline[relativePath], count > baseCount else { return nil }
            return "\(relativePath): \(baseCount) → \(count)"
        }.sorted()
        #expect(grown.isEmpty, "视图层 DatabaseManager 引用数回涨：\(grown)")
    }

    @Test("(c) 基线名单不腐烂：已清零/已消失的文件必须从基线删除")
    func baselineHasNoStaleEntries() throws {
        let detected = try ViewDataAccessContract.detectedOffenders()
        let baseline = try ViewDataAccessContract.baseline()

        let stale = baseline.keys
            .filter { (detected[$0] ?? 0) < baseline[$0]! }
            .sorted()
        #expect(stale.isEmpty, "基线里这些文件已整改/已删除，请同步删行：\(stale)")
    }

    @Test("(d) 唯一入口在位：LibraryReads / TrackDeletionService")
    func entryPointsExist() throws {
        for relative in ViewDataAccessContract.entryPointPaths {
            let url = ViewDataAccessContract.repositoryRoot.appendingPathComponent(relative)
            #expect(FileManager.default.fileExists(atPath: url.path), "缺少唯一入口：\(relative)")
        }
    }

    @Test("自证：检测规则本身能抓到合成输入（fail-closed 反向验证）")
    func detectionRuleSelfTest() {
        let viewSource = """
        import SwiftUI
        struct Foo: View {
            var body: some View {
                _ = try? DatabaseManager.shared.getTrack(byStableId: "x")
            }
        }
        """
        #expect(ViewDataAccessContract.declaresSwiftUIView(viewSource))
        #expect(ViewDataAccessContract.referenceCount(in: viewSource) == 1)

        let serviceSource = """
        import Foundation
        enum BarService {
            static func load() throws { _ = try DatabaseManager.shared.getAllTracks() }
        }
        """
        #expect(!ViewDataAccessContract.declaresSwiftUIView(serviceSource))
    }
}
