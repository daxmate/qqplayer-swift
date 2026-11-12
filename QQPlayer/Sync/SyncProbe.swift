//
//  SyncProbe.swift
//  QQPlayer
//
//  T2 合成探针（测速）：用既有文件传输通道发一个 4 MiB 临时载荷，测「链路极限」。
//
//  为什么复用文件通道而不是新帧：探针只要「首块发出 → 末块 ack」的时间，块/ack/窗口
//  逻辑已经存在；新增帧类型要动协议版本与两端解码，收益为零。
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
    /// 载荷大小（4 MiB，按 1024² 字节）。
    static let payloadBytes: Int64 = 4 * 1024 * 1024
    /// 保留 fileID 前缀（接收端据此走探针分支）。
    static let fileIDPrefix = "probe:"
    /// 传输名（只用于日志/诊断；接收端探针分支不落曲库）。
    static let fileName = "__qqprobe__"
    /// 探针窗口（不放大到 maxInFlight：测的是链路极限，不是吞吐调参）。
    static let window = 2
    /// 硬超时上限（秒）：探针不能拖住会话收尾。
    static let timeout: TimeInterval = 20
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
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.qqplayer.sync.probe")
    private let lock = NSLock()

    private var sender: SyncFileSender?
    private var payloadURL: URL?
    private var finished = false
    private var completion: ((Double?) -> Void)?

    init(session: SyncPeerSession,
         payloadBytes: Int64 = SyncProbe.payloadBytes,
         timeout: TimeInterval = SyncProbe.timeout) {
        self.session = session
        self.payloadBytes = payloadBytes
        self.timeout = timeout
    }

    /// 跑一次探针；`completion` 收到 MB/s（失败/超时/不支持 → nil），只回调一次。
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
            try Self.writePayload(to: url, bytes: payloadBytes)
        } catch {
            finish(nil)
            return
        }

        let sender = SyncFileSender(session: session)
        sender.windowOverride = SyncProbe.window
        sender.onCompletion = { [weak self, weak sender] outcome in
            guard let self else { return }
            switch outcome {
            case .succeeded:
                self.finish(SyncProbe.megabytesPerSecond(bytes: self.payloadBytes,
                                                         seconds: sender?.lastTransferSeconds ?? -1))
            case .failed:
                self.finish(nil)
            }
        }

        lock.lock()
        self.sender = sender
        self.payloadURL = url
        lock.unlock()

        scheduleTimeout()
        do {
            try sender.send(fileURL: url,
                            fileID: SyncProbe.fileIDPrefix + UUID().uuidString,
                            name: SyncProbe.fileName)
        } catch {
            finish(nil)
        }
    }

    // MARK: 内部

    private static func writePayload(to url: URL, bytes: Int64) throws {
        guard bytes > 0, bytes <= Int64(Int.max) else {
            throw SyncFileTransferError.invalidArgument("探针载荷大小非法")
        }
        let data = Data(count: Int(bytes))
        try data.write(to: url, options: .atomic)
    }

    private func scheduleTimeout() {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let sender = self.sender
            self.lock.unlock()
            sender?.cancel()
            self.finish(nil)
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
        let url = payloadURL
        sender = nil
        payloadURL = nil
        lock.unlock()

        if let url { try? FileManager.default.removeItem(at: url) }
        SyncProbeStore.shared.record(mbps)
        if let mbps = mbps, !mbps.isFinite { completion?(nil) } else {
            completion?(mbps)
        }
    }
}

/// 会话 ready 后的自动探针入口（10 分钟节流；失败静默，不影响同步）。
enum SyncProbeScheduler {
    /// 若距上次探针超过 10 分钟 → 后台跑一次并写 `SyncProbeStore`。
    static func maybeAutoProbe(session: SyncPeerSession) {
        guard session.isReady else { return }
        guard SyncProbe.shouldAutoProbe(lastProbeAt: SyncProbeStore.shared.lastAttemptAt) else { return }
        let runner = SyncProbeRunner(session: session)
        runner.start { _ in }
    }
}
