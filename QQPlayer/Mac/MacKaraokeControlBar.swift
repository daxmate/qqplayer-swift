//
//  MacKaraokeControlBar.swift
//  QQPlayer
//
//  macOS 跟唱控制条（QQPlayerMac target only）：单行 · 通栏 · accent 实心播放键。
//
//  与 iOS 的 KaraokeControlBar 语义完全一致（只消费 KaraokeController 状态，动作逐字相同），
//  差异只在观感：iOS 版靠深色模糊全屏背景撑 .ultraThinMaterial 材质，落到 Mac 浅色面板里会发灰、
//  对比度低、三键与胶囊高矮不齐；这里改为「中性半透明底 + 细描边 + hover 反馈」的 macOS 观感
//  （用户 2026-09-13 拍板：单行布局 / 播放键 accent 实心圆 / 通栏底条）。
//
//  - 播放控制：上一句 / 播放暂停 / 下一句（歌词行级，用户 2026-08-29 拍板）
//  - 倍速：点击弹出速度菜单（除当前档位外的其他速度点选），非 1.0 高亮
//  - 单句循环：点击切换，开启高亮
//  - AB 循环：单击切换（用户 2026-08-29 拍板：不用长按）——未启用 → 以当前句为 A
//    进入等选终点态（显示 "AB…" + 提示），已启用 → 单击退出
//  状态全部读自 KaraokeController.shared（本组件只消费，不做决策）。
//
//  keyboard 提示只写 MacKeyboardShortcuts.swift 已确证存在的组合（Space / A / B / [ ]）。
//

import SwiftUI

struct MacKaraokeControlBar: View {
    @ObservedObject private var karaoke = KaraokeController.shared
    @ObservedObject private var progress = PlayerEngine.shared.progress
    @ObservedObject private var playerEngine = PlayerEngine.shared
    let accentColor: Color

    /// 当前句 index（AB 单击取 A 点）；还没到第一句时为 nil
    private var currentLineIndex: Int? {
        LyricTiming.activeLineIndex(time: progress.playbackTime, in: karaoke.currentLines)
    }

    /// 等选终点态：AB 已启用但 b 未设（点歌词设终点前）
    private var isWaitingABEnd: Bool {
        guard let ab = karaoke.abLoop else { return false }
        return ab.b == nil
    }

    private var abLabel: String {
        isWaitingABEnd ? "AB…" : "AB"
    }

    var body: some View {
        VStack(spacing: DesignTokens.space6) {
            if isWaitingABEnd {
                abEndHint
            }

            HStack(spacing: DesignTokens.space14) {
                HStack(spacing: DesignTokens.space12) {
                    prevLineButton
                    playPauseButton
                    nextLineButton
                }

                // 播放控制组与模式组之间的竖向分隔线（无渐变托盘，靠留白与分隔线分组）
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 22)

                HStack(spacing: DesignTokens.space8) {
                    speedButton
                    singleLineLoopButton
                    abButton
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.space16)
        .padding(.vertical, DesignTokens.space10)
    }

    // MARK: - 播放控制（上一句 / 播放暂停 / 下一句）

    private var prevLineButton: some View {
        KaraokeCircleButton(
            size: 30,
            isAccentFilled: false,
            accentColor: accentColor,
            action: {
                KaraokeController.shared.stepLine(delta: -1, currentTime: progress.playbackTime)
            }
        ) {
            Image(systemName: "chevron.up")
                .font(.system(size: DesignTokens.font12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.85))
        }
        .accessibilityLabel(NSLocalizedString("karaoke_previous_line", value: "Previous line", comment: ""))
        .help(NSLocalizedString("karaoke_previous_line", value: "Previous line", comment: ""))
    }

    private var playPauseButton: some View {
        KaraokeCircleButton(
            size: 38,
            isAccentFilled: true,
            accentColor: accentColor,
            action: {
                if playerEngine.isPlaying {
                    playerEngine.pause()
                } else {
                    playerEngine.play()
                }
            }
        ) {
            Image(systemName: playerEngine.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: DesignTokens.font15, weight: .bold))
                .foregroundColor(.white)
        }
        .shadow(color: accentColor.opacity(0.35), radius: 6, y: 2)
        .accessibilityLabel(playerEngine.isPlaying
            ? NSLocalizedString("karaoke_pause", value: "Pause", comment: "")
            : NSLocalizedString("karaoke_play", value: "Play", comment: ""))
        .help(playerEngine.isPlaying
            ? NSLocalizedString("karaoke_pause", value: "Pause", comment: "") + " (Space)"
            : NSLocalizedString("karaoke_play", value: "Play", comment: "") + " (Space)")
    }

    private var nextLineButton: some View {
        KaraokeCircleButton(
            size: 30,
            isAccentFilled: false,
            accentColor: accentColor,
            action: {
                KaraokeController.shared.stepLine(delta: 1, currentTime: progress.playbackTime)
            }
        ) {
            Image(systemName: "chevron.down")
                .font(.system(size: DesignTokens.font12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.85))
        }
        .accessibilityLabel(NSLocalizedString("karaoke_next_line", value: "Next line", comment: ""))
        .help(NSLocalizedString("karaoke_next_line", value: "Next line", comment: ""))
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
                HStack(spacing: DesignTokens.space3) {
                    Text(String(format: "%.1fx", karaoke.speed))
                    Image(systemName: "chevron.down")
                        .font(.system(size: DesignTokens.font8, weight: .bold))
                }
            }
        }
        .accessibilityLabel(String(format: NSLocalizedString("karaoke_speed_label", value: "Speed %.1f", comment: ""), karaoke.speed))
        .help(String(format: NSLocalizedString("karaoke_speed_label", value: "Speed %.1f", comment: ""), karaoke.speed) + " ([ / ])")
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
        .help(NSLocalizedString("karaoke_single_line_loop", value: "Single-line loop", comment: ""))
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
        .help(NSLocalizedString("karaoke_ab_loop", value: "AB loop", comment: "") + " (A / B)")
    }

    // MARK: - AB 等选终点提示

    private var abEndHint: some View {
        Text(NSLocalizedString("karaoke_ab_end_hint", value: "Tap a lyric line to set the AB end point", comment: ""))
            .font(.system(size: DesignTokens.font12, weight: .medium))
            .foregroundColor(accentColor)
            .padding(.horizontal, DesignTokens.space10)
            .padding(.vertical, DesignTokens.space4)
            .background(Capsule().fill(accentColor.opacity(0.12)))
    }

    // MARK: - 胶囊样式（三个模式键共用，保证同高同款）

    private func pill<Content: View>(isHighlighted: Bool, @ViewBuilder content: () -> Content) -> some View {
        KaraokePill(isHighlighted: isHighlighted, accentColor: accentColor, content: content)
    }
}

// MARK: - 圆钮（中性款 / accent 实心款共用一套 hover 语义）

/// 圆钮：上一句 / 下一句为中性款（30pt），播放 / 暂停为 accent 实心款（38pt）。
/// hover：中性填充 0.06→0.12、描边 0.12→0.18；accent 实心款改提亮 0.06。
private struct KaraokeCircleButton<Label: View>: View {
    let size: CGFloat
    let isAccentFilled: Bool
    let accentColor: Color
    let action: () -> Void
    private let label: Label

    @State private var isHovered = false

    init(
        size: CGFloat,
        isAccentFilled: Bool,
        accentColor: Color,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.size = size
        self.isAccentFilled = isAccentFilled
        self.accentColor = accentColor
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(width: size, height: size)
                .background(Circle().fill(fillColor))
                .overlay(Circle().stroke(strokeColor, lineWidth: 1))
                .brightness(isAccentFilled && isHovered ? 0.06 : 0)
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var fillColor: Color {
        isAccentFilled ? accentColor : Color.primary.opacity(isHovered ? 0.12 : 0.06)
    }

    private var strokeColor: Color {
        isAccentFilled ? .clear : Color.primary.opacity(isHovered ? 0.18 : 0.12)
    }
}

// MARK: - 模式胶囊（倍速 / 单句循环 / AB 同高同款）

private struct KaraokePill<Content: View>: View {
    let isHighlighted: Bool
    let accentColor: Color
    private let content: Content

    @State private var isHovered = false

    init(isHighlighted: Bool, accentColor: Color, @ViewBuilder content: () -> Content) {
        self.isHighlighted = isHighlighted
        self.accentColor = accentColor
        self.content = content()
    }

    var body: some View {
        content
            .font(.system(size: DesignTokens.font12, weight: .semibold))
            .foregroundColor(isHighlighted ? accentColor : Color.primary.opacity(0.85))
            .padding(.horizontal, DesignTokens.space12)
            .padding(.vertical, DesignTokens.space6)
            .background(Capsule().fill(backgroundColor))
            .overlay(Capsule().stroke(borderColor, lineWidth: 1))
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var backgroundColor: Color {
        isHighlighted ? accentColor.opacity(0.15) : Color.primary.opacity(isHovered ? 0.12 : 0.06)
    }

    private var borderColor: Color {
        isHighlighted ? accentColor.opacity(0.6) : Color.primary.opacity(isHovered ? 0.18 : 0.12)
    }
}
