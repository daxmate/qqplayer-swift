//  MacImportNamingTests.swift
//  QQPlayerTests
//
//  文件拖入导入的目标命名纯逻辑防回归测试（web 版 useDragImport 对齐：
//  复制进曲库、同名加后缀、只收音频）。改坏命名/过滤规则会在 CI 暴露。

import Foundation
import Testing

@testable import QQPlayer

struct MacImportNamingTests {
    // MARK: - isImportable（只收引擎支持格式）

    @Test("支持格式可导入")
    func supportedFormatsImportable() {
        for ext in LibraryAudioFormats.allSupported {
            let url = URL(fileURLWithPath: "/tmp/song.\(ext)")
            #expect(MacImportNaming.isImportable(url: url), "\(ext) 应可导入")
        }
    }

    @Test("非音频/未知扩展名不可导入")
    func nonAudioRejected() {
        #expect(!MacImportNaming.isImportable(url: URL(fileURLWithPath: "/tmp/song.mp4")))
        #expect(!MacImportNaming.isImportable(url: URL(fileURLWithPath: "/tmp/song.txt")))
        #expect(!MacImportNaming.isImportable(url: URL(fileURLWithPath: "/tmp/noext")))
        #expect(!MacImportNaming.isImportable(url: URL(fileURLWithPath: "/tmp/song.wma")))
    }

    @Test("扩展名大小写不敏感")
    func extensionCaseInsensitive() {
        #expect(MacImportNaming.isImportable(url: URL(fileURLWithPath: "/tmp/song.FLAC")))
        #expect(MacImportNaming.isImportable(url: URL(fileURLWithPath: "/tmp/song.Mp3")))
    }

    // MARK: - uniqueDestinationURL（同名加后缀）

    @Test("目标不存在 → 直接用原名")
    func noConflictUsesOriginalName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dest = MacImportNaming.uniqueDestinationURL(in: dir, sourceName: "song.flac")
        #expect(dest.lastPathComponent == "song.flac")
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("已存在同名 → 加 ' 2' 后缀")
    func conflictGetsSuffix() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = dir.appendingPathComponent("song.flac")
        try Data("existing".utf8).write(to: existing)

        let dest = MacImportNaming.uniqueDestinationURL(in: dir, sourceName: "song.flac")
        #expect(dest.lastPathComponent == "song 2.flac")
    }

    @Test("同名连续占用 → 递增后缀直到可用")
    func repeatedConflictIncrements() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["song.flac", "song 2.flac", "song 3.flac"] {
            try Data(name.utf8).write(to: dir.appendingPathComponent(name))
        }

        let dest = MacImportNaming.uniqueDestinationURL(in: dir, sourceName: "song.flac")
        #expect(dest.lastPathComponent == "song 4.flac")
    }

    @Test("无扩展名文件冲突也加后缀")
    func extensionlessConflict() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("x".utf8).write(to: dir.appendingPathComponent("song"))
        let dest = MacImportNaming.uniqueDestinationURL(in: dir, sourceName: "song")
        #expect(dest.lastPathComponent == "song 2")
    }
}
