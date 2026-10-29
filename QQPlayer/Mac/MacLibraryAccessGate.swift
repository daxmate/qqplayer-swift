//
//  MacLibraryAccessGate.swift
//  QQPlayer
//
//  **曲库授权引导页**（MAS 沙盒化，批 2B 2026-10-29）。
//
//  主窗内容的前置门：`MacLibraryRootAccess.state` 不是 `.granted` 时，整窗替换成
//  授权引导（选文件夹 / 导入旧库），**绝不进空库主页**——沙盒下读不到目录时若直接
//  放行主窗，用户看到的是「歌全没了」，而不是「需要授权」。
//
//  为什么门放在 WindowGroup 根（而不是某个视图里弹 sheet）：
//  未授权时连 `DatabaseManager` 都不该开（打开的是容器里空库 → 可能触发一次
//  空扫描把旧状态覆盖掉）；门在根上，`MacLibraryView.task` 根本不会跑。
//
//  target: macos-only
//

import AppKit
import SwiftUI

struct MacLibraryAccessGate<Content: View>: View {
    @Environment(MacLibraryRootAccess.self) private var access

    private let content: () -> Content

    @State private var errorMessage: String?
    @State private var importMessage: String?
    @State private var isImporting = false
    @State private var legacyDatabaseFound = false

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        Group {
            if access.state == .granted {
                content()
            } else {
                setupView
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            refresh()
        }
    }

    // MARK: - 引导页

    private var setupView: some View {
        VStack(spacing: DesignTokens.space16) {
            Spacer(minLength: DesignTokens.space24)

            Image(systemName: "folder.badge.key")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(.accentColor)

            Text("library_access_gate_title".localized)
                .font(.title2.weight(.semibold))

            Text("library_access_gate_body".localized)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)

            Text("library_access_gate_default".localized(with: MacLibraryRoot.defaultRootURL.path))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                chooseLibraryFolder()
            } label: {
                Label("library_access_authorize".localized, systemImage: "folder.badge.plus")
                    .frame(minWidth: 200)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Divider()
                .frame(maxWidth: 460)
                .padding(.vertical, DesignTokens.space8)

            legacyImportSection

            Spacer(minLength: DesignTokens.space24)
        }
        .padding(DesignTokens.space24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 旧库导入

    private var legacyImportSection: some View {
        VStack(spacing: DesignTokens.space8) {
            if legacyDatabaseFound {
                Label("library_import_legacy_hint".localized, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Button {
                importLegacyDatabase()
            } label: {
                if isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("library_import_legacy".localized, systemImage: "internaldrive")
                }
            }
            .disabled(isImporting)

            if let importMessage {
                Text(importMessage)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
    }

    // MARK: - 动作

    private func refresh() {
        access.refreshState()
        legacyDatabaseFound = MacLegacyLibraryImporter.legacyDatabaseExists()
    }

    private func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory()
        panel.message = "library_access_gate_body".localized
        panel.prompt = Localized.ok
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try access.authorize(url)
            errorMessage = nil
            if access.state != .granted {
                errorMessage = "library_access_grant_failed".localized(with: url.path)
            }
        } catch {
            errorMessage = "library_access_grant_failed".localized(with: error.localizedDescription)
        }
    }

    /// 面板初始目录：期望根存在就用它，否则用它最近的存在的父目录（不存在则用音乐目录）。
    private func initialDirectory() -> URL {
        let desired = access.desiredRootURL
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: desired.path) { return desired }
        let parent = desired.deletingLastPathComponent()
        if fileManager.fileExists(atPath: parent.path) { return parent }
        return fileManager.urls(for: .musicDirectory, in: .userDomainMask).first ?? parent
    }

    private func importLegacyDatabase() {
        isImporting = true
        importMessage = nil
        defer { isImporting = false }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let legacy = MacLegacyLibraryImporter.legacyDirectoryURL(),
           FileManager.default.fileExists(atPath: legacy.deletingLastPathComponent().path) {
            panel.directoryURL = legacy.deletingLastPathComponent()
        }
        panel.message = "library_import_legacy_prompt".localized
        panel.prompt = Localized.ok
        guard panel.runModal() == .OK, let directory = panel.url else {
            importMessage = nil
            return
        }

        do {
            try importDatabase(from: directory)
        } catch let error as MacLegacyLibraryImporter.ImportError {
            if case .sourceMissing = error {
                importMessage = "library_import_legacy_missing".localized
            } else {
                importMessage = "library_import_legacy_failed".localized(with: error.localizedDescription)
            }
        } catch {
            importMessage = "library_import_legacy_failed".localized(with: error.localizedDescription)
        }
    }

    private func importDatabase(from directory: URL) throws {
        let destination = try destinationDirectory()
        let outcome = try MacLegacyLibraryImporter.importDatabase(from: directory, into: destination)
        var message = "library_import_legacy_done".localized(with: outcome.copiedFiles.count)
        if let backup = outcome.backupFileName {
            message += " " + "library_import_legacy_backup".localized(with: backup)
        }
        importMessage = message
    }

    private func destinationDirectory() throws -> URL {
        guard let root = LibraryRoot.macAppSupportRootURL() else {
            throw MacLegacyLibraryImporter.ImportError.destinationUnavailable("Application Support")
        }
        return root
    }
}
