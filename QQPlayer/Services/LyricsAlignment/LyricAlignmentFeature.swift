//
//  LyricAlignmentFeature.swift
//  QQPlayer
//
//  歌词时间轴对齐的「能不能用」判定（纯函数，可单测）。
//  入口可见性（菜单项）与真正开跑前的守门都收敛在这里，避免视图里各写一套。
//

import Foundation

enum LyricAlignmentFeature {
    /// 系统能力：Apple SpeechAnalyzer 需要 iOS 26 / macOS 26。
    static var isSupported: Bool {
        if #available(iOS 26, macOS 26, *) {
            return true
        }
        return false
    }

    /// 完整判据（真正开跑前用）：支持系统 + 本地文件存在 + 非纯音乐 + 至少 2 个非空歌词行 + 时长 > 0。
    static func canAlign(track: Track, lyrics: Lyrics, fileExists: Bool) -> Bool {
        guard canOfferAlignment(track: track, fileExists: fileExists) else { return false }
        guard !lyrics.isInstrumental else { return false }
        return nonEmptyLineCount(in: lyrics) >= 2
    }

    /// 菜单入口用的轻量判据：不依赖歌词是否已加载（歌词在点按后才去取）。
    ///
    /// 与 `canAlign` 的差别只在「歌词行数」这一项——它需要异步取歌词，做不到在菜单
    /// 渲染时同步判断；取到歌词后再由 `canAlign` 兜底，不满足就给可读提示。
    static func canOfferAlignment(track: Track, fileExists: Bool) -> Bool {
        guard isSupported, fileExists else { return false }
        guard (track.durationMs ?? 0) > 0 else { return false }
        return true
    }

    /// 播放页 / 跟唱控制条入口的可用性（纯函数）：能提供对齐 + 当前歌词真有同步行。
    /// 视图只读这个结果决定灰显，不再各自拼判据。
    static func canOfferTimelineAnalysis(track: Track, fileExists: Bool, lyrics: Lyrics?) -> Bool {
        guard canOfferAlignment(track: track, fileExists: fileExists) else { return false }
        return hasSyncedLyrics(lyrics)
    }

    /// 入口点击的即时提示（播放页 / 跟唱条共用；文案集中在这里，避免两处入口各写一套）。
    enum EntryNotice: Equatable {
        /// 正在取歌词 / 起任务，随后进度 sheet 接管。
        case preparing
        /// 对齐已在跑（再点不静默）。
        case alreadyRunning
        /// 没有同步歌词（未加载完 / 纯音乐 / 空行）。
        case noSyncedLyrics
        /// 歌词仍在加载。
        case lyricsLoading

        /// 顶部一行提示文案。
        var message: String {
            switch self {
            case .preparing: return "lyrics.align.entry.preparing".localized
            case .alreadyRunning: return "lyrics.align.entry.running".localized
            case .noSyncedLyrics: return "lyric_align_no_synced_lyrics".localized
            case .lyricsLoading: return "lyrics.align.entry.loading".localized
            }
        }
    }

    /// 点击入口时的即时反馈判定（纯函数）：
    /// - 对齐已在跑 → `.alreadyRunning`
    /// - 歌词没到位且仍在加载 → `.lyricsLoading`
    /// - 没有同步歌词（含纯音乐 / 空行）→ `.noSyncedLyrics`
    /// - 其余 → `.preparing`（交给 startAlignment；系统 / 文件 / 时长不满足时由它把可读失败写进 sheet）
    ///
    /// 无当前曲目 → nil（无话可说，也不开跑）。
    static func entryNotice(
        track: Track?,
        lyrics: Lyrics?,
        lyricsLoading: Bool,
        isRunning: Bool
    ) -> EntryNotice? {
        guard track != nil else { return nil }
        if isRunning { return .alreadyRunning }
        if lyrics == nil, lyricsLoading { return .lyricsLoading }
        guard hasSyncedLyrics(lyrics) else { return .noSyncedLyrics }
        return .preparing
    }

    /// 是否有可对齐的同步歌词：nil（未加载 / 取不到）、纯音乐、空行都算「没有」。
    static func hasSyncedLyrics(_ lyrics: Lyrics?) -> Bool {
        guard let lyrics, !lyrics.isInstrumental else { return false }
        return nonEmptyLineCount(in: lyrics) > 0
    }

    /// 是否已有对齐产物（「已对齐」的唯一事实源 = aligned 歌词库）。
    /// - Parameter store: 测试注入临时目录；生产用 `.shared`。
    static func isAligned(stableId: String, store: AlignedLyricsStore = .shared) -> Bool {
        store.contains(forStableId: stableId)
    }

    /// 非空（去首尾空白后）歌词行数。
    static func nonEmptyLineCount(in lyrics: Lyrics) -> Int {
        lyrics.syncedLyrics.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }
}
