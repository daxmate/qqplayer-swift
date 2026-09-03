//  LibraryAudioFormatsTests.swift
//  QQPlayerTests
//
//  文件类型设置（web 版 audioExts 对齐）纯逻辑防回归测试：
//  ① LibraryAudioFormats 默认全集/路径判定
//  ② DeleteSettings.audioExtensions 解码兜底（旧数据无此 key / 空列表 → 默认全集）
//
//  背景（2026-09-03 B 组）：macOS 扫描按用户启用格式过滤；取消某格式后重扫
//  由 reconcile 移除该格式曲目（文件保留，勾回重扫恢复）。默认全集 = 历史
//  硬编码 9 种，任何改动导致默认集收缩都会让既有曲库曲目被误删，故锁定。

import Foundation
import Testing

@testable import QQPlayer

struct LibraryAudioFormatsTests {
    // MARK: - 默认全集

    @Test("默认启用集 = 全部支持格式（9 种，含 DSD）")
    func defaultEnabledEqualsAllSupported() {
        #expect(LibraryAudioFormats.defaultEnabled == LibraryAudioFormats.allSupported)
        #expect(LibraryAudioFormats.allSupported.count == 9)
        #expect(LibraryAudioFormats.allSupported.contains("mp3"))
        #expect(LibraryAudioFormats.allSupported.contains("flac"))
        #expect(LibraryAudioFormats.allSupported.contains("dsf"))
        #expect(LibraryAudioFormats.allSupported.contains("dff"))
    }

    @Test("allSupported 小写不带点（内部过滤用 pathExtension 比较）")
    func allSupportedAreLowercaseWithoutDot() {
        for ext in LibraryAudioFormats.allSupported {
            #expect(ext == ext.lowercased())
            #expect(!ext.hasPrefix("."))
        }
    }

    // MARK: - isEnabled 路径判定

    @Test("启用集包含该扩展名 → 路径可收录")
    func enabledExtensionMatches() {
        let enabled = ["mp3", "flac"]
        #expect(LibraryAudioFormats.isEnabled(path: "/a/b/song.flac", enabled: enabled))
        #expect(LibraryAudioFormats.isEnabled(path: "/a/b/song.MP3", enabled: enabled)) // 大小写不敏感
    }

    @Test("启用集不含该扩展名 → 路径不收录")
    func disabledExtensionExcluded() {
        let enabled = ["mp3", "flac"]
        #expect(!LibraryAudioFormats.isEnabled(path: "/a/b/song.opus", enabled: enabled))
        #expect(!LibraryAudioFormats.isEnabled(path: "/a/b/noext", enabled: enabled))
        #expect(!LibraryAudioFormats.isEnabled(path: "/a/b/song.mp4", enabled: enabled)) // 视频/未知不误收
    }

    // MARK: - DeleteSettings.audioExtensions 解码兜底

    @Test("旧数据（无 audioExtensions key）→ 默认全集")
    func missingKeyFallsBackToDefaults() throws {
        let legacyJSON = Data(#"{"forceDarkMode":true,"dsdPlaybackMode":"pcm"}"#.utf8)
        let settings = try JSONDecoder().decode(DeleteSettings.self, from: legacyJSON)
        #expect(settings.audioExtensions == LibraryAudioFormats.defaultEnabled)
        #expect(settings.forceDarkMode)
    }

    @Test("显式空列表 → 默认全集（不把空当『什么都不收』）")
    func emptyListFallsBackToDefaults() throws {
        let json = Data(#"{"audioExtensions":[]}"#.utf8)
        let settings = try JSONDecoder().decode(DeleteSettings.self, from: json)
        #expect(settings.audioExtensions == LibraryAudioFormats.defaultEnabled)
    }

    @Test("显式部分列表 → 原样保留（用户裁剪生效）")
    func explicitSubsetPreserved() throws {
        let json = Data(#"{"audioExtensions":["mp3","flac"]}"#.utf8)
        let settings = try JSONDecoder().decode(DeleteSettings.self, from: json)
        #expect(settings.audioExtensions == ["mp3", "flac"])
    }

    @Test("round-trip：保存裁剪列表后再解码保持")
    func roundTripPreservesSubset() throws {
        var settings = DeleteSettings()
        settings.audioExtensions = ["opus", "ogg"]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DeleteSettings.self, from: data)
        #expect(decoded.audioExtensions == ["opus", "ogg"])
    }
}
