//  MacFolderWatchPolicy.swift
//  QQPlayer
//
//  macOS 曲库文件夹 FSEvents 实时监控的决策纯逻辑（平台无关，可单测）。
//
//  对齐 web 版 watchdog 语义（2026-09-03 B 组调研）：
//  - 递归监听曲库文件夹，事件去抖后触发全量重扫（Swift 端现有
//    scanMusicFolder 本就是全量 + reconcile，无需增量）
//  - 忽略噪声事件：隐藏文件/目录、.DS_Store、Finder 元数据
//  - 只监控当前存在的文件夹（FSEvents 对不存在的路径不产生事件；
//    目录缺失时沿用「启动全扫 + 手动刷新」，与设置页添加文件夹路径一致）
//

import Foundation

enum MacFolderWatchPolicy {
    /// 去抖窗口（web 版 WATCH_DEBOUNCE_SECONDS=2.0 对齐）。
    static let debounceNanoseconds: UInt64 = 2_000_000_000

    /// 归一化 + 去重 + 只保留当前存在的目录。
    /// 配置顺序保留（首项为默认 ~/Music/QQPlayer 的语义由 StateManager 保证）。
    static func relevantFolders(_ configured: [URL]) -> [URL] {
        var seen = Set<String>()
        return configured
            .map { $0.standardizedFileURL }
            .filter { url in
                let key = url.path
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return FileManager.default.fileExists(atPath: key)
            }
    }

    /// 事件路径是否应忽略（噪声过滤）。
    /// - 任一路径段以 "." 开头：隐藏文件/目录（.DS_Store、.git 等）
    /// - Finder AppleDouble 元数据（._*）
    static func shouldIgnore(eventPath path: String) -> Bool {
        let components = (path as NSString).pathComponents
        for component in components.dropFirst() { // dropFirst: 去掉根 "/"
            if component.hasPrefix(".") {
                return true
            }
            if component.hasPrefix("._") {
                return true
            }
        }
        return false
    }
}
