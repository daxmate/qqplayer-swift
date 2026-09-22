//  DatabasePathResolverTests.swift
//  QQPlayerTests
//
//  数据库路径决策防回归测试（DatabasePathResolver）。
//
//  背景（2026-08-31 首测 bug）：macOS 走 iOS 的 App Group 容器路径，目录不存在
//  → GRDB 打开失败 → in-memory fallback → 扫描白跑、库永远为空。
//  锁定：macOS 必须落在 Application Support/QQPlayerMac/qqplayer.db（与桌面版区分）。
//

import Foundation
import Testing

@testable import QQPlayer

struct DatabasePathResolverTests {
    @Test("macOS 路径：Application Support/QQPlayerMac/qqplayer.db")
    func macPathUsesApplicationSupport() {
        let root = URL(fileURLWithPath: "/Users/test/Library/Application Support")
        let url = DatabasePathResolver.macDatabaseURL(appSupportRoot: root)
        #expect(url.path == "/Users/test/Library/Application Support/QQPlayerMac/qqplayer.db")
        #expect(url.pathExtension == "db")
    }

    @Test("macOS 路径：与桌面版 qqplayer 目录区分")
    func macPathSeparateFromDesktop() {
        let root = URL(fileURLWithPath: "/Users/test/Library/Application Support")
        let url = DatabasePathResolver.macDatabaseURL(appSupportRoot: root)
        // 桌面版在 Application Support/qqplayer/qqplayer.db，macOS 原生版必须不同目录
        #expect(url.deletingLastPathComponent().lastPathComponent == "QQPlayerMac")
    }

    @Test("iOS 有 App Group 容器：用容器内 qqplayer.db")
    func iosUsesAppGroupWhenAvailable() {
        let container = URL(fileURLWithPath: "/group/container")
        let docs = URL(fileURLWithPath: "/docs")
        let url = DatabasePathResolver.iosDatabaseURL(
            appGroupContainer: container, fallbackDirectory: docs)
        #expect(url.path == "/group/container/qqplayer.db")
    }

    @Test("iOS 无 App Group 容器：Documents 兜底 MusicLibrary.sqlite")
    func iosFallsBackToDocuments() {
        let docs = URL(fileURLWithPath: "/docs")
        let url = DatabasePathResolver.iosDatabaseURL(
            appGroupContainer: nil, fallbackDirectory: docs)
        // 2026-09-22 隐藏布局：参数语义从「Documents 根」改成「回退目录」
        // （生产 = `LibraryRoot.databaseDirectoryURL()`，即 `<Documents>/.qqplayer/db`）；
        // 本用例传什么目录就落在什么目录，断言不变。
        #expect(url.path == "/docs/MusicLibrary.sqlite")
    }
}
