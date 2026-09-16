//
//  PlaybackOrderIconContractTests.swift
//  QQPlayerTests
//
//  播放顺序四态图标「唯一入口」形状契约（2026-09-16 立）。
//
//  背景：同一个语义（顺序/随机/循环列表/单曲循环 → SF Symbol）曾有两份实现——
//  iOS `CollapsiblePlayerControls.playOrderIcon`（08-29 建）与 Mac `MacPlayerView.playOrderIcon`
//  （09-01 建），**且只有顺序态取值不同**（`arrow.clockwise` vs `arrow.right.to.line`）。
//  09-16 iOS + CarPlay 收敛到 `PlaybackOrderMode.systemImageName` 时 Mac 没跟，差异就此固化。
//  这类问题**测行为测不到**（两份实现各自都对、各自都能出图），只能用静态形状契约兜住。
//
//  决策记录（2026-09-16 用户拍板）：统一用共享入口现行的 `arrow.clockwise`。
//  Mac 那份 `arrow.right.to.line` 经查不是「刻意保留的平台差异」：写它时共享入口还不存在，
//  其余三态与 iOS 逐字相同、仅顺序态不同，且没有任何注释/文档/测试记录理由
//  = 未记录的一次性偏差。故选「拉齐取值、保留一份实现」，而不是「让差异显式化」。
//
//  设计要点（照 DisplayScriptContractTests / UIAccentContractTests 的写法）：
//  - 扫描规则 + 白名单收敛在纯函数 `PlaybackOrderIconContract.scan(source:filePath:rules:)`，
//    **不碰文件系统** → 测试里能用合成源码自证「能抓到违规」（防契约空转）。
//  - 白名单 fail-closed：没列出的映射一律算违规；另有单独用例断言「每条白名单条目都还在真实源码里命中」
//    （防白名单腐烂）。
//  - 注释行不计（文档/说明里出现反例写法不该判违规）。
//  - 除「禁止第二份实现」外，还有一条**消费点接上唯一入口**的形状断言：三个端
//    （iOS 播放页 / CarPlay 页头 / Mac 播放条）都必须引用 `.systemImageName`。
//

import Foundation
import Testing

@testable import QQPlayer

// SCAN-BEGIN —— 以下到 SCAN-END 之间是纯逻辑（只用 Foundation 字符串 API，不碰文件系统）

enum PlaybackOrderIconContract {
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

    /// 唯一入口所在文件（所有规则的唯一白名单目标）
    static let entryFile = "QQPlayer/Services/PlaybackModels.swift"

    /// 规则 1：**第二份图标 switch** 不得存在。
    /// 形态锚在「对 `.sequential` 直接返回字符串字面量」——这是一份映射表的最小特征，
    /// 挂在哪个视图里都一样抓得到（Mac 历史那份正是此形态）。
    /// 刻意**不写**宽匹配（如「文件里同时出现 shuffle + repeat.1」）：播放顺序**标题** switch
    /// （返回 `Localized.*`）、卡拉OK条的 `Image(systemName: "repeat")` 都是合法用途，
    /// 宽匹配会把它们误判成第二份映射。
    static let secondMappingSwitchRule = Rule(
        name: "播放顺序图标映射只有一处实现（PlaybackOrderMode.systemImageName），视图不得再自建 switch",
        pattern: #"case \.sequential:\s*return\s*""#,
        whitelist: [
            WhitelistEntry(
                fileSuffix: entryFile,
                lineSnippet: #"case .sequential: return "arrow.clockwise""#,
                reason: "唯一入口本身（iOS 播放页 / CarPlay 页头 / Mac 播放条三处共用）"
            ),
        ]
    )

    /// 规则 2：Mac 历史那个「顺序态第二符号」不得复活。
    /// 这条是本次统一的**决策留痕**：顺序态二选一已拍板（`arrow.clockwise`），
    /// 不存在「Mac 单独用另一个」的例外；它再出现即说明又开了一份映射。
    static let retiredSequentialGlyphRule = Rule(
        name: "顺序态不得再用第二符号 arrow.right.to.line（已统一为共享入口的 arrow.clockwise）",
        pattern: #"arrow\.right\.to\.line"#,
        whitelist: []
    )

    /// 规则 3：单曲循环符号 `repeat.1` 只属于唯一入口。
    /// 它是这张表里最独占的字面量（全仓别处没有合法用途）→ 照抄这张表的人一定会带上它；
    /// 而 `"shuffle"` / `"repeat"` 在播放列表/卡拉OK条有合法命中，不能拿来做判据。
    static let mappingLiteralRule = Rule(
        name: "单曲循环符号 repeat.1 只允许出现在唯一入口里",
        pattern: #""repeat\.1""#,
        whitelist: [
            WhitelistEntry(
                fileSuffix: entryFile,
                lineSnippet: #"case .repeatOne: return "repeat.1""#,
                reason: "唯一入口本身"
            ),
        ]
    )

    /// 全部规则（扫描真实源码用）：新增规则必须登记到这里，否则它只服务合成用例、守卫空转
    static let allRules = [secondMappingSwitchRule, retiredSequentialGlyphRule, mappingLiteralRule]

    /// 三个消费点（形状断言：每端都必须接上唯一入口，而不是自己画一份）
    /// - iOS 播放页：`CollapsiblePlayerControls.playOrderIcon`
    /// - CarPlay 页头：`CarPlay+PlayerPage` 取图标
    /// - Mac 播放条：`MacPlayerView.playOrderIcon`
    static let consumptionPoints = [
        "QQPlayer/Views/Player/CollapsiblePlayerControls.swift",
        "QQPlayer/CarPlay+PlayerPage.swift",
        "QQPlayer/Mac/MacPlayerView.swift",
    ]

    /// 一次扫描的结果
    struct Report {
        var scannedLines = 0
        /// 命中过禁止模式的行数（>0 说明规则确实在匹配真实代码，不是空转）
        var forbiddenLines = 0
        /// 违规行描述：`路径:行号: 行内容 → 违反 <规则名>`
        var violations: [String] = []
        /// 命中的白名单下标（白名单腐烂检测用）
        var whitelistHits: Set<String> = []
    }

    /// 纯函数扫描：源码文本 → 违规列表（不读文件系统，便于合成源码单测）
    static func scan(source: String, filePath: String, rules: [Rule]) -> Report {
        var report = Report()
        for (index, line) in source.components(separatedBy: .newlines).enumerated() {
            report.scannedLines += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 注释不是代码（文档里出现反例写法不该判违规）
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }

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
                report.violations.append(
                    "\(filePath):\(index + 1): \(trimmed)  → 违反「\(rule.name)」"
                )
            }
        }
        return report
    }
}

// SCAN-END

extension PlaybackOrderIconContract {
    /// App 源码（不含测试：测试里会出现「反例写法」字符串，不该自判）
    static func appSourceFiles(repoRoot: URL) -> [URL] {
        var result: [URL] = []
        let fileManager = FileManager.default
        let base = repoRoot.appendingPathComponent("QQPlayer")
        guard let enumerator = fileManager.enumerator(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }
}

// MARK: - 测试

struct PlaybackOrderIconContractTests {
    /// 仓库根：本文件位于 <repo>/QQPlayerTests/ 下 → 上两级
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
    }

    static func scanFiles(
        _ urls: [URL],
        rules: [PlaybackOrderIconContract.Rule]
    ) -> (violations: [String], forbiddenLines: Int, hits: Set<String>) {
        var violations: [String] = []
        var forbiddenLines = 0
        var hits: Set<String> = []
        for file in urls {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let report = PlaybackOrderIconContract.scan(source: source, filePath: Self.relativePath(file), rules: rules)
            violations.append(contentsOf: report.violations)
            forbiddenLines += report.forbiddenLines
            hits.formUnion(report.whitelistHits)
        }
        return (violations, forbiddenLines, hits)
    }

    /// 命中某正则的代码行（注释行不计）
    static func linesContaining(_ pattern: String, in urls: [URL]) -> [String] {
        var result: [String] = []
        for file in urls {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let relative = Self.relativePath(file)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }
                if line.range(of: pattern, options: .regularExpression) != nil {
                    result.append("\(relative):\(index + 1): \(trimmed)")
                }
            }
        }
        return result
    }

    // MARK: 地基检查

    @Test("仓库根与扫描范围解析正确（扫描前的地基检查）")
    func scanScopeResolves() {
        let marker = Self.repoRoot.appendingPathComponent(PlaybackOrderIconContract.entryFile)
        #expect(FileManager.default.fileExists(atPath: marker.path), "仓库根解析错了：\(Self.repoRoot.path)")

        let files = PlaybackOrderIconContract.appSourceFiles(repoRoot: Self.repoRoot)
        #expect(files.count >= 200, "App 源码扫描范围文件数异常：\(files.count)")
        for point in PlaybackOrderIconContract.consumptionPoints {
            let url = Self.repoRoot.appendingPathComponent(point)
            #expect(FileManager.default.fileExists(atPath: url.path), "消费点文件不存在（改名了要同步改契约）：\(point)")
        }
    }

    // MARK: 契约自证有效（合成源码）

    @Test("合成违规源码必须被抓到（契约自证有效的关键用例）")
    func syntheticViolationsAreCaught() {
        // 第二份 switch（Mac 历史那份的形态，只是把取值换成别的）
        let macHistoricalSwitch = [
            "import SwiftUI",
            "struct V: View {",
            "    private var playOrderIcon: String {",
            "        switch playOrderMode {",
            "        case .sequential: return \"arrow.right.to.line\"",
            "        case .shuffle: return \"shuffle\"",
            "        case .repeatAll: return \"repeat\"",
            "        case .repeatOne: return \"repeat.1\"",
            "        }",
            "    }",
            "}",
        ].joined(separator: "\n")
        let switchReport = PlaybackOrderIconContract.scan(
            source: macHistoricalSwitch,
            filePath: "QQPlayer/Mac/MacTmp.swift",
            rules: PlaybackOrderIconContract.allRules
        )
        #expect(switchReport.violations.count >= 2, "第二份 switch 应被规则 1/2/3 抓到，实际：\(switchReport.violations)")
        #expect(switchReport.violations.contains { $0.contains("MacTmp.swift:5:") && $0.contains("播放顺序图标映射只有一处实现") },
                "违规行应带行号+规则名：\(switchReport.violations)")

        // 只复活旧符号、不写 switch（改成一个字典 / 三元）也要抓到
        let retiredGlyphOnly = #"    let icon = mode == .sequential ? "arrow.right.to.line" : "shuffle""#
        let glyphReport = PlaybackOrderIconContract.scan(
            source: retiredGlyphOnly,
            filePath: "QQPlayer/Views/Player/Tmp.swift",
            rules: PlaybackOrderIconContract.allRules
        )
        #expect(glyphReport.violations.count == 1, "旧顺序符号应被抓到，实际：\(glyphReport.violations)")

        // 唯一入口那两行在**别的文件里**不享受白名单
        let copiedEntryLines = [
            #"    case .sequential: return "arrow.clockwise""#,
            #"    case .repeatOne: return "repeat.1""#,
        ].joined(separator: "\n")
        let copiedReport = PlaybackOrderIconContract.scan(
            source: copiedEntryLines,
            filePath: "QQPlayer/Views/Player/Tmp.swift",
            rules: PlaybackOrderIconContract.allRules
        )
        #expect(copiedReport.violations.count == 2, "白名单只认唯一入口文件，别处照抄应被抓住：\(copiedReport.violations)")
    }

    @Test("合成合法源码不报（唯一入口 / 标题 switch / 卡拉OK条 / 注释反例）")
    func syntheticLegalSourceIsClean() {
        let entrySource = [
            "enum PlaybackOrderMode {",
            "    var systemImageName: String {",
            "        switch self {",
            #"        case .sequential: return "arrow.clockwise""#,
            #"        case .shuffle: return "shuffle""#,
            #"        case .repeatAll: return "repeat""#,
            #"        case .repeatOne: return "repeat.1""#,
            "        }",
            "    }",
            "}",
        ].joined(separator: "\n")
        let entryReport = PlaybackOrderIconContract.scan(
            source: entrySource,
            filePath: PlaybackOrderIconContract.entryFile,
            rules: PlaybackOrderIconContract.allRules
        )
        #expect(entryReport.violations.isEmpty, "唯一入口本身不得被判违规：\(entryReport.violations)")
        #expect(entryReport.whitelistHits.count == 2, "两条白名单都该命中：\(entryReport.whitelistHits)")

        let viewSource = [
            "import SwiftUI",
            "struct V: View {",
            "    private var playOrderIcon: String { playOrderMode.systemImageName }",
            "    private var playOrderTitle: String {",
            "        switch playOrderMode {",
            "        case .sequential: return Localized.playOrderSequential",
            "        case .shuffle: return Localized.playOrderShuffle",
            "        default: return \"\"",
            "        }",
            "    }",
            "    var body: some View {",
            "        Image(systemName: \"repeat\")   // 卡拉OK条：重复段落，与播放顺序无关",
            "        Image(systemName: \"shuffle\")  // 歌单「随机播放全部」按钮",
            "        // 反例说明：不要写 case .sequential: return \"arrow.right.to.line\"",
            "        /// 反例说明：顺序态不再用 arrow.right.to.line，也不要再抄 \"repeat.1\"",
            "    }",
            "}",
        ].joined(separator: "\n")
        let viewReport = PlaybackOrderIconContract.scan(
            source: viewSource,
            filePath: "QQPlayer/Views/Player/Tmp.swift",
            rules: PlaybackOrderIconContract.allRules
        )
        #expect(viewReport.violations.isEmpty, "合法消费点/标题 switch/注释反例不得误报：\(viewReport.violations)")
    }

    // MARK: 真实源码扫描

    @Test("播放顺序图标映射只有一处实现（视图不得自建 switch / 旧符号不得复活）")
    func iconMappingIsSingleSourced() {
        let files = PlaybackOrderIconContract.appSourceFiles(repoRoot: Self.repoRoot)
        let result = Self.scanFiles(files, rules: PlaybackOrderIconContract.allRules)
        #expect(result.forbiddenLines > 0, "扫描没匹配到任何映射行 = 规则空转（模式或路径写错了）")
        #expect(result.violations.isEmpty,
                "出现第二份图标映射（改走 PlaybackOrderMode.systemImageName）：\n\(result.violations.joined(separator: "\n"))")
    }

    @Test("三个消费点都接上唯一入口（形状：没人自己画一份）")
    func allConsumptionPointsUseTheSharedEntry() {
        for point in PlaybackOrderIconContract.consumptionPoints {
            let url = Self.repoRoot.appendingPathComponent(point)
            let lines = Self.linesContaining(#"\.systemImageName"#, in: [url])
            #expect(!lines.isEmpty, "\(point) 没有引用 .systemImageName（播放顺序图标必须走唯一入口）：\(lines)")
        }
    }

    @Test("四态图标都由唯一入口给出（四态齐全且互不相同）")
    func theSharedEntryCoversAllFourModes() {
        // 与 CarPlay 页头那条断言同源：这里再锁一次「入口本身四态齐全」，
        // 防的是「把某个端从入口摘掉、自己补一个 case」时入口悄悄退化成三态。
        let icons = PlaybackOrderMode.allCases.map(\.systemImageName)
        #expect(icons.count == 4, "播放顺序必须仍是四态：\(icons)")
        #expect(Set(icons).count == icons.count, "四态图标必须互不相同：\(icons)")

        let byMode = Dictionary(uniqueKeysWithValues: PlaybackOrderMode.allCases.map { ($0, $0.systemImageName) })
        #expect(byMode[.sequential] == "arrow.clockwise",
                "顺序态取值是 2026-09-16 拍板的统一值：\(byMode[.sequential] ?? "nil")")
    }

    @Test("白名单没有腐烂：每条都还在真实源码里命中")
    func whitelistEntriesAreAllLive() {
        let files = PlaybackOrderIconContract.appSourceFiles(repoRoot: Self.repoRoot)
        let result = Self.scanFiles(files, rules: PlaybackOrderIconContract.allRules)
        let expected = PlaybackOrderIconContract.allRules.flatMap { rule in
            rule.whitelist.indices.map { "\(rule.name)|\($0)" }
        }
        let dead = expected.filter { !result.hits.contains($0) }
        #expect(dead.isEmpty, "白名单条目已不再命中（代码改了 → 条目要同步删/改）：\n\(dead.joined(separator: "\n"))")
    }
}
