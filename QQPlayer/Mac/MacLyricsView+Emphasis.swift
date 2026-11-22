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
    // 单一实现：`LyricsCenterMetrics.lerp`（同一文件被 macOS / iOS 共用），避免两份插值漂移。
    LyricsCenterMetrics.lerp(value, nodes)
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
    /// 阅读态（用户拍板 2026-10-12）：普通模式用户手动滚动后为 true → 关距离分级灰度 + 正常字号；
    /// 跟唱模式恒 false（不受影响）。
    let reading: Bool

    /// 关键：让 emphasis 可插值 → body 逐帧重算 → 字号连续变化
    var animatableData: Double {
        get { emphasis }
        set { emphasis = newValue }
    }

    func body(content: Content) -> some View {
        content
            // 字号随 animatableData 逐帧插值（视觉要求：高亮行平滑放大 / 缩小）。
            // 行高在动画中会连续变化 → 居中由「滚动时机 + 落定后重锚」保证，不靠冻结布局。
            .font(
                Self.lineFont(
                    emphasis: emphasis,
                    karaoke: karaoke,
                    reading: reading,
                    fontScale: fontScale
                )
            )
            .foregroundColor(mainColor)
            .shadow(color: shadowColor, radius: shadowRadius)
    }

    /// 插值字体：emphasis 逐帧传入（`LyricsCenterMetrics.fontSize` 是分段线性插值），
    /// 字重不可插值 → 按阈值切换；`reading` 时字号固定为正常大小那一档。
    static func lineFont(
        emphasis: Double,
        karaoke: Bool,
        reading: Bool,
        fontScale: CGFloat
    ) -> Font {
        .system(
            size: LyricsCenterMetrics.fontSize(
                emphasis: emphasis,
                karaoke: karaoke,
                reading: reading,
                fontScale: fontScale
            ),
            weight: lineWeight(emphasis: emphasis, karaoke: karaoke, reading: reading)
        )
    }

    /// 字重不可插值 → 按 emphasis 阈值切换（切换点前后颜色/透明度连续变化，视觉上被掩盖）。
    static func lineWeight(emphasis: Double, karaoke: Bool, reading: Bool) -> Font.Weight {
        // 阅读态：当前行加粗保留、其余统一 semibold（正常大小那一档；emphasis 1.0 = 当前行）
        if reading { return emphasis > 0.85 ? .bold : .semibold }
        if karaoke { return emphasis > 0.85 ? .bold : .regular }
        if emphasis > 0.85 { return .bold }
        if emphasis > 0.45 { return .semibold }
        return .medium
    }

    // MARK: 行级度量（透明度/缩放/行距作用于整行，含译文行）

    /// 整行透明度（节点值 = 改前的 mainOpacity；跟唱 1.0 / 0.8）
    static func lineOpacity(_ emphasis: Double, karaoke: Bool, reading: Bool) -> Double {
        if reading { return 1.0 } // 阅读态：整行全亮（关灰度）
        if karaoke {
            return lyricLerp(emphasis, [(1.0, 1.0), (0.66, 0.8)])
        }
        return lyricLerp(
            emphasis,
            [(1.0, 1.0), (0.66, 0.9), (0.40, 0.6), (0.20, 0.3), (0.08, 0.15)]
        )
    }

    /// 整行缩放（节点值 = 改前的 lineScale；跟唱不缩放）
    static func lineScale(_ emphasis: Double, karaoke: Bool, reading: Bool) -> CGFloat {
        if reading { return 1.0 } // 阅读态：不缩放（用户定）
        guard !karaoke else { return 1.0 }
        return CGFloat(lyricLerp(emphasis, [(1.0, 1.02), (0.66, 0.97), (0.40, 0.94)]))
    }

    /// 整行垂直内边距（逐帧插值：1.0 → 24 / 0.66 及更远 → 16；跟唱固定 18）。
    /// 必须放在行的 `.animation(value: emphasis)` **内层**才会随动画连续变化。
    static func linePadding(_ emphasis: Double, karaoke: Bool) -> CGFloat {
        guard !karaoke else { return 18 }
        return CGFloat(lyricLerp(emphasis, [(1.0, 24), (0.66, 16)]))
    }

    // MARK: 主行样式

    /// 颜色：≤0.66 只插值 primary 的 alpha（0.75 / 0.40 / 0.18），>0.66 才由 primary 混向 accent
    private var mainColor: Color {
        // 阅读态：全亮、不分级（当前行 accent + 加粗高亮，其余 primary）
        if reading { return emphasis > 0.85 ? accent : .primary }
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
    /// 阅读态（同 LyricLineEmphasis 口径）
    let reading: Bool
    var tier: Tier = .translation

    var animatableData: Double {
        get { emphasis }
        set { emphasis = newValue }
    }

    func body(content: Content) -> some View {
        content
            // 同主行：字号跟随 animatableData 逐帧插值（`fontSize` 本身就是分段线性插值）。
            .font(
                Self.font(
                    emphasis: emphasis,
                    karaoke: karaoke,
                    reading: reading,
                    fontScale: fontScale,
                    tier: tier
                )
            )
            .foregroundColor(color)
    }

    /// 插值字体：emphasis 逐帧传入（字号表按分段线性插值）。
    static func font(
        emphasis: Double,
        karaoke: Bool,
        reading: Bool,
        fontScale: CGFloat,
        tier: Tier
    ) -> Font {
        .system(size: fontSize(
            emphasis: emphasis,
            karaoke: karaoke,
            reading: reading,
            fontScale: fontScale,
            tier: tier
        ))
    }

    /// 字号阶梯：译文与罗马音共用这一张表（罗马音整体小一档）
    static func fontSize(
        emphasis: Double,
        karaoke: Bool,
        reading: Bool,
        fontScale: CGFloat,
        tier: Tier
    ) -> CGFloat {
        // 阅读态：译文 14 / 罗马音 12（正常大小那一档），不随距离分级
        if reading { return (tier == .roman ? 12 : 14) * fontScale }
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
        if reading { return .secondary } // 阅读态：译文/罗马音全亮，不再叠加 opacity
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
