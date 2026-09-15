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

// MARK: - SyncContentHashResolver（生产在 SyncChangeLogMapping.swift，未被 harness 编入）
//
// 「歌曲身份解析」的唯一生产实现走 GRDB 的 track 表；harness 的 DatabaseManager 是内存
// 桩、没有 content_hash 查询，故这里给等价签名的空解析器（两向恒 nil）。harness 里需要
// 身份的断言一律显式注入夹具映射（main.swift 的 `mapping(of:)`）。
// 注意：本桩只被 `SyncLocalLibraryDescriptor.live` 引用，而 harness 从不调用它（自建
// 描述符），所以空实现不会影响任何断言。

struct SyncContentHashResolver: SyncIdentityResolving {
    let database: DatabaseManager

    func contentHash(forTrackStableId stableId: String) throws -> String? { nil }

    func trackStableId(forContentHash contentHash: String) throws -> String? { nil }
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

// MARK: - DatabaseSyncPeerLibraryFacts（生产在 Services/，未被 harness 编入）
//
// T9（2026-09-12）起 `SyncLibraryPassiveHost` 的默认内容清单 provider 走
// `DatabaseSyncPeerLibraryFacts.catalogProvider(database:libraryRoot:)`（生产实现查
// 真 DB 的 track/playlist 表）。harness 的 DatabaseManager 是内存桩、没有歌单/曲目表，
// 故这里给出等价签名的**空清单**——harness 的端到端断言显式注入内存清单
// （main.swift 的 SyncPeerLibraryCatalog），不走本默认值。
enum DatabaseSyncPeerLibraryFacts {
    static func catalogProvider(
        database: DatabaseManager,
        libraryRoot: URL,
        favoritesName: String? = nil
    ) -> () -> SyncPeerLibraryCatalog {
        { SyncPeerLibraryCatalog() }
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

// MARK: - SmartPlaylistKind（生产定义在 Services/SmartPlaylistStore.swift）
//
// 为什么是桩：`SyncBrowseSource.swift`（T11「来源挑歌」，2026-09-13）的
// `var smartPlaylistKind: SmartPlaylistKind` 需要这个类型，而它的生产宿主
// `Services/SmartPlaylistStore.swift` 是 **GRDB-SQL 重依赖**（`Database` / `Row.fetchAll`
// / `Track.fetchAll(db, sql:arguments:)` / `DatabaseManager.read`）——要在命令行编它，
// 桩里就得实现真 SQL 查询语义，等于再造一个数据库，不可行。
//
// 故按本文件既有模式（`Track` / `DatabaseManager` / `DeleteSettings` 等都是这么做的）
// 给出**与生产逐字同形**的替身：case 名、case 顺序、rawValue、协议一致性全部一致。
//
// ⚠️ 漂移防线（两道）：
// ① 编译期：`SyncBrowseSource.swift` 里按 case 的 switch 是穷尽式的，
//    桩少一个 case / 改名 → harness 直接编译失败。
// ② 运行期：`run-local-sync-tests.sh` 在编译前比对本声明与生产声明，不一致即报错退出
//    （防「生产新增 case 但桩没跟」这类编译期看不见的漂移）。

enum SmartPlaylistKind: String, CaseIterable, Identifiable {
    case recentAdded, recentPlayed, topPlayed, decades
    var id: String { rawValue }
}
