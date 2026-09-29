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
    /// 生产 = GRDB `Record` 的自增主键（`QQPlayer/Models/DatabaseModels.swift` 的 `var id: Int64?`）。
    /// harness 的行一律无 id（= 「只有路径、查不到行」形态）：`DatabaseManager+ContentHash.swift`
    /// 的兜底回填只在有 id（= 真有行）时触发，故 harness 里回填分支恒不触发——与生产
    /// 「查不到行 → 只现算、不回填」同义。
    var id: Int64?
    var path: String
    var stableId: String
    var contentHash: String?
}

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()
    private var tracksByPath: [String: Track] = [:]
    private let lock = NSLock()

    func createTables() throws {}

    // ── 事务 API 面替身（生产 = GRDB `dbWriter.read/write`）──────────────────────
    //
    // `DatabaseManager+ContentHash.swift`（批 B 的唯一指纹兜底入口）在 harness **真跑**的
    // 路径上（`SyncLocalLibraryScanner.sourceFiles` → `resolvedContentHash`），不能黑名单化
    // ⇒ 必须真编；它除纯逻辑外还用 `read`/`write` 两处真 GRDB 事务 API。生产 `DatabaseManager`
    // （真 GRDB）编不进命令行，故这里给出**类型面**替身：签名与生产逐字同形
    // （`func read<T>(_ operation: @escaping (Database) throws -> T) throws -> T`），
    // 语义 = 直接把替身句柄交给闭包（harness 不覆盖落库/游标层，与既有空桩口径一致）。
    func read<T>(_ operation: @escaping (Database) throws -> T) throws -> T {
        try operation(Database())
    }

    func write<T>(_ operation: @escaping (Database) throws -> T) throws -> T {
        try operation(Database())
    }

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

// MARK: - GRDB 事务/查询 API 面替身（同上：让 `DatabaseManager+ContentHash.swift` 真编进 harness）
//
// 生产 = GRDB `Database`（`read`/`write` 闭包的参数类型）与 `QueryInterfaceRequest<Track>`
// （`Track.filter(sql:)` 的返回）。本 harness 的 GRDB 模块桩（GRDBShim.swift）只有两个
// Record 协议，故这两个类型在夹具里给出：**只保证类型面**，语义空转（harness 不覆盖
// 游标/落库层）。**不许**在这里实现 SQL 语义。

/// 生产 = GRDB `Database`。
final class Database {
    /// 生产同形 `func execute(sql: String, arguments: StatementArguments = …)`。
    func execute(sql: String, arguments: [Any?] = []) throws {}
}

/// 生产 = GRDB `QueryInterfaceRequest<Track>`。
struct TrackQuery {
    /// 生产同形 `fetchAll(_ db: Database) throws -> [Track]`；harness 空库 ⇒ 恒空集
    /// （= 「表里没有 `content_hash IS NULL` 的行」，回填路径因此不写库）。
    func fetchAll(_ db: Database) throws -> [Track] { [] }
}

extension Track {
    /// 生产 = GRDB `FetchableRecord` 的 `static func filter(sql:arguments:)`。
    static func filter(sql: String) -> TrackQuery { TrackQuery() }
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
    static func live(database: DatabaseManager, libraryRoot: URL) -> SyncLyricsContentMapping { .unresolved }
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
    let libraryRoot: URL

    func contentHash(forTrackStableId stableId: String) throws -> String? { nil }

    func trackStableId(forContentHash contentHash: String) throws -> String? { nil }

    func trackIdentity(atAbsolutePath path: String) throws -> (stableId: String, contentHash: String?)? { nil }

    func remoteTrackIdentity(forTrackStableId stableId: String) throws -> SyncRemoteTrackIdentity? { nil }

    func localizeRemoteTrack(_ identity: SyncRemoteTrackIdentity) throws -> SyncLocalTrackOutcome {
        .unresolved
    }
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

    /// 生产 = 分平台缺省曲库根（macOS `MacLibraryRoot.resolvedRootURL` / iOS 沙盒
    /// `Documents/Music`，见 `Services/DatabaseSyncCollectionFacts.swift`）——那个文件
    /// 依赖 macOS-only 的 `MacLibraryRoot`（`QQPlayer/Mac/**`，不在候选池）与真 GRDB 的
    /// `DatabaseManager.getAllPlaylists()`，编不进命令行，故由本同形桩替代
    ///（`static var defaultLibraryRoot: URL`）。harness 不跑启动回填路径，故取值不参与断言。
    static var defaultLibraryRoot: URL {
        FileManager.default.temporaryDirectory
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

// MARK: - SyncChangeLogReplay（生产在 QQPlayer/Sync/SyncChangeLogPendingStore.swift）
//
// 生产文件已在黑名单（`Column` + `.fetchAll(db)` 真 GRDB 查询），故其重放入口由本桩替代：
// 签名与生产逐字同形（`replay(pendingKey:database:libraryRoot:) throws -> Int`）。
// harness 只消费它的**签名**（`DatabaseManager+ContentHash.swift` 的启动回填路径调用它），
// 而 harness 不跑启动回填 ⇒ 同形替身恒回 0（不重放任何挂起变更）。
// 需要重放断言的场景由夹具显式注入（同 `SyncContentHashResolver` / `SyncLyricsContentMapping` 口径）。

enum SyncChangeLogReplay {
    @discardableResult
    static func replay(pendingKey: String, database: DatabaseManager, libraryRoot: URL) throws -> Int {
        0
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
