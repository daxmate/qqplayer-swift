import SwiftUI

// MARK: - GraphicEQ Import View

struct GraphicEQImportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var eqManager = EQManager.shared

    @State private var showingDocumentPicker = false
    @State private var presetName = ""
    @State private var importError: String?
    @State private var showingTextImport = false
    @State private var textContent = ""

    var body: some View {
        NavigationView {
            Form {
                Section(Localized.presetName) {
                    TextField(Localized.enterPresetName, text: $presetName)
                }

                Section(Localized.importMethods) {
                    Button(Localized.importFromTxtFile) {
                        showingDocumentPicker = true
                    }
                    .foregroundColor(.blue)

                    Button(Localized.pasteGraphicEQText) {
                        showingTextImport = true
                    }
                    .foregroundColor(.blue)
                }

                if let error = importError {
                    Section(Localized.eqError) {
                        Text(error)
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
                            .background(Color(.systemGray6))
                            .cornerRadius(DesignTokens.radius4)

                        Text(Localized.frequencyGainPair)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(Localized.importGraphicEQ)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(Localized.eqCancel) {
                        dismiss()
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingDocumentPicker,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .sheet(isPresented: $showingTextImport) {
            TextImportView(
                textContent: $textContent,
                presetName: presetName.isEmpty ? "Imported Preset" : presetName,
                onImport: handleTextImport
            )
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            Task {
                guard url.startAccessingSecurityScopedResource() else {
                    await MainActor.run {
                        importError = Localized.fileImportFailed("Unable to access the selected file.")
                    }
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }

                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    let finalPresetName = presetName.isEmpty
                        ? url.deletingPathExtension().lastPathComponent
                        : presetName

                    let preset = try await eqManager.importGraphicEQPreset(from: content, name: finalPresetName)

                    await MainActor.run {
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

        case .failure(let error):
            importError = Localized.fileImportFailed(error.localizedDescription)
        }
    }

    private func handleTextImport(_ content: String, name: String) {
        Task {
            do {
                let preset = try await eqManager.importGraphicEQPreset(from: content, name: name)

                await MainActor.run {
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

// MARK: - Text Import View

struct TextImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var textContent: String
    let presetName: String
    let onImport: (String, String) -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(Localized.pasteGraphicEQTextSection) {
                    TextEditor(text: $textContent)
                        .frame(minHeight: 200)
                        .font(.caption.monospaced())
                }

                Section(Localized.example) {
                    Text("GraphicEQ: 20 -7.9; 21 -7.9; 22 -8.0; ...")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(Localized.pasteGraphicEQ)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(Localized.eqCancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.eqImport) {
                        onImport(textContent, presetName)
                        dismiss()
                    }
                    .disabled(textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
