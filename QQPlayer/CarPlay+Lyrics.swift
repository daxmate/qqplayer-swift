//
//  CarPlay+Lyrics.swift
//  QQPlayer
//
//  CarPlay 歌词页：「当前句 + 后续句」列表形态显示同步歌词。
//
//  形态由来（2026-09-15）：CarPlay 模板集里没有歌词控件——iPhoneOS26.5 SDK 的
//  CarPlay.framework 全部头文件 grep -i lyric 无命中；Now Playing 屏由系统接管，
//  不接受 App 注入自定义内容（CPNowPlayingTemplate 只有按钮 / Up Next / Sports 模式）。
//  可行且不分散注意力的形态 = 一个 CPListTemplate：当前句永远在首行（isPlaying
//  播放指示器标注）+ 后续若干句，逐句重建列表——等价于「不用滚动的自动滚屏」
//  （CarPlay 列表模板没有 scrollTo API）。
//
//  歌词语义不另起一套：
//   - 行号判定 → LyricTiming.activeLineIndex（iOS 唯一入口）
//   - 简繁字形归一 → LyricsLine.displayText / displayTranslation（DisplayScriptNormalizer）
//  本文件只做「播放态 → 列表内容」的映射与模板装配；构建部分是纯函数，可单测。
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
        upcoming: Int = CarPlayLyricsBuilder.upcomingLineCount
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
            let rows = window(lyrics.syncedLyrics, activeLineIndex: activeLineIndex, upcoming: upcoming)
            return CarPlayLyricsContent(header: trackTitle, rows: rows, placeholder: nil)
        }

        let rows = plainRows(lyrics.plainLyrics, limit: plainLineLimit)
        guard !rows.isEmpty else {
            return CarPlayLyricsContent(header: trackTitle, rows: [], placeholder: .noLyrics)
        }
        return CarPlayLyricsContent(header: trackTitle, rows: rows, placeholder: nil)
    }

    /// 从当前句开始的窗口（当前句 + 后续 upcoming 句）
    static func window(_ lines: [LyricsLine], activeLineIndex: Int?, upcoming: Int) -> [CarPlayLyricRow] {
        guard !lines.isEmpty else { return [] }
        let start = windowStart(activeLineIndex: activeLineIndex, lineCount: lines.count)
        let end = min(lines.count, start + max(upcoming, 0) + 1)
        return (start ..< end).map { index in
            let line = lines[index]
            let translation = line.displayTranslation
            return CarPlayLyricRow(
                lineIndex: index,
                text: line.displayText,
                translation: (translation?.isEmpty ?? true) ? nil : translation,
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
                    isPlaying: false
                )
            }
    }
}

// MARK: - 歌词页控制器

/// CarPlay 歌词页：持有模板、订阅播放态、内容变化才重建列表。
/// 生命周期由 CarPlaySceneDelegate 管（didConnect 建立 / didDisconnect 调 stop()）。
@MainActor
final class CarPlayLyricsController {
    /// 歌词页模板（在 CarPlaySceneDelegate 里作为 TabBar 第 2 个 tab）
    let template: CPListTemplate

    private var cancellables = Set<AnyCancellable>()
    /// 进度时钟（自己带一只，不复用前 UI timer——见 startObserving 注释）
    private var tickTimer: Timer?
    /// 当前曲目的歌词（加载完成前为 nil）
    private var lyrics: Lyrics?
    private var isLoadingLyrics = false
    /// 歌词归属的曲目：切歌后旧请求的返回必须丢弃（LyricsManager 取歌词可达数秒）
    private var lyricsTrackId: String?
    /// 上一次已上屏的内容
    private var appliedContent: CarPlayLyricsContent?

    init() {
        template = CPListTemplate(title: "lyrics".localized, sections: [])
        template.tabImage = UIImage(systemName: "quote.bubble")
        template.emptyViewTitleVariants = [CarPlayLyricsPlaceholder.noTrack.title]
        startObserving()
    }

    /// 断开 CarPlay 连接时调用：解除订阅与时钟，避免继续更新已销毁的场景
    func stop() {
        cancellables.removeAll()
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - 订阅

    private func startObserving() {
        // 只捕获 Sendable 值（stableId），播放器状态在 MainActor 回调里现读
        // （与 AppCoordinator.setupBindings 同款写法）
        PlayerEngine.shared.$currentTrack
            .map { $0?.stableId }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.currentTrackChanged() }
            }
            .store(in: &cancellables)

        // 播放进度时钟自己带：iOS 进后台会停用 0.25s 前台 UI timer
        // （PlayerEngine.suspendUITimersForBackground），而车里手机基本是锁屏后台态——
        // 订阅 progress.$playbackTime 会冻结在上一句，歌词永远不往下走。
        // 0.5s 与后台 checkIfTrackEnded 同档；内容不变时 refresh 内直接返回，不上屏。
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        currentTrackChanged()
    }

    // MARK: - 状态同步

    private func currentTrackChanged() {
        let track = PlayerEngine.shared.currentTrack
        let trackId = track?.stableId

        guard trackId != lyricsTrackId else {
            refresh()
            return
        }

        lyricsTrackId = trackId
        lyrics = nil
        isLoadingLyrics = track != nil
        refresh()

        guard let track else { return }

        Task { @MainActor [weak self] in
            let loaded = await LyricsManager.shared.getLyrics(for: track)
            guard let self, self.lyricsTrackId == track.stableId else { return }
            self.lyrics = loaded
            self.isLoadingLyrics = false
            self.refresh()
        }
    }

    /// 由播放态算出内容；与上次上屏内容相同则不动模板
    private func refresh() {
        let engine = PlayerEngine.shared
        let lines = lyrics?.syncedLyrics ?? []
        // 位置走 nowPlayingElapsedTime（后台/锁屏可用的实时位置唯一入口，锁屏时间轴同源），
        // 不读后台会冻结的 progress.playbackTime
        let currentTime = engine.nowPlayingElapsedTime()
        let activeIndex = LyricTiming.activeLineIndex(time: currentTime, in: lines)

        let content = CarPlayLyricsBuilder.content(
            trackTitle: engine.currentTrack?.title,
            lyrics: lyrics,
            isLoading: isLoadingLyrics,
            activeLineIndex: activeIndex
        )

        guard content != appliedContent else { return }
        appliedContent = content
        apply(content)
    }

    // MARK: - 上屏

    private func apply(_ content: CarPlayLyricsContent) {
        if let placeholder = content.placeholder {
            template.emptyViewTitleVariants = [placeholder.title]
            // 加载中才转菊花（iOS 18.4+ 系统自带，比自造行更省事）
            template.showsSpinnerWhileEmpty = placeholder == .loading
        }

        guard let header = content.header, !content.rows.isEmpty else {
            template.updateSections([])
            return
        }

        let items = content.rows.map { row -> CPListItem in
            let item = CPListItem(text: row.text, detailText: row.translation)
            item.isPlaying = row.isPlaying
            item.playingIndicatorLocation = .trailing
            // 不设 handler：歌词行不可点，避免行车中误触跳播
            return item
        }

        template.updateSections([CPListSection(items: items, header: header, sectionIndexTitle: nil)])
    }
}
