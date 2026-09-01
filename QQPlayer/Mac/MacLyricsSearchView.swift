//
//  MacLyricsSearchView.swift
//  QQPlayer
//
//  macOS 歌词搜索页（sheet 形式）：双源搜索（网易云 + lrclib）候选列表，
//  用户手动挑选；选中后持久化为该歌曲的手动指定歌词。
//  对齐 iOS LyricsSearchView 功能，交互改为 macOS sheet（无滑入手势）。
//

import SwiftUI

struct MacLyricsSearchView: View {
    let track: Track
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
        _searchTitle = State(initialValue: track.title)
        // 歌手名预填在 onAppear 的 Task 里异步读（对齐 iOS，避免 init 阻塞）
        _searchArtist = State(initialValue: "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
                .padding(.horizontal, 20)
                .padding(.top, 8)

            if manualActive {
                manualStatusRow
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            if !searchError.isEmpty {
                Text(searchError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }

            content
                .padding(.top, 12)
        }
        .frame(minWidth: 520, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        // 首次进入的手势提示气泡：顶部浮层（卡片自身不拦截卡片外区域）
        .overlay(alignment: .top) {
            if showHint {
                HintCardView(
                    title: Localized.hintSearchTitle,
                    lines: [Localized.hintSearchMacLine1],
                    accentColor: .accentColor,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showHint = false
                        }
                    }
                )
                .padding(.top, 56)
                .padding(.horizontal, 20)
            }
        }
        .onAppear {
            // 首次进入歌词搜索页：触发提示气泡（之后永不再现）
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
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("lyrics_search_close".localized)

            VStack(alignment: .leading, spacing: 2) {
                Text("lyrics_search_title".localized)
                    .font(.headline)
                Text(track.title)
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
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            TextField("lyrics_search_song_title".localized, text: $searchTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit { doSearch() }

            TextField("lyrics_search_artist".localized, text: $searchArtist)
                .textFieldStyle(.roundedBorder)
                .onSubmit { doSearch() }

            Button(action: doSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .disabled(searching)
            .opacity(searching ? 0.5 : 1)
            .help("lyrics_search_button".localized)
        }
    }

    // MARK: - Manual Status

    private var manualStatusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.accentColor)

            Text("lyrics_search_manual_active".localized)
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
                Text("lyrics_search_restore_auto".localized)
                    .font(.footnote.weight(.medium))
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if searching && results.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("lyrics_search_searching".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else if searched && results.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "text.badge.xmark")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text("lyrics_search_no_results".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else {
            resultList
        }
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, candidate in
                    resultRow(candidate, at: index)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private func resultRow(_ candidate: LyricsSearchCandidate, at index: Int) -> some View {
        Button {
            apply(candidate, at: index)
        } label: {
            HStack(spacing: 12) {
                // 来源标签
                Text(candidate.source.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(sourceColor(candidate.source), in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if !candidate.artist.isEmpty {
                        Text(candidate.artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if candidate.tlyric != nil {
                    Text("lyrics_search_translation_badge".localized)
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                        )
                        .help("lyrics_search_has_translation".localized)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            searchError = "lyrics_search_enter_title".localized
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
            applyingIndex = nil
            if let lyrics {
                manualActive = true
                onApply(lyrics)
            } else {
                searchError = "lyrics_search_apply_failed".localized
            }
        }
    }
}
