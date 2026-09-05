//
//  TagWriterTests.swift
//  QQPlayerTests
//
//  标签写入服务集成测试（E1 标签刮削，S1）。
//  - SFB 写标签 round-trip：base64 fixture → TagWriterService.writeTags →
//    AudioMetadataParser.parseMetadata 读回断言（标题/歌手/专辑/年份/音轨）
//  - 原子性：不支持格式 → 抛错且原文件不动
//  - 改名：模板渲染/去重/子目录
//  - moveTrack：改名后的库内引用迁移
//  注：genre 字段由 S3 批加入解析器，本批断言不含 genre（写入侧用 SFB 重读断言）。
//

import Foundation
import GRDB
import SFBAudioEngine
import Testing

@testable import QQPlayer

struct TagWriterTests {
    // MARK: - Helpers

    private func tempFixture(_ ext: String) throws -> URL {
        switch ext {
        case "mp3": return try TestAudioFixtures.writeFixture("smoke", base64: TestAudioFixtures.mp3Empty, ext: "mp3")
        case "flac": return try TestAudioFixtures.writeFixture("smoke", base64: TestAudioFixtures.flacEmpty, ext: "flac")
        case "m4a": return try TestAudioFixtures.writeFixture("smoke", base64: TestAudioFixtures.m4aEmpty, ext: "m4a")
        default: fatalError("no fixture for \(ext)")
        }
    }

    private func readMetadata(_ url: URL) async throws -> QQPlayer.AudioMetadata {
        try await AudioMetadataParser.parseMetadata(from: url)
    }

    private func makeRequest(
        title: String? = nil, artist: String? = nil, album: String? = nil,
        genre: String? = nil, year: Int? = nil, track: Int? = nil,
        coverData: Data? = nil, removeCover: Bool = false,
        renameTemplate: String? = nil
    ) -> TagWriteRequest {
        TagWriteRequest(
            title: title, artist: artist, album: album, albumArtist: nil,
            genre: genre, year: year, trackNumber: track,
            coverData: coverData, removeCover: removeCover, renameTemplate: renameTemplate
        )
    }

    // MARK: - Round-trip（写 → AudioMetadataParser 读回）

    @Test("MP3 round-trip：全字段写入后读回一致（含 MP3 year 特例）")
    func mp3RoundTrip() async throws {
        let url = try tempFixture("mp3")
        let result = try TagWriterService.writeTags(
            to: url,
            request: makeRequest(
                title: "New Title", artist: "New Artist", album: "New Album",
                genre: "Rock", year: 2018, track: 3
            )
        )
        #expect(result.renamed == false)
        #expect(result.finalURL == url)

        let meta = try await readMetadata(url)
        #expect(meta.title == "New Title")
        #expect(meta.artist == "New Artist")
        #expect(meta.album == "New Album")
        #expect(meta.year == 2018)
        #expect(meta.trackNumber == 3)
    }

    @Test("FLAC round-trip：全字段写入后读回一致")
    func flacRoundTrip() async throws {
        let url = try tempFixture("flac")
        _ = try TagWriterService.writeTags(
            to: url,
            request: makeRequest(
                title: "FLAC Title", artist: "FLAC Artist", album: "FLAC Album",
                genre: "Jazz", year: 1999, track: 7
            )
        )
        let meta = try await readMetadata(url)
        #expect(meta.title == "FLAC Title")
        #expect(meta.artist == "FLAC Artist")
        #expect(meta.album == "FLAC Album")
        #expect(meta.year == 1999)
        #expect(meta.trackNumber == 7)
    }

    @Test("M4A round-trip：全字段写入后读回一致")
    func m4aRoundTrip() async throws {
        let url = try tempFixture("m4a")
        _ = try TagWriterService.writeTags(
            to: url,
            request: makeRequest(
                title: "M4A Title", artist: "M4A Artist", album: "M4A Album",
                genre: "Pop", year: 2010, track: 2
            )
        )
        let meta = try await readMetadata(url)
        #expect(meta.title == "M4A Title")
        #expect(meta.artist == "M4A Artist")
        #expect(meta.album == "M4A Album")
        #expect(meta.year == 2010)
        #expect(meta.trackNumber == 2)
    }

    @Test("封面：写入后 SFB 重读 attachedPictures 非空；removeCover 后为空")
    func coverWriteAndRemove() throws {
        let url = try tempFixture("flac")
        _ = try TagWriterService.writeTags(
            to: url,
            request: makeRequest(title: "Cover Song", coverData: TestAudioFixtures.png1x1)
        )
        let withCover = try SFBAudioEngine.AudioFile(readingPropertiesAndMetadataFrom: url)
        #expect(withCover.metadata.attachedPictures.isEmpty == false)

        _ = try TagWriterService.writeTags(
            to: url,
            request: makeRequest(title: "Cover Song", removeCover: true)
        )
        let withoutCover = try SFBAudioEngine.AudioFile(readingPropertiesAndMetadataFrom: url)
        #expect(withoutCover.metadata.attachedPictures.isEmpty)
    }

    @Test("genre 写入：SFB 重读断言（解析器 genre 字段由 S3 批加入）")
    func genreWriteViaSFB() throws {
        let url = try tempFixture("mp3")
        _ = try TagWriterService.writeTags(to: url, request: makeRequest(title: "G", genre: "Rock"))
        let audioFile = try SFBAudioEngine.AudioFile(readingPropertiesAndMetadataFrom: url)
        #expect(audioFile.metadata.genre == "Rock")
    }

    // MARK: - 原子性 / 错误

    @Test("不支持格式 → unsupportedFormat 且原文件不动")
    func unsupportedFormatLeavesFileIntact() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("x.wav")
        let original = Data("fake wav content".utf8)
        try original.write(to: url)

        #expect(throws: TagWriterError.self) {
            try TagWriterService.writeTags(to: url, request: makeRequest(title: "T"))
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("nil 字段保留文件原值（部分写语义：只写 genre 不动 title）")
    func partialWritePreservesOtherFields() async throws {
        let url = try tempFixture("flac")
        _ = try TagWriterService.writeTags(
            to: url,
            request: makeRequest(title: "Keep Me", artist: "Keep Artist", year: 2001)
        )
        // 第二次只写 genre——title/artist/year 应保留
        _ = try TagWriterService.writeTags(to: url, request: makeRequest(genre: "Blues"))
        let meta = try await readMetadata(url)
        #expect(meta.title == "Keep Me")
        #expect(meta.artist == "Keep Artist")
        #expect(meta.year == 2001)
        let audioFile = try SFBAudioEngine.AudioFile(readingPropertiesAndMetadataFrom: url)
        #expect(audioFile.metadata.genre == "Blues")
    }

    // MARK: - 改名

    @Test("改名：模板渲染改名，原路径消失，finalURL 指向新路径")
    func renameMovesFile() throws {
        let url = try tempFixture("mp3")
        let result = try TagWriterService.writeTags(
            to: url,
            request: makeRequest(
                title: "New Title", artist: "Some Artist",
                renameTemplate: TagWriterService.defaultRenameTemplate
            )
        )
        #expect(result.renamed)
        #expect(result.finalURL.lastPathComponent == "Some Artist - New Title.mp3")
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        #expect(FileManager.default.fileExists(atPath: result.finalURL.path))
    }

    @Test("改名去重：目标已存在 → (2) 递增，绝不覆盖")
    func renameDeduplicates() throws {
        let url = try tempFixture("mp3")
        let req = makeRequest(
            title: "Dup Title", artist: "Dup Artist",
            renameTemplate: TagWriterService.defaultRenameTemplate
        )
        let first = try TagWriterService.writeTags(to: url, request: req)
        // 造一个同名文件再写第二首（同目录另一首歌）
        let dir = url.deletingLastPathComponent()
        let second = dir.appendingPathComponent("second.mp3")
        try FileManager.default.copyItem(at: try tempFixture("mp3"), to: second)
        let secondResult = try TagWriterService.writeTags(to: second, request: req)
        #expect(first.finalURL.lastPathComponent == "Dup Artist - Dup Title.mp3")
        #expect(secondResult.finalURL.lastPathComponent == "Dup Artist - Dup Title (2).mp3")
    }

    // MARK: - moveTrack（DB 引用迁移）

    private static func makeManager() throws -> (DatabaseManager, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        return (manager, dbQueue)
    }

    @Test("moveTrack：path/stable_id 更新，favorite/playlist/history 引用跟随")
    func moveTrackMigratesReferences() throws {
        let (manager, dbQueue) = try Self.makeManager()
        let oldPath = "/m/old/Artist - Old.flac"
        let newPath = "/m/new/Artist - New.flac"
        let oldStable = DatabaseManager.generatePathStableId(forPath: oldPath)
        let newStable = DatabaseManager.generatePathStableId(forPath: newPath)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO track (stable_id, title, path) VALUES (?, 'T', ?)
            """, arguments: [oldStable, oldPath])
            try db.execute(sql: "INSERT INTO favorite (track_stable_id) VALUES (?)", arguments: [oldStable])
            try db.execute(sql: "INSERT INTO playlist_item (playlist_id, position, track_stable_id) VALUES (1, 0, ?)", arguments: [oldStable])
            try db.execute(sql: "INSERT INTO play_history (track_stable_id, played_at) VALUES (?, 100)", arguments: [oldStable])
        }

        try manager.moveTrack(from: oldPath, to: newPath)

        try dbQueue.read { db in
            let trackPath = try String.fetchOne(db, sql: "SELECT path FROM track WHERE stable_id = ?", arguments: [newStable])
            #expect(trackPath == newPath)
            let favCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorite WHERE track_stable_id = ?", arguments: [newStable])
            #expect(favCount == 1)
            let plCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_item WHERE track_stable_id = ?", arguments: [newStable])
            #expect(plCount == 1)
            let histCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play_history WHERE track_stable_id = ?", arguments: [newStable])
            #expect(histCount == 1)
            let oldCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE stable_id = ?", arguments: [oldStable])
            #expect(oldCount == 0)
        }
    }

    @Test("moveTrack：目标 stable_id 已被占用 → 引用合并进已存在者，旧行删除")
    func moveTrackMergesIntoExisting() throws {
        let (manager, dbQueue) = try Self.makeManager()
        let oldPath = "/m/old.flac"
        let newPath = "/m/existing.flac"
        let oldStable = DatabaseManager.generatePathStableId(forPath: oldPath)
        let newStable = DatabaseManager.generatePathStableId(forPath: newPath)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO track (stable_id, title, path) VALUES
                (?, 'Old', ?), (?, 'Existing', ?)
            """, arguments: [oldStable, oldPath, newStable, newPath])
            try db.execute(sql: "INSERT INTO favorite (track_stable_id) VALUES (?)", arguments: [oldStable])
        }

        try manager.moveTrack(from: oldPath, to: newPath)

        try dbQueue.read { db in
            let favCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorite WHERE track_stable_id = ?", arguments: [newStable])
            #expect(favCount == 1)
            let oldCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE stable_id = ?", arguments: [oldStable])
            #expect(oldCount == 0)
            let existingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE stable_id = ?", arguments: [newStable])
            #expect(existingCount == 1)
        }
    }

    @Test("moveTrack：旧路径无 track → 幂等无事")
    func moveTrackNoop() throws {
        let (manager, dbQueue) = try Self.makeManager()
        try manager.moveTrack(from: "/m/ghost.flac", to: "/m/ghost-new.flac")
        let count = try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") }
        #expect(count == 0)
    }
}
