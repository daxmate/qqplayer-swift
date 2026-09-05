//
//  TagRenameLogic.swift
//  QQPlayer
//
//  重命名模板渲染纯逻辑（web tag_editor.target_filename/_render_rename_template 移植，
//  E1 刮削批 2026-09）。web 为唯一事实源，行为逐条对齐（回归测试锚定）：
//
//  - 模板占位符 {artist}/{title}/{album}/{track}/{year}；值为 nil/空 → 渲染空串；
//    非法占位符/语法错误 → 回落默认模板 "{artist} - {title}"
//  - 模板为 nil 或等于默认模板 → 旧版分支逻辑（artist+title 都空 → 返回 nil 不改名；
//    artist 空 → 只有 title，不留 " - " 分隔符）
//  - 模板含 '/' → 相对文件所在目录的子目录（调用方 mkdir parents）
//  - 非法文件名字符清洗（不含 '/'，保留其目录分隔语义）；过滤空/./.. 路径段防穿越
//  - 同名去重 (2)(3) 递增由调用方（TagWriterService）在目标目录做，本逻辑只渲染
//  - track/year 渲染：数字转字符串，nil/非法 → 空串

import Foundation

enum TagRenameLogic {
    static let defaultTemplate = "{artist} - {title}"

    /// 模板渲染上下文（文件当前标签值；nil = 空占位）
    struct Values {
        var artist: String?
        var title: String?
        var album: String?
        var track: Int?
        var year: Int?

        init(artist: String? = nil, title: String? = nil, album: String? = nil,
             track: Int? = nil, year: Int? = nil) {
            self.artist = artist
            self.title = title
            self.album = album
            self.track = track
            self.year = year
        }
    }

    // web _INVALID_FILENAME_CHARS：默认模板清洗（含 / 与 \）
    private static let invalidChars = "[\\\\/:*?\"<>|]"
    // web _INVALID_FILENAME_CHARS_NO_SLASH：模板分段清洗（保留 / 作目录分隔）
    private static let invalidCharsNoSlash = "[\\\\:*?\"<>|]"

    // web _fmt_template_int：nil/非法 → 空串
    private static func fmtInt(_ v: Int?) -> String {
        guard let v else { return "" }
        return String(v)
    }

    /// 按模板渲染目标文件名（相对文件所在目录，可能含子目录路径段）。
    /// 返回 nil = 不改名。
    /// - Parameter ext: 带点扩展名（如 ".mp3"），调用方传 URL.pathExtension 前加 "."
    static func renderFileName(
        template: String?,
        values: Values,
        ext: String
    ) -> String? {
        let isDefault = template == nil || template == defaultTemplate
        // 默认模板旧分支：artist+title 组合，空则 nil（web target_filename 逐字节对齐）
        if isDefault {
            let artistS = (values.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let titleS = (values.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let base: String
            if !artistS.isEmpty && !titleS.isEmpty {
                base = "\(artistS) - \(titleS)"
            } else if !titleS.isEmpty {
                base = titleS
            } else if !artistS.isEmpty {
                base = artistS
            } else {
                return nil
            }
            let cleaned = clean(base, regex: invalidChars)
            if cleaned.isEmpty { return nil }
            return cleaned + ext
        }

        // 自定义模板：占位符替换（未知占位符/异常 → 回落默认模板渲染）
        let rendered = renderTemplate(template!, values: values)
        // 分段：保留 '/' 作目录分隔；清洗每段非法字符；过滤空/./..
        let parts = rendered
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { clean(String($0), regex: invalidCharsNoSlash) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        if parts.isEmpty { return nil }
        // 空占位符残留的 -_. 空白分隔符清理（web 只在首尾）
        let joined = parts.joined(separator: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        if joined.isEmpty { return nil }
        return joined + ext
    }

    private static func clean(_ s: String, regex: String) -> String {
        guard let re = try? NSRegularExpression(pattern: regex) else { return s }
        let range = NSRange(s.startIndex ..< s.endIndex, in: s)
        let cleaned = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 占位符替换；未知占位符残留 `{`/`}` → 用默认模板字符串重渲（web .format 抛 KeyError 回落）
    private static func renderTemplate(_ template: String, values: Values) -> String {
        let map: [String: String] = [
            "artist": (values.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            "title": (values.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            "album": (values.album ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            "track": fmtInt(values.track),
            "year": fmtInt(values.year),
        ]
        var out = template
        for (key, value) in map {
            out = out.replacingOccurrences(of: "{\(key)}", with: value)
        }
        if out.contains("{") || out.contains("}") {
            // 未知占位符（如 {foo}）→ web .format KeyError → DEFAULT_RENAME_TEMPLATE 渲染
            out = defaultTemplate
            for (key, value) in map {
                out = out.replacingOccurrences(of: "{\(key)}", with: value)
            }
        }
        return out
    }
}
