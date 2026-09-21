//
//  GequhaiClient+Logic.swift
//  QQPlayer
//
//  歌曲海（gequhai.com）纯解析逻辑（web 版 backend/gequhai_provider.py 语义逐字对齐）：
//  `GequhaiLogic` = HTML 实体解码 / 搜索页与播放页解析 / limit 归一化与翻页 /
//  百分号与表单编码 / 响应字节解码（UTF-8 → GB18030 兜底，中文站常见 GBK）/ 正则编译；
//  以及本文件级 `NSRegularExpression` 助手扩展（fileprivate firstMatch/matches，
//  只被同文件内的 GequhaiLogic 使用，故与使用者同片、无需降级）。
//
//  2026-09-21 从 GequhaiClient.swift 原样搬出（纯搬家，无逻辑变更）。
//  网络层（`GequhaiClient` 结构体、常量、请求构造、protocolClasses mock 注入、
//  QuarkClient 下载编排）仍在 GequhaiClient.swift；模型与错误类型也在该文件。
//  两侧同属「歌曲海」链路，改语义时一起看。
//
//  同族写法（网络三连 GequhaiClient / NeteaseOnlineClient / QuarkClient）：
//  「纯逻辑 enum 独立成片」——逻辑片自带其文件级 private/fileprivate 助手，
//  私有面零跨区 ⇒ 零降级；切法见拆分预研 §2.8 候选 1。
//
import Foundation

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
        // 不用 `try!`：模式被改坏时给出可定位诊断（本文件在行数基线内 ⇒ 保持净零，见棘轮清单）
        do { return try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) } catch { preconditionFailure("内置正则模式必须可编译（编程错误）：\(pattern) — \(error)") }
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
