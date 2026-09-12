import GRDB
import SwiftUI
struct ArtistsScreen: View {
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var artists: [ArtistNameNormalizer.NormalizedArtist] = []
    @State private var settings = DeleteSettings.load()

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .artists)

            VStack {
                if artists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.2")
                            .font(.system(size: 40))
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

                                VStack(alignment: .leading, spacing: 4) {
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
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
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
                    .padding(.horizontal, 8)
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
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
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
