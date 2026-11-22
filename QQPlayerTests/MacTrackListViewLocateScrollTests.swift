//
//  MacTrackListViewLocateScrollTests.swift
//  QQPlayerTests
//
//  「定位当前播放 → 把当前行滚到列表可视区垂直居中」（2026-09-28）的两条守护：
//
//  ① 纯几何单测：`MacTableScrollGeometry.centeredOriginY`（共享层 `QQPlayer/Services/`，
//     iOS 单测 target 编得到——与 MacLibrarySelection 同款：`QQPlayer/Mac/**` 在 iOS 例外表里）。
//  ② 形状契约：全仓「把 Table 某行滚到垂直居中」**只允许一处实现**（`MacTableScroll.centerRow`），
//     白名单 = 入口文件 + 调用点；禁止别处直连 AppKit 滚动 API。
//
//  为什么会漂移：滚动这件事在 SwiftUI `Table` 上没有公开接口（见入口文件头注释），
//  后来人遇到「滚不动」最省力的做法就是在自己的视图里再写一遍 `enclosingScrollView` +
//  `scroll(to:)`——那就是第二份实现，行为会与唯一入口分叉。故用静态扫描把它变成 CI 红灯。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - ① 纯几何

@Suite("MacTableScrollGeometry 居中口径")
struct MacTableScrollGeometryTests {
    @Test("顶行：被夹取到 0")
    func topRowClampsToZero() {
        // desired = 0 + 12 − 200 = −188 → 0
        let origin = MacTableScrollGeometry.centeredOriginY(
            rowMinY: 0, rowHeight: 24, viewportHeight: 400, contentHeight: 4000
        )
        #expect(origin == 0)
    }

    @Test("中间行：落在垂直居中位置")
    func middleRowCenters() {
        // desired = 1000 + 12 − 200 = 812；maxOrigin = 3600 → 812
        let origin = MacTableScrollGeometry.centeredOriginY(
            rowMinY: 1000, rowHeight: 24, viewportHeight: 400, contentHeight: 4000
        )
        #expect(origin == 812)
    }

    @Test("底部行：被夹取到 contentHeight − viewportHeight")
    func bottomRowClampsToMax() {
        // desired = 3976 + 12 − 200 = 3788 → 夹到 4000 − 400 = 3600
        let origin = MacTableScrollGeometry.centeredOriginY(
            rowMinY: 3976, rowHeight: 24, viewportHeight: 400, contentHeight: 4000
        )
        #expect(origin == 3600)
    }

    @Test("内容短于视口：恒为 0（无滚动空间）")
    func contentShorterThanViewportStaysZero() {
        let top = MacTableScrollGeometry.centeredOriginY(
            rowMinY: 0, rowHeight: 24, viewportHeight: 400, contentHeight: 300
        )
        let middle = MacTableScrollGeometry.centeredOriginY(
            rowMinY: 100, rowHeight: 24, viewportHeight: 400, contentHeight: 300
        )
        #expect(top == 0)
        #expect(middle == 0)
    }

    @Test("空内容：0")
    func emptyContentStaysZero() {
        let origin = MacTableScrollGeometry.centeredOriginY(
            rowMinY: 0, rowHeight: 0, viewportHeight: 400, contentHeight: 0
        )
        #expect(origin == 0)
    }

    @Test("退化输入（行高 0）不产出负值")
    func zeroRowHeightNeverNegative() {
        let origin = MacTableScrollGeometry.centeredOriginY(
            rowMinY: 10, rowHeight: 0, viewportHeight: 100, contentHeight: 1000
        )
        #expect(origin == 0)
    }
}

// MARK: - ② 形状契约：滚动唯一入口

private enum LocateScrollShapeContract {
    /// 禁止的 AppKit 滚动特征：任何第二份「滚 Table 行」实现都要碰其中之一。
    static let forbiddenMarkers: [String] = [
        "enclosingScrollView",
        "scrollRowToVisible",
        "reflectScrolledClipView",
        "contentView.scroll(",
        ".scroll(to:",
    ]

    /// 滚动唯一入口的标识 token（只允许出现在白名单文件里）。
    static let entryTokens: [String] = ["MacTableScroll", "MacTableLocateScroller"]

    /// 允许持有滚动实现 / 引用入口的文件（相对仓库根）。
    static let whitelist: [String] = [
        "QQPlayer/Mac/MacTrackListView+LocateScroll.swift", // 唯一入口：MacTableScroll.centerRow + representable
        "QQPlayer/Mac/MacTrackListView.swift", // 调用点：.background(MacTableLocateScroller(…))
    ]

    /// 仓库根：本文件位于 <repo>/QQPlayerTests/ 下 → 上两级。
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let directory): return "契约测试无法枚举目录（fail-closed）：\(directory)"
            }
        }
    }

    /// 生产源码根下全部 `.swift`（相对仓库根路径 + URL）；读不出来 → throw（fail-closed）。
    static func swiftFiles() throws -> [(relativePath: String, url: URL)] {
        let base: URL = repositoryRoot.appendingPathComponent("QQPlayer", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ContractError.directoryUnreadable("QQPlayer")
        }
        let prefix: String = repositoryRoot.path + "/"
        var files: [(relativePath: String, url: URL)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((url.path.replacingOccurrences(of: prefix, with: ""), url))
        }
        return files.sorted { lhs, rhs in lhs.relativePath < rhs.relativePath }
    }

    /// 按相对路径取源码文本（不存在 → throw，红）。
    static func source(relativePath: String) throws -> String {
        let url: URL = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // SCAN-BEGIN
    /// token 是否作为**独立标识符**出现（后一字符不得是字母 / 数字 / 下划线）。
    /// 必要性：共享层几何类型 `MacTableScrollGeometry` 含前缀 `MacTableScroll`，不设边界即误伤。
    static func mentions(_ token: String, in code: String) -> Bool {
        var searchStart: String.Index = code.startIndex
        while let range = code.range(of: token, range: searchStart ..< code.endIndex) {
            let upper: String.Index = range.upperBound
            if upper == code.endIndex { return true }
            let next: Character = code[upper]
            if !(next.isLetter || next.isNumber || next == "_") { return true }
            searchStart = upper
        }
        return false
    }

    /// 违规原因清单（空 = 合规）。`code` 必须是**已剥离注释与字符串**的源码。
    static func violations(code: String) -> [String] {
        var found: [String] = []
        for marker in forbiddenMarkers where code.contains(marker) {
            found.append("AppKit 滚动特征 `\(marker)`")
        }
        for token in entryTokens where mentions(token, in: code) {
            found.append("滚动入口 token `\(token)`")
        }
        return found
    }

    /// 把源码里的字符串字面量与注释整体替换成空格（换行保留 → 行号不变）。
    /// 必要性：入口文件的注释里就写着 `enclosingScrollView` / `scrollRowToVisible` 等字样
    /// （解释为什么桥接），不剥离就会把「解释」当成「实现」。
    static func strippingLiteralsAndComments(_ source: String) -> String {
        let characters: [Character] = Array(source)
        let total: Int = characters.count
        var result: [Character] = []
        var index: Int = 0
        while index < total {
            let character: Character = characters[index]
            if character == "\"" {
                let next: Int = stringLiteralEnd(characters, from: index)
                blank(characters, from: index, to: next, into: &result)
                index = next
                continue
            }
            if character == "/", index + 1 < total {
                let follower: Character = characters[index + 1]
                if follower == "/" {
                    var next: Int = index
                    while next < total, characters[next] != "\n" { next += 1 }
                    blank(characters, from: index, to: next, into: &result)
                    index = next
                    continue
                }
                if follower == "*" {
                    var next: Int = index + 2
                    while next + 1 < total {
                        if characters[next] == "*", characters[next + 1] == "/" {
                            next += 2
                            break
                        }
                        next += 1
                    }
                    let stop: Int = min(next, total)
                    blank(characters, from: index, to: stop, into: &result)
                    index = stop
                    continue
                }
            }
            result.append(character)
            index += 1
        }
        return String(result)
    }

    /// 从 `start`（指向 `"`）解析字符串字面量（兼容 `"""…"""`）→ 下一个字符下标。
    private static func stringLiteralEnd(_ characters: [Character], from start: Int) -> Int {
        let total: Int = characters.count
        let quote: Character = "\""
        var isBlock: Bool = false
        if start + 2 < total, characters[start + 1] == quote, characters[start + 2] == quote {
            isBlock = true
        }
        var index: Int = start + (isBlock ? 3 : 1)
        while index < total {
            let character: Character = characters[index]
            if isBlock {
                if character == quote, index + 2 < total,
                   characters[index + 1] == quote, characters[index + 2] == quote {
                    return index + 3
                }
            } else if character == quote {
                return index + 1
            } else if character == "\\", index + 1 < total {
                index += 2
                continue
            }
            index += 1
        }
        return total
    }

    /// 把 `[from, to)` 写进 `result`（非换行字符换成空格；换行原样保留 → 行号不变）。
    private static func blank(_ characters: [Character], from: Int, to: Int, into result: inout [Character]) {
        for inner in from ..< min(to, characters.count) {
            result.append(characters[inner] == "\n" ? "\n" : " ")
        }
    }
    // SCAN-END
}

@Suite("定位滚动形状契约")
struct LocateScrollShapeContractTests {
    @Test("白名单不许腐烂：每个条目仍存在")
    func whitelistEntriesStillExist() {
        for path in LocateScrollShapeContract.whitelist {
            let url: URL = LocateScrollShapeContract.repositoryRoot.appendingPathComponent(path)
            #expect(FileManager.default.fileExists(atPath: url.path), "白名单腐烂：\(path) 不存在")
        }
    }

    @Test("全仓：滚 Table 行的实现只允许唯一入口（白名单外零命中）")
    func onlyEntryPointImplementsScrolling() throws {
        let files: [(relativePath: String, url: URL)] = try LocateScrollShapeContract.swiftFiles()
        #expect(files.count > 100, "扫到的生产源文件过少，路径推导可能失效：\(files.count)")

        var offenders: [String] = []
        for file in files where !LocateScrollShapeContract.whitelist.contains(file.relativePath) {
            let text: String = try String(contentsOf: file.url, encoding: .utf8)
            let code: String = LocateScrollShapeContract.strippingLiteralsAndComments(text)
            let hits: [String] = LocateScrollShapeContract.violations(code: code)
            if !hits.isEmpty {
                offenders.append("\(file.relativePath) → \(hits.joined(separator: "、"))")
            }
        }

        let message: String = """
        ❌ 出现绕过唯一入口的第二份「滚动 Table 行」实现：
          \(offenders)
          请改走 MacTableScroll.centerRow（QQPlayer/Mac/MacTrackListView+LocateScroll.swift），
          不要在各视图里各写一份 enclosingScrollView / scroll(to:)。
        """
        #expect(offenders.isEmpty, "\(message)")
    }

    @Test("非空转：唯一入口仍实现 AppKit 滚动路径，调用点仍挂 representable")
    func entryPointStillPresent() throws {
        let entryCode: String = LocateScrollShapeContract.strippingLiteralsAndComments(
            try LocateScrollShapeContract.source(relativePath: "QQPlayer/Mac/MacTrackListView+LocateScroll.swift")
        )
        #expect(entryCode.contains("enclosingScrollView"), "唯一入口不见了 AppKit 滚动路径（扫描器可能只是空转）")
        #expect(entryCode.contains("reflectScrolledClipView"), "唯一入口不见了滚动后的回显调用")

        let callerCode: String = LocateScrollShapeContract.strippingLiteralsAndComments(
            try LocateScrollShapeContract.source(relativePath: "QQPlayer/Mac/MacTrackListView.swift")
        )
        #expect(callerCode.contains("MacTableLocateScroller"), "调用点不再挂滚动信号桥")
    }

    @Test("自证：注释 / 字符串里的特征不算违规（剥离管线）")
    func commentsAndStringsAreStripped() {
        let synthetic: String = """
        // enclosingScrollView 出现在注释里
        let note = "scrollRowToVisible 出现在字符串里"
        let real = tableView.enclosingScrollView
        """
        let code: String = LocateScrollShapeContract.strippingLiteralsAndComments(synthetic)
        #expect(!code.contains("// enclosingScrollView 出现在注释里"), "注释没被剥离：\(code)")
        #expect(!code.contains("scrollRowToVisible"), "字符串没被剥离：\(code)")
        #expect(code.contains("tableView.enclosingScrollView"), "真代码必须原样保留：\(code)")

        let hits: [String] = LocateScrollShapeContract.violations(code: code)
        #expect(hits.count == 1, "应只报真代码那 1 处，实际：\(hits)")
    }

    @Test("自证：`MacTableScrollGeometry` 不撞 `MacTableScroll` 的 token 边界")
    func geometryTypeIsNotFlaggedAsSecondImplementation() {
        let geometryUsage: String = """
        let y = MacTableScrollGeometry.centeredOriginY(rowMinY: 0, rowHeight: 1, viewportHeight: 2, contentHeight: 3)
        """
        #expect(
            LocateScrollShapeContract.violations(code: geometryUsage).isEmpty,
            "共享层几何类型不得被判成第二份滚动实现"
        )

        let entryUsage: String = "MacTableScroll.centerRow(0, from: view)"
        let entryHits: [String] = LocateScrollShapeContract.violations(code: entryUsage)
        #expect(entryHits == ["滚动入口 token `MacTableScroll`"], "入口 token 必须被抓到，实际：\(entryHits)")
    }
}
