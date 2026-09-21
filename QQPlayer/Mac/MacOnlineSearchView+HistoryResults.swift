//
//  MacOnlineSearchView+HistoryResults.swift
//  QQPlayer
//
//  `MacOnlineSearchView` 的搜索历史（B2）与结果列表（2026-09-21 从 `MacOnlineSearchView.swift` 纯搬家，零行为/UI 变化）。
//
//  ⚠️ 可见性：被主片或其它分区文件引用的成员为 internal（原 `private`）。
//
import SwiftUI

extension MacOnlineSearchView {
    /// 分片：跨文件可见（原 private）
    var idleView: some View {
        VStack(spacing: DesignTokens.space10) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: DesignTokens.font36))
                .foregroundColor(.secondary)
            Text("online_search_idle_hint".localized)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignTokens.space40)
        }
    }

    // MARK: - 搜索历史（B2）

    /// 历史列表（标题行「最近搜索」+ 清空按钮；行 = 图标 + keyword + 来源标签 +
    /// hover 删除；点击 = 填词 + 切源 + 立即搜索）
    /// 分片：跨文件可见（原 private）
    var historyView: some View {
        VStack(spacing: DesignTokens.space0) {
            HStack(spacing: DesignTokens.space8) {
                Text("online_search_history_title".localized)
                    .font(.callout)
                    .foregroundColor(.secondary)
                Spacer()
                Button("online_search_clear_history".localized) {
                    history = MacSearchHistoryStore.clear()
                    hoveredHistoryID = nil
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, DesignTokens.space12)
            .padding(.vertical, DesignTokens.space6)

            List {
                ForEach(history) { entry in
                    historyRow(entry)
                }
            }
            .listStyle(.inset)
        }
    }

    private func historyRow(_ entry: SearchHistoryEntry) -> some View {
        HStack(spacing: DesignTokens.space8) {
            // 左侧内容区点击 = 应用历史（与行尾删除按钮 hit 区分离，避免误触发）
            HStack(spacing: DesignTokens.space8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 12)
                Text(entry.keyword)
                    .lineLimit(1)
                Text(sourceDisplayName(entry.source))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                applyHistoryEntry(entry)
            }

            Spacer()

            if hoveredHistoryID == entry.id {
                Button {
                    deleteHistoryEntry(entry)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("online_search_history_delete_help".localized)
            }
        }
        .padding(.vertical, DesignTokens.space2)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredHistoryID = hovering ? entry.id : nil
        }
    }

    /// 历史删除（无需二次确认，低风险 UI 操作）
    private func deleteHistoryEntry(_ entry: SearchHistoryEntry) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history = MacSearchHistoryStore.remove(at: index)
        if hoveredHistoryID == entry.id {
            hoveredHistoryID = nil
        }
    }

    /// 点历史项 = 填词 + 切到该项来源 + 立即搜索（web 语义；抑制防抖避免双搜）
    private func applyHistoryEntry(_ entry: SearchHistoryEntry) {
        searchTask?.cancel()
        let target = OnlineSource(rawValue: entry.source) ?? .netease
        if query != entry.keyword {
            suppressNextQueryDebounce = true
            query = entry.keyword
        }
        if source != target {
            source = target // onChange(source) → switchSource：query 非空立即重搜
        } else {
            startSearch()
        }
    }

    /// 历史行来源标签（复用 segmented 文案：网易云/歌曲海）
    private func sourceDisplayName(_ source: String) -> String {
        source == OnlineSource.gequhai.rawValue ? "source_gequhai".localized : "source_netease".localized
    }

    /// 分片：跨文件可见（原 private）
    var resultsList: some View {
        List(results) { item in
            MacOnlineResultRow(
                item: item,
                isDownloading: downloadingIDs.contains(item.id),
                isDownloaded: downloadedIDs.contains(item.id),
                didFail: failedIDs.contains(item.id),
                progress: progressValue(for: item.id),
                onDownload: { download(item) }
            )
        }
        .listStyle(.inset)
        .overlay(alignment: .bottom) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, DesignTokens.space6)
                    .padding(.horizontal, DesignTokens.space12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, DesignTokens.space8)
            }
        }
    }

    /// 行进度取值（rowID → 0-1 或 nil=不确定；B2）
    private func progressValue(for rowID: String) -> Double? {
        downloadProgress[rowID] ?? nil
    }
}
