//
//  SyncCollectionSelection.swift
//  QQPlayer
//
//  R3a（2026-09-11）同步方向改造 · **选择集模型 + 展开器**（纯逻辑，零 IO）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  语义（docs/lan-sync-design.md §6.1 + §12b 决策 6-10）
//  ════════════════════════════════════════════════════════════════════════════
//  决策 9：歌单/收藏**可选同步**——用户显式勾选要同步的歌单；同步时目标端缺的
//          歌自动上传补齐（收藏视为特殊歌单，同规则）。同步集合 = 用户显式选择。
//  决策 10：**不做全库自动镜像**（移动端容量有限）——选择性集合是默认路径，
//           `.all` 仅作为 v1 兼容保留（显式选择才用）。
//  决策 7：**绝不跨端删除**——本文件只产出「要同步哪些文件」的期望集合，
//          既不删除也不隐含删除；对端多出的条目在编排层直接忽略。
//
//  为什么单独一个文件（而不是塞进 SyncCollection.swift）：
//  `SyncCollection` 是**线上载荷**（帧 10/11 的请求参数，跨端解释）；本文件是
//  **本端选择集 + 展开器**（本端解释，不进协议）。两者语义不同：
//  - `SyncCollection.playlists(ids)` 的 id 是**跨端可解释**的歌单标识；
//  - `SyncCollectionSelection.playlists(ids)` 的 id 是**本端**歌单标识
//    （Mac 侧 slug / 预留「收藏」标识），只在发起端展开。
//
//  为什么经注入协议取曲库事实：
//  歌单 → 曲目 → content_hash → 相对路径是 **DB 侧事实**，不是纯逻辑。若直接调
//  `DatabaseManager.shared`，无模拟器 harness 与单测就无法真跑（单例不可注入）。
//  因此这里定义 `SyncCollectionFactsProviding`（同 `SyncLocalLibraryDescriptor`
//  的注入风格）：生产装配给 DB 实现，测试/harness 给内存实现。
//
//  未解析（unresolved）处理：歌单里查不到 content_hash / 相对路径的曲目
//  （未指纹 / 未入库）→ **跳过并计入 `unresolved`**，不中止整批、不伪造路径
//  （伪造路径 = 让对端收到一份永远对不上的传输，比漏传更糟）。
//

import Foundation

// MARK: - 传输方向（T7 2026-09-11：用户显式选择，二者不混跑）

/// 一次同步的传输方向（**用户显式选择**；一次编排只跑一个方向，不混跑）。
///
/// 为什么要有方向：R3a 的「一次开始 → 先推后拉双向补齐」在对账基准上必然偏袒本端
/// （期望集合恒为本端展开结果）→ 对端独有的歌永远拉不回来；且 `.all` 空转。
/// T7 把方向提成显式参数：上传 = 只推（本端权威），下载 = 只拉（**以对端清单为准**）。
enum SyncTransferDirection: Equatable, Sendable {
    /// 上传到移动端：本端有、对端缺 → 推送（本端权威）。
    case upload
    /// 从移动端下载：对端有、本端缺 → 拉取（**以对端清单为准**）。
    case download
}

// MARK: - 选择集

/// 本端同步选择集（R3a 决策 9；`.all` 为 v1 兼容）。
enum SyncCollectionSelection: Equatable, Sendable {
    /// 全库（v1 兼容；决策 10 不默认走这条路）
    case all
    /// 显式勾选的歌单标识集合（**本端**标识；含「收藏」保留标识）
    case playlists([String])
    /// 显式相对路径集合（对账键口径；R1b-2 既有语义，保持不变）
    case relativePaths([String])

    /// 「收藏」的保留歌单标识（决策 9：收藏视为特殊歌单，走同一套展开规则）。
    /// 以 `@` 开头，与真实歌单 slug（字母/数字/连字符）不可能撞名。
    static let favoritesPlaylistID = "@favorites"

    /// 歌单标识长度上限（防超长垃圾输入）。
    static let maxPlaylistIDLength = 128

    /// 歌单标识形态校验：非空、限长、非点段、无路径分隔符、无控制字符。
    /// 标识不参与路径拼接，但仍按不可信输入处理（来自设置/对端编辑过的选择集）。
    static func isValidPlaylistID(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxPlaylistIDLength else { return false }
        guard trimmed != ".", trimmed != ".." else { return false }
        guard !trimmed.contains("/"), !trimmed.contains("\\") else { return false }
        return !trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// 规范化歌单标识：去空白 → 丢非法 → 去重 → 升序（确定性，便于比对与日志）。
    static func normalizePlaylistIDs(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for id in raw {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidPlaylistID(trimmed) else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out.sorted()
    }

    /// 是否「库级」选择（不过滤）。
    var isLibraryWide: Bool {
        if case .all = self { return true }
        return false
    }

    /// 规范化后的歌单标识（非 `.playlists` → nil）。
    var playlistIDs: [String]? {
        guard case let .playlists(raw) = self else { return nil }
        return SyncCollectionSelection.normalizePlaylistIDs(raw)
    }

    /// 规范化后的相对路径（非 `.relativePaths` → nil）。
    var relativePaths: [String]? {
        guard case let .relativePaths(raw) = self else { return nil }
        return SyncFetchRequest.normalize(raw)
    }

    /// **空选择集语义 = 不推不拉**（决策 9：同步集合 = 用户显式选择）。
    /// 注意与 `.all`（全库）**语义相反**，任何调用方都不许把两者混用。
    var isEmptySelection: Bool {
        switch self {
        case .all:
            return false
        case let .playlists(raw):
            return SyncCollectionSelection.normalizePlaylistIDs(raw).isEmpty
        case let .relativePaths(raw):
            return SyncFetchRequest.normalize(raw).isEmpty
        }
    }

    /// 规范化后的等价选择集（非法值一律丢弃；`.all` 原样）。
    var normalized: SyncCollectionSelection {
        switch self {
        case .all:
            return .all
        case let .playlists(raw):
            return .playlists(SyncCollectionSelection.normalizePlaylistIDs(raw))
        case let .relativePaths(raw):
            return .relativePaths(SyncFetchRequest.normalize(raw))
        }
    }
}

// MARK: - 曲库事实（注入）

/// 一条曲目事实（纯值；由注入实现从 DB 取）。
struct SyncCollectionTrackFact: Equatable, Sendable {
    /// 本端 stableId（诊断/去重；不参与跨端对账）
    var stableId: String
    /// 曲库内相对路径（对账键口径）；nil = 文件不在曲库根内 / 未入库
    var relativePath: String?
    /// 内容指纹（SHA-256 小写 hex）；nil = 尚未指纹
    var contentHash: String?

    init(stableId: String, relativePath: String? = nil, contentHash: String? = nil) {
        self.stableId = stableId
        self.relativePath = relativePath
        self.contentHash = contentHash
    }
}

/// 未解析原因（本地字符串常量，跨版本可加不可改）。
enum SyncCollectionUnresolvedReason {
    /// 尚未指纹（content_hash 缺失）→ 无从判定「同一首歌」
    static let notFingerprinted = "not_fingerprinted"
    /// 未入库 / 不在曲库根内（拿不到相对路径）
    static let notInLibrary = "not_in_library"
    /// 显式路径在本端查不到曲目
    static let unknownPath = "unknown_path"
}

/// 一条未解析记录（诊断/UI 用；不参与线上协议）。
struct SyncCollectionUnresolvedTrack: Equatable, Sendable {
    /// 本端 stableId（显式路径查不到时为空串）
    var stableId: String
    /// 相对路径（未入库时为空串）
    var relativePath: String
    /// 来源歌单标识（显式路径来源为空串）
    var playlistID: String
    /// 原因（`SyncCollectionUnresolvedReason` 取值）
    var reason: String
}

/// 曲库事实注入协议：选择集展开所需的**全部** DB 侧事实都从这里取。
/// 实现方必须**不抛**（查询失败按「查不到」返回，跳过单条而不是炸整批）。
protocol SyncCollectionFactsProviding {
    /// 歌单标识 → 歌单内曲目事实；**nil = 该歌单不存在**（空数组 = 歌单存在但为空）。
    func tracks(inPlaylist playlistID: String) -> [SyncCollectionTrackFact]?
    /// 显式相对路径 → 曲目事实（未入库 → nil）。
    func track(atRelativePath relativePath: String) -> SyncCollectionTrackFact?
    /// 本端是否已有该 wire 歌词（`@lyrics/{歌曲 content_hash}.json`）。
    func hasLyrics(atWirePath wirePath: String) -> Bool
}

// MARK: - 展开结果

/// 一条期望条目（对账键 + 身份键；`ManifestEntry` 的最小子集——展开器只从 DB
/// 拿得到这两个字段，size/mtime 是扫描侧事实，不在这里编造）。
struct SyncCollectionExpectation: Equatable, Sendable {
    /// 相对曲库根路径（对账键口径，已规范化）
    var relativePath: String
    /// 内容指纹；nil = 未知（仅显式路径可能为 nil，歌单展开必非 nil）
    var contentHash: String?
    /// 是否歌词命名空间条目（`@lyrics/...`）
    var isLyrics: Bool

    init(relativePath: String, contentHash: String?, isLyrics: Bool = false) {
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.isLyrics = isLyrics
    }
}

/// 选择集展开结果（纯值）。
struct SyncCollectionExpansion: Equatable, Sendable {
    /// 库级选择（`.all`）：不产出条目，调用方用本端全量 manifest（不过滤）。
    var isLibraryWide: Bool = false
    /// 空选择集：**不推不拉**（连 manifest 都不请求）。
    var isEmptySelection: Bool = false
    /// 期望条目（按 relativePath 升序、同路径去重；含歌词条目）
    var entries: [SyncCollectionExpectation] = []
    /// 未解析曲目（跳过 + 计数；不中止整批）
    var unresolved: [SyncCollectionUnresolvedTrack] = []
    /// 未知/非法歌单标识（忽略 + 计数；不抛）
    var unknownPlaylistIDs: [String] = []

    /// 期望的相对路径（升序）——直接喂给两个既有控制器的选择集。
    var relativePaths: [String] { entries.map(\.relativePath) }
    /// 未解析计数（诊断/UI）。
    var unresolvedCount: Int { unresolved.count }
    /// 歌曲条目数（不含歌词）。
    var songEntryCount: Int { entries.filter { !$0.isLyrics }.count }
    /// 歌词条目数。
    var lyricsEntryCount: Int { entries.filter(\.isLyrics).count }
    /// 是否有可同步内容。
    var hasSyncableEntries: Bool { !entries.isEmpty }
}

// MARK: - 展开器

enum SyncCollectionExpander {
    /// 选择集 → 期望条目集合。
    /// - `.all` → `isLibraryWide`（不展开；调用方用本端全量 manifest）
    /// - 空选择集 → `isEmptySelection`（不推不拉）
    /// - `.playlists(ids)` → 逐歌单取曲目事实；未知歌单忽略并计入 `unknownPlaylistIDs`
    /// - `.relativePaths(paths)` → 逐路径取曲目事实；查不到计入 `unresolved`
    static func expand(
        selection: SyncCollectionSelection,
        facts: SyncCollectionFactsProviding
    ) -> SyncCollectionExpansion {
        switch selection {
        case .all:
            return SyncCollectionExpansion(isLibraryWide: true)

        case let .playlists(raw):
            let ids = SyncCollectionSelection.normalizePlaylistIDs(raw)
            // 非法标识：忽略但记账（不抛）
            let invalidIDs = raw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !SyncCollectionSelection.isValidPlaylistID($0) }
            guard !ids.isEmpty else {
                return SyncCollectionExpansion(
                    isEmptySelection: true,
                    unknownPlaylistIDs: Array(Set(invalidIDs)).sorted()
                )
            }
            var builder = Builder()
            builder.unknownPlaylistIDs = invalidIDs
            for playlistID in ids {
                guard let tracks = facts.tracks(inPlaylist: playlistID) else {
                    builder.unknownPlaylistIDs.append(playlistID)
                    continue
                }
                for track in tracks {
                    builder.add(track: track, playlistID: playlistID, facts: facts)
                }
            }
            return builder.build()

        case let .relativePaths(raw):
            let paths = SyncFetchRequest.normalize(raw)
            guard !paths.isEmpty else {
                return SyncCollectionExpansion(isEmptySelection: true)
            }
            var builder = Builder()
            for path in paths {
                // 显式歌词路径：直接作为歌词条目纳入（不经歌曲映射）
                if SyncLyricsNamespace.isLyricsPath(path) {
                    if facts.hasLyrics(atWirePath: path) {
                        builder.insert(
                            SyncCollectionExpectation(
                                relativePath: path,
                                contentHash: SyncLyricsNamespace.songContentHash(fromWirePath: path),
                                isLyrics: true
                            )
                        )
                    } else {
                        builder.unresolved.append(
                            SyncCollectionUnresolvedTrack(
                                stableId: "",
                                relativePath: path,
                                playlistID: "",
                                reason: SyncCollectionUnresolvedReason.notInLibrary
                            )
                        )
                    }
                    continue
                }
                guard let track = facts.track(atRelativePath: path) else {
                    builder.unresolved.append(
                        SyncCollectionUnresolvedTrack(
                            stableId: "",
                            relativePath: path,
                            playlistID: "",
                            reason: SyncCollectionUnresolvedReason.unknownPath
                        )
                    )
                    continue
                }
                builder.add(track: track, playlistID: "", facts: facts)
            }
            return builder.build()
        }
    }

    // MARK: 内部累加器

    /// 条目去重 + 未解析记账（同路径 first wins：先到者来自更靠前的歌单）。
    private struct Builder {
        private var byPath: [String: SyncCollectionExpectation] = [:]
        var unresolved: [SyncCollectionUnresolvedTrack] = []
        var unknownPlaylistIDs: [String] = []

        /// 加入一条曲目事实（含其歌词条目）。
        mutating func add(
            track: SyncCollectionTrackFact,
            playlistID: String,
            facts: SyncCollectionFactsProviding
        ) {
            guard let rawPath = track.relativePath,
                  let path = SyncManifestGenerator.normalizeRelativePath(rawPath)
            else {
                unresolved.append(
                    SyncCollectionUnresolvedTrack(
                        stableId: track.stableId,
                        relativePath: track.relativePath ?? "",
                        playlistID: playlistID,
                        reason: SyncCollectionUnresolvedReason.notInLibrary
                    )
                )
                return
            }
            guard let hash = track.contentHash, SyncLyricsNamespace.isValidContentHash(hash) else {
                unresolved.append(
                    SyncCollectionUnresolvedTrack(
                        stableId: track.stableId,
                        relativePath: path,
                        playlistID: playlistID,
                        reason: SyncCollectionUnresolvedReason.notFingerprinted
                    )
                )
                return
            }
            insert(
                SyncCollectionExpectation(relativePath: path, contentHash: hash, isLyrics: false)
            )
            // 歌词随歌：wire 路径由歌曲 content_hash 唯一确定；本端没有就不纳入
            // （纳入而无实体 = 推送侧必然 localFileUnavailable，白记一次失败）。
            if let wirePath = SyncLyricsNamespace.wirePath(songContentHash: hash),
               facts.hasLyrics(atWirePath: wirePath) {
                insert(
                    SyncCollectionExpectation(
                        relativePath: wirePath,
                        contentHash: hash,
                        isLyrics: true
                    )
                )
            }
        }

        /// 插入一条期望条目（同路径 first wins）。
        mutating func insert(_ expectation: SyncCollectionExpectation) {
            if byPath[expectation.relativePath] == nil {
                byPath[expectation.relativePath] = expectation
            }
        }

        func build() -> SyncCollectionExpansion {
            SyncCollectionExpansion(
                isLibraryWide: false,
                isEmptySelection: false,
                entries: byPath.values.sorted { $0.relativePath < $1.relativePath },
                unresolved: unresolved,
                unknownPlaylistIDs: Array(Set(unknownPlaylistIDs)).sorted()
            )
        }
    }
}

// MARK: - 期望集合 → manifest 过滤（纯逻辑）

extension SyncCollectionExpansion {
    /// 在 manifest 条目上应用期望集合（库级选择 = 不过滤；空/无条目 = 空结果）。
    /// 用于：本端（Mac）manifest 收口、以及对端 manifest 的**同一口径**收口
    /// （对账键 = relativePath，两端一致时才能比较）。
    func filter(_ entries: [ManifestEntry]) -> [ManifestEntry] {
        if isLibraryWide {
            return entries.sorted { $0.relativePath < $1.relativePath }
        }
        let wanted = Set(relativePaths)
        return entries
            .filter { wanted.contains($0.relativePath) }
            .sorted { $0.relativePath < $1.relativePath }
    }
}

// MARK: - 传输方向 → 对端请求集合（T7，纯函数）

extension SyncCollectionSelection {
    /// 选择集 → **对端 manifest 请求集合**（方向敏感；纯函数，零 IO）。
    ///
    /// 为什么方向敏感：
    /// - **upload**：选择在**本端**执行（本端展开选择集），对端只需要回全量清单
    ///   供对账 → 恒 `.all`。
    /// - **download**：期望集合以**对端清单**为准，所以过滤必须在**对端**先做：
    ///   对端按歌单标识（Mac 侧 = `Playlist.slug`，与 M4-1 changeLog rowKey 同口径）
    ///   收口后再回清单，本端拿回来的就是「该歌单在对端持有的全部文件」。
    ///   相对路径选择集无法在对端表达（对端 manifest 过滤器只认 stableId 集合）
    ///   → 回全量清单，差异由本端按路径对账（见 `SyncExpectedPlanner`）。
    ///
    /// ⚠️ 依赖：download × `.playlists` 要求对端能解析歌单标识（被动端装配需注入
    /// 歌单成员；对端解析不出 → 回空清单 → 本端拉不到东西，不误删、不伪造）。
    func remoteRequestCollection(for direction: SyncTransferDirection) -> SyncCollection {
        switch (self, direction) {
        case (.all, _):
            return .all
        case let (.playlists(raw), .download):
            return .playlists(SyncCollectionSelection.normalizePlaylistIDs(raw))
        case (.playlists, .upload), (.relativePaths, _):
            return .all
        }
    }
}

// MARK: - 期望集合（对账基准）按方向取（T7，纯函数）

/// 一次编排的**期望集合来源**（对账基准；决定「谁缺谁」的判定方向）。
enum SyncExpectedSource: Equatable, Sendable {
    /// 本端全量 manifest 的路径（upload × `.all`：修「全库空转」）。
    case localManifest
    /// 本端选择集展开结果（upload × `.playlists` / `.relativePaths`）。
    case expansion
    /// 对端 manifest 的全部路径（download × `.all` / `.playlists`，对端已按集合收口）。
    case remoteManifest
    /// 选择集本身的相对路径（download × `.relativePaths`：对账键就是 relativePath，
    /// **不能**用本端展开结果——本端没有的歌正是要拉的那些）。
    case selectionPaths
}

enum SyncExpectedPlanner {
    /// 选择集 × 方向 → 期望集合来源（纯函数）。
    static func source(
        selection: SyncCollectionSelection,
        direction: SyncTransferDirection
    ) -> SyncExpectedSource {
        switch (selection, direction) {
        case (.all, .upload):
            return .localManifest
        case (.playlists, .upload), (.relativePaths, .upload):
            return .expansion
        case (.all, .download), (.playlists, .download):
            return .remoteManifest
        case (.relativePaths, .download):
            return .selectionPaths
        }
    }

    /// 期望相对路径集合（升序、去重；纯函数）。
    ///
    /// 调用时机：拿到**对端 manifest** 之后（download 的两条路都依赖对端清单）。
    /// `expansion` 只在 `selectionPaths` 之外的路径上参与，`localManifest` 只在
    /// upload × `.all` 时参与——两个入参都给全，由 `source` 决定用哪个。
    static func expected(
        selection: SyncCollectionSelection,
        direction: SyncTransferDirection,
        expansion: SyncCollectionExpansion,
        localManifest: [ManifestEntry],
        remoteManifest: [ManifestEntry]
    ) -> [String] {
        let paths: [String]
        switch source(selection: selection, direction: direction) {
        case .localManifest:
            paths = localManifest.map(\.relativePath)
        case .expansion:
            paths = expansion.relativePaths
        case .remoteManifest:
            paths = remoteManifest.map(\.relativePath)
        case .selectionPaths:
            paths = selection.relativePaths ?? []
        }
        return Array(Set(paths)).sorted()
    }
}
