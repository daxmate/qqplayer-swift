//
//  FavoriteCurrentSongIntent.swift
//  QQPlayer
//
//  Explicit App Shortcut for phrases such as "Like this song in QQPlayer".
//  The audio affinity schema can handle named SongEntity values on iOS 27,
//  but Siri does not consistently bind "this song" to the current QQPlayer
//  track. This parameter-free intent makes that use case deterministic.
//

import AppIntents

@available(iOS 26.0, *)
struct FavoriteCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Favorite Current Song"
    static let description = IntentDescription(
        "Adds the currently playing QQPlayer song to Liked Songs.",
        categoryName: "Playback"
    )
    static let openAppWhenRun = false

    @Dependency var playback: IntentPlaybackService

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let track = playback.currentTrack else {
            throw FavoriteCurrentSongError.nothingPlaying
        }

        if try playback.isFavorite(trackStableId: track.stableId) {
            return .result(dialog: IntentDialog(
                "\(DisplayScriptNormalizer.display(track.title)) is already in your Liked Songs."
            ))
        }

        try playback.setFavorite(trackStableId: track.stableId, isFavorite: true)
        return .result(dialog: IntentDialog(
            "Added \(DisplayScriptNormalizer.display(track.title)) to your Liked Songs."
        ))
    }
}

@available(iOS 26.0, *)
enum FavoriteCurrentSongError: Error, CustomLocalizedStringResourceConvertible {
    case nothingPlaying

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingPlaying:
            "There isn't a song playing in QQPlayer right now."
        }
    }
}
