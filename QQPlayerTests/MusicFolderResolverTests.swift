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

    // MARK: - macOS 曲库根（**唯一地址**）纯逻辑（2026-09-28）

    // 用户拍板口径：曲库只能有一个地址——要么默认 ~/Music/QQPlayer，要么用户指定；
    // 指定目录不存在 → 静默回退默认（不报错、不建指定目录）。is 本函数零 IO：
    // 目录存在性由注入闭包给（可注入可测）。

    @Test("macOS 曲库根：未指定 → 默认目录")
    func macLibraryRootUnspecifiedFallsBackToDefault() {
        let home = URL(fileURLWithPath: "/Users/test")
        let url = MusicFolderResolver.macLibraryRootURL(
            homeDirectory: home,
            specifiedPath: nil,
            directoryExists: { _ in true }
        )
        #expect(url.path == "/Users/test/Music/QQPlayer")
    }

    @Test("macOS 曲库根：指定且存在 → 用指定")
    func macLibraryRootSpecifiedExistingWins() {
        let home = URL(fileURLWithPath: "/Users/test")
        let url = MusicFolderResolver.macLibraryRootURL(
            homeDirectory: home,
            specifiedPath: "~/Music/Vinyl",
            directoryExists: { $0.path == "/Users/test/Music/Vinyl" }
        )
        #expect(url.path == "/Users/test/Music/Vinyl")
    }

    @Test("macOS 曲库根：指定但目录不存在 → 回退默认（不报错、不建指定目录）")
    func macLibraryRootSpecifiedMissingFallsBackToDefault() {
        let home = URL(fileURLWithPath: "/Users/test")
        let url = MusicFolderResolver.macLibraryRootURL(
            homeDirectory: home,
            specifiedPath: "/Volumes/Gone/Music",
            directoryExists: { _ in false }
        )
        #expect(url.path == "/Users/test/Music/QQPlayer")
    }

    @Test("macOS 曲库根：空串视为未指定 → 默认")
    func macLibraryRootEmptySpecifiedFallsBackToDefault() {
        let home = URL(fileURLWithPath: "/Users/test")
        let url = MusicFolderResolver.macLibraryRootURL(
            homeDirectory: home,
            specifiedPath: "",
            directoryExists: { _ in true }
        )
        #expect(url.path == "/Users/test/Music/QQPlayer")
    }

    @Test("macOS 曲库根：~ 展开基于注入的 homeDirectory（非系统真实 home）")
    func macLibraryRootTildeExpandsAgainstInjectedHome() {
        let home = URL(fileURLWithPath: "/Users/injected")
        var probedPath: String?
        let url = MusicFolderResolver.macLibraryRootURL(
            homeDirectory: home,
            specifiedPath: "~/Music/Specified",
            directoryExists: { probedPath = $0.path; return true }
        )
        // 传给 directoryExists 的必须是展开后的注入 home 路径（不是真实 ~）
        #expect(probedPath == "/Users/injected/Music/Specified")
        #expect(url.path == "/Users/injected/Music/Specified")
    }
}
