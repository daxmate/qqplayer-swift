//
//  MacSyncRunViewModel.swift
//  QQPlayer
//
//  M6（T3，2026-09-11）Mac 同步页**执行侧视图模型**（QQPlayerMac target only）。
//
//  职责（契约 C4）：把一个 ready 会话 + 用户选择集，驱动成一次可见的同步：
//  - 装配：`MacSyncCoordinatorFactory.make(session:selection:)`（**唯一装配入口**：
//    曲库根 / 描述符 / sink / 歌词映射一律走它，本文件不另建一套路径或 DB 口径）
//  - 订阅：`onStateChange` / `onFileTransferred` / `onPeerManifestReceived`
//  - 发布：阶段、进度、结果摘要、选择集与选择集规模（供四区 UI 消费）
//  - 判定：全部委托 `SyncUIState`（纯逻辑，可单测）；本文件只做 IO 与线程搬运
//
//  线程（硬要求）：协调器的回调在**会话线程**触发 → 一律 `Task { @MainActor in }`
//  回到主线程再改 `@Published`（本类是 `@MainActor`）。
//
//  会话断开：`SyncHostCenter.connectedPeer` 变 nil 时把进行中的同步 `cancel()` 并
//  标记 `didDisconnectWhileRunning`（UI 展示「设备已断开，同步已停止」而不是
//  干巴巴的 `cancelled`）。
//
//  账目实时读 + 终态兜底重读：`coordinator.report` 是实时值，但两个控制器的
//  落盘/入库账目可能**晚于** `.done` 回调（见 `SyncCollectionSyncCoordinator.report`
//  文档：拉取侧 `summary.completed` 晚于结果帧）→ 终态时先立刻读一次，再延迟读一次
//  覆盖（只在本协调器仍是当前、且仍在终态时生效）。
//
//  为什么不做单测：本文件属 `QQPlayer/Mac/`（iOS 单测 target 看不到它，仓库也没有
//  macOS 单测 target）→ 靠编译 + 代码审查覆盖；其中可测的判定全部在
//  `SyncUIState`（共享 Core，QQPlayerTests 真跑）。
//

import Combine
import Foundation
import GRDB

@MainActor
final class MacSyncRunViewModel: ObservableObject {
    /// 单曲级列表每页条数（懒加载；量大不分页会卡主线程）。
    static let trackPageSize = 100
    /// 单曲级搜索结果上限（搜索走 DB 的 ranked search，不再分页）。
    static let trackSearchLimit = 200

    // MARK: 依赖

    private let hostCenter: SyncHostCenter
    private let selectionStore: SyncSelectionStore
    private let database: DatabaseManager
    private let deviceStore: DeviceStore
    /// 曲库根（相对路径口径；与 `MacSyncCoordinatorFactory` / `MacSyncLibraryHost` 同源）。
    private let libraryRoot: URL
    private let makeCoordinator: (SyncPeerSession, SyncCollectionSelection) -> SyncCollectionSyncCoordinator

    // MARK: 发布状态

    /// 当前阶段。
    @Published private(set) var phase: SyncUIPhase = .disconnected
    /// 「开始同步」可用性。
    @Published private(set) var startAvailability: SyncUIStartAvailability = .notPaired
    /// 文件级进度。
    @Published private(set) var progress: SyncUIProgress = .idle
    /// 最近一次同步的结果摘要（nil = 还没跑过）。
    @Published private(set) var reportSummary: SyncUIReportSummary?
    /// 当前选择集（唯一事实源；持久化到 `SyncSelectionStore`）。
    @Published private(set) var selection: SyncCollectionSelection = .playlists([])
    /// 选择集规模摘要（底部合计 / 全库二次确认文案）。
    @Published private(set) var selectionSummary: SyncUISelectionSummary = .empty
    /// 歌单选项（含「收藏」伪歌单）。
    @Published private(set) var playlistOptions: [SyncUIPlaylistOption] = []
    /// 单曲级选项（当前页 / 搜索结果）。
    @Published private(set) var trackOptions: [SyncUITrackOption] = []
    /// 单曲级是否还有下一页。
    @Published private(set) var hasMoreTracks = false
    /// 单曲级正在加载。
    @Published private(set) var isLoadingTracks = false
    /// 单曲级搜索词（View 绑定；变化后调用 `reloadTracks(reset: true)`）。
    @Published var trackQuery = ""
    /// 集合错误（加载失败等；UI 弹一次）。
    @Published private(set) var errorMessage: String?
    /// 每秒更新（连接时长展示用）。
    @Published private(set) var now = Date()
    /// 同步进行中会话断开（UI 提示用）。
    @Published private(set) var didDisconnectWhileRunning = false

    // MARK: 内部状态

    private var coordinator: SyncCollectionSyncCoordinator?
    private var transferredCount = 0
    private var currentPath: String?
    private var didLoadOnce = false
    private var trackOffset = 0
    private var libraryFacts: SyncUILibraryFacts = .empty
    private var artistNamesByStableId: [String: String] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var tickTask: Task<Void, Never>?
    private var reportRefreshTask: Task<Void, Never>?

    init(
        hostCenter: SyncHostCenter? = nil,
        selectionStore: SyncSelectionStore = SyncSelectionStore(),
        database: DatabaseManager = .shared,
        deviceStore: DeviceStore = DeviceStore(),
        libraryRoot: URL? = nil,
        makeCoordinator: @escaping (SyncPeerSession, SyncCollectionSelection) -> SyncCollectionSyncCoordinator = {
            MacSyncCoordinatorFactory.make(session: $0, selection: $1)
        }
    ) {
        // 默认值是 `nil` 而不是 `.shared`：默认实参在**非隔离**上下文求值，
        // 直接写 `= .shared` 会报「main actor-isolated property 跨隔离引用」
        // （Swift 6 语言模式下是错误）→ 在 init 体内（MainActor）解析。
        let center = hostCenter ?? .shared
        self.hostCenter = center
        self.selectionStore = selectionStore
        self.database = database
        self.deviceStore = deviceStore
        self.libraryRoot = libraryRoot ?? MusicFolderResolver.macDefaultFolderURL(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        self.makeCoordinator = makeCoordinator
        // 监听中心变化（连接/断开/开关）→ 主线程刷新可用性与运行态。
        // objectWillChange 是**变更前**通知 → 用 Task 排到主线程队列尾，读到的就是新值。
        center.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.hostDidChange() }
            }
            .store(in: &cancellables)
    }

    // MARK: - 派生（View 只读）

    /// 当前连接的对端（nil = 未连接）。
    var connectedPeer: SyncConnectedPeer? { hostCenter.connectedPeer }

    /// 是否已连接。
    var isConnected: Bool { hostCenter.connectedPeer != nil }

    /// 连接时长文案（"3:12"；未连接 = nil）。
    var connectionDurationText: String? {
        guard let peer = hostCenter.connectedPeer else { return nil }
        return SyncUIDurationText.short(seconds: now.timeIntervalSince(peer.connectedAt))
    }

    /// 监听是否在运行（开关关闭 / 启动失败 = false）。
    var isListening: Bool { hostCenter.isRunning }

    /// 允许局域网设备连接（绑定到 `SyncHostCenter`）。
    var allowsLANConnections: Bool {
        get { hostCenter.allowsLANConnections }
        set { hostCenter.allowsLANConnections = newValue }
    }

    /// 当前选择集模式（三级）。
    var selectionMode: SyncUISelectionMode {
        SyncUISelectionMode.mode(for: selection)
    }

    /// 已选歌单标识（歌单级多选态）。
    var selectedPlaylistIDs: Set<String> { Set(selection.playlistIDs ?? []) }

    /// 已选相对路径（单曲级多选态）。
    var selectedTrackPaths: Set<String> { Set(selection.relativePaths ?? []) }

    /// 中断提示（掉线中止 / 用户取消 / 无）。
    var interruption: SyncUIInterruption {
        SyncUIInterruption.resolve(phase: phase, didDisconnectWhileRunning: didDisconnectWhileRunning)
    }

    /// 当前失败原因文本（非失败态 = nil）：已知码走本地化，未知码原样展示
    /// （协调器内部诊断文案，比 "unknown" 有信息量）。
    var failureText: String? {
        guard case let .failed(reason) = phase else { return nil }
        switch (interruption, reason) {
        case (.sessionClosed, _): return "sync_run_interrupted".localized
        case (.cancelled, _): return "sync_run_cancelled".localized
        default: return reason
        }
    }

    // MARK: - 生命周期

    /// 页面出现：载入上次选择 + 列表 + 可用性（幂等：第二次起只刷新）。
    func onAppear() {
        if !didLoadOnce {
            didLoadOnce = true
            let stored = selectionStore.load()
            selection = stored
            reloadPlaylists()
            reloadTracks(reset: true)
            estimateSelection()
        }
        refreshAvailability()
        if isConnected { startTicking() } else { stopTicking() }
    }

    /// 页面消失：停掉计时与延迟任务（协调器不取消——同步应在后台继续跑）。
    func onDisappear() {
        stopTicking()
    }

    /// 弹一次错误。
    func clearError() { errorMessage = nil }

    // MARK: - 选择集

    /// 切到「全曲库」模式（View 二次确认后才调）。
    func setLibraryWide() {
        setMode(.library)
    }

    /// 切到歌单级（保留已勾选的歌单）。
    func setPlaylistsMode() {
        setMode(.playlists)
    }

    /// 切到单曲级（保留已勾选的单曲）。
    func setTracksMode() {
        setMode(.tracks)
    }

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
    func clearSelection() {
        applyPicks(mode: .playlists, playlistIDs: [], trackPaths: [])
    }

    /// 全曲库选择的规模预览（二次确认文案；会按需加载全库合计）。
    func libraryWidePreview() -> SyncUISelectionSummary {
        loadLibraryFacts()
        return SyncUISelectionSummarizer.make(
            selection: .all,
            playlists: playlistOptions,
            tracks: trackOptions,
            library: libraryFacts
        )
    }

    /// 重算选择集规模（选项加载/选择变化后调用）。
    func estimateSelection() {
        if selection.isLibraryWide { loadLibraryFacts() }
        selectionSummary = SyncUISelectionSummarizer.make(
            selection: selection,
            playlists: playlistOptions,
            tracks: trackOptions,
            library: libraryFacts
        )
    }

    // MARK: - 数据加载

    /// 重载歌单选项（含「收藏」伪歌单；每项带曲目数与大小合计）。
    func reloadPlaylists() {
        var options: [SyncUIPlaylistOption] = []

        let favorites = (try? database.getFavoriteTracks()) ?? []
        options.append(
            SyncUIPlaylistOption(
                id: SyncCollectionSelection.favoritesPlaylistID,
                title: "sync_run_favorites".localized,
                trackCount: favorites.count,
                totalBytes: totalBytes(of: favorites),
                missingSizeCount: favorites.filter { ($0.fileSize ?? 0) <= 0 }.count
            )
        )

        // 一次取全库曲目建索引，避免「每个歌单成员一次查询」把主线程拖住。
        let tracksByStableId = Dictionary(
            ((try? database.getAllTracks()) ?? []).map { ($0.stableId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let playlists = (try? database.getAllPlaylists()) ?? []
        for playlist in playlists {
            guard let playlistID = playlist.id,
                  let items = try? database.getPlaylistItems(playlistId: playlistID)
            else { continue }
            let members = items.compactMap { tracksByStableId[$0.trackStableId] }
            options.append(
                SyncUIPlaylistOption(
                    id: playlist.slug,
                    title: playlist.title,
                    trackCount: members.count,
                    totalBytes: totalBytes(of: members),
                    missingSizeCount: members.filter { ($0.fileSize ?? 0) <= 0 }.count
                )
            )
        }
        playlistOptions = options
        estimateSelection()
    }

    /// 单曲级列表：`reset` 重头加载第一页（或按搜索词搜），否则追加下一页。
    func reloadTracks(reset: Bool) {
        if reset { trackOffset = 0 }
        isLoadingTracks = true
        defer { isLoadingTracks = false }

        let query = trackQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let page: [Track]
        if query.isEmpty {
            page = (try? database.getTracksPaginated(limit: Self.trackPageSize, offset: trackOffset)) ?? []
        } else {
            page = (try? database.searchTracks(query: query, limit: Self.trackSearchLimit)) ?? []
        }
        loadArtistNamesIfNeeded(for: page)

        let options = page.compactMap(trackOption(for:))
        if reset || !query.isEmpty {
            trackOptions = options
            trackOffset = options.count
            hasMoreTracks = query.isEmpty && page.count == Self.trackPageSize
        } else {
            trackOptions += options
            trackOffset += options.count
            hasMoreTracks = page.count == Self.trackPageSize
        }
        estimateSelection()
    }

    // MARK: - 同步执行

    /// 开始一次同步（仅在 `startAvailability == .ready` 时有效）。
    func startSync() {
        refreshAvailability()
        guard startAvailability == .ready else { return }
        guard let session = hostCenter.activeSession else {
            refreshAvailability()
            return
        }

        stopReportRefresh()
        didDisconnectWhileRunning = false
        transferredCount = 0
        currentPath = nil
        reportSummary = nil
        errorMessage = nil

        let coordinator = makeCoordinator(session, selection)
        coordinator.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleState(state, from: coordinator) }
        }
        coordinator.onFileTransferred = { [weak self] relativePath in
            Task { @MainActor in self?.handleFileTransferred(relativePath, from: coordinator) }
        }
        coordinator.onPeerManifestReceived = { [weak self] _ in
            Task { @MainActor in self?.handlePeerManifest(from: coordinator) }
        }
        self.coordinator = coordinator

        do {
            try coordinator.start()
        } catch {
            errorMessage = "\(error)"
        }
        // 内存回环下 `start()` 可能已在本调用内跑到终态 → 补一次状态同步（幂等）。
        handleState(coordinator.state, from: coordinator)
        refreshAvailability()
    }

    /// 取消进行中的同步。
    func cancelSync() {
        guard let coordinator else { return }
        coordinator.cancel()
        handleState(coordinator.state, from: coordinator)
        refreshAvailability()
    }

    // MARK: - 回调处理（主线程）

    private func handleState(_ state: SyncCollectionSyncState, from source: SyncCollectionSyncCoordinator) {
        guard coordinator === source else { return }
        phase = SyncUIPhase.resolve(isConnected: isConnected, state: state)
        refreshProgress(for: source)
        guard phase.isTerminal else { return }
        refreshReportSummary(for: source)
        scheduleReportRefresh(for: source)
        refreshAvailability()
    }

    private func handleFileTransferred(_ relativePath: String, from source: SyncCollectionSyncCoordinator) {
        guard coordinator === source else { return }
        transferredCount += 1
        currentPath = relativePath
        refreshProgress(for: source)
    }

    private func handlePeerManifest(from source: SyncCollectionSyncCoordinator) {
        guard coordinator === source else { return }
        // 计划已到手：总数为 0 的阶段到此结束（进度条从不确定态切确定态）。
        currentPath = nil
        refreshProgress(for: source)
    }

    /// 监听中心状态变化（连接 / 断开 / 开关）。
    private func hostDidChange() {
        if isConnected {
            startTicking()
        } else {
            stopTicking()
            if let coordinator, !SyncCollectionSyncState.isTerminal(coordinator.state) {
                didDisconnectWhileRunning = true
                coordinator.cancel()
            }
        }
        refreshAvailability()
    }

    // MARK: - 内部

    private func setMode(_ mode: SyncUISelectionMode) {
        applyPicks(mode: mode, playlistIDs: selectedPlaylistIDs, trackPaths: selectedTrackPaths)
    }

    /// 唯一的选择集写入口：算选择集 → 持久化 → 重算摘要 → 刷新可用性。
    /// 持久化只在**非空**时发生（空选择不覆盖上次勾选：中途切模式不会把存档清空）。
    private func applyPicks(mode: SyncUISelectionMode, playlistIDs: Set<String>, trackPaths: Set<String>) {
        let next = SyncUISelectionMode.selection(mode: mode, playlistIDs: playlistIDs, trackPaths: trackPaths)
        selection = next
        if !next.isEmptySelection { selectionStore.save(next) }
        estimateSelection()
        refreshAvailability()
    }

    private func refreshAvailability() {
        let running = coordinator.map { !SyncCollectionSyncState.isTerminal($0.state) } ?? false
        startAvailability = SyncUIStartGate.evaluate(
            hasPairedDevice: hasPairedDevice,
            isConnected: isConnected,
            hasSession: hostCenter.activeSession != nil,
            isRunning: running,
            isEmptySelection: selection.isEmptySelection
        )
    }

    private var hasPairedDevice: Bool {
        ((try? deviceStore.all()) ?? []).isEmpty == false
    }

    private func refreshProgress(for source: SyncCollectionSyncCoordinator) {
        progress = SyncUIProgressAggregator.make(
            phase: phase,
            report: source.report,
            completed: transferredCount,
            currentPath: currentPath
        )
    }

    /// 账目快照（数据源 = `report` 实时值）。
    private func refreshReportSummary(for source: SyncCollectionSyncCoordinator) {
        reportSummary = SyncUIReportSummary.make(report: source.report)
    }

    /// 终态后再延迟读一次账目：控制器落盘/入库账目可能晚于终态回调（见文件头）。
    private func scheduleReportRefresh(for source: SyncCollectionSyncCoordinator) {
        stopReportRefresh()
        reportRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.coordinator === source, SyncCollectionSyncState.isTerminal(source.state) else { return }
            self.refreshReportSummary(for: source)
        }
    }

    private func stopReportRefresh() {
        reportRefreshTask?.cancel()
        reportRefreshTask = nil
    }

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.now = Date()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func loadLibraryFacts() {
        let count = (try? database.getTrackCount()) ?? 0
        let bytes = (try? database.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(file_size), 0) FROM track")
        }) ?? 0
        libraryFacts = SyncUILibraryFacts(trackCount: count, totalBytes: bytes)
    }

    private func loadArtistNamesIfNeeded(for page: [Track]) {
        let missing = page.filter { artistNamesByStableId[$0.stableId] == nil }
        guard !missing.isEmpty else { return }
        let fallback = Dictionary(
            missing.compactMap { track in track.artistId.map { (track.stableId, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let names = (try? database.getArtistDisplayNames(
            forTrackStableIds: missing.map(\.stableId),
            fallbackArtistIdsByStableId: fallback
        )) ?? [:]
        artistNamesByStableId.merge(names) { _, new in new }
    }

    private func trackOption(for track: Track) -> SyncUITrackOption? {
        guard let relativePath = SyncManifestGenerator.relativePath(
            of: URL(fileURLWithPath: track.path),
            baseDirectory: libraryRoot
        ) else {
            return nil
        }
        return SyncUITrackOption(
            relativePath: relativePath,
            title: track.title,
            artistName: artistNamesByStableId[track.stableId],
            fileSize: track.fileSize
        )
    }

    private func totalBytes(of tracks: [Track]) -> Int64 {
        tracks.reduce(Int64(0)) { total, track in
            total + max(0, track.fileSize ?? 0)
        }
    }
}
