//
//  MacOnlineSearchView+SearchDownload.swift
//  QQPlayer
//
//  `MacOnlineSearchView` 的搜索 / 源切换 / 下载分发与两源下载（2026-09-21 从 `MacOnlineSearchView.swift` 纯搬家，零行为/UI 变化）。
//
//  ⚠️ 可见性：被主片或其它分区文件引用的成员为 internal（原 `private`）。
//
import SwiftUI

extension MacOnlineSearchView {
    // MARK: - 搜索

    /// 分片：跨文件可见（原 private）
    func switchSource() {
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

    /// 分片：跨文件可见（原 private）
    func startSearch() {
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
                    let songs = try await services.neteaseOnlineClient.search(query: q, limit: 20)
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

    /// 显式提交才记历史（B2 修正 2026-09-08 晚）：防抖自动搜索（输入中间态停顿）
    /// 不记——否则 "馬と鹿" 的打字过程会留下 "馬" "馬と" 等中间词；只在用户
    /// 回车提交或对结果发起下载（确认这个词有用）时记录。
    /// 分片：跨文件可见（原 private）
    func recordHistory() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        history = MacSearchHistoryStore.add(keyword: q, source: source.rawValue)
    }

    // MARK: - 下载分发

    /// 分片：跨文件可见（原 private）
    func download(_ item: OnlineItem) {
        // 下载 = 对当前搜索词的强确认信号 → 补记历史（同词去重置顶、更新来源）
        recordHistory()
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
        downloadProgress[rowID] = nil // 刚开始（total 未知）→ 不确定态
        errorMessage = nil
        downloadTasks[rowID] = Task {
            do {
                _ = try await MacOnlineDownloadService.download(
                    song: song,
                    progress: { done, total in
                        // 进度回调可能在后台线程 → hop 主线程落 @State（B2）
                        let p: Double? = total > 0 ? Double(done) / Double(total) : nil
                        DispatchQueue.main.async {
                            downloadProgress[rowID] = p
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                downloadedIDs.insert(rowID)
                failedIDs.remove(rowID)
            } catch {
                guard !Task.isCancelled else { return }
                failedIDs.insert(rowID)
                downloadedIDs.remove(rowID)
                // 诊断：底层错误打日志（stdout.log 可读），并在红字里附上原因，
                // 便于区分直链服务不可用 / HTTP 拒绝 / 落盘失败等不同环节。
                AppLog.error(.ui, "❌ [在线下载] 失败《\(song.title)》id=\(song.id): \(error)")
                // errorMessage 是 String?：先拼好非可选字符串再整体赋值（不能 +=）。
                var message = "online_download_failed_prefix".localized(with: DisplayScriptNormalizer.display(song.title))
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
            downloadProgress.removeValue(forKey: rowID) // 下载结束清进度（B2）
            downloadTasks.removeValue(forKey: rowID)
        }
    }

    // MARK: 歌曲海下载（夸克直链；401 → 扫码登录，成功自动重试）

    private func downloadGequhai(_ song: GequhaiSong, isRetryAfterLogin: Bool = false) {
        let rowID = "gequhai-\(song.id)"
        guard !downloadingIDs.contains(rowID) else { return }
        downloadingIDs.insert(rowID)
        failedIDs.remove(rowID)
        downloadProgress[rowID] = nil // 刚开始（total 未知）→ 不确定态
        if !isRetryAfterLogin {
            errorMessage = nil
        }
        downloadTasks[rowID] = Task {
            do {
                // 音质读设置 quarkQuality（B2 排期；默认 mp3，web download.quarkQuality
                // 语义对齐——旧注释「固定 mp3、设置未排期」已由 B2 设置面板闭合）
                let quality = DeleteSettings.load().quarkQuality
                let info = try await gequhaiClient.downloadInfo(songID: song.id, quality: quality)
                guard let url = URL(string: info.urlString) else {
                    throw GequhaiDownloadError.quarkFailed("invalid download URL: \(info.urlString)")
                }
                _ = try await MacOnlineDownloadService.downloadDirect(
                    url: url,
                    headers: info.headers,
                    suggestedFileName: info.fileName,
                    progress: { done, total in
                        // 进度回调可能在后台线程 → hop 主线程落 @State（B2）
                        let p: Double? = total > 0 ? Double(done) / Double(total) : nil
                        DispatchQueue.main.async {
                            downloadProgress[rowID] = p
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                downloadedIDs.insert(rowID)
                failedIDs.remove(rowID)
                errorMessage = nil
                // downloadDirect 不自动刷新；落盘成功 → 通知曲库重扫收录（web watchdog 语义）
                NotificationCenter.default.post(
                    name: .libraryFolderContentChanged,
                    object: nil
                )
                AppLog.info(.ui, "✅ [歌曲海下载] 成功《\(song.title)》id=\(song.id)")
            } catch {
                guard !Task.isCancelled else { return }
                if Self.isLoginRequired(error), !isRetryAfterLogin {
                    // 401 = 夸克未登录（web 语义：非配对失效）→ 记待重试条目并弹扫码登录
                    pendingGequhaiDownload = song
                    showQuarkLogin = true
                    errorMessage = "quark_login_required_hint".localized
                    AppLog.error(.ui, "❌ [歌曲海下载] 未登录《\(song.title)》id=\(song.id) → 弹扫码登录")
                } else {
                    failedIDs.insert(rowID)
                    downloadedIDs.remove(rowID)
                    AppLog.error(.ui, "❌ [歌曲海下载] 失败《\(song.title)》id=\(song.id): \(error)")
                    // 错误文案 = web 路由 error 原文（GequhaiDownloadError.errorDescription），
                    // 真实原因红字展示（无分享/分享失效/无音频/夸克侧失败等）
                    var message = "online_download_failed_prefix".localized(with: DisplayScriptNormalizer.display(song.title))
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
            downloadProgress.removeValue(forKey: rowID) // 下载结束清进度（B2）
            downloadTasks.removeValue(forKey: rowID)
        }
    }

    /// 夸克扫码登录成功：关面板 → 提示登录成功 → 自动重试刚才被 401 拦下的下载
    /// （web onQuarkLoginSuccess 语义：不再弹框，失败直接红字）
    /// 分片：跨文件可见（原 private）
    func onQuarkLoginSuccess(nickname: String?) {
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
