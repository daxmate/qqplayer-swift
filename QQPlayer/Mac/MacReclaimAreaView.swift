//
//  MacReclaimAreaView.swift
//  QQPlayer
//
//  设置 →「音乐库」→「回收区」（macOS）：生产回收区 `<曲库根>/.Trash` 的
//  **查看 / 恢复 / 彻底删除**（2026-09-29 回收区管理批）。
//
//  与 iOS 侧 `QQPlayer/Views/Library/ReclaimAreaView.swift` **共享同一套 Services**
//  （`ReclaimAreaCatalog` / `ReclaimRestoreService` / `ReclaimPurgeService`）——
//  本文件只做平台呈现，**不复制任何业务判定**。
//
//  target: macos-only
//

import AppKit
import SwiftUI

struct MacReclaimAreaView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryIndexer.self) private var libraryIndexer

    @State private var entries: [ReclaimAreaEntry] = []
    @State private var selection = Set<String>()
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var resultMessage: String?
    @State private var pendingPurge: PurgeRequest?

    private enum PurgeRequest: Identifiable {
        case selected([ReclaimAreaEntry])
        case all([ReclaimAreaEntry])

        var id: String {
            switch self {
            case .selected: return "selected"
            case .all: return "all"
            }
        }

        var items: [ReclaimAreaEntry] {
            switch self {
            case .selected(let items): return items
            case .all(let items): return items
            }
        }
    }

    private var libraryRoot: URL { DatabaseSyncCollectionFacts.defaultLibraryRoot }

    private var selectedEntries: [ReclaimAreaEntry] {
        entries.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: DesignTokens.space0) {
            header
            Divider()
            content
            Divider()
            actionBar
        }
        .frame(minWidth: 620, minHeight: 440)
        .overlay {
            if isLoading || isWorking {
                ProgressView()
            }
        }
        .alert(
            "reclaim_purge_confirm_title".localized,
            isPresented: Binding(
                get: { pendingPurge != nil },
                set: { if !$0 { pendingPurge = nil } }
            )
        ) {
            if let request = pendingPurge {
                Button("reclaim_purge_all".localized, role: .destructive) {
                    let items = request.items
                    pendingPurge = nil
                    purge(items)
                }
                Button(Localized.cancel, role: .cancel) { pendingPurge = nil }
            }
        } message: {
            if let request = pendingPurge {
                Text(purgeConfirmMessage(for: request))
            }
        }
        .task { await reload() }
    }

    // MARK: - 子视图

    private var header: some View {
        HStack(spacing: DesignTokens.space8) {
            Image(systemName: "trash")
                .foregroundColor(.secondary)
            Text("reclaim_area".localized)
                .font(.headline)
            Spacer()
            Text(summaryText)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding(DesignTokens.space12)
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            VStack {
                Spacer()
                Text("reclaim_area_empty".localized)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(entries) { entry in
                    row(entry)
                        .tag(entry.id)
                }
            }
        }
    }

    private func row(_ entry: ReclaimAreaEntry) -> some View {
        HStack(spacing: DesignTokens.space12) {
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(entry.existingName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(for: entry))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !entry.isRestorable {
                Text("reclaim_not_restorable".localized)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .contentShape(Rectangle())
    }

    private var actionBar: some View {
        VStack(spacing: DesignTokens.space8) {
            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: DesignTokens.space8) {
                Button(selection.count == entries.count && !entries.isEmpty
                    ? "reclaim_deselect_all".localized
                    : "reclaim_select_all".localized) {
                        selection = selection.count == entries.count ? [] : Set(entries.map(\.id))
                    }
                    .disabled(entries.isEmpty)

                Spacer()

                Button {
                    restore(selectedEntries)
                } label: {
                    Label("reclaim_restore_selected".localized(with: selection.count), systemImage: "arrow.uturn.backward")
                }
                .disabled(selection.isEmpty || isWorking)

                Button(role: .destructive) {
                    pendingPurge = .selected(selectedEntries)
                } label: {
                    Label("reclaim_delete_selected".localized(with: selection.count), systemImage: "trash")
                }
                .disabled(selection.isEmpty || isWorking)

                Button(role: .destructive) {
                    pendingPurge = .all(entries)
                } label: {
                    Text("reclaim_purge_all".localized)
                }
                .disabled(entries.isEmpty || isWorking)
            }
        }
        .padding(DesignTokens.space12)
    }

    // MARK: - 文案

    private var summaryText: String {
        "reclaim_area_summary".localized(
            entries.count,
            ReclaimAreaCatalog.formattedSize(ReclaimAreaCatalog.totalByteSize(of: entries))
        )
    }

    private func subtitle(for entry: ReclaimAreaEntry) -> String {
        let size = ReclaimAreaCatalog.formattedSize(entry.byteSize)
        guard let date = entry.modificationDate else { return size }
        return "\(size) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func purgeConfirmMessage(for request: PurgeRequest) -> String {
        let items = request.items
        let size = ReclaimAreaCatalog.formattedSize(ReclaimAreaCatalog.totalByteSize(of: items))
        switch request {
        case .selected:
            return "reclaim_purge_confirm_message".localized(items.count, size)
        case .all:
            return "reclaim_purge_all_confirm_message".localized(items.count, size)
        }
    }

    // MARK: - 动作

    private func reload() async {
        isLoading = true
        let root = libraryRoot
        let loaded = await Task.detached { ReclaimAreaCatalog.entries(libraryRoot: root) }.value
        entries = loaded
        selection = selection.intersection(Set(loaded.map(\.id)))
        isLoading = false
    }

    private func restore(_ items: [ReclaimAreaEntry]) {
        guard !items.isEmpty, !isWorking else { return }
        isWorking = true
        resultMessage = nil
        Task { @MainActor in
            var restored = 0
            var skipped = 0
            var failed = 0
            for entry in items {
                switch await ReclaimRestoreService.restore(
                    entry: entry,
                    libraryRoot: libraryRoot,
                    indexer: libraryIndexer
                ) {
                case .restored: restored += 1
                case .skipped: skipped += 1
                case .failed: failed += 1
                }
            }
            var text = "reclaim_restore_result".localized(restored, skipped)
            if failed > 0 {
                text += " · " + "reclaim_operation_failed".localized(failed)
            }
            resultMessage = text
            isWorking = false
            await reload()
        }
    }

    private func purge(_ items: [ReclaimAreaEntry]) {
        guard !items.isEmpty, !isWorking else { return }
        isWorking = true
        resultMessage = nil
        Task { @MainActor in
            let summary = await Task.detached { ReclaimPurgeService.purge(items) }.value
            var text = "reclaim_purge_result".localized(
                summary.deleted,
                ReclaimAreaCatalog.formattedSize(summary.freedBytes)
            )
            if summary.failedCount > 0 {
                text += " · " + "reclaim_operation_failed".localized(summary.failedCount)
            }
            resultMessage = text
            isWorking = false
            await reload()
        }
    }
}
