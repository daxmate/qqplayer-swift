//
//  CarPlayPlayerPageTests.swift
//  QQPlayerTests
//
//  CarPlay 播放页内容构建契约（纯逻辑，不碰 CarPlay / 播放器）：
//  - 歌词行数 = 3（当前句 + 后续 2 句），窗口在末尾收敛
//  - 页头 = 歌名 / 歌手 / 播放态 / 播放顺序 / 封面归属（封面异步，只记 key）
//  - 占位四态（未在播放 / 加载中 / 无歌词 / 纯音乐）
//  - 同一状态下内容不变（否则页头与列表会按 0.5s tick 重建）
//  - 行窗口与占位判定都走 CarPlayLyricsBuilder（本层不复制一份）
//

import Foundation
import Testing

@testable import QQPlayer

struct CarPlayPlayerPageBuilderTests {
    // MARK: - 夹具

    /// 造同步歌词：默认 1s 起、每句 5s（第 0/1/2 句 = 1s/6s/11s）
    private func makeLines(
        _ texts: [String],
        start: TimeInterval = 1,
        step: TimeInterval = 5
    ) -> [LyricsLine] {
        texts.enumerated().map { index, text in
            LyricsLine(timestamp: start + Double(index) * step, text: text)
        }
    }

    private func makeLyrics(
        _ lines: [LyricsLine],
        plain: String = "",
        instrumental: Bool = false
    ) -> Lyrics {
        Lyrics(plainLyrics: plain, syncedLyrics: lines, isInstrumental: instrumental, source: .lrclib)
    }

    private func content(
        trackKey: String? = "track-a",
        title: String? = "歌名",
        artist: String? = "歌手",
        isPlaying: Bool = true,
        playOrderMode: PlaybackOrderMode = .sequential,
        elapsed: TimeInterval = 0,
        duration: TimeInterval = 0,
        lyrics: Lyrics?,
        isLoading: Bool = false,
        activeLineIndex: Int? = 0
    ) -> CarPlayPlayerPageContent {
        let track = trackKey.flatMap { key in
            title.map { CarPlayPlayerPageTrackInfo(key: key, title: $0, artist: artist) }
        }
        return CarPlayPlayerPageBuilder.content(
            track: track,
            playback: CarPlayPlayerPagePlaybackState(
                isPlaying: isPlaying,
                playOrderMode: playOrderMode,
                elapsed: elapsed,
                duration: duration
            ),
            lyrics: lyrics,
            isLoading: isLoading,
            activeLineIndex: activeLineIndex
        )
    }

    // MARK: - 三行歌词

    @Test("播放页显示三行：当前句 + 后续 2 句，当前句高亮")
    func showsThreeLinesFromActiveLine() {
        let page = content(
            lyrics: makeLyrics(makeLines(["一", "二", "三", "四", "五", "六"])),
            activeLineIndex: 1
        )
        #expect(page.rows.count == CarPlayPlayerPageBuilder.lyricLineCount)
        #expect(page.rows.map(\.lineIndex) == [1, 2, 3])
        #expect(page.rows.map(\.text) == ["二", "三", "四"])
        #expect(page.rows.map(\.isPlaying) == [true, false, false])
        #expect(page.placeholder == nil)
    }

    @Test("末尾收敛：不足三行就有几行给几行")
    func clampsAtLastLine() {
        let page = content(
            lyrics: makeLyrics(makeLines(["一", "二", "三"])),
            activeLineIndex: 2
        )
        #expect(page.rows.map(\.lineIndex) == [2])
        #expect(page.rows.first?.isPlaying == true)
    }

    @Test("无时间轴歌词兜底也是三行，且不高亮")
    func plainLyricsFallBackToThreeLines() {
        let page = content(
            lyrics: makeLyrics([], plain: "一\n二\n三\n四\n五"),
            activeLineIndex: nil
        )
        #expect(page.rows.map(\.text) == ["一", "二", "三"])
        #expect(page.rows.allSatisfy { $0.lineIndex == nil && !$0.isPlaying })
    }

    // MARK: - 页头

    @Test("页头带歌名 / 歌手 / 播放态 / 播放顺序 / 封面归属")
    func headerCarriesPlaybackState() {
        let page = content(
            isPlaying: false,
            playOrderMode: .repeatOne,
            lyrics: makeLyrics(makeLines(["一", "二"]))
        )
        let header = page.header
        #expect(header?.title == "歌名")
        #expect(header?.subtitle == "歌手")
        #expect(header?.isPlaying == false)
        #expect(header?.playOrderMode == .repeatOne)
        #expect(header?.artworkKey == "track-a")
    }

    @Test("歌手为空串等同没有歌手（与副行取舍同口径）")
    func emptyArtistBecomesNilSubtitle() {
        #expect(content(artist: "", lyrics: makeLyrics(makeLines(["一"]))).header?.subtitle == nil)
        #expect(content(artist: nil, lyrics: makeLyrics(makeLines(["一"]))).header?.subtitle == nil)
    }

    @Test("播放顺序四态各自有图标（页头按钮图标唯一入口）")
    func playOrderIconsAreDistinct() {
        let icons = PlaybackOrderMode.allCases.map(\.systemImageName)
        #expect(Set(icons).count == PlaybackOrderMode.allCases.count)
    }

    // MARK: - 占位四态

    @Test("占位四态")
    func placeholders() {
        // 没有在播曲目：页头也不该有
        let noTrack = content(trackKey: nil, title: nil, lyrics: nil)
        #expect(noTrack.placeholder == .noTrack)
        #expect(noTrack.header == nil)
        #expect(noTrack.rows.isEmpty)

        // 加载中：页头在（歌名/控制键能用），歌词位空
        let loading = content(lyrics: nil, isLoading: true)
        #expect(loading.placeholder == .loading)
        #expect(loading.header?.title == "歌名")
        #expect(loading.rows.isEmpty)

        // 无歌词
        let noLyrics = content(lyrics: makeLyrics([]))
        #expect(noLyrics.placeholder == .noLyrics)
        #expect(noLyrics.header != nil)

        // 纯音乐
        let instrumental = content(lyrics: makeLyrics([], instrumental: true))
        #expect(instrumental.placeholder == .instrumental)
    }

    @Test("有内容时占位为空")
    func placeholderClearsWithContent() {
        let page = content(lyrics: makeLyrics(makeLines(["一", "二", "三"])))
        #expect(page.placeholder == nil)
        #expect(page.rows.count == 3)
    }

    // MARK: - 稳定性（防按 tick 重建）

    @Test("同一状态下内容不变（否则页头/列表会按 0.5s tick 重建）")
    func contentIsStableWithinSameState() {
        let lyrics = makeLyrics(makeLines(["一", "二", "三", "四"]))
        let first = content(lyrics: lyrics, activeLineIndex: 1)
        let second = content(lyrics: lyrics, activeLineIndex: 1)
        #expect(first == second)
    }

    @Test("换句产生新内容；换播放态也要产生新内容（页头按钮图标要跟着变）")
    func contentChangesWhenLineOrPlaybackStateChanges() {
        let lyrics = makeLyrics(makeLines(["一", "二", "三", "四"]))
        let line0 = content(lyrics: lyrics, activeLineIndex: 0)
        let line1 = content(lyrics: lyrics, activeLineIndex: 1)
        #expect(line0 != line1)

        let playing = content(isPlaying: true, lyrics: lyrics, activeLineIndex: 0)
        let paused = content(isPlaying: false, lyrics: lyrics, activeLineIndex: 0)
        #expect(playing != paused)

        let sequential = content(playOrderMode: .sequential, lyrics: lyrics, activeLineIndex: 0)
        let shuffled = content(playOrderMode: .shuffle, lyrics: lyrics, activeLineIndex: 0)
        #expect(sequential != shuffled)
    }

    // MARK: - 进度

    @Test("进度按 2s 量化：同一段内内容不变（否则页头会按 tick 重建）")
    func progressIsQuantized() {
        let lyrics = makeLyrics(makeLines(["一", "二", "三", "四"]))
        let at0 = content(elapsed: 0, duration: 200, lyrics: lyrics)
        let at19 = content(elapsed: 1.9, duration: 200, lyrics: lyrics)
        let at2 = content(elapsed: 2, duration: 200, lyrics: lyrics)

        #expect(at0 == at19)
        #expect(at0 != at2)
    }

    @Test("进度：总时长未知不画进度条")
    func progressHiddenWithoutDuration() {
        #expect(content(elapsed: 30, duration: 0, lyrics: makeLyrics(makeLines(["一"]))).header?.progress == nil)
    }

    @Test("进度：越界与负值收敛到 0…1，文案带已播 / 总长")
    func progressClampsOutOfRange() {
        let overrun = content(elapsed: 999, duration: 100, lyrics: makeLyrics(makeLines(["一"]))).header?.progress
        #expect(overrun?.fraction == 1)
        #expect(overrun?.elapsedText == "1:40")
        #expect(overrun?.totalText == "1:40")

        let negative = content(elapsed: -5, duration: 100, lyrics: makeLyrics(makeLines(["一"]))).header?.progress
        #expect(negative?.fraction == 0)
        #expect(negative?.elapsedText == "0:00")
    }

    @Test("播放时间文案走唯一入口：mm:ss，超一小时带小时位，负值归零")
    func timeFormatting() {
        #expect(PlaybackTimeFormat.mmss(0) == "0:00")
        #expect(PlaybackTimeFormat.mmss(59.9) == "0:59")
        #expect(PlaybackTimeFormat.mmss(60) == "1:00")
        #expect(PlaybackTimeFormat.mmss(3661) == "1:01:01")
        #expect(PlaybackTimeFormat.mmss(-3) == "0:00")
    }
}
