//
//  MacSyncLibraryHost.swift
//  QQPlayer
//
//  局域网同步（S2）macOS Host 侧曲库接线（QQPlayerMac target only）：把「一个曲库根 +
//  一个已配对会话」接成可服务对端拉取的文件源。
//
//  R1b-1（2026-09-11）：协议行为（manifest 生成 / 越界拒读 / 歌词命名空间 / 多根 /
//  内容指纹回落）已**通用化移植**到平台无关的 `SyncLocalLibraryProvider`
//  （QQPlayer/Sync/SyncLocalLibraryProvider.swift），本文件退化为**薄装配**：
//    - 曲库根 ~/Music/QQPlayer（调用方可注入）+ DB / 歌词库 / 映射 → 装配描述符
//    - 描述符 → SyncLocalLibraryProvider（manifest 应答 + 按路径拉取应答 + 歌词根）
//    - 本文件只做「本端事实 → 描述符」的注入与生命周期（attach/detach）转发
//
//  ⚠️ 行为零变化约束（R1b-1 硬要求）：本文件的公开 API（libraryRoot / rootName /
//  init / attach / detach / manifest / lyricsRoot / sourceFiles / onFetchResult）
//  与语义保持与重构前完全一致——曲库根不存在仍拒绝接线，manifest 仍走
//  SyncLocalLibraryScanner 同口径，越界/软链仍一律拒。
//  （2026-09-12 审计 D1：无消费点的 onProviderUnavailable 已删，见下）
//
//  线程：会话线程（NW 队列）上会被同步调用（provider 立即要答案），因此本类不是
//  @MainActor；状态用锁保护。扫描是同步的（本地目录枚举，v1 接受）。
//

import Foundation

final class MacSyncLibraryHost: @unchecked Sendable {
    /// 曲库根（对端 manifest 相对路径的基准）。
    let libraryRoot: URL
    /// 曲库根显示名（manifest 响应附带，诊断/UI 用）。
    let rootName: String

    private let provider: SyncLocalLibraryProvider
    /// 歌单成员表 provider（T7b）：应答 `.playlists` manifest 时按需求值。
    private let membersProvider: () -> SyncCollectionMembers
    private let lock = NSLock()

    /// 一次拉取的结论（诊断/UI 用；M6 接进度展示）。
    var onFetchResult: ((SyncFetchResult) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return fetchResultHandler }
        set { lock.lock(); fetchResultHandler = newValue; lock.unlock() }
    }

    /// 对端请求了 manifest 但本地未接线（诊断）。
    /// 2026-09-12 审计 D1：该属性全仓无任何赋值/读取点（只有自身转发）——属「声明为
    /// 诊断用但没人接」的死链，已按死代码处置删除。

    private var fetchResultHandler: ((SyncFetchResult) -> Void)?

    init(
        libraryRoot: URL,
        rootName: String? = nil,
        database: DatabaseManager = .shared,
        fileManager: FileManager = .default,
        lyricsStore: AlignedLyricsStore = .shared,
        lyricsMapping: SyncLyricsContentMapping? = nil,
        membersProvider: (() -> SyncCollectionMembers)? = nil
    ) {
        self.libraryRoot = libraryRoot
        self.rootName = rootName ?? libraryRoot.lastPathComponent
        // T7b：默认接真实 DB 歌单成员表（`slug` → stableId 集合 + `@favorites`）。
        // 可注入：单测 / harness 用固定成员表（不碰 DB）。
        let members = membersProvider ?? DatabaseSyncCollectionFacts.liveMembersProvider(database: database)
        self.membersProvider = members
        // 默认走 M4-2a 的 SyncContentHashResolver（stable_id ↔ content_hash）
        let descriptor = SyncLocalLibraryDescriptor.live(
            libraryRoot: libraryRoot,
            rootName: self.rootName,
            database: database,
            fileManager: fileManager,
            lyricsStore: lyricsStore,
            lyricsMapping: lyricsMapping,
            // 赋给局部量再注入：闭包不捕获 self，避免 host ← provider ← descriptor
            // ← members 的引用环。
            members: members
        )
        self.provider = SyncLocalLibraryProvider(descriptor: descriptor, fileManager: fileManager)
        provider.onFetchResult = { [weak self] result in
            self?.onFetchResult?(result)
        }
    }

    // MARK: 接线 / 拆除

    /// 把一个已配对会话接上本曲库。曲库根不存在 → 不接线，返回 false。
    @discardableResult
    func attach(to session: SyncPeerSession) -> Bool {
        provider.attach(to: session)
    }

    /// 拆除接线（会话关闭 / 服务停止）：manifest 提供者置 nil（未接线 → 不应答，
    /// 绝不回空表）+ 中止进行中的推送。
    func detach() {
        provider.detach()
    }

    // MARK: manifest（会话线程同步调用）

    /// 曲库根全量 manifest 经集合过滤后的条目（供 SyncManifestPeer 应答）。
    /// - Parameter members: 显式成员表（测试/诊断覆盖用）；`nil`（缺省）= 走本实例
    ///   装配的成员表（T7b：生产 = 真实歌单成员，且只在 `.playlists` 时求值）。
    func manifest(
        collection: SyncCollection,
        members: SyncCollectionMembers? = nil
    ) -> [ManifestEntry] {
        provider.manifest(collection: collection, members: members)
    }

    /// aligned 歌词根：与 `AlignedLyricsStore` 同一目录（库目录不可解析 → nil，
    /// 即本次不服务歌词命名空间）。
    var lyricsRoot: URL? { provider.lyricsRoot }

    /// 扫描曲库根 → manifest 生成输入（共享采集器，iOS 对账侧同一口径）。
    func sourceFiles() -> [SyncManifestSourceFile] {
        provider.sourceFiles()
    }
}
