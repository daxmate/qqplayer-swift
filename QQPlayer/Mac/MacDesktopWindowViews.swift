//
//  MacDesktopWindowViews.swift
//  QQPlayer
//
//  桌面浮窗内容视图（E3→v2；QQPlayerMac target only）：
//  - MacMiniPlayerView：迷你播放器（web mini.html 语义）——封面 + 标题/歌手 +
//    上一首/播放暂停/下一首 + 进度滑杆（拖动 seek）+ 桌面歌词开关；
//    点封面/标题 = 返回主窗（v2：迷你模式与主窗互斥，封面是唯一显式出口）
//  - MacDesktopLyricView：桌面歌词（web desktop-lyric.html 语义）——当前句大字 +
//    译文行（跟随「歌词」分类译文偏好），字号读 DeleteSettings.desktopLyricFontSize；
//    无歌词/无播放时占位不打扰
//
//  两视图都由 DesktopWindowsManager 置于透明无边框置顶 NSPanel 中；
//  数据源：PlayerEngine.shared + KaraokeController.shared（主窗播放时注入歌词，
//  桌面歌词仅在有歌词注入时显示内容）。v2：桌面歌词只存在于迷你模式（主窗态
//  歌词在窗内面板，不产生桌面歌词）；显隐收敛见 MacDesktopWindowsManager。
//

import AppKit
import SwiftUI

// MARK: - 迷你播放器窗

struct MacMiniPlayerView: View {
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor
    @Environment(PlayerEngine.self) private var player
    /// 桌面浮窗管理器（歌词按钮点亮态 = isLyricVisible；批 5b 起由浮窗装配点注入，读属性追踪）
    @Environment(DesktopWindowsManager.self) private var desktopWindows
    /// 「封面毛玻璃背景」开关（键与默认值的唯一来源见 `PlayerGlassBackground`）
    @AppStorage(PlayerGlassBackground.storageKey) private var glassEnabled = PlayerGlassBackground.enabledByDefault
    /// 系统「降低透明度」：开启时回落 `.ultraThinMaterial` 原样
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// 封面来源（玻璃模式下模糊底的图；经浮窗装配点注入的 AppServices 取）
    @Environment(AppServices.self) private var services
    @State private var artwork: ArtworkImage?
    @State private var artworkTrackId: String?
    /// 当前曲目歌手名（Track 无 artist 冗余字段，按 stableId 查库解析）
    @State private var artistName = ""
    /// 拖动进度条中的暂存值（松手才 seek）
    @State private var scrubValue: Double = 0
    @State private var scrubbing = false
    /// 本视图是否已在光标栈上压入 pointingHand（审计 L2：push/pop 成对健壮性）
    @State private var cursorPushed = false

    private var duration: TimeInterval {
        player.duration > 0 ? player.duration : 1
    }

    /// 生效判定走唯一实现；浮窗没有「当前曲目封面」这个前置条件 ⇒ hasArtwork 传 true
    /// （与主窗 / 设置窗 / sheet 同口径）。
    private var glassActive: Bool {
        PlayerGlassBackground.isActive(
            isEnabled: glassEnabled,
            hasArtwork: true,
            reduceTransparency: reduceTransparency
        )
    }

    var body: some View {
        HStack(spacing: DesignTokens.space12) {
            // 封面（点击返回主窗——v2 迷你模式与主窗互斥，封面是返回出口；
            // hover 手型提示可点击）
            Button {
                desktopWindows.showMainWindow()
            } label: {
                MacArtworkThumbnail(track: player.currentTrack, size: 76, cornerRadius: DesignTokens.radius8)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                updateCursor(hovering: hovering)
            }

            VStack(alignment: .leading, spacing: DesignTokens.space6) {
                // 标题 / 歌手（点击返回主窗，hover 手型同封面）
                Button {
                    desktopWindows.showMainWindow()
                } label: {
                    VStack(alignment: .leading, spacing: DesignTokens.space2) {
                        Text(player.currentTrack?.displayTitle ?? "mini_window_no_track".localized)
                            .font(.system(size: DesignTokens.font13, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(artistName)
                            .font(.system(size: DesignTokens.font12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    updateCursor(hovering: hovering)
                }

                // 进度滑杆（0.25s 刷新；拖动中冻结值，松手 seek）
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    Slider(
                        value: Binding(
                            get: { scrubbing ? scrubValue : min(player.playbackTime, duration) },
                            set: { scrubValue = $0 }
                        ),
                        in: 0 ... duration
                    ) { editing in
                        scrubbing = editing
                        if !editing {
                            let target = scrubValue
                            Task { @MainActor in await player.seek(to: target) }
                        }
                    }
                    .controlSize(.mini)
                    .disabled(player.currentTrack == nil)
                }

                HStack(spacing: DesignTokens.space12) {
                    controlButton("backward.fill", size: 15) {
                        Task { @MainActor in await player.previousTrack() }
                    }
                    controlButton(
                        player.isPlaying ? "pause.fill" : "play.fill",
                        size: 20,
                        accent: appAccentColor
                    ) {
                        if player.isPlaying {
                            player.pause()
                        } else {
                            player.play()
                        }
                    }
                    controlButton("forward.fill", size: 15) {
                        Task { @MainActor in await player.nextTrack() }
                    }
                    Spacer()
                    // 桌面歌词开关（点亮 = 歌词窗可见；只写设置，收敛在管理器）
                    controlButton(
                        "quote.bubble",
                        size: 14,
                        accent: desktopWindows.isLyricVisible ? appAccentColor : nil
                    ) {
                        desktopWindows.setMiniLyricsEnabled(!DeleteSettings.load().miniLyricsEnabled)
                    }
                    .help("mini_lyrics_enabled".localized)
                }
                .padding(.top, DesignTokens.space2)
            }
            Spacer(minLength: DesignTokens.space0)
        }
        .padding(DesignTokens.space12)
        // 玻璃生效 → 封面模糊底（与主窗同一配方 `MacWindowGlass`，只换底色）；
        // 不生效 → 原 `.ultraThinMaterial` 圆角卡（逐像素还原）。
        .background {
            if glassActive {
                MacWindowGlass(artwork: artwork, cacheKey: artworkTrackId)
            } else {
                RoundedRectangle(cornerRadius: DesignTokens.radius16, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radius16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        // 圆角裁切提到内容根上（背景 / 内容 / 描边一起裁，半径与卡片同一个 radius16）：
        // `.compositingGroup()` 先把整棵子树合成一层再裁，否则毛玻璃层的 `.blur` / `.scaleEffect(1.15)`
        // 越界部分会从圆角外漏出来（真机表现为「迷你窗变硬角」）。
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius16, style: .continuous))
        .task(id: player.currentTrack?.stableId) {
            guard let track = player.currentTrack else {
                artistName = ""
                artwork = nil
                artworkTrackId = nil
                return
            }
            artistName = (try? LibraryReads.artistDisplayName(
                forTrackStableId: track.stableId,
                fallbackArtistId: track.artistId
            )) ?? ""
            await loadArtwork(for: track)
        }
        // 光标栈兜底（审计 L2）：面板被 orderOut/视图被卸载时 onHover(false) 可能不送达，
        // 若不弹出则整个 App 后续任意窗口都会显示手型光标
        .onDisappear {
            updateCursor(hovering: false)
        }
        // 整窗拖动（隐式背景拖动在新系统上实测失效，见 macWindowDragGesture）
        .macWindowDragGesture()
    }

    /// 拉取曲目封面（切歌后旧结果丢弃）——与设置窗 / sheet 同一路径。
    private func loadArtwork(for track: Track) async {
        let trackId = track.stableId
        let image = await services.artworkManager.getArtwork(for: track)
        guard player.currentTrack?.stableId == trackId else { return }
        artwork = image
        artworkTrackId = trackId
    }

    /// hover 手型光标（审计 L2）：用标志记录栈上是否有本视图压入的一项，
    /// 保证 push/pop 严格成对（重复 hover(true) / 孤立 hover(false) 都不会失衡）。
    private func updateCursor(hovering: Bool) {
        if hovering, !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        } else if !hovering, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    private func controlButton(
        _ systemImage: String,
        size: CGFloat,
        accent: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .foregroundColor(accent ?? .secondary)
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 桌面歌词窗

struct MacDesktopLyricView: View {
    @Environment(KaraokeController.self) private var karaoke
    @Environment(PlayerEngine.self) private var player
    /// 字号（设置页改动经 qqplayerSettingsDidChange 刷新）
    @State private var fontSize: Double = DeleteSettings.load().desktopLyricFontSize
    @State private var showTranslation = DeleteSettings.load().lyricShowTranslation
    @State private var showRoman = DeleteSettings.load().lyricShowRoman
    @State private var lyricOffset: Double = DeleteSettings.load().lyricOffset

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let index = LyricTiming.activeLineIndex(
                time: player.playbackTime - lyricOffset,
                in: karaoke.currentLines
            )
            content(line: index.map { karaoke.currentLines[$0] })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignTokens.space24)
        .padding(.vertical, DesignTokens.space12)
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            let settings = DeleteSettings.load()
            fontSize = settings.desktopLyricFontSize
            showTranslation = settings.lyricShowTranslation
            showRoman = settings.lyricShowRoman
            lyricOffset = settings.lyricOffset
        }
        // 整窗拖动（隐式背景拖动在新系统上实测失效，见 macWindowDragGesture）
        .macWindowDragGesture()
    }

    @ViewBuilder
    private func content(line: LyricsLine?) -> some View {
        VStack(spacing: DesignTokens.space6) {
            if let line {
                Text(line.displayText)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                if showRoman, let roman = line.displayRoman, !roman.isEmpty {
                    Text(roman)
                        .font(.system(size: fontSize * 0.45, weight: .regular))
                        .foregroundColor(.white.opacity(0.72))
                        .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                }
                if showTranslation, let translation = line.displayTranslation, !translation.isEmpty {
                    Text(translation)
                        .font(.system(size: fontSize * 0.55, weight: .regular))
                        .foregroundColor(.white.opacity(0.8))
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                }
            } else {
                // 无歌词/前奏无句：弱占位，不打扰
                Text("♪")
                    .font(.system(size: fontSize * 0.7))
                    .foregroundColor(.white.opacity(0.12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 浮窗整窗拖动

extension View {
    /// 给无边框 `NSPanel` 的内容根加上「拖整窗」能力。
    ///
    /// 迷你播放窗 / 桌面歌词窗原本只靠 `isMovableByWindowBackground = true`
    /// 这条 AppKit 隐式背景拖动机制；实测在 macOS 27.2.1（xmini）上两个浮窗
    /// 完全拖不动，同一 App 在 macOS 27.0.1（xhome）上正常 —— 隐式机制在新系统上
    /// 不可靠，所以在内容根显式叠加 SwiftUI 原生 `WindowDragGesture`。
    ///
    /// - 用普通 `.gesture` 而不是 `highPriorityGesture`：子控件（封面返回主窗、
    ///   上一首/播放/下一首）的手势优先，按钮照旧可点。
    /// - deployment target 是 macOS 14.0，`WindowDragGesture` 只有 macOS 15+ 才有
    ///   → `#available` 兜底：低版本原样返回，继续走 `isMovableByWindowBackground`
    ///   的旧路径（两者叠加不冲突）。
    @ViewBuilder
    func macWindowDragGesture() -> some View {
        if #available(macOS 15.0, *) {
            gesture(WindowDragGesture())
        } else {
            self
        }
    }
}
