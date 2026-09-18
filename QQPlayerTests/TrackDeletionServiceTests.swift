//
//  TrackDeletionServiceTests.swift
//  QQPlayerTests
//
//  曲目删除唯一入口的语义回归（2026-09-17 P0 收口；2026-09-18 P1 两端合流后合并原
//  `MacTrashServiceTests` 的全部用例 → 一个入口一个测试文件）。
//
//  三个套件：
//   · 核心语义（策略 × 失败路径）——两端共有，纯逻辑（磁盘/DB 全走注入闭包）；
//   · Mac 批量路径——原 MacTrashServiceTests 的 7 条语义逐条保留（磁盘已丢仍清引用 /
//     trash 失败保留曲目 / DB 失败计数 / 取消 / 进度 / 空批次）；
//   · iOS 废纸篓实测——用**真实 FileManager** 在模拟器容器里探测 `trashItem` 的实际行为
//     （2026-09-18 用户认为「废纸篓只有 Mac 能用」，需实测取证；该用例 fail-closed：
//     谎报成功（报成功但文件还在、或报错却已把文件抹掉）都判红）。
//
//  2026-09-17 用户确认后修正的一条语义（本文件已同步）：
//  文件删不掉时**必须保留曲目**（不删 DB 引用）——旧实现「删失败仍删库引用」不是本意，
//  那会让曲目从库里消失、文件赖在磁盘上（用户看不见也删不掉）。
//
//  2026-09-18 的默认值决策（两次拍板，先第一版默认废纸篓，实测后改回）：
//  iOS 容器**没有废纸篓宗卷**（`trashItem` 抛 NSCocoaErrorDomain 3328，本文件实测套件取证）
//  → iOS 默认 `.delete`（= 合流前 iOS 行为，**行为零变化**）；macOS 默认 `.trash`（可恢复）。
//  差异只是**调用点传入的数据**（`Policy.ios(libraryOnly:)` / `Policy.mac()`），不是第二份实现。
//

import Foundation
import Testing

@testable import QQPlayer

/// 记录调用轨迹的假执行环境（可按需注入失败/取消）。
private final class FakeDeletionEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var trashed: [String] = []
    private var removed: [String] = []
    private var excluded: [String] = []
    private var deleted: [String] = []
    private var deleteAttempts: [String] = []
    private var logs: [String] = []
    private var existenceChecks: [String] = []

    /// 抛出错误的 path（废纸篓动作）
    var trashErrorPaths: Set<String> = []
    /// 抛出错误的 path（永久删除动作）
    var removeErrorPaths: Set<String> = []
    /// 抛出错误的 stableId（DB 删除阶段）
    var deleteErrorStableIds: Set<String> = []
    /// 文件系统中「存在」的 path（其余视为磁盘已丢）
    var existingPaths: Set<String> = []
    /// 返回第几次「逐首取消探测」后开始取消（nil = 从不）
    var cancelAfter: Int?
    private var cancelProbe = 0

    func environment() -> TrackDeletionService.Environment {
        cancelProbe = 0
        return TrackDeletionService.Environment(
            fileExists: { [self] path in
                lock.lock()
                existenceChecks.append(path)
                lock.unlock()
                return existingPaths.contains(path)
            },
            moveToTrash: { [self] path in
                lock.lock()
                trashed.append(path)
                let shouldThrow = trashErrorPaths.contains(path)
                lock.unlock()
                if shouldThrow { throw TestError.trashFailed(path) }
            },
            removePermanently: { [self] path in
                lock.lock()
                removed.append(path)
                let shouldThrow = removeErrorPaths.contains(path)
                lock.unlock()
                if shouldThrow { throw TestError.removeFailed(path) }
            },
            excludeFromLibrary: { [self] stableId in
                lock.lock()
                excluded.append(stableId)
                lock.unlock()
            },
            deleteReference: { [self] stableId in
                lock.lock()
                deleteAttempts.append(stableId)
                let shouldThrow = deleteErrorStableIds.contains(stableId)
                if !shouldThrow { deleted.append(stableId) }
                lock.unlock()
                if shouldThrow { throw TestError.deleteFailed(stableId) }
            },
            log: { [self] message in
                lock.lock()
                logs.append(message)
                lock.unlock()
            },
            isCancelled: { [self] in
                lock.lock()
                defer { lock.unlock() }
                cancelProbe += 1
                guard let cancelAfter else { return false }
                return cancelProbe > cancelAfter
            }
        )
    }

    var trashedPaths: [String] { lock.lock(); defer { lock.unlock() }; return trashed }
    var removedPaths: [String] { lock.lock(); defer { lock.unlock() }; return removed }
    var excludedIds: [String] { lock.lock(); defer { lock.unlock() }; return excluded }
    /// DB 删除**成功**的 stableId（iOS 用例看这个）
    var deletedStableIds: [String] { lock.lock(); defer { lock.unlock() }; return deleted }
    /// DB 删除**尝试过**的 stableId（Mac 用例看这个：失败项也会调一次）
    var deleteReferenceAttempts: [String] { lock.lock(); defer { lock.unlock() }; return deleteAttempts }
    var logMessages: [String] { lock.lock(); defer { lock.unlock() }; return logs }
    var existenceCheckPaths: [String] { lock.lock(); defer { lock.unlock() }; return existenceChecks }

    enum TestError: Error {
        case trashFailed(String)
        case removeFailed(String)
        case deleteFailed(String)
    }
}

/// 进度回调收集器（回调可能在任意线程 → 加锁）。
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(done: Int, total: Int)] = []

    func append(done: Int, total: Int) {
        lock.lock()
        values.append((done, total))
        lock.unlock()
    }

    var snapshot: [(done: Int, total: Int)] {
        lock.lock(); defer { lock.unlock() }; return values
    }
}

private func iosItems(_ ids: [String]) -> [TrackDeletionService.Item] {
    ids.map { TrackDeletionService.Item(stableId: $0, path: "/tmp/\($0).flac") }
}

private func macItem(_ index: Int) -> TrackDeletionService.Item {
    TrackDeletionService.Item(
        stableId: "stable-\(index)",
        title: "Song \(index)",
        path: "/music/song\(index).flac"
    )
}

// MARK: - 策略 × 失败路径（两端共有语义）

@Suite("曲目删除唯一入口 · 核心语义（策略 × 失败路径）")
struct TrackDeletionServiceTests {
    @Test("平台默认值 = 数据：iOS 默认 .delete（行为零变化）/ macOS 默认 .trash")
    func platformDefaultsAreData() {
        // iOS：永久删除——实测 iOS 容器无废纸篓宗卷，默认 .trash 会让「关掉只从曲库移除」的删歌永远失败
        #expect(TrackDeletionService.Policy.ios(libraryOnly: false).fileAction == .delete)
        #expect(TrackDeletionService.Policy.ios(libraryOnly: true).fileAction == .delete)
        // libraryOnly 按设置透传（沿用既有开关语义）
        #expect(TrackDeletionService.Policy.ios(libraryOnly: true).libraryOnly)
        #expect(!TrackDeletionService.Policy.ios(libraryOnly: false).libraryOnly)

        // macOS：进废纸篓（可恢复）；Mac 没有「只从曲库移除」开关（现状保留）
        #expect(TrackDeletionService.Policy.mac().fileAction == .trash)
        #expect(!TrackDeletionService.Policy.mac().libraryOnly)

        // `.trash` 仍是合法策略（只是不是 iOS 默认）——两条腿都在
        #expect(TrackDeletionService.FileAction.allCases == [.trash, .delete])
    }

    @Test("libraryOnly：只加排除标记，不碰磁盘（连存在性都不查）")
    func libraryOnlyExcludesWithoutTouchingDisk() {
        let fake = FakeDeletionEnvironment()
        let outcome = TrackDeletionService.delete(
            items: iosItems(["a", "b"]),
            policy: TrackDeletionService.Policy(fileAction: .trash, libraryOnly: true),
            environment: fake.environment()
        )

        #expect(outcome.deleted == 2)
        #expect(outcome.excludedFromLibrary == 2)
        #expect(outcome.failed == 0)
        #expect(outcome.fileRemovalFailed == 0)
        #expect(fake.trashedPaths.isEmpty)
        #expect(fake.removedPaths.isEmpty)
        #expect(fake.existenceCheckPaths.isEmpty)
        #expect(fake.excludedIds == ["a", "b"])
        #expect(fake.deletedStableIds == ["a", "b"])
    }

    @Test("默认分支（fileAction: .trash）：进废纸篓 + 删 DB 引用，顺序稳定")
    func trashPolicyMovesFilesThenRemovesReferences() {
        let fake = FakeDeletionEnvironment()
        fake.existingPaths = ["/tmp/a.flac", "/tmp/b.flac"]
        let outcome = TrackDeletionService.delete(
            items: iosItems(["a", "b"]),
            policy: TrackDeletionService.Policy(fileAction: .trash),
            environment: fake.environment()
        )

        #expect(outcome.deleted == 2)
        #expect(outcome.excludedFromLibrary == 0)
        #expect(outcome.failed == 0)
        #expect(fake.excludedIds.isEmpty)
        #expect(fake.trashedPaths == ["/tmp/a.flac", "/tmp/b.flac"])
        #expect(fake.removedPaths.isEmpty, "策略是废纸篓，就不该走永久删除那条腿")
        #expect(fake.deletedStableIds == ["a", "b"])
    }

    @Test("fileAction: .delete：永久删除那条腿仍然可用（策略是数据，不是死代码）")
    func deletePolicyRemovesPermanently() {
        let fake = FakeDeletionEnvironment()
        fake.existingPaths = ["/tmp/a.flac"]
        let outcome = TrackDeletionService.delete(
            items: iosItems(["a"]),
            policy: TrackDeletionService.Policy(fileAction: .delete),
            environment: fake.environment()
        )

        #expect(outcome.deleted == 1)
        #expect(outcome.failed == 0)
        #expect(fake.removedPaths == ["/tmp/a.flac"])
        #expect(fake.trashedPaths.isEmpty)
        #expect(fake.deletedStableIds == ["a"])
    }

    @Test("文件已不在磁盘：不当失败，照常清 DB 引用（同 Mac 语义）")
    func missingFileStillClearsReference() {
        let fake = FakeDeletionEnvironment()
        let outcome = TrackDeletionService.delete(
            items: iosItems(["a"]),
            policy: TrackDeletionService.Policy(fileAction: .trash),
            environment: fake.environment()
        )

        #expect(outcome.deleted == 1)
        #expect(outcome.failed == 0)
        #expect(outcome.fileRemovalFailed == 0)
        #expect(fake.trashedPaths.isEmpty, "文件都不在了，不该再去动一次")
        #expect(fake.deletedStableIds == ["a"])
    }

    @Test("文件动作失败 → 保留曲目（不删库引用），其余曲目继续处理")
    func fileActionFailureKeepsTrack() {
        let fake = FakeDeletionEnvironment()
        fake.existingPaths = ["/tmp/a.flac", "/tmp/b.flac", "/tmp/c.flac"]
        fake.trashErrorPaths = ["/tmp/b.flac"]
        let outcome = TrackDeletionService.delete(
            items: iosItems(["a", "b", "c"]),
            policy: TrackDeletionService.Policy(fileAction: .trash),
            environment: fake.environment()
        )

        #expect(outcome.deleted == 2)
        #expect(outcome.failed == 1)
        #expect(outcome.fileRemovalFailed == 1)
        #expect(fake.trashedPaths == ["/tmp/a.flac", "/tmp/b.flac", "/tmp/c.flac"])
        #expect(
            fake.deletedStableIds == ["a", "c"],
            "删不掉文件的那首必须留在库里（2026-09-17 纠正：旧实现会连库引用一起删）"
        )
    }

    @Test("DB 删除失败 → 计入 failed，其余曲目继续处理")
    func referenceFailureIsCountedAndLoopContinues() {
        let fake = FakeDeletionEnvironment()
        fake.existingPaths = ["/tmp/a.flac", "/tmp/b.flac", "/tmp/c.flac"]
        fake.deleteErrorStableIds = ["b"]
        let outcome = TrackDeletionService.delete(
            items: iosItems(["a", "b", "c"]),
            policy: TrackDeletionService.Policy(fileAction: .trash),
            environment: fake.environment()
        )

        #expect(outcome.deleted == 2)
        #expect(outcome.failed == 1)
        #expect(outcome.fileRemovalFailed == 0)
        #expect(fake.trashedPaths == ["/tmp/a.flac", "/tmp/b.flac", "/tmp/c.flac"])
        #expect(fake.deletedStableIds == ["a", "c"])
    }

    @Test("空输入：什么都不做")
    func emptyInputIsNoop() {
        let fake = FakeDeletionEnvironment()
        let outcome = TrackDeletionService.delete(
            items: [],
            policy: TrackDeletionService.Policy(fileAction: .trash),
            environment: fake.environment()
        )

        #expect(outcome == TrackDeletionService.Outcome())
        #expect(fake.trashedPaths.isEmpty)
        #expect(fake.removedPaths.isEmpty)
        #expect(fake.deletedStableIds.isEmpty)
    }
}

// MARK: - Mac 批量路径（原 MacTrashServiceTests 用例逐条保留）

@Suite("曲目删除唯一入口 · Mac 批量路径（原 MacTrashService 语义回归）")
struct TrackDeletionServiceMacPathTests {
    @Test("文件存在 + trash 成功 + DB 成功：计入 deleted 且 deletedAny 为真")
    func successfulTrashClearsRecord() async {
        let fake = FakeDeletionEnvironment()
        fake.existingPaths = ["/music/song0.flac"]

        let result = await TrackDeletionService.trash(
            items: [macItem(0)],
            environment: fake.environment()
        )

        #expect(result.failed == 0)
        #expect(result.deletedAny)
        #expect(result.processed == 1)
        #expect(!result.cancelled)
        #expect(fake.trashedPaths == ["/music/song0.flac"])
        #expect(fake.deleteReferenceAttempts == ["stable-0"])
    }

    @Test("文件已丢（磁盘不存在）：跳过 trash，仍清理 DB 引用")
    func missingFileStillClearsRecord() async {
        let fake = FakeDeletionEnvironment()

        let result = await TrackDeletionService.trash(
            items: [macItem(0)],
            environment: fake.environment()
        )

        #expect(result.failed == 0)
        #expect(result.deletedAny)
        #expect(fake.trashedPaths.isEmpty)
        #expect(fake.deleteReferenceAttempts == ["stable-0"])
        #expect(fake.logMessages.contains { $0.contains("文件不存在(磁盘已丢)") })
    }

    @Test("trash 失败且文件仍在：计入 failed，且不得删 DB 引用（保留曲目）")
    func trashFailureKeepsRecord() async {
        let fake = FakeDeletionEnvironment()
        fake.existingPaths = ["/music/song0.flac"]
        fake.trashErrorPaths = ["/music/song0.flac"]

        let result = await TrackDeletionService.trash(
            items: [macItem(0)],
            environment: fake.environment()
        )

        #expect(result.failed == 1)
        #expect(!result.deletedAny)
        #expect(result.processed == 1)
        #expect(fake.deleteReferenceAttempts.isEmpty)
    }

    @Test("DB 删除失败：计入 failed，成功项仍置 deletedAny")
    func deleteFailureCounted() async {
        let fake = FakeDeletionEnvironment()
        fake.existingPaths = ["/music/song0.flac", "/music/song1.flac"]
        fake.deleteErrorStableIds = ["stable-1"]

        let result = await TrackDeletionService.trash(
            items: [macItem(0), macItem(1)],
            environment: fake.environment()
        )

        #expect(result.failed == 1)
        #expect(result.deletedAny)
        #expect(result.processed == 2)
        #expect(fake.deleteReferenceAttempts == ["stable-0", "stable-1"])
    }

    @Test("取消在逐首之间生效：剩余曲目不再处理")
    func cancellationStopsRemainingItems() async {
        let fake = FakeDeletionEnvironment()
        fake.existingPaths = ["/music/song0.flac", "/music/song1.flac", "/music/song2.flac"]
        fake.cancelAfter = 1

        let result = await TrackDeletionService.trash(
            items: [macItem(0), macItem(1), macItem(2)],
            environment: fake.environment()
        )

        // 第一首前探测点 0 → 1（未到 cancelAfter）→ 处理第一首；第二首前探测点 1 → 取消
        #expect(result.cancelled)
        #expect(result.processed == 1)
        #expect(fake.trashedPaths == ["/music/song0.flac"])
        #expect(fake.deleteReferenceAttempts == ["stable-0"])
    }

    @Test("进度回调按处理顺序递增到总数")
    func progressReportedInOrder() async {
        let fake = FakeDeletionEnvironment()
        fake.existingPaths = ["/music/song0.flac", "/music/song1.flac", "/music/song2.flac"]

        let box = ProgressBox()
        _ = await TrackDeletionService.trash(
            items: [macItem(0), macItem(1), macItem(2)],
            environment: fake.environment(),
            onProgress: { done, total in box.append(done: done, total: total) }
        )

        #expect(box.snapshot.map(\.done) == [1, 2, 3])
        #expect(box.snapshot.allSatisfy { $0.total == 3 })
    }

    @Test("空批次：不产生任何调用")
    func emptyBatchIsNoOp() async {
        let fake = FakeDeletionEnvironment()

        let result = await TrackDeletionService.trash(items: [], environment: fake.environment())

        #expect(result == TrackDeletionService.Outcome())
        #expect(fake.trashedPaths.isEmpty)
        #expect(fake.deleteReferenceAttempts.isEmpty)
    }

    @Test("单首结论回调：成功/失败都会被报出（诊断链路保留）")
    func itemOutcomeCallbackReported() async {
        let fake = FakeDeletionEnvironment()
        fake.existingPaths = ["/music/song0.flac", "/music/song1.flac"]
        fake.deleteErrorStableIds = ["stable-1"]

        let box = ItemOutcomeBox()
        _ = await TrackDeletionService.trash(
            items: [macItem(0), macItem(1)],
            environment: fake.environment(),
            onItemProcessed: { item, outcome in box.append(stableId: item.stableId, outcome: outcome) }
        )

        #expect(box.snapshot.map(\.stableId) == ["stable-0", "stable-1"])
        #expect(box.snapshot.map(\.outcome) == [.deleted, .failed])
    }
}

/// 单首结论收集器（回调可能在任意线程 → 加锁）。
private final class ItemOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(stableId: String, outcome: TrackDeletionService.ItemOutcome)] = []

    func append(stableId: String, outcome: TrackDeletionService.ItemOutcome) {
        lock.lock()
        values.append((stableId, outcome))
        lock.unlock()
    }

    var snapshot: [(stableId: String, outcome: TrackDeletionService.ItemOutcome)] {
        lock.lock(); defer { lock.unlock() }; return values
    }
}

// MARK: - iOS 废纸篓实测（真实 FileManager，模拟器容器内取证）

@Suite("iOS 容器里 FileManager.trashItem 的真实行为（实测取证）")
struct TrashItemProbeTests {
    /// `trashItem` 在两个方向上都不得说谎：
    /// · 报成功 → 原路径必须真的消失（真移动）；
    /// · 报错 → 文件必须原样保留（不得退化成「静默删除」）。
    /// 本用例同时把实测结论 print 出来（供人工核对；不静默假设 iOS 行为）。
    @Test("真实 trashItem：要么真移走，要么报错且文件原样保留")
    func realTrashItemTellsTheTruth() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("trash-probe-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let file = dir.appendingPathComponent("probe.flac")
        let payload = Data([0x66, 0x4C, 0x61, 0x43, 0x00])
        try payload.write(to: file)

        var resultingURL: NSURL?
        var verdict: String
        do {
            try fm.trashItem(at: file, resultingItemURL: &resultingURL)
            verdict = "成功（未报错）"
            #expect(
                !fm.fileExists(atPath: file.path),
                "trashItem 报成功却把文件留在原路径 = 说谎（假成功）"
            )
            if let destination = resultingURL as URL? {
                #expect(
                    fm.fileExists(atPath: destination.path),
                    "resultingItemURL 指向的位置应当真的有文件：\(destination.path)"
                )
            }
        } catch {
            verdict = "报错：\(error)"
            #expect(
                fm.fileExists(atPath: file.path),
                "trashItem 报错时文件必须原样保留（不得退化成删除）"
            )
        }

        print(
            """
            【iOS 废纸篓实测】单文件临时目录
              结论：\(verdict)
              原路径是否还在：\(fm.fileExists(atPath: file.path))
              去向（resultingItemURL）：\(String(describing: resultingURL))
              容器 temp：\(fm.temporaryDirectory.path)
              容器目录（NSHomeDirectory）：\(NSHomeDirectory())
            """
        )
    }

    /// 目录场景（Mac 端 trash 目标常是文件；这里补一条目录观测，避免把「文件能移走」外推成「目录也行」）。
    @Test("真实 trashItem 对目录：结论同样不得说谎")
    func realTrashItemOnDirectoryTellsTheTruth() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("trash-probe-dir-\(UUID().uuidString)")
        let payload = root.appendingPathComponent("album")
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data([0x00]).write(to: payload.appendingPathComponent("a.flac"))
        defer { try? fm.removeItem(at: root) }

        var resultingURL: NSURL?
        var verdict: String
        do {
            try fm.trashItem(at: payload, resultingItemURL: &resultingURL)
            verdict = "成功（未报错）"
            #expect(!fm.fileExists(atPath: payload.path), "报成功就必须真的移走目录")
        } catch {
            verdict = "报错：\(error)"
            #expect(fm.fileExists(atPath: payload.path), "报错时目录必须原样保留")
        }

        print("【iOS 废纸篓实测】目录场景：\(verdict)｜原路径是否还在：\(fm.fileExists(atPath: payload.path))")
    }
}
