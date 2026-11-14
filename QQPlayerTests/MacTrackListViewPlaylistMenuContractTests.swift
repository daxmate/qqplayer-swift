//
//  MacTrackListViewPlaylistMenuContractTests.swift
//  QQPlayerTests
//
//  曲目右键菜单的形状契约（2026-09-30 立，2026-11-14 随菜单收口重写）。
//
//  收口的语义（2026-11-14 用户拍板）：macOS 上「曲目右键菜单」**只有一份实现** ——
//  QQPlayer/Mac/MacTrackContextMenu.swift 里的：
//    · MacTrackContextMenuContent  菜单项本体（播放 / 下一首播放 / 收藏 / 添加到歌单 /
//                                  进歌手 / 进专辑 / 编辑标签 / 移到废纸篓）
//    · MacAddToPlaylistMenu        「添加到歌单」子菜单内容
//    · MacTrackMenuModifier        新建歌单 / 编辑标签 / 删除确认 三处弹窗宿主 + 删除执行
//  曲库 Table 与两个搜索面（侧栏库内检索 MacSearchResultsView、⌘K MacSearchAnythingLayer）
//  都只是**调用点**。多选分支最省力的写法就是再抄一遍菜单内容，两处会各自漂移
//  （菜单项增减 / 动作语义 / post 次数）——故把「只有一份实现 + 恰好三个调用点」做成 CI 红灯。
//
//  ⚠️ 与旧版契约的差异（本版按实测事实登记）：
//    · 旧版只守「添加到歌单」这一个 builder 的全仓唯一；本版把「整份曲目菜单」也纳入唯一性，
//      并要求三个宿主都真的调用它（否则「抽了共享视图但搜索面没接」这类遗漏不会被发现）。
//    · 旧版白名单里 QQPlayer/Mac/MacTrackListView.swift 持有标题 token（单选 + 多选两处 Menu 标题）；
//      现在单选那处随菜单收口进了 MacTrackContextMenu.swift，多选那处仍在 MacTrackListView.swift。
//      故 Mac 端持有者 = 这两个文件，且每处只应是 Menu 包装（不是菜单内容实现）。
//
//  判据全部走静态扫描（源码文本 + 注释/字符串剥离），无需模拟器即可**编译**；
//  但 Swift Testing 用例的**执行**只发生在 CI 的模拟器上（本地只做编译级验证）。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 扫描器

private enum PlaylistMenuShapeContract {
    /// 唯一实现所在文件（相对仓库根）。
    static let menuFile = "QQPlayer/Mac/MacTrackContextMenu.swift"

    /// 曲库 Table（三个调用点之一 + 多选菜单）。
    static let macTrackListView = "QQPlayer/Mac/MacTrackListView.swift"

    /// 侧栏库内检索结果（三个调用点之二）。
    static let searchResultsView = "QQPlayer/Mac/MacSearchView.swift"

    /// ⌘K search anything 浮层本体（弹窗宿主挂载点，三个调用点之三）。
    static let searchAnythingLayer = "QQPlayer/Mac/MacSearchAnythingLayer.swift"

    /// ⌘K search anything 行（曲目菜单调用点，三个调用点之三）。
    static let searchAnythingRows = "QQPlayer/Mac/MacSearchAnythingLayer+Rows.swift"

    /// 三个宿主都必须调用同一份曲目菜单内容（路径按扫描顺序即字典序排列）。
    static let expectedMenuContentCallers: [String] = [
        searchAnythingRows,
        searchResultsView,
        macTrackListView,
    ]

    /// 三个宿主都必须挂载同一份弹窗宿主（路径按扫描顺序即字典序排列）。
    static let expectedMenuModifierCallers: [String] = [
        searchAnythingLayer,
        searchResultsView,
        macTrackListView,
    ]

    /// 菜单标题 token（必须按**独立标识符**计数：Localized.addToPlaylistEllipsis 不算）。
    static let menuTitleToken = "Localized.addToPlaylist"

    /// 重构前 Mac 端用的裸字面量标题（收口后不得再出现）。
    static let legacyRawMenuTitle = "\"add_to_playlist\".localized"

    /// 「添加到歌单」子菜单内容的**声明**前缀（全仓唯一）。
    static let playlistMenuDeclaration = "struct MacAddToPlaylistMenu"
    /// 「添加到歌单」子菜单内容的**调用**前缀（声明处是 struct，不冲突）。
    static let playlistMenuCallPrefix = "MacAddToPlaylistMenu("

    /// 曲目菜单内容的**声明**前缀（全仓唯一）。
    static let menuContentDeclaration = "struct MacTrackContextMenuContent"
    /// 曲目菜单内容的**调用**前缀。
    static let menuContentCallPrefix = "MacTrackContextMenuContent("

    /// 弹窗宿主扩展的**声明**前缀（全仓唯一）。
    static let menuModifierDeclaration = "func macTrackMenu("
    /// 弹窗宿主的**调用**前缀（调用点写 .macTrackMenu(...)）。
    static let menuModifierCallPrefix = ".macTrackMenu("

    /// Mac 端允许持有「添加到歌单」标题 token 的文件：菜单实现 + 曲库多选 Menu。
    static let macTitleHolders: [String] = [menuFile, macTrackListView]

    /// 允许持有「添加到歌单」标题 token 的全部文件（相对仓库根）。
    /// Mac 端 = 唯一实现 + 多选包装；其余 4 个是 iOS 端**既有**使用（本批不动，
    /// 登记以便「新增第二处」立刻变红）。
    static let titleTokenWhitelist: [String] = [
        "QQPlayer/Mac/MacTrackContextMenu.swift",
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

    /// 生产源码根（QQPlayer/）下全部 .swift：相对仓库根路径 + **已剥离注释/字符串**的源码。
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
    /// token 作为**独立标识符**出现的次数（后一字符不得是字母 / 数字 / 下划线）。
    /// 必要性：Localized.addToPlaylist 是 Localized.addToPlaylistEllipsis 的前缀，
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

    /// 纯子串计数（不做标识符边界判断）。
    /// 用于**以标点结尾**的 token（如 "MacTrackContextMenuContent(" 或 ".macTrackMenu("）：
    /// 这类 token 末尾已是分隔符，不存在前缀误伤，而边界规则会把紧随其后的标识符首字母
    /// 当成「不是独立标识符」——反而一律计 0（实测踩过，契约会静默变空转）。
    static func exactOccurrences(of token: String, in code: String) -> Int {
        guard !token.isEmpty else { return 0 }
        var count: Int = 0
        var searchStart: String.Index = code.startIndex
        while let range = code.range(of: token, range: searchStart ..< code.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    /// 把源码里的字符串字面量与注释整体替换成空格（换行保留 → 行号不变）。
    /// 必要性：解释性注释里会写 MacTrackContextMenuContent(...) / ForEach(playlists)…，
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

    /// 从 start（指向双引号）解析字符串字面量（兼容三引号）→ 下一个字符下标。
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

    /// 把 [from, to) 写进 result（非换行字符换成空格；换行原样保留 → 行号不变）。
    private static func blank(_ characters: [Character], from: Int, to: Int, into result: inout [Character]) {
        for inner in from ..< min(to, characters.count) {
            result.append(characters[inner] == "\n" ? "\n" : " ")
        }
    }
    // SCAN-END

    /// 全仓每个文件里 token 的命中次数（只保留命中数 > 0 的，按路径排序）。
    static func filesHolding(_ token: String) throws -> [String] {
        try scannedSources()
            .filter { occurrences(of: token, in: $0.code) > 0 }
            .map(\.relativePath)
    }

    /// 命中标题 token 的文件（相对仓库根，排序后）。
    static func filesHoldingMenuTitleToken() throws -> [String] {
        try filesHolding(menuTitleToken)
    }
}

// MARK: - 契约

@Suite("曲目右键菜单形状契约")
struct MacTrackListViewPlaylistMenuContractTests {
    // MARK: 契约 1：「添加到歌单」子菜单内容全仓只有一份

    @Test("契约 1：「添加到歌单」子菜单内容全仓恰好一处声明，且在 MacTrackContextMenu.swift")
    func addToPlaylistMenuDeclaredExactlyOnce() throws {
        let files: [(relativePath: String, code: String)] = try PlaylistMenuShapeContract.scannedSources()
        #expect(files.count > 100, "扫到的生产源文件过少，仓库根推导可能失效：\(files.count)")

        var declaringFiles: [String] = []
        for file in files {
            let declarations: Int = PlaylistMenuShapeContract.occurrences(
                of: PlaylistMenuShapeContract.playlistMenuDeclaration, in: file.code
            )
            if declarations > 0 { declaringFiles.append("\(file.relativePath) ×\(declarations)") }
        }

        #expect(
            declaringFiles == ["\(PlaylistMenuShapeContract.menuFile) ×1"],
            "❌ 「添加到歌单」子菜单内容必须全仓只有一处声明（唯一实现），实际：\(declaringFiles)"
        )

        // 调用点恰好 2 处：曲目菜单内的 Menu（唯一实现文件）+ 曲库多选菜单。
        var callFiles: [String] = []
        for file in files {
            let calls: Int = PlaylistMenuShapeContract.exactOccurrences(
                of: PlaylistMenuShapeContract.playlistMenuCallPrefix, in: file.code
            )
            if calls > 0 { callFiles.append("\(file.relativePath) ×\(calls)") }
        }
        #expect(
            callFiles == [
                "\(PlaylistMenuShapeContract.menuFile) ×1",
                "\(PlaylistMenuShapeContract.macTrackListView) ×1",
            ],
            "❌ 「添加到歌单」子菜单内容应只被 曲库多选 + 曲目菜单 两处调用，实际：\(callFiles)"
        )
    }

    // MARK: 契约 2：整份曲目菜单只有一份实现，且三个宿主都接入

    @Test("契约 2：曲目菜单内容全仓恰好一处声明，且曲库 + 两个搜索面都调用它")
    func trackMenuContentIsSharedByAllThreeSurfaces() throws {
        let files: [(relativePath: String, code: String)] = try PlaylistMenuShapeContract.scannedSources()

        var declaringFiles: [String] = []
        var callFiles: [String] = []
        for file in files {
            let declarations: Int = PlaylistMenuShapeContract.occurrences(
                of: PlaylistMenuShapeContract.menuContentDeclaration, in: file.code
            )
            if declarations > 0 { declaringFiles.append("\(file.relativePath) ×\(declarations)") }

            let calls: Int = PlaylistMenuShapeContract.exactOccurrences(
                of: PlaylistMenuShapeContract.menuContentCallPrefix, in: file.code
            )
            if calls > 0 { callFiles.append(file.relativePath) }
        }

        #expect(
            declaringFiles == ["\(PlaylistMenuShapeContract.menuFile) ×1"],
            "❌ 曲目右键菜单必须全仓只有一处声明（唯一实现），实际：\(declaringFiles)"
        )
        #expect(
            callFiles == PlaylistMenuShapeContract.expectedMenuContentCallers,
            """
            ❌ 曲库 + 两个搜索面都必须调用同一份曲目菜单（三处调用点），实际：\(callFiles)。
            少一处 = 某个面的菜单没接上共享实现；多一处 = 疑似又抄了一份。
            """
        )
    }

    // MARK: 契约 3：弹窗宿主（新建歌单 / 编辑标签 / 删除确认）只有一份

    @Test("契约 3：弹窗宿主 .macTrackMenu 恰好一处声明，且三个宿主都挂载")
    func menuModifierIsDeclaredOnceAndWiredOnAllHosts() throws {
        let files: [(relativePath: String, code: String)] = try PlaylistMenuShapeContract.scannedSources()

        var declaringFiles: [String] = []
        var callFiles: [String] = []
        for file in files {
            let declarations: Int = PlaylistMenuShapeContract.exactOccurrences(
                of: PlaylistMenuShapeContract.menuModifierDeclaration, in: file.code
            )
            if declarations > 0 { declaringFiles.append("\(file.relativePath) ×\(declarations)") }

            let calls: Int = PlaylistMenuShapeContract.exactOccurrences(
                of: PlaylistMenuShapeContract.menuModifierCallPrefix, in: file.code
            )
            if calls > 0 { callFiles.append(file.relativePath) }
        }

        #expect(
            declaringFiles == ["\(PlaylistMenuShapeContract.menuFile) ×1"],
            "❌ 菜单弹窗宿主必须全仓只有一处声明，实际：\(declaringFiles)"
        )
        #expect(
            callFiles == PlaylistMenuShapeContract.expectedMenuModifierCallers,
            """
            ❌ 曲库 + 两个搜索面都必须挂载同一份弹窗宿主（新建歌单 / 编辑标签 / 删除确认），
            实际：\(callFiles)。少一处 = 该面的菜单动作会缺弹窗或另写一套。
            """
        )
    }

    // MARK: 契约 4：标题 token 白名单 + Mac 端不再有第二份实现

    @Test("契约 4：Localized.addToPlaylist 命中文件 = 白名单，Mac 端只有菜单实现 + 曲库多选包装")
    func menuTitleTokenIsWhitelistedAndMacHasOnlyWrapperUsages() throws {
        let hits: [String] = try PlaylistMenuShapeContract.filesHoldingMenuTitleToken()
        #expect(
            hits == PlaylistMenuShapeContract.titleTokenWhitelist,
            """
            ❌ 出现白名单外的「添加到歌单」标题 token 持有者（疑似第二份实现）：\(hits)
            白名单实际期望：\(PlaylistMenuShapeContract.titleTokenWhitelist)
            """
        )

        // Mac 端只允许「唯一实现 + 曲库多选 Menu 包装」两个文件持有该标题 token。
        let macHolders: [String] = hits.filter { $0.hasPrefix("QQPlayer/Mac/") }
        #expect(
            macHolders == PlaylistMenuShapeContract.macTitleHolders,
            "❌ Mac 端「添加到歌单」标题 token 只允许出现在唯一实现 + 曲库多选包装，实际：\(macHolders)"
        )
    }

    @Test("契约 4 补充：Mac 端不再用裸字面量标题（add_to_playlist 裸 localize）")
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
            "❌ Mac 端「添加到歌单」标题统一走 Localized.addToPlaylist，不得再用裸字面量（会绕过契约 4）：\(offenders)"
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

    @Test("唯一实现文件三件套齐全（菜单内容 + 子菜单内容 + 弹窗宿主）")
    func sharedMenuFileHoldsAllThreePieces() throws {
        let code: String = try PlaylistMenuShapeContract.strippedCode(
            relativePath: PlaylistMenuShapeContract.menuFile
        )
        #expect(
            PlaylistMenuShapeContract.occurrences(of: PlaylistMenuShapeContract.menuContentDeclaration, in: code) == 1,
            "唯一实现文件里应有曲目菜单内容声明"
        )
        #expect(
            PlaylistMenuShapeContract.occurrences(of: PlaylistMenuShapeContract.playlistMenuDeclaration, in: code) == 1,
            "唯一实现文件里应有「添加到歌单」子菜单内容声明"
        )
        #expect(
            PlaylistMenuShapeContract.exactOccurrences(of: PlaylistMenuShapeContract.menuModifierDeclaration, in: code) == 1,
            "唯一实现文件里应有弹窗宿主声明"
        )
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

    @Test("自证：Localized.addToPlaylistEllipsis 不被算作菜单标题 token")
    func ellipsisTokenIsNotCounted() {
        let ellipsisCode: String = "Label(Localized.addToPlaylistEllipsis, systemImage: \"rectangle.stack.badge.plus\")"
        #expect(
            PlaylistMenuShapeContract.occurrences(of: PlaylistMenuShapeContract.menuTitleToken, in: ellipsisCode) == 0,
            "椭圆菜单项 token 不得计入「添加到歌单」标题"
        )
        let realCode: String = "Menu(Localized.addToPlaylist) { MacAddToPlaylistMenu(tracks: [track], model: model) }"
        #expect(
            PlaylistMenuShapeContract.occurrences(of: PlaylistMenuShapeContract.menuTitleToken, in: realCode) == 1,
            "唯一入口的标题必须被统计到"
        )
    }

    @Test("自证：第二处声明 / 第四处调用必须被计数（计数非空转）")
    func counterDetectsSecondImplementation() {
        let twoDeclarations: String = """
        struct MacTrackContextMenuContent: View { var body: some View { EmptyView() } }
        struct MacTrackContextMenuContent: View { var body: some View { EmptyView() } }
        """
        #expect(
            PlaylistMenuShapeContract.occurrences(
                of: PlaylistMenuShapeContract.menuContentDeclaration, in: twoDeclarations
            ) == 2,
            "注入第二处声明后必须计到 2，否则契约 2 是空转"
        )

        let fourCallSites: String = """
        MacTrackContextMenuContent(track: a, model: m, onPlay: {})
        MacTrackContextMenuContent(track: b, model: m, onPlay: {})
        MacTrackContextMenuContent(track: c, model: m, onPlay: {})
        MacTrackContextMenuContent(track: d, model: m, onPlay: {})
        """
        #expect(
            PlaylistMenuShapeContract.exactOccurrences(
                of: PlaylistMenuShapeContract.menuContentCallPrefix, in: fourCallSites
            ) == 4,
            "注入第四处调用后必须计到 4，否则「三个宿主」判据是空转"
        )
    }
}
