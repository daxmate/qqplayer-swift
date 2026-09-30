//
//  MacTrackListViewPlaylistMenuContractTests.swift
//  QQPlayerTests
//
//  「曲目列表右键 → 添加到歌单」菜单的形状契约（2026-09-30）。
//
//  收口的语义：macOS 曲目列表（含歌单详情）右键菜单里的「添加到歌单」，**菜单内容只有一份实现**
//  —— MacTrackListView 的共享 builder `addToPlaylistMenu(for:)`；单选右键与多选右键都只是它的调用点。
//  为什么要有契约：多选分支最省力的写法就是再抄一遍 `ForEach(playlists)…`，两处会各自漂移
//  （新建歌单流程 / post 次数 / 逐首 vs 整批）。故把「只有一份」做成 CI 红灯。
//
//  ⚠️ 与任务包 v1 §3B「契约 1」的**实测差异**（本测试按实测事实登记，未改动 iOS 端）：
//     · 任务包写的白名单 = 只含 `QQPlayer/Mac/MacTrackListView.swift`；实测 `Localized.addToPlaylist`
//       在本批**不改动的 iOS 端**已有 4 处既有使用（见 `titleTokenWhitelist`，grep 实证），
//       故白名单按其真实归属登记为 5 个文件，Contract 1 的核心判据改为
//       「共享 builder 声明全仓唯一 + Mac 生产目录里标题 token 只此一文件」。
//     · MacTrackListView.swift 内该 token 由重构前的 1 处（`Menu("add_to_playlist".localized)`）
//       变为 2 处（单选 + 多选各一个 Menu 标题），故计数断言取 2（理由见 `menuTitleOccurrencesInMacTrackList`）。
//
//  判据全部走静态扫描（源码文本 + 注释/字符串剥离），无需模拟器即可**编译**；
//  但 Swift Testing 用例的**执行**只发生在 CI 的模拟器上（本地只做编译级验证）。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 扫描器

private enum PlaylistMenuShapeContract {
    /// 本批唯一改动的生产文件（相对仓库根）。
    static let macTrackListView = "QQPlayer/Mac/MacTrackListView.swift"

    /// 菜单标题 token（必须按**独立标识符**计数：`Localized.addToPlaylistEllipsis` 不算）。
    static let menuTitleToken = "Localized.addToPlaylist"

    /// 重构前 Mac 端用的裸字面量标题（收口后不得再出现）。
    static let legacyRawMenuTitle = "\"add_to_playlist\".localized"

    /// 共享 builder 的标识 token（全仓唯一）。
    static let builderToken = "addToPlaylistMenu"
    /// 共享 builder 的**声明**前缀（只匹配 `func addToPlaylistMenu(for tracks: …)`）。
    static let builderDeclarationPrefix = "func addToPlaylistMenu(for"
    /// 共享 builder 的**调用**前缀（声明处是 `(for tracks:`，故不会与声明冲突）。
    static let builderCallPrefix = "addToPlaylistMenu(for:"

    /// 共享 builder 期望的调用点数：单选右键 1 + 多选右键 1。
    static let expectedCallSites = 2

    /// MacTrackListView.swift 内标题 token 的期望出现次数：单选 + 多选各一个 Menu 标题。
    static let menuTitleOccurrencesInMacTrackList = 2

    /// 允许持有「添加到歌单」标题 token 的文件（相对仓库根）。
    /// Mac 端 = 唯一实现；其余 4 个是 iOS 端**既有**使用（本批不动，登记以便「新增第二处」立刻变红）。
    static let titleTokenWhitelist: [String] = [
        "QQPlayer/Mac/MacTrackListView.swift",
        "QQPlayer/Views/Library/BulkPlaylistSelectionView.swift",
        "QQPlayer/Views/Library/TrackBulkSelection.swift",
        "QQPlayer/Views/Library/TrackListView.swift",
        "QQPlayer/Views/Playlists/PlaylistSelectionView.swift",
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

    /// 生产源码根（`QQPlayer/`）下全部 `.swift`：相对仓库根路径 + **已剥离注释/字符串**的源码。
    /// 读不出来 → throw（fail-closed，不算通过）。
    static func scannedSources() throws -> [(relativePath: String, code: String)] {
        let base: URL = repositoryRoot.appendingPathComponent("QQPlayer", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ContractError.directoryUnreadable("QQPlayer")
        }
        let prefix: String = repositoryRoot.path + "/"
        var files: [(relativePath: String, code: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let raw: String = try String(contentsOf: url, encoding: .utf8)
            let relative: String = url.path.replacingOccurrences(of: prefix, with: "")
            files.append((relative, strippingLiteralsAndComments(raw)))
        }
        return files.sorted { lhs, rhs in lhs.relativePath < rhs.relativePath }
    }

    /// 取指定相对路径文件的**已剥离**源码（不存在 → throw，红）。
    static func strippedCode(relativePath: String) throws -> String {
        strippingLiteralsAndComments(try rawCode(relativePath: relativePath))
    }

    /// 取指定相对路径文件的**原始**源码（用于「裸字面量」这类需要保留字符串的判据）。
    static func rawCode(relativePath: String) throws -> String {
        let url: URL = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // SCAN-BEGIN
    /// `token` 作为**独立标识符**出现的次数（后一字符不得是字母 / 数字 / 下划线）。
    /// 必要性：`Localized.addToPlaylist` 是 `Localized.addToPlaylistEllipsis` 的前缀，
    /// 不设边界即把「添加到歌单（椭圆）」菜单项也算进来（实测 5 处误伤）。
    static func occurrences(of token: String, in code: String) -> Int {
        var count: Int = 0
        var searchStart: String.Index = code.startIndex
        while let range = code.range(of: token, range: searchStart ..< code.endIndex) {
            let upper: String.Index = range.upperBound
            if upper == code.endIndex {
                count += 1
            } else {
                let next: Character = code[upper]
                if !(next.isLetter || next.isNumber || next == "_") { count += 1 }
            }
            searchStart = upper
        }
        return count
    }

    /// 把源码里的字符串字面量与注释整体替换成空格（换行保留 → 行号不变）。
    /// 必要性：解释性注释里会写 `addToPlaylistMenu(for:)` / `ForEach(playlists)…`，
    /// 不剥离就会把「解释」当成「实现」；字符串同理。
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

    /// 命中标题 token 的文件（相对仓库根，排序后）。
    static func filesHoldingMenuTitleToken() throws -> [String] {
        try scannedSources()
            .filter { occurrences(of: menuTitleToken, in: $0.code) > 0 }
            .map(\.relativePath)
    }
}

// MARK: - 契约

@Suite("曲目列表「添加到歌单」菜单形状契约")
struct MacTrackListViewPlaylistMenuContractTests {
    // MARK: 契约 1：共享 builder 全仓只有一处声明

    @Test("契约 1：共享 builder `addToPlaylistMenu(for:)` 全仓恰好一处声明，且在 MacTrackListView.swift")
    func sharedBuilderDeclaredExactlyOnce() throws {
        let files: [(relativePath: String, code: String)] = try PlaylistMenuShapeContract.scannedSources()
        #expect(files.count > 100, "扫到的生产源文件过少，仓库根推导可能失效：\(files.count)")

        var declaringFiles: [String] = []
        var filesMentioningBuilder: [String] = []
        for file in files {
            let declarations: Int = PlaylistMenuShapeContract.occurrences(
                of: PlaylistMenuShapeContract.builderDeclarationPrefix, in: file.code
            )
            if declarations > 0 { declaringFiles.append("\(file.relativePath) ×\(declarations)") }

            let mentions: Int = PlaylistMenuShapeContract.occurrences(
                of: PlaylistMenuShapeContract.builderToken, in: file.code
            )
            if mentions > 0 { filesMentioningBuilder.append("\(file.relativePath) ×\(mentions)") }
        }

        #expect(
            declaringFiles == ["\(PlaylistMenuShapeContract.macTrackListView) ×1"],
            "❌ 「添加到歌单」菜单 builder 必须全仓只有一处声明（唯一实现），实际：\(declaringFiles)"
        )
        #expect(
            filesMentioningBuilder == ["\(PlaylistMenuShapeContract.macTrackListView) ×3"],
            "❌ builder 只允许出现在唯一入口文件里（1 处声明 + 2 处调用），实际：\(filesMentioningBuilder)"
        )
    }

    // MARK: 契约 2：多选分支确实接入（恰好 2 处调用点）

    @Test("契约 2：共享 builder 恰好两处调用点（单选 1 + 多选 1），且都在 MacTrackListView.swift")
    func menuBuilderWiredAtExactlyTwoCallSites() throws {
        let code: String = try PlaylistMenuShapeContract.strippedCode(
            relativePath: PlaylistMenuShapeContract.macTrackListView
        )

        let declarations: Int = PlaylistMenuShapeContract.occurrences(
            of: PlaylistMenuShapeContract.builderDeclarationPrefix, in: code
        )
        let callSites: Int = PlaylistMenuShapeContract.occurrences(
            of: PlaylistMenuShapeContract.builderCallPrefix, in: code
        )
        #expect(declarations == 1, "非空转：唯一入口里必须能扫到那 1 处 builder 声明，实际：\(declarations)")
        #expect(
            callSites == PlaylistMenuShapeContract.expectedCallSites,
            """
            ❌ 「添加到歌单」共享 builder 的调用点必须恰好 \(PlaylistMenuShapeContract.expectedCallSites) 处\
            （单选右键 1 + 多选右键 1），实际：\(callSites)。
            多选分支被摘掉 / 或又冒出第三处调用，都会让这条变红。
            """
        )
    }

    // MARK: 契约 3：标题 token 白名单 + Mac 端唯一

    @Test("契约 3：`Localized.addToPlaylist` 命中文件 = 白名单，Mac 端只此一份且恰 2 处")
    func menuTitleTokenIsWhitelistedAndMacOnly() throws {
        let hits: [String] = try PlaylistMenuShapeContract.filesHoldingMenuTitleToken()
        #expect(
            hits == PlaylistMenuShapeContract.titleTokenWhitelist,
            """
            ❌ 出现白名单外的「添加到歌单」标题 token 持有者（疑似第二份实现）：\(hits)
            白名单实际期望：\(PlaylistMenuShapeContract.titleTokenWhitelist)
            """
        )

        // Mac 端只允许一个文件持有该 token（防「在别处再写一份歌单选择菜单」）。
        let macHolders: [String] = hits.filter { $0.hasPrefix("QQPlayer/Mac/") }
        #expect(
            macHolders == [PlaylistMenuShapeContract.macTrackListView],
            "❌ Mac 端「添加到歌单」标题 token 只允许出现在唯一入口文件，实际：\(macHolders)"
        )

        // 唯一入口内恰好 2 处：单选右键 + 多选右键各一个 Menu 标题。
        let code: String = try PlaylistMenuShapeContract.strippedCode(
            relativePath: PlaylistMenuShapeContract.macTrackListView
        )
        let titleCount: Int = PlaylistMenuShapeContract.occurrences(
            of: PlaylistMenuShapeContract.menuTitleToken, in: code
        )
        #expect(
            titleCount == PlaylistMenuShapeContract.menuTitleOccurrencesInMacTrackList,
            """
            ❌ MacTrackListView 内 `\(PlaylistMenuShapeContract.menuTitleToken)` 应恰好 \
            \(PlaylistMenuShapeContract.menuTitleOccurrencesInMacTrackList) 处\
            （单选 + 多选两个 Menu 标题），实际：\(titleCount)。
            """
        )
    }

    @Test("契约 3 补充：Mac 端不再用裸字面量标题（`\"add_to_playlist\".localized`）")
    func macTargetNoLongerUsesRawMenuTitleLiteral() throws {
        let files: [(relativePath: String, code: String)] = try PlaylistMenuShapeContract.scannedSources()
        var offenders: [String] = []
        for file in files where file.relativePath.hasPrefix("QQPlayer/Mac/") {
            let raw: String = try PlaylistMenuShapeContract.rawCode(relativePath: file.relativePath)
            let count: Int = PlaylistMenuShapeContract.occurrences(
                of: PlaylistMenuShapeContract.legacyRawMenuTitle, in: raw
            )
            if count > 0 { offenders.append("\(file.relativePath) ×\(count)") }
        }
        #expect(
            offenders.isEmpty,
            "❌ Mac 端「添加到歌单」标题统一走 Localized.addToPlaylist，不得再用裸字面量（会绕过契约 3）：\(offenders)"
        )
    }

    // MARK: 白名单不许腐烂 / 扫描不空转

    @Test("白名单不许腐烂：每个条目仍存在，且仍持有该 token")
    func whitelistEntriesStillHoldTheToken() throws {
        let hits: [String] = try PlaylistMenuShapeContract.filesHoldingMenuTitleToken()
        for path in PlaylistMenuShapeContract.titleTokenWhitelist {
            let url: URL = PlaylistMenuShapeContract.repositoryRoot.appendingPathComponent(path)
            #expect(FileManager.default.fileExists(atPath: url.path), "白名单腐烂：\(path) 不存在")
            #expect(hits.contains(path), "白名单腐烂：\(path) 已不再持有「添加到歌单」标题 token，请收窄白名单")
        }
    }

    // MARK: 扫描器自证（剥离管线 / 词边界 / 计数非空转）

    @Test("自证：注释 / 字符串里的特征不算命中（剥离管线）")
    func commentsAndStringsAreStripped() {
        let synthetic: String = """
        // 解释：这里曾经用 Localized.addToPlaylist 当标题
        let note = "Localized.addToPlaylist 出现在字符串里"
        let real = Localized.addToPlaylist
        """
        let code: String = PlaylistMenuShapeContract.strippingLiteralsAndComments(synthetic)
        #expect(!code.contains("曾经用 Localized.addToPlaylist"), "注释没被剥离：\(code)")
        #expect(!code.contains("出现在字符串里"), "字符串没被剥离：\(code)")
        #expect(
            PlaylistMenuShapeContract.occurrences(of: PlaylistMenuShapeContract.menuTitleToken, in: code) == 1,
            "应只统计真代码那 1 处，实际：\(code)"
        )
    }

    @Test("自证：`Localized.addToPlaylistEllipsis` 不被算作菜单标题 token")
    func ellipsisTokenIsNotCounted() {
        let ellipsisCode: String = "Label(Localized.addToPlaylistEllipsis, systemImage: \"rectangle.stack.badge.plus\")"
        #expect(
            PlaylistMenuShapeContract.occurrences(of: PlaylistMenuShapeContract.menuTitleToken, in: ellipsisCode) == 0,
            "椭圆菜单项 token 不得计入「添加到歌单」标题"
        )
        let realCode: String = "Menu(Localized.addToPlaylist) { addToPlaylistMenu(for: [track]) }"
        #expect(
            PlaylistMenuShapeContract.occurrences(of: PlaylistMenuShapeContract.menuTitleToken, in: realCode) == 1,
            "唯一入口的标题必须被统计到"
        )
    }

    @Test("自证：第二处声明 / 第二处调用必须被计数（计数非空转）")
    func counterDetectsSecondImplementation() {
        let twoDeclarations: String = """
        func addToPlaylistMenu(for tracks: [Track]) -> some View { EmptyView() }
        func addToPlaylistMenu(for tracks: [Track]) -> some View { EmptyView() }
        """
        #expect(
            PlaylistMenuShapeContract.occurrences(
                of: PlaylistMenuShapeContract.builderDeclarationPrefix, in: twoDeclarations
            ) == 2,
            "注入第二处声明后必须计到 2，否则契约 1 是空转"
        )

        let threeCallSites: String = """
        addToPlaylistMenu(for: [track])
        addToPlaylistMenu(for: tracks)
        addToPlaylistMenu(for: tracks)
        """
        #expect(
            PlaylistMenuShapeContract.occurrences(
                of: PlaylistMenuShapeContract.builderCallPrefix, in: threeCallSites
            ) == 3,
            "注入第三处调用后必须计到 3，否则契约 2 是空转"
        )
    }
}
