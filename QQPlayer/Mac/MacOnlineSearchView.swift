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
//  web 语义）；下载 = GequhaiClient.downloadInfo(quality: settings.quarkQuality) →
//  夸克签名直链 → MacOnlineDownloadService.downloadDirect（.part 原子落盘，完成 post
//  LibraryFolderContentChanged 刷新曲库）。401/未登录 → 弹 MacQuarkLoginView
//  扫码登录，登录成功自动重试刚才的下载（web OnlineSearch.vue 401 → QuarkLoginModal
//  → 成功重试 语义对齐）。
//
//  B2 批（2026-09）：搜索历史（网易云/歌曲海合并列表，UserDefaults，上限 10；点历史项
//  = 填词 + 切源 + 立即搜索）+ 下载进度圆环（行尾 downloading → DownloadProgressRing，
//  网易云/歌曲海统一；进度回调后台线程 → 主线程落 @State，下载结束清 rowID）。
//

import SwiftUI

/// 在线搜索面板（sheet 形态，参照 MacLyricsSearchView 异步搜索页写法）
struct MacOnlineSearchView: View {
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor
    @Environment(\.dismiss) private var dismiss
    /// 分片：跨文件可见（原 private）
    @Environment(AppServices.self) var services

    /// 分片：跨文件可见（原 private）
    @State var source: OnlineSource = .netease
    /// 分片：跨文件可见（原 private）
    @State var query = ""
    /// 分片：跨文件可见（原 private）
    @State var results: [OnlineItem] = []
    /// 分片：跨文件可见（原 private）
    @State var status: Status = .idle
    /// 分片：跨文件可见（原 private）
    @State var searchTask: Task<Void, Never>?
    /// 行级下载任务句柄（rowID → Task；关 sheet 后在途下载不得写已卸载视图的 @State）
    /// 分片：跨文件可见（原 private）
    @State var downloadTasks: [String: Task<Void, Never>] = [:]
    /// 分片：跨文件可见（原 private）
    @State var searchSeq = 0
    /// 分片：跨文件可见（原 private）
    @State var downloadingIDs: Set<String> = []
    /// 分片：跨文件可见（原 private）
    @State var downloadedIDs: Set<String> = []
    /// 分片：跨文件可见（原 private）
    @State var failedIDs: Set<String> = []
    /// 分片：跨文件可见（原 private）
    @State var errorMessage: String?
    /// 分片：跨文件可见（原 private）
    @State var showQuarkLogin = false
    /// 分片：跨文件可见（原 private）
    @State var pendingGequhaiDownload: GequhaiSong?
    /// 歌曲海客户端（qurark 直链走同一实例；登录 cookie 归文件管，登录面板换
    /// 实例后下载自动带上新 cookie）
    /// 分片：跨文件可见（原 private）
    @State var gequhaiClient = GequhaiClient()
    /// 搜索历史（B2：网易云/歌曲海合并列表；UserDefaults 上限 10，store 见 MacSearchHistoryStore）
    /// 分片：跨文件可见（原 private）
    @State var history: [SearchHistoryEntry] = MacSearchHistoryStore.load()
    /// 历史行 hover 高亮 id（删除按钮显隐）
    /// 分片：跨文件可见（原 private）
    @State var hoveredHistoryID: String?
    /// 行下载进度（rowID → 0-1 确定 / nil 不确定；下载结束清 rowID，B2）
    /// 分片：跨文件可见（原 private）
    @State var downloadProgress: [String: Double?] = [:]
    /// 历史项点击填词后抑制下一次 query 防抖（避免重复搜索）
    /// 分片：跨文件可见（原 private）
    @State var suppressNextQueryDebounce = false

    /// 分片：跨文件可见（原 private）
    enum Status {
        case idle
        case loading
        case loaded
        case failed
    }

    var body: some View {
        VStack(spacing: DesignTokens.space0) {
            header

            sourcePicker
                .padding(.horizontal, DesignTokens.space16)
                .padding(.top, DesignTokens.space8)

            searchField
                .padding(.horizontal, DesignTokens.space16)
                .padding(.vertical, DesignTokens.space10)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 480)
        .onChange(of: source) { _, _ in
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
            // 审计 L5：sheet 关闭 → 取消所有在途下载（下载服务自行管理落盘，
            // 取消只停止状态回调，不会损坏已下载内容）
            for task in downloadTasks.values {
                task.cancel()
            }
            downloadTasks.removeAll()
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
        .padding(.horizontal, DesignTokens.space16)
        .padding(.top, DesignTokens.space16)
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
        HStack(spacing: DesignTokens.space6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("online_search_placeholder".localized, text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    startSearch()
                    recordHistory()
                }
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
        .onChange(of: query) { _, _ in
            // 历史项点击已立即搜索（suppress 消费一次，见 applyHistory）
            guard !suppressNextQueryDebounce else {
                suppressNextQueryDebounce = false
                return
            }
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
            // B2：历史非空 → 最近搜索列表；空 → 既有 idle 提示
            if history.isEmpty {
                idleView
            } else {
                historyView
            }
        case .loading:
            VStack(spacing: DesignTokens.space10) {
                ProgressView()
                Text("online_search_loading".localized)
                    .foregroundColor(.secondary)
            }
        case .failed:
            VStack(spacing: DesignTokens.space8) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: DesignTokens.font30))
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
                VStack(spacing: DesignTokens.space8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: DesignTokens.font30))
                        .foregroundColor(.secondary)
                    Text("online_search_no_results".localized)
                        .foregroundColor(.secondary)
                }
            } else {
                resultsList
            }
        }
    }
}
