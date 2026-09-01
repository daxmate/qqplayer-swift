//
//  MacManualEQEditorView.swift
//  QQPlayer
//
//  macOS manual parametric EQ (对齐 iOS CreateManualEQView +
//  ManualEQEditorView)：创建页（名称 + 0-16 段）+ 编辑器（波段列表、
//  选中波段频率/增益/Q 滑杆、Add/Remove Band、Reset、曲线图、Save/Cancel）。
//  QQPlayerMac target only。
//

import SwiftUI

// MARK: - Create Manual EQ

struct MacCreateManualEQView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var eqManager = EQManager.shared

    @State private var presetName = ""
    @State private var bandCount = 0
    @State private var createError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section(Localized.presetName) {
                    TextField(Localized.enterPresetName, text: $presetName)
                }

                Section(Localized.eqBands) {
                    Stepper(value: $bandCount, in: 0 ... 16) {
                        Text("\(bandCount) / 16")
                    }
                }

                if let createError {
                    Section(Localized.eqError) {
                        Text(createError)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                Section(Localized.presetInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Localized.eqCreateManualDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(Localized.eqEditBandsHint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 420, minHeight: 380)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(Localized.eqCreateManual)
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Button(Localized.eqCancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(Localized.eqCreate) {
                createPreset()
            }
            .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    private func createPreset() {
        Task {
            do {
                let preset = try await eqManager.createManualParametricPreset(name: presetName, bandCount: bandCount)

                await MainActor.run {
                    eqManager.currentPreset = preset
                    createError = nil
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    createError = Localized.failedToCreate(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Manual EQ Editor

struct MacManualEQEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var eqManager = EQManager.shared

    let preset: EQPreset
    @State private var bandFrequencies: [Double] = []
    @State private var bandGains: [Double] = []
    @State private var bandBandwidths: [Double] = []
    @State private var selectedBandIndex: Int?
    @State private var isLoading = true
    @State private var saveError: String?

    private let minFrequency = 20.0
    private let maxFrequency = 20_000.0
    private let minGain = -12.0
    private let maxGain = 12.0
    private let maxBands = 16

    private var editableBandCount: Int {
        min(bandFrequencies.count, min(bandGains.count, bandBandwidths.count))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        loadBands()
                    }
            } else {
                Form {
                    Section {
                        HStack {
                            Text(preset.name)
                                .font(.headline)
                            Spacer()
                            Text(Localized.eqBandsCount(editableBandCount, maxBands))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section(Localized.eqParametricEditor) {
                        MacParametricEQGraphView(
                            frequencies: $bandFrequencies,
                            gains: $bandGains,
                            selectedBandIndex: $selectedBandIndex,
                            minFrequency: minFrequency,
                            maxFrequency: maxFrequency,
                            minGain: minGain,
                            maxGain: maxGain
                        )
                        .frame(height: 240)

                        HStack {
                            Button(Localized.eqAddBand) {
                                addBand()
                            }
                            .disabled(editableBandCount >= maxBands)

                            Button(Localized.eqRemoveBand) {
                                removeSelectedBand()
                            }
                            .disabled(editableBandCount == 0)
                        }
                    }

                    if let selectedBandIndex, selectedBandIndex < editableBandCount {
                        Section(Localized.eqSelectedBand) {
                            Text(Localized.eqBandNumber(selectedBandIndex + 1))
                                .font(.headline)

                            HStack {
                                Text(Localized.eqFrequency)
                                Spacer()
                                Text(formatFrequency(bandFrequencies[selectedBandIndex]))
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { logFrequencyValue(for: bandFrequencies[selectedBandIndex]) },
                                    set: { bandFrequencies[selectedBandIndex] = frequency(fromLogValue: $0).rounded(toPlaces: 1) }
                                ),
                                in: log10(minFrequency) ... log10(maxFrequency)
                            )
                            .tint(.orange)

                            HStack {
                                Text(Localized.eqGain)
                                Spacer()
                                Text("\(bandGains[selectedBandIndex], specifier: "%.1f") dB")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $bandGains[selectedBandIndex], in: minGain ... maxGain, step: 0.1)
                                .tint(.blue)

                            HStack {
                                Text(Localized.eqQ)
                                Spacer()
                                Text("\(qFactor(fromBandwidth: bandBandwidths[selectedBandIndex]), specifier: "%.2f")")
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { qFactor(fromBandwidth: bandBandwidths[selectedBandIndex]) },
                                    set: { bandBandwidths[selectedBandIndex] = bandwidth(fromQFactor: $0) }
                                ),
                                in: 0.10 ... 10.0,
                                step: 0.01
                            )
                            .tint(.purple)
                        }
                    }

                    Section {
                        Button(Localized.resetToFlat) {
                            resetToFlat()
                        }
                    }
                }
                .formStyle(.grouped)
                .onChange(of: editableBandCount) { newCount in
                    if newCount == 0 {
                        selectedBandIndex = nil
                    } else if let selectedBandIndex, selectedBandIndex >= newCount {
                        self.selectedBandIndex = newCount - 1
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 620)
        .alert(Localized.eqError, isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button(Localized.done, role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(Localized.editEqualizer)
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Button(Localized.eqCancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(Localized.eqSave) {
                saveChanges()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Data

    private func loadBands() {
        Task {
            do {
                let bands = try await eqManager.databaseManager.getBands(for: preset)
                let sortedBands = bands.sorted { $0.bandIndex < $1.bandIndex }
                let targetBandCount = sortedBands.count

                await MainActor.run {
                    bandFrequencies = []
                    bandGains = []
                    bandBandwidths = []

                    for index in 0 ..< targetBandCount {
                        let defaultFrequency = defaultFrequencies(for: targetBandCount)[index]

                        if index < sortedBands.count {
                            bandFrequencies.append(max(minFrequency, min(maxFrequency, sortedBands[index].frequency)))
                            bandGains.append(sortedBands[index].gain)
                            bandBandwidths.append(max(0.05, min(5.0, sortedBands[index].bandwidth)))
                        } else {
                            bandFrequencies.append(defaultFrequency)
                            bandGains.append(0.0)
                            bandBandwidths.append(1.0)
                        }
                    }

                    selectedBandIndex = editableBandCount > 0 ? 0 : nil
                    isLoading = false
                }
            } catch {
                print("❌ Failed to load bands: \(error)")
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }

    private func saveChanges() {
        Task {
            do {
                let sortedBands = (0 ..< editableBandCount)
                    .map { index in
                        (
                            frequency: bandFrequencies[index],
                            gain: bandGains[index],
                            bandwidth: bandBandwidths[index]
                        )
                    }
                    .sorted { $0.frequency < $1.frequency }

                try await eqManager.updatePresetBands(
                    preset,
                    frequencies: sortedBands.map { $0.frequency },
                    gains: sortedBands.map { $0.gain },
                    bandwidths: sortedBands.map { $0.bandwidth }
                )

                await MainActor.run {
                    dismiss()
                }
            } catch {
                print("❌ Failed to save changes: \(error)")
                await MainActor.run {
                    saveError = NSLocalizedString("failed_to_save", value: "Failed to save changes", comment: "") + ": \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Band editing helpers

    private func formatFrequency(_ freq: Double) -> String {
        if freq >= 1000 {
            return String(format: "%.1fkHz", freq / 1000)
        } else {
            return String(format: "%.0fHz", freq)
        }
    }

    private func defaultFrequencies(for totalBands: Int) -> [Double] {
        EQManager.defaultParametricFrequencies(for: totalBands)
    }

    private func qFactor(fromBandwidth bandwidth: Double) -> Double {
        let clampedBandwidth = max(0.05, min(5.0, bandwidth))
        let twoPowBandwidth = pow(2.0, clampedBandwidth)
        let denominator = max(twoPowBandwidth - 1.0, 0.0001)
        let q = sqrt(twoPowBandwidth) / denominator
        return max(0.1, min(10.0, q))
    }

    private func bandwidth(fromQFactor qFactor: Double) -> Double {
        let q = max(0.1, min(10.0, qFactor))
        let reciprocal = 1.0 / (2.0 * q)
        let sqrtTerm = sqrt(1.0 + (1.0 / (4.0 * q * q)))
        let denominator = max(sqrtTerm - reciprocal, 0.0001)
        let bandwidth = log2((sqrtTerm + reciprocal) / denominator)
        guard bandwidth.isFinite else { return 1.0 }
        return max(0.05, min(5.0, bandwidth))
    }

    private func logFrequencyValue(for frequency: Double) -> Double {
        let clampedFrequency = max(minFrequency, min(maxFrequency, frequency))
        return log10(clampedFrequency)
    }

    private func frequency(fromLogValue logValue: Double) -> Double {
        let clampedLogValue = max(log10(minFrequency), min(log10(maxFrequency), logValue))
        return pow(10, clampedLogValue)
    }

    private func resetToFlat() {
        let defaults = defaultFrequencies(for: editableBandCount)
        for index in 0 ..< editableBandCount {
            bandFrequencies[index] = defaults[index]
            bandGains[index] = 0.0
            bandBandwidths[index] = 1.0
        }
    }

    private func addBand() {
        guard editableBandCount < maxBands else { return }

        let newFrequency: Double
        if let selectedBandIndex, bandFrequencies.indices.contains(selectedBandIndex), selectedBandIndex < editableBandCount - 1 {
            newFrequency = sqrt(bandFrequencies[selectedBandIndex] * bandFrequencies[selectedBandIndex + 1])
        } else if let lastFrequency = bandFrequencies.last {
            newFrequency = min(maxFrequency, lastFrequency * 1.5)
        } else {
            newFrequency = 1000.0
        }

        bandFrequencies.append(max(minFrequency, min(maxFrequency, newFrequency)))
        bandGains.append(0.0)
        bandBandwidths.append(1.0)

        selectedBandIndex = bandFrequencies.count - 1
    }

    private func removeSelectedBand() {
        guard editableBandCount > 0 else { return }
        let indexToRemove: Int
        if let selectedBandIndex, selectedBandIndex >= 0, selectedBandIndex < editableBandCount {
            indexToRemove = selectedBandIndex
        } else {
            indexToRemove = editableBandCount - 1
        }

        bandFrequencies.remove(at: indexToRemove)
        bandGains.remove(at: indexToRemove)
        bandBandwidths.remove(at: indexToRemove)

        if editableBandCount == 0 {
            self.selectedBandIndex = nil
        } else {
            self.selectedBandIndex = min(indexToRemove, editableBandCount - 1)
        }
    }
}

// MARK: - Parametric EQ graph

private struct MacParametricEQGraphView: View {
    @Binding var frequencies: [Double]
    @Binding var gains: [Double]
    @Binding var selectedBandIndex: Int?

    let minFrequency: Double
    let maxFrequency: Double
    let minGain: Double
    let maxGain: Double

    var body: some View {
        GeometryReader { geometry in
            let plotRect = CGRect(
                x: 12,
                y: 12,
                width: max(geometry.size.width - 24, 1),
                height: max(geometry.size.height - 24, 1)
            )
            let points = frequencies.enumerated()
                .map { index, frequency in
                    (
                        index: index,
                        point: point(forFrequency: frequency, gain: gains[safe: index] ?? 0.0, in: plotRect)
                    )
                }
                .sorted { $0.point.x < $1.point.x }

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))

                Path { path in
                    for tick in 0 ... 6 {
                        let ratio = CGFloat(tick) / 6.0
                        let y = plotRect.minY + ratio * plotRect.height
                        path.move(to: CGPoint(x: plotRect.minX, y: y))
                        path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
                    }
                }
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)

                Path { path in
                    guard let firstPoint = points.first?.point else { return }
                    path.move(to: firstPoint)
                    for point in points.dropFirst() {
                        path.addLine(to: point.point)
                    }
                }
                .stroke(Color.blue.opacity(0.85), lineWidth: 2)

                ForEach(points, id: \.index) { item in
                    Circle()
                        .fill(selectedBandIndex == item.index ? Color.orange : Color.blue)
                        .frame(width: selectedBandIndex == item.index ? 14 : 12, height: selectedBandIndex == item.index ? 14 : 12)
                        .position(item.point)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    selectedBandIndex = item.index
                                    frequencies[item.index] = frequency(forX: value.location.x, in: plotRect)
                                    gains[item.index] = gain(forY: value.location.y, in: plotRect)
                                }
                        )
                        .onTapGesture {
                            selectedBandIndex = item.index
                        }
                }
            }
        }
    }

    private func point(forFrequency frequency: Double, gain: Double, in plotRect: CGRect) -> CGPoint {
        let clampedFrequency = max(minFrequency, min(maxFrequency, frequency))
        let clampedGain = max(minGain, min(maxGain, gain))

        let xRatio = (log10(clampedFrequency) - log10(minFrequency)) / (log10(maxFrequency) - log10(minFrequency))
        let yRatio = (maxGain - clampedGain) / (maxGain - minGain)

        return CGPoint(
            x: plotRect.minX + CGFloat(xRatio) * plotRect.width,
            y: plotRect.minY + CGFloat(yRatio) * plotRect.height
        )
    }

    private func frequency(forX x: CGFloat, in plotRect: CGRect) -> Double {
        let clampedX = max(plotRect.minX, min(plotRect.maxX, x))
        let ratio = Double((clampedX - plotRect.minX) / plotRect.width)
        let logFrequency = log10(minFrequency) + ratio * (log10(maxFrequency) - log10(minFrequency))
        return pow(10, logFrequency)
    }

    private func gain(forY y: CGFloat, in plotRect: CGRect) -> Double {
        let clampedY = max(plotRect.minY, min(plotRect.maxY, y))
        let ratio = Double((clampedY - plotRect.minY) / plotRect.height)
        return maxGain - ratio * (maxGain - minGain)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
