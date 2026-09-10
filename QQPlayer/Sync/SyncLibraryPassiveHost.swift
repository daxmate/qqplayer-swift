//
//  SyncLibraryPassiveHost.swift
//  QQPlayer
//
//  R1b-1（2026-09-11）同步方向改造 · **被动端装配**（发起方恒为 Mac，移动端纯被动）。
//
//  一个已配对会话的被动端能力，两件事：
//   ① 应答 Mac 的请求（本文件不实现协议细节，全部走共用实现）：
//      - `manifest_request`（帧 10）→ 本端曲库清单（含 aligned 歌词条目）→ `manifest_response`
//      - `sync_fetch_request`（帧 12）→ 越界拒读 + 串行推送本端文件 → `sync_fetch_result`
//        这两个能力由 `SyncLocalLibraryProvider` 提供（Mac 侧同一实现，见其文件头映射稿）。
//   ② 接收 Mac 的推送并落库：
//      - `library_push_announce`（帧 14）→ 建认领表（传输名 → 目标相对路径）
//      - 既有停等传输（帧 4/5/6，`SyncFileReceiver`）→ SHA-256 校验后落在
//        `曲库根/.sync-incoming/` → 认领 → 移入目标相对路径 → **走既有
//        `LibraryIndexerSyncSink`（`LibraryIndexer.processExternalFile`）入库**
//      - aligned 歌词 → `SyncLyricsReceiver`（与主动流程共用同一实现）安装进歌词库
//
//  语义硬约束（§6.1 + §12b 决策 6/7，本文件是执行点）：
//  - **不传播删除**：本类不存在删除本端曲库文件/曲库行/歌词的路径。「落位」只有
//    「目标路径已存在 → 同路径就地替换为新内容」（= §6.1「内容不同则更新」）；
//    对端 manifest/声明里没有的本端内容一律保留。
//  - 歌词只处理 aligned（wire 命名空间 `@lyrics/`）；`manual`/`network` 不在本链路。
//  - 未声明过的传输（名字不在认领表）不落位、不索引，直接清理临时文件并记账。
//
//  线程：会话线程（NW 队列）同步驱动；状态用锁保护。
//

import Foundation

// MARK: - 配置 / 账目

/// 被动端配置。
struct SyncLibraryPassiveConfiguration: Equatable, Sendable {
    /// 应答 manifest 时用的集合（v1 默认全库）
    var collection: SyncCollection = .all
    /// 落地目录名（曲库根内，隐藏目录——曲库扫描跳过隐藏文件）
    var incomingDirectoryName: String = ".sync-incoming"
}

/// 一次推送接收的账目（诊断/测试/UI 用）。
struct SyncLibraryPassiveSummary: Equatable, Sendable {
    /// 已落位并交给入库入口的相对路径（含歌词 wire 路径），按接收序
    var landed: [String] = []
    /// 失败记录
    var failed: [SyncPushFailure] = []
    /// 收到但本端无对应歌曲、被丢弃的 aligned 歌词（下次同步自愈；审计用）
    var discardedLyrics: [String] = []
    /// 未声明过的传输名（不落位；审计用）
    var undeclaredTransfers: [String] = []

    /// 已处理的声明条目数（含落位/失败/丢弃）。
    var accountedEntries: Int = 0
    /// 最近一批声明的条目数（0 = 尚无声明）。
    var announcedEntries: Int = 0
    /// 最近一批声明是否已全部处理完（收尾已跑，含暂存歌词重试）。
    var batchCompleted: Bool = false
}

// MARK: - 被动端

/// 移动端（iOS）被动侧装配：一个会话一个实例；由 iOS 侧在会话 ready 后 `attach(to:)`。
final class SyncLibraryPassiveHost: @unchecked Sendable {
    /// 曲库根（对端 manifest 相对路径基准 + 推送落位根）。
    let libraryRoot: URL
    /// 曲库根显示名（manifest 响应附带）。
    let rootName: String

    private let provider: SyncLocalLibraryProvider
    private let sink: SyncLibrarySyncSink
    private let configuration: SyncLibraryPassiveConfiguration
    private let fileManager: FileManager
    private let lyricsStore: AlignedLyricsStore
    private let lyricsMapping: SyncLyricsContentMapping
    /// 歌词接收编排：**每批声明重建**（暂存/收尾语义按批界定，与主动流程单轮等价）
    private var lyricsReceiver: SyncLyricsReceiver
    private let lock = NSLock()

    private var receiver: SyncFileReceiver?
    private var priorAppHandler: ((SyncFrame) -> Void)?
    private var priorClosedHandler: ((SyncSessionCloseReason) -> Void)?

    // 锁保护状态
    private var claims = SyncPushClaimTable()
    private var summaryValue = SyncLibraryPassiveSummary()

    /// 有文件已落位并交给入库入口（进度回调；锁外触发）。
    var onFileLanded: ((String) -> Void)?
    /// 一批推送处理完毕（含暂存歌词收尾；锁外触发）。
    var onBatchCompleted: ((SyncLibraryPassiveSummary) -> Void)?
    /// 一次拉取（Mac 从设备下载）的结论（诊断/UI 用）。
    var onFetchResult: ((SyncFetchResult) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return fetchResultHandler }
        set { lock.lock(); fetchResultHandler = newValue; lock.unlock() }
    }

    /// 对端请求了 manifest 但本地未接线（诊断）。
    var onProviderUnavailable: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return providerUnavailableHandler }
        set { lock.lock(); providerUnavailableHandler = newValue; lock.unlock() }
    }

    private var fetchResultHandler: ((SyncFetchResult) -> Void)?
    private var providerUnavailableHandler: (() -> Void)?

    init(
        libraryRoot: URL,
        rootName: String? = nil,
        sink: SyncLibrarySyncSink = LibraryIndexerSyncSink(),
        configuration: SyncLibraryPassiveConfiguration = SyncLibraryPassiveConfiguration(),
        database: DatabaseManager = .shared,
        fileManager: FileManager = .default,
        lyricsStore: AlignedLyricsStore = .shared,
        lyricsMapping: SyncLyricsContentMapping? = nil
    ) {
        let mapping = lyricsMapping ?? .live(database: database)
        self.libraryRoot = libraryRoot
        self.rootName = rootName ?? libraryRoot.lastPathComponent
        self.sink = sink
        self.configuration = configuration
        self.fileManager = fileManager
        self.lyricsStore = lyricsStore
        self.lyricsMapping = mapping
        self.lyricsReceiver = SyncLyricsReceiver(
            lyricsStore: lyricsStore,
            lyricsMapping: mapping,
            fileManager: fileManager
        )
        let descriptor = SyncLocalLibraryDescriptor.live(
            libraryRoot: libraryRoot,
            rootName: self.rootName,
            database: database,
            fileManager: fileManager,
            lyricsStore: lyricsStore,
            lyricsMapping: mapping
        )
        self.provider = SyncLocalLibraryProvider(descriptor: descriptor, fileManager: fileManager)
        provider.onFetchResult = { [weak self] result in self?.onFetchResult?(result) }
        provider.onProviderUnavailable = { [weak self] in self?.onProviderUnavailable?() }
    }

    /// 是否已接线（诊断用）。
    var isAttached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receiver != nil
    }

    /// 当前账目快照。
    var summary: SyncLibraryPassiveSummary {
        lock.lock()
        defer { lock.unlock() }
        return summaryValue
    }

    // MARK: 接线 / 拆除

    /// 把一个已配对会话接成被动端。曲库根不存在 → 不接线，返回 false。
    @discardableResult
    func attach(to session: SyncPeerSession) -> Bool {
        guard provider.attach(to: session) else { return false }

        let incoming = libraryRoot.appendingPathComponent(
            configuration.incomingDirectoryName,
            isDirectory: true
        )
        try? fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)

        let receiver = SyncFileReceiver(session: session, directory: incoming)
        receiver.onCompletion = { [weak self] outcome in
            self?.handleTransfer(outcome)
        }

        lock.lock()
        self.receiver = receiver
        priorAppHandler = session.onApplicationFrame
        priorClosedHandler = session.onClosed
        lock.unlock()

        session.onApplicationFrame = { [weak self] frame in
            guard let self else {
                return
            }
            if frame.type == .libraryPushAnnounce {
                self.handleAnnounce(frame)
            }
            self.priorAppHandler?(frame)
        }
        session.onClosed = { [weak self] reason in
            guard let self else {
                return
            }
            self.handleSessionClosed()
            self.priorClosedHandler?(reason)
        }
        return true
    }

    /// 拆除接线（会话关闭 / 服务停止）：停止接收 + 中止应答 + 丢弃暂存临时文件。
    func detach() {
        lock.lock()
        let receiver = self.receiver
        self.receiver = nil
        claims = SyncPushClaimTable()
        lock.unlock()
        receiver?.cancel()
        lyricsReceiver.cancel()
        provider.detach()
    }

    // MARK: 推送声明（帧 14）

    private func handleAnnounce(_ frame: SyncFrame) {
        let announce: SyncLibraryPushAnnounce
        do {
            announce = try SyncPushCodec.decode(SyncLibraryPushAnnounce.self, from: frame.payload)
        } catch {
            return // 载荷非法：忽略（不落位任何东西），诊断由接收端自己记
        }
        lock.lock()
        claims = SyncPushClaimTable(entries: announce.entries)
        summaryValue.accountedEntries = 0
        summaryValue.announcedEntries = announce.entries.count
        summaryValue.batchCompleted = false
        let previousReceiver = lyricsReceiver
        lyricsReceiver = SyncLyricsReceiver(
            lyricsStore: lyricsStore,
            lyricsMapping: lyricsMapping,
            fileManager: fileManager
        )
        lock.unlock()
        // 上一批没收尾完的暂存临时文件不再需要（本批歌词重新声明）
        previousReceiver.cancel()

        if announce.isEmpty {
            finishBatch()
        }
    }

    // MARK: 接收 → 落位 + 入库

    private func handleTransfer(_ outcome: SyncFileReceiver.Outcome) {
        switch outcome {
        case let .received(url):
            receive(url: url)
        case let .failed(error):
            lock.lock()
            summaryValue.failed.append(
                SyncPushFailure(
                    relativePath: "",
                    reason: SyncPushFailureReason.receiveFailed,
                    detail: "\(error)"
                )
            )
            lock.unlock()
        }
    }

    /// 一个文件收齐（SyncFileReceiver 已做 SHA-256 校验）→ 认领 → 落位 / 安装歌词。
    private func receive(url: URL) {
        let transferName = url.lastPathComponent

        lock.lock()
        let claimed = claims.claim(transferName: transferName)
        if claimed == nil {
            summaryValue.undeclaredTransfers.append(transferName)
        }
        lock.unlock()

        guard let relativePath = claimed else {
            // 未声明过的传输：不落位、不索引（清掉落地目录里的临时文件）
            try? fileManager.removeItem(at: url)
            return
        }

        if SyncLyricsNamespace.isLyricsPath(relativePath) {
            applyLyrics(lyricsReceiver.receive(tempURL: url, wirePath: relativePath))
        } else {
            land(fileAt: url, relativePath: relativePath)
        }
        accountOne()
    }

    /// 把收到的曲库文件移入目标相对路径并交给既有入库入口。
    private func land(fileAt url: URL, relativePath: String) {
        guard case let .resolved(destination) = SyncLibraryPathResolver.resolve(
            relativePath: relativePath,
            root: libraryRoot
        ) else {
            lock.lock()
            summaryValue.failed.append(
                SyncPushFailure(relativePath: relativePath, reason: SyncPushFailureReason.invalidPath, detail: nil)
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
                SyncPushFailure(
                    relativePath: relativePath,
                    reason: SyncPushFailureReason.landFailed,
                    detail: "\(error)"
                )
            )
            lock.unlock()
            try? fileManager.removeItem(at: url)
            return
        }
        sink.indexLandedFile(at: destination)
        lock.lock()
        summaryValue.landed.append(relativePath)
        lock.unlock()
        onFileLanded?(relativePath)
    }

    /// 歌词安装结论 → 账目（`SyncLyricsReceiver` 与主动流程共用同一实现）。
    private func applyLyrics(_ outcome: SyncLyricsReceiver.Outcome) {
        switch outcome {
        case let .installed(wirePath):
            lock.lock()
            summaryValue.landed.append(wirePath)
            lock.unlock()
            onFileLanded?(wirePath)
        case .pending:
            break // 本端歌曲还没入库：本批收尾时再试一次映射
        case let .discarded(wirePath):
            lock.lock()
            summaryValue.discardedLyrics.append(wirePath)
            lock.unlock()
        case let .failed(wirePath):
            lock.lock()
            summaryValue.failed.append(
                SyncPushFailure(relativePath: wirePath, reason: SyncPushFailureReason.landFailed, detail: nil)
            )
            lock.unlock()
        }
    }

    // MARK: 批次收尾

    /// 一条声明条目已处理（落位 / 丢弃 / 失败）——全部处理完 → 收尾。
    private func accountOne() {
        lock.lock()
        summaryValue.accountedEntries += 1
        let done = summaryValue.announcedEntries > 0
            && summaryValue.accountedEntries >= summaryValue.announcedEntries
        lock.unlock()
        if done {
            finishBatch()
        }
    }

    /// 批次收尾：暂存歌词再试一次映射（此时同批先落下的歌已入库），再落终态。
    /// **无删除阶段**（§6.1 + §12b 决策 7：删除不跨端传播）。
    private func finishBatch() {
        for outcome in lyricsReceiver.flushPending() {
            applyLyrics(outcome)
        }
        lock.lock()
        summaryValue.batchCompleted = true
        let snapshot = summaryValue
        lock.unlock()
        onBatchCompleted?(snapshot)
    }

    private func handleSessionClosed() {
        detach()
    }
}
