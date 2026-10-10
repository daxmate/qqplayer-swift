//
//  MacDocumentsStorageRelocationTests.swift
//  QQPlayerTests
//
//  macOS App 数据迁出 ~/Documents → Application Support/QQPlayerMac 的迁移器单测
//  （MacDocumentsStorageRelocation，2026-10-10）。
//
//  口径：迁移器逻辑平台无关（纯 Foundation），故在 iOS 测试 target 用**合成目录**覆盖 ——
//  真机 ~/Documents 数据本地一律不碰（生产真机验证不在本批本地范围，见任务包 §6.7）。
//  用注入的 FileManager 把 .documentDirectory / .applicationSupportDirectory 同时重定向到临时根。
//

import Foundation
import Testing

@testable import QQPlayer

/// 把 `.documentDirectory` / `.applicationSupportDirectory` 都重定向到临时根的 FileManager。
class RelocationTestFileManager: FileManager {
    let documentsRoot: URL
    let appSupportRoot: URL

    init(documentsRoot: URL, appSupportRoot: URL) {
        self.documentsRoot = documentsRoot
        self.appSupportRoot = appSupportRoot
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        if domainMask.contains(.userDomainMask) {
            if directory == .documentDirectory { return [documentsRoot] }
            if directory == .applicationSupportDirectory { return [appSupportRoot] }
        }
        return super.urls(for: directory, in: domainMask)
    }
}

/// 对指定源路径的 move 抛错的 FileManager（测「失败不中断 + 源保留」）。
final class FailingMoveFileManager: RelocationTestFileManager {
    var failSourcePath: String?

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if let failSourcePath, srcURL.path == failSourcePath {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

@Suite("macOS App 数据迁出 ~/Documents（MacDocumentsStorageRelocation）", .serialized)
struct MacDocumentsStorageRelocationTests {
    private let fm = FileManager.default

    private func makeRoots() -> (documents: URL, appSupport: URL, cleanup: URL) {
        let base = fm.temporaryDirectory
            .appendingPathComponent("mac-relocation-\(UUID().uuidString)", isDirectory: true)
        let documents = base.appendingPathComponent("Documents", isDirectory: true)
        let appSupport = base.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return (documents, appSupport, base)
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "mac-relocation-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func write(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// App 数据根（注入 Application Support + QQPlayerMac）。
    private func appDataRoot(_ roots: (documents: URL, appSupport: URL, cleanup: URL)) -> URL {
        roots.appSupport.appendingPathComponent(LibraryRoot.macAppSupportDirectoryName, isDirectory: true)
    }

    @Test("合成旧布局 → 迁移：新位置内容一致、旧位置已清空、完成门置位后二次幂等")
    func migratesAllItemsThenIdempotent() throws {
        let roots = makeRoots()
        defer { try? fm.removeItem(at: roots.cleanup) }
        let fileManager = RelocationTestFileManager(documentsRoot: roots.documents, appSupportRoot: roots.appSupport)
        let defaults = freshDefaults()
        let docs = roots.documents
        let appRoot = appDataRoot(roots)

        try write(docs.appendingPathComponent("Artwork/cover-a.jpg"), "IMG")
        try write(docs.appendingPathComponent("ArtworkMapping.plist"), "PLIST")
        try write(docs.appendingPathComponent("Lyrics/l1.json"), "L")
        try write(docs.appendingPathComponent("lyrics-aligned/a1.json"), "A")
        try write(docs.appendingPathComponent("lyrics-cache/tracks/t1.json"), "T")
        try write(docs.appendingPathComponent("SpotifyCache/s.json"), "S")
        try write(docs.appendingPathComponent("DiscogsCache/d.json"), "D")
        try write(docs.appendingPathComponent("HybridMusicCache/h.json"), "H")
        try write(docs.appendingPathComponent("meta/m.json"), "M")
        try write(docs.appendingPathComponent("Logs/app.log"), "LOG")
        try write(docs.appendingPathComponent("qqplayer-playlists/p1.json"), "P")
        try write(docs.appendingPathComponent("qqplayer-favorites.json"), "FAV")
        try write(docs.appendingPathComponent("qqplayer-player-state.json"), "PS")
        try write(docs.appendingPathComponent("pairing.json"), "PAIR")
        try write(docs.appendingPathComponent(LibraryRoot.externalBookmarksFileName), "BM")

        let summary = MacDocumentsStorageRelocation.run(fileManager: fileManager, defaults: defaults)
        #expect(summary.failedCount == 0)
        #expect(summary.skippedCount == 0)
        #expect(summary.movedCount == MacDocumentsStorageRelocation.items.count)

        // 新位置内容一致
        #expect(try read(appRoot.appendingPathComponent("Artwork/cover-a.jpg")) == "IMG")
        #expect(try read(appRoot.appendingPathComponent("Artwork/ArtworkMapping.plist")) == "PLIST")
        #expect(try read(appRoot.appendingPathComponent("Lyrics/l1.json")) == "L")
        #expect(try read(appRoot.appendingPathComponent("lyrics-aligned/a1.json")) == "A")
        #expect(try read(appRoot.appendingPathComponent("lyrics-cache/tracks/t1.json")) == "T")
        #expect(try read(appRoot.appendingPathComponent("SpotifyCache/s.json")) == "S")
        #expect(try read(appRoot.appendingPathComponent("DiscogsCache/d.json")) == "D")
        #expect(try read(appRoot.appendingPathComponent("HybridMusicCache/h.json")) == "H")
        #expect(try read(appRoot.appendingPathComponent("meta/m.json")) == "M")
        #expect(try read(appRoot.appendingPathComponent("Logs/app.log")) == "LOG")
        #expect(try read(appRoot.appendingPathComponent("qqplayer-playlists/p1.json")) == "P")
        #expect(try read(appRoot.appendingPathComponent("qqplayer-favorites.json")) == "FAV")
        #expect(try read(appRoot.appendingPathComponent("qqplayer-player-state.json")) == "PS")
        #expect(try read(appRoot.appendingPathComponent("pairing.json")) == "PAIR")
        #expect(try read(appRoot.appendingPathComponent(LibraryRoot.externalBookmarksFileName)) == "BM")

        // 旧位置已清空
        for legacy in [
            "Artwork", "ArtworkMapping.plist", "Lyrics", "lyrics-aligned", "lyrics-cache",
            "SpotifyCache", "DiscogsCache", "HybridMusicCache", "meta", "Logs",
            "qqplayer-playlists", "qqplayer-favorites.json", "qqplayer-player-state.json",
            "pairing.json", LibraryRoot.externalBookmarksFileName,
        ] {
            #expect(!fm.fileExists(atPath: docs.appendingPathComponent(legacy).path), "旧位置未清空：\(legacy)")
        }

        // 完成门已置位 → 二次运行幂等跳过
        let second = MacDocumentsStorageRelocation.run(fileManager: fileManager, defaults: defaults)
        #expect(second.alreadyCompleted)
        #expect(second.movedCount == 0)
        #expect(second.failedCount == 0)
    }

    @Test("冲突不覆盖：目标已存在 → 跳过并计数，源与目标内容都不变")
    func conflictDoesNotOverwrite() throws {
        let roots = makeRoots()
        defer { try? fm.removeItem(at: roots.cleanup) }
        let fileManager = RelocationTestFileManager(documentsRoot: roots.documents, appSupportRoot: roots.appSupport)
        let defaults = freshDefaults()
        let docs = roots.documents
        let appRoot = appDataRoot(roots)

        try write(docs.appendingPathComponent("Lyrics/l1.json"), "OLD")
        // 目标侧已有同名目录（内容不同）——不得被覆盖。
        try write(appRoot.appendingPathComponent("Lyrics/l1.json"), "NEW")

        let summary = MacDocumentsStorageRelocation.run(fileManager: fileManager, defaults: defaults)
        #expect(summary.skipped.contains("Lyrics"))
        #expect(try read(appRoot.appendingPathComponent("Lyrics/l1.json")) == "NEW")
        #expect(try read(docs.appendingPathComponent("Lyrics/l1.json")) == "OLD")
    }

    @Test("失败不中断：单项 move 失败 → 源保留、其余项照搬、完成门不置位、下次重试成功")
    func failureDoesNotInterrupt() throws {
        let roots = makeRoots()
        defer { try? fm.removeItem(at: roots.cleanup) }
        let fileManager = FailingMoveFileManager(documentsRoot: roots.documents, appSupportRoot: roots.appSupport)
        let defaults = freshDefaults()
        let docs = roots.documents
        let appRoot = appDataRoot(roots)

        try write(docs.appendingPathComponent("Artwork/cover-a.jpg"), "IMG")
        try write(docs.appendingPathComponent("Lyrics/l1.json"), "L")
        fileManager.failSourcePath = docs.appendingPathComponent("Artwork", isDirectory: true).path

        let summary = MacDocumentsStorageRelocation.run(fileManager: fileManager, defaults: defaults)
        #expect(summary.failedCount == 1)
        #expect(summary.moved.contains("Lyrics"))
        #expect(!summary.didComplete)
        // 失败项源保留；其余项照搬（失败不中断）
        #expect(fm.fileExists(atPath: docs.appendingPathComponent("Artwork/cover-a.jpg").path))
        #expect(try read(appRoot.appendingPathComponent("Lyrics/l1.json")) == "L")
        // 完成门未置位 → 下次启动重试
        #expect(!defaults.bool(forKey: MacDocumentsStorageRelocation.completionDefaultsKey))

        // 放行后重跑：失败项补搬、完成门置位
        fileManager.failSourcePath = nil
        let retry = MacDocumentsStorageRelocation.run(fileManager: fileManager, defaults: defaults)
        #expect(retry.failedCount == 0)
        #expect(try read(appRoot.appendingPathComponent("Artwork/cover-a.jpg")) == "IMG")
        #expect(defaults.bool(forKey: MacDocumentsStorageRelocation.completionDefaultsKey))
    }

    @Test("干跑：只统计不搬、不置完成门")
    func dryRunDoesNotMove() throws {
        let roots = makeRoots()
        defer { try? fm.removeItem(at: roots.cleanup) }
        let fileManager = RelocationTestFileManager(documentsRoot: roots.documents, appSupportRoot: roots.appSupport)
        let defaults = freshDefaults()
        let docs = roots.documents
        let appRoot = appDataRoot(roots)

        try write(docs.appendingPathComponent("Lyrics/l1.json"), "L")

        let summary = MacDocumentsStorageRelocation.run(fileManager: fileManager, defaults: defaults, dryRun: true)
        #expect(summary.isDryRun)
        #expect(summary.movedCount == 1)
        #expect(fm.fileExists(atPath: docs.appendingPathComponent("Lyrics/l1.json").path))
        #expect(!fm.fileExists(atPath: appRoot.appendingPathComponent("Lyrics/l1.json").path))
        #expect(!defaults.bool(forKey: MacDocumentsStorageRelocation.completionDefaultsKey))
    }

    @Test("无旧布局：全程无操作（无失败）且完成门可置位")
    func emptyDocumentsCompletesWithoutWork() throws {
        let roots = makeRoots()
        defer { try? fm.removeItem(at: roots.cleanup) }
        let fileManager = RelocationTestFileManager(documentsRoot: roots.documents, appSupportRoot: roots.appSupport)
        let defaults = freshDefaults()

        let summary = MacDocumentsStorageRelocation.run(fileManager: fileManager, defaults: defaults)
        #expect(summary.movedCount == 0)
        #expect(summary.skippedCount == 0)
        #expect(summary.failedCount == 0)
        #expect(defaults.bool(forKey: MacDocumentsStorageRelocation.completionDefaultsKey))
    }
}
