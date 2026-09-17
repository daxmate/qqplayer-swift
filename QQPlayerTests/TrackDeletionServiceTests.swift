//
//  TrackDeletionServiceTests.swift
//  QQPlayerTests
//
//  P0 收口（2026-09-17）：曲目删除语义的唯一入口测试。
//
//  为什么值得写：整改前这段仪式在视图层抄了 7 份且各不相同（有的 `try` 有的 `try?`），
//  收成一个入口后，行为第一次变成**可断言**的——文件删失败不影响 DB 引用删除、
//  DB 删除失败计入 failed、libraryOnly 分支只加排除标记不碰磁盘、通知只发一次。
//
//  纯逻辑测试：磁盘/DB 全部走注入闭包，无模拟器、无真实文件、无真实数据库。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite("曲目删除唯一入口（TrackDeletionService）")
struct TrackDeletionServiceTests {
    /// 记录调用轨迹的假实现。
    private final class Recorder {
        var excluded: [String] = []
        var removedFiles: [String] = []
        var deletedReferences: [String] = []
    }

    private static func items(_ ids: [String]) -> [TrackDeletionService.Item] {
        ids.map { TrackDeletionService.Item(stableId: $0, path: "/tmp/\($0).flac") }
    }

    @Test("libraryOnly：只加排除标记，不碰磁盘")
    func libraryOnlyExcludesWithoutTouchingDisk() {
        let recorder = Recorder()
        let outcome = TrackDeletionService.delete(
            items: Self.items(["a", "b"]),
            libraryOnly: true,
            excludeFromLibrary: { recorder.excluded.append($0) },
            removeFile: { recorder.removedFiles.append($0) },
            deleteReference: { recorder.deletedReferences.append($0) }
        )

        #expect(outcome.deleted == 2)
        #expect(outcome.excludedFromLibrary == 2)
        #expect(outcome.failed == 0)
        #expect(outcome.fileRemovalFailed == 0)
        #expect(recorder.removedFiles.isEmpty)
        #expect(recorder.excluded == ["a", "b"])
        #expect(recorder.deletedReferences == ["a", "b"])
    }

    @Test("默认分支：删文件 + 删 DB 引用，顺序稳定")
    func removesFilesThenReferences() {
        let recorder = Recorder()
        let outcome = TrackDeletionService.delete(
            items: Self.items(["a", "b"]),
            libraryOnly: false,
            excludeFromLibrary: { recorder.excluded.append($0) },
            removeFile: { recorder.removedFiles.append($0) },
            deleteReference: { recorder.deletedReferences.append($0) }
        )

        #expect(outcome.deleted == 2)
        #expect(outcome.excludedFromLibrary == 0)
        #expect(recorder.excluded.isEmpty)
        #expect(recorder.removedFiles == ["/tmp/a.flac", "/tmp/b.flac"])
        #expect(recorder.deletedReferences == ["a", "b"])
    }

    @Test("文件删失败 → 只记数，DB 引用照常删除（保 iOS 既有语义）")
    func fileRemovalFailureStillDeletesReference() {
        let recorder = Recorder()
        let outcome = TrackDeletionService.delete(
            items: Self.items(["a"]),
            libraryOnly: false,
            excludeFromLibrary: { recorder.excluded.append($0) },
            removeFile: { _ in throw CocoaError(.fileWriteNoPermission) },
            deleteReference: { recorder.deletedReferences.append($0) }
        )

        #expect(outcome.fileRemovalFailed == 1)
        #expect(outcome.failed == 0)
        #expect(outcome.deleted == 1)
        #expect(recorder.deletedReferences == ["a"])
    }

    @Test("DB 删除失败 → 计入 failed，其余曲目继续处理")
    func referenceFailureIsCountedAndLoopContinues() {
        let recorder = Recorder()
        let outcome = TrackDeletionService.delete(
            items: Self.items(["a", "b", "c"]),
            libraryOnly: false,
            excludeFromLibrary: { recorder.excluded.append($0) },
            removeFile: { recorder.removedFiles.append($0) },
            deleteReference: { stableId in
                if stableId == "b" { throw CocoaError(.fileNoSuchFile) }
                recorder.deletedReferences.append(stableId)
            }
        )

        #expect(outcome.deleted == 2)
        #expect(outcome.failed == 1)
        #expect(recorder.removedFiles == ["/tmp/a.flac", "/tmp/b.flac", "/tmp/c.flac"])
        #expect(recorder.deletedReferences == ["a", "c"])
    }

    @Test("空输入：什么都不做")
    func emptyInputIsNoop() {
        let recorder = Recorder()
        let outcome = TrackDeletionService.delete(
            items: [],
            libraryOnly: false,
            excludeFromLibrary: { recorder.excluded.append($0) },
            removeFile: { recorder.removedFiles.append($0) },
            deleteReference: { recorder.deletedReferences.append($0) }
        )

        #expect(outcome == TrackDeletionService.Outcome())
        #expect(recorder.removedFiles.isEmpty)
    }
}
