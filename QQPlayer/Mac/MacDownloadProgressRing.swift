//
//  MacDownloadProgressRing.swift
//  QQPlayer
//
//  下载进度圆环（在线下载行尾 / search anything 徽标共用，2026-09 B2 批；
//  QQPlayerMac target only）。语义对齐 web 下载进度展示：
//  - progress 0-1 确定进度：轨道 + trim 弧（-90° 起笔）+ 可选中部小百分比
//  - progress nil 不确定态（total 未知，如 aria2 无总长 / 直链无 Content-Length）：
//    trim 0.2 短弧 + repeatForever 旋转
//  强调色读 @Environment(\.appAccentColor)（App 根视图注入，随设置刷新）。
//

import SwiftUI

/// 下载进度圆环（行尾小环默认 18pt；size 放大后可选中部百分比 caption2）
struct DownloadProgressRing: View {
    @Environment(\.appAccentColor) private var appAccentColor

    /// 进度 0-1；nil = 不确定态（转圈）
    let progress: Double?
    /// 圆环边长（默认行尾小环 18pt）
    var size: CGFloat = 18
    /// 确定态是否显示中部百分比（caption2，行内小环放不下时由调用方关掉）
    var showsPercentage: Bool = false

    @State private var spinning = false

    private var lineWidth: CGFloat { max(2, size * 0.14) }

    var body: some View {
        ZStack {
            // 轨道
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            // 进度弧 / 不确定短弧
            Group {
                if let progress {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                        .stroke(appAccentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    Circle()
                        .trim(from: 0, to: 0.2)
                        .stroke(appAccentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                }
            }
            if showsPercentage, let progress {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard progress == nil else { return }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
        .onDisappear {
            spinning = false
        }
    }
}
