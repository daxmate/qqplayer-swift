//
//  MacEQSettingsView.swift
//  QQPlayer
//
//  macOS EQ settings (对齐 iOS EQSettingsView)：EQ 开关、常用预设网格、
//  手动 EQ 预设、导入预设、全局增益、GraphicEQ 格式说明。
//  导出用 NSPasteboard 复制文本（macOS 没有 UIActivityViewController）。
//  QQPlayerMac target only。
//

import AppKit
import SwiftUI

struct MacEQSettingsView: View {
    @StateObject private var eqManager = EQManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showingImport = false
    @State private var showingCreateManual = false
    @State private var showingEditManual = false
    @State private var showingCustomEQ = false
    /// 待删除确认的预设（删除前必须确认弹窗）
    @State private var presetPendingDelete: EQPreset?
    /// 导出成功（已复制到剪贴板）提示
    @State private var showCopiedAlert = false
    /// 删除/导出失败提示
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                enableSection
                commonPresetsSection
                manualPresetsSection
                importedPresetsSection
                if eqManager.isEnabled {
                    globalGainSection
                }
                formatInfoSection
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 480, minHeight: 560)
        .sheet(isPresented: $showingImport) {
            MacEQImportView()
        }
        .sheet(isPresented: $showingCreateManual) {
            MacCreateManualEQView()
        }
        .sheet(isPresented: $showingEditManual) {
            if let preset = eqManager.currentPreset, preset.presetType == .manual {
                MacManualEQEditorView(preset: preset)
            }
        }
        .sheet(isPresented: $showingCustomEQ) {
            MacGraphicEQ10BandEditorView()
        }
        .alert(Localized.eqDeleteConfirmTitle, isPresented: Binding(
            get: { presetPendingDelete != nil },
            set: { if !$0 { presetPendingDelete = nil } }
        )) {
            Button(Localized.eqDelete, role: .destructive) {
                if let preset = presetPendingDelete {
                    deletePreset(preset)
                }
            }
            Button(Localized.eqCancel, role: .cancel) {}
        } message: {
            Text(Localized.eqDeleteConfirmMessage(presetPendingDelete?.name ?? ""))
        }
        .alert(Localized.eqCopied, isPresented: $showCopiedAlert) {
            Button(Localized.done, role: .cancel) {}
        }
        .alert(Localized.eqError, isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button(Localized.done, role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(Localized.equalizer)
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Button(Localized.done) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    // MARK: - Sections

    private var enableSection: some View {
        Section {
            Toggle(Localized.enableEqualizer, isOn: $eqManager.isEnabled)
                .tint(.blue)
        } footer: {
            Text(Localized.enableDisableEqDescription)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var commonPresetsSection: some View {
        Section(Localized.presetCommon) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(BuiltinEQPresets.all, id: \.key) { preset in
                    builtinPresetButton(key: preset.key, title: preset.localizedName)
                }
                builtinPresetButton(key: BuiltinEQPresets.customKey, title: Localized.presetCustom)
            }
            .padding(.vertical, 4)
        }
    }

    private var manualPresetsSection: some View {
        Section(Localized.manualEQPresets) {
            if eqManager.availablePresets.contains(where: { $0.presetType == .manual }) {
                ForEach(eqManager.availablePresets.filter { $0.presetType == .manual }) { preset in
                    presetRow(
                        preset: preset,
                        subtitle: Localized.eqManualParametric,
                        subtitleColor: .green
                    ) {
                        applyManualPreset(preset)
                        showingEditManual = true
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
    }

    private var importedPresetsSection: some View {
        Section(Localized.importedPresets) {
            if eqManager.availablePresets.contains(where: { $0.presetType == .imported }) {
                ForEach(eqManager.availablePresets.filter { $0.presetType == .imported }) { preset in
                    presetRow(
                        preset: preset,
                        subtitle: Localized.importedGraphicEQ,
                        subtitleColor: .blue
                    ) {
                        applyImportedPreset(preset)
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
    }

    private var globalGainSection: some View {
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

    private var formatInfoSection: some View {
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
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(4)

                Text(Localized.frequencyGainPairDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Row helpers

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
                .background(isSelected ? Color.blue : Color.gray.opacity(0.15))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    /// 手动/导入预设行：点击应用（手动预设进编辑器），右侧删除/导出按钮。
    private func presetRow(
        preset: EQPreset,
        subtitle: String,
        subtitleColor: Color,
        onSelect: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                onSelect()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(subtitleColor)
                    }

                    Spacer()

                    if eqManager.currentPreset?.id == preset.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 18))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                exportPreset(preset)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help(Localized.eqExport)

            Button(role: .destructive) {
                presetPendingDelete = preset
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help(Localized.eqDelete)
        }
    }

    // MARK: - Actions

    private func applyManualPreset(_ preset: EQPreset) {
        eqManager.clearBuiltin()
        eqManager.isEnabled = true
        eqManager.currentPreset = preset
    }

    private func applyImportedPreset(_ preset: EQPreset) {
        eqManager.clearBuiltin()
        eqManager.isEnabled = true
        eqManager.currentPreset = preset
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
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(graphicEQString, forType: .string)
                    showCopiedAlert = true
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
