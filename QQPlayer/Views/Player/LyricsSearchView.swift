//
//  LyricsSearchView.swift
//  QQPlayer
//
//  歌词搜索页：小歌词窗口右滑从左侧滑入。
//  双源搜索（网易云 + lrclib）候选列表，用户手动挑选；选中后持久化为该歌曲的手动指定歌词。
//  背景与全屏歌词页一致（不透明系统底色 + 媒体库同款光晕），交互参考桌面版 LyricSpecModal。
//

import SwiftUI

struct LyricsSearchView: View {
    let track: Track
    /// App 强调色（读环境值；根注入见 ContentView）
    @Environment(\.appAccentColor) private var accentColor
    let onClose: () -> Void
    /// 应用搜索结果（选中候选）或恢复自动（nil）；由外层负责刷新歌词显示
    let onApply: (Lyrics?) -> Void

    @State private var searchTitle: String
    @State private var searchArtist: String
    @State private var searching = false
    @State private var searched = false
    @State private var searchError = ""
    @State private var results: [LyricsSearchCandidate] = []
    @State private var applyingIndex: Int?
    @State private var manualActive = false
    @State private var dragX: CGFloat = 0
    /// 首次进入歌词搜索页的手势提示气泡
    @State private var showHint = false

    init(
        track: Track,
        onClose: @escaping () -> Void,
        onApply: @escaping (Lyrics?) -> Void
    ) {
        self.track = track
        self.onClose = onClose
        self.onApply = onApply
        // 显示值≠查询值：这里是发给网易云/lrclib 的查询串（按 UI 语言转字形会降低命中率），保持原文
        _searchTitle = State(initialValue: track.title)
        // 歌手名预填原本在 init 内同步 DB 读（阻塞初始化），改到 onAppear 的 Task 里
        _searchArtist = State(initialValue: "")
    }

    var body: some View {
        ZStack {
            // 不透明底色：不透出下层播放页封面（歌词页同款做法）
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            // 媒体库同款背景光晕（跟随设置主题色变化）
            ScreenSpecificBackgroundView(screen: .library)
                .ignoresSafeArea()

            VStack(spacing: DesignTokens.space0) {
                header
                searchBar
                    .padding(.horizontal, DesignTokens.space20)
                    .padding(.top, DesignTokens.space8)

                if manualActive {
                    manualStatusRow
                        .padding(.horizontal, DesignTokens.space20)
                        .padding(.top, DesignTokens.space12)
                }

                if !searchError.isEmpty {
                    Text(searchError)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding(.horizontal, DesignTokens.space20)
                        .padding(.top, DesignTokens.space10)
                }

                content
                    .padding(.top, DesignTokens.space12)
            }
        }
        .onAppear {
            // 首次进入歌词搜索页：触发手势提示气泡（之后永不再现）
            withAnimation(.easeOut(duration: 0.3)) {
                showHint = HintCoordinator.showIfNeeded(.lyricsSearchPage)
            }
            Task {
                manualActive = await LyricsManager.shared.hasManualLyrics(for: track)
                // 预填歌手名（原 init 内同步 DB 读挪到这里；先填再搜，首次自动搜索带歌手过滤）
                let artistName: String = {
                    guard let artistId = track.artistId,
                          let artist = try? DatabaseManager.shared.read({ db in
                              try Artist.fetchOne(db, key: artistId)
                          }) else {
                        return ""
                    }
                    return artist.name
                }()
                if !artistName.isEmpty {
                    searchArtist = artistName
                }
                // 进入页面自动搜索当前歌曲（预填关键词），用户可改词再搜
                doSearch()
            }
        }
        // 左滑关闭：跟手位移，达阈值/快速回甩滑出（与全屏歌词页右滑关闭同款，方向镜像）。
        // simultaneousGesture：结果列表是 ScrollView，普通 .gesture 优先级低于子视图，
        // 列表区域左滑会被滚动视图吃掉（只有空白区能滑）；simultaneous 与列表互不取消——
        // 纵向滚动正常、左滑关闭仍可用（与 LyricsView 同款模式）。
        .offset(x: dragX)
        // 首次进入的手势提示气泡：顶部浮层（卡片自身不拦截卡片外区域）
        .overlay(alignment: .top) {
            if showHint {
                HintCardView(
                    title: Localized.hintSearchTitle,
                    lines: [Localized.hintSearchLine1],
                    accentColor: accentColor,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showHint = false
                        }
                    }
                )
                .padding(.top, DesignTokens.space64)
                .padding(.horizontal, DesignTokens.space20)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    guard value.translation.width < 0 else { return }
                    dragX = value.translation.width
                }
                .onEnded { value in
                    if PlayerDismissGesture.shouldDismissLyricsSearch(
                        translation: value.translation.width,
                        predictedTranslation: value.predictedEndTranslation.width
                    ) {
                        onClose()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dragX = 0
                        }
                    }
                }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.space12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: DesignTokens.font17, weight: .semibold))
                    .foregroundColor(accentColor)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(NSLocalizedString("lyrics_search_close", value: "Close lyrics search", comment: ""))

            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(NSLocalizedString("lyrics_search_title", value: "Lyrics Search", comment: ""))
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(track.displayTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if searching {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(.horizontal, DesignTokens.space20)
        .padding(.top, DesignTokens.space8)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        VStack(spacing: DesignTokens.space10) {
            HStack(spacing: DesignTokens.space10) {
                TextField(NSLocalizedString("lyrics_search_song_title", value: "Song title", comment: ""), text: $searchTitle)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .padding(.horizontal, DesignTokens.space12)
                    .padding(.vertical, DesignTokens.space8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.radius10))
                    .submitLabel(.search)
                    .onSubmit { doSearch() }

                TextField(NSLocalizedString("lyrics_search_artist", value: "Artist (optional)", comment: ""), text: $searchArtist)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .padding(.horizontal, DesignTokens.space12)
                    .padding(.vertical, DesignTokens.space8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.radius10))
                    .submitLabel(.search)
                    .onSubmit { doSearch() }

                Button(action: doSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: DesignTokens.font15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(accentColor, in: RoundedRectangle(cornerRadius: DesignTokens.radius10))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(searching)
                .opacity(searching ? 0.5 : 1)
                .accessibilityLabel(NSLocalizedString("lyrics_search_button", value: "Search", comment: ""))
            }
        }
    }

    // MARK: - Manual Status

    private var manualStatusRow: some View {
        HStack(spacing: DesignTokens.space10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: DesignTokens.font14))
                .foregroundColor(accentColor)

            Text(NSLocalizedString("lyrics_search_manual_active", value: "Manual lyrics assigned", comment: ""))
                .font(.footnote)
                .foregroundColor(.secondary)

            Spacer()

            Button {
                Task {
                    await LyricsManager.shared.clearManualLyrics(for: track)
                    manualActive = false
                    onApply(nil) // 恢复自动：外层重新加载
                }
            } label: {
                Text(NSLocalizedString("lyrics_search_restore_auto", value: "Restore automatic", comment: ""))
                    .font(.footnote.weight(.medium))
                    .foregroundColor(accentColor)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, DesignTokens.space12)
        .padding(.vertical, DesignTokens.space10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DesignTokens.radius12))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if searching && results.isEmpty {
            VStack(spacing: DesignTokens.space12) {
                Spacer()
                ProgressView()
                Text(NSLocalizedString("lyrics_search_searching", value: "Searching…", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else if searched && results.isEmpty {
            VStack(spacing: DesignTokens.space12) {
                Spacer()
                Image(systemName: "text.badge.xmark")
                    .font(.system(size: DesignTokens.font36))
                    .foregroundColor(.secondary)
                Text(NSLocalizedString("lyrics_search_no_results", value: "No lyrics found. Try changing the title or artist", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else {
            resultList
        }
    }

    private var resultList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: DesignTokens.space10) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, candidate in
                    resultRow(candidate, at: index)
                }
            }
            .padding(.horizontal, DesignTokens.space20)
            .padding(.bottom, DesignTokens.space24)
        }
    }

    private func resultRow(_ candidate: LyricsSearchCandidate, at index: Int) -> some View {
        Button {
            apply(candidate, at: index)
        } label: {
            HStack(spacing: DesignTokens.space12) {
                // 来源标签
                Text(candidate.source.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, DesignTokens.space8)
                    .padding(.vertical, DesignTokens.space4)
                    .background(sourceColor(candidate.source), in: RoundedRectangle(cornerRadius: DesignTokens.radius6))

                VStack(alignment: .leading, spacing: DesignTokens.space4) {
                    // 候选行是渲染出来的歌曲文本（转字形只影响显示；id/source 等取歌词用字段不动）
                    Text(DisplayScriptNormalizer.display(candidate.title))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if !candidate.artist.isEmpty {
                        Text(DisplayScriptNormalizer.display(candidate.artist))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if candidate.tlyric != nil {
                    Text(NSLocalizedString("lyrics_search_translation_badge", value: "TR", comment: ""))
                        .font(.caption2.weight(.bold))
                        .foregroundColor(accentColor)
                        .padding(.horizontal, DesignTokens.space6)
                        .padding(.vertical, DesignTokens.space4)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.radius6)
                                .stroke(accentColor.opacity(0.6), lineWidth: 1)
                        )
                        .accessibilityLabel(NSLocalizedString("lyrics_search_has_translation", value: "Contains translation", comment: ""))
                }

                if applyingIndex == index {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, DesignTokens.space14)
            .padding(.vertical, DesignTokens.space12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DesignTokens.radius12))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(applyingIndex != nil)
        .opacity(applyingIndex != nil && applyingIndex != index ? 0.6 : 1)
    }

    private func sourceColor(_ source: LyricsSearchCandidate.Source) -> Color {
        switch source {
        case .netease: return Color(red: 0.76, green: 0.05, blue: 0.05) // 网易云品牌红
        case .lrclib: return .blue
        }
    }

    // MARK: - Actions

    private func doSearch() {
        let title = searchTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            searchError = NSLocalizedString("lyrics_search_enter_title", value: "Please enter a song title", comment: "")
            return
        }
        guard !searching else { return }

        searchError = ""
        searched = false
        results = []
        searching = true
        let artist = searchArtist.trimmingCharacters(in: .whitespaces)

        Task {
            let candidates = await LyricsSearchProvider.shared.search(title: title, artist: artist)
            await MainActor.run {
                results = candidates
                searched = true
                searching = false
            }
        }
    }

    private func apply(_ candidate: LyricsSearchCandidate, at index: Int) {
        guard applyingIndex == nil else { return }
        applyingIndex = index
        searchError = ""

        Task {
            let lyrics = await LyricsManager.shared.apply(candidate: candidate, for: track)
            await MainActor.run {
                applyingIndex = nil
                if let lyrics {
                    manualActive = true
                    onApply(lyrics)
                } else {
                    searchError = NSLocalizedString("lyrics_search_apply_failed", value: "Failed to apply. Please try again", comment: "")
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    LyricsSearchView(
        track: Track(
            stableId: "preview",
            title: "花海",
            path: "/tmp/preview.flac"
        ),
        onClose: {},
        onApply: { _ in }
    )
    .environment(\.appAccentColor, .red)
}
