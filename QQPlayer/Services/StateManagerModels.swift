//
//  StateManagerModels.swift
//  QQPlayer
//
//  Player state persistence model and StateManager errors
//

import Foundation

struct PlayerState: Codable {
    let currentTrackStableId: String?
    let playbackTime: TimeInterval
    let isPlaying: Bool
    let queueTrackIds: [String]
    let currentIndex: Int
    let isRepeating: Bool
    let isShuffled: Bool
    let isLoopingSong: Bool
    let originalQueueTrackIds: [String]
    let lastSavedAt: Date
}

enum StateManagerError: Error {
    case fileNotFound
    case invalidData
}
