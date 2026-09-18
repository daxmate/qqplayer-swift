//
//  MacSettingsSearchContractTests.swift
//  QQPlayerTests
//
//  形状契约（2026-09-18 ⌘K 设置项搜索批次）：**设置目录只有一份，锚点只能来自目录**。
//
//  为什么需要它：⌘K 原来搜不到设置项，根因不是「少写过滤」，而是**设置项目录根本不存在**
//  ——浮层里写死 5 个分类字符串，设置页里的项没有任何 id/别名数据源。这类问题行为测试
//  覆盖不到（是「同一语义有两处/零处表达」），只能静态钉形状（AGENTS.md 2026-09-15：
//  共享语义防第二实现必须靠形状测试，不能靠人记得）。
//
//  四条断言（全部 fail-closed：读不到文件 / 解析不出条目 = 红，绝不静默通过）：
//   (a) 目录每条 titleKey（含分类）在**全部** lproj 的 Localizable.strings 里真实存在
//       ——防止目录引用一个不存在的 key（搜索行标题显示成裸 key）。
//   (b) 目录每条锚点在设置页源码里真实出现（标记式扫描 `.settingsAnchor(MacSettingsCatalog.<常量>)`）
//       ——防止「目录加了条目、设置页没标锚点」→ 滚动/高亮落空。
//   (c) 设置页里不得出现目录之外的锚点写法（`.settingsAnchor("字面量")` / `.id("字面量")` /
//       `.scrollTo("字面量")`）——锚点 id 的唯一来源是目录常量，手写等于第二份事实源。
//   (d) ⌘K 浮层不得再有写死的分类名单（必须走 `MacSettingsCatalog.matches(for:)`），
//       且全仓不许再出现字符串型私有 selector（`Selector((`）——本次修的第二个 bug
//       （`showSettingsWindow:` 实测无效导致「点设置打不开」）。
//
//  **注释不算代码**（踩过坑：文档注释里出现反例写法会误伤）：扫描前剥注释，但**保留字符串
//  字面量**（(c) 要看清 `.id("…")` 这种写法）；字符串里的 `//`（如 URL）不会被误当注释。
//
//  范式照抄 `TrackDeletionShapeContractTests.swift` + `UIAccentContractTests.swift`：
//  扫描规则收敛在纯函数里（不碰文件系统）→ 合成源码自证「能抓到违规」（防契约空转）。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 扫描纯逻辑（不碰文件系统）

enum MacSettingsSearchContract {
    /// 目录源文件（注册表唯一实现）
    static let catalogPath = "QQPlayer/Mac/MacSettingsCatalog.swift"

    /// 设置页源码 = 契约扫描范围（锚点标记只能出现在这些文件里）
    static let settingsPageFiles: [String] = [
        "QQPlayer/Mac/MacSettingsView.swift",
        "QQPlayer/Mac/MacScrapeSettingsView.swift",
        "QQPlayer/Mac/MacDesktopWindowsSettingsView.swift",
        "QQPlayer/Mac/MacOnlineSettingsView.swift",
        "QQPlayer/Mac/MacEQSettingsView.swift",
        "QQPlayer/Mac/MacShortcutsSettingsView.swift",
        "QQPlayer/Mac/MacSyncSettingsView.swift",
    ]

    /// ⌘K 浮层（设置分组数据源必须来自目录）
    static let searchLayerPath = "QQPlayer/Mac/MacSearchAnythingLayer.swift"

    /// 锚点辅助的规范调用形式：`.settingsAnchor(MacSettingsCatalog.<常量>)`
    static let anchorCallPrefix = ".settingsAnchor(MacSettingsCatalog."

    enum ContractError: Error, CustomStringConvertible {
        case unreadable(String)
        case malformedCatalog(String)
        case noLocalizationResource(String)

        var description: String {
            switch self {
            case .unreadable(let path):
                return "契约测试读不到文件（fail-closed）：\(path)"
            case .malformedCatalog(let detail):
                return "设置目录解析失败（fail-closed）：\(detail)"
            case .noLocalizationResource(let detail):
                return "契约测试读不到本地化资源（fail-closed）：\(detail)"
            }
        }
    }

    /// 目录里的一条设置项（源码解析结果；测试不能 @testable 到 Mac target 的类型）
    struct CatalogItem {
        let constant: String
        let id: String
        let category: String
        let titleKey: String
        let aliases: [String]
    }

    // MARK: 注释剥离

    /// 剥掉行注释 / 块注释，**保留字符串字面量**（锚点规则要看清 `.id("…")`）。
    /// 字符串内的 `//`（URL 等）不当注释；字符串内的转义字符原样保留。
    static func codeOnly(_ source: String) -> String {
        var output = ""
        let characters = Array(source)
        var index = 0
        var inLineComment = false
        var inBlockComment = false
        var inString = false

        while index < characters.count {
            let current = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil

            if inLineComment {
                if current == "\n" { inLineComment = false; output.append(current) }
                index += 1
                continue
            }
            if inBlockComment {
                if current == "*" && next == "/" { inBlockComment = false; index += 2; continue }
                index += 1
                continue
            }
            if inString {
                output.append(current)
                if current == "\\" {
                    if let escaped = next { output.append(escaped) }
                    index += 2
                    continue
                }
                if current == "\"" { inString = false }
                index += 1
                continue
            }
            if current == "/" && next == "/" { inLineComment = true; index += 2; continue }
            if current == "/" && next == "*" { inBlockComment = true; index += 2; continue }
            if current == "\"" { inString = true; output.append(current); index += 1; continue }
            output.append(current)
            index += 1
        }
        return output
    }

    // MARK: 正则

    static func captureGroups(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0 ..< match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return "" }
                return ns.substring(with: range)
            }
        }
    }

    // MARK: 目录解析

    /// 解析 `static let <常量> = Item(id:category:titleKey:aliases:)` 条目。
    /// 形状固定（一处定义），解析不出任何条目 = 红（防目录被改写成别的形状后契约空转）。
    static func parseItems(catalogSource: String) throws -> [CatalogItem] {
        let pattern = #"static let (\w+) = Item\(\s*id: "([^"]+)",\s*category: \.(\w+),\s*titleKey: "([^"]+)",\s*aliases: \[([^\]]*)\]\s*\)"#
        let rows = captureGroups(pattern: pattern, in: codeOnly(catalogSource))
        guard !rows.isEmpty else {
            throw ContractError.malformedCatalog("解析不出任何 Item（形状变了？）")
        }
        return rows.map { groups in
            CatalogItem(
                constant: groups[1],
                id: groups[2],
                category: groups[3],
                titleKey: groups[4],
                aliases: groups[5]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"")) }
                    .filter { !$0.isEmpty }
            )
        }
    }

    /// 解析分类的 titleKey（`case .playback: return "settings_category_playback"`）。
    static func parseCategoryTitleKeys(catalogSource: String) throws -> [(category: String, titleKey: String)] {
        let pattern = #"case \.(\w+): return "(settings_category_[a-z_]+)""#
        let rows = captureGroups(pattern: pattern, in: codeOnly(catalogSource))
        guard !rows.isEmpty else {
            throw ContractError.malformedCatalog("解析不出任何分类 titleKey")
        }
        return rows.map { (category: $0[1], titleKey: $0[2]) }
    }

    /// 分类 rawValue（`case playback` 枚举 case 行）——⌘K 分组里的写死名单检查用。
    static func parseCategoryRawValues(catalogSource: String) -> [String] {
        let pattern = #"enum Category: String, CaseIterable, Hashable, Identifiable \{\s*((?:case \w+\s*)+)"#
        guard let block = captureGroups(pattern: pattern, in: codeOnly(catalogSource)).first else { return [] }
        return captureGroups(pattern: #"case (\w+)"#, in: block[1]).map { $0[1] }
    }

    // MARK: 锚点扫描

    /// 设置页源码里引用的目录常量名（规范形式 `.settingsAnchor(MacSettingsCatalog.<常量>)`）。
    static func anchorReferences(inSettingsSource code: String) -> [String] {
        captureGroups(pattern: #"\.settingsAnchor\(MacSettingsCatalog\.(\w+)\)"#, in: code).map { $0[1] }
    }

    /// 目录之外的锚点写法（返回违规片段描述）：
    /// 字符串字面量作为锚点 id、非规范形式的 `.settingsAnchor(...)`、以及手写 `.id("…")` / `.scrollTo("…")`。
    static func anchorViolations(inSettingsSource code: String) -> [String] {
        var violations: [String] = []
        for row in captureGroups(pattern: #"\.settingsAnchor\(([^)]*)\)"#, in: code) {
            let argument = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !argument.hasPrefix("MacSettingsCatalog.") {
                violations.append(".settingsAnchor(\(argument))")
            }
        }
        for pattern in [#"\.id\(\s*""#, #"\.scrollTo\(\s*""#] {
            for row in captureGroups(pattern: pattern, in: code) {
                violations.append(row[0].trimmingCharacters(in: .whitespacesAndNewlines) + "…")
            }
        }
        return violations
    }

    // MARK: 文件读取（失败一律抛，不静默）

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func read(relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContractError.unreadable(relativePath)
        }
        return text
    }

    static func settingsPageSources() throws -> [(path: String, code: String)] {
        try settingsPageFiles.map { path in (path: path, code: codeOnly(try read(relativePath: path))) }
    }

    /// 全部 lproj 的 Localizable.strings → key 集合（一个都读不到 = 红）
    static func localizationKeysByLocale() throws -> [String: Set<String>] {
        let resources = repositoryRoot.appendingPathComponent("QQPlayer/Resources")
        let entries = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
        let locales = entries.filter { $0.pathExtension == "lproj" }.sorted { $0.path < $1.path }
        guard !locales.isEmpty else {
            throw ContractError.noLocalizationResource("QQPlayer/Resources 下没有 .lproj")
        }
        var result: [String: Set<String>] = [:]
        for locale in locales {
            let file = locale.appendingPathComponent("Localizable.strings")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                throw ContractError.unreadable(file.path)
            }
            let keys = captureGroups(pattern: #"(?m)^\s*"([^"]+)"\s*="#, in: text).map { $0[1] }
            result[locale.deletingPathExtension().lastPathComponent] = Set(keys)
        }
        return result
    }

    /// 全仓（QQPlayer/ + Share/ + 测试）Swift 源码
    static func allSwiftSources() throws -> [(path: String, code: String)] {
        var files: [(String, String)] = []
        let prefix = repositoryRoot.path + "/"
        for directory in ["QQPlayer", "Share", "QQPlayerTests"] {
            let url = repositoryRoot.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else { throw ContractError.unreadable(directory) }
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let relative = file.path.replacingOccurrences(of: prefix, with: "")
                guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                    throw ContractError.unreadable(relative)
                }
                files.append((relative, text))
            }
        }
        guard !files.isEmpty else { throw ContractError.unreadable("Swift 源码目录") }
        return files.sorted { $0.0 < $1.0 }
    }
}

// MARK: - 契约测试

@Suite("⌘K 设置项搜索契约（设置目录唯一注册表 + 锚点单一来源）")
struct MacSettingsSearchContractTests {
    @Test("目录可解析：条目非空、id / 常量名唯一、分类齐全")
    func catalogIsWellFormed() throws {
        let source = try MacSettingsSearchContract.read(relativePath: MacSettingsSearchContract.catalogPath)
        let items = try MacSettingsSearchContract.parseItems(catalogSource: source)
        let categories = try MacSettingsSearchContract.parseCategoryTitleKeys(catalogSource: source)
        let rawValues = MacSettingsSearchContract.parseCategoryRawValues(catalogSource: source)

        #expect(items.count >= 20, "设置目录条目数疑似被削（当前 \(items.count)）")
        #expect(categories.count == rawValues.count, "分类数（\(rawValues.count)）与 titleKey 数（\(categories.count)）不一致")
        #expect(Set(rawValues).count == rawValues.count, "分类 rawValue 有重复：\(rawValues)")
        #expect(Set(items.map(\.id)).count == items.count, "锚点 id 有重复")
        #expect(Set(items.map(\.constant)).count == items.count, "条目常量名有重复")
        for item in items {
            #expect(rawValues.contains(item.category), "条目 \(item.constant) 的分类 .\(item.category) 不在 Category 里")
            #expect(!item.aliases.isEmpty, "条目 \(item.constant) 没有搜索别名（搜不到）")
        }
    }

    @Test("(a) 目录每条 titleKey（含分类）在全部 lproj 里真实存在")
    func everyTitleKeyExistsInLocalizations() throws {
        let source = try MacSettingsSearchContract.read(relativePath: MacSettingsSearchContract.catalogPath)
        let items = try MacSettingsSearchContract.parseItems(catalogSource: source)
        let categories = try MacSettingsSearchContract.parseCategoryTitleKeys(catalogSource: source)
        let keysByLocale = try MacSettingsSearchContract.localizationKeysByLocale()

        var missing: [String] = []
        for (locale, keys) in keysByLocale.sorted(by: { $0.key < $1.key }) {
            for item in items where !keys.contains(item.titleKey) {
                missing.append("\(locale): \(item.constant) → \(item.titleKey)")
            }
            for category in categories where !keys.contains(category.titleKey) {
                missing.append("\(locale): 分类 .\(category.category) → \(category.titleKey)")
            }
        }
        #expect(missing.isEmpty, "目录引用了不存在的本地化 key：\(missing)")
        #expect(keysByLocale.count >= 5, "lproj 数量疑似被削（当前 \(keysByLocale.keys.sorted())）")
    }

    @Test("(b)(c) 每条锚点在设置页真实出现；设置页不得手写锚点 id")
    func anchorsAreSingleSourced() throws {
        let catalogSource = try MacSettingsSearchContract.read(relativePath: MacSettingsSearchContract.catalogPath)
        let items = try MacSettingsSearchContract.parseItems(catalogSource: catalogSource)
        let pages = try MacSettingsSearchContract.settingsPageSources()

        var referenced: Set<String> = []
        var violations: [String] = []
        for page in pages {
            referenced.formUnion(MacSettingsSearchContract.anchorReferences(inSettingsSource: page.code))
            for violation in MacSettingsSearchContract.anchorViolations(inSettingsSource: page.code) {
                violations.append("\(page.path): \(violation)")
            }
        }

        let missing = items.map(\.constant).filter { !referenced.contains($0) }
        #expect(
            missing.isEmpty,
            "目录里的条目在设置页没有锚点（滚动/高亮会落空）：\(missing)——用 .settingsAnchor(MacSettingsCatalog.<常量>) 标"
        )
        let dangling = referenced.subtracting(items.map(\.constant))
        #expect(dangling.isEmpty, "设置页引用了目录里不存在的锚点常量：\(dangling.sorted())")
        #expect(
            violations.isEmpty,
            "设置页出现目录之外的锚点写法（锚点 id 只能来自目录常量）：\(violations)"
        )
    }

    @Test("(d) ⌘K 设置分组走目录，且不再写死分类名单")
    func searchLayerUsesCatalog() throws {
        let code = MacSettingsSearchContract.codeOnly(
            try MacSettingsSearchContract.read(relativePath: MacSettingsSearchContract.searchLayerPath)
        )
        let catalogSource = try MacSettingsSearchContract.read(relativePath: MacSettingsSearchContract.catalogPath)
        let rawValues = MacSettingsSearchContract.parseCategoryRawValues(catalogSource: catalogSource)

        #expect(
            code.contains("MacSettingsCatalog.matches(for:"),
            "⌘K 设置分组必须用 MacSettingsCatalog.matches(for:) 过滤（分类名 + 项标题 + 别名）"
        )
        #expect(
            !code.contains(".settingsAnchor("),
            "⌘K 浮层不是设置页，不该有锚点标记"
        )
        let hardcoded = rawValues.filter { code.contains("\"\($0)\"") }
        #expect(
            hardcoded.isEmpty,
            "⌘K 浮层里出现了写死的分类 rawValue 字面量（第二份分类名单）：\(hardcoded)"
        )
    }

    @Test("(d) 全仓不再有字符串型私有 selector（showSettingsWindow: 那类）")
    func noStringBasedPrivateSelectors() throws {
        var hits: [String] = []
        for file in try MacSettingsSearchContract.allSwiftSources() {
            let code = MacSettingsSearchContract.codeOnly(file.code)
            // 匹配「调用形状」而不是标识符本身：本文件里的模式字符串（`#"…"#`）不会自匹配
            for row in MacSettingsSearchContract.captureGroups(pattern: #"Selector\s*\(\s*\("#, in: code) {
                hits.append("\(file.path): \(row[0])…")
            }
            for _ in MacSettingsSearchContract.captureGroups(pattern: #"NSSelector"# + #"FromString\s*\("#, in: code) {
                hits.append("\(file.path): NSSelector" + "FromString")
            }
        }
        #expect(
            hits.isEmpty,
            "字符串型 selector 会随系统版本静默失效（macOS 26 实测 showSettingsWindow: 无效，改用 @Environment(\\.openSettings)）：\(hits)"
        )
    }

    @Test("防契约空转：剥注释保留字面量、违规抓得到、目录解析抓得到")
    func scannersCatchSyntheticViolations() {
        // 注释里的字面量不算代码（踩过坑：文档注释里的反例会误伤）
        let commented = """
        // 反例：.id("settings.scraping.batchEnabled") 与 .settingsAnchor("x")
        /* 块注释里也一样 .settingsAnchor("y") */
        Text("hello") // .id("another")
        """
        let stripped = MacSettingsSearchContract.codeOnly(commented)
        #expect(MacSettingsSearchContract.anchorViolations(inSettingsSource: stripped).isEmpty)
        #expect(MacSettingsSearchContract.anchorReferences(inSettingsSource: stripped).isEmpty)

        // 字符串里的 `//`（URL）不被当注释，且字符串字面量保留（(c) 能抓到）
        let urlString = "Text(\"https://example.com\")"
        #expect(MacSettingsSearchContract.codeOnly(urlString).contains("https://example.com"))

        // 违规抓得到：手写 id / 字面量锚点 / 非规范形式
        let bad = """
        Text("a").id("settings.lyrics.offset")
        Text("b").settingsAnchor("literal")
        """
        let caught = MacSettingsSearchContract.anchorViolations(inSettingsSource: bad)
        #expect(caught.count == 2, "应抓到 2 处违规，实际 \(caught)")

        // 规范形式被正确识别为「引用了目录常量」
        let good = "Toggle(\"x\", isOn: $b).settingsAnchor(MacSettingsCatalog.scrapingBatchEnabled)"
        #expect(MacSettingsSearchContract.anchorReferences(inSettingsSource: good) == ["scrapingBatchEnabled"])
        #expect(MacSettingsSearchContract.anchorViolations(inSettingsSource: good).isEmpty)

        // 目录解析：形状变了要抛错（而不是静默 0 条）
        let emptyCatalog = "enum MacSettingsCatalog { static let x = 1 }"
        #expect(throws: MacSettingsSearchContract.ContractError.self) {
            try MacSettingsSearchContract.parseItems(catalogSource: emptyCatalog)
        }
        let snippet = """
            static let scrapingBatchEnabled = Item(
                id: "settings.scraping.batchEnabled",
                category: .scraping,
                titleKey: "scraping_batch_enabled",
                aliases: ["刮削", "批量", "batch"]
            )
        """
        let parsed = try? MacSettingsSearchContract.parseItems(catalogSource: snippet)
        #expect(parsed?.count == 1)
        #expect(parsed?.first?.aliases == ["刮削", "批量", "batch"])
        #expect(parsed?.first?.category == "scraping")
    }
}
