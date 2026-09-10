//
//  SyncLibraryPassiveTests.swift
//  QQPlayerTests
//
//  R1b-1（2026-09-11）同步方向改造 · 被动侧能力（iOS = 被动端，发起方恒为 Mac）：
//    Mac 侧（测试内驱动）= 发 manifest_request / sync_fetch_request / library_push_announce
//    被动端（被测）= SyncLibraryPassiveHost（应答 + 接收落位 + 入库）
//
//  覆盖：
//    ① 应答 Mac 的 manifest 请求（本端曲库 + aligned 歌词命名空间）
//    ② 应答文件请求（回推内容一致）+ 越界拒读（绝对路径 / `..` / 软链逃逸）
//    ③ 接收推送 → 落位 + 走既有入库入口 + **不传播删除** + 未声明传输不落位
//    ④ 歌词推送：按 content_hash 映射落到本端 stableId；本端无歌 → 丢弃不写孤儿
//    ⑤ 推送声明模型 / 认领表（纯逻辑）
//    ⑥ 曲库根不存在 → 不接线（绝不回空 manifest）
//
//  fixture 复用 SyncPeerSessionTestSupport.swift（SessionFixture 双 ready 回环）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - 夹具

/// 入库入口 spy（断言「走既有 LibraryIndexer 入口」这件事本身）。
private final class PassiveSinkSpy: SyncLibrarySyncSink, @unchecked Sendable {
    private let lock = NSLock()
    private var indexedPaths: [String] = []

    var indexed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return indexedPaths
    }

    func indexLandedFile(at url: URL) {
        lock.lock()
        indexedPaths.append(url.path)
        lock.unlock()
    }
}

/// 收集 Mac 侧收到的 sync_fetch_result（假 Mac 侧）。
private final class FetchResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SyncFetchResult?
    private var priorHandler: ((SyncFrame) -> Void)?

    init(session: SyncPeerSession) {
        priorHandler = session.onApplicationFrame
        session.onApplicationFrame = { [weak self] frame in
            guard let self else { return }
            if frame.type == .syncFetchResult,
               let decoded = try? SyncFetchCodec.decode(SyncFetchResult.self, from: frame.payload) {
                self.lock.lock()
                self.value = decoded
                self.lock.unlock()
            }
            self.priorHandler?(frame)
        }
    }

    var result: SyncFetchResult? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class TransferOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SyncFileReceiver.Outcome] = []

    var outcomes: [SyncFileReceiver.Outcome] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(_ outcome: SyncFileReceiver.Outcome) {
        lock.lock()
        values.append(outcome)
        lock.unlock()
    }
}

// MARK: - 测试

@MainActor
struct SyncLibraryPassiveTests {
    // MARK: 夹具辅助

    private func makeTempRoot(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-sync-r1b-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeFile(_ relativePath: String, in root: URL, data: Data) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }

    private func silentData(_ marker: UInt8, count: Int) -> Data {
        Data(repeating: marker, count: count)
    }

    private func makeManager() throws -> DatabaseManager {
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        return manager
    }

    private func sha256(of data: Data) throws -> String {
        let url = try writeFile("hash-\(UUID().uuidString)", in: try makeTempRoot("hash"), data: data)
        return try SyncFileChecksum.sha256Hex(ofFile: url)
    }

    private func mapping(songHash: String, stableId: String) -> SyncLyricsContentMapping {
        SyncLyricsContentMapping(
            contentHashForStableId: { $0 == stableId ? songHash : nil },
            stableIdForContentHash: { $0 == songHash ? stableId : nil }
        )
    }

    // MARK: ① 应答 manifest

    @Test("被动端应答 Mac 的 manifest 请求：本端曲库 + aligned 歌词命名空间")
    func answersManifestWithLibraryAndLyricsNamespace() throws {
        let song = silentData(0x71, count: 4_096)
        let songHash = try sha256(of: song)
        let deviceRoot = try makeTempRoot("manifest")
        try writeFile("Album/01 Song.flac", in: deviceRoot, data: song)
        try writeFile("Imported/device-only.flac", in: deviceRoot, data: silentData(0x72, count: 512))

        let lyricsStore = AlignedLyricsStore(directory: try makeTempRoot("lyrics"))
        try lyricsStore.write(
            Lyrics(plainLyrics: "设备侧歌词", syncedLyrics: [], isInstrumental: false, source: .lrclib),
            forStableId: "device-sid"
        )

        let fixture = SessionFixture.pairedHandshake()
        let host = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: PassiveSinkSpy(),
            database: try makeManager(),
            lyricsStore: lyricsStore,
            lyricsMapping: mapping(songHash: songHash, stableId: "device-sid")
        )
        #expect(host.attach(to: fixture.clientSession))

        let macPeer = SyncManifestPeer(session: fixture.hostSession)
        var response: SyncManifestResponse?
        macPeer.onManifestReceived = { response = $0 }
        try macPeer.requestManifest()

        #expect(
            response?.entries.map(\.relativePath)
                == ["@lyrics/\(songHash).json", "Album/01 Song.flac", "Imported/device-only.flac"]
        )
    }

    // MARK: ② 应答文件请求 + 越界拒读

    @Test("被动端应答文件请求：回推内容一致；绝对路径/`..`/软链逃逸一律拒读")
    func answersFetchRequestAndRejectsOutOfRoot() throws {
        let song = silentData(0x73, count: 300_000)
        let songHash = try sha256(of: song)
        let deviceRoot = try makeTempRoot("fetch")
        try writeFile("Album/01 Song.flac", in: deviceRoot, data: song)

        let outsideRoot = try makeTempRoot("outside")
        let outsideFile = try writeFile("secret.flac", in: outsideRoot, data: silentData(0x74, count: 32))
        try FileManager.default.createSymbolicLink(
            at: deviceRoot.appendingPathComponent("escape.flac"),
            withDestinationURL: outsideFile
        )

        let fixture = SessionFixture.pairedHandshake()
        let host = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: PassiveSinkSpy(),
            database: try makeManager()
        )
        #expect(host.attach(to: fixture.clientSession))

        let macIncoming = try makeTempRoot("mac-incoming")
        let macReceiver = SyncFileReceiver(session: fixture.hostSession, directory: macIncoming)
        let outcomes = TransferOutcomeBox()
        macReceiver.onCompletion = { outcomes.append($0) }
        let resultBox = FetchResultBox(session: fixture.hostSession)

        let request = SyncFetchRequest(
            collection: .all,
            relativePaths: ["Album/01 Song.flac", "/etc/passwd", "../escape.flac", "escape.flac"]
        )
        try fixture.hostSession.sendApplicationFrame(
            type: .syncFetchRequest,
            payload: try SyncFetchCodec.encode(request)
        )

        let result = try #require(resultBox.result)
        #expect(result.completed == ["Album/01 Song.flac"])
        let reasons = Dictionary(uniqueKeysWithValues: result.failed.map { ($0.relativePath, $0.reason) })
        #expect(reasons["/etc/passwd"] == SyncFetchFailureReason.invalidPath)
        #expect(reasons["../escape.flac"] == SyncFetchFailureReason.invalidPath)
        #expect(reasons["escape.flac"] == SyncFetchFailureReason.outOfRoot)

        let downloaded = macIncoming.appendingPathComponent("01 Song.flac")
        #expect(try SyncFileChecksum.sha256Hex(ofFile: downloaded) == songHash)
        #expect(outcomes.outcomes.count == 1)
    }

    // MARK: ③ 接收推送 → 落位 + 入库 + 不传播删除

    @Test("被动端接收 Mac 推送：落位 + 入库入口；对端未声明的本端内容保留")
    func receivesPushedFilesAndIndexes() throws {
        let deviceRoot = try makeTempRoot("push")
        try writeFile("Imported/device-only.flac", in: deviceRoot, data: silentData(0x81, count: 1_024))
        try writeFile("Album/tobe-updated.flac", in: deviceRoot, data: silentData(0x82, count: 1_024))

        let macRoot = try makeTempRoot("push-mac")
        let newSong = silentData(0x83, count: 300_000)
        let newURL = try writeFile("Pushed/new.flac", in: macRoot, data: newSong)
        let newHash = try SyncFileChecksum.sha256Hex(ofFile: newURL)
        let updatedURL = try writeFile("Album/tobe-updated.flac", in: macRoot, data: silentData(0x84, count: 2_048))
        let updatedHash = try SyncFileChecksum.sha256Hex(ofFile: updatedURL)

        let fixture = SessionFixture.pairedHandshake()
        let sink = PassiveSinkSpy()
        let host = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: sink,
            database: try makeManager()
        )
        #expect(host.attach(to: fixture.clientSession))

        let entries = [
            SyncPushEntry.make(relativePath: "Pushed/new.flac", fileID: newHash, sha256Hex: newHash, size: 1),
            SyncPushEntry.make(
                relativePath: "Album/tobe-updated.flac",
                fileID: updatedHash,
                sha256Hex: updatedHash,
                size: 1
            ),
        ].compactMap { $0 }
        #expect(entries.count == 2)

        try fixture.hostSession.sendApplicationFrame(
            type: .libraryPushAnnounce,
            payload: try SyncPushCodec.encode(SyncLibraryPushAnnounce(entries: entries))
        )
        let sender = SyncFileSender(session: fixture.hostSession)
        try sender.send(fileURL: newURL, fileID: newHash, name: "new.flac")
        try sender.send(fileURL: updatedURL, fileID: updatedHash, name: "tobe-updated.flac")

        let landed = deviceRoot.appendingPathComponent("Pushed/new.flac")
        #expect(FileManager.default.fileExists(atPath: landed.path))
        #expect(try SyncFileChecksum.sha256Hex(ofFile: landed) == newHash)
        #expect(
            try SyncFileChecksum.sha256Hex(ofFile: deviceRoot.appendingPathComponent("Album/tobe-updated.flac"))
                == updatedHash
        )
        // 不传播删除：对端没提到的本端文件一条都不动
        #expect(FileManager.default.fileExists(atPath: deviceRoot.appendingPathComponent("Imported/device-only.flac").path))
        #expect(sink.indexed.sorted() == [landed.path, deviceRoot.appendingPathComponent("Album/tobe-updated.flac").path].sorted())
        #expect(host.summary.landed.sorted() == ["Album/tobe-updated.flac", "Pushed/new.flac"])
        #expect(host.summary.batchCompleted)

        // 未声明的传输：不落位、不索引，落地目录无残渣
        let strayURL = try writeFile("Stray/orphan.flac", in: macRoot, data: silentData(0x85, count: 512))
        let strayHash = try SyncFileChecksum.sha256Hex(ofFile: strayURL)
        try fixture.hostSession.sendApplicationFrame(
            type: .libraryPushAnnounce,
            payload: try SyncPushCodec.encode(SyncLibraryPushAnnounce(entries: []))
        )
        try sender.send(fileURL: strayURL, fileID: strayHash, name: "orphan.flac")

        #expect(!FileManager.default.fileExists(atPath: deviceRoot.appendingPathComponent("Stray/orphan.flac").path))
        #expect(host.summary.undeclaredTransfers == ["orphan.flac"])
        #expect(sink.indexed.count == 2)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: deviceRoot.appendingPathComponent(".sync-incoming").path
        )
        #expect(leftovers.isEmpty)
    }

    // MARK: ④ 歌词推送

    @Test("被动端接收推送歌词：按 content_hash 映射落库；本端无歌 → 丢弃不写孤儿")
    func installsPushedLyricsAndDiscardsOrphans() throws {
        let songHash = String(repeating: "a", count: 64)
        let deviceRoot = try makeTempRoot("lyrics-device")
        let lyricsStore = AlignedLyricsStore(directory: try makeTempRoot("lyrics-store"))
        let macRoot = try makeTempRoot("lyrics-mac")
        let lyricsData = try JSONEncoder().encode(
            Lyrics(
                plainLyrics: "推送过来的歌词",
                syncedLyrics: [LyricsLine(timestamp: 1, text: "推送过来的歌词")],
                isInstrumental: false,
                source: .lrclib
            )
        )
        let lyricsURL = try writeFile("src.json", in: macRoot, data: lyricsData)
        let lyricsFileHash = try SyncFileChecksum.sha256Hex(ofFile: lyricsURL)
        let orphanHash = String(repeating: "b", count: 64)

        let fixture = SessionFixture.pairedHandshake()
        let sink = PassiveSinkSpy()
        let host = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: sink,
            database: try makeManager(),
            lyricsStore: lyricsStore,
            lyricsMapping: mapping(songHash: songHash, stableId: "device-sid")
        )
        #expect(host.attach(to: fixture.clientSession))

        let entries = [
            SyncPushEntry(
                relativePath: "@lyrics/\(songHash).json",
                transferName: "\(songHash).json",
                fileID: songHash,
                sha256Hex: lyricsFileHash,
                size: Int64(lyricsData.count)
            ),
            SyncPushEntry(
                relativePath: "@lyrics/\(orphanHash).json",
                transferName: "\(orphanHash).json",
                fileID: orphanHash,
                sha256Hex: lyricsFileHash,
                size: Int64(lyricsData.count)
            ),
        ]
        try fixture.hostSession.sendApplicationFrame(
            type: .libraryPushAnnounce,
            payload: try SyncPushCodec.encode(SyncLibraryPushAnnounce(entries: entries))
        )
        let sender = SyncFileSender(session: fixture.hostSession)
        try sender.send(fileURL: lyricsURL, fileID: songHash, name: "\(songHash).json")
        try sender.send(fileURL: lyricsURL, fileID: orphanHash, name: "\(orphanHash).json")

        #expect(try lyricsStore.read(forStableId: "device-sid")?.plainLyrics == "推送过来的歌词")
        #expect(sink.indexed.isEmpty) // 歌词不走曲库入库入口
        #expect(host.summary.discardedLyrics == ["@lyrics/\(orphanHash).json"])
        #expect(lyricsStore.stableIds() == ["device-sid"])
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: deviceRoot.appendingPathComponent(".sync-incoming").path
        )
        #expect(leftovers.isEmpty)
    }

    // MARK: ⑤ 声明模型 / 认领表

    @Test("推送声明模型：路径拒绝逃逸/隐藏名，认领表同名取首个未认领")
    func pushModelsRejectUnsafePathsAndClaimByName() throws {
        #expect(SyncPushEntry.make(relativePath: "../escape.flac", fileID: "h", sha256Hex: "h", size: 1) == nil)
        #expect(SyncPushEntry.make(relativePath: "/abs.flac", fileID: "h", sha256Hex: "h", size: 1) == nil)
        #expect(SyncPushEntry.make(relativePath: "Album/.hidden.flac", fileID: "h", sha256Hex: "h", size: 1) == nil)
        #expect(
            SyncPushEntry.make(relativePath: "Album/./01.flac", fileID: "h", sha256Hex: "h", size: 1)?.relativePath
                == "Album/01.flac"
        )

        let dup = SyncPushEntry(
            relativePath: "Album/01.flac", transferName: "01.flac", fileID: "a", sha256Hex: "a", size: 1
        )
        let invalid = SyncPushEntry(
            relativePath: "../x.flac", transferName: "x.flac", fileID: "b", sha256Hex: "b", size: 1
        )
        #expect(SyncLibraryPushAnnounce(entries: [dup, invalid, dup]).entries.map(\.relativePath) == ["Album/01.flac"])
        #expect(SyncLibraryPushAnnounce(entries: []).isEmpty)

        let a = SyncPushEntry(relativePath: "A/dup.flac", transferName: "dup.flac", fileID: "a", sha256Hex: "a", size: 1)
        let b = SyncPushEntry(relativePath: "B/dup.flac", transferName: "dup.flac", fileID: "b", sha256Hex: "b", size: 1)
        var table = SyncPushClaimTable(entries: [a, b])
        #expect(table.claim(transferName: "dup.flac") == "A/dup.flac")
        #expect(table.claim(transferName: "dup.flac") == "B/dup.flac")
        #expect(table.claim(transferName: "dup.flac") == nil)
        #expect(table.isEmpty)

        // 帧 14 新编号；既有帧值语义不动
        #expect(SyncFrameType.libraryPushAnnounce.rawValue == 14)
        #expect(SyncFrameType.syncFetchResult.rawValue == 13)
        let roundTrip = try SyncPushCodec.decode(
            SyncLibraryPushAnnounce.self,
            from: try SyncPushCodec.encode(SyncLibraryPushAnnounce(entries: [dup]))
        )
        #expect(roundTrip.entries.map(\.relativePath) == ["Album/01.flac"])
    }

    // MARK: ⑥ 曲库根不存在

    @Test("被动端：曲库根不存在 → 不接线，且不应答 manifest（绝不回空表）")
    func doesNotAttachWhenLibraryRootMissing() throws {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-sync-r1b-missing-\(UUID().uuidString)", isDirectory: true)
        let fixture = SessionFixture.pairedHandshake()
        let host = SyncLibraryPassiveHost(
            libraryRoot: missingRoot,
            sink: PassiveSinkSpy(),
            database: try makeManager()
        )
        #expect(!host.attach(to: fixture.clientSession))
        #expect(!host.isAttached)

        let macPeer = SyncManifestPeer(session: fixture.hostSession)
        var response: SyncManifestResponse?
        macPeer.onManifestReceived = { response = $0 }
        try macPeer.requestManifest()
        #expect(response == nil)
    }
}
