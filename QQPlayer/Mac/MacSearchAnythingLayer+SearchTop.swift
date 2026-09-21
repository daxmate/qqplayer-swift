//
//  MacSearchAnythingLayer+SearchTop.swift
//  QQPlayer
//
//  `MacSearchAnythingLayer` 的设置分组命中 / 空态 / 在线检索中提示 / 防抖检索与下载（2026-09-21 从 `MacSearchAnythingLayer.swift` 纯搬家，零行为/UI 变化）。
//
//  ⚠️ 可见性：被主片或其它分区文件引用的成员为 internal（原 `private`）。
//

import SwiftUI

extension MacSearchAnythingLayer {
    // MARK: - 分组 / 空态 / 在线检索中

    /// 设置分组：目录（`MacSettingsCatalog`）按 query 过滤——分类名 + 项标题 + 别名。
    /// 无匹配则整个分组不显示（原实现无条件渲染固定分类列表 = 「⌘K 只是分类快捷入口，
    /// 设置项搜不到」的根因）。
    @ViewBuilder
    /// 分片：跨文件可见（原 private）
    var settingsSection: some View {
        let matches = settingsMatches
        if !matches.isEmpty {
            section("search_badge_setting".localized) {
                ForEach(matches) { match in
                    Button {
                        onOpenSettings(match)
                        state.isOpen = false
                    } label: {
                        HStack(spacing: DesignTokens.space10) {
                            Image(systemName: match.icon)
                                .foregroundColor(.secondary)
                                .frame(width: 14)
                            Text(match.title).lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, DesignTokens.space12)
                        .padding(.vertical, DesignTokens.space4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 分组 / 空态 / 在线检索中

    /// 分片：跨文件可见（原 private）
    var emptyHint: some View {
        VStack(spacing: DesignTokens.space8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: DesignTokens.font36))
                .foregroundColor(.secondary)
            Text("search_any_empty_hint".localized)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignTokens.space64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 分组 / 空态 / 在线检索中

    /// 在线检索中的**行内**提示（复用既有 loading 文案，不新增本地化 key）
    /// 分片：跨文件可见（原 private）
    var onlineSearchingRow: some View {
        HStack(spacing: DesignTokens.space10) {
            ProgressView()
                .controlSize(.small)
            Text("search_any_loading".localized)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, DesignTokens.space12)
        .padding(.vertical, DesignTokens.space4)
    }

    // MARK: - 搜索

    /// 分片：跨文件可见（原 private）
    func scheduleSearch() {
        searchTask?.cancel()
        // 防抖窗口也算「检索中」：否则第一帧会拿旧状态判“无结果”、闪一下空态
        isSearchPending = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }

    @MainActor
    private func performSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchSeq += 1
            localSongs = []
            artists = []
            albums = []
            onlineSongs = []
            isSearchPending = false
            isOnlineSearching = false
            return
        }
        searchSeq += 1
        let seq = searchSeq
        statusMessage = nil

        // 阶段 1：本地多路（同步、快）——**先出结果**，不等在线
        #if DEBUG
            let localStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        do {
            localSongs = Array(try LibraryReads.searchTracks(query: q, limit: 8))
            artists = try LibraryReads.searchArtists(query: q, limit: 5)
            albums = try LibraryReads.searchAlbums(query: q, limit: 5)
        } catch {
            localSongs = []
            artists = []
            albums = []
        }
        #if DEBUG
            let localMs = Double(DispatchTime.now().uptimeNanoseconds - localStarted) / 1_000_000
            if AppLog.isEnabled(.debug, .ui) { AppLog.debug(.ui, String(
                format: "[SearchAnything] 本地检索 %.1fms（tracks=%d artists=%d albums=%d，防抖另计 250ms）",
                localMs, localSongs.count, artists.count, albums.count
            )) }
        #endif
        guard seq == searchSeq else { return } // 已被更新的查询取代：本地结果不落
        isSearchPending = false // 本地已就绪 → 立即渲染（不再等在线）

        // 阶段 2：在线（异步追尾，失败静默降级不打断本地结果）
        onlineSongs = []
        isOnlineSearching = true
        do {
            let songs = try await services.neteaseOnlineClient.search(query: q, limit: 20)
            guard seq == searchSeq, !Task.isCancelled else { return }
            onlineSongs = songs
        } catch {
            guard seq == searchSeq, !Task.isCancelled else { return }
        }
        if seq == searchSeq {
            isOnlineSearching = false
        }
    }

    // MARK: - 分组 / 空态 / 在线检索中

    /// 分片：跨文件可见（原 private）
    func download(_ song: NeteaseOnlineSong) {
        guard !downloadingIDs.contains(song.id) else { return }
        downloadingIDs.insert(song.id)
        failedIDs.remove(song.id)
        downloadProgress[song.id] = nil // 刚开始（total 未知）→ 不确定态
        statusMessage = nil
        Task {
            do {
                _ = try await MacOnlineDownloadService.download(
                    song: song,
                    progress: { done, total in
                        // 进度回调可能在后台线程 → hop 主线程落 @State（B2）
                        let p: Double? = total > 0 ? Double(done) / Double(total) : nil
                        DispatchQueue.main.async {
                            downloadProgress[song.id] = p
                        }
                    }
                )
                downloadedIDs.insert(song.id)
                failedIDs.remove(song.id)
            } catch {
                failedIDs.insert(song.id)
                downloadedIDs.remove(song.id)
                statusMessage = "online_download_failed_prefix".localized(with: DisplayScriptNormalizer.display(song.title))
            }
            downloadingIDs.remove(song.id)
            downloadProgress.removeValue(forKey: song.id) // 下载结束清进度（B2）
        }
    }
}
