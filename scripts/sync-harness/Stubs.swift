//
//  Stubs.swift — 本地 harness 专用桩（**不参与 App target 编译**）
//
//  目的：用 swiftc 直编生产源码（QQPlayer/Sync/*）跑端到端断言，而不启动模拟器。
//  生产代码只依赖少数 GRDB/IO 类型，这里给出最小可用替身；被测逻辑本身全部是
//  真实源码文件（见 run-local-sync-tests.sh 的编译列表）。
//

import Foundation

// MARK: - Track / DatabaseManager（生产为 GRDB Record）

struct Track {
    var path: String
    var stableId: String
    var contentHash: String?
}

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()
    private var tracksByPath: [String: Track] = [:]
    private let lock = NSLock()

    func createTables() throws {}

    func getTrack(byPath path: String) throws -> Track? {
        lock.lock()
        defer { lock.unlock() }
        return tracksByPath[path]
    }

    func deleteTrack(byStableId stableId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        tracksByPath = tracksByPath.filter { $0.value.stableId != stableId }
    }

    func seed(track: Track) {
        lock.lock()
        tracksByPath[track.path] = track
        lock.unlock()
    }

    static func contentHashIfFilePresent(atPath path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? SyncFileChecksum.sha256Hex(ofFile: URL(fileURLWithPath: path))
    }
}

// MARK: - DeviceStore（生产走 GRDB；harness 只用内存信任表 MemoryTrustStore）
//
// SyncSessionModels.swift 里有 `extension DeviceStore: SyncTrustStore`，
// 故类型必须存在（形态对齐生产签名）。PeerDevice 用生产源码 PairingModels.swift
// 里的真实现，不在此重复声明。

final class DeviceStore: @unchecked Sendable {
    private var records: [String: PeerDevice] = [:]

    func byPeerID(_ peerID: String) throws -> PeerDevice? { records[peerID] }
    func upsert(_ device: PeerDevice) throws { records[device.peerID] = device }
    func remove(peerID: String) throws { records[peerID] = nil }
}

// MARK: - 扫描/设置桩

struct DeleteSettings {
    var audioExtensions: [String] = []

    static func load() -> DeleteSettings { DeleteSettings() }
}

enum LibraryAudioFormats {
    static let defaultEnabled: [String] = ["flac", "mp3", "m4a", "wav", "opus", "ogg", "dsf", "dff", "aac"]
}

// MARK: - SyncLyricsContentMapping.live（生产在 SyncChangeLogMapping.swift，未被 harness 编入）
//
// 生产实现走 SyncContentHashResolver（GRDB）；harness 的 DatabaseManager 是内存桩，无
// content_hash 查询，故这里给出等价签名的空映射——需要映射的断言由夹具显式注入
// （main.swift 的 mapping(of:)），不走本默认值。

extension SyncLyricsContentMapping {
    static func live(database: DatabaseManager) -> SyncLyricsContentMapping { .unresolved }
}

// MARK: - DatabaseSyncCollectionFacts.liveMembersProvider（生产在 Services/，未被 harness 编入）
//
// T7b（2026-09-11）起 `SyncLibraryPassiveHost` / `SyncLocalLibraryProvider` 的默认歌单
// 成员表走 `DatabaseSyncCollectionFacts.liveMembersProvider(database:)`（生产实现走
// GRDB 查歌单）。harness 的 DatabaseManager 是内存桩、没有歌单表，故这里给出等价签名
// 的空成员表——harness 断言不覆盖 `.playlists` 收口径（该路径由 QQPlayerTests 的
// `SyncPlaylistMembersTests` 真跑 GRDB 覆盖），行为与 T7b 之前一致（空表）。
enum DatabaseSyncCollectionFacts {
    static func liveMembersProvider(database: DatabaseManager) -> () -> SyncCollectionMembers {
        { SyncCollectionMembers() }
    }
}

// MARK: - LibraryIndexer（生产为 @MainActor 服务；harness 记录调用）

final class LibraryIndexer: @unchecked Sendable {
    static let shared = LibraryIndexer()
    private let lock = NSLock()
    private(set) var processedPaths: [String] = []

    func processExternalFile(_ fileURL: URL) async -> Bool {
        lock.lock()
        processedPaths.append(fileURL.path)
        lock.unlock()
        return true
    }
}
