//
//  SyncFileSender.swift
//  QQPlayer
//
//  局域网同步（S2, M2b）发送端：单文件分块上传。
//
//  流程（v1 定案 + 2026-11-06 滑动窗口）：
//    发送前整文件 SHA-256（流式读一遍）→ 发 file_meta(startOffset) → 等 file_ack：
//      ack.error != none → 失败回调（resumeMismatch 时调用方可 startOffset=0 重试一次）
//      ack.done        → 成功回调结束
//      否则按 ack.receivedBytes 推进窗口，补齐到窗口深度（`Active.window`）继续发块
//
//  窗口（2026-11-06；1MB 停等在 424–500ms RTT 链路上实测只有 2.12MB/s）：
//    深度由接收端在**应答 file_meta 那条 ack** 里声明，发送端取 min(声明, 硬上限)；
//    对端不声明 → 1（停等，行为不变）。发送严格有序、在途块连续；ack 不前进 = 重复/滞后
//    → 忽略（旧实现判违例）。发块恒为 FileHandle 分段读**本轮声明的块大小**，在途
//    ≤ 窗口 × 块大小，绝不整文件入内存；空文件只发 meta 即 done。
//  `precomputedSHA256` 可复用调用方算好的 SHA-256（省一次全文件读；对端仍校验内容）。
//  cancel()/会话断连 → 失败回调（接收端 .part 保留，之后可续传）。
//
//  回调契约：send() 只对“未开始的传输”（参数/文件/会话前置错误）抛错；一旦传输
//  开始，终态一律经 onCompletion 通知（每轮恰一次，锁外触发）。
//
//  并发：@unchecked Sendable + NSLock。帧回调内只迁移状态，发帧/回调在锁外执行
//  （内存回环同步投递下 ack 会同步重入本对象：持锁发帧必死锁）。
//  会话回调槽位链式挂接（先己后彼），结束用 enabled 开关静默自己，不拆链。
//  ack **无进展超时**（2026-09-12 审计 🟡T4）：ackTimeout 内 receivedBytes 一直不前进
//  （对端静默/卡死）→ 按 `protocolError` 终止、清状态（可重试），不留悬挂。
//
//  计时诊断（2026-09-18 提速）：一轮终态记**一行** `SyncTransferMetrics`（字节数 /
//  块数 / 声明块大小 / 耗时 / 首末块等 ack 往返），经 `SyncConnectDiag.log` 落到各端
//  既有诊断通道——用来判断下一轮是否值得上滑动窗口/并发，而不是笼统「慢」。
//

import Foundation

/// 文件发送端（一个 sender 可顺序服务多次 send()；并发 send 拒绝）。
final class SyncFileSender: @unchecked Sendable {
    /// 一轮传输的本端结论（每轮恰一次，锁外触发）。
    enum Outcome: Equatable, Sendable {
        case succeeded
        case failed(SyncFileTransferError)
    }

    let session: SyncPeerSession
    /// 状态锁（`SyncFileSender+Metrics` 里的 `activeID` 也要用 → 非 private）
    let lock = NSLock()
    /// 等待 file_ack 的超时（秒；0 = 禁用，测试用）
    private let ackTimeout: TimeInterval
    /// 超时调度入口（唯一入口；测试注入手动调度器 = 显式触发，不等真实定时器）
    private let deadlineScheduler: any SyncDeadlineScheduling

    /// 传输结论回调（锁外触发）。
    var onCompletion: (@Sendable (Outcome) -> Void)?

    // MARK: 会话槽位链式挂接

    private var priorAppHandler: (@Sendable (SyncFrame) -> Void)?
    private var priorClosedHandler: (@Sendable (SyncSessionCloseReason) -> Void)?
    private var forwardingEnabled = true

    /// 跨文件共享的全局在途字节预算（nil = 不限：单文件路径 / 既有测试不注入）。
    var budget: SyncTransferBudget?

    /// 窗口硬上限覆盖（**测试接缝**：强制把窗口压到 N；默认 nil = 按对端声明与 `maxInFlight` 取小）。
    /// 生产路径不用它——探针也走真实窗口（2026-11-13 起），否则测速会比实速低好几倍。
    var windowOverride: Int?

    /// 最近一轮终态时对端**最后确认的字节数**（断点续传起点；无 ack → 0）。
    private(set) var lastAckOffset: Int64 = 0

    /// 最近一轮**成功**传输的耗时（首块发出 → 终态 ack，单调时钟；失败 → nil）。
    private(set) var lastTransferSeconds: TimeInterval?
    /// 本文件第一条 ack（= 应答 file_meta 那条）到达时报告对端声明的并发文件数（nil = 旧端）。
    var onConcurrencyNegotiated: (@Sendable (Int?) -> Void)?
    /// 计时日志里的并发度 / 槽位（nil = 不打印，保持既有单文件日志形状）。
    var metricConcurrency: Int?
    var metricSlot: Int?
    private var negotiatedOnce = false

    // MARK: 当前传输（锁保护）

    /// 已发出但未确认的块（窗口占位；`end` = 该块末字节的绝对偏移）。
    typealias SentChunk = SyncSenderSentChunk

    /// 本轮状态（定义见 `SyncFileSender+Active.swift`；类型别名保持调用点不变）。
    typealias Active = SyncSenderActive

    var active: Active?
    private var ackDeadlineItem: (any SyncScheduledDeadline)? // 已排定的 ack 超时（nil = 没在等）
    /// 超时代号（锁保护）：每次重挂 +1，旧 deadline 到点按代号自证过期（cancel 是尽力而为）
    private var deadlineGeneration = 0
    /// 是否在窗口泵里（锁保护）：泵内 ack 只推进状态、由外层补齐 —— 否则同步回环会深递归爆栈
    private var pumping = false

    /// 当前进行中传输的 fileID（nil = 空闲；诊断用）。
    var activeFileID: String? {
        lock.lock()
        defer { lock.unlock() }
        return active?.fileID
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active != nil
    }

    /// 默认 ack 超时：LAN 上 1MB 块远快于此；超时说明对端不再推进（静默丢帧/卡死）。
    static let defaultAckTimeout: TimeInterval = 30

    /// init
    /// - Parameters:
    ///   - session: 对端会话
    ///   - ackTimeout: 等 file_ack 的超时（秒；0 = 禁用）
    ///   - deadlineScheduler: 超时调度入口（缺省 GCD；测试注入手动调度器——见
    ///     `SyncDeadlineScheduling` 文件头：超时判定不得依赖 runner 的线程调度）
    init(
        session: SyncPeerSession,
        ackTimeout: TimeInterval = SyncFileSender.defaultAckTimeout,
        deadlineScheduler: any SyncDeadlineScheduling = DispatchSyncDeadlineScheduler.shared
    ) {
        self.session = session
        self.ackTimeout = ackTimeout
        self.deadlineScheduler = deadlineScheduler
        attachHandlers()
    }

    // MARK: 对外 API

    /// 发起一轮传输（同步完成本地准备并发 meta；后续由 ack 驱动，可能在本调用内
    /// 同步跑完——内存回环下是同步的，真实网络是异步的，两者都必须 work）。
    /// - Parameters:
    ///   - fileID: 传输唯一 ID（调用方保证；断点续传时须与首轮一致）
    ///   - startOffset: 续传起点（上一轮 ack.receivedBytes；默认 0 = 从头）
    ///   - precomputedSHA256: 调用方已算好的全文件 SHA-256（须确实对应该文件当前内容）。
    func send(fileURL: URL, fileID: String, name: String? = nil, startOffset: Int64 = 0,
              precomputedSHA256: String? = nil) throws {
        // 前置校验（未开始传输的错误用 throw 报，不经 onCompletion）
        guard !fileID.isEmpty else {
            throw SyncFileTransferError.invalidArgument("fileID 为空")
        }
        guard startOffset >= 0 else {
            throw SyncFileTransferError.invalidArgument("startOffset 为负")
        }
        lock.lock()
        let busy = active != nil
        lock.unlock()
        guard !busy else {
            throw SyncFileTransferError.transferInProgress
        }
        guard session.isReady else {
            throw SyncFileTransferError.sessionNotReady
        }
        // 探针：握手阶段就判对端能力。旧端没有 probe 分支，收到 meta 就会在曲库目录建
        // `.part`（并留悬挂 active）⇒ 非 true 时**一个帧都不发**（连 meta 都不发）。
        // meta ack 里的 probeCapable 门控保留作防御性二次校验。
        if SyncProbe.isProbeFileID(fileID), !session.peerProbeCapable {
            throw SyncFileTransferError.probeUnsupported(fileID)
        }
        let resolvedName = name ?? fileURL.lastPathComponent
        guard !resolvedName.isEmpty, !resolvedName.contains("/"), !resolvedName.contains("\\") else {
            throw SyncFileTransferError.invalidArgument("name 非法：\(resolvedName)")
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SyncFileTransferError.fileUnavailable("文件不存在：\(fileURL.path)")
        }
        guard let size = fileSize(fileURL) else {
            throw SyncFileTransferError.fileUnavailable("读文件大小失败：\(fileURL.path)")
        }
        if startOffset > size {
            throw SyncFileTransferError.invalidArgument("startOffset \(startOffset) 超过文件大小 \(size)")
        }
        if size == 0, startOffset > 0 {
            throw SyncFileTransferError.invalidArgument("空文件无可续传")
        }

        // 发送前算全文件 SHA-256（本地流式读一遍；调用方已算好则复用）
        let sha256Hex: String
        if let precomputed = precomputedSHA256 {
            // 调用方给了值就必须是合法 SHA-256：非法即调用方 bug，明确报错（不静默改算）
            guard SyncFileChecksum.isValidSHA256Hex(precomputed) else {
                throw SyncFileTransferError.invalidArgument("precomputedSHA256 非法：\(precomputed)")
            }
            sha256Hex = precomputed.lowercased()
        } else {
            do {
                sha256Hex = try SyncFileChecksum.sha256Hex(ofFile: fileURL)
            } catch {
                throw SyncFileTransferError.fileUnavailable("计算 SHA-256 失败：\(error)")
            }
        }

        // 本轮声明值：写进 meta 的块大小与本地读块/对齐用的是**同一个值**
        let chunkSize = SyncFileTransfer.chunkSize

        // 先置 active 再发 meta：内存回环下对端 ack 会同步重入 handleInboundFrame，
        // 若 meta 发出时还没有 active，同步到达的 ack 会被当 stray 丢弃
        let transfer = Active(fileID: fileID, fileURL: fileURL, totalSize: size,
                              name: resolvedName, chunkSize: chunkSize, startOffset: startOffset,
                              startedAt: Date(), handle: nil, lastAckBytes: nil,
                              nextOffset: startOffset, inFlight: [],
                              window: 1, // 协商前按停等发（= 旧端行为）；meta ack 后再放大
                              inFlightMax: 0, wireBytes: 0, binaryChunks: false,
                              chunksSent: 0, firstChunkSentAt: nil, firstChunkSentUptime: nil,
                              lastChunkSentAt: nil,
                              firstChunkWait: nil, lastChunkWait: nil)
        lock.lock()
        active = transfer
        scheduleAckDeadlineLocked()
        lock.unlock()

        let meta = FileMetaPayload(fileID: fileID, name: resolvedName, totalSize: size,
                                   chunkSize: chunkSize,
                                   sha256Hex: sha256Hex, startOffset: startOffset)
        do {
            try session.sendApplicationFrame(type: .fileMeta,
                                             payload: SyncFilePayloadCodec.encode(meta))
        } catch {
            // 传输已开始（active 已置）→ 按终态通知，不抛。按 fileID 过滤防误杀
            // （极端并发下 ack 已完成并开启下一轮传输时，不得终止别人的传输）
            if let actions = terminateActive(.sendFailed("发送 file_meta 失败：\(error)"), fileID: fileID) {
                perform(actions)
            }
        }
        // 注：内存回环下整轮传输可能在 sendApplicationFrame 内同步跑完（active 已清）；
        // 异步网络下此处返回，等 ack 经 handleInboundFrame 推进。
        // 块**只在收到 meta ack 之后**才发（`handleInboundFrame → pump`）：那条 ack 同时
        // 是能力协商（窗口深度 / 二进制块）与续传对齐的确认点——先发块会在「对端其实要
        // 从头重传」时白传，也拿不到协商结果（首块只能退回 base64）。
    }

    /// 中止当前发送（无传输则无操作）：停止发送并失败回调。
    func cancel() {
        if let actions = terminateActive(.cancelled(activeID() ?? "")) {
            perform(actions)
        }
    }

    /// 会话断开（链式 onClosed 转发进来）：失败回调（.part 留在接收端，可续传）。
    private func handleSessionClosed(_ reason: SyncSessionCloseReason) {
        if let actions = terminateActive(.sessionClosed(activeID() ?? "")) {
            perform(actions)
        }
    }

    // MARK: 帧入口（会话 onApplicationFrame 转发）

    func handleInboundFrame(_ frame: SyncFrame) {
        guard frame.type == .fileAck else { return }
        guard let ack = try? SyncFilePayloadCodec.decode(FileAckPayload.self, from: frame.payload) else {
            // ack 解码失败：无法继续推进（停等悬挂），按协议违例终止
            if let actions = terminateActive(.protocolError(activeID() ?? "", "file_ack 解码失败")) {
                perform(actions)
            }
            return
        }
        // 并发度协商：本文件第一条 ack（= 应答 file_meta 那条）带对端声明的并发文件数
        let notice = takeNegotiationNotice(ack)
        runLocked { [ack] in self.processAckLocked(ack) }
        // ack 推进窗口后补齐（泵内到达时由外层循环接手，见 `pumping`）
        pump()
        if notice.notified { onConcurrencyNegotiated?(notice.declared) }
    }

    // MARK: 锁内 ack 状态机

    /// ack 处理（锁内）。窗口推进只迁状态，发块由 `pump()` 在锁外补齐。
    /// 只有 error / done 字节不符 / 进度越界 / 超过已发送字节才中止；
    /// 重复/滞后 ack 忽略（窗口下多条 ack 在途是常态，不是协议违例）。
    /// 锁内：本文件第一条 ack 是否需要做并发度协商通知（只有一次；非本文件的 ack 不算）。
    private func takeNegotiationNotice(_ ack: FileAckPayload) -> (notified: Bool, declared: Int?) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = active, current.fileID == ack.fileID, !negotiatedOnce else {
            return (false, nil)
        }
        negotiatedOnce = true
        return (true, ack.maxConcurrentFiles)
    }

    private func processAckLocked(_ ack: FileAckPayload) -> [Action] {
        guard var current = active else { return [] } // 空闲 stray ack 忽略
        guard ack.fileID == current.fileID else { return [] } // 别的传输的 ack 与本轮无关

        // ack.error → 失败（resumeMismatch 保留给调用方做 startOffset=0 重试决策）
        if let failure = probeGatingFailure(ack, fileID: current.fileID, chunksSent: current.chunksSent) {
            return terminateLocked(failure, current: current)
        }

        guard ack.error == .none else {
            // resumeMismatch 的 ack 带对端**真实**进度 → 记下来供调用方决定重试起点。
            if ack.error == .resumeMismatch { current.lastAckBytes = ack.receivedBytes }
            return terminateLocked(localError(ack.error, fileID: current.fileID), current: current)
        }
        // done → 成功（receivedBytes 必须与声明一致）
        if ack.done {
            guard ack.receivedBytes == current.totalSize else {
                return terminateLocked(.protocolError(current.fileID, "done ack 字节数与 totalSize 不符"),
                                       current: current)
            }
            // 末块往返：最后一块的发出时刻 → done 落地（诊断「尾部还差多少」）
            if let sentAt = current.lastChunkSentAt {
                current.lastChunkWait = Date().timeIntervalSince(sentAt)
            }
            return terminateLocked(nil, current: current) // nil = 成功
        }
        // 进度边界防御（上界 = 本轮总字节；且不得比已发出的还多）
        guard ack.receivedBytes >= 0, ack.receivedBytes <= current.totalSize else {
            return terminateLocked(.protocolError(current.fileID, "ack 进度越界"), current: current)
        }
        guard ack.receivedBytes <= current.nextOffset else {
            return terminateLocked(.protocolError(current.fileID, "ack 超过已发送字节"), current: current)
        }
        // 未前进的 ack（重复 / 滞后）→ 忽略（幂等；不能因此中止窗口内的传输）
        if let last = current.lastAckBytes, ack.receivedBytes <= last {
            return []
        }

        current.lastAckBytes = ack.receivedBytes
        // 推进窗口：摘掉已被对端确认的块（同时把预留的在途字节还给全局预算）
        if let budget {
            for chunk in current.inFlight where chunk.end <= ack.receivedBytes {
                budget.release(Int(chunk.length))
            }
        }
        current.inFlight.removeAll { $0.end <= ack.receivedBytes }
        // 能力协商（应答 file_meta 的那条 ack 才带；旧端不带 → 保持停等 / base64）
        if let advertised = ack.maxInFlight {
            current.window = min(max(advertised, 1), windowOverride ?? SyncFileTransfer.maxInFlight)
        }
        if let binary = ack.binaryChunks {
            current.binaryChunks = binary
        }
        // 首次推进 = 首块往返（发送 → 对端写盘确认）
        if current.firstChunkWait == nil, let sentAt = current.firstChunkSentAt {
            current.firstChunkWait = Date().timeIntervalSince(sentAt)
        }
        active = current
        // 有推进才重挂：无进展超时语义（单块慢无所谓，一直不动才失败）
        scheduleAckDeadlineLocked()
        return []
    }

    // MARK: 窗口泵（锁外驱动，按窗口补齐发块）

    /// 窗口补齐：只要窗口还有空位且没发完，就继续发下一块。
    ///
    /// 每块一次「持锁取快照 → 锁外发帧」，发帧期间到达的 ack 只推进状态；`pumping` 防重入
    /// （同步回环下 ack 会同步重入，递归补齐会上千层）。失败/终止动作在退出泵后执行
    /// （用户回调里可能立刻发起下一轮 send）。
    private func pump() {
        lock.lock()
        let alreadyPumping = pumping
        if !alreadyPumping { pumping = true }
        lock.unlock()
        guard !alreadyPumping else { return }

        var pending: [Action] = []
        loop: while true {
            lock.lock()
            let decision = nextSendLocked()
            lock.unlock()
            switch decision {
            case .stop:
                break loop
            case let .send(payload, flags):
                if let actions = sendChunk(payload, flags: flags) {
                    pending += actions
                    break loop
                }
            case let .fail(actions):
                pending += actions
                break loop
            }
        }

        lock.lock()
        pumping = false
        lock.unlock()
        perform(pending)
    }

    private enum SendDecision {
        case stop
        case send(payload: Data, flags: SyncFrameFlags)
        case fail([Action])
    }

    private func nextSendLocked() -> SendDecision {
        guard var current = active else { return .stop }
        guard current.inFlight.count < current.window else { return .stop }
        guard current.nextOffset < current.totalSize else { return .stop }

        let offset = current.nextOffset
        let length = min(current.chunkSize, current.totalSize - offset) // 尾块短读

        // 全局在途字节上限：触顶就不读块、不排队（ack 释放后由下一次 pump 补齐）；先判后扣 = 失败分支不漏预留
        if let budget, !budget.canFit(Int(length)) { return .stop }

        var handle = current.handle // FileHandle 分段读 + 惰性打开复用
        let data: Data
        do {
            if handle == nil {
                handle = try FileHandle(forReadingFrom: current.fileURL)
            }
            try handle?.seek(toOffset: UInt64(offset))
            data = try handle?.read(upToCount: Int(length)) ?? Data()
        } catch {
            if current.handle == nil { try? handle?.close() } // 刚打开失败 → 别泄漏
            return .fail(terminateLocked(.fileUnavailable("读源文件失败：\(error)"), current: current))
        }
        guard Int64(data.count) == length else {
            if current.handle == nil { try? handle?.close() }
            return .fail(terminateLocked(.fileUnavailable("源文件比声明短（传输未完已到文件尾）"),
                                         current: current))
        }

        // 编码（二进制 or base64 JSON）：线上字节在这里定，记账也在这里
        let chunk = FileChunkPayload(fileID: current.fileID, offset: offset, data: data)
        let payload: Data
        let flags: SyncFrameFlags
        if current.binaryChunks {
            guard let binary = SyncFileChunkCodec.encodeBinary(fileID: current.fileID, data: data) else {
                if current.handle == nil { try? handle?.close() }
                return .fail(terminateLocked(.protocolError(current.fileID, "fileID 过长，二进制块无法编码"),
                                             current: current))
            }
            payload = binary
            flags = [.binaryChunk]
        } else {
            do {
                payload = try SyncFilePayloadCodec.encode(chunk)
            } catch {
                if current.handle == nil { try? handle?.close() }
                return .fail(terminateLocked(.sendFailed("编码 file_chunk 失败：\(error)"), current: current))
            }
            flags = []
        }

        // 读/编码之后才扣（失败分支不产生预留 → 不会漏释放）
        if let budget, !budget.reserve(Int(length)) {
            if current.handle == nil { try? handle?.close() }
            return .stop
        }
        current.handle = handle
        current.inFlight.append(SentChunk(offset: offset, length: length))
        current.nextOffset = offset + length
        current.inFlightMax = max(current.inFlightMax, current.inFlight.count)
        current.chunksSent += 1
        current.wireBytes += payload.count
        let now = Date()
        current.noteChunkSent(at: now)
        active = current
        return .send(payload: payload, flags: flags)
    }

    // MARK: ack 超时

    /// 重挂 ack 超时（锁内调用；0 = 禁用）。
    ///
    /// 走注入的调度入口：超时**何时**被判由调度器决定（生产 = GCD；测试 = 手动触发）。
    private func scheduleAckDeadlineLocked() {
        cancelAckDeadlineLocked()
        guard ackTimeout > 0 else { return }
        deadlineGeneration += 1
        let generation = deadlineGeneration
        ackDeadlineItem = deadlineScheduler.schedule(after: ackTimeout) { [weak self] in
            self?.handleAckDeadline(generation: generation)
        }
    }

    private func cancelAckDeadlineLocked() {
        ackDeadlineItem?.cancel()
        ackDeadlineItem = nil
    }

    /// 超时：**无进展**超时（不是「某一块慢」）→ 按协议违例终止本轮并**清状态**
    /// （调用方可重试，不留悬挂）。
    /// - Parameter generation: 排定时的代号；与当前不符 = 已被推进重挂，直接忽略。
    private func handleAckDeadline(generation: Int) {
        lock.lock()
        let isCurrent = generation == deadlineGeneration
        let fileID = active?.fileID
        lock.unlock()
        guard isCurrent, let fileID else { return }
        if let actions = terminateActive(
            .protocolError(fileID, "等待 file_ack 无进展超时（\(ackTimeout)s）")
        ) {
            perform(actions)
        }
    }

    // MARK: 辅助

    /// 终止当前传输（锁内调用）：清状态 + 关文件；error = nil 表示成功。
    /// 终态一律附一行计时日志（成功/失败都记，便于定位卡在哪一块）。
    private func terminateLocked(_ error: SyncFileTransferError?, current: Active) -> [Action] {
        // 终止即归还本文件所有未确认块的全局预留（成功/失败/取消同一路径）
        if let budget {
            for chunk in current.inFlight { budget.release(Int(chunk.length)) }
        }
        active = nil
        cancelAckDeadlineLocked()
        try? current.handle?.close()
        // 断点续传载体 + 成功轮耗时（首块发出 → 终态 ack，单调时钟）
        lastAckOffset = current.lastAckBytes ?? 0
        if error == nil, let first = current.firstChunkSentUptime {
            lastTransferSeconds = max(0, ProcessInfo.processInfo.systemUptime - first)
        }
        let metrics = metricsLocked(current, succeeded: error == nil, error: error)
        guard let error else {
            return [.log(metrics), .finish(.succeeded)]
        }
        return [.log(metrics), .finish(.failed(error))]
    }

    /// 终止当前传输并返回待执行效果（无活动传输 / fileID 不匹配返回 nil）：调用方负责执行。
    private func terminateActive(_ error: SyncFileTransferError, fileID: String? = nil) -> [Action]? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = active else { return nil }
        if let fileID, current.fileID != fileID { return nil }
        if let budget {
            for chunk in current.inFlight { budget.release(Int(chunk.length)) }
        }
        active = nil
        cancelAckDeadlineLocked()
        try? current.handle?.close()
        return [.log(metricsLocked(current, succeeded: false, error: error)), .finish(.failed(error))]
    }

    // MARK: 锁 + 效果执行

    private enum Action {
        case log(SyncTransferMetrics)
        case finish(Outcome)
    }

    /// 锁内跑状态机，锁外执行效果（发块 / 日志 / 用户回调）。
    private func runLocked(_ body: () -> [Action]) {
        lock.lock()
        let actions = body()
        lock.unlock()
        perform(actions)
    }

    /// 执行效果（锁外；顺序 = 生产顺序：先记日志，再用户回调）。
    private func perform(_ actions: [Action]) {
        for action in actions {
            switch action {
            case let .log(metrics):
                SyncConnectDiag.log(metrics.logLine)
            case let .finish(outcome):
                onCompletion?(outcome)
            }
        }
    }

    /// 发一块（锁外）。返回非 nil = 已终止本轮的待执行效果（发帧失败）。
    private func sendChunk(_ payload: Data, flags: SyncFrameFlags) -> [Action]? {
        do {
            try session.sendApplicationFrame(type: .fileChunk, payload: payload, extraFlags: flags)
            return nil
        } catch {
            // 发块失败（典型：会话刚关闭）→ 按终态通知（会话关闭路径已兜底则这里空跑）
            return terminateActive(.sendFailed("发送 file_chunk 失败：\(error)"))
        }
    }

    // MARK: 会话槽位挂接（链式：先己后彼；结束用开关静默，不拆链）

    private func attachHandlers() {
        // ⚠️ `prior` 必须**强捕获**（局部常量），不得写成 `self?.priorAppHandler?`：
        // 本类被释放后弱 self == nil，旧写法既不转发也不报错 → 整条转发链静默断掉
        // （2026-11-12 真机：iPhone 端换装数据同步端后 manifest 帧全部消失）。
        // 只强捕获 prior，不强捕获 self（否则会话闭包 ↔ 本类成环）。
        let priorApp = session.onApplicationFrame
        let priorClosed = session.onClosed
        priorAppHandler = priorApp
        priorClosedHandler = priorClosed
        session.onApplicationFrame = { [weak self] frame in
            if let self {
                if self.forwardingEnabled {
                    self.handleInboundFrame(frame)
                }
            } else {
                AppLog.debug(.sync, "🧩 SyncFileSender 包装层已释放，仅转发 type=\(frame.type)")
            }
            priorApp?(frame)
        }
        session.onClosed = { [weak self] reason in
            if let self, self.forwardingEnabled {
                self.handleSessionClosed(reason)
            }
            priorClosed?(reason)
        }
    }
}
