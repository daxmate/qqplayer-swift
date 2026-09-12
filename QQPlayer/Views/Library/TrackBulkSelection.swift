//
//  TrackBulkSelection.swift
//  QQPlayer
//
//  Shared multi-select behaviour for track lists.
//
//  All Songs and Liked Songs grew this inline inside TrackListView. Album and
//  artist detail pages embed their song lists as sections of a larger
//  ScrollView (with disc grouping, track numbers and artwork rows), so they
//  cannot simply reuse TrackListView - but they should still offer the same
//  actions. The toolbar, action sheets and bulk operations live here so all
//  three lists stay in step.
//

import SwiftUI

/// Supplies the selection toolbar, the "add to playlist" sheet and the delete
/// confirmation for a list that supports multi-select.
struct TrackBulkActionsModifier: ViewModifier {
    /// Candidates for "Select All" - the tracks currently shown by the list.
    let tracks: [Track]
    @Binding var isBulkMode: Bool
    @Binding var selectedTracks: Set<String>
    /// Liked Songs phrases the favourite action as "remove" rather than "add".
    let isLikedContext: Bool

    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var showPlaylistDialog = false
    @State private var showDeleteConfirmation = false
    @State private var settings = DeleteSettings.load()

    func body(content: Content) -> some View {
        content
            .toolbar {
                if isBulkMode {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(Localized.cancel) { exitBulkMode() }
                            .foregroundColor(settings.backgroundColorChoice.color)
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button(action: { selectAll() }) {
                                Label(Localized.selectAll, systemImage: "checkmark.circle")
                            }
                            Divider()
                            Button(action: { bulkSetLiked() }) {
                                Label(
                                    isLikedContext ? Localized.removeFromLiked : Localized.addToLiked,
                                    systemImage: "heart.fill"
                                )
                            }
                            .disabled(selectedTracks.isEmpty)

                            Button(action: { showPlaylistDialog = true }) {
                                Label(Localized.addToPlaylist, systemImage: "music.note.list")
                            }
                            .disabled(selectedTracks.isEmpty)
                            Divider()
                            Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                                Label(Localized.deleteFiles, systemImage: "trash")
                            }
                            .disabled(selectedTracks.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundColor(settings.backgroundColorChoice.color)
                                .padding(4)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                    }
                }
            }
            .sheet(isPresented: $showPlaylistDialog) {
                BulkPlaylistSelectionView(
                    trackIds: Array(selectedTracks),
                    onComplete: { exitBulkMode() }
                )
                .accentColor(settings.backgroundColorChoice.color)
            }
            .alert(Localized.deleteFilesConfirmation, isPresented: $showDeleteConfirmation) {
                Button(Localized.delete, role: .destructive) { bulkDelete() }
                Button(Localized.cancel, role: .cancel) { }
            } message: {
                Text(Localized.deleteFilesConfirmationMessage(selectedTracks.count))
            }
            .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
                settings = DeleteSettings.load()
            }
    }

    private func exitBulkMode() {
        isBulkMode = false
        selectedTracks.removeAll()
    }

    private func selectAll() {
        selectedTracks = Set(tracks.map { $0.stableId })
    }

    /// 批量收藏：文案即目标状态（「加入喜欢」= 全部设为已喜欢），幂等，不是逐曲取反。
    private func bulkSetLiked() {
        let selected = orderedSelection()
        let desired = FavoriteBatchLogic.desiredState(isLikedContext: isLikedContext)
        _ = try? appCoordinator.setFavorites(trackStableIds: selected.map(\.stableId), isFavorite: desired)
        exitBulkMode()
    }

    /// 选中曲目（按列表顺序，保持稳定；顺带避免逐个 O(n) first(where:)）
    private func orderedSelection() -> [Track] {
        let tracksByStableId = Dictionary(tracks.map { ($0.stableId, $0) }, uniquingKeysWith: { first, _ in first })
        return selectedTracks.compactMap { tracksByStableId[$0] }
    }

    private func bulkDelete() {
        Task {
            let deleteSettings = DeleteSettings.load()
            for track in orderedSelection() {
                if deleteSettings.deleteFromLibraryOnly {
                    DeleteSettings.addExcludedTrack(track.stableId)
                } else {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: track.path))
                }
                try? DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("LibraryNeedsRefresh"),
                object: nil
            )
            exitBulkMode()
        }
    }
}

extension View {
    /// Adds the shared selection toolbar and bulk actions to a track list.
    func trackBulkActions(
        tracks: [Track],
        isBulkMode: Binding<Bool>,
        selectedTracks: Binding<Set<String>>,
        isLikedContext: Bool = false
    ) -> some View {
        modifier(
            TrackBulkActionsModifier(
                tracks: tracks,
                isBulkMode: isBulkMode,
                selectedTracks: selectedTracks,
                isLikedContext: isLikedContext
            )
        )
    }
}

/// The leading checkmark shown on a track row while selecting. Kept here so the
/// album and artist rows present selection identically to the library list,
/// including a full-size tap target on the checkmark itself.
struct TrackSelectionIndicator: View {
    let isSelected: Bool
    let accentColor: Color
    var onTap: (() -> Void)?

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundColor(isSelected ? accentColor : .secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
    }
}
