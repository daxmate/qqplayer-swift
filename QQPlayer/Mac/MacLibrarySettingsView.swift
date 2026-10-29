//
//  MacLibrarySettingsView.swift
//  QQPlayer
//
//  设置 →「音乐库」分类：曲库**唯一位置**（默认 `~/Music/QQPlayer` 或用户指定；M2 单值化）
//  + 文件类型 chips。从 `MacSettingsView.swift` 拆出（该文件已超 600 行预算线；
//  与本仓既有「每分类一个设置视图文件」的形状一致：MacEQ/MacOnline/MacScrape/...）。
//
//  本功能专用文案走**内联 key**（`"library_root".localized`），不加 `Localized.*` 静态项——
//  `LocalizationHelper.swift` 已在 600 行预算线附近，且既有 sync 视图同样内联。
//
//  target: macos-only
//

import AppKit
import SwiftUI

/// 音乐库分类：曲库唯一位置（默认 `~/Music/QQPlayer` 或用户指定；M2 单值化）。
/// 「更换…」可选把旧库内容拷到新位置；变化后重扫曲库（`LibraryFoldersChanged` 通知）。
struct MacLibrarySettingsView: View {
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor
    @State private var deleteSettings = DeleteSettings.load()
    /// 拷贝进度（nil = 当前没有在拷）。
    @State private var copyProgress: MacLibraryRootCopy.Progress?
    /// 最近一次动作的结果文案（拷贝完成 / 已更换 / 已恢复默认）。
    @State private var resultMessage: String?
    /// 回收区管理弹窗（2026-09-29 回收区管理批）。
    @State private var showReclaimArea = false

    /// 曲库根授权状态（MAS 批 2B）：设置页与引导页读同一份，避免「两个地方两套口径」。
    @Environment(MacLibraryRootAccess.self) private var libraryAccess
    @State private var accessMessage: String?
    @State private var isImportingLegacy = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                    Text(positionSummary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if !deleteSettings.libraryRoot.isEmpty {
                        Button("library_root_reset".localized) {
                            resetToDefault()
                        }
                    }
                }

                if MacLibraryRoot.specifiedRootIsUnavailable(deleteSettings.libraryRoot) {
                    Text("library_root_unavailable_hint".localized)
                        .font(.callout)
                        .foregroundColor(.orange)
                }

                if let copyProgress {
                    HStack(spacing: DesignTokens.space8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("library_root_copy_progress".localized(with: copyProgress.done, copyProgress.total))
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                } else if let resultMessage {
                    Text(resultMessage)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("library_root".localized)
                    .settingsAnchor(MacSettingsCatalog.libraryLocation)
            }

            Section {
                Button {
                    pickRoot()
                } label: {
                    Label("library_root_change".localized, systemImage: "folder.badge.gearshape")
                }
                .disabled(copyProgress != nil)
            }

            // 曲库文件夹访问权限（MAS 批 2B，2026-10-29）：沙盒下容器外目录必须显式授权。
            // 状态行 + 重新授权 + 旧库导入入口（首启引导页之外的常驻入口）。
            Section {
                HStack(spacing: DesignTokens.space8) {
                    Image(systemName: libraryAccess.state == .granted ? "lock.open" : "lock.slash")
                        .foregroundColor(libraryAccess.state == .granted ? .green : .orange)
                    Text(libraryAccess.state == .granted
                        ? "library_access_state_granted".localized
                        : "library_access_state_needed".localized)
                    Spacer()
                    Button {
                        authorizeLibraryFolder()
                    } label: {
                        Text("library_access_authorize".localized)
                    }
                }

                Button {
                    importLegacyDatabase()
                } label: {
                    if isImportingLegacy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("library_import_legacy".localized, systemImage: "internaldrive")
                    }
                }
                .disabled(isImportingLegacy)

                if let accessMessage {
                    Text(accessMessage)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("library_access_section".localized)
            } footer: {
                Text("library_access_section_footer".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 文件类型（web 版「文件类型」chips 对齐，2026-09-03 B 组）：
            // 多选 chips，至少保留一种；改动保存后触发曲库重扫（取消的格式
            // 由扫描收尾 reconcile 从库移除，文件保留在磁盘，勾回重扫恢复）。
            Section {
                fileTypeChips
            } header: {
                Text(Localized.libraryFileTypes)
                    .settingsAnchor(MacSettingsCatalog.libraryFileTypes)
            } footer: {
                Text(Localized.libraryFileTypesFooter)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 回收区（2026-09-29 回收区管理批）：查看 / 恢复 / 彻底删除
            // （生产回收区 `<曲库根>/.Trash`；业务逻辑全在 Services，本页只做入口）。
            Section {
                Button {
                    showReclaimArea = true
                } label: {
                    Label("reclaim_area".localized, systemImage: "trash")
                }
            } header: {
                Text("reclaim_area".localized)
            } footer: {
                Text("reclaim_area_description".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showReclaimArea) {
            MacReclaimAreaView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            deleteSettings = DeleteSettings.load()
        }
    }

    /// 文件类型多选 chips。最后一个启用项不可取消（web 版至少保留一种语义）。
    private var fileTypeChips: some View {
        let enabled = Set(deleteSettings.audioExtensions)
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 84), spacing: DesignTokens.space8)],
            alignment: .leading,
            spacing: DesignTokens.space8
        ) {
            ForEach(LibraryAudioFormats.allSupported, id: \.self) { ext in
                let isOn = enabled.contains(ext)
                let isLastEnabled = isOn && enabled.count == 1
                Button {
                    guard !isLastEnabled else { return }
                    toggleExtension(ext, currentlyEnabled: enabled)
                } label: {
                    Text("." + ext)
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, DesignTokens.space10)
                        .padding(.vertical, DesignTokens.space4)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: DesignTokens.radius6)
                                .fill(isOn ? appAccentColor.opacity(0.18) : Color.gray.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.radius6)
                                .strokeBorder(isOn ? appAccentColor : Color.gray.opacity(0.25), lineWidth: 1)
                        )
                        .foregroundColor(isOn ? appAccentColor : .primary)
                        .opacity(isLastEnabled ? 0.55 : 1)
                }
                .buttonStyle(.plain)
                .help(isLastEnabled ? Localized.libraryFileTypesFooter : "")
            }
        }
        .padding(.vertical, DesignTokens.space2)
    }

    private func toggleExtension(_ ext: String, currentlyEnabled: Set<String>) {
        var settings = deleteSettings
        var next = currentlyEnabled
        if next.contains(ext) {
            // 至少保留一种（web 版 toggleExt 语义：next.length 为 0 则不保存）
            guard next.count > 1 else { return }
            next.remove(ext)
        } else {
            next.insert(ext)
        }
        // 存小写不带点、按支持顺序排列（保证存储稳定）
        settings.audioExtensions = LibraryAudioFormats.allSupported.filter { next.contains($0) }
        settings.save()
        deleteSettings = settings
        // 触发主窗口重扫曲库（取消格式 → reconcile 移除该格式曲目）
        NotificationCenter.default.post(name: .libraryScanCriteriaChanged, object: nil)
    }

    /// 位置行：指定了显示指定路径；未指定显示默认路径 +「（默认）」。
    private var positionSummary: String {
        if let specified = MacLibraryRoot.expandedSpecifiedPath(deleteSettings.libraryRoot) {
            return specified
        }
        return MacLibraryRoot.defaultRootURL.path + "library_root_default_suffix".localized
    }

    /// 写入曲库位置 + 触发主窗口重扫（通知名保持不变——别处有订阅）。
    private func applyRoot(_ newRoot: String) {
        var settings = deleteSettings
        settings.libraryRoot = newRoot
        settings.save()
        deleteSettings = settings
        NotificationCenter.default.post(name: .libraryFoldersChanged, object: nil)
    }

    /// 「恢复默认」：清空指定 → 回默认根。
    private func resetToDefault() {
        guard !deleteSettings.libraryRoot.isEmpty else { return }
        copyProgress = nil
        applyRoot("")
        // 默认根同样在容器外：回到默认后需要重新授权（主窗会自动回到授权引导页）。
        libraryAccess.refreshState()
        resultMessage = "library_root_changed".localized
    }

    /// 「更换…」：单选目录 → 询问是否拷贝旧库内容。
    private func pickRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "library_root_change_prompt".localized
        panel.prompt = Localized.ok
        guard panel.runModal() == .OK, let newURL = panel.url else { return }

        let oldRoot = MacLibraryRoot.resolvedRootURL
        guard newURL.standardizedFileURL.path != oldRoot.standardizedFileURL.path else { return }

        switch confirmCopy(old: oldRoot.path, new: newURL.path) {
        case .copy:
            copyLibraryContents(from: oldRoot, to: newURL)
        case .keepOnly:
            copyProgress = nil
            applyRoot(newURL.path)
            authorizeRootIfNeeded(newURL)
            resultMessage = "library_root_changed".localized
        case .cancel:
            return
        }
    }

    /// 换位置后补授权：沙盒下新目录默认不可读，书签是唯一的持久授权手段。
    /// 授权失败不阻断设置变更（目录仍是设置里的位置，主窗会回到授权引导页）。
    private func authorizeRootIfNeeded(_ url: URL) {
        do {
            try libraryAccess.authorize(url, updateSettings: false)
            accessMessage = nil
        } catch {
            accessMessage = "library_access_grant_failed".localized(with: error.localizedDescription)
        }
    }

    /// 本页「授权…」按钮：选一次曲库文件夹（= 授权 + 指定位置，同一动作）。
    private func authorizeLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = libraryAccess.desiredRootURL
        panel.message = "library_access_gate_body".localized
        panel.prompt = Localized.ok
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try libraryAccess.authorize(url)
            accessMessage = nil
            deleteSettings = DeleteSettings.load()
            NotificationCenter.default.post(name: .libraryFoldersChanged, object: nil)
        } catch {
            accessMessage = "library_access_grant_failed".localized(with: error.localizedDescription)
        }
    }

    /// 导入确认框（覆盖当前容器数据库 = 影响正在用的库）。
    private func confirmLegacyImport() -> Bool {
        let alert = NSAlert()
        alert.messageText = "library_import_legacy".localized
        alert.informativeText = "library_import_legacy_confirm".localized
        alert.addButton(withTitle: Localized.ok)
        alert.addButton(withTitle: "cancel".localized)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 「导入旧版数据库…」：选旧目录（Application Support/QQPlayerMac）→ 拷进容器。
    private func importLegacyDatabase() {
        // 本页导入时 App 正在运行（数据库已打开）：覆盖前必须让用户确认，
        // 且明确「完成后重启」（当前会话仍读写旧 inode）。
        guard confirmLegacyImport() else { return }

        isImportingLegacy = true
        defer { isImportingLegacy = false }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let legacy = MacLegacyLibraryImporter.legacyDirectoryURL() {
            let parent = legacy.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) { panel.directoryURL = parent }
        }
        panel.message = "library_import_legacy_prompt".localized
        panel.prompt = Localized.ok
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        guard let destination = LibraryRoot.macAppSupportRootURL() else {
            accessMessage = "library_import_legacy_failed".localized(
                with: "Application Support unavailable"
            )
            return
        }
        do {
            let outcome = try MacLegacyLibraryImporter.importDatabase(
                from: directory,
                into: destination
            )
            var message = "library_import_legacy_done".localized(with: outcome.copiedFiles.count)
            if let backup = outcome.backupFileName {
                message += " " + "library_import_legacy_backup".localized(with: backup)
            }
            accessMessage = message
        } catch let error as MacLegacyLibraryImporter.ImportError {
            if case .sourceMissing = error {
                accessMessage = "library_import_legacy_missing".localized
            } else {
                accessMessage = "library_import_legacy_failed".localized(with: error.localizedDescription)
            }
        } catch {
            accessMessage = "library_import_legacy_failed".localized(with: error.localizedDescription)
        }
    }

    private enum CopyChoice { case copy, keepOnly, cancel }

    /// 「是否把旧库歌曲/设置拷到新库」确认框（拷贝 / 不拷贝 / 取消）。
    private func confirmCopy(old: String, new: String) -> CopyChoice {
        let alert = NSAlert()
        alert.messageText = "library_root_copy_title".localized
        alert.informativeText = "library_root_copy_message".localized(with: old, new)
        alert.addButton(withTitle: "library_root_copy_confirm".localized)
        alert.addButton(withTitle: "library_root_copy_decline".localized)
        alert.addButton(withTitle: Localized.cancel)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .copy
        case .alertSecondButtonReturn: return .keepOnly
        default: return .cancel
        }
    }

    /// 后台拷贝旧库内容 → 完成后才切换地址 + 重扫。
    /// **先拷后切**（顺序不可颠倒）：`track.path` 相对根的相对路径语义要求新根里
    /// 先有文件；切早了会让主扫的 reconcile 把「新根里还不存在的」曲目行删掉
    /// （见 `FileCleanupManager.reconcileMissingFiles`）。
    private func copyLibraryContents(from oldRoot: URL, to newRoot: URL) {
        copyProgress = MacLibraryRootCopy.Progress(done: 0, total: 0)
        resultMessage = nil
        Task { @MainActor in
            let result = await MacLibraryRootCopy.copyContentsInBackground(from: oldRoot, to: newRoot) { progress in
                DispatchQueue.main.async { copyProgress = progress }
            }
            copyProgress = nil
            applyRoot(newRoot.path)
            authorizeRootIfNeeded(newRoot)
            resultMessage = "library_root_copy_result".localized(
                with: result.copied, result.skipped, result.failed
            )
        }
    }
}
