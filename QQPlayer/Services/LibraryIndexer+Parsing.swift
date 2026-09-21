//
//  LibraryIndexer+Parsing.swift
//  QQPlayer
//
//  文件发现与元数据解析：findMusicFiles / indexFile / processLocalFile /
//  generateStableId / parseAudioFile / 艺术家名解析与清洗 /
//  copyFilesFromSharedContainer。纯搬家自 LibraryIndexer.swift（无行为变化；
//  仅按分片放宽可见性）。
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import GRDB
import SFBAudioEngine

extension LibraryIndexer {
    /// 递归扫描目录下的音乐文件（共享实现 MusicDirectoryScanner，iOS/macOS 同一套
    /// 过滤/隐藏/常规文件规则）。文件类型设置（web 版 audioExts 对齐）：扫描只收录
    /// 启用格式；默认全 9 种 = 历史行为（2026-09-03 B 组）。A0-prep 前是 LibraryIndexer
    /// 私有实现，抽取共享后行为逐条一致（含 enumerator 失败返回空、遍历错误抛出）。
    /// 分片：跨文件可见（原 private）
    func findMusicFiles(in directory: URL) async throws -> [URL] {
        let settings = DeleteSettings.load()
        let enabledExtensions = MusicDirectoryScanner.enabledExtensions(from: settings)
        return try await MusicDirectoryScanner.audioFiles(
            in: directory,
            enabledExtensions: enabledExtensions
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

            if let existingTrack, !needsMetadataRefresh(existingTrack, fingerprint: fingerprint) {
                if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "⏭️ Track metadata is current: \(fileURL.lastPathComponent)") }
                return
            }
            if existingTrack != nil {
                if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🔄 File changed; reparsing metadata: \(fileURL.lastPathComponent)") }
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
            path: url.path,
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
