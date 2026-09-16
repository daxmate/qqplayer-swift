import Combine
import GRDB
import SwiftUI

struct AllSongsScreen: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    let tracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var settings = DeleteSettings.load()

    var body: some View {
        TrackListView(tracks: tracks, listIdentifier: "all_songs")
            .background(ScreenSpecificBackgroundView(screen: .allSongs))
            .navigationTitle(Localized.allSongs)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        shuffleAllSongs()
                    } label: {
                        Image(systemName: "shuffle")
                            .foregroundColor(accentColor)
                    }
                    .disabled(tracks.isEmpty)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
                settings = DeleteSettings.load()
            }
    }

    private func shuffleAllSongs() {
        guard !tracks.isEmpty else { return }
        let shuffled = tracks.shuffled()
        Task {
            await appCoordinator.playTrack(shuffled[0], queue: shuffled)
        }
    }
}

struct LikedSongsScreen: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var likedTracks: [Track] = []
    @State private var settings = DeleteSettings.load()

    var body: some View {
        TrackListView(tracks: likedTracks, listIdentifier: "liked_songs", isLikedSongsScreen: true)
            .background(ScreenSpecificBackgroundView(screen: .likedSongs))
            .navigationTitle(Localized.likedSongs)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        shuffleLikedSongs()
                    } label: {
                        Image(systemName: "shuffle")
                            .foregroundColor(accentColor)
                    }
                    .disabled(likedTracks.isEmpty)
                }
            }
            .onAppear {
                loadLikedTracks()
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
                loadLikedTracks()
            }
            .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
                settings = DeleteSettings.load()
            }
    }

    private func shuffleLikedSongs() {
        guard !likedTracks.isEmpty else { return }
        let shuffled = likedTracks.shuffled()
        Task {
            await appCoordinator.playTrack(shuffled[0], queue: shuffled)
        }
    }

    private func loadLikedTracks() {
        do {
            let favoriteIds = try appCoordinator.getFavorites()
            likedTracks = allTracks.filter { favoriteIds.contains($0.stableId) }
        } catch {
            print("Failed to load liked tracks: \(error)")
        }
    }
}

enum TrackSortOption: String, CaseIterable {
    case playlistOrder
    case dateNewest
    case dateOldest
    case nameAZ
    case nameZA
    case artistAZ
    case artistZA
    case sizeLargest
    case sizeSmallest

    var localizedString: String {
        switch self {
        case .playlistOrder: return "Manual Order"
        case .dateNewest: return Localized.sortDateNewest
        case .dateOldest: return Localized.sortDateOldest
        case .nameAZ: return Localized.sortNameAZ
        case .nameZA: return Localized.sortNameZA
        case .artistAZ: return "Artist A-Z"
        case .artistZA: return "Artist Z-A"
        case .sizeLargest: return Localized.sortSizeLargest
        case .sizeSmallest: return Localized.sortSizeSmallest
        }
    }
}
