//
//  SmartPlaylistCardView.swift
//  QQPlayer
//
//  Pinned card for one automatic playlist (自动歌单) on the playlist page.
//  Visually mirrors PlaylistCardView (square artwork area plus two text
//  lines) so the grid rows stay aligned, but carries no edit/delete
//  affordances — the smart cards are fixed and not user-editable.
//
//  SmartPlaylistUILogic holds the pure card decisions (icon / subtitle
//  mapping) so they can be unit-tested without localization or the database.
//

import SwiftUI

/// Pure UI decisions for the smart playlist cards.
enum SmartPlaylistUILogic {
    /// SF Symbol shown on the pinned card for each kind.
    static func iconName(for kind: SmartPlaylistKind) -> String {
        switch kind {
        case .recentAdded: return "clock"
        case .recentPlayed: return "history"
        case .topPlayed: return "flame"
        case .decades: return "calendar"
        }
    }

    /// 封面拼贴布局决策：0 张 → 图标；1-3 张 → 单封面；4 张 → 2×2 拼贴。
    static func coverLayout(artworkCount: Int) -> CoverLayout {
        switch artworkCount {
        case 0: return .icon
        case 1 ... 3: return .single
        default: return .grid2x2
        }
    }

    enum CoverLayout {
        case icon, single, grid2x2
    }

    /// Card badge: song count for track-based kinds, decade count for decades.
    /// Formatting is injected so the decision is testable without localization.
    static func cardSubtitle(
        kind: SmartPlaylistKind,
        count: Int,
        songsFormat: (Int) -> String,
        decadesFormat: (Int) -> String
    ) -> String {
        switch kind {
        case .decades:
            return decadesFormat(count)
        default:
            return songsFormat(count)
        }
    }
}

/// Pinned automatic-playlist card. `info.count` comes from
/// `SmartPlaylistStore.cardInfos()`; on failure the caller falls back to a
/// placeholder info with count 0 and the card still renders.
struct SmartPlaylistCardView: View {
    let info: SmartPlaylistCardInfo

    @Environment(AppServices.self) private var services
    @State private var artworks: [UIImage] = []
    @State private var didLoadCovers = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space8) {
            // Artwork area, matching PlaylistCardView's square artwork geometry.
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.radius12)
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(1, contentMode: .fit)

                switch SmartPlaylistUILogic.coverLayout(artworkCount: artworks.count) {
                case .icon:
                    Image(systemName: SmartPlaylistUILogic.iconName(for: info.kind))
                        .font(.system(size: DesignTokens.font40))
                        .foregroundColor(.secondary)
                case .single:
                    GeometryReader { geometry in
                        artworkView(at: 0, size: geometry.size.width)
                    }
                case .grid2x2:
                    GeometryReader { geometry in
                        let size = (geometry.size.width - 2) / 2
                        VStack(spacing: DesignTokens.space2) {
                            HStack(spacing: DesignTokens.space2) {
                                artworkView(at: 0, size: size)
                                artworkView(at: 1, size: size)
                            }
                            HStack(spacing: DesignTokens.space2) {
                                artworkView(at: 2, size: size)
                                artworkView(at: 3, size: size)
                            }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius12))
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.radius12))

            // Text info
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(Localized.smartPlaylistTitle(info.kind))
                    .font(.headline)
                    .lineLimit(1)

                Text(SmartPlaylistUILogic.cardSubtitle(
                    kind: info.kind,
                    count: info.count,
                    songsFormat: Localized.smartSongsCount,
                    decadesFormat: Localized.smartDecadeCount
                ))
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Localized.smartPlaylistTitle(info.kind))
        .accessibilityAddTraits(.isButton)
        .task {
            await loadCovers()
        }
    }

    @ViewBuilder
    private func artworkView(at index: Int, size: CGFloat) -> some View {
        if index < artworks.count {
            Image(uiImage: artworks[index])
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: artworks.count >= 4 ? DesignTokens.radius6 : DesignTokens.radius12))
        } else {
            RoundedRectangle(cornerRadius: artworks.count >= 4 ? DesignTokens.radius6 : DesignTokens.radius12)
                .fill(Color.gray.opacity(0.3))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundColor(.secondary)
                        .font(.system(size: size / 4))
                )
        }
    }

    private func loadCovers() async {
        guard !didLoadCovers else { return }
        didLoadCovers = true
        guard let tracks = try? SmartPlaylistStore.coverTracks(for: info.kind) else { return }
        var loaded: [UIImage] = []
        for track in tracks.prefix(4) {
            if let artwork = await services.artworkManager.getThumbnail(for: track, maxPixelSize: 256) {
                loaded.append(artwork)
            }
        }
        await MainActor.run {
            artworks = loaded
        }
    }
}
