//
//  MacGraphicEQ10BandEditorView.swift
//  QQPlayer
//
//  macOS 10 段图形 EQ 自定义编辑器（对齐 iOS GraphicEQ10BandEditorView）：
//  固定频点 31Hz-16kHz、±12dB、拖拽实时应用。曲线图背景用
//  controlBackgroundColor 替代 iOS 的 secondarySystemBackground。
//  QQPlayerMac target only。
//

import SwiftUI

struct MacGraphicEQ10BandEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var eqManager = EQManager.shared

    @State private var gains: [Double] = Array(repeating: 0.0, count: BuiltinEQPresets.bands10.count)

    private let minGain = -12.0
    private let maxGain = 12.0
    private let gainStep = 0.5

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    MacGraphicEQ10BandGraphView(
                        gains: gains,
                        minGain: minGain,
                        maxGain: maxGain
                    )
                    .frame(height: 200)
                }

                Section(Localized.frequencyBands) {
                    ForEach(BuiltinEQPresets.bands10.indices, id: \.self) { index in
                        HStack {
                            Text(bandLabel(for: BuiltinEQPresets.bands10[index]))
                                .font(.subheadline)
                                .frame(width: 76, alignment: .leading)

                            Slider(
                                value: $gains[index],
                                in: minGain ... maxGain,
                                step: gainStep
                            )
                            .tint(.blue)
                            .onChange(of: gains[index]) { _ in
                                applyChanges()
                            }

                            Text("\(gains[index], specifier: "%+.1f") dB")
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                }

                Section {
                    Button(Localized.resetToFlat) {
                        resetToFlat()
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear {
                loadInitialGains()
            }
        }
        .frame(minWidth: 480, minHeight: 600)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(Localized.eqCustomTitle)
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Button(Localized.eqDone) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    // MARK: - Helpers

    private func loadInitialGains() {
        // 已处于自定义模式时恢复当前增益，否则从平坦开始
        if eqManager.activeBuiltinKey == BuiltinEQPresets.customKey {
            let current = eqManager.currentEQGains
            if current.count == BuiltinEQPresets.bands10.count {
                gains = current.map { max(minGain, min(maxGain, $0)) }
                return
            }
        }
        gains = Array(repeating: 0.0, count: BuiltinEQPresets.bands10.count)
    }

    private func resetToFlat() {
        gains = Array(repeating: 0.0, count: BuiltinEQPresets.bands10.count)
        applyChanges()
    }

    private func applyChanges() {
        // 拖拽实时应用（AVAudioUnitEQ 参数更新开销小）
        eqManager.applyCustomEQGains(gains)
    }

    private func bandLabel(for frequency: Double) -> String {
        if frequency >= 1000 {
            return String(format: "%.0f kHz", frequency / 1000)
        }
        return String(format: "%.0f Hz", frequency)
    }
}

/// 10 段增益曲线图（只读展示，参考 ParametricEQGraphView 的绘制思路）
private struct MacGraphicEQ10BandGraphView: View {
    let gains: [Double]
    let minGain: Double
    let maxGain: Double

    private var points: [CGPoint] {
        // 频点固定，对数 x 轴（31Hz - 16kHz），线性 y 轴（-12 - +12dB）
        let minLog = log10(BuiltinEQPresets.bands10.first ?? 31.0)
        let maxLog = log10(BuiltinEQPresets.bands10.last ?? 16_000.0)
        let logSpan = max(maxLog - minLog, 0.001)

        return BuiltinEQPresets.bands10.enumerated().map { index, frequency in
            let xRatio = (log10(frequency) - minLog) / logSpan
            let clampedGain = max(minGain, min(maxGain, index < gains.count ? gains[index] : 0.0))
            let yRatio = (maxGain - clampedGain) / (maxGain - minGain)
            return CGPoint(x: xRatio, y: yRatio)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let plotRect = CGRect(
                x: 12,
                y: 12,
                width: max(geometry.size.width - 24, 1),
                height: max(geometry.size.height - 24, 1)
            )
            let mapped = points.map { point in
                CGPoint(
                    x: plotRect.minX + point.x * plotRect.width,
                    y: plotRect.minY + point.y * plotRect.height
                )
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))

                // 水平网格线（0dB 中线高亮）
                Path { path in
                    for tick in 0 ... 6 {
                        let ratio = CGFloat(tick) / 6.0
                        let y = plotRect.minY + ratio * plotRect.height
                        path.move(to: CGPoint(x: plotRect.minX, y: y))
                        path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
                    }
                }
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)

                // 0dB 中线
                let zeroY = plotRect.minY + (maxGain / (maxGain - minGain)) * plotRect.height
                Path { path in
                    path.move(to: CGPoint(x: plotRect.minX, y: zeroY))
                    path.addLine(to: CGPoint(x: plotRect.maxX, y: zeroY))
                }
                .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)

                // 增益曲线
                Path { path in
                    guard let first = mapped.first else { return }
                    path.move(to: first)
                    for point in mapped.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(Color.blue.opacity(0.85), lineWidth: 2)

                // 频点节点
                ForEach(Array(mapped.enumerated()), id: \.offset) { _, point in
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                        .position(point)
                }
            }
        }
    }
}
