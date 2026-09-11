//
//  SyncLocalLibraryProvider.swift
//  QQPlayer
//
//  R1b-1（2026-09-11）同步方向改造 · **被动侧能力**（发起方恒为 Mac，移动端纯被动）
//
//  ════════════════════════════════════════════════════════════════════════════
//  块① 现有类型 → 新角色映射（docs/ 在本仓库被 gitignore，映射稿落在此处 + 报告复述）
//  ════════════════════════════════════════════════════════════════════════════
//
//  【复用，不动，两端共用】
//   - SyncManifest / SyncManifestRequest / SyncManifestResponse / SyncManifestCodec
//       → 协议载荷（帧 10/11）
//   - SyncManifestGenerator / SyncManifestReconciler / SyncCollection(+Members)
//       → 对账与集合过滤纯逻辑（对账键 = relativePath，身份键 = content_hash）
//   - SyncManifestPeer
//       → manifest 帧分发钩子（本地提供者 + 响应回发）；两端同一实现
//   - SyncLibraryFetchResponder（+ SyncLibrarySyncModels 的 SyncFetchRoots /
//     SyncLibraryPathResolver / 载荷 / 失败原因）
//       → 按路径拉取应答器：多根（曲库根 + 歌词根）、越界拒读（realpath + 前缀 +
//         软链逃逸）、歌词命名空间 `@lyrics/{歌曲 content_hash}.json`；两端同一实现
//   - SyncLocalLibraryScanner
//       → 本端曲库清单采集（两端同口径唯一入口）
//   - SyncAlignedLyrics / SyncLyricsNamespace / SyncLyricsContentMapping /
//     SyncAlignedLyricsManifest
//       → 歌词命名空间、映射注入、manifest 纳入（仅 aligned，§6.3）
//   - SyncFileSender / SyncFileReceiver / SyncFileChecksum / SyncFileTransferModels
//       → 停等文件传输（帧 4/5/6），两端同一实现
//   - SyncLibrarySyncSink（协议） + LibraryIndexerSyncSink
//       → 落库出口（走既有 LibraryIndexer 入口，不新造第二条索引路径）
//   - SyncListener / MacSyncHostService / PairingStateMachine / SyncIdentity / DeviceStore
//       → 会话与配对（本包不碰）
//
//  【通用化移植到平台无关层（本包新增／改造）】
//   - MacSyncLibraryHost 里「本端曲库事实 → 协议钩子」的装配逻辑（扫描、内容指纹、
//     歌词映射、根表、越界校验参数）提炼成本文件的 `SyncLocalLibraryProvider`
//     （+ `SyncLocalLibraryDescriptor`）——**曲库根 + 歌词根 + 扫描器 +
//     content_hash/stableId 映射注入**，Mac 与 iOS 各自装配；Mac 侧退化为薄包装
//     （`MacSyncLibraryHost`，公开 API 与行为零变化）。
//   - 「Mac 推送 → 本端接收落库」契约与编排（新帧 14 `library_push_announce` +
//     落盘/入库/歌词安装）提炼为 `SyncLibraryPassiveHost`（被动端装配，iOS 用）。
//   - 歌词接收安装（暂存重试 / 孤儿丢弃）从旧主动控制器提炼为 `SyncLyricsReceiver`
//     （拉取控制器与被动端共用同一实现）。
//
//  【R1b-2（2026-09-11）已退役 / 取代（本节为收口记录）】
//   - 旧 iOS 主动拉取链路（SyncLibrarySyncController + 其 planner / state machine /
//     configuration）已删除；发起方恒为 Mac —— `SyncLibraryPushController`（推送到设备）
//     / `SyncLibraryPullController`（从设备下载）承接，iOS 侧只留 `SyncLibraryPassiveHost`
//     单一被动入口（无 App 层装配引用，无需改线）。
//   - 落库出口（SyncLibrarySyncSink / LibraryIndexerSyncSink）搬到 `SyncLibrarySink.swift`。
//   - 既有测试与 harness 断言已改指新控制器（见 scripts/run-local-sync-tests.sh）。
//
//  ════════════════════════════════════════════════════════════════════════════
//
//  语义（docs/lan-sync-design.md §6.1 + §12b 决策 6-10）：
//  - 提供者只回答「本端有什么」与「按路径给文件」——**不发起任何同步**（发起方恒为 Mac）
//  - 曲库根不存在 → 拒绝接线（宁可不服务，也绝不回「空 manifest」——空表会被对端
//    误读为「远端全没了」）
//  - 「不传播删除」由发起方与接收方共同保证，提供者自身不存在删除通道
//
//  线程：会话线程（NW 队列）同步驱动；状态用锁保护。
//

import Foundation

// MARK: - 装配输入（平台无关 + 注入闭包）

/// 「本地曲库提供者」的装配输入：曲库根 + 歌词根 + 扫描器 + 映射注入。
///
/// Mac 与 iOS 各自装配（曲库根不同、DB 相同、歌词映射相同），装配差异只体现在
/// 这里的闭包与根路径上——协议行为（manifest 生成、越界拒读、歌词命名空间）由
/// `SyncLocalLibraryProvider` 单点实现，两端不可能漂移。
struct SyncLocalLibraryDescriptor {
    /// 曲库根（对端 manifest 相对路径的基准）
    var libraryRoot: URL
    /// 曲库根显示名（manifest 响应附带的诊断字段）
    var rootName: String
    /// aligned 歌词根（nil = 本端不服务歌词命名空间）
    var lyricsRoot: URL?
    /// 扫描本端曲库 → manifest 生成输入（注入：两端同口径走 SyncLocalLibraryScanner）
    var sourceFiles: () -> [SyncManifestSourceFile]
    /// aligned 歌词命名空间条目（未过滤；无歌词同步 = 空）
    var lyricsEntries: () -> [ManifestEntry]
    /// 曲库内相对路径 → content_hash（发送 fileID 用；缺失可回落现算）
    var contentHash: (String) -> String?
    /// wire 歌词路径（`@lyrics/{歌曲 content_hash}.json`）→ 本端库文件名（`{stableId}.json`）
    var lyricsFileName: (String) -> String?
    /// 歌单标识 → 成员 stableId 集合（T7b）：应答 `.playlists` manifest 时按需求值。
    /// 缺省空表 = 「歌单过滤不出内容」（接 DB 的装配方负责注入真实表，见
    /// `DatabaseSyncCollectionFacts.liveMembersProvider(database:)`）。
    var members: () -> SyncCollectionMembers

    init(
        libraryRoot: URL,
        rootName: String,
        lyricsRoot: URL? = nil,
        sourceFiles: @escaping () -> [SyncManifestSourceFile],
        lyricsEntries: @escaping () -> [ManifestEntry] = { [] },
        contentHash: @escaping (String) -> String? = { _ in nil },
        lyricsFileName: @escaping (String) -> String? = { _ in nil },
        members: (() -> SyncCollectionMembers)? = nil
    ) {
        self.libraryRoot = libraryRoot
        self.rootName = rootName
        self.lyricsRoot = lyricsRoot
        self.sourceFiles = sourceFiles
        self.lyricsEntries = lyricsEntries
        self.contentHash = contentHash
        self.lyricsFileName = lyricsFileName
        self.members = members ?? { SyncCollectionMembers() }
    }
}

extension SyncLocalLibraryDescriptor {
    /// 生产装配（Mac / iOS 通用）：曲库根 + 歌词库 + DB 既有入口。
    /// - 扫描/指纹：`SyncLocalLibraryScanner`（惰性回填语义）
    /// - 歌词：`AlignedLyricsStore`（仅 aligned）+ stable_id ↔ content_hash 映射
    /// - Parameter members: 歌单成员表 provider（T7b）。**应答 manifest 的装配方必须
    ///   传真实实现**（Mac：`MacSyncLibraryHost` / iOS：`SyncLibraryPassiveHost`），
    ///   否则 `.playlists` 集合会被滤成空清单。nil（缺省）= 空表，供发起端装配与
    ///   测试/harness 保持改造前行为。
    static func live(
        libraryRoot: URL,
        rootName: String? = nil,
        database: DatabaseManager = .shared,
        fileManager: FileManager = .default,
        lyricsStore: AlignedLyricsStore = .shared,
        lyricsMapping: SyncLyricsContentMapping? = nil,
        members: (() -> SyncCollectionMembers)? = nil
    ) -> SyncLocalLibraryDescriptor {
        let mapping = lyricsMapping ?? .live(database: database)
        return SyncLocalLibraryDescriptor(
            libraryRoot: libraryRoot,
            rootName: rootName ?? libraryRoot.lastPathComponent,
            lyricsRoot: lyricsStore.directory,
            sourceFiles: { [libraryRoot] in
                SyncLocalLibraryScanner.sourceFiles(
                    in: libraryRoot,
                    database: database,
                    fileManager: fileManager
                )
            },
            lyricsEntries: {
                SyncAlignedLyricsManifest.entries(store: lyricsStore, mapping: mapping)
            },
            contentHash: { [libraryRoot] relativePath in
                let url = libraryRoot.appendingPathComponent(relativePath)
                if let stored = try? database.getTrack(byPath: url.path)?.contentHash, !stored.isEmpty {
                    return stored
                }
                return DatabaseManager.contentHashIfFilePresent(atPath: url.path)
            },
            lyricsFileName: { wirePath in
                guard let songHash = SyncLyricsNamespace.songContentHash(fromWirePath: wirePath),
                      let stableId = mapping.stableIdForContentHash(songHash),
                      AlignedLyricsStore.isValidStableId(stableId)
                else { return nil }
                return "\(stableId).json"
            },
            members: members
        )
    }
}

// MARK: - 本地曲库提供者

/// 把「本端曲库事实」接成对端可请求的协议能力（**平台无关**，Mac / iOS 同一实现）：
/// - `manifest_request`（帧 10）→ 扫本端曲库 + 生成器 + 集合过滤 → `manifest_response`（帧 11）
/// - `sync_fetch_request`（帧 12）→ 越界拒读 + 串行推送 → `sync_fetch_result`（帧 13）
///
/// 行为与 R1b-1 之前的 `MacSyncLibraryHost` 装配完全一致（那正是本类的第一份实现），
/// 差别只在本类不绑定 Mac：装配输入全部来自 `SyncLocalLibraryDescriptor`。
final class SyncLocalLibraryProvider: @unchecked Sendable {
    let descriptor: SyncLocalLibraryDescriptor

    private let fileManager: FileManager
    private let lock = NSLock()
    private var manifestPeer: SyncManifestPeer?
    private var responder: SyncLibraryFetchResponder?

    /// 一次拉取（对端请求文件）的结论（诊断/UI 用）。
    var onFetchResult: ((SyncFetchResult) -> Void)?
    /// 对端请求了 manifest 但本地未接线（诊断）。
    var onProviderUnavailable: (() -> Void)?

    init(descriptor: SyncLocalLibraryDescriptor, fileManager: FileManager = .default) {
        self.descriptor = descriptor
        self.fileManager = fileManager
    }

    /// 曲库根（对端 manifest 相对路径的基准）。
    var libraryRoot: URL { descriptor.libraryRoot }
    /// 曲库根显示名。
    var rootName: String { descriptor.rootName }
    /// aligned 歌词根（nil = 不服务歌词命名空间）。
    var lyricsRoot: URL? { descriptor.lyricsRoot }
    /// 是否已接线（诊断用）。
    var isAttached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return manifestPeer != nil
    }

    // MARK: 接线 / 拆除

    /// 把一个已配对会话接上本曲库。曲库根不存在 → 不接线，返回 false。
    @discardableResult
    func attach(to session: SyncPeerSession) -> Bool {
        guard fileManager.fileExists(atPath: descriptor.libraryRoot.path) else { return false }

        let peer = SyncManifestPeer(session: session)
        peer.localRootName = { [weak self] in self?.descriptor.rootName }
        peer.localManifestProvider = { [weak self] collection in
            self?.manifest(collection: collection) ?? []
        }
        peer.onProviderUnavailable = { [weak self] in self?.onProviderUnavailable?() }

        let responder = SyncLibraryFetchResponder(
            session: session,
            roots: SyncFetchRoots(libraryRoot: descriptor.libraryRoot, lyricsRoot: descriptor.lyricsRoot),
            fileManager: fileManager,
            contentHashProvider: { [weak self] relativePath in
                self?.descriptor.contentHash(relativePath)
            },
            lyricsFileNameProvider: { [weak self] wirePath in
                self?.descriptor.lyricsFileName(wirePath)
            }
        )
        responder.onResultSent = { [weak self] result in self?.onFetchResult?(result) }

        lock.lock()
        manifestPeer = peer
        self.responder = responder
        lock.unlock()
        return true
    }

    /// 拆除接线（会话关闭 / 服务停止）：manifest 提供者置 nil（未接线 → 不应答，
    /// 绝不回空表）+ 中止进行中的推送。
    func detach() {
        lock.lock()
        let peer = manifestPeer
        let responder = self.responder
        manifestPeer = nil
        self.responder = nil
        lock.unlock()
        peer?.localManifestProvider = nil
        responder?.cancel()
    }

    // MARK: manifest

    /// 本端曲库根全量 manifest 经集合过滤后的条目（供 SyncManifestPeer 应答）。
    /// - Parameter members: 歌单成员表（T7b）。`nil`（缺省）= 按需构建：只有
    ///   `.playlists` 集合会向 descriptor 求值，`.all` / `.tracks` 零 DB 查询。
    func manifest(
        collection: SyncCollection,
        members: SyncCollectionMembers? = nil
    ) -> [ManifestEntry] {
        let library = SyncManifestGenerator.generate(files: descriptor.sourceFiles())
        return collection.filter(
            library + descriptor.lyricsEntries(),
            members: members ?? resolvedMembers(for: collection)
        )
    }

    /// 集合 → 歌单成员表（T7b）：**只有 `.playlists` 的非空选择需要 DB 展开**。
    ///
    /// 为什么按需求值而不是装配时构建/缓存：
    /// - 求值点在会话线程（应答 manifest 是同步调用），无关集合上不能白跑 DB；
    /// - 歌单成员随用户编辑而变，缓存会引入失效窗口；而每次同步只发一次
    ///   manifest 请求，按需读的是本地索引查询（每歌单一次 `getPlaylistItems`），
    ///   总量 = 歌单数，成本与「一次请求」成正比，可接受（详情见任务报告）。
    private func resolvedMembers(for collection: SyncCollection) -> SyncCollectionMembers {
        guard collection.kind == .playlists, !collection.ids.isEmpty else {
            return SyncCollectionMembers()
        }
        return descriptor.members()
    }

    /// 扫描曲库根 → manifest 生成输入（诊断/测试用）。
    func sourceFiles() -> [SyncManifestSourceFile] {
        descriptor.sourceFiles()
    }
}
