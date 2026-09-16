//
//  AppNotifications.swift
//  QQPlayer
//
//  全 App 通知名的**唯一入口**（2026-09-16 事件层收口）：
//  其它文件只能引用下面的 `.xxx` 常量，不得再写 `Notification.Name("…")` 字面量
//  （形状契约：QQPlayerTests/AppNotificationContractTests.swift）。
//
//  ⚠️ 字符串值必须与历史字面量**逐字相同**：它与跨进程/跨端语义绑定，
//  「改名 = 断链」。新增通知请加在这里，并同时在契约测试的常量清单里登记。
//

import Foundation

extension Notification.Name {
    /// 曲库/列表需要刷新（扫描落库、标签保存、刮削、批量操作后由写入点广播；
    /// 视图侧 .onReceive 收到后重载列表）。
    static let libraryNeedsRefresh = Notification.Name("LibraryNeedsRefresh")

    /// 歌单增删改后广播（Mac 导入 / 歌单详情面板 / 拖拽写入点）→ 侧栏与列表重拉歌单。
    static let playlistsChanged = Notification.Name("PlaylistsChanged")

    /// 背景色设置改变（设置页写入）→ 各背景视图与桌面小组件主题重读。
    static let backgroundColorChanged = Notification.Name("BackgroundColorChanged")

    /// 曲库文件夹内容变化（导入落盘 / 在线下载完成 / 刮削落库）→ 触发重扫收录。
    static let libraryFolderContentChanged = Notification.Name("LibraryFolderContentChanged")

    /// 收藏（喜欢）变化 → 各列表重拉收藏。
    static let favoritesChanged = Notification.Name("FavoritesChanged")

    /// 当前曲目封面被重写（刮削保存 forceRefreshArtwork）后广播：
    /// stableId 不变，视图必须显式重拉封面。
    static let qqplayerArtworkRefreshed = Notification.Name("QQPlayerArtworkRefreshed")

    /// 播放页点歌手名 → 跳转到该歌手详情（userInfo 携带跳转参数）。
    static let navigateToArtistFromPlayer = Notification.Name("NavigateToArtistFromPlayer")

    /// 播放页点专辑名 → 跳转到该专辑详情（userInfo 携带跳转参数）。
    static let navigateToAlbumFromPlayer = Notification.Name("NavigateToAlbumFromPlayer")

    /// 收起播放页（全屏播放 → 返回列表）。
    static let minimizePlayer = Notification.Name("MinimizePlayer")

    /// CarPlay 场景断开 → 主场景刷新布局：iOS 26 在 CarPlay 断开后可能不刷新主窗口
    /// safe area，导致 safeAreaInset 内容（迷你播放条）残留在错误位置。
    static let carPlaySceneDidDisconnect = Notification.Name("CarPlaySceneDidDisconnect")

    /// 跳转到指定歌单（App 入口发布）。
    static let navigateToPlaylist = Notification.Name("NavigateToPlaylist")

    /// 扫描过程中发现新曲目（增量进度提示）。
    static let trackFound = Notification.Name("TrackFound")

    /// 打开设置窗口并定位到指定分类（search anything 入口）。
    static let macSettingsOpenCategory = Notification.Name("MacSettingsOpenCategory")

    /// 曲库文件夹增删（设置页写入）→ 触发重扫。
    static let libraryFoldersChanged = Notification.Name("LibraryFoldersChanged")

    /// Posted only when QQPlayer UI settings change. Playback persistence also
    /// writes to UserDefaults, so views must not observe the broad
    /// UserDefaults.didChangeNotification or every state save rebuilds the
    /// library hierarchy while audio is playing.
    static let qqplayerSettingsDidChange = Notification.Name("QQPlayerSettingsDidChange")

    /// 曲库扫描条件变化（文件类型设置改动等）→ 需重扫曲库。与
    /// LibraryFoldersChanged 分开：语义不同（文件夹增删 vs 收录条件变化），
    /// 但消费方动作相同（reload + start，扫描中则排队）。
    static let libraryScanCriteriaChanged = Notification.Name("LibraryScanCriteriaChanged")

    /// 文件拖入导入完成（B 组）：userInfo["count"] = 成功导入数。
    /// MacLibraryView 监听后弹瞬时提示（对齐 web 版 toast 语义）。
    static let libraryImportFinished = Notification.Name("LibraryImportFinished")

    /// 同步中心设备列表变化（审计 M4）：SyncHostCenter 的单槽回调不再直接捕获 View 值，
    /// 改为转发这个热点通知，由视图侧（.onReceive）自己重载。
    static let macSyncDevicesChanged = Notification.Name("MacSyncDevicesChanged")
}
