//
//  MacEQImportView.swift
//  QQPlayer
//
//  macOS GraphicEQ 导入页（对齐 iOS GraphicEQImportView + TextImportView，
//  按任务裁剪：不做 NSOpenPanel 文件选择，直接粘贴 GraphicEQ 文本导入）。
//  QQPlayerMac target only。
//

import SwiftUI

struct MacEQImportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var eqManager = EQManager.shared

    @State private var presetName = ""
    @State private var textContent = ""
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section(Localized.presetName) {
                    TextField(Localized.enterPresetName, text: $presetName)
                }

                Section(Localized.pasteGraphicEQTextSection) {
                    TextEditor(text: $textContent)
                        .frame(minHeight: 180)
                        .font(.caption.monospaced())
                }

                if let importError {
                    Section(Localized.eqError) {
                        Text(importError)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                Section(Localized.formatInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Localized.expectedGraphicEQFormat)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("GraphicEQ: 20 -7.9; 21 -7.9; 22 -8.0; 23 -8.0; ...")
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .padding(8)
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(4)

                        Text(Localized.frequencyGainPair)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 460, minHeight: 520)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(Localized.importGraphicEQ)
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Button(Localized.eqCancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(Localized.eqImport) {
                importPreset()
            }
            .disabled(textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    // MARK: - Actions

    private func importPreset() {
        let finalName = presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Localized.eqImportedPreset
            : presetName.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                let preset = try await eqManager.importGraphicEQPreset(from: textContent, name: finalName)

                await MainActor.run {
                    eqManager.clearBuiltin()
                    eqManager.isEnabled = true
                    eqManager.currentPreset = preset
                    importError = nil
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    importError = Localized.failedToImport(error.localizedDescription)
                }
            }
        }
    }
}
