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
//  并发：@unchecked Sendable + NSLock。锁内只迁移状态 + 落盘；发 ack / 用户回调
//  一律在锁外执行（内存回环同步投递下对端 ack 会同步重入本对象，持锁发帧必死锁）。
//  会话回调槽位（onApplicationFrame/onClosed）为会话单槽：挂接时链式保留既有
//  handler（先己后彼）；本对象结束用 enabled 开关静默自己，不拆链（避免误伤后挂者）。
//

import Foundation

/// 文件接收端（一个 receiver 常驻一个会话，可顺序服务多轮传输）。
final class SyncFileReceiver: @unchecked Sendable {
    /// 一轮传输的本地结论（每轮恰一次，锁外触发）。
    enum Outcome: Equatable, Sendable {
        /// 文件已就绪（幂等 done / 收齐改名后）
        case received(URL)
        case failed(SyncFileTransferError)
    }

    private let session: SyncPeerSession
    /// 落盘目录（纯逻辑层不碰全局路径；测试注入临时目录）
    private let directory: URL
    private let lock = NSLock()

    /// 传输结论回调（锁外触发）。
    var onCompletion: ((Outcome) -> Void)?
    /// 每次发出 ack 的钩子（诊断/测试断言用）。
    var onAckSent: ((FileAckPayload) -> Void)?

    // MARK: 会话槽位链式挂接

    private var priorAppHandler: ((SyncFrame) -> Void)?
    private var priorClosedHandler: ((SyncSessionCloseReason) -> Void)?
    private var forwardingEnabled = true

    // MARK: 当前传输（锁保护）

    private struct Active {
        let fileID: String
        let name: String
        let totalSize: Int64
        let chunkSize: Int64
        let sha256Hex: String
        let finalURL: URL
        let partURL: URL
        var handle: FileHandle?
        /// .part 当前完整字节数（= 下一块期望 offset）
        var received: Int64
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
            return [.finish(.failed(.cancelled(current.fileID)))]
        }
    }

    /// 会话断开（链式 onClosed 转发进来）：与 cancel 同语义（.part 保留）。
    private func handleSessionClosed(_ reason: SyncSessionCloseReason) {
        runLocked {
            guard let current = self.active else { return [] }
            self.active = nil
            self.closeHandle(current)
            return [.finish(.failed(.sessionClosed(current.fileID)))]
        }
    }

    // MARK: 帧入口（会话 onApplicationFrame 转发）

    func handleInboundFrame(_ frame: SyncFrame) {
        switch frame.type {
        case .fileMeta:
            guard let meta = try? SyncFilePayloadCodec.decode(FileMetaPayload.self, from: frame.payload) else {
                return // meta 解码失败无 fileID 可回，静默（协议损坏由会话层兜底）
            }
            runLocked { [meta] in self.processMetaLocked(meta) }
        case .fileChunk:
            guard let chunk = try? SyncFilePayloadCodec.decode(FileChunkPayload.self, from: frame.payload) else {
                // 传输进行中收到损坏块：回 protocolError 让对端干净失败（避免双方悬挂）
                runLocked {
                    guard let current = self.active else { return [] }
                    self.active = nil
                    self.closeHandle(current)
                    return [.sendAck(self.ack(fileID: current.fileID, receivedBytes: current.received,
                                              error: .protocolError)),
                            .finish(.failed(.protocolError(current.fileID, "块解码失败")))]
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

    // MARK: 锁内状态机

    /// meta 处理（锁内；返回待执行效果）。
    private func processMetaLocked(_ meta: FileMetaPayload) -> [Action] {
        if let current = active {
            if current.fileID == meta.fileID {
                // 同 fileID 新 meta = 发送端重启（如 checksumMismatch 后从头重发 /
                // cancel 后同会话再传）：关旧 handle，保留 .part，按新 meta 重对齐
                closeHandle(current)
                active = nil
            } else {
                // v1 不支不同 fileID 交叠传输（对端并发双传 = 调用方 bug）
                return [.sendAck(ack(fileID: meta.fileID, receivedBytes: 0, error: .protocolError))]
            }
        }

        // 参数合法性（v1 校验集：非法 → protocolError 中止）
        guard isValidMeta(meta) else {
            return [.sendAck(ack(fileID: meta.fileID, receivedBytes: 0, error: .protocolError))]
        }

        let fm = FileManager.default
        let finalURL = directory.appendingPathComponent(meta.name)
        let partURL = directory.appendingPathComponent(meta.name + ".part")
        let sha = meta.sha256Hex.lowercased()

        // 幂等：目标已完整存在且同 sha → 直接 done（不重写不重传）
        if fm.fileExists(atPath: finalURL.path),
           fileSize(finalURL) == meta.totalSize,
           (try? SyncFileChecksum.sha256Hex(ofFile: finalURL).lowercased()) == sha {
            return [.sendAck(ack(fileID: meta.fileID, receivedBytes: meta.totalSize, done: true)),
                    .finish(.received(finalURL))]
        }

        // 空文件：无块可收，确保最终文件存在且为 0 字节（M3 manifest 需要空条目）后直接
        // done。同名旧版本（非空）先清空——协议宣称 0 字节，磁盘不得留旧内容
        if meta.totalSize == 0 {
            if !fm.fileExists(atPath: finalURL.path) {
                if !fm.createFile(atPath: finalURL.path, contents: nil) {
                    return [.sendAck(ack(fileID: meta.fileID, receivedBytes: 0, error: .ioError)),
                            .finish(.failed(.ioError(meta.fileID)))]
                }
            } else if fileSize(finalURL) != 0 {
                do {
                    let handle = try FileHandle(forWritingTo: finalURL)
                    try handle.truncate(atOffset: 0)
                    try handle.close()
                } catch {
                    return [.sendAck(ack(fileID: meta.fileID, receivedBytes: 0, error: errorCode(for: error))),
                            .finish(.failed(.ioError(meta.fileID)))]
                }
            }
            return [.sendAck(ack(fileID: meta.fileID, receivedBytes: 0, done: true)),
                    .finish(.received(finalURL))]
        }

        let rawPart = partSize(partURL) ?? 0
        // 断点对齐：offset 永远对齐块边界（半块残留先 truncate，见下方统一对齐分支）
        let alignedPart = alignDown(rawPart, to: meta.chunkSize)

        // 无 .part 且 startOffset > 0：没有可续的数据源 → resumeMismatch
        guard rawPart > 0 || meta.startOffset == 0 else {
            return [.sendAck(ack(fileID: meta.fileID, receivedBytes: 0, error: .resumeMismatch)),
                    .finish(.failed(.resumeMismatch(meta.fileID)))]
        }

        if meta.startOffset == 0 {
            // 从头收：删除任何残留 .part（规格 3.2：删除重建）
            try? fm.removeItem(at: partURL)
        } else if alignedPart != meta.startOffset {
            // .part 对齐后仍与续传起点不符（对端进度记忆与本地不一致）→ resumeMismatch
            return [.sendAck(ack(fileID: meta.fileID, receivedBytes: 0, error: .resumeMismatch)),
                    .finish(.failed(.resumeMismatch(meta.fileID)))]
        }
        // 续写前统一对齐：.part 尾部若有半块残留（异常中断在写块中途）→ truncate 到
        // 块边界。续写与“收齐未改名”两条路径共用，保证后续整文件校验读的是干净数据
        if rawPart > alignedPart {
            if let handle = try? FileHandle(forWritingTo: partURL) {
                try? handle.truncate(atOffset: UInt64(alignedPart))
                try? handle.close()
            }
        }

        do {
            let received = (meta.startOffset == 0) ? 0 : alignedPart

            // 续传起点已含全部字节（上一轮收齐但未及改名）→ 直接整文件校验收尾
            if meta.startOffset > 0, alignedPart == meta.totalSize {
                return completePartLocked(fileID: meta.fileID, totalSize: meta.totalSize,
                                          sha256Hex: meta.sha256Hex, partURL: partURL, finalURL: finalURL)
            }

            let handle = try openPartForAppending(partURL)
            active = Active(fileID: meta.fileID, name: meta.name, totalSize: meta.totalSize,
                            chunkSize: meta.chunkSize, sha256Hex: sha, finalURL: finalURL,
                            partURL: partURL, handle: handle, received: received)
            return [.sendAck(ack(fileID: meta.fileID, receivedBytes: received, done: false))]
        } catch {
            let code = errorCode(for: error)
            return [.sendAck(ack(fileID: meta.fileID, receivedBytes: 0, error: code)),
                    .finish(.failed(localError(code, fileID: meta.fileID)))]
        }
    }

    /// chunk 处理（锁内；返回待执行效果）。
    private func processChunkLocked(_ chunk: FileChunkPayload) -> [Action] {
        guard let current = active else {
            // 无 meta 先到块：无从校验，回 protocolError 让对端发送端干净失败
            return [.sendAck(ack(fileID: chunk.fileID, receivedBytes: 0, error: .protocolError))]
        }
        guard chunk.fileID == current.fileID else {
            // 交叠传输的块（本对象正收别的 fileID）→ protocolError（v1 不交叠）
            return [.sendAck(ack(fileID: chunk.fileID, receivedBytes: 0, error: .protocolError))]
        }

        let abort: [Action] = [.sendAck(ack(fileID: current.fileID, receivedBytes: current.received,
                                            error: .protocolError)),
                               .finish(.failed(.protocolError(current.fileID, "块序违例")))]
        // offset 必须 == 期望偏移（= 已收完整字节）；跳/乱序 → protocolError 中止
        guard chunk.offset == current.received else {
            active = nil
            closeHandle(current)
            return abort
        }
        // 块大小/长度边界防御
        let byteCount = Int64(chunk.data.count)
        guard byteCount > 0,
              byteCount <= current.chunkSize,
              byteCount <= current.totalSize - current.received
        else {
            active = nil
            closeHandle(current)
            return abort
        }

        do {
            try current.handle?.write(contentsOf: chunk.data)
        } catch {
            let code = errorCode(for: error)
            active = nil
            closeHandle(current)
            return [.sendAck(ack(fileID: current.fileID, receivedBytes: current.received, error: code)),
                    .finish(.failed(localError(code, fileID: current.fileID)))]
        }

        var advanced = current
        advanced.received += byteCount
        active = advanced

        if advanced.received == advanced.totalSize {
            // 收齐：关文件 → 整文件 SHA-256 → 匹配改名 / 不匹配删 .part
            closeHandle(advanced)
            active = nil
            return completePartLocked(fileID: advanced.fileID, totalSize: advanced.totalSize,
                                      sha256Hex: advanced.sha256Hex, partURL: advanced.partURL,
                                      finalURL: advanced.finalURL)
        }
        return [.sendAck(ack(fileID: advanced.fileID, receivedBytes: advanced.received, done: false))]
    }

    /// 收齐收尾（锁内）：算 SHA-256，匹配 → 原子改名去 .part + ack(done)；
    /// 不匹配 → 删 .part + ack(checksumMismatch)。IO 失败 → ioError 中止（.part 保留）。
    private func completePartLocked(fileID: String, totalSize: Int64, sha256Hex: String,
                                    partURL: URL, finalURL: URL) -> [Action] {
        let sha: String
        do {
            sha = try SyncFileChecksum.sha256Hex(ofFile: partURL).lowercased()
        } catch {
            return [.sendAck(ack(fileID: fileID, receivedBytes: totalSize, error: .ioError)),
                    .finish(.failed(.ioError(fileID)))]
        }
        guard sha == sha256Hex.lowercased() else {
            // 校验失败：删 .part（发送端可从头重发）
            try? FileManager.default.removeItem(at: partURL)
            return [.sendAck(ack(fileID: fileID, receivedBytes: 0, error: .checksumMismatch)),
                    .finish(.failed(.checksumMismatch(fileID)))]
        }
        do {
            // 原子改名去 .part（目标已存在则替换——同名不同 sha 的旧版本让位于新收版本）
            _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: partURL)
        } catch {
            return [.sendAck(ack(fileID: fileID, receivedBytes: totalSize, error: .ioError)),
                    .finish(.failed(.ioError(fileID)))]
        }
        return [.sendAck(ack(fileID: fileID, receivedBytes: totalSize, done: true)),
                .finish(.received(finalURL))]
    }

    // MARK: 校验与辅助（锁内调用）

    /// meta 参数合法性（非法 → protocolError，见 3.2 第 1 条）。
    private func isValidMeta(_ meta: FileMetaPayload) -> Bool {
        guard !meta.fileID.isEmpty,
              !meta.name.isEmpty,
              meta.name != ".", meta.name != "..",
              !meta.name.contains("/"), !meta.name.contains("\\")
        else { return false }
        guard meta.totalSize >= 0,
              meta.startOffset >= 0,
              meta.startOffset <= meta.totalSize,
              meta.chunkSize > 0,
              meta.chunkSize <= Int64(SyncFrame.maxPayloadSize),
              meta.startOffset == 0 || meta.startOffset % meta.chunkSize == 0
        else { return false }
        guard SyncFileChecksum.isValidSHA256Hex(meta.sha256Hex) else { return false }
        // 0 字节文件的 sha 必须是空数据 sha（自洽性）
        if meta.totalSize == 0 {
            return meta.sha256Hex.lowercased() == SyncFileChecksum.emptyHex
        }
        return true
    }

    /// 对齐到块边界（断点/truncate 语义的唯一对齐入口）。
    private func alignDown(_ value: Int64, to chunkSize: Int64) -> Int64 {
        value - value % chunkSize
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    private func partSize(_ url: URL) -> Int64? {
        FileManager.default.fileExists(atPath: url.path) ? fileSize(url) : nil
    }

    /// 打开 .part 追加写句柄（不存在则创建；offset 移到文件尾）。
    private func openPartForAppending(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    private func closeHandle(_ transfer: Active) {
        try? transfer.handle?.close()
    }

    /// 错误 → 线上错误码（写失败按 ENOSPC 区分 diskFull；其余 ioError）。
    private func errorCode(for error: Error) -> FileTransferErrorCode {
        let nsError = error as NSError
        let isDiskFull = nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOSPC
            || nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError
        return isDiskFull ? .diskFull : .ioError
    }

    /// 线上错误码 → 本端错误。
    private func localError(_ code: FileTransferErrorCode, fileID: String) -> SyncFileTransferError {
        switch code {
        case .none: return .protocolError(fileID, "ack 无错误码但中止")
        case .ioError: return .ioError(fileID)
        case .diskFull: return .diskFull(fileID)
        case .checksumMismatch: return .checksumMismatch(fileID)
        case .resumeMismatch: return .resumeMismatch(fileID)
        case .cancelled: return .cancelled(fileID)
        case .protocolError: return .protocolError(fileID, "接收端协议中止")
        }
    }

    private func ack(fileID: String, receivedBytes: Int64, done: Bool = false,
                     error: FileTransferErrorCode = .none) -> FileAckPayload {
        FileAckPayload(fileID: fileID, receivedBytes: receivedBytes, done: done, error: error)
    }

    // MARK: 锁 + 效果执行

    private enum Action {
        case sendAck(FileAckPayload)
        case finish(Outcome)
    }

    /// 锁内跑状态机，锁外执行效果（发 ack / 用户回调）。所有路径的 ack 发送都在锁外，
    /// 保证同步回环下对端 ack 重入本对象不死锁。
    private func runLocked(_ body: () -> [Action]) {
        lock.lock()
        let actions = body()
        lock.unlock()
        for action in actions {
            switch action {
            case let .sendAck(ack):
                sendAck(ack)
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
