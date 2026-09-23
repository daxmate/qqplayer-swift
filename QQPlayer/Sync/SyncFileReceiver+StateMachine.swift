//
//  SyncFileReceiver+StateMachine.swift
//  QQPlayer
//
//  锁内状态机（meta / chunk 处理与收尾）与校验、IO 辅助；返回待执行效果 [Action]。
//  锁外效果执行（发 ack / 日志 / 用户回调）仍在主片 runLocked。
//  E5（2026-09-21）自 SyncFileReceiver.swift 拆出——纯搬家。
//
import Foundation

/// 收齐收尾（`completePartLocked`）的文件级入参打包。
/// 这 5 个值在两条收尾路径（meta 续传已收齐 / chunk 收齐）里语义相同、总是一起传，
/// 打包后收尾函数只剩「上下文 + 进度」两个参数（清 swiftlint `function_parameter_count`）。
private struct PartCompletionContext {
    let fileID: String
    let totalSize: Int64
    let sha256Hex: String
    let partURL: URL
    let finalURL: URL
}

extension SyncFileReceiver {
    // MARK: 锁内状态机

    /// meta 处理（锁内；返回待执行效果）。
    func processMetaLocked(_ meta: FileMetaPayload) -> [Action] {
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
                    .finish(.received(ReceivedFile(fileID: meta.fileID, sha256Hex: sha, url: finalURL)))]
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
                    .finish(.received(ReceivedFile(fileID: meta.fileID,
                                                   sha256Hex: SyncFileChecksum.emptyHex,
                                                   url: finalURL)))]
        }

        let rawPart = partSize(partURL) ?? 0
        // 断点对齐：offset 永远对齐**声明**块边界（半块残留先 truncate，见下方统一对齐分支）
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
        // 块边界。续写与“收齐未改名”两条路径共用，保证后续整文件校验读的是干净数据。
        // 失败**绝不静默继续**（2026-09-12 审计 🟡T5）：对齐不成就意味着后续块按错误偏移
        // 追加（把可定位的 IO 错误伪装成 checksumMismatch）→ 直接失败，`.part` 保留可重试。
        if meta.startOffset > 0, rawPart > alignedPart {
            do {
                try realignPart(partURL, to: alignedPart)
            } catch {
                let code = errorCode(for: error)
                AppLog.warn(.transfer, "⚠️ SyncFileReceiver: .part 断点对齐失败（fileID=\(meta.fileID) 目标偏移=\(alignedPart)）：\(error)")
                return [.sendAck(ack(fileID: meta.fileID, receivedBytes: 0, error: code)),
                        .finish(.failed(localError(code, fileID: meta.fileID)))]
            }
        }

        do {
            let received = (meta.startOffset == 0) ? 0 : alignedPart

            // 续传起点已含全部字节（上一轮收齐但未及改名）→ 直接整文件校验收尾
            if meta.startOffset > 0, alignedPart == meta.totalSize {
                return completePartLocked(PartCompletionContext(fileID: meta.fileID,
                                                                totalSize: meta.totalSize,
                                                                sha256Hex: meta.sha256Hex,
                                                                partURL: partURL,
                                                                finalURL: finalURL),
                                          progress: Progress(startedAt: Date(), chunks: 0,
                                                             chunkSize: meta.chunkSize,
                                                             startOffset: meta.startOffset))
            }

            let handle = try openPartForAppending(partURL)
            active = Active(fileID: meta.fileID, name: meta.name, totalSize: meta.totalSize,
                            chunkSize: meta.chunkSize, sha256Hex: sha, finalURL: finalURL,
                            partURL: partURL, startOffset: meta.startOffset, startedAt: Date(),
                            handle: handle, received: received, chunksReceived: 0)
            return [.sendAck(ack(fileID: meta.fileID, receivedBytes: received, done: false))]
        } catch {
            let code = errorCode(for: error)
            return [.sendAck(ack(fileID: meta.fileID, receivedBytes: 0, error: code)),
                    .finish(.failed(localError(code, fileID: meta.fileID)))]
        }
    }

    /// chunk 处理（锁内；返回待执行效果）。
    func processChunkLocked(_ chunk: FileChunkPayload) -> [Action] {
        guard let current = active else {
            // 无 meta 先到块：无从校验，回 protocolError 让对端发送端干净失败
            return [.sendAck(ack(fileID: chunk.fileID, receivedBytes: 0, error: .protocolError))]
        }
        guard chunk.fileID == current.fileID else {
            // 交叠传输的块（本对象正收别的 fileID）→ protocolError（v1 不交叠）
            return [.sendAck(ack(fileID: chunk.fileID, receivedBytes: 0, error: .protocolError))]
        }

        let abortError = SyncFileTransferError.protocolError(current.fileID, "块序违例")
        let abort: [Action] = [.sendAck(ack(fileID: current.fileID, receivedBytes: current.received,
                                            error: .protocolError)),
                               .log(metrics(current, succeeded: false, error: abortError)),
                               .finish(.failed(abortError))]
        // offset 必须 == 期望偏移（= 已收完整字节）；跳/乱序 → protocolError 中止
        guard chunk.offset == current.received else {
            active = nil
            closeHandle(current)
            return abort
        }
        // 块大小/长度边界防御（上界 = **声明**块大小，不是本地常量）
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
            let error = localError(code, fileID: current.fileID)
            return [.sendAck(ack(fileID: current.fileID, receivedBytes: current.received, error: code)),
                    .log(metrics(current, succeeded: false, error: error)),
                    .finish(.failed(error))]
        }

        var advanced = current
        advanced.received += byteCount
        advanced.chunksReceived += 1
        active = advanced

        if advanced.received == advanced.totalSize {
            // 收齐：关文件 → 整文件 SHA-256 → 匹配改名 / 不匹配删 .part
            closeHandle(advanced)
            active = nil
            return completePartLocked(PartCompletionContext(fileID: advanced.fileID,
                                                            totalSize: advanced.totalSize,
                                                            sha256Hex: advanced.sha256Hex,
                                                            partURL: advanced.partURL,
                                                            finalURL: advanced.finalURL),
                                      progress: Progress(startedAt: advanced.startedAt,
                                                         chunks: advanced.chunksReceived,
                                                         chunkSize: advanced.chunkSize,
                                                         startOffset: advanced.startOffset))
        }
        return [.sendAck(ack(fileID: advanced.fileID, receivedBytes: advanced.received, done: false))]
    }

    /// 收齐收尾（锁内）：算 SHA-256，匹配 → 原子改名去 .part + ack(done)；
    /// 不匹配 → 删 .part + ack(checksumMismatch)。IO 失败 → ioError 中止（.part 保留）。
    private func completePartLocked(_ context: PartCompletionContext, progress: Progress) -> [Action] {
        let fileID = context.fileID
        let totalSize = context.totalSize
        let sha256Hex = context.sha256Hex
        let partURL = context.partURL
        let finalURL = context.finalURL
        let sha: String
        do {
            sha = try SyncFileChecksum.sha256Hex(ofFile: partURL).lowercased()
        } catch {
            return [.sendAck(ack(fileID: fileID, receivedBytes: totalSize, error: .ioError)),
                    .log(metricsLocked(fileID: fileID, totalSize: totalSize, progress: progress,
                                       succeeded: false, error: .ioError(fileID))),
                    .finish(.failed(.ioError(fileID)))]
        }
        guard sha == sha256Hex.lowercased() else {
            // 校验失败：删 .part（发送端可从头重发）
            try? FileManager.default.removeItem(at: partURL)
            return [.sendAck(ack(fileID: fileID, receivedBytes: 0, error: .checksumMismatch)),
                    .log(metricsLocked(fileID: fileID, totalSize: totalSize, progress: progress,
                                       succeeded: false, error: .checksumMismatch(fileID))),
                    .finish(.failed(.checksumMismatch(fileID)))]
        }
        do {
            // 原子改名去 .part（目标已存在则替换——同名不同 sha 的旧版本让位于新收版本）
            _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: partURL)
        } catch {
            return [.sendAck(ack(fileID: fileID, receivedBytes: totalSize, error: .ioError)),
                    .log(metricsLocked(fileID: fileID, totalSize: totalSize, progress: progress,
                                       succeeded: false, error: .ioError(fileID))),
                    .finish(.failed(.ioError(fileID)))]
        }
        return [.sendAck(ack(fileID: fileID, receivedBytes: totalSize, done: true)),
                .log(metricsLocked(fileID: fileID, totalSize: totalSize, progress: progress,
                                   succeeded: true, error: nil)),
                .finish(.received(ReceivedFile(fileID: fileID,
                                               sha256Hex: sha256Hex.lowercased(),
                                               url: finalURL)))]
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

    /// 断点对齐（truncate 到块边界）：`.part` 尾部半块残留 → 截到 `offset`。
    /// 可注入覆盖（测试覆盖失败路径）；生产路径为真实 FileHandle。
    private func realignPart(_ partURL: URL, to offset: Int64) throws {
        if let hook = partAlignmentHook {
            try hook(partURL, offset)
            return
        }
        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
    }

    /// 对齐到块边界（断点/truncate 语义的唯一对齐入口；`chunkSize` 由调用方给声明值）。
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

    func closeHandle(_ transfer: Active) {
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

}
