//
//  AppNotificationContractTests.swift
//  QQPlayerTests
//
//  通知名「唯一入口 + 形状」契约（2026-09-16 事件层收口）。
//
//  背景：20 个通知名散落在 97 处字面量里，16 个**根本没有常量**（调用点内联
//  `NSNotification.Name("X")`）。这种缺口单测测不到——写错了名字、多写一套字面量，
//  编译、lint、跑起来都不报（顶多事件静默不生效），只能用**静态形状契约**兜住。
//
//  设计要点（照 UIAccentContractTests 的写法）：
//  - 扫描规则收敛在纯函数里（`AppNotificationContract`），**不碰文件系统** ⇒
//    测试里能用合成源码自证「该抓的会红、不该抓的不误报」（防契约空转）。
//  - 白名单 fail-closed：唯一入口文件之外任何一处 `Notification.Name("…")` 都算违规；
//    另有单独用例断言「每条白名单都还在真实源码里命中」（防白名单腐烂）。
//  - 去注释**必须分区 + 感知字符串**（踩过的坑：朴素全局 `/* */` 去注释一次吞掉 40% 文件，
//    导致违规漏抓）。本文件的剥离器：逐字符状态机，认 `//`、嵌套 `/* */`、字符串（含
//    `"""` 多行串与 `#"…"#` 原始串），注释字符替换成空格**保留行号**；
//    另有「块注释不得未闭合」断言，防止解析出错时静默吞文件。
//  - 扫描范围**只含 App 源码**（`QQPlayer/**`），不含 `QQPlayerTests/**`——
//    本文件内部就含反例字符串字面量，扫进来必然自判违规。
//

import Foundation
import Testing

@testable import QQPlayer

// SCAN-BEGIN —— 以下到 SCAN-END 之间是纯逻辑（只用 Foundation 字符串 API，不碰文件系统）

enum AppNotificationContract {
    /// 唯一入口文件（全 App 唯一允许出现 `Notification.Name("…")` 字面量的地方）
    static let entryFileSuffix = "QQPlayer/Models/AppNotifications.swift"

    /// 18 个常量的期望清单：`字符串值 → 常量属性名`（顺序即入口文件里的声明顺序）。
    /// 少一个 / 多一个 / 拼错名 / 字符串值被改动 → 契约红。
    static let expectedConstants: [(value: String, property: String)] = [
        ("LibraryNeedsRefresh", "libraryNeedsRefresh"),
        ("PlaylistsChanged", "playlistsChanged"),
        ("BackgroundColorChanged", "backgroundColorChanged"),
        ("LibraryFolderContentChanged", "libraryFolderContentChanged"),
        ("FavoritesChanged", "favoritesChanged"),
        ("QQPlayerArtworkRefreshed", "qqplayerArtworkRefreshed"),
        ("NavigateToArtistFromPlayer", "navigateToArtistFromPlayer"),
        ("NavigateToAlbumFromPlayer", "navigateToAlbumFromPlayer"),
        ("MinimizePlayer", "minimizePlayer"),
        ("CarPlaySceneDidDisconnect", "carPlaySceneDidDisconnect"),
        ("NavigateToPlaylist", "navigateToPlaylist"),
        ("TrackFound", "trackFound"),
        ("MacSettingsOpenCategory", "macSettingsOpenCategory"),
        ("LibraryFoldersChanged", "libraryFoldersChanged"),
        ("QQPlayerSettingsDidChange", "qqplayerSettingsDidChange"),
        ("LibraryScanCriteriaChanged", "libraryScanCriteriaChanged"),
        ("LibraryImportFinished", "libraryImportFinished"),
        ("MacSyncDevicesChanged", "macSyncDevicesChanged"),
    ]

    /// 2026-09-16 收口时**删除的死事件**（0 订阅方，审计核实）：不得再出现在源码里，
    /// 也不得有常量（谁把 post 加回来而没有订阅方 → 红）。
    static let retiredValues = ["PlayerStateChanged", "PlayerSeekFailed"]

    /// 白名单条目：文件路径尾段 + 行内容片段 + 理由（理由必写明「为什么这里合法」）
    struct WhitelistEntry {
        let fileSuffix: String
        let lineSnippet: String
        let reason: String
    }

    /// 一条静态规则：禁止的正则 + 合法例外
    struct Rule {
        let name: String
        let pattern: String
        let whitelist: [WhitelistEntry]
    }

    /// 唯一性规则：App 源码里除唯一入口文件外，不得再出现 `Notification.Name("…")` 字面量。
    ///
    /// 正则是带前后视的（**不是裸子串**）：
    /// - `(?<![\w.])` 排除 `SomeType.Notification.Name(` / 标识符尾部这类粘连，同时允许 `NSNotification.Name(`；
    /// - `(?:NS)?` 两种写法都抓（仓库里本来就混用）；
    /// - `\("` 要求紧跟字符串引号 ⇒ `Notification.Name(rawValue:)`、`forName:` 参数名、
    ///   `Notification.Name.常量` 这些都不是「新造字面量」，不误伤。
    static let literalRule = Rule(
        name: "通知名走唯一入口 AppNotifications.swift，不得再写 Notification.Name(\"…\") 字面量",
        pattern: #"(?<![\w.])(?:NS)?Notification\.Name\(""#,
        whitelist: [
            WhitelistEntry(
                fileSuffix: entryFileSuffix,
                lineSnippet: #"Notification.Name(""#,
                reason: "唯一入口文件本身：18 个常量的字符串值在此定义，字符串值必须与历史字面量逐字相同"
            ),
        ]
    )

    /// 唯一入口声明规则：全 App 只能有一处 `extension Notification.Name`
    static let extensionDeclarationPattern = #"extension\s+Notification\.Name\b"#

    // MARK: - 去注释（分区 + 感知字符串）

    /// 纯函数：把源码里的注释字符替换成空格（**换行保留 ⇒ 行号不变**）。
    ///
    /// 处理：`//` 行注释、`/* */` 块注释（Swift 支持嵌套）、普通字符串 `"…"`、
    /// 多行字符串 `"""…"""`、原始字符串 `#"…"#`（含多 `#`）。
    /// 字符串**内容**一并抹成空格（防串内 `//` 开注释、防串内反例自判违规），
    /// 但**首尾引号保留为代码**——否则 `Notification.Name("X")` 的 `("` 会被当成串首被抹掉，
    /// 唯一性规则就再也抓不到任何东西（契约静默空转）。
    ///
    /// 返回值第二项 = 「块注释到文件结束仍未闭合」。真源码不该出现（编译不过）；
    /// 出现说明本剥离器解析错了（B2c 那次的吞文件坑），测试里直接红。
    static func stripComments(source: String) -> (code: String, unterminatedBlockComment: Bool) {
        let chars = Array(source)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        var blockDepth = 0

        /// 注释内容 → 空格（换行保留）
        func mask(_ c: Character) { out.append(c == "\n" ? "\n" : " ") }
        func keep(_ c: Character) { out.append(c) }

        while i < chars.count {
            let c = chars[i]

            // ① 块注释内（含嵌套）
            if blockDepth > 0 {
                if c == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    blockDepth -= 1
                    mask(c); mask(chars[i + 1]); i += 2; continue
                }
                if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    blockDepth += 1
                    mask(c); mask(chars[i + 1]); i += 2; continue
                }
                mask(c); i += 1; continue
            }

            // ② 行注释
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { mask(chars[i]); i += 1 }
                continue
            }

            // ③ 块注释开启
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                blockDepth = 1
                mask(c); mask(chars[i + 1]); i += 2; continue
            }

            // ④ 原始字符串 #"…"#（内容抹掉，首尾定界符保留）
            if c == "#" {
                var j = i
                while j < chars.count, chars[j] == "#" { j += 1 }
                if j < chars.count, chars[j] == "\"" {
                    let hashes = j - i
                    var k = j + 1
                    while k < chars.count {
                        if chars[k] == "\"" {
                            var m = k + 1
                            var seen = 0
                            while m < chars.count, chars[m] == "#", seen < hashes { seen += 1; m += 1 }
                            if seen == hashes { k = m; break }
                        }
                        k += 1
                    }
                    for x in i ..< min(j + 1, chars.count) { keep(chars[x]) }          // 开场 #…"
                    for x in min(j + 1, chars.count) ..< min(max(k - 1, j + 1), chars.count) { mask(chars[x]) }
                    if k - 1 >= j + 1, k - 1 < chars.count { keep(chars[k - 1]) }        // 收尾 "
                    for x in min(max(k, j + 1), chars.count) ..< min(k + hashes, chars.count) { keep(chars[x]) }
                    i = min(k + hashes, chars.count)
                    continue
                }
                keep(c); i += 1; continue
            }

            // ⑤ 多行字符串 """…"""
            if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                keep(chars[i]); keep(chars[i + 1]); keep(chars[i + 2])
                i += 3
                while i < chars.count {
                    if chars[i] == "\\", i + 1 < chars.count { mask(chars[i]); mask(chars[i + 1]); i += 2; continue }
                    if chars[i] == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                        keep(chars[i]); keep(chars[i + 1]); keep(chars[i + 2]); i += 3; break
                    }
                    mask(chars[i]); i += 1
                }
                continue
            }

            // ⑥ 普通字符串 "…"
            if c == "\"" {
                keep(c); i += 1
                while i < chars.count {
                    if chars[i] == "\\", i + 1 < chars.count { mask(chars[i]); mask(chars[i + 1]); i += 2; continue }
                    if chars[i] == "\"" { keep(chars[i]); i += 1; break }
                    mask(chars[i]); i += 1
                }
                continue
            }

            keep(c); i += 1
        }

        return (out, blockDepth > 0)
    }

    // MARK: - 扫描

    struct Report {
        var scannedLines = 0
        /// 命中过禁止模式的行数（>0 说明规则确实在匹配真实代码，不是空转）
        var forbiddenLines = 0
        /// 违规行描述：`路径:行号: 行内容 → 违反 <规则名>`
        var violations: [String] = []
        /// 命中的白名单下标（白名单腐烂检测用）
        var whitelistHits: Set<String> = []
        /// 块注释未闭合的文件（剥离器解析出错的自证）
        var suspiciousFiles: [String] = []
    }

    /// 纯函数扫描：源码文本 → 违规列表（不读文件系统，便于合成源码单测）
    static func scan(source: String, filePath: String, rules: [Rule]) -> Report {
        var report = Report()
        let stripped = stripComments(source: source)
        if stripped.unterminatedBlockComment { report.suspiciousFiles.append(filePath) }

        // 掩码文本用于**匹配**（串内内容/注释已抹掉）；报错时把**原始行**打出来给人看，
        // 否则违规信息里那行代码的字符串会被显示成一串空格（本文件第一次写完就这样）。
        let maskedLines = stripped.code.components(separatedBy: .newlines)
        let originalLines = source.components(separatedBy: .newlines)
        for (index, line) in maskedLines.enumerated() {
            report.scannedLines += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            for rule in rules {
                guard line.range(of: rule.pattern, options: .regularExpression) != nil else { continue }
                report.forbiddenLines += 1
                // 白名单：整行命中即豁免（fileSuffix + lineSnippet 同时匹配才算）
                if let hit = rule.whitelist.firstIndex(where: {
                    filePath.hasSuffix($0.fileSuffix) && line.contains($0.lineSnippet)
                }) {
                    report.whitelistHits.insert("\(rule.name)|\(hit)")
                    continue
                }
                let shown = index < originalLines.count
                    ? originalLines[index].trimmingCharacters(in: .whitespaces)
                    : trimmed
                report.violations.append(
                    "\(filePath):\(index + 1): \(shown)  → 违反「\(rule.name)」"
                )
            }
        }
        return report
    }

    // MARK: - 形状断言（专治死事件：有 broadcast 没人听 / 有人听没人发）

    /// 出现次数（纯函数；正则，不碰文件系统）
    static func occurrences(of pattern: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex ..< text.endIndex
        while let range = text.range(of: pattern, options: .regularExpression, range: searchRange) {
            count += 1
            if range.upperBound >= text.endIndex { break }
            searchRange = range.upperBound ..< text.endIndex
        }
        return count
    }

    /// post 点：`NotificationCenter.default.post(name: .x, …)`（`name:` 只属于 post）。
    /// 允许两种写法：`.x` 与显式拼类型的 `Notification.Name.x`（超长 SwiftUI 修饰链里
    /// 显式拼出类型能显著降低类型推断负担，MacLibraryView 实测需要）。
    static func postSites(constant: String, in code: String) -> Int {
        occurrences(of: "name:\\s*(?:Notification\\.Name)?\\.\(constant)\\b", in: code)
    }

    /// 订阅点：`publisher(for: .x)` / `addObserver(forName: .x, …)`（同样允许显式类型写法）
    static func subscribeSites(constant: String, in code: String) -> Int {
        occurrences(of: "(?:forName|for):\\s*(?:Notification\\.Name)?\\.\(constant)\\b", in: code)
    }

    /// 形状缺口：既没有 post 点、或没有订阅点的常量（谁没有谁红）
    static func shapeGaps(in code: String, constants: [String]) -> [String] {
        var gaps: [String] = []
        for name in constants {
            let posts = postSites(constant: name, in: code)
            let subs = subscribeSites(constant: name, in: code)
            if posts == 0 { gaps.append(".\(name) 没有 post 点（发出去没人听的死事件）") }
            if subs == 0 { gaps.append(".\(name) 没有订阅点（永远不触发的空广播）") }
        }
        return gaps
    }

    // MARK: - 入口文件解析

    /// 纯函数：解析入口文件里的常量定义 `static let <property> = Notification.Name("<value>")`。
    ///
    /// 注意：**匹配位置在「去注释后的掩码文本」上找，取值回到原始文本上取**——
    /// 掩码会把字符串内容抹成空格（防串内 `//` 开注释），直接在被掩码文本上取值会
    /// 得到一串空格（本文件第一次写完就是这么红的）。掩码是「每个 Character → 一个空格、
    /// 换行保留」⇒ Character 计数一一对应，按字符偏移回原文本取值即可，也不受 emoji 等
    /// 多 UTF-16 单元字符影响。
    static func parseConstants(source: String) -> [(value: String, property: String)] {
        let masked = stripComments(source: source).code
        let regex = try? NSRegularExpression(
            pattern: #"static\s+let\s+([A-Za-z0-9_]+)\s*=\s*Notification\.Name\("([^"]+)"\)"#
        )
        guard let regex else { return [] }
        let full = masked as NSString
        return regex.matches(in: masked, range: NSRange(location: 0, length: full.length))
            .compactMap { match in
                guard match.numberOfRanges == 3 else { return nil }
                guard let property = originalSubstring(masked: masked, source: source, range: match.range(at: 1)),
                      let value = originalSubstring(masked: masked, source: source, range: match.range(at: 2))
                else { return nil }
                return (value: value, property: property)
            }
    }

    /// 掩码文本上的 NSRange → 原始文本上的同位置子串（按 Character 偏移映射）
    static func originalSubstring(masked: String, source: String, range: NSRange) -> String? {
        guard let maskedRange = Range(range, in: masked) else { return nil }
        let start = masked.distance(from: masked.startIndex, to: maskedRange.lowerBound)
        let length = masked.distance(from: maskedRange.lowerBound, to: maskedRange.upperBound)
        guard let lower = source.index(source.startIndex, offsetBy: start, limitedBy: source.endIndex),
              let upper = source.index(lower, offsetBy: length, limitedBy: source.endIndex)
        else { return nil }
        return String(source[lower ..< upper])
    }
}

// SCAN-END

extension AppNotificationContract {
    /// 递归收集 .swift（文件系统访问只在这个辅助函数里，核心扫描保持纯净）
    static func swiftFiles(under relativePaths: [String], repoRoot: URL) -> [URL] {
        var result: [URL] = []
        let fileManager = FileManager.default
        for path in relativePaths {
            let base = repoRoot.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: base.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                result.append(base)
                continue
            }
            guard let enumerator = fileManager.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// App 源码（**只扫 App，不扫测试**：测试里会出现反例写法字符串，不该自判）
    static func appSourceFiles(repoRoot: URL) -> [URL] {
        swiftFiles(under: ["QQPlayer"], repoRoot: repoRoot)
    }
}

// MARK: - 测试

struct AppNotificationContractTests {
    /// 仓库根：本文件位于 <repo>/QQPlayerTests/ 下 → 上两级
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static var entryFileURL: URL {
        repoRoot.appendingPathComponent(AppNotificationContract.entryFileSuffix)
    }

    static func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
    }

    static func scanFiles(_ urls: [URL], rules: [AppNotificationContract.Rule])
        -> (violations: [String], forbiddenLines: Int, hits: Set<String>, suspicious: [String]) {
        var violations: [String] = []
        var forbiddenLines = 0
        var hits: Set<String> = []
        var suspicious: [String] = []
        for file in urls {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let report = AppNotificationContract.scan(
                source: source, filePath: Self.relativePath(file), rules: rules
            )
            violations.append(contentsOf: report.violations)
            forbiddenLines += report.forbiddenLines
            hits.formUnion(report.whitelistHits)
            suspicious.append(contentsOf: report.suspiciousFiles)
        }
        return (violations, forbiddenLines, hits, suspicious)
    }

    /// 全 App 源码（已去注释）拼成一份文本，供形状统计
    static func strippedAppCode(_ urls: [URL]) -> String {
        urls.compactMap { url -> String? in
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return AppNotificationContract.stripComments(source: source).code
        }.joined(separator: "\n")
    }

    static let constantNames = AppNotificationContract.expectedConstants.map(\.property)

    // MARK: 地基检查

    @Test("仓库根与唯一入口文件解析正确（扫描前的地基检查）")
    func scanScopeResolves() {
        #expect(
            FileManager.default.fileExists(atPath: Self.entryFileURL.path),
            "唯一入口文件不存在：\(Self.entryFileURL.path)（仓库根解析错了？\(Self.repoRoot.path)）"
        )
        let files = AppNotificationContract.appSourceFiles(repoRoot: Self.repoRoot)
        #expect(files.count >= 250, "App 源码扫描范围异常：\(files.count)")
        let testFiles = files.filter { Self.relativePath($0).hasPrefix("QQPlayerTests/") }
        #expect(testFiles.isEmpty, "扫描范围混进了测试文件（测试里的反例字符串会自判违规）：\(testFiles)")
    }

    // MARK: 去注释剥离器自证（B2c 吞文件坑的守卫）

    @Test("去注释：行号保留 + 串内 // 与 /* 不开注释 + 块注释里的反例被抹掉 + 不吞后续代码")
    func commentStripperIsStringAwareAndKeepsLineNumbers() {
        let source = [
            #"let url = "https://example.com/a//b"  // 行注释：Notification.Name("FavoritesChanged")"#, // 1
            "/* 块注释开头",                                                                              // 2
            #"   反例 Notification.Name("LibraryNeedsRefresh")"#,                                        // 3
            "*/",                                                                                        // 4
            ##"let pattern = #"a//b/*c"#"##,                                                               // 5
            #"let doc = "Notification.Name(\"TrackFound\")""#,                                            // 6
            #"Notification.Name("MinimizePlayer")"#,                                                      // 7 ← 真正该抓的
        ].joined(separator: "\n")

        let stripped = AppNotificationContract.stripComments(source: source)
        #expect(!stripped.unterminatedBlockComment, "块注释被误判为未闭合（剥离器解析错了）")
        #expect(
            stripped.code.components(separatedBy: .newlines).count == source.components(separatedBy: .newlines).count,
            "剥离后行数变了（行号会漂，违规定位就不可信了）"
        )

        let report = AppNotificationContract.scan(
            source: source, filePath: "QQPlayer/Views/Tmp.swift", rules: [AppNotificationContract.literalRule]
        )
        #expect(report.forbiddenLines == 1, "应只命中第 7 行那 1 处，实际 \(report.forbiddenLines)")
        #expect(
            report.violations.first?.hasPrefix("QQPlayer/Views/Tmp.swift:7:") == true,
            "违规行号应精确到 7：\(report.violations)"
        )
        #expect(report.suspiciousFiles.isEmpty, "不该报块注释未闭合：\(report.suspiciousFiles)")
    }

    // MARK: 契约自证有效（合成源码）

    @Test("合成违规源码必须被抓到，且报出精确 文件:行（契约自证有效的关键用例）")
    func syntheticViolationsAreCaught() {
        let snippets = [
            #"        NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)"#,
            #"        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("PlaylistsChanged"))) { _ in }"#,
            #"        NotificationCenter.default.addObserver(forName: NSNotification.Name("TrackFound"), object: nil, queue: nil) { _ in }"#,
        ]
        for snippet in snippets {
            let source = ["import Foundation", "", "func f() {", snippet, "}"].joined(separator: "\n")
            let report = AppNotificationContract.scan(
                source: source, filePath: "QQPlayer/Views/Tmp.swift", rules: [AppNotificationContract.literalRule]
            )
            #expect(report.violations.count == 1, "\(snippet) 应被抓到，实际：\(report.violations)")
            #expect(
                report.violations.first?.contains("QQPlayer/Views/Tmp.swift:4:") == true,
                "违规行应带精确行号：\(report.violations)"
            )
        }
    }

    @Test("合成合法源码不报（常量形式 / rawValue / 参数名 / 注释 / 字符串内反例）")
    func syntheticLegalSourceIsClean() {
        let source = [
            "import Foundation",
            "func f() {",
            "    NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)",
            "    NotificationCenter.default.post(",
            "        name: .libraryImportFinished,",
            "        object: nil,",
            "        userInfo: [\"count\": 1]",
            "    )",
            "    _ = NotificationCenter.default.publisher(for: .qqplayerArtworkRefreshed)",
            "    NotificationCenter.default.addObserver(forName: .trackFound, object: nil, queue: nil) { _ in }",
            "    NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in }",
            "    let raw = Notification.Name(rawValue: \"LibraryNeedsRefresh\")",
            "    // 反例说明：不要写 Notification.Name(\"LibraryNeedsRefresh\")",
            "    /// 反例说明：不要写 NSNotification.Name(\"PlaylistsChanged\")",
            "    let doc = \"反例 Notification.Name(\\\"FavoritesChanged\\\")\"",
            "    /* 块注释里的反例 Notification.Name(\"MinimizePlayer\") */",
            "}",
        ].joined(separator: "\n")
        let report = AppNotificationContract.scan(
            source: source, filePath: "QQPlayer/Views/Tmp.swift", rules: [AppNotificationContract.literalRule]
        )
        #expect(report.violations.isEmpty, "合法写法被误判：\(report.violations)")
        #expect(report.forbiddenLines == 0, "合法源码不该命中禁止模式：\(report.forbiddenLines)")
    }

    @Test("形状断言自证：无订阅的空广播 / 无 post 的死事件，恰好被抓")
    func shapeAssertionCatchesSyntheticGaps() {
        let source = [
            "import Foundation",
            "func postOnly() {",
            "    NotificationCenter.default.post(name: .playlistsChanged, object: nil)",   // 有 post 无订阅
            "}",
            "func subscribeOnly() {",
            "    _ = NotificationCenter.default.publisher(for: .favoritesChanged)",        // 有订阅无 post
            "}",
            "func healthy() {",
            "    NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)",
            "    _ = NotificationCenter.default.publisher(for: .libraryNeedsRefresh)",
            "}",
        ].joined(separator: "\n")
        let code = AppNotificationContract.stripComments(source: source).code
        let gaps = AppNotificationContract.shapeGaps(
            in: code, constants: ["playlistsChanged", "favoritesChanged", "libraryNeedsRefresh"]
        )
        #expect(gaps.count == 2, "应恰好 2 条缺口，实际：\(gaps)")
        #expect(gaps.contains { $0.hasPrefix(".playlistsChanged") && $0.contains("订阅") }, "\(gaps)")
        #expect(gaps.contains { $0.hasPrefix(".favoritesChanged") && $0.contains("post") }, "\(gaps)")
        #expect(
            AppNotificationContract.postSites(constant: "libraryNeedsRefresh", in: code) == 1
                && AppNotificationContract.subscribeSites(constant: "libraryNeedsRefresh", in: code) == 1,
            "健康事件不该被判缺口"
        )
    }

    // MARK: 真实源码扫描

    @Test("唯一入口：App 源码里 Notification.Name(\"…\") 只允许出现在 AppNotifications.swift")
    func literalsLiveOnlyInTheEntryFile() {
        let files = AppNotificationContract.appSourceFiles(repoRoot: Self.repoRoot)
        let result = Self.scanFiles(files, rules: [AppNotificationContract.literalRule])

        #expect(result.suspicious.isEmpty, "这些文件的注释剥离异常（块注释未闭合）：\(result.suspicious)")
        // 非空转佐证：入口文件里那 18 行定义必须被模式命中（模式/路径写错就会漏抓）
        #expect(
            result.forbiddenLines == AppNotificationContract.expectedConstants.count,
            "命中数应恰为入口文件的 18 处常量定义，实际 \(result.forbiddenLines) = 规则空转或迁移漏做"
        )
        #expect(
            result.violations.isEmpty,
            "App 源码里仍有内联通知名字面量（改用 AppNotifications.swift 的常量）：\n\(result.violations.joined(separator: "\n"))"
        )
    }

    @Test("唯一入口文件唯一：全 App 只有一处 extension Notification.Name")
    func notificationNameExtensionIsDeclaredOnce() {
        let files = AppNotificationContract.appSourceFiles(repoRoot: Self.repoRoot)
        var declarations: [String] = []
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = AppNotificationContract.stripComments(source: source).code
            let hits = code.components(separatedBy: .newlines).enumerated()
                .filter { _, line in
                    line.range(
                        of: AppNotificationContract.extensionDeclarationPattern, options: .regularExpression
                    ) != nil
                }
                .map { index, _ in index + 1 }
            declarations.append(contentsOf: hits.map { "\(Self.relativePath(file)):\($0)" })
        }
        #expect(
            declarations.count == 1,
            "extension Notification.Name 必须只有一处（唯一入口）：\(declarations)"
        )
        #expect(
            declarations.first?.hasPrefix(AppNotificationContract.entryFileSuffix) == true,
            "唯一入口应在 \(AppNotificationContract.entryFileSuffix)：\(declarations)"
        )
    }

    @Test("常量齐全：入口文件 18 个常量，值 ↔ 名一一对应（防拼错 / 防漏迁移）")
    func entryFileDeclaresAllExpectedConstants() throws {
        let source = try String(contentsOf: Self.entryFileURL, encoding: .utf8)
        let parsed = AppNotificationContract.parseConstants(source: source)

        let expectedValues = AppNotificationContract.expectedConstants.map(\.value)
        let expectedProperties = AppNotificationContract.expectedConstants.map(\.property)
        let actualValues = parsed.map(\.value)
        let actualProperties = parsed.map(\.property)

        #expect(parsed.count == AppNotificationContract.expectedConstants.count,
                "常量条数应为 \(AppNotificationContract.expectedConstants.count)，实际 \(parsed.count)")
        #expect(actualValues == expectedValues, "字符串值集合/顺序不符（值改了 = 跨端语义断链）：\(actualValues)")
        #expect(actualProperties == expectedProperties, "常量属性名不符（拼错 / 漏迁移）：\(actualProperties)")

        let values = parsed.map(\.value)
        #expect(Set(values).count == values.count, "字符串值有重复：\(values)")
    }

    @Test("常量字符串值与历史字面量逐字一致（跨进程/跨端语义锚点）")
    func constantRawValuesMatchHistoricalLiterals() {
        for (value, property) in AppNotificationContract.expectedConstants {
            let matched: String
            switch property {
            case "libraryNeedsRefresh": matched = Notification.Name.libraryNeedsRefresh.rawValue
            case "playlistsChanged": matched = Notification.Name.playlistsChanged.rawValue
            case "backgroundColorChanged": matched = Notification.Name.backgroundColorChanged.rawValue
            case "libraryFolderContentChanged": matched = Notification.Name.libraryFolderContentChanged.rawValue
            case "favoritesChanged": matched = Notification.Name.favoritesChanged.rawValue
            case "qqplayerArtworkRefreshed": matched = Notification.Name.qqplayerArtworkRefreshed.rawValue
            case "navigateToArtistFromPlayer": matched = Notification.Name.navigateToArtistFromPlayer.rawValue
            case "navigateToAlbumFromPlayer": matched = Notification.Name.navigateToAlbumFromPlayer.rawValue
            case "minimizePlayer": matched = Notification.Name.minimizePlayer.rawValue
            case "carPlaySceneDidDisconnect": matched = Notification.Name.carPlaySceneDidDisconnect.rawValue
            case "navigateToPlaylist": matched = Notification.Name.navigateToPlaylist.rawValue
            case "trackFound": matched = Notification.Name.trackFound.rawValue
            case "macSettingsOpenCategory": matched = Notification.Name.macSettingsOpenCategory.rawValue
            case "libraryFoldersChanged": matched = Notification.Name.libraryFoldersChanged.rawValue
            case "qqplayerSettingsDidChange": matched = Notification.Name.qqplayerSettingsDidChange.rawValue
            case "libraryScanCriteriaChanged": matched = Notification.Name.libraryScanCriteriaChanged.rawValue
            case "libraryImportFinished": matched = Notification.Name.libraryImportFinished.rawValue
            case "macSyncDevicesChanged": matched = Notification.Name.macSyncDevicesChanged.rawValue
            default:
                Issue.record("契约清单里出现了未登记的常量：\(property)")
                continue
            }
            #expect(matched == value, ".\(property) 的字符串值应为 \"\(value)\"，实际 \"\(matched)\"")
        }
    }

    @Test("每个常量都有 post 点与订阅点（专治死事件：谁没有谁红）")
    func everyConstantHasBothPostAndSubscription() {
        let files = AppNotificationContract.appSourceFiles(repoRoot: Self.repoRoot)
        let code = Self.strippedAppCode(files)
        let gaps = AppNotificationContract.shapeGaps(in: code, constants: Self.constantNames)
        #expect(gaps.isEmpty, "形状缺口（0 订阅方的广播 / 0 发送方的订阅）：\n\(gaps.joined(separator: "\n"))")
    }

    @Test("死事件已删：PlayerStateChanged / PlayerSeekFailed 不再出现在 App 源码里")
    func retiredEventsAreGone() {
        let files = AppNotificationContract.appSourceFiles(repoRoot: Self.repoRoot)
        let code = Self.strippedAppCode(files)
        var lingering: [String] = []
        for value in AppNotificationContract.retiredValues {
            let hits = AppNotificationContract.occurrences(of: "\"\(value)\"", in: code)
            if hits > 0 { lingering.append("\(value)（仍出现 \(hits) 次）") }
        }
        #expect(lingering.isEmpty, "死事件残留：\(lingering)")

        let entrySource = (try? String(contentsOf: Self.entryFileURL, encoding: .utf8)) ?? ""
        let defined = AppNotificationContract.parseConstants(source: entrySource).map(\.value)
        for value in AppNotificationContract.retiredValues {
            #expect(!defined.contains(value), "死事件不应有常量：\(value)")
        }
    }

    @Test("白名单没有腐烂：每条都还在真实源码里命中")
    func whitelistEntriesAreAllLive() {
        let files = AppNotificationContract.appSourceFiles(repoRoot: Self.repoRoot)
        let rules = [AppNotificationContract.literalRule]
        let result = Self.scanFiles(files, rules: rules)
        let expected = rules.flatMap { rule in rule.whitelist.indices.map { "\(rule.name)|\($0)" } }
        let dead = expected.filter { !result.hits.contains($0) }
        #expect(dead.isEmpty, "白名单条目已不再命中（代码改了 → 条目要同步删/改）：\n\(dead.joined(separator: "\n"))")
    }
}
