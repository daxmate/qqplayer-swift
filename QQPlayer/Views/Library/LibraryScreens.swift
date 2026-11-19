import Combine
import GRDB
import SwiftUI

struct AllSongsScreen: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    let tracks: [Track]
    /// 定位目标（mini 播放条长按带入）：nil = 普通进入，不滚动、不 toast
    var locateTrackId: String?
    @Environment(AppCoordinator.self) private var appCoordinator
    @State private var settings = DeleteSettings.load()
    /// 定位 toast（进入本页时短暂提示「已定位到当前播放」）
    @State private var showLocateToast = false

    var body: some View {
        TrackListView(tracks: tracks, listIdentifier: "all_songs", locateTrackId: locateTrackId)
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
            .overlay(alignment: .top) {
                if showLocateToast {
                    Text(Localized.locateCurrentTrackToast)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, DesignTokens.space12)
                        .padding(.vertical, DesignTokens.space8)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .padding(.top, DesignTokens.space8)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showLocateToast)
            .task(id: locateTrackId) {
                guard locateTrackId != nil else { return }
                showLocateToast = true
                // 2 秒后收起；连续定位会重开本 task，旧计时随取消结束
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                showLocateToast = false
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
    @Environment(AppCoordinator.self) private var appCoordinator
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
            AppLog.error(.ui, "Failed to load liked tracks: \(error)")
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
