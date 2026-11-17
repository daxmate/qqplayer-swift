//
//  MacTrackFavoriteButton.swift
//  QQPlayer
//
//  macOS 曲目行尾「♥ 收藏」按钮的**唯一实现**：歌曲 Table 行与分组折叠行共用。
//  QQPlayerMac target only.
//
//  数据源纪律（2026-11-16 C 阶段抽取）：状态不在按钮内自持 —— 宿主从
//  MacTrackMenuModel.favoriteIds 读出后传入（.favoritesChanged 由宿主的
//  .macTrackMenu 宿主统一重载，全仓一份）；动作走既有唯一入口
//  AppCoordinator.toggleFavorite(trackStableId:)。严禁另写第二份收藏 UI。
//

import SwiftUI

struct MacTrackFavoriteButton: View {
    @Environment(AppCoordinator.self) private var appCoordinator
    @Environment(\.appAccentColor) private var appAccentColor

    let track: Track
    /// 当前是否已收藏（调用方读 MacTrackMenuModel.favoriteIds）
    let isFavorite: Bool

    var body: some View {
        Button {
            toggleFavorite()
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundColor(isFavorite ? appAccentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs)
    }

    private func toggleFavorite() {
        do {
            try appCoordinator.toggleFavorite(trackStableId: track.stableId)
        } catch {
            AppLog.error(.general, "❌ Track list favorite toggle failed: \(error.localizedDescription)")
        }
    }
}
