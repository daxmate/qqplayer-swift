//
//  NeteaseOnlineClient+Logic.swift
//  QQPlayer
//
//  网易云在线「纯逻辑 + 错误类型」分片（web 版 backend/netease_provider.py 语义对齐）：
//  `NeteaseOnlineLogic` = 音质等级归一化 / Meting br 参数 / 文件名清洗 / 扩展名推断 /
//  http→https 归一 / 下载文件名与重名加序号；`NeteaseOnlineError` = 错误枚举
//  （HTTP 状态 / 非法响应 / 无直链 / 下载失败）。
//
//  2026-09-21 从 NeteaseOnlineClient.swift 原样搬出（纯搬家，无逻辑变更）。
//  模型与 `NeteaseOnlineClient` 客户端（搜索 / 直链 / 专辑年份）仍在
//  NeteaseOnlineClient.swift；传输层在 NeteaseOnlineClient+Transport.swift。
//
//  同族写法（网络三连 GequhaiClient / NeteaseOnlineClient / QuarkClient）：
//  「纯逻辑 enum 独立成片」——逻辑片零私有面 ⇒ 零降级；切法见拆分预研 §2.7 候选 1。
//
import Foundation

// MARK: - 纯逻辑（web 语义对齐，可单测）

enum NeteaseOnlineLogic {
    static let validLevels = ["standard", "exhigh", "lossless", "hires"]
    static let defaultLevel = "exhigh"

    /// 非法/缺失音质 → 默认 exhigh（web VALID_LEVELS 检查同语义）
    static func normalizeLevel(_ level: String?) -> String {
        guard let level = level?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              validLevels.contains(level) else {
            return defaultLevel
        }
        return level
    }

    /// 音质等级 → Meting br 参数（web METING_BR_BY_LEVEL 对齐）
    static func brParameter(forLevel level: String) -> String {
        switch normalizeLevel(level) {
        case "standard": return "128"
        case "exhigh": return "320"
        case "lossless", "hires": return "2000"
        default: return "320"
        }
    }

    /// 文件名清洗：去掉 / \\ : * ? " < > | 与首尾空白（web download._sanitize_filename 对齐）
    static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalid).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从 URL 推断扩展名（去 query，取路径末段点后缀；推断不出用 fallback）。
    /// web _extract_ext：后缀须字母数字且 ≤5 字符。
    static func extractExtension(from url: URL, fallback: String = "mp3") -> String {
        let name = url.path.components(separatedBy: "/").last ?? ""
        guard let dot = name.lastIndex(of: ".") else { return fallback }
        let candidate = String(name[name.index(after: dot)...]).lowercased()
        guard !candidate.isEmpty, candidate.count <= 5,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return fallback
        }
        return candidate
    }

    /// http:// → https://（CDN 同路径支持 https；web _to_https 对齐）
    static func toHttpsURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidate = trimmed
        if candidate.lowercased().hasPrefix("http://") {
            candidate = "https://" + String(candidate.dropFirst("http://".count))
        }
        return URL(string: candidate)
    }

    /// 下载文件名：{title}-{artist}.{ext}；artist 清洗后空 → {title}.{ext}；
    /// title 清洗后也空 → id 兜底（web /api/online/download 对齐）
    static func downloadFileName(title: String, artist: String, ext: String, songID: Int) -> String {
        let cleanExt = ext.isEmpty ? "mp3" : ext
        let cleanTitle = sanitizeFilename(title)
        let cleanArtist = sanitizeFilename(artist)
        let titlePart = cleanTitle.isEmpty ? String(songID) : cleanTitle
        let base = cleanArtist.isEmpty ? titlePart : "\(titlePart)-\(cleanArtist)"
        return "\(base).\(cleanExt)"
    }

    /// 重名加序号：name.ext → name (1).ext（web download._unique_path 对齐；exists 由调用方注入）
    static func uniqueFileName(base: String, exists: (String) -> Bool) -> String {
        guard exists(base) else { return base }
        guard let dot = base.lastIndex(of: ".") else {
            for i in 1 ..< 1000 {
                let cand = "\(base) (\(i))"
                if !exists(cand) { return cand }
            }
            return base
        }
        let stem = String(base[..<dot])
        let ext = String(base[dot...])
        for i in 1 ..< 1000 {
            let cand = "\(stem) (\(i))\(ext)"
            if !exists(cand) { return cand }
        }
        return base
    }
}

// MARK: - 错误

enum NeteaseOnlineError: Error, LocalizedError {
    case httpError(Int)
    case invalidResponse
    case noPlayURL
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP \(code)"
        case .invalidResponse: return "invalid response"
        case .noPlayURL: return "no play URL"
        case .downloadFailed(let reason): return reason
        }
    }
}
