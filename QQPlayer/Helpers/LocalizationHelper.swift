//
//  LocalizationHelper.swift
//  QQPlayer
//
//  Localization helper for easy access to localized strings
//

import Foundation

extension String {
    /// Returns the localized string for this key
    ///
    /// 语言热切换（设置 → 外观 → 语言）：选了具体语言时从该语言 lproj 的 Bundle 取文案；
    /// 跟随系统、或该语言缺这条 key → 回退系统 `NSLocalizedString`（保持旧行为）。
    var localized: String {
        if let translated = AppLanguageResources.localizedString(
            forKey: self,
            languageCode: AppLanguage.resolvedCode
        ) {
            return translated
        }
        return NSLocalizedString(self, comment: "")
    }

    /// Returns the localized string with format arguments
    func localized(with arguments: CVarArg...) -> String {
        return String(format: localized, arguments: arguments)
    }
}

/// Localization helper with commonly used strings
struct Localized {
    // MARK: - Playlist strings
    static var playlists: String { "playlists".localized }
    static var noPlaylistsYet: String { "no_playlists_yet".localized }
    static var createPlaylistsInstruction: String { "create_playlists_instruction".localized }
    static var addToPlaylist: String { "add_to_playlist".localized }
    static var createNewPlaylist: String { "create_new_playlist".localized }
    static var createPlaylist: String { "create_playlist".localized }
    static var playlistNamePlaceholder: String { "playlist_name_placeholder".localized }
    static var aiPlaylistTitle: String { "ai_playlist_title".localized }
    static var aiPlaylistDescription: String { "ai_playlist_description".localized }
    static var aiPlaylistPlaceholder: String { "ai_playlist_placeholder".localized }
    static var aiPlaylistGenerate: String { "ai_playlist_generate".localized }
    static var aiPlaylistGenerating: String { "ai_playlist_generating".localized }
    static var aiPlaylistFailed: String { "ai_playlist_failed".localized }
    static var aiPlaylistButton: String { "ai_playlist_button".localized }
    static var aiPlaylistCreatedTitle: String { "ai_playlist_created_title".localized }
    static func aiPlaylistCreatedMessage(_ title: String, _ count: Int) -> String {
        "ai_playlist_created_message".localized(with: title, count)
    }
    static var enterPlaylistName: String { "enter_playlist_name".localized }
    static var deletePlaylist: String { "delete_playlist".localized }
    static var delete: String { "delete".localized }
    static var cancel: String { "cancel".localized }
    static var create: String { "create".localized }
    static var done: String { "done".localized }
    static var edit: String { "edit".localized }
    static var editPlaylist: String { "edit_playlist".localized }
    static var save: String { "save".localized }
    static var enterNewName: String { "enter_new_name".localized }
    static var managePlaylists: String { "manage_playlists".localized }
    static var playlist: String { "playlist".localized }
    static var createFirstPlaylist: String { "create_first_playlist".localized }

    // MARK: - General UI strings
    static var allSongs: String { "all_songs".localized }
    /// 定位到当前播放后的 toast
    static var locateCurrentTrackToast: String { "locate_current_track_toast".localized }
    /// 歌词对齐入口不可用时的提示（无同步歌词）
    static var lyricAlignmentNoSyncedLyrics: String { "lyric_align_no_synced_lyrics".localized }
    static var likedSongs: String { "liked_songs".localized }
    static var addSongs: String { "add_songs".localized }
    static var importMusicFiles: String { "import_music_files".localized }
    static var noSongsFound: String { "no_songs_found".localized }
    static var yourMusicWillAppearHere: String { "your_music_will_appear_here".localized }
    static var ok: String { "ok".localized }
    static var settings: String { "settings".localized }
    static var retry: String { "retry".localized }
    static var openSettings: String { "open_settings".localized }
    static var `continue`: String { "continue".localized }
    static var back: String { "back".localized }
    static var getStarted: String { "get_started".localized }
    static var imSignedIn: String { "im_signed_in".localized }
    static var itsEnabled: String { "its_enabled".localized }

    // MARK: - Library and Navigation
    static var library: String { "library".localized }
    static var artists: String { "artists".localized }
    static var albums: String { "albums".localized }
    static var search: String { "search".localized }
    static var browse: String { "browse".localized }
    static var songs: String { "songs".localized }
    static var processing: String { "processing".localized }
    static var waiting: String { "waiting".localized }

    // MARK: - Artist/Album/Track Info
    static var noArtistsFound: String { "no_artists_found".localized }
    static var artistsWillAppear: String { "artists_will_appear".localized }
    static var noAlbumsFound: String { "no_albums_found".localized }
    static var albumsWillAppear: String { "albums_will_appear".localized }
    static var artist: String { "artist".localized }
    static var album: String { "album".localized }
    static var play: String { "play".localized }
    static var shuffle: String { "shuffle".localized }
    static var wrongArtist: String { "wrong_artist".localized }
    static var openSpotify: String { "open_spotify".localized }
    static var loadingArtist: String { "loading_artist".localized }

    // MARK: - Player
    static var playingQueue: String { "playing_queue".localized }
    static var noSongsInQueue: String { "no_songs_in_queue".localized }
    static var queueShuffleDisabledHint: String { "queue_shuffle_disabled_hint".localized }
    static var removeFromQueue: String { "queue_remove_from_queue".localized }
    static var noTrackSelected: String { "no_track_selected".localized }

    // MARK: - Search
    static var searchYourMusicLibrary: String { "search_your_music_library".localized }
    static var findSongsArtistsAlbumsPlaylists: String { "find_songs_artists_albums_playlists".localized }
    static var noResultsFound: String { "no_results_found".localized }
    static var tryDifferentKeywords: String { "try_different_keywords".localized }

    // MARK: - Context Menu Actions
    static var showArtistPage: String { "show_artist_page".localized }
    static var addToPlaylistEllipsis: String { "add_to_playlist_ellipsis".localized }
    static var removeFromPlaylist: String { "playlist_manage_remove_from_playlist".localized }
    static var deleteFile: String { "delete_file".localized }

    // MARK: - Settings
    static var appearance: String { "appearance".localized }
    static var language: String { "language".localized }
    static var languageFollowSystem: String { "language_follow_system".localized }
    static var information: String { "information".localized }
    static var minimalistLibraryIcons: String { "minimalist_library_icons".localized }
    static var forceDarkMode: String { "force_dark_mode".localized }
    static var version: String { "version".localized }
    static var appName: String { "app_name".localized }
    static var qqplayerName: String { "qqplayer".localized }
    static var githubRepository: String { "github_repository".localized }
    static var useSimpleIcons: String { "use_simple_icons".localized }
    static var overrideSystemAppearance: String { "override_system_appearance".localized }
    /// 播放页封面毛玻璃背景开关（iOS 设置 → 外观 / macOS 设置 → 外观）
    static var playerGlassBackground: String { "player_glass_background".localized }
    static var playerGlassBackgroundFootnote: String { "player_glass_background_footnote".localized }
    /// 显示风格（iOS 设置 → 外观：毛玻璃 / 经典，二选一）
    static var appearanceStyle: String { "appearance_style".localized }
    static var appearanceStyleGlass: String { "appearance_style_glass".localized }
    static var appearanceStyleClassic: String { "appearance_style_classic".localized }
    static var appearanceStyleFootnote: String { "appearance_style_footnote".localized }
    static var backgroundColor: String { "background_color".localized }
    static var chooseColorTheme: String { "choose_color_theme".localized }
    static var librarySection: String { "library_section".localized }
    static var homeSections: String { "home_sections".localized }
    static var chooseVisibleSections: String { "choose_visible_sections".localized }
    static var removeFromLibraryOnly: String { "remove_from_library_only".localized }
    static var removeFromLibraryOnlyDescription: String { "remove_from_library_only_description".localized }
    static var playerControls: String { "player_controls".localized }
    static var showSleepTimerButton: String { "show_sleep_timer_button".localized }
    static var showSleepTimerButtonDescription: String { "show_sleep_timer_button_description".localized }

    // MARK: - Track List（列头排序/右键菜单/定位，web 版对齐）
    static var showArtist: String { "show_artist".localized }
    static var showAlbum: String { "show_album".localized }
    static var locatePlayingTrack: String { "locate_playing_track".localized }
    /// 歌曲详情（macOS 右键菜单 / ⌘I，2026-11-16）
    static var songDetail: String { "context_song_detail".localized }

    // MARK: - Move to Trash（web 版「移到废纸篓」对齐，macOS 2026-09-02 A4）
    static var moveToTrash: String { "move_to_trash".localized }
    static var moveToTrashFailedCount: String { "move_to_trash_failed_count".localized }

    static func moveToTrashConfirm(_ trackTitle: String) -> String {
        return "move_to_trash_confirm_single".localized(with: trackTitle)
    }

    static func moveToTrashConfirm(count: Int) -> String {
        return "move_to_trash_confirm_multi".localized(with: count)
    }

    static func moveToTrashFailed(count: Int) -> String {
        return "move_to_trash_failed_count".localized(with: count)
    }

    // MARK: - Settings Categories（web 版左导航分类对齐）
    static var settingsCategoryPlayback: String { "settings_category_playback".localized }
    static var settingsCategoryLyrics: String { "settings_category_lyrics".localized }
    static var settingsCategoryDesktopLyric: String { "settings_category_desktop_lyric".localized }
    static var settingsCategoryLibrary: String { "settings_category_library".localized }
    static var settingsCategoryDownload: String { "settings_category_download".localized }
    static var settingsCategoryScraping: String { "settings_category_scraping".localized }
    static var settingsCategoryShortcuts: String { "settings_category_shortcuts".localized }
    static var settingsCategoryAppearance: String { "settings_category_appearance".localized }
    static var settingsCategoryAbout: String { "settings_category_about".localized }
    static var settingsDownloadQuality: String { "settings_download_quality".localized }

    // MARK: - Lyrics（歌词设置，D3 web 版 lyric 设置对齐）
    static var lyricsDisplay: String { "lyrics_display".localized }
    static var lyricsFontSize: String { "lyrics_font_size".localized }
    static var lyricsShowTranslation: String { "lyrics_show_translation".localized }
    static var lyricsShowRoman: String { "lyrics_show_roman".localized }
    static var lyricsCalibration: String { "lyrics_calibration".localized }
    static var lyricsOffset: String { "lyrics_offset".localized }
    static var lyricsOffsetReset: String { "lyrics_offset_reset".localized }
    static var lyricsOffsetHint: String { "lyrics_offset_hint".localized }

    // MARK: - Visualizer（播放页频谱，D4 web 版 visualizerEnabled 对齐）
    static var visualizerEnabled: String { "visualizer_enabled".localized }

    // MARK: - Music Library File Types（文件类型，web 版 audioExts 对齐）
    static var libraryFileTypes: String { "library_file_types".localized }
    static var libraryFileTypesFooter: String { "library_file_types_footer".localized }

    // MARK: - Drag & Drop Import（文件拖入导入，web 版拖拽对齐）
    static var dragImportHint: String { "drag_import_hint".localized }
    static var dragImportNone: String { "drag_import_none".localized }
    static func dragImportSuccess(count: Int) -> String {
        "drag_import_success_count".localized(with: count)
    }
    /// 导入被跳过的文件数（不支持的格式/网络 URL；审计 D2：写而不读 → 接上）
    static func dragImportSkipped(count: Int) -> String {
        "drag_import_skipped_count".localized(with: count)
    }
    /// 部分导入（既导入又跳过）
    static func dragImportPartial(imported: Int, skipped: Int) -> String {
        "drag_import_partial_count".localized(with: imported, skipped)
    }

    // MARK: - Appearance（主题三态 + 强调色）
    static var appearanceTheme: String { "appearance_theme".localized }
    static var themeSystem: String { "theme_system".localized }
    static var themeDark: String { "theme_dark".localized }
    static var themeLight: String { "theme_light".localized }
    static var accentColor: String { "accent_color".localized }

    /// 强调色预设名（web 版 labelKey 语义：settings.accentColor.*）
    static func accentName(_ key: String) -> String {
        "accent_\(key)".localized
    }

    // MARK: - Liked Songs Actions
    static var addToLikedSongs: String { "add_to_liked_songs".localized }
    static var removeFromLikedSongs: String { "remove_from_liked_songs".localized }

    // MARK: - Search Categories
    static var all: String { "all".localized }

    // MARK: - Tutorial/Onboarding
    static var welcomeToQQPlayer: String { "welcome_to_qqplayer".localized }
    static var ifSignedInContinue: String { "if_signed_in_continue".localized }
    static var addYourMusic: String { "add_your_music".localized }
    static var howToAddMusic: String { "how_to_add_music".localized }
    static var openFilesApp: String { "open_files_app".localized }
    static var navigateToOnMyIphone: String { "navigate_to_on_my_iphone".localized }
    static var findQQPlayerFolder: String { "find_qqplayer_folder".localized }
    static var addYourMusicInstruction: String { "add_your_music_instruction".localized }

    // MARK: - Tutorial Instructions
    static var findOpenFilesApp: String { "find_open_files_app".localized }
    static var tapOnMyIphoneSidebar: String { "tap_on_my_iphone_sidebar".localized }
    static var lookForQQPlayerFolder: String { "look_for_qqplayer_folder".localized }
    static var copyMusicFiles: String { "copy_music_files".localized }

    // MARK: - Library Processing
    static var processingColon: String { "processing_colon".localized }
    static var waitingColon: String { "waiting_colon".localized }

    // MARK: - Subtitles and descriptions
    static var yourFavorites: String { "your_favorites".localized }
    static var yourPlaylists: String { "your_playlists".localized }
    static var browseByArtist: String { "browse_by_artist".localized }
    static var browseByAlbum: String { "browse_by_album".localized }
    static var unknownAlbum: String { "unknown_album".localized }
    static var unknownArtist: String { "unknown_artist".localized }

    // MARK: - Dynamic strings with parameters
    static func songsCount(_ count: Int) -> String {
        if count == 1 {
            return "songs_count_singular".localized(with: count)
        } else {
            return "songs_count_plural".localized(with: count)
        }
    }

    /// 专辑数（歌手详情页「N 张专辑」）：英文单复数分开，与 songsCount 同款
    static func albumsCount(_ count: Int) -> String {
        if count == 1 {
            return "albums_count_singular".localized(with: count)
        } else {
            return "albums_count_plural".localized(with: count)
        }
    }

    static func createdDate(_ dateString: String) -> String {
        return "created_date".localized(with: dateString)
    }

    static func deletePlaylistConfirmation(_ playlistName: String) -> String {
        return "delete_playlist_confirmation".localized(with: playlistName)
    }

    static func deleteFileConfirmation(_ fileName: String) -> String {
        return "delete_file_confirmation".localized(with: fileName)
    }

    static func foundTracks(_ count: Int) -> String {
        return "found_tracks".localized(with: count)
    }

    static func andMore(_ count: Int) -> String {
        return "and_more".localized(with: count)
    }

    static func dataProvidedBy(_ source: String) -> String {
        return "data_provided_by".localized(with: source)
    }

    static func percentComplete(_ percent: Int) -> String {
        return "percent_complete".localized(with: percent)
    }

    static func songsCountOnly(_ count: Int) -> String {
        return "songs_count".localized(with: count)
    }

    // MARK: - Equalizer strings
    static var equalizer: String { "equalizer".localized }
    static var graphicEqualizer: String { "graphic_equalizer".localized }
    static var enableEqualizer: String { "enable_equalizer".localized }
    static var enableDisableEqDescription: String { "enable_disable_eq_description".localized }

    // Manual EQ Presets
    static var manualEQPresets: String { "manual_eq_presets".localized }

    // Common Presets (常用预设)
    static var presetCommon: String { "preset_common".localized }
    static var presetCustom: String { "preset_custom".localized }
    static var eqCustomTitle: String { "eq_custom_title".localized }
    static var noManualPresetsCreated: String { "no_manual_presets_created".localized }
    static var createManualEQDescription: String { "create_manual_eq_description".localized }
    static var createManual16BandEQ: String { "create_manual_16band_eq".localized }
    static var manual16BandEQ: String { "manual_16band_eq".localized }
    static var manual16BandDescription: String { "manual_16band_description".localized }
    static var adjustBandsAfterCreation: String { "adjust_bands_after_creation".localized }
    static var frequencyBands: String { "frequency_bands".localized }
    static var editEqualizer: String { "edit_equalizer".localized }
    static var resetToFlat: String { "reset_to_flat".localized }

    // Imported GraphicEQ Presets
    static var importedPresets: String { "imported_presets".localized }
    static var noPresetsImported: String { "no_presets_imported".localized }
    static var importGraphicEQDescription: String { "import_graphiceq_description".localized }
    static var importedGraphicEQ: String { "imported_graphiceq".localized }
    static var importGraphicEQFile: String { "import_graphiceq_file".localized }

    // General EQ Settings
    static var globalSettings: String { "global_settings".localized }
    static var globalGain: String { "global_gain".localized }
    static var globalGainDescription: String { "global_gain_description".localized }
    static var aboutGraphicEQFormat: String { "about_graphiceq_format".localized }
    static var importGraphicEQFormatDescription: String { "import_graphiceq_format_description".localized }
    static var frequencyGainPairDescription: String { "frequency_gain_pair_description".localized }
    static var eqExport: String { "export".localized }
    static var eqDelete: String { "delete".localized }
    static var eqEdit: String { "edit".localized }
    static var eqCancel: String { "cancel".localized }
    static var eqDone: String { "done".localized }
    static var eqSave: String { "save".localized }
    static var eqCreate: String { "create".localized }
    static var presetInfo: String { "preset_info".localized }

    // GraphicEQ Import View
    static var importGraphicEQ: String { "import_graphiceq".localized }
    static var presetName: String { "preset_name".localized }
    static var enterPresetName: String { "enter_preset_name".localized }
    static var importMethods: String { "import_methods".localized }
    static var importFromTxtFile: String { "import_from_txt_file".localized }
    static var pasteGraphicEQText: String { "paste_graphiceq_text".localized }
    static var eqError: String { "error".localized }
    static var formatInfo: String { "format_info".localized }
    static var expectedGraphicEQFormat: String { "expected_graphiceq_format".localized }
    static var frequencyGainPair: String { "frequency_gain_pair".localized }

    // Text Import View
    static var pasteGraphicEQ: String { "paste_graphiceq".localized }
    static var pasteGraphicEQTextSection: String { "paste_graphiceq_text_section".localized }
    static var example: String { "example".localized }
    static var eqImport: String { "import".localized }

    // Error Messages
    static func failedToImport(_ error: String) -> String {
        return "failed_to_import".localized(with: error)
    }

    static func fileImportFailed(_ error: String) -> String {
        return "file_import_failed".localized(with: error)
    }

    static func failedToCreate(_ error: String) -> String {
        return "failed_to_create".localized(with: error)
    }

    static var failedToExport: String { "failed_to_export".localized }
    static var failedToDelete: String { "failed_to_delete".localized }

    // EQ Band Information
    static func bandCountInfo(used: Int, original: Int) -> String {
        return "band_count_info".localized(with: used, original)
    }

    static func bandsReducedDescription(original: Int, reduced: Int) -> String {
        return "bands_reduced_description".localized(with: original, reduced)
    }

    static func bandsLimitedWarning(original: Int, limited: Int) -> String {
        return "bands_limited_warning".localized(with: original, limited)
    }

    // macOS EQ UI
    static var eqCopied: String { "eq_copied".localized }
    static var eqDeleteConfirmTitle: String { "eq_delete_confirm_title".localized }
    static func eqDeleteConfirmMessage(_ name: String) -> String {
        return "eq_delete_confirm_message".localized(with: name)
    }
    static var eqManualParametric: String { "eq_manual_parametric".localized }
    static var eqCreateManual: String { "eq_create_manual".localized }
    static var eqBands: String { "eq_bands".localized }
    static func eqBandsCount(_ used: Int, _ total: Int) -> String {
        return "eq_bands_count".localized(with: used, total)
    }
    static var eqParametricEditor: String { "eq_parametric_editor".localized }
    static var eqAddBand: String { "eq_add_band".localized }
    static var eqRemoveBand: String { "eq_remove_band".localized }
    static var eqSelectedBand: String { "eq_selected_band".localized }
    static func eqBandNumber(_ index: Int) -> String {
        return "eq_band_number".localized(with: index)
    }
    static var eqFrequency: String { "eq_frequency".localized }
    static var eqGain: String { "eq_gain".localized }
    static var eqQ: String { "eq_q".localized }
    static var eqCreateManualDescription: String { "eq_create_manual_description".localized }
    static var eqEditBandsHint: String { "eq_edit_bands_hint".localized }
    static var eqImportedPreset: String { "eq_imported_preset".localized }

    // MARK: - Audio Settings
    static var audioSettings: String { "audio_settings".localized }
    static var dsdPlaybackMode: String { "dsd_playback_mode".localized }
    static var dsdPlaybackModeDescription: String { "dsd_playback_mode_description".localized }
    static var dsdModeAuto: String { "dsd_mode_auto".localized }
    static var dsdModePCM: String { "dsd_mode_pcm".localized }
    static var dsdModeDoP: String { "dsd_mode_dop".localized }
    static var dsdModeAutoDescription: String { "dsd_mode_auto_description".localized }
    static var dsdModePCMDescription: String { "dsd_mode_pcm_description".localized }
    static var dsdModeDoDescription: String { "dsd_mode_dop_description".localized }

    // MARK: - Sort Options
    static var sortDateNewest: String { "sort_date_newest".localized }
    static var sortDateOldest: String { "sort_date_oldest".localized }
    static var sortNameAZ: String { "sort_name_az".localized }
    static var sortNameZA: String { "sort_name_za".localized }
    static var sortSizeLargest: String { "sort_size_largest".localized }
    static var sortSizeSmallest: String { "sort_size_smallest".localized }

    // MARK: - Queue Actions
    static var playNext: String { "play_next".localized }
    static var addToQueue: String { "add_to_queue".localized }

    // MARK: - Track Action Feedback (toast)
    static var toastPlayNext: String { "toast_play_next".localized }
    static var toastAddedToQueue: String { "toast_added_to_queue".localized }

    // MARK: - Sleep Timer
    static var sleepTimer: String { "sleep_timer".localized }
    static var sleepTimerOff: String { "sleep_timer_off".localized }
    static var sleepTimer15Minutes: String { "sleep_timer_15_minutes".localized }
    static var sleepTimer30Minutes: String { "sleep_timer_30_minutes".localized }
    static var sleepTimer45Minutes: String { "sleep_timer_45_minutes".localized }
    static var sleepTimer60Minutes: String { "sleep_timer_60_minutes".localized }
    static var cancelSleepTimer: String { "cancel_sleep_timer".localized }
    // MARK: - Contextual hints (首次提示气泡)
    static var hintDismiss: String { "hint_dismiss".localized }
    static var hintPlaybackTitle: String { "hint_playback_title".localized }
    static var hintPlaybackLine1: String { "hint_playback_line1".localized }
    static var hintPlaybackLine2: String { "hint_playback_line2".localized }
    static var hintPlaybackLine3: String { "hint_playback_line3".localized }
    static var hintFullLyricsTitle: String { "hint_full_lyrics_title".localized }
    static var hintFullLyricsLine1: String { "hint_full_lyrics_line1".localized }
    static var hintFullLyricsLine2: String { "hint_full_lyrics_line2".localized }
    /// 普通模式手动滚动歌词后浮出的「回到当前行」按钮
    static var backToCurrentLine: String { "back_to_current_line".localized }
    static var hintSearchTitle: String { "hint_search_title".localized }
    static var hintSearchLine1: String { "hint_search_line1".localized }
    /// macOS 歌词搜索页提示（iOS 的 line1 是滑动手势，Mac sheet 无此交互）
    static var hintSearchMacLine1: String { "hint_search_mac_line1".localized }

    // MARK: - Bulk Selection
    static var select: String { "select".localized }
    static var selectAll: String { "select_all".localized }
    static var bulkActions: String { "bulk_actions".localized }
    static var addToLiked: String { "add_to_liked".localized }
    static var removeFromLiked: String { "remove_from_liked".localized }
    static var deleteFiles: String { "delete_files".localized }
    static var deleteFilesConfirmation: String { "delete_files_confirmation".localized }

    static func selectedCount(_ count: Int) -> String {
        if count == 1 {
            return "selected_count_singular".localized(with: count)
        } else {
            return "selected_count_plural".localized(with: count)
        }
    }

    static func deleteFilesConfirmationMessage(_ count: Int) -> String {
        return "delete_files_confirmation_message".localized(with: count)
    }

    // MARK: - Playback order
    static var playOrderSequential: String { "play_order_sequential".localized }
    static var playOrderShuffle: String { "play_order_shuffle".localized }
    static var playOrderRepeatAll: String { "play_order_repeat_all".localized }
    static var playOrderRepeatOne: String { "play_order_repeat_one".localized }
    // MARK: - Feature guide (帮助中心)
    static var featureGuide: String { "feature_guide".localized }
    static var featureGuideSectionPlayer: String { "feature_guide_section_player".localized }
    static var featureGuideSectionLyrics: String { "feature_guide_section_lyrics".localized }
    static var featureGuideSectionControls: String { "feature_guide_section_controls".localized }
    static var featureGuideSectionSmart: String { "feature_guide_section_smart".localized }
    static var featureGuideSectionMisc: String { "feature_guide_section_misc".localized }
    static var featureGuideSwipeArtworkTitle: String { "feature_guide_swipe_artwork_title".localized }
    static var featureGuideSwipeArtworkDetail: String { "feature_guide_swipe_artwork_detail".localized }
    static var featureGuidePullToCloseTitle: String { "feature_guide_pull_to_close_title".localized }
    static var featureGuidePullToCloseDetail: String { "feature_guide_pull_to_close_detail".localized }
    static var featureGuideExpandControlsTitle: String { "feature_guide_expand_controls_title".localized }
    static var featureGuideExpandControlsDetail: String { "feature_guide_expand_controls_detail".localized }
    static var featureGuideOpenFullLyricsTitle: String { "feature_guide_open_full_lyrics_title".localized }
    static var featureGuideOpenFullLyricsDetail: String { "feature_guide_open_full_lyrics_detail".localized }
    static var featureGuideSearchLyricsTitle: String { "feature_guide_search_lyrics_title".localized }
    static var featureGuideSearchLyricsDetail: String { "feature_guide_search_lyrics_detail".localized }
    static var featureGuideKaraokeStartTitle: String { "feature_guide_karaoke_start_title".localized }
    static var featureGuideKaraokeStartDetail: String { "feature_guide_karaoke_start_detail".localized }
    static var featureGuideKaraokeControlsTitle: String { "feature_guide_karaoke_controls_title".localized }
    static var featureGuideKaraokeControlsDetail: String { "feature_guide_karaoke_controls_detail".localized }
    static var featureGuideKaraokeExitTitle: String { "feature_guide_karaoke_exit_title".localized }
    static var featureGuideKaraokeExitDetail: String { "feature_guide_karaoke_exit_detail".localized }
    static var featureGuideOrderModesTitle: String { "feature_guide_order_modes_title".localized }
    static var featureGuideOrderModesDetail: String { "feature_guide_order_modes_detail".localized }
    static var featureGuideSmartSourceTitle: String { "feature_guide_smart_source_title".localized }
    static var featureGuideSmartSourceDetail: String { "feature_guide_smart_source_detail".localized }
    static var featureGuideSmartWhereTitle: String { "feature_guide_smart_where_title".localized }
    static var featureGuideSmartWhereDetail: String { "feature_guide_smart_where_detail".localized }
    static var featureGuideEQTitle: String { "feature_guide_eq_title".localized }
    static var featureGuideEQDetail: String { "feature_guide_eq_detail".localized }
    static var featureGuideDarkModeTitle: String { "feature_guide_dark_mode_title".localized }
    static var featureGuideDarkModeDetail: String { "feature_guide_dark_mode_detail".localized }
    static var featureGuideImportTitle: String { "feature_guide_import_title".localized }
    static var featureGuideImportDetail: String { "feature_guide_import_detail".localized }

    // MARK: - Smart playlists (自动歌单)
    static var smartRecentAdded: String { "smart_recent_added".localized }
    static var smartRecentPlayed: String { "smart_recent_played".localized }
    static var smartTopPlayed: String { "smart_top_played".localized }
    static var smartDecades: String { "smart_decades".localized }
    static var smartEmptyRecentPlayed: String { "smart_empty_recent_played".localized }
    static var smartEmptyTopPlayed: String { "smart_empty_top_played".localized }
    static var smartEmptyDecade: String { "smart_empty_decade".localized }
    static var smartLoadFailed: String { "smart_load_failed".localized }

    static func smartPlaylistTitle(_ kind: SmartPlaylistKind) -> String {
        switch kind {
        case .recentAdded: return smartRecentAdded
        case .recentPlayed: return smartRecentPlayed
        case .topPlayed: return smartTopPlayed
        case .decades: return smartDecades
        }
    }

    static func smartSongsCount(_ count: Int) -> String {
        "smart_songs_count".localized(with: count)
    }

    static func smartDecadeCount(_ count: Int) -> String {
        "smart_decade_count".localized(with: count)
    }
    // MARK: - What's New (新功能弹窗)
    static var whatsNewTitle: String { "whats_new_title".localized }
    static var whatsNewItemHints: String { "whats_new_item_hints".localized }
    static var whatsNewItemGuide: String { "whats_new_item_guide".localized }
    static var whatsNewItemAnnouncement: String { "whats_new_item_announcement".localized }
}
