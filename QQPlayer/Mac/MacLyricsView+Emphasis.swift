//
//  MacLyricsView+Emphasis.swift
//  QQPlayer
//
//  `MacLyricsView` 的切句过渡（emphasis 插值）与两个 ViewModifier（2026-09-21 从 `MacLyricsView.swift` 纯搬家，零行为/UI 变化）。
//
//  ⚠️ 可见性：被主片或其它分区文件引用的成员为 internal（原 `private`）。
//

import AppKit
import SwiftUI

// MARK: - 切句过渡（emphasis 逐帧插值）

/// 分段线性插值：节点按 emphasis 降序给出，超出两端取端值。
/// 每个节点值 = 改前（3ff6474）该档位的静态渲染值，故静态效果不变，只有节点之间才插值。
private func lyricLerp(_ value: Double, _ nodes: [(Double, Double)]) -> Double {
    guard let first = nodes.first, let last = nodes.last else { return value }
    if value >= first.0 { return first.1 }
    if value <= last.0 { return last.1 }
    for index in 0 ..< (nodes.count - 1) {
        let (highEmphasis, highValue) = nodes[index]
        let (lowEmphasis, lowValue) = nodes[index + 1]
        guard value <= highEmphasis, value >= lowEmphasis else { continue }
        let ratio = (value - lowEmphasis) / (highEmphasis - lowEmphasis)
        return lowValue + (highValue - lowValue) * ratio
    }
    return last.1
}

/// 0.66 → 1.0 的归一化进度：只有这一段跨色相（语义色 → accent），低段只动 alpha。
private func lyricEmphasisProgress(_ emphasis: Double) -> CGFloat {
    CGFloat(min(max((emphasis - 0.66) / 0.34, 0), 1))
}

/// 语义色 → accent 的跨档位混色（fraction 0 = 语义色，1 = accent）。
/// 用 NSColor.blended(withFraction:of:)：`Color.mix` 是 macOS 15+ API（2026-09-18 部署目标由 13.0 提到 14.0，本条结论不变，仍用不了）。
private func blendSemantic(
    _ base: NSColor,
    alpha: CGFloat,
    with accent: Color,
    fraction: CGFloat
) -> Color {
    let clamped = min(max(fraction, 0), 1)
    guard let from = base.withAlphaComponent(alpha).usingColorSpace(.sRGB),
          let to = NSColor(accent).usingColorSpace(.sRGB),
          let mixed = from.blended(withFraction: clamped, of: to)
    else { return accent }
    return Color(nsColor: mixed)
}

/// 行强调度（0…1，1 = 当前行）：Animatable —— 字号/颜色/阴影随过渡值逐帧插值，
/// 替代「字号瞬间跳变（SwiftUI 不插值 Font）+ 两条曲线不同步」的急促观感（2026-09-13 用户反馈）。
/// 字重不可插值 → 按 emphasis 阈值切换（切换点前后字号/透明度正在连续变化，视觉上被掩盖）。
/// 透明度/缩放/行距作用于整行（含译文行）→ 由下面的 static 方法供行容器调用。
/// 分片：跨文件可见（原 private）
struct LyricLineEmphasis: ViewModifier, Animatable {
    /// 0…1
    var emphasis: Double
    let accent: Color
    let fontScale: CGFloat
    let karaoke: Bool

    /// 关键：让 emphasis 可插值 → body 逐帧重算 → 字号连续变化
    var animatableData: Double {
        get { emphasis }
        set { emphasis = newValue }
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: mainSize, weight: mainWeight))
            .foregroundColor(mainColor)
            .shadow(color: shadowColor, radius: shadowRadius)
    }

    // MARK: 行级度量（透明度/缩放/行距作用于整行，含译文行）

    /// 整行透明度（节点值 = 改前的 mainOpacity；跟唱 1.0 / 0.8）
    static func lineOpacity(_ emphasis: Double, karaoke: Bool) -> Double {
        if karaoke {
            return lyricLerp(emphasis, [(1.0, 1.0), (0.66, 0.8)])
        }
        return lyricLerp(
            emphasis,
            [(1.0, 1.0), (0.66, 0.9), (0.40, 0.6), (0.20, 0.3), (0.08, 0.15)]
        )
    }

    /// 整行缩放（节点值 = 改前的 lineScale；跟唱不缩放）
    static func lineScale(_ emphasis: Double, karaoke: Bool) -> CGFloat {
        guard !karaoke else { return 1.0 }
        return CGFloat(lyricLerp(emphasis, [(1.0, 1.02), (0.66, 0.97), (0.40, 0.94)]))
    }

    /// 整行垂直内边距（改前 当前行 24 / 其余 16；跟唱固定 18）
    static func linePadding(_ emphasis: Double, karaoke: Bool) -> CGFloat {
        guard !karaoke else { return 18 }
        return CGFloat(lyricLerp(emphasis, [(1.0, 24), (0.66, 16)]))
    }

    // MARK: 主行样式

    /// 字号（×fontScale）：1.0 → 26、0.66 → 19、0.40 及更远 → 16（跟唱 22 / 19）
    private var mainSize: CGFloat {
        let size = karaoke
            ? lyricLerp(emphasis, [(1.0, 22), (0.66, 19)])
            : lyricLerp(emphasis, [(1.0, 26), (0.66, 19), (0.40, 16)])
        return CGFloat(size) * fontScale
    }

    private var mainWeight: Font.Weight {
        if karaoke { return emphasis > 0.85 ? .bold : .regular }
        if emphasis > 0.85 { return .bold }
        if emphasis > 0.45 { return .semibold }
        return .medium
    }

    /// 颜色：≤0.66 只插值 primary 的 alpha（0.75 / 0.40 / 0.18），>0.66 才由 primary 混向 accent
    private var mainColor: Color {
        let fraction = lyricEmphasisProgress(emphasis)
        if karaoke {
            guard fraction > 0 else { return .primary.opacity(0.8) }
            return blendSemantic(.labelColor, alpha: 0.8, with: accent, fraction: fraction)
        }
        guard fraction > 0 else {
            let alpha = lyricLerp(emphasis, [(0.66, 0.75), (0.40, 0.4), (0.20, 0.18), (0.08, 0.18)])
            return .primary.opacity(alpha)
        }
        return blendSemantic(.labelColor, alpha: 0.75, with: accent, fraction: fraction)
    }

    /// 阴影：只有 0.66 → 1.0 段出现（1.0 → 半径 20 / accent 0.5，节点之下 → 0 / clear）
    private var shadowRadius: CGFloat {
        guard !karaoke else { return 0 }
        return CGFloat(lyricLerp(emphasis, [(1.0, 20), (0.66, 0)]))
    }

    private var shadowColor: Color {
        guard !karaoke else { return .clear }
        return accent.opacity(0.5 * Double(lyricEmphasisProgress(emphasis)))
    }
}

/// 译文行强调：与主行同一套路（节点值照旧：当前 16 / 距离 1 14 / 更远 13；
/// 跟唱 当前 16 / 其余 14），字号与颜色都按 emphasis 插值、字号 ×fontScale。
/// 整行透明度/缩放仍由行容器统一施加。
/// 分片：跨文件可见（原 private）
struct LyricTranslationEmphasis: ViewModifier, Animatable {
    /// 次要行层级：译文（原档）/ 罗马音（同一套插值，比译文小一档）
    enum Tier {
        case translation
        case roman
    }

    var emphasis: Double
    let accent: Color
    let fontScale: CGFloat
    let karaoke: Bool
    var tier: Tier = .translation

    var animatableData: Double {
        get { emphasis }
        set { emphasis = newValue }
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: size * fontScale))
            .foregroundColor(color)
    }

    /// 字号阶梯：译文与罗马音共用这一张表（罗马音整体小一档）
    private var size: CGFloat {
        let table: [(Double, Double)]
        switch (karaoke, tier) {
        case (true, .translation): table = [(1.0, 16), (0.66, 14)]
        case (true, .roman): table = [(1.0, 14), (0.66, 12)]
        case (false, .translation): table = [(1.0, 16), (0.66, 14), (0.20, 13)]
        case (false, .roman): table = [(1.0, 14), (0.66, 12), (0.20, 11)]
        }
        return CGFloat(lyricLerp(emphasis, table))
    }

    private var color: Color {
        let fraction = lyricEmphasisProgress(emphasis)
        if karaoke {
            guard fraction > 0 else { return .secondary.opacity(0.7) }
            return blendSemantic(
                .secondaryLabelColor,
                alpha: 0.7,
                with: accent.opacity(0.95),
                fraction: fraction
            )
        }
        guard fraction > 0 else {
            let alpha = lyricLerp(emphasis, [(0.66, 0.85), (0.40, 0.5), (0.20, 0.25)])
            return .secondary.opacity(alpha)
        }
        return blendSemantic(
            .secondaryLabelColor,
            alpha: 0.85,
            with: accent.opacity(0.95),
            fraction: fraction
        )
    }
}
