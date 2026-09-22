//
//  LibraryRoot.swift
//  QQPlayer
//
//  曲库根与「存储路径 ↔ 绝对 URL」的**唯一入口**（2026-09-22 曲库文件夹化）。
//
//  背景（用户口径 2026-09-22 13:1x）：Documents 文件夹化 —— 曲库 = `Documents/Music`
//  （扫描只认它，且**单层不递归**）、手工歌词 = `Documents/Lyrics`、封面缓存 =
//  `Documents/Artwork`、日志 = `Documents/Logs`；`track.path` 改存**相对 Music 根**的
//  相对路径（读取时经本入口解析回绝对 URL）。未规划文件一律不动。
//
//  存储语义（`track.path` 的两种形态，判据 = 首字符是否 `/`）：
//   · **相对路径** = 曲库内文件（相对 Music 根，POSIX 分隔）；
//   · **绝对路径** = 曲库外文件——Documents 之外的安全域/书签文件，或未规划的
//     Documents 根文件。语义与改动前一致：绝对路径 + security-scoped bookmark。
//
//  为什么必须唯一入口：路径解析散落时，「相对」与「绝对」两种形态会在不同调用点各自
//  被猜一次（换容器、旧前缀、兼容读取），必然漂移。全仓只允许经本文件做「存储形态 ↔
//  绝对 URL」的换算。相对路径的**规范化规则也在本文件**（`normalizedRelativePath` /
//  `relativePath(of:baseDirectory:)`）——它是对账键的单一事实源；同步层的
//  `SyncManifestGenerator` 那两处同名人只是**转发**到本文件（依赖方向 Sync → LibraryRoot）。
//
//  **对同步层零依赖（硬约束）**：本文件必须能被小组件扩展（`PlayerWidgetExtension`）
//  单独编译 —— 扩展的共享文件名单里有 `Services/AppLog.swift`，而 `AppLog` 的 iOS 日志
//  落点用到本文件的目录常量。若本文件引用 `Sync/` 任何东西，整个同步层会被拖进扩展，
//  `PlayerWidgetExtension` 立刻编译不过。⇒ 本文件**只允许 Foundation**。
//
//  macOS：曲库根仍是 `~/Music/QQPlayer`（`MusicFolderResolver.macDefaultFolderURL`），
//  不在 `<~/Documents>/Music` 之下 ⇒ 本文件对 Mac 路径全部**透传**（行为零变化）。
//
// target: shared
//

import Foundation

enum LibraryRoot {
    // MARK: - 目录名（唯一常量；别处不得再写字面量）

    /// 曲库目录名（曲库根 = `<Documents>/Music`）。
    static let musicDirectoryName = "Music"
    /// 手工歌词目录名。
    static let lyricsDirectoryName = "Lyrics"
    /// 封面缓存目录名。
    static let artworkDirectoryName = "Artwork"
    /// 日志目录名。
    static let logsDirectoryName = "Logs"
    /// 回收区目录名（**曲库根内的隐藏目录**，不是 `Documents` 下的一级目录）：
    /// 生产落点 = `<曲库根>/.Trash/<64位hex>.<ext>`（见 `DeleteReclaimArea`，差集语义要求
    /// 文件移出曲库根才可见）；`Documents/.Trash` 是旧根残留（`trashDirectoryURL` 只解析它）。
    static let trashDirectoryName = ".Trash"

    /// 封面映射表文件名（`Documents/Artwork/ArtworkMapping.plist`；改名前的旧位置是
    /// `Documents/ArtworkMapping.plist`，只做兼容读取）。
    static let artworkMappingFileName = "ArtworkMapping.plist"

    /// 规划目录（一次性迁移器要建的目录，顺序即建立顺序）。
    static let plannedDirectoryNames = [
        musicDirectoryName, lyricsDirectoryName, artworkDirectoryName, logsDirectoryName,
    ]

    // MARK: - 隐藏布局（iOS）常量

    /// 隐藏根目录名（iOS）。**macOS 不启用**隐藏根 —— `LibraryRoot` 对 macOS 逐字节保持
    /// 改动前行为（见 `scopedURL`）。
    static let hiddenRootDirectoryName = ".qqplayer"

    /// 隐藏根下的子目录名（iOS 唯一常量，别处不得再写字面量）。
    static let hiddenDatabaseDirectoryName = "db"
    static let hiddenStateDirectoryName = "state"
    static let hiddenArtworkDirectoryName = "artwork"
    static let hiddenLyricsDirectoryName = "lyrics"
    static let hiddenLogsDirectoryName = "logs"
    static let hiddenMetaDirectoryName = "meta"
    static let hiddenCacheDirectoryName = "cache"
    static let hiddenTrashDirectoryName = "trash"

    /// 隐藏布局下 `state/` 的一级子目录名（歌单；别处不写字面量）。
    static let hiddenPlaylistsDirectoryName = "playlists"
    /// 隐藏布局下 `lyrics/` 的一级子目录名（三类歌词互不重叠，禁混放）。
    static let hiddenManualLyricsDirectoryName = "manual"
    static let hiddenAlignedLyricsDirectoryName = "aligned"
    static let hiddenLyricsCacheDirectoryName = "cache"
    static let hiddenLegacyManualLyricsDirectoryName = "legacy-manual"

    // MARK: - 文件名常量（唯一事实源；别处不写字面量）

    /// iOS 数据库文件名（App Group 容器 / 隐藏 db 目录共用）。
    static let musicLibraryFileName = "MusicLibrary.sqlite"
    static let favoritesFileName = "qqplayer-favorites.json"
    static let playerStateFileName = "qqplayer-player-state.json"
    static let pairingFileName = "pairing.json"
    static let externalBookmarksFileName = "ExternalFileBookmarks.plist"
    static let appLogFileName = "app.log"
    static let dbDebugLogFileName = "db-debug.log"
    static let interruptionDebugLogFileName = "intr-debug.log"
    static let syncDiagnosticsLogFileName = "sync-diag.log"

    // MARK: - 隐藏布局解析（iOS 隐藏根 / macOS 现状，逐字节透传）

    /// 隐藏根 URL（iOS = `<Documents>/.qqplayer`；macOS = `<Documents>` 本身，不引入隐藏层）。
    static func hiddenRootURL(fileManager: FileManager = .default) -> URL? {
        guard let documents = documentsRootURL(fileManager: fileManager) else { return nil }
        #if os(iOS)
            return documents.appendingPathComponent(hiddenRootDirectoryName, isDirectory: true)
        #else
            return documents
        #endif
    }

    /// 「iOS 隐藏布局 / macOS 现状布局」的**唯一换算**（路径解析只此一处，禁散落拼接）：
    /// · iOS  → `<Documents>/.qqplayer/<hidden…>`
    /// · macOS → `<Documents>/<macOS…>`（逐字节等于改动前 ⇒ Mac 行为零变化）
    ///
    /// - Parameters:
    ///   - hidden: iOS 隐藏根下的相对组件
    ///   - macOS: macOS 下的现状相对组件
    ///   - isFile: 末组件是文件（false = 目录）
    static func scopedURL(
        hidden: [String],
        macOS: [String],
        isFile: Bool = false,
        fileManager: FileManager = .default
    ) -> URL? {
        #if os(iOS)
            let components = [hiddenRootDirectoryName] + hidden
        #else
            let components = macOS
        #endif
        guard let documents = documentsRootURL(fileManager: fileManager) else { return nil }
        // macOS 下部分类目（state / cache）现状就是 **Documents 根本身**（components 为空）
        // ⇒ 空列表要原样返回 Documents，不能当解析失败。
        guard !components.isEmpty else { return documents }
        var url = documents
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            url.appendPathComponent(component, isDirectory: !(isLast && isFile))
        }
        return url
    }

    // MARK: - 各存储类目 → URL（唯一入口）

    /// iOS 数据库目录（隐藏）；macOS 不走本函数（DB 落 Application Support）。
    static func databaseDirectoryURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(hidden: [hiddenDatabaseDirectoryName], macOS: [], fileManager: fileManager)
    }

    /// 状态类目录（iOS = `.qqplayer/state`；macOS = Documents 根 —— 状态文件现状即平铺在根）。
    static func stateDirectoryURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(hidden: [hiddenStateDirectoryName], macOS: [], fileManager: fileManager)
    }

    static func favoritesFileURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenStateDirectoryName, favoritesFileName],
            macOS: [favoritesFileName], isFile: true, fileManager: fileManager
        )
    }

    static func playlistsDirectoryURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenStateDirectoryName, hiddenPlaylistsDirectoryName],
            macOS: ["qqplayer-playlists"], fileManager: fileManager
        )
    }

    static func playerStateFileURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenStateDirectoryName, playerStateFileName],
            macOS: [playerStateFileName], isFile: true, fileManager: fileManager
        )
    }

    static func pairingFileURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenStateDirectoryName, pairingFileName],
            macOS: [pairingFileName], isFile: true, fileManager: fileManager
        )
    }

    static func externalBookmarksFileURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenStateDirectoryName, externalBookmarksFileName],
            macOS: [externalBookmarksFileName], isFile: true, fileManager: fileManager
        )
    }

    /// 封面缓存目录（iOS = `.qqplayer/artwork`；macOS = `Documents/Artwork`，现状）。
    static func artworkDirectoryURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenArtworkDirectoryName],
            macOS: [artworkDirectoryName], fileManager: fileManager
        )
    }

    /// 封面映射表（**元数据**，与缓存同目录但不属于缓存）。
    static func artworkMappingFileURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenArtworkDirectoryName, artworkMappingFileName],
            macOS: [artworkDirectoryName, artworkMappingFileName],
            isFile: true, fileManager: fileManager
        )
    }

    /// 封面映射表的**旧位置**（只读兼容；顺序 = 优先级，新位置仍高于全部旧位置）。
    /// · iOS：① v1 位置 `Documents/Artwork/ArtworkMapping.plist`
    ///         ② 改名前的旧位置 `Documents/ArtworkMapping.plist`
    /// · macOS：②（现状，与改动前一致）
    /// 映射内容由 `ArtworkManager.loadMapping` 合并（新位置优先），合并结果只写新位置。
    static func legacyArtworkMappingFileURLs(fileManager: FileManager = .default) -> [URL] {
        guard let documents = documentsRootURL(fileManager: fileManager) else { return [] }
        var urls: [URL] = []
        #if os(iOS)
            urls.append(
                documents
                    .appendingPathComponent(artworkDirectoryName, isDirectory: true)
                    .appendingPathComponent(artworkMappingFileName)
            )
        #endif
        urls.append(documents.appendingPathComponent(artworkMappingFileName))
        return urls
    }

    /// 手工歌词目录（iOS = `.qqplayer/lyrics/manual`；macOS = `Documents/Lyrics`，现状）。
    static func manualLyricsDirectoryURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenLyricsDirectoryName, hiddenManualLyricsDirectoryName],
            macOS: [lyricsDirectoryName], fileManager: fileManager
        )
    }

    /// 对齐歌词目录（iOS = `.qqplayer/lyrics/aligned`；macOS = `Documents/lyrics-aligned`）。
    static func alignedLyricsDirectoryURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenLyricsDirectoryName, hiddenAlignedLyricsDirectoryName],
            macOS: ["lyrics-aligned"], fileManager: fileManager
        )
    }

    /// 逐曲歌词缓存目录（iOS = `.qqplayer/lyrics/cache/tracks`；macOS = `Documents/lyrics-cache/tracks`）。
    static func lyricsCacheTracksDirectoryURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenLyricsDirectoryName, hiddenLyricsCacheDirectoryName, "tracks"],
            macOS: ["lyrics-cache", "tracks"], fileManager: fileManager
        )
    }

    /// 歌词搜索缓存目录（iOS = `.qqplayer/lyrics/cache/search`；macOS = `Documents/lyrics-cache/search`）。
    static func lyricsSearchCacheDirectoryURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenLyricsDirectoryName, hiddenLyricsCacheDirectoryName, "search"],
            macOS: ["lyrics-cache", "search"], fileManager: fileManager
        )
    }

    /// 日志目录（iOS = `.qqplayer/logs`；macOS = `Documents/Logs`，现状；macOS 的 AppLog
    /// 主日志另有 `~/Library/Logs/QQPlayerMac`，见 `AppLog`）。
    static func logsDirectoryURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenLogsDirectoryName],
            macOS: [logsDirectoryName], fileManager: fileManager
        )
    }

    /// 元数据目录（iOS = `.qqplayer/meta`；macOS = `Documents/meta`）。
    static func metaDirectoryURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenMetaDirectoryName],
            macOS: ["meta"], fileManager: fileManager
        )
    }

    /// 各类缓存根（iOS = `.qqplayer/cache`；macOS = Documents 根 —— 现状缓存目录即平铺在根）。
    static func cacheDirectoryURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(hidden: [hiddenCacheDirectoryName], macOS: [], fileManager: fileManager)
    }

    /// 具名网络缓存目录（`SpotifyCache` / `DiscogsCache` / `HybridMusicCache`）。
    /// iOS = `.qqplayer/cache/<name>`；macOS = `Documents/<name>`（现状）。
    static func namedCacheDirectoryURL(_ name: String, fileManager: FileManager = .default) -> URL? {
        scopedURL(hidden: [hiddenCacheDirectoryName, name], macOS: [name], fileManager: fileManager)
    }

    /// 回收区目录（iOS = `.qqplayer/trash`；macOS = `Documents/.Trash`，现状）。
    /// ⚠️ 生产回收区**不在这里**：删除落点必须是「曲库根内」的隐藏目录（见 `DeleteReclaimArea`，
    /// 差集语义要求文件移出曲库根才可见）。本函数只解析**旧根残留**的回收区。
    static func trashDirectoryURL(fileManager: FileManager = .default) -> URL? {
        scopedURL(
            hidden: [hiddenTrashDirectoryName],
            macOS: [trashDirectoryName], fileManager: fileManager
        )
    }

    // MARK: - 根

    /// 测试注入：覆盖 Documents 根（nil = 真实沙盒 Documents）。
    /// 与 `LyricsManager.manualLyricsDirectoryOverride` / `AlignedLyricsStore.directoryOverride`
    /// 同款：**只由测试在用例内写入**（串行用例 + 结束即复原），生产只读。
    /// 有了它，路径语义（相对/绝对、换容器、扫描根）才能脱离真机容器确定性验证。
    nonisolated(unsafe) static var documentsRootOverride: URL?

    /// 容器 Documents（唯一出口）。
    static func documentsRootURL(fileManager: FileManager = .default) -> URL? {
        documentsRootOverride ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// 曲库根 = `<Documents>/Music` —— **路径解析的唯一基准**。
    /// Documents 不可解析（极简注入 FileManager）→ 回落 `~/Documents`，永不返回 nil
    /// （调用方全是热路径，不接受可选）。
    static func musicRootURL(fileManager: FileManager = .default) -> URL {
        let documents = documentsRootURL(fileManager: fileManager)
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent(musicDirectoryName, isDirectory: true)
    }

    /// 规划目录 URL（nil = Documents 不可解析）。
    static func plannedDirectoryURL(_ name: String, fileManager: FileManager = .default) -> URL? {
        documentsRootURL(fileManager: fileManager)?
            .appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - 存储形态判定

    /// 相对路径 = 曲库内文件；绝对路径 = 曲库外文件。判据只看首字符，不猜。
    static func isRelativeStoredPath(_ path: String) -> Bool { !path.hasPrefix("/") }

    /// 相对路径规范化（**对账键的单一事实源**）：拒绝绝对路径与 `..` 逃逸，统一分隔符。
    /// 返回 nil = 非法（调用方丢弃，绝不「顺手修正」成可疑路径）。
    ///
    /// 实现放在**本文件**（而非 `SyncManifestGenerator`）是刻意的：本文件必须对同步层
    /// 零依赖（见文件头），而相对路径规范化是纯 Foundation 逻辑。同步层的
    /// `SyncManifestGenerator.normalizeRelativePath` 是本函数的转发 —— 规则仍只有一份。
    static func normalizedRelativePath(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        path = path.replacingOccurrences(of: "\\", with: "/")
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                return nil
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    /// 绝对 URL → 相对 `baseDirectory` 的路径（POSIX 分隔）。
    /// 不在根内 / 等于根 / 空路径 → nil（调用方跳过）。
    /// 同样落本文件（零依赖）；`SyncManifestGenerator.relativePath(of:baseDirectory:)` 转发。
    static func relativePath(of url: URL, baseDirectory: URL) -> String? {
        let base = baseDirectory.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        guard target.count > base.count, Array(target.prefix(base.count)) == base else {
            return nil
        }
        return normalizedRelativePath(target.dropFirst(base.count).joined(separator: "/"))
    }

    // MARK: - 换算（唯一入口）

    /// 绝对路径 → 存储形态。**幂等**（对已是存储形态的入参再调用结果不变，
    /// 因此所有写入点可以无脑调用）。
    /// · 已是相对路径 → 规范化后原样；· 曲库根下 → 相对路径；
    /// · 旧数据容器前缀 → 先归一化到现容器；· 其余 → 绝对路径。
    static func storedPath(forAbsolutePath path: String, fileManager: FileManager = .default) -> String {
        guard !path.isEmpty else { return path }
        if isRelativeStoredPath(path) { return normalizedRelativePath(path) ?? path }
        let rebased = rebasedFromLegacyContainer(path, fileManager: fileManager)
        if let relative = relativePathInMusicRoot(ofAbsolutePath: rebased, fileManager: fileManager) {
            return relative
        }
        return rebased
    }

    /// 绝对 URL → 存储形态。
    static func storedPath(for url: URL, fileManager: FileManager = .default) -> String {
        storedPath(forAbsolutePath: url.standardizedFileURL.path, fileManager: fileManager)
    }

    /// 存储形态 → 绝对 URL（**唯一解析口径**）。
    static func absoluteURL(forStoredPath path: String, fileManager: FileManager = .default) -> URL {
        if isRelativeStoredPath(path) {
            guard !path.isEmpty, let relative = normalizedRelativePath(path) else {
                return musicRootURL(fileManager: fileManager)
            }
            return musicRootURL(fileManager: fileManager)
                .appendingPathComponent(relative, isDirectory: false)
        }
        return URL(fileURLWithPath: rebasedFromLegacyContainer(path, fileManager: fileManager))
    }

    /// 存储形态 → 绝对路径字符串。
    static func absolutePath(forStoredPath path: String, fileManager: FileManager = .default) -> String {
        absoluteURL(forStoredPath: path, fileManager: fileManager).path
    }

    /// 绝对路径 → 曲库根内相对路径（nil = 不在曲库根下）。同步第二身份/打点用。
    static func relativePathInMusicRoot(
        ofAbsolutePath path: String,
        fileManager: FileManager = .default
    ) -> String? {
        guard !path.isEmpty else { return nil }
        return relativePath(
            of: URL(fileURLWithPath: path),
            baseDirectory: musicRootURL(fileManager: fileManager)
        )
    }

    static func relativePathInMusicRoot(of url: URL, fileManager: FileManager = .default) -> String? {
        relativePath(of: url, baseDirectory: musicRootURL(fileManager: fileManager))
    }

    /// 存储形态 → 曲库根内相对路径（曲库外文件 → nil）。打点用。
    static func relativePath(forStoredPath path: String, fileManager: FileManager = .default) -> String? {
        if isRelativeStoredPath(path) { return normalizedRelativePath(path) }
        return relativePathInMusicRoot(
            ofAbsolutePath: rebasedFromLegacyContainer(path, fileManager: fileManager),
            fileManager: fileManager
        )
    }

    /// 是否**曲库外文件**（Documents 之外 / 书签类）。
    /// 口径（唯一）：存储形态不是相对路径，**且**归一化后不在现 Documents 之下。
    /// 这批文件语义与改动前一致 —— 继续用绝对路径 + security-scoped bookmark，
    /// 绝不因为「看起来像 Documents」就把它当曲库内文件。
    static func isExternalPath(_ storedPath: String, fileManager: FileManager = .default) -> Bool {
        guard !storedPath.isEmpty, !isRelativeStoredPath(storedPath) else { return false }
        let rebased = rebasedFromLegacyContainer(storedPath, fileManager: fileManager)
        return !isInsideDocuments(rebased, fileManager: fileManager)
    }

    /// 绝对路径是否落在**现** Documents 之下。
    static func isInsideDocuments(_ absolutePath: String, fileManager: FileManager = .default) -> Bool {
        guard !absolutePath.isEmpty,
              let documents = documentsRootURL(fileManager: fileManager)?.standardizedFileURL.path
        else { return false }
        let normalized = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let prefix = documents.hasSuffix("/") ? documents : documents + "/"
        return normalized == documents || normalized.hasPrefix(prefix)
    }

    // MARK: - 旧数据容器前缀归一化

    /// 旧数据容器前缀 → 现容器：`…/Containers/Data/Application/<容器 ID>/Documents/<rest>`
    /// → `<现 Documents>/<rest>`。
    ///
    /// 保守判据（防误伤，2026-09-22 CI 修正）：必须同时满足
    /// ① 含 `/Containers/Data/Application/`（App 的**数据容器**形态）；
    /// ② 紧跟容器 ID 的那一层**就是** `Documents`；
    /// ③ 不在现 Documents 之下。
    ///
    /// 为什么不能只看 `contains("/Containers/")` + 取**最后一个** `/Documents/`（旧实现）：
    /// 那样会把下列两类路径误改到现 Documents 下，`track.path` 随即指向不存在的文件
    /// ⇒ 全库行被误判「悬空」（P1 三态判定反过来误触发 resync）：
    ///   · `<容器>/tmp/xxx/Documents/song.flac`（临时目录里的路径）；
    ///   · `…/Containers/Shared/AppGroup/<id>/…`（App Group 共享容器）。
    /// 非数据容器绝对路径一律原样返回。
    static func rebasedFromLegacyContainer(
        _ absolutePath: String,
        fileManager: FileManager = .default
    ) -> String {
        guard absolutePath.hasPrefix("/"),
              !isInsideDocuments(absolutePath, fileManager: fileManager) else {
            return absolutePath
        }
        let marker = "/Containers/Data/Application/"
        guard let range = absolutePath.range(of: marker, options: .backwards) else {
            return absolutePath
        }
        // 容器 ID 后必须**紧跟** `Documents` 才算「旧数据容器的 Documents 目录」。
        let components = absolutePath[range.upperBound...]
            .split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[1] == "Documents" else { return absolutePath }
        guard let documents = documentsRootURL(fileManager: fileManager)?.standardizedFileURL.path else {
            return absolutePath
        }
        let rest = components.dropFirst(2).map(String.init)
        return rest.isEmpty ? documents : documents + "/" + rest.joined(separator: "/")
    }
}
