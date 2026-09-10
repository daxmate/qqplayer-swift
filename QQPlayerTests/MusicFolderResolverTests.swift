//  MusicFolderResolverTests.swift
//  QQPlayerTests
//
//  音乐文件夹位置决策纯逻辑防回归测试（MusicFolderResolver）。
//
//  背景（M3-2，2026-09-10）：iOS 音乐存储已迁移到本地沙盒 Documents（退役 iCloud
//  ubiquity 容器双位置）——iOS 唯一位置 = 沙盒 Documents（LibraryIndexer 直接
//  FileManager 扫 Documents）；macOS 默认 ~/Music/QQPlayer + 设置页外部文件夹
//  （多根去重）。任何改动让 macOS 默认目录丢失都会让曲库变空，故锁定。

import Foundation
import Testing

@testable import QQPlayer

struct MusicFolderResolverTests {
    // MARK: - iOS 唯一位置（M3-2：沙盒 Documents，退役 ubiquity 双位置）

    @Test("iOS：唯一位置 = 沙盒 Documents（不再有 iCloud 次位置概念）")
    func iosSingleLocationIsDocuments() {
        // iosDocumentsDirectoryURL 直接读 FileManager 沙盒 Documents——断言其语义
        // 为 documentDirectory（不抛、路径以 Documents 结尾）。
        let url = MusicFolderResolver.iosDocumentsDirectoryURL()
        #expect(url.lastPathComponent == "Documents")
        let fileManagerDocs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #expect(url == fileManagerDocs)
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
