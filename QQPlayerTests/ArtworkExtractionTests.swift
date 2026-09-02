//  ArtworkExtractionTests.swift
//  QQPlayerTests
//
//  封面提取兜底测试：内嵌封面缺失时回退同目录 cover.jpg / cover.png /
//  folder.jpg（对齐 web 版「内嵌封面优先，其次文件夹 cover.jpg」行为）。
//

import Foundation
import Testing

@testable import QQPlayer

struct ArtworkExtractionTests {
    /// 1x1 透明 PNG（最小合法 PNG，UIImage/NSImage 均可解码）。
    private static let pngData = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    )!

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkExtractionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("无封面文件：返回 nil")
    func noCoverReturnsNil() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let audio = dir.appendingPathComponent("song.mp3")
        #expect(ArtworkManager.coverImage(inDirectoryOf: audio) == nil)
    }

    @Test("cover.jpg 命中")
    func coverJpgHit() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Self.pngData.write(to: dir.appendingPathComponent("cover.jpg"))
        let audio = dir.appendingPathComponent("song.mp3")
        #expect(ArtworkManager.coverImage(inDirectoryOf: audio) != nil)
    }

    @Test("cover.png 兜底命中")
    func coverPngFallback() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Self.pngData.write(to: dir.appendingPathComponent("cover.png"))
        let audio = dir.appendingPathComponent("song.mp3")
        #expect(ArtworkManager.coverImage(inDirectoryOf: audio) != nil)
    }

    @Test("folder.jpg 兜底命中")
    func folderJpgFallback() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Self.pngData.write(to: dir.appendingPathComponent("folder.jpg"))
        let audio = dir.appendingPathComponent("song.mp3")
        #expect(ArtworkManager.coverImage(inDirectoryOf: audio) != nil)
    }
}
