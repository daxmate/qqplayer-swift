//
//  IntentArtworkService.swift
//  QQPlayer
//
//  意图层（Siri / 快捷指令 / Spotlight）读封面的**唯一入口**（2026-09-20 立）。
//
//  为什么需要它：意图没有 SwiftUI 环境链（`@Environment` 取不到任何东西），
//  `AppIntentsDependencies.register()` 注册的 `@Dependency` 服务就是意图层唯一通道——
//  与 `IntentPlaybackService` / `IntentEntityStore` 同款（那两个包住 PlayerEngine /
//  AppCoordinator / DatabaseManager，意图不直连）。
//
//  触发原因：`Snippets/SongCardSnippetIntent.swift` 里声明了 `SongCardSnippetView`（SwiftUI 视图）
//  ⇒ 该文件属于 `ViewSharedSingletonContractTests`（口径 = 声明了 SwiftUI 视图的文件）的扫描范围，
//  原先的 `await ArtworkManager.shared.getThumbnail(…)` 随口径补齐显形。改走本入口后，
//  该文件直连归零。本文件自身不声明 View，不在棘轮范围内 —— 判据始终是
//  「这个语义有没有唯一入口」，不是「把 `.shared` 藏进别处」。
//

#if canImport(MediaIntents)
    import AppIntents
    import UIKit

    @available(iOS 27.0, *)
    @MainActor
    final class IntentArtworkService {
        /// 单曲封面缩略图（卡片渲染用；纯转发 `ArtworkManager`，不改缓存/像素语义）。
        func thumbnail(for track: Track, maxPixelSize: CGFloat) async -> UIImage? {
            await ArtworkManager.shared.getThumbnail(for: track, maxPixelSize: maxPixelSize)
        }
    }
#endif
