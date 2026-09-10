//
//  SyncLibrarySyncController.swift
//  QQPlayer
//
//  局域网同步（S2, M3-3b）Client 侧文件同步控制器：ready 后拉 manifest →
//  本地清单对账 → 按路径请求拉取（Host 串行推送）→ 落盘 + 走既有入库入口。
//
//  状态机（每态回调 onStateChange，UI 留 M6）：
//    idle → requestingManifest → fetching → done / failed
//  （无可拉取文件时 requestingManifest → done 直落；纯逻辑见
//   SyncLibrarySyncStateMachine）
//
//  同步语义（§6.1 硬要求，本文件是执行点）：**不传播删除**——任一端删除歌曲都是
//  本地事务：对端 manifest 里没有、而本端已有的文件**一律保留**（既不删文件也不删
//  曲库行）。同步只做「补齐缺失 + 内容不同则更新」；因此本文件不存在删除执行路径。
//
//  落地：文件先落曲库根内的隐藏落地目录（同步扫描跳过隐藏文件，不会被误当曲库内容），
//  收齐校验通过（SyncFileReceiver 已做 SHA-256）后移入相对路径位置，再交给
//  sink.indexLandedFile 走既有 LibraryIndexer 入口入库——本文件不写 DB 逻辑。
//
//  M4-2b aligned 歌词随歌同步（§6.3 + 2026-09-10 语义修订）：
//  - 本地清单 = 曲库文件 + aligned 歌词（`@lyrics/{歌曲 content_hash}.json`），
//    两者走同一套对账 / 集合过滤；**歌词只参与「补齐缺失 / 内容不同则更新」**。
//  - **不传播删除（2026-09-10 用户拍板）**：任一端删歌/删歌词只在本地生效，
//    绝不能因对端多出/缺失而删本端内容——本控制器不提供任何删除路径。
//  - 收到歌词文件：经 content_hash → 本端 stableId 映射后交给 `AlignedLyricsStore`
//    安装（不落进曲库根、不写孤儿）。本端歌曲还没入库（同一轮同步里歌比歌词先到）
//    → 暂存到本轮收尾再试一次；仍解析不出 → **丢弃**（歌词是依附歌曲的内容，
//    不留孤儿文件），下次同步会从 manifest 重新拉到（自愈），不引入第二套挂起队列。
//  - 本文件**不发起同步**（发起方恒为 Mac，2026-09-10 拍板）：这里只是
//    会话帧驱动的一端行为，推送/拉取由 Mac 侧装配决定。
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
    /// 收到但本端无对应歌曲、未落库的 aligned 歌词（丢弃；下次同步自愈，审计用）
    var orphanLyricsSkipped: [String] = []

    /// 本次是否动了本端歌词库（诊断用）。
    var touchedLyrics: Bool {
        (completed + failed.map(\.relativePath) + orphanLyricsSkipped)
            .contains { SyncLyricsNamespace.isLyricsPath($0) }
    }
}

/// 状态迁移合法性（纯逻辑，可单测）：保证 UI/日志看到一致的序列。
enum SyncLibrarySyncStateMachine {
    static func canTransition(from: SyncLibrarySyncState, to: SyncLibrarySyncState) -> Bool {
        switch (from, to) {
        case (.idle, .requestingManifest): return true
        case (.requestingManifest, .fetching): return true
        // 无待拉取条目：对账后直接收尾
        case (.requestingManifest, .done): return true
        // 拉取完成（含对端结果帧）：收尾
        case (.fetching, .done): return true
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
    /// 同步集合（v1 默认全库）
    var collection: SyncCollection = .all
    /// 落地目录名（曲库根内，隐藏目录——同步扫描跳过隐藏文件）
    var incomingDirectoryName: String = ".sync-incoming"
}

/// 对账结果 → 本次要做的动作（纯逻辑，可单测）。
struct SyncLibrarySyncPlan: Equatable, Sendable {
    /// 要请求对端推送的文件（nil = 无需拉取）
    var fetchRequest: SyncFetchRequest?
    /// 内容一致的远端条目
    var unchanged: [ManifestEntry] = []
}

enum SyncLibrarySyncPlanner {
    /// 远端 manifest + 本地清单 → 动作计划（**只补齐，不删除**）。
    /// 对端没有、而本端已有的条目一律保留（§6 语义修订：删除不跨端传播），
    /// 因此计划里不存在删除动作。
    static func plan(
        remote: SyncManifestResponse,
        local: [ManifestEntry],
        configuration: SyncLibrarySyncConfiguration
    ) -> SyncLibrarySyncPlan {
        let reconciliation = SyncManifestReconciler.reconcile(
            remote: remote.entries,
            local: local
        )
        let paths = SyncFetchRequest.normalize(reconciliation.toFetch.map(\.relativePath))
        return SyncLibrarySyncPlan(
            fetchRequest: paths.isEmpty
                ? nil
                : SyncFetchRequest(collection: configuration.collection, relativePaths: paths),
            unchanged: reconciliation.unchanged
        )
    }
}

// MARK: - 落盘副作用出口（生产实现注入；测试用 spy）

/// 同步结果的本地副作用：入库（走既有入口）。
/// 非 async：会话线程同步驱动，实现内部自行 hop 主线程（fire-and-forget）。
protocol SyncLibrarySyncSink: Sendable {
    /// 一个文件已落盘到位 → 走既有入库入口。
    func indexLandedFile(at url: URL)
}

/// 生产实现：入库复用 LibraryIndexer 既有入口。
/// **无删除出口**（§6 语义修订 2026-09-10：删除不传播）。
final class LibraryIndexerSyncSink: SyncLibrarySyncSink, @unchecked Sendable {
    func indexLandedFile(at url: URL) {
        Task { @MainActor in
            _ = await LibraryIndexer.shared.processExternalFile(url)
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
    private let database: DatabaseManager
    private let fileManager: FileManager
    /// aligned 歌词库（Part A 单一入口）+ content_hash 映射（歌词同步开关）
    private let lyricsStore: AlignedLyricsStore
    private let lyricsMapping: SyncLyricsContentMapping
    private let lock = NSLock()

    private var manifestPeer: SyncManifestPeer?
    private var receiver: SyncFileReceiver?
    private var priorAppHandler: ((SyncFrame) -> Void)?

    // 锁保护状态
    private var stateValue: SyncLibrarySyncState = .idle
    private var summary = SyncLibrarySyncSummary()
    /// 文件名 → 期望的相对路径（串行推送下按名回收；同名多路径取请求序首个未匹配）
    private var expectedByFileName: [String: [String]] = [:]
    /// 已收到、但本端歌曲尚未入库的歌词文件（本轮收尾再试一次映射）
    private var pendingLyrics: [(wirePath: String, fileURL: URL)] = []
    /// 本轮是否已收尾（收尾后到的歌词不再暂存，直接丢弃 + 记账）
    private var passFinalized = false

    /// 每态回调（会话线程触发）。
    var onStateChange: ((SyncLibrarySyncState) -> Void)?
    /// 落盘并交给入库入口时回调（进度用）。
    var onFileApplied: ((String) -> Void)?

    init(
        session: SyncPeerSession,
        libraryRoot: URL,
        sink: SyncLibrarySyncSink = LibraryIndexerSyncSink(),
        configuration: SyncLibrarySyncConfiguration = SyncLibrarySyncConfiguration(),
        database: DatabaseManager = .shared,
        fileManager: FileManager = .default,
        lyricsStore: AlignedLyricsStore = .shared,
        lyricsMapping: SyncLyricsContentMapping = .unresolved
    ) {
        self.session = session
        self.libraryRoot = libraryRoot
        self.sink = sink
        self.configuration = configuration
        self.database = database
        self.fileManager = fileManager
        self.lyricsStore = lyricsStore
        self.lyricsMapping = lyricsMapping
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
        lock.lock()
        passFinalized = false
        lock.unlock()
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
            lyricsStore: lyricsStore,
            lyricsMapping: lyricsMapping,
            database: database,
            fileManager: fileManager
        )
        let plan = SyncLibrarySyncPlanner.plan(
            remote: response,
            local: local,
            configuration: configuration
        )

        lock.lock()
        if let request = plan.fetchRequest {
            summary.requested = request.relativePaths
            expectedByFileName = Self.expectedPathsByName(request.relativePaths)
        }
        let finished = summary
        lock.unlock()

        guard let request = plan.fetchRequest else {
            // 无可拉取条目（含「对端少的本端自己保留」）：直接收尾
            transition(to: .done(finished))
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
            if SyncLyricsNamespace.isLyricsPath(relativePath) {
                acceptLyricsFile(from: url, wirePath: relativePath)
                return
            }
            let destination = libraryRoot.appendingPathComponent(relativePath)
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
        summary.failed = result.failed
        lock.unlock()
        finalize()
    }

    /// 收尾：先兜现暂存歌词（此时同轮先落下的歌多已入库），再落终态。
    /// **无删除阶段**（§6 语义修订：删除不跨端传播）。
    private func finalize() {
        flushPendingLyrics()
        lock.lock()
        let finished = summary
        lock.unlock()
        transition(to: .done(finished))
    }

    // MARK: 歌词落地（M4-2b）

    private enum LyricsInstallOutcome {
        /// 已写进本端歌词库
        case installed
        /// 本端还没有对应歌曲（暂存重试 / 最终丢弃）
        case orphan
        /// 解码或写盘失败
        case failed
    }

    /// 收到一个歌词文件：映射 + 安装；映射不到时按本轮是否收尾决定「暂存」或「丢弃」。
    private func acceptLyricsFile(from tempURL: URL, wirePath: String) {
        switch installLyricsFile(tempURL, wirePath: wirePath) {
        case .installed:
            lock.lock()
            summary.completed.append(wirePath)
            lock.unlock()
            onFileApplied?(wirePath)
        case .orphan:
            var shouldDiscard = false
            lock.lock()
            if passFinalized {
                summary.orphanLyricsSkipped.append(wirePath)
                shouldDiscard = true
            } else {
                pendingLyrics.append((wirePath: wirePath, fileURL: tempURL))
            }
            lock.unlock()
            if shouldDiscard {
                // 不放孤儿文件；下次同步远端 manifest 仍在 → 重新拉到（自愈）
                try? fileManager.removeItem(at: tempURL)
            }
        case .failed:
            lock.lock()
            summary.failed.append(
                SyncFileFetchFailure(relativePath: wirePath, reason: SyncFetchFailureReason.sendFailed)
            )
            lock.unlock()
            try? fileManager.removeItem(at: tempURL)
        }
    }

    /// 单次安装尝试：wire 路径 → 歌曲 content_hash → 本端 stableId → 歌词库安装。
    private func installLyricsFile(_ tempURL: URL, wirePath: String) -> LyricsInstallOutcome {
        guard let songHash = SyncLyricsNamespace.songContentHash(fromWirePath: wirePath),
              let stableId = lyricsMapping.stableIdForContentHash(songHash)
        else { return .orphan }
        do {
            try lyricsStore.install(receivedFileAt: tempURL, forStableId: stableId)
            return .installed
        } catch {
            return .failed
        }
    }

    /// 本轮收尾：暂存歌词再试一次映射（同轮先落下的歌此时已入库），仍不行则丢弃。
    private func flushPendingLyrics() {
        lock.lock()
        passFinalized = true
        let pending = pendingLyrics
        pendingLyrics = []
        lock.unlock()

        for item in pending {
            switch installLyricsFile(item.fileURL, wirePath: item.wirePath) {
            case .installed:
                lock.lock()
                summary.completed.append(item.wirePath)
                lock.unlock()
                onFileApplied?(item.wirePath)
            case .orphan:
                lock.lock()
                summary.orphanLyricsSkipped.append(item.wirePath)
                lock.unlock()
                try? fileManager.removeItem(at: item.fileURL)
            case .failed:
                lock.lock()
                summary.failed.append(
                    SyncFileFetchFailure(relativePath: item.wirePath, reason: SyncFetchFailureReason.sendFailed)
                )
                lock.unlock()
                try? fileManager.removeItem(at: item.fileURL)
            }
        }
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
