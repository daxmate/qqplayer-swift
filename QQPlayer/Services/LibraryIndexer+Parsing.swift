//
//  LibraryIndexer+Parsing.swift
//  QQPlayer
//
//  文件发现与元数据解析：findMusicFiles / indexFile / processLocalFile /
//  generateStableId / parseAudioFile / 艺术家名解析与清洗 /
//  copyFilesFromSharedContainer。纯搬家自 LibraryIndexer.swift（无行为变化；
//  仅按分片放宽可见性）。
//
//  2026-09-22 新增：扫描 vs 指纹判定的 **path 维度**（`MetadataRefreshDecision` /
//  `staleStoredPath`，P1 重装自愈）。逻辑放本分片是为了不动 `LibraryIndexer.swift`
//  的行数预算（该文件恰好 600 行上限）；对外的唯一入口仍是 `needsMetadataRefresh`。
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import GRDB
import SFBAudioEngine

extension LibraryIndexer {
    // MARK: - 扫描 vs 指纹判定（唯一入口 = needsMetadataRefresh；本段是 path 维度的实现）

    /// 一轮扫描对某一行要做什么。三态是**穷尽**的：
    /// `current` 无事发生 / `resyncPathOnly` 只回写 path / `reparse` 重解析元数据。
    enum MetadataRefreshDecision: Equatable {
        /// 指纹与入库 path 都最新 → 本次扫描跳过该文件。
        case current
        /// 指纹未变，但入库 path 已失效（文件已在现容器路径下）→ 只回写 path，不重解析。
        case resyncPathOnly
        /// 指纹变了（或无指纹）→ 走既有重解析路径。
        case reparse
    }

    /// 入库 path 与当前文件 path 不一致、**且旧 path 已不存在** → 返回旧 path；否则 nil。
    ///
    /// 纯字符串相同直接返回 nil（不 stat）：每文件每次扫描的额外存在性判断**至多一次**，
    /// 且只在指纹未变、需要判断 path 时才发生（P1 代价控制）。
    /// 不做 `migrateTrackForMovedFile` 之外的任何写库动作——修 path 的唯一入口链不变。
    ///
    /// 2026-09-22 曲库文件夹化：`currentPath` 是调用方给的**绝对路径**（扫描到的文件），
    /// 比较前先经 `LibraryRoot.storedPath` 换算成与 `track.path` 同形态（相对曲库根）；
    /// `track.path` 的实际存在性走 `LibraryRoot` 解回绝对 URL
    /// （相对串直接 `fileExists` 会以 cwd 为基准，永远为假 = 全库误判「悬空」）。
    ///
    /// - Parameter fileManager: **Documents 根解析缝**（默认 `.default` ⇒ 生产调用点行为
    ///   逐字节不变）。本函数里的存在性判定是一条 Documents 派生解析链，注入临时根 FM
    ///   即可在测试里脱离真机容器驱动（见 `ReinstallLibraryPurgeTests`）。
    nonisolated func staleStoredPath(
        _ track: Track,
        currentPath: String,
        fileManager: FileManager = .default
    ) -> String? {
        let storedCurrent = LibraryRoot.storedPath(forAbsolutePath: currentPath, fileManager: fileManager)
        guard track.path != storedCurrent else { return nil }
        guard !fileManager.fileExists(
            atPath: LibraryRoot.absolutePath(forStoredPath: track.path, fileManager: fileManager)
        ) else { return nil }
        return track.path
    }

    /// `needsMetadataRefresh` 的 **path 维度重载**：指纹判定之外，再管「入库 path 悬空」。
    /// 重装后（数据容器 UUID 变化）整库 path 悬空而 mtime/size 不变 —— 旧实现一律返回
    /// false ⇒ 主扫整批跳过、永不自愈（2026-09-22）。
    nonisolated func needsMetadataRefresh(
        _ track: Track,
        fingerprint: FileFingerprint,
        currentPath: String
    ) -> Bool {
        metadataRefreshDecision(track, fingerprint: fingerprint, currentPath: currentPath) != .current
    }

    /// 判定实现（唯一一份）：先指纹（无 IO），指纹未变才看 path（至多一次 stat）。
    ///
    /// - Parameter fileManager: `staleStoredPath` 的 Documents 根解析缝（默认 `.default`）。
    nonisolated func metadataRefreshDecision(
        _ track: Track,
        fingerprint: FileFingerprint,
        currentPath: String,
        fileManager: FileManager = .default
    ) -> MetadataRefreshDecision {
        if needsMetadataRefresh(track, fingerprint: fingerprint) {
            return .reparse
        }
        return staleStoredPath(track, currentPath: currentPath, fileManager: fileManager) == nil
            ? .current : .resyncPathOnly
    }

    /// 扫描目录下的音乐文件（共享实现 MusicDirectoryScanner，iOS/macOS 同一套
    /// 过滤/隐藏/常规文件规则）。文件类型设置（web 版 audioExts 对齐）：扫描只收录
    /// 启用格式；默认全 9 种 = 历史行为（2026-09-03 B 组）。A0-prep 前是 LibraryIndexer
    /// 私有实现，抽取共享后行为逐条一致（含 enumerator 失败返回空、遍历错误抛出）。
    /// 分片：跨文件可见（原 private）
    ///
    /// - Parameter recursive: `true`（缺省）= 递归；`false` = 单层（iOS 曲库根口径）。
    func findMusicFiles(in directory: URL, recursive: Bool = true) async throws -> [URL] {
        let settings = DeleteSettings.load()
        let enabledExtensions = MusicDirectoryScanner.enabledExtensions(from: settings)
        return try await MusicDirectoryScanner.audioFiles(
            in: directory,
            enabledExtensions: enabledExtensions,
            recursive: recursive
        )
    }

    /// One unit of scan work, safe to run concurrently off the main actor.
    /// M3-2：iOS 已退役 ubiquity 主扫，与 macOS 一样全部按本地文件处理（沙盒
    /// Documents / 用户添加文件夹），无鉴权/下载门。
    /// 分片：跨文件可见（原 private）
    nonisolated func indexFile(_ fileURL: URL) async {
        await processLocalFile(fileURL)
    }

    nonisolated private func processLocalFile(_ fileURL: URL) async {
        // 取消检查：stop() 取消在途扫描后，已入队的文件不再继续处理（审计 🔵-9）。
        // 子任务继承父任务取消状态，此处早退即可（不写库、不做 IO）。
        guard !Task.isCancelled else { return }
        do {
            if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🎵 Starting to process file: \(fileURL.lastPathComponent)") }

            // M3-2：iOS/macOS 统一按本地文件处理（iOS 沙盒 Documents / macOS 用户
            // 添加文件夹），无 iCloud 实体化/下载门。macOS dataless 文件已在
            // scanMusicFolder 分区时过滤。

            if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🆔 Generating stable ID for: \(fileURL.lastPathComponent)") }
            let stableId = try generateStableId(for: fileURL)
            if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🆔 Generated stable ID: \(stableId)") }

            let fingerprint = try fileFingerprint(for: fileURL)
            let existingTrack = try existingTrack(stableId: stableId, path: fileURL.path)

            if let existingTrack {
                switch metadataRefreshDecision(existingTrack, fingerprint: fingerprint, currentPath: fileURL.path) {
                case .current:
                    if existingTrack.path != LibraryRoot.storedPath(for: fileURL) {
                        // 旧 path 仍存在（同一文件的两份副本 / 尚未失效）→ 依旧跳过，
                        // 但不再是静默 DEBUG：两条 path 一起打出来（D2 打点）。
                        AppLog.warn(.general, "⚠️ Skip scan but DB path ≠ file path: db=\(existingTrack.path) · file=\(LibraryRoot.storedPath(for: fileURL))")
                    } else if AppLog.isEnabled(.debug, .general) {
                        AppLog.debug(.general, "⏭️ Track metadata is current: \(fileURL.lastPathComponent)")
                    }
                    return
                case .resyncPathOnly:
                    // P1 自愈：指纹未变、库里 path 已悬空（iOS 重装换数据容器 UUID）
                    // → 只回写 path，保留其余元数据；不重解析、不删行。
                    // 修 path 仍走唯一入口链（FileCleanupManager → migrateTrackForMovedFile
                    // → migrateTrackStableIdAndPath），不另开平行入口。
                    // E 打点：打相对路径（整条绝对路径会刷屏，且容器前缀每台机器都不同）。
                    AppLog.warn(.general, "⚠️ Path resync only（指纹未变、入库 path 已失效）: "
                        + "\(LibraryRoot.relativePath(forStoredPath: existingTrack.path) ?? existingTrack.path)"
                        + " -> \(LibraryRoot.storedPath(for: fileURL))")
                    try databaseManager.migrateTrackForMovedFile(oldStableId: existingTrack.stableId, newPath: fileURL.path)
                    return
                case .reparse:
                    if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🔄 File changed; reparsing metadata: \(fileURL.lastPathComponent)") }
                }
            }

            // Check if track was excluded (removed from library only)
            if DeleteSettings.isTrackExcluded(stableId) {
                if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "⏭️ Track excluded from library: \(fileURL.lastPathComponent)") }
                return
            }

            if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🎶 Parsing audio file: \(fileURL.lastPathComponent)") }
            let parsedFile = try await parseAudioFile(at: fileURL, stableId: stableId)
            if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "✅ Audio file parsed successfully: \(parsedFile.track.title)") }
            try await saveParsedFile(
                parsedFile,
                replacing: existingTrack,
                sourceDescription: "file"
            )

        } catch LibraryIndexerError.parseTimeout {
            AppLog.warn(.general, "⏰ Timeout parsing audio file: \(fileURL.lastPathComponent)")
            AppLog.error(.general, "❌ Skipping file due to parsing timeout")
        } catch {
            AppLog.error(.general, "❌ Failed to process local track at \(fileURL.lastPathComponent): \(error)"
                + "\n❌ Error type: \(type(of: error))"
                + "\n❌ Error details: \(String(describing: error))")
        }
    }

    nonisolated func generateStableId(for url: URL) throws -> String {
        DatabaseManager.generatePathStableId(forPath: url.path)
    }

    /// 按 stableId 或存储形态路径回查已入库行（扫描/导入的既有行查询）。
    ///
    /// 2026-09-22 曲库文件夹化：从 `LibraryIndexer.swift` 搬到这里（那个文件卡在 600 行
    /// 预算上——路径语义相关的改动一律放本分片）。语义与搬迁前逐字一致。
    /// `path` 入参是**绝对路径**（调用点给的 URL），比较/回写一律用**存储形态**。
    /// 分片：跨文件可见（原 private）
    nonisolated func existingTrack(stableId: String, path: String) throws -> Track? {
        if let existing = try databaseManager.getTrack(byStableId: stableId) {
            return existing
        }

        guard var existing = try databaseManager.getTrack(byPath: path) else {
            return nil
        }

        // 存储形态（相对曲库根）与入参（绝对路径）不同形态：比较/回写一律用存储形态。
        let storedPath = LibraryRoot.storedPath(forAbsolutePath: path)
        if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🔁 Track already exists by path with old stable ID: \(existing.stableId)") }
        try databaseManager.migrateTrackForMovedFile(oldStableId: existing.stableId, newPath: storedPath)
        existing.stableId = stableId
        existing.path = storedPath
        return existing
    }

    /// 分片：跨文件可见（原 private）
    nonisolated func parseAudioFile(at url: URL, stableId: String) async throws -> ParsedAudioFile {
        if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🔍 Calling AudioMetadataParser for: \(url.lastPathComponent)") }

        // Add timeout to prevent hanging
        // 守卫时长取自注入缝 `parseTimeout`（生产默认 30s = 历史值，行为零变化）；
        // 测试可注入打不穿的值，避开 CI 线程饥饿造成的假红。
        // 先取成局部值再进闭包：不捕获 `self`，也避开 Sendable 捕获语义问题。
        let timeoutNanoseconds = UInt64(parseTimeout * 1_000_000_000)
        let metadata = try await withThrowingTaskGroup(of: AudioMetadata.self) { group in
            group.addTask {
                return try await AudioMetadataParser.parseMetadata(from: url)
            }

            group.addTask {
                // Files are parsed several at a time, so a single file's
                // wall-clock time now includes contention with its peers (and,
                // on a fresh install, iCloud still materialising the data).
                // 10s was tight enough that large files were being skipped
                // outright; this only bounds a genuine hang.
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw LibraryIndexerError.parseTimeout
            }

            guard let result = try await group.next() else {
                throw LibraryIndexerError.parseTimeout
            }

            group.cancelAll()
            return result
        }

        if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "✅ AudioMetadataParser completed for: \(url.lastPathComponent)") }

        let artistNames = parseArtistNames(metadata.artist)
        let rawAlbumArtist = metadata.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let albumArtistNames = rawAlbumArtist.isEmpty ? artistNames : parseArtistNames(rawAlbumArtist)
        let displayAlbumArtist = displayArtistName(from: albumArtistNames)
        if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🎤 Creating artist(s): '\(displayArtistName(from: artistNames))'") }

        let artists = try artistNames.map { try databaseManager.upsertArtist(name: $0) }
        let albumArtists = try albumArtistNames.map { try databaseManager.upsertArtist(name: $0) }
        let artist: Artist
        if let firstArtist = artists.first {
            artist = firstArtist
        } else {
            artist = try databaseManager.upsertArtist(name: Localized.unknownArtist)
        }
        // Key the album on the ALBUM artist, not the track's artist - keying
        // on the track artist split albums whenever a track featured a guest
        // (issue #81). candidateArtistIds lets upsertAlbum group tracks whose
        // artist order differs (e.g. "Guest; Main") into the existing album.
        let albumPrimaryArtist = albumArtists.first ?? artist
        let album = try databaseManager.upsertAlbum(
            title: metadata.album ?? Localized.unknownAlbum,
            artistId: albumPrimaryArtist.id,
            year: metadata.year,
            albumArtist: displayAlbumArtist,
            candidateArtistIds: (artists + albumArtists).compactMap(\.id)
        )

        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])

        let track = Track(
            stableId: stableId,
            albumId: album.id,
            artistId: artist.id,
            title: metadata.title ?? url.deletingPathExtension().lastPathComponent,
            genre: metadata.genre,
            trackNo: metadata.trackNumber,
            discNo: metadata.discNumber,
            durationMs: metadata.durationMs,
            sampleRate: metadata.sampleRate,
            bitDepth: metadata.bitDepth,
            channels: metadata.channels,
            path: LibraryRoot.storedPath(for: url),
            fileSize: Int64(resourceValues.fileSize ?? 0),
            modificationDate: Self.modificationTimestamp(resourceValues.contentModificationDate),
            replaygainTrackGain: metadata.replaygainTrackGain,
            replaygainAlbumGain: metadata.replaygainAlbumGain,
            replaygainTrackPeak: metadata.replaygainTrackPeak,
            replaygainAlbumPeak: metadata.replaygainAlbumPeak,
            hasEmbeddedArt: metadata.hasEmbeddedArt
        )

        return ParsedAudioFile(
            track: track,
            trackArtistIds: artists.compactMap(\.id),
            albumArtistIds: albumArtists.compactMap(\.id)
        )
    }

    nonisolated private func parseArtistNames(_ artistName: String?) -> [String] {
        let rawName = artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawName.isEmpty else { return [Localized.unknownArtist] }

        // Treat "feat."-style credits as additional artists so featured
        // tracks group under the same artists and albums (issues #16, #81)
        let featSeparated = rawName.replacingOccurrences(
            of: "(?i)\\s*[\\(\\[]?\\s*\\b(?:featuring|feat\\.?|ft\\.?)\\s+",
            with: ";",
            options: .regularExpression
        )

        // Split on the common multi-artist separators (issue #16):
        // "\\" (ID3 joined-value convention), ";" (most taggers), and
        // NUL (ID3v2.4 multi-value text frames)
        let delimiters = ["\\\\", ";", "\u{0}"]
        var rawComponents = [featSeparated]
        for delimiter in delimiters {
            rawComponents = rawComponents.flatMap { $0.components(separatedBy: delimiter) }
        }

        var seenNames = Set<String>()
        var artists: [String] = []

        for component in rawComponents {
            let cleaned = cleanArtistName(component)
            let normalized = cleaned.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            guard !cleaned.isEmpty, !seenNames.contains(normalized) else { continue }
            seenNames.insert(normalized)
            artists.append(cleaned)
        }

        return artists.isEmpty ? [Localized.unknownArtist] : artists
    }

    nonisolated private func displayArtistName(from artistNames: [String]) -> String {
        artistNames.joined(separator: " / ")
    }

    nonisolated private func cleanArtistName(_ artistName: String) -> String {
        var cleaned = artistName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove common YouTube/streaming suffixes
        let suffixesToRemove = [
            " - Topic",
            " Topic",
            "- Topic",
            ", Topic",
            " (Topic)",
        ]

        for suffix in suffixesToRemove where cleaned.hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Remove brackets and additional info that might cause duplicates
        if let bracketStart = cleaned.firstIndex(of: "[") {
            cleaned = String(cleaned[..<bracketStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Drop unbalanced trailing brackets left over when a "(feat. X)"
        // credit was converted into a separator (keeps names like "(G)I-DLE")
        while let last = cleaned.last,
              (last == ")" && !cleaned.contains("(")) || (last == "]" && !cleaned.contains("[")) {
            cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned.isEmpty ? Localized.unknownArtist : cleaned
    }

    func copyFilesFromSharedContainer() async {
        AppLog.info(.general, "📁 Checking shared container for new music files...")

        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.daxmate.qqplayer.ios") else {
            AppLog.error(.general, "❌ Failed to get shared container URL")
            return
        }

        // Process shared URLs from share extension
        await processSharedURLs(from: sharedContainer)

        // Also check for legacy copied files (for backward compatibility)
        await processLegacySharedFiles(from: sharedContainer)

        // Process previously stored external bookmarks (both document picker and share extension files)
        await processStoredExternalBookmarks()
    }

}
