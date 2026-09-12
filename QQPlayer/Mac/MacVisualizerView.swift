//
//  MacVisualizerView.swift
//  QQPlayer
//
//  macOS player spectrum visualizer (D4, web 版 Visualizer 对齐——bars 起步)。
//  画 32 段对数频谱条（MacSpectrumAnalyzer 数据），数据到达即重绘（~30fps）。
//  QQPlayerMac target only.
//

import SwiftUI

/// 播放页频谱条（数据源 MacSpectrumAnalyzer.shared；无数据/未激活时不绘制）。
/// 颜色跟随设置强调色（web 版强调色语义）：Color.accentColor 在 macOS 上跟随
/// 系统强调色而非 App tint，故直接读 MacAppearance.accentColor(forKey:)（2026-09-05）。
///
/// ⚠️ 重绘驱动（2026-09-12 修「播放中频谱条恒为最低高度、贴成一条虚线」）：
/// 2026-09-08 曾把数据订阅换成「直读 levels + TimelineView(.animation) 驱动」，
/// 当时的理由是减少每帧 body 重算（那条 layout 递归结论后来被推翻，白框根因是
/// sheet 的 item 时序竞态）。改完的后果：数据到达不再触发 SwiftUI 失效，重绘只剩
/// TimelineView 调度一条路——播放中 32 根条常年停在最低高度 2pt，肉眼像一条虚线。
/// 现改回**数据驱动重绘**：订阅 levels（@Published，~30fps 节流）作为绘制输入，
/// 数据一变即重绘。本视图是叶子节点，body 只有 Group + Canvas，逐帧重算负担可忽略。
/// 保留 2026-09-08 的合理部分：不活跃时整体不绘制（不空转 Canvas）。
struct MacVisualizerView: View {
    /// 是否正在输出频谱数据（播放中 native 引擎曲目）
    @State private var isActive = false
    /// 当前频谱数据（~30fps 发布；作为绘制输入，数据驱动重绘）
    @State private var levels: [Float] = []
    /// 当前强调色（设置页改动经 qqplayerSettingsDidChange 刷新）
    @State private var accentColor: Color = MacAppearance.accentColor(
        forKey: DeleteSettings.load().accentColorName
    )

    var body: some View {
        Group {
            if isActive {
                Canvas { context, size in
                    drawBars(in: &context, size: size)
                }
            }
        }
        .onReceive(MacSpectrumAnalyzer.shared.$isActive) { isActive = $0 }
        .onReceive(MacSpectrumAnalyzer.shared.$levels) { levels = $0 }
        .onAppear {
            isActive = MacSpectrumAnalyzer.shared.isActive
            levels = MacSpectrumAnalyzer.shared.levels
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            accentColor = MacAppearance.accentColor(forKey: DeleteSettings.load().accentColorName)
        }
    }

    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
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
