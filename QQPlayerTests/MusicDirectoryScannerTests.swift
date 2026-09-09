//  MusicDirectoryScannerTests.swift
//  QQPlayerTests
//
//  共享目录扫描器防回归测试（MusicDirectoryScanner）。
//
//  背景（2026-09 A0-prep）：目录枚举逻辑原先内嵌 LibraryIndexer.findMusicFiles
//  （iOS fallback 双扫 / offline 与 macOS 多文件夹扫描共用），A0 抽为共享纯函数。
//  规则锁定：跳过隐藏、仅常规文件、扩展名小写匹配启用集、enumerator 失败返回空；
//  任何改动让隐藏文件/未启用格式误入列都会污染曲库。

import Foundation
import Testing

@testable import QQPlayer

struct MusicDirectoryScannerTests {
    /// 造一个临时目录树，测试后删除。
    private func makeTempTree(
        _ spec: [String: String]
    ) throws -> (root: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicDirectoryScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, content) in spec {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: url)
        }
        return (root, { try? FileManager.default.removeItem(at: root) })
    }

    // MARK: - enabledExtensions 解析

    @Test("audioExtensions 为空 → 回落默认全集（与 findMusicFiles 旧逻辑一致）")
    func emptyAudioExtensionsFallsBackToDefaults() {
        var settings = DeleteSettings()
        settings.audioExtensions = []
        #expect(MusicDirectoryScanner.enabledExtensions(from: settings) == LibraryAudioFormats.defaultEnabled)
        #expect(MusicDirectoryScanner.enabledExtensions(from: settings).count == 9)
    }

    @Test("audioExtensions 非空 → 原样保留（用户裁剪生效）")
    func configuredExtensionsPreserved() {
        var settings = DeleteSettings()
        settings.audioExtensions = ["mp3", "flac"]
        #expect(MusicDirectoryScanner.enabledExtensions(from: settings) == ["mp3", "flac"])
    }

    // MARK: - 递归扫描规则

    @Test("扫描：平铺目录只收启用格式音频，跳过非音频/隐藏")
    func flatDirectoryFilters() async throws {
        let (root, cleanup) = try makeTempTree([
            "a.mp3": "x",
            "b.flac": "x",
            "note.txt": "not audio",
            "cover.jpg": "img",
            ".hidden.mp3": "hidden file should be skipped",
            "noext": "no extension",
        ])
        defer { cleanup() }

        let files = try await MusicDirectoryScanner.audioFiles(
            in: root,
            enabledExtensions: ["mp3", "flac"]
        )
        let names = files.map(\.lastPathComponent).sorted()
        #expect(names == ["a.mp3", "b.flac"])
    }

    @Test("扫描：递归子目录（与 findMusicFiles 历史行为一致）")
    func nestedDirectoriesIncluded() async throws {
        let (root, cleanup) = try makeTempTree([
            "top.mp3": "x",
            "sub/deep.flac": "x",
            "sub/deeper/innermost.ogg": "x",
        ])
        defer { cleanup() }

        let files = try await MusicDirectoryScanner.audioFiles(
            in: root,
            enabledExtensions: ["mp3", "flac", "ogg"]
        )
        #expect(files.count == 3)
        let names = files.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }.sorted()
        #expect(names == ["sub/deep.flac", "sub/deeper/innermost.ogg", "top.mp3"])
    }

    @Test("扫描：隐藏目录整体跳过（.skipsHiddenFiles 含目录）")
    func hiddenDirectoriesSkipped() async throws {
        let (root, cleanup) = try makeTempTree([
            ".hiddendir/song.flac": "x",
            ".dotfolder/another.mp3": "x",
            "visible.mp3": "x",
        ])
        defer { cleanup() }

        let files = try await MusicDirectoryScanner.audioFiles(
            in: root,
            enabledExtensions: ["mp3", "flac"]
        )
        #expect(files.map(\.lastPathComponent) == ["visible.mp3"])
    }

    @Test("扫描：扩展名大小写不敏感（.MP3/.Flac 也收）")
    func extensionCaseInsensitive() async throws {
        let (root, cleanup) = try makeTempTree([
            "upper.MP3": "x",
            "mixed.Flac": "x",
        ])
        defer { cleanup() }

        let files = try await MusicDirectoryScanner.audioFiles(
            in: root,
            enabledExtensions: ["mp3", "flac"]
        )
        #expect(files.count == 2)
    }

    @Test("扫描：启用集不含的格式不入列（即使真实音频扩展名）")
    func disabledFormatsExcluded() async throws {
        let (root, cleanup) = try makeTempTree([
            "song.opus": "x",
            "song.m4a": "x",
        ])
        defer { cleanup() }

        let files = try await MusicDirectoryScanner.audioFiles(
            in: root,
            enabledExtensions: ["mp3", "flac"]
        )
        #expect(files.isEmpty)
    }

    @Test("扫描：enumerator 创建失败（目录不存在）→ 返回空数组不抛错")
    func missingDirectoryReturnsEmpty() async throws {
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-dir-\(UUID().uuidString)")
        let files = try await MusicDirectoryScanner.audioFiles(
            in: ghost,
            enabledExtensions: ["mp3"]
        )
        #expect(files.isEmpty)
    }

    @Test("扫描：空目录 → 空数组")
    func emptyDirectoryReturnsEmpty() async throws {
        let (root, cleanup) = try makeTempTree([:])
        defer { cleanup() }
        let files = try await MusicDirectoryScanner.audioFiles(
            in: root,
            enabledExtensions: ["mp3", "flac"]
        )
        #expect(files.isEmpty)
    }

    @Test("扫描：目录内文件枚举顺序 = FileManager 枚举顺序（未排序契约）")
    func orderIsEnumeratorOrder() async throws {
        let (root, cleanup) = try makeTempTree([
            "z.mp3": "x",
            "a.mp3": "x",
            "m.mp3": "x",
        ])
        defer { cleanup() }

        let files = try await MusicDirectoryScanner.audioFiles(
            in: root,
            enabledExtensions: ["mp3"]
        )
        // 不排序直接收集：与 findMusicFiles 历史行为一致（上层负责排序/去重）
        #expect(files.count == 3)
        #expect(Set(files.map(\.lastPathComponent)) == Set(["a.mp3", "m.mp3", "z.mp3"]))
    }
}
