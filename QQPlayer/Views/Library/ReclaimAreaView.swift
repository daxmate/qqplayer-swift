//
//  ReclaimAreaView.swift
//  QQPlayer
//
//  设置 →「回收区」（iOS）：生产回收区 `<曲库根>/.Trash` 的**查看 / 恢复 / 彻底删除**
//  （2026-09-29 回收区管理批）。
//
//  用户口径（2026-09-29）：「从回收区恢复到曲库中（可以选择单曲）；恢复后自动从排除清单
//  中除掉」「清空」；删除 = 彻底删除 + 二次确认（文案含数量与占用）。
//
//  唯一入口（本视图**不自己实现业务**）：
//   · 枚举 = `ReclaimAreaCatalog`；
//   · 恢复 = `ReclaimRestoreService`（收录 + 清排除走 `LibraryIndexer` 唯一入口）；
//   · 彻底删除 / 清空 = `ReclaimPurgeService`。
//
//  target: ios-only（macOS 侧对应 `QQPlayer/Mac/MacReclaimAreaView.swift`，共享同一套 Services）。
//

import SwiftUI

struct ReclaimAreaView: View {
    @Environment(LibraryIndexer.self) private var libraryIndexer

    @State private var entries: [ReclaimAreaEntry] = []
    @State private var selection = Set<String>()
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var resultMessage: String?
    @State private var pendingPurge: PurgeRequest?

    /// 待确认的彻底删除（二次确认后才动手）。
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
        List {
            if entries.isEmpty {
                Text("reclaim_area_empty".localized)
                    .foregroundColor(.secondary)
            } else {
                Section {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                } footer: {
                    Text(summaryText)
                        .font(.caption)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("reclaim_area".localized)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading || isWorking {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(selection.count == entries.count && !entries.isEmpty
                    ? "reclaim_deselect_all".localized
                    : "reclaim_select_all".localized) {
                        selection = selection.count == entries.count ? [] : Set(entries.map(\.id))
                    }
                    .disabled(entries.isEmpty)
            }
        }
        .confirmationDialog(
            "reclaim_purge_confirm_title".localized,
            isPresented: Binding(
                get: { pendingPurge != nil },
                set: { if !$0 { pendingPurge = nil } }
            ),
            titleVisibility: .visible
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

    private func row(_ entry: ReclaimAreaEntry) -> some View {
        HStack(spacing: DesignTokens.space12) {
            Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                .foregroundColor(selection.contains(entry.id) ? .accentColor : .secondary)

            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(entry.existingName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(for: entry))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(entry) }
        .swipeActions(edge: .leading) {
            if entry.isRestorable {
                Button {
                    restore([entry])
                } label: {
                    Label("reclaim_restore".localized, systemImage: "arrow.uturn.backward")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingPurge = .selected([entry])
            } label: {
                Label(Localized.delete, systemImage: "trash")
            }
        }
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
                Button {
                    restore(selectedEntries)
                } label: {
                    Label("reclaim_restore_selected".localized(with: selection.count), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(selection.isEmpty || isWorking)

                Button(role: .destructive) {
                    pendingPurge = .selected(selectedEntries)
                } label: {
                    Label("reclaim_delete_selected".localized(with: selection.count), systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(selection.isEmpty || isWorking)
            }
            Button(role: .destructive) {
                pendingPurge = .all(entries)
            } label: {
                Text("reclaim_purge_all".localized)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(entries.isEmpty || isWorking)
        }
        .padding(DesignTokens.space12)
        .background(.bar)
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

    private func toggle(_ entry: ReclaimAreaEntry) {
        if selection.contains(entry.id) {
            selection.remove(entry.id)
        } else {
            selection.insert(entry.id)
        }
    }

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
            resultMessage = restoreResultMessage(restored: restored, skipped: skipped, failed: failed)
            isWorking = false
            await reload()
        }
    }

    private func restoreResultMessage(restored: Int, skipped: Int, failed: Int) -> String {
        var text = "reclaim_restore_result".localized(restored, skipped)
        if failed > 0 {
            text += " · " + "reclaim_operation_failed".localized(failed)
        }
        return text
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
