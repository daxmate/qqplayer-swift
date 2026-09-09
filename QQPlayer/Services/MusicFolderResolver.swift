//  MusicFolderResolver.swift
//  QQPlayer
//
//  音乐文件夹位置决策纯逻辑（平台无关，可单测）。仿 DatabasePathResolver 范式。
//
//  背景（2026-09 A0-prep）：iOS 音乐数据现存 iCloud ubiquity 容器（Cosmos 遗留）。
//  为适配多平台同步（每端本地文件库形态），iOS 将切到本地沙盒 Documents。
//  A0 = 代码准备：位置决策上收为纯函数，现阶段行为不变——iOS 仍双扫（本地沙盒
//  Documents 为主位置 + iCloud ubiquity 容器为次位置）；macOS 仍扫默认曲库目录
//  + 设置页添加的外部文件夹。数据迁移 / iCloud 代码删除 / 行为切换不在 A0 范围。
//

import Foundation

enum MusicFolderResolver {
    /// iOS 音乐位置（A0 过渡：主 = 本地沙盒 Documents，次 = iCloud ubiquity 容器 Documents）。
    struct IOSLocations: Equatable {
        /// 本地沙盒 Documents（主位置；迁移完成后为唯一数据位置）
        let primary: URL
        /// iCloud ubiquity 容器 Documents（次位置，Cosmos 遗留；迁移完成后移除）
        let secondary: URL?
    }

    /// iOS 位置决策：主 = 本地沙盒 Documents，次 = iCloud ubiquity 容器 Documents。
    /// - documentsDirectory：FileManager 沙盒 Documents（主位置）
    /// - ubiquityContainerURL：ubiquity 容器根（可能 nil——未登录 iCloud / 容器未解析）
    static func iosLocations(
        documentsDirectory: URL,
        ubiquityContainerURL: URL?
    ) -> IOSLocations {
        IOSLocations(
            primary: documentsDirectory,
            // A0 过渡：iCloud 为次位置，迁移完成后移除
            secondary: ubiquityContainerURL?
                .appendingPathComponent("Documents", isDirectory: true)
        )
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
        for path in extraFolderPaths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if url.standardizedFileURL.path != defaultPath {
                folders.append(url)
            }
        }
        return folders
    }
}
