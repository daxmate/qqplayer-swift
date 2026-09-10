//
//  SyncLibrarySyncController.swift
//  QQPlayer
//
//  局域网同步（S2, M3-3b）Client 侧文件同步控制器：ready 后拉 manifest →
//  本地清单对账 → 按路径请求拉取（Host 串行推送）→ 删除远端已消失项（受保护
//  范围除外）→ 落盘 + 走既有入库入口。
//
//  状态机（每态回调 onStateChange，UI 留 M6）：
//    idle → requestingManifest → fetching → applyingDeletes → done / failed
//  （无可拉取文件时 requestingManifest → applyingDeletes 直落；纯逻辑见
//   SyncLibrarySyncStateMachine）
//
//  删除语义（§6.1 硬要求，本文件是执行点）：
//  只删「同步集合内 + 非私有区」的本地条目——范围由
//  SyncManifestReconciler.deleteScope(collection:members:localEntries:protectedRelativePaths:)
//  推导，执行前再用同一 scope 复核一次（计划与执行之间本地可能变化）。
//  **私有区（文件 App 导入 / 未配对来源）绝不出现在删除路径上**。
//  protectedRelativePaths 的来源（导入标记 / 同步账本）由调用方注入，本文件不自造。
//
//  落地：文件先落曲库根内的隐藏落地目录（同步扫描跳过隐藏文件，不会被误当曲库内容），
//  收齐校验通过（SyncFileReceiver 已做 SHA-256）后移入相对路径位置，再交给
//  sink.indexLandedFile 走既有 LibraryIndexer 入口入库——本文件不写 DB 逻辑。
//
//  线程：会话线程同步驱动（与 M2b 组件同风格）；自身状态用锁保护。
//

import Foundation

// MARK: - 状态

/// 一次同步的进度状态。
enum SyncLibrarySyncState: Equatable, Sendable {
    case idle
    /// 已请求对端 manifest，等应答
    case requestingManifest
    /// 已发拉取请求，等对端串行推送 + 结果帧
    case fetching
    /// 正在执行删除（受保护范围已过滤）
    case applyingDeletes
    case done(SyncLibrarySyncSummary)
    case failed(String)
}

/// 一次同步的结果摘要（诊断/UI/测试用）。
struct SyncLibrarySyncSummary: Equatable, Sendable {
    /// 本端请求的相对路径（升序）
    var requested: [String] = []
    /// 已落盘并交给入库入口的相对路径
    var completed: [String] = []
    /// 对端报告的失败项
    var failed: [SyncFileFetchFailure] = []
    /// 已删除的本地相对路径
    var deleted: [String] = []
    /// 因私有区/未受管豁免而未删的本地条目（审计用）
    var protectedSkipped: [String] = []
}

/// 状态迁移合法性（纯逻辑，可单测）：保证 UI/日志看到一致的序列。
enum SyncLibrarySyncStateMachine {
    static func canTransition(from: SyncLibrarySyncState, to: SyncLibrarySyncState) -> Bool {
        switch (from, to) {
        case (.idle, .requestingManifest): return true
        case (.requestingManifest, .fetching): return true
        case (.requestingManifest, .applyingDeletes): return true
        case (.fetching, .applyingDeletes): return true
        case (.applyingDeletes, .done): return true
        default:
            // 任何非终态都可能失败
            if case .failed = to {
                return !isTerminal(from)
            }
            return false
        }
    }

    static func isTerminal(_ state: SyncLibrarySyncState) -> Bool {
        switch state {
        case .done, .failed: return true
        default: return false
        }
    }
}

// MARK: - 配置 / 对账计划

/// 控制器配置。
struct SyncLibrarySyncConfiguration: Sendable, Equatable {
    /// 同步集合（v1 默认全库镜像）
    var collection: SyncCollection = .all
    /// 私有区：本端非同步来源（文件 App 导入 / 未配对来源）——**永不删除**。
    /// 来源（导入标记 / 同步账本）由调用方注入；v1 默认空集（等 M6 接账本）。
    var protectedRelativePaths: Set<String> = []
    /// 落地目录名（曲库根内，隐藏目录——同步扫描跳过隐藏文件）
    var incomingDirectoryName: String = ".sync-incoming"
}

/// 对账结果 → 本次要做的动作（纯逻辑，可单测）。
struct SyncLibrarySyncPlan: Equatable, Sendable {
    /// 要请求对端推送的文件（nil = 无需拉取）
    var fetchRequest: SyncFetchRequest?
    /// 要删除的本地条目（已过 deleteScope）
    var deletes: [ManifestEntry] = []
    /// 因私有区豁免被跳过的本地条目（不删，审计）
    var protectedSkipped: [ManifestEntry] = []
    /// 内容一致的远端条目
    var unchanged: [ManifestEntry] = []
}

enum SyncLibrarySyncPlanner {
    /// 远端 manifest + 本地清单 → 动作计划。
    static func plan(
        remote: SyncManifestResponse,
        local: [ManifestEntry],
        configuration: SyncLibrarySyncConfiguration,
        members: SyncCollectionMembers = SyncCollectionMembers()
    ) -> SyncLibrarySyncPlan {
        let scope = SyncManifestReconciler.deleteScope(
            collection: configuration.collection,
            members: members,
            localEntries: local,
            protectedRelativePaths: configuration.protectedRelativePaths
        )
        let reconciliation = SyncManifestReconciler.reconcile(
            remote: remote.entries,
            local: local,
            deleteScope: scope
        )
        let paths = SyncFetchRequest.normalize(reconciliation.toFetch.map(\.relativePath))
        return SyncLibrarySyncPlan(
            fetchRequest: paths.isEmpty
                ? nil
                : SyncFetchRequest(collection: configuration.collection, relativePaths: paths),
            deletes: reconciliation.toDelete,
            protectedSkipped: reconciliation.protectedSkipped,
            unchanged: reconciliation.unchanged
        )
    }

    /// 执行期复核：该条目此刻是否仍归同步管（私有区/未受管 → false）。
    static func mayDelete(
        _ entry: ManifestEntry,
        configuration: SyncLibrarySyncConfiguration,
        members: SyncCollectionMembers = SyncCollectionMembers(),
        local: [ManifestEntry]
    ) -> Bool {
        SyncManifestReconciler.deleteScope(
            collection: configuration.collection,
            members: members,
            localEntries: local,
            protectedRelativePaths: configuration.protectedRelativePaths
        ).manages(entry.relativePath)
    }
}

// MARK: - 落盘副作用出口（生产实现注入；测试用 spy）

/// 同步结果的本地副作用：入库（走既有入口）/ 删除。
/// 非 async：会话线程同步驱动，实现内部自行 hop 主线程（fire-and-forget）。
protocol SyncLibrarySyncSink: Sendable {
    /// 一个文件已落盘到位 → 走既有入库入口。
    func indexLandedFile(at url: URL)
    /// 删除本地副本（文件 + 曲库行）。
    func deleteLocalFile(at url: URL, stableId: String?)
}

/// 生产实现：入库复用 LibraryIndexer 既有入口；删除走 FileManager + DatabaseManager。
final class LibraryIndexerSyncSink: SyncLibrarySyncSink, @unchecked Sendable {
    func indexLandedFile(at url: URL) {
        Task { @MainActor in
            _ = await LibraryIndexer.shared.processExternalFile(url)
        }
    }

    func deleteLocalFile(at url: URL, stableId: String?) {
        try? FileManager.default.removeItem(at: url)
        if let stableId {
            try? DatabaseManager.shared.deleteTrack(byStableId: stableId)
        }
    }
}

// MARK: - 控制器

/// Client 侧文件同步控制器（一个会话一个实例；M6 由 UI 持有并展示状态）。
final class SyncLibrarySyncController: @unchecked Sendable {
    enum StartError: Error, Equatable {
        /// 会话未 ready（未配对/已关闭）
        case sessionNotReady
    }

    private let session: SyncPeerSession
    private let libraryRoot: URL
    private let sink: SyncLibrarySyncSink
    private let configuration: SyncLibrarySyncConfiguration
    private let members: SyncCollectionMembers
    private let database: DatabaseManager
    private let fileManager: FileManager
    private let lock = NSLock()

    private var manifestPeer: SyncManifestPeer?
    private var receiver: SyncFileReceiver?
    private var priorAppHandler: ((SyncFrame) -> Void)?

    // 锁保护状态
    private var stateValue: SyncLibrarySyncState = .idle
    private var summary = SyncLibrarySyncSummary()
    private var pendingDeletes: [ManifestEntry] = []
    private var localEntriesAtPlan: [ManifestEntry] = []
    /// 文件名 → 期望的相对路径（串行推送下按名回收；同名多路径取请求序首个未匹配）
    private var expectedByFileName: [String: [String]] = [:]

    /// 每态回调（会话线程触发）。
    var onStateChange: ((SyncLibrarySyncState) -> Void)?
    /// 落盘并交给入库入口时回调（进度用）。
    var onFileApplied: ((String) -> Void)?

    init(
        session: SyncPeerSession,
        libraryRoot: URL,
        sink: SyncLibrarySyncSink = LibraryIndexerSyncSink(),
        configuration: SyncLibrarySyncConfiguration = SyncLibrarySyncConfiguration(),
        members: SyncCollectionMembers = SyncCollectionMembers(),
        database: DatabaseManager = .shared,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.libraryRoot = libraryRoot
        self.sink = sink
        self.configuration = configuration
        self.members = members
        self.database = database
        self.fileManager = fileManager
    }

    var state: SyncLibrarySyncState {
        lock.lock()
        defer { lock.unlock() }
        return effectiveStateLocked()
    }

    /// 有效状态：终态（.done）的 summary 取**实时值**——接收端先回 ack 再回调
    /// onCompletion（SyncFileReceiver 的顺序），对端 sync_fetch_result 因此可能先于
    /// 最后一个文件的落盘/入库回调到达；实时读取保证调用方看到完整账目。
    private func effectiveStateLocked() -> SyncLibrarySyncState {
        if case .done = stateValue {
            return .done(summary)
        }
        return stateValue
    }

    var currentSummary: SyncLibrarySyncSummary {
        lock.lock()
        defer { lock.unlock() }
        return summary
    }

    // MARK: 生命周期

    /// 开始一次同步（会话必须已 ready）：请求 manifest，随后由帧驱动。
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

        let incoming = libraryRoot.appendingPathComponent(
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
        transition(to: .failed("cancelled"))
    }

    // MARK: manifest → 对账 → 拉取

    private func handleManifest(_ response: SyncManifestResponse) {
        let local = SyncLocalLibraryScanner.entries(
            in: libraryRoot,
            database: database,
            fileManager: fileManager
        )
        let plan = SyncLibrarySyncPlanner.plan(
            remote: response,
            local: local,
            configuration: configuration,
            members: members
        )

        lock.lock()
        localEntriesAtPlan = local
        pendingDeletes = plan.deletes
        summary.protectedSkipped = plan.protectedSkipped.map(\.relativePath)
        if let request = plan.fetchRequest {
            summary.requested = request.relativePaths
            expectedByFileName = Self.expectedPathsByName(request.relativePaths)
        }
        lock.unlock()

        guard let request = plan.fetchRequest else {
            // 无差异/无需拉取：直接进删除阶段（状态机允许 requestingManifest → applyingDeletes）
            applyDeletes()
            return
        }
        transition(to: .fetching)
        do {
            let payload = try SyncFetchCodec.encode(request)
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
                return // 未请求过的文件：不落位（留在落地目录，交由 M6 清理）
            }
            let destination = libraryRoot.appendingPathComponent(relativePath)
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: url, to: destination)
            } catch {
                lock.lock()
                summary.failed.append(
                    SyncFileFetchFailure(relativePath: relativePath, reason: SyncFetchFailureReason.sendFailed)
                )
                lock.unlock()
                return
            }
            sink.indexLandedFile(at: destination)
            lock.lock()
            summary.completed.append(relativePath)
            lock.unlock()
            onFileApplied?(relativePath)
        case .failed:
            // 单文件失败由对端 sync_fetch_result 归集（本端不重复记账）
            break
        }
    }

    // MARK: 结果帧 → 删除 → 收尾

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
        summary.failed = result.failed
        lock.unlock()
        applyDeletes()
    }

    /// 删除阶段：逐个复核 deleteScope（私有区/未受管绝不删）后执行。
    private func applyDeletes() {
        transition(to: .applyingDeletes)

        lock.lock()
        let deletes = pendingDeletes
        let local = localEntriesAtPlan
        lock.unlock()

        for entry in deletes {
            let allowed = SyncLibrarySyncPlanner.mayDelete(
                entry,
                configuration: configuration,
                members: members,
                local: local
            )
            guard allowed else {
                lock.lock()
                if !summary.protectedSkipped.contains(entry.relativePath) {
                    summary.protectedSkipped.append(entry.relativePath)
                }
                lock.unlock()
                continue
            }
            let url = libraryRoot.appendingPathComponent(entry.relativePath)
            sink.deleteLocalFile(at: url, stableId: entry.stableId)
            try? fileManager.removeItem(at: url) // 幂等：sink 实现可能已删
            lock.lock()
            summary.deleted.append(entry.relativePath)
            lock.unlock()
        }

        lock.lock()
        let finished = summary
        lock.unlock()
        transition(to: .done(finished))
    }

    // MARK: 辅助

    /// 文件名 → 期望相对路径列表（按请求序）。同名多路径时按序取首个未匹配。
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
        // 同名只保留一组，移除后不再期待
        _ = paths
        expectedByFileName[name] = nil
        return path
    }

    private func transition(to newState: SyncLibrarySyncState) {
        lock.lock()
        let current = stateValue
        guard SyncLibrarySyncStateMachine.canTransition(from: current, to: newState) else {
            lock.unlock()
            return
        }
        stateValue = newState
        let effective = effectiveStateLocked()
        lock.unlock()
        onStateChange?(effective)
    }
}
