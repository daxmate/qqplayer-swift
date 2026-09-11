//
//  SyncPeerLibraryClient.swift
//  QQPlayer
//
//  T9（2026-09-12）「对端内容清单」**发起端客户端**（Mac 侧；平台无关）。
//
//  用途（T10 UI）：内容面板随同步方向切换数据源——选「从 iPhone 下载」时展示
//  **对端（iPhone）**的歌单/曲目，而不是本端曲库。本类就是那条取数通道：
//  发 `peer_library_request`（帧 15）→ 等 `peer_library_response`（帧 16）。
//
//  与既有组件的关系：
//  - 传输/加密/分帧全部由 `SyncPeerSession` 承担，本类只做「请求 ↔ 响应」配对；
//  - 事实过滤/分页/钳制在**对端**（`SyncPeerLibraryResponder` + `SyncPeerLibraryCatalog`），
//    本类不重复实现业务规则（除了 `fetchPlaylists()` 的自动翻页）。
//
//  可靠性硬要求（契约）：
//  - **超时有**（默认 10s）：对端不答 → 抛 `.timeout`，UI 显示失败态，绝不永久等待；
//  - `requestID` 关联：不匹配/重复的响应一律丢弃（`onUnexpectedResponse` 仅诊断）；
//  - `cancel()`：UI 取消时立即唤醒所有在途请求（抛 `.cancelled`），会话关闭同理；
//  - 每次请求前检查 `session.isReady`（未就绪 → `.sessionNotReady`，不静默挂起）。
//
//  线程：可在任意线程调用（内部锁保护在途表）；响应回调发生在会话线程。
//

import Foundation

/// 对端内容清单客户端（一个会话一个实例；T10 由 UI 持有）。
final class SyncPeerLibraryClient: @unchecked Sendable {
    /// 客户端错误（`Equatable` 便于测试断言；`sendFailed` 带诊断串故手写相等）。
    enum ClientError: Error, Equatable, Sendable {
        /// 会话未 ready（未配对 / 已关闭 / 正在重建）
        case sessionNotReady
        /// 对端在超时内没回响应（含对端未接线的情形）
        case timeout
        /// 本端主动取消（UI 关闭面板 / 切换方向）
        case cancelled
        /// 会话已关闭（在途请求立即失败，不等超时）
        case sessionClosed
        /// 帧发送失败（未 ready / 超过帧上限等）
        case sendFailed(String)
    }

    /// 自动翻页上限（防对端 `hasMore` 恒真的病态响应把本端拖死）。
    static let maxAutoPages = 20

    private let session: SyncPeerSession
    private let timeout: TimeInterval
    private let timeoutQueue = DispatchQueue(label: "qqplayer.sync.peer-library.timeout", qos: .utility)
    private let lock = NSLock()

    /// 在途请求：requestID → continuation
    private var pending: [UInt64: CheckedContinuation<SyncPeerLibraryResponsePayload, Error>] = [:]
    private var nextRequestID: UInt64 = 1
    private var isActive = true

    /// 会话槽位链式挂接
    private var priorAppHandler: ((SyncFrame) -> Void)?
    private var priorClosedHandler: ((SyncSessionCloseReason) -> Void)?

    /// 收到「无对应在途请求」的响应（重复/过期；仅诊断，不参与协议）。
    var onUnexpectedResponse: ((SyncPeerLibraryResponsePayload) -> Void)?
    /// 响应载荷解码失败（诊断）。
    var onDecodeFailure: ((String) -> Void)?
    /// 会话关闭（在途请求已全部失败）。
    var onSessionClosed: (() -> Void)?

    init(session: SyncPeerSession, timeout: TimeInterval = 10) {
        self.session = session
        self.timeout = timeout
        attachHandlers()
    }

    deinit {
        // 实例销毁不得让在途 await 悬挂（契约：超时不得悬挂）。
        cancel()
    }

    // MARK: - 对外 API

    /// 歌单清单（含收藏伪歌单，若对端有收藏）。
    /// 自动翻页（页大小 = 协议上限），总页数有上限（`maxAutoPages`）。
    func fetchPlaylists() async throws -> [SyncPeerPlaylistItem] {
        var collected: [SyncPeerPlaylistItem] = []
        var offset = 0
        var pages = 0
        while true {
            let response = try await requestPage(
                scope: .playlists,
                playlistID: nil,
                query: nil,
                offset: offset,
                limit: SyncPeerLibraryRequestPayload.maxLimit
            )
            collected.append(contentsOf: response.playlistItems)
            pages += 1
            guard response.hasMore, !response.items.isEmpty, pages < Self.maxAutoPages else { break }
            offset += response.items.count
        }
        return collected
    }

    /// 曲库摘要（曲目数 / 总大小）；随任意响应返回，本方法只借一页请求取值。
    func fetchLibrarySummary() async throws -> (trackCount: Int, sizeBytes: Int64) {
        let response = try await requestPage(scope: .tracks, playlistID: nil, query: nil, offset: 0, limit: 1)
        return (response.libraryTrackCount, response.librarySizeBytes)
    }

    /// 曲目分页（`playlistID`/`query` 可空 = 全库；搜索与歌单筛选都在对端执行）。
    func fetchTracks(
        playlistID: String?,
        query: String?,
        offset: Int,
        limit: Int
    ) async throws -> SyncPeerLibraryResponsePayload {
        try await requestPage(
            scope: .tracks,
            playlistID: playlistID,
            query: query,
            offset: offset,
            limit: limit
        )
    }

    /// UI 取消 / 面板关闭：唤醒所有在途请求（抛 `.cancelled`）并停止接收响应。
    /// 幂等；此后本实例不再可用（需要继续用就重建）。
    func cancel() {
        let waiters: [CheckedContinuation<SyncPeerLibraryResponsePayload, Error>]
        lock.lock()
        isActive = false
        waiters = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume(throwing: ClientError.cancelled)
        }
    }

    /// 当前在途请求数（诊断/测试用）。
    var pendingRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    // MARK: - 请求/响应配对

    private func requestPage(
        scope: SyncPeerLibraryScope,
        playlistID: String?,
        query: String?,
        offset: Int,
        limit: Int
    ) async throws -> SyncPeerLibraryResponsePayload {
        guard session.isReady else { throw ClientError.sessionNotReady }
        let requestID = allocateRequestID()
        let request = SyncPeerLibraryRequestPayload(
            scope: scope.rawValue,
            playlistID: playlistID,
            query: query,
            offset: offset,
            limit: limit,
            requestID: requestID
        )
        let payload = try SyncPeerLibraryCodec.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            register(requestID: requestID, continuation: continuation)
            scheduleTimeout(requestID: requestID)
            do {
                try session.sendApplicationFrame(type: .peerLibraryRequest, payload: payload)
            } catch {
                take(requestID: requestID)?.resume(throwing: ClientError.sendFailed("\(error)"))
            }
        }
    }

    private func allocateRequestID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextRequestID
        nextRequestID &+= 1
        return id
    }

    private func register(
        requestID: UInt64,
        continuation: CheckedContinuation<SyncPeerLibraryResponsePayload, Error>
    ) {
        lock.lock()
        guard isActive else {
            lock.unlock()
            continuation.resume(throwing: ClientError.cancelled)
            return
        }
        pending[requestID] = continuation
        lock.unlock()
    }

    /// 取出并移除一个在途请求（取不到 = 已超时/已取消/不匹配 → 丢弃）。
    private func take(requestID: UInt64) -> CheckedContinuation<SyncPeerLibraryResponsePayload, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: requestID)
    }

    private func scheduleTimeout(requestID: UInt64) {
        let seconds = max(timeout, 0)
        timeoutQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.take(requestID: requestID)?.resume(throwing: ClientError.timeout)
        }
    }

    private func handleInboundFrame(_ frame: SyncFrame) {
        guard frame.type == .peerLibraryResponse else { return }
        guard let response = try? SyncPeerLibraryCodec.decode(
            SyncPeerLibraryResponsePayload.self,
            from: frame.payload
        ) else {
            onDecodeFailure?("peer_library_response 解码失败")
            return
        }
        guard let waiter = take(requestID: response.requestID) else {
            // 不匹配（过期/重复/伪造）：丢弃，不影响其它在途请求
            onUnexpectedResponse?(response)
            return
        }
        waiter.resume(returning: response)
    }

    private func failAllPending(_ error: ClientError) {
        let waiters: [CheckedContinuation<SyncPeerLibraryResponsePayload, Error>]
        lock.lock()
        waiters = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    // MARK: 会话槽位挂接（链式：先己后彼；不拆链）

    private func attachHandlers() {
        lock.lock()
        priorAppHandler = session.onApplicationFrame
        priorClosedHandler = session.onClosed
        lock.unlock()
        session.onApplicationFrame = { [weak self] frame in
            guard let self else { return }
            self.lock.lock()
            let enabled = self.isActive
            let prior = self.priorAppHandler
            self.lock.unlock()
            if enabled {
                self.handleInboundFrame(frame)
            }
            prior?(frame)
        }
        session.onClosed = { [weak self] reason in
            guard let self else { return }
            self.lock.lock()
            let prior = self.priorClosedHandler
            self.lock.unlock()
            self.failAllPending(.sessionClosed)
            self.onSessionClosed?()
            prior?(reason)
        }
    }
}
