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
//  M4-2b 多根（aligned 歌词随歌同步，§6.3）：
//  - 歌词走**单一命名空间的第二个根**——`@lyrics/{歌曲 content_hash}.json` 解析到
//    `lyricsRoot`（SyncFetchRoots），其余路径仍只认 `libraryRoot`。
//  - 歌词文件在盘上的名字是 `{本端 stableId}.json`，与 wire 路径不同名，由注入的
//    `lyricsFileNameProvider`（wire 路径 → 库文件名）给出；**只接受单段文件名**，
//    再经同一套「根内包含性 + 软链逃逸」校验——注入方给不出合法名 = notFound，
//    绝不用它拼出根外路径。
//  - 未配置 lyricsRoot 时，`@lyrics/...` 一律 notFound（不落回曲库根尝试）。
//
//  串行推进：v1 单飞——一个 responder 同时只服务一个请求（已在服务中收到新请求
//  则忽略；会话上下一个请求由调用方在上一个 onResultSent 之后发起）。
//  推完一个文件（SyncFileSender.onCompletion）才发下一个；本类不并发发多个 transfer。
//  内存回环测试下整条链是同步递归的（与 M2b 既有风格一致），真实网络下每步由
//  ack 异步驱动。
//
//  会话槽位挂接统一走 `SyncSessionAttachment`（分发链，见 SyncPeerSession+Frames.swift）：
//  onApplicationFrame 收 sync_fetch_request，onClosed 清服务态；本实例释放只静默自己，
//  **不牵连链上其它 handler**（🟡F1）。
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
    private let roots: SyncFetchRoots
    private let fileManager: FileManager
    /// 相对路径 → content_hash（本端事实；缺失时回落到现算 SHA-256，用于 fileID）
    private let contentHashProvider: ((String) -> String?)?
    /// wire 歌词路径（`@lyrics/{歌曲 content_hash}.json`）→ 本端库文件名（`{stableId}.json`）
    private let lyricsFileNameProvider: ((String) -> String?)?
    private let lock = NSLock()

    /// 一次拉取的结论已发出（含全失败/空请求的场景）。
    var onResultSent: ((SyncFetchResult) -> Void)?
    /// sync_fetch_request 载荷解码失败（协议违例，诊断用）。
    var onDecodeFailure: ((String) -> Void)?

    // MARK: 会话槽位挂接（分发链）

    private var attachment: SyncSessionAttachment?

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

    /// 单根初始化（M4-2b 之前的调用点/测试保持不变：歌词命名空间不服务）。
    convenience init(
        session: SyncPeerSession,
        libraryRoot: URL,
        fileManager: FileManager = .default,
        contentHashProvider: ((String) -> String?)? = nil
    ) {
        self.init(
            session: session,
            roots: .libraryOnly(libraryRoot),
            fileManager: fileManager,
            contentHashProvider: contentHashProvider
        )
    }

    init(
        session: SyncPeerSession,
        roots: SyncFetchRoots,
        fileManager: FileManager = .default,
        contentHashProvider: ((String) -> String?)? = nil,
        lyricsFileNameProvider: ((String) -> String?)? = nil
    ) {
        self.session = session
        self.roots = roots
        self.fileManager = fileManager
        self.contentHashProvider = contentHashProvider
        self.lyricsFileNameProvider = lyricsFileNameProvider
        attachment = SyncSessionAttachment(
            session: session,
            owner: self,
            onFrame: { [weak self] frame in self?.handleInboundFrame(frame) },
            onClosed: { [weak self] _ in self?.handleSessionClosed() }
        )
    }

    /// 是否正在服务一个请求（诊断/测试用）。
    var isServing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return serving != nil
    }

    // MARK: 解析计划（纯逻辑 + 只读磁盘检查，可单测）

    /// 请求路径 → 可推送文件 + 失败记录（单根版，保留给既有调用点/测试）。
    static func makePlan(
        relativePaths: [String],
        root: URL,
        fileManager: FileManager = .default
    ) -> Plan {
        makePlan(relativePaths: relativePaths, roots: .libraryOnly(root), fileManager: fileManager)
    }

    /// 请求路径 → 可推送文件 + 失败记录（多根版）。
    /// - 歌词命名空间（`@lyrics/...`）：wire 路径 → 注入映射给出本端库文件名 →
    ///   在 `lyricsRoot` 内解析；未配置根 / 映射不到 / 文件名非法 → notFound。
    /// - 其余路径：曲库根内解析（原语义不变）。
    /// - 重复路径只处理一次（首个生效）：能解析者按**规范化相对路径**判重
    ///   （与 Generator 对账键同口径，故 "song.flac" 与 "./song.flac" 视为同一文件），
    ///   非法/越界请求按原始字符串判重
    /// - 非法/越界/不存在/非常规文件/软链逃逸 → failed（不读任何根之外的文件）
    static func makePlan(
        relativePaths: [String],
        roots: SyncFetchRoots,
        lyricsFileNameProvider: ((String) -> String?)? = nil,
        fileManager: FileManager = .default
    ) -> Plan {
        var plan = Plan()
        /// 能解析的请求：按规范化相对路径判重
        var seenResolved: Set<String> = []
        /// 解析即被拒的请求（无规范化形式可用）：按原始字符串判重
        var seenRejected: Set<String> = []

        /// 记一条失败（按原始请求串判重）。
        func reject(_ raw: String, _ reason: String) {
            guard seenRejected.insert(raw).inserted else { return }
            plan.failures.append(SyncFileFetchFailure(relativePath: raw, reason: reason))
        }

        for raw in relativePaths {
            let normalized = SyncManifestGenerator.normalizeRelativePath(raw)
            let isLyrics = SyncLyricsNamespace.isLyricsPath(raw)

            // ① 选根 + 定「根内相对路径」
            let root: URL
            let pathWithinRoot: String
            if isLyrics {
                guard let normalized, SyncLyricsNamespace.songContentHash(fromWirePath: normalized) != nil else {
                    reject(raw, SyncFetchFailureReason.invalidPath)
                    continue
                }
                guard let lyricsRoot = roots.lyricsRoot else {
                    reject(raw, SyncFetchFailureReason.notFound)
                    continue
                }
                // 注入映射：wire 路径 → 本端库文件名；只接受单段合法名
                guard let fileName = lyricsFileNameProvider?(normalized),
                      let relativeName = SyncManifestGenerator.normalizeRelativePath(fileName),
                      !relativeName.contains("/")
                else {
                    reject(raw, SyncFetchFailureReason.notFound)
                    continue
                }
                root = lyricsRoot
                pathWithinRoot = relativeName
            } else {
                root = roots.libraryRoot
                pathWithinRoot = normalized ?? raw
            }

            guard seenResolved.insert(normalized ?? raw).inserted else { continue }

            let url: URL
            switch SyncLibraryPathResolver.resolve(relativePath: pathWithinRoot, root: root) {
            case let .rejected(reason):
                reject(raw, reason)
                continue
            case let .resolved(resolved):
                url = resolved
            }

            if let failure = Self.failureForFile(at: url, root: root, fileManager: fileManager) {
                reject(raw, failure)
                continue
            }
            plan.files.append(RequestedFile(relativePath: normalized ?? raw, url: url))
        }
        return plan
    }

    /// 磁盘侧三道校验（存在 / 常规文件 / 软链不逃逸出根）。通过 = nil。
    static func failureForFile(at url: URL, root: URL, fileManager: FileManager = .default) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return SyncFetchFailureReason.notFound
        }
        guard !isDirectory.boolValue else {
            return SyncFetchFailureReason.notRegularFile
        }
        // 软链逃逸防御：解析真实路径后必须仍在根内
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = realRoot.path.hasSuffix("/") ? realRoot.path : realRoot.path + "/"
        let realTarget = url.resolvingSymlinksInPath().standardizedFileURL
        guard realTarget.path.hasPrefix(rootPrefix) else {
            return SyncFetchFailureReason.outOfRoot
        }
        return nil
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
            roots: roots,
            lyricsFileNameProvider: lyricsFileNameProvider,
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
    /// 歌词文件不在曲库根的 content_hash 表里（那是音频路径→指纹），直接现算。
    private func push(_ file: RequestedFile) {
        let fileID: String?
        if SyncLyricsNamespace.isLyricsPath(file.relativePath) {
            fileID = try? SyncFileChecksum.sha256Hex(ofFile: file.url)
        } else if let provided = contentHashProvider?(file.relativePath), !provided.isEmpty {
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
            // 歌词文件：线上名用 wire 路径末段（`{歌曲 content_hash}.json`）而非盘上名
            // （`{本端 stableId}.json`）——两端对同一首歌看到同一个名字，接收侧才能把
            // 收到的东西对回自己请求过的条目；两端均对 name 做单段校验。
            let transferName = SyncLyricsNamespace.isLyricsPath(file.relativePath)
                ? (file.relativePath as NSString).lastPathComponent
                : file.url.lastPathComponent
            try ensureSender().send(
                fileURL: file.url,
                fileID: fileID,
                name: transferName
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

    /// 停止收帧（会话关闭 / 服务停止）：静默自己并让出链位（幂等）。
    /// 不调用也会在本实例释放时自动摘除。与 `cancel()`（中止进行中的推送）互不依赖。
    func detach() {
        attachment?.detach()
    }
}
