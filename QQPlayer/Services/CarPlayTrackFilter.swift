//
//  CarPlayTrackFilter.swift
//  QQPlayer
//
//  CarPlay 连接时「哪些曲目可播」的**唯一入口**（2026-09-20 立）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  为什么要有这个文件（2026-09-20 棘轮口径补齐批）
//  ════════════════════════════════════════════════════════════════════════════
//  「CarPlay 环境 → 剔除 ogg / opus / dsf / dff」这段判据此前在 **5 个视图文件**里
//  各写一遍（`ContentView` / `PlaylistDetailScreen` / `TrackListView` /
//  `ArtistDetailScreen` / `AlbumViews`）：名单是同一份字面量、判据是同一个
//  `SFBAudioEngineManager.shared` 直连。
//    - 同一行为五处实现 → 改一处必漏四处（前例：封面解析散落 5 处、锁屏封面第三套）；
//    - 视图层直连单例（棘轮 `ViewSharedSingletonContractTests` 的口径补齐后全部显形）。
//  按纪律（**行为单一事实源 + 同类消费点全查**）：判据与名单收口到本文件，视图只调用
//  `isActive` / `isCompatible(_:)` / `filtered(_:)`。
//
//  行为与迁移前**逐字一致**：名单内容、扩展名小写化、过滤时机均未变；视图仍在同一处
//  读环境值（原先直读 `.shared` 本就不产生订阅，现在同样不产生 → 刷新时机不变）。
//
// target: ios-only（CarPlay 场景是 iOS 专属；Mac 侧无消费点）

import Foundation

/// CarPlay 连接时的曲目可用性判据（唯一入口）。
/// `@MainActor`：环境值自身就是 MainActor 隔离（`SFBAudioEngineManager`），判据随它同隔离域。
@MainActor
enum CarPlayTrackFilter {
    /// CarPlay 环境下不可用的格式：SFBAudioEngine 侧不支持（`ogg` / `opus` / `dsf` / `dff`）。
    static let incompatibleFormats: Set<String> = ["ogg", "opus", "dsf", "dff"]

    /// 当前是否处于 CarPlay 环境。
    static var isActive: Bool { SFBAudioEngineManager.shared.isCarPlayEnvironment }

    /// 单个曲目在 CarPlay 环境下是否可用。
    static func isCompatible(_ track: Track) -> Bool {
        !incompatibleFormats.contains(URL(fileURLWithPath: track.path).pathExtension.lowercased())
    }

    /// CarPlay 连接时剔除不可用格式；未连接时原样返回（顺序不变）。
    static func filtered(_ tracks: [Track]) -> [Track] {
        guard isActive else { return tracks }
        return tracks.filter(isCompatible)
    }
}
