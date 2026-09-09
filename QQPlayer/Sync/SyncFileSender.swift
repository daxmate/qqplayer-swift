//
//  SyncFileSender.swift
//  QQPlayer
//
//  局域网同步（S2, M2b）发送端：单文件 停等协议（stop-and-wait）分块上传。
//
//  流程（v1 定案，见任务包 3.2）：
//    发送前整文件 SHA-256（流式读一遍）→ 发 file_meta(startOffset) → 等 file_ack：
//      ack.error != none → 失败回调（resumeMismatch 时调用方可 startOffset=0 重试一次）
//      ack.done        → 成功回调结束
//      否则从 alignDown(ack.receivedBytes) 起发下一块（每块发完等 ack 再发下一块）
//  发块用 FileHandle 分段读 256KB（不整文件进内存）；空文件只发 meta 即 done。
//  cancel()/会话断连 → 失败回调（接收端 .part 保留，之后可续传）。
//
//  回调契约：send() 只对“未开始的传输”（参数/文件/会话前置错误）抛错；一旦传输
//  开始，终态一律经 onCompletion 通知（每轮恰一次，锁外触发）。
//
//  并发：@unchecked Sendable + NSLock。帧回调内只迁移状态，发帧/回调在锁外执行
//  （内存回环同步投递下 ack 会同步重入本对象：持锁发帧必死锁）。
//  会话回调槽位链式挂接（先己后彼），结束用 enabled 开关静默自己，不拆链。
//  v1 限制：停等无 ack 超时——对端失联靠会话断连（onClosed）兜底，超时留 M4。
//

import Foundation

/// 文件发送端（一个 sender 可顺序服务多次 send()；并发 send 拒绝）。
final class SyncFileSender: @unchecked Sendable {
    /// 一轮传输的本端结论（每轮恰一次，锁外触发）。
    enum Outcome: Equatable, Sendable {
        case succeeded
        case failed(SyncFileTransferError)
    }

    private let session: SyncPeerSession
    private let lock = NSLock()

    /// 传输结论回调（锁外触发）。
    var onCompletion: ((Outcome) -> Void)?

    // MARK: 会话槽位链式挂接

    private var priorAppHandler: ((SyncFrame) -> Void)?
    private var priorClosedHandler: ((SyncSessionCloseReason) -> Void)?
    private var forwardingEnabled = true

    // MARK: 当前传输（锁保护）

    private struct Active {
        let fileID: String
        let fileURL: URL
        let totalSize: Int64
        let name: String
        var handle: FileHandle?
        /// 最近一次有效 ack 的 receivedBytes（推进检测基线）
        var lastAckBytes: Int64?
    }

    private var active: Active?

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

    init(session: SyncPeerSession) {
        self.session = session
        attachHandlers()
    }

    // MARK: 对外 API

    /// 发起一轮传输（同步完成本地准备并发 meta；后续由 ack 驱动，可能在本调用内
    /// 同步跑完——内存回环下是同步的，真实网络是异步的，两者都必须 work）。
    /// - Parameters:
    ///   - fileURL: 本地源文件
    ///   - fileID: 传输唯一 ID（调用方保证；断点续传时须与首轮一致）
    ///   - name: 接收端落盘名（默认取文件名）
    ///   - startOffset: 续传起点（上一轮 ack.receivedBytes；默认 0 = 从头）
    func send(fileURL: URL, fileID: String, name: String? = nil, startOffset: Int64 = 0) throws {
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

        // 发送前算全文件 SHA-256（本地流式读一遍；v1 接受）
        let sha256Hex: String
        do {
            sha256Hex = try SyncFileChecksum.sha256Hex(ofFile: fileURL)
        } catch {
            throw SyncFileTransferError.fileUnavailable("计算 SHA-256 失败：\(error)")
        }

        // 先置 active 再发 meta：内存回环下对端 ack 会同步重入 handleInboundFrame，
        // 若 meta 发出时还没有 active，同步到达的 ack 会被当 stray 丢弃
        let transfer = Active(fileID: fileID, fileURL: fileURL, totalSize: size,
                              name: resolvedName, handle: nil, lastAckBytes: nil)
        lock.lock()
        active = transfer
        lock.unlock()

        let meta = FileMetaPayload(fileID: fileID, name: resolvedName, totalSize: size,
                                   chunkSize: SyncFileTransfer.chunkSize,
                                   sha256Hex: sha256Hex, startOffset: startOffset)
        do {
            try session.sendApplicationFrame(type: .fileMeta,
                                             payload: SyncFilePayloadCodec.encode(meta))
        } catch {
            // 传输已开始（active 已置）→ 按终态通知，不抛。按 fileID 过滤防误杀
            // （极端并发下 ack 已完成并开启下一轮传输时，不得终止别人的传输）
            if let outcome = terminateActive(.sendFailed("发送 file_meta 失败：\(error)"), fileID: fileID) {
                onCompletion?(outcome)
            }
        }
        // 注：内存回环下整轮传输可能在 sendApplicationFrame 内同步跑完（active 已清）；
        // 异步网络下此处返回，等 ack 经 handleInboundFrame 推进。
    }

    /// 中止当前发送（无传输则无操作）：停止发送并失败回调。
    func cancel() {
        if let outcome = terminateActive(.cancelled(activeID() ?? "")) {
            onCompletion?(outcome)
        }
    }

    /// 会话断开（链式 onClosed 转发进来）：失败回调（.part 留在接收端，可续传）。
    private func handleSessionClosed(_ reason: SyncSessionCloseReason) {
        if let outcome = terminateActive(.sessionClosed(activeID() ?? "")) {
            onCompletion?(outcome)
        }
    }

    // MARK: 帧入口（会话 onApplicationFrame 转发）

    func handleInboundFrame(_ frame: SyncFrame) {
        guard frame.type == .fileAck else { return }
        guard let ack = try? SyncFilePayloadCodec.decode(FileAckPayload.self, from: frame.payload) else {
            // ack 解码失败：无法继续推进（停等悬挂），按协议违例终止
            if let outcome = terminateActive(.protocolError(activeID() ?? "", "file_ack 解码失败")) {
                onCompletion?(outcome)
            }
            return
        }
        runLocked { [ack] in self.processAckLocked(ack) }
    }

    // MARK: 锁内 ack 状态机

    /// ack 处理（锁内；返回待执行效果）。ack 驱动：发完一块即挂起，不假设同步到达。
    private func processAckLocked(_ ack: FileAckPayload) -> [Action] {
        guard let current = active else { return [] } // 空闲 stray ack 忽略
        guard ack.fileID == current.fileID else { return [] } // 别的传输的 ack 与本轮无关

        // ack.error → 失败（resumeMismatch 保留给调用方做 startOffset=0 重试决策）
        guard ack.error == .none else {
            return terminateLocked(localError(ack.error, fileID: current.fileID), current: current)
        }
        // done → 成功（receivedBytes 必须与声明一致）
        if ack.done {
            guard ack.receivedBytes == current.totalSize else {
                return terminateLocked(.protocolError(current.fileID, "done ack 字节数与 totalSize 不符"),
                                       current: current)
            }
            return terminateLocked(nil, current: current) // nil = 成功
        }
        // 进度边界防御
        guard ack.receivedBytes >= 0, ack.receivedBytes <= current.totalSize else {
            return terminateLocked(.protocolError(current.fileID, "ack 进度越界"), current: current)
        }
        // 推进检测：ack 必须单调前进（重复/回退 ack = 协议违例，避免死循环重发）
        if let last = current.lastAckBytes, ack.receivedBytes <= last {
            return terminateLocked(.protocolError(current.fileID, "ack 未前进（重复/回退）"), current: current)
        }
        // 续传起点 = ack 进度对齐到块边界（防御：理论已对齐）
        let offset = alignDown(ack.receivedBytes, to: SyncFileTransfer.chunkSize)
        guard offset < current.totalSize else {
            return terminateLocked(.protocolError(current.fileID, "ack 未 done 但字节已收齐"), current: current)
        }

        // 读下一块（FileHandle 分段读，不整文件进内存；handle 惰性打开复用）
        let data: Data
        do {
            if current.handle == nil {
                var opened = current
                opened.handle = try FileHandle(forReadingFrom: current.fileURL)
                active = opened
            }
            let handle = active?.handle // 刚打开或复用
            try handle?.seek(toOffset: UInt64(offset))
            data = try handle?.read(upToCount: Int(SyncFileTransfer.chunkSize)) ?? Data()
        } catch {
            return terminateLocked(.fileUnavailable("读源文件失败：\(error)"), current: current)
        }
        guard !data.isEmpty else {
            return terminateLocked(.fileUnavailable("源文件比声明短（传输未完已到文件尾）"), current: current)
        }

        // 记推进基线 → 发块（发帧在锁外执行）
        var updated = current
        updated.handle = active?.handle
        updated.lastAckBytes = ack.receivedBytes
        active = updated
        return [.sendChunk(FileChunkPayload(fileID: current.fileID, offset: offset, data: data))]
    }

    // MARK: 辅助

    /// 终止当前传输（锁内调用）：清状态 + 关文件；error = nil 表示成功。
    private func terminateLocked(_ error: SyncFileTransferError?, current: Active) -> [Action] {
        active = nil
        try? current.handle?.close()
        if let error {
            return [.finish(.failed(error))]
        }
        return [.finish(.succeeded)]
    }

    /// 终止当前传输并返回终态（无活动传输 / fileID 不匹配返回 nil）：调用方负责锁外通知。
    private func terminateActive(_ error: SyncFileTransferError, fileID: String? = nil) -> Outcome? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = active else { return nil }
        if let fileID, current.fileID != fileID { return nil }
        active = nil
        try? current.handle?.close()
        return .failed(error)
    }

    private func localError(_ code: FileTransferErrorCode, fileID: String) -> SyncFileTransferError {
        switch code {
        case .none: return .protocolError(fileID, "对端 ack 错误码缺失")
        case .ioError: return .ioError(fileID)
        case .diskFull: return .diskFull(fileID)
        case .checksumMismatch: return .checksumMismatch(fileID)
        case .resumeMismatch: return .resumeMismatch(fileID)
        case .cancelled: return .cancelled(fileID)
        case .protocolError: return .protocolError(fileID, "对端协议中止")
        }
    }

    private func alignDown(_ value: Int64, to chunkSize: Int64) -> Int64 {
        value - value % chunkSize
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    private func activeID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return active?.fileID
    }

    // MARK: 锁 + 效果执行

    private enum Action {
        case sendChunk(FileChunkPayload)
        case finish(Outcome)
    }

    /// 锁内跑状态机，锁外执行效果（发块 / 用户回调）。
    private func runLocked(_ body: () -> [Action]) {
        lock.lock()
        let actions = body()
        lock.unlock()
        for action in actions {
            switch action {
            case let .sendChunk(chunk):
                sendChunk(chunk)
            case let .finish(outcome):
                onCompletion?(outcome)
            }
        }
    }

    private func sendChunk(_ chunk: FileChunkPayload) {
        do {
            try session.sendApplicationFrame(type: .fileChunk, payload: SyncFilePayloadCodec.encode(chunk))
        } catch {
            // 发块失败（典型：会话刚关闭）→ 按终态通知（会话关闭路径已兜底则这里空跑）
            if let outcome = terminateActive(.sendFailed("发送 file_chunk 失败：\(error)")) {
                onCompletion?(outcome)
            }
        }
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
