//
//  ShuffleOrderModeTests.swift
//  QQPlayerTests
//
//  随机顺序的**行为**回归（2026-09-20 真机反馈：点「随机」后曲终仍按原顺序播）。
//
//  症状机制（审计定位）：`scheduleGaplessNextIfPossible()` 会把下一首的**音频段**排进
//  `playerNode`；而随机只重排了 `playbackQueue` ⇒ 曲终 `promoteGaplessNextIfAvailable()`
//  用重排前的 `nextTrackIndex` 提升了旧邻居 = 「随机开着还是顺序播」。
//
//  本文件锁两条契约：
//    ① 顺序 / 成员变化必须作废陈旧预载（`invalidatePreloadedNextForOrderChange()` 唯一入口）
//    ② 提升自带**队列一致性**硬前提（任何遗漏作废的路径也不能把歌播错）
//
//  注：`PlayerEngine.init` 是 private，与 `PlaybackOrderModeTests` 同款做法复用 `.shared`；
//  测试结束还原全部被写状态（共享单例防泄漏），串行执行。
//

import Foundation
import Testing

@testable import QQPlayer

@MainActor
@Suite(.serialized)
struct ShuffleOrderModeTests {
    private let engine = PlayerEngine.shared

    private func makeTrack(_ id: String) -> Track {
        Track(stableId: id, title: id, path: "/m/\(id).flac")
    }

    /// 快照 / 还原引擎状态（共享单例，防泄漏到其他测试）。
    private func withEngineRestored(_ body: () -> Void) {
        let savedQueue = engine.playbackQueue
        let savedIndex = engine.currentIndex
        let savedTrack = engine.currentTrack
        let savedOriginal = engine.originalQueue
        let savedFlags = (engine.isShuffled, engine.isRepeating, engine.isLoopingSong)
        let savedNext = (engine.nextTrack, engine.nextTrackIndex)
        let savedGapless = engine.gaplessScheduled
        defer {
            engine.playbackQueue = savedQueue
            engine.currentIndex = savedIndex
            engine.currentTrack = savedTrack
            engine.originalQueue = savedOriginal
            engine.isShuffled = savedFlags.0
            engine.isRepeating = savedFlags.1
            engine.isLoopingSong = savedFlags.2
            engine.nextTrack = savedNext.0
            engine.nextTrackIndex = savedNext.1
            engine.gaplessScheduled = savedGapless
        }
        body()
    }

    /// 造一个「重排前已预载 + 已排段」的现场：队列 [a, b, c]，正在播 a，无缝接的是 b。
    /// `originalQueue` 置空 ⇒ 关随机路径不触数据库。
    private func stageStalePreload() {
        let a = makeTrack("a")
        engine.playbackQueue = [a, makeTrack("b"), makeTrack("c")]
        engine.currentTrack = a
        engine.currentIndex = 0
        engine.originalQueue = []
        engine.isShuffled = false
        engine.nextTrack = engine.playbackQueue[1]
        engine.nextTrackIndex = 1
        engine.gaplessScheduled = true
    }

    @Test("点「随机」→ 作废陈旧的无缝预载（真机回归：否则曲终接的是重排前的邻居）")
    func shuffleInvalidatesStalePreload() {
        withEngineRestored {
            stageStalePreload()

            engine.toggleShuffle()

            #expect(engine.isShuffled)
            #expect(engine.gaplessScheduled == false, "已排段的陈旧预载必须作废")
            #expect(engine.nextTrack == nil)
            #expect(engine.nextTrackIndex == nil)
        }
    }

    @Test("关「随机」同样作废（恢复原顺序后旧 index 也可能指向别的歌）")
    func unshuffleInvalidatesStalePreload() {
        withEngineRestored {
            stageStalePreload()
            engine.isShuffled = true

            engine.toggleShuffle()

            #expect(engine.isShuffled == false)
            #expect(engine.gaplessScheduled == false)
            #expect(engine.nextTrackIndex == nil)
        }
    }

    @Test("插播（insertNext）改变「下一首」⇒ 陈旧预载必须作废")
    func insertNextInvalidatesStalePreload() {
        withEngineRestored {
            stageStalePreload()

            engine.insertNext(makeTrack("x"))

            #expect(engine.gaplessScheduled == false)
            #expect(engine.nextTrackIndex == nil)
        }
    }

    @Test("提升的硬前提：`nextTrackIndex` 指向的必须仍是同一首（结构防护）")
    func promotionRejectsInconsistentQueue() {
        withEngineRestored {
            stageStalePreload()
            // 模拟「重排后没作废」的最坏情况：index 1 已换成 c，陈旧预载还写着 b
            engine.playbackQueue = [engine.playbackQueue[0], makeTrack("c"), engine.playbackQueue[1]]

            #expect(
                engine.promoteGaplessNextIfAvailable() == false,
                "队列已变 ⇒ 拒绝提升，交回按当前队列推进"
            )
            #expect(engine.gaplessScheduled == false, "被拒后要清掉陈旧状态，别在后续曲终反复尝试")
        }
    }
}
