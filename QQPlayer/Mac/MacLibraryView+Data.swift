//
//  MacLibraryView+Data.swift
//  QQPlayer
//
//  `MacLibraryView` 的数据与外观（2026-09-21 从 `MacLibraryView.swift` 纯搬家，零行为/UI 变化）：
//  窗口级拖入导入（未被行消费的文件 → `MacImportService`）、曲库/喜欢曲目重载与失败绑定、
//  曲库文件夹 FSEvents 实时监控补扫、外观三态循环（主题图标 + 应用外观）与当前歌手名解析。
//
//  ⚠️ 可见性：被 `body` 或其它分区文件引用的成员为 internal（原 `private`）。
//
import SwiftUI

extension MacLibraryView {
    /// 解析拖入的 fileURL providers → 导入曲库。窗口级兜底：
    /// 拖到歌单行时行级 drop（MacPlaylistListView 行）先于本窗口级命中，
    /// 此处只处理未被行消费的文件。
    /// 分片：跨文件可见（原 private）
    func handleDroppedFiles(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.loadFileURL() {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            let result = await MacImportService.importFiles(urls)
            if result.importedCount == 0, result.skippedCount > 0 {
                // 全部被跳过（格式不支持/非文件 URL）：告知跳过数，而非笼统「未导入」
                showImportToast(Localized.dragImportSkipped(count: result.skippedCount))
            } else if result.importedCount == 0 {
                showImportToast(Localized.dragImportNone)
            }
        }
    }

    // MARK: - Data

    /// 曲库加载：四表全量读在全局执行器上跑（审计 M2——以前同步跑在主线程、且由 7+ 处通知反复触发）。
    /// 拿到快照后先预取卡片事实再落表，卡片渲染时计数已就位（不闪 0）。
    /// 分片：跨文件可见（原 private）
    func reloadLibrary() {
        libraryLoadTask?.cancel()
        // 曲库数据可能已变：作废在途事实（旧值保留到预取完，不闪 0）
        libraryFacts.invalidate()
        libraryLoadTask = Task { @MainActor in
            let loaded = await MacLibraryLoader.load()
            guard !Task.isCancelled else { return }
            switch loaded {
            case .success(let snapshot):
                await libraryFacts.preload(
                    tracks: snapshot.tracks,
                    albums: snapshot.albums,
                    artists: snapshot.artists,
                    playlists: snapshot.playlists
                )
                guard !Task.isCancelled else { return }
                tracks = snapshot.tracks
                albums = snapshot.albums
                artists = snapshot.artists
                playlists = snapshot.playlists
                loadError = nil
            case .failure(let error):
                loadError = "load_library_failed".localized(with: error.localizedDescription)
                AppLog.error(.ui, "❌ macOS reloadLibrary failed: \(error)")
            }
            reloadLikedTracks()
        }
    }

    /// 加载失败弹窗开关（审计 M6）
    /// 分片：跨文件可见（原 private）
    var libraryLoadErrorBinding: Binding<Bool> {
        Binding(
            get: { loadError != nil },
            set: { if !$0 { loadError = nil } }
        )
    }

    /// 分片：跨文件可见（原 private）
    func reloadLikedTracks() {
        do {
            let favoriteIds = try appCoordinator.getFavorites()
            likedTracks = tracks.filter { favoriteIds.contains($0.stableId) }
        } catch {
            AppLog.error(.ui, "❌ macOS reloadLikedTracks failed: \(error)")
        }
    }

    // MARK: - FSEvents 实时监控（web 版 watchdog 对齐，2026-09-03 B 组）

    /// 启动/重启曲库文件夹实时监控。监控根 = 当前配置文件夹集合
    /// （默认 ~/Music/QQPlayer + 设置页添加的外部文件夹，StateManager 归一）。
    /// 分片：跨文件可见（原 private）
    func startFolderMonitoring() {
        let folders = services.stateManager.getMusicFolderURLs()
        let paths = MacFolderWatchPolicy.relevantFolders(folders).map(\.path)
        MacScanLogger.log("FSEvents watch start, folders: \(paths)")
        services.folderMonitor.start(paths: paths) {
            // 已在主线程（MacFolderMonitor 去抖后 main 投递）。经通知转发，
            // 与 LibraryFoldersChanged 共用「reload + start/排队」语义，避免
            // 此处重复实现扫描中排队逻辑。
            NotificationCenter.default.post(name: .libraryFolderContentChanged, object: nil)
        }
    }

    /// 工具栏月亮按钮：三态循环 system → dark → light → system。
    /// 分片：跨文件可见（原 private）
    func cycleTheme() {
        let next: AppearanceTheme
        switch theme {
        case .system: next = .dark
        case .dark: next = .light
        case .light: next = .system
        }
        theme = next
        var settings = DeleteSettings.load()
        settings.appearanceTheme = next.rawValue
        settings.forceDarkMode = next == .dark
        settings.save()
    }

    /// 分片：跨文件可见（原 private）
    var themeIconName: String {
        switch theme {
        case .system: return "circle.lefthalf.filled"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        }
    }

    /// 全局外观：NSApp.appearance 控制所有窗口（主窗/设置窗/sheet）立即生效，
    /// system = nil 跟随系统立即恢复。不用 .preferredColorScheme（只作用于
    /// 挂载视图，且从 .dark 切回 nil 时系统不重新解析——2026-09-02 用户实测）。
    /// 分片：跨文件可见（原 private）
    func applyMacAppearance() {
        MacAppearance.apply(theme: theme)
    }

    /// 分片：跨文件可见（原 private）
    func resolveArtistName(for track: Track) -> String? {
        try? LibraryReads.artistDisplayName(
            forTrackStableId: track.stableId,
            fallbackArtistId: track.artistId
        )
    }

    /// 分片：跨文件可见（原 private）
    var currentArtistName: String? {
        guard let track = player.currentTrack else { return nil }
        return resolveArtistName(for: track)
    }
}
