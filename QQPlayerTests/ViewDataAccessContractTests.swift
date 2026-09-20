//
//  ViewDataAccessContractTests.swift
//  QQPlayerTests
//
//  P0 收口契约：**视图层不得直连 DatabaseManager**（2026-09-17 立）。
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
//  「视图文件」的判定（**2026-09-20 口径补齐**；唯一实现 `isViewLayerFile(relativePath:source:)`）：
//    ① 全 `QQPlayer/**` 中**声明了 SwiftUI View**（`: View` / `some View`）的文件
//       —— 与 `EnvironmentInjectionContractTests` / `ViewSharedSingletonContractTests` 同款口径；
//    ② 并集保留 `QQPlayer/Views/**` 全部文件（含 `UIViewRepresentable` /
//       `UIViewControllerRepresentable` / `UIImage` 扩展这类不声明 `: View` 的视图层 helper）
//       —— **口径只紧不松**：新口径是旧口径的超集，改口径不得丢掉既有覆盖。
//    非视图文件（`Services/**` 里不声明 View 的服务、`QQPlayer/Mac/**` 下的服务
//    MacImportService / MacSync* / MacLyricsResendAutoRunner 等）不在范围内。
//
//  **口径事故（本次修；与直连单例棘轮批 6-0 同因）**：原口径是「`QQPlayer/Views/**` 全部
//  + `QQPlayer/Mac/**` 中声明 View 的文件」⇒ **仓库根目录视图与 `QQPlayer/AppIntents/**`
//  里的视图完全不在扫描范围**：`QQPlayer/ContentView.swift` 里
//  `DatabaseManager.shared.getAllTracks()` 一处都看不见（实测补齐后新增可见 1 文件 / 1 处）。
//  同类口径问题在 `EnvironmentInjectionContractTests` 已修过一次（根目录视图漏检）——
//  三处口径现已对齐，且各自带「口径自证」用例：合成根目录视图必须被抓到、
//  服务层文件不得误伤、磁盘真实文件归属断言、**口径内文件数下限 fail-closed**。
//
//  **基线为何上调（历史债显形，非新增直连）**：口径补齐后多出 `QQPlayer/ContentView.swift`
//  1 处（实测 2026-09-20）。它是**既有**代码、不是本次新增，按「棘轮只防变差」的口径
//  登记为存量；整改去向同下方「整改去向」（查询 → `LibraryReads`）。
//
//  计数口径：**按字面量数**（`DatabaseManager` 出现次数，不解析语法）。
//    ⚠️ 与直连单例棘轮不同：那边会先剥 `//` 注释再数；本文件保持原口径不变
//    （当前量级 0/1，剥不剥不影响判据），如需收紧应作为独立一批并同步重测基线。
//
//  基线文件：`QQPlayerTests/Fixtures/view-data-access-baseline.tsv`（`路径<TAB>计数`）。
//

import Foundation
import Testing

private enum ViewDataAccessContract {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 扫描根目录：全 `QQPlayer/**`（2026-09-20 口径补齐——根目录 / `AppIntents/**` 视图此前不可见）。
    static let scannedDirectory = "QQPlayer"
    /// 视图层 helper 目录：`QQPlayer/Views/**` 全部文件仍计入（含不声明 `: View` 的视图层 helper）。
    static let legacyViewDirectory = "QQPlayer/Views"
    static let baselinePath: String = "QQPlayerTests/Fixtures/view-data-access-baseline.tsv"
    static let entryPointPaths: [String] = [
        "QQPlayer/Services/LibraryReads.swift",
        "QQPlayer/Services/TrackDeletionService.swift",
    ]

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)
        case baselineMalformed(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path):
                return "契约测试无法枚举/读取（fail-closed）：\(path)"
            case .baselineMalformed(let line):
                return "基线格式错误（fail-closed）：\(line)"
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

    /// 口径判定（**唯一实现**：契约与自证共用）：
    /// `QQPlayer/Views/**` 全部 + 其余位置里声明了 SwiftUI View 的文件。
    static func isViewLayerFile(relativePath: String, source: String) -> Bool {
        if relativePath.hasPrefix(legacyViewDirectory + "/") { return true }
        return declaresSwiftUIView(source)
    }

    /// 仓库内全部 `QQPlayer/**` Swift 文件（相对路径 + 源码）。
    /// 逐文件读取，读不出来即抛错（fail-closed，绝不静默当成「没违规」）。
    static func repositoryFiles() throws -> [(relativePath: String, source: String)] {
        let directory = repositoryRoot.appendingPathComponent(scannedDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractError.directoryUnreadable(scannedDirectory)
        }
        let prefix = repositoryRoot.path + "/"
        var files: [(relativePath: String, source: String)] = []
        var unreadable: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: prefix, with: "")
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                files.append((relative, source))
            } else {
                unreadable.append(relative)
            }
        }
        guard unreadable.isEmpty else {
            throw ContractError.directoryUnreadable("以下文件读不到：\(unreadable.sorted())")
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    /// 检测结果：相对路径 → 引用数（只含 > 0 的**视图层**文件）。
    /// 纯函数（输入 = 文件清单）——口径自证用例靠它合成根目录视图文件，不必真写盘。
    static func detectedOccurrences(
        in files: [(relativePath: String, source: String)]
    ) -> [String: Int] {
        var result: [String: Int] = [:]
        for file in files {
            guard isViewLayerFile(relativePath: file.relativePath, source: file.source) else { continue }
            let count = referenceCount(in: file.source)
            guard count > 0 else { continue }
            result[file.relativePath] = count
        }
        return result
    }

    /// 实际检测结果（仓库真实文件）：相对路径 → 引用数（只含 > 0 的视图层文件）。
    static func detectedOffenders() throws -> [String: Int] {
        detectedOccurrences(in: try repositoryFiles())
    }

    /// 基线清单（`路径<TAB>计数`）；文件不存在/格式错 → 抛错（红）。
    static func baseline() throws -> [String: Int] {
        let url = repositoryRoot.appendingPathComponent(baselinePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ContractError.directoryUnreadable(baselinePath)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var result: [String: Int] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let count = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                throw ContractError.baselineMalformed(line)
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

        var missing: [String] = []
        var decreased: [String] = []
        for (relativePath, baseCount) in baseline {
            let fileURL = ViewDataAccessContract.repositoryRoot.appendingPathComponent(relativePath)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                missing.append(relativePath)
                continue
            }
            let actual = detected[relativePath] ?? 0
            if actual < baseCount {
                decreased.append("\(relativePath): \(baseCount) → \(actual)")
            }
        }
        #expect(missing.isEmpty, "基线里的文件已不存在，请删行：\(missing.sorted())")
        #expect(
            decreased.isEmpty,
            "基线里这些文件的直连已减少/归零，请同步改行（归零则删行）：\(decreased.sorted())"
        )
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

    @Test("口径自证：声明 View 的文件一律在口径内（含仓库根 / 意图层；fail-closed 反向验证）")
    func scopeSelfTest() throws {
        // 非视图文件，但确实含一处直连（否则会被「计数为 0 不进名单」当成过）
        let viewSource = """
        import SwiftUI
        struct RootScreen: View {
            var body: some View {
                _ = try? DatabaseManager.shared.getAllTracks()
            }
        }
        """
        let serviceSource = """
        import Foundation
        enum FooService {
            static func load() throws { _ = try DatabaseManager.shared.getAllTracks() }
        }
        """

        let detected = ViewDataAccessContract.detectedOccurrences(in: [
            ("QQPlayer/ContentView.swift", viewSource),
            ("QQPlayer/AppIntents/Snippets/SongCardSnippetIntent.swift", viewSource),
            ("QQPlayer/Services/DatabaseManager.swift", serviceSource),
            ("QQPlayer/Mac/MacImportService.swift", serviceSource),
            ("QQPlayer/Views/Player/PlayerGestureLogic.swift", serviceSource),
        ])

        // 口径补齐前，这两类位置的视图文件一处都看不见（本次事故形态：根目录视图 + 意图层视图）
        #expect(detected["QQPlayer/ContentView.swift"] == 1)
        #expect(detected["QQPlayer/AppIntents/Snippets/SongCardSnippetIntent.swift"] == 1)
        // 不声明 View 的服务不在口径内（不误伤服务层）
        #expect(detected["QQPlayer/Services/DatabaseManager.swift"] == nil)
        #expect(detected["QQPlayer/Mac/MacImportService.swift"] == nil)
        // `QQPlayer/Views/**` 通配保留：不声明 `: View` 的视图层 helper 仍在口径内（口径只紧不松）
        #expect(detected["QQPlayer/Views/Player/PlayerGestureLogic.swift"] == 1)
        // 口径判定本身（与计数无关，直接断言集合归属）
        #expect(ViewDataAccessContract.isViewLayerFile(
            relativePath: "QQPlayer/Views/Player/PlayerGestureLogic.swift", source: serviceSource
        ))
        #expect(!ViewDataAccessContract.isViewLayerFile(
            relativePath: "QQPlayer/Services/DatabaseManager.swift", source: serviceSource
        ))

        // 反向验证（磁盘真实文件）：口径判定对真实仓库成立——
        // 根目录 / 意图层 / Mac 视图在口径内，服务层文件不在。
        let inScope = try ViewDataAccessContract.repositoryFiles()
            .filter { ViewDataAccessContract.isViewLayerFile(relativePath: $0.relativePath, source: $0.source) }
            .map(\.relativePath)
        for path in [
            "QQPlayer/ContentView.swift",
            "QQPlayer/AppIntents/Snippets/SongCardSnippetIntent.swift",
            "QQPlayer/Views/Player/PlayerGestureLogic.swift",
            "QQPlayer/Mac/MacLibraryView.swift",
        ] {
            #expect(inScope.contains(path), "口径漏了：\(path)")
        }
        for path in ["QQPlayer/Services/DatabaseManager.swift", "QQPlayer/Mac/MacImportService.swift"] {
            #expect(!inScope.contains(path), "口径过宽：\(path)")
        }
        // fail-closed：口径内文件数不应明显偏小（枚举/判定失灵时本断言先红，绝不静默通过）
        #expect(inScope.filter { $0.hasPrefix("QQPlayer/Views/") }.count > 40)
        #expect(inScope.count > 60)
    }
}
