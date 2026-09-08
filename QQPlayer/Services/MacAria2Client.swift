//
//  MacAria2Client.swift
//  QQPlayer
//
//  aria2 JSON-RPC 客户端（web backend/app/services/download.py 的 _aria2_rpc_call +
//  _download_with_engine aria2 分支移植，2026-09 B1 下载引擎批）。QQPlayer 共享层：
//  Foundation only（禁 AppKit/UIKit，iOS 编译无害），QQPlayerMac target 走 B1A 白名单
//  （pbxproj membershipExceptions）。web 为唯一事实源，语义逐字对齐。
//
//  语义对齐（web services/download.py，此处逐条注释）：
//  - addUri：POST JSON-RPC 2.0，params 顺序固定 = ["token:<secret>", [[url], opts]]
//    （token 在前）；opts = {"dir":…, "out":…}；maxSpeedMbps > 0 → 追加
//    "max-download-limit": "<Int>M"；headers 非空 → 追加 "header": ["k: v", …]
//    （数组，键值原样）
//  - tellStatus：轮询进度。completedLength/totalLength/downloadSpeed 在 aria2 响应里
//    是字符串数字（"12345"），容错解析（字符串/NSNumber 双兼容），缺字段给默认 0
//  - remove：下载超时兜底清理任务（服务层调用，失败忽略）
//  - RPC 响应含 error 字段 → throw（web raise RuntimeError 语义）；code=1（aria2
//    Unauthorized，secret 错误）→ unauthorized；其余 → rpcError(message)；非 JSON/
//    无 result → invalidResponse；连接失败（URLError 等传输层）→ unreachable
//  - 单次请求 timeout 15s；JSON-RPC id 用进程内递增 Int
//
//  结构与 QuarkClient/MusicBrainzClient 同款：struct + init 注入 protocolClasses
//  （URLProtocol mock；[AnyClass] 非 Sendable → 装箱成 @unchecked Sendable 类）。
//  纯逻辑抽到 MacAria2Logic（防回归单测）：请求体/opts 组装、响应解析、header 数组
//  格式化、tellStatus 容错映射。
//

import Foundation

// MARK: - 模型

/// aria2.tellStatus 结果（缺字段给默认；长度/速度字段 aria2 返回字符串数字）
struct Aria2Status: Sendable {
    /// 任务状态：active/waiting/paused/error/complete/removed
    var status: String = ""
    /// 已下载字节
    var completedLength: Int64 = 0
    /// 总字节（未知 = 0，aria2 未取到 Content-Length 时可能为 0）
    var totalLength: Int64 = 0
    /// 下载速度 bytes/s
    var downloadSpeed: Int64 = 0
    /// 失败原因（status=error 时服务端给；缺失 = nil）
    var errorMessage: String?
}

// MARK: - 错误

enum Aria2ClientError: Error, LocalizedError, Equatable {
    /// 连接失败（URLError 等传输层错误 / 非 2xx：本机 daemon 不可达或未启动）
    case unreachable
    /// RPC 返回 error 且 code=1（aria2 Unauthorized = secret 错误）
    case unauthorized
    /// RPC 返回 error（code ≠ 1，携带服务端 message）
    case rpcError(String)
    /// 响应非法（非 JSON 对象 / 缺 result）
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "aria2 RPC 连接失败（daemon 未启动或地址不对）"
        case .unauthorized:
            return "aria2 RPC secret 错误（Unauthorized）"
        case .rpcError(let message):
            return "aria2 RPC 错误：\(message)"
        case .invalidResponse:
            return "aria2 RPC 响应非法"
        }
    }
}

// MARK: - 纯逻辑（web 语义对齐，可单测）

enum MacAria2Logic {
    /// JSON-RPC 请求体组装（web _aria2_rpc_call 的 json 字面量对齐）。
    /// params 需已含 "token:<secret>" 首位（见 rpcCall）。
    static func requestBody(id: Int, method: String, params: [Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    /// addUri options 组装（web _download_with_engine opts 逐字对齐）：
    /// dir/out 恒在；maxSpeedMbps > 0 → "max-download-limit": "<Int>M"；
    /// headers 非空 → "header": ["k: v", …]（键值原样，数组）
    static func addUriOptions(
        dir: String,
        out: String,
        headers: [String: String],
        maxSpeedMbps: Double
    ) -> [String: Any] {
        var opts: [String: Any] = ["dir": dir, "out": out]
        if maxSpeedMbps > 0 {
            opts["max-download-limit"] = "\(Int(maxSpeedMbps))M"
        }
        if !headers.isEmpty {
            opts["header"] = headerArray(from: headers)
        }
        return opts
    }

    /// header 数组格式化（web [f"{k}: {v}" for k, v in headers.items()] 逐字对齐）
    static func headerArray(from headers: [String: String]) -> [String] {
        headers.map { "\($0.key): \($0.value)" }
    }

    /// RPC 响应解析：error 字段 → throw（code=1 → unauthorized，其余 rpcError(message)，
    /// 文案取服务端 message；web raise RuntimeError 语义）；成功 → result 值。
    /// 非 JSON 对象 / 无 result → invalidResponse。
    static func responseResult(from data: Data) throws -> Any {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Aria2ClientError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            let code = error["code"] as? Int
            let message = (error["message"] as? String) ?? "aria2 error"
            if code == 1 {
                throw Aria2ClientError.unauthorized
            }
            throw Aria2ClientError.rpcError(message)
        }
        guard let result = object["result"] else {
            throw Aria2ClientError.invalidResponse
        }
        return result
    }

    /// tellStatus result 容错映射 → Aria2Status（status 非 dict → 全默认；
    /// 长度字段兼容字符串/NSNumber；缺字段给默认）
    static func tellStatus(from result: Any) -> Aria2Status {
        guard let dict = result as? [String: Any] else { return Aria2Status() }
        var status = Aria2Status()
        status.status = (dict["status"] as? String) ?? ""
        status.completedLength = int64Value(dict["completedLength"])
        status.totalLength = int64Value(dict["totalLength"])
        status.downloadSpeed = int64Value(dict["downloadSpeed"])
        status.errorMessage = dict["errorMessage"] as? String
        return status
    }

    /// aria2 长度/速度字段是字符串数字（"12345"），JSONSerialization 也可能给
    /// NSNumber：双兼容，解析失败/缺失 → 0
    static func int64Value(_ value: Any?) -> Int64 {
        if let string = value as? String {
            return Int64(string) ?? 0
        }
        if let number = value as? NSNumber {
            return number.int64Value
        }
        return 0
    }
}

// MARK: - 客户端

/// [AnyClass] 非 Sendable：protocolClasses 装箱成 @unchecked Sendable 类后
/// 结构体其余字段全 Sendable → MacAria2Client 可声明 Sendable
private final class Aria2ProtocolBox: @unchecked Sendable {
    let value: [AnyClass]?
    init(_ value: [AnyClass]?) {
        self.value = value
    }
}

/// JSON-RPC id 进程内递增（跨并发调用安全）
private final class Aria2IDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        current += 1
        return current
    }
}

/// aria2 JSON-RPC 客户端（本机 daemon 默认 http://localhost:6800/jsonrpc）。
/// 每请求临时 ephemeral session（QuarkClient 同款），测试经 protocolClasses 注入
/// URLProtocol mock。
struct MacAria2Client: Sendable {
    /// 默认本机 daemon RPC 地址（web 默认值逐字）
    static let defaultRPCURL = URL(string: "http://localhost:6800/jsonrpc")!
    /// 单次请求超时（web _aria2_rpc_call timeout=10.0 放宽到 15s，大任务排队）
    static let requestTimeout: TimeInterval = 15

    let rpcURL: URL
    let secret: String
    /// 测试注入：URLProtocol mock 类列表（nil = 真实网络）
    private let protocolBox: Aria2ProtocolBox
    private let idBox = Aria2IDBox()

    init(
        rpcURL: URL = MacAria2Client.defaultRPCURL,
        secret: String = "",
        protocolClasses: [AnyClass]? = nil
    ) {
        self.rpcURL = rpcURL
        self.secret = secret
        self.protocolBox = Aria2ProtocolBox(protocolClasses)
    }

    /// 提交下载（web aria2.addUri 语义）：opts 组装见 MacAria2Logic.addUriOptions。
    /// - Returns: aria2 gid（后续 tellStatus/remove 用）。
    func addUri(
        url: String,
        headers: [String: String],
        dir: String,
        out: String,
        maxSpeedMbps: Double
    ) async throws -> String {
        let opts = MacAria2Logic.addUriOptions(
            dir: dir,
            out: out,
            headers: headers,
            maxSpeedMbps: maxSpeedMbps
        )
        // aria2 参数顺序固定：["token:<secret>", [[url], opts]]（web 逐字）
        let result = try await rpcCall(method: "aria2.addUri", params: [[url], opts])
        guard let gid = result as? String, !gid.isEmpty else {
            print("❌ [aria2] addUri 响应无 gid url=\(url.prefix(160))")
            throw Aria2ClientError.invalidResponse
        }
        print("✅ [aria2] addUri 提交 gid=\(gid) url=\(url.prefix(160))")
        return gid
    }

    /// 查询下载状态（web aria2.tellStatus 语义；结果容错解析见 MacAria2Logic.tellStatus）
    func tellStatus(gid: String) async throws -> Aria2Status {
        let result = try await rpcCall(method: "aria2.tellStatus", params: [gid])
        return MacAria2Logic.tellStatus(from: result)
    }

    /// 移除下载任务（web aria2.remove 语义；服务层超时兜底调用，失败忽略）
    func remove(gid: String) async throws {
        _ = try await rpcCall(method: "aria2.remove", params: [gid])
        print("✅ [aria2] remove gid=\(gid)")
    }

    /// 单次 JSON-RPC 调用：POST body → 响应解析（error → throw）。
    /// 传输层错误（URLError 等连接失败/非 2xx）→ unreachable。
    private func rpcCall(method: String, params: [Any]) async throws -> Any {
        let body = MacAria2Logic.requestBody(id: idBox.next(), method: method, params: ["token:\(secret)"] + params)
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = Self.requestTimeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout + 10
        if let protocolClasses = protocolBox.value {
            configuration.protocolClasses = protocolClasses
        }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // 连接失败（URLError）/ 传输层异常 → unreachable（web 降级语义的触发点）
            print("❌ [aria2] RPC 连接失败 url=\(rpcURL.absoluteString) method=\(method) error=\(error)")
            throw Aria2ClientError.unreachable
        }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("❌ [aria2] RPC HTTP \(statusCode) url=\(rpcURL.absoluteString) method=\(method)")
            throw Aria2ClientError.unreachable
        }

        do {
            return try MacAria2Logic.responseResult(from: data)
        } catch let error as Aria2ClientError {
            print("❌ [aria2] RPC error method=\(method) \(error.localizedDescription)")
            throw error
        }
    }
}
