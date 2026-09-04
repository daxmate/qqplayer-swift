//  MacImportNaming.swift
//  QQPlayer
//
//  文件拖入导入的目标文件名决策纯逻辑（平台无关，可单测）。
//
//  对齐 web 版 useDragImport/import API 语义（2026-09-03 B 组调研）：
//  - 复制进曲库，不覆盖源文件
//  - 目标已存在同名 → 加后缀（web: 同名加后缀）
//  - 只收音频（非音频 skipped）
//

import Foundation

enum MacImportNaming {
    /// 拖入导入接受格式 = 引擎支持全集（web 版导入白名单独立静态的等价物；
    /// 不随「文件类型设置」裁剪——取消格式只影响扫描收录，不影响显式导入，
    /// 与 web useDragImport 静态白名单行为一致）。
    static func isImportable(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return LibraryAudioFormats.allSupported.contains(ext)
    }

    /// 目标目录里可用（不冲突）的最终 URL：已存在则 "name 2.ext"、递增。
    static func uniqueDestinationURL(in directory: URL, sourceName: String) -> URL {
        let base = (sourceName as NSString).deletingPathExtension
        let ext = (sourceName as NSString).pathExtension
        let fileManager = FileManager.default

        var candidate = directory.appendingPathComponent(sourceName)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        var index = 2
        while true {
            let nameWithSuffix = ext.isEmpty
                ? "\(base) \(index)"
                : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(nameWithSuffix)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}
