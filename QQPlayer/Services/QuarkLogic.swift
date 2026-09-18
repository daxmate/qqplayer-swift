//
//  QuarkLogic.swift
//  QQPlayer
//
//  夸克网盘纯逻辑（web quark_provider.py 语义对齐，可单测）。
//  原 QuarkClient.swift「纯逻辑」段，纯移动：类型/函数/访问级别逐字未改。
//  share token 提取、扩展名、目录判定、pick_file 降级决策、Set-Cookie 解析、
//  cookie 序列化/反序列化（含损坏兜底）。
//

import Foundation

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
