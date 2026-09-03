//  MacFolderWatchPolicyTests.swift
//  QQPlayerTests
//
//  FSEvents 实时监控（web 版 watchdog 对齐）决策纯逻辑防回归测试。
//  覆盖：监控根归一化（去重/只留存在目录）、噪声事件过滤（隐藏/.DS_Store/
//  Finder 元数据）。锁定后任何人改动去抖时长或过滤规则都会在 CI 暴露。

import Foundation
import Testing

@testable import QQPlayer

struct MacFolderWatchPolicyTests {
    // MARK: - 去抖

    @Test("去抖 2s（web 版 WATCH_DEBOUNCE_SECONDS=2.0 对齐）")
    func debounceWindow() {
        #expect(MacFolderWatchPolicy.debounceNanoseconds == 2_000_000_000)
    }

    // MARK: - relevantFolders

    @Test("重复路径去重且保留顺序")
    func duplicateFoldersDeduplicated() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "qqplayer-dedup-test")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = MacFolderWatchPolicy.relevantFolders([url, url])
        #expect(result.count == 1)
        #expect(result[0].path == url.standardizedFileURL.path)
    }

    @Test("不存在的目录被过滤（FSEvents 对不存在路径无事件）")
    func nonexistentFolderFiltered() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory() + "qqplayer-nonexistent-" + UUID().uuidString)
        let result = MacFolderWatchPolicy.relevantFolders([missing])
        #expect(result.isEmpty)
    }

    // MARK: - shouldIgnore

    @Test("隐藏文件/目录忽略（.DS_Store、.git、点开头）")
    func hiddenPathsIgnored() {
        #expect(MacFolderWatchPolicy.shouldIgnore(eventPath: "/Music/QQPlayer/.DS_Store"))
        #expect(MacFolderWatchPolicy.shouldIgnore(eventPath: "/Music/QQPlayer/.hidden-song.flac"))
        #expect(MacFolderWatchPolicy.shouldIgnore(eventPath: "/Music/.git/config"))
        #expect(MacFolderWatchPolicy.shouldIgnore(eventPath: "/.Trash/song.mp3"))
    }

    @Test("Finder AppleDouble 元数据忽略（._*）")
    func appleDoubleIgnored() {
        #expect(MacFolderWatchPolicy.shouldIgnore(eventPath: "/Music/QQPlayer/._song.mp3"))
        #expect(MacFolderWatchPolicy.shouldIgnore(eventPath: "/Music/QQPlayer/._cover.jpg"))
    }

    @Test("正常音乐文件路径不忽略")
    func normalPathsNotIgnored() {
        #expect(!MacFolderWatchPolicy.shouldIgnore(eventPath: "/Music/QQPlayer/song.mp3"))
        #expect(!MacFolderWatchPolicy.shouldIgnore(eventPath: "/Music/QQPlayer/Album/flac.flac"))
        #expect(!MacFolderWatchPolicy.shouldIgnore(eventPath: "/Music/QQPlayer/封面.jpg"))
    }
}
