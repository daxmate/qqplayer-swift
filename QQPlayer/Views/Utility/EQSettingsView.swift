//
//  EQSettingsView.swift
//  QQPlayer
//
//  Graphic equalizer settings and management UI
//

import SwiftUI

struct EQSettingsView: View {
    @StateObject private var eqManager = EQManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showingImport = false
    @State private var showingCreateManual = false
    @State private var showingEditManual = false
    @State private var showingCustomEQ = false
    /// 删除/导出失败提示（原实现只 print 无用户反馈）
    @State private var actionError: String?

    var body: some View {
        NavigationView {
            formContent
        }
    }

    private var formContent: some View {
        Form {
            // EQ Enable/Disable
            Section {
                Toggle(Localized.enableEqualizer, isOn: $eqManager.isEnabled)
                    .tint(.blue)
            } footer: {
                Text(Localized.enableDisableEqDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Common Presets (常用预设)
            Section(Localized.presetCommon) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(BuiltinEQPresets.all, id: \.key) { preset in
                        builtinPresetButton(key: preset.key, title: preset.localizedName)
                    }
                    builtinPresetButton(key: BuiltinEQPresets.customKey, title: Localized.presetCustom)
                }
                .padding(.vertical, 4)
            }
            Section(Localized.manualEQPresets) {
                if eqManager.availablePresets.contains(where: { $0.presetType == .manual }) {
                    ForEach(eqManager.availablePresets.filter { $0.presetType == .manual }) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.headline)

                                Text(Localized.eqManualParametric)
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }

                            Spacer()

                            if eqManager.currentPreset?.id == preset.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 20))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            eqManager.clearBuiltin()
                            eqManager.isEnabled = true
                            eqManager.currentPreset = preset
                            showingEditManual = true
                        }
                        .swipeActions(edge: .trailing) {
                            Button(Localized.eqDelete, role: .destructive) {
                                deletePreset(preset)
                            }

                            Button(Localized.eqEdit) {
                                eqManager.clearBuiltin()
                                eqManager.isEnabled = true
                                eqManager.currentPreset = preset
                                showingEditManual = true
                            }
                            .tint(.green)

                            Button(Localized.eqExport) {
                                exportPreset(preset)
                            }
                            .tint(.blue)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Localized.noManualPresetsCreated)
                            .foregroundColor(.secondary)
                            .italic()

                        Text(Localized.createManualEQDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Button(Localized.eqCreateManual) {
                    showingCreateManual = true
                }
                .foregroundColor(.green)
            }

            // Imported GraphicEQ Presets
            Section(Localized.importedPresets) {
                if eqManager.availablePresets.contains(where: { $0.presetType == .imported }) {
                    ForEach(eqManager.availablePresets.filter { $0.presetType == .imported }) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.headline)

                                Text(Localized.importedGraphicEQ)
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }

                            Spacer()

                            if eqManager.currentPreset?.id == preset.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 20))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            eqManager.clearBuiltin()
                            eqManager.isEnabled = true
                            eqManager.currentPreset = preset
                        }
                        .swipeActions(edge: .trailing) {
                            Button(Localized.eqDelete, role: .destructive) {
                                deletePreset(preset)
                            }

                            Button(Localized.eqExport) {
                                exportPreset(preset)
                            }
                            .tint(.blue)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Localized.noPresetsImported)
                            .foregroundColor(.secondary)
                            .italic()

                        Text(Localized.importGraphicEQDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Button(Localized.importGraphicEQFile) {
                    showingImport = true
                }
                .foregroundColor(.blue)
            }

            // Global Gain (only show when EQ is enabled)
            if eqManager.isEnabled {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(Localized.globalGain)
                            Spacer()
                            Text("\(eqManager.globalGain, specifier: "%.1f")dB")
                                .foregroundColor(.secondary)
                        }

                        Slider(value: $eqManager.globalGain, in: -30 ... 30, step: 0.5)
                            .tint(.blue)
                    }
                } header: {
                    Text(Localized.globalSettings)
                } footer: {
                    Text(Localized.globalGainDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Info Section
            Section(Localized.aboutGraphicEQFormat) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Localized.importGraphicEQFormatDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("GraphicEQ: 20 -7.9; 21 -7.8; 22 -8.0; ...")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color(.systemGray6))
                        .cornerRadius(4)

                    Text(Localized.frequencyGainPairDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(Localized.equalizer)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingImport) {
            GraphicEQImportView()
        }
        .sheet(isPresented: $showingCreateManual) {
            CreateManualEQView()
        }
        .sheet(isPresented: $showingEditManual) {
            if let preset = eqManager.currentPreset, preset.presetType == .manual {
                ManualEQEditorView(preset: preset)
            }
        }
        .sheet(isPresented: $showingCustomEQ) {
            GraphicEQ10BandEditorView()
        }
        .alert(Localized.eqError, isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button(Localized.done, role: .cancel) { }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Helper Methods

    private func builtinPresetButton(key: String, title: String) -> some View {
        let isSelected = eqManager.activeBuiltinKey == key
        return Button {
            if key == BuiltinEQPresets.customKey {
                showingCustomEQ = true
            } else {
                eqManager.applyBuiltinPreset(key)
            }
        } label: {
            Text(title)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue : Color(.systemGray6))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func deletePreset(_ preset: EQPreset) {
        Task {
            do {
                try await eqManager.deletePreset(preset)
            } catch {
                print("❌ \(Localized.failedToDelete): \(error)")
                await MainActor.run {
                    actionError = Localized.failedToDelete
                }
            }
        }
    }

    private func exportPreset(_ preset: EQPreset) {
        Task {
            do {
                let graphicEQString = try await eqManager.exportPreset(preset)
                await MainActor.run {
                    let activityVC = UIActivityViewController(activityItems: [graphicEQString], applicationActivities: nil)
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootViewController = windowScene.windows.first?.rootViewController {
                        rootViewController.present(activityVC, animated: true)
                    }
                }
            } catch {
                print("❌ \(Localized.failedToExport): \(error)")
                await MainActor.run {
                    actionError = Localized.failedToExport
                }
            }
        }
    }
}
