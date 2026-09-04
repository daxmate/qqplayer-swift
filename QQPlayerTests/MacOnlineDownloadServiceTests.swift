//  MacOnlineDownloadServiceTests.swift
//  QQPlayerTests
//
//  在线下载编排（web 版 /api/online/download 对齐，2026-09 C 组①）纯逻辑防回归测试：
//  ① 音质设置值归一（旧数据/非法回落 exhigh）
//  ② 目标目录决策（设置路径优先；空 → 曲库首目录；无曲库 → nil）
//  ③ 重名自动加序号（name (1).ext…）
//  背景：web download.downloadDir 空 = LIBRARY；_unique_path 重名加序号。

import Foundation
import Testing

@testable import QQPlayer

struct MacOnlineDownloadServiceTests {
    // MARK: - 音质归一

    @Test("设置值合法 → 原样；非法/缺失 → exhigh")
    func effectiveQualityNormalizes() {
        #expect(MacOnlineDownloadService.effectiveQuality(from: "lossless") == "lossless")
        #expect(MacOnlineDownloadService.effectiveQuality(from: " EXHIGH ") == "exhigh")
        #expect(MacOnlineDownloadService.effectiveQuality(from: "bogus") == "exhigh")
        #expect(MacOnlineDownloadService.effectiveQuality(from: "") == "exhigh")
        #expect(MacOnlineDownloadService.effectiveQuality(from: nil) == "exhigh")
    }

    // MARK: - 目标目录

    @Test("配置了下载目录 → 用设置路径（忽略曲库列表）")
    func destinationUsesConfiguredDirectory() {
        let url = MacOnlineDownloadService.destinationDirectory(
            configuredDirectory: "/tmp/dl",
            libraryDirectories: ["/Users/x/Music/QQPlayer", "/Volumes/Other/Music"]
        )
        #expect(url?.path == "/tmp/dl")
    }

    @Test("下载目录为空 → 曲库首目录（默认目录恒在列）")
    func destinationFallsBackToLibraryFirst() {
        let url = MacOnlineDownloadService.destinationDirectory(
            configuredDirectory: " ",
            libraryDirectories: ["/Users/x/Music/QQPlayer"]
        )
        #expect(url?.path == "/Users/x/Music/QQPlayer")
    }

    @Test("下载目录为空且无曲库目录 → nil")
    func destinationNilWithoutLibrary() {
        let url = MacOnlineDownloadService.destinationDirectory(
            configuredDirectory: "",
            libraryDirectories: []
        )
        #expect(url == nil)
    }

    // MARK: - 落盘路径（重名序号）

    @Test("无冲突 → 原文件名直接落在目录下")
    func destinationWithoutCollision() {
        let url = MacOnlineDownloadService.destinationURL(
            directory: URL(fileURLWithPath: "/Music"),
            fileName: "晴天-周杰伦.mp3",
            fileExists: { _ in false }
        )
        #expect(url.path == "/Music/晴天-周杰伦.mp3")
    }

    @Test("已存在 → name (1).ext（web _unique_path 对齐）")
    func destinationAppendsSequence() {
        var existing: Set<String> = ["/Music/晴天-周杰伦.mp3"]
        let url = MacOnlineDownloadService.destinationURL(
            directory: URL(fileURLWithPath: "/Music"),
            fileName: "晴天-周杰伦.mp3",
            fileExists: { existing.contains($0) }
        )
        #expect(url.path == "/Music/晴天-周杰伦 (1).mp3")
        existing.insert(url.path)
        let url2 = MacOnlineDownloadService.destinationURL(
            directory: URL(fileURLWithPath: "/Music"),
            fileName: "晴天-周杰伦.mp3",
            fileExists: { existing.contains($0) }
        )
        #expect(url2.path == "/Music/晴天-周杰伦 (2).mp3")
    }
}
