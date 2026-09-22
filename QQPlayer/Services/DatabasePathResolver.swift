//  DatabasePathResolver.swift
//  QQPlayer
//
//  数据库文件路径决策纯逻辑（平台无关，可单测）。
//
//  背景（2026-08-31 首测 bug）：getDatabaseURL() 在 macOS 走 iOS 遗留的 App Group
//  容器路径（group.com.daxmate.qqplayer.ios），macOS 无此容器目录，GRDB 打开必失败
//  → in-memory fallback → 扫描全部白跑、库永远为空。路径决策上收为纯函数，防回归。
//

import Foundation

enum DatabasePathResolver {
    /// macOS 数据库目录：Application Support/QQPlayerMac（与桌面版 qqplayer/ 区分）。
    /// - appSupportRoot：FileManager 的 applicationSupportDirectory（注入便于测试）
    static func macDatabaseURL(appSupportRoot: URL) -> URL {
        let dir = appSupportRoot.appendingPathComponent("QQPlayerMac", isDirectory: true)
        return dir.appendingPathComponent("qqplayer.db")
    }

    /// iOS 数据库路径：优先 App Group 容器（与 Siri 扩展共享），否则隐藏根 `db/` 兜底。
    /// - fallbackDirectory：无 App Group 容器时的回退目录（生产 = `LibraryRoot.databaseDirectoryURL()`，
    ///   即 `<Documents>/.qqplayer/db`；2026-09-22 隐藏布局改造前是 Documents 根）
    static func iosDatabaseURL(
        appGroupContainer: URL?,
        fallbackDirectory: URL
    ) -> URL {
        if let appGroupContainer {
            return appGroupContainer.appendingPathComponent("qqplayer.db")
        } else {
            return fallbackDirectory.appendingPathComponent(LibraryRoot.musicLibraryFileName)
        }
    }
}
