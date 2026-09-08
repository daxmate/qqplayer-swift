//
//  QuarkClient.swift
//  QQPlayer
//
//  夸克网盘客户端（web 版 backend/quark_provider.py 538 行移植，E2 下载批 2026-09）。
//  QQPlayer 共享层：Services 文件 iOS 也编译（禁 AppKit/UIKit），QQPlayerMac target
//  走 B1A 白名单（pbxproj membershipExceptions）。web 为唯一事实源，语义逐字对齐。
//
//  语义对齐（web quark_provider.py，此处逐条注释）：
//  - 扫码登录：login_qrcode()（uop.quark.cn，浏览器 UA）生成二维码内容 →
//    login_status(qr_id) 由调用方每 2s 轮询（本层只做单次查询）→ 扫码成功拿
//    service_ticket → GET pan.quark.cn/account/info 换会话 Cookie → 持久化到本地文件
//  - Cookie 持久化：会话 cookie 存 Application Support/QQPlayerMac/quark_cookies.json
//    （0600 权限原子写；web _persist_cookies 语义）。每次请求都从文件重载 cookie，
//    登录态变更（扫码/退出）立即可见（web _get_drive_client 语义）
//  - 分享解析：resolve_share(share_url) 匿名列文件（sharepage/token + sharepage/detail，
//    目录型分享递归进入深度 ≤3、翻页、fid 去重）；分享失败返回空数组不抛（web 语义）
//  - ⚠️ stoken 绑定 share_fid_token：下载直链必须用同一次 resolve_share_verbose 返回的
//    stoken（新 stoken + 旧 fid_token → 41020 转存文件token校验异常）
//  - 音质挑选 pick_file：mp3（默认）/ flac 可选，找不到偏好格式自动降级，
//    最后兜底任何音频扩展；同格式多个取 size 最大（纯逻辑，可单测）
//  - 下载直链 get_download_url：登录后把分享文件换成签名直链（~10min 有效）。
//    ⚠️ web 自己标注未真实联调（无真实登录 cookie 无法离线验证）；实现参照 alist
//    quark_uc 驱动（POST /1/clouddrive/file/download）请求约定。真实联调由 maintainer
//    扫码登录后完成，本批所有网络路径经 URLProtocol mock 验证，不发真实网络
//  - refresh_puus()：发一次不带 __puus 的 GET /1/clouddrive/config（alist#830 方案）
//    触发服务端重新下发 __puus；只有确认重新下发才持久化；失败静默（web 语义）
//  - 401/403 不删 cookie 文件（保留现场便于诊断；web 注释：可能是凭证不全或参数问题，
//    未必是登录失效；删文件会导致扫码-下载-重扫死循环）
//
//  结构与 MusicBrainzClient 同款：struct + init 注入 protocolClasses（URLProtocol mock）
//  + sleep（预留节流钩子；web quark provider 无内部 sleep——扫码 2s 轮询由调用方负责，
//  本层 sleep 仅对齐既有骨架，暂无非零调用点）+ cookieFileURL 注入（便于测试）。
//
//  纯逻辑抽到 QuarkLogic（防回归单测）：share token 提取、扩展名、目录判定、
//  pick_file 降级决策、Set-Cookie 解析、cookie 序列化/反序列化（含损坏兜底）。
//  网络层每请求自带 UA/Referer（web 逐字段）；单次请求失败抛 QuarkClientError
//  （LocalizedError），绝不静默吞（resolve 汇总层的空数组是 web 语义，非吞错）。
//

import Foundation

// MARK: - 模型

/// 夸克分享文件条目（web resolve_share 返回 dict 结构对齐）
struct QuarkShareFile: Equatable, Sendable {
    var fid: String
    var fileName: String
    var size: Int64
    var formatType: String      // 小写（web item["format_type"] or ""）.lower() 对齐
    var shareFidToken: String   // 绑定本次 stoken；web share_fid_token or fid_token or ""
    var ext: String             // 小写带点扩展名（web _ext_of(file_name)），无 → ""
}

/// 扫码登录二维码（web login_qrcode 返回对齐；qrID 供 loginStatus(qrID:) 轮询）
struct QuarkQRCode: Equatable, Sendable {
    var qrID: String           // web str(uuid.uuid4())（含连字符）
    var contentURL: String     // 二维码内容（su.quark.cn weblogin 流程，逐字对齐 web）
    var expiresIn: Int         // web QR_EXPIRE_SECONDS = 170
}

/// 扫码登录状态（web login_status 返回 {status, nickname, message} 对齐）。
/// status 取值与 web 字符串一致："waiting" / "ok" / "expired" / "error"。
struct QuarkLoginStatus: Equatable, Sendable {
    enum State: String, Sendable {
        case waiting
        case ok
        case expired
        case error
    }

    var state: State
    var nickname: String?
    var message: String?

    static func waiting() -> QuarkLoginStatus {
        QuarkLoginStatus(state: .waiting, nickname: nil, message: nil)
    }

    static func ok(nickname: String?) -> QuarkLoginStatus {
        QuarkLoginStatus(state: .ok, nickname: nickname, message: nil)
    }

    static func expired(message: String) -> QuarkLoginStatus {
        QuarkLoginStatus(state: .expired, nickname: nil, message: message)
    }

    static func error(message: String) -> QuarkLoginStatus {
        QuarkLoginStatus(state: .error, nickname: nil, message: message)
    }
}

/// 下载直链（web get_download_url 返回 (download_url, download_headers) 对齐）。
/// urlString 保持原样（web 返回字符串）；下载头快照与获取直链时的请求一致
/// （UA/Cookie/Referer）——直链签名绑定它们，下载必须原样携带（否则 412）。
struct QuarkDownload: Equatable, Sendable {
    var urlString: String
    var headers: [String: String]
}

// MARK: - 错误（LocalizedError，UI 直接展示 errorDescription；文案对齐 web）

enum QuarkClientError: Error, LocalizedError, Equatable {
    /// 无效的夸克分享链接（web ValueError("无效的夸克分享链接: {url}")）
    case invalidShareURL(String)
    /// 未登录 / cookie 失效（web RuntimeError("quark login required")，文案原文）
    case loginRequired
    /// 非 2xx HTTP（web raise_for_status）
    case httpStatus(Int)
    /// 响应非 JSON / 结构非法（web .json() ValueError / KeyError 冒泡语义）
    case invalidResponse
    /// 业务错误（web RuntimeError(f"{前缀}: {message}")）；message 已含前缀完整文案
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidShareURL(let url):
            return "无效的夸克分享链接: \(url)"
        case .loginRequired:
            return "quark login required"
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .invalidResponse:
            return "invalid response"
        case .serverMessage(let message):
            return message
        }
    }
}

// MARK: - 纯逻辑（web 语义对齐，可单测）

enum QuarkLogic {
    /// query 值表单编码（web urllib.parse.urlencode → quote_plus 语义）：
    /// 保留 ALPHA/DIGIT/-._~，空格 → '+',其余（含 + / =）百分号编码。
    static func formQueryValue(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~ ")
        let kept = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return kept.replacingOccurrences(of: " ", with: "+")
    }
    /// 可接受的音频扩展（web AUDIO_EXTS，小写带点）
    static let audioExtensions: Set<String> = [
        ".mp3", ".flac", ".m4a", ".wav", ".ape", ".ogg", ".aac", ".wma", ".opus",
    ]

    /// 夸克分享 URL 正则（web _SHARE_URL_RE = pan\.quark\.cn/s/([0-9A-Za-z]+)，IGNORECASE）
    private static let shareURLRegex = try? NSRegularExpression(
        pattern: #"pan\.quark\.cn/s/([0-9A-Za-z]+)"#,
        options: [.caseInsensitive]
    )

    // MARK: 分享 URL → pwd_id（web _pwd_id_from_url；规范化：容忍首尾空白/大小写/前后缀）

    /// 从夸克分享 URL 提取 pwd_id（web _SHARE_URL_RE 提取，去首尾空白后匹配）；
    /// 非夸克分享链接 / 提取不出 → nil（web ValueError 语义，由调用方决定抛错或兜底）。
    static func shareToken(from shareURL: String) -> String? {
        let trimmed = shareURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let regex = shareURLRegex else { return nil }
        let ns = trimmed as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        let token = ns.substring(with: match.range(at: 1))
        return token.isEmpty ? nil : token
    }

    // MARK: 扩展名（web _ext_of：Path(file_name).suffix.lower()）

    /// 从文件名取小写扩展名（带点，如 ".mp3"；无扩展名返回 ""）——web Path.suffix 语义
    static func extensionOf(fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        guard !ext.isEmpty else { return "" }
        return "." + ext.lowercased()
    }

    // MARK: 分享列表目录判定（web _is_dir_item）

    /// 判断分享列表原始 JSON 项是否为目录（web _is_dir_item）：
    /// dir 布尔字段优先（社区 quark-share-downloader 只认它）→ format_type 字符串
    /// ("folder"/"dir") 兜底 → file_type 字符串 ("dir"/"folder") 兜底。
    /// file_type 数字语义不稳定（实测文件=1），不作为判据（web 注释对齐）。
    static func rawIsDirectory(_ item: [String: Any]) -> Bool {
        if let dir = item["dir"] as? Bool {
            return dir
        }
        if let format = item["format_type"] as? String {
            let normalized = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "folder" || normalized == "dir" {
                return true
            }
        }
        if let fileType = item["file_type"] as? String {
            let normalized = fileType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "dir" || normalized == "folder"
        }
        return false
    }

    // MARK: 音质挑选（web pick_file）

    /// 按音质偏好挑文件（web pick_file 逐字对齐）：
    /// quality="flac" → 优先 .flac；否则优先 .mp3（也可接受 .m4a/.wav 等音频扩展）。
    /// 找不到偏好格式 → 降级另一格式 → 再兜底任何 AUDIO_EXTS；全无 → nil。
    /// 同格式多个取 size 最大（并列取先出现者——Python max 语义，非 Swift 默认末位）。
    static func pickFile(_ files: [QuarkShareFile], quality: String?) -> QuarkShareFile? {
        guard !files.isEmpty else { return nil }
        let preferFlac = (quality ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "flac"
        let primary = preferFlac ? ".flac" : ".mp3"
        let fallback = preferFlac ? ".mp3" : ".flac"

        var candidates = files.filter { resolvedExtension(of: $0) == primary }
        if candidates.isEmpty {
            candidates = files.filter { resolvedExtension(of: $0) == fallback }
        }
        if candidates.isEmpty {
            candidates = files.filter { audioExtensions.contains(resolvedExtension(of: $0)) }
        }
        guard !candidates.isEmpty else { return nil }
        // Python max 并列返回先出现者：仅当严格大于当前 best 才替换
        var best: QuarkShareFile?
        for file in candidates {
            if best == nil || file.size > best!.size {
                best = file
            }
        }
        return best
    }

    /// pick_file 用的扩展名判定（web 内层 _ext：f.get("ext") or 文件名后缀小写）
    static func resolvedExtension(of file: QuarkShareFile) -> String {
        if !file.ext.isEmpty {
            return file.ext
        }
        return extensionOf(fileName: file.fileName)
    }

    // MARK: Set-Cookie 解析（httpx 自动收 Set-Cookie 语义；URLSession 需手动）

    /// 解析一个或多个 Set-Cookie 响应头 → cookie 字典（后出现者覆盖同名）。
    /// URLSession 会把同名的多个 Set-Cookie 头以 ", " 拼成一条字符串：用
    /// "逗号后紧跟 cookie名=" 的位置切分，避开 Expires 等属性值里的日期逗号
    /// （"Wed, 21 Oct 2015 ..." 的逗号后不是 name=，不会误切）。
    static func parseSetCookieHeaders(_ headers: [String]) -> [String: String] {
        var jar: [String: String] = [:]
        for header in headers {
            for segment in splitCookieSegments(header) {
                guard let eq = segment.firstIndex(of: "=") else { continue }
                let name = String(segment[..<eq]).trimmingCharacters(in: .whitespaces)
                // 合法 cookie 名不含 ;/,/空白（属性段如 "; Path=/" 是无 name 的垃圾，
                // 直接跳过——web httpx 对这类头也会忽略）
                guard !name.isEmpty,
                      !name.contains(";"),
                      !name.contains(","),
                      !name.contains(" ") else { continue }
                var value = String(segment[segment.index(after: eq)...])
                if let semicolon = value.firstIndex(of: ";") {
                    value = String(value[..<semicolon])
                }
                jar[name] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        return jar
    }

    /// 把可能含多条 cookie 的头按边界切成单条段；无边界 → 原样单段。
    private static func splitCookieSegments(_ header: String) -> [String] {
        let pattern = #",\s*(?=[^,;=\s]+=)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return header.isEmpty ? [] : [header]
        }
        let ns = header as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: header, range: fullRange)
        guard !matches.isEmpty else {
            return header.isEmpty ? [] : [header]
        }
        var segments: [String] = []
        var cursor = header.startIndex
        for match in matches {
            guard let boundary = Range(match.range, in: header) else { continue }
            if boundary.lowerBound > cursor {
                segments.append(String(header[cursor ..< boundary.lowerBound]))
            }
            cursor = boundary.upperBound
        }
        if cursor < header.endIndex {
            segments.append(String(header[cursor...]))
        }
        return segments.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Cookie 文件序列化（web json.loads/dumps 语义；损坏兜底）

    /// [String: String] → JSON Data（web json.dumps(cookies, indent=2)；字典序稳定输出）
    static func cookiesData(_ cookies: [String: String]) -> Data? {
        guard !cookies.isEmpty else {
            // 空字典也要能持久化（web json.dumps({})）
            return try? JSONSerialization.data(withJSONObject: [String: String](), options: [.prettyPrinted, .sortedKeys])
        }
        return try? JSONSerialization.data(withJSONObject: cookies, options: [.prettyPrinted, .sortedKeys])
    }

    /// JSON Data → cookie 字典；非 dict 根 / 非字符串值 / 损坏 → nil（调用方兜底为空）
    static func cookies(from data: Data) -> [String: String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var result: [String: String] = [:]
        for (key, value) in obj {
            if let text = value as? String {
                result[key] = text
            } else {
                return nil
            }
        }
        return result
    }

    /// Cookie 字典 → "k=v; k2=v2" 头字符串（空 → ""；web "; ".join 语义）
    static func cookieHeader(_ cookies: [String: String]) -> String {
        // 字典序输出保证确定性（web 顺序无关；测试与抓包稳定）
        cookies.keys.sorted().map { "\($0)=\(cookies[$0] ?? "")" }.joined(separator: "; ")
    }
}

// MARK: - qr_id → 二维码 token 进程内映射（web 模块级 _QR_TOKENS）

/// 扫码 token 存储：qr_id → token（进程内有效；进程重启后查不到 → loginStatus
/// 返回 error「登录会话已失效」——web 语义）。class box 引用语义：struct 值拷贝间
/// 共享（web 是模块级全局 dict；Swift 侧要求调用方对 loginQRCode/loginStatus 使用
/// 同一 QuarkClient 实例——批量下载等长生命周期服务持有单实例即可）。
private final class QuarkQRTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    func store(_ qrID: String, _ token: String) {
        lock.lock()
        defer { lock.unlock() }
        tokens[qrID] = token
    }

    func token(for qrID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tokens[qrID]
    }

    func remove(_ qrID: String) {
        lock.lock()
        defer { lock.unlock() }
        tokens.removeValue(forKey: qrID)
    }
}

// MARK: - 客户端

struct QuarkClient {
    // MARK: 常量（web quark_provider.py 逐字对齐）

    /// 夸克客户端 UA：服务器校验，非客户端 UA 部分接口返回 404 混淆（web 注释原文）
    static let quarkClientUA = (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 "
            + "Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    )
    /// 浏览器 UA：仅用于 uop.quark.cn 扫码登录流程（网页端 weblogin）
    static let browserUA = (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )

    static let driveAPIBase = "https://drive-pc.quark.cn/1/clouddrive"
    static let panBase = "https://pan.quark.cn"
    static let uopBase = "https://uop.quark.cn"
    static let qrScanPage = "https://su.quark.cn/4_eMHBJ"
    static let referer = "https://pan.quark.cn/"
    static let qrClientID = "532"
    static let qrExpireSeconds = 170          // 二维码 TTL（服务端 ~170s）
    static let poolTimeout: TimeInterval = 15.0
    static let maxShareDepth = 3              // 目录递归深度上限，防炸
    static let sharePageSize = 50

    /// Cookie 文件默认路径：Application Support/QQPlayerMac/quark_cookies.json
    /// （与 DatabasePathResolver macDatabaseURL 同目录惯例；web 存 Application
    /// Support/qqplayer——Mac 端沿用 QQPlayerMac 目录）。路径注入便于测试。
    /// ⚠️ 本默认值仅供 macOS 运行期使用：iOS 沙盒无 homeDirectoryForCurrentUser
    /// （macOS-only API），fallback 用临时目录保证双平台可编译（iOS 不调用默认值）。
    static func defaultCookieFileURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("QQPlayerMac", isDirectory: true)
            .appendingPathComponent("quark_cookies.json")
    }

    // MARK: 注入点（MusicBrainzClient 骨架同款）

    /// 供测试注入的时钟/休眠（web quark provider 无内部 sleep——扫码 2s 轮询由
    /// 调用方负责；保留骨架，当前无非零调用点，测试注入 no-op）
    var sleep: (TimeInterval) async throws -> Void

    /// 测试注入：URLProtocol mock 类列表（nil = 真实网络）。网络请求每次临时构造
    /// URLSession（ephemeral + 手动 Cookie 管理），无法注入现成 session，故注入
    /// protocolClasses（MusicBrainzClient 同款）。
    private let protocolClasses: [AnyClass]?

    /// Cookie 文件路径（注入便于测试；默认 App Support/QQPlayerMac/quark_cookies.json）
    let cookieFileURL: URL

    /// qr_id → token 进程内映射（web 模块级 _QR_TOKENS）
    private let qrTokens = QuarkQRTokenBox()

    init(
        sleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        cookieFileURL: URL = QuarkClient.defaultCookieFileURL(),
        protocolClasses: [AnyClass]? = nil
    ) {
        self.sleep = sleep
        self.cookieFileURL = cookieFileURL
        self.protocolClasses = protocolClasses
    }

    // MARK: - 扫码登录（web login_qrcode / login_status / login_state / logout）

    /// 生成扫码登录二维码（web login_qrcode）。
    ///
    /// 流程：uuid4 request_id → GET uop.quark.cn/cas/ajax/getTokenForQrcodeLogin
    /// （client_id=532, v=1.2）拿 token → 生成本地 qr_id 并记住 token →
    /// 组装网页端 weblogin 二维码内容 URL（逐字对齐 web）。
    /// - Returns: 二维码内容 + qrID（供 loginStatus(qrID:) 轮询）+ TTL。
    /// - Throws: token 缺失 / 非 2xx / JSON 非法（web 均冒泡 500，不静默）。
    func loginQRCode() async throws -> QuarkQRCode {
        let url = Self.url(Self.uopBase, "/cas/ajax/getTokenForQrcodeLogin", query: [
            "client_id": Self.qrClientID,
            "v": "1.2",
            "request_id": Self.randomHex32(),
        ])
        let payload = try await getJSON(url: url, headers: Self.anonHeaders())
        let members = (payload["data"] as? [String: Any])?["members"] as? [String: Any]
        let token = members?["token"] as? String
        guard let token, !token.isEmpty else {
            let message = payload["message"] as? String ?? ""
            let detail = message.isEmpty ? "\(payload)" : message
            throw QuarkClientError.serverMessage("获取扫码 token 失败: \(detail)")
        }

        let qrID = UUID().uuidString
        qrTokens.store(qrID, token)

        // 二维码内容 URL（web f-string 逐字：uc_biz_str 已按服务端要求编码）
        let content = "\(Self.qrScanPage)?token=\(token)&client_id=\(Self.qrClientID)&ssb=weblogin"
            + "&uc_param_str=&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400"
        return QuarkQRCode(qrID: qrID, contentURL: content, expiresIn: Self.qrExpireSeconds)
    }

    /// 单次查询扫码状态（web login_status；web 前端每 2s 调一次，Swift 侧由调用方轮询）。
    ///
    /// 状态机：unknown qr_id → error「登录会话已失效」；status=2000000 → 拿
    /// service_ticket 换会话 Cookie（成功即持久化）→ ok；50004001 → waiting；
    /// 50004002 → expired（弹出 token）；其余 → error。
    /// 首查 HTTP/传输错误折成 error 状态（web 返回 error 状态）；ticket 交换阶段
    /// 与 JSON 解析错误抛出（web _exchange_ticket 在 login_status 的 try 之外，
    /// 异常冒泡 500 对齐——由调用方捕获展示）。
    func loginStatus(qrID: String) async throws -> QuarkLoginStatus {
        guard let token = qrTokens.token(for: qrID) else {
            return .error(message: "登录会话已失效，请重新扫码")
        }
        let url = Self.url(Self.uopBase, "/cas/ajax/getServiceTicketByQrcodeToken", query: [
            "client_id": Self.qrClientID,
            "v": "1.2",
            "request_id": Self.randomHex32(),
            "token": token,
        ])
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.poolTimeout
        for (key, value) in Self.anonHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await perform(request)
        } catch {
            // 传输层错误 → error 状态（web except httpx.HTTPError 折 error 对齐）
            return .error(message: "轮询扫码状态失败: \(error.localizedDescription)")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            return .error(message: "轮询扫码状态失败: HTTP \(http.statusCode)")
        }
        let payload = try Self.decode(data)   // JSON 非法 → 抛出（web ValueError 冒泡对齐）

        switch (payload["status"] as? NSNumber)?.intValue {
        case 2_000_000:
            // 扫码成功：拿 service_ticket 换会话 Cookie（web _exchange_ticket）
            let members = (payload["data"] as? [String: Any])?["members"] as? [String: Any]
            let ticket = members?["service_ticket"] as? String
            guard let ticket, !ticket.isEmpty else {
                return .error(message: "登录响应缺少 service_ticket")
            }
            return try await exchangeTicket(ticket)
        case 50_004_001:
            return .waiting()
        case 50_004_002:
            qrTokens.remove(qrID)
            return .expired(message: "二维码已过期，请重新扫码")
        default:
            if let message = payload["message"] as? String, !message.isEmpty {
                return .error(message: message)
            }
            let statusValue = (payload["status"] as? NSNumber)?.intValue
            // web f"未知状态: {status}"：缺失打印 None（对齐 Python None 文案）
            let unknown = statusValue.map(String.init) ?? "None"
            return .error(message: "未知状态: \(unknown)")
        }
    }

    /// 检查是否已登录（web login_state）：cookie 文件存在且冒烟通过
    /// （GET pan.quark.cn/account/info 200 且 success）才算 logged_in。
    /// 非 200 / success=false → 清掉失效 cookie（web 手动检查状态码，无 raise）；
    /// JSON 解析失败/网络抖动 → 保留文件下次再试（web except ValueError/HTTPError 对齐）。
    func loginState() async -> (loggedIn: Bool, nickname: String?) {
        guard cookieFileExists else {
            return (false, nil)
        }
        let url = Self.url(Self.panBase, "/account/info", query: [:])
        let request = makeRequest(url: url, headers: driveHeaders())
        do {
            let (data, http) = try await perform(request)
            if http.statusCode == 200 {
                if let payload = try? Self.decode(data) {
                    if payload["success"] as? Bool == true {
                        let nickname = (payload["data"] as? [String: Any])?["nickname"] as? String
                        return (true, nickname)
                    }
                    // success=false → cookie 已失效（web _clear_cookie_file 对齐）
                    deleteCookieFile()
                }
                // JSON 解析失败 → 保留文件（web except ValueError 对齐）
            } else {
                // 401 / 非 200 → cookie 已失效（web login_state 手动检查对齐）
                deleteCookieFile()
            }
        } catch {
            // 网络抖动等瞬时错误：不删 cookie，下次再试（web except HTTPError 对齐）
        }
        return (false, nil)
    }

    /// 退出登录：删除本地 cookie 文件（web logout）
    func logout() {
        deleteCookieFile()
    }

    /// 用 service_ticket 换会话 Cookie（web _exchange_ticket）：
    /// GET pan.quark.cn/account/info?st=&lw=scan（匿名浏览器 UA，收 Set-Cookie），
    /// 成功后把响应 cookie 持久化（新登录整体替换旧文件——web 用全新 client 语义）。
    /// - Throws: 非 2xx / JSON 非法（web 冒泡 500 对齐）。
    private func exchangeTicket(_ ticket: String) async throws -> QuarkLoginStatus {
        let url = Self.url(Self.panBase, "/account/info", query: ["st": ticket, "lw": "scan"])
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.poolTimeout
        for (key, value) in Self.anonHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, http) = try await perform(request)
        guard (200 ..< 300).contains(http.statusCode) else {
            throw QuarkClientError.httpStatus(http.statusCode)
        }
        let payload = try Self.decode(data)
        guard payload["success"] as? Bool == true else {
            let message = payload["message"] as? String ?? ""
            return .error(message: message.isEmpty ? "扫码登录失败" : message)
        }
        // 全新匿名客户端只收到本次响应的 Set-Cookie（web 语义）→ 整体替换落盘
        let setCookieHeaders = Self.setCookieHeaderValues(from: http)
        let jar = QuarkLogic.parseSetCookieHeaders(setCookieHeaders)
        try saveCookies(jar)
        let nickname = (payload["data"] as? [String: Any])?["nickname"] as? String
        return .ok(nickname: nickname)
    }

    // MARK: - 分享解析（匿名；web resolve_share / resolve_share_verbose）

    /// 匿名解析夸克分享链接（不需要登录）→ 文件列表（web resolve_share）。
    /// 目录型分享递归进入（深度 ≤3）；无文件/任何失败 → []（web 语义，不抛）。
    func resolveShare(_ shareURL: String) async -> [QuarkShareFile] {
        let (files, _) = await resolveShareVerbose(shareURL)
        return files
    }

    /// resolveShare + 本次解析使用的 stoken（web resolve_share_verbose）。
    ///
    /// ⚠️ share_fid_token 绑定本次 stoken：下载直链必须用同一个 stoken
    /// （新 stoken + 旧 fid_token → 41020 转存文件token校验异常）。
    /// 失败返回 ([], "")（web 语义，不抛）。
    func resolveShareVerbose(_ shareURL: String) async -> (files: [QuarkShareFile], stoken: String) {
        do {
            guard let pwdID = QuarkLogic.shareToken(from: shareURL) else {
                throw QuarkClientError.invalidShareURL(shareURL)
            }
            let stoken = try await fetchShareStoken(pwdID: pwdID)
            var files: [QuarkShareFile] = []
            var seen: Set<String> = []
            try await walkShare(
                pwdID: pwdID, stoken: stoken, pdirFid: "0", depth: 1,
                files: &files, seen: &seen
            )
            print("✅ [夸克 resolve] 分享解析成功 shareURL=\(shareURL) files=\(files.count) stoken=\(stoken.prefix(8))…")
            return (files, stoken)
        } catch {
            // 诊断打点（2026-09-08 歌曲海下载 shareEmptyOrExpired 排查）：
            // resolve 失败原因曾被完全吞掉（web 语义失败返回空数组），UI 只能看到
            // shareEmptyOrExpired；这里把真实环节错误打出来（invalidShareURL /
            // stoken 获取失败 HTTP/目录列表失败/业务 message 等）。
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            print("❌ [夸克 resolve] 分享解析失败 shareURL=\(shareURL) error=\(detail)")
            return ([], "")
        }
    }

    // MARK: - 下载直链（登录后；web get_download_url）

    /// 登录后把分享文件换成签名直链（~10min 有效）。
    ///
    /// stoken 必须与 shareFidToken 同源（来自同一次 resolveShareVerbose）。
    /// 未登录（cookie 文件不存在/已失效）抛 loginRequired；401/403 同样抛
    /// loginRequired 但**不删 cookie 文件**（保留现场便于诊断，web 注释原文）。
    /// 实现对齐社区 quark-share-downloader（POST /file/download，fids/fids_token）。
    func getDownloadURL(
        shareURL: String,
        fid: String,
        shareFidToken: String,
        stoken: String
    ) async throws -> QuarkDownload {
        guard cookieFileExists else {
            throw QuarkClientError.loginRequired
        }
        // 会话保活（2026-09-08 歌曲海下载 403 auth miss 修复）：扫码登录只存
        // 6 个 cookie，下载 CDN 校验需要的 __puus 仅由 /config 接口 Set-Cookie
        // 下发（Max-Age 24h）；refreshPUUS 此前定义了但从未被调用 → 下载必然
        // auth miss。每次取直链前刷一次保活（失败静默，不影响主流程）。
        await refreshPUUS()
        guard let pwdID = QuarkLogic.shareToken(from: shareURL) else {
            throw QuarkClientError.invalidShareURL(shareURL)
        }
        let jar = loadCookies()
        var headers = driveHeaders(cookies: jar)
        headers["Origin"] = "https://pan.quark.cn"
        headers["Content-Type"] = "application/json"

        let url = Self.url(Self.driveAPIBase, "/file/download", query: [
            "entry": "ft", "fr": "pc", "pr": "ucpro",
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.poolTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "fids": [fid],
            "fids_token": [shareFidToken],
            "pwd_id": pwdID,
            "stoken": stoken,
        ])
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, http) = try await perform(request)

        if http.statusCode == 401 || http.statusCode == 403 {
            // ⚠️ 不删 cookie 文件：401/403 可能是凭证不全或参数问题，未必是登录失效；
            // 删文件会导致扫码-下载-重扫死循环（web 注释原文）
            // 诊断打点（2026-09-08）：403 body 常含真实原因（如 41020 token 校验异常）
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            print("❌ [夸克直链] 取直链被拒 status=\(http.statusCode) body=\(bodyPreview)")
            throw QuarkClientError.loginRequired
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            print("❌ [夸克直链] 取直链 HTTP 失败 status=\(http.statusCode) body=\(bodyPreview)")
            throw QuarkClientError.httpStatus(http.statusCode)
        }
        let payload = try Self.decode(data)
        // web 成功判定：status != 200 且 code != 0 才失败（缺省值按 web None 语义：
        // None != 200 / None != 0 均为 True → 视为失败）
        let statusCode = (payload["status"] as? NSNumber)?.intValue
        let businessCode = (payload["code"] as? NSNumber)?.intValue
        if statusCode != 200 && businessCode != 0 {
            let message = payload["message"] as? String ?? ""
            print("❌ [夸克直链] 取直链业务失败 status=\(statusCode ?? -1) code=\(businessCode ?? -1) message=\(message)")
            let detail = message.isEmpty ? "" : ": \(message)"
            throw QuarkClientError.serverMessage("获取下载直链失败\(detail)")
        }
        guard let list = payload["data"] as? [Any],
              let first = list.first as? [String: Any],
              let downloadURLString = first["download_url"] as? String,
              !downloadURLString.isEmpty else {
            throw QuarkClientError.serverMessage("下载直链响应缺少 download_url")
        }
        // 下载头快照：与获取直链的请求一致（UA/Cookie/Referer/Origin），
        // 直链签名绑定它们（否则 412 Precondition Failed，web 注释原文）
        let downloadHeaders: [String: String] = [
            "User-Agent": Self.quarkClientUA,
            "Referer": Self.referer,
            "Origin": "https://pan.quark.cn",
            "Cookie": QuarkLogic.cookieHeader(jar),
        ]
        // 诊断打点（2026-09-08）：Cookie 值不打（日志卫生），只打是否携带；
        // url 截断（签名 URL 含 token，全量无意义且刷屏）
        print("✅ [夸克直链] 取直链成功 url=\(downloadURLString.prefix(140))… cookie=\(downloadHeaders["Cookie"]?.isEmpty == false ? "携带(\(downloadHeaders["Cookie"]?.count ?? 0)字符)" : "无")")
        return QuarkDownload(urlString: downloadURLString, headers: downloadHeaders)
    }

    // MARK: - 会话 cookie 刷新（web refresh_puus）

    /// 刷新 __puus 会话 cookie（约 2h 过期）：发一次不带 __puus 的
    /// GET /1/clouddrive/config（alist#830 方案），服务端会重新下发 __puus；
    /// 只有确认重新下发才持久化，避免误删旧值。失败静默（web 语义）。
    func refreshPUUS() async {
        guard cookieFileExists else { return }
        do {
            var jar = loadCookies()
            jar.removeValue(forKey: "__puus")   // 不带 __puus 请求，触发服务端重发
            let url = Self.url(Self.driveAPIBase, "/config", query: ["pr": "ucpro", "fr": "pc"])
            let (_, http) = try await perform(
                makeRequest(url: url, headers: driveHeaders(cookies: jar))
            )
            guard http.statusCode == 200 else { return }
            let responseCookies = QuarkLogic.parseSetCookieHeaders(
                Self.setCookieHeaderValues(from: http)
            )
            guard responseCookies["__puus"] != nil else { return }
            jar.merge(responseCookies) { _, new in new }
            try saveCookies(jar)
        } catch {
            // 刷新失败：忽略，下次调用自然恢复（web 注释原文）
        }
    }

    // MARK: - 分享内部：stoken / 目录列表 / 递归（web 同名函数）

    /// 匿名取分享 stoken（web _get_share_stoken：POST share/sharepage/token）
    private func fetchShareStoken(pwdID: String) async throws -> String {
        let url = Self.url(Self.driveAPIBase, "/share/sharepage/token", query: [
            "pr": "ucpro", "fr": "pc",
        ])
        var headers = driveHeaders()
        headers["Origin"] = "https://pan.quark.cn"
        headers["Content-Type"] = "application/json"
        let payload = try await postJSON(url: url, headers: headers, body: [
            "pwd_id": pwdID,
            "passcode": "",
            "support_visit_limit_private_share": true,
        ])
        if (payload["code"] as? NSNumber)?.intValue != 0 {
            throw QuarkClientError.serverMessage(
                "获取分享 token 失败\(Self.detailSuffix(payload["message"]))"
            )
        }
        let stoken = ((payload["data"] as? [String: Any])?["stoken"] as? String) ?? ""
        guard !stoken.isEmpty else {
            throw QuarkClientError.serverMessage("分享 token 响应缺少 stoken")
        }
        return stoken
    }

    /// 列分享目录单层（翻页；web _list_share_dir），返回原始 JSON 项（目录判定在
    /// walk 里做，保持 web item 字段可读）；失败抛异常由 resolve 汇总层兜底。
    private func listShareDirectory(
        pwdID: String, stoken: String, pdirFid: String
    ) async throws -> (items: [[String: Any]], total: Int) {
        var items: [[String: Any]] = []
        var total = 0
        var page = 1
        while true {
            let url = Self.url(Self.driveAPIBase, "/share/sharepage/detail", query: [
                "ver": "2",
                "pwd_id": pwdID,
                "stoken": stoken,
                "pdir_fid": pdirFid,
                "force": "0",
                "_page": String(page),
                "_size": String(Self.sharePageSize),
                "_fetch_total": "1",
                "_sort": "file_type:asc,updated_at:desc",
                "pr": "ucpro",
                "fr": "pc",
            ])
            let payload = try await getJSON(url: url, headers: driveHeaders())
            if (payload["code"] as? NSNumber)?.intValue != 0 {
                throw QuarkClientError.serverMessage(
                    "分享目录列表失败\(Self.detailSuffix(payload["message"]))"
                )
            }
            let batch = (((payload["data"] as? [String: Any])?["list"] as? [Any]) ?? [])
                .compactMap { $0 as? [String: Any] }
            items.append(contentsOf: batch)
            // web：metadata._total or len(items)（0/None → len 兜底）
            let metaTotal = ((payload["metadata"] as? [String: Any])?["_total"] as? NSNumber)?
                .intValue ?? 0
            total = metaTotal > 0 ? metaTotal : items.count
            if batch.isEmpty || items.count >= total || batch.count < Self.sharePageSize {
                break
            }
            page += 1
        }
        return (items, total)
    }

    // swiftlint:disable function_parameter_count
    // 6 参数与 web _walk_share(pwd_id, stoken, pdir_fid, depth, files, seen) 逐字对齐

    /// 递归列分享目录（web _walk_share）：深度 > MAX_SHARE_DEPTH 不再进入，fid 去重。
    /// 目录项本身也进文件列表（web 先 append 再递归，dir 的 fid 也占 seen）。
    private func walkShare(
        pwdID: String,
        stoken: String,
        pdirFid: String,
        depth: Int,
        files: inout [QuarkShareFile],
        seen: inout Set<String>
    ) async throws {
        guard depth <= Self.maxShareDepth else { return }
        let (items, _) = try await listShareDirectory(pwdID: pwdID, stoken: stoken, pdirFid: pdirFid)
        for item in items {
            guard let fid = item["fid"] as? String, !fid.isEmpty, !seen.contains(fid) else {
                continue
            }
            seen.insert(fid)
            if let file = Self.mapShareFile(item) {
                files.append(file)
            }
            if QuarkLogic.rawIsDirectory(item) {
                try await walkShare(
                    pwdID: pwdID, stoken: stoken, pdirFid: fid, depth: depth + 1,
                    files: &files, seen: &seen
                )
            }
        }
    }
    // swiftlint:enable function_parameter_count

    /// 分享列表原始项 → QuarkShareFile（web resolve 内层 dict 构造逐字段对齐）
    private static func mapShareFile(_ item: [String: Any]) -> QuarkShareFile? {
        guard let fid = item["fid"] as? String, !fid.isEmpty else { return nil }
        let fileName = item["file_name"] as? String ?? ""
        let size = (item["size"] as? NSNumber)?.int64Value ?? 0
        let formatType = ((item["format_type"] as? String) ?? "").lowercased()
        // web：share_fid_token or fid_token or ""（空值/缺失都落到下一个）
        let token: String
        if let first = item["share_fid_token"] as? String, !first.isEmpty {
            token = first
        } else {
            token = (item["fid_token"] as? String) ?? ""
        }
        return QuarkShareFile(
            fid: fid,
            fileName: fileName,
            size: size,
            formatType: formatType,
            shareFidToken: token,
            ext: QuarkLogic.extensionOf(fileName: fileName)
        )
    }

    // MARK: - Cookie 文件存取（web _load_cookies_into / _persist_cookies / _clear_cookie_file）

    private var cookieFileExists: Bool {
        FileManager.default.fileExists(atPath: cookieFileURL.path)
    }

    /// 从 cookie 文件重载（web 每次请求都重载，登录态变更立即可见）；
    /// 文件缺失/损坏/非字符串值 → 空字典（web except (OSError, ValueError) return 对齐）
    private func loadCookies() -> [String: String] {
        guard let data = try? Data(contentsOf: cookieFileURL) else { return [:] }
        return QuarkLogic.cookies(from: data) ?? [:]
    }

    /// 持久化 cookie 文件（0600 权限，原子写入；web _persist_cookies 语义：
    /// 写同目录 .tmp → chmod 0600 → os.replace）
    private func saveCookies(_ cookies: [String: String]) throws {
        guard let data = QuarkLogic.cookiesData(cookies) else {
            throw QuarkClientError.invalidResponse
        }
        let fileManager = FileManager.default
        let directory = cookieFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // web：COOKIE_FILE.with_suffix(".json.tmp")
        let tmpURL = directory.appendingPathComponent("quark_cookies.json.tmp")
        try data.write(to: tmpURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tmpURL.path
        )
        if fileManager.fileExists(atPath: cookieFileURL.path) {
            _ = try fileManager.replaceItemAt(cookieFileURL, withItemAt: tmpURL)
        } else {
            try fileManager.moveItem(at: tmpURL, to: cookieFileURL)
        }
    }

    /// 删除 cookie 文件（web _clear_cookie_file，missing_ok）
    private func deleteCookieFile() {
        try? FileManager.default.removeItem(at: cookieFileURL)
    }

    // MARK: - 请求头（web 逐字段）

    /// 匿名客户端头（web _new_anon_client：浏览器 UA，无 Referer）
    private static func anonHeaders() -> [String: String] {
        ["User-Agent": browserUA]
    }

    /// drive 客户端头（web _new_drive_client：夸克客户端 UA + Referer），
    /// cookie 非空时附加 Cookie 头（httpx 只在有 cookie 时带头）。
    private func driveHeaders(cookies: [String: String]? = nil) -> [String: String] {
        let jar = cookies ?? loadCookies()
        var headers: [String: String] = [
            "User-Agent": Self.quarkClientUA,
            "Referer": Self.referer,
        ]
        if !jar.isEmpty {
            headers["Cookie"] = QuarkLogic.cookieHeader(jar)
        }
        return headers
    }

    /// 从 HTTPURLResponse 收集全部 Set-Cookie 头值（allHeaderFields 键大小写不定、
    /// 值可能是 String 或 [String]——不同 OS 版本行为不同，两种都兼容）
    private static func setCookieHeaderValues(from response: HTTPURLResponse) -> [String] {
        var values: [String] = []
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, key.caseInsensitiveCompare("Set-Cookie") == .orderedSame else {
                continue
            }
            if let text = value as? String {
                values.append(text)
            } else if let array = value as? [String] {
                values.append(contentsOf: array)
            }
        }
        return values
    }

    // MARK: - 网络层

    /// 单次请求（ephemeral session，手动 Cookie 管理——禁 URLSession 自动 cookie
    /// 存储/附加，web httpx 语义全手动）。测试经 protocolClasses 注入 URLProtocol mock。
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.poolTimeout
        configuration.timeoutIntervalForResource = Self.poolTimeout + 10
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuarkClientError.invalidResponse
        }
        return (data, http)
    }

    /// GET JSON：非 2xx → httpStatus；JSON 非法 → invalidResponse（都不静默）
    private func getJSON(url: URL, headers: [String: String]) async throws -> [String: Any] {
        let (data, http) = try await perform(makeRequest(url: url, headers: headers))
        guard (200 ..< 300).contains(http.statusCode) else {
            // 诊断打点（2026-09-08）：400/401 响应体带服务端真实原因（参数缺失提示等）
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            print("❌ [夸克 GET] HTTP \(http.statusCode) url=\(url.absoluteString) body=\(bodyPreview)")
            throw QuarkClientError.httpStatus(http.statusCode)
        }
        return try Self.decode(data)
    }

    /// POST JSON：非 2xx → httpStatus；JSON 非法 → invalidResponse
    private func postJSON(
        url: URL, headers: [String: String], body: [String: Any]
    ) async throws -> [String: Any] {
        var request = makeRequest(url: url, headers: headers)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await perform(request)
        guard (200 ..< 300).contains(http.statusCode) else {
            // 诊断打点（2026-09-08）：400/401 响应体带服务端真实原因（参数缺失提示等）
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            print("❌ [夸克 POST] HTTP \(http.statusCode) url=\(url.absoluteString) body=\(bodyPreview)")
            throw QuarkClientError.httpStatus(http.statusCode)
        }
        return try Self.decode(data)
    }

    private func makeRequest(url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.poolTimeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    // MARK: - 工具

    /// base + path + query → URL（query 值按 web urllib.parse.urlencode 的
    /// quote_plus 语义编码）。
    ///
    /// ⚠️ 不能用 URLComponents.queryItems / URLQueryItem：它按 RFC 3986 把
    /// '+' 与 '/' 视为 query 合法字符不编码，而夸克服务端按
    /// x-www-form-urlencoded 解码（'+' → 空格），stoken 等 base64 值会被篡改
    /// → HTTP 400「非法 token」→ resolve 空 → shareEmptyOrExpired
    /// （2026-09-08 歌曲海下载全挂根因；web 端 httpx params 用 quote_plus
    /// 无此问题，纯 Swift 移植差异）。
    private static func url(_ base: String, _ path: String, query: [String: String]) -> URL {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty {
            let encoded = query
                .map { key, value in
                    "\(QuarkLogic.formQueryValue(key))=\(QuarkLogic.formQueryValue(value))"
                }
                .joined(separator: "&")
            components.percentEncodedQuery = encoded
        }
        return components.url!
    }

    /// JSON Data → dict；非法 → invalidResponse（web .json() ValueError 冒泡对齐）
    private static func decode(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuarkClientError.invalidResponse
        }
        return object
    }

    /// 业务错误文案后缀（web f"...: {payload.get('message')}"；message 缺失不带冒号）
    private static func detailSuffix(_ message: Any?) -> String {
        guard let message = message as? String, !message.isEmpty else { return "" }
        return ": \(message)"
    }

    /// 32 位小写 hex（web uuid.uuid4().hex）
    private static func randomHex32() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
