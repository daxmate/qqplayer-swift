//
//  EQManager+Presets.swift
//  QQPlayer
//
//  DB 预设管理（增删改查）/ 设置持久化（loadSettings / saveSettings）/ GraphicEQ 导入导出。
//  E4（2026-09-21）自 EQManager.swift 拆出——纯搬家。
//
import Foundation
import GRDB

@MainActor
extension EQManager {
    // MARK: - Preset Management

    func loadPresets() {
        Task {
            do {
                let presets = try await databaseManager.getAllEQPresets()
                await MainActor.run {
                    self.availablePresets = presets
                }
            } catch {
                AppLog.error(.general, "❌ Failed to load EQ presets: \(error)")
            }
        }
    }

    static func defaultParametricFrequencies(for bandCount: Int) -> [Double] {
        let clampedBandCount = max(0, min(16, bandCount))
        guard clampedBandCount > 0 else { return [] }
        guard clampedBandCount > 1 else { return [1000.0] }

        let minFrequency = 20.0
        let maxFrequency = 20_000.0
        return (0 ..< clampedBandCount).map { index in
            minFrequency * pow(maxFrequency / minFrequency, Double(index) / Double(clampedBandCount - 1))
        }
    }

    func createPreset(
        name: String,
        frequencies: [Double],
        gains: [Double],
        bandwidths: [Double]? = nil,
        type: EQPresetType = .imported
    ) async throws -> EQPreset {
        let currentTime = Int64(Date().timeIntervalSince1970)

        let preset = EQPreset(
            name: name,
            isBuiltIn: false,
            isActive: false,
            presetType: type,
            createdAt: currentTime,
            updatedAt: currentTime
        )

        let savedPreset = try await databaseManager.saveEQPreset(preset)

        // Create bands for the preset
        let bandCount = min(frequencies.count, gains.count)
        let bandwidthValues = bandwidths ?? Array(repeating: 1.0, count: bandCount)
        for index in 0 ..< bandCount {
            let band = EQBand(
                presetId: savedPreset.id!,
                frequency: frequencies[index],
                gain: gains[index],
                bandwidth: index < bandwidthValues.count ? max(0.05, min(5.0, bandwidthValues[index])) : 1.0,
                bandIndex: index
            )
            try await databaseManager.saveEQBand(band)
        }

        await MainActor.run {
            self.loadPresets()
        }

        return savedPreset
    }

    func deletePreset(_ preset: EQPreset) async throws {
        guard !preset.isBuiltIn else {
            throw EQError.cannotDeleteBuiltInPreset
        }

        try await databaseManager.deleteEQPreset(preset)

        await MainActor.run {
            if self.currentPreset?.id == preset.id {
                self.currentPreset = nil
            }
            self.loadPresets()
        }
    }

    func updatePresetBands(_ preset: EQPreset, frequencies: [Double], gains: [Double], bandwidths: [Double]) async throws {
        let currentTime = Int64(Date().timeIntervalSince1970)

        try databaseManager.write { db in
            // Update preset timestamp
            var updatedPreset = preset
            updatedPreset.updatedAt = currentTime
            try updatedPreset.update(db)

            // Delete existing bands for this preset
            try db.execute(sql: "DELETE FROM eq_band WHERE preset_id = ?", arguments: [preset.id!])

            // Insert new bands
            let bandCount = min(min(frequencies.count, gains.count), bandwidths.count)
            for index in 0 ..< bandCount {
                let band = EQBand(
                    presetId: preset.id!,
                    frequency: frequencies[index],
                    gain: gains[index],
                    bandwidth: max(0.05, min(5.0, bandwidths[index])),
                    bandIndex: index
                )
                try band.insert(db)
            }
        }

        // If this is the current preset, apply changes immediately
        await MainActor.run {
            if EQPresetApplyGate.shouldApply(requestedPresetId: preset.id, currentPresetId: self.currentPreset?.id) {
                self.applyEQSettings()
            }
        }
    }

    func updatePresetGains(_ preset: EQPreset, frequencies: [Double], gains: [Double]) async throws {
        let bandwidths = Array(repeating: 1.0, count: min(frequencies.count, gains.count))
        try await updatePresetBands(preset, frequencies: frequencies, gains: gains, bandwidths: bandwidths)
    }

    func loadBands(for preset: EQPreset) async throws -> [EQBand] {
        return try await databaseManager.getBands(for: preset)
    }

    // MARK: - Settings Persistence

    func loadSettings() {
        Task {
            do {
                if let settings = try await databaseManager.getEQSettings() {
                    await MainActor.run {
                        self.isEnabled = settings.isEnabled
                        self.globalGain = settings.globalGain
                        // 内置预设优先恢复（UserDefaults 持久化）；恢复成功则跳过 DB preset 恢复
                        if !self.restoreBuiltinPresetIfNeeded() {
                            if let activePresetId = settings.activePresetId {
                                // Load the active preset
                                Task {
                                    if let preset = try? await self.databaseManager.getEQPreset(id: activePresetId) {
                                        await MainActor.run {
                                            self.currentPreset = preset
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // Create default settings
                    let defaultSettings = EQSettings(
                        isEnabled: false,
                        activePresetId: nil,
                        globalGain: 0.0,
                        updatedAt: Int64(Date().timeIntervalSince1970)
                    )
                    try await databaseManager.saveEQSettings(defaultSettings)
                }
            } catch {
                AppLog.error(.general, "❌ Failed to load EQ settings: \(error)")
            }
        }
    }

    func saveSettings() {
        Task {
            do {
                let settings = EQSettings(
                    isEnabled: self.isEnabled,
                    activePresetId: self.currentPreset?.id,
                    globalGain: self.globalGain,
                    updatedAt: Int64(Date().timeIntervalSince1970)
                )
                try await databaseManager.saveEQSettings(settings)
            } catch {
                AppLog.error(.general, "❌ Failed to save EQ settings: \(error)")
            }
        }
    }

    // MARK: - GraphicEQ Import

    // MARK: - Import/Export

    func exportPreset(_ preset: EQPreset) async throws -> String {
        let bands = try await loadBands(for: preset)
        let sortedBands = bands.sorted { $0.bandIndex < $1.bandIndex }
        // 编码下沉 GraphicEQCodec（纯逻辑，可单测）
        return GraphicEQCodec.encode(
            frequencies: sortedBands.map(\.frequency),
            gains: sortedBands.map(\.gain)
        )
    }

    func createManualParametricPreset(name: String, bandCount: Int) async throws -> EQPreset {
        let frequencies = EQManager.defaultParametricFrequencies(for: bandCount)
        let gains = Array(repeating: 0.0, count: frequencies.count)
        let bandwidths = Array(repeating: 1.0, count: frequencies.count)

        return try await createPreset(
            name: name,
            frequencies: frequencies,
            gains: gains,
            bandwidths: bandwidths,
            type: .manual
        )
    }

    func createManual16BandPreset(name: String) async throws -> EQPreset {
        return try await createManualParametricPreset(name: name, bandCount: 16)
    }

    func importGraphicEQPreset(from content: String, name: String) async throws -> EQPreset {
        // 解析下沉 GraphicEQCodec（纯逻辑，可单测）
        let parsed = try GraphicEQCodec.decode(content)

        // Validate we have data
        guard !parsed.frequencies.isEmpty, parsed.frequencies.count == parsed.gains.count else {
            throw EQError.invalidImportData
        }

        return try await createPreset(name: name, frequencies: parsed.frequencies, gains: parsed.gains, type: .imported)
    }
}
