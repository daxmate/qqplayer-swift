//
//  SyncUIDirectionContent.swift
//  QQPlayer
//
//  T10（2026-09-12）同步界面**方向优先**内容源的决策纯逻辑（平台无关，可单测）。
//
//  背景（用户 2026-09-12 反馈）：M6 的同步页内容面板恒读**本端** DB——选「从 iPhone
//  下载」看到的却是 Mac 的歌单/曲库，方向与内容错配。T10 把方向提成面板第一屏，
//  内容面板随方向切换数据源：
//  - 上传 → **本端**（Mac）DB（`MacSyncLocalContentProvider`）；
//  - 下载 → **对端**（iPhone）内容清单（`SyncPeerLibraryClient`，帧 15/16）。
//
//  为什么单独一个文件：`SyncUIState.swift` 已 500+ 行（文件规模纪律「逻辑 ≤ 500 行」），
//  本文件与它同层同性质（纯值 + 纯函数、零 IO、零 SwiftUI、零 DB），继续被
//  QQPlayerTests 真跑。判定一律走这里，View / ViewModel 不自己发明规则。
//
//  ⚠️ 与 `SyncUIState.swift` 同一纪律：**本文件不产生任何用户可见文案**——只返回
//  enum case 或 i18n key 字符串，真正的本地化在 Mac 侧 View 做。
//

import Foundation

// MARK: - 内容面板常量（单一事实源；`nonisolated` 才能同时被 MainActor 与
// 非隔离上下文——如提供者的静态默认值——安全引用）

/// 内容面板的取数常量（本端分页 / 对端分页 / 搜索去抖）。
enum SyncUIContentLimits {
    /// 本端单曲级每页条数（懒加载；量大不分页会卡主线程）。
    static let trackPageSize = 100
    /// 本端单曲搜索结果上限（走 DB ranked search，不再分页）。
    static let trackSearchLimit = 200
    /// 对端单曲级每页条数（协议上限 500，这里取 100 = 一屏多一点）。
    static let peerPageSize = 100
    /// 搜索去抖时长（View 侧计时；本地/对端两条路共用）。
    static let searchDebounceNanoseconds: UInt64 = 300_000_000
}

// MARK: - 内容源（方向 → 数据源）

/// 内容面板的数据源（由同步方向唯一决定）。
enum SyncUIContentSource: Equatable, Sendable {
    /// 方向未选（内容区只显示引导，**不显示任何一端的内容**——修复方向与内容错配）
    case none
    /// 本端（Mac）曲库与歌单（上传方向的来源）
    case local
    /// 对端（iPhone）内容清单（下载方向的来源）
    case peer
}

/// 方向 → 内容源（纯函数；唯一映射）。
enum SyncUIContentSourceResolver {
    static func source(for direction: SyncTransferDirection?) -> SyncUIContentSource {
        switch direction {
        case .none: return .none
        case .some(.upload): return .local
        case .some(.download): return .peer
        }
    }

    /// 是否需要联网取对端内容（下载方向）。
    static func requiresPeer(for direction: SyncTransferDirection?) -> Bool {
        source(for: direction) == .peer
    }
}

// MARK: - 异步加载状态（对端清单）

/// 对端清单加载错误（把 `SyncPeerLibraryClient.ClientError` 归一成可测、可本地化的值）。
enum SyncUIPeerContentError: Equatable, Sendable {
    /// 还没有连接（无活跃会话）→ 提示先连接 iPhone
    case notConnected
    /// 会话存在但未就绪（重建中 / 已关闭）
    case sessionNotReady
    /// 对端在超时内没回（对端未接线 / 网络卡住）
    case timeout
    /// 本端主动取消（切方向 / 切歌单 / 关面板）——不是错误，不弹错误态
    case cancelled
    /// 会话已关闭（在途请求立即失败）
    case sessionClosed
    /// 帧发送失败（带诊断串）
    case sendFailed(String)
    /// 其它（解码失败等）
    case other

    /// 从任意错误归一（客户端错误按 case 映射；其余一律 other）。
    static func from(_ error: Error) -> SyncUIPeerContentError {
        guard let clientError = error as? SyncPeerLibraryClient.ClientError else { return .other }
        switch clientError {
        case .sessionNotReady: return .sessionNotReady
        case .timeout: return .timeout
        case .cancelled: return .cancelled
        case .sessionClosed: return .sessionClosed
        case let .sendFailed(detail): return .sendFailed(detail)
        }
    }

    /// 是否用户可见的失败（取消 = 用户行为，不当失败展示）。
    var isUserVisibleFailure: Bool {
        if case .cancelled = self { return false }
        return true
    }

    /// 错误 → i18n key（文案在 Mac 侧 View 落地）。
    var messageKey: String {
        switch self {
        case .notConnected: return "sync_peer_error_not_connected"
        case .sessionNotReady, .sessionClosed: return "sync_peer_error_session"
        case .timeout: return "sync_peer_error_timeout"
        case .cancelled: return "sync_peer_error_cancelled"
        case .sendFailed, .other: return "sync_peer_error_other"
        }
    }
}

/// 对端内容的一次加载状态（歌单清单 / 摘要各自持有一份）。
enum SyncUIContentLoadState: Equatable, Sendable {
    /// 未开始（方向未选 / 未连接 / 切走后）
    case idle
    /// 加载中（UI 显示进度）
    case loading
    /// 已加载（结果在 ViewModel 的选项属性里）
    case loaded
    /// 失败（UI 显示原因 + 重试入口）
    case failed(SyncUIPeerContentError)

    /// 是否加载中。
    var isLoading: Bool { self == .loading }

    /// 失败原因（非失败态 = nil）。
    var failure: SyncUIPeerContentError? {
        if case let .failed(error) = self { return error }
        return nil
    }

    /// 是否需要用户可见的失败提示（取消不算）。
    var isVisibleFailure: Bool { failure?.isUserVisibleFailure == true }
}

// MARK: - 对端清单 → 选择区行模型（纯函数）

/// 对端（iPhone）内容清单 → 选择区行模型。
enum SyncUIPeerContentMapper {
    /// 对端歌单 → 选择区选项。
    /// - 「收藏」伪歌单（`id == "@favorites"`）**置顶**，且用**本端语言**显示
    ///   （对端回传的名字是它自己语言的，本端覆盖）；
    /// - 其余保持对端顺序（对端已按 name 升序归一，这里不去重排）；
    /// - 非法标识丢弃（不可信输入：被编辑过的对端数据），空名回落标识本身。
    static func playlistOptions(
        from items: [SyncPeerPlaylistItem],
        favoritesTitle: String
    ) -> [SyncUIPlaylistOption] {
        var seen: Set<String> = []
        var favorites: [SyncUIPlaylistOption] = []
        var others: [SyncUIPlaylistOption] = []
        for item in items {
            guard SyncCollectionSelection.isValidPlaylistID(item.id) else { continue }
            guard seen.insert(item.id).inserted else { continue }
            if item.id == SyncCollectionSelection.favoritesPlaylistID {
                favorites.append(
                    SyncUIPlaylistOption(
                        id: item.id,
                        title: favoritesTitle,
                        trackCount: max(0, item.trackCount)
                    )
                )
                continue
            }
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            others.append(
                SyncUIPlaylistOption(
                    id: item.id,
                    title: name.isEmpty ? item.id : name,
                    trackCount: max(0, item.trackCount)
                )
            )
        }
        return favorites + others
    }

    /// 对端曲目 → 单曲选项（大小 0 = 未知 → nil，与本地侧口径一致）。
    static func trackOption(from item: SyncPeerTrackItem) -> SyncUITrackOption {
        let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (item.artistName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return SyncUITrackOption(
            relativePath: item.relativePath,
            title: title.isEmpty ? fallbackTitle(for: item.relativePath) : title,
            artistName: artist.isEmpty ? nil : artist,
            fileSize: item.sizeBytes > 0 ? item.sizeBytes : nil
        )
    }

    /// 兜底标题：相对路径最后一段去掉扩展名（对端没回标题时也不显示空白行）。
    static func fallbackTitle(for relativePath: String) -> String {
        let last = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        let stripped = URL(fileURLWithPath: last).deletingPathExtension().lastPathComponent
        return stripped.isEmpty ? last : stripped
    }

    /// 一页响应 → 单曲选项（保持页内序）。
    static func trackOptions(from response: SyncPeerLibraryResponsePayload) -> [SyncUITrackOption] {
        response.trackItems.map(trackOption(from:))
    }
}

// MARK: - 分页拼接（纯函数）

/// 清单分页拼接（懒加载追加；去重按对账键 `relativePath`，保序）。
enum SyncUIContentPager {
    /// 拼接一页：`reset` = 替换（新搜索 / 新歌单），否则追加。
    static func merge(
        existing: [SyncUITrackOption],
        page: [SyncUITrackOption],
        reset: Bool
    ) -> [SyncUITrackOption] {
        guard !reset else { return dedupe(page) }
        return dedupe(existing + page)
    }

    /// 按 `relativePath` 去重（先到者优先；对端分页/重复页不会出现两行同一首歌）。
    static func dedupe(_ options: [SyncUITrackOption]) -> [SyncUITrackOption] {
        var seen: Set<String> = []
        return options.filter { seen.insert($0.relativePath).inserted }
    }

    /// 下一页起点（= 当前已加载条数；对端按 offset/limit 分页，故必须用**实际条数**）。
    static func nextOffset(loadedCount: Int) -> Int {
        max(0, loadedCount)
    }
}

// MARK: - 搜索去抖状态机（纯逻辑部分）

/// 搜索框的「待生效 / 已生效」查询状态机。
///
/// 去抖等待本身由 View 的 `Task.sleep` 承担（时间不可测，不进单测）；本类型只管
/// **语义**（可测的那一半）：
/// - 归一（去首尾空白 + 截断到协议上限——与 `SyncPeerLibraryRequestPayload` 同源，
///   不另起一套长度上限）；
/// - 归一后与已生效不同才算「有新输入」→ 调用方据此重启去抖计时；
/// - 提交（去抖到期）→ 需要从第一页重新加载。
struct SyncUISearchGate: Equatable, Sendable {
    /// 搜索词长度上限（与协议侧同一约束，避免本端过滤与对端钳制不一致）。
    static let maxQueryLength = SyncPeerLibraryRequestPayload.maxQueryLength

    /// 已生效的查询（当前列表/请求用的那个）。
    private(set) var appliedQuery: String = ""
    /// 待生效的查询（输入框最新值，等去抖到期才提交）。
    private(set) var pendingQuery: String = ""

    init(appliedQuery: String = "") {
        self.appliedQuery = appliedQuery
        self.pendingQuery = appliedQuery
    }

    /// 归一（唯一入口：本端与协议侧同一口径）。
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxQueryLength))
    }

    /// 输入变化：返回 true = 需要（重新）启动去抖计时。
    mutating func stage(_ raw: String) -> Bool {
        let normalized = Self.normalize(raw)
        pendingQuery = normalized
        return normalized != appliedQuery
    }

    /// 去抖到期提交：返回 true = 查询真的变了 → 调用方从第一页重新加载。
    mutating func commit() -> Bool {
        guard pendingQuery != appliedQuery else { return false }
        appliedQuery = pendingQuery
        return true
    }

    /// 立即生效（切方向 / 切歌单：清空搜索且不走去抖）。
    mutating func reset() {
        appliedQuery = ""
        pendingQuery = ""
    }
}

// MARK: - 对端摘要文案数值（纯逻辑）

/// 对端摘要（「iPhone 曲库 · N 首 · 约 X GB」）的**数**（文案在 View 组装）。
struct SyncUIPeerSummaryFacts: Equatable, Sendable {
    /// 曲目数
    var trackCount: Int
    /// 总字节（未知按 0）
    var totalBytes: Int64

    static let empty = SyncUIPeerSummaryFacts(trackCount: 0, totalBytes: 0)

    init(trackCount: Int, totalBytes: Int64) {
        self.trackCount = max(0, trackCount)
        self.totalBytes = max(0, totalBytes)
    }

    /// 从客户端摘要取值。
    init(trackCount: Int, sizeBytes: Int64) {
        self.init(trackCount: trackCount, totalBytes: sizeBytes)
    }

    /// 人类可读大小（复用既有格式化，不另起一套）。
    var sizeText: String { SyncUISizeText.humanReadable(bytes: totalBytes) }

    /// 选择集摘要用的全库事实口径。
    var libraryFacts: SyncUILibraryFacts {
        SyncUILibraryFacts(trackCount: trackCount, totalBytes: totalBytes)
    }
}
