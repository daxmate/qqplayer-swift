//
//  GequhaiClient.swift
//  QQPlayer
//
//  歌曲海（gequhai.com）客户端（web 版 backend/gequhai_provider.py 210 行移植，
//  E2 下载批 2026-09）。QQPlayer 共享层：Services 文件 iOS 也编译（禁 AppKit/UIKit），
//  QQPlayerMac target 走 B1A 白名单（pbxproj membershipExceptions）。web 为唯一事实源，
//  语义逐字对齐。
//
//  能力边界（web docstring 原文）：歌曲海只做「搜索 + 提取夸克分享链接」，HQ 下载由
//  QuarkClient 负责。本文件同时提供「分享 URL → 直链」的衔接编排（组合 QuarkClient：
//  resolveShare → pickFile(quality) → getDownloadURL），返回可下载直链 + 元信息
//  （文件名/大小/扩展名），供下载编排直接用。
//
//  语义对齐（web gequhai_provider.py，此处逐条注释）：
//  - search：POST /api/s（XMLHttpRequest 预检，code==1 才算可用）→ GET /s/<kw>
//    （翻页凑 limit，每页 10 条，上限 50）；HTML 表格解析（id="myTables" 行：
//    歌名 <a href="/play/<id>"> + 歌手 td color:#666）；网络/解析失败返回 [] 不抛
//    （web 语义，docstring 原文）
//  - playInfo（web get_share_url）：GET /play/<id> → 解析两个 JS 变量
//    window.play_id / window.mp3_extra_url；mp3_extra_url 做 '#'→'H'、'%'→'S'
//    替换后 base64 解码得夸克分享 URL（pan.quark.cn/s/xxx）；失败/无分享 → 字段 nil
//    不抛（web 语义）
//  - downloadInfo（web /api/gequhai/download 路由）：分享 URL 空 → noShareURL（web
//    404「该歌曲没有夸克网盘分享链接」）；resolve 空 → shareEmptyOrExpired（404「夸克
//    分享链接为空或已失效」）；pick_file 无音频 → noAudioFile（404「分享中没有可下载的
//    音频文件」）；getDownloadURL 未登录 → quarkLoginRequired（401）。音质质量由调用方
//    传（web 读设置 download.quarkQuality，默认 "mp3"——与 QuarkLogic.pickFile 默认一致）
//  - 每请求带 UA（web DEFAULT_UA 逐字）；Referer 逐字段：预检 → BASE_URL/，
//    搜索/播放页 GET → SEARCH_URL/（https://www.gequhai.com/s/）
//
//  结构与 MusicBrainzClient/QuarkClient 同款：struct + init 注入 protocolClasses
//  （URLProtocol mock）+ 注入 QuarkClient（下载编排需要登录态 cookie，cookie 归
//  QuarkClient 管）。纯逻辑抽到 GequhaiLogic（防回归单测）：HTML 清理/unescape、
//  搜索表格解析、播放页 JS 变量解析、mp3_extra_url 解码、limit 归一化、翻页计算、
//  关键词百分号编码（urllib.parse.quote safe="/" 语义）、表单编码（quote_plus 语义）、
//  响应字节解码（UTF-8 → GB18030 兜底，中文站常见 GBK）。
//
//  错误策略（与已合入 QuarkClient 一致）：网络层单次请求失败抛 GequhaiClientError
//  （LocalizedError，绝不静默吞）；公开 search/playInfo 按 web 顶层 try/except 语义
//  兜底（[] / shareURL=nil），downloadInfo 抛 GequhaiDownloadError（web 路由把业务
//  失败转 404/401 JSON——mac 端无 FastAPI 层，由调用方 catch 展示）。差异已在批内
//  汇报标注：本批全部网络路径经 URLProtocol mock 验证，不发真实网络。
//

import Foundation

// MARK: - 模型

/// 歌曲海搜索结果条目（web search 返回 {id, title, artist, page_url} 逐字段对齐）。
/// id 是播放页数字 ID（字符串，web 全链路 str）；page_url = PLAY_URL/<id>。
struct GequhaiSong: Equatable, Sendable {
    var id: String
    var title: String
    var artist: String          // 歌手 td 缺失 → "未知歌手"（web or "未知歌手" 对齐）
    var pageURL: String         // https://www.gequhai.com/play/<id>
}

/// 播放页解析结果（web get_share_url 返回 {"share_url", "play_id"} 对齐）。
/// 无分享/解析失败 → shareURL = nil（web 语义，不抛异常）。
struct GequhaiShareInfo: Equatable, Sendable {
    var shareURL: String?       // 夸克分享 URL（pan.quark.cn/s/xxx）；缺失/解码失败 nil
    var playID: String?         // window.play_id 原文；页面缺失 nil
}

/// 下载编排产物（web /api/gequhai/download 成功路径 + QuarkClient 返回对齐）：
/// 夸克直链 + 下载头快照（直链签名绑定 UA/Cookie/Referer，下载必须原样携带）+
/// 分享文件元信息（文件名/大小/扩展名），供下载编排直接用。
struct GequhaiDownloadInfo: Equatable, Sendable {
    var urlString: String            // 签名直链（~10min 有效）
    var headers: [String: String]    // QuarkDownload.headers 快照
    var fileName: String             // 分享文件原名（如 "周杰伦-晴天.mp3"）
    var size: Int64                  // 字节
    var ext: String                  // 小写带点扩展名（".mp3"；无 → ""）
}

// MARK: - 错误

/// 网络层错误（LocalizedError；单次请求失败抛，绝不静默吞——
/// 公开 search/playInfo 的兜底 []/nil 是 web 顶层语义，非吞错）
enum GequhaiClientError: Error, LocalizedError, Equatable {
    /// 非 2xx HTTP（web raise_for_status）
    case httpStatus(Int)
    /// 响应字节无法按支持的编码解码（web httpx resp.text 编码解析失败语义）
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .invalidResponse:
            return "invalid response"
        }
    }
}

/// 下载编排业务错误（web /api/gequhai/download 路由 404/401 响应逐条对齐；
/// 文案即 web JSON error 原文，UI 可直接展示）
enum GequhaiDownloadError: Error, LocalizedError, Equatable {
    /// 该歌曲没有夸克网盘分享链接（web 404 error 原文；含 playInfo 无分享）
    case noShareURL
    /// 夸克分享链接为空或已失效（web 404 error 原文；resolveShare 空数组）
    case shareEmptyOrExpired
    /// 分享中没有可下载的音频文件（web 404 error 原文；pick_file 无候选）
    case noAudioFile
    /// 需要登录夸克网盘（web 401 {"error": "quark_login_required"}）
    case quarkLoginRequired
    /// 夸克侧其它失败透传（直链获取失败等；文案含原因）
    case quarkFailed(String)

    var errorDescription: String? {
        switch self {
        case .noShareURL:
            return "该歌曲没有夸克网盘分享链接"
        case .shareEmptyOrExpired:
            return "夸克分享链接为空或已失效"
        case .noAudioFile:
            return "分享中没有可下载的音频文件"
        case .quarkLoginRequired:
            return "需要登录夸克网盘"
        case .quarkFailed(let reason):
            return reason
        }
    }
}

// MARK: - 纯逻辑（web 语义对齐，可单测）

enum GequhaiLogic {
    /// HTML 文本清理：先折叠空白再解实体最后去首尾空白（web _clean_text：
    /// unescape(re.sub(r"\s+", " ", value or "")).strip() ——注意 sub 在 unescape 前）
    static func cleanText(_ value: String?) -> String {
        guard let value else { return "" }
        let collapsed = value.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        return unescapeHTML(collapsed).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: HTML 实体解码（web html.unescape 常用子集 + 数字实体）

    /// 常见命名实体表（HTML5 全集 ~2000 条在 web 端；Swift 只收歌曲标题/歌手
    /// 高频出现的常用子集，未知命名实体保留原文——与 Python 差异见批内汇报）
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "copy": "\u{00A9}", "reg": "\u{00AE}",
        "trade": "\u{2122}", "hellip": "\u{2026}", "mdash": "\u{2014}",
        "ndash": "\u{2013}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "laquo": "\u{00AB}",
        "raquo": "\u{00BB}", "deg": "\u{00B0}", "plusmn": "\u{00B1}",
        "times": "\u{00D7}", "divide": "\u{00F7}", "middot": "\u{00B7}",
        "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}",
        "eacute": "\u{00E9}", "egrave": "\u{00E8}", "agrave": "\u{00E0}",
        "ccedil": "\u{00E7}", "uuml": "\u{00FC}", "ouml": "\u{00F6}",
        "auml": "\u{00E4}", "iacute": "\u{00ED}", "oacute": "\u{00F3}",
        "uacute": "\u{00FA}", "ntilde": "\u{00F1}", "szlig": "\u{00DF}",
        "yen": "\u{00A5}", "euro": "\u{20AC}", "pound": "\u{00A3}",
        "sect": "\u{00A7}", "para": "\u{00B6}", "bull": "\u{2022}",
    ]

    /// 解码一段 HTML 文本的 & 实体（命名查表 + 数字实体 &#NNN; / &#xHH;）。
    /// 未知命名实体 / 非法数字实体保留原文（& 原样输出，继续向后扫描）。
    static func unescapeHTML(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var output = ""
        var index = input.startIndex
        while let amp = input[index...].firstIndex(of: "&") {
            output += input[index ..< amp]
            let afterAmp = input.index(after: amp)
            if let semi = input[afterAmp...].firstIndex(of: ";"),
               semi > afterAmp,
               let replacement = entityReplacement(String(input[afterAmp ..< semi])) {
                output += replacement
                index = input.index(after: semi)
            } else {
                output += "&"
                index = afterAmp
            }
        }
        output += input[index...]
        return output
    }

    /// 实体名（不含 & 与 ;）→ 替换文本；不认识返回 nil（保留原文）
    private static func entityReplacement(_ name: String) -> String? {
        if let named = namedEntities[name] {
            return named
        }
        guard name.hasPrefix("#") else { return nil }
        let body = String(name.dropFirst())
        let value: UInt32?
        if body.lowercased().hasPrefix("x") {
            value = UInt32(String(body.dropFirst()), radix: 16)
        } else {
            value = UInt32(body, radix: 10)
        }
        guard let value, let scalar = UnicodeScalar(value) else { return nil }
        return String(scalar)
    }

    // MARK: 搜索页 HTML 解析（web _parse_search_html）

    private static let tableRegex = makeRegex(#"<table[^>]*id=["']?myTables["']?[^>]*>(.*?)</table>"#)
    private static let trRowRegex = makeRegex(#"<tr[^>]*>(.*?)</tr>"#)
    private static let songLinkRegex = makeRegex(#"<a[^>]*href="/play/(\d+)"[^>]*>(.*?)</a>"#)
    // 歌手 td 的 color 样式实测为 `color: #666;font-size: 15px;`，兼容 `color:#666` 无空格写法
    private static let artistTdRegex = makeRegex(#"<td[^>]*color\s*:\s*#666[^>]*>(.*?)</td>"#)

    /// 解析搜索结果页 HTML → 歌曲列表；无结果/解析失败返回 []（web 语义）。
    /// 只解析 id="myTables" 表格内的行（每行：排名 / <a href="/play/<id>">歌名</a> /
    /// color:#666 样式的歌手 td）。表头行、无关行自然跳过。
    /// - Parameters:
    ///   - htmlText: 页面 HTML 全文
    ///   - playBaseURL: web PLAY_URL 常量（拼 page_url 用）
    static func parseSearchHTML(_ htmlText: String?, playBaseURL: String) -> [GequhaiSong] {
        guard let htmlText, !htmlText.isEmpty else { return [] }
        guard let table = tableRegex.firstMatch(in: htmlText) else { return [] }
        let tableBody = (htmlText as NSString).substring(with: table.range(at: 1))
        var items: [GequhaiSong] = []
        for rowMatch in trRowRegex.matches(in: tableBody) {
            let row = (tableBody as NSString).substring(with: rowMatch.range(at: 1))
            guard let link = songLinkRegex.firstMatch(in: row),
                  let artistTd = artistTdRegex.firstMatch(in: row) else {
                continue
            }
            let rowNS = row as NSString
            let songID = rowNS.substring(with: link.range(at: 1))
            let title = cleanText(rowNS.substring(with: link.range(at: 2)))
            if title.isEmpty {
                continue
            }
            let artist = cleanText(rowNS.substring(with: artistTd.range(at: 1)))
            items.append(GequhaiSong(
                id: songID,
                title: title,
                artist: artist.isEmpty ? "未知歌手" : artist,
                pageURL: "\(playBaseURL)/\(songID)"
            ))
        }
        return items
    }

    // MARK: 播放页解析 + mp3_extra_url 解码（web _parse_play_html / _decode_extra_url）

    private static let playIDRegex = makeRegex(#"window\.play_id\s*=\s*['"]([^'"]*)['"]"#)
    private static let extraURLRegex = makeRegex(#"window\.mp3_extra_url\s*=\s*['"]([^'"]*)['"]"#)

    /// 解析播放页 HTML → shareInfo（web _parse_play_html）：
    /// 提取 window.play_id / window.mp3_extra_url 两个 JS 变量；字段缺失对应 nil。
    static func parsePlayHTML(_ htmlText: String?) -> GequhaiShareInfo {
        var playID: String?
        var extraURL: String?
        if let htmlText {
            if let m = playIDRegex.firstMatch(in: htmlText) {
                playID = (htmlText as NSString).substring(with: m.range(at: 1))
            }
            if let m = extraURLRegex.firstMatch(in: htmlText) {
                extraURL = (htmlText as NSString).substring(with: m.range(at: 1))
            }
        }
        return GequhaiShareInfo(shareURL: decodeExtraURL(extraURL), playID: playID)
    }

    /// mp3_extra_url 解码（web _decode_extra_url）：'#'→'H'、'%'→'S'，base64 解码 →
    /// 夸克分享 URL。解码失败或结果非 http(s) URL 返回 nil。
    static func decodeExtraURL(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let substituted = value
            .replacingOccurrences(of: "#", with: "H")
            .replacingOccurrences(of: "%", with: "S")
        guard let data = Data(base64Encoded: substituted),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        // web _HTTP_URL_RE = ^https?:// (IGNORECASE)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            return nil
        }
        return trimmed
    }

    // MARK: limit 归一化 / 翻页（web search 内联语义）

    /// limit 收敛到 [1, 50]（web MAX_RESULTS=50：max(1, min(50, limit))）
    static func normalizeLimit(_ limit: Int) -> Int {
        max(1, min(50, limit))
    }

    /// 需要请求的页数（web：min((limit + PAGE_SIZE - 1) // PAGE_SIZE, MAX_RESULTS // 10)；
    /// 每页 10 条，最多 5 页）
    static func pages(forLimit limit: Int) -> Int {
        min((normalizeLimit(limit) + 9) / 10, 5)
    }

    // MARK: 编码（urllib.parse 语义逐字对齐）

    /// URL 路径段百分号编码（web urllib.parse.quote(keyword)：默认 safe="/"——
    /// 只保留 ASCII 字母数字与 _ . - ~ /，其余按 UTF-8 百分号编码）
    static func percentEncodePath(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// application/x-www-form-urlencoded 表单编码（web httpx data={...} →
    /// urllib.parse.urlencode → quote_plus：保留 ASCII 字母数字与 _ . - ~，空格 → '+'
    /// （quote 时把空格留在 safe 集里再 replace 成 '+'，web 源码语义））
    static func formEncoded(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~ ")
        let kept = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return kept.replacingOccurrences(of: " ", with: "+")
    }

    // MARK: 响应字节解码（web httpx resp.text 语义；GBK 兜底利好中文站）

    /// 按 Content-Type charset → NSStringEncoding；不认得的返回 nil
    private static func encoding(fromContentType contentType: String?) -> UInt? {
        guard let contentType else { return nil }
        let parts = contentType.lowercased().split(separator: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("charset=") else { continue }
            let charset = String(trimmed.dropFirst("charset=".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch charset {
            case "utf-8", "utf8":
                return String.Encoding.utf8.rawValue
            case "gbk", "gb2312", "gb18030":
                return Self.gb18030Encoding
            case "latin-1", "iso-8859-1", "us-ascii", "ascii":
                return String.Encoding.isoLatin1.rawValue
            default:
                return nil
            }
        }
        return nil
    }

    /// GB18030 NSStringEncoding（GBK/GB2312 超集；中文站无 charset 时兜底）
    static let gb18030Encoding: UInt = {
        CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    }()

    /// HTML 响应字节 → 文本。顺序：charset 指定 → UTF-8 → GB18030 → UTF-8 lossy
    /// （web httpx 无 charset 时按 UTF-8 解、失败替换；GB18030 是 Swift 侧对
    /// 常见 GBK 中文站的兜底——web 环境同页面按自身编码无此问题）。
    /// 全部失败返回 nil（调用方按 GequhaiClientError.invalidResponse 处理）。
    static func decodeHTMLBytes(_ data: Data, contentType: String?) -> String? {
        if let rawValue = encoding(fromContentType: contentType),
           let text = NSString(data: data, encoding: rawValue) {
            return text as String
        }
        if let text = String(bytes: data, encoding: .utf8) {
            return text
        }
        if let text = NSString(data: data, encoding: gb18030Encoding) {
            return text as String
        }
        return String(decoding: data, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        // lossy：替换非法序列为 U+FFFD
    }

    /// 编译 DOTALL 正则（对应 web re.S）；内置模式均经测试验证，失败即编程错误
    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    }
}

extension NSRegularExpression {
    /// 首个匹配（web re.search 语义）；无匹配 nil
    fileprivate func firstMatch(in string: String) -> NSTextCheckingResult? {
        let ns = string as NSString
        return firstMatch(in: string, options: [], range: NSRange(location: 0, length: ns.length))
    }

    /// 全部匹配（web re.findall 语义）
    fileprivate func matches(in string: String) -> [NSTextCheckingResult] {
        let ns = string as NSString
        return matches(in: string, options: [], range: NSRange(location: 0, length: ns.length))
    }
}

// MARK: - 客户端

/// 歌曲海搜索 + 夸克分享 URL 提取 + 直链衔接编排（web gequhai_provider + /api/gequhai/download 对齐）。
/// 每实例自带网络栈（protocolClasses 注入 mock）；quark 下载编排复用注入的 QuarkClient
/// （登录 cookie 归 QuarkClient 管，本层不接触）。所有网络路径经 URLProtocol mock 验证。
struct GequhaiClient {
    // MARK: 常量（web gequhai_provider.py 逐字对齐）

    static let baseURL = "https://www.gequhai.com"
    static let searchAPIURL = "\(baseURL)/api/s"
    static let searchURL = "\(baseURL)/s"
    static let playURL = "\(baseURL)/play"
    static let pageSize = 10
    static let maxResults = 50
    static let timeout: TimeInterval = 15.0

    /// web DEFAULT_UA 逐字（Windows Chrome 126）
    static let defaultUA = (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    )

    /// 下载编排用的 QuarkClient（默认真实实例；测试注入带 mock protocolClasses 的实例）
    let quark: QuarkClient

    /// 测试注入：URLProtocol mock 类列表（nil = 真实网络）。网络请求每次临时构造
    /// URLSession（ephemeral + 手动 Cookie 管理——歌曲海无 cookie 语义，但架构与
    /// QuarkClient/MusicBrainzClient 一致），无法注入现成 session，故注入
    /// protocolClasses。quark 的请求由 quark.protocolClasses 负责。
    private let protocolClasses: [AnyClass]?

    init(
        quark: QuarkClient = QuarkClient(),
        protocolClasses: [AnyClass]? = nil
    ) {
        self.quark = quark
        self.protocolClasses = protocolClasses
    }

    // MARK: - 搜索（web search）

    /// 搜索歌曲；失败返回 [] 不抛（web docstring 原文）。
    /// 预检 POST /api/s（code==1 才算可用）→ GET /s/<kw> 翻页凑 limit（每页 10 条，
    /// 上限 50，HTML 解析无结果即停）。
    func search(query: String, limit: Int = 20) async -> [GequhaiSong] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let bounded = GequhaiLogic.normalizeLimit(limit)
        do {
            guard try await apiReady(keyword: keyword) else {
                return []   // 预检不可用 → 无结果（web 语义，不抛）
            }
            var items: [GequhaiSong] = []
            let pages = GequhaiLogic.pages(forLimit: bounded)
            for page in 1 ... pages {
                let url = Self.searchPageURL(keyword: keyword, page: page)
                let html = try await fetchHTML(url: url, referer: "\(Self.searchURL)/")
                let pageItems = GequhaiLogic.parseSearchHTML(html, playBaseURL: Self.playURL)
                items.append(contentsOf: pageItems)
                if pageItems.isEmpty || items.count >= bounded {
                    break
                }
            }
            return Array(items.prefix(bounded))
        } catch {
            // web search 顶层 except (HTTPError, OSError, ValueError) → [] 对齐
            return []
        }
    }

    /// 搜索预检：POST /api/s（XMLHttpRequest），code==1 才算可用。
    /// 网络异常 / 非 JSON / code!=1 一律视为不可用（返回 false，search 得 []）——
    /// web _api_ready 注释原文，预检语义不抛。
    private func apiReady(keyword: String) async throws -> Bool {
        let url = URL(string: Self.searchAPIURL)!
        var request = makeRequest(url: url, referer: "\(Self.baseURL)/")
        request.httpMethod = "POST"
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Data("keyword=\(GequhaiLogic.formEncoded(keyword))".utf8)
        do {
            let (data, http) = try await perform(request)
            guard (200 ..< 300).contains(http.statusCode),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return (payload["code"] as? NSNumber)?.intValue == 1
        } catch {
            return false
        }
    }

    // MARK: - 播放信息（web get_share_url → 夸克分享 URL）

    /// 播放页解析：GET /play/<id> → {shareURL, playID}。
    /// 网络/解析失败或无分享 → shareURL = nil，不抛（web get_share_url 语义）。
    func playInfo(songID: String) async -> GequhaiShareInfo {
        let sid = songID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty else {
            return GequhaiShareInfo(shareURL: nil, playID: nil)
        }
        do {
            let url = URL(string: "\(Self.playURL)/\(sid)")!
            let html = try await fetchHTML(url: url, referer: "\(Self.searchURL)/")
            return GequhaiLogic.parsePlayHTML(html)
        } catch {
            // web get_share_url 顶层 except → {"share_url": None, "play_id": None} 对齐
            return GequhaiShareInfo(shareURL: nil, playID: nil)
        }
    }

    // MARK: - 分享 URL → 直链（web /api/gequhai/download 编排；组合 QuarkClient）

    /// 歌曲 id → 可下载直链（playInfo → resolveShare → pickFile → getDownloadURL）。
    /// 业务失败抛 GequhaiDownloadError（文案逐字对齐 web 路由 404/401）。
    /// - Parameters:
    ///   - songID: 歌曲海播放页数字 id
    ///   - quality: 音质偏好（web 读设置 quarkQuality，默认 "mp3"；nil 走 QuarkLogic
    ///     pickFile 默认 mp3 优先）
    func downloadInfo(songID: String, quality: String? = nil) async throws -> GequhaiDownloadInfo {
        let info = await playInfo(songID: songID)
        guard let shareURL = info.shareURL else {
            throw GequhaiDownloadError.noShareURL
        }
        return try await downloadInfo(shareURL: shareURL, quality: quality)
    }

    /// 分享 URL → 可下载直链 + 元信息（组合 QuarkClient：resolveShareVerbose →
    /// QuarkLogic.pickFile(quality) → getDownloadURL），供批 2b 下载编排直接用。
    func downloadInfo(
        shareURL: String, quality: String? = nil
    ) async throws -> GequhaiDownloadInfo {
        // resolveShareVerbose 失败 → ([], "")（web resolve 汇总语义）；空 = 分享空/失效
        let (files, stoken) = await quark.resolveShareVerbose(shareURL)
        guard !files.isEmpty else {
            throw GequhaiDownloadError.shareEmptyOrExpired
        }
        guard let chosen = QuarkLogic.pickFile(files, quality: quality) else {
            throw GequhaiDownloadError.noAudioFile
        }
        let download: QuarkDownload
        do {
            download = try await quark.getDownloadURL(
                shareURL: shareURL,
                fid: chosen.fid,
                shareFidToken: chosen.shareFidToken,
                stoken: stoken
            )
        } catch let error as QuarkClientError {
            if error == .loginRequired {
                throw GequhaiDownloadError.quarkLoginRequired
            }
            throw GequhaiDownloadError.quarkFailed(error.localizedDescription)
        } catch {
            throw GequhaiDownloadError.quarkFailed(error.localizedDescription)
        }
        return GequhaiDownloadInfo(
            urlString: download.urlString,
            headers: download.headers,
            fileName: chosen.fileName,
            size: chosen.size,
            ext: QuarkLogic.resolvedExtension(of: chosen)
        )
    }

    // MARK: - 内部：URL 构造 / 请求（web 逐字段）

    /// 搜索页 URL：/s/<quote(keyword)>，page>1 追加 ?page=N（web f-string + quote 逐字）
    private static func searchPageURL(keyword: String, page: Int) -> URL {
        var urlString = "\(searchURL)/\(GequhaiLogic.percentEncodePath(keyword))"
        if page > 1 {
            urlString += "?page=\(page)"
        }
        return URL(string: urlString)!
    }

    /// 请求头（web _headers：UA 必带，referer 非空追加）
    private func makeRequest(url: URL, referer: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.setValue(Self.defaultUA, forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return request
    }

    /// GET 页面 HTML；非 2xx → httpStatus、字节解码失败 → invalidResponse（均抛出，
    /// 由公开方法按 web 语义兜底）
    private func fetchHTML(url: URL, referer: String?) async throws -> String? {
        let request = makeRequest(url: url, referer: referer)
        let (data, http) = try await perform(request)
        guard (200 ..< 300).contains(http.statusCode) else {
            throw GequhaiClientError.httpStatus(http.statusCode)
        }
        let contentType = http.allHeaderFields["Content-Type"] as? String
            ?? http.allHeaderFields["content-type"] as? String
        return GequhaiLogic.decodeHTMLBytes(data, contentType: contentType)
    }

    /// 单次请求（ephemeral session——歌曲海无需 cookie，架构与 QuarkClient 一致；
    /// 测试经 protocolClasses 注入 URLProtocol mock）
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout + 10
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
            throw GequhaiClientError.invalidResponse
        }
        return (data, http)
    }
}
