//
//  SyncLibraryFetchResponder.swift
//  QQPlayer
//
//  局域网同步（S2, M3-3b）Host 侧「按路径拉取」应答器：收 sync_fetch_request →
//  曲库根内逐个解析 → **串行**用 M2b 的 SyncFileSender 推送 → 全部结束回
//  sync_fetch_result。
//
//  安全性（§6.1 硬要求，本文件是执行点）：
//  - 每条请求路径过 SyncLibraryPathResolver（规范化 + 根内包含性），再加两道
//    磁盘侧校验：① 必须存在且是常规文件 ② resolvingSymlinksInPath 后仍在根内
//    （挡「根内软链指向根外」）。任一不过 → 计入 failed，**绝不读曲库之外的文件**。
//  - 请求路径原样回填 failed.relativePath，方便请求方定位。
//
//  串行推进：v1 单飞——一个 responder 同时只服务一个请求（已在服务中收到新请求
//  则忽略；会话上下一个请求由调用方在上一个 onResultSent 之后发起）。
//  推完一个文件（SyncFileSender.onCompletion）才发下一个；本类不并发发多个 transfer。
//  内存回环测试下整条链是同步递归的（与 M2b 既有风格一致），真实网络下每步由
//  ack 异步驱动。
//
//  会话槽位链式挂接（先己后彼）：onApplicationFrame 收 sync_fetch_request，
//  onClosed 清服务态；结束用 enabled 开关静默自己，不拆链。
//

import Foundation

final class SyncLibraryFetchResponder: @unchecked Sendable {
    /// 一条待推送文件。
    struct RequestedFile: Equatable {
        /// 规范化后的相对路径（协议结果里的 completed 用它）
        var relativePath: String
        /// 曲库根内的绝对 URL
        var url: URL
    }

    /// 解析计划：能推的 + 一开始就注定失败的。
    struct Plan: Equatable {
        var files: [RequestedFile] = []
        var failures: [SyncFileFetchFailure] = []
    }

    private let session: SyncPeerSession
    private let libraryRoot: URL
    private let fileManager: FileManager
    /// 相对路径 → content_hash（本端事实；缺失时回落到现算 SHA-256，用于 fileID）
    private let contentHashProvider: ((String) -> String?)?
    private let lock = NSLock()

    /// 一次拉取的结论已发出（含全失败/空请求的场景）。
    var onResultSent: ((SyncFetchResult) -> Void)?
    /// sync_fetch_request 载荷解码失败（协议违例，诊断用）。
    var onDecodeFailure: ((String) -> Void)?

    // MARK: 会话槽位链式挂接

    private var priorAppHandler: ((SyncFrame) -> Void)?
    private var priorClosedHandler: ((SyncSessionCloseReason) -> Void)?
    private var forwardingEnabled = true

    // MARK: 锁保护状态

    /// 正在服务的请求（nil = 空闲）。
    private struct Serving {
        var remaining: [RequestedFile]
        var current: String?
        var completed: [String]
        var failures: [SyncFileFetchFailure]
    }

    private var serving: Serving?
    /// 推送用发送端（懒建，跨请求复用；会话关闭后由调用方重建 responder）
    private var sender: SyncFileSender?

    // MARK: init

    init(
        session: SyncPeerSession,
        libraryRoot: URL,
        fileManager: FileManager = .default,
        contentHashProvider: ((String) -> String?)? = nil
    ) {
        self.session = session
        self.libraryRoot = libraryRoot
        self.fileManager = fileManager
        self.contentHashProvider = contentHashProvider
        attachHandlers()
    }

    /// 是否正在服务一个请求（诊断/测试用）。
    var isServing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return serving != nil
    }

    // MARK: 解析计划（纯逻辑 + 只读磁盘检查，可单测）

    /// 请求路径 → 可推送文件 + 失败记录。
    /// - 重复路径只处理一次（首个生效）
    /// - 非法/越界/不存在/非常规文件/软链逃逸 → failed（不读曲库之外）
    static func makePlan(
        relativePaths: [String],
        root: URL,
        fileManager: FileManager = .default
    ) -> Plan {
        var plan = Plan()
        var seen: Set<String> = []
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = realRoot.path.hasSuffix("/") ? realRoot.path : realRoot.path + "/"

        for raw in relativePaths {
            guard seen.insert(raw).inserted else { continue }

            let url: URL
            switch SyncLibraryPathResolver.resolve(relativePath: raw, root: root) {
            case let .rejected(reason):
                plan.failures.append(SyncFileFetchFailure(relativePath: raw, reason: reason))
                continue
            case let .resolved(resolved):
                url = resolved
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                plan.failures.append(
                    SyncFileFetchFailure(relativePath: raw, reason: SyncFetchFailureReason.notFound)
                )
                continue
            }
            guard !isDirectory.boolValue else {
                plan.failures.append(
                    SyncFileFetchFailure(relativePath: raw, reason: SyncFetchFailureReason.notRegularFile)
                )
                continue
            }
            // 软链逃逸防御：解析真实路径后必须仍在曲库根内
            let realTarget = url.resolvingSymlinksInPath().standardizedFileURL
            guard realTarget.path.hasPrefix(rootPrefix) else {
                plan.failures.append(
                    SyncFileFetchFailure(relativePath: raw, reason: SyncFetchFailureReason.outOfRoot)
                )
                continue
            }
            let normalized = SyncManifestGenerator.normalizeRelativePath(raw) ?? raw
            plan.files.append(RequestedFile(relativePath: normalized, url: url))
        }
        return plan
    }

    // MARK: 中止

    /// 中止当前服务（会话关闭 / 服务停止）：停止发帧，不再回结果帧。
    func cancel() {
        lock.lock()
        serving = nil
        let activeSender = sender
        lock.unlock()
        activeSender?.cancel()
    }

    // MARK: 帧入口（会话 onApplicationFrame 转发）

    func handleInboundFrame(_ frame: SyncFrame) {
        guard frame.type == .syncFetchRequest else { return }
        let request: SyncFetchRequest
        do {
            request = try SyncFetchCodec.decode(SyncFetchRequest.self, from: frame.payload)
        } catch {
            onDecodeFailure?("sync_fetch_request 解码失败：\(error)")
            return
        }

        let plan = Self.makePlan(
            relativePaths: request.relativePaths,
            root: libraryRoot,
            fileManager: fileManager
        )

        lock.lock()
        guard serving == nil else {
            // v1 单飞：服务中忽略新请求（调用方应等上一次 result）
            lock.unlock()
            return
        }
        serving = Serving(
            remaining: plan.files,
            current: nil,
            completed: [],
            failures: plan.failures
        )
        lock.unlock()
        sendNext()
    }

    // MARK: 串行推进

    /// 推送下一个文件；没有剩余 → 回结果帧收尾。
    private func sendNext() {
        lock.lock()
        guard let state = serving else {
            lock.unlock()
            return
        }
        guard let next = state.remaining.first else {
            serving = nil
            lock.unlock()
            sendResult(SyncFetchResult(completed: state.completed, failed: state.failures))
            return
        }
        var updated = state
        updated.remaining.removeFirst()
        updated.current = next.relativePath
        serving = updated
        lock.unlock()

        push(next)
    }

    /// 单个文件推送（fileID = content_hash，缺失则现算 SHA-256）。
    private func push(_ file: RequestedFile) {
        let fileID: String?
        if let provided = contentHashProvider?(file.relativePath), !provided.isEmpty {
            fileID = provided
        } else {
            fileID = try? SyncFileChecksum.sha256Hex(ofFile: file.url)
        }
        guard let fileID, !fileID.isEmpty else {
            record(path: file.relativePath, failureReason: SyncFetchFailureReason.sendFailed)
            sendNext()
            return
        }
        do {
            try ensureSender().send(
                fileURL: file.url,
                fileID: fileID,
                name: file.url.lastPathComponent
            )
        } catch {
            record(path: file.relativePath, failureReason: SyncFetchFailureReason.sendFailed)
            sendNext()
        }
    }

    /// 一轮传输结论（SyncFileSender 回调，锁外触发）。
    private func handleOutcome(_ outcome: SyncFileSender.Outcome) {
        lock.lock()
        guard var state = serving, let current = state.current else {
            lock.unlock()
            return
        }
        state.current = nil
        serving = state
        lock.unlock()

        switch outcome {
        case .succeeded:
            lock.lock()
            if var updated = serving {
                updated.completed.append(current)
                serving = updated
            }
            lock.unlock()
            sendNext()
        case let .failed(error):
            if case .sessionClosed = error {
                // 会话已断：结果帧发不出去，直接收尾（不再推进）
                lock.lock()
                serving = nil
                lock.unlock()
                return
            }
            record(path: current, failureReason: SyncFetchFailureReason.sendFailed)
            sendNext()
        }
    }

    // MARK: 辅助

    private func record(path: String, failureReason: String) {
        lock.lock()
        if var updated = serving {
            updated.failures.append(SyncFileFetchFailure(relativePath: path, reason: failureReason))
            serving = updated
        }
        lock.unlock()
    }

    /// 懒建发送端（跨请求复用；回调在锁外设置，避免构造期重入）。
    private func ensureSender() -> SyncFileSender {
        lock.lock()
        if let sender {
            lock.unlock()
            return sender
        }
        lock.unlock()
        let created = SyncFileSender(session: session)
        created.onCompletion = { [weak self] outcome in
            self?.handleOutcome(outcome)
        }
        lock.lock()
        if let existing = sender {
            lock.unlock()
            return existing
        }
        sender = created
        lock.unlock()
        return created
    }

    private func sendResult(_ result: SyncFetchResult) {
        guard let payload = try? SyncFetchCodec.encode(result) else { return }
        try? session.sendApplicationFrame(type: .syncFetchResult, payload: payload)
        onResultSent?(result)
    }

    private func handleSessionClosed() {
        lock.lock()
        serving = nil
        lock.unlock()
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
            self.handleSessionClosed()
            self.priorClosedHandler?(reason)
        }
    }
}
