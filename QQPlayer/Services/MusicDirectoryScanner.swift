//  MusicDirectoryScanner.swift
//  QQPlayer
//
//  音乐目录扫描共享实现（iOS/macOS 共用，可单测）。
//
//  背景（2026-09 A0-prep）：目录递归枚举逻辑原先内嵌在 LibraryIndexer.findMusicFiles
//  （iOS fallback 双扫 / offline 扫描与 macOS 多文件夹扫描各自调用）。A0 抽为共享
//  纯函数：音频扩展名过滤 / 忽略隐藏 / 常规文件判定规则单一事实源，两端只提供
//  "要扫的根 URL 列表"。行为与旧 findMusicFiles 逐条一致（含错误语义）。
//

import Foundation

enum MusicDirectoryScanner {
    /// 启用扩展名解析：设置里 audioExtensions 为空（未配置/旧数据）→ 回落默认全集。
    /// 行为与旧 LibraryIndexer.findMusicFiles 内联逻辑一致（2026-09-03 B 组：扫描
    /// 只收录启用格式，取消格式后重扫从曲库移除该格式曲目）。
    static func enabledExtensions(from settings: DeleteSettings) -> [String] {
        settings.audioExtensions.isEmpty
            ? LibraryAudioFormats.defaultEnabled
            : settings.audioExtensions
    }

    /// 递归扫描单根目录，返回匹配启用扩展名的音频文件 URL。
    /// - 隐藏文件/目录：跳过（.skipsHiddenFiles）
    /// - 仅收录常规文件（isRegularFile）
    /// - 扩展名：小写比较，命中 enabledExtensions
    /// - 错误语义与旧 findMusicFiles 一致：enumerator 创建失败返回空数组（不抛错）；
    ///   遍历中 resourceValues 读取失败 → 抛出终止
    static func audioFiles(in root: URL, enabledExtensions: [String]) async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    var musicFiles: [URL] = []

                    let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
                    let directoryEnumerator = FileManager.default.enumerator(
                        at: root,
                        includingPropertiesForKeys: resourceKeys,
                        options: [.skipsHiddenFiles]
                    )

                    guard let enumerator = directoryEnumerator else {
                        continuation.resume(returning: musicFiles)
                        return
                    }

                    for case let fileURL as URL in enumerator {
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))

                        guard let isRegularFile = resourceValues.isRegularFile, isRegularFile else {
                            continue
                        }

                        let pathExtension = fileURL.pathExtension.lowercased()
                        if enabledExtensions.contains(pathExtension) {
                            musicFiles.append(fileURL)
                        }
                    }

                    continuation.resume(returning: musicFiles)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
