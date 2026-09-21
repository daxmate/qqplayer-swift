//
//  NeteaseOnlineClient+Transport.swift
//  QQPlayer
//
//  网易云在线客户端「网络传输层」分片：`NetworkTransport` 抽象（测试注入用）、
//  真实实现 `URLSessionNetworkTransport`（普通请求 / 302 不跟随取 Location / 流式下载），
//  以及它的两个文件级 private URLSession 委托：`RedirectCapturingDelegate`（302 捕获）与
//  `DownloadProgressDelegate`（进度回调 + 临时文件落盘 + 终态桥 async）。
//
//  2026-09-21 从 NeteaseOnlineClient.swift 原样搬出（纯搬家，无逻辑变更）。
//  ⚠️ 两个委托是文件级 `private` ⇒ 必须与使用者 `URLSessionNetworkTransport` 同片，
//  拆散即触发降级（`RedirectCapturingDelegate` :171 与 `DownloadProgressDelegate` :207
//  的 `private let lock` 是**两个不同类的同名属性**，不是跨区引用）。
//  `NeteaseOnlineLogic` / `NeteaseOnlineError` 在 NeteaseOnlineClient+Logic.swift；
//  模型与 `NeteaseOnlineClient` 客户端在 NeteaseOnlineClient.swift。
//
//  同族写法（网络三连 GequhaiClient / NeteaseOnlineClient / QuarkClient）：
//  「传输层自包自用」——私有助手与其使用者同片 ⇒ 零降级；切法见拆分预研 §2.7 候选 1。
//
import Foundation

// MARK: - 网络传输抽象（测试注入）

protocol NetworkTransport: Sendable {
    /// 普通请求（自动跟随重定向；POST/GET 通用）
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// GET 且不跟随重定向：302 时返回响应头 Location（Meting 直链语义）
    func getWithoutRedirect(url: URL, timeout: TimeInterval) async throws -> (statusCode: Int, headers: [String: String], body: Data)
    /// 流式下载到文件（跟随重定向）；progress 回调 (completed, total) 字节数，
    /// total 未知时传 0 由调用方处理
    func download(
        url: URL,
        to destination: URL,
        timeout: TimeInterval,
        headers: [String: String],
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws
}

/// 重定向捕获 delegate：302 时记录 Location 并取消跟随（Meting 直链）
private final class RedirectCapturingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _redirectLocation: String?

    var redirectLocation: String? {
        lock.lock()
        defer { lock.unlock() }
        return _redirectLocation
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        _redirectLocation = request.url?.absoluteString
        lock.unlock()
        completionHandler(nil) // 取消跟随
    }
}

/// 下载进度 delegate：URLSessionDownloadDelegate 桥 async（进度回调 + 落盘 + 错误）。
/// 生命周期：perform(_:) 挂起 CheckedContinuation，didCompleteWithError（终态回调）恢复；
/// delegate 被 session 弱引用 → 整个请求期间由调用方局部变量强引用保活。
/// ⚠️ didFinishDownloadingTo 返回后系统即删除临时文件：必须当场搬到本方临时目录
/// （保存 URL 供恢复后再读会踩已删除文件——2026-09 B1 进度改造时规避）。
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// 下载结果（临时文件已搬到本方 staging 目录 + 原始响应）
    struct DownloadOutcome {
        var temporaryURL: URL
        var response: URLResponse?
    }

    private let progress: (@Sendable (Int64, Int64) -> Void)?
    private let lock = NSLock()
    private var stagedURL: URL?
    private var continuation: CheckedContinuation<DownloadOutcome, Error>?

    init(progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.progress = progress
    }

    /// 发起下载任务并等待终态（didCompleteWithError 恢复）
    func perform(_ task: URLSessionDownloadTask) async throws -> DownloadOutcome {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            task.resume()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let progress else { return }
        // total 未知（NSURLSessionTransferSizeUnknown=-1）→ 传 0（调用方处理）
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        progress(totalBytesWritten, total)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 临时文件在本方法返回后即被系统删除：立刻搬到本方 staging 目录（同卷 move 便宜）
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("QQPlayerDL-\(UUID().uuidString).part")
        try? FileManager.default.moveItem(at: location, to: staged)
        lock.lock()
        stagedURL = staged
        lock.unlock()
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let staged = stagedURL
        stagedURL = nil
        let continuation = self.continuation
        self.continuation = nil
        let taskResponse = task.response
        lock.unlock()

        guard let continuation else { return }
        if let error {
            if let staged {
                try? FileManager.default.removeItem(at: staged)
            }
            continuation.resume(throwing: error)
            return
        }
        guard let staged else {
            continuation.resume(throwing: NeteaseOnlineError.invalidResponse)
            return
        }
        continuation.resume(returning: DownloadOutcome(temporaryURL: staged, response: taskResponse))
    }
}

/// URLSession 实现（macOS 13+/iOS 均可用）
struct URLSessionNetworkTransport: NetworkTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NeteaseOnlineError.invalidResponse
        }
        return (data, http)
    }

    func getWithoutRedirect(
        url: URL,
        timeout: TimeInterval
    ) async throws -> (statusCode: Int, headers: [String: String], body: Data) {
        let delegate = RedirectCapturingDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 10
        // delegate 被 session 弱引用：整个请求期间持有强引用
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NeteaseOnlineError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        if let redirect = delegate.redirectLocation, headers["Location"] == nil {
            headers["Location"] = redirect
        }
        return (http.statusCode, headers, data)
    }

    func download(
        url: URL,
        to destination: URL,
        timeout: TimeInterval,
        headers: [String: String],
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        // 诊断打点（2026-09-08 歌曲海下载 412/auth miss 排查）：记录实际发出的
        // 请求头概况（Cookie 只打长度不打值）与 URL 前缀，对照直链签名绑定。
        let headerSummary = headers.keys.sorted().map { key -> String in
            let value = headers[key] ?? ""
            if key == "Cookie" {
                return "Cookie=<长度\(value.count)>"
            }
            return "\(key)=\(value)"
        }.joined(separator: ", ")
        AppLog.info(.scrape, "ℹ️ [网络下载] urlHost=\(url.host ?? "?") url=\(url.absoluteString.prefix(140))… headers=\(headerSummary)")

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // delegate 实现拿 didWriteData 进度；临时文件由 delegate 当场搬到 staging
        // （URLSession.shared.download 拿不到进度回调，2026-09 B1 进度圆环打基础）
        let delegate = DownloadProgressDelegate(progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 10
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let temporaryURL: URL
        let statusCode: Int
        let outcome = try await delegate.perform(session.downloadTask(with: request))
        temporaryURL = outcome.temporaryURL
        statusCode = (outcome.response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(statusCode) else {
            // 诊断打点（2026-09-08）：非 2xx 读响应体——夸克 CDN 403 返回 XML
            // （如 "require login [auth miss]"），仅打状态码无法区分原因。
            if let body = try? String(contentsOf: temporaryURL, encoding: .utf8) {
                AppLog.error(.scrape, "❌ [网络下载] HTTP \(statusCode) body=\(body.prefix(300))")
            } else {
                AppLog.error(.scrape, "❌ [网络下载] HTTP \(statusCode)（响应体不可读）")
            }
            try? FileManager.default.removeItem(at: temporaryURL)
            throw NeteaseOnlineError.httpError(statusCode)
        }
        // 只清理确实存在的 .part 残留（上次中断下载留下的同名文件）：
        // 之前无条件 removeItem，正常无残留时抛 ENOENT(NSFileNoSuchFileError)，
        // 导致每次下载都在落盘前失败（2026-09-05 线上日志定位）。
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }
}
