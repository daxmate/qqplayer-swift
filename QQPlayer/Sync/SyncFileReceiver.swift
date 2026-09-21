//
//  SyncFileReceiver.swift
//  QQPlayer
//
//  局域网同步（S2, M2b）接收端：单文件流式 .part 落盘 + 断点续传 + SHA-256 校验。
//
//  语义（v1 定案，见任务包 3.2/3.3）：
//    file_meta（幂等/断点对齐/参数校验 → 初始 ack）：
//      - 目标 {name} 已完整存在且 size+sha 都匹配 → 直接 ack(done)（幂等，不重写）
//      - .part 完整字节对齐到块边界后 == startOffset → 续写（半块残留先 truncate）
//      - 其余状态：startOffset==0 → 删 .part 从头收；startOffset>0 → ack(resumeMismatch)
//      - 参数非法 → ack(protocolError)；totalSize==0 → 直接 done
//      - 传输进行中收到同 fileID 新 meta = 发送端重启（关旧 handle，.part 保留重对齐）
//    file_chunk：offset != 已收完整字节 → ack(protocolError) 中止；块数据追加 .part
//      （写失败按 ENOSPC 映射 diskFull/ioError）；收齐 → 整文件 SHA-256 →
//      匹配：原子改名去 .part + ack(done)；不匹配：删 .part + ack(checksumMismatch)
//    file_ack：接收端不收 ack → 静默忽略（有测试锁定）
//    cancel()/会话断连：清理内存状态；.part 保留磁盘（断点数据源，不删）
//
//  块大小**只按 meta 声明值**行事（`Active.chunkSize`；不读 `SyncFileTransfer.chunkSize`
//  常量）——发送端声明多大就按多大校验/对齐/截断，两端才可能各自演进块大小。
//
//  并发：@unchecked Sendable + NSLock。锁内只迁移状态 + 落盘；发 ack / 用户回调
//  一律在锁外执行（内存回环同步投递下对端 ack 会同步重入本对象，持锁发帧必死锁）。
//  会话回调槽位（onApplicationFrame/onClosed）为会话单槽：挂接时链式保留既有
//  handler（先己后彼）；本对象结束用 enabled 开关静默自己，不拆链（避免误伤后挂者）。
//
//  计时诊断（2026-09-18 提速）：本轮实际收完字节的传输记**一行** `SyncTransferMetrics`
//  （字节数 / 块数 / 声明块大小 / 耗时），经 `SyncConnectDiag.log` 落到本端既有诊断
//  通道（iOS：容器 `Documents/sync-diag.log`）。只走完 ack 的幂等/空文件不记（噪声）。
//

import Foundation

/// 文件接收端（一个 receiver 常驻一个会话，可顺序服务多轮传输）。
final class SyncFileReceiver: @unchecked Sendable {
    /// 一轮传输的本地结论（每轮恰一次，锁外触发）。
    enum Outcome: Equatable, Sendable {
        /// 文件已就绪（幂等 done / 收齐改名后）；带**传输级身份**供上层按身份认领落位
        case received(ReceivedFile)
        case failed(SyncFileTransferError)
    }

    /// 已就绪文件（URL + 传输级身份：`fileID` / 全文件 SHA-256）。
    /// 接收侧上层（推送被动端 / 拉取控制器）据此按身份认领目标路径——**不得只靠文件名**
    /// （同名不同目录会错位，见 2026-09-12 审计 🔴T1）。
    struct ReceivedFile: Equatable, Sendable {
        /// 传输唯一 ID（= `file_meta.fileID`）
        let fileID: String
        /// 全文件 SHA-256 小写 hex（已校验与磁盘一致）
        let sha256Hex: String
        /// 落盘文件 URL（落地目录内）
        let url: URL
    }

    private let session: SyncPeerSession
    /// 落盘目录（纯逻辑层不碰全局路径；测试注入临时目录）
    let directory: URL
    private let lock = NSLock()

    /// 传输结论回调（锁外触发）。
    var onCompletion: (@Sendable (Outcome) -> Void)?
    /// 每次发出 ack 的钩子（诊断/测试断言用）。
    var onAckSent: (@Sendable (FileAckPayload) -> Void)?

    /// 断点对齐实现注入（**测试用**：覆盖 truncate 失败路径；nil = 真实 FileHandle）。
    var partAlignmentHook: (@Sendable (_ partURL: URL, _ offset: Int64) throws -> Void)?

    // MARK: 会话槽位链式挂接

    private var priorAppHandler: (@Sendable (SyncFrame) -> Void)?
    private var priorClosedHandler: (@Sendable (SyncSessionCloseReason) -> Void)?
    private var forwardingEnabled = true

    // MARK: 当前传输（锁保护）

    struct Active {
        let fileID: String
        let name: String
        let totalSize: Int64
        /// 本轮**声明**的块大小（= file_meta.chunkSize；校验/对齐/截断都用它）
        let chunkSize: Int64
        let sha256Hex: String
        let finalURL: URL
        let partURL: URL
        /// 本轮起点（0 = 从头；> 0 = 断点续传；诊断用）
        let startOffset: Int64
        /// 本轮开始时刻（诊断计时基线）
        let startedAt: Date
        var handle: FileHandle?
        /// .part 当前完整字节数（= 下一块期望 offset）
        var received: Int64
        /// 本轮已写盘块数（诊断用）
        var chunksReceived: Int
    }

    /// 收尾时的进度快照（诊断用；`completePartLocked` 已脱离 Active，故显式携带）。
    struct Progress {
        let startedAt: Date
        let chunks: Int
        let chunkSize: Int64
        let startOffset: Int64
    }

    var active: Active?

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

    // MARK: init

    init(session: SyncPeerSession, directory: URL) {
        self.session = session
        self.directory = directory
        attachHandlers()
    }

    // MARK: 对外 API

    /// 中止当前传输（无传输则无操作）：清理内存状态，.part 保留（断点数据源）。
    func cancel() {
        runLocked {
            guard let current = self.active else { return [] }
            self.active = nil
            self.closeHandle(current)
            let error = SyncFileTransferError.cancelled(current.fileID)
            return [.log(self.metrics(current, succeeded: false, error: error)),
                    .finish(.failed(error))]
        }
    }

    /// 会话断开（链式 onClosed 转发进来）：与 cancel 同语义（.part 保留）。
    private func handleSessionClosed(_ reason: SyncSessionCloseReason) {
        runLocked {
            guard let current = self.active else { return [] }
            self.active = nil
            self.closeHandle(current)
            let error = SyncFileTransferError.sessionClosed(current.fileID)
            return [.log(self.metrics(current, succeeded: false, error: error)),
                    .finish(.failed(error))]
        }
    }

    // MARK: 帧入口（会话 onApplicationFrame 转发）

    func handleInboundFrame(_ frame: SyncFrame) {
        switch frame.type {
        case .fileMeta:
            guard let meta = try? SyncFilePayloadCodec.decode(FileMetaPayload.self, from: frame.payload) else {
                // meta 解码失败：与 file_chunk 策略对齐——能从原始 JSON 里取出 fileID 就回
                // protocolError 让发送端干净失败（取不到 → 靠发送端 ack 超时兜底，同样不悬挂）
                guard let fileID = Self.extractFileID(from: frame.payload), !fileID.isEmpty else { return }
                abortActive(fileID: fileID, reason: "file_meta 解码失败")
                return
            }
            runLocked { [meta] in self.processMetaLocked(meta) }
        case .fileChunk:
            guard let chunk = try? SyncFilePayloadCodec.decode(FileChunkPayload.self, from: frame.payload) else {
                // 传输进行中收到损坏块：回 protocolError 让对端干净失败（避免双方悬挂）
                runLocked {
                    guard let current = self.active else { return [] }
                    self.active = nil
                    self.closeHandle(current)
                    let error = SyncFileTransferError.protocolError(current.fileID, "块解码失败")
                    return [.sendAck(self.ack(fileID: current.fileID, receivedBytes: current.received,
                                              error: .protocolError)),
                            .log(self.metrics(current, succeeded: false, error: error)),
                            .finish(.failed(error))]
                }
                return
            }
            runLocked { [chunk] in self.processChunkLocked(chunk) }
        case .fileAck:
            // 接收端不收 ack：忽略（有测试锁定该行为）
            break
        default:
            break
        }
    }

    /// 解码失败的 meta：从原始 JSON 里尽量取出 fileID（不可信输入，只取字符串），
    /// 取到则回 protocolError 并中止同 fileID 的进行中传输（发送端据此干净失败）。
    private func abortActive(fileID: String, reason: String) {
        runLocked {
            guard let current = self.active, current.fileID == fileID else {
                // 没有同名进行中传输：只回 ack（发送端在等 meta 的 ack）
                return [.sendAck(self.ack(fileID: fileID, receivedBytes: 0, error: .protocolError))]
            }
            self.active = nil
            self.closeHandle(current)
            let error = SyncFileTransferError.protocolError(fileID, reason)
            return [.sendAck(self.ack(fileID: fileID, receivedBytes: current.received, error: .protocolError)),
                    .log(self.metrics(current, succeeded: false, error: error)),
                    .finish(.failed(error))]
        }
    }

    /// 从 meta 原始载荷里局部提取 `fileID`（字段类型损坏时严格解码会整体失败）。
    static func extractFileID(from payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let fileID = object["fileID"] as? String
        else { return nil }
        return fileID
    }
    func ack(fileID: String, receivedBytes: Int64, done: Bool = false,
             error: FileTransferErrorCode = .none) -> FileAckPayload {
        FileAckPayload(fileID: fileID, receivedBytes: receivedBytes, done: done, error: error)
    }

    // MARK: 计时诊断（锁内取快照）

    /// 进行中传输的计时快照（锁内调用；只读状态）。
    func metrics(_ current: Active, succeeded: Bool,
                 error: SyncFileTransferError?) -> SyncTransferMetrics {
        metricsLocked(fileID: current.fileID, totalSize: current.totalSize,
                      progress: Progress(startedAt: current.startedAt, chunks: current.chunksReceived,
                                         chunkSize: current.chunkSize, startOffset: current.startOffset),
                      succeeded: succeeded, error: error)
    }

    /// 由显式进度构造计时行（收尾路径 Active 已清，故走这条）。
    func metricsLocked(fileID: String, totalSize: Int64, progress: Progress,
                       succeeded: Bool, error: SyncFileTransferError?) -> SyncTransferMetrics {
        SyncTransferMetrics(
            role: .receive,
            fileID: fileID,
            startOffset: progress.startOffset,
            totalSize: totalSize,
            chunkSize: progress.chunkSize,
            chunks: progress.chunks,
            milliseconds: Int(Date().timeIntervalSince(progress.startedAt) * 1000),
            firstChunkWaitMs: nil,
            lastChunkWaitMs: nil,
            succeeded: succeeded,
            errorLine: error.map { "\($0)" }
        )
    }

    // MARK: 锁 + 效果执行

    enum Action {
        case sendAck(FileAckPayload)
        case log(SyncTransferMetrics)
        case finish(Outcome)
    }

    /// 锁内跑状态机，锁外执行效果（发 ack / 日志 / 用户回调）。所有路径的 ack 发送都在锁外，
    /// 保证同步回环下对端 ack 重入本对象不死锁。
    private func runLocked(_ body: () -> [Action]) {
        lock.lock()
        let actions = body()
        lock.unlock()
        for action in actions {
            switch action {
            case let .sendAck(ack):
                sendAck(ack)
            case let .log(metrics):
                SyncConnectDiag.log(metrics.logLine)
            case let .finish(outcome):
                onCompletion?(outcome)
            }
        }
    }

    private func sendAck(_ ack: FileAckPayload) {
        onAckSent?(ack)
        guard let data = try? SyncFilePayloadCodec.encode(ack) else { return }
        try? session.sendApplicationFrame(type: .fileAck, payload: data)
    }

    // MARK: 会话槽位挂接（链式：先己后彼；结束用开关静默，不拆链）

    private func attachHandlers() {
        priorAppHandler = session.onApplicationFrame
        priorClosedHandler = session.onClosed
        session.onApplicationFrame = { [weak self] frame in
            guard let self, self.forwardingEnabled else {
                self?.priorAppHandler?(frame)
                return
            }
            self.handleInboundFrame(frame)
            self.priorAppHandler?(frame)
        }
        session.onClosed = { [weak self] reason in
            guard let self, self.forwardingEnabled else {
                self?.priorClosedHandler?(reason)
                return
            }
            self.handleSessionClosed(reason)
            self.priorClosedHandler?(reason)
        }
    }
}
