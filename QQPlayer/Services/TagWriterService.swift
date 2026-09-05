//
//  TagWriterService.swift
//  QQPlayer
//
//  标签写入服务（web 版 backend/tag_editor.py 移植，E1 刮削批 2026-09）。
//  引擎 = SFBAudioEngine writeMetadata（S0 冒烟已验证：mp3/flac/m4a 写 title/artist/
//  album/albumArtist/genre/year/track/封面全通；mutagen 帧级交叉验证写入正确）。
//
//  语义对齐 web tag_editor.py（web 为唯一事实源）：
//  - 支持格式：mp3/m4a/mp4/flac/ogg/opus（TAG_WRITABLE_EXTS 对齐；其余抛 .unsupportedFormat）
//  - 字段有值才写：request 里 nil 的字段保留文件原值（batch 场景只写 year/genre 时关键）
//  - 原子写：同目录 copy2 → SFB 写临时副本 → FileManager.replaceItem（web os.replace 语义；
//    任何一步失败原文件完好）
//  - 封面：coverData 非 nil → 替换内嵌封面；removeCover → 删除；都未设 → 不动
//  - 改名：renameTemplate 渲染（TagRenameLogic，web target_filename 语义：占位符
//    {artist}/{title}/{album}/{track}/{year}、'/' 子目录、非法字符清洗、同名 (2)(3) 去重）；
//    渲染结果 ≠ 原名 → 原子改名（含子目录 mkdir）；改名后 DB 引用迁移由调用方处理
//    （UI 层调 DatabaseManager 的 moveTrack 扩展）
//
//  ⚠️ SFB 已知缺口（S0 定位，必须处理）：
//  ① MP3 年份：releaseDate 需完整 ISO8601（SFB 内部 NSISO8601DateFormatter 默认
//    withInternetDateTime，纯日期 "2018-05-05" 解析失败 → 整段跳过不写帧）。
//    → .mp3 时 year 渲染 "\(year)-01-01T00:00:00Z"（已验证写入 TDRC/TYER，读回 2018）；
//    flac/m4a/ogg/opus 无此门槛，写 "\(year)" 即可
//  ② SFB 读回 M4A albumTitle 为空（写入正确）→ 本服务不依赖 SFB 读回验证/回填；
//    读侧统一走 AudioMetadataParser（QQPlayer 自家解析器）
//
//  调用方（MacTagEditorView / 批量）写完后：
//  - 通知 UI 刷新（LibraryFolderContentChanged / LibraryNeedsRefresh）
//  - 若 renamed → DatabaseManager.moveTrack(from:to:) 迁移引用，再触发索引刷新

import Foundation

enum TagWriterError: Error, LocalizedError {
    /// 扩展名不在可写清单（wav/dsf/aiff/…）
    case unsupportedFormat(String)
    case fileNotReadable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "该格式不支持写标签: \(ext)"
        case .fileNotReadable:
            return "文件不可读"
        case .writeFailed(let reason):
            return "写标签失败: \(reason)"
        }
    }
}

/// 标签写入请求。nil 字段 = 不写（保留文件原值）。
struct TagWriteRequest {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    /// 年份（写 releaseDate；.mp3 由服务内部 normalize 成完整 ISO8601）
    var year: Int?
    var trackNumber: Int?
    /// JPEG/PNG 原始数据；nil = 不动封面（与 removeCover 互斥时以 removeCover 为准）
    var coverData: Data?
    var removeCover: Bool = false
    /// 重命名模板；nil = 不改名。默认模板常量见 DEFAULT_RENAME_TEMPLATE
    var renameTemplate: String?
}

struct TagWriteResult {
    /// 写完后实际路径（可能因改名变化）
    var finalURL: URL
    var renamed: Bool
    var wroteCover: Bool
}

enum TagWriterService {
    /// 默认重命名模板（对齐 web DEFAULT_RENAME_TEMPLATE：artist 空 → 只有 title，不留 " - "）
    static let defaultRenameTemplate = "{artist} - {title}"

    /// 可写标签格式（对齐 web TAG_WRITABLE_EXTS；大小写不敏感）
    static let writableExtensions: Set<String> = ["mp3", "m4a", "mp4", "flac", "ogg", "opus"]

    /// 写标签（原子写 + 可选改名）。S1 实现。
    static func writeTags(to url: URL, request: TagWriteRequest) throws -> TagWriteResult {
        fatalError("S1 实现：SFB 写标签 + 原子写 + 改名；见文件头契约")
    }
}
