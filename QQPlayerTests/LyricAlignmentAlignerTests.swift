//
//  LyricAlignmentAlignerTests.swift
//  QQPlayerTests
//
//  纯逻辑对齐器：完美匹配 / 常数偏移 / 漏句插值 / 重复副歌 / 单调与边界 / 全不匹配。
//

import Foundation
import Testing

@testable import QQPlayer

struct LyricAlignmentAlignerTests {
    private func line(_ text: String, _ prior: TimeInterval?) -> LyricAlignmentAligner.LineInput {
        LyricAlignmentAligner.LineInput(text: text, priorStart: prior)
    }

    private func token(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> AsrToken {
        AsrToken(text: text, start: start, end: end)
    }

    @Test("完美匹配：行时间贴 ASR，全部非插值")
    func perfectMatch() throws {
        let lines = [line("第一句歌词", 0), line("第二句歌词", 2)]
        let tokens = [token("第一句歌词", 0.2, 1.8), token("第二句歌词", 2.2, 3.8)]

        let result = try LyricAlignmentAligner.align(
            lines: lines,
            tokens: tokens,
            duration: 10,
            simplifyChinese: false
        )

        #expect(result.matchedCount == 2)
        #expect(abs(result.lines[0].start - 0.2) < 0.02)
        #expect(abs(result.lines[1].start - 2.2) < 0.02)
        #expect(abs(result.lines[0].similarity - 1) < 0.001)
        #expect(result.lines.allSatisfy { !$0.isInterpolated })
    }

    @Test("整体常数偏移：原时间比音频晚 3.7s → offset ≈ −3.7，输出贴 ASR")
    func constantOffset() throws {
        let lines = [line("第一句歌词", 3.7), line("第二句歌词", 5.7)]
        let tokens = [token("第一句歌词", 0, 2), token("第二句歌词", 2, 4)]

        let result = try LyricAlignmentAligner.align(
            lines: lines,
            tokens: tokens,
            duration: 10,
            simplifyChinese: false
        )

        #expect(abs(result.medianOffset + 3.7) < 0.05)
        #expect(abs(result.lines[0].start - 0) < 0.02)
        #expect(abs(result.lines[1].start - 2) < 0.02)
        #expect(result.matchedCount == 2)
    }

    @Test("ASR 漏一整句：该行插值且夹在邻居之间")
    func missingLineInterpolates() throws {
        // 三行用完全不同字面，避免「半句相同」被 DP 判成部分命中。
        let lines = [line("春风吹过山岗", 0), line("夏雨落在窗前", 2), line("秋叶飘零无声", 4)]
        let tokens = [token("春风吹过山岗", 0, 2), token("秋叶飘零无声", 4, 6)]

        let result = try LyricAlignmentAligner.align(
            lines: lines,
            tokens: tokens,
            duration: 10,
            simplifyChinese: false
        )

        #expect(result.matchedCount == 2)
        let middle = result.lines[1]
        #expect(middle.isInterpolated)
        #expect(middle.start >= result.lines[0].end - 0.001)
        #expect(middle.end <= result.lines[2].start + 0.001)
        #expect(result.lines[2].start >= result.lines[0].end)
    }

    @Test("重复副歌（同文本 3 次）按位置单调分配，不塌到第一处")
    func repeatedChorus() throws {
        let chorus = "副歌部分"
        let verse = "尾声段落"
        var lines: [LyricAlignmentAligner.LineInput] = []
        var tokens: [AsrToken] = []
        for round in 0 ..< 3 {
            let base = Double(round) * 10
            lines.append(line(chorus, base))
            lines.append(line(verse, base + 2))
            tokens.append(token(chorus, base, base + 1.8))
            tokens.append(token(verse, base + 2, base + 3.8))
        }

        let result = try LyricAlignmentAligner.align(
            lines: lines,
            tokens: tokens,
            duration: 30,
            simplifyChinese: false
        )

        #expect(result.matchedCount == 6)
        let starts = result.lines.map(\.start)
        for index in 1 ..< starts.count {
            #expect(starts[index] > starts[index - 1])
        }
        #expect(abs(starts[4] - 20) < 0.02)
    }

    @Test("输出严格单调不重叠，且全部落在 [0, duration]")
    func monotonicWithinDuration() throws {
        let lines = [
            line("第一句歌词", 0),
            line("第二句歌词", 2),
            line("第三句歌词", 4),
            line("第四句歌词", 6),
        ]
        // 一个超长 token 把前两行挤到一起，逼出插值与单调化。
        let tokens = [token("第一句歌词", 0.1, 3.9), token("第四句歌词", 4.1, 6.5)]

        let result = try LyricAlignmentAligner.align(
            lines: lines,
            tokens: tokens,
            duration: 9,
            simplifyChinese: false
        )

        for (index, aligned) in result.lines.enumerated() {
            #expect(aligned.start >= 0)
            #expect(aligned.end <= 9 + 0.001)
            #expect(aligned.end >= aligned.start)
            if index > 0 {
                #expect(aligned.start >= result.lines[index - 1].end - 0.001)
            }
        }
    }

    @Test("完全无匹配：抛 alignmentFailed")
    func noMatchThrows() {
        let lines = [line("完全不同的词句", 0)]
        let tokens = [token("zzz qqq", 0, 2)]

        #expect(throws: LyricAlignmentError.alignmentFailed) {
            _ = try LyricAlignmentAligner.align(
                lines: lines,
                tokens: tokens,
                duration: 10,
                simplifyChinese: false
            )
        }
    }
}
