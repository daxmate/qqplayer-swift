//
//  MacTrackDetailModel.swift
//  QQPlayer
//
//  macOS「歌曲详情」sheet 的**唯一数据组装入口**（2026-11-16）。
//
//  为什么放 Services 而不是 QQPlayer/Mac：本文件不 import AppKit，双 target 共享，
//  于是播放历史聚合口径能在 iOS 测试 target（CI 唯一跑测试的地方）里用内存库断言
//  （先例：MacLibraryFactsStore.swift）。
//
//  约束：
//  - play_history 的聚合读法只有这一份（`DatabaseManager.playHistorySummary`），
//    视图 / 其它文件不得再写第二段 SQL。
//  - 所有展示字段（时长 / 文件大小 / 采样率 / 最近播放 …）只在这里算一次；
//    视图层只做呈现与本地化兜底。
//  - 刮削来源 / 匹配状态 / 最后刮削时间**本批不展示**（无对应 DB 列，用户拍板方案 A，
//    不做迁移）。
//

import Foundation
import GRDB
import Observation

// MARK: - 播放历史聚合（唯一实现）

/// 单曲播放历史聚合结果。
struct PlayHistorySummary: Equatable, Sendable {
    struct RecentPlay: Equatable, Sendable {
        /// Unix 秒（PlayHistoryRecorder 写入口径：`Int64(Date().timeIntervalSince1970)`）。
        var playedAt: Int64
        var playDurationMs: Int64
    }

    var playCount: Int = 0
    var lastPlayedAt: Int64?
    var totalPlayedMs: Int64 = 0
    /// 最近播放记录，按 playedAt 倒序（新 → 旧）。
    var recentPlays: [RecentPlay] = []

    static let empty = PlayHistorySummary()

    var hasEverPlayed: Bool { playCount > 0 }
}

extension DatabaseManager {
    /// 单曲播放历史聚合读取（**唯一实现**）。
    ///
    /// - 次数 = play_history 行数（一次会话一行，见 PlayHistoryRecorder）
    /// - 最近播放 = MAX(played_at)
    /// - 累计时长 = SUM(play_duration_ms)
    /// - 最近记录 = 按 played_at 倒序（同秒用自增 id 兜底稳定顺序），最多 `recentLimit` 条
    func playHistorySummary(trackStableId: String, recentLimit: Int = 10) throws -> PlayHistorySummary {
        try read { db in
            var summary = PlayHistorySummary()
            if let row = try Row.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) AS play_count,
                       MAX(played_at) AS last_played_at,
                       COALESCE(SUM(play_duration_ms), 0) AS total_ms
                FROM play_history
                WHERE track_stable_id = ?
                """,
                arguments: [trackStableId]
            ) {
                summary.playCount = row["play_count"]
                summary.lastPlayedAt = row["last_played_at"]
                summary.totalPlayedMs = row["total_ms"]
            }
            if recentLimit > 0 {
                summary.recentPlays = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT played_at, play_duration_ms
                    FROM play_history
                    WHERE track_stable_id = ?
                    ORDER BY played_at DESC, id DESC
                    LIMIT ?
                    """,
                    arguments: [trackStableId, recentLimit]
                ).map { row in
                    PlayHistorySummary.RecentPlay(
                        playedAt: row["played_at"],
                        playDurationMs: row["play_duration_ms"]
                    )
                }
            }
            return summary
        }
    }
}

// MARK: - 展示快照

/// 详情 sheet 的一次性快照：曲目字段 + 关联专辑/歌手 + 播放历史 + 歌词预览。
struct MacTrackDetailSnapshot: Equatable, Sendable {
    var track: Track
    var artistName: String?
    var albumTitle: String?
    var albumArtist: String?
    var year: Int?
    var history: PlayHistorySummary = .empty
    var lyricsPreview: [String] = []
    var hasLyrics: Bool = false

    init(track: Track) {
        self.track = track
    }
}

/// 异步组装（nonisolated async → DB 读在并发执行器上，不占主线程；同 MacLibraryLoader）。
enum MacTrackDetailLoader {
    /// 歌词预览最多展示的行数（详情 sheet 内可滚动区域）。
    static let lyricsPreviewLineLimit = 12

    static func load(
        track: Track,
        database: DatabaseManager,
        lyrics: Lyrics?
    ) async -> MacTrackDetailSnapshot {
        var snapshot = MacTrackDetailSnapshot(track: track)
        if let albumId = track.albumId, let album = try? database.getAlbum(byId: albumId) {
            snapshot.albumTitle = album.title
            snapshot.albumArtist = album.albumArtist
            snapshot.year = album.year
        }
        snapshot.artistName = (try? database.getArtistDisplayName(
            forTrackStableId: track.stableId,
            fallbackArtistId: track.artistId
        )) ?? nil
        snapshot.history = (try? database.playHistorySummary(
            trackStableId: track.stableId,
            recentLimit: MacTrackDetailModel.recentPlayLimit
        )) ?? .empty
        snapshot.lyricsPreview = previewLines(from: lyrics)
        snapshot.hasLyrics = lyrics != nil && !(lyrics?.plainLyrics.isEmpty ?? true)
        return snapshot
    }

    /// 歌词预览：优先纯文本行；纯文本为空时退回逐行歌词文本。
    static func previewLines(from lyrics: Lyrics?) -> [String] {
        guard let lyrics else { return [] }
        let plain = lyrics.plainLyrics
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let lines = plain.isEmpty ? lyrics.syncedLyrics.map(\.text) : plain
        return Array(lines.prefix(lyricsPreviewLineLimit))
    }
}

/// 歌词来源（既有唯一入口 LyricsManager 的薄封装；nonisolated，便于作为默认值/测试注入）。
enum MacTrackDetailLyricsSource {
    static func load(track: Track) async -> Lyrics? {
        await LyricsManager.shared.getLyrics(for: track)
    }
}

// MARK: - 模型

/// 详情 sheet 的展示模型：异步加载一次，之后视图只读。
@MainActor
@Observable
final class MacTrackDetailModel {
    /// 最近播放列表展示条数（与 sheet 文案一致：最近 10 次）。
    nonisolated static let recentPlayLimit = 10

    let track: Track
    private let database: DatabaseManager
    private let lyricsProvider: (Track) async -> Lyrics?

    private(set) var snapshot: MacTrackDetailSnapshot
    private(set) var isLoading = true

    init(
        track: Track,
        database: DatabaseManager = .shared,
        lyricsProvider: @escaping (Track) async -> Lyrics? = MacTrackDetailLyricsSource.load
    ) {
        self.track = track
        self.database = database
        self.lyricsProvider = lyricsProvider
        // 首屏立刻可用（曲目自身字段），关联数据加载完再刷新。
        self.snapshot = MacTrackDetailSnapshot(track: track)
    }

    func load() async {
        isLoading = true
        let track = self.track
        let lyrics = await lyricsProvider(track)
        snapshot = await MacTrackDetailLoader.load(track: track, database: database, lyrics: lyrics)
        isLoading = false
    }

    // MARK: 派生展示字段（全部只在这里算）

    /// 未刮削判据：专辑标题 & 年份 & 流派**皆空** → true（任一非空即已刮削）。
    var isUnscraped: Bool {
        let albumEmpty = (snapshot.albumTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let genreEmpty = (track.genre ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return albumEmpty && snapshot.year == nil && genreEmpty
    }

    var durationText: String? { Self.formatDuration(ms: track.durationMs) }
    var fileSizeText: String? { Self.formatFileSize(bytes: track.fileSize) }
    var fileFormatText: String? { Self.formatFileFormat(path: track.path) }
    var sampleRateText: String? { Self.formatSampleRate(hz: track.sampleRate) }
    var bitDepthText: String? { Self.formatBitDepth(bits: track.bitDepth) }
    var channelsText: String? { Self.formatChannels(count: track.channels) }
    var trackNumberText: String? { Self.formatTrackNumber(track.trackNo, discNo: track.discNo) }

    var playCountText: String { "\(snapshot.history.playCount)" }
    var lastPlayedText: String? { Self.formatPlayedAt(snapshot.history.lastPlayedAt) }
    var totalPlayedText: String? {
        snapshot.history.hasEverPlayed ? Self.formatDuration(ms: Int(snapshot.history.totalPlayedMs)) : nil
    }

    // MARK: 格式化（纯函数，单测覆盖）

    static func formatDuration(ms: Int?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let totalSeconds = (ms + 500) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func formatFileSize(bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    static func formatFileFormat(path: String) -> String? {
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? nil : ext.uppercased()
    }

    static func formatSampleRate(hz: Int?) -> String? {
        guard let hz, hz > 0 else { return nil }
        let khz = Double(hz) / 1000
        let text = khz == khz.rounded()
            ? String(format: "%.0f", khz)
            : String(format: "%.1f", khz)
        return "\(text) kHz"
    }

    static func formatBitDepth(bits: Int?) -> String? {
        guard let bits, bits > 0 else { return nil }
        return "\(bits)-bit"
    }

    static func formatChannels(count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return "\(count)"
    }

    static func formatTrackNumber(_ trackNo: Int?, discNo: Int?) -> String? {
        switch (discNo, trackNo) {
        case let (disc?, track?): return "\(disc)-\(track)"
        case let (nil, track?): return "\(track)"
        case let (disc?, nil): return "\(disc)-"
        case (nil, nil): return nil
        }
    }

    static func formatPlayedAt(_ seconds: Int64?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
