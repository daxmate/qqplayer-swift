import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var deleteSettings = DeleteSettings.load()
    /// 歌词延迟校准（按输出路由存；车里最常用）
    @ObservedObject private var lyricOffsetStore = LyricOffsetStore.shared
    @State private var showDeleteFolderPlaylistsPrompt = false

    private func deleteExistingFolderPlaylists() {
        do {
            let folderPlaylists = try DatabaseManager.shared.getAllFolderPlaylists()
            for playlist in folderPlaylists {
                if let id = playlist.id {
                    try DatabaseManager.shared.deletePlaylist(playlistId: id)
                }
            }
            print("🗑️ Deleted \(folderPlaylists.count) folder playlist(s) after disabling auto-creation")
        } catch {
            print("❌ Failed to delete folder playlists: \(error)")
        }
    }

    var body: some View {
        NavigationView {
            Form {
                // 功能与手势：帮助中心入口（置顶）
                Section {
                    NavigationLink(destination: FeatureGuideView()) {
                        HStack {
                            Image(systemName: "questionmark.circle.fill")
                                .foregroundColor(.blue)
                            Text(Localized.featureGuide)
                        }
                    }
                }

                Section(Localized.appearance) {
                    Toggle(Localized.minimalistLibraryIcons, isOn: $deleteSettings.minimalistIcons)
                        .onChange(of: deleteSettings.minimalistIcons) { _, _ in
                            deleteSettings.save()
                        }

                    Text(Localized.useSimpleIcons)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle(Localized.forceDarkMode, isOn: $deleteSettings.forceDarkMode)
                        .onChange(of: deleteSettings.forceDarkMode) { _, _ in
                            deleteSettings.save()
                        }

                    Text(Localized.overrideSystemAppearance)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: DesignTokens.space12) {
                        Text(Localized.backgroundColor)
                            .font(.headline)

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                        ], spacing: DesignTokens.space16) {
                            ForEach(IOSAppearance.accentPresets, id: \.key) { preset in
                                Button(action: {
                                    // 唯一配色字段（2026-09-17 字段层收口）：写 token。
                                    // save() 本身已发 .qqplayerSettingsDidChange（设置变更唯一信号）——
                                    // 不再补发第二个「配色变更」事件（.backgroundColorChanged 已退役）。
                                    deleteSettings.accentColorName = preset.key
                                    deleteSettings.save()
                                }) {
                                    ZStack {
                                        Circle()
                                            .fill(IOSAppearance.accentColor(forKey: preset.key))
                                            .frame(width: 44, height: 44)
                                            .overlay(
                                                Circle()
                                                    .stroke(deleteSettings.accentColorName == preset.key ? Color.primary : Color.clear, lineWidth: 3)
                                            )

                                        if deleteSettings.accentColorName == preset.key {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: DesignTokens.font16, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }

                    Text(Localized.chooseColorTheme)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(Localized.audioSettings) {
                    NavigationLink(destination: EQSettingsView()) {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundColor(.blue)
                                .font(.system(size: DesignTokens.font20))
                            Text(Localized.graphicEqualizer)
                        }
                    }

                    VStack(alignment: .leading, spacing: DesignTokens.space8) {
                        Text(Localized.dsdPlaybackMode)
                            .font(.headline)

                        Text(Localized.dsdPlaybackModeDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: $deleteSettings.dsdPlaybackMode) {
                            ForEach(DSDPlaybackMode.allCases, id: \.self) { mode in
                                VStack(alignment: .leading) {
                                    Text(mode.displayName)
                                        .font(.body)
                                }
                                .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: deleteSettings.dsdPlaybackMode) { _, _ in
                            deleteSettings.save()
                        }

                        Text(deleteSettings.dsdPlaybackMode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, DesignTokens.space4)
                    }
                    .padding(.vertical, DesignTokens.space4)
                }

                Section(Localized.lyricsDisplay) {
                    Toggle(Localized.lyricsShowRoman, isOn: $deleteSettings.lyricShowRoman)
                        .onChange(of: deleteSettings.lyricShowRoman) { _, _ in
                            deleteSettings.save()
                        }

                    // 歌词延迟校准：无线 CarPlay / 蓝牙下「听到的」比「看到的」晚，
                    // 这里把偏移补回去（正值 = 歌词延后显示）。不手动校准时用系统报的输出延迟当初值。
                    VStack(alignment: .leading, spacing: DesignTokens.space8) {
                        HStack {
                            Text(Localized.lyricsOffset)
                            Spacer()
                            Text(String(format: "%+.2f s", lyricOffsetStore.effectiveOffset))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: Binding(
                                get: { lyricOffsetStore.manualOffset ?? lyricOffsetStore.effectiveOffset },
                                set: { lyricOffsetStore.setManualOffset($0) }
                            ),
                            in: -1.0 ... 1.0,
                            step: 0.05
                        )

                        HStack {
                            Text(lyricOffsetRouteDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(Localized.lyricsOffsetReset) {
                                lyricOffsetStore.clearManualOffset()
                            }
                            .buttonStyle(.borderless)
                            .disabled(lyricOffsetStore.manualOffset == nil)
                        }

                        Text(Localized.lyricsOffsetHint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section(Localized.librarySection) {
                    Toggle(Localized.removeFromLibraryOnly, isOn: $deleteSettings.deleteFromLibraryOnly)
                        .onChange(of: deleteSettings.deleteFromLibraryOnly) { _, _ in
                            deleteSettings.save()
                        }

                    Text(Localized.removeFromLibraryOnlyDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle(Localized.autoFolderPlaylists, isOn: $deleteSettings.autoCreateFolderPlaylists)
                        .onChange(of: deleteSettings.autoCreateFolderPlaylists) { _, newValue in
                            deleteSettings.save()
                            if newValue {
                                // Re-enabled: clear tombstones so folder playlists
                                // can be recreated on the next scan
                                try? DatabaseManager.shared.clearDeletedFolderPlaylistTombstones()
                            } else {
                                showDeleteFolderPlaylistsPrompt = true
                            }
                        }

                    Text(Localized.autoFolderPlaylistsDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .alert(Localized.deleteFolderPlaylistsTitle, isPresented: $showDeleteFolderPlaylistsPrompt) {
                    Button(Localized.deleteFolderPlaylistsConfirm, role: .destructive) {
                        deleteExistingFolderPlaylists()
                    }
                    Button(Localized.keepFolderPlaylists, role: .cancel) {}
                } message: {
                    Text(Localized.deleteFolderPlaylistsMessage)
                }

                Section(Localized.playerControls) {
                    Toggle(Localized.showSleepTimerButton, isOn: $deleteSettings.showSleepTimerButton)
                        .onChange(of: deleteSettings.showSleepTimerButton) { _, _ in
                            deleteSettings.save()
                        }

                    Text(Localized.showSleepTimerButtonDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // S2 M1-UI：局域网同步设置（Client 侧：主机列表/扫码/手输配对）
                Section {
                    NavigationLink(destination: SyncSettingsView()) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.blue)
                                .font(.system(size: DesignTokens.font20))
                            Text("sync_settings_entry".localized)
                        }
                    }
                } header: {
                    Text("sync_settings".localized)
                } footer: {
                    Text("sync_settings_footer".localized)
                }

                Section {
                    ForEach($deleteSettings.homeSections) { $section in
                        HStack {
                            Image(systemName: section.id.icon)
                                .foregroundColor(.secondary)
                                .frame(width: 24)

                            Toggle(section.id.displayName, isOn: $section.isVisible)
                                .onChange(of: section.isVisible) { _, _ in
                                    deleteSettings.save()
                                }
                        }
                    }
                    .onMove { source, destination in
                        deleteSettings.homeSections.move(fromOffsets: source, toOffset: destination)
                        deleteSettings.save()
                    }

                    Text(Localized.chooseVisibleSections)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    HStack {
                        Text(Localized.homeSections)
                        Spacer()
                        EditButton()
                            .font(.caption)
                    }
                }

                Section(Localized.information) {
                    HStack {
                        Text(Localized.version)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text(Localized.appName)
                        Spacer()
                        Text(Localized.qqplayerName)
                            .foregroundColor(.secondary)
                    }

                    Button(action: {
                        print("🔗 GitHub repository button tapped")
                        if let url = URL(string: "https://github.com/daxmate/qqplayer-ios") {
                            print("🔗 Opening URL: \(url)")
                            UIApplication.shared.open(url)
                        } else {
                            print("❌ Invalid GitHub URL")
                        }
                    }) {
                        HStack {
                            Text(Localized.githubRepository)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                                .font(.system(size: DesignTokens.font16))
                        }
                        .contentShape(Rectangle()) // Make entire area tappable
                    }
                    .buttonStyle(PlainButtonStyle()) // Remove default button styling that might interfere
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 100)
            }
            .navigationTitle(Localized.settings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.done) {
                        dismiss()
                    }
                }
            }
        }
    }

    /// 设置页里「当前输出 + 偏移初值从哪来」的说明（端口名用系统给的，别再自造一份翻译）
    private var lyricOffsetRouteDescription: String {
        let name = lyricOffsetStore.routeName ?? lyricOffsetStore.route.rawValue
        if lyricOffsetStore.manualOffset != nil {
            return name
        }
        return "\(name) · +\(String(format: "%.2f", lyricOffsetStore.autoOffset)) s"
    }
}

#Preview {
    SettingsView()
}
