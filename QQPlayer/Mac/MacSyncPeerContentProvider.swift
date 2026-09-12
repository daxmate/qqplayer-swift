//
//  MacSyncPeerContentProvider.swift
//  QQPlayer
//
//  T10（2026-09-12）同步页**对端内容提供者**（QQPlayerMac target only）——下载方向的
//  数据源：把「iPhone 上有什么」通过 T9 的清单协议（帧 15/16）取回来。
//
//  与 `MacSyncLocalContentProvider` 对称：ViewModel 只看两条提供者的同一套返回类型
//  （`[SyncUIPlaylistOption]` / `[SyncUITrackOption]` / `SyncUILibraryFacts`），
//  方向决定用哪条。
//
//  ⚠️ 客户端生命周期（T9 客户端的帧链约束，踩过就炸）：
//  `SyncPeerLibraryClient.attachHandlers()` 把客户端挂在会话的 `onApplicationFrame`
//  **链顶**，且转发闭包是 `guard let self else { return }` → **客户端释放会让整条链
//  断裂**（下层的 manifest 应答器 / 拉取器全部收不到帧）。因此：
//  1. 客户端**按会话复用**（`MacSyncPeerClientPool`），不随页面视图生灭；
//  2. `cancel()` 会永久废掉一个实例（契约：此后不可再用）→ 取消在途请求时
//     **换一个客户端**（旧的留在池里续命，链不断）。
//  3. `cancel()` 的语义是「唤醒所有在途请求」→ 调用方靠**代号（generation）**丢弃
//     过期响应，两者配合：真取消 + 绝不让旧响应覆盖新状态。
//
//  线程：`@MainActor`（UI 驱动的取数）；客户端内部自带锁，可在任意线程调。
//

import Foundation

/// 对端曲目一页（提供者返回；ViewModel 只做拼接与状态迁移）。
struct SyncUIPeerTrackPage: Equatable, Sendable {
    /// 本页曲目（保持对端页内序）
    var options: [SyncUITrackOption]
    /// 后面还有页
    var hasMore: Bool
    /// 该范围（含筛选）总条数
    var total: Int
    /// 对端曲库总曲目数（摘要）
    var libraryTrackCount: Int
    /// 对端曲库总大小（摘要）
    var librarySizeBytes: Int64
    /// 对端因上限截断（诊断）
    var truncated: Bool

    static let empty = SyncUIPeerTrackPage(
        options: [],
        hasMore: false,
        total: 0,
        libraryTrackCount: 0,
        librarySizeBytes: 0,
        truncated: false
    )
}

/// 每会话一份的 UI 客户端池（见文件头「客户端生命周期」）。
@MainActor
final class MacSyncPeerClientPool {
    static let shared = MacSyncPeerClientPool()

    /// 会话标识 → 当前客户端
    private var clients: [ObjectIdentifier: SyncPeerLibraryClient] = [:]
    /// 被 `cancel()` 退役但仍需**保活**的客户端（帧链不能断）；会话关闭时一并释放。
    private var retired: [ObjectIdentifier: [SyncPeerLibraryClient]] = [:]

    private init() {}

    /// 当前客户端（没有就建一个并挂链）。
    func client(for session: SyncPeerSession) -> SyncPeerLibraryClient {
        let key = ObjectIdentifier(session)
        if let existing = clients[key] { return existing }
        let client = SyncPeerLibraryClient(session: session)
        clients[key] = client
        client.onSessionClosed = { [weak self] in
            Task { @MainActor in self?.releaseAll(for: session) }
        }
        return client
    }

    /// 取消在途请求并换一个新客户端（旧客户端保留在池里，帧链不断）。
    @discardableResult
    func replace(for session: SyncPeerSession) -> SyncPeerLibraryClient {
        let key = ObjectIdentifier(session)
        if let old = clients[key] {
            old.cancel()
            retired[key, default: []].append(old)
        }
        clients[key] = nil
        return client(for: session)
    }

    /// 会话关闭：链已无意义（会话本身死了），整批释放。
    private func releaseAll(for session: SyncPeerSession) {
        let key = ObjectIdentifier(session)
        clients[key] = nil
        retired[key] = nil
    }
}

/// 对端内容读取（下载方向；一次会话一个实例）。
@MainActor
final class MacSyncPeerContentProvider {
    /// 每页条数（懒加载分页；协议上限 500，这里取 100 = 一屏多一点）。
    static let pageSize = SyncUIContentLimits.peerPageSize

    private let session: SyncPeerSession
    private let pool: MacSyncPeerClientPool
    private var client: SyncPeerLibraryClient

    /// ⚠️ `pool` 默认值写成 `nil` 再在 init 体内取 `.shared`：默认实参在**非隔离**
    /// 上下文求值，直接写 `= .shared` 会报「main actor-isolated static property 跨隔离引用」
    /// （与本仓库其它 `@MainActor` 类型的同一处理）。
    init(session: SyncPeerSession, pool: MacSyncPeerClientPool? = nil) {
        self.session = session
        let resolvedPool = pool ?? MacSyncPeerClientPool.shared
        self.pool = resolvedPool
        self.client = resolvedPool.client(for: session)
    }

    /// 是否就是这条会话（ViewModel 用它判断要不要重建提供者）。
    func matches(session: SyncPeerSession) -> Bool { self.session === session }

    /// 会话是否就绪（未就绪 → 请求前就会被客户端拒绝）。
    var isReady: Bool { session.isReady }

    // MARK: - 取数

    /// 对端歌单清单（含收藏伪歌单；本端语言显示收藏）。
    func loadPlaylistOptions(favoritesTitle: String) async throws -> [SyncUIPlaylistOption] {
        let items = try await client.fetchPlaylists()
        return SyncUIPeerContentMapper.playlistOptions(from: items, favoritesTitle: favoritesTitle)
    }

    /// 对端曲库摘要（曲目数 + 总大小）。
    func loadSummary() async throws -> SyncUIPeerSummaryFacts {
        let summary = try await client.fetchLibrarySummary()
        return SyncUIPeerSummaryFacts(trackCount: summary.trackCount, sizeBytes: summary.sizeBytes)
    }

    /// 对端曲目一页（`query` 空 = 全库；**搜索在对端执行**，本端不做过滤）。
    func loadTrackPage(query: String, offset: Int) async throws -> SyncUIPeerTrackPage {
        let normalized = SyncUISearchGate.normalize(query)
        let response = try await client.fetchTracks(
            playlistID: nil,
            query: normalized.isEmpty ? nil : normalized,
            offset: max(0, offset),
            limit: Self.pageSize
        )
        return SyncUIPeerTrackPage(
            options: SyncUIPeerContentMapper.trackOptions(from: response),
            hasMore: response.hasMore,
            total: response.total,
            libraryTrackCount: response.libraryTrackCount,
            librarySizeBytes: response.librarySizeBytes,
            truncated: response.truncated
        )
    }

    /// 取消在途请求（切方向 / 切歌单 / 关面板）：换新客户端继续可用（见文件头）。
    func cancelInFlight() {
        client = pool.replace(for: session)
    }
}
