//
//  MacOnlineSearchView.swift
//  QQPlayer
//
//  网易云在线搜索 + 下载面板（web 版 OnlineSearch/SearchAnything 在线组对齐，
//  2026-09 C 组①；QQPlayerMac target only）。
//  用户 2026-09-04 拍板 v1 形态：在线行动作 = 下载落盘入曲库（默认曲库目录 320k，
//  完成自动收录）；试听/网络登记延后评估。
//  语义：400ms 防抖 + 过期响应丢弃（web OnlineSearch 对齐）；行点击/按钮均触发
//  下载（per-row busy 防重）；成功行变 ✓，失败行红叹号 + 底部错误行。
//

import SwiftUI

/// 在线搜索面板（sheet 形态，参照 MacLyricsSearchView 异步搜索页写法）
struct MacOnlineSearchView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [NeteaseOnlineSong] = []
    @State private var status: Status = .idle
    @State private var searchTask: Task<Void, Never>?
    @State private var searchSeq = 0
    @State private var downloadingIDs: Set<Int> = []
    @State private var downloadedIDs: Set<Int> = []
    @State private var failedIDs: Set<Int> = []
    @State private var errorMessage: String?

    private enum Status {
        case idle
        case loading
        case loaded
        case failed
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            searchField
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 480)
        .onDisappear {
            searchTask?.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "globe")
                .foregroundColor(.accentColor)
            Text("online_search_title".localized)
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - 搜索框

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("online_search_placeholder".localized, text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { startSearch() }
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    status = .idle
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: query) { _ in
            // 400ms 防抖（web OnlineSearch 对齐）
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                startSearch()
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch status {
        case .idle:
            idleView
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("online_search_loading".localized)
                    .foregroundColor(.secondary)
            }
        case .failed:
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 30))
                    .foregroundColor(.secondary)
                Text(errorMessage ?? "online_search_failed".localized)
                    .font(.callout)
                    .foregroundColor(.secondary)
                Button("common_retry".localized) {
                    startSearch()
                }
            }
        case .loaded:
            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text("online_search_no_results".localized)
                        .foregroundColor(.secondary)
                }
            } else {
                resultsList
            }
        }
    }

    private var idleView: some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("online_search_idle_hint".localized)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var resultsList: some View {
        List(results) { song in
            MacOnlineResultRow(
                song: song,
                isDownloading: downloadingIDs.contains(song.id),
                isDownloaded: downloadedIDs.contains(song.id),
                didFail: failedIDs.contains(song.id),
                onDownload: { download(song) }
            )
        }
        .listStyle(.inset)
        .overlay(alignment: .bottom) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - 搜索 / 下载

    private func startSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchSeq += 1
            results = []
            status = .idle
            return
        }
        searchTask?.cancel()
        status = .loading
        errorMessage = nil
        searchSeq += 1
        let seq = searchSeq
        searchTask = Task {
            do {
                let songs = try await NeteaseOnlineClient.shared.search(query: q, limit: 20)
                guard !Task.isCancelled, seq == searchSeq else { return } // 过期响应丢弃
                results = songs
                status = .loaded
            } catch {
                guard !Task.isCancelled, seq == searchSeq else { return }
                status = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    private func download(_ song: NeteaseOnlineSong) {
        guard !downloadingIDs.contains(song.id) else { return }
        downloadingIDs.insert(song.id)
        failedIDs.remove(song.id)
        errorMessage = nil
        Task {
            do {
                _ = try await MacOnlineDownloadService.download(song: song)
                guard !Task.isCancelled else { return }
                downloadedIDs.insert(song.id)
                failedIDs.remove(song.id)
            } catch {
                guard !Task.isCancelled else { return }
                failedIDs.insert(song.id)
                downloadedIDs.remove(song.id)
                // 诊断：底层错误打日志（stdout.log 可读），并在红字里附上原因，
                // 便于区分直链服务不可用 / HTTP 拒绝 / 落盘失败等不同环节。
                print("❌ [在线下载] 失败《\(song.title)》id=\(song.id): \(error)")
                // errorMessage 是 String?：先拼好非可选字符串再整体赋值（不能 +=）。
                var message = "online_download_failed_prefix".localized(with: song.title)
                // noPlayURL 高频原因：VIP/版权受限歌曲 → 直链代理(200 空响应)与
                // cenguigui 兜底都取不到 URL。给用户可理解的提示而非裸错误码。
                if let ne = error as? NeteaseOnlineError, case .noPlayURL = ne {
                    message += "（该歌曲暂无可用下载源，可能是会员/VIP或版权受限）"
                } else {
                    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    if !reason.isEmpty {
                        message += "（\(reason)）"
                    }
                }
                errorMessage = message
            }
            downloadingIDs.remove(song.id)
        }
    }
}

// MARK: - 结果行

private struct MacOnlineResultRow: View {
    let song: NeteaseOnlineSong
    let isDownloading: Bool
    let isDownloaded: Bool
    let didFail: Bool
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            cover

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onDownload) {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .disabled(isDownloading)
            .help(helpText)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDownload)
    }

    private var cover: some View {
        Group {
            if let coverURL = song.coverURL {
                AsyncImage(url: coverURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.gray.opacity(0.18))
            .overlay {
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
    }

    private var subtitle: String {
        var parts: [String] = [song.artist]
        if let album = song.album, !album.isEmpty {
            parts.append(album)
        }
        if let duration = song.durationDisplay {
            parts.append(duration)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var iconName: String {
        if isDownloaded { return "checkmark.circle.fill" }
        if didFail { return "exclamationmark.circle.fill" }
        if isDownloading { return "arrow.down.circle" }
        return "icloud.and.arrow.down"
    }

    private var iconColor: Color {
        if isDownloaded { return .green }
        if didFail { return .red }
        if isDownloading { return .accentColor }
        return .secondary
    }

    private var helpText: String {
        if isDownloaded { return "online_downloaded".localized }
        if didFail { return "online_download_failed".localized }
        if isDownloading { return "online_downloading".localized }
        return "online_download".localized
    }
}
