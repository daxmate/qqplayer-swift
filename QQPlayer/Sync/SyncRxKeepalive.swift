//
//  SyncRxKeepalive.swift
//  QQPlayer
//
//  接收端「上行 keep-alive」：正在接收文件期间，每 ~30ms 给对端发一个既有 `.ping` 帧，
//  把手机的无线维持在唤醒态。
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
//    - 单帧开销：10B 帧头 + 28B（nonce 12 + tag 16）= **38B**；30ms 一帧 ≈ 1.27KB/s。
//    - 只在**本端是接收方**时发（本文件只被 SyncFileReceiver 使用）。
//    - pacer 跑在会话既有串行队列（`SyncPeerTransport.serialQueue`）；状态用独立 NSLock 保护，
//      **锁内不发送/不做 IO**（发 ping 在锁外）。
//    - 同一时刻最多一个定时器；发送失败只停 pacer，不影响传输。
//
//  生命周期（谁启动 / 谁停止，细节见 SyncFileReceiver）：
//    启动：file_meta 被接受、进入 `Active`（含探针）→ `.keepalive(.start)` 动作（锁外执行）
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

    /// 发 ping 间隔（秒）
    static let interval: TimeInterval = 0.03

    /// 连续多久没有 file_chunk 就停（秒）
    static let idleTimeout: TimeInterval = 0.5

    /// 全程硬上限（秒）：兜底防泄漏（会话残留 / 状态机漏停）
    static let maxLifetime: TimeInterval = 120

    /// 这一拍该发 ping 吗。
    ///
    /// 两个条件都满足才发：
    ///   ① 距上次 ping 已满一个间隔（限速，绝不 30ms 内连发两帧）；
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

    /// 单帧 ping 的线上字节数（诊断用：10B 帧头 + 28B 密文开销）
    static let pingFrameBytes = SyncFrame.headerLength + 28

    private let queueProvider: @Sendable () -> DispatchQueue?
    private let sendPing: @Sendable () throws -> Void
    private let interval: TimeInterval
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

    /// - Parameters:
    ///   - queueProvider: 会话既有串行队列（`transport.serialQueue`）。nil = 该通道没有串行
    ///     队列（内存回环 / 测试夹具）→ pacer 整体不启用，行为与改动前完全一致。
    ///   - sendPing: 发一帧 `.ping`（生产= `session.sendPing()`；测试可注入）。
    init(
        queueProvider: @escaping @Sendable () -> DispatchQueue?,
        sendPing: @escaping @Sendable () throws -> Void,
        interval: TimeInterval = SyncRxKeepalive.interval,
        idleTimeout: TimeInterval = SyncRxKeepalive.idleTimeout,
        maxLifetime: TimeInterval = SyncRxKeepalive.maxLifetime
    ) {
        self.queueProvider = queueProvider
        self.sendPing = sendPing
        self.interval = interval
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
    func start(fileID: String) {
        guard SyncRxKeepalive.isEnabled else { return }
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
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = source
        stateLock.unlock()
        source.resume()
        SyncConnectDiag.log("keepalive start fileID=\(fileID)")
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
        let shouldPing = SyncRxKeepalive.shouldPing(
            now: now, lastChunkAt: lastChunkAt, lastPingAt: lastPingAt, interval: interval
        )
        if shouldPing {
            lastPingAt = now
            pings += 1
        }
        stateLock.unlock()
        guard shouldPing else { return }
        // 锁外发送：发送失败只停 pacer（传输层有自己的失败路径，不许在这里扩散）。
        do {
            try sendPing()
        } catch {
            stop(reason: .sendFail)
        }
    }
}
