//
//  CarPlay+PlayerPage.swift
//  QQPlayer
//
//  CarPlay 播放页（自建）：封面 + 歌名/歌手 + 播放控制 + 三行同步歌词。
//
//  形态由来（2026-09-16 取证；用户给的是 QQ 音乐车载页截图）：
//   - 系统「正在播放」屏（CPNowPlayingTemplate.shared）不接受 App 注入内容，文字位只有
//     title / artist 两行。第三方 App 能让车里看到歌词的做法是把**当前歌词行写进 title
//     槽位**（QQ 音乐就是这么干的）→ 最多一行歌词，且曲名被挤掉。用户要三行 → 系统屏做不到。
//   - iOS 26.4 起 CPListTemplate 有 listHeader（CPListTemplateDetailsHeader：缩略图 + 标题 +
//     副标题 + 若干动作按钮），正好凑成「封面 + 歌名/歌手 + 播放控制」，下面挂歌词行。
//   - iOS 26.4 以下没有该 API：页头缺省，页面退化为「三行歌词」（曲名回落成小节标题）；
//     iPhoneOS26.5 SDK 的 CarPlay.framework 里也没有别的可用控件（grep -i lyric 零命中）。
//
//  歌词语义不另起一套：
//   - 行窗口 / 占位 / 字形归一 → CarPlayLyricsBuilder（歌词内容唯一入口），本层只改行数
//   - 行号判定 → LyricTiming.activeLineIndex；实时位置 → PlayerEngine.nowPlayingElapsedTime()
//  本文件只做「播放态 → 播放页内容」的映射与模板装配；构建部分是纯函数，可单测。
//
// target: ios-only
//
import CarPlay
import Combine
import Foundation
import UIKit

// MARK: - 内容模型（纯值类型）

/// 播放页页头：封面归属 + 歌名/歌手 + 控制键状态（Equatable：变了才重建页头）
struct CarPlayPlayerPageHeader: Equatable {
    let title: String
    let subtitle: String?
    let isPlaying: Bool
    let playOrderMode: PlaybackOrderMode
    /// 进度（只用于页头渲染与重建判据；不变就不重建页头）
    let progress: CarPlayPlayerPageProgress?
    /// 封面归属的曲目（封面异步加载；页头只记 key，图片单独上屏）
    let artworkKey: String?
}

/// 播放页的曲目信息（值类型）：把「谁在播」从参数表里分出来
struct CarPlayPlayerPageTrackInfo: Equatable {
    /// 曲目标识（封面归属）
    let key: String
    let title: String
    let artist: String?
}

/// 播放页页头要跟着变的播放态（播放/暂停图标、播放顺序图标、进度条）
struct CarPlayPlayerPagePlaybackState: Equatable {
    let isPlaying: Bool
    let playOrderMode: PlaybackOrderMode
    /// 已播放时长（秒）
    let elapsed: TimeInterval
    /// 总时长（秒）；0 = 未知（不画进度条）
    let duration: TimeInterval
}

/// 播放页进度：跑在页头封面底部的一条自绘进度条 + 时间文案（CarPlay 列表模板没有滑块）
struct CarPlayPlayerPageProgress: Equatable {
    /// 0…1
    let fraction: Double
    let elapsedText: String
    let totalText: String
}

/// 播放页内容：页头 + 三行歌词
struct CarPlayPlayerPageContent: Equatable {
    let header: CarPlayPlayerPageHeader?
    let rows: [CarPlayLyricRow]
    let placeholder: CarPlayLyricsPlaceholder?
}

// MARK: - 内容构建（纯逻辑）

/// 播放态 → 播放页内容（纯函数：输入全是值类型，不依赖 CarPlay / 播放器 / 数据库）
enum CarPlayPlayerPageBuilder {
    /// 播放页显示几行歌词（当前句 + 后续 2 句）
    static let lyricLineCount = 3

    /// 进度量化步长（秒）：页头重建有成本，进度按 2s 跳而不是按 0.5s tick 跳
    static let progressStep: TimeInterval = 2

    static func content(
        track: CarPlayPlayerPageTrackInfo?,
        playback: CarPlayPlayerPagePlaybackState,
        lyrics: Lyrics?,
        isLoading: Bool,
        activeLineIndex: Int?,
        showRoman: Bool = true
    ) -> CarPlayPlayerPageContent {
        guard let track, !track.title.isEmpty else {
            return CarPlayPlayerPageContent(header: nil, rows: [], placeholder: .noTrack)
        }

        let header = CarPlayPlayerPageHeader(
            title: track.title,
            subtitle: (track.artist?.isEmpty ?? true) ? nil : track.artist,
            isPlaying: playback.isPlaying,
            playOrderMode: playback.playOrderMode,
            progress: progress(elapsed: playback.elapsed, duration: playback.duration),
            artworkKey: track.key
        )

        // 行窗口 / 占位 / 文本归一走歌词内容唯一入口，本层只把行数从 6 收到 3
        let lyricsContent = CarPlayLyricsBuilder.content(
            trackTitle: track.title,
            lyrics: lyrics,
            isLoading: isLoading,
            activeLineIndex: activeLineIndex,
            upcoming: max(lyricLineCount - 1, 0),
            showRoman: showRoman,
            plainLineLimit: lyricLineCount
        )

        return CarPlayPlayerPageContent(
            header: header,
            rows: lyricsContent.rows,
            placeholder: lyricsContent.placeholder
        )
    }

    /// 进度：按步长量化（量化后的值同时决定进度条位置与时间文案 → 同一段内内容不变，页头不重建）
    static func progress(elapsed: TimeInterval, duration: TimeInterval) -> CarPlayPlayerPageProgress? {
        guard duration > 0 else { return nil }
        let clamped = min(max(elapsed, 0), duration)
        let stepped = min((clamped / progressStep).rounded(.down) * progressStep, duration)
        return CarPlayPlayerPageProgress(
            fraction: stepped / duration,
            elapsedText: PlaybackTimeFormat.mmss(stepped),
            totalText: PlaybackTimeFormat.mmss(duration)
        )
    }
}

// MARK: - 播放页控制器

/// CarPlay 播放页：页头（iOS 26.4+：封面 + 歌名/歌手 + 控制键）+ 三行歌词。
/// 生命周期由 CarPlaySceneDelegate 管（didConnect 建立 / didDisconnect 调 stop()）。
@MainActor
final class CarPlayPlayerPageController {
    /// 播放页模板（右上角「正在播放」按钮推入，不占 tab 位）
    let template: CPListTemplate

    private var cancellables = Set<AnyCancellable>()
    /// 进度时钟自己带一只，不复用 0.25s 前台 UI timer——车里手机基本是锁屏后台态
    /// （PlayerEngine.suspendUITimersForBackground 会停掉前台 timer，歌词会冻在上一句）
    private var tickTimer: Timer?
    /// 当前曲目的歌词（加载完成前为 nil）
    private var lyrics: Lyrics?
    private var isLoadingLyrics = false
    /// 歌词归属的曲目：切歌后旧请求的返回必须丢弃（LyricsManager 取歌词可达数秒）
    private var lyricsTrackId: String?
    /// 当前曲目的歌手名（只在切歌时查库一次，别放到 0.5s tick 里）；带 key 防止旧值贴到新曲目上
    private var artistCache: (key: String, name: String?)?
    /// 当前曲目的封面缩略图
    private var artwork: UIImage?
    /// 封面**已出结果**的曲目 key（nil = 当前曲目的封面还没回来）
    private var loadedArtworkKey: String?
    /// 页头已用过的封面归属（出结果后才置位，防每 0.5s 重建页头）
    private var appliedArtworkKey: String?
    /// 上一次已上屏的页头 / 歌词行 / 占位
    private var appliedHeader: CarPlayPlayerPageHeader?
    private var appliedRows: [CarPlayLyricRow] = []
    private var appliedPlaceholder: CarPlayLyricsPlaceholder?
    /// 罗马音开关（iOS 设置页可改；缓存一份，避免每个 tick 读设置）
    private var showRoman = DeleteSettings.load().lyricShowRoman
    /// 已写进系统「正在播放」标题位的歌词行（车载歌词；nil = 当前无覆盖）
    private var appliedCarLyricsTitle: String?

    init() {
        template = CPListTemplate(title: "lyrics".localized, sections: [])
        template.emptyViewTitleVariants = [CarPlayLyricsPlaceholder.noTrack.title]
        startObserving()
    }

    /// 断开 CarPlay 连接时调用：解除订阅与时钟，避免继续更新已销毁的场景
    func stop() {
        cancellables.removeAll()
        tickTimer?.invalidate()
        tickTimer = nil
        clearCarLyricsTitle()
    }

    // MARK: - 订阅

    private func startObserving() {
        // 只捕获 Sendable 值（stableId），播放器状态在 MainActor 回调里现读
        PlayerEngine.shared.currentTrackPublisher
            .map { $0?.stableId }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.currentTrackChanged() }
            }
            .store(in: &cancellables)

        // 0.5s 与播放器后台曲终检测同档（源码注释 "timer that works in background"）。
        // 内容不变时 apply 内直接返回，不上屏。
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        // 设置页改动（显示罗马音开关）→ 下次 refresh 用新值重建内容
        NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.showRoman = DeleteSettings.load().lyricShowRoman
                    self.refresh()
                }
            }
            .store(in: &cancellables)

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
        artistCache = track.map { (key: $0.stableId, name: artistName(for: $0)) }
        isLoadingLyrics = track != nil
        // 封面状态随曲目重置：旧曲目的图既不能显示，也不能算「已出结果」
        artwork = nil
        loadedArtworkKey = nil
        appliedArtworkKey = nil
        refresh()

        guard let track else { return }
        loadLyrics(for: track)
        loadArtwork(for: track)
    }

    private func loadLyrics(for track: Track) {
        Task { @MainActor [weak self] in
            let loaded = await LyricsManager.shared.getLyrics(for: track)
            guard let self, self.lyricsTrackId == track.stableId else { return }
            self.lyrics = loaded
            self.isLoadingLyrics = false
            self.refresh()
        }
    }

    private func loadArtwork(for track: Track) {
        let key = track.stableId
        Task { @MainActor [weak self] in
            let image = await ArtworkManager.shared.getArtwork(for: track)
            guard let self, self.lyricsTrackId == key else { return }
            self.artwork = image.map { resizeArtworkForPlayerPage($0) }
            self.loadedArtworkKey = key
            self.refresh()
        }
    }

    /// 歌手展示名走与列表同一入口（DatabaseManager），只在切歌时查一次
    private func artistName(for track: Track) -> String? {
        guard let name = try? DatabaseManager.shared.getArtistDisplayName(
            forTrackStableId: track.stableId,
            fallbackArtistId: track.artistId
        ), !name.isEmpty else {
            return nil
        }
        return name
    }

    /// 只认当前曲目的缓存值（切歌与查库之间可能插进一次 tick）
    private func cachedArtist(for key: String?) -> String? {
        guard let key, artistCache?.key == key else { return nil }
        return artistCache?.name
    }

    /// 由播放态算出内容；与上次上屏内容相同则不动模板
    private func refresh() {
        let engine = PlayerEngine.shared
        let track = engine.currentTrack
        let lines = lyrics?.syncedLyrics ?? []
        // 位置走 nowPlayingElapsedTime（后台/锁屏可用的实时位置唯一入口），
        // 不读后台会冻结的 progress.playbackTime。
        // 延迟补偿：减掉「听到的比引擎时钟晚」的那一段（按当前输出路由取，见 LyricOffsetStore）；
        // 歌词行号与页头进度共用同一个时间，别各算一份
        let heardTime = engine.nowPlayingElapsedTime() - LyricOffsetStore.shared.effectiveOffset
        let activeIndex = LyricTiming.activeLineIndex(time: heardTime, in: lines)

        // 车载歌词：当前句写进系统「正在播放」信息的标题位（QQ 音乐同款做法）。
        // 系统屏由 CarPlay 接管、没有歌词控件，这是唯一能让那一页出现歌词的办法。
        publishCarLyricsTitle(activeLineIndex: activeIndex, lines: lines)

        let content = CarPlayPlayerPageBuilder.content(
            track: track.map {
                CarPlayPlayerPageTrackInfo(
                    key: $0.stableId,
                    title: $0.title,
                    artist: cachedArtist(for: $0.stableId)
                )
            },
            playback: CarPlayPlayerPagePlaybackState(
                isPlaying: engine.isPlaying,
                playOrderMode: engine.playbackOrderMode,
                elapsed: heardTime,
                duration: engine.duration
            ),
            lyrics: lyrics,
            isLoading: isLoadingLyrics,
            activeLineIndex: activeIndex,
            showRoman: showRoman
        )

        apply(content)
    }

    /// 车载歌词：把当前句写进系统「正在播放」标题位（变化才写，避免 0.5s tick 反复改元数据）。
    /// 写入动作仍只有一处——本层只给覆盖值，然后让播放器重建一次元数据（保留封面/时长）。
    private func publishCarLyricsTitle(activeLineIndex: Int?, lines: [LyricsLine]) {
        let line = CarPlayLyricsBuilder.currentLineText(lines, activeLineIndex: activeLineIndex)
        guard line != appliedCarLyricsTitle else { return }
        appliedCarLyricsTitle = line
        NowPlayingTitleOverlay.title = line
        PlayerEngine.shared.updateNowPlayingInfoEnhanced()
    }

    /// 断开连接/停止时撤掉覆盖，让锁屏与控制中心回到曲名
    private func clearCarLyricsTitle() {
        guard appliedCarLyricsTitle != nil else { return }
        appliedCarLyricsTitle = nil
        NowPlayingTitleOverlay.title = nil
        PlayerEngine.shared.updateNowPlayingInfoEnhanced()
    }

    private func apply(_ content: CarPlayPlayerPageContent) {
        if content.rows != appliedRows || content.placeholder != appliedPlaceholder {
            applyRows(content)
        }

        let headerChanged = content.header != appliedHeader
        if headerChanged || headerNeedsArtwork(content.header) {
            applyHeader(content.header)
        }
    }

    /// 页头是否需要因封面变化重建：封面已出结果、且页头用的还不是这一份
    private func headerNeedsArtwork(_ header: CarPlayPlayerPageHeader?) -> Bool {
        guard let header, let artworkKey = header.artworkKey else { return false }
        guard loadedArtworkKey == artworkKey else { return false }
        return appliedArtworkKey != artworkKey
    }

    // MARK: - 上屏

    private func applyRows(_ content: CarPlayPlayerPageContent) {
        appliedRows = content.rows
        appliedPlaceholder = content.placeholder

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
            // 副行：有罗马音给罗马音（乘客跟唱/跟读更需要），否则退回译文（中文歌等行为不变）
            let item = CPListItem(text: row.text, detailText: row.roman ?? row.translation)
            item.isPlaying = row.isPlaying
            item.playingIndicatorLocation = .trailing
            // 不设 handler：歌词行不可点，避免行车中误触跳播
            return item
        }

        // 有页头时曲名在页头上；没有页头的系统（iOS 26.4 以下）把曲名回落成小节标题
        let sectionHeader = supportsDetailsHeader ? nil : header.title
        template.updateSections([CPListSection(items: items, header: sectionHeader, sectionIndexTitle: nil)])
    }

    private func applyHeader(_ header: CarPlayPlayerPageHeader?) {
        // 页头 API 是 iOS 26.4 起才有的（见文件头）；低于此版本页面退化成三行歌词
        if #available(iOS 26.4, *) {
            applyDetailsHeader(header)
        }
    }

    @available(iOS 26.4, *)
    private func applyDetailsHeader(_ header: CarPlayPlayerPageHeader?) {
        guard let header else {
            template.listHeader = nil
            appliedHeader = nil
            appliedArtworkKey = nil
            return
        }

        let artworkSettled = (loadedArtworkKey == header.artworkKey)
        let image = artworkSettled ? artwork : nil
        let thumbnail = CPThumbnailImage(image: headerThumbnail(artwork: image, progress: header.progress))

        let details = CPListTemplateDetailsHeader(
            thumbnail: thumbnail,
            title: header.title,
            subtitle: header.subtitle,
            actionButtons: controlButtons(for: header)
        )
        // 页头背景由封面派生（与车载播放页的观感一致）；系统自适应日夜
        details.wantsAdaptiveBackgroundStyle = true
        template.listHeader = details

        appliedHeader = header
        // 封面出结果后才置位：出结果前不置位 → 图到了会重建一次页头；之后不再按 tick 重建
        appliedArtworkKey = artworkSettled ? header.artworkKey : nil
    }

    private var supportsDetailsHeader: Bool {
        if #available(iOS 26.4, *) { return true }
        return false
    }

    // MARK: - 控制键

    /// 页头控制键：上一首 / 播放暂停 / 下一首 / 播放顺序（顺序四态与 iOS 播放页同一入口）
    private func controlButtons(for header: CarPlayPlayerPageHeader) -> [CPButton] {
        var buttons: [CPButton] = []

        if let image = UIImage(systemName: "backward.fill") {
            buttons.append(CPButton(image: image) { [weak self] _ in self?.handlePrevious() })
        }
        if let image = UIImage(systemName: header.isPlaying ? "pause.fill" : "play.fill") {
            buttons.append(CPButton(image: image) { [weak self] _ in self?.handlePlayPause() })
        }
        if let image = UIImage(systemName: "forward.fill") {
            buttons.append(CPButton(image: image) { [weak self] _ in self?.handleNext() })
        }
        if let image = UIImage(systemName: header.playOrderMode.systemImageName) {
            buttons.append(CPButton(image: image) { [weak self] _ in self?.handlePlayOrder() })
        }

        if #available(iOS 26.4, *) {
            // 上限是运行时值（Apple 文档：超出的按钮会被忽略）→ 自己先裁剪并打日志，
            // 别赌系统丢弃，也别让多余按钮把页头挤崩
            let maxCount = CPListTemplateDetailsHeader.maximumActionButtonCount
            if maxCount > 0, buttons.count > maxCount {
                print("⚠️ CarPlay 播放页页头动作按钮上限 \(maxCount)：已裁剪 \(buttons.count - maxCount) 个")
                buttons = Array(buttons.prefix(maxCount))
            }
        }
        return buttons
    }

    private func handlePlayPause() {
        let engine = PlayerEngine.shared
        if engine.isPlaying {
            engine.pause()
        } else {
            engine.play()
        }
        refresh()
    }

    private func handleNext() {
        // 与车机/控制中心的 next 语义一致：保持原播放态（暂停时不自动开播）
        let shouldAutoplay = PlayerEngine.shared.isPlaying
        Task { @MainActor [weak self] in
            await PlayerEngine.shared.nextTrack(autoplay: shouldAutoplay)
            self?.refresh()
        }
    }

    private func handlePrevious() {
        let shouldAutoplay = PlayerEngine.shared.isPlaying
        Task { @MainActor [weak self] in
            await PlayerEngine.shared.previousTrack(autoplay: shouldAutoplay)
            self?.refresh()
        }
    }

    private func handlePlayOrder() {
        PlayerEngine.shared.cyclePlaybackOrderMode()
        refresh()
    }

    // MARK: - 封面绘制

    /// 页头缩略图：封面（或占位）+ 底部进度条与时间文案。
    /// CarPlay 列表模板没有滑块/进度控件，进度只能自绘进封面里（只读，不可拖动）。
    private func headerThumbnail(artwork: UIImage?, progress: CarPlayPlayerPageProgress?) -> UIImage {
        let side = playerPageThumbnailSide
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            if let artwork {
                drawAspectFill(artwork, in: rect)
            } else {
                drawPlaceholderFill(in: rect)
            }
            if let progress {
                drawProgressFooter(progress, in: rect)
            }
        }
    }

    /// 封面未就绪时的占位填充（页头条目要求缩略图非空）
    private func drawPlaceholderFill(in rect: CGRect) {
        UIColor.systemGray5.setFill()
        UIRectFill(rect)

        guard let note = UIImage(systemName: "music.note")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: rect.width * 0.3, weight: .medium)
        ) else { return }
        let noteRect = CGRect(
            x: rect.midX - note.size.width / 2,
            y: rect.midY - note.size.height / 2,
            width: note.size.width,
            height: note.size.height
        )
        note.withTintColor(.systemGray3, renderingMode: .alwaysOriginal).draw(in: noteRect)
    }

    /// 底部压暗 + 进度条 + 「已播 / 总长」：任何封面上都读得清
    private func drawProgressFooter(_ progress: CarPlayPlayerPageProgress, in rect: CGRect) {
        let side = rect.width
        let footerHeight = side * 0.22
        let footer = CGRect(x: 0, y: rect.maxY - footerHeight, width: side, height: footerHeight)
        UIColor.black.withAlphaComponent(0.42).setFill()
        UIRectFill(footer)

        let inset = side * 0.08
        let barHeight = side * 0.03
        let trackRect = CGRect(x: inset, y: footer.minY + footerHeight * 0.58, width: side - inset * 2, height: barHeight)
        UIColor.white.withAlphaComponent(0.28).setFill()
        UIBezierPath(roundedRect: trackRect, cornerRadius: barHeight / 2).fill()

        // 跑过的部分：至少留一个圆点，起始处也看得见
        let filledWidth = min(max(trackRect.width * CGFloat(progress.fraction), barHeight), trackRect.width)
        UIColor.white.setFill()
        UIBezierPath(
            roundedRect: CGRect(x: trackRect.minX, y: trackRect.minY, width: filledWidth, height: barHeight),
            cornerRadius: barHeight / 2
        ).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: side * 0.08, weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        let textY = footer.minY + footerHeight * 0.12
        (progress.elapsedText as NSString).draw(at: CGPoint(x: inset, y: textY), withAttributes: attributes)

        let totalText = progress.totalText as NSString
        let totalWidth = totalText.size(withAttributes: attributes).width
        totalText.draw(at: CGPoint(x: rect.maxX - inset - totalWidth, y: textY), withAttributes: attributes)
    }
}

// MARK: - 封面绘制

/// 播放页页头缩略图边长（页头是大图，不能用 CPListItem.maximumImageSize 那个列表尺寸）
private let playerPageThumbnailSide = 512.0

/// 播放页页头缩略图：封面按 aspect-fill 画进正方形。
/// 填充规则复用列表页的 drawAspectFill（同一套「封面怎么裁」只有一份实现）。
@MainActor
private func resizeArtworkForPlayerPage(_ image: UIImage) -> UIImage {
    let side = playerPageThumbnailSide
    let target = CGSize(width: side, height: side)
    return UIGraphicsImageRenderer(size: target).image { _ in
        drawAspectFill(image, in: CGRect(origin: .zero, size: target))
    }
}
