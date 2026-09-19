//
//  DatabaseSuspensionCoordinator.swift
//  QQPlayer
//
//  iOS 进程被挂起前暂停 GRDB（0xdead10cc 防护）：仅「后台且未播放」时暂停。
//
//  2026-09-19 从 DatabaseManager.swift 原样搬出（纯搬家）。
//

import Combine
import Foundation
#if os(iOS)
    import UIKit
#endif
@preconcurrency import GRDB

// MARK: - Suspension coordination (0xdead10cc)

/// Suspends GRDB when the app is about to be suspended by iOS.
///
/// The database lives in the app group container. If SQLite still holds a
/// file lock when the process is suspended, the kernel kills the app with
/// 0xdead10cc - the most frequent crash across all shipped versions.
///
/// Background audio keeps the process alive and legitimately writing (play
/// counts, queue state), so the database is only suspended while the app is
/// backgrounded AND playback is stopped. It resumes on foregrounding or when
/// playback restarts (e.g. from the lock screen or a remote command).
@MainActor
final class DatabaseSuspensionCoordinator {
    static let shared = DatabaseSuspensionCoordinator()

    private var observers: [NSObjectProtocol] = []
    private var playbackCancellable: AnyCancellable?
    private var isInBackground = false
    private var isPlaying = false
    private var isSuspended = false

    private init() {}

    func start() {
        guard observers.isEmpty else { return }

        #if os(iOS)
            let backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { @Sendable _ in
                Task { @MainActor in
                    let coordinator = DatabaseSuspensionCoordinator.shared
                    coordinator.isInBackground = true
                    coordinator.apply()
                }
            }
            observers.append(backgroundObserver)

            let foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: nil
            ) { @Sendable _ in
                Task { @MainActor in
                    let coordinator = DatabaseSuspensionCoordinator.shared
                    coordinator.isInBackground = false
                    coordinator.apply()
                }
            }
            observers.append(foregroundObserver)
        #endif

        isPlaying = PlayerEngine.shared.isPlaying
        playbackCancellable = PlayerEngine.shared.$isPlaying
            .removeDuplicates()
            .sink { playing in
                Task { @MainActor in
                    let coordinator = DatabaseSuspensionCoordinator.shared
                    coordinator.isPlaying = playing
                    coordinator.apply()
                }
            }
    }

    private func apply() {
        let shouldSuspend = isInBackground && !isPlaying
        guard shouldSuspend != isSuspended else { return }
        isSuspended = shouldSuspend
        NotificationCenter.default.post(
            name: shouldSuspend ? Database.suspendNotification : Database.resumeNotification,
            object: nil
        )
        print(shouldSuspend
            ? "🛑 Database suspended (backgrounded, not playing)"
            : "▶️ Database resumed")
    }
}
