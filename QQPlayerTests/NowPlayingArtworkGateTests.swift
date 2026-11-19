//
//  NowPlayingArtworkGateTests.swift
//  QQPlayerTests
//
//  2026-11-19 CarPlay 封面偶发空白修复的回归用例。
//
//  修复前必红的点（结构性，不依赖真机复现）：
//    · 首次发布时 cachedArtwork 一定是 nil（切歌刚 reset 过）→ 发布出去的
//      nowPlayingInfo 没有 artwork 键，而 CarPlay 多数只在元数据变化时读一次；
//    · 真图到位后的补发是「读旧字典 + 只改 artwork 键」，半份字典会把 title 冲掉；
//    · 页头首取 nil 也算"已出结果"，真图晚到后再也不会重画。
//
//  本文件只测纯逻辑（决策 / 有界等待 / 代际 / 完整字典），不碰真机与 UI。
//

import Foundation
import MediaPlayer
import Testing

@testable import QQPlayer

@MainActor
struct NowPlayingArtworkGateTests {
    /// 生产侧是 MPMediaItemArtwork；这里只需要一个可比较身份的替身。
    private final class FakeArtwork {}

    // MARK: - ① 缓存命中

    @Test("① 缓存命中：直接用本曲封面，不算超时、不退回上一曲")
    func cacheHitWinsImmediately() {
        let cached = FakeArtwork()
        let resolution = NowPlayingArtworkGate.decide(
            cached: cached,
            arrived: FakeArtwork(),
            previous: FakeArtwork(),
            placeholder: FakeArtwork(),
            timedOut: true
        )
        #expect(resolution.source == .cached)
        #expect(resolution.artwork === cached)
        #expect(resolution.timedOut == false)
    }

    // MARK: - ② 超时前返回

    @Test("② 有界等待内返回：等待成功，用刚取到的真封面")
    func arrivesWithinTimeout() async {
        let task = Task { _ = try? await Task.sleep(for: .milliseconds(10)) }
        let finished = await NowPlayingBoundedWait.run(for: task, timeout: .seconds(5))
        #expect(finished)

        let arrived = FakeArtwork()
        let resolution = NowPlayingArtworkGate.decide(
            cached: nil,
            arrived: arrived,
            previous: FakeArtwork(),
            placeholder: FakeArtwork(),
            timedOut: !finished
        )
        #expect(resolution.source == .extracted)
        #expect(resolution.artwork === arrived)
    }

    // MARK: - ③ 超时兜底 + 迟到补发

    @Test("③ 超时：先用上一曲封面兜底，不取消后台任务")
    func timesOutUsesPreviousArtwork() async {
        let previous = FakeArtwork()
        // 加载侧 1s vs 超时 20ms：留 50× 余量，CI 机器再慢也不会翻转判定
        let task = Task { _ = try? await Task.sleep(for: .seconds(1)) }
        let finished = await NowPlayingBoundedWait.run(for: task, timeout: .milliseconds(20))
        #expect(finished == false)

        let fallback = NowPlayingArtworkGate.decide(
            cached: nil,
            arrived: nil,
            previous: previous,
            placeholder: FakeArtwork(),
            timedOut: true
        )
        #expect(fallback.source == .previousTrack)
        #expect(fallback.artwork === previous)
        #expect(fallback.timedOut)

        // 等待超时也**不许取消**加载任务：它还要在后台跑完并补发
        await task.value
        #expect(task.isCancelled == false)
    }

    @Test("③b 超时且没有上一曲：退回占位图（仍然带 artwork）")
    func timesOutWithoutPreviousUsesPlaceholder() {
        let placeholder = FakeArtwork()
        let resolution = NowPlayingArtworkGate.decide(
            cached: nil,
            arrived: nil,
            previous: nil,
            placeholder: placeholder,
            timedOut: true
        )
        #expect(resolution.source == .placeholder)
        #expect(resolution.artwork === placeholder)
    }

    @Test("③c 确定没有封面（非超时）：不许拿上一曲封面凑数")
    func missingArtworkDoesNotReusePrevious() {
        let placeholder = FakeArtwork()
        let resolution = NowPlayingArtworkGate.decide(
            cached: nil,
            arrived: nil,
            previous: FakeArtwork(),
            placeholder: placeholder,
            timedOut: false
        )
        #expect(resolution.source == .placeholder)
        #expect(resolution.artwork === placeholder)
    }

    @Test("③d 迟到结果补发：写的是完整字典，不是只改 artwork 键")
    func lateArrivalRepublishesFullDictionary() {
        let fields = NowPlayingInfoFields(
            title: "夜曲",
            artist: "周杰伦",
            duration: 226,
            elapsed: 12,
            rate: 1,
            queueCount: 3,
            queueIndex: 1,
            trackNumber: 2,
            artwork: PlayerEngine.placeholderArtwork
        )
        let info = NowPlayingInfoBuilder.dictionary(fields)

        #expect(info[MPMediaItemPropertyTitle] as? String == "夜曲")
        #expect(info[MPMediaItemPropertyArtist] as? String == "周杰伦")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval == 226)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 12)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 3)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int == 1)
        #expect(info[MPMediaItemPropertyAlbumTrackNumber] as? Int == 2)
        #expect(info[MPMediaItemPropertyArtwork] != nil)
        #expect(info.count == 10)
    }

    @Test("③e 可选字段为空时不写 nil 键，但核心键仍齐全")
    func builderSkipsNilFields() {
        let info = NowPlayingInfoBuilder.dictionary(
            NowPlayingInfoFields(
                title: "标题",
                artist: nil,
                duration: 1,
                elapsed: 0,
                rate: 0,
                queueCount: 0,
                queueIndex: nil,
                trackNumber: nil,
                artwork: nil
            )
        )
        #expect(info[MPMediaItemPropertyTitle] as? String == "标题")
        #expect(info[MPMediaItemPropertyArtwork] == nil)
        #expect(info.count == 6)
    }

    // MARK: - ④ / ⑤ 代际

    @Test("④ 旧曲目迟到回调：曲目或代际对不上一律丢弃")
    func staleResultIsRejected() {
        #expect(
            PlaybackTrackGate.isStillCurrent(
                trackId: "A",
                generation: 1,
                currentTrackId: "B",
                currentGeneration: 2
            ) == false
        )
        #expect(
            PlaybackTrackGate.isStillCurrent(
                trackId: "B",
                generation: 2,
                currentTrackId: "B",
                currentGeneration: 2
            )
        )
    }

    @Test("⑤ 连续切歌 A→B→A：同 id 的旧代际也不许当新结果")
    func rapidSwitchBackDoesNotCross() {
        // 旧口径只比 trackId，会误判成「仍是当前曲」
        #expect(PlaybackTrackGate.isStillCurrent(trackId: "A", currentTrackId: "A"))
        // 新口径：代际不同 → 丢弃（A→B→A 的第一次回调属于 gen 1）
        #expect(
            PlaybackTrackGate.isStillCurrent(
                trackId: "A",
                generation: 1,
                currentTrackId: "A",
                currentGeneration: 3
            ) == false
        )
        #expect(
            PlaybackTrackGate.isStillCurrent(
                trackId: "A",
                generation: 3,
                currentTrackId: "A",
                currentGeneration: 3
            )
        )
    }

    // MARK: - 占位图（任何发布都必须带 artwork 键）

    @Test("占位图：取图不为 nil、方形、边长 ≤1024（boundsSize 与图一致）")
    func placeholderArtworkIsUsable() throws {
        let artwork = PlayerEngine.placeholderArtwork
        let image = artwork.image(at: CGSize(width: 512, height: 512))
        let size = try #require(image).size
        #expect(size.width > 0)
        #expect(size.width <= 1024)
        #expect(size.height <= 1024)
        #expect(size.width == size.height)
    }
}
