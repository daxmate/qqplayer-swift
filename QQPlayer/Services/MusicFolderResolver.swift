//  MusicFolderResolver.swift
//  QQPlayer
//
//  音乐文件夹位置决策纯逻辑（平台无关，可单测）。仿 DatabasePathResolver 范式。
//
//  背景：M3-2（2026-09-10）iOS 音乐存储已从 iCloud ubiquity 容器（Cosmos 遗留）
//  迁移到本地沙盒 Documents。iOS 唯一位置 = 沙盒 Documents（LibraryIndexer 直接
//  使用 FileManager 扫 Documents）；macOS 仍扫默认曲库目录 + 设置页添加的外部文件夹。
//

import Foundation

enum MusicFolderResolver {
    /// iOS 音乐位置（M3-2 起：唯一位置 = 本地沙盒 Documents；iCloud ubiquity 容器已退役）。
    /// 注：这是**容器 Documents**，不是曲库根——曲库根见 `iosMusicLibraryDirectoryURL()`。
    static func iosDocumentsDirectoryURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// iOS 曲库根（2026-09-22 曲库文件夹化）：`Documents/Music`。
    /// 扫描只认它（单层不递归），`track.path` 存相对它的相对路径。
    /// 唯一事实源仍是 `LibraryRoot.musicRootURL()`——这里只做平台命名的转接。
    static func iosMusicLibraryDirectoryURL() -> URL {
        LibraryRoot.musicRootURL()
    }

    /// macOS 默认曲库目录：~/Music/QQPlayer（用户拍板 2026-08-30：本地文件夹扫描）。
    static func macDefaultFolderURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("QQPlayer", isDirectory: true)
    }

    /// **同步子系统的曲库根（缺省值语义）**：与各装配点注入的根同源。
    ///
    /// ⚠️ macOS（M2，2026-09-28）：本访问器在 macOS 返回的是**默认根**
    /// （`macDefaultFolderURL`，不含用户指定）——它已**不再是 macOS 的生产取值点**：
    /// macOS 消费者一律走 `MacLibraryRoot.resolvedRootURL`（唯一入口），或共享 Core 里
    /// 的分平台缺省 `DatabaseSyncCollectionFacts.defaultLibraryRoot`。
    /// 保留它只为「默认值语义」与 iOS 分支（iOS = 沙盒 `Documents/Music`）。
    ///
    /// 为什么要有这个访问器：同步装配点（Mac 工厂 / iOS 被动中心 / 曲库 host）都在
    /// 构造时显式注入根（测试可注入）；但**入库路径**（`DatabaseManager.upsertTrack`）
    /// 的挂起重放触发点拿不到装配点上下文，需要一个**同一事实源**的根来换算
    /// `rel:` 命名空间的挂起键——不能在那里另写一套平台判断。
    /// 平台分叉与 `DatabaseSyncCollectionFacts.defaultLibraryRoot` 同口径（生产装配点
    /// 用的就是这两个值）。
    static var syncLibraryRoot: URL {
        #if os(macOS)
            macDefaultFolderURL(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        #else
            iosMusicLibraryDirectoryURL()
        #endif
    }

    /// macOS 曲库扫描根列表：默认 ~/Music/QQPlayer 恒在列，加上设置页「音乐库」
    /// 添加的外部文件夹（多根共存，与默认目录同路径者去重）。行为与旧
    /// StateManager.getMusicFolderURLs() 完全一致（A0 仅上收实现位置）。
    static func macFolderURLs(homeDirectory: URL, extraFolderPaths: [String]) -> [URL] {
        let defaultURL = macDefaultFolderURL(homeDirectory: homeDirectory)
        var folders = [defaultURL]
        let defaultPath = defaultURL.standardizedFileURL.path
        for path in extraFolderPaths {
            // ~ 展开基于注入的 homeDirectory（而非系统真实 home），保证可注入可测
            let expanded = expandedPath(path, homeDirectory: homeDirectory)
            let url = URL(fileURLWithPath: expanded)
            if url.standardizedFileURL.path != defaultPath {
                folders.append(url)
            }
        }
        return folders
    }

    /// macOS 曲库根（**唯一地址**）的纯逻辑：指定路径存在 → 用它；否则回退默认。
    ///
    /// 用户拍板口径（2026-09-28）：「曲库只能有一个地址」——要么默认 `~/Music/QQPlayer`，
    /// 要么用户指定；**不接受「多根 + 谁排第一」**。用户指定的目录**不存在时静默回退默认**
    /// （不报错、也不去创建那个指定目录）。
    ///
    /// 本函数**不做任何 IO**（文件头契约：纯逻辑、可单测）：目录是否存在由调用方以
    /// `directoryExists` 闭包注入（照 `macFolderURLs` 的注入风格）。对本根做 `fileExists` /
    /// `createDirectory` 的**唯一** IO 入口是 `QQPlayer/Mac/MacLibraryRoot.swift`。
    static func macLibraryRootURL(
        homeDirectory: URL,
        specifiedPath: String?,
        directoryExists: (URL) -> Bool
    ) -> URL {
        if let specifiedPath, !specifiedPath.isEmpty {
            let expanded = expandedPath(specifiedPath, homeDirectory: homeDirectory)
            let url = URL(fileURLWithPath: expanded)
            if directoryExists(url) { return url }
        }
        return macDefaultFolderURL(homeDirectory: homeDirectory)
    }

    /// `~` / `~/…` 展开（基准 = 注入的 `homeDirectory`，保证可注入可测）。
    /// **唯一实现**：`macFolderURLs` 与 `macLibraryRootURL` 共用，避免两处各写一套展开规则。
    static func expandedPath(_ path: String, homeDirectory: URL) -> String {
        let homePath = homeDirectory.standardizedFileURL.path
        if path == "~" { return homePath }
        if path.hasPrefix("~/") { return homePath + "/" + String(path.dropFirst(2)) }
        return path
    }
}
