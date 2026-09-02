//
//  LocalizationHelper.swift
//  QQPlayer
//
//  Localization helper for easy access to localized strings
//

import Foundation

extension String {
    /// Returns the localized string for this key
    var localized: String {
        return NSLocalizedString(self, comment: "")
    }

    /// Returns the localized string with format arguments
    func localized(with arguments: CVarArg...) -> String {
        return String(format: NSLocalizedString(self, comment: ""), arguments: arguments)
    }
}

/// Localization helper with commonly used strings
struct Localized {
    // MARK: - Playlist strings
    static let playlists = "playlists".localized
    static let noPlaylistsYet = "no_playlists_yet".localized
    static let createPlaylistsInstruction = "create_playlists_instruction".localized
    static let addToPlaylist = "add_to_playlist".localized
    static let createNewPlaylist = "create_new_playlist".localized
    static let createPlaylist = "create_playlist".localized
    static let playlistNamePlaceholder = "playlist_name_placeholder".localized
    static let aiPlaylistTitle = "ai_playlist_title".localized
    static let aiPlaylistDescription = "ai_playlist_description".localized
    static let aiPlaylistPlaceholder = "ai_playlist_placeholder".localized
    static let aiPlaylistGenerate = "ai_playlist_generate".localized
    static let aiPlaylistGenerating = "ai_playlist_generating".localized
    static let aiPlaylistFailed = "ai_playlist_failed".localized
    static let aiPlaylistButton = "ai_playlist_button".localized
    static let aiPlaylistCreatedTitle = "ai_playlist_created_title".localized
    static func aiPlaylistCreatedMessage(_ title: String, _ count: Int) -> String {
        "ai_playlist_created_message".localized(with: title, count)
    }
    static let enterPlaylistName = "enter_playlist_name".localized
    static let deletePlaylist = "delete_playlist".localized
    static let delete = "delete".localized
    static let cancel = "cancel".localized
    static let create = "create".localized
    static let done = "done".localized
    static let edit = "edit".localized
    static let editPlaylist = "edit_playlist".localized
    static let save = "save".localized
    static let enterNewName = "enter_new_name".localized
    static let managePlaylists = "manage_playlists".localized
    static let playlist = "playlist".localized
    static let createFirstPlaylist = "create_first_playlist".localized

    // MARK: - General UI strings
    static let allSongs = "all_songs".localized
    static let likedSongs = "liked_songs".localized
    static let addSongs = "add_songs".localized
    static let importMusicFiles = "import_music_files".localized
    static let noSongsFound = "no_songs_found".localized
    static let yourMusicWillAppearHere = "your_music_will_appear_here".localized
    static let ok = "ok".localized
    static let settings = "settings".localized
    static let retry = "retry".localized
    static let openSettings = "open_settings".localized
    static let `continue` = "continue".localized
    static let back = "back".localized
    static let getStarted = "get_started".localized
    static let imSignedIn = "im_signed_in".localized
    static let itsEnabled = "its_enabled".localized

    // MARK: - Library and Navigation
    static let library = "library".localized
    static let artists = "artists".localized
    static let albums = "albums".localized
    static let search = "search".localized
    static let browse = "browse".localized
    static let songs = "songs".localized
    static let processing = "processing".localized
    static let waiting = "waiting".localized

    // MARK: - Artist/Album/Track Info
    static let noArtistsFound = "no_artists_found".localized
    static let artistsWillAppear = "artists_will_appear".localized
    static let noAlbumsFound = "no_albums_found".localized
    static let albumsWillAppear = "albums_will_appear".localized
    static let artist = "artist".localized
    static let album = "album".localized
    static let play = "play".localized
    static let shuffle = "shuffle".localized
    static let wrongArtist = "wrong_artist".localized
    static let openSpotify = "open_spotify".localized
    static let loadingArtist = "loading_artist".localized

    // MARK: - Player
    static let playingQueue = "playing_queue".localized
    static let noSongsInQueue = "no_songs_in_queue".localized
    static let noTrackSelected = "no_track_selected".localized

    // MARK: - Search
    static let searchYourMusicLibrary = "search_your_music_library".localized
    static let findSongsArtistsAlbumsPlaylists = "find_songs_artists_albums_playlists".localized
    static let noResultsFound = "no_results_found".localized
    static let tryDifferentKeywords = "try_different_keywords".localized

    // MARK: - Context Menu Actions
    static let showArtistPage = "show_artist_page".localized
    static let addToPlaylistEllipsis = "add_to_playlist_ellipsis".localized
    static let deleteFile = "delete_file".localized

    // MARK: - Settings
    static let appearance = "appearance".localized
    static let information = "information".localized
    static let minimalistLibraryIcons = "minimalist_library_icons".localized
    static let forceDarkMode = "force_dark_mode".localized
    static let version = "version".localized
    static let appName = "app_name".localized
    static let qqplayerName = "qqplayer".localized
    static let githubRepository = "github_repository".localized
    static let useSimpleIcons = "use_simple_icons".localized
    static let overrideSystemAppearance = "override_system_appearance".localized
    static let backgroundColor = "background_color".localized
    static let chooseColorTheme = "choose_color_theme".localized
    static let librarySection = "library_section".localized
    static let homeSections = "home_sections".localized
    static let chooseVisibleSections = "choose_visible_sections".localized
    static let removeFromLibraryOnly = "remove_from_library_only".localized
    static let removeFromLibraryOnlyDescription = "remove_from_library_only_description".localized
    static let autoFolderPlaylists = "auto_folder_playlists".localized
    static let autoFolderPlaylistsDescription = "auto_folder_playlists_description".localized
    static let deleteFolderPlaylistsTitle = "delete_folder_playlists_title".localized
    static let deleteFolderPlaylistsMessage = "delete_folder_playlists_message".localized
    static let deleteFolderPlaylistsConfirm = "delete_folder_playlists_confirm".localized
    static let keepFolderPlaylists = "keep_folder_playlists".localized
    static let playerControls = "player_controls".localized
    static let showSleepTimerButton = "show_sleep_timer_button".localized
    static let showSleepTimerButtonDescription = "show_sleep_timer_button_description".localized

    // MARK: - Settings Categories（web 版左导航分类对齐）
    static let settingsCategoryPlayback = "settings_category_playback".localized
    static let settingsCategoryAppearance = "settings_category_appearance".localized
    static let settingsCategoryAbout = "settings_category_about".localized

    // MARK: - Appearance（主题三态 + 强调色）
    static let appearanceTheme = "appearance_theme".localized
    static let themeSystem = "theme_system".localized
    static let themeDark = "theme_dark".localized
    static let themeLight = "theme_light".localized
    static let accentColor = "accent_color".localized

    /// 强调色预设名（web 版 labelKey 语义：settings.accentColor.*）
    static func accentName(_ key: String) -> String {
        "accent_\(key)".localized
    }

    // MARK: - Liked Songs Actions
    static let addToLikedSongs = "add_to_liked_songs".localized
    static let removeFromLikedSongs = "remove_from_liked_songs".localized

    // MARK: - Search Categories
    static let all = "all".localized

    // MARK: - Sync and Connection
    static let libraryOutOfSync = "library_out_of_sync".localized
    static let librarySyncMessage = "library_sync_message".localized
    static let offlineMode = "offline_mode".localized
    static let offlineModeMessage = "offline_mode_message".localized
    static let icloudConnectionRequired = "icloud_connection_required".localized

    // MARK: - Tutorial/Onboarding
    static let welcomeToQQPlayer = "welcome_to_qqplayer".localized
    static let signInToAppleId = "sign_in_to_apple_id".localized
    static let signInMessage = "sign_in_message".localized
    static let ifSignedInContinue = "if_signed_in_continue".localized
    static let enableIcloudDrive = "enable_icloud_drive".localized
    static let icloudDriveMessage = "icloud_drive_message".localized
    static let ifIcloudEnabledContinue = "if_icloud_enabled_continue".localized
    static let addYourMusic = "add_your_music".localized
    static let howToAddMusic = "how_to_add_music".localized
    static let openFilesApp = "open_files_app".localized
    static let navigateToIcloudDrive = "navigate_to_icloud_drive".localized
    static let findQQPlayerFolder = "find_qqplayer_folder".localized
    static let addYourMusicInstruction = "add_your_music_instruction".localized

    // MARK: - Tutorial Status Messages
    static let signedInToAppleId = "signed_in_to_apple_id".localized
    static let notSignedInToAppleId = "not_signed_in_to_apple_id".localized
    static let cannotDetectAppleIdStatus = "cannot_detect_apple_id_status".localized
    static let icloudDriveEnabled = "icloud_drive_enabled".localized
    static let icloudDriveNotEnabled = "icloud_drive_not_enabled".localized
    static let cannotDetectIcloudStatus = "cannot_detect_icloud_status".localized

    // MARK: - Tutorial Instructions
    static let findOpenFilesApp = "find_open_files_app".localized
    static let tapIcloudDriveSidebar = "tap_icloud_drive_sidebar".localized
    static let lookForQQPlayerFolder = "look_for_qqplayer_folder".localized
    static let copyMusicFiles = "copy_music_files".localized

    // MARK: - Library Processing
    static let processingColon = "processing_colon".localized
    static let waitingColon = "waiting_colon".localized

    // MARK: - Subtitles and descriptions
    static let yourFavorites = "your_favorites".localized
    static let yourPlaylists = "your_playlists".localized
    static let browseByArtist = "browse_by_artist".localized
    static let browseByAlbum = "browse_by_album".localized
    static let unknownAlbum = "unknown_album".localized
    static let unknownArtist = "unknown_artist".localized

    // MARK: - Dynamic strings with parameters
    static func songsCount(_ count: Int) -> String {
        if count == 1 {
            return "songs_count_singular".localized(with: count)
        } else {
            return "songs_count_plural".localized(with: count)
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
    static let equalizer = "equalizer".localized
    static let graphicEqualizer = "graphic_equalizer".localized
    static let enableEqualizer = "enable_equalizer".localized
    static let enableDisableEqDescription = "enable_disable_eq_description".localized

    // Manual EQ Presets
    static let manualEQPresets = "manual_eq_presets".localized

    // Common Presets (常用预设)
    static let presetCommon = "preset_common".localized
    static let presetCustom = "preset_custom".localized
    static let eqCustomTitle = "eq_custom_title".localized
    static let noManualPresetsCreated = "no_manual_presets_created".localized
    static let createManualEQDescription = "create_manual_eq_description".localized
    static let createManual16BandEQ = "create_manual_16band_eq".localized
    static let manual16BandEQ = "manual_16band_eq".localized
    static let manual16BandDescription = "manual_16band_description".localized
    static let adjustBandsAfterCreation = "adjust_bands_after_creation".localized
    static let frequencyBands = "frequency_bands".localized
    static let editEqualizer = "edit_equalizer".localized
    static let resetToFlat = "reset_to_flat".localized

    // Imported GraphicEQ Presets
    static let importedPresets = "imported_presets".localized
    static let noPresetsImported = "no_presets_imported".localized
    static let importGraphicEQDescription = "import_graphiceq_description".localized
    static let importedGraphicEQ = "imported_graphiceq".localized
    static let importGraphicEQFile = "import_graphiceq_file".localized

    // General EQ Settings
    static let globalSettings = "global_settings".localized
    static let globalGain = "global_gain".localized
    static let globalGainDescription = "global_gain_description".localized
    static let aboutGraphicEQFormat = "about_graphiceq_format".localized
    static let importGraphicEQFormatDescription = "import_graphiceq_format_description".localized
    static let frequencyGainPairDescription = "frequency_gain_pair_description".localized
    static let eqExport = "export".localized
    static let eqDelete = "delete".localized
    static let eqEdit = "edit".localized
    static let eqCancel = "cancel".localized
    static let eqDone = "done".localized
    static let eqSave = "save".localized
    static let eqCreate = "create".localized
    static let presetInfo = "preset_info".localized

    // GraphicEQ Import View
    static let importGraphicEQ = "import_graphiceq".localized
    static let presetName = "preset_name".localized
    static let enterPresetName = "enter_preset_name".localized
    static let importMethods = "import_methods".localized
    static let importFromTxtFile = "import_from_txt_file".localized
    static let pasteGraphicEQText = "paste_graphiceq_text".localized
    static let eqError = "error".localized
    static let formatInfo = "format_info".localized
    static let expectedGraphicEQFormat = "expected_graphiceq_format".localized
    static let frequencyGainPair = "frequency_gain_pair".localized

    // Text Import View
    static let pasteGraphicEQ = "paste_graphiceq".localized
    static let pasteGraphicEQTextSection = "paste_graphiceq_text_section".localized
    static let example = "example".localized
    static let eqImport = "import".localized

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

    static let failedToExport = "failed_to_export".localized
    static let failedToDelete = "failed_to_delete".localized

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
    static let eqCopied = "eq_copied".localized
    static let eqDeleteConfirmTitle = "eq_delete_confirm_title".localized
    static func eqDeleteConfirmMessage(_ name: String) -> String {
        return "eq_delete_confirm_message".localized(with: name)
    }
    static let eqManualParametric = "eq_manual_parametric".localized
    static let eqCreateManual = "eq_create_manual".localized
    static let eqBands = "eq_bands".localized
    static func eqBandsCount(_ used: Int, _ total: Int) -> String {
        return "eq_bands_count".localized(with: used, total)
    }
    static let eqParametricEditor = "eq_parametric_editor".localized
    static let eqAddBand = "eq_add_band".localized
    static let eqRemoveBand = "eq_remove_band".localized
    static let eqSelectedBand = "eq_selected_band".localized
    static func eqBandNumber(_ index: Int) -> String {
        return "eq_band_number".localized(with: index)
    }
    static let eqFrequency = "eq_frequency".localized
    static let eqGain = "eq_gain".localized
    static let eqQ = "eq_q".localized
    static let eqCreateManualDescription = "eq_create_manual_description".localized
    static let eqEditBandsHint = "eq_edit_bands_hint".localized
    static let eqImportedPreset = "eq_imported_preset".localized

    // MARK: - Audio Settings
    static let audioSettings = "audio_settings".localized
    static let dsdPlaybackMode = "dsd_playback_mode".localized
    static let dsdPlaybackModeDescription = "dsd_playback_mode_description".localized
    static let dsdModeAuto = "dsd_mode_auto".localized
    static let dsdModePCM = "dsd_mode_pcm".localized
    static let dsdModeDoP = "dsd_mode_dop".localized
    static let dsdModeAutoDescription = "dsd_mode_auto_description".localized
    static let dsdModePCMDescription = "dsd_mode_pcm_description".localized
    static let dsdModeDoDescription = "dsd_mode_dop_description".localized

    // MARK: - Sort Options
    static let sortDateNewest = "sort_date_newest".localized
    static let sortDateOldest = "sort_date_oldest".localized
    static let sortNameAZ = "sort_name_az".localized
    static let sortNameZA = "sort_name_za".localized
    static let sortSizeLargest = "sort_size_largest".localized
    static let sortSizeSmallest = "sort_size_smallest".localized

    // MARK: - Queue Actions
    static let playNext = "play_next".localized
    static let addToQueue = "add_to_queue".localized

    // MARK: - Sleep Timer
    static let sleepTimer = "sleep_timer".localized
    static let sleepTimerOff = "sleep_timer_off".localized
    static let sleepTimer15Minutes = "sleep_timer_15_minutes".localized
    static let sleepTimer30Minutes = "sleep_timer_30_minutes".localized
    static let sleepTimer45Minutes = "sleep_timer_45_minutes".localized
    static let sleepTimer60Minutes = "sleep_timer_60_minutes".localized
    static let cancelSleepTimer = "cancel_sleep_timer".localized
    // MARK: - Contextual hints (首次提示气泡)
    static let hintDismiss = "hint_dismiss".localized
    static let hintPlaybackTitle = "hint_playback_title".localized
    static let hintPlaybackLine1 = "hint_playback_line1".localized
    static let hintPlaybackLine2 = "hint_playback_line2".localized
    static let hintPlaybackLine3 = "hint_playback_line3".localized
    static let hintFullLyricsTitle = "hint_full_lyrics_title".localized
    static let hintFullLyricsLine1 = "hint_full_lyrics_line1".localized
    static let hintFullLyricsLine2 = "hint_full_lyrics_line2".localized
    static let hintSearchTitle = "hint_search_title".localized
    static let hintSearchLine1 = "hint_search_line1".localized
    /// macOS 歌词搜索页提示（iOS 的 line1 是滑动手势，Mac sheet 无此交互）
    static let hintSearchMacLine1 = "hint_search_mac_line1".localized

    // MARK: - Bulk Selection
    static let select = "select".localized
    static let selectAll = "select_all".localized
    static let bulkActions = "bulk_actions".localized
    static let addToLiked = "add_to_liked".localized
    static let removeFromLiked = "remove_from_liked".localized
    static let deleteFiles = "delete_files".localized
    static let deleteFilesConfirmation = "delete_files_confirmation".localized

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
    static let playOrderSequential = "play_order_sequential".localized
    static let playOrderShuffle = "play_order_shuffle".localized
    static let playOrderRepeatAll = "play_order_repeat_all".localized
    static let playOrderRepeatOne = "play_order_repeat_one".localized
    // MARK: - Feature guide (帮助中心)
    static let featureGuide = "feature_guide".localized
    static let featureGuideSectionPlayer = "feature_guide_section_player".localized
    static let featureGuideSectionLyrics = "feature_guide_section_lyrics".localized
    static let featureGuideSectionControls = "feature_guide_section_controls".localized
    static let featureGuideSectionSmart = "feature_guide_section_smart".localized
    static let featureGuideSectionMisc = "feature_guide_section_misc".localized
    static let featureGuideSwipeArtworkTitle = "feature_guide_swipe_artwork_title".localized
    static let featureGuideSwipeArtworkDetail = "feature_guide_swipe_artwork_detail".localized
    static let featureGuidePullToCloseTitle = "feature_guide_pull_to_close_title".localized
    static let featureGuidePullToCloseDetail = "feature_guide_pull_to_close_detail".localized
    static let featureGuideExpandControlsTitle = "feature_guide_expand_controls_title".localized
    static let featureGuideExpandControlsDetail = "feature_guide_expand_controls_detail".localized
    static let featureGuideOpenFullLyricsTitle = "feature_guide_open_full_lyrics_title".localized
    static let featureGuideOpenFullLyricsDetail = "feature_guide_open_full_lyrics_detail".localized
    static let featureGuideSearchLyricsTitle = "feature_guide_search_lyrics_title".localized
    static let featureGuideSearchLyricsDetail = "feature_guide_search_lyrics_detail".localized
    static let featureGuideKaraokeStartTitle = "feature_guide_karaoke_start_title".localized
    static let featureGuideKaraokeStartDetail = "feature_guide_karaoke_start_detail".localized
    static let featureGuideKaraokeControlsTitle = "feature_guide_karaoke_controls_title".localized
    static let featureGuideKaraokeControlsDetail = "feature_guide_karaoke_controls_detail".localized
    static let featureGuideKaraokeExitTitle = "feature_guide_karaoke_exit_title".localized
    static let featureGuideKaraokeExitDetail = "feature_guide_karaoke_exit_detail".localized
    static let featureGuideOrderModesTitle = "feature_guide_order_modes_title".localized
    static let featureGuideOrderModesDetail = "feature_guide_order_modes_detail".localized
    static let featureGuideSmartSourceTitle = "feature_guide_smart_source_title".localized
    static let featureGuideSmartSourceDetail = "feature_guide_smart_source_detail".localized
    static let featureGuideSmartWhereTitle = "feature_guide_smart_where_title".localized
    static let featureGuideSmartWhereDetail = "feature_guide_smart_where_detail".localized
    static let featureGuideEQTitle = "feature_guide_eq_title".localized
    static let featureGuideEQDetail = "feature_guide_eq_detail".localized
    static let featureGuideDarkModeTitle = "feature_guide_dark_mode_title".localized
    static let featureGuideDarkModeDetail = "feature_guide_dark_mode_detail".localized
    static let featureGuideImportTitle = "feature_guide_import_title".localized
    static let featureGuideImportDetail = "feature_guide_import_detail".localized

    // MARK: - Smart playlists (自动歌单)
    static let smartRecentAdded = "smart_recent_added".localized
    static let smartRecentPlayed = "smart_recent_played".localized
    static let smartTopPlayed = "smart_top_played".localized
    static let smartDecades = "smart_decades".localized
    static let smartEmptyRecentPlayed = "smart_empty_recent_played".localized
    static let smartEmptyTopPlayed = "smart_empty_top_played".localized
    static let smartEmptyDecade = "smart_empty_decade".localized
    static let smartLoadFailed = "smart_load_failed".localized

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
    static let whatsNewTitle = "whats_new_title".localized
    static let whatsNewItemHints = "whats_new_item_hints".localized
    static let whatsNewItemGuide = "whats_new_item_guide".localized
    static let whatsNewItemAnnouncement = "whats_new_item_announcement".localized
}
