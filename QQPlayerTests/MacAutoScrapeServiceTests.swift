//
//  MacAutoScrapeServiceTests.swift
//  QQPlayerTests
//
//  「下载完成后自动刮削」纯决策防回归（2026-11-14）：
//  - shouldEnqueue 三态：开关关 → false（零副作用）；开关开 + 可写扩展名 → true；
//    开关开但扩展名不可写（wav / 空扩展名）→ false。
//  实网/写盘链路（MacAutoScrapeWorker）不做单测：依赖真实网络与曲库索引，
//  由真机流程验证；本文件只锁「要不要入队」这一条可判定的口径。
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
}
