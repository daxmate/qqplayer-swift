//
//  LyricAlignmentTypes.swift
//  QQPlayer
//
//  歌词时间轴自动对齐（核心层）的公共值类型。
//  与 UI 无关：只描述「ASR 产物」「对齐结果」「统计报告」「错误」。
//

import Foundation

/// ASR 产物：一段文本（词/字）与它在音频里的时间范围（秒，从 0 起）。
struct AsrToken: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// 对齐后的一行歌词时间。
struct AlignedLyricLine: Equatable, Sendable {
    /// 原歌词行下标（用于把时间写回原始 Lyrics）。
    let index: Int
    /// 该行起始时间（秒）。
    let start: TimeInterval
    /// 该行结束时间（秒）。
    let end: TimeInterval
    /// 该行匹配字符数 / 行有效字符数（0…1；纯插值行为 0）。
    let similarity: Double
    /// 该行时间不是 ASR 直接命中，而是常数偏移 / 邻位插值推出来的。
    let isInterpolated: Bool
}

/// 一次对齐的统计报告（写库前的可观测结果）。
struct LyricAlignmentReport: Equatable, Sendable {
    /// 参与对齐的歌词行数。
    let lineCount: Int
    /// 被 ASR 直接命中的行数。
    let matchedCount: Int
    /// 命中字符数（分母见 `characterCount`）。
    let matchedCharacters: Int
    /// 参与对齐的歌词有效字符总数（归一化后）。
    let characterCount: Int
    /// 匹配行「ASR 时间 − 原时间」的中位数（秒）；无先验匹配行时为 0。
    let medianOffset: TimeInterval
    /// 实际使用的识别语言标识（如 zh / ja / en）。
    let localeIdentifier: String
    /// 需要提示调用方的告警（覆盖率偏低、先验样本不足等）。
    let warnings: [String]

    /// 识别覆盖率（0…1）：命中字符数 / 歌词有效字符总数；无字符时为 0。
    var coverage: Double {
        guard characterCount > 0 else { return 0 }
        return Double(matchedCharacters) / Double(characterCount)
    }
}

/// 对齐失败原因（底层网络/IO 错误不在此列：那些原样抛出）。
enum LyricAlignmentError: Error, Equatable {
    /// 系统低于 iOS 26 / macOS 26，没有 SpeechAnalyzer。
    case unsupportedSystem
    /// 音频文件读不出来（不存在 / 格式不支持 / 转换失败）。
    case audioUnreadable
    /// 没有可对齐的歌词行。
    case lyricsEmpty
    /// 识别语言在当前系统不可用。
    case localeUnavailable
    /// 语音模型下载/安装失败。
    case assetInstallFailed
    /// 调用方取消。
    case cancelled
    /// 没有任何一行能匹配上（纯音乐、歌词与音频不对应等）。
    case alignmentFailed
}
