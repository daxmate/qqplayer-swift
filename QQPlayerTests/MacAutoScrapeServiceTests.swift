//
//  MacAutoScrapeServiceTests.swift
//  QQPlayerTests
//
//  「下载完成后自动刮削」纯决策防回归（2026-11-14）：
//  - shouldEnqueue 三态：开关关 → false（零副作用）；开关开 + 可写扩展名 → true；
//    开关开但扩展名不可写（wav / 空扩展名）→ false。
//  实网/写盘链路（MacAutoScrapeWorker.process）不做端到端单测：依赖真实网络与曲库索引，
//  由真机流程验证。
//  但「写前按文件身份重新定位路径」是纯本地可判定的口径，必须锁（2026-11-19 真机回归：
//  索引扫掠把 夜曲-周杰伦.mp3 改名后，自动刮削仍按旧路径写标签 → fileNotReadable 全失败）。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite(.serialized)
struct MacAutoScrapeServiceTests {
    @Test("开关关 → 一律不入队（即使扩展名可写）")
    func disabledNeverEnqueues() {
        for ext in TagWriterService.writableExtensions {
            #expect(!MacAutoScrapeService.shouldEnqueue(enabled: false, extension: ext))
        }
        #expect(!MacAutoScrapeService.shouldEnqueue(enabled: false, extension: "wav"))
    }

    @Test("开关开 + 可写扩展名 → 入队（大小写不敏感）")
    func enabledWritableExtensionsEnqueue() {
        for ext in TagWriterService.writableExtensions {
            #expect(MacAutoScrapeService.shouldEnqueue(enabled: true, extension: ext))
        }
        #expect(MacAutoScrapeService.shouldEnqueue(enabled: true, extension: "MP3"))
        #expect(MacAutoScrapeService.shouldEnqueue(enabled: true, extension: "Flac"))
    }

    @Test("开关开但扩展名不可写 → 不入队（wav / dsf / 空扩展名）")
    func enabledUnsupportedFormatDoesNotEnqueue() {
        #expect(!MacAutoScrapeService.shouldEnqueue(enabled: true, extension: "wav"))
        #expect(!MacAutoScrapeService.shouldEnqueue(enabled: true, extension: "dsf"))
        #expect(!MacAutoScrapeService.shouldEnqueue(enabled: true, extension: ""))
    }

    // MARK: - 写前重新定位（索引改名抢跑回归）

    /// 造临时目录 + 文件；调用方负责 defer 删目录。
    private func makeTempFile(named name: String) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoscrape-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: file)
        return (directory, file)
    }

    @Test("原路径仍存在 → 解析返回原路径")
    func resolveKeepsExistingPath() throws {
        let (directory, file) = try makeTempFile(named: "夜曲-周杰伦.mp3")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MacAutoScrapeFileIdentity.capture(at: file)
        #expect(identity != nil)

        let job = MacAutoScrapeJob(path: file.path, knownTitle: nil, knownArtist: nil, identity: identity)
        #expect(MacAutoScrapeWorker.resolveCurrentURL(for: job)?.path == file.path)
    }

    @Test("索引改名后 → 解析按 identity 返回新路径（核心回归）")
    func resolveFollowsRename() throws {
        let (directory, file) = try makeTempFile(named: "夜曲-周杰伦.mp3")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MacAutoScrapeFileIdentity.capture(at: file)
        #expect(identity != nil)

        let renamed = directory.appendingPathComponent("周杰伦 - 夜曲.mp3")
        try FileManager.default.moveItem(at: file, to: renamed)

        let job = MacAutoScrapeJob(path: file.path, knownTitle: nil, knownArtist: nil, identity: identity)
        #expect(MacAutoScrapeWorker.resolveCurrentURL(for: job)?.path == renamed.path)
    }

    @Test("文件被移走/删除 → 解析返回 nil（调用方跳过，不抛错）")
    func resolveReturnsNilWhenGone() throws {
        let (directory, file) = try makeTempFile(named: "月半小夜曲-李克勤.mp3")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MacAutoScrapeFileIdentity.capture(at: file)
        let job = MacAutoScrapeJob(path: file.path, knownTitle: nil, knownArtist: nil, identity: identity)

        try FileManager.default.removeItem(at: file)
        #expect(MacAutoScrapeWorker.resolveCurrentURL(for: job) == nil)
    }

    @Test("identity 为 nil 且路径不存在 → 返回 nil，不崩")
    func resolveWithoutIdentityAndMissingPath() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoscrape-missing-\(UUID().uuidString).mp3")
        let job = MacAutoScrapeJob(path: missing.path, knownTitle: nil, knownArtist: nil)
        #expect(MacAutoScrapeWorker.resolveCurrentURL(for: job) == nil)
    }
}
