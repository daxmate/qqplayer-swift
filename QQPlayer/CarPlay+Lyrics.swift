//
//  CarPlay+Lyrics.swift
//  QQPlayer
//
//  CarPlay 歌词内容（纯逻辑）：把播放态映射成「当前句 + 后续句」的行窗口。
//
//  形态由来（2026-09-15）：CarPlay 模板集里没有歌词控件——iPhoneOS26.5 SDK 的
//  CarPlay.framework 全部头文件 grep -i lyric 无命中；Now Playing 屏由系统接管，
//  不接受 App 注入自定义内容（CPNowPlayingTemplate 只有按钮 / Up Next / Sports 模式）。
//  可行且不分散注意力的形态 = 列表行：当前句永远在位（isPlaying 播放指示器标注）+
//  后续若干句，逐句重建列表——等价于「不用滚动的自动滚屏」（列表模板没有 scrollTo API）。
//
//  消费方（2026-09-16 起）：CarPlay+PlayerPage.swift 的播放页（页头 + 三行歌词）。
//  本站保留「播放态 → 行窗口」的唯一实现：行数由消费方给（upcoming / plainLineLimit），
//  占位四态、简繁归一、翻译/罗马音取舍都在这里，别在页面层再写一套。
//
//  歌词语义不另起一套：
//   - 行号判定 → LyricTiming.activeLineIndex（iOS 唯一入口）
//   - 简繁字形归一 → LyricsLine.displayText / displayTranslation（DisplayScriptNormalizer）
//
// target: ios-only
//
import CarPlay
import Combine
import Foundation
import UIKit

// MARK: - 内容模型（纯值类型）

/// CarPlay 歌词列表的一行
struct CarPlayLyricRow: Equatable {
    /// syncedLyrics 中的行号；无时间轴的纯文本兜底行为 nil
    let lineIndex: Int?
    let text: String
    /// 翻译（与 iOS 歌词页一致：有翻译就显示）
    let translation: String?
    /// 罗马音（网易云 romalrc；仅部分曲目有）。列表行只有「主行 + 副行」两个文字位，
    /// 渲染时罗马音优先占副行（乘客跟唱/跟读更需要），没有罗马音才退回译文。
    let roman: String?
    /// 是否为当前句（映射到 CPListItem.isPlaying）
    let isPlaying: Bool
}

/// 没有歌词行可显示时的占位状态（文案在渲染层解析，纯逻辑侧只表达状态 → 可单测）
enum CarPlayLyricsPlaceholder: Equatable {
    /// 没有在播曲目
    case noTrack
    /// 歌词加载中
    case loading
    /// 该曲目没有歌词
    case noLyrics
    /// 纯音乐
    case instrumental

    var title: String {
        switch self {
        case .noTrack: return "not_playing".localized
        case .loading: return "lyrics_loading".localized
        case .noLyrics: return "no_lyrics".localized
        case .instrumental: return "instrumental_no_lyrics".localized
        }
    }
}

/// 歌词页内容（Equatable：相等 = 不上屏）。
/// 歌词页自己的时钟每 0.5s 算一次内容，没有这层判据会把整个列表按 tick 频率重建。
struct CarPlayLyricsContent: Equatable {
    /// 小节标题（曲名；无曲目时 nil）
    let header: String?
    let rows: [CarPlayLyricRow]
    /// rows 为空时的占位
    let placeholder: CarPlayLyricsPlaceholder?
}

// MARK: - 内容构建（纯逻辑）

/// 播放态 → 歌词页内容（纯函数：输入全是值类型，不依赖 CarPlay / 播放器 / 数据库）
enum CarPlayLyricsBuilder {
    /// 当前句之后还显示几句（行驶中一屏 6 行够读）
    static let upcomingLineCount = 5
    /// 无时间轴歌词兜底显示几行
    static let plainLineLimit = 6

    static func content(
        trackTitle: String?,
        lyrics: Lyrics?,
        isLoading: Bool,
        activeLineIndex: Int?,
        upcoming: Int = CarPlayLyricsBuilder.upcomingLineCount,
        showRoman: Bool = true,
        plainLineLimit: Int = CarPlayLyricsBuilder.plainLineLimit
    ) -> CarPlayLyricsContent {
        guard let trackTitle, !trackTitle.isEmpty else {
            return CarPlayLyricsContent(header: nil, rows: [], placeholder: .noTrack)
        }
        guard !isLoading else {
            return CarPlayLyricsContent(header: trackTitle, rows: [], placeholder: .loading)
        }
        guard let lyrics else {
            return CarPlayLyricsContent(header: trackTitle, rows: [], placeholder: .noLyrics)
        }
        guard !lyrics.isInstrumental else {
            return CarPlayLyricsContent(header: trackTitle, rows: [], placeholder: .instrumental)
        }

        if !lyrics.syncedLyrics.isEmpty {
            let rows = window(
                lyrics.syncedLyrics,
                activeLineIndex: activeLineIndex,
                upcoming: upcoming,
                showRoman: showRoman
            )
            return CarPlayLyricsContent(header: trackTitle, rows: rows, placeholder: nil)
        }

        let rows = plainRows(lyrics.plainLyrics, limit: plainLineLimit)
        guard !rows.isEmpty else {
            return CarPlayLyricsContent(header: trackTitle, rows: [], placeholder: .noLyrics)
        }
        return CarPlayLyricsContent(header: trackTitle, rows: rows, placeholder: nil)
    }

    /// 从当前句开始的窗口（当前句 + 后续 upcoming 句）
    static func window(
        _ lines: [LyricsLine],
        activeLineIndex: Int?,
        upcoming: Int,
        showRoman: Bool = true
    ) -> [CarPlayLyricRow] {
        guard !lines.isEmpty else { return [] }
        let start = windowStart(activeLineIndex: activeLineIndex, lineCount: lines.count)
        let end = min(lines.count, start + max(upcoming, 0) + 1)
        return (start ..< end).map { index in
            let line = lines[index]
            let translation = line.displayTranslation
            let roman = showRoman ? line.displayRoman : nil
            return CarPlayLyricRow(
                lineIndex: index,
                text: line.displayText,
                translation: (translation?.isEmpty ?? true) ? nil : translation,
                roman: (roman?.isEmpty ?? true) ? nil : roman,
                isPlaying: index == activeLineIndex
            )
        }
    }

    /// 窗口起点：当前句；尚未到第一句（nil）或行号越界时收敛到合法范围
    static func windowStart(activeLineIndex: Int?, lineCount: Int) -> Int {
        guard lineCount > 0 else { return 0 }
        return min(max(activeLineIndex ?? 0, 0), lineCount - 1)
    }

    /// 无时间轴歌词兜底：静态显示开头几行（没有时间轴就没有「当前句」，故不高亮）
    static func plainRows(_ plainLyrics: String, limit: Int) -> [CarPlayLyricRow] {
        guard limit > 0 else { return [] }
        return plainLyrics
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { text in
                CarPlayLyricRow(
                    lineIndex: nil,
                    text: DisplayScriptNormalizer.display(String(text)),
                    translation: nil,
                    roman: nil,
                    isPlaying: false
                )
            }
    }
}
