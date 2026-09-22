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

    /// 封面映射表文件名（`Documents/Artwork/ArtworkMapping.plist`；改名前的旧位置是
    /// `Documents/ArtworkMapping.plist`，只做兼容读取）。
    static let artworkMappingFileName = "ArtworkMapping.plist"

    /// 规划目录（一次性迁移器要建的目录，顺序即建立顺序）。
    static let plannedDirectoryNames = [
        musicDirectoryName, lyricsDirectoryName, artworkDirectoryName, logsDirectoryName,
    ]

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

    /// 旧数据容器前缀 → 现容器：`…/Containers/…/Documents/<rest>` → `<现 Documents>/<rest>`。
    ///
    /// 保守判据（防误伤）：只在**含 `/Containers/`** 且**不在现 Documents 之下**时动手。
    /// 非容器绝对路径一律原样返回 —— 否则 iCloud / 外置盘里恰含 `/Documents/` 的路径
    /// 会被误认成沙盒内文件（曲库内/外的判定随之外错）。
    static func rebasedFromLegacyContainer(
        _ absolutePath: String,
        fileManager: FileManager = .default
    ) -> String {
        guard absolutePath.hasPrefix("/"), absolutePath.contains("/Containers/") else {
            return absolutePath
        }
        guard !isInsideDocuments(absolutePath, fileManager: fileManager) else { return absolutePath }
        guard let documents = documentsRootURL(fileManager: fileManager)?.standardizedFileURL.path else {
            return absolutePath
        }
        let marker = "/Documents/"
        guard let range = absolutePath.range(of: marker, options: .backwards) else {
            // 恰好停在 `…/Documents`（无尾斜杠）
            return absolutePath.hasSuffix("/Documents") ? documents : absolutePath
        }
        let rest = String(absolutePath[range.upperBound...])
        return rest.isEmpty ? documents : documents + "/" + rest
    }
}
