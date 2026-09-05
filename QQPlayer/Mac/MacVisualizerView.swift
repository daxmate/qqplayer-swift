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
struct MacVisualizerView: View {
    @ObservedObject private var analyzer = MacSpectrumAnalyzer.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { context, size in
                drawBars(in: &context, size: size)
            }
        }
        // 无数据（SFB 曲目/暂停清空后）整块淡出，不占视觉焦点
        .opacity(analyzer.isActive ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: analyzer.isActive)
    }

    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
        let levels = analyzer.levels
        guard !levels.isEmpty, size.width > 0, size.height > 0 else { return }

        let spacing: CGFloat = 2
        let barWidth = max(1, (size.width - spacing * CGFloat(levels.count - 1)) / CGFloat(levels.count))
        let accent = Color.accentColor

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
