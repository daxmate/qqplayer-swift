//
//  UpdateAudioAffinityIntent.swift
//  QQPlayer
//
//  "Like this song" / "Unlike that" via the .audio.updateAudioAffinity
//  schema. QQPlayer only has favorites: like adds one, dislike and unset
//  both remove it.
//

#if canImport(MediaIntents)
    import AppIntents

    @available(iOS 27.0, *)
    @AppIntent(schema: .audio.updateAudioAffinity)
    struct UpdateAudioAffinityIntent {
        // MARK: Schema parameters

        var affinityState: AffinityState
        var target: AudioEntity

        // MARK: Dependencies

        @Dependency var playback: IntentPlaybackService

        // MARK: Perform

        @MainActor
        func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
            guard case .song(let song) = target else {
                throw AppIntentError(wrapping: AudioIntentError.unsupportedTarget)
            }

            let isLiked = (affinityState == .like)
            try playback.setFavorite(trackStableId: song.id, isFavorite: isLiked)

            let dialog: IntentDialog
            switch affinityState {
            case .like:
                dialog = IntentDialog(
                    LocalizedStringResource(
                        "Added \(DisplayScriptNormalizer.display(song.title)) to your favorites.",
                        comment: "Spoken confirmation when the person likes a song. Argument 1 is the song title."
                    )
                )
            case .dislike, .unset:
                dialog = IntentDialog(
                    LocalizedStringResource(
                        "Removed \(DisplayScriptNormalizer.display(song.title)) from your favorites.",
                        comment: "Spoken confirmation when the person unlikes a song. Argument 1 is the song title."
                    )
                )
            }

            return .result(
                dialog: dialog,
                snippetIntent: SongCardSnippetIntent(trackStableId: song.id)
            )
        }
    }

#endif // canImport(MediaIntents)
