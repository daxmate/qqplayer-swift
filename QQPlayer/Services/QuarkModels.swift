//
//  QuarkModels.swift
//  QQPlayer
//
//  夸克网盘 DTO 与错误（原 QuarkClient.swift「模型」段，纯移动：类型/字段/访问级别逐字未改）。
//  web backend/quark_provider.py 返回结构对齐。
//

import Foundation

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
