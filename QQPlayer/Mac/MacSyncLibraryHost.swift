//
//  MacSyncLibraryHost.swift
//  QQPlayer
//
//  局域网同步（S2, M3-3b）macOS Host 侧曲库接线（QQPlayerMac target only）：
//  把「一个曲库根 + 一个已配对会话」接成可服务对端拉取的文件源——
//    - manifest：SyncManifestPeer.localManifestProvider = 扫曲库根（复用
//      MusicDirectoryScanner 同步扫描）→ SyncManifestGenerator.generate →
//      collection.filter；content_hash / stableId 走 DatabaseManager 现有入口
//      （getTrack(byPath:) 命中即用；未指纹回落到 contentHashIfFilePresent）
//    - 拉取：SyncLibraryFetchResponder（越界拒读 + 串行 SyncFileSender 推送）
//
//  本文件只做「本端事实 → 协议钩子」的装配，不含协议逻辑（那些在 Sync/ 下的
//  共享文件里，可单测）；IO/DB 细节集中在此，Mac target 编译，iOS target 排除。
//
//  线程：会话线程（NW 队列）上会被同步调用（provider 立即要答案），因此本类
//  不是 @MainActor；状态用锁保护。扫描是同步的（本地目录枚举，v1 接受）。
//
//  安全护栏：曲库根不存在 → 拒绝接线（返回 false）——宁可不服务（对端超时），
//  也绝不给「空 manifest」（空表会被对端解读为"远端文件全没了"而误删）。
//

import Foundation

final class MacSyncLibraryHost: @unchecked Sendable {
    /// 曲库根（对端 manifest 相对路径的基准）。
    let libraryRoot: URL
    /// 曲库根显示名（manifest 响应附带，诊断/UI 用）。
    let rootName: String

    private let database: DatabaseManager
    private let fileManager: FileManager
    private let lock = NSLock()
    private var manifestPeer: SyncManifestPeer?
    private var responder: SyncLibraryFetchResponder?

    /// 一次拉取的结论（诊断/UI 用；M6 接进度展示）。
    var onFetchResult: ((SyncFetchResult) -> Void)?
    /// 对端请求了 manifest 但本地未接线（诊断）。
    var onProviderUnavailable: (() -> Void)?

    init(
        libraryRoot: URL,
        rootName: String? = nil,
        database: DatabaseManager = .shared,
        fileManager: FileManager = .default
    ) {
        self.libraryRoot = libraryRoot
        self.rootName = rootName ?? libraryRoot.lastPathComponent
        self.database = database
        self.fileManager = fileManager
    }

    // MARK: 接线 / 拆除

    /// 把一个已配对会话接上本曲库。曲库根不存在 → 不接线，返回 false。
    @discardableResult
    func attach(to session: SyncPeerSession) -> Bool {
        guard fileManager.fileExists(atPath: libraryRoot.path) else { return false }

        let peer = SyncManifestPeer(session: session)
        peer.localRootName = { [weak self] in self?.rootName }
        peer.localManifestProvider = { [weak self] collection in
            self?.manifest(collection: collection) ?? []
        }
        peer.onProviderUnavailable = { [weak self] in self?.onProviderUnavailable?() }

        let responder = SyncLibraryFetchResponder(
            session: session,
            libraryRoot: libraryRoot,
            fileManager: fileManager,
            contentHashProvider: { [weak self] relativePath in
                self?.contentHash(relativePath: relativePath)
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

    // MARK: manifest（会话线程同步调用）

    /// 曲库根全量 manifest 经集合过滤后的条目（供 SyncManifestPeer 应答）。
    func manifest(collection: SyncCollection, members: SyncCollectionMembers = SyncCollectionMembers()) -> [ManifestEntry] {
        SyncLocalLibraryScanner.entries(
            in: libraryRoot,
            collection: collection,
            members: members,
            database: database,
            fileManager: fileManager
        )
    }

    /// 扫描曲库根 → manifest 生成输入（共享采集器，iOS 对账侧同一口径）。
    func sourceFiles() -> [SyncManifestSourceFile] {
        SyncLocalLibraryScanner.sourceFiles(in: libraryRoot, database: database, fileManager: fileManager)
    }

    // MARK: DB 事实（复用既有入口，不新写查询）

    /// 相对路径 → content_hash：优先用库里已存指纹；没有则现算一次 SHA-256
    /// （惰性回填语义，与 DatabaseManager.contentHashIfFilePresent 一致）。
    private func contentHash(relativePath: String) -> String? {
        let url = libraryRoot.appendingPathComponent(relativePath)
        if let stored = try? database.getTrack(byPath: url.path)?.contentHash, !stored.isEmpty {
            return stored
        }
        return DatabaseManager.contentHashIfFilePresent(atPath: url.path)
    }
}
