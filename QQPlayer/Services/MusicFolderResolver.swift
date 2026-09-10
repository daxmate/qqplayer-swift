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
    static func iosDocumentsDirectoryURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// macOS 默认曲库目录：~/Music/QQPlayer（用户拍板 2026-08-30：本地文件夹扫描）。
    static func macDefaultFolderURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("QQPlayer", isDirectory: true)
    }

    /// macOS 曲库扫描根列表：默认 ~/Music/QQPlayer 恒在列，加上设置页「音乐库」
    /// 添加的外部文件夹（多根共存，与默认目录同路径者去重）。行为与旧
    /// StateManager.getMusicFolderURLs() 完全一致（A0 仅上收实现位置）。
    static func macFolderURLs(homeDirectory: URL, extraFolderPaths: [String]) -> [URL] {
        let defaultURL = macDefaultFolderURL(homeDirectory: homeDirectory)
        var folders = [defaultURL]
        let defaultPath = defaultURL.standardizedFileURL.path
        let homePath = homeDirectory.standardizedFileURL.path
        for path in extraFolderPaths {
            // ~ 展开基于注入的 homeDirectory（而非系统真实 home），保证可注入可测
            let expanded: String
            if path == "~" {
                expanded = homePath
            } else if path.hasPrefix("~/") {
                expanded = homePath + "/" + String(path.dropFirst(2))
            } else {
                expanded = path
            }
            let url = URL(fileURLWithPath: expanded)
            if url.standardizedFileURL.path != defaultPath {
                folders.append(url)
            }
        }
        return folders
    }
}
