//
//  MacOnlineSearchView.swift
//  QQPlayer
//
//  在线搜索 + 下载面板（网易云 / 歌曲海两源，web 版 OnlineSearch.vue 对齐，
//  2026-09 C 组① + E2 批2b；QQPlayerMac target only）。
//  用户 2026-09-04 拍板 v1 形态：在线行动作 = 下载落盘入曲库（默认曲库目录 320k，
//  完成自动收录）；试听/网络登记延后评估。
//  语义：400ms 防抖 + 过期响应丢弃（web OnlineSearch 对齐）；行点击/按钮均触发
//  下载（per-row busy 防重）；成功行变 ✓，失败行红叹号 + 底部错误行。
//
//  源切换（web OnlineSearch.vue src-seg 对齐）：顶部 segmented 网易云（默认，
//  行为与既有完全一致）/ 歌曲海。歌曲海搜索走 GequhaiClient（失败返回 [] 不抛，
//  web 语义）；下载 = GequhaiClient.downloadInfo(quality:"mp3") → 夸克签名直链 →
//  MacOnlineDownloadService.downloadDirect（.part 原子落盘，完成 post
//  LibraryFolderContentChanged 刷新曲库）。401/未登录 → 弹 MacQuarkLoginView
//  扫码登录，登录成功自动重试刚才的下载（web OnlineSearch.vue 401 → QuarkLoginModal
//  → 成功重试 语义对齐）。
//

import SwiftUI

/// 在线搜索面板（sheet 形态，参照 MacLyricsSearchView 异步搜索页写法）
struct MacOnlineSearchView: View {
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor
    @Environment(\.dismiss) private var dismiss

    @State private var source: OnlineSource = .netease
    @State private var query = ""
    @State private var results: [OnlineItem] = []
    @State private var status: Status = .idle
    @State private var searchTask: Task<Void, Never>?
    @State private var searchSeq = 0
    @State private var downloadingIDs: Set<String> = []
    @State private var downloadedIDs: Set<String> = []
    @State private var failedIDs: Set<String> = []
    @State private var errorMessage: String?
    @State private var showQuarkLogin = false
    @State private var pendingGequhaiDownload: GequhaiSong?
    /// 歌曲海客户端（qurark 直链走同一实例；登录 cookie 归文件管，登录面板换
    /// 实例后下载自动带上新 cookie）
    @State private var gequhaiClient = GequhaiClient()

    private enum Status {
        case idle
        case loading
        case loaded
        case failed
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            sourcePicker
                .padding(.horizontal, 16)
                .padding(.top, 8)

            searchField
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 480)
        .onChange(of: source) { _ in
            switchSource()
        }
        .sheet(isPresented: $showQuarkLogin, onDismiss: {
            // 用户未登录成功就关掉面板 → 丢弃待重试条目（web close 语义；
            // 行回到空闲状态，可再次点击重新触发）
            pendingGequhaiDownload = nil
        }) {
            MacQuarkLoginView { nickname in
                onQuarkLoginSuccess(nickname: nickname)
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "globe")
                .foregroundColor(appAccentColor)
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

    // MARK: - 源切换（web OnlineSearch src-seg 对齐）

    private var sourcePicker: some View {
        Picker("", selection: $source) {
            Text("source_netease".localized).tag(OnlineSource.netease)
            Text("source_gequhai".localized).tag(OnlineSource.gequhai)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
        .help("online_search_source_hint".localized)
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
                Button("online_search_retry".localized) {
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
        List(results) { item in
            MacOnlineResultRow(
                item: item,
                isDownloading: downloadingIDs.contains(item.id),
                isDownloaded: downloadedIDs.contains(item.id),
                didFail: failedIDs.contains(item.id),
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
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - 搜索

    private func switchSource() {
        // 切源（web switchSource）：作废在途请求，保留输入；query 非空立即重搜
        // （切源不防抖——web 同语义）
        searchSeq += 1
        searchTask?.cancel()
        errorMessage = nil
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            results = []
            status = .idle
        } else {
            results = []
            status = .loading
            startSearch()
        }
    }

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
            switch source {
            case .netease:
                do {
                    let songs = try await NeteaseOnlineClient.shared.search(query: q, limit: 20)
                    guard !Task.isCancelled, seq == searchSeq else { return } // 过期响应丢弃
                    results = songs.map { OnlineItem.netease($0) }
                    status = .loaded
                } catch {
                    guard !Task.isCancelled, seq == searchSeq else { return }
                    status = .failed
                    errorMessage = error.localizedDescription
                }
            case .gequhai:
                // 歌曲海 search 不抛（web 语义：网络/解析失败返回 []）；空结果走 no-results
                let songs = await gequhaiClient.search(query: q, limit: 20)
                guard !Task.isCancelled, seq == searchSeq else { return }
                results = songs.map { OnlineItem.gequhai($0) }
                status = .loaded
            }
        }
    }

    // MARK: - 下载分发

    private func download(_ item: OnlineItem) {
        switch item {
        case .netease(let song):
            downloadNetease(song)
        case .gequhai(let song):
            downloadGequhai(song)
        }
    }

    // MARK: 网易云下载（既有行为，逐字保留：行 busy 防重 / ✓ / 红字 + 底部错误行）

    private func downloadNetease(_ song: NeteaseOnlineSong) {
        let rowID = "netease-\(song.id)"
        guard !downloadingIDs.contains(rowID) else { return }
        downloadingIDs.insert(rowID)
        failedIDs.remove(rowID)
        errorMessage = nil
        Task {
            do {
                _ = try await MacOnlineDownloadService.download(song: song)
                guard !Task.isCancelled else { return }
                downloadedIDs.insert(rowID)
                failedIDs.remove(rowID)
            } catch {
                guard !Task.isCancelled else { return }
                failedIDs.insert(rowID)
                downloadedIDs.remove(rowID)
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
            downloadingIDs.remove(rowID)
        }
    }

    // MARK: 歌曲海下载（夸克直链；401 → 扫码登录，成功自动重试）

    private func downloadGequhai(_ song: GequhaiSong, isRetryAfterLogin: Bool = false) {
        let rowID = "gequhai-\(song.id)"
        guard !downloadingIDs.contains(rowID) else { return }
        downloadingIDs.insert(rowID)
        failedIDs.remove(rowID)
        if !isRetryAfterLogin {
            errorMessage = nil
        }
        Task {
            do {
                // 音质固定 "mp3"（web download.quarkQuality 默认 mp3；Mac 侧设置项
                // 未排期，先按默认值——见批内汇报）
                let info = try await gequhaiClient.downloadInfo(songID: song.id, quality: "mp3")
                guard let url = URL(string: info.urlString) else {
                    throw GequhaiDownloadError.quarkFailed("invalid download URL: \(info.urlString)")
                }
                _ = try await MacOnlineDownloadService.downloadDirect(
                    url: url,
                    headers: info.headers,
                    suggestedFileName: info.fileName
                )
                guard !Task.isCancelled else { return }
                downloadedIDs.insert(rowID)
                failedIDs.remove(rowID)
                errorMessage = nil
                // downloadDirect 不自动刷新；落盘成功 → 通知曲库重扫收录（web watchdog 语义）
                NotificationCenter.default.post(
                    name: NSNotification.Name("LibraryFolderContentChanged"),
                    object: nil
                )
                print("✅ [歌曲海下载] 成功《\(song.title)》id=\(song.id)")
            } catch {
                guard !Task.isCancelled else { return }
                if Self.isLoginRequired(error), !isRetryAfterLogin {
                    // 401 = 夸克未登录（web 语义：非配对失效）→ 记待重试条目并弹扫码登录
                    pendingGequhaiDownload = song
                    showQuarkLogin = true
                    errorMessage = "quark_login_required_hint".localized
                    print("❌ [歌曲海下载] 未登录《\(song.title)》id=\(song.id) → 弹扫码登录")
                } else {
                    failedIDs.insert(rowID)
                    downloadedIDs.remove(rowID)
                    print("❌ [歌曲海下载] 失败《\(song.title)》id=\(song.id): \(error)")
                    // 错误文案 = web 路由 error 原文（GequhaiDownloadError.errorDescription），
                    // 真实原因红字展示（无分享/分享失效/无音频/夸克侧失败等）
                    var message = "online_download_failed_prefix".localized(with: song.title)
                    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    if !reason.isEmpty {
                        message += "（\(reason)）"
                    }
                    if Self.isLoginRequired(error) {
                        // 登录成功后的重试仍 401（极端：cookie 又失效）→ 附登录引导，
                        // 但不再弹面板（避免死循环；用户再点行会重新触发）
                        message += "\n" + "quark_login_required_hint".localized
                    }
                    errorMessage = message
                }
            }
            downloadingIDs.remove(rowID)
        }
    }

    /// 夸克扫码登录成功：关面板 → 提示登录成功 → 自动重试刚才被 401 拦下的下载
    /// （web onQuarkLoginSuccess 语义：不再弹框，失败直接红字）
    private func onQuarkLoginSuccess(nickname: String?) {
        showQuarkLogin = false
        guard let song = pendingGequhaiDownload else { return }
        pendingGequhaiDownload = nil
        if let nickname, !nickname.isEmpty {
            errorMessage = "quark_login_success".localized(with: nickname)
                + "\n" + "quark_login_retrying".localized
        } else {
            errorMessage = "quark_login_retrying".localized
        }
        downloadGequhai(song, isRetryAfterLogin: true)
    }

    /// 登录态错误判定（downloadInfo 已把 QuarkClientError.loginRequired/401 折成
    /// GequhaiDownloadError.quarkLoginRequired；双查兜底不重弹）
    private static func isLoginRequired(_ error: Error) -> Bool {
        if let ge = error as? GequhaiDownloadError, ge == .quarkLoginRequired {
            return true
        }
        if let qe = error as? QuarkClientError, qe == .loginRequired {
            return true
        }
        return false
    }
}

// MARK: - 源 / 结果统一模型

/// 在线源（web OnlineSearch source 对齐：netease 默认 | gequhai）
private enum OnlineSource: String, CaseIterable, Identifiable {
    case netease
    case gequhai

    var id: String { rawValue }
}

/// 统一结果条目（两源共用行/下载状态骨架；id 带源前缀防跨源冲突）
private enum OnlineItem: Identifiable {
    case netease(NeteaseOnlineSong)
    case gequhai(GequhaiSong)

    var id: String {
        switch self {
        case .netease(let song): return "netease-\(song.id)"
        case .gequhai(let song): return "gequhai-\(song.id)"
        }
    }

    var title: String {
        switch self {
        case .netease(let song): return song.title
        case .gequhai(let song): return song.title
        }
    }

    var subtitle: String {
        var parts: [String] = []
        switch self {
        case .netease(let song):
            parts.append(song.artist)
            if let album = song.album, !album.isEmpty {
                parts.append(album)
            }
            if let duration = song.durationDisplay {
                parts.append(duration)
            }
        case .gequhai(let song):
            // 歌曲海行副信息只有歌手（web 显示对齐）；缺失段跳过
            parts.append(song.artist)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var coverURL: URL? {
        switch self {
        case .netease(let song): return song.coverURL
        case .gequhai: return nil
        }
    }
}

// MARK: - 结果行

private struct MacOnlineResultRow: View {
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor
    let item: OnlineItem
    let isDownloading: Bool
    let isDownloaded: Bool
    let didFail: Bool
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            cover

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                Text(item.subtitle)
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
            if let coverURL = item.coverURL {
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

    private var iconName: String {
        if isDownloaded { return "checkmark.circle.fill" }
        if didFail { return "exclamationmark.circle.fill" }
        if isDownloading { return "arrow.down.circle" }
        return "icloud.and.arrow.down"
    }

    private var iconColor: Color {
        if isDownloaded { return .green }
        if didFail { return .red }
        if isDownloading { return appAccentColor }
        return .secondary
    }

    private var helpText: String {
        if isDownloaded { return "online_downloaded".localized }
        if didFail { return "online_download_failed".localized }
        if isDownloading { return "online_downloading".localized }
        return "online_download".localized
    }
}
