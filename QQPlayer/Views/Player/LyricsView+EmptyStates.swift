//
//  LyricsView+EmptyStates.swift
//  QQPlayer
//
//  全屏歌词页**占位状态**：加载中 / 纯音乐（无人声）/ 无歌词 三种占位视图
//  （共用同一套玻璃卡片 + 主题色光晕视觉）。
//
//  2026-09-21 从 LyricsView.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Player/LyricsView.swift               — 视图壳：stored property + `body` 装配 + `#Preview`
//    · Views/Player/LyricsView+LyricsContent.swift — 同步 / 纯文本歌词渲染 + 活动行自动滚动
//
// target: ios-only（LyricsView 分片：消费端全在 iOS；Mac 侧为 MacLyricsView）
//

import SwiftUI

extension LyricsView {
    // MARK: - States

    /// 分片：跨文件可见（原 private）
    var instrumentalView: some View {
        VStack(spacing: DesignTokens.space0) {
            Spacer()

            VStack(spacing: DesignTokens.space32) {
                // Animated icon with glass background
                ZStack {
                    // Large outer glow
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    accentColor.opacity(0.4),
                                    accentColor.opacity(0.2),
                                    accentColor.opacity(0.05),
                                    Color.clear,
                                ]),
                                center: .center,
                                startRadius: 0,
                                endRadius: 100
                            )
                        )
                        .frame(width: 200, height: 200)
                        .blur(radius: 30)

                    // Glass circle
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            accentColor.opacity(0.6),
                                            accentColor.opacity(0.3),
                                            accentColor.opacity(0.1),
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )
                        .frame(width: 120, height: 120)
                        .shadow(
                            color: accentColor.opacity(0.3),
                            radius: 25,
                            x: 0,
                            y: 10
                        )

                    Image(systemName: "music.note")
                        .font(.system(size: DesignTokens.font50, weight: .medium))
                        .foregroundColor(.primary)
                        .shadow(color: accentColor.opacity(0.6), radius: 15)
                }

                VStack(spacing: DesignTokens.space12) {
                    Text("lyrics_empty_instrumental_title".localized)
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text("lyrics_empty_instrumental_subtitle".localized)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .padding(DesignTokens.space40)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.radius28)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: DesignTokens.radius28)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    accentColor.opacity(0.3),
                                    Color.primary.opacity(0.15),
                                    accentColor.opacity(0.2),
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )

                    RoundedRectangle(cornerRadius: DesignTokens.radius28)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    accentColor.opacity(0.05),
                                    Color.clear,
                                    accentColor.opacity(0.08),
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: accentColor.opacity(0.2), radius: 35, x: 0, y: 15)
            )
            .padding(.horizontal, DesignTokens.space40)

            Spacer()
        }
    }

    /// 分片：跨文件可见（原 private）
    var noLyricsView: some View {
        VStack(spacing: DesignTokens.space0) {
            Spacer()

            VStack(spacing: DesignTokens.space32) {
                // Animated icon with glass background
                ZStack {
                    // Large outer glow
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    accentColor.opacity(0.4),
                                    accentColor.opacity(0.2),
                                    accentColor.opacity(0.05),
                                    Color.clear,
                                ]),
                                center: .center,
                                startRadius: 0,
                                endRadius: 100
                            )
                        )
                        .frame(width: 200, height: 200)
                        .blur(radius: 30)

                    // Glass circle
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            accentColor.opacity(0.6),
                                            accentColor.opacity(0.3),
                                            accentColor.opacity(0.1),
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )
                        .frame(width: 120, height: 120)
                        .shadow(
                            color: accentColor.opacity(0.3),
                            radius: 25,
                            x: 0,
                            y: 10
                        )

                    Image(systemName: "text.badge.xmark")
                        .font(.system(size: DesignTokens.font50, weight: .medium))
                        .foregroundColor(.primary)
                        .shadow(color: accentColor.opacity(0.6), radius: 15)
                }

                VStack(spacing: DesignTokens.space12) {
                    Text("lyrics_empty_not_found_title".localized)
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text("lyrics_empty_not_found_subtitle".localized)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .padding(DesignTokens.space40)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.radius28)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: DesignTokens.radius28)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    accentColor.opacity(0.3),
                                    Color.primary.opacity(0.15),
                                    accentColor.opacity(0.2),
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )

                    RoundedRectangle(cornerRadius: DesignTokens.radius28)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    accentColor.opacity(0.05),
                                    Color.clear,
                                    accentColor.opacity(0.08),
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: accentColor.opacity(0.2), radius: 35, x: 0, y: 15)
            )
            .padding(.horizontal, DesignTokens.space40)

            Spacer()
        }
    }

    /// 分片：跨文件可见（原 private）
    var loadingView: some View {
        VStack(spacing: DesignTokens.space0) {
            Spacer()

            VStack(spacing: DesignTokens.space32) {
                // Animated loading with glass background
                ZStack {
                    // Large outer glow - animated
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    accentColor.opacity(0.4),
                                    accentColor.opacity(0.2),
                                    accentColor.opacity(0.05),
                                    Color.clear,
                                ]),
                                center: .center,
                                startRadius: 0,
                                endRadius: 100
                            )
                        )
                        .frame(width: 200, height: 200)
                        .blur(radius: 30)

                    // Glass circle
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            accentColor.opacity(0.6),
                                            accentColor.opacity(0.3),
                                            accentColor.opacity(0.1),
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )
                        .frame(width: 120, height: 120)
                        .shadow(
                            color: accentColor.opacity(0.3),
                            radius: 25,
                            x: 0,
                            y: 10
                        )

                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .primary))
                        .scaleEffect(1.5)
                }

                VStack(spacing: DesignTokens.space12) {
                    Text("lyrics_empty_loading_title".localized)
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text("lyrics_empty_loading_subtitle".localized)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(DesignTokens.space40)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.radius28)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: DesignTokens.radius28)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    accentColor.opacity(0.3),
                                    Color.primary.opacity(0.15),
                                    accentColor.opacity(0.2),
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )

                    RoundedRectangle(cornerRadius: DesignTokens.radius28)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    accentColor.opacity(0.05),
                                    Color.clear,
                                    accentColor.opacity(0.08),
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: accentColor.opacity(0.2), radius: 35, x: 0, y: 15)
            )
            .padding(.horizontal, DesignTokens.space40)

            Spacer()
        }
    }
}
