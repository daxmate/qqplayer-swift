//
//  MacVisualizerView.swift
//  QQPlayer
//
//  macOS player spectrum visualizer (D4, web 版 Visualizer 对齐——bars 起步)。
//  画 32 段对数频谱条（MacSpectrumAnalyzer 数据），数据到达即重绘（~30fps）。
//  QQPlayerMac target only.
//

import SwiftUI

/// 播放页频谱条（数据源 MacSpectrumAnalyzer.shared；未激活且无冻结帧时不绘制；暂停 = 冻结最后一帧）。
/// 颜色跟随设置强调色（web 版强调色语义）：`Color.accentColor` 在 macOS 上跟随
/// 系统强调色而非 App tint，故读 App 根注入的 `\.appAccentColor` 环境值
/// （2026-09-05 改为直读 MacAppearance，2026-09-15 M2 收口为 currentAccentColor；
/// 2026-11-13 改为读环境值——刷新由 `AccentInjector` 的可观察 store 负责，
/// 本视图不再自带 `.onReceive(.qqplayerSettingsDidChange)` 第二条刷新路径）。
///
/// ⚠️ 重绘驱动（2026-09-12 修「播放中频谱条恒为最低高度、贴成一条虚线」）：
/// 2026-09-08 曾把数据订阅换成「直读 levels + TimelineView(.animation) 驱动」，
/// 当时的理由是减少每帧 body 重算（那条 layout 递归结论后来被推翻，白框根因是
/// sheet 的 item 时序竞态）。改完的后果：数据到达不再触发 SwiftUI 失效，重绘只剩
/// TimelineView 调度一条路——播放中 32 根条常年停在最低高度 2pt，肉眼像一条虚线。
/// 现改回**数据驱动重绘**：body 读 `analyzer.isActive` / `analyzer.levels`（`@Observable`
/// 按属性追踪，`levels` 由 tap 回调 ~30fps 节流发布）作为绘制输入，数据一变即重绘。
/// 本视图是叶子节点，body 只有 Group + Canvas，逐帧重算负担可忽略。
/// 保留 2026-09-08 的合理部分：未激活且无冻结帧时整体不绘制（不空转 Canvas）。
///
/// 2026-09-20 批 6-1：`@Published` 订阅（`.onReceive(…$levels)`）→ 组合根注入的
/// `@Environment(MacSpectrumAnalyzer.self)`。⚠️ `levels` 必须在 **body 求值期**读
/// （下面那行局部 `let`）——不能只在 `Canvas` 渲染闭包里读：渲染闭包不在 body 求值
/// 范围内，读 `@Observable` 属性**不会登记依赖**，数据到达就不触发重绘。
struct MacVisualizerView: View {
    /// 频谱分析器（Mac 组合根注入；按属性追踪驱动重绘）
    @Environment(MacSpectrumAnalyzer.self) private var analyzer
    /// 当前强调色：统一读 App 根注入的环境值（由 `AccentInjector` 提供，换色即时跟随）。
    /// 不要再自读 `MacAppearance.currentAccentColor` + 自带 onReceive——那是第二条刷新路径。
    @Environment(\.appAccentColor) private var appAccentColor

    var body: some View {
        Group {
            if analyzer.isActive || analyzer.isFrozen {
                let levels = analyzer.levels
                // ⚠️ 强调色同样必须在 body 求值期读取并作为参数传进渲染闭包：
                // Canvas 渲染闭包不在 body 求值范围内，那里读环境值 / `@Observable` 属性
                // 都不登记依赖 ⇒ 换色后不重绘（与 `levels` 同一条纪律）。
                let accent = appAccentColor
                Canvas { context, size in
                    drawBars(levels: levels, accent: accent, in: &context, size: size)
                }
            }
        }
    }

    private func drawBars(levels: [Float], accent: Color, in context: inout GraphicsContext, size: CGSize) {
        guard !levels.isEmpty, size.width > 0, size.height > 0 else { return }

        let spacing: CGFloat = 2
        let barWidth = max(1, (size.width - spacing * CGFloat(levels.count - 1)) / CGFloat(levels.count))

        for (i, level) in levels.enumerated() {
            let height = max(2, CGFloat(level) * size.height)
            let x = CGFloat(i) * (barWidth + spacing)
            let rect = CGRect(x: x, y: size.height - height, width: barWidth, height: height)
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
            // 能量越高越实；静态低亮避免视觉噪点
            let opacity = 0.35 + 0.65 * min(1, Double(level) * 1.4)
            context.fill(path, with: .color(accent.opacity(opacity)))
        }
    }
}
