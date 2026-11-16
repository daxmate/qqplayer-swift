//
//  MacTrackDetailModelTests.swift
//  QQPlayerTests
//
//  macOS「歌曲详情」sheet 的数据口径（2026-11-16）。
//
//  用 `DatabaseManager(dbWriter: DatabaseQueue())` 内存库测试缝跑真实生产读路径：
//  - 播放次数 / 最近播放 / 累计时长 / 最近 N 条（N=10 截断）
//  - 未刮削判据（专辑 & 年份 & 流派皆空）
//  - 展示格式化（时长 / 文件大小 / 采样率 / 位深 / 音轨号）
//
//  模型放 Services（无 AppKit，双 target 共享），因此可在 CI 的 iOS 测试 target 里跑。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

struct MacTrackDetailModelTests {
    // MARK: - Fixture

    private static func makeManager() throws -> (DatabaseManager, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        return (manager, dbQueue)
    }

    private static func makeTrack(
        stableId: String = "detail-track",
        albumId: Int64? = nil,
        genre: String? = nil
    ) -> Track {
        Track(
            id: nil,
            stableId: stableId,
            albumId: albumId,
            artistId: nil,
            title: "曲目 \(stableId)",
            genre: genre,
            trackNo: 3,
            discNo: 1,
            durationMs: 215_000,
            sampleRate: 44100,
            bitDepth: 16,
            channels: 2,
            path: "/tmp/\(stableId).flac",
            fileSize: 25_000_000,
            modificationDate: nil,
            contentHash: nil,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: false
        )
    }

    private static func insertPlay(
        _ db: Database,
        stableId: String,
        playedAt: Int64,
        durationMs: Int64
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO play_history (track_stable_id, played_at, play_duration_ms)
            VALUES (?, ?, ?)
            """,
            arguments: [stableId, playedAt, durationMs]
        )
    }

    @MainActor
    private static func loadedModel(
        track: Track,
        manager: DatabaseManager
    ) async -> MacTrackDetailModel {
        let model = MacTrackDetailModel(
            track: track,
            database: manager,
            lyricsProvider: { _ in nil }
        )
        await model.load()
        return model
    }

    // MARK: - 播放次数

    @Test("从未播放：0 条 → playCount 0，最近播放/累计时长均无值")
    @MainActor
    func neverPlayed() async throws {
        let (manager, _) = try Self.makeManager()
        let model = await Self.loadedModel(track: Self.makeTrack(), manager: manager)

        #expect(model.snapshot.history.playCount == 0)
        #expect(model.snapshot.history.hasEverPlayed == false)
        #expect(model.snapshot.history.lastPlayedAt == nil)
        #expect(model.lastPlayedText == nil)
        #expect(model.totalPlayedText == nil)
        #expect(model.snapshot.history.recentPlays.isEmpty)
    }

    @Test("播放次数 = play_history 行数（只统计当前曲目）")
    @MainActor
    func playCountCountsRowsForTrackOnly() async throws {
        let (manager, dbQueue) = try Self.makeManager()
        try await dbQueue.write { db in
            try Self.insertPlay(db, stableId: "detail-track", playedAt: 100, durationMs: 1000)
            try Self.insertPlay(db, stableId: "detail-track", playedAt: 200, durationMs: 2000)
            try Self.insertPlay(db, stableId: "other-track", playedAt: 300, durationMs: 9000)
        }
        let model = await Self.loadedModel(track: Self.makeTrack(), manager: manager)

        #expect(model.snapshot.history.playCount == 2)
        #expect(model.playCountText == "2")
        #expect(model.snapshot.history.totalPlayedMs == 3000)
    }

    // MARK: - 最近播放 / 累计时长

    @Test("最近播放 = MAX(playedAt)，累计 = SUM(playDurationMs)")
    @MainActor
    func lastAndTotalAggregates() async throws {
        let (manager, dbQueue) = try Self.makeManager()
        try await dbQueue.write { db in
            try Self.insertPlay(db, stableId: "detail-track", playedAt: 1000, durationMs: 500)
            try Self.insertPlay(db, stableId: "detail-track", playedAt: 5000, durationMs: 1500)
            try Self.insertPlay(db, stableId: "detail-track", playedAt: 3000, durationMs: 2500)
        }
        let model = await Self.loadedModel(track: Self.makeTrack(), manager: manager)

        #expect(model.snapshot.history.lastPlayedAt == 5000)
        #expect(model.snapshot.history.totalPlayedMs == 4500)
        #expect(model.lastPlayedText == MacTrackDetailModel.formatPlayedAt(5000))
        #expect(model.totalPlayedText == MacTrackDetailModel.formatDuration(ms: 4500))
    }

    @Test("最近记录按时间倒序，且 N=10 截断")
    @MainActor
    func recentPlaysOrderedAndTruncated() async throws {
        let (manager, dbQueue) = try Self.makeManager()
        try await dbQueue.write { db in
            // 12 条，playedAt 1...12（乱序写入）
            for value in [4, 12, 1, 9, 7, 2, 11, 5, 3, 10, 6, 8] {
                try Self.insertPlay(
                    db,
                    stableId: "detail-track",
                    playedAt: Int64(value),
                    durationMs: Int64(value) * 100
                )
            }
        }
        let model = await Self.loadedModel(track: Self.makeTrack(), manager: manager)
        let recent = model.snapshot.history.recentPlays

        #expect(model.snapshot.history.playCount == 12)
        #expect(recent.count == MacTrackDetailModel.recentPlayLimit)
        #expect(recent.map(\.playedAt) == [12, 11, 10, 9, 8, 7, 6, 5, 4, 3].map(Int64.init))
        #expect(recent.first?.playDurationMs == 1200)
    }

    @Test("同秒多条：用自增 id 兜底，顺序稳定（新的在前）")
    @MainActor
    func recentPlaysStableWithinSameSecond() async throws {
        let (manager, dbQueue) = try Self.makeManager()
        try await dbQueue.write { db in
            try Self.insertPlay(db, stableId: "detail-track", playedAt: 700, durationMs: 100)
            try Self.insertPlay(db, stableId: "detail-track", playedAt: 700, durationMs: 200)
        }
        let model = await Self.loadedModel(track: Self.makeTrack(), manager: manager)

        #expect(model.snapshot.history.recentPlays.map(\.playDurationMs) == [200, 100])
    }

    // MARK: - 未刮削判据

    @Test("未刮削：专辑 & 年份 & 流派皆空 → true；任一非空 → false")
    @MainActor
    func unscrapedRule() async throws {
        let (manager, dbQueue) = try Self.makeManager()
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO album (id, artist_id, title, year, album_artist) VALUES (1, NULL, 'Album One', 1999, 'Band')",
                arguments: []
            )
            try db.execute(
                sql: "INSERT INTO album (id, artist_id, title, year, album_artist) VALUES (2, NULL, 'Album Two', NULL, NULL)",
                arguments: []
            )
        }

        let empty = await Self.loadedModel(track: Self.makeTrack(), manager: manager)
        #expect(empty.isUnscraped)

        let withGenre = await Self.loadedModel(track: Self.makeTrack(genre: "Rock"), manager: manager)
        #expect(withGenre.isUnscraped == false)

        let withAlbum = await Self.loadedModel(track: Self.makeTrack(albumId: 1), manager: manager)
        #expect(withAlbum.snapshot.albumTitle == "Album One")
        #expect(withAlbum.snapshot.year == 1999)
        #expect(withAlbum.isUnscraped == false)

        // 专辑存在但年份为空、流派为空 → 专辑标题非空即「已刮削」
        let albumOnly = await Self.loadedModel(track: Self.makeTrack(albumId: 2), manager: manager)
        #expect(albumOnly.snapshot.year == nil)
        #expect(albumOnly.isUnscraped == false)
    }

    // MARK: - 展示格式化

    @Test("格式化：时长 / 文件大小 / 采样率 / 位深 / 声道 / 音轨号")
    @MainActor
    func displayFormatting() async throws {
        #expect(MacTrackDetailModel.formatDuration(ms: 215_000) == "3:35")
        #expect(MacTrackDetailModel.formatDuration(ms: 3_725_000) == "1:02:05")
        #expect(MacTrackDetailModel.formatDuration(ms: 0) == nil)

        #expect(MacTrackDetailModel.formatFileSize(bytes: 25_000_000) == "23.8 MB")
        #expect(MacTrackDetailModel.formatFileSize(bytes: 512) == "512 B")
        #expect(MacTrackDetailModel.formatFileSize(bytes: nil) == nil)

        #expect(MacTrackDetailModel.formatSampleRate(hz: 44100) == "44.1 kHz")
        #expect(MacTrackDetailModel.formatSampleRate(hz: 48000) == "48 kHz")
        #expect(MacTrackDetailModel.formatBitDepth(bits: 16) == "16-bit")
        #expect(MacTrackDetailModel.formatChannels(count: 2) == "2")
        #expect(MacTrackDetailModel.formatTrackNumber(3, discNo: 1) == "1-3")
        #expect(MacTrackDetailModel.formatTrackNumber(3, discNo: nil) == "3")
        #expect(MacTrackDetailModel.formatTrackNumber(nil, discNo: 1) == "1-")
        #expect(MacTrackDetailModel.formatTrackNumber(nil, discNo: nil) == nil)
        #expect(MacTrackDetailModel.formatFileFormat(path: "/tmp/a.FLAC") == "FLAC")
        #expect(MacTrackDetailModel.formatFileFormat(path: "/tmp/noext") == nil)

        let (manager, _) = try Self.makeManager()
        let model = await Self.loadedModel(track: Self.makeTrack(), manager: manager)
        #expect(model.durationText == "3:35")
        #expect(model.fileSizeText == "23.8 MB")
        #expect(model.sampleRateText == "44.1 kHz")
        #expect(model.bitDepthText == "16-bit")
        #expect(model.channelsText == "2")
        #expect(model.trackNumberText == "1-3")
    }
}
