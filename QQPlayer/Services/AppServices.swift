//
//  AppServices.swift
//  QQPlayer
//
//  App 级「无状态服务入口」容器（2026-09-19 立，方案 A）。
//
//  为什么存在：`WhatsNewStore` / `StateManager` / `MacFolderMonitor` 这类 App 级对象
//  **不是** `@Observable` 状态源（视图侧的站点全是方法调用），`@Environment(T.self)` 不适用；
//  而自定义 `EnvironmentKey` 的默认值必须是真实例 —— 那等于把 `.shared` 藏进环境键，
//  正是预算账本 §二.3 明令禁止的「换写法绕过棘轮」。
//
//  边界（与「有状态对象走 `@Environment(T.self)`」的分工，见
//  `QQPlayerTests/Fixtures/shared-singleton-budget-plan.md`）：
//    - **有状态**（视图读其属性、需要按属性追踪）→ 仍走 `@Environment(T.self)`（批 2/3a 已立）；
//    - **无状态 / 非 Observable 入口**（视图只调方法）→ 走本容器。
//
//  装配：组合根（iOS `QQPlayerApp` 的 `WindowGroup` 根 / Mac `QQPlayerMacApp` 的两个场景根）
//  各自 `.environment(AppServices.live)`。**视图层不得直连 `.live`**（棘轮口径与 `.shared` 同）。
//

import Foundation
import Observation

/// App 级服务入口容器（只读持有；组合根装配，视图 `@Environment(AppServices.self)` 取）。
///
/// `@Observable` 是 `@Environment(T.self)` 的**类型要求**；成员都是 `let` 常量引用，
/// 不参与按属性追踪（这些入口本身无视图可见状态，刷新语义与迁移前一致）。
/// `@MainActor` 与其余 `@Observable` store 保持一致（容器只从组合根 / 视图取用）。
@MainActor
@Observable
final class AppServices {
    /// 组合根唯一实例。视图层不得直连（与 `.shared` 同一条棘轮纪律）。
    static let live = AppServices()

    /// 「有哪些新东西」的已读记录（`UserDefaults` 支撑；调用点只读/写版本号）。
    let whatsNew = WhatsNewStore.shared
    /// 曲库目录等 App 级设置的读写入口。
    let stateManager = StateManager.shared

    // MARK: - 批 4：无状态客户端/读取器入口
    //
    // 判据仍是「视图侧是否读属性」（见账本 §批 3b 机制边界）：
    // 下面四者在视图侧全是**方法调用 / 一次性取值**，不产生按属性追踪需求，故走容器而非
    // `@Environment(T.self)`。

    /// 本机展示名读写（`name` 一次性取值 + `setName` 调用；设备名变更不是视图状态源）。
    let localDeviceName = LocalDeviceNameStore.shared
    /// 多源歌手信息聚合（视图侧只有 `searchArtist` / `searchAlternativeArtist` / `searchSimilarArtist`）。
    let hybridMusicAPI = HybridMusicAPIService.shared
    /// 歌词候选检索（视图侧只有 `search`）。
    let lyricsSearchProvider = LyricsSearchProvider.shared
    /// 网易云在线检索（视图侧只有 `search`）。
    let neteaseOnlineClient = NeteaseOnlineClient.shared

    // MARK: - 批 5：无状态歌词入口

    /// 歌词读取 / 手动指定 / 应用（`actor`；视图侧 8 处全是 `await LyricsManager.shared.<method>(…)` 调用，
    /// 不读属性 ⇒ 不产生按属性追踪需求，故走容器而非 `@Environment(T.self)`）。
    let lyricsManager = LyricsManager.shared

    // MARK: - 批 6-5：封面入口

    /// 封面加载 / 缓存（视图侧 23 处全是 `await ArtworkManager.shared.<method>(…)` 调用，
    /// **读属性 0 处、订阅 0 处**（本体 `@Published` 也是 0 个）⇒ 判据命中「无状态入口」，
    /// 故走容器而非 `@Environment(ArtworkManager.self)`（与批 4/5 同款）。
    let artworkManager = ArtworkManager.shared

    #if os(macOS)
        /// 曲库文件夹监视（Mac 专属；`start(paths:)` / `stop()` 由曲库加载路径驱动）。
        let folderMonitor = MacFolderMonitor.shared
    #endif

    private init() {}
}
