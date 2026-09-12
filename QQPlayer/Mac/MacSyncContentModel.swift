//
//  MacSyncContentModel.swift
//  QQPlayer
//
//  T10（2026-09-12）同步页**内容面板**（QQPlayerMac target only）——「同步什么」。
//
//  ════════════════════════════════════════════════════════════════════════════
//  用户反馈（2026-09-12）与本次设计
//  ════════════════════════════════════════════════════════════════════════════
//  「我明明是从 iPhone 上下载，但是显示的内容是本地的曲库」——旧面板的内容源恒为
//  本端 DB，与方向无关。本类型把内容源做成**方向驱动**：
//  - 方向未选 → `source == .none`，内容区只显示引导（不显示任何一端的内容）；
//  - 上传 → `MacSyncLocalContentProvider`（本端 DB，行为与 T3 一致）；
//  - 下载 → `MacSyncPeerContentProvider`（对端 iPhone 清单，帧 15/16）。
//
//  大内容显示（用户要求）：顶部摘要（总数 + 总大小，来自对端）+ 列表懒加载分页
//  （页大小 100）+ 搜索（debounce 后带 query 请求对端，**不在本端过滤**）+
//  全曲库二次确认（下载方向用对端的数字）。绝不把全量条目一次性塞进 UI。
//
//  ⚠️ 与执行侧的分工：本类型只管「选什么」；「跑一次同步 / 进度 / 结果」在
//  `MacSyncRunViewModel`（执行侧订阅本类型的 `objectWillChange` 刷新按钮可用性）。
//
//  ⚠️ 文件规模：本文件属逻辑层（≤ 500 行）；超出就把对端/本端提供者再拆出去。
//

import Combine
import Foundation

@MainActor
final class MacSyncContentModel: ObservableObject {
    /// 搜索去抖时长（View 侧计时；与本地/对端两条路共用同一时长）。
    static let searchDebounceNanoseconds = SyncUIContentLimits.searchDebounceNanoseconds

    // MARK: 依赖

    private let hostCenter: SyncHostCenter
    private let selectionStore: SyncSelectionStore
    private let database: DatabaseManager
    private let libraryRoot: URL

    // MARK: 发布状态

    /// 当前内容源（方向驱动；`.none` = 方向未选 → 内容区显示引导）。
    @Published private(set) var source: SyncUIContentSource = .none
    /// 当前选择集（唯一事实源；按方向重建）。
    @Published private(set) var selection: SyncCollectionSelection = .playlists([])
    /// 选择集规模摘要（底部合计 / 全曲库二次确认文案）。
    @Published private(set) var selectionSummary: SyncUISelectionSummary = .empty
    /// 歌单选项（含「收藏」伪歌单，置顶）。
    @Published private(set) var playlistOptions: [SyncUIPlaylistOption] = []
    /// 单曲级选项（当前页 / 搜索结果）。
    @Published private(set) var trackOptions: [SyncUITrackOption] = []
    /// 单曲级是否还有下一页。
    @Published private(set) var hasMoreTracks = false
    /// 单曲级正在加载（翻页/搜索共用）。
    @Published private(set) var isLoadingTracks = false
    /// 单曲级搜索词（View 绑定；去抖到期后调用 `applySearch()`）。
    @Published var trackQuery = ""

    /// 歌单清单加载态（对端清单才有异步态；本端为 `.loaded`）。
    @Published private(set) var playlistState: SyncUIContentLoadState = .idle
    /// 单曲列表加载态（同上）。
    @Published private(set) var tracksState: SyncUIContentLoadState = .idle
    /// 对端曲库摘要加载态（失败只影响顶部摘要，不阻塞列表）。
    @Published private(set) var summaryState: SyncUIContentLoadState = .idle
    /// 对端曲库摘要事实（nil = 未加载/加载失败 → 显示占位）。
    @Published private(set) var peerFacts: SyncUIPeerSummaryFacts?

    // MARK: 内部状态

    /// 当前方向（由执行侧 `MacSyncRunViewModel.selectDirection` 驱动）。
    private(set) var direction: SyncTransferDirection?
    /// 本次内容会话的代号：切换方向 / 重建数据源即自增，**过期响应一律丢弃**
    /// （对端的响应可能晚于用户的下一步操作到达）。
    private var generation = 0
    private var trackOffset = 0
    private var searchGate = SyncUISearchGate()
    private var localFacts: SyncUILibraryFacts = .empty
    private let local: MacSyncLocalContentProvider
    private var peer: MacSyncPeerContentProvider?
    private var loadTask: Task<Void, Never>?
    /// 对端摘要请求句柄（审计 L6：修复前只有歌单/曲目两条存入 loadTask，摘要靠
    /// generation 丢弃结果——不对称，取消时也照应不到）
    private var summaryTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        hostCenter: SyncHostCenter? = nil,
        selectionStore: SyncSelectionStore = SyncSelectionStore(),
        database: DatabaseManager = .shared,
        libraryRoot: URL? = nil
    ) {
        // 默认值用 `nil` 而不是 `.shared`：默认实参在非隔离上下文求值，
        // 直接写 `= .shared` 会报「main actor-isolated property 跨隔离引用」
        // （Swift 6 语言模式下是错误）→ 在 init 体（MainActor）解析。
        let center = hostCenter ?? .shared
        self.hostCenter = center
        self.selectionStore = selectionStore
        self.database = database
        let root = libraryRoot ?? MusicFolderResolver.macDefaultFolderURL(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        self.libraryRoot = root
        self.local = MacSyncLocalContentProvider(database: database, libraryRoot: root)
        // 连接断开 → 对端内容失效（清掉对端清单，避免把上一台设备的内容留在屏上）。
        center.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.hostDidChange() }
            }
            .store(in: &cancellables)
    }

    // MARK: - 派生（View 只读）

    /// 当前选择集模式（三级）。
    var selectionMode: SyncUISelectionMode { SyncUISelectionMode.mode(for: selection) }

    /// 已选歌单标识（歌单级多选态）。
    var selectedPlaylistIDs: Set<String> { Set(selection.playlistIDs ?? []) }

    /// 已选相对路径（单曲级多选态）。
    var selectedTrackPaths: Set<String> { Set(selection.relativePaths ?? []) }

    /// 是否已选方向（内容区显示引导 vs 内容）。
    var hasDirection: Bool { source != .none }

    /// 是否需要连接（下载方向 + 未连接）→ UI 提示「请先连接 iPhone」。
    var needsPeerConnection: Bool {
        SyncUIContentSourceResolver.requiresPeer(for: direction) && hostCenter.connectedPeer == nil
    }

    /// 内容区当前错误（对端清单加载失败时取第一条；本端无异步错误）。
    var contentFailure: SyncUIPeerContentError? {
        playlistState.failure ?? tracksState.failure ?? summaryState.failure
    }

    // MARK: - 方向（内容源切换）

    /// 切方向：**清空并重建选择集与选项**，然后按新数据源加载。
    ///
    /// 为什么必须清空：两个方向的标识空间不同——上传时勾的是**本端**歌单 slug /
    /// 本端相对路径，下载时勾的是**对端** slug / 对端相对路径。跨方向保留会让
    /// 「另一端不存在的歌单」继续挂在选择集里（UI 显示未知歌单、同步白跑一趟）。
    func switchDirection(to direction: SyncTransferDirection) {
        guard self.direction != direction else { return }
        self.direction = direction
        source = SyncUIContentSourceResolver.source(for: direction)
        resetContentState()
        clearSelection(persist: true)
        loadContent()
    }

    /// 不用了（会话断开 / 页面重来）：清空对端清单，回到方向未选前的空态。
    func detachContent() {
        resetContentState()
        clearSelection(persist: true)
    }

    // MARK: - 生命周期

    /// 不用了（页面关闭 / 会话断开）：取消在途请求，回到空态。
    func onDisappear() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        summaryTask?.cancel()
        summaryTask = nil
        peer?.cancelInFlight()
    }

    /// 重试对端清单（UI 的失败态重试入口）。
    func retryPeerContent() {
        guard source == .peer else { return }
        loadContent()
    }

    // MARK: - 选择集

    /// 切到「全曲库」模式（View 二次确认后才调）。
    func setLibraryWide() { setMode(.library) }

    /// 切到歌单级（保留已勾选的歌单）。
    func setPlaylistsMode() { setMode(.playlists) }

    /// 切到单曲级（保留已勾选的单曲）。
    func setTracksMode() { setMode(.tracks) }

    /// 勾选 / 取消勾选一个歌单。
    func togglePlaylist(_ id: String) {
        var picks = selectedPlaylistIDs
        if picks.contains(id) { picks.remove(id) } else { picks.insert(id) }
        applyPicks(mode: .playlists, playlistIDs: picks, trackPaths: selectedTrackPaths)
    }

    /// 勾选 / 取消勾选一首歌。
    func toggleTrack(_ relativePath: String) {
        var picks = selectedTrackPaths
        if picks.contains(relativePath) { picks.remove(relativePath) } else { picks.insert(relativePath) }
        applyPicks(mode: .tracks, playlistIDs: selectedPlaylistIDs, trackPaths: picks)
    }

    /// 手动指定单曲集合（替换整个单曲级选择）。
    func setManualTracks(_ relativePaths: [String]) {
        applyPicks(mode: .tracks, playlistIDs: selectedPlaylistIDs, trackPaths: Set(relativePaths))
    }

    /// 清空选择（不推不拉）。
    func clearSelection() { clearSelection(persist: true) }

    /// 全曲库选择的规模预览（二次确认文案；下载方向用**对端**的数字）。
    func libraryWidePreview() -> SyncUISelectionSummary {
        SyncUISelectionSummarizer.make(
            selection: .all,
            playlists: playlistOptions,
            tracks: trackOptions,
            library: libraryFacts
        )
    }

    /// 重算选择集规模（选项加载 / 选择变化后调用）。
    func estimateSelection() {
        selectionSummary = SyncUISelectionSummarizer.make(
            selection: selection,
            playlists: playlistOptions,
            tracks: trackOptions,
            library: libraryFacts
        )
    }

    // MARK: - 搜索 / 翻页（View 调用）

    /// 去抖到期：查询真的变了才从第一页重新加载（本地/对端同一条语义）。
    /// 输入变化本身不用回调（`stage` 只记待生效），故这里把两步收在一个入口。
    func applySearch() {
        _ = searchGate.stage(trackQuery)
        guard searchGate.commit() else { return }
        reloadTracks(reset: true)
    }

    /// 单曲级列表：`reset` 重头加载第一页（或按搜索词搜），否则追加下一页。
    func reloadTracks(reset: Bool) {
        switch source {
        case .none:
            return
        case .local:
            reloadLocalTracks(reset: reset)
        case .peer:
            reloadPeerTracks(reset: reset)
        }
    }

    /// 加载下一页（滚动到底 / 「加载更多」按钮）。
    func loadMoreTracks() {
        guard hasMoreTracks, !isLoadingTracks else { return }
        reloadTracks(reset: false)
    }

    /// 重载歌单选项（本地 = DB；对端 = 异步清单）。
    func reloadPlaylists() {
        switch source {
        case .none:
            return
        case .local:
            playlistOptions = local.playlistOptions()
            playlistState = .loaded
            estimateSelection()
        case .peer:
            reloadPeerPlaylists()
        }
    }

    // MARK: - 内部：数据源装配

    /// 按当前方向加载全部内容（歌单 + 摘要 + 第一页曲目）。
    private func loadContent() {
        switch source {
        case .none:
            return
        case .local:
            localFacts = local.libraryFacts()
            reloadPlaylists()
            reloadLocalTracks(reset: true)
        case .peer:
            guard ensurePeerProvider() else {
                markPeerUnavailable(.notConnected)
                return
            }
            reloadPeerPlaylists()
            reloadPeerSummary()
            reloadPeerTracks(reset: true)
        }
    }

    /// 取消在途请求、清空选项与加载态（切方向 / 断开时调）。
    private func resetContentState() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        summaryTask?.cancel()
        summaryTask = nil
        peer?.cancelInFlight()
        peer = nil
        playlistOptions = []
        trackOptions = []
        hasMoreTracks = false
        isLoadingTracks = false
        trackOffset = 0
        trackQuery = ""
        searchGate.reset()
        peerFacts = nil
        localFacts = .empty
        playlistState = .idle
        tracksState = .idle
        summaryState = .idle
        selectionSummary = .empty
    }

    private func hostDidChange() {
        guard source == .peer else { return }
        guard hostCenter.connectedPeer != nil, let session = hostCenter.activeSession else {
            // 对端掉线：在途请求作废，清单清空（避免展示上一台设备的内容）。
            resetContentState()
            markPeerUnavailable(.notConnected)
            return
        }
        // 同一会话（开关 / 时长等无关变化）→ 不动内容，避免无谓重载。
        if let peer, peer.matches(session: session) { return }
        // 换了会话（重连 / 换设备）：整个内容会话重建。
        resetContentState()
        loadContent()
    }

    /// 拿（或重建）对端提供者。未连接 / 无会话 → nil。
    private func ensurePeerProvider() -> Bool {
        guard hostCenter.connectedPeer != nil, let session = hostCenter.activeSession else {
            return false
        }
        if let peer, peer.matches(session: session) { return true }
        peer?.cancelInFlight()
        peer = MacSyncPeerContentProvider(session: session)
        return true
    }

    /// 对端不可用（未连接 / 会话未就绪）：三处状态统一进失败态（UI 显示一条原因 + 重试）。
    private func markPeerUnavailable(_ error: SyncUIPeerContentError) {
        playlistOptions = []
        trackOptions = []
        hasMoreTracks = false
        playlistState = .failed(error)
        tracksState = .failed(error)
        summaryState = .failed(error)
    }

    /// 全库规模事实（本地取 DB 缓存；对端取清单摘要）。
    private var libraryFacts: SyncUILibraryFacts {
        switch source {
        case .peer: return peerFacts?.libraryFacts ?? .empty
        case .local, .none: return localFacts
        }
    }

    // MARK: - 内部：本端加载（同步 DB 读）

    private func reloadLocalTracks(reset: Bool) {
        if reset { trackOffset = 0 }
        let page = local.trackPage(query: searchGate.appliedQuery, offset: trackOffset)
        trackOptions = SyncUIContentPager.merge(existing: trackOptions, page: page.options, reset: reset)
        trackOffset = SyncUIContentPager.nextOffset(loadedCount: trackOptions.count)
        hasMoreTracks = page.hasMore
        isLoadingTracks = false
        tracksState = .loaded
        estimateSelection()
    }

    // MARK: - 内部：对端加载（异步）

    private func reloadPeerPlaylists() {
        guard let peer else {
            markPeerUnavailable(.notConnected)
            return
        }
        let generation = self.generation
        playlistState = .loading
        loadTask = Task { @MainActor [weak self] in
            do {
                let options = try await peer.loadPlaylistOptions(
                    favoritesTitle: "sync_run_favorites".localized
                )
                guard let self, self.generation == generation else { return }
                self.playlistOptions = options
                self.playlistState = .loaded
                self.estimateSelection()
            } catch {
                guard let self, self.generation == generation else { return }
                self.applyPeerFailure(error) { self.playlistState = $0 }
            }
        }
    }

    private func reloadPeerSummary() {
        guard let peer else { return }
        let generation = self.generation
        summaryState = .loading
        summaryTask?.cancel()
        summaryTask = Task { @MainActor [weak self] in
            do {
                let facts = try await peer.loadSummary()
                guard let self, self.generation == generation else { return }
                self.peerFacts = facts
                self.summaryState = .loaded
                self.estimateSelection()
            } catch {
                guard let self, self.generation == generation else { return }
                // 摘要失败只影响顶部一行（列表照常）；不阻塞、不弹窗。
                self.applyPeerFailure(error) { self.summaryState = $0 }
            }
        }
    }

    private func reloadPeerTracks(reset: Bool) {
        guard let peer else {
            markPeerUnavailable(.notConnected)
            return
        }
        if reset { trackOffset = 0 }
        let generation = self.generation
        let query = searchGate.appliedQuery
        let offset = trackOffset
        loadTask?.cancel()
        tracksState = .loading
        isLoadingTracks = true
        loadTask = Task { @MainActor [weak self] in
            do {
                let page = try await peer.loadTrackPage(query: query, offset: offset)
                guard let self, self.generation == generation else { return }
                self.trackOptions = SyncUIContentPager.merge(
                    existing: self.trackOptions,
                    page: page.options,
                    reset: reset
                )
                self.trackOffset = SyncUIContentPager.nextOffset(loadedCount: self.trackOptions.count)
                self.hasMoreTracks = page.hasMore
                self.isLoadingTracks = false
                self.tracksState = .loaded
                self.estimateSelection()
            } catch {
                guard let self, self.generation == generation else { return }
                self.isLoadingTracks = false
                self.applyPeerFailure(error) { self.tracksState = $0 }
            }
        }
    }

    /// 失败归一：取消（用户切走/关闭）不算失败态，回到 idle 等下一次加载。
    private func applyPeerFailure(
        _ error: Error,
        assign: (SyncUIContentLoadState) -> Void
    ) {
        let mapped = SyncUIPeerContentError.from(error)
        if case .cancelled = mapped {
            assign(.idle)
        } else {
            assign(.failed(mapped))
        }
    }

    // MARK: - 内部：选择集写入口

    private func setMode(_ mode: SyncUISelectionMode) {
        applyPicks(mode: mode, playlistIDs: selectedPlaylistIDs, trackPaths: selectedTrackPaths)
    }

    /// 唯一的选择集写入口：算选择集 → 持久化 → 重算摘要。
    /// 持久化只在**非空**时发生（空选择不覆盖上次勾选：中途切模式不会把存档清空）。
    private func applyPicks(mode: SyncUISelectionMode, playlistIDs: Set<String>, trackPaths: Set<String>) {
        let next = SyncUISelectionMode.selection(mode: mode, playlistIDs: playlistIDs, trackPaths: trackPaths)
        selection = next
        if !next.isEmptySelection { selectionStore.save(next) }
        estimateSelection()
    }

    /// 清空选择（`persist` = 同时清掉存档；方向切换 / 断开走 true）。
    ///
    /// ⚠️ T10 起**不再跨会话恢复存档**（`load()` 不再被调用）：方向必选且选择集
    /// 语义随方向变（本端 slug vs 对端 slug），跨会话恢复会指向另一端的标识空间。
    /// 存档写入保持（`SyncSelectionStore` 契约不变），留给「连方向一起记住」的后续迭代。
    private func clearSelection(persist: Bool) {
        selection = .playlists([])
        if persist { selectionStore.save(.playlists([])) }
        estimateSelection()
    }
}
