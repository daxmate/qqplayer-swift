//
//  SyncLibraryFetchResponderTests.swift
//  QQPlayerTests
//
//  S2 M3-3b Host 侧应答器：请求路径解析计划（makePlan）纯逻辑 + 只读磁盘校验。
//  覆盖「越界/不存在/非常规文件/软链逃逸一律计入 failed，绝不读曲库之外」。
//  串行推送与失败归集的端到端断言见 SyncLibrarySyncE2ETests.swift。
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncLibraryFetchResponderTests {
    // MARK: 工具

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-sync-m33b-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func writeFile(_ relativePath: String, in root: URL, bytes: Int = 32) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    // MARK: - makePlan

    @Test("根内存在的常规文件 → 进待推送列表（路径规范化）")
    func planAcceptsExistingFile() throws {
        let root = try makeTempRoot()
        try writeFile("Album/01 Song.flac", in: root)

        let plan = SyncLibraryFetchResponder.makePlan(
            relativePaths: ["Album/./01 Song.flac"],
            root: root
        )
        #expect(plan.failures.isEmpty)
        #expect(plan.files.map(\.relativePath) == ["Album/01 Song.flac"])
        #expect(plan.files.first?.url.lastPathComponent == "01 Song.flac")
    }

    @Test("越界路径（绝对 / `..` 逃逸）→ failed，不出曲库根")
    func planRejectsEscapePaths() throws {
        let root = try makeTempRoot()
        try writeFile("inside.flac", in: root)

        let plan = SyncLibraryFetchResponder.makePlan(
            relativePaths: ["/etc/passwd", "../outside.flac", "a/../../outside.flac", ""],
            root: root
        )
        #expect(plan.files.isEmpty)
        #expect(plan.failures.count == 4)
        #expect(plan.failures.allSatisfy { $0.reason == SyncFetchFailureReason.invalidPath })
        #expect(plan.failures.map(\.relativePath) == ["/etc/passwd", "../outside.flac", "a/../../outside.flac", ""])
    }

    @Test("根内不存在 / 目录 → failed（notFound / notRegularFile）")
    func planReportsMissingAndDirectory() throws {
        let root = try makeTempRoot()
        let fileURL = try writeFile("Album/song.flac", in: root)
        let directoryURL = fileURL.deletingLastPathComponent()

        let plan = SyncLibraryFetchResponder.makePlan(
            relativePaths: [directoryURL.lastPathComponent, "Album/missing.flac"],
            root: root
        )
        #expect(plan.files.isEmpty)
        let byPath = Dictionary(uniqueKeysWithValues: plan.failures.map { ($0.relativePath, $0.reason) })
        #expect(byPath["Album"] == SyncFetchFailureReason.notRegularFile)
        #expect(byPath["Album/missing.flac"] == SyncFetchFailureReason.notFound)
    }

    @Test("软链逃逸 → failed(outOfRoot)；根内软链 → 放行")
    func planRejectsSymlinkEscape() throws {
        let root = try makeTempRoot()
        let outsideDir = try makeTempRoot()
        let outsideFile = try writeFile("secret.flac", in: outsideDir)

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.flac"),
            withDestinationURL: outsideFile
        )
        let insideFile = try writeFile("real.flac", in: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias.flac"),
            withDestinationURL: insideFile
        )

        let plan = SyncLibraryFetchResponder.makePlan(
            relativePaths: ["escape.flac", "alias.flac"],
            root: root
        )
        #expect(plan.failures.map(\.relativePath) == ["escape.flac"])
        #expect(plan.failures.first?.reason == SyncFetchFailureReason.outOfRoot)
        #expect(plan.files.map(\.relativePath) == ["alias.flac"])
    }

    @Test("重复请求路径只处理一次")
    func planDeduplicatesRequests() throws {
        let root = try makeTempRoot()
        try writeFile("song.flac", in: root)

        let plan = SyncLibraryFetchResponder.makePlan(
            relativePaths: ["song.flac", "song.flac", "./song.flac"],
            root: root
        )
        #expect(plan.files.count == 1)
        #expect(plan.failures.isEmpty)
    }
}
