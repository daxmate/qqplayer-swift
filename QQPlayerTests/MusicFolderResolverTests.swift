//  MusicFolderResolverTests.swift
//  QQPlayerTests
//
//  音乐文件夹位置决策纯逻辑防回归测试（MusicFolderResolver）。
//
//  背景（2026-09 A0-prep）：iOS 音乐数据现存 iCloud ubiquity 容器（Cosmos 遗留），
//  将切到本地沙盒 Documents。A0 = 代码准备：决策上收为纯函数、行为不变——iOS 仍
//  双扫（本地沙盒 Documents 主 + iCloud ubiquity 容器 Documents 次），macOS 默认
//  ~/Music/QQPlayer + 设置页外部文件夹（多根去重）。任何改动让 iOS 主位置丢失 /
//  macOS 默认目录丢失都会让曲库变空，故锁定。

import Foundation
import Testing

@testable import QQPlayer

struct MusicFolderResolverTests {
    // MARK: - iOS 位置决策

    @Test("iOS：主位置 = 本地沙盒 Documents（传入目录原样返回）")
    func iosPrimaryIsDocumentsDirectory() {
        let docs = URL(fileURLWithPath: "/sandbox/Documents")
        let container = URL(fileURLWithPath: "/container")
        let locations = MusicFolderResolver.iosLocations(
            documentsDirectory: docs,
            ubiquityContainerURL: container
        )
        #expect(locations.primary == docs)
    }

    @Test("iOS：次位置 = ubiquity 容器 Documents 子目录（Cosmos 遗留布局）")
    func iosSecondaryIsUbiquityDocuments() {
        let docs = URL(fileURLWithPath: "/sandbox/Documents")
        let container = URL(fileURLWithPath: "/private/var/mobile/container")
        let locations = MusicFolderResolver.iosLocations(
            documentsDirectory: docs,
            ubiquityContainerURL: container
        )
        #expect(locations.secondary == container.appendingPathComponent("Documents", isDirectory: true))
        #expect(locations.secondary?.path == "/private/var/mobile/container/Documents")
    }

    @Test("iOS：无 ubiquity 容器（未登录 iCloud）→ 次位置为 nil，主位置不受影响")
    func iosNoContainerMeansNoSecondary() {
        let docs = URL(fileURLWithPath: "/sandbox/Documents")
        let locations = MusicFolderResolver.iosLocations(
            documentsDirectory: docs,
            ubiquityContainerURL: nil
        )
        #expect(locations.secondary == nil)
        #expect(locations.primary == docs)
    }

    @Test("iOS：双扫语义——次位置可用时两处都在（A0 过渡行为基线）")
    func iosBothLocationsWhenContainerAvailable() {
        let docs = URL(fileURLWithPath: "/sandbox/Documents")
        let container = URL(fileURLWithPath: "/container")
        let locations = MusicFolderResolver.iosLocations(
            documentsDirectory: docs,
            ubiquityContainerURL: container
        )
        // 现阶段两处都扫；迁移完成后此断言会变（主位置唯一），改动点即 A0 过渡点。
        #expect(locations.secondary != nil)
        #expect(locations.primary.path.hasSuffix("/Documents"))
    }

    // MARK: - macOS 默认目录

    @Test("macOS：默认曲库目录 = ~/Music/QQPlayer")
    func macDefaultFolder() {
        let home = URL(fileURLWithPath: "/Users/test")
        let url = MusicFolderResolver.macDefaultFolderURL(homeDirectory: home)
        #expect(url.path == "/Users/test/Music/QQPlayer")
    }

    @Test("macOS：默认目录与桌面版 qqplayer 区分（QQPlayerMac 命名空间）")
    func macDefaultSeparateFromDesktop() {
        let home = URL(fileURLWithPath: "/Users/test")
        let url = MusicFolderResolver.macDefaultFolderURL(homeDirectory: home)
        #expect(url.lastPathComponent == "QQPlayer")
    }

    // MARK: - macOS 多根列表（去重规则 = 旧 getMusicFolderURLs）

    @Test("macOS：默认目录恒在列（空配置）")
    func macFoldersDefaultAlwaysFirst() {
        let home = URL(fileURLWithPath: "/Users/test")
        let folders = MusicFolderResolver.macFolderURLs(homeDirectory: home, extraFolderPaths: [])
        #expect(folders == [MusicFolderResolver.macDefaultFolderURL(homeDirectory: home)])
        #expect(folders.count == 1)
    }

    @Test("macOS：外部文件夹追加在默认目录后（不冲掉默认）")
    func macFoldersAppendExtras() {
        let home = URL(fileURLWithPath: "/Users/test")
        let folders = MusicFolderResolver.macFolderURLs(
            homeDirectory: home,
            extraFolderPaths: ["~/Music/Vinyl", "/Volumes/External/Music"]
        )
        #expect(folders.map(\.path) == [
            "/Users/test/Music/QQPlayer",
            "/Users/test/Music/Vinyl",
            "/Volumes/External/Music",
        ])
    }

    @Test("macOS：外部路径与默认目录同路径（含 ~ 展开）→ 去重跳过")
    func macFoldersDedupeAgainstDefault() {
        let home = URL(fileURLWithPath: "/Users/test")
        // "~/Music/QQPlayer" 展开后与默认目录同路径 → 不重复添加
        let folders = MusicFolderResolver.macFolderURLs(
            homeDirectory: home,
            extraFolderPaths: ["~/Music/QQPlayer", "/Users/test/Music/QQPlayer"]
        )
        #expect(folders.count == 1)
        #expect(folders.map(\.path) == ["/Users/test/Music/QQPlayer"])
    }

    @Test("macOS：behavior 等价基线——默认目录绝不因 extra 丢失")
    func macFoldersNeverLoseDefault() {
        let home = URL(fileURLWithPath: "/Users/test")
        for extra in [["/a"], ["~/Music/QQPlayer"], ["/a", "/b", "~/Music/QQPlayer"]] {
            let folders = MusicFolderResolver.macFolderURLs(homeDirectory: home, extraFolderPaths: extra)
            #expect(folders.contains(MusicFolderResolver.macDefaultFolderURL(homeDirectory: home)))
        }
    }
}
