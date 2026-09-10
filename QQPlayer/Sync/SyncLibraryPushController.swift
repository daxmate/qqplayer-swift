//
//  SyncLibraryPushController.swift
//  QQPlayer
//
//  R1b-2（2026-09-11）同步方向改造 · **发起端（Mac）「推送到设备」控制器**。
//
//  ════════════════════════════════════════════════════════════════════════════
//  为什么放在平台无关层（`QQPlayer/Sync/`，而非 `QQPlayer/Mac/`）
//  ════════════════════════════════════════════════════════════════════════════
//  发起方恒为桌面端（docs/lan-sync-design.md §6.1 + §12b 决策 6），但本类本身
//  **零平台依赖**（Foundation + 共用协议层）：曲库事实一律经
//  `SyncLocalLibraryDescriptor` 注入，Mac 侧装配（`MacSyncHostService` / M6 UI）
//  只负责给根路径与生命周期。放 `Sync/` 使无模拟器 harness 与 iOS 测试 target
//  都能真编真跑（`Mac/` 目录被 iOS target 例外表排除，测试 target 看不到）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  流程
//  ════════════════════════════════════════════════════════════════════════════
//    Mac 选集合 → 发 `manifest_request`(10) → 收 `manifest_response`(11)
//    → 推送方向对账（本端选择集 vs 对端 manifest）→ 取「对端缺失 / 内容不同」条目
//    → 发 `library_push_announce`(14)（认领表）→ `SyncFileSender` 串行推送
//      每个文件（帧 4/5/6 停等，收 fileAck）→ 结果账目 + 回调
//
//  **推送方向对账为什么自己写**（`SyncLibraryPushPlanner`）：
//  `SyncManifestReconciler` 是**拉取方向**语义（以对端为准 → 本端该拉什么），
//  本类要的恰好相反（以本端选择集为准 → 该给对端送什么）。它的既有语义不允许
//  改动（R1b-1/R1b-2 契约），也不适合用参数换向（同名条目在两侧的角色会反）。
//  因此这里只**调用**它的内容判定单点 `contentMatches(local:remote:)`，方向
//  判定自己实现——判据与它逐字一致：双侧 contentHash 均非空且相等 = 一致；
//  任一侧 nil = 内容未知 = 保守判为「需推送」（宁可多传一次，不可漏传）。
//
//  语义硬约束（§6.1 + §12b 决策 6/7）：
//  - **不传播删除**：本类不存在删除本端/对端任何文件、曲库行、歌词的路径。
//    对端多出来的条目（manifest 里有、本端选择集里没有）**什么都不做**。
//  - 同步集合 = 用户显式选择（v1：全库枚举 / 显式相对路径集合；歌单勾选是 R3）。
//  - aligned 歌词随歌推送（wire 路径 `@lyrics/{歌曲 content_hash}.json`，与被动端
//    接收口径同一命名空间）；`manual` / `network` 歌词不参与同步。
//  - 传输身份：歌曲 = `content_hash`；歌词 = 所属歌曲的 `content_hash`。
//
//  线程：会话线程（NW 队列）同步驱动（内存回环下 `SyncFileSender.send` 会在
//  本调用内同步跑完整轮传输）；状态用锁保护，回调一律锁外触发。
//

import Foundation

// MARK: - 选择集

/// 推送选择集（v1）。
enum SyncLibraryPushSelection: Equatable, Sendable {
    /// 全库枚举（该端曲库全部可同步文件，含 aligned 歌词条目）
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

    /// 在 manifest 条目上应用选择集（保持入参顺序；输出仍由调用方排序口径决定）。
    func filter(_ entries: [ManifestEntry]) -> [ManifestEntry] {
        guard let paths = normalizedPaths else { return entries }
        let wanted = Set(paths)
        return entries.filter { wanted.contains($0.relativePath) }
    }
}

// MARK: - 状态 / 账目

/// 一次推送的进度状态。
enum SyncLibraryPushState: Equatable, Sendable {
    case idle
    /// 已请求对端 manifest，等应答
    case requestingManifest
    /// 已发推送声明，正在串行推送文件
    case pushing
    case done(SyncLibraryPushSummary)
    case failed(String)
}

/// 一次推送的结果账目（诊断 / M6 UI / 测试用）。
struct SyncLibraryPushSummary: Equatable, Sendable {
    /// 本次声明推送的相对路径（升序）
    var planned: [String] = []
    /// 对端已一致（同路径 + content_hash 相同）→ 跳过的相对路径（升序）
    var skipped: [String] = []
    /// 已确认送达（对端 fileAck done）的相对路径（推送序）
    var completed: [String] = []
    /// 失败记录（本地不可读 / 传输终态失败 / 声明被丢弃）
    var failed: [SyncPushFailure] = []

    /// 是否每一个计划条目都确认送达。
    var isFullSuccess: Bool { failed.isEmpty && completed.count == planned.count }
}

/// 状态迁移合法性（纯逻辑，可单测）。
enum SyncLibraryPushStateMachine {
    static func canTransition(from: SyncLibraryPushState, to: SyncLibraryPushState) -> Bool {
        switch (from, to) {
        case (.idle, .requestingManifest): return true
        // 全部已一致 / 无条目：对账后直接收尾
        case (.requestingManifest, .done): return true
        case (.requestingManifest, .pushing): return true
        case (.pushing, .done): return true
        default:
            if case .failed = to {
                return !isTerminal(from)
            }
            return false
        }
    }

    static func isTerminal(_ state: SyncLibraryPushState) -> Bool {
        switch state {
        case .done, .failed: return true
        default: return false
        }
    }
}

// MARK: - 推送方向对账（纯逻辑）

/// 推送计划（纯值）。
struct SyncLibraryPushPlan: Equatable, Sendable {
    /// 需推送给对端的本端条目（升序）
    var toPush: [ManifestEntry] = []
    /// 对端已一致（同路径 + content_hash 相同）→ 跳过（升序）
    var unchanged: [ManifestEntry] = []
}

enum SyncLibraryPushPlanner {
    /// 推送方向对账（纯函数）：**以本端选择集为准**。
    /// - 对端缺该相对路径 → 推送
    /// - 同路径 contentHash 相同（非 nil）→ 跳过
    /// - 任一侧 contentHash 为 nil（尚未指纹）→ 保守判为需推送
    /// - **对端多出来的条目 → 什么都不做（不传播删除）**
    static func plan(local: [ManifestEntry], remote: [ManifestEntry]) -> SyncLibraryPushPlan {
        var remoteByPath: [String: ManifestEntry] = [:]
        for entry in remote {
            remoteByPath[entry.relativePath] = entry // later wins（调用方给最终快照）
        }
        var toPush: [ManifestEntry] = []
        var unchanged: [ManifestEntry] = []
        for entry in local {
            guard let remoteEntry = remoteByPath[entry.relativePath] else {
                toPush.append(entry)
                continue
            }
            if SyncManifestReconciler.contentMatches(local: entry, remote: remoteEntry) {
                unchanged.append(entry)
            } else {
                toPush.append(entry)
            }
        }
        return SyncLibraryPushPlan(
            toPush: toPush.sorted { $0.relativePath < $1.relativePath },
            unchanged: unchanged.sorted { $0.relativePath < $1.relativePath }
        )
    }
}

// MARK: - 控制器

/// Mac 侧「推送到设备」控制器（一个会话一个实例；M6 由 UI 持有并展示状态）。
final class SyncLibraryPushController: @unchecked Sendable {
    enum StartError: Error, Equatable {
        /// 会话未 ready（未配对/已关闭）
        case sessionNotReady
    }

    private let session: SyncPeerSession
    private let descriptor: SyncLocalLibraryDescriptor
    private let selection: SyncLibraryPushSelection
    private let members: SyncCollectionMembers
    private let fileManager: FileManager
    private let lock = NSLock()

    private var manifestPeer: SyncManifestPeer?
    private var sender: SyncFileSender?

    /// 待推送队列（已按声明顺序排好）
    private var queue: [PendingPush] = []
    /// 队列驱动中标志（防内存回环同步完成导致递归/重入）
    private var pumping = false

    private var stateValue: SyncLibraryPushState = .idle
    private var summaryValue = SyncLibraryPushSummary()

    /// 每态回调（锁外触发；会话线程）。
    var onStateChange: ((SyncLibraryPushState) -> Void)?
    /// 一个文件确认送达（锁外触发；进度用）。
    var onFilePushed: ((String) -> Void)?

    private struct PendingPush {
        let entry: SyncPushEntry
        let fileURL: URL
    }

    init(
        session: SyncPeerSession,
        descriptor: SyncLocalLibraryDescriptor,
        selection: SyncLibraryPushSelection = .all,
        members: SyncCollectionMembers = SyncCollectionMembers(),
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.descriptor = descriptor
        self.selection = selection
        self.members = members
        self.fileManager = fileManager
    }

    // MARK: 对外状态

    var state: SyncLibraryPushState {
        lock.lock()
        defer { lock.unlock() }
        return effectiveStateLocked()
    }

    /// 终态（.done）的账目取**实时值**：接收端先回 ack 再回调 onCompletion，
    /// 调用方看到的状态必须带完整账目。
    private func effectiveStateLocked() -> SyncLibraryPushState {
        if case .done = stateValue {
            return .done(summaryValue)
        }
        return stateValue
    }

    var summary: SyncLibraryPushSummary {
        lock.lock()
        defer { lock.unlock() }
        return summaryValue
    }

    // MARK: 生命周期

    /// 开始一次推送（会话必须已 ready）：请求对端 manifest，随后由帧驱动。
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

        let sender = SyncFileSender(session: session)
        sender.onCompletion = { [weak self] outcome in
            self?.handleSendOutcome(outcome)
        }
        self.sender = sender

        transition(to: .requestingManifest)
        do {
            try peer.requestManifest(collection: collection)
        } catch {
            transition(to: .failed("请求 manifest 失败：\(error)"))
            throw error
        }
    }

    /// 中止（会话关闭 / 用户取消）：停发文件，状态落 failed。
    func cancel() {
        sender?.cancel()
        transition(to: .failed("cancelled"))
    }

    /// 同步集合（协议载荷用）：显式路径集合 → `.tracks` 之外的语义仍是「本端选择」，
    /// v1 一律用 `.all` 让对端回全量 manifest（选择在本端执行，见 `selection`）。
    private var collection: SyncCollection { .all }

    // MARK: manifest → 对账 → 声明 → 推送

    /// 本端选择集下的 manifest 条目（曲库 + aligned 歌词，集合过滤后）。
    private func localEntries() -> [ManifestEntry] {
        let library = SyncManifestGenerator.generate(files: descriptor.sourceFiles())
        let all = library + descriptor.lyricsEntries()
        return selection.filter(collection.filter(all, members: members))
    }

    private func handleManifest(_ response: SyncManifestResponse) {
        let local = localEntries()
        let plan = SyncLibraryPushPlanner.plan(local: local, remote: response.entries)

        var queued: [PendingPush] = []
        var failures: [SyncPushFailure] = []
        for entry in plan.toPush {
            guard let built = makePushEntry(for: entry) else {
                failures.append(
                    SyncPushFailure(
                        relativePath: entry.relativePath,
                        reason: SyncPushFailureReason.localFileUnavailable,
                        detail: nil
                    )
                )
                continue
            }
            queued.append(PendingPush(entry: built.pushEntry, fileURL: built.url))
        }

        let announce = SyncLibraryPushAnnounce(entries: queued.map(\.entry))
        // 结构非法被声明丢弃的条目：如实记账（不静默）
        let announcedPaths = Set(announce.entries.map(\.relativePath))
        for pending in queued where !announcedPaths.contains(pending.entry.relativePath) {
            failures.append(
                SyncPushFailure(
                    relativePath: pending.entry.relativePath,
                    reason: SyncPushFailureReason.invalidPath,
                    detail: "声明结构校验未通过"
                )
            )
        }
        let kept = queued.filter { announcedPaths.contains($0.entry.relativePath) }

        lock.lock()
        summaryValue.planned = announce.entries.map(\.relativePath)
        summaryValue.skipped = plan.unchanged.map(\.relativePath)
        summaryValue.failed = failures
        lock.unlock()

        guard !kept.isEmpty else {
            // 无待推送条目（全部已一致 / 无可发送内容）：不发声明
            transition(to: .done(summaryValue))
            return
        }

        do {
            try session.sendApplicationFrame(
                type: .libraryPushAnnounce,
                payload: try SyncPushCodec.encode(announce)
            )
        } catch {
            transition(to: .failed("发送推送声明失败：\(error)"))
            return
        }

        lock.lock()
        queue = kept
        lock.unlock()
        transition(to: .pushing)
        pump()
    }

    /// 一个 manifest 条目 → 可发送的推送声明条目 + 本地文件 URL（不可读 → nil）。
    private func makePushEntry(for entry: ManifestEntry) -> PendingPushEntry? {
        guard let url = localURL(forWirePath: entry.relativePath),
              fileManager.fileExists(atPath: url.path)
        else { return nil }
        guard let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int64
        else { return nil }
        guard let sha256 = try? SyncFileChecksum.sha256Hex(ofFile: url) else { return nil }
        let fileID = transferFileID(for: entry, sha256: sha256)
        guard let pushEntry = SyncPushEntry.make(
            relativePath: entry.relativePath,
            fileID: fileID,
            sha256Hex: sha256,
            size: size
        ) else { return nil }
        return PendingPushEntry(pushEntry: pushEntry, url: url)
    }

    /// 传输身份：歌词 = 所属歌曲 content_hash；歌曲 = 条目 content_hash（缺失回落到文件 SHA-256）。
    private func transferFileID(for entry: ManifestEntry, sha256: String) -> String {
        if SyncLyricsNamespace.isLyricsPath(entry.relativePath),
           let songHash = SyncLyricsNamespace.songContentHash(fromWirePath: entry.relativePath) {
            return songHash
        }
        if let hash = entry.contentHash, !hash.isEmpty { return hash }
        return sha256
    }

    /// wire 相对路径 → 本端待发送文件 URL（歌词命名空间归歌词根；其余归曲库根）。
    private func localURL(forWirePath wirePath: String) -> URL? {
        guard let normalized = SyncManifestGenerator.normalizeRelativePath(wirePath) else { return nil }
        if SyncLyricsNamespace.isLyricsPath(normalized) {
            guard let lyricsRoot = descriptor.lyricsRoot,
                  let fileName = descriptor.lyricsFileName(normalized)
            else { return nil }
            return lyricsRoot.appendingPathComponent(fileName)
        }
        return descriptor.libraryRoot.appendingPathComponent(normalized)
    }

    // MARK: 串行推送（停等，一次一个）

    /// 驱动队列：给空闲的 sender 喂下一个文件。
    /// 内存回环下 `send` 会同步跑完整轮（onCompletion 在 send 内触发 → `pump`
    /// 重入被 `pumping` 挡住），真实网络下 `send` 返回时仍在传输 → 退出循环，
    /// 由 onCompletion 再次 `pump`。
    private func pump() {
        lock.lock()
        if pumping {
            lock.unlock()
            return
        }
        pumping = true
        lock.unlock()
        defer {
            lock.lock()
            pumping = false
            lock.unlock()
        }
        while true {
            lock.lock()
            let isPushing: Bool = {
                if case .pushing = stateValue { return true }
                return false
            }()
            let next = queue.isEmpty ? nil : queue.removeFirst()
            lock.unlock()

            guard isPushing else { return }
            guard let pending = next else {
                transition(to: .done(summaryValue))
                return
            }
            guard let sender else { return }
            lock.lock()
            lastDispatchedPath = pending.entry.relativePath
            lock.unlock()
            do {
                try sender.send(
                    fileURL: pending.fileURL,
                    fileID: pending.entry.fileID,
                    name: pending.entry.transferName
                )
            } catch {
                appendFailure(
                    SyncPushFailure(
                        relativePath: pending.entry.relativePath,
                        reason: SyncPushFailureReason.sendFailed,
                        detail: "\(error)"
                    )
                )
                continue
            }
            if sender.isActive {
                return // 异步进行中：等 onCompletion 再驱动
            }
        }
    }

    private func handleSendOutcome(_ outcome: SyncFileSender.Outcome) {
        let path = consumeLastDispatched()
        switch outcome {
        case .succeeded:
            if let path {
                lock.lock()
                summaryValue.completed.append(path)
                lock.unlock()
                onFilePushed?(path)
            }
        case let .failed(error):
            if let path {
                appendFailure(
                    SyncPushFailure(
                        relativePath: path,
                        reason: SyncPushFailureReason.sendFailed,
                        detail: "\(error)"
                    )
                )
            }
        }
        pump()
    }

    /// 最近派发（尚未收到终态）的相对路径——fileAck 只带 fileID，本端按派发序回收。
    private var lastDispatchedPath: String?

    private func consumeLastDispatched() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let path = lastDispatchedPath
        lastDispatchedPath = nil
        return path
    }

    private func appendFailure(_ failure: SyncPushFailure) {
        lock.lock()
        summaryValue.failed.append(failure)
        lock.unlock()
    }

    private func transition(to newState: SyncLibraryPushState) {
        lock.lock()
        let current = stateValue
        guard SyncLibraryPushStateMachine.canTransition(from: current, to: newState) else {
            lock.unlock()
            return
        }
        stateValue = newState
        let effective = effectiveStateLocked()
        lock.unlock()
        onStateChange?(effective)
    }
}

// MARK: - 内部传递结构

/// `makePushEntry` 的返回值（声明条目 + 本地文件 URL）。
private struct PendingPushEntry {
    let pushEntry: SyncPushEntry
    let url: URL
}
