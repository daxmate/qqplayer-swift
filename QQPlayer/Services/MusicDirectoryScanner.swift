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

    /// 扫描单根目录，返回匹配启用扩展名的音频文件 URL。
    /// - 隐藏文件/目录：跳过（.skipsHiddenFiles）
    /// - 仅收录常规文件（isRegularFile）
    /// - 扩展名：小写比较，命中 enabledExtensions
    /// - 错误语义与旧 findMusicFiles 一致：enumerator 创建失败返回空数组（不抛错）；
    ///   遍历中 resourceValues 读取失败 → 抛出终止
    /// 同步版扫描（目录枚举与 resourceValues 读取本身就是同步 API）：供「必须在
    /// 当前调用栈里立刻拿到结果」的场景用（如会话线程上的 manifest 提供者）。
    /// 规则与 audioFiles(in:enabledExtensions:recursive:) 逐条一致——后者只是本函数的
    /// 后台队列包装（错误语义同旧实现：enumerator 创建失败 → 空数组；遍历中
    /// resourceValues 读取失败 → 抛出）。
    ///
    /// - Parameter recursive: `true`（缺省，行为与改动前逐字一致）= 递归枚举（macOS 多层
    ///   音乐文件夹）；`false` = **只收根下第一层**（iOS 曲库根 `Documents/Music` 的用户口径
    ///   是「单层」，子目录一律不收录）。
    static func audioFilesSync(
        in root: URL,
        enabledExtensions: [String],
        recursive: Bool = true
    ) throws -> [URL] {
        var musicFiles: [URL] = []
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .nameKey]

        guard recursive else {
            // 单层：只列根下条目（隐藏项跳过），不做目录下降。
            // 根不存在 / 无权限 → 空数组（与 enumerator 创建失败的语义一致）。
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                return musicFiles
            }
            for fileURL in entries {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                guard let isRegularFile = resourceValues.isRegularFile, isRegularFile else { continue }
                if enabledExtensions.contains(fileURL.pathExtension.lowercased()) {
                    musicFiles.append(fileURL)
                }
            }
            return musicFiles
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return musicFiles
        }
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            guard let isRegularFile = resourceValues.isRegularFile, isRegularFile else { continue }
            if enabledExtensions.contains(fileURL.pathExtension.lowercased()) {
                musicFiles.append(fileURL)
            }
        }
        return musicFiles
    }

    static func audioFiles(
        in root: URL,
        enabledExtensions: [String],
        recursive: Bool = true
    ) async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(
                        returning: try audioFilesSync(
                            in: root,
                            enabledExtensions: enabledExtensions,
                            recursive: recursive
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
