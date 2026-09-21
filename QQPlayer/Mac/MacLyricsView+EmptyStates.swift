//
//  MacLyricsView+EmptyStates.swift
//  QQPlayer
//
//  `MacLyricsView` 的空态类型与玻璃卡（2026-09-21 从 `MacLyricsView.swift` 纯搬家，零行为/UI 变化）。
//
//  ⚠️ 可见性：被主片或其它分区文件引用的成员为 internal（原 `private`）。
//

import AppKit
import SwiftUI

extension MacLyricsView {
    // MARK: - Empty / loading / instrumental states（玻璃卡，按面板高度自适应）

    /// 分片：跨文件可见（原 private）
    func emptyState(_ kind: MacLyricsEmptyKind) -> some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            Group {
                if height < 200 {
                    // 极矮面板（最小 140pt）：只留图标 + 标题，不套卡片，保证不裁切
                    VStack(spacing: DesignTokens.space8) {
                        emptyIcon(kind, size: 28)
                        Text(kind.title)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    emptyCard(kind, compact: height < 340)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyCard(_ kind: MacLyricsEmptyKind, compact: Bool) -> some View {
        VStack(spacing: compact ? DesignTokens.space12 : DesignTokens.space32) {
            ZStack {
                glassGlow(size: compact ? 120 : 200)

                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(glassStroke, lineWidth: 2))
                    .frame(width: compact ? 64 : 120, height: compact ? 64 : 120)
                    .shadow(color: appAccentColor.opacity(0.3), radius: 25, x: 0, y: 10)

                emptyIcon(kind, size: compact ? 28 : 50)
            }

            VStack(spacing: DesignTokens.space12) {
                Text(kind.title)
                    .font(compact ? Font.headline : Font.title)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)

                // 紧凑版隐藏副标题（面板矮时保证不裁切）
                if !compact {
                    Text(kind.subtitle)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(compact ? DesignTokens.space20 : DesignTokens.space40)
        .background(cardBackground)
        .padding(.horizontal, DesignTokens.space40)
    }

    /// 外圈径向辉光（跟随主题色）
    private func glassGlow(size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        appAccentColor.opacity(0.4),
                        appAccentColor.opacity(0.2),
                        appAccentColor.opacity(0.05),
                        .clear,
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .blur(radius: 30)
    }

    /// 玻璃圆描边渐变（主题色由亮到暗）
    private var glassStroke: LinearGradient {
        LinearGradient(
            colors: [
                appAccentColor.opacity(0.6),
                appAccentColor.opacity(0.3),
                appAccentColor.opacity(0.1),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 毛玻璃卡：ultraThinMaterial + 主题色渐变描边 + 内层高光 + 主题色投影
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.radius28)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(
                shape.stroke(
                    LinearGradient(
                        colors: [
                            appAccentColor.opacity(0.3),
                            Color.primary.opacity(0.15),
                            appAccentColor.opacity(0.2),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [
                            appAccentColor.opacity(0.05),
                            .clear,
                            appAccentColor.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .shadow(color: appAccentColor.opacity(0.2), radius: 35, x: 0, y: 15)
    }

    @ViewBuilder
    private func emptyIcon(_ kind: MacLyricsEmptyKind, size: CGFloat) -> some View {
        switch kind {
        case .loading:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .primary))
                .scaleEffect(1.5)
        case .instrumental, .notFound:
            Image(systemName: kind == .instrumental ? "music.note" : "text.badge.xmark")
                .font(.system(size: size, weight: .medium))
                .foregroundColor(.primary)
                .shadow(color: appAccentColor.opacity(0.6), radius: 15)
        }
    }
}

/// 空态类型（加载中 / 纯音乐 / 无歌词）：决定玻璃卡图标与文案。
/// 文案 key 与 iOS LyricsView 完全共用（五语齐备，无需新增本地化）。
/// 分片：跨文件可见（原 private）
enum MacLyricsEmptyKind {
    case loading
    case instrumental
    case notFound

    var title: String {
        switch self {
        case .loading: return "lyrics_empty_loading_title".localized
        case .instrumental: return "lyrics_empty_instrumental_title".localized
        case .notFound: return "lyrics_empty_not_found_title".localized
        }
    }

    var subtitle: String {
        switch self {
        case .loading: return "lyrics_empty_loading_subtitle".localized
        case .instrumental: return "lyrics_empty_instrumental_subtitle".localized
        case .notFound: return "lyrics_empty_not_found_subtitle".localized
        }
    }
}
