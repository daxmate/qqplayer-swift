//
//  SyncProbe.swift
//  QQPlayer
//
//  T2 合成探针（测速）：用既有文件传输通道发一个 8 MiB 临时载荷，报告「用户实际会拿到的速度」。
//
//  口径（2026-11-13 用户拍板）：探针 = **真实传输的缩小复刻**——同样的块大小（1 MiB）、
//  同样的窗口协商（`min(对端声明 maxInFlight, SyncFileTransfer.maxInFlight)`，不降窗）、
//  同样的 ack 推进逻辑，只是文件更小（8 MiB = 8 × 1 MiB = 一个满窗）。所以它报出来的
//  MB/s 就是用户在相同网络下同步歌曲会拿到的速度；旧口径（4 MiB + 强制 window=2）只有
//  2 个 ack 往返，RTT 一抖就把结果压到实速的几分之一（实测 25 MB/s 的链路只报 4 MB/s）。
//
//  为什么复用文件通道而不是新帧：探针只要「首块发出 → 末块 ack」的时间，块/ack/窗口
//  逻辑已经存在；新增帧类型要动协议版本与两端解码，收益为零。
//
//  **热身 + 多次取最好（2026-11-13 用户拍板第二版）**
//
//  为什么热身：iPhone 在 Wi-Fi 上省电时会「睡着」——第一份载荷要去唤醒射频、触发速率
//  爬升（rate adaptation），单发一次测到的是**冷启动最差值**，不是用户持续同步时拿到的
//  速度。用户原话：「测试的时候你需要多长时间的热身就在热身之后再测嘛！」
//
//  实测依据（2026-11-13 10:12:41–10:13:12，同一链路连发 19 条 8 MiB 探针，MB/s）：
//    4.76 3.86 7.19 12.64 17.24 17.09 20.89 20.36 21.39
//    20.46 20.51 26.58 22.22 29.20 30.30 26.32 26.76 30.53 22.92 35.09
//  → 前 ~10 秒持续爬升，之后稳定在 20–35 MB/s（与真实传歌 25–42 MB/s 一致）。
//  所以热身 = 块间不留空闲地连发，直到 6 秒 **或** 6 个 8 MiB（≈48 MiB，覆盖爬升段）；
//  随后连测 2 次取**最快**的那次——峰值代表链路实际能力，均值会被一次抖动拖低。
//  （两个上限取先到者：慢链路靠 6 秒够、快链路靠 6 次够，都不至于把探针拖长。）
//
//  流程：热身（结果全部丢弃）→ 测量 N 次 → 取最快 → 报 MB/s。
//  预算：整轮硬上限 30 秒（热身 + 测量一起），单个 pass 仍用 20 秒超时。
//
//  纪律（见 docs/sync-slo.md / T2 任务包）：
//  - **能力门控**：只有对端 meta ack 声明 `probeCapable == true` 才发块（旧端收到探针
//    会被当普通文件落盘）。门控在 `SyncFileSender.processAckLocked` 里，唯一入口。
//  - **不占并发槽 / 不进曲库**：接收端把 `probe:` 开头的 fileID 写临时目录，收齐（或
//    中止）立即删除，不发 `.finish`（不进 peer state / 台账）。
//  - **失败不影响同步结论**：探针失败只让 `probeMBps` 保持 nil（日志写 -1）。
//
import Foundation

/// 探针常量与纯函数（可单测；不含 IO）。
enum SyncProbe {
    /// 载荷大小（8 MiB，按 1024² 字节）：8 × 1 MiB 块 = 一个满窗口（`maxInFlight` = 8），
    /// 能测到稳态吞吐，而不是只有一两次 ack 往返的瞬时采样。
    /// 超时余量：20s 硬超时对应 0.4 MB/s 下限（0.6 MB/s 的慢链路约 13s 收工）。
    static let payloadBytes: Int64 = 8 * 1024 * 1024
    /// 保留 fileID 前缀（接收端据此走探针分支）。
    static let fileIDPrefix = "probe:"
    /// 传输名（只用于日志/诊断；接收端探针分支不落曲库）。
    static let fileName = "__qqprobe__"
    /// 单个 pass（一份 8 MiB 载荷）的超时上限（秒）；整轮另有 `totalTimeout` 兜底。
    static let timeout: TimeInterval = 20
    /// 整轮探针（热身 + 测量）硬上限（秒）：探针不能拖住会话收尾。
    static let totalTimeout: TimeInterval = 30
    /// 热身停止判据之一：已耗时到这么长（秒）。
    static let warmupSeconds: TimeInterval = 6
    /// 热身停止判据之二：已发这么多个 pass（先到先停）。
    static let warmupMaxPasses = 6
    /// 测量阶段连发次数；取成功次里最快的一次作为结果。
    static let measurePasses = 2
    /// 自动探针最小间隔（秒）。
    static let autoInterval: TimeInterval = 10 * 60

    /// 是否探针 fileID（接收端 / 发送端共用的唯一判定）。
    static func isProbeFileID(_ fileID: String) -> Bool {
        fileID.hasPrefix(fileIDPrefix)
    }

    /// MB/s（1 MB = 1024² 字节）；非法输入 → nil（绝不写编造值）。
    static func megabytesPerSecond(bytes: Int64, seconds: TimeInterval) -> Double? {
        guard bytes > 0, seconds > 0, seconds.isFinite else { return nil }
        return Double(bytes) / seconds / 1_048_576
    }

    /// 距上次探针是否已过自动间隔（无历史 → true）。
    static func shouldAutoProbe(lastProbeAt: Date?, now: Date = Date()) -> Bool {
        guard let lastProbeAt else { return true }
        return now.timeIntervalSince(lastProbeAt) >= autoInterval
    }

    /// 热身是否该停：时间到 **或** 次数到（先到先停，两者都未到 → 继续热身）。
    /// 纯函数：判据只吃输入，便于单测；非法耗时（负数 / 非有限）不算「时间到」。
    static func shouldStopWarmup(elapsed: TimeInterval,
                                 passes: Int,
                                 seconds: TimeInterval = warmupSeconds,
                                 maxPasses: Int = warmupMaxPasses) -> Bool {
        if passes >= maxPasses { return true }
        guard elapsed.isFinite else { return false }
        return elapsed >= seconds
    }

    /// 多轮取最快：失败（nil）与非正 / 非有限值一律跳过；全失败 → nil（绝不编造值）。
    static func bestRate(_ rates: [Double?]) -> Double? {
        rates.compactMap { $0 }.filter { $0.isFinite && $0 > 0 }.max()
    }
}

/// 探针结果存储（进程内；probeMBps 随 `kind=frame` 诊断行落盘，不做持久化）。
final class SyncProbeStore: @unchecked Sendable {
    static let shared = SyncProbeStore()

    private let lock = NSLock()
    private var value: Double?
    private var stamp: Date?

    /// 最近一次探针结果（nil = 未测到：从没跑过 / 最近一次失败）。
    var lastMBps: Double? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// 最近一次探针时刻（成功失败都记；自动探针的 10 分钟节流用它）。
    var lastAttemptAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return stamp
    }

    func record(_ mbps: Double?) {
        lock.lock()
        stamp = Date()
        // 失败/超时/对端不支持 → 值清空（诊断行写 -1）；绝不沿用上一次的旧值冒充本次实测。
        value = mbps
        lock.unlock()
    }
}

/// 单次探针执行器：临时载荷文件 + 一个独立 `SyncFileSender`（不占同步控制器的并发槽）。
///
/// 线程模型：`start` 可从任意线程调；`completion` 在内部串行队列上回调一次。
final class SyncProbeRunner: @unchecked Sendable {
    private let session: SyncPeerSession
    private let payloadBytes: Int64
    private let passTimeout: TimeInterval
    private let totalTimeout: TimeInterval
    private let warmupSeconds: TimeInterval
    private let warmupMaxPasses: Int
    private let measurePasses: Int
    private let queue = DispatchQueue(label: "com.qqplayer.sync.probe")
    private let lock = NSLock()

    private var sender: SyncFileSender?
    private var payloadURL: URL?
    private var finished = false
    private var completion: ((Double?) -> Void)?

    // MARK: 相位状态（只在串行 queue 上读写：start 之后所有 pass 推进都在这条队列）

    private enum Phase { case warmup, measurement }

    private var phase: Phase = .warmup
    /// 已完成的 warmup pass 数（成功失败都算，只用于停止判据）。
    private var warmupPasses = 0
    private var warmupSuccesses = 0
    private var warmupStartedUptime: TimeInterval = 0
    /// 当前是否有 pass 在途（串行队列上的状态机位，防重复记账）。
    private var passInFlight = false
    /// 单 pass 超时令牌：只有最新令牌能取消当前 pass（老定时器静默作废）。
    private var passToken = 0
    /// 测量阶段各次结果（失败记 nil）。
    private var measured: [Double?] = []

    init(session: SyncPeerSession,
         payloadBytes: Int64 = SyncProbe.payloadBytes,
         passTimeout: TimeInterval = SyncProbe.timeout,
         totalTimeout: TimeInterval = SyncProbe.totalTimeout,
         warmupSeconds: TimeInterval = SyncProbe.warmupSeconds,
         warmupMaxPasses: Int = SyncProbe.warmupMaxPasses,
         measurePasses: Int = SyncProbe.measurePasses) {
        self.session = session
        self.payloadBytes = payloadBytes
        self.passTimeout = passTimeout
        self.totalTimeout = totalTimeout
        self.warmupSeconds = warmupSeconds
        self.warmupMaxPasses = warmupMaxPasses
        self.measurePasses = measurePasses
    }

    /// 跑一轮探针（热身 → 测量）；completion 收到 MB/s（失败/超时/不支持 → nil），只回调一次。
    func start(completion: @escaping (Double?) -> Void) {
        lock.lock()
        guard !finished, sender == nil else {
            lock.unlock()
            return
        }
        self.completion = completion
        lock.unlock()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-probe-\(UUID().uuidString).bin")
        do {
            // 载荷只写一次：热身与测量的每个 pass 复用同一个文件（不同 fileID）。
            try Self.writePayload(to: url, bytes: payloadBytes)
        } catch {
            finish(nil)
            return
        }

        let sender = SyncFileSender(session: session)
        // 不降窗（2026-11-13 用户拍板）：探针与真实传输走同一套窗口逻辑
        // （min(对端声明 maxInFlight, SyncFileTransfer.maxInFlight)），否则测出来的只是
        // 「2 个 ack 往返的链路极限」，比用户实速低好几倍。
        sender.onCompletion = { [weak self, weak sender] outcome in
            guard let self else { return }
            // 回调可能在 sender.send 内**同步**到达（内存回环）：投回串行队列，
            // 既避免叠栈递归，也保证 pass 推进只有一个执行者。
            let seconds = sender?.lastTransferSeconds
            self.queue.async { self.handlePassOutcome(outcome, seconds: seconds) }
        }

        lock.lock()
        self.sender = sender
        self.payloadURL = url
        lock.unlock()

        queue.async { [weak self] in self?.begin() }
    }

    // MARK: 内部

    private static func writePayload(to url: URL, bytes: Int64) throws {
        guard bytes > 0, bytes <= Int64(Int.max) else {
            throw SyncFileTransferError.invalidArgument("探针载荷大小非法")
        }
        let data = Data(count: Int(bytes))
        try data.write(to: url, options: .atomic)
    }

    /// 整轮硬上限：到点直接按失败收尾（含在途 pass）。
    private func armTotalTimeout() {
        queue.asyncAfter(deadline: .now() + totalTimeout) { [weak self] in
            guard let self, !self.isFinished else { return }
            self.finish(nil)
        }
    }

    /// 单 pass 超时：只作废令牌匹配的那一次；cancel 会回调 .failed → 本 pass 记失败。
    private func armPassTimeout(_ token: Int) {
        queue.asyncAfter(deadline: .now() + passTimeout) { [weak self] in
            guard let self, !self.isFinished, self.passInFlight, self.passToken == token else { return }
            self.sender?.cancel()
        }
    }

    private func finish(_ mbps: Double?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let completion = self.completion
        let sender = self.sender
        let url = payloadURL
        self.sender = nil
        payloadURL = nil
        lock.unlock()

        // 兜底路径（总超时 / 提前收尾）：在途 pass 一并停；它的回调会被 finished 拦掉。
        sender?.cancel()
        if let url { try? FileManager.default.removeItem(at: url) }
        SyncProbeStore.shared.record(mbps)
        if let mbps = mbps, !mbps.isFinite { completion?(nil) } else {
            completion?(mbps)
        }
    }

    // MARK: 相位推进（全部在 queue 上：串行执行 ⇒ 无需为状态机加锁）

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private func begin() {
        guard !isFinished else { return }
        warmupStartedUptime = ProcessInfo.processInfo.systemUptime
        armTotalTimeout()
        sendPass()
    }

    /// 发一个 8 MiB pass：热身与测量共用同一条路径（同一个 sender、同一个载荷文件）。
    /// pass 之间**不留空闲** —— 上一 pass 的终态回调里直接发下一 pass。
    private func sendPass() {
        guard !isFinished else { return }
        guard let sender, let url = payloadURL else {
            finish(nil)
            return
        }
        passToken &+= 1
        passInFlight = true
        armPassTimeout(passToken)
        do {
            try sender.send(fileURL: url,
                            fileID: SyncProbe.fileIDPrefix + UUID().uuidString,
                            name: SyncProbe.fileName)
        } catch {
            // 同步失败（会话不可用 / 参数非法）：本 pass 记失败，判据照常推进。
            passInFlight = false
            queue.async { [weak self] in
                guard let self else { return }
                self.record(nil)
                self.advance()
            }
        }
    }

    private func handlePassOutcome(_ outcome: SyncFileSender.Outcome, seconds: TimeInterval?) {
        guard !isFinished, passInFlight else { return }
        passInFlight = false
        switch outcome {
        case .succeeded:
            // 分母只用**这一次** pass 的耗时（首块发出 → 末块 ack）。
            record(SyncProbe.megabytesPerSecond(bytes: payloadBytes, seconds: seconds ?? -1))
        case .failed:
            record(nil)
        }
        advance()
    }

    /// 记一次 pass 结果：热身只记计数（速率全部丢弃），测量收进候选集。
    private func record(_ mbps: Double?) {
        switch phase {
        case .warmup:
            warmupPasses += 1
            if mbps != nil { warmupSuccesses += 1 }
        case .measurement:
            measured.append(mbps)
        }
    }

    /// 决定下一步：继续热身 / 转测量 / 再测一次 / 收尾。
    private func advance() {
        guard !isFinished else { return }
        switch phase {
        case .warmup:
            let elapsed = ProcessInfo.processInfo.systemUptime - warmupStartedUptime
            let stop = SyncProbe.shouldStopWarmup(elapsed: elapsed,
                                                  passes: warmupPasses,
                                                  seconds: warmupSeconds,
                                                  maxPasses: warmupMaxPasses)
            guard stop else {
                sendPass()
                return
            }
            // 热身一次都没成 = 链路根本没起来，测下去只会拿到必然失败的值。
            guard warmupSuccesses > 0 else {
                finish(nil)
                return
            }
            phase = .measurement
            measured = []
            sendPass()
        case .measurement:
            guard measured.count < measurePasses else {
                // 取最快：峰值代表链路实际能力（均值会被一次抖动拖低）；全失败 → nil。
                finish(SyncProbe.bestRate(measured))
                return
            }
            sendPass()
        }
    }

    /// 兜底（任何提前释放路径）：取消在途发送 + 删除临时载荷，绝不留下孤儿文件/回调。
    /// 正常路径 `finish` 已清空这两个字段，此处是幂等的空操作。
    deinit {
        lock.lock()
        let sender = self.sender
        let url = payloadURL
        self.sender = nil
        self.payloadURL = nil
        lock.unlock()
        sender?.cancel()
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

/// 探针调度（**单飞 + 强持有**）：自动探针与手动探针互斥，同一时刻最多一条。
///
/// 为什么必须由调度器持有 runner：`SyncProbeRunner` 内部对 self 全是 weak（onCompletion /
/// asyncAfter），`SyncFileSender` 的会话处理器也是 weak，session 不持有 sender ——
/// 裸局部变量 start 后立刻 dealloc ⇒ 探针永不完成、`probeMBps` 恒 -1、临时载荷残留、
/// 节流时间戳也不落（每次 ready 都重试）。故持有到 completion 为止。
final class SyncProbeScheduler: @unchecked Sendable {
    static let shared = SyncProbeScheduler()

    /// 测试接缝：默认真 runner（`payloadBytes` / 超时可注入）。
    var makeRunner: (SyncPeerSession) -> SyncProbeRunner = { SyncProbeRunner(session: $0) }

    private let lock = NSLock()
    private var activeRunner: SyncProbeRunner?

    /// 是否已有探针在跑（单飞判据）。
    var isProbing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeRunner != nil
    }

    /// 跑一次探针；已有探针在跑 → 直接返回 false（互斥，跳过本次）。
    /// - Parameter completion: MB/s（失败/超时/不支持 → nil），必然回调一次。
    @discardableResult
    func run(session: SyncPeerSession, completion: @escaping (Double?) -> Void) -> Bool {
        lock.lock()
        guard activeRunner == nil else {
            lock.unlock()
            return false
        }
        let runner = makeRunner(session)
        activeRunner = runner // 强持有到 completion（或 start 同步失败时的 release）
        lock.unlock()

        runner.start { [weak self, weak runner] value in
            if let runner { self?.release(runner) }
            completion(value)
        }
        return true
    }

    /// 会话 ready 后的自动探针（10 分钟节流 + 单飞；失败静默，不影响同步）。
    func maybeAutoProbe(session: SyncPeerSession) {
        guard session.isReady else { return }
        guard SyncProbe.shouldAutoProbe(lastProbeAt: SyncProbeStore.shared.lastAttemptAt) else { return }
        run(session: session) { _ in }
    }

    private func release(_ runner: SyncProbeRunner) {
        lock.lock()
        if activeRunner === runner { activeRunner = nil }
        lock.unlock()
    }
}
