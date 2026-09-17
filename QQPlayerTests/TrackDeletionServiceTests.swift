//
//  TrackDeletionServiceTests.swift
//  QQPlayerTests
//
//  P0 收口（2026-09-17）：曲目删除语义的唯一入口测试。
//
//  为什么值得写：整改前这段仪式在视图层抄了 7 份且各不相同（有的 `try` 有的 `try?`），
//  收成一个入口后，行为第一次变成**可断言**的。
//
//  2026-09-17 用户确认后修正了一条语义（本文件相应用例已同步）：
//  文件删不掉时**必须保留曲目**（不删 DB 引用）——旧实现「删失败仍删库引用」不是本意，
//  那会让曲目从库里消失、文件赖在磁盘上（用户看不见也删不掉）。
//  Mac 端 `MacTrashService` 一直是这个语义，两端现已对齐。
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
        var existenceChecks: [String] = []

        /// 每个 stableId 的 DB 删除是否应当失败。
        var failingReferenceIds: Set<String> = []
    }

    private static func items(_ ids: [String]) -> [TrackDeletionService.Item] {
        ids.map { TrackDeletionService.Item(stableId: $0, path: "/tmp/\($0).flac") }
    }

    @Test("libraryOnly：只加排除标记，不碰磁盘（连存在性都不查）")
    func libraryOnlyExcludesWithoutTouchingDisk() {
        let recorder = Recorder()
        let outcome = TrackDeletionService.delete(
            items: Self.items(["a", "b"]),
            libraryOnly: true,
            fileExists: { path in
                recorder.existenceChecks.append(path)
                return true
            },
            excludeFromLibrary: { recorder.excluded.append($0) },
            removeFile: { recorder.removedFiles.append($0) },
            deleteReference: { recorder.deletedReferences.append($0) }
        )

        #expect(outcome.deleted == 2)
        #expect(outcome.excludedFromLibrary == 2)
        #expect(outcome.failed == 0)
        #expect(outcome.fileRemovalFailed == 0)
        #expect(recorder.removedFiles.isEmpty)
        #expect(recorder.existenceChecks.isEmpty)
        #expect(recorder.excluded == ["a", "b"])
        #expect(recorder.deletedReferences == ["a", "b"])
    }

    @Test("默认分支：删文件 + 删 DB 引用，顺序稳定")
    func removesFilesThenReferences() {
        let recorder = Recorder()
        let outcome = TrackDeletionService.delete(
            items: Self.items(["a", "b"]),
            libraryOnly: false,
            fileExists: { _ in true },
            excludeFromLibrary: { recorder.excluded.append($0) },
            removeFile: { recorder.removedFiles.append($0) },
            deleteReference: { recorder.deletedReferences.append($0) }
        )

        #expect(outcome.deleted == 2)
        #expect(outcome.excludedFromLibrary == 0)
        #expect(outcome.failed == 0)
        #expect(recorder.excluded.isEmpty)
        #expect(recorder.removedFiles == ["/tmp/a.flac", "/tmp/b.flac"])
        #expect(recorder.deletedReferences == ["a", "b"])
    }

    @Test("文件已不在磁盘：不当失败，照常清 DB 引用（同 Mac 语义）")
    func missingFileStillClearsReference() {
        let recorder = Recorder()
        let outcome = TrackDeletionService.delete(
            items: Self.items(["a"]),
            libraryOnly: false,
            fileExists: { _ in false },
            excludeFromLibrary: { recorder.excluded.append($0) },
            removeFile: { recorder.removedFiles.append($0) },
            deleteReference: { recorder.deletedReferences.append($0) }
        )

        #expect(outcome.deleted == 1)
        #expect(outcome.failed == 0)
        #expect(outcome.fileRemovalFailed == 0)
        #expect(recorder.removedFiles.isEmpty, "文件都不在了，不该再去删一次")
        #expect(recorder.deletedReferences == ["a"])
    }

    @Test("文件删不掉 → 保留曲目（不删库引用），其余曲目继续处理")
    func fileRemovalFailureKeepsTrack() {
        let recorder = Recorder()
        let outcome = TrackDeletionService.delete(
            items: Self.items(["a", "b", "c"]),
            libraryOnly: false,
            fileExists: { _ in true },
            excludeFromLibrary: { recorder.excluded.append($0) },
            removeFile: { path in
                if path.hasSuffix("b.flac") { throw CocoaError(.fileWriteNoPermission) }
                recorder.removedFiles.append(path)
            },
            deleteReference: { recorder.deletedReferences.append($0) }
        )

        #expect(outcome.deleted == 2)
        #expect(outcome.failed == 1)
        #expect(outcome.fileRemovalFailed == 1)
        #expect(recorder.removedFiles == ["/tmp/a.flac", "/tmp/c.flac"])
        #expect(
            recorder.deletedReferences == ["a", "c"],
            "删不掉文件的那首必须留在库里（2026-09-17 纠正：旧实现会连库引用一起删）"
        )
    }

    @Test("DB 删除失败 → 计入 failed，其余曲目继续处理")
    func referenceFailureIsCountedAndLoopContinues() {
        let recorder = Recorder()
        let outcome = TrackDeletionService.delete(
            items: Self.items(["a", "b", "c"]),
            libraryOnly: false,
            fileExists: { _ in true },
            excludeFromLibrary: { recorder.excluded.append($0) },
            removeFile: { recorder.removedFiles.append($0) },
            deleteReference: { stableId in
                if stableId == "b" { throw CocoaError(.fileNoSuchFile) }
                recorder.deletedReferences.append(stableId)
            }
        )

        #expect(outcome.deleted == 2)
        #expect(outcome.failed == 1)
        #expect(outcome.fileRemovalFailed == 0)
        #expect(recorder.removedFiles == ["/tmp/a.flac", "/tmp/b.flac", "/tmp/c.flac"])
        #expect(recorder.deletedReferences == ["a", "c"])
    }

    @Test("空输入：什么都不做")
    func emptyInputIsNoop() {
        let recorder = Recorder()
        let outcome = TrackDeletionService.delete(
            items: [],
            libraryOnly: false,
            fileExists: { _ in true },
            excludeFromLibrary: { recorder.excluded.append($0) },
            removeFile: { recorder.removedFiles.append($0) },
            deleteReference: { recorder.deletedReferences.append($0) }
        )

        #expect(outcome == TrackDeletionService.Outcome())
        #expect(recorder.removedFiles.isEmpty)
    }
}
