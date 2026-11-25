//
//  MacMainWindowLookupContractTests.swift
//  QQPlayerTests
//
//  窗口查找的源码契约（防回流，2026-11-25）。
//
//  被守住的缺陷：主窗查找原先用「窗口标题 == 产品名」当身份。2026-11-24 产品显示名改成
//  「婷听 / TingFi」后，运行实例的标题不再等于旧值 → 判据必然落空，且失败完全静默
//  （迷你窗点封面回主窗 = 什么都不发生）。标题随产品名变，不是身份；身份只来自
//  视图侧登记 + `NSUserInterfaceItemIdentifier`。
//
//  这些是**源码形状**守卫：窗口查找是否又长出标题判据、是否又有人绕过解析器自己枚举窗口。
//

import Foundation
import Testing

struct MacMainWindowLookupContractTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 参与窗口查找的文件（新增/调整判据必须同时改实现与这份清单）。
    private static let lookupFiles = [
        "QQPlayer/Mac/MacMainWindowResolver.swift",
        "QQPlayer/Mac/MacDesktopWindowsManager.swift",
        "QQPlayer/QQPlayerMacApp.swift",
        "QQPlayer/Mac/MacMainWindowFrameWatch.swift",
    ]

    /// 唯一允许枚举 `NSApp.windows` 的文件。
    private static let enumerationOwner = "QQPlayer/Mac/MacMainWindowResolver.swift"

    /// 检查实现（唯一入口，自证用例共用）：返回第一处「窗口标题比较」的代码行（nil = 干净）。
    static func firstWindowTitleComparison(in source: String) -> String? {
        for rawLine in source.components(separatedBy: "\n") {
            let code = rawLine.components(separatedBy: "//").first ?? rawLine
            if code.range(of: #"\.title\s*(==|!=)"#, options: .regularExpression) != nil {
                return rawLine.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    @Test("窗口查找不再以窗口标题为判据")
    func noTitleBasedWindowLookup() throws {
        for path in Self.lookupFiles {
            let source = try Self.source(at: path)
            let hit = Self.firstWindowTitleComparison(in: source)
            #expect(hit == nil, "\(path) 仍在用标题查找窗口：\(hit ?? "")")
        }
    }

    @Test("三处消费方都走同一个解析入口")
    func consumersUseResolverEntry() throws {
        let consumers = [
            "QQPlayer/Mac/MacDesktopWindowsManager.swift",
            "QQPlayer/QQPlayerMacApp.swift",
            "QQPlayer/Mac/MacMainWindowFrameWatch.swift",
        ]
        for path in consumers {
            let source = try Self.source(at: path)
            #expect(source.contains("MacMainWindowResolver."), "\(path) 没走主窗解析唯一入口")
        }
    }

    @Test("NSApp.windows 只在解析器里枚举（窗口枚举入口唯一）")
    func windowEnumerationHasSingleEntry() throws {
        var offenders: [String] = []
        for path in try Self.allSwiftSources() where path != Self.enumerationOwner {
            let code = Self.strippingLineComments(try Self.source(at: path))
            if code.contains("NSApp.windows") {
                offenders.append(path)
            }
        }
        #expect(offenders.isEmpty, "这些文件自己枚举窗口（应走 MacMainWindowResolver）：\(offenders)")
    }

    @Test("检测器自证：命中标题比较、放过注释与非比较用法")
    func detectorSelfTest() {
        #expect(Self.firstWindowTitleComparison(in: "guard window.title == \"QQPlayer\" else { return }") != nil)
        #expect(Self.firstWindowTitleComparison(in: "if window.title != other { return }") != nil)
        #expect(Self.firstWindowTitleComparison(in: "// 旧判据：window.title == \"QQPlayer\"，已删除") == nil)
        #expect(Self.firstWindowTitleComparison(in: "let name = track.title") == nil)
    }

    // MARK: - 源码读取

    private static func source(at relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func strippingLineComments(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }

    /// `QQPlayer/**` 下所有 Swift 源文件（相对仓库根的路径，已排序）。
    private static func allSwiftSources() throws -> [String] {
        let root = repositoryRoot.appendingPathComponent("QQPlayer")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let prefix = repositoryRoot.path + "/"
        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            paths.append(url.path.replacingOccurrences(of: prefix, with: ""))
        }
        return paths.sorted()
    }
}
