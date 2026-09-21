//
//  MacLibraryView+Sidebar.swift
//  QQPlayer
//
//  `MacLibraryView` 的侧栏分区（2026-09-21 从 `MacLibraryView.swift` 纯搬家，零行为/UI 变化）：
//  `MacLibrarySection` 侧栏分区模型 + 侧栏列表本体（分区选择、侧栏搜索框、曲库卡统计行）。
//
//  ⚠️ 可见性：被 `body` 或其它分区文件引用的成员为 internal（原 `private`）。
//
import SwiftUI

enum MacLibrarySection: String, CaseIterable, Identifiable {
    case tracks = "songs"
    case likedSongs = "liked_songs"
    case albums = "albums"
    case artists = "artists"
    case playlists = "playlists"

    var id: String { rawValue }

    /// Localized sidebar title (rawValue is a localization key).
    var title: String { rawValue.localized }

    var icon: String {
        switch self {
        case .tracks: return "music.note.list"
        case .likedSongs: return "heart.fill"
        case .albums: return "square.stack"
        case .artists: return "music.mic"
        case .playlists: return "list.bullet.rectangle"
        }
    }
}

extension MacLibraryView {
    // MARK: - Sidebar

    /// 分片：跨文件可见（原 private）
    var sidebar: some View {
        VStack(spacing: DesignTokens.space0) {
            MacSearchField(text: $searchText)
            List(MacLibrarySection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: DesignTokens.space6) {
                if indexer.isIndexing {
                    ProgressView(value: indexer.indexingProgress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                    Text(String(format: "indexing_progress".localized, indexer.tracksFound))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Button {
                        // 手动刷新语义收紧（2026-09-03 复查 A4 反馈）：先立即用 DB
                        // 真值重载列表，再排队/启动扫描。之前只 start()——扫描被占用
                        // 或启动被吞时列表不重读 DB，用户观感"点刷新没反应"；若曲库
                        // 数据已被其它路径改掉（删除/回收站/iCloud），点一下立刻对齐。
                        reloadLibrary()
                        // 2026-09-02 A4 修复：dataless 自动补扫在跑时 start() 会被
                        // guard !isIndexing 静默吞掉 → 手动刷新"没反应"。改为排队：
                        // 扫描结束后由 onReceive(isIndexing) 补一次重扫
                        if indexer.isIndexing {
                            MacScanLogger.log("手动刷新时正在扫描，标记排队（rescanWhenIdle）")
                            rescanWhenIdle = true
                        } else {
                            indexer.start()
                        }
                    } label: {
                        Label("refresh_library".localized, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(DesignTokens.space8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
