//
//  KaraokeControlBar.swift
//  QQPlayer
//
//  跟唱模式底部控制条：播放控制三键 + 倍速 / 单句循环 / AB 循环（对齐桌面 ControlBar 语义）
//

import SwiftUI

/// 跟唱模式控制条（桌面 ControlBar 的 iOS 版）：播放控制三键 + 模式三按钮。
/// - 播放控制：上一句 / 播放暂停 / 下一句（歌词行级，用户 2026-08-29 拍板）
/// - 倍速：点击弹出速度菜单（除当前档位外的其他速度点选），非 1.0 高亮
/// - 单句循环：点击切换，开启高亮
/// - AB 循环：单击切换（用户 2026-08-29 拍板：不用长按）——未启用 → 以当前句为 A
///   进入等选终点态（显示 "AB…" + 提示），已启用 → 单击退出
/// 状态全部读自 KaraokeController.shared（本组件只消费，不做决策）。
struct KaraokeControlBar: View {
    @ObservedObject private var karaoke = KaraokeController.shared
    @Environment(PlayerEngine.self) private var playerEngine
    /// App 强调色（读环境值；根注入见 ContentView）
    @Environment(\.appAccentColor) private var accentColor

    /// 当前句 index（AB 单击取 A 点）；还没到第一句时为 nil
    private var currentLineIndex: Int? {
        LyricTiming.activeLineIndex(time: playerEngine.progress.playbackTime, in: karaoke.currentLines)
    }

    /// 等选终点态：AB 已启用但 b 未设（长按后、点歌词设终点前）
    private var isWaitingABEnd: Bool {
        guard let ab = karaoke.abLoop else { return false }
        return ab.b == nil
    }

    private var abLabel: String {
        isWaitingABEnd ? "AB…" : "AB"
    }

    var body: some View {
        VStack(spacing: DesignTokens.space10) {
            if isWaitingABEnd {
                Text(NSLocalizedString("karaoke_ab_end_hint", value: "Tap a lyric line to set the AB end point", comment: ""))
                    .font(.caption2.weight(.medium))
                    .foregroundColor(accentColor)
                    .padding(.horizontal, DesignTokens.space12)
                    .padding(.vertical, DesignTokens.space4)
                    .background(Capsule().fill(.ultraThinMaterial))
            }

            // 播放控制三键：上一句 / 播放暂停 / 下一句（歌词行级，用户 2026-08-29 拍板）
            HStack(spacing: DesignTokens.space24) {
                prevLineButton
                playPauseButton
                nextLineButton
            }

            HStack(spacing: DesignTokens.space10) {
                speedButton
                singleLineLoopButton
                abButton
            }
        }
        .padding(.vertical, DesignTokens.space6)
    }

    // MARK: - 播放控制（上一句 / 播放暂停 / 下一句）

    private var prevLineButton: some View {
        Button {
            KaraokeController.shared.stepLine(delta: -1, currentTime: playerEngine.progress.playbackTime)
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: DesignTokens.font17, weight: .semibold))
                .foregroundColor(.primary.opacity(0.85))
                .frame(width: 42, height: 42)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(NSLocalizedString("karaoke_previous_line", value: "Previous line", comment: ""))
    }

    private var playPauseButton: some View {
        Button {
            if playerEngine.isPlaying {
                playerEngine.pause()
            } else {
                playerEngine.play()
            }
        } label: {
            Image(systemName: playerEngine.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: DesignTokens.font22, weight: .semibold))
                .foregroundColor(accentColor)
                .frame(width: 54, height: 54)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(playerEngine.isPlaying
            ? NSLocalizedString("karaoke_pause", value: "Pause", comment: "")
            : NSLocalizedString("karaoke_play", value: "Play", comment: ""))
    }

    private var nextLineButton: some View {
        Button {
            KaraokeController.shared.stepLine(delta: 1, currentTime: playerEngine.progress.playbackTime)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: DesignTokens.font17, weight: .semibold))
                .foregroundColor(.primary.opacity(0.85))
                .frame(width: 42, height: 42)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(NSLocalizedString("karaoke_next_line", value: "Next line", comment: ""))
    }

    // MARK: - 倍速

    /// 倍速：点击弹出速度菜单（除当前档位外的其他速度点选，用户 2026-08-29 拍板）
    private var speedButton: some View {
        Menu {
            ForEach(KaraokeController.speedLevels.filter { $0 != karaoke.speed }, id: \.self) { level in
                Button {
                    karaoke.setSpeed(level)
                } label: {
                    Text(String(format: "%.1fx", level))
                }
            }
        } label: {
            pill(isHighlighted: karaoke.speed != 1.0) {
                Text(String(format: "%.1fx", karaoke.speed))
            }
        }
        .accessibilityLabel(String(format: NSLocalizedString("karaoke_speed_label", value: "Speed %.1f", comment: ""), karaoke.speed))
    }

    // MARK: - 单句循环

    private var singleLineLoopButton: some View {
        Button {
            karaoke.toggleSingleLineLoop()
        } label: {
            pill(isHighlighted: karaoke.isSingleLineLoop) {
                Image(systemName: "repeat")
            }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(NSLocalizedString("karaoke_single_line_loop", value: "Single-line loop", comment: ""))
    }

    // MARK: - AB 循环

    /// AB 按钮：单击切换（用户 2026-08-29 拍板：不用长按）。
    /// 未启用 → 以当前句为 A 进入等选终点；已启用 → 退出 AB 循环。
    /// 等选终点态点击歌词行即设 B（clickLine 决策）。
    private var abButton: some View {
        Button {
            if karaoke.abLoop != nil {
                karaoke.exitABLoop()
            } else {
                guard let index = currentLineIndex else { return }
                #if os(iOS)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
                karaoke.enterABLoop(currentLine: index)
            }
        } label: {
            pill(isHighlighted: karaoke.abLoop != nil) {
                Text(abLabel)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(NSLocalizedString("karaoke_ab_loop", value: "AB loop", comment: ""))
        .accessibilityHint(NSLocalizedString("karaoke_ab_loop_hint", value: "Tap once to start at the current line, tap a lyric line to set the end; tap again to exit", comment: ""))
    }

    // MARK: - 胶囊样式

    private func pill<Content: View>(isHighlighted: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.footnote.weight(.semibold))
            .foregroundColor(isHighlighted ? accentColor : .primary.opacity(0.85))
            .padding(.horizontal, DesignTokens.space16)
            .padding(.vertical, DesignTokens.space8)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().fill(isHighlighted ? accentColor.opacity(0.16) : Color.clear))
            .overlay(
                Capsule().stroke(
                    isHighlighted ? accentColor.opacity(0.7) : Color.primary.opacity(0.1),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
    }
}

// MARK: - Preview

#Preview {
    KaraokeControlBar()
        .environment(\.appAccentColor, .blue)
        .padding()
}
