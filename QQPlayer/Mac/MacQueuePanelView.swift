//
//  MacQueuePanelView.swift
//  QQPlayer
//
//  macOS 播放队列面板（2026-09-21 从 MacPlayerView.swift 原样搬出，纯搬家，无逻辑变更）。
//  同族文件：
//    · Mac/MacPlayerView.swift                  — 播放页主片：视图壳 + body + 播放顺序/收藏/睡眠定时
//    · Mac/MacPlayerView+PlayerSection.swift    — 播放区（封面/进度条/控制条/频谱）
//
//  ⚠️ 可见性：整类型被主片 `body` 引用，故为 internal（原 `private struct`）。
//

import SwiftUI

// MARK: - 播放队列面板（B 组队列排序持久化，2026-09-03）

/// macOS 播放队列管理：显示当前队列，支持拖拽重排 / 移除（当前播放项除外）/
/// 点行跳转。每次变更经 PlayerEngine.moveQueueItems/removeQueueItem(stableId:)/jumpToQueueIndex
/// 立即持久化（savePlayerState 落盘 queueTrackIds），重启 restoreUIStateOnly 恢复——
/// web 版 persistQueueOrder/applyQueueOrder 语义的 Swift 端形态（队列=播放引擎队列，
/// 启动恢复 = 现成 QQPlayerState 恢复链路）。
/// 分片：跨文件可见（原 private）
struct MacQueuePanelView: View {
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: DesignTokens.space0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private var header: some View {
        HStack {
            Text(Localized.playingQueue)
                .font(.headline)
            Spacer()
            Button("close".localized) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(DesignTokens.space12)
    }

    @ViewBuilder
    private var content: some View {
        if player.playbackQueue.isEmpty {
            VStack(spacing: DesignTokens.space12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: DesignTokens.font40))
                    .foregroundColor(.secondary)
                Text(Localized.noSongsInQueue)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: DesignTokens.space0) {
                if !player.isQueueReorderable {
                    Text(Localized.queueShuffleDisabledHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DesignTokens.space12)
                        .padding(.vertical, DesignTokens.space6)
                }
                List {
                    ForEach(Array(player.playbackQueue.enumerated()), id: \.element.stableId) { index, track in
                        row(for: track, at: index)
                    }
                    // macOS List：onMove 直接支持鼠标拖拽重排（无需 iOS EditMode）
                    .onMove(perform: player.moveQueueItems)
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(for track: Track, at index: Int) -> some View {
        let isCurrent = index == player.currentIndex
        return HStack(spacing: DesignTokens.space10) {
            Text("\(index + 1)")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundColor(appAccentColor)
                    .frame(width: 14)
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
            }

            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(track.displayTitle)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                if let artist = try? LibraryReads.artistDisplayName(
                    forTrackStableId: track.stableId,
                    fallbackArtistId: track.artistId
                ) {
                    Text(artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()

            if !isCurrent {
                Button {
                    // 按 stableId 移除（2026-09-12 审计 P2）：渲染期下标与引擎数组可能不一致，
                    // 旧写法把 ForEach 的 index 直接传给 removeQueueItems(at:) 会越界/错位。
                    player.removeQueueItem(stableId: track.stableId)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(Localized.removeFromQueue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isCurrent else { return }
            Task { await player.jumpToQueueIndex(index) }
        }
    }
}
