//
//  MacTrashServiceTests.swift
//  QQPlayerTests
//
//  批量「移到废纸篓」执行层（MacTrashService）语义回归用例
//  —— 2026-09-12 审计批次 B4 · H1/M1。
//
//  修复前这段逻辑写死在 MacTrackListView.movePendingTrashTracks 的
//  `Task { @MainActor in … }` 里：`FileManager.trashItem` 与 `DatabaseManager.deleteTrack`
//  逐首**同步**跑在主 actor 上——右键多选数百首、或碰上 iCloud dataless 文件
//  （trashItem 走网络往返）时窗口卡死数十秒且无法取消；且因为依赖
//  FileManager/DB 单例、没有缝，完全不可测。
//
//  本次把「逐首处理 + 计数 + 取消点」下沉为可注入环境的 nonisolated async
//  MacTrashService（生产默认 `.live`，测试注入假文件系统/假 DB）。本文件锁定：
//  1) 磁盘已丢仍清 DB 引用（web 语义）；
//  2) trash 失败**不得**删 DB 引用（文件还在 → 保留曲目）；
//  3) DB 删除失败计入 failedCount 且不置 deletedAny；
//  4) 取消在逐首之间生效，未处理项不产生调用；
//  5) 进度回调按处理顺序递增。
//  修复前这些用例连编译都过不了（MacTrashService 符号不存在），语义只存在于
//  View 的私有方法里——这正是审计点名的「不可测路径」。
//

import Foundation
import Testing

@testable import QQPlayer

/// 假执行环境：记录 trash / deleteRecord 调用顺序与日志，并可按需注入失败。
private final class FakeTrashEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var trashed: [String] = []
    private var deleted: [String] = []
    private var logs: [String] = []

    /// 抛错的 path（trash 阶段）
    var trashErrorPaths: Set<String> = []
    /// 抛错的 stableId（DB 删除阶段）
    var deleteErrorStableIds: Set<String> = []
    /// 文件系统中「存在」的 path（其余视为磁盘已丢）
    var existingPaths: Set<String> = []
    /// 返回第几次「逐首取消探测」后开始取消（nil = 从不）
    var cancelAfter: Int?
    private var cancelProbe = 0

    func environment() -> MacTrashService.Environment {
        MacTrashService.Environment(
            fileExists: { [self] path in existingPaths.contains(path) },
            trashItem: { [self] path in
                lock.lock()
                trashed.append(path)
                let shouldThrow = trashErrorPaths.contains(path)
                lock.unlock()
                if shouldThrow { throw TestError.trashFailed(path) }
            },
            deleteRecord: { [self] stableId in
                lock.lock()
                deleted.append(stableId)
                let shouldThrow = deleteErrorStableIds.contains(stableId)
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

    var trashedPaths: [String] {
        lock.lock(); defer { lock.unlock() }; return trashed
    }

    var deletedStableIds: [String] {
        lock.lock(); defer { lock.unlock() }; return deleted
    }

    var logMessages: [String] {
        lock.lock(); defer { lock.unlock() }; return logs
    }

    enum TestError: Error {
        case trashFailed(String)
        case deleteFailed(String)
    }
}

private func item(_ index: Int) -> MacTrashService.Item {
    MacTrashService.Item(
        stableId: "stable-\(index)",
        title: "Song \(index)",
        path: "/music/song\(index).flac"
    )
}

struct MacTrashServiceTests {
    @Test("文件存在 + trash 成功 + DB 成功：计入 deleted 且 deletedAny 为真")
    func successfulTrashClearsRecord() async {
        let environment = FakeTrashEnvironment()
        environment.existingPaths = ["/music/song0.flac"]
        let recorder = environment.environment()

        let result = await MacTrashService.trash(items: [item(0)], environment: recorder)

        #expect(result.failedCount == 0)
        #expect(result.deletedAny)
        #expect(result.processedCount == 1)
        #expect(!result.cancelled)
        #expect(environment.trashedPaths == ["/music/song0.flac"])
        #expect(environment.deletedStableIds == ["stable-0"])
    }

    @Test("文件已丢（磁盘不存在）：跳过 trash，仍清理 DB 引用")
    func missingFileStillClearsRecord() async {
        let environment = FakeTrashEnvironment()
        environment.existingPaths = []
        let recorder = environment.environment()

        let result = await MacTrashService.trash(items: [item(0)], environment: recorder)

        #expect(result.failedCount == 0)
        #expect(result.deletedAny)
        #expect(environment.trashedPaths.isEmpty)
        #expect(environment.deletedStableIds == ["stable-0"])
        #expect(environment.logMessages.contains { $0.contains("文件不存在(磁盘已丢)") })
    }

    @Test("trash 失败且文件仍在：计入 failedCount，且不得删 DB 引用（保留曲目）")
    func trashFailureKeepsRecord() async {
        let environment = FakeTrashEnvironment()
        environment.existingPaths = ["/music/song0.flac"]
        environment.trashErrorPaths = ["/music/song0.flac"]
        let recorder = environment.environment()

        let result = await MacTrashService.trash(items: [item(0)], environment: recorder)

        #expect(result.failedCount == 1)
        #expect(!result.deletedAny)
        #expect(result.processedCount == 1)
        #expect(environment.deletedStableIds.isEmpty)
    }

    @Test("DB 删除失败：计入 failedCount，成功项仍置 deletedAny")
    func deleteFailureCounted() async {
        let environment = FakeTrashEnvironment()
        environment.existingPaths = ["/music/song0.flac", "/music/song1.flac"]
        environment.deleteErrorStableIds = ["stable-1"]
        let recorder = environment.environment()

        let result = await MacTrashService.trash(items: [item(0), item(1)], environment: recorder)

        #expect(result.failedCount == 1)
        #expect(result.deletedAny)
        #expect(result.processedCount == 2)
        #expect(environment.deletedStableIds == ["stable-0", "stable-1"])
    }

    @Test("取消在逐首之间生效：剩余曲目不再处理")
    func cancellationStopsRemainingItems() async {
        let environment = FakeTrashEnvironment()
        environment.existingPaths = ["/music/song0.flac", "/music/song1.flac", "/music/song2.flac"]
        environment.cancelAfter = 1
        let recorder = environment.environment()

        let result = await MacTrashService.trash(items: [item(0), item(1), item(2)], environment: recorder)

        // 第一首前探测点 0 → 1（未到 cancelAfter）→ 处理第一首；第二首前探测点 1 → 取消
        #expect(result.cancelled)
        #expect(result.processedCount == 1)
        #expect(environment.trashedPaths == ["/music/song0.flac"])
        #expect(environment.deletedStableIds == ["stable-0"])
    }

    @Test("进度回调按处理顺序递增到总数")
    func progressReportedInOrder() async {
        let environment = FakeTrashEnvironment()
        environment.existingPaths = ["/music/song0.flac", "/music/song1.flac", "/music/song2.flac"]
        let recorder = environment.environment()

        let box = ProgressBox()
        _ = await MacTrashService.trash(
            items: [item(0), item(1), item(2)],
            environment: recorder,
            onProgress: { done, total in box.append(done: done, total: total) }
        )

        #expect(box.snapshot.map(\.done) == [1, 2, 3])
        #expect(box.snapshot.allSatisfy { $0.total == 3 })
    }

    @Test("空批次：不产生任何调用")
    func emptyBatchIsNoOp() async {
        let environment = FakeTrashEnvironment()
        let recorder = environment.environment()

        let result = await MacTrashService.trash(items: [], environment: recorder)

        #expect(result == MacTrashService.BatchResult())
        #expect(environment.trashedPaths.isEmpty)
        #expect(environment.deletedStableIds.isEmpty)
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
