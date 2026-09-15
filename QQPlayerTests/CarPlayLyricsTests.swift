//
//  CarPlayLyricsTests.swift
//  QQPlayerTests
//
//  CarPlay 歌词页内容构建契约（纯逻辑，不碰 CarPlay / 播放器）：
//  - 窗口 = 当前句 + 后续 N 句（当前句永远在首行 = 「不用滚动的自动滚屏」）
//  - 同一句内播放进度推进不产生新内容（否则列表会按 0.25s tick 重建）
//  - 占位状态四态（未在播放 / 加载中 / 无歌词 / 纯音乐）
//  - 歌词文本与行号判定都走既有唯一入口（LyricsLine.displayText / LyricTiming）
//

import Foundation
import Testing

@testable import QQPlayer

struct CarPlayLyricsBuilderTests {
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

    // MARK: - 窗口

    @Test("窗口以当前句为首行，含后续 N 句")
    func windowStartsAtActiveLine() {
        let rows = CarPlayLyricsBuilder.window(
            makeLines(["一", "二", "三", "四", "五", "六", "七", "八"]),
            activeLineIndex: 2,
            upcoming: 3
        )
        #expect(rows.map(\.lineIndex) == [2, 3, 4, 5])
        #expect(rows.first?.text == "三")
        #expect(rows.map(\.isPlaying) == [true, false, false, false])
    }

    @Test("窗口在末尾收敛，不越界")
    func windowClampsAtLastLine() {
        let rows = CarPlayLyricsBuilder.window(makeLines(["一", "二", "三"]), activeLineIndex: 2, upcoming: 5)
        #expect(rows.map(\.lineIndex) == [2])
        #expect(rows.first?.isPlaying == true)
    }

    @Test("还没到第一句（activeLineIndex = nil）从首行开始且不高亮")
    func windowWithoutActiveLine() {
        let rows = CarPlayLyricsBuilder.window(makeLines(["一", "二", "三"]), activeLineIndex: nil, upcoming: 2)
        #expect(rows.map(\.lineIndex) == [0, 1, 2])
        #expect(rows.allSatisfy { !$0.isPlaying })
    }

    @Test("窗口起点越界/空列表收敛到合法范围")
    func windowStartClamps() {
        #expect(CarPlayLyricsBuilder.windowStart(activeLineIndex: nil, lineCount: 4) == 0)
        #expect(CarPlayLyricsBuilder.windowStart(activeLineIndex: -3, lineCount: 4) == 0)
        #expect(CarPlayLyricsBuilder.windowStart(activeLineIndex: 99, lineCount: 4) == 3)
        #expect(CarPlayLyricsBuilder.windowStart(activeLineIndex: 1, lineCount: 0) == 0)
        #expect(CarPlayLyricsBuilder.window([], activeLineIndex: 0, upcoming: 3).isEmpty)
    }

    // MARK: - 行内容

    @Test("翻译有才带上（空串等同没有）")
    func translationOnlyWhenPresent() {
        let lines = [
            LyricsLine(timestamp: 1, text: "一", translation: "one"),
            LyricsLine(timestamp: 2, text: "二", translation: ""),
            LyricsLine(timestamp: 3, text: "三"),
        ]
        let rows = CarPlayLyricsBuilder.window(lines, activeLineIndex: 0, upcoming: 5)
        #expect(rows[0].translation == "one")
        #expect(rows[1].translation == nil)
        #expect(rows[2].translation == nil)
    }

    @Test("歌词文本走显示层唯一入口（本层不自造简繁规则）")
    func textGoesThroughDisplayNormalizer() {
        let raw = "繁體字與简体字"
        let rows = CarPlayLyricsBuilder.window([LyricsLine(timestamp: 1, text: raw)], activeLineIndex: 0, upcoming: 0)
        #expect(rows.first?.text == DisplayScriptNormalizer.display(raw))
    }

    @Test("无时间轴歌词：静态几行、不高亮、行号为 nil")
    func plainLyricsFallback() {
        let plain = "\n第一行\n\n  第二行  \n第三行\n第四行\n第五行\n第六行\n第七行\n"
        let rows = CarPlayLyricsBuilder.plainRows(plain, limit: 3)
        #expect(rows.map(\.text) == ["第一行", "第二行", "第三行"])
        #expect(rows.allSatisfy { $0.lineIndex == nil && !$0.isPlaying && $0.translation == nil })
        #expect(CarPlayLyricsBuilder.plainRows(plain, limit: 0).isEmpty)
        #expect(CarPlayLyricsBuilder.plainRows("\n  \n", limit: 3).isEmpty)
    }

    // MARK: - 内容与占位

    @Test("占位四态：未在播放 / 加载中 / 无歌词 / 纯音乐")
    func placeholderStates() {
        let noTrack = CarPlayLyricsBuilder.content(
            trackTitle: nil, lyrics: nil, isLoading: false, activeLineIndex: nil
        )
        #expect(noTrack.placeholder == .noTrack)
        #expect(noTrack.header == nil)

        let emptyTitle = CarPlayLyricsBuilder.content(
            trackTitle: "", lyrics: nil, isLoading: false, activeLineIndex: nil
        )
        #expect(emptyTitle.placeholder == .noTrack)

        let loading = CarPlayLyricsBuilder.content(
            trackTitle: "歌", lyrics: makeLyrics(makeLines(["一"])), isLoading: true, activeLineIndex: 0
        )
        #expect(loading.placeholder == .loading)
        #expect(loading.rows.isEmpty)

        let noLyrics = CarPlayLyricsBuilder.content(
            trackTitle: "歌", lyrics: nil, isLoading: false, activeLineIndex: nil
        )
        #expect(noLyrics.placeholder == .noLyrics)

        let instrumental = CarPlayLyricsBuilder.content(
            trackTitle: "歌",
            lyrics: makeLyrics([], instrumental: true),
            isLoading: false,
            activeLineIndex: nil
        )
        #expect(instrumental.placeholder == .instrumental)

        let blankPlain = CarPlayLyricsBuilder.content(
            trackTitle: "歌", lyrics: makeLyrics([], plain: "   \n\n"), isLoading: false, activeLineIndex: nil
        )
        #expect(blankPlain.placeholder == .noLyrics)
    }

    @Test("有内容时占位为空，小节标题 = 曲名")
    func headerAndPlaceholderWhenPlaying() {
        let content = CarPlayLyricsBuilder.content(
            trackTitle: "七里香",
            lyrics: makeLyrics(makeLines(["一", "二", "三"])),
            isLoading: false,
            activeLineIndex: 1
        )
        #expect(content.header == "七里香")
        #expect(content.placeholder == nil)
        #expect(content.rows.first?.lineIndex == 1)
    }

    @Test("同步歌词优先；无时间轴才用纯文本兜底")
    func syncedWinsOverPlain() {
        let both = CarPlayLyricsBuilder.content(
            trackTitle: "歌",
            lyrics: makeLyrics(makeLines(["同步一", "同步二", "同步三"]), plain: "纯文本一\n纯文本二"),
            isLoading: false,
            activeLineIndex: 1
        )
        #expect(both.rows.map(\.lineIndex) == [1, 2])
        #expect(both.rows.first?.text == "同步二")
        #expect(both.rows.first?.isPlaying == true)

        let plainOnly = CarPlayLyricsBuilder.content(
            trackTitle: "歌",
            lyrics: makeLyrics([], plain: "纯文本一\n纯文本二"),
            isLoading: false,
            activeLineIndex: nil
        )
        #expect(plainOnly.rows.count == 2)
        #expect(plainOnly.rows.allSatisfy { !$0.isPlaying && $0.lineIndex == nil })
    }

    // MARK: - 刷新判据（不重建的契约）

    @Test("同一句内内容不变（否则列表会按 0.25s tick 重建）")
    func contentStableWithinSameLine() {
        let lyrics = makeLyrics(makeLines(["一", "二", "三"]))

        let base = CarPlayLyricsBuilder.content(
            trackTitle: "歌", lyrics: lyrics, isLoading: false, activeLineIndex: 1
        )
        let again = CarPlayLyricsBuilder.content(
            trackTitle: "歌", lyrics: lyrics, isLoading: false, activeLineIndex: 1
        )
        let nextLine = CarPlayLyricsBuilder.content(
            trackTitle: "歌", lyrics: lyrics, isLoading: false, activeLineIndex: 2
        )

        #expect(base == again)
        #expect(base != nextLine)
    }

    @Test("行号由 LyricTiming 决定（两句之间仍是前一句），窗口随之移动")
    func activeLineIndexComesFromLyricTiming() {
        let lines = makeLines(["一", "二", "三"]) // 1s / 6s / 11s
        let index = LyricTiming.activeLineIndex(time: 7, in: lines)
        #expect(index == 1)

        let content = CarPlayLyricsBuilder.content(
            trackTitle: "歌",
            lyrics: makeLyrics(lines),
            isLoading: false,
            activeLineIndex: index
        )
        #expect(content.rows.first?.lineIndex == 1)
        #expect(content.rows.first?.text == "二")
        #expect(content.rows.first?.isPlaying == true)
    }
}
