//
//  EQManager.swift
//  QQPlayer — Graphic equalizer management service（iOS / macOS 共用）
//  拆分见 EQManager+Presets.swift（DB 预设 / 持久化 / 导入导出）。
//

import AVFoundation
import Foundation
import GRDB
import Observation

@MainActor
@Observable
class EQManager {
    static let shared = EQManager()

    var isEnabled: Bool = false {
        didSet {
            if isEnabled != oldValue {
                applyEQSettings()
                saveSettings()
            }
        }
    }

    var currentPreset: EQPreset? {
        didSet {
            if currentPreset?.id != oldValue?.id {
                applyEQSettings()
                saveSettings()
            }
        }
    }

    var globalGain: Double = 0.0 {
        didSet {
            if abs(globalGain - oldValue) > 0.01 {
                applyGlobalGain()
                saveSettings()
            }
        }
    }

    var availablePresets: [EQPreset] = []

    /// 当前选中的内置预设 key（nil = 未使用内置预设；"custom" = 自定义 10 段）
    var activeBuiltinKey: String?

    // Runtime EQ data used by both AVAudioEngine and SFBAudioEngine backends
    @ObservationIgnored private var eqFrequencies: [Double] = []
    @ObservationIgnored private var eqGains: [Double] = []
    @ObservationIgnored private var eqBandwidths: [Double] = []

    // Public getters for SFBAudioEngine integration
    var currentEQFrequencies: [Double] { eqFrequencies }
    var currentEQGains: [Double] { eqGains }
    var currentEQBandwidths: [Double] { eqBandwidths }

    @ObservationIgnored let databaseManager = DatabaseManager.shared
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var eqNode: AVAudioUnitEQ?

    private init() {
        loadSettings()
        loadPresets()
    }

    // MARK: - Audio Engine Integration

    func setAudioEngine(_ engine: AVAudioEngine?) {
        audioEngine = engine
        setupEQNode()
    }

    private func setupEQNode() {
        guard let audioEngine = audioEngine else { return }

        // iOS supports up to ~48 bands for AVAudioUnitEQ
        // Using more may cause issues - limit to safe maximum
        let maxSafeBands = 16
        let requestedBands = !eqFrequencies.isEmpty ? min(eqFrequencies.count, maxSafeBands) : maxSafeBands

        AppLog.info(.general, "🎛️ Original bands: \(eqFrequencies.count), requesting: \(requestedBands) (limited to \(maxSafeBands))")

        eqNode = AVAudioUnitEQ(numberOfBands: requestedBands)
        guard let eqNode = eqNode else { return }

        let actualBands = eqNode.bands.count
        AppLog.info(.general, "🎛️ Requested \(requestedBands) bands for GraphicEQ preset, iOS created \(actualBands) bands")

        // Configure bands if we have frequency data
        if !eqFrequencies.isEmpty {
            configureEQBands()
            if eqFrequencies.count > maxSafeBands {
                AppLog.warn(.general, "⚠️ GraphicEQ preset has \(eqFrequencies.count) bands, reduced to \(actualBands) bands (iOS limit)")
            } else {
                AppLog.info(.general, "✅ Using \(actualBands) bands from GraphicEQ preset")
            }
        } else {
            // Default configuration for empty presets
            for i in 0 ..< actualBands {
                let band = eqNode.bands[i]
                band.frequency = Float(1000 * pow(2.0, Double(i - actualBands / 2)))
                band.gain = 0.0
                band.bandwidth = 1.0
                band.filterType = .parametric
                band.bypass = true
            }
        }

        // Attach the EQ node
        audioEngine.attach(eqNode)

        AppLog.info(.general, "✅ EQ node created with \(actualBands) bands")

        // Apply current settings if enabled
        if isEnabled {
            applyEQSettings()
        }
    }

    // insertEQIntoAudioGraph(between:and:format:) 已删除（2026-09-12 审计死代码 ⚰️-7）：
    // 全仓 grep 仅命中定义处、零调用方——真实接线在 PlayerEngine.connectPlaybackChain /
    // ensureMacAudioEngineSetup。

    // Expose this for PlayerEngine to use when reconfiguring
    var currentEQNode: AVAudioUnitEQ? {
        return eqNode
    }

    private func configureEQBands() {
        guard let eqNode = eqNode, !eqFrequencies.isEmpty else { return }

        let availableBands = eqNode.bands.count
        let inputBandCount = eqFrequencies.count

        if inputBandCount <= availableBands {
            // Direct mapping - use exactly what we have
            for i in 0 ..< inputBandCount {
                let band = eqNode.bands[i]
                band.frequency = Float(eqFrequencies[i])
                band.gain = i < eqGains.count ? Float(eqGains[i]) : 0.0
                let bandwidth = i < eqBandwidths.count ? eqBandwidths[i] : 1.0
                band.bandwidth = Float(max(0.05, min(5.0, bandwidth)))
                band.filterType = .parametric
                band.bypass = false
            }

            // Bypass remaining bands
            for i in inputBandCount ..< availableBands {
                eqNode.bands[i].bypass = true
            }

            AppLog.info(.general, "✅ Direct mapping: Using all \(inputBandCount) bands")
        } else {
            // More input bands than available - group and average multiple bands
            AppLog.info(.general, "🔄 Reducing \(inputBandCount) bands to \(availableBands) bands using frequency grouping and averaging")

            let bandsPerGroup = Double(inputBandCount) / Double(availableBands)

            for i in 0 ..< availableBands {
                // Calculate the range of input bands for this output band
                let startIndex = Int(Double(i) * bandsPerGroup)
                let endIndex = min(Int(Double(i + 1) * bandsPerGroup), inputBandCount)

                // Average the frequencies and gains for this group
                var avgFrequency = 0.0
                var avgGain = 0.0
                var avgBandwidth = 0.0
                var groupSize = 0

                for j in startIndex ..< endIndex {
                    if j < eqFrequencies.count && j < eqGains.count {
                        avgFrequency += eqFrequencies[j]
                        avgGain += eqGains[j]
                        avgBandwidth += j < eqBandwidths.count ? eqBandwidths[j] : 1.0
                        groupSize += 1
                    }
                }

                if groupSize > 0 {
                    avgFrequency /= Double(groupSize)
                    avgGain /= Double(groupSize)
                    avgBandwidth /= Double(groupSize)
                }

                let band = eqNode.bands[i]
                band.frequency = Float(avgFrequency)
                band.gain = Float(avgGain)
                band.bandwidth = Float(max(0.05, min(5.0, avgBandwidth)))
                band.filterType = .parametric
                band.bypass = false

                if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "  Band \(i): \(avgFrequency.rounded(toPlaces: 1))Hz, \(avgGain.rounded(toPlaces: 1))dB (avg of \(groupSize) bands: \(startIndex)-\(endIndex - 1))") }
            }

            AppLog.info(.general, "✅ Applied frequency grouping and averaging (\(bandsPerGroup.rounded(toPlaces: 1)) bands per group)")
        }
    }

    func applyEQSettings() {
        let eqNode = self.eqNode

        // 内置预设（常用预设 / 自定义 10 段）激活时直接应用运行时数据，
        // 不走 DB preset 加载路径（activeBuiltinKey 默认 nil，现有行为零变化）
        if activeBuiltinKey != nil {
            applyBuiltinEQData()
            return
        }

        if !isEnabled || currentPreset == nil {
            eqNode?.bands.forEach { $0.bypass = true }
            eqNode?.globalGain = 0.0

            SFBAudioEngineManager.shared.updateEQSettings()
            AppLog.info(.general, "🚫 EQ disabled - all bands bypassed")
            return
        }

        guard let preset = currentPreset else {
            SFBAudioEngineManager.shared.updateEQSettings()
            return
        }

        Task {
            do {
                let bands = try await loadBands(for: preset)
                let sortedBands = bands.sorted { $0.bandIndex < $1.bandIndex }

                // 同源校验（2026-09-12 审计 P4，与 updatePresetBands 同一入口）：await 期间
                // 用户可能已切到别的预设/关闭 EQ，后完成的旧任务不得覆盖新选择。
                guard EQPresetApplyGate.shouldApply(
                    requestedPresetId: preset.id,
                    currentPresetId: currentPreset?.id
                ) else {
                    AppLog.warn(.general, "↩️ EQ 预设加载结果已过期（\(preset.name)），丢弃不落地")
                    return
                }

                await MainActor.run {
                    let newFrequencies = sortedBands.map { $0.frequency }
                    let newGains = sortedBands.map { $0.gain }
                    let newBandwidths = sortedBands.map { max(0.05, min(5.0, $0.bandwidth)) }

                    self.eqFrequencies = newFrequencies
                    self.eqGains = newGains
                    self.eqBandwidths = newBandwidths

                    if self.eqNode != nil {
                        self.configureEQBands()
                        AppLog.info(.general, "✅ Reconfigured existing EQ node with \(newFrequencies.count) input bands")
                    } else {
                        AppLog.info(.general, "ℹ️ Stored \(newFrequencies.count) EQ bands for SFBAudioEngine")
                    }
                }

                applyGlobalGain()
                AppLog.info(.general, "✅ Applied EQ preset: \(preset.name)")
            } catch {
                AppLog.error(.general, "❌ Failed to apply EQ settings: \(error)")
            }
        }
    }

    private func applyGlobalGain() {
        let globalGainFloat = Float(globalGain)
        eqNode?.globalGain = globalGainFloat

        SFBAudioEngineManager.shared.updateEQSettings()
    }
}

// MARK: - Builtin Presets (常用预设 + 自定义 10 段)

@MainActor
extension EQManager {
    /// UserDefaults key：当前选中的内置预设 key（含 "custom"）
    static let builtinPresetUserDefaultsKey = "qqplayer.eq.activeBuiltinKey"
    /// UserDefaults key：自定义 10 段增益（JSON 编码的 [Double]）
    static let builtinCustomGainsUserDefaultsKey = "qqplayer.eq.customGains"

    /// 应用内置预设（7 个常用预设之一）。
    /// 设置运行时数据 + activeBuiltinKey，currentPreset 置 nil（与 DB 预设互斥）。
    func applyBuiltinPreset(_ key: String) {
        guard let preset = BuiltinEQPresets.preset(for: key) else { return }
        let gains = preset.gains
        applyBuiltinData(
            frequencies: BuiltinEQPresets.bands10,
            gains: gains,
            key: key
        )
        UserDefaults.standard.set(key, forKey: Self.builtinPresetUserDefaultsKey)
    }

    /// 应用自定义 10 段增益（滑杆编辑器实时调用），key 记为 "custom"。
    func applyCustomEQGains(_ gains: [Double]) {
        let clamped = gains.map { max(-12.0, min(12.0, $0)) }
        applyBuiltinData(
            frequencies: BuiltinEQPresets.bands10,
            gains: clamped,
            key: BuiltinEQPresets.customKey
        )
        UserDefaults.standard.set(BuiltinEQPresets.customKey, forKey: Self.builtinPresetUserDefaultsKey)
        if let data = try? JSONEncoder().encode(clamped) {
            UserDefaults.standard.set(data, forKey: Self.builtinCustomGainsUserDefaultsKey)
        }
    }

    /// 清除内置预设选中态（应用 DB 预设前由 UI 层调用）。
    func clearBuiltin() {
        guard activeBuiltinKey != nil else { return }
        activeBuiltinKey = nil
        UserDefaults.standard.removeObject(forKey: Self.builtinPresetUserDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.builtinCustomGainsUserDefaultsKey)
    }

    // MARK: - Private

    private func applyBuiltinData(frequencies: [Double], gains: [Double], key: String) {
        eqFrequencies = frequencies
        eqGains = gains
        eqBandwidths = Array(repeating: 1.0, count: frequencies.count)
        activeBuiltinKey = key
        // 选择预设 = 明确使用意图，自动启用 EQ（否则用户选了预设但开关没开，
        // 全程 bypass 听不到任何变化，2026-08-31 用户实测踩坑）
        isEnabled = true
        if currentPreset != nil {
            currentPreset = nil
        }
        applyEQSettings()
        saveSettings()
    }

    /// 内置预设激活时的应用路径：直接用运行时数据配置节点 + SFB。
    /// EQ 关闭时与现有逻辑一致（全部 bypass）。
    private func applyBuiltinEQData() {
        let eqNode = self.eqNode

        if !isEnabled {
            eqNode?.bands.forEach { $0.bypass = true }
            eqNode?.globalGain = 0.0
            SFBAudioEngineManager.shared.updateEQSettings()
            AppLog.info(.general, "🚫 EQ disabled - all bands bypassed")
            return
        }

        if eqNode != nil {
            configureEQBands()
            AppLog.info(.general, "✅ Applied builtin EQ '\(activeBuiltinKey ?? "?")' with \(eqFrequencies.count) bands")
        } else {
            AppLog.info(.general, "ℹ️ Stored \(eqFrequencies.count) builtin EQ bands for SFBAudioEngine")
        }

        applyGlobalGain()
    }

    /// 从 UserDefaults 恢复内置预设；成功返回 true（调用方跳过 DB preset 恢复）。
    /// flat 等预设数据来自静态表；custom 从持久化增益恢复；无 key 或数据非法返回 false。
    @discardableResult
    func restoreBuiltinPresetIfNeeded() -> Bool {
        guard let key = UserDefaults.standard.string(forKey: Self.builtinPresetUserDefaultsKey) else {
            return false
        }

        let storedCustomGains: [Double]?
        if key == BuiltinEQPresets.customKey {
            if let data = UserDefaults.standard.data(forKey: Self.builtinCustomGainsUserDefaultsKey),
               let decoded = try? JSONDecoder().decode([Double].self, from: data) {
                storedCustomGains = decoded
            } else {
                storedCustomGains = nil
            }
        } else {
            storedCustomGains = nil
        }

        guard let gains = BuiltinEQPresets.gains(for: key, storedCustomGains: storedCustomGains),
              gains.count == BuiltinEQPresets.bands10.count else {
            // 非法/失效 key：清掉脏数据，退回 DB preset 恢复
            UserDefaults.standard.removeObject(forKey: Self.builtinPresetUserDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.builtinCustomGainsUserDefaultsKey)
            return false
        }

        eqFrequencies = BuiltinEQPresets.bands10
        eqGains = gains
        eqBandwidths = Array(repeating: 1.0, count: BuiltinEQPresets.bands10.count)
        activeBuiltinKey = key
        // loadSettings 阶段 currentPreset 尚未恢复，必为 nil，不会触发 didSet 重入
        currentPreset = nil
        applyEQSettings()
        return true
    }
}
