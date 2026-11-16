//
//  LyricAlignmentControllerTests.swift
//  QQPlayerTests
//
//  状态机：注入假 service，验证成功 / 失败 / 取消三路径、进度→阶段映射、
//  revert 后「已对齐」事实源翻假。不测 SwiftUI 视图。
//

import Foundation
import Testing

@testable import QQPlayer

@MainActor
struct LyricAlignmentControllerTests {
    // MARK: - 夹具

    /// 假对齐服务：按脚本吐进度，可选中途抛错 / 延时（取消用）。
    private actor FakeAlignmentService: LyricAlignmentReporting {
        private let report: LyricAlignmentReport
        private let error: LyricAlignmentError?
        private let progressSteps: [Double]
        private let delayNanoseconds: UInt64

        init(
            report: LyricAlignmentReport,
            error: LyricAlignmentError? = nil,
            progressSteps: [Double] = [],
            delayNanoseconds: UInt64 = 0
        ) {
            self.report = report
            self.error = error
            self.progressSteps = progressSteps
            self.delayNanoseconds = delayNanoseconds
        }

        func align(
            track: Track,
            currentLyrics: Lyrics,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws -> LyricAlignmentReport {
            for step in progressSteps { progress(step) }
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            if let error { throw error }
            return report
        }
    }

    /// 记录 onLyricsChanged 回调（@MainActor 闭包的可变捕获需要引用类型）。
    @MainActor
    private final class ChangeRecorder {
        var stableIds: [String] = []
    }

    private func makeTrack(stableId: String = "stable-align-controller") -> Track {
        Track(
            id: nil,
            stableId: stableId,
            albumId: nil,
            artistId: nil,
            title: "控制器测试",
            genre: nil,
            trackNo: nil,
            discNo: nil,
            durationMs: 20_000,
            sampleRate: nil,
            bitDepth: nil,
            channels: nil,
            path: "/tmp/controller-test.mp3",
            fileSize: nil,
            modificationDate: nil,
            contentHash: nil,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil
        )
    }

    private func makeLyrics() -> Lyrics {
        Lyrics(
            plainLyrics: "第一句\n第二句",
            syncedLyrics: [
                LyricsLine(timestamp: 0, text: "第一句", translation: nil, roman: nil),
                LyricsLine(timestamp: 5, text: "第二句", translation: nil, roman: nil),
            ],
            isInstrumental: false,
            source: .lrclib
        )
    }

    private func makeReport(lineCount: Int = 4, matchedCount: Int = 3) -> LyricAlignmentReport {
        LyricAlignmentReport(
            lineCount: lineCount,
            matchedCount: matchedCount,
            medianOffset: 0.2,
            localeIdentifier: "zh",
            warnings: []
        )
    }

    private func makeStore() throws -> (store: AlignedLyricsStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-align-controller-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (AlignedLyricsStore(directory: directory), directory)
    }

    // MARK: - 成功路径

    @Test("成功：finished(报告) + 触发歌词刷新回调")
    func successFinishesAndNotifies() async throws {
        let report = makeReport()
        let service = FakeAlignmentService(report: report, progressSteps: [0.1, 0.5, 0.9])
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ChangeRecorder()
        let controller = LyricAlignmentController(
            service: service,
            store: store,
            onLyricsChanged: { recorder.stableIds.append($0) }
        )
        let track = makeTrack()

        await controller.start(track: track, lyrics: makeLyrics())

        #expect(controller.state == .finished(report))
        #expect(recorder.stableIds == [track.stableId])
    }

    @Test("运行中：state 是 running，且 sheet 需要展示")
    func runningStatePresentsSheet() async throws {
        let service = FakeAlignmentService(report: makeReport(), delayNanoseconds: 300_000_000)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = LyricAlignmentController(service: service, store: store, onLyricsChanged: { _ in })

        let task = Task { await controller.start(track: makeTrack(), lyrics: makeLyrics()) }
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(controller.isRunning)
        #expect(controller.presentsSheet)

        controller.cancel()
        await task.value
    }

    // MARK: - 失败路径

    @Test("失败：failed(可读文案)")
    func failureProducesMessage() async throws {
        let service = FakeAlignmentService(report: makeReport(), error: .audioUnreadable)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ChangeRecorder()
        let controller = LyricAlignmentController(
            service: service,
            store: store,
            onLyricsChanged: { recorder.stableIds.append($0) }
        )

        await controller.start(track: makeTrack(), lyrics: makeLyrics())

        guard case let .failed(message) = controller.state else {
            Issue.record("失败路径应落到 failed，实际 \(controller.state)")
            return
        }
        #expect(!message.isEmpty)
        #expect(recorder.stableIds.isEmpty, "失败不应触发歌词刷新")
    }

    // MARK: - 取消路径

    @Test("取消（cancelled 错误）：静默回 idle")
    func cancelledErrorIsSilent() async throws {
        let service = FakeAlignmentService(report: makeReport(), error: .cancelled)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = LyricAlignmentController(service: service, store: store, onLyricsChanged: { _ in })

        await controller.start(track: makeTrack(), lyrics: makeLyrics())

        #expect(controller.state == .idle)
    }

    @Test("取消（用户点取消）：正在跑的任务被打断，静默回 idle")
    func userCancelReturnsToIdle() async throws {
        let service = FakeAlignmentService(report: makeReport(), delayNanoseconds: 300_000_000)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ChangeRecorder()
        let controller = LyricAlignmentController(
            service: service,
            store: store,
            onLyricsChanged: { recorder.stableIds.append($0) }
        )

        let task = Task { await controller.start(track: makeTrack(), lyrics: makeLyrics()) }
        try await Task.sleep(nanoseconds: 80_000_000)
        controller.cancel()
        await task.value

        #expect(controller.state == .idle)
        #expect(recorder.stableIds.isEmpty, "取消不应触发歌词刷新")
    }

    // MARK: - 恢复原时间轴

    @Test("revert：删除 aligned 产物 → 已对齐翻假 + 触发刷新")
    func revertDeletesAlignedLyrics() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stableId = "stable-revert"
        try store.write(makeLyrics(), forStableId: stableId)
        #expect(LyricAlignmentFeature.isAligned(stableId: stableId, store: store))

        let recorder = ChangeRecorder()
        let controller = LyricAlignmentController(
            service: FakeAlignmentService(report: makeReport()),
            store: store,
            onLyricsChanged: { recorder.stableIds.append($0) }
        )

        try controller.revert(stableId: stableId)

        #expect(!LyricAlignmentFeature.isAligned(stableId: stableId, store: store))
        #expect(recorder.stableIds == [stableId])
    }

    // MARK: - 纯函数

    @Test("进度区间 → 阶段")
    func phaseMappingFollowsProgressRanges() {
        #expect(LyricAlignmentController.phase(for: 0) == .installingAssets)
        #expect(LyricAlignmentController.phase(for: 0.1) == .installingAssets)
        #expect(LyricAlignmentController.phase(for: 0.2) == .transcribing)
        #expect(LyricAlignmentController.phase(for: 0.84) == .transcribing)
        #expect(LyricAlignmentController.phase(for: 0.85) == .aligning)
        #expect(LyricAlignmentController.phase(for: 1) == .aligning)
    }

    @Test("低匹配率阈值：< 50% 才算低")
    func lowMatchRateBoundary() {
        #expect(LyricAlignmentController.isLowMatch(makeReport(lineCount: 4, matchedCount: 1)))
        #expect(!LyricAlignmentController.isLowMatch(makeReport(lineCount: 4, matchedCount: 2)))
        #expect(!LyricAlignmentController.isLowMatch(makeReport(lineCount: 4, matchedCount: 4)))
        #expect(LyricAlignmentController.isLowMatch(makeReport(lineCount: 0, matchedCount: 0)))
    }
}
