import GRDB
import SwiftUI
#if canImport(FoundationModels)
    import FoundationModels
#endif
struct PlaylistsScreen: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    @Environment(AppCoordinator.self) private var appCoordinator
    @State private var playlists: [Playlist] = []
    /// 歌单 id → 曲目（loadPlaylists 时批量加载一次，替代网格每卡片每次 body 求值查库）
    @State private var playlistTracksCache: [Int64: [Track]] = [:]
    @State private var isEditMode: Bool = false
    @State private var playlistToEdit: Playlist?
    @State private var playlistToDelete: Playlist?
    @State private var showEditDialog = false
    @State private var showDeleteConfirmation = false
    @State private var editPlaylistName = ""
    @State private var showAIPlaylistSheet = false
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var smartCardInfos: [SmartPlaylistCardInfo] = []

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .playlists)

            VStack {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: DesignTokens.space8),
                        GridItem(.flexible(), spacing: DesignTokens.space8),
                    ], spacing: DesignTokens.space16) {
                        // Pinned automatic playlists — always visible (even with
                        // an empty library), never editable.
                        ForEach(smartCardInfos, id: \.kind) { info in
                            NavigationLink {
                                SmartPlaylistDetailScreen(kind: info.kind)
                            } label: {
                                SmartPlaylistCardView(info: info)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if !playlists.isEmpty {
                            ForEach(playlists, id: \.id) { playlist in
                                if isEditMode {
                                    PlaylistCardView(playlist: playlist, allTracks: playlistTracksCache[playlist.id ?? 0] ?? [], isEditMode: true, onEdit: {
                                        playlistToEdit = playlist
                                        editPlaylistName = playlist.title
                                        showEditDialog = true
                                    }, onDelete: {
                                        playlistToDelete = playlist
                                        showDeleteConfirmation = true
                                    })
                                } else {
                                    NavigationLink {
                                        PlaylistDetailScreen(playlist: playlist)
                                    } label: {
                                        PlaylistCardView(playlist: playlist, allTracks: playlistTracksCache[playlist.id ?? 0] ?? [])
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }

                            // Trailing "new playlist" tile, only while editing.
                            if isEditMode {
                                Button {
                                    newPlaylistName = ""
                                    showCreatePlaylist = true
                                } label: {
                                    NewPlaylistCardView()
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                    .padding(DesignTokens.space16)
                    .padding(.bottom, DesignTokens.space100) // Add padding for mini player

                    // Empty-library hint below the pinned smart cards.
                    if playlists.isEmpty {
                        VStack(spacing: DesignTokens.space16) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: DesignTokens.font40))
                                .foregroundColor(.secondary)

                            Text(Localized.noPlaylistsYet)
                                .font(.headline)

                            Text(Localized.createPlaylistsInstruction)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, DesignTokens.space24)
                        .padding(.bottom, DesignTokens.space100) // Add padding for mini player
                    }
                }
            }
            .navigationTitle(Localized.playlists)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isEditMode ? Localized.done : Localized.edit) {
                        withAnimation {
                            isEditMode.toggle()
                        }
                    }
                    .disabled(playlists.isEmpty)
                }
            }
            .alert(Localized.editPlaylist, isPresented: $showEditDialog) {
                TextField(Localized.playlistNamePlaceholder, text: $editPlaylistName)
                Button(Localized.save) {
                    if let playlist = playlistToEdit, !editPlaylistName.isEmpty {
                        editPlaylist(playlist, newName: editPlaylistName)
                    }
                }
                .disabled(editPlaylistName.isEmpty)
                Button(Localized.cancel, role: .cancel) { }
            } message: {
                Text(Localized.enterNewName)
            }
            .alert(Localized.createPlaylist, isPresented: $showCreatePlaylist) {
                TextField(Localized.playlistNamePlaceholder, text: $newPlaylistName)
                Button(Localized.create) {
                    createPlaylist()
                }
                .disabled(newPlaylistName.isEmpty)
                Button(Localized.cancel, role: .cancel) { }
            } message: {
                Text(Localized.enterPlaylistName)
            }
            .alert(Localized.deletePlaylist, isPresented: $showDeleteConfirmation) {
                Button(Localized.delete, role: .destructive) {
                    if let playlist = playlistToDelete {
                        deletePlaylist(playlist)
                    }
                }
                Button(Localized.cancel, role: .cancel) { }
            } message: {
                if let playlist = playlistToDelete {
                    Text(Localized.deletePlaylistConfirmation(playlist.title))
                }
            }
            .onAppear {
                loadPlaylists()
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
                loadPlaylists()
            }

            #if canImport(FoundationModels)
                if isAIAvailable {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                showAIPlaylistSheet = true
                            } label: {
                                Image(systemName: "wand.and.stars")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .frame(width: 56, height: 56)
                                    .background(Circle().fill(accentColor))
                                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                            }
                            .accessibilityLabel(Localized.aiPlaylistButton)
                            .padding(.trailing, DesignTokens.space20)
                            .padding(.bottom, DesignTokens.space110) // clear the mini player
                        }
                    }
                }
            #endif
        }
        .sheet(isPresented: $showAIPlaylistSheet) {
            #if canImport(FoundationModels)
                if #available(iOS 26.0, *) {
                    AIPlaylistSheet {
                        loadPlaylists()
                    }
                    .environment(appCoordinator)
                }
            #endif
        }
    }

    /// Only offer the AI playlist button when Apple Intelligence is actually
    /// usable on this device (model downloaded and enabled), not merely when
    /// the OS version supports it.
    private var isAIAvailable: Bool {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                if case .available = SystemLanguageModel.default.availability {
                    return true
                }
            }
        #endif
        return false
    }

    private func getAllPlaylistTracks(_ playlist: Playlist) -> [Track] {
        guard let playlistId = playlist.id else { return [] }
        do {
            let playlistItems = try appCoordinator.databaseManager.getPlaylistItems(playlistId: playlistId)
            let trackIds = playlistItems.map { $0.trackStableId }
            return try appCoordinator.databaseManager.getTracksByStableIdsPreservingOrder(trackIds)
        } catch {
            print("Failed to get playlist tracks: \(error)")
            return []
        }
    }

    private func loadPlaylists() {
        do {
            playlists = try appCoordinator.databaseManager.getAllPlaylists()
            // 批量取所有歌单的 tracks（替代网格里每张卡片各查两次 DB，且每次 body 求值重跑）
            var cache: [Int64: [Track]] = [:]
            for playlist in playlists {
                if let playlistId = playlist.id {
                    cache[playlistId] = getAllPlaylistTracks(playlist)
                }
            }
            playlistTracksCache = cache
        } catch {
            print("Failed to load playlists: \(error)")
        }
        // Pinned smart cards: keep showing entries even if the query fails
        // (count 0 placeholder), so the grid always has the four fixed cards.
        smartCardInfos = (try? SmartPlaylistStore.cardInfos()) ?? SmartPlaylistKind.allCases.map {
            SmartPlaylistCardInfo(kind: $0, title: $0.rawValue, count: 0)
        }
    }

    private func createPlaylist() {
        let title = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            _ = try appCoordinator.createPlaylist(title: title)
            loadPlaylists()
            newPlaylistName = ""
        } catch {
            print("Failed to create playlist: \(error)")
        }
    }

    private func editPlaylist(_ playlist: Playlist, newName: String) {
        guard let playlistId = playlist.id else { return }
        do {
            try appCoordinator.renamePlaylist(playlistId: playlistId, newTitle: newName)
            loadPlaylists()
            playlistToEdit = nil
            editPlaylistName = ""
        } catch {
            print("Failed to rename playlist: \(error)")
        }
    }

    private func deletePlaylist(_ playlist: Playlist) {
        guard let playlistId = playlist.id else { return }
        do {
            try appCoordinator.deletePlaylist(playlistId: playlistId)
            loadPlaylists()
            playlistToDelete = nil
        } catch {
            print("Failed to delete playlist: \(error)")
        }
    }
}

#if canImport(FoundationModels)
    /// Bottom sheet behind the playlists screen's floating AI button: describe a
    /// playlist, the on-device model picks tracks (MixGenerator), and the result
    /// is saved as a regular playlist.
    @available(iOS 26.0, *)
    struct AIPlaylistSheet: View {
        @Environment(AppCoordinator.self) private var appCoordinator
        @Environment(\.dismiss) private var dismiss

        @State private var prompt = ""
        @State private var isGenerating = false
        @State private var showError = false
        @State private var showCreated = false
        @State private var createdTitle = ""
        @State private var createdTracks: [Track] = []
        @FocusState private var promptFocused: Bool

        var onCreated: () -> Void

        var body: some View {
            NavigationStack {
                VStack(alignment: .leading, spacing: DesignTokens.space20) {
                    Text(Localized.aiPlaylistDescription)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    TextField(Localized.aiPlaylistPlaceholder, text: $prompt, axis: .vertical)
                        .lineLimit(2 ... 4)
                        .textFieldStyle(.roundedBorder)
                        .focused($promptFocused)
                        .disabled(isGenerating)
                        .onSubmit(generate)

                    if showError {
                        Text(Localized.aiPlaylistFailed)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }

                    Button(action: generate) {
                        HStack {
                            if isGenerating {
                                ProgressView()
                                    .tint(.white)
                                Text(Localized.aiPlaylistGenerating)
                            } else {
                                Image(systemName: "wand.and.stars")
                                Text(Localized.aiPlaylistGenerate)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.space6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()
                }
                .padding(DesignTokens.space20)
                .navigationTitle(Localized.aiPlaylistTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Localized.cancel) { dismiss() }
                            .disabled(isGenerating)
                    }
                }
                .onAppear { promptFocused = true }
                .alert(Localized.aiPlaylistCreatedTitle, isPresented: $showCreated) {
                    Button(Localized.play) {
                        let tracks = createdTracks
                        Task { @MainActor in
                            if let first = tracks.first {
                                await appCoordinator.playTrack(first, queue: tracks)
                            }
                            dismiss()
                        }
                    }
                    Button(Localized.done, role: .cancel) { dismiss() }
                } message: {
                    Text(Localized.aiPlaylistCreatedMessage(createdTitle, createdTracks.count))
                }
            }
            .presentationDetents([.medium])
        }

        private func generate() {
            let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty, !isGenerating else { return }
            isGenerating = true
            showError = false

            Task { @MainActor in
                do {
                    let mix = try await MixGenerator().generate(matching: request)
                    guard !mix.tracks.isEmpty else { throw MixGenerationError.emptyLibrary }

                    let playlist = try appCoordinator.createPlaylist(title: mix.title)
                    if let playlistId = playlist.id {
                        for track in mix.tracks {
                            try appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                        }
                    }
                    onCreated()
                    createdTitle = playlist.title
                    createdTracks = mix.tracks
                    isGenerating = false
                    showCreated = true
                } catch {
                    print("❌ AI playlist generation failed: \(error)")
                    showError = true
                    isGenerating = false
                }
            }
        }
    }
#endif // canImport(FoundationModels)

/// Trailing tile in the playlists grid, shown only while editing. Mirrors
/// PlaylistCardView's geometry (square artwork area plus two text lines) so the
/// grid rows stay aligned alongside real playlist cards.
struct NewPlaylistCardView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space8) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.radius12)
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(1, contentMode: .fit)

                RoundedRectangle(cornerRadius: DesignTokens.radius12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundColor(.secondary.opacity(0.5))
                    .aspectRatio(1, contentMode: .fit)

                Image(systemName: "plus")
                    .font(.system(size: DesignTokens.font40, weight: .light))
                    .foregroundColor(.secondary)
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius12))
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.radius12))

            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(Localized.createPlaylist)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                // Keeps this tile the same height as the playlist cards, which
                // carry a song-count caption on their second line.
                Text(" ")
                    .font(.caption)
                    .hidden()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Localized.createPlaylist)
        .accessibilityAddTraits(.isButton)
    }
}
