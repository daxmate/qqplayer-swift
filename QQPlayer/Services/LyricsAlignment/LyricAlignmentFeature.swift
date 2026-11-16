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
