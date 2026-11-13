//
//  SyncRxKeepalive.swift
//  QQPlayer
//
//  接收端「上行 keep-alive」：正在接收文件期间，每 10ms 给对端发一个既有 `.ping` 帧，
//  把手机的无线维持在唤醒态。冷启动时先突发送 12 帧（4ms 间隔 ≈ 48ms）把无线**强制拉醒**
//  （prewarm），再切到 10ms 稳态节拍。
//
//  为什么需要（2026-11-13 抓包 + 埋点实测）：
//    - Mac → iPhone 上传 7.22MB / 5349 段、0 重传，iPhone 通告窗口 831KB，但**最大在途只有
//      443KB**，吞吐 6MB/s ⇒ 反推 RTT ≈ 70ms，而 ping6 只有 8–40ms。
//    - 接收端每块处理 < 1ms、发送端 8 块 12ms 内交完 ⇒ 不是 App 慢。
//    - 反方向（iPhone → Mac）25–42MB/s：差别只在「发往手机时要等手机的省电唤醒窗口」。
//    - 连续测速从 4.8 涨到 35MB/s（持续流量把无线钉在唤醒态）= 旁证。
//  故：接收端只要在收文件期间持续有上行小帧，手机侧无线就不进省电窗口，ack 不再被压。
//
//  约束（任务包定案）：
//    - 复用既有 `.ping`（`SyncFrameKind.ping = 3`）：**不新增帧类型、不改协议版本**；
//      旧对端收到 ping 按既有语义忽略（`SyncPeerSession+Frames` 的 `case .ping: return []`），
//      两端行为都不会变。
//    - 单帧开销：10B 帧头 + 28B（nonce 12 + tag 16）= **38B**；10ms 一帧 ≈ 3.8KB/s，
//      外加每次启动 12 帧预热 ≈ 456B——相对 10MB/s 级的传输可忽略。
//    - 只在**本端是接收方**时发（本文件只被 SyncFileReceiver 使用）。
//    - pacer 跑在会话既有串行队列（`SyncPeerTransport.serialQueue`）；状态用独立 NSLock 保护，
//      **锁内不发送/不做 IO**（发 ping 在锁外）。
//    - 同一时刻最多一个定时器；发送失败只停 pacer，不影响传输。
//
//  生命周期（谁启动 / 谁停止，细节见 SyncFileReceiver）：
//    启动：① **提前启动**：推送声明帧 `libraryPushAnnounce`（帧类型 14，`SyncFrame.swift:69`）
//          到达 → pacer 起来跑预热。依据：发送端 `SyncLibraryPushController.swift:404-418`
//          先发声明、紧接着 `pump()` 派发文件（`SyncFileSender` 才发 file_meta），故「收到声明」
//          是本端能判定「即将有文件要传」的**最早**信号（比 file_meta 早一次文件 SHA-256 + 一程
//          网络；更早的 `manifestRequest`(`SyncFrame.swift:63`) 推送/拉取两轮都会发，判不出来，故不用）。
//          ② 兜底：file_meta 被接受、进入 `Active`（含探针）→ `.keepalive(.start)` 动作（锁外执行）。
//          两路都只在「有传输在途」时触发：仅连着没传输的空闲会话永远收不到这两种帧 → pacer 不启动；
//          信号到了但 500ms 内没有 chunk（对端放弃 / 全部已一致）→ 自停（idle）。
//    刷新：每个 file_chunk 帧到达（`handleInboundFrame`，无锁路径）→ `.touch`
//    停止：① 连续 500ms 无 chunk（idle）② 一轮传输收尾且无其他在途文件（done）
//          ③ 硬上限 120s（timeout）④ 发 ping 抛错（sendFail）
//
// target: shared（两端都编；接收端两端都有 —— iOS 被动收、Mac 拉取收）
//

import Foundation

/// 接收端 keep-alive 的纯逻辑判据 + 常量（可脱离定时器单测）。
enum SyncRxKeepalive {
    /// 总开关（默认启用；A/B 用。**刻意不做成用户设置项**：这是链路行为，不是偏好）。
    static let isEnabled = true

    /// 稳态发 ping 间隔（秒）。
    ///
    /// 2026-11-13 真机：30ms 时「空闲 3.5 分钟后开传」首块 ackWaitFirst 仍有 212–287ms，
    /// 换成 10ms 让心跳密度盖过无线省电窗口（38B/10ms ≈ 3.8KB/s，可忽略）。
    static let interval: TimeInterval = 0.010

    /// 启动预热帧数：pacer 冷启动先连发这么多个 ping（≈ 12 × 4ms = 48ms），把无线
    /// 从省电态**强制拉醒**；之后再按 `interval` 走稳态节拍。
    static let prewarmCount = 12

    /// 预热帧间隔（秒）：4ms ≈ 无线唤醒所需的最短连续发送节奏。
    static let prewarmInterval: TimeInterval = 0.004

    /// 连续多久没有 file_chunk 就停（秒）
    static let idleTimeout: TimeInterval = 0.5

    /// 全程硬上限（秒）：兜底防泄漏（会话残留 / 状态机漏停）
    static let maxLifetime: TimeInterval = 120

    /// 这一拍该发 ping 吗。
    ///
    /// 两个条件都满足才发：
    ///   ① 距上次 ping 已满一个间隔（限速，绝不在稳态节拍内连发两帧）；
    ///   ② 距最近一个 file_chunk 也已满一个间隔——**数据本身就在持续唤醒无线**时不再补 ping
    ///   （满速流下 ping 是纯开销；而且 ping 与数据帧同队列，密集时只会添乱）。
    static func shouldPing(
        now: TimeInterval,
        lastChunkAt: TimeInterval,
        lastPingAt: TimeInterval,
        interval: TimeInterval = SyncRxKeepalive.interval
    ) -> Bool {
        guard interval > 0 else { return false }
        return now - lastPingAt >= interval && now - lastChunkAt >= interval
    }

    /// 一拍的计划（纯逻辑：定时器只负责照做，节奏判据全部可单测）。
    struct TickPlan: Equatable {
        /// 这一拍发不发 ping
        let sendPing: Bool
        /// 下一拍用多长的间隔（预热期 = `prewarmInterval`；稳态 = `interval`）
        let nextInterval: TimeInterval
        /// 本拍执行完之后还剩几帧预热
        let prewarmRemaining: Int
    }

    /// 算出这一拍该做什么（**预热优先**）。
    ///
    /// 预热期（`prewarmRemaining > 0`）**不看 chunk 时刻**：预热发生在「文件还没开始来」的
    /// 窗口里，目的就是把无线拉醒，被 `shouldPing` 的第二条件压掉就白预热了。
    static func plan(
        now: TimeInterval,
        lastChunkAt: TimeInterval,
        lastPingAt: TimeInterval,
        prewarmRemaining: Int,
        interval: TimeInterval = SyncRxKeepalive.interval,
        prewarmInterval: TimeInterval = SyncRxKeepalive.prewarmInterval
    ) -> TickPlan {
        if prewarmRemaining > 0 {
            let remaining = prewarmRemaining - 1
            // 坏参数（<= 0）不许变成忙等：退回稳态节拍
            let next = remaining > 0 ? (prewarmInterval > 0 ? prewarmInterval : interval) : interval
            return TickPlan(sendPing: true, nextInterval: next, prewarmRemaining: remaining)
        }
        let send = shouldPing(now: now, lastChunkAt: lastChunkAt, lastPingAt: lastPingAt, interval: interval)
        return TickPlan(sendPing: send, nextInterval: interval, prewarmRemaining: 0)
    }

    /// 入站帧 → 提前启动 pacer 的来源（nil = 这条帧不算「即将有文件要传」）。
    ///
    /// 唯一信号 = 推送声明（帧 14 `libraryPushAnnounce`）：发送端发完它必然派发文件
    /// （`SyncLibraryPushController.swift:404-418`：声明 → `pump()` → `SyncFileSender.send` 发 file_meta）。
    /// **不用更早的 manifest 帧**：`manifestRequest`/`manifestResponse` 推送轮与拉取轮都会出现
    /// （推送轮 `SyncLibraryPushController.swift:307`、拉取轮 `SyncLibraryPullController.swift:282`），
    /// 判不出「本方要收文件」→ 拿它当信号等于给「只是连着」的空闲会话发 ping（耗电）。
    static func startReason(for type: SyncFrameType) -> SyncRxKeepalivePacer.StartReason? {
        type == .libraryPushAnnounce ? .pushAnnounce : nil
    }

    /// 该停了吗（空闲超时 / 硬上限共用同一判据）。
    static func shouldStop(
        idleFor: TimeInterval,
        idleTimeout: TimeInterval = SyncRxKeepalive.idleTimeout
    ) -> Bool {
        guard idleTimeout > 0 else { return false }
        return idleFor >= idleTimeout
    }
}

/// 接收端 keep-alive 定时器（单实例 = 单定时器，跟随会话生命周期）。
///
/// 为什么自带 NSLock 而不用接收端那把锁：pacer 的 stop/touch 可能来自会话队列之外的线程
/// （UI 取消 / 会话关闭），而 tick 在队列上跑；两者只共享本对象的几个标量。
/// 锁内只读写标量，**发送一律在锁外**。
final class SyncRxKeepalivePacer: @unchecked Sendable {
    /// 停止原因（日志 `reason=` 取值）
    enum StopReason: String {
        /// 连续 idleTimeout 没有 chunk
        case idle
        /// 一轮传输收尾且无其他在途文件（含中止 / 会话关闭）
        case done
        /// 硬上限兜底
        case timeout
        /// 发 ping 抛错（会话已关 / 未 ready）——只停 pacer，不影响传输
        case sendFail
    }

    /// 启动来源（日志 `reason=` 取值）：早启动靠推送声明，兜底靠 file_meta。
    enum StartReason: String {
        /// 推送声明帧（帧 14）到达 → 提前预热
        case pushAnnounce = "push_announce"
        /// file_meta 被接受（兜底 / 拉取路径唯一信号）
        case fileMeta = "file_meta"
    }

    /// 单帧 ping 的线上字节数（诊断用：10B 帧头 + 28B 密文开销）
    static let pingFrameBytes = SyncFrame.headerLength + 28

    private let queueProvider: @Sendable () -> DispatchQueue?
    private let sendPing: @Sendable () throws -> Void
    private let enabled: Bool
    private let interval: TimeInterval
    private let prewarmCount: Int
    private let prewarmInterval: TimeInterval
    private let idleTimeout: TimeInterval
    private let maxLifetime: TimeInterval

    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var running = false
    private var fileID = ""
    private var startedAt: TimeInterval = 0
    private var lastChunkAt: TimeInterval = 0
    private var lastPingAt: TimeInterval = 0
    private var pings = 0
    /// 还没发完的预热帧数（0 = 已进稳态节拍）
    private var prewarmRemaining = 0
    /// 预热开始时刻（诊断：`keepalive prewarm` 的 ms=）
    private var prewarmStartedAt: TimeInterval = 0
    /// 定时器当前挂的重复间隔（只在节拍变化时重挂，避免每拍都 schedule）
    private var scheduledInterval: TimeInterval = 0

    /// - Parameters:
    ///   - queueProvider: 会话既有串行队列（`transport.serialQueue`）。nil = 该通道没有串行
    ///     队列（内存回环 / 测试夹具）→ pacer 整体不启用，行为与改动前完全一致。
    ///   - sendPing: 发一帧 `.ping`（生产= `session.sendPing()`；测试可注入）。
    ///   - enabled: 总开关（A/B 用，默认取 `SyncRxKeepalive.isEnabled`；测试可注入 false）。
    ///   - prewarmCount / prewarmInterval: 启动预热帧数 / 间隔（测试可注入 0 = 关闭预热）。
    init(
        queueProvider: @escaping @Sendable () -> DispatchQueue?,
        sendPing: @escaping @Sendable () throws -> Void,
        enabled: Bool = SyncRxKeepalive.isEnabled,
        interval: TimeInterval = SyncRxKeepalive.interval,
        prewarmCount: Int = SyncRxKeepalive.prewarmCount,
        prewarmInterval: TimeInterval = SyncRxKeepalive.prewarmInterval,
        idleTimeout: TimeInterval = SyncRxKeepalive.idleTimeout,
        maxLifetime: TimeInterval = SyncRxKeepalive.maxLifetime
    ) {
        self.queueProvider = queueProvider
        self.sendPing = sendPing
        self.enabled = enabled
        self.interval = interval
        self.prewarmCount = max(0, prewarmCount)
        self.prewarmInterval = prewarmInterval
        self.idleTimeout = idleTimeout
        self.maxLifetime = maxLifetime
    }

    deinit {
        // 定时器持有 self（eventHandler 弱引用，但 source 本身持有 handler 上下文），
        // 不 cancel 就是泄漏。deinit 时仍在跑 → 直接收掉（不记日志：那是会话层的事）。
        timer?.cancel()
        timer = nil
    }

    /// 当前是否在跑（诊断 / 测试用）。
    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    /// 已发 ping 数（诊断 / 测试用）。
    var pingCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pings
    }

    /// 开始 / 续跑（幂等）：并发收多文件时沿用同一个 pacer，只刷新最近 chunk 时刻。
    /// - Parameters:
    ///   - fileID: 触发启动的 fileID（推送声明那一路还不知道 fileID → 空串）
    ///   - reason: 启动来源（日志用，见 `StartReason`）
    func start(fileID: String, reason: StartReason = .fileMeta) {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        if running {
            lastChunkAt = now
            stateLock.unlock()
            return
        }
        // 队列在 start 时解析（receiver 可能先于 transport 建好）：拿不到就不启用。
        guard let queue = queueProvider() else {
            stateLock.unlock()
            return
        }
        running = true
        self.fileID = fileID
        startedAt = now
        lastChunkAt = now
        lastPingAt = 0
        pings = 0
        // 预热：先按 prewarmInterval 连发 prewarmCount 帧，发完在 tick 里切回 interval
        prewarmRemaining = prewarmCount
        // 没预热（count=0）时不留时间戳，免得稳态第一帧被误记成 prewarm 收尾
        prewarmStartedAt = prewarmRemaining > 0 ? now : 0
        let firstInterval: TimeInterval = prewarmRemaining > 0
            ? Self.sanitized(prewarmInterval, fallback: interval)
            : interval
        scheduledInterval = firstInterval
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + firstInterval, repeating: firstInterval)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = source
        stateLock.unlock()
        source.resume()
        SyncConnectDiag.log("keepalive start reason=\(reason.rawValue) fileID=\(fileID)")
    }

    /// 非法间隔（<= 0）不许变成忙等：退回 1ms，再坏就退回稳态节拍。
    private static func sanitized(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        if value > 0 { return value }
        return fallback > 0 ? fallback : 0.001
    }

    /// 收到一个 file_chunk（任意文件）→ 刷新空闲计时。未运行 = 无操作。
    func touch() {
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        if running { lastChunkAt = now }
        stateLock.unlock()
    }

    /// 停止（幂等）：cancel 定时器并落一行 `keepalive stop`。
    func stop(reason: StopReason) {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        running = false
        timer?.cancel()
        timer = nil
        let count = pings
        pings = 0
        prewarmRemaining = 0
        scheduledInterval = 0
        fileID = ""
        stateLock.unlock()
        SyncConnectDiag.log("keepalive stop reason=\(reason.rawValue) pings=\(count)")
    }

    // MARK: 定时器一拍

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        if now - startedAt >= maxLifetime {
            stateLock.unlock()
            stop(reason: .timeout)
            return
        }
        if SyncRxKeepalive.shouldStop(idleFor: now - lastChunkAt, idleTimeout: idleTimeout) {
            stateLock.unlock()
            stop(reason: .idle)
            return
        }
        let plan = SyncRxKeepalive.plan(
            now: now,
            lastChunkAt: lastChunkAt,
            lastPingAt: lastPingAt,
            prewarmRemaining: prewarmRemaining,
            interval: interval,
            prewarmInterval: prewarmInterval
        )
        prewarmRemaining = plan.prewarmRemaining
        // 节拍只在变化时重挂（预热 4ms ↔ 稳态 10ms）：同一个定时器，不新建第二个。
        if plan.nextInterval != scheduledInterval {
            timer?.schedule(deadline: .now() + plan.nextInterval, repeating: plan.nextInterval)
            scheduledInterval = plan.nextInterval
        }
        // 预热最后一帧：记下「共几帧 / 花了多久」，落盘在锁外（且只在这一帧真发出去之后）
        var prewarmElapsedMs: Int?
        var sentPings = 0
        if plan.sendPing {
            lastPingAt = now
            pings += 1
            sentPings = pings
            if plan.prewarmRemaining == 0, prewarmStartedAt > 0 {
                prewarmElapsedMs = Int(((now - prewarmStartedAt) * 1000).rounded())
                prewarmStartedAt = 0
            }
        }
        stateLock.unlock()
        guard plan.sendPing else { return }
        // 锁外发送：发送失败只停 pacer（传输层有自己的失败路径，不许在这里扩散）。
        do {
            try sendPing()
        } catch {
            stop(reason: .sendFail)
            return
        }
        if let prewarmElapsedMs {
            SyncConnectDiag.log("keepalive prewarm pings=\(sentPings) ms=\(prewarmElapsedMs)")
        }
    }
}
