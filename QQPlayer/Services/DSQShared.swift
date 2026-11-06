//
//  DSQShared.swift
//  QQPlayer
//
//  `DSQSharedPaths` 的 App 侧入口：解析路径 + 走 AppLog 记录实际分支（线上排查用）。
//
//  只有本文件把「解析结果」翻译成日志；纯解析层保持无依赖，便于脚本 harness 直编。
//

import Foundation

enum DSQShared {
    /// 解析共享资源根（每次调用都会记一条 .migration 日志）。
    static func resolve(
        environment: [String: String]? = nil,
        fileManager: FileManager = .default
    ) -> DSQSharedLocations {
        let resolver = DSQSharedResolver(environment: environment, fileManager: fileManager)
        let locations = resolver.resolve()
        var message = "🗂️ 共享资源根 source=\(locations.source.rawValue) root=\(locations.root.path)"
        if let note = locations.fallbackNote {
            message += " fallback=\(note)"
        }
        AppLog.info(.migration, message)
        return locations
    }

    /// 便捷访问（**只用于一次性读取**；热路径请先 `resolve()` 再复用）。
    static var root: URL { resolve().root }
    static var modelsRoot: URL { resolve().modelsRoot }
    static var booksRoot: URL { resolve().booksRoot }
    static var dictionariesRoot: URL { resolve().dictionariesRoot }
    static var audiobooksRoot: URL { resolve().audiobooksRoot }
}
