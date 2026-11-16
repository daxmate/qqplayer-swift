//
//  LyricAlignmentAligner.swift
//  QQPlayer
//
//  纯逻辑：把歌词行对齐到 ASR 时间轴（字符级单调 DP）。
//  禁止 import Speech / AVFoundation —— 本文件只吃 AsrToken，可离线单测。
//
//  算法见 docs/lyrics-alignment.md：
//    1. 歌词行 → 归一化字符序列（带行号），ASR token → 字符流（char 时间在 token 内线性摊派）
//    2. Needleman-Wunsch 全局对齐：匹配 +1 / 错配 −0.5 / gap −0.6（内部 ×10 存 Int32）
//       有原时间先验时只允许落在「期望时间 ±8s」的窄带内，防跨段错配
//    3. 每行统计命中字符 → similarity + start/end
//    4. 未命中行：常数偏移（MAD 小且样本够）或邻居插值
//    5. 单调化：严格不重叠、夹在 [0, duration]
//

import Foundation

struct LyricAlignmentAligner {
    /// 对齐输入行。
    struct LineInput: Equatable, Sendable {
        let text: String
        /// 原歌词时间（有 synced 歌词时的先验；plain 歌词为 nil）。
        let priorStart: TimeInterval?

        init(text: String, priorStart: TimeInterval? = nil) {
            self.text = text
            self.priorStart = priorStart
        }
    }

    /// 对齐输出（行时间 + 统计）。
    struct Result: Equatable, Sendable {
        let lines: [AlignedLyricLine]
        let matchedCount: Int
        let medianOffset: TimeInterval
        let warnings: [String]
    }

    // MARK: - 阈值（与 docs/lyrics-alignment.md 同步）

    /// 行相似度门槛：命中字符数 / 行字符数。
    static let matchThreshold = 0.6
    /// 允许参与锚点的最短行（1 字符行另判，见 matchLine）。
    static let minAnchorCharacters = 2
    /// 时间先验窄带半径（秒）：只允许落在期望时间 ±8s 内。
    static let priorBandSeconds: TimeInterval = 8
    /// 常数偏移可用的 MAD 上限（秒）：偏移不稳定说明不是整体平移。
    static let offsetLimitMAD: TimeInterval = 0.4
    /// 常数偏移的最少样本行数。
    static let minOffsetSamples = 3
    /// 一行歌词的最短显示时长（秒）。
    static let minLineDuration: TimeInterval = 0.2
    /// 无先验时估计每字时长的经验值（秒/字），用于估算行跨度。
    static let estimatedSecondsPerCharacter: TimeInterval = 0.22

    /// DP 打分（× 10 的整数，避免浮点比较误差）。
    private static let matchScore: Int32 = 10
    private static let mismatchScore: Int32 = -5
    private static let gapScore: Int32 = -6
    /// DP 规模上限（网格数）：超了就不做（正常歌曲远低于此）。
    private static let maxGridCells = 8_000_000

    // MARK: - 主入口

    static func align(
        lines: [LineInput],
        tokens: [AsrToken],
        duration: TimeInterval,
        simplifyChinese: Bool
    ) throws -> Result {
        let asr = asrCharacters(from: tokens)
        guard !asr.isEmpty else { throw LyricAlignmentError.alignmentFailed }

        // 1. 参考序列：所有行的归一化字符串起来（带行号）。
        var reference: [Character] = []
        var referenceLine: [Int] = []
        var lineCharacterCounts = [Int](repeating: 0, count: lines.count)
        for (index, line) in lines.enumerated() {
            let characters = LyricAlignmentTextNormalizer.normalizedCharacters(
                of: line.text,
                simplifyChinese: simplifyChinese
            )
            lineCharacterCounts[index] = characters.count
            reference.append(contentsOf: characters)
            referenceLine.append(contentsOf: repeatElement(index, count: characters.count))
        }
        guard !reference.isEmpty else { throw LyricAlignmentError.alignmentFailed }
        guard reference.count * asr.count <= maxGridCells else {
            throw LyricAlignmentError.alignmentFailed
        }

        // 2. 先验期望时间（每字符）：有原时间才能窄带。
        let expected = expectedTimes(
            lines: lines,
            lineCharacterCounts: lineCharacterCounts
        )

        // 3. 单调字符级 DP。
        let pairs = monotonicPairs(reference: reference, asr: asr, expected: expected)

        // 4. 每行命中统计。
        var matchedCharacters = [Int](repeating: 0, count: lines.count)
        var hitStarts = [TimeInterval?](repeating: nil, count: lines.count)
        var hitEnds = [TimeInterval?](repeating: nil, count: lines.count)
        for pair in pairs where reference[pair.reference] == asr[pair.asr].character {
            let line = referenceLine[pair.reference]
            matchedCharacters[line] += 1
            let start = asr[pair.asr].start
            let end = asr[pair.asr].end
            hitStarts[line] = min(hitStarts[line] ?? start, start)
            hitEnds[line] = max(hitEnds[line] ?? end, end)
        }

        var similarities = [Double](repeating: 0, count: lines.count)
        var isMatched = [Bool](repeating: false, count: lines.count)
        for index in lines.indices {
            guard lineCharacterCounts[index] > 0 else { continue }
            let similarity = Double(matchedCharacters[index]) / Double(lineCharacterCounts[index])
            similarities[index] = similarity
            if lineCharacterCounts[index] >= minAnchorCharacters {
                isMatched[index] = similarity >= matchThreshold
            } else {
                // 单字符行：只有那一个字精确命中才算（否则任何一行都「100% 命中」）。
                isMatched[index] = matchedCharacters[index] == 1
            }
        }
        let matchedCount = isMatched.reduce(into: 0) { count, value in if value { count += 1 } }
        guard matchedCount > 0 else { throw LyricAlignmentError.alignmentFailed }

        // 5. 常数偏移（有先验的命中行才参与）。
        var offsets: [TimeInterval] = []
        for index in lines.indices where isMatched[index] {
            guard let prior = lines[index].priorStart, let start = hitStarts[index] else { continue }
            offsets.append(start - prior)
        }
        let medianOffset = median(offsets) ?? 0
        let mad = median(offsets.map { abs($0 - medianOffset) }) ?? 0
        let usesConstantOffset = offsets.count >= minOffsetSamples && mad < offsetLimitMAD

        // 6. 逐行初值：命中行用 ASR 时间；未命中行能偏移就先偏移，否则留空等插值。
        var starts = [TimeInterval?](repeating: nil, count: lines.count)
        var ends = [TimeInterval?](repeating: nil, count: lines.count)
        var isInterpolated = [Bool](repeating: true, count: lines.count)
        for index in lines.indices {
            if isMatched[index], let start = hitStarts[index] {
                starts[index] = start
                ends[index] = max(hitEnds[index] ?? start, start + minLineDuration)
                isInterpolated[index] = false
            } else if usesConstantOffset, let prior = lines[index].priorStart {
                let start = max(0, prior + medianOffset)
                starts[index] = start
                ends[index] = start + estimatedDuration(characterCount: lineCharacterCounts[index])
            }
        }

        // 7. 空档插值：按字符数分摊前后锚点之间的时间。
        interpolateGaps(
            starts: &starts,
            ends: &ends,
            lineCharacterCounts: lineCharacterCounts,
            duration: duration
        )

        // 8. 单调化 + 夹在 [0, duration]。
        let limit = effectiveLimit(starts: starts, ends: ends, duration: duration)
        var aligned: [AlignedLyricLine] = []
        aligned.reserveCapacity(lines.count)
        var previousEnd: TimeInterval = 0
        for index in lines.indices {
            var start = max(starts[index] ?? previousEnd, previousEnd)
            if start > limit { start = limit }
            var end = ends[index] ?? (start + minLineDuration)
            if end < start + minLineDuration, start + minLineDuration <= limit {
                end = start + minLineDuration
            }
            end = min(max(end, start), limit)
            aligned.append(
                AlignedLyricLine(
                    index: index,
                    start: start,
                    end: end,
                    similarity: similarities[index],
                    isInterpolated: isInterpolated[index]
                )
            )
            previousEnd = end
        }

        return Result(
            lines: aligned,
            matchedCount: matchedCount,
            medianOffset: medianOffset,
            warnings: warnings(
                lines: lines,
                matchedCount: matchedCount,
                offsets: offsets,
                usesConstantOffset: usesConstantOffset,
                mad: mad
            )
        )
    }

    // MARK: - ASR 字符流

    private struct AsrCharacter {
        let character: Character
        let start: TimeInterval
        let end: TimeInterval
    }

    /// token → 字符流；字符时间在 token 内部线性摊派（提高行首/行尾精度）。
    private static func asrCharacters(from tokens: [AsrToken]) -> [AsrCharacter] {
        var characters: [AsrCharacter] = []
        for token in tokens {
            let normalized = LyricAlignmentTextNormalizer.normalizedCharacters(
                of: token.text,
                simplifyChinese: false
            )
            guard !normalized.isEmpty else { continue }
            let span = max(token.end - token.start, 0)
            let step = span / Double(normalized.count)
            for (offset, character) in normalized.enumerated() {
                let start = token.start + step * Double(offset)
                let end = token.start + step * Double(offset + 1)
                characters.append(
                    AsrCharacter(character: character, start: start, end: max(end, start))
                )
            }
        }
        return characters
    }

    // MARK: - 先验窄带

    /// 每个参考字符的期望时间（nil = 该行无先验，不限窄带）。
    private static func expectedTimes(
        lines: [LineInput],
        lineCharacterCounts: [Int]
    ) -> [TimeInterval?] {
        var expected: [TimeInterval?] = []
        for (index, line) in lines.enumerated() {
            let count = lineCharacterCounts[index]
            guard count > 0 else { continue }
            guard let prior = line.priorStart else {
                expected.append(contentsOf: repeatElement(nil, count: count))
                continue
            }
            let span = estimatedSpan(lineIndex: index, lines: lines, characterCount: count)
            for offset in 0 ..< count {
                expected.append(prior + Double(offset) / Double(count) * span)
            }
        }
        return expected
    }

    /// 一行的时间跨度估计：下一行先验 − 本行先验；没有下一行就按字数估。
    private static func estimatedSpan(
        lineIndex: Int,
        lines: [LineInput],
        characterCount: Int
    ) -> TimeInterval {
        let prior = lines[lineIndex].priorStart ?? 0
        for next in lines.index(after: lineIndex) ..< lines.count {
            guard let nextPrior = lines[next].priorStart else { continue }
            if nextPrior > prior {
                return min(max(nextPrior - prior, 0.5), 30)
            }
        }
        return min(
            max(Double(characterCount) * estimatedSecondsPerCharacter, 1),
            15
        )
    }

    private static func allowsAlignment(expected: [TimeInterval?], reference: Int, asrTime: TimeInterval) -> Bool {
        guard let expectedTime = expected[reference] else { return true }
        return abs(asrTime - expectedTime) <= priorBandSeconds
    }

    // MARK: - DP

    private struct Pair {
        let reference: Int
        let asr: Int
    }

    /// Needleman-Wunsch 全局对齐，返回单调递增的配对序列。
    private static func monotonicPairs(
        reference: [Character],
        asr: [AsrCharacter],
        expected: [TimeInterval?]
    ) -> [Pair] {
        let referenceCount = reference.count
        let asrCount = asr.count
        let width = asrCount + 1
        var scores = [Int32](repeating: 0, count: (referenceCount + 1) * width)

        for row in 1 ... referenceCount {
            scores[row * width] = Int32(row) * gapScore
        }
        for column in 1 ... asrCount {
            scores[column] = Int32(column) * gapScore
        }

        for row in 1 ... referenceCount {
            let rowBase = row * width
            let previousBase = rowBase - width
            let character = reference[row - 1]
            for column in 1 ... asrCount {
                let gapInReference = scores[previousBase + column] + gapScore
                let gapInASR = scores[rowBase + column - 1] + gapScore
                var best = max(gapInReference, gapInASR)
                if allowsAlignment(
                    expected: expected,
                    reference: row - 1,
                    asrTime: asr[column - 1].start
                ) {
                    let pairScore = character == asr[column - 1].character ? matchScore : mismatchScore
                    best = max(best, scores[previousBase + column - 1] + pairScore)
                }
                scores[rowBase + column] = best
            }
        }

        var pairs: [Pair] = []
        pairs.reserveCapacity(min(referenceCount, asrCount))
        var row = referenceCount
        var column = asrCount
        while row > 0 && column > 0 {
            let current = scores[row * width + column]
            let diagonalBase = (row - 1) * width + (column - 1)
            if allowsAlignment(
                expected: expected,
                reference: row - 1,
                asrTime: asr[column - 1].start
            ) {
                let pairScore = reference[row - 1] == asr[column - 1].character
                    ? matchScore
                    : mismatchScore
                if current == scores[diagonalBase] + pairScore {
                    pairs.append(Pair(reference: row - 1, asr: column - 1))
                    row -= 1
                    column -= 1
                    continue
                }
            }
            if current == scores[(row - 1) * width + column] + gapScore {
                row -= 1
                continue
            }
            if current == scores[row * width + column - 1] + gapScore {
                column -= 1
                continue
            }
            // 理论上不可达；保守地退一格，避免死循环。
            row -= 1
            column -= 1
        }
        return pairs.reversed()
    }

    // MARK: - 插值与兜底

    private static func estimatedDuration(characterCount: Int) -> TimeInterval {
        max(minLineDuration, Double(max(characterCount, 1)) * estimatedSecondsPerCharacter)
    }

    /// 给所有还没有时间的行按字符权重插值（前后锚点之间）。
    private static func interpolateGaps(
        starts: inout [TimeInterval?],
        ends: inout [TimeInterval?],
        lineCharacterCounts: [Int],
        duration: TimeInterval
    ) {
        var index = 0
        while index < starts.count {
            guard starts[index] == nil else {
                index += 1
                continue
            }
            var last = index
            while last + 1 < starts.count, starts[last + 1] == nil {
                last += 1
            }
            let lowerBound = index > 0 ? (ends[index - 1] ?? 0) : 0
            let upperBound: TimeInterval
            if last + 1 < starts.count, let nextStart = starts[last + 1] {
                upperBound = max(nextStart, lowerBound + minLineDuration)
            } else {
                upperBound = max(duration, lowerBound + minLineDuration)
            }
            let weights = (index ... last).map { max(lineCharacterCounts[$0], 1) }
            let totalWeight = weights.reduce(0, +)
            let span = max(upperBound - lowerBound, minLineDuration * Double(last - index + 1))
            var cursor = lowerBound
            for (offset, lineIndex) in (index ... last).enumerated() {
                let share = span * Double(weights[offset]) / Double(totalWeight)
                starts[lineIndex] = cursor
                ends[lineIndex] = cursor + max(share, 0.05)
                cursor = ends[lineIndex] ?? cursor
            }
            index = last + 1
        }
    }

    private static func effectiveLimit(
        starts: [TimeInterval?],
        ends: [TimeInterval?],
        duration: TimeInterval
    ) -> TimeInterval {
        if duration > 0 { return duration }
        let lastEnd = ends.compactMap { $0 }.max() ?? 0
        let lastStart = starts.compactMap { $0 }.max() ?? 0
        return max(max(lastEnd, lastStart), 1)
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func warnings(
        lines: [LineInput],
        matchedCount: Int,
        offsets: [TimeInterval],
        usesConstantOffset: Bool,
        mad: TimeInterval
    ) -> [String] {
        var warnings: [String] = []
        if Double(matchedCount) / Double(max(lines.count, 1)) < 0.5 {
            warnings.append(
                "匹配率偏低（" + String(matchedCount) + "/" + String(lines.count) + "）：歌词可能与音频不对应"
            )
        }
        if !offsets.isEmpty, !usesConstantOffset {
            warnings.append(
                "原时间偏移不稳定（样本 " + String(offsets.count)
                    + " 行，MAD " + formatted(mad) + "s）：未使用常数偏移，改用邻位插值"
            )
        }
        return warnings
    }

    private static func formatted(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
    }
}
