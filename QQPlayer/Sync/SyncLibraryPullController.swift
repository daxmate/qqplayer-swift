//
//  SyncLibraryPullController.swift
//  QQPlayer
//
//  R1b-2（2026-09-11）同步方向改造 · **发起端（Mac）「从设备下载」控制器**。
//
//  流程：发 `manifest_request`(10) → 收设备 manifest(11) → 拉取方向对账
//  （既有 `SyncManifestReconciler`：远端 = 设备、本端 = Mac）→ 发
//  `sync_fetch_request`(12) 点名路径 → 设备串行回推（帧 4/5/6）→ 落
//  `曲库根/.sync-incoming/` → SHA-256 校验（`SyncFileReceiver`）→ 认领 →
//  移入目标相对路径 → 既有入库入口（`LibraryIndexerSyncSink`）→ 收
//  `sync_fetch_result`(13) 收尾。
//
//  aligned 歌词安装走共用 `SyncLyricsReceiver`（**不新写第二套落库**）。
//
//  语义硬约束（docs/lan-sync-design.md §6.1 + §12b 决策 6/7）：
//  - **不传播删除**：任一端删歌只在本地生效。设备 manifest 里没有、而本端已有的
//    文件一律保留（既不删文件也不删曲库行/歌词）——本类不存在删除执行路径。
//  - 同步集合 = 用户显式选择（v1：全库 / 显式相对路径；歌单勾选是 R3）。
//  - 状态：idle → requestingManifest → fetching → done / failed。
//
//  线程：会话线程（NW 队列）同步驱动；状态用锁保护，回调锁外触发。
//

import Foundation

// MARK: - 状态 / 账目 / 配置

/// 一次拉取的进度状态。
enum SyncLibraryPullState: Equatable, Sendable {
    case idle
    /// 已请求对端 manifest，等应答
    case requestingManifest
    /// 已发拉取请求，等对端串行推送 + 结果帧
    case fetching
    case done(SyncLibraryPullSummary)
    case failed(String)
}

/// 一次拉取的结果摘要（诊断/UI/测试用）。
struct SyncLibraryPullSummary: Equatable, Sendable {
    /// 本端请求的相对路径（升序）
    var requested: [String] = []
    /// 已落盘并交给入库入口的相对路径（含歌词 wire 路径，接收序）
    var completed: [String] = []
    /// 对端报告的失败项
    var failed: [SyncFileFetchFailure] = []
    /// 内容一致、无需拉取的对端条目（升序；诊断用）
    var unchanged: [String] = []
    /// 对端**回报送达**的相对路径（`sync_fetch_result.completed`；诊断/账目用）。
    /// 语义 = 对端本批确实送出的文件（对端每发送成功一个文件都会收到本端 done ack，
    /// 即本端已收齐并校验通过）。⚠️ 与 `completed` 的区别：本端的**落位/入库回调**
    /// 会晚于该结果帧（接收方先回 ack 再回调，见 SyncFileReceiver 的动作序），
    /// 因此阶段收尾时该集合先于 `completed` 可用（R3b 跟歌走携带用它定范围）。
    var reportedCompleted: [String] = []
    /// 收到但本端无对应歌曲、未落库的 aligned 歌词（丢弃；下次同步自愈，审计用）
    var orphanLyricsSkipped: [String] = []

    /// 本次是否动了本端歌词库（诊断用）。
    var touchedLyrics: Bool {
        (completed + failed.map(\.relativePath) + orphanLyricsSkipped)
            .contains { SyncLyricsNamespace.isLyricsPath($0) }
    }}

/// 状态迁移合法性（纯逻辑，可单测）。
enum SyncLibraryPullStateMachine {
    static func canTransition(from: SyncLibraryPullState, to: SyncLibraryPullState) -> Bool {
        switch (from, to) {
        case (.idle, .requestingManifest): return true
        case (.requestingManifest, .fetching): return true
        // 无待拉取条目：对账后直接收尾
        case (.requestingManifest, .done): return true
        case (.fetching, .done): return true
        default:
            if case .failed = to {
                return !isTerminal(from)
            }
            return false
        }
    }

    static func isTerminal(_ state: SyncLibraryPullState) -> Bool {
        switch state {
        case .done, .failed: return true
        default: return false
        }
    }
}

/// 拉取控制器配置。
struct SyncLibraryPullConfiguration: Equatable, Sendable {
    /// 对端 manifest 请求的集合（v1 默认全库；选择在本端 filter 上执行）
    var collection: SyncCollection = .all
    /// 本端选择集（v1：全库 / 显式相对路径）
    var selection: SyncLibraryPullSelection = .all
    /// 落地目录名（曲库根内，隐藏目录——曲库扫描跳过隐藏文件）
    var incomingDirectoryName: String = ".sync-incoming"
}

/// 拉取选择集（v1，与推送侧同口径）。
enum SyncLibraryPullSelection: Equatable, Sendable {
    /// 全库（设备 manifest 全量参与对账）
    case all
    /// 显式相对路径集合（对账键口径；非法路径丢弃，去重 + 升序）
    case relativePaths([String])

    /// 规范化后的路径集合（`.all` → nil = 不过滤）。
    var normalizedPaths: [String]? {
        switch self {
        case .all:
            return nil
        case let .relativePaths(raw):
            return SyncFetchRequest.normalize(raw)
        }
    }

    /// 对端 manifest → 本端选择集内的条目。
    func filter(_ entries: [ManifestEntry]) -> [ManifestEntry] {
        guard let paths = normalizedPaths else { return entries }
        let wanted = Set(paths)
        return entries.filter { wanted.contains($0.relativePath) }
    }
}

// MARK: - 对账（纯逻辑，复用既有 reconciler）

/// 拉取计划（纯值）。
struct SyncLibraryPullPlan: Equatable, Sendable {
    /// 要向对端点名拉取的相对路径（升序）
    var relativePaths: [String] = []
    /// 内容一致的对端条目（升序）
    var unchanged: [ManifestEntry] = []
}

enum SyncLibraryPullPlanner {
    /// 拉取方向对账（纯函数）：远端 = 对端 manifest、本地 = 本端清单（含 aligned 歌词）。
    /// 直接复用 `SyncManifestReconciler`（拉取方向语义本就如此）——**只调用不改语义**。
    /// 「对端没有而本端已有」的条目一律保留（不传播删除），因此计划里没有删除动作。
    static func plan(
        remote: SyncManifestResponse,
        local: [ManifestEntry],
        selection: SyncLibraryPullSelection,
        collection: SyncCollection = .all
    ) -> SyncLibraryPullPlan {
        let scoped = selection.filter(collection.filter(remote.entries))
        let reconciliation = SyncManifestReconciler.reconcile(remote: scoped, local: local)
        return SyncLibraryPullPlan(
            relativePaths: SyncFetchRequest.normalize(reconciliation.toFetch.map(\.relativePath)),
            unchanged: reconciliation.unchanged
        )
    }
}

// MARK: - 控制器

/// Mac 侧「从设备下载」控制器（一个会话一个实例；M6 由 UI 持有并展示状态）。
final class SyncLibraryPullController: @unchecked Sendable {
    enum StartError: Error, Equatable {
        /// 会话未 ready（未配对/已关闭）
        case sessionNotReady
    }

    private let session: SyncPeerSession
    private let descriptor: SyncLocalLibraryDescriptor
    private let sink: SyncLibrarySyncSink
    private let configuration: SyncLibraryPullConfiguration
    private let lyricsStore: AlignedLyricsStore
    private let lyricsMapping: SyncLyricsContentMapping
    private let fileManager: FileManager
    private let lock = NSLock()

    private var manifestPeer: SyncManifestPeer?
    private var receiver: SyncFileReceiver?
    private var priorAppHandler: ((SyncFrame) -> Void)?
    /// 歌词接收安装编排（与被动端/旧主流程共用同一实现）
    private var lyricsReceiver: SyncLyricsReceiver

    // 锁保护状态
    private var stateValue: SyncLibraryPullState = .idle
    private var summaryValue = SyncLibraryPullSummary()
    /// 文件名 → 期望的相对路径（串行推送下按名回收；同名多路径按请求序）
    private var expectedByFileName: [String: [String]] = [:]

    /// 每态回调（会话线程触发，锁外）。
    var onStateChange: ((SyncLibraryPullState) -> Void)?
    /// 落盘并交给入库入口时回调（进度用，锁外）。
    var onFileApplied: ((String) -> Void)?

    init(
        session: SyncPeerSession,
        descriptor: SyncLocalLibraryDescriptor,
        sink: SyncLibrarySyncSink = LibraryIndexerSyncSink(),
        configuration: SyncLibraryPullConfiguration = SyncLibraryPullConfiguration(),
        lyricsStore: AlignedLyricsStore = .shared,
        lyricsMapping: SyncLyricsContentMapping? = nil,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.descriptor = descriptor
        self.sink = sink
        self.configuration = configuration
        self.fileManager = fileManager
        self.lyricsStore = lyricsStore
        let mapping = lyricsMapping ?? .unresolved
        self.lyricsMapping = mapping
        self.lyricsReceiver = SyncLyricsReceiver(
            lyricsStore: lyricsStore,
            lyricsMapping: mapping,
            fileManager: fileManager
        )
    }

    // MARK: 对外状态

    var state: SyncLibraryPullState {
        lock.lock()
        defer { lock.unlock() }
        return effectiveStateLocked()
    }

    /// 终态（.done）的账目取实时值：接收端先回 ack 再回调 onCompletion，
    /// 对端 `sync_fetch_result` 可能先于最后一个文件的落盘/入库回调到达。
    private func effectiveStateLocked() -> SyncLibraryPullState {
        if case .done = stateValue {
            return .done(summaryValue)
        }
        return stateValue
    }

    var summary: SyncLibraryPullSummary {
        lock.lock()
        defer { lock.unlock() }
        return summaryValue
    }

    // MARK: 生命周期

    /// 开始一次拉取（会话必须已 ready）：请求 manifest，随后由帧驱动。
    func start() throws {
        guard session.isReady else { throw StartError.sessionNotReady }

        let peer = SyncManifestPeer(session: session)
        peer.onManifestReceived = { [weak self] response in
            self?.handleManifest(response)
        }
        peer.onDecodeFailure = { [weak self] error in
            self?.transition(to: .failed("manifest 载荷非法：\(error)"))
        }
        manifestPeer = peer

        let incoming = descriptor.libraryRoot.appendingPathComponent(
            configuration.incomingDirectoryName,
            isDirectory: true
        )
        try? fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
        let receiver = SyncFileReceiver(session: session, directory: incoming)
        receiver.onCompletion = { [weak self] outcome in
            self?.handleTransfer(outcome)
        }
        self.receiver = receiver

        attachResultHandler()
        // 每轮重置歌词编排状态
        lyricsReceiver = SyncLyricsReceiver(
            lyricsStore: lyricsStore,
            lyricsMapping: lyricsMapping,
            fileManager: fileManager
        )
        transition(to: .requestingManifest)
        do {
            try peer.requestManifest(collection: configuration.collection)
        } catch {
            transition(to: .failed("请求 manifest 失败：\(error)"))
            throw error
        }
    }

    /// 中止（会话关闭 / 用户取消）：停收文件，状态落 failed。
    func cancel() {
        receiver?.cancel()
        lyricsReceiver.cancel()
        transition(to: .failed("cancelled"))
    }

    // MARK: manifest → 对账 → 拉取

    /// 本端清单（曲库 + aligned 歌词；对账「本地是否已有」用）。
    private func localEntries() -> [ManifestEntry] {
        let library = SyncManifestGenerator.generate(files: descriptor.sourceFiles())
        return library + descriptor.lyricsEntries()
    }

    private func handleManifest(_ response: SyncManifestResponse) {
        let plan = SyncLibraryPullPlanner.plan(
            remote: response,
            local: localEntries(),
            selection: configuration.selection,
            collection: configuration.collection
        )

        lock.lock()
        summaryValue.unchanged = plan.unchanged.map(\.relativePath)
        if !plan.relativePaths.isEmpty {
            summaryValue.requested = plan.relativePaths
            expectedByFileName = Self.expectedPathsByName(plan.relativePaths)
        }
        lock.unlock()

        guard !plan.relativePaths.isEmpty else {
            transition(to: .done(summaryValue))
            return
        }
        transition(to: .fetching)
        do {
            let payload = try SyncFetchCodec.encode(
                SyncFetchRequest(collection: configuration.collection, relativePaths: plan.relativePaths)
            )
            try session.sendApplicationFrame(type: .syncFetchRequest, payload: payload)
        } catch {
            transition(to: .failed("发送拉取请求失败：\(error)"))
        }
    }

    // MARK: 收文件 → 落位 + 入库

    private func handleTransfer(_ outcome: SyncFileReceiver.Outcome) {
        switch outcome {
        case let .received(url):
            guard let relativePath = takeExpectedPath(forFileName: url.lastPathComponent) else {
                return // 未请求过的文件：不落位（留在落地目录）
            }
            if SyncLyricsNamespace.isLyricsPath(relativePath) {
                apply(lyricsOutcome: lyricsReceiver.receive(tempURL: url, wirePath: relativePath))
                return
            }
            land(fileAt: url, relativePath: relativePath)
        case .failed:
            // 单文件失败由对端 sync_fetch_result 归集（本端不重复记账）
            break
        }
    }

    private func land(fileAt url: URL, relativePath: String) {
        guard case let .resolved(destination) = SyncLibraryPathResolver.resolve(
            relativePath: relativePath,
            root: descriptor.libraryRoot
        ) else {
            lock.lock()
            summaryValue.failed.append(
                SyncFileFetchFailure(relativePath: relativePath, reason: SyncFetchFailureReason.invalidPath)
            )
            lock.unlock()
            try? fileManager.removeItem(at: url)
            return
        }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                // 内容不同 → 更新：同路径旧副本就地替换（本端事务，非删除传播）
                try? fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: url, to: destination)
        } catch {
            lock.lock()
            summaryValue.failed.append(
                SyncFileFetchFailure(relativePath: relativePath, reason: SyncFetchFailureReason.sendFailed)
            )
            lock.unlock()
            return
        }
        sink.indexLandedFile(at: destination)
        lock.lock()
        summaryValue.completed.append(relativePath)
        lock.unlock()
        onFileApplied?(relativePath)
    }

    // MARK: 结果帧 → 收尾

    private func attachResultHandler() {
        priorAppHandler = session.onApplicationFrame
        session.onApplicationFrame = { [weak self] frame in
            guard let self else {
                return
            }
            if frame.type == .syncFetchResult {
                self.handleFetchResult(frame)
            }
            self.priorAppHandler?(frame)
        }
    }

    private func handleFetchResult(_ frame: SyncFrame) {
        guard let result = try? SyncFetchCodec.decode(SyncFetchResult.self, from: frame.payload) else {
            transition(to: .failed("sync_fetch_result 解码失败"))
            return
        }
        lock.lock()
        summaryValue.failed = result.failed
        summaryValue.reportedCompleted = result.completed
        lock.unlock()
        finalize()
    }

    /// 收尾：先兜现暂存歌词（此时同轮先落下的歌多已入库），再落终态。
    /// **无删除阶段**（§6.1 + §12b 决策 7：删除不跨端传播）。
    private func finalize() {
        for outcome in lyricsReceiver.flushPending() {
            apply(lyricsOutcome: outcome)
        }
        transition(to: .done(summaryValue))
    }

    // MARK: 歌词落地

    /// 歌词安装结论 → 账目（`SyncLyricsReceiver` 共用同一实现）。
    private func apply(lyricsOutcome: SyncLyricsReceiver.Outcome) {
        switch lyricsOutcome {
        case let .installed(wirePath):
            lock.lock()
            summaryValue.completed.append(wirePath)
            lock.unlock()
            onFileApplied?(wirePath)
        case .pending:
            break // 本端歌曲还没入库：本轮收尾时再试一次映射
        case let .discarded(wirePath):
            lock.lock()
            summaryValue.orphanLyricsSkipped.append(wirePath)
            lock.unlock()
        case let .failed(wirePath):
            lock.lock()
            summaryValue.failed.append(
                SyncFileFetchFailure(relativePath: wirePath, reason: SyncFetchFailureReason.sendFailed)
            )
            lock.unlock()
        }
    }

    // MARK: 辅助

    /// 文件名 → 期望相对路径列表（按请求序）。同名多路径按序取首个未匹配。
    static func expectedPathsByName(_ relativePaths: [String]) -> [String: [String]] {
        var byName: [String: [String]] = [:]
        for path in relativePaths {
            let name = (path as NSString).lastPathComponent
            byName[name, default: []].append(path)
        }
        return byName
    }

    /// 取一个期望路径（同名多路径按序），取走即从期待表移除。
    private func takeExpectedPath(forFileName name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard var paths = expectedByFileName[name], !paths.isEmpty else { return nil }
        let path = paths.removeFirst()
        expectedByFileName[name] = paths.isEmpty ? nil : paths
        return path
    }

    private func transition(to newState: SyncLibraryPullState) {
        lock.lock()
        let current = stateValue
        guard SyncLibraryPullStateMachine.canTransition(from: current, to: newState) else {
            lock.unlock()
            return
        }
        stateValue = newState
        let effective = effectiveStateLocked()
        lock.unlock()
        onStateChange?(effective)
    }
}
