//
//  ObservationTrackingShapeContractTests.swift
//  QQPlayerTests
//
//  形状契约：**测试代码里 `withObservationTracking` 只允许出现在观测口径入口文件内**
//  （2026-09-25 立，与 `ObservationTrackingTestSupport.swift` 配套）。
//
//  为什么：2026-09-25 实测的假阴性 —— 把被测的读**整个放进** `withObservationTracking` 的
//  apply 闭包后，`onChange` 不在 apply 执行期间触发 ⇒ 把「读路径写 inFlight」的旧实现注回去，
//  断言**仍然全绿**。正确顺序（先建追踪、再执行被测操作）已收进唯一入口
//  `ObservationTrackingProbe.mutationCount(whenTracking:thenRunning:)`（顺序写进签名 +
//  头注释 ❌/✅ 对照）。
//  **但注释不是机制**：下一个人照样可以裸写一个 `withObservationTracking` 回到假阴性形态。
//  所以加这条形状守卫 —— 测试里裸用即红，白名单只有入口文件自己。
//
//  判据先**剥注释 + 剥字符串**（2026-09-19 教训：不剥注释 → 把守卫行注掉测试仍绿）；
//  剥离复用本仓库既有的内部实现 `AppNotificationContract.stripComments(source:)`
//  （不另造第 13 份剥注释器）。自带自证用例（合成文本注入裸用 → 必须红）；
//  交付时另做过「真文件注入裸用 → 红 → 精确还原 → 复跑绿」的反向验证。
//
//  为什么只扫 `QQPlayerTests`：生产代码里 SwiftUI body 的读**本来就在**
//  `withObservationTracking` 闭包内（那是正确用法，渲染期读取另由
//  `MacLibraryFactsReadPathContractTests.swift` 守护）；本契约针对的是测试里
//  「顺序反了」的假阴性陷阱。
//

import Foundation
import Testing

private enum ObservationTrackingShape {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 扫描范围：测试 target 全量（测试源文件都在 `QQPlayerTests/` 下，子目录一并覆盖）。
    static let scannedDirectory = "QQPlayerTests"

    /// 唯一允许裸用观测 API 的文件（观测口径入口）。
    static let allowedPath = "QQPlayerTests/ObservationTrackingTestSupport.swift"

    static let needle = "withObservationTracking"

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)
        case sourceUnreadable(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path):
                return "契约测试无法枚举测试目录（fail-closed）：\(path)"
            case .sourceUnreadable(let path):
                return "契约测试无法读取测试源码（fail-closed）：\(path)"
            }
        }
    }

    /// 裸用次数（**入口文件自己不计** —— 白名单 = 它自己）。
    static func bareUseCount(inSource source: String, relativePath: String) -> Int {
        guard relativePath != allowedPath else { return 0 }
        return count(inSource: source)
    }

    /// 入口文件的裸用次数（fail-closed 锚点：唯一入口真的在建追踪）。
    static func entryPointUseCount(inSource source: String) -> Int {
        count(inSource: source)
    }

    private static func count(inSource source: String) -> Int {
        occurrences(
            of: needle,
            in: AppNotificationContract.stripComments(source: source).code
        )
    }

    static func occurrences(of needle: String, in text: String) -> Int {
        var total = 0
        var searchStart = text.startIndex
        while let range = text.range(of: needle, range: searchStart ..< text.endIndex) {
            total += 1
            searchStart = range.upperBound
        }
        return total
    }

    static func testSwiftFiles() throws -> [URL] {
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
}

@Suite("withObservationTracking 裸用契约（测试代码只允许走唯一入口）")
struct ObservationTrackingShapeContractTests {
    @Test("(a) 测试代码里裸用 withObservationTracking 只允许出现在入口文件内（fail-closed）")
    func bareUsageOnlyInEntryPoint() throws {
        let prefix = ObservationTrackingShape.repositoryRoot.path + "/"
        var scanned = 0
        var entryPointUses: Int?
        var violations: [String] = []

        for url in try ObservationTrackingShape.testSwiftFiles() {
            let relative = url.path.replacingOccurrences(of: prefix, with: "")
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw ObservationTrackingShape.ContractError.sourceUnreadable(relative)
            }
            scanned += 1
            if relative == ObservationTrackingShape.allowedPath {
                entryPointUses = ObservationTrackingShape.entryPointUseCount(inSource: source)
                continue
            }
            let uses = ObservationTrackingShape.bareUseCount(inSource: source, relativePath: relative)
            if uses > 0 {
                violations.append("\(relative)：\(uses) 处裸用")
            }
        }

        // fail-closed：扫不到文件 / 入口文件不在扫描结果里 / 入口没在用这个 API = 判据入口失效
        #expect(scanned > 0, "扫描不到任何测试源文件 = 判定规则写坏（fail-closed）")
        #expect(
            entryPointUses != nil,
            "扫描结果里没有入口文件 \(ObservationTrackingShape.allowedPath)（改名/搬走 → 判据失效，fail-closed）"
        )
        #expect(
            (entryPointUses ?? 0) >= 1,
            "入口文件里没有 `\(ObservationTrackingShape.needle)` —— 唯一入口没在真的建追踪（fail-closed）"
        )
        #expect(
            violations.isEmpty,
            """
            测试代码里出现裸用 `withObservationTracking`（回到 2026-09-25 的假阴性形态）：
            \(violations.sorted().joined(separator: "\n"))

            修法：改用唯一入口 `ObservationTrackingProbe.mutationCount(whenTracking:thenRunning:)`
            —— 先建追踪（apply 里只做那次读），**再**执行被测操作。
            """
        )
    }

    @Test("(b) 自证：合成文本里裸用必红；注释/字符串里的字样不算；入口文件本身放行")
    func scannerSelfTest() {
        let bare = """
        func testReading() {
            withObservationTracking { _ = store.albumFacts(forAlbumId: 5) } onChange: { _ = 1 }
        }
        """
        #expect(
            ObservationTrackingShape.bareUseCount(inSource: bare, relativePath: "QQPlayerTests/SomeTests.swift") == 1,
            "裸用必须被抓到"
        )

        // 注释里的字样不算（2026-09-19 教训：不剥注释 → 注掉守卫行测试仍绿）
        let commented = """
        func testReading() {
            // withObservationTracking { _ = store.albumFacts(forAlbumId: 5) } onChange: { _ = 1 }
            /* withObservationTracking */
            /*
               withObservationTracking（嵌套块注释里的字样）
             */
            _ = 1
        }
        """
        #expect(
            ObservationTrackingShape.bareUseCount(inSource: commented, relativePath: "QQPlayerTests/SomeTests.swift") == 0,
            "注释里的字样不算代码"
        )

        // 字符串字面量里的字样不算（普通 / 原始 / 多行）
        let quoted = """
        let a = "withObservationTracking"
        let b = #"withObservationTracking"#
        let c = \"\"\"
        withObservationTracking { _ = store.albumFacts(forAlbumId: 5) }
        \"\"\"
        """
        #expect(
            ObservationTrackingShape.bareUseCount(inSource: quoted, relativePath: "QQPlayerTests/SomeTests.swift") == 0,
            "字符串里的字样不算代码"
        )

        // 入口文件本身放行（白名单 = 它自己）
        #expect(
            ObservationTrackingShape.bareUseCount(
                inSource: bare,
                relativePath: ObservationTrackingShape.allowedPath
            ) == 0,
            "入口文件是白名单，不得自判违规"
        )
    }
}
