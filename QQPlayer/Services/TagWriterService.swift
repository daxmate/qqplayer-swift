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
import SFBAudioEngine

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

    /// 写标签（原子写 + 可选改名）。
    /// 流程对齐 web tag_editor.save_tags：copy2 同目录临时文件 → 改临时文件 → 原子替换；
    /// 任何一步失败原文件保持完好。
    static func writeTags(to url: URL, request: TagWriteRequest) throws -> TagWriteResult {
        let fm = FileManager.default
        let ext = url.pathExtension.lowercased()
        guard writableExtensions.contains(ext) else {
            throw TagWriterError.unsupportedFormat(ext.isEmpty ? "无扩展名" : ext)
        }
        guard fm.fileExists(atPath: url.path) else {
            throw TagWriterError.fileNotReadable
        }

        // 1. 渲染目标文件名（仅当调用方给了 renameTemplate；nil = 不改名）
        let targetURL: URL
        let renamed: Bool
        if let template = request.renameTemplate,
           let newName = TagRenameLogic.renderFileName(
               template: template,
               values: TagRenameLogic.Values(
                   artist: request.artist,
                   title: request.title,
                   album: request.album,
                   track: request.trackNumber,
                   year: request.year
               ),
               ext: "." + ext
           ) {
            let candidate = url.deletingLastPathComponent().appendingPathComponent(newName)
            if candidate.standardizedFileURL != url.standardizedFileURL {
                targetURL = dedupeTarget(candidate)
                renamed = true
            } else {
                targetURL = url
                renamed = false
            }
        } else {
            targetURL = url
            renamed = false
        }

        // 2. 原子写：copy 到同目录临时文件（保留扩展名——SFB 按扩展名识别格式）
        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).tagtmp-\(UUID().uuidString.prefix(8)).\(ext)")
        do {
            try fm.copyItem(at: url, to: tmpURL)
            // SFB 步骤放独立作用域：写完即释放文件句柄，再原子替换
            do {
                let audioFile = try SFBAudioEngine.AudioFile(readingPropertiesAndMetadataFrom: tmpURL)
                let metadata = audioFile.metadata
                if let title = request.title, !title.isEmpty { metadata.title = title }
                if let artist = request.artist, !artist.isEmpty { metadata.artist = artist }
                if let album = request.album, !album.isEmpty { metadata.albumTitle = album }
                if let albumArtist = request.albumArtist, !albumArtist.isEmpty { metadata.albumArtist = albumArtist }
                if let genre = request.genre, !genre.isEmpty { metadata.genre = genre }
                if let year = request.year {
                    // ⚠️ SFB 已知缺口（S0）：.mp3 的 releaseDate 必须完整 ISO8601，
                    // date-only "2018" 会被内部 NSISO8601DateFormatter 拒 → 帧不写
                    if ext == "mp3" {
                        metadata.releaseDate = "\(year)-01-01T00:00:00Z"
                    } else {
                        metadata.releaseDate = String(year)
                    }
                }
                if let track = request.trackNumber { metadata.trackNumber = track }
                if request.removeCover {
                    metadata.removeAllAttachedPictures()
                } else if let coverData = request.coverData {
                    metadata.removeAllAttachedPictures()
                    metadata.attachPicture(AttachedPicture(imageData: coverData))
                }
                try audioFile.writeMetadata()
            }

            // 3. 原子落位：target == 原路径 → 原地替换；新路径（含子目录）→ mkdir + 移动
            if renamed {
                let dir = targetURL.deletingLastPathComponent()
                if !fm.fileExists(atPath: dir.path) {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
            }
            if fm.fileExists(atPath: targetURL.path) {
                _ = try fm.replaceItemAt(targetURL, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: targetURL)
            }
            // 改名完成：移除旧路径（web save_tags 的 f.unlink() 语义）
            if renamed {
                try? fm.removeItem(at: url)
            }
        } catch let error as TagWriterError {
            try? fm.removeItem(at: tmpURL)
            throw error
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw TagWriterError.writeFailed(error.localizedDescription)
        }

        return TagWriteResult(
            finalURL: targetURL,
            renamed: renamed,
            wroteCover: request.coverData != nil || request.removeCover
        )
    }

    /// 目标已存在 → 加 (2)/(3) 序号，绝不覆盖（web _dedupe_target）
    private static func dedupeTarget(_ candidate: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let dir = candidate.deletingLastPathComponent()
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 2
        while true {
            let next = dir.appendingPathComponent("\(stem) (\(n)).\(ext)")
            if !fm.fileExists(atPath: next.path) { return next }
            n += 1
        }
    }
}
