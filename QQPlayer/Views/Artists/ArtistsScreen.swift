import GRDB
import SwiftUI
struct ArtistsScreen: View {
    let allTracks: [Track]
    @Environment(AppCoordinator.self) private var appCoordinator
    @State private var artists: [ArtistNameNormalizer.NormalizedArtist] = []
    @State private var settings = DeleteSettings.load()

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .artists)

            VStack {
                if artists.isEmpty {
                    VStack(spacing: DesignTokens.space16) {
                        Image(systemName: "person.2")
                            .font(.system(size: DesignTokens.font40))
                            .foregroundColor(.secondary)

                        Text(Localized.noArtistsFound)
                            .font(.headline)

                        Text(Localized.artistsWillAppear)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(artists, id: \.id) { item in
                        ZStack {
                            NavigationLink(destination: ArtistDetailScreen(artists: item.artists, allTracks: allTracks)) {
                                EmptyView()
                            }
                            .opacity(0.0)

                            HStack {
                                Image(systemName: "person")
                                    .foregroundColor(.purple)
                                    .frame(width: 24, height: 24)

                                VStack(alignment: .leading, spacing: DesignTokens.space4) {
                                    Text(item.displayName)
                                        .font(.headline)

                                    Text(Localized.artist)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, DesignTokens.space16)
                            .padding(.vertical, DesignTokens.space12)
                            .background(
                                RoundedRectangle(cornerRadius: DesignTokens.radius12)
                                    .fill(.ultraThinMaterial)
                                    .opacity(0.7)
                            )
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(PlainListStyle())
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, DesignTokens.space8)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 100) // Space for mini player
                    }
                }
            }
            .navigationTitle(Localized.artists)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadArtists()
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
                loadArtists()
            }
            .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
                settings = DeleteSettings.load()
            }
        }
    } // end body

    private func loadArtists() {
        do {
            let allArtists = try appCoordinator.databaseManager.getAllArtists()
            // 简繁归一：同名简繁两行按归一 key 分组，每组一个显示项
            artists = ArtistNameNormalizer.groupedArtists(allArtists)
        } catch {
            print("Failed to load artists: \(error)")
        }
    }
}
