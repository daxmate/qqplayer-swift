//
//  MacVisualizerView.swift
//  QQPlayer
//
//  macOS player spectrum visualizer (D4, web 版 Visualizer 对齐——bars 起步)。
//  画 32 段对数频谱条（MacSpectrumAnalyzer 数据），TimelineView ~30fps 驱动。
//  QQPlayerMac target only.
//

import SwiftUI

/// 播放页频谱条（数据源 MacSpectrumAnalyzer.shared；无数据/未激活时不绘制）。
/// 颜色跟随设置强调色（web 版强调色语义）：Color.accentColor 在 macOS 上跟随
/// 系统强调色而非 App tint，故直接读 MacAppearance.accentColor(forKey:)（2026-09-05）。
///
/// ⚠️ 高频数据隔离（2026-09-08 白框 bug 排查中的健壮性改进，非根因修复）：
/// levels 是 @Published 且每 30fps 在主线程赋值——若用 @ObservedObject 订阅，body 会
/// 每帧重算、播放期间窗口持续 invalid，与窗口 layout 冲突时加剧 AppKit layout 递归
/// （layoutSubtreeWithOldSize 嵌套 15+ 层，排查时实测）。故：① 只单项订阅低频的
/// isActive；② 绘制时直读共享 analyzer 的 levels（不进 SwiftUI 依赖图）；
/// ③ 不活跃时整体移除 TimelineView（不再 opacity 透明空转 30fps）。
struct MacVisualizerView: View {
    /// 是否正在输出频谱数据（播放中 native 引擎曲目）
    @State private var isActive = false
    /// 当前强调色（设置页改动经 qqplayerSettingsDidChange 刷新）
    @State private var accentColor: Color = MacAppearance.accentColor(
        forKey: DeleteSettings.load().accentColorName
    )

    var body: some View {
        Group {
            if isActive {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                    Canvas { context, size in
                        drawBars(in: &context, size: size)
                    }
                }
            }
        }
        .onReceive(MacSpectrumAnalyzer.shared.$isActive) { isActive = $0 }
        .onAppear { isActive = MacSpectrumAnalyzer.shared.isActive }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            accentColor = MacAppearance.accentColor(forKey: DeleteSettings.load().accentColorName)
        }
    }

    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
        // 直读共享数据源：高频读取不走 @ObservedObject（避免每帧 body 重算触发 layout 风暴）
        let levels = MacSpectrumAnalyzer.shared.levels
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
            context.fill(path, with: .color(accentColor.opacity(opacity)))
        }
    }
}
