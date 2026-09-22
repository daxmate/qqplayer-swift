//
//  PlayerGestureLogicTests.swift
//  QQPlayerTests
//
//  播放页/歌词页手势判定与歌词时间轴纯逻辑测试：
//  - LyricTiming.activeLineIndex：当前播放时间 → 当前歌词行
//  - PlayerDismissGesture：歌词页右滑关闭 / 歌词搜索页左滑关闭 / 播放页下拉关闭阈值
//  - PlayerPageGesture：播放页整页手势（方向锁定、左右滑开歌词/搜索、上下滑展开/收起）
//

import Foundation
import Testing

@testable import QQPlayer

struct LyricTimingTests {
    private func lines(_ texts: [(TimeInterval?, String)]) -> [LyricsLine] {
        texts.map { LyricsLine(timestamp: $0.0, text: $0.1) }
    }

    @Test("时间在句间：返回最后一句已到时间戳的行")
    func activeLineBetweenLines() {
        let l = lines([(0, "A"), (5, "B"), (10, "C")])
        #expect(LyricTiming.activeLineIndex(time: 0, in: l) == 0)
        #expect(LyricTiming.activeLineIndex(time: 4.9, in: l) == 0)
        #expect(LyricTiming.activeLineIndex(time: 5, in: l) == 1)
        #expect(LyricTiming.activeLineIndex(time: 9.9, in: l) == 1)
        #expect(LyricTiming.activeLineIndex(time: 10, in: l) == 2)
    }

    @Test("时间超过最后一句：返回最后一句")
    func activeLinePastEnd() {
        let l = lines([(0, "A"), (5, "B")])
        #expect(LyricTiming.activeLineIndex(time: 100, in: l) == 1)
        #expect(LyricTiming.activeLineIndex(time: 5, in: l) == 1)
    }

    @Test("时间早于第一句：返回 nil")
    func activeLineBeforeFirst() {
        let l = lines([(5, "A"), (10, "B")])
        #expect(LyricTiming.activeLineIndex(time: 0, in: l) == nil)
        #expect(LyricTiming.activeLineIndex(time: 4.9, in: l) == nil)
    }

    @Test("空歌词：返回 nil")
    func activeLineEmpty() {
        #expect(LyricTiming.activeLineIndex(time: 0, in: []) == nil)
    }

    @Test("无时间戳的行被跳过，不影响 index")
    func activeLineSkipsUntimed() {
        let l = lines([(0, "A"), (nil, "旁白"), (5, "B")])
        #expect(LyricTiming.activeLineIndex(time: 2, in: l) == 0)
        #expect(LyricTiming.activeLineIndex(time: 5, in: l) == 2)
        #expect(LyricTiming.activeLineIndex(time: 6, in: l) == 2)
    }

    @Test("全部无时间戳：返回 nil")
    func activeLineAllUntimed() {
        let l = lines([(nil, "A"), (nil, "B")])
        #expect(LyricTiming.activeLineIndex(time: 0, in: l) == nil)
    }
}

struct PlayerDismissGestureTests {
    // ---- 歌词页右滑关闭 ----

    @Test("位移超 120pt：关闭")
    func dismissLyricsLargeTranslation() {
        #expect(PlayerDismissGesture.shouldDismissLyrics(translation: 121, predictedTranslation: 0) == true)
        #expect(PlayerDismissGesture.shouldDismissLyrics(translation: 300, predictedTranslation: 50) == true)
    }

    @Test("位移未达 120pt 且非快速回甩：不关闭")
    func dismissLyricsSmallTranslation() {
        #expect(PlayerDismissGesture.shouldDismissLyrics(translation: 119, predictedTranslation: 0) == false)
        #expect(PlayerDismissGesture.shouldDismissLyrics(translation: 30, predictedTranslation: 250) == false)
    }

    @Test("位移过半（>40pt）且快速回甩（预测 >260pt）：关闭")
    func dismissLyricsFlick() {
        #expect(PlayerDismissGesture.shouldDismissLyrics(translation: 41, predictedTranslation: 261) == true)
        #expect(PlayerDismissGesture.shouldDismissLyrics(translation: 80, predictedTranslation: 265) == true)
        // 边界：刚好 40/260 不关闭
        #expect(PlayerDismissGesture.shouldDismissLyrics(translation: 40, predictedTranslation: 260) == false)
        #expect(PlayerDismissGesture.shouldDismissLyrics(translation: 40, predictedTranslation: 300) == false)
    }

    // ---- 播放页封面下拉关闭 ----

    @Test("下拉位移达 100pt：关闭")
    func dismissPlayerLargePull() {
        #expect(PlayerDismissGesture.shouldDismissPlayer(pullOffset: 100, predictedHeight: 0) == true)
        #expect(PlayerDismissGesture.shouldDismissPlayer(pullOffset: 160, predictedHeight: 10) == true)
    }

    @Test("下拉未达阈值且非快速：不关闭（回弹）")
    func dismissPlayerSmallPull() {
        #expect(PlayerDismissGesture.shouldDismissPlayer(pullOffset: 99, predictedHeight: 0) == false)
        #expect(PlayerDismissGesture.shouldDismissPlayer(pullOffset: 50, predictedHeight: 200) == false)
    }

    @Test("下拉过半（≥40pt）且快速下拉（预测 >300pt）：关闭")
    func dismissPlayerFlick() {
        #expect(PlayerDismissGesture.shouldDismissPlayer(pullOffset: 40, predictedHeight: 301) == true)
        #expect(PlayerDismissGesture.shouldDismissPlayer(pullOffset: 60, predictedHeight: 350) == true)
        // 边界：预测 300 不关闭
        #expect(PlayerDismissGesture.shouldDismissPlayer(pullOffset: 40, predictedHeight: 300) == false)
        #expect(PlayerDismissGesture.shouldDismissPlayer(pullOffset: 39, predictedHeight: 500) == false)
    }

    @Test("上滑（位移为负）不参与关闭判定")
    func dismissPlayerIgnoresUpward() {
        // 上滑时 predictedHeight 为负/小，不应触发
        #expect(PlayerDismissGesture.shouldDismissPlayer(pullOffset: 0, predictedHeight: -100) == false)
    }

    // ---- 歌词搜索页左滑关闭（与右滑关闭镜像） ----

    @Test("左滑位移超 120pt：关闭搜索页")
    func dismissLyricsSearchLargeTranslation() {
        #expect(PlayerDismissGesture.shouldDismissLyricsSearch(translation: -121, predictedTranslation: 0) == true)
        #expect(PlayerDismissGesture.shouldDismissLyricsSearch(translation: -300, predictedTranslation: -50) == true)
    }

    @Test("左滑未达 120pt 且非快速回甩：不关闭搜索页")
    func dismissLyricsSearchSmallTranslation() {
        #expect(PlayerDismissGesture.shouldDismissLyricsSearch(translation: -119, predictedTranslation: 0) == false)
        #expect(PlayerDismissGesture.shouldDismissLyricsSearch(translation: -30, predictedTranslation: -250) == false)
    }

    @Test("左滑过半（<-40pt）且快速回甩（预测 <-260pt）：关闭搜索页")
    func dismissLyricsSearchFlick() {
        #expect(PlayerDismissGesture.shouldDismissLyricsSearch(translation: -41, predictedTranslation: -261) == true)
        #expect(PlayerDismissGesture.shouldDismissLyricsSearch(translation: -80, predictedTranslation: -300) == true)
        // 边界：刚好 -40/-260 不关闭
        #expect(PlayerDismissGesture.shouldDismissLyricsSearch(translation: -40, predictedTranslation: -260) == false)
        #expect(PlayerDismissGesture.shouldDismissLyricsSearch(translation: -40, predictedTranslation: -300) == false)
    }

    @Test("右滑（位移为正）不参与搜索页关闭判定")
    func dismissLyricsSearchIgnoresRight() {
        #expect(PlayerDismissGesture.shouldDismissLyricsSearch(translation: 100, predictedTranslation: 200) == false)
        #expect(PlayerDismissGesture.shouldDismissLyricsSearch(translation: 121, predictedTranslation: 300) == false)
    }
}

struct PlayerPageGestureTests {
    // ---- 起手区域分流（2026-09-22 复核 ① / ②） ----

    /// 封面区 frame（整页坐标系示例）
    private let artworkFrame = CGRect(x: 20, y: 100, width: 360, height: 360)
    /// 进度条实测 frame（布局高 1pt）
    private let progressBarFrame = CGRect(x: 24, y: 600, width: 345, height: 1)
    private var progressFrame: CGRect {
        PlayerPageGesture.progressTouchRegion(barFrame: progressBarFrame)
    }

    @Test("封面区 + 无可切换相邻曲目（队列 ≤1）：判定为 .page（左右滑仍开歌词 / 搜索）")
    func regionArtworkWithoutAdjacentTrackFallsBackToPage() {
        let inside = CGPoint(x: artworkFrame.midX, y: artworkFrame.midY)
        #expect(PlayerPageGesture.region(
            startLocation: inside,
            artworkFrame: artworkFrame,
            progressFrame: progressFrame,
            canSwitchTrack: false
        ) == .page)
    }

    @Test("封面区 + 有相邻曲目（队列 >1）：仍为 .artwork（横滑切歌不受影响）")
    func regionArtworkWithAdjacentTrackKeepsArtwork() {
        let inside = CGPoint(x: artworkFrame.midX, y: artworkFrame.midY)
        #expect(PlayerPageGesture.region(
            startLocation: inside,
            artworkFrame: artworkFrame,
            progressFrame: progressFrame,
            canSwitchTrack: true
        ) == .artwork)
        // 队列 >1 与 ≤1 只差这一个事实，其余区域判定不变
        #expect(PlayerPageGesture.region(
            startLocation: inside,
            artworkFrame: artworkFrame,
            progressFrame: progressFrame,
            canSwitchTrack: false
        ) == .page)
    }

    @Test("进度条区起手：横向归 .progress；纵向不入整页手势")
    func regionProgressOwnsHorizontalAndVertical() {
        let onBar = CGPoint(x: progressBarFrame.midX, y: progressBarFrame.midY)
        #expect(PlayerPageGesture.region(
            startLocation: onBar,
            artworkFrame: artworkFrame,
            progressFrame: progressFrame,
            canSwitchTrack: false
        ) == .progress)
        #expect(PlayerPageGesture.ownsVerticalPull(
            startLocation: onBar,
            artworkFrame: artworkFrame,
            progressFrame: progressFrame
        ) == false)
    }

    @Test("封面区起手纵向：仍归封面手势（整页不下拉）")
    func verticalPullExcludesArtwork() {
        let inside = CGPoint(x: artworkFrame.midX, y: artworkFrame.midY)
        #expect(PlayerPageGesture.ownsVerticalPull(
            startLocation: inside,
            artworkFrame: artworkFrame,
            progressFrame: progressFrame
        ) == false)
    }

    @Test("其余整页区起手纵向：归整页手势（下拉缩回主页）")
    func verticalPullOutsideExceptions() {
        let middle = CGPoint(x: 200, y: 520)
        #expect(PlayerPageGesture.ownsVerticalPull(
            startLocation: middle,
            artworkFrame: artworkFrame,
            progressFrame: progressFrame
        ) == true)
        #expect(PlayerPageGesture.region(
            startLocation: middle,
            artworkFrame: artworkFrame,
            progressFrame: progressFrame,
            canSwitchTrack: true
        ) == .page)
    }

    @Test("进度条触摸区：实测 frame 上下各外扩 progressTouchSlop；未测量到 fram 时不排除任何点")
    func progressTouchRegionShape() {
        let slop = PlayerPageGesture.progressTouchSlop
        let region = PlayerPageGesture.progressTouchRegion(barFrame: progressBarFrame)
        #expect(region.height == progressBarFrame.height + 2 * slop)
        #expect(region.width == progressBarFrame.width)
        #expect(region.minX == progressBarFrame.minX)
        #expect(region.contains(CGPoint(x: progressBarFrame.midX, y: progressBarFrame.minY - slop)))
        #expect(region.contains(CGPoint(x: progressBarFrame.midX, y: progressBarFrame.maxY + slop - 0.5)))
        // 超出外扩量即不再算进度条区（旧实现写死 60pt，会把时间标签行一并吃掉）
        #expect(region.contains(CGPoint(x: progressBarFrame.midX, y: progressBarFrame.maxY + slop + 1)) == false)
        // 外扩量远小于与时间标签行的间距（12/16pt），不抢标签行的横向手势
        #expect(slop < 12)
        // frame 未测量到（.zero）：不排除任何点
        #expect(PlayerPageGesture.progressTouchRegion(barFrame: .zero) == .null)
    }

    // ---- 方向锁定 ----

    @Test("方向锁定：|横向| > |纵向| 即横向")
    func axisLock() {
        #expect(PlayerPageGesture.axis(translation: CGSize(width: 80, height: 10)) == .horizontal)
        #expect(PlayerPageGesture.axis(translation: CGSize(width: -80, height: 10)) == .horizontal)
        #expect(PlayerPageGesture.axis(translation: CGSize(width: 10, height: 80)) == .vertical)
        #expect(PlayerPageGesture.axis(translation: CGSize(width: 10, height: -80)) == .vertical)
        // 相等时算纵向（与封面手势同口径：宁可不开歌词也不要误当成横滑）
        #expect(PlayerPageGesture.axis(translation: CGSize(width: 50, height: 50)) == .vertical)
    }

    // ---- 上滑展开 / 下滑收起更多控制 ----

    @Test("上滑 ≥30pt：展开更多控制")
    func expandMoreControls() {
        #expect(PlayerPageGesture.shouldExpandMoreControls(translationHeight: -31) == true)
        #expect(PlayerPageGesture.shouldExpandMoreControls(translationHeight: -200) == true)
    }

    @Test("上滑未达 30pt：不展开")
    func expandMoreControlsBelowThreshold() {
        #expect(PlayerPageGesture.shouldExpandMoreControls(translationHeight: -30) == false)
        #expect(PlayerPageGesture.shouldExpandMoreControls(translationHeight: 0) == false)
        // 下滑不触发展开
        #expect(PlayerPageGesture.shouldExpandMoreControls(translationHeight: 50) == false)
    }

    @Test("下滑 ≥30pt：收起更多控制")
    func collapseMoreControls() {
        #expect(PlayerPageGesture.shouldCollapseMoreControls(translationHeight: 31) == true)
        #expect(PlayerPageGesture.shouldCollapseMoreControls(translationHeight: 200) == true)
    }

    @Test("下滑未达 30pt：不收面板")
    func collapseMoreControlsBelowThreshold() {
        #expect(PlayerPageGesture.shouldCollapseMoreControls(translationHeight: 30) == false)
        #expect(PlayerPageGesture.shouldCollapseMoreControls(translationHeight: 0) == false)
        // 上滑不触发收起
        #expect(PlayerPageGesture.shouldCollapseMoreControls(translationHeight: -50) == false)
    }

    // ---- 左滑打开全屏歌词页（阈值与历史小歌词窗手势 -60/-120 一致） ----

    @Test("左滑位移超 60pt：打开歌词页")
    func openLyricsSheetLargeSwipe() {
        #expect(PlayerPageGesture.shouldOpenLyricsSheet(translation: -61, predictedTranslation: 0) == true)
        #expect(PlayerPageGesture.shouldOpenLyricsSheet(translation: -300, predictedTranslation: -50) == true)
    }

    @Test("左滑快速回甩（预测 < -120pt）：打开歌词页")
    func openLyricsSheetFlick() {
        #expect(PlayerPageGesture.shouldOpenLyricsSheet(translation: -20, predictedTranslation: -121) == true)
        #expect(PlayerPageGesture.shouldOpenLyricsSheet(translation: -59, predictedTranslation: -200) == true)
    }

    @Test("左滑未达阈值且非快速回甩：不打开")
    func openLyricsSheetSmallSwipe() {
        #expect(PlayerPageGesture.shouldOpenLyricsSheet(translation: -59, predictedTranslation: -100) == false)
        #expect(PlayerPageGesture.shouldOpenLyricsSheet(translation: -30, predictedTranslation: -119) == false)
        // 右滑（正位移）不触发
        #expect(PlayerPageGesture.shouldOpenLyricsSheet(translation: 100, predictedTranslation: 200) == false)
    }

    // ---- 右滑打开歌词搜索页（与左滑阈值对称） ----

    @Test("右滑位移超 60pt：打开搜索页")
    func openLyricsSearchLargeSwipe() {
        #expect(PlayerPageGesture.shouldOpenLyricsSearch(translation: 61, predictedTranslation: 0) == true)
        #expect(PlayerPageGesture.shouldOpenLyricsSearch(translation: 300, predictedTranslation: 50) == true)
    }

    @Test("右滑快速回甩（预测 > 120pt）：打开搜索页")
    func openLyricsSearchFlick() {
        #expect(PlayerPageGesture.shouldOpenLyricsSearch(translation: 20, predictedTranslation: 121) == true)
        #expect(PlayerPageGesture.shouldOpenLyricsSearch(translation: 59, predictedTranslation: 200) == true)
    }

    @Test("右滑未达阈值且非快速回甩：不打开")
    func openLyricsSearchSmallSwipe() {
        #expect(PlayerPageGesture.shouldOpenLyricsSearch(translation: 59, predictedTranslation: 100) == false)
        #expect(PlayerPageGesture.shouldOpenLyricsSearch(translation: 30, predictedTranslation: 119) == false)
        // 左滑（负位移）不触发
        #expect(PlayerPageGesture.shouldOpenLyricsSearch(translation: -100, predictedTranslation: -200) == false)
    }
}
