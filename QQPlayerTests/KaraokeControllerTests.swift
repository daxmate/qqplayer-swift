//
//  KaraokeControllerTests.swift
//  QQPlayerTests
//
//  跟唱模式控制器状态机测试（@MainActor 共享单例，串行执行）：
//  - 句末自动停 / 单句循环 / AB 循环（等选终点 / B 终点 / 区间中间句 / 区间外点击）
//  - 倍速档位循环 / 退出跟唱清理 / 切歌重置 / 跳转静默窗口 / 最后一句句末 = duration
//
//  通过 FakeActions 注入动作层，验证 KaraokeController 的决策输出
//  （seek 目标 + 是否保持播放 + 倍速设置），不碰真实 PlayerEngine。
//

import Foundation
import Testing

@testable import QQPlayer

/// 播放器动作 fake：记录 seek 目标与倍速设置（KaraokeController 的薄桥测试替身）
@MainActor
final class FakeActions: KaraokeActions {
    var seeks: [(time: TimeInterval, play: Bool)] = []
    var rates: [Double] = []

    func seekAndPlay(to time: TimeInterval) async {
        seeks.append((time, true))
    }

    func seekAndPause(to time: TimeInterval) async {
        seeks.append((time, false))
    }

    func setRate(_ rate: Double) {
        rates.append(rate)
    }
}

@MainActor
@Suite(.serialized)
struct KaraokeControllerTests {
    // MARK: - 基础设施

    /// 按时间戳构造测试歌词行（text 与 index 对应，便于断言）
    private func makeLines(_ timestamps: TimeInterval...) -> [LyricsLine] {
        timestamps.enumerated().map { LyricsLine(timestamp: $0.element, text: "行\($0.offset)") }
    }

    /// 恢复共享单例到干净状态并注入新 fake。
    /// expireJumpQuiet: 需要本用例首个 tick 真正生效时传 true —— 等跳转静默窗口
    /// （0.3s）过期，避免上一个用例的 jump 抑制它（窗口是私有状态，测试无法直接重置）。
    /// 纯 clickLine / 断言不受抑制影响的用例传 false，不加时延（套件整体需在
    /// App 宿主 Siri 集成异步崩溃点前跑完）。
    private func makeFake(expireJumpQuiet: Bool) async -> FakeActions {
        let fake = FakeActions()
        let kc = KaraokeController.shared
        kc.actions = fake
        kc.setKaraokeOn(true) // 幂等进入，确保下面的退出路径完整清理
        kc.setKaraokeOn(false) // 退出：清 AB/单句 + 速度恢复 1.0
        kc.exitABLoop()
        kc.setLyrics([])
        fake.rates = []
        fake.seeks = []
        if expireJumpQuiet {
            try? await Task.sleep(nanoseconds: 320_000_000)
        }
        return fake
    }

    /// 让 jumpTo 里 spawn 的 @MainActor Task 执行完（把 seek 记录进 fake）
    private func drainMainActor() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    /// 断言 fake 收到恰好一次 seek 且目标时间/播放态一致（元组数组不支持 ==）
    private func expectSingleSeek(_ fake: FakeActions, time: TimeInterval, play: Bool) {
        #expect(fake.seeks.count == 1)
        #expect(fake.seeks.first?.time == time)
        #expect(fake.seeks.first?.play == play)
    }

    // MARK: - 句末自动停

    @Test("句末自动停：句末回句首暂停")
    func lineEndAutoStop() async {
        let fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5))

        kc.handlePlaybackTick(time: 10.0, duration: 10.0)
        await drainMainActor()

        expectSingleSeek(fake, time: 5.0, play: false)
    }

    @Test("回归：非末句播完即触发（缓存行句末检测，单句循环真正生效）")
    func midLineEndTriggersWithCachedLine() async {
        let fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5))

        kc.handlePlaybackTick(time: 4.0, duration: 10.0) // 缓存第 0 句（[0,5)）
        kc.handlePlaybackTick(time: 5.0, duration: 10.0) // 第 0 句播完（5.0 = 句末）
        await drainMainActor()

        expectSingleSeek(fake, time: 0.0, play: false) // 句末自动停：回第 0 句句首暂停
    }

    @Test("未到句末不动作（句中采样不触发）")
    func noActionBeforeLineEnd() async {
        let fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5))

        kc.handlePlaybackTick(time: 4.0, duration: 10.0) // 缓存第 0 句（句首 0，句末 5）
        kc.handlePlaybackTick(time: 4.5, duration: 10.0) // 仍在第 0 句内，未到句末
        await drainMainActor()

        #expect(fake.seeks.isEmpty)
    }

    // MARK: - 单句循环

    @Test("单句循环：句末重播本句（保持播放）")
    func singleLineLoop() async {
        let fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5))
        kc.toggleSingleLineLoop()

        kc.handlePlaybackTick(time: 10.0, duration: 10.0)
        await drainMainActor()

        expectSingleSeek(fake, time: 5.0, play: true)
    }

    @Test("单句循环关闭兜底：回句末自动停")
    func singleLineLoopOffFallsBackToAutoStop() async {
        let fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5))
        kc.toggleSingleLineLoop()
        kc.toggleSingleLineLoop() // 再关掉

        kc.handlePlaybackTick(time: 10.0, duration: 10.0)
        await drainMainActor()

        expectSingleSeek(fake, time: 5.0, play: false)
    }

    @Test("非跟唱模式：即使单句循环开启也不动作")
    func noTickWhenKaraokeOff() async {
        let fake = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setLyrics(makeLines(0, 5))
        kc.toggleSingleLineLoop() // 跟唱关时仍可开单句循环

        kc.handlePlaybackTick(time: 10.0, duration: 10.0)
        await drainMainActor()

        #expect(fake.seeks.isEmpty)
        #expect(!kc.isKaraokeOn)
    }

    // MARK: - AB 循环

    @Test("AB 等选终点：任何句末跳回 A 循环")
    func abWaitingForEnd() async {
        let fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 9))
        kc.enterABLoop(currentLine: 0)

        kc.handlePlaybackTick(time: 10.0, duration: 10.0)
        await drainMainActor()

        #expect(kc.abLoop == ABLoopState(a: 0, b: nil))
        expectSingleSeek(fake, time: 0.0, play: true)
    }

    @Test("AB 设 B：点击句设为终点，不触发跳转")
    func abSetEnd() async {
        let fake = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 9))
        kc.enterABLoop(currentLine: 0)

        kc.clickLine(index: 1)
        await drainMainActor()

        #expect(kc.abLoop == ABLoopState(a: 0, b: 1))
        #expect(fake.seeks.isEmpty)
    }

    @Test("AB B 终点：B 句播完跳回 A 重播")
    func abEndPointLoop() async {
        let fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 9))
        kc.enterABLoop(currentLine: 0)
        kc.clickLine(index: 2) // B = 2（最后一句，句末 = duration）

        kc.handlePlaybackTick(time: 10.0, duration: 10.0)
        await drainMainActor()

        #expect(kc.abLoop == ABLoopState(a: 0, b: 2))
        expectSingleSeek(fake, time: 0.0, play: true)
    }

    @Test("AB 区间中间句：句末自然推进（缓存行 +1），不干预不跳转")
    func abMiddleLineNaturalProgress() async {
        let fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 9, 12))
        kc.enterABLoop(currentLine: 0)
        kc.clickLine(index: 3) // B = 3

        kc.handlePlaybackTick(time: 6.0, duration: 15.0) // 缓存第 1 句（[5,9)）
        kc.handlePlaybackTick(time: 9.0, duration: 15.0) // 第 1 句末：推进缓存行，不跳转
        await drainMainActor()

        #expect(fake.seeks.isEmpty)
    }

    @Test("AB 区间外点击：退出 AB 并跳到该句播放")
    func abClickOutsideRange() async {
        let fake = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 9, 12, 14, 16))
        kc.enterABLoop(currentLine: 0)
        kc.clickLine(index: 2) // B = 2，区间 [0, 2]

        kc.clickLine(index: 5) // 区间外
        await drainMainActor()

        #expect(kc.abLoop == nil)
        expectSingleSeek(fake, time: 16.0, play: true)
    }

    @Test("无 AB 点击歌词：直接跳到该句播放")
    func clickLineWithoutAB() async {
        let fake = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 9))

        kc.clickLine(index: 1)
        await drainMainActor()

        #expect(kc.abLoop == nil)
        expectSingleSeek(fake, time: 5.0, play: true)
    }

    @Test("点击歌词后 seek 未生效：tick 不重定位旧行、不误触发句末（2026-08-31 竞态回归）")
    func pendingJumpSuppressesRelocation() async {
        let fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 9, 12))

        kc.handlePlaybackTick(time: 6.0, duration: 15.0) // 缓存第 1 行 [5,9)
        kc.clickLine(index: 3) // 点击第 3 行（ts=12）→ pending jump + seek(12, play)
        await drainMainActor()
        #expect(fake.seeks.count == 1)
        #expect(fake.seeks.first?.time == 12.0)
        #expect(fake.seeks.first?.play == true)
        fake.seeks = []

        // 模拟真实竞态：seek 慢（>0.3s quiet 窗口），播放位置仍停留在旧行。
        // quiet 过期后旧代码会把 karaokeLine 重定位回第 1 行，随后 9.0（第 1 行句末）
        // 误触发句末自动停（seek 5.0 play:false）；修复后 pending 期间全部跳过。
        try? await Task.sleep(nanoseconds: 320_000_000)
        kc.handlePlaybackTick(time: 6.0, duration: 15.0)
        await drainMainActor()
        kc.handlePlaybackTick(time: 9.0, duration: 15.0)
        await drainMainActor()
        #expect(fake.seeks.isEmpty)

        // seek 生效：播放时间到达目标行句首（12.0）→ pending 解除，恢复正常检测；
        // 12 < 末句句末，不触发句末。
        kc.handlePlaybackTick(time: 12.0, duration: 12.5)
        await drainMainActor()
        #expect(fake.seeks.isEmpty)

        // 解除后句末检测恢复工作：模拟真实 0.25s tick 间隔自然播放到末句句末
        // （12.5 = duration）→ 句末自动停回 12.0 暂停。不能直接 12→15 跳变：
        // 间隔 >1s 会被「前向 seek 检测」误判为用户拖进度条而跳过句末检测。
        kc.handlePlaybackTick(time: 12.25, duration: 12.5)
        await drainMainActor()
        #expect(fake.seeks.isEmpty)
        kc.handlePlaybackTick(time: 12.5, duration: 12.5)
        await drainMainActor()
        expectSingleSeek(fake, time: 12.0, play: false)
    }

    @Test("enterABLoop：A 点取不到（行无时间戳/越界）返回 false 不进入；正常行返回 true")
    func enterABLoopRejectsInvalidStart() async {
        _ = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics([
            LyricsLine(timestamp: nil, text: "前奏（无时间戳）"),
            LyricsLine(timestamp: 5, text: "第一句"),
        ])

        // 前奏行无时间戳：进入失败（带反馈），不建 AB
        #expect(kc.enterABLoop(currentLine: 0) == false)
        #expect(kc.abLoop == nil)

        // 越界行：进入失败
        #expect(kc.enterABLoop(currentLine: 5) == false)
        #expect(kc.abLoop == nil)

        // 正常行：成功进入等选终点
        #expect(kc.enterABLoop(currentLine: 1) == true)
        #expect(kc.abLoop == ABLoopState(a: 1, b: nil))
    }

    // MARK: - 倍速

    @Test("cycleSpeed 档位循环：1.0 → 0.5 → … → 1.0，每次追加 setRate")
    func cycleSpeedLevels() async {
        let fake = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        #expect(fake.rates == [1.0]) // 进入跟唱应用当前速度

        kc.cycleSpeed() // 0.5
        kc.cycleSpeed() // 0.6
        kc.cycleSpeed() // 0.7
        kc.cycleSpeed() // 0.8
        kc.cycleSpeed() // 0.9
        kc.cycleSpeed() // 1.0

        #expect(kc.speed == 1.0)
        #expect(fake.rates == [1.0, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0])
    }

    @Test("setSpeed：直接设档（点选菜单），非法档位忽略")
    func setSpeedDirect() async {
        let fake = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        fake.rates = []

        kc.setSpeed(0.7)
        kc.setSpeed(1.0)
        kc.setSpeed(1.3) // 非法档位：忽略

        #expect(kc.speed == 1.0)
        #expect(fake.rates == [0.7, 1.0])
    }

    @Test("resetSpeedForUnsupportedEngine（SFB 不支持倍速）：复位显示为 1.0，不写回引擎")
    func resetSpeedForUnsupportedEngineClearsDisplay() async {
        let fake = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setSpeed(0.7)
        fake.rates = []

        kc.resetSpeedForUnsupportedEngine()

        #expect(kc.speed == 1.0) // UI 显示复位
        #expect(fake.rates.isEmpty) // 不调用 setRate（SFB 引擎不生效；用户值保留在 PlayerEngine）

        // 已是 1.0 时调用无副作用
        kc.resetSpeedForUnsupportedEngine()
        #expect(kc.speed == 1.0)
        #expect(fake.rates.isEmpty)
    }

    @Test("上一句/下一句：跳到目标句首播放，边界不动作")
    func stepLine() async {
        let fake = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 9))
        kc.handlePlaybackTick(time: 6.0, duration: 12.0) // 缓存第 1 句（[5,9)）
        fake.seeks = []

        kc.stepLine(delta: 1, currentTime: 6.0) // 下一句 → 第 2 句首 9.0
        await drainMainActor()
        expectSingleSeek(fake, time: 9.0, play: true)

        fake.seeks = []
        kc.stepLine(delta: -1, currentTime: 9.0) // 上一句 → 第 1 句首 5.0（缓存行已更新为句 2）
        await drainMainActor()
        expectSingleSeek(fake, time: 5.0, play: true)

        fake.seeks = []
        kc.stepLine(delta: -1, currentTime: 5.0) // 再上一句 → 第 0 句首 0.0
        await drainMainActor()
        expectSingleSeek(fake, time: 0.0, play: true)

        fake.seeks = []
        kc.stepLine(delta: -1, currentTime: 0.0) // 第 0 句上越界：不动作
        await drainMainActor()
        #expect(fake.seeks.isEmpty)
    }

    // MARK: - 模式开关 / 切歌

    @Test("单句循环与 AB 互斥：开单句清 AB；进 AB 关单句")
    func singleLineLoopAndABMutuallyExclusive() async {
        _ = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 9))

        // 开 AB → 单句被关
        kc.toggleSingleLineLoop()
        kc.enterABLoop(currentLine: 0)
        #expect(kc.abLoop == ABLoopState(a: 0, b: nil))
        #expect(!kc.isSingleLineLoop)

        // 开单句 → AB 被清
        kc.toggleSingleLineLoop()
        #expect(kc.isSingleLineLoop)
        #expect(kc.abLoop == nil)
    }

    @Test("退出跟唱：清 AB/单句循环，速度恢复 1.0 并应用到引擎")
    func exitKaraokeCleansUp() async {
        let fake = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 9))
        kc.toggleSingleLineLoop()
        kc.enterABLoop(currentLine: 0)
        kc.clickLine(index: 1) // AB {0, 1}
        kc.cycleSpeed() // 0.5
        kc.cycleSpeed() // 0.6
        kc.cycleSpeed() // 0.7

        kc.toggleKaraokeMode()
        await drainMainActor()

        #expect(!kc.isKaraokeOn)
        #expect(kc.abLoop == nil)
        #expect(!kc.isSingleLineLoop)
        #expect(kc.speed == 1.0)
        #expect(fake.rates == [1.0, 0.5, 0.6, 0.7, 1.0])
    }

    @Test("resetForNewTrack：保留跟唱/速度/单句循环，仅清 AB")
    func resetForNewTrackKeepsState() async {
        _ = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 9))
        kc.toggleSingleLineLoop()
        kc.cycleSpeed() // 0.5

        kc.resetForNewTrack()

        #expect(kc.isKaraokeOn)
        #expect(kc.isSingleLineLoop)
        #expect(kc.speed == 0.5)
        #expect(kc.abLoop == nil)

        // AB 场景：进 AB 后 reset → AB 清、单句仍关（互斥）
        kc.enterABLoop(currentLine: 0)
        kc.clickLine(index: 1) // AB {0, 1}
        kc.resetForNewTrack()
        #expect(kc.abLoop == nil)
        #expect(!kc.isSingleLineLoop)
    }

    // MARK: - 静默窗口 / 边界

    @Test("跳转静默窗口：jump 后 0.3s 内再 tick 同时间不重复 seek")
    func jumpQuietWindowSuppressesDuplicate() async {
        let fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5))

        kc.handlePlaybackTick(time: 10.0, duration: 10.0) // 触发 jump（设静默窗口）
        kc.handlePlaybackTick(time: 10.0, duration: 10.0) // 静默窗口内：忽略
        await drainMainActor()

        expectSingleSeek(fake, time: 5.0, play: false)
    }

    @Test("最后一句句末 = duration：按单句/自动停规则处理")
    func lastLineEndAtDuration() async {
        var fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared

        // 单句循环开：重播本句
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5))
        kc.toggleSingleLineLoop()
        kc.handlePlaybackTick(time: 10.0, duration: 10.0)
        await drainMainActor()
        expectSingleSeek(fake, time: 5.0, play: true)

        // 单句循环关：回句首暂停
        fake = await makeFake(expireJumpQuiet: true)
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5))
        kc.handlePlaybackTick(time: 10.0, duration: 10.0)
        await drainMainActor()
        expectSingleSeek(fake, time: 5.0, play: false)
    }

    // MARK: - 前向 seek / duration 未知（2026-08-29 回归）

    @Test("前向拖进度条：不触发句末自动停，重定位到实际行；后续自然句末仍生效")
    func forwardSeekDoesNotTriggerLineEnd() async {
        let fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 10, 20))

        kc.handlePlaybackTick(time: 6.0, duration: 30.0) // 缓存第 1 句（[5,10)）
        kc.handlePlaybackTick(time: 19.0, duration: 30.0) // 前跳 13s（>1s = 用户 seek）→ 重定位第 2 句，不弹回
        await drainMainActor()
        #expect(fake.seeks.isEmpty)

        kc.handlePlaybackTick(time: 19.25, duration: 30.0) // 自然播放：句中，不触发
        await drainMainActor()
        #expect(fake.seeks.isEmpty)

        kc.handlePlaybackTick(time: 20.0, duration: 30.0) // 第 2 句播完 → 句末自动停仍生效
        await drainMainActor()
        expectSingleSeek(fake, time: 10.0, play: false)
    }

    @Test("duration 未知（0）：末句不触发无限句末自动停")
    func unknownDurationNoLastLineEndLoop() async {
        let fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5))

        kc.handlePlaybackTick(time: 10.0, duration: 0)
        kc.handlePlaybackTick(time: 10.25, duration: 0)
        kc.handlePlaybackTick(time: 10.5, duration: 0)
        await drainMainActor()

        #expect(fake.seeks.isEmpty)
    }

    @Test("duration 未知（0）：非末句句末检测仍生效（用下一句时间戳）")
    func unknownDurationMidLineEndStillWorks() async {
        let fake = await makeFake(expireJumpQuiet: true)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 9))

        kc.handlePlaybackTick(time: 8.75, duration: 0) // 缓存第 1 句（[5,9)）
        kc.handlePlaybackTick(time: 9.0, duration: 0) // 第 1 句播完 → 句末自动停（下一句时间戳 9）
        await drainMainActor()

        expectSingleSeek(fake, time: 5.0, play: false)
    }

    // MARK: - 普通模式点行：seekToLyricLine（2026-10-12 手动滚动/点行跳转）

    @Test("普通模式点行：跳到该行句首并播放（不要求跟唱模式）")
    func seekToLyricLinePlaysWithoutKaraoke() async {
        let fake = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        #expect(!kc.isKaraokeOn) // 普通模式
        kc.setLyrics(makeLines(0, 5, 9))

        kc.seekToLyricLine(2)
        await drainMainActor()

        // 目标时间 = 第 2 行时间戳 9.0；play = true（暂停态也开播）
        expectSingleSeek(fake, time: 9.0, play: true)
    }

    @Test("普通模式点行：seek 目标沿用同一 lyricOffset 语义（歌词时间 + offset）")
    func seekToLyricLineRespectsLyricOffset() async {
        let fake = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setLyrics(makeLines(0, 5, 9))
        kc.lyricOffset = 0.5 // 音频轴 = 歌词时间 + offset

        kc.seekToLyricLine(1) // 第 1 行时间戳 5.0 → 目标 5.5
        await drainMainActor()

        expectSingleSeek(fake, time: 5.5, play: true)
        kc.lyricOffset = 0 // 还原，避免串扰（套件串行、共享单例）
    }

    @Test("普通模式点行：索引越界 / 行无时间戳 → 不动作")
    func seekToLyricLineInvalidIndexNoop() async {
        let fake = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setLyrics([LyricsLine(timestamp: 0, text: "行0"), LyricsLine(timestamp: nil, text: "无时间戳")])

        kc.seekToLyricLine(9) // 越界
        kc.seekToLyricLine(1) // 行无时间戳
        await drainMainActor()

        #expect(fake.seeks.isEmpty)
    }

    @Test("普通模式点行：不改动 AB / 单句循环 / 倍速等跟唱状态")
    func seekToLyricLineDoesNotTouchKaraokeState() async {
        let fake = await makeFake(expireJumpQuiet: false)
        let kc = KaraokeController.shared
        kc.setKaraokeOn(true)
        kc.setLyrics(makeLines(0, 5, 9))
        kc.enterABLoop(currentLine: 0)
        kc.clickLine(index: 1) // 等选终点 → 设 B：AB {0, 1}（不跳句）
        kc.setSpeed(0.7)
        fake.seeks = []

        kc.seekToLyricLine(2) // 该入口只 seek，不碰状态
        await drainMainActor()

        expectSingleSeek(fake, time: 9.0, play: true)
        #expect(kc.abLoop == ABLoopState(a: 0, b: 1))
        #expect(kc.speed == 0.7)
        #expect(!kc.isSingleLineLoop)
        #expect(kc.isKaraokeOn) // 也不改模式开关
    }
}
