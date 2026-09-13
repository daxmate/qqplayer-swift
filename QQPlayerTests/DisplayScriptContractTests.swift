//
//  DisplayScriptContractTests.swift
//  QQPlayerTests
//
//  显示层简繁字形归一的「防裸用」契约测试（2026-09-13 立）。
//
//  背景：显示层归一的唯一入口是 DisplayScriptNormalizer（模型侧是 Track.displayTitle /
//  Album.displayTitle / LyricsLine.displayText / displayTranslation）。只要有人在渲染路径里
//  直接写 Text(track.title)，繁/简 UI 就会显示错字形——这类问题单测很难覆盖，故用静态契约兜住：
//  新代码再想裸用原始字段，这里就红。
//
//  设计要点：
//  - 扫描规则 + 白名单全部收敛在纯函数 DisplayScriptContract.scan(source:filePath:)，
//    **不碰文件系统** → 测试里能用合成源码自证「能抓到违规」（防止契约本身空转）。
//  - 白名单 fail-closed：没列出的裸用一律算违规。每条 = 文件路径尾段 + 行内容片段 + 理由，
//    并有单独测试断言「每条白名单都还在真实源码里命中」，防止白名单腐烂（代码改了条目没删）。
//  - 扫描范围 = 渲染路径 + Siri 入口（2026-09-13 扩展）：
//    QQPlayer/Views/**、QQPlayer/Mac/**、QQPlayer/AppIntents/**、SiriIntentsExtension/**。
//    Siri 消歧卡片（INMediaItem）、AppIntents 卡片与对话、实体 → 展示字段走显示字形；
//    而 **实体 schema 属性 / Spotlight 索引 / 匹配 / 查询 / SQL / 诊断日志** 一律保持原文
//    （保住跨字形可搜性），这些位置逐条进白名单并写明理由。
//    Share / PlayerWidget 仍未纳入（无歌名显示 / 写入点已归一）。
//

import Foundation
import Testing

@testable import QQPlayer

// SCAN-BEGIN —— 以下到 SCAN-END 之间是纯逻辑（只用 Foundation 字符串 API，不碰文件系统），
// 可整体抽出来用 swiftc 单独编译运行，用于在没有模拟器的环境里先验证扫描规则本身。
enum DisplayScriptContract {
    /// 白名单条目：文件路径尾段 + 行内容片段 + 理由（理由必写明「为什么这里不是显示路径」）
    struct WhitelistEntry {
        let fileSuffix: String
        let lineSnippet: String
        let reason: String
    }

    /// 禁止裸用的原始字段访问器：出现在渲染路径里 = 违规
    /// （除非命中白名单，或该处已被 DisplayScriptNormalizer 包裹）。
    /// 只收「歌曲文本 / 专辑名 / 歌词」这类会被渲染出来的原始数据字段。
    static let forbiddenAccessors = [
        "track.title",
        "currentTrack.title",
        "album.title",
        "track.genre",
        "line.text",
        "line.translation",
        "candidate.title",
        "candidate.artist",
    ]

    /// 合法例外（fail-closed：不在这里的裸用一律违规）。
    /// 这些行虽然出现原始字段，但不是「把字形渲染给用户看」，转字形反而有害。
    static let whitelist: [WhitelistEntry] = [
        // 查询串：搜索框初值同时是发给网易云/lrclib 的查询字面量，显示值≠查询值
        WhitelistEntry(fileSuffix: "QQPlayer/Views/Player/LyricsSearchView.swift", lineSnippet: "_searchTitle = State(initialValue: track.title)", reason: "搜索框初值 = 发给网易云/lrclib 的查询串（转字形会降低命中率），不是显示值"),
        WhitelistEntry(fileSuffix: "QQPlayer/Mac/MacLyricsSearchView.swift", lineSnippet: "_searchTitle = State(initialValue: track.title)", reason: "同上：macOS 歌词搜索的查询串初值"),
        // 判空守卫：候选行的空判断，随后同一字段才经 display(...) 渲染
        WhitelistEntry(fileSuffix: "QQPlayer/Views/Player/LyricsSearchView.swift", lineSnippet: "if !candidate.artist.isEmpty", reason: "候选行判空守卫（下一行才 display 渲染），不是显示值"),
        WhitelistEntry(fileSuffix: "QQPlayer/Mac/MacLyricsSearchView.swift", lineSnippet: "if !candidate.artist.isEmpty", reason: "同上：macOS 候选行判空守卫"),
        // 表单值 / 落库值：标签编辑器里这些字符串会原样写回 DB，不能按显示字形改
        WhitelistEntry(fileSuffix: "QQPlayer/Mac/MacTagEditorView.swift", lineSnippet: "formTitle = candidate.title", reason: "标签编辑器表单值（随后写回 DB，不能转字形）"),
        WhitelistEntry(fileSuffix: "QQPlayer/Mac/MacTagEditorView.swift", lineSnippet: "formArtist = candidate.artist", reason: "标签编辑器表单值（随后写回 DB，不能转字形）"),
        // 非界面文本：刮削/重命名模板的样本值（渲染成文件名，不是给用户读的界面文案）
        WhitelistEntry(fileSuffix: "QQPlayer/Mac/MacScrapeSettingsView.swift", lineSnippet: "let title = track.title.trimmingCharacters", reason: "重命名模板/刮削样本值（文件名渲染输入，非界面文本）"),
        WhitelistEntry(fileSuffix: "QQPlayer/Mac/MacScrapeSettingsView.swift", lineSnippet: "albumTitle = album.title", reason: "同上：重命名模板样本值"),
        // 先绑定局部变量、渲染的是 display 后的值
        WhitelistEntry(fileSuffix: "QQPlayer/Mac/MacTagEditorCandidateRow.swift", lineSnippet: "if let artist = candidate.artist", reason: "绑定局部变量后交给 DisplayScriptNormalizer.display(artist) 渲染，原值不直接显示"),
        // 排序 key：Table 列排序用的 @objc 存储属性，单元格实际渲染 row.track.displayTitle
        WhitelistEntry(fileSuffix: "QQPlayer/Mac/MacTrackListView.swift", lineSnippet: "self.title = track.title", reason: "Table 排序列值（单元格渲染走 row.track.displayTitle）"),
        // 传输载荷：跨端同步的字段，属于数据不是显示
        WhitelistEntry(fileSuffix: "QQPlayer/Mac/MacSyncLocalContentProvider.swift", lineSnippet: "title: track.title,", reason: "同步载荷字段（跨端传输数据，非显示）"),

        // ── 2026-09-13 新增扫描范围（QQPlayer/AppIntents + SiriIntentsExtension）：显示层之外的例外 ──
        // 判据：出现在渲染/对话里才是显示；索引、匹配、查询、排序、落库、诊断日志一律保持原文。
        WhitelistEntry(fileSuffix: "QQPlayer/AppIntents/Entities/SongEntity.swift", lineSnippet: "            title = track.title", reason: "实体 schema 属性：indexAppEntities 索引进 Spotlight，Siri 按名解析/跨字形可搜，保持原文"),
        WhitelistEntry(fileSuffix: "QQPlayer/AppIntents/Entities/AlbumEntity.swift", lineSnippet: "            title = album.title", reason: "同上：专辑实体 schema 属性（Spotlight 索引 + 实体解析），保持原文"),
        WhitelistEntry(fileSuffix: "QQPlayer/AppIntents/Entities/AudioEntity.swift", lineSnippet: "                album.title", reason: "union value 的标题聚合（与实体属性同源，供实体解析语境）；本包内无显示消费点，保持原文"),
        WhitelistEntry(fileSuffix: "QQPlayer/AppIntents/FoundationModels/MixGenerator.swift", lineSnippet: "                try database.getAllAlbums().compactMap { album in album.id.map { ($0, album.title) } },", reason: "LLM 提示词/候选集构建（语义匹配输入，非显示）"),
        WhitelistEntry(fileSuffix: "QQPlayer/AppIntents/FoundationModels/MixGenerator.swift", lineSnippet: "            var parts = [track.title]", reason: "同上：describe() 拼匹配用 haystack（lowercased 后参与匹配）"),
        WhitelistEntry(fileSuffix: "SiriIntentsExtension/IntentHandler.swift", lineSnippet: "                       track.title,", reason: "SQL 投影列：SELECT 读原文供打分/排序，不是显示值"),
        WhitelistEntry(fileSuffix: "SiriIntentsExtension/IntentHandler.swift", lineSnippet: "                       album.title AS album_title", reason: "同上：SQL 投影列（album.title AS album_title）"),
        WhitelistEntry(fileSuffix: "SiriIntentsExtension/IntentHandler.swift", lineSnippet: "                ORDER BY track.title", reason: "SQL ORDER BY：列表排序键"),
        WhitelistEntry(fileSuffix: "SiriIntentsExtension/IntentHandler.swift", lineSnippet: "                    let metadata = [track.title, track.artistName, track.albumTitle]", reason: "打分用元数据拼接（匹配输入）"),
        WhitelistEntry(fileSuffix: "SiriIntentsExtension/IntentHandler.swift", lineSnippet: "                        query.siriSearchScore(against: track.title),", reason: "siriSearchScore 打分（匹配）"),
        WhitelistEntry(fileSuffix: "SiriIntentsExtension/IntentHandler.swift", lineSnippet: "                    return $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending", reason: "同分时的字母序 tie-break（排序）"),
        WhitelistEntry(fileSuffix: "SiriIntentsExtension/IntentHandler.swift", lineSnippet: "                return \"\\(index): title=\\(track.title) | artist=\\(track.artistName ?? \"unknown\") | album=\\(track.albumTitle ?? \"unknown\")\"", reason: "LLM 候选清单文本（语义匹配输入）"),
        WhitelistEntry(fileSuffix: "SiriIntentsExtension/IntentHandler.swift", lineSnippet: "            SiriDiag.log(\"EXT LLM matched query=\\(query) index=\\(index) title=\\(shortlist[index].track.title)\")", reason: "SiriDiag 诊断日志（匹配透明度用，不是界面文案）"),

    ]

    /// 一次扫描的结果
    struct Report {
        /// 扫过的总行数
        var scannedLines = 0
        /// 命中过禁止访问器的行数（>0 说明规则确实在匹配真实代码，不是空转）
        var accessorLines = 0
        /// 违规行描述：`路径:行号: 行内容 → 裸用 xxx`
        var violations: [String] = []
        /// 命中的白名单下标（白名单腐烂检测用）
        var whitelistHits: Set<Int> = []
    }

    /// 纯函数扫描：输入文件源码文本 → 违规列表（不读文件系统，便于合成源码单测）
    static func scan(source: String, filePath: String) -> Report {
        var report = Report()
        for (index, line) in source.components(separatedBy: .newlines).enumerated() {
            report.scannedLines += 1
            // 注释行不是渲染路径（文档里出现反例写法不该判违规）
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }

            let matched = forbiddenAccessors.filter { line.contains($0) }
            guard !matched.isEmpty else { continue }
            report.accessorLines += 1

            // 白名单：整行命中即豁免（fileSuffix + lineSnippet 同时匹配才算）
            if let hit = whitelist.firstIndex(where: { filePath.hasSuffix($0.fileSuffix) && line.contains($0.lineSnippet) }) {
                report.whitelistHits.insert(hit)
                continue
            }

            let naked = matched.filter { !isDisplayWrapped($0, in: line) }
            guard !naked.isEmpty else { continue }
            report.violations.append("\(filePath):\(index + 1): \(trimmed)  → 裸用 \(naked.joined(separator: " / "))")
        }
        return report
    }

    /// 只要违规行文本（对外主入口）
    static func violations(inSource source: String, filePath: String) -> [String] {
        scan(source: source, filePath: filePath).violations
    }

    /// 该访问器在行内的**每一处**是否都被 display 入口包裹：
    ///   `DisplayScriptNormalizer.display(track.title)` / `display(track.title)`
    ///   `candidate.title.map(DisplayScriptNormalizer.display)`（Optional 映射写法）
    /// 只要有一处没包裹就返回 false（同一行混写也不会漏判）。
    private static func isDisplayWrapped(_ accessor: String, in line: String) -> Bool {
        var searchStart = line.startIndex
        var found = false
        while let range = line.range(of: accessor, range: searchStart ..< line.endIndex) {
            found = true
            let prefix = line[line.startIndex ..< range.lowerBound].trimmingCharacters(in: .whitespaces)
            let suffix = String(line[range.upperBound...])
            let wrappedByCall = prefix.hasSuffix("display(")
            let wrappedByMap = suffix.hasPrefix(".map(DisplayScriptNormalizer.display)")
                || suffix.hasPrefix(".map(display)")
            if !wrappedByCall, !wrappedByMap { return false }
            searchStart = range.upperBound
        }
        return found
    }
}

// SCAN-END

extension DisplayScriptContract {
    /// 渲染路径下的所有 .swift（递归；文件系统访问只在这个辅助函数里，核心扫描保持纯净）
    static func renderPathSwiftFiles(repoRoot: URL) -> [URL] {
        let roots = ["QQPlayer/Views", "QQPlayer/Mac", "QQPlayer/AppIntents", "SiriIntentsExtension"]
        var result: [URL] = []
        let fileManager = FileManager.default
        for root in roots {
            let base = repoRoot.appendingPathComponent(root)
            guard let enumerator = fileManager.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}

// MARK: - 测试

struct DisplayScriptContractTests {
    /// 仓库根：本文件位于 <repo>/QQPlayerTests/ 下 → 上两级
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let renderPathFiles = DisplayScriptContract.renderPathSwiftFiles(repoRoot: repoRoot)

    static func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
    }

    // MARK: 地基检查

    @Test("仓库根与扫描范围解析正确（扫描前的地基检查）")
    func scanScopeResolves() {
        let marker = Self.repoRoot.appendingPathComponent("QQPlayer/Services/DisplayScriptNormalizer.swift")
        #expect(FileManager.default.fileExists(atPath: marker.path), "仓库根解析错了：\(Self.repoRoot.path)")
        #expect(Self.renderPathFiles.count >= 80, "渲染路径 swift 文件数异常：\(Self.renderPathFiles.count)")
    }

    // MARK: 契约自证有效（合成源码）

    @Test("合成违规源码必须被抓到（契约测试自证有效的关键用例）")
    func syntheticViolationsAreCaught() {
        let cases = [
            "Text(track.title)",
            "Text(currentTrack.title)",
            "Text(album.title)",
            "Text(track.genre)",
            "Text(line.text)",
            "Text(line.translation ?? \"\")",
            "Text(candidate.title)",
            "Text(candidate.artist)",
            "        .navigationTitle(track.title)",
        ]
        for snippet in cases {
            let source = [
                "import SwiftUI",
                "",
                "struct V: View {",
                "    var body: some View {",
                snippet,
                "    }",
                "}",
            ].joined(separator: "\n")
            let violations = DisplayScriptContract.violations(inSource: source, filePath: "QQPlayer/Views/Tmp.swift")
            #expect(violations.count == 1, "\(snippet) 应被抓到，实际：\(violations)")
            #expect(violations.first?.contains("QQPlayer/Views/Tmp.swift:5:") == true, "违规行应带行号：\(violations)")
        }
    }

    @Test("同一行里包裹与裸用混写：裸用那处仍要报（按处判定，不是按行）")
    func mixedWrappedAndNakedOnSameLine() {
        let line = "let a = DisplayScriptNormalizer.display(track.title); let b = track.title"
        let violations = DisplayScriptContract.violations(inSource: line, filePath: "QQPlayer/Views/Tmp.swift")
        #expect(violations.count == 1, "\(violations)")
    }

    @Test("合成合法源码不报（display 属性 / display 包裹 / 字体 / 用户数据 / 注释）")
    func syntheticLegalSourceIsClean() {
        let source = [
            "Text(track.displayTitle)",
            "Text(row.track.displayTitle)",
            "Text(album.displayTitle)",
            "Text(line.displayText)",
            "Text(line.displayTranslation ?? \"\")",
            ".font(.title2)",
            "Text(playlist.title)",
            "Text(track.artistName)",
            "Text(DisplayScriptNormalizer.display(track.title))",
            "Text(candidate.title.map(DisplayScriptNormalizer.display) ?? \"\")",
            "// 反例说明：不要写 Text(track.title)",
            "/// 反例说明：不要写 Text(track.title)",
        ].joined(separator: "\n")
        let violations = DisplayScriptContract.violations(inSource: source, filePath: "QQPlayer/Views/Tmp.swift")
        #expect(violations.isEmpty, "\(violations)")
    }

    // MARK: 真实源码扫描

    @Test("渲染路径全仓扫描：无裸用（有残留这里会红，见输出）")
    func renderPathHasNoNakedUsage() {
        var violations: [String] = []
        var accessorLines = 0
        for file in Self.renderPathFiles {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let report = DisplayScriptContract.scan(source: source, filePath: Self.relativePath(file))
            violations.append(contentsOf: report.violations)
            accessorLines += report.accessorLines
        }
        #expect(accessorLines > 0, "扫描没匹配到任何访问器 = 规则空转（模式或路径写错了）")
        #expect(violations.isEmpty, "渲染路径出现裸用原始字段（改走 display 入口，或补白名单说明理由）：\n\(violations.joined(separator: "\n"))")
    }

    @Test("白名单没有腐烂：每条都还在真实源码里命中")
    func whitelistEntriesAreAllLive() {
        var hits: Set<Int> = []
        for file in Self.renderPathFiles {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            hits.formUnion(DisplayScriptContract.scan(source: source, filePath: Self.relativePath(file)).whitelistHits)
        }
        let dead = DisplayScriptContract.whitelist.indices
            .filter { !hits.contains($0) }
            .map { "\($0): \(DisplayScriptContract.whitelist[$0].fileSuffix) | \(DisplayScriptContract.whitelist[$0].lineSnippet)" }
        #expect(dead.isEmpty, "白名单条目已不再命中（代码改了 → 条目要同步删/改）：\n\(dead.joined(separator: "\n"))")
    }
}
