//
//  SyncBrowseSource.swift
//  QQPlayer
//
//  S2 同步页「内容来源」（浏览来源）模型 —— **纯逻辑，零 IO**（不读 DB、不发帧、
//  不产生用户可见文案）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  背景（用户 2026-09-13 反馈）
//  ════════════════════════════════════════════════════════════════════════════
//  同步页的内容选择区只有三级：全曲库 / 歌单 / 单曲。单曲级只有「搜索框 + 全库
//  分页逐首勾选」——用户抱怨「要一首一首搜索」；而播放列表页已有的自动歌单
//  （最近添加 / 最近播放 / 常听排行）在同步页完全没有。本文件把「来源」提成
//  一等概念：**单曲 tab 可先选来源（下拉），再在来源内搜索/分页**；歌单 tab 的
//  行也可以下钻到该来源的单曲列表。
//
//  ════════════════════════════════════════════════════════════════════════════
//  标识命名空间（**保留标识，不得擅自改**）
//  ════════════════════════════════════════════════════════════════════════════
//  - `@library`     = 全部曲库（**仅本端 UI 合成项**；发帧 15 时 playlistID = nil）
//  - `@favorites`   = 收藏（既有保留标识，`SyncCollectionSelection.favoritesPlaylistID`）
//  - 真实歌单        = slug（既有；字母/数字/连字符，不以 `@` 开头）
//  - `@smart:*`     = 自动歌单（`@smart:recentAdded` / `@smart:recentPlayed` /
//                     `@smart:topPlayed`；本期三个，年代留待后续）
//
//  未知 / 非法标识 → **nil（解析失败）**，绝不回落成「全部曲库」或某个真实歌单
//  （沿用 `SyncCollectionSelection.isValidPlaylistID` 的语义：选不出内容比误给全库安全）。
//  帧 15/16 的载荷结构、帧号一律不变（本文件只是 ID 命名空间的扩展）。
//
//  为什么单独一个文件：`SyncUIState.swift` 已 500+ 行（文件规模纪律「逻辑 ≤ 500 行」），
//  且本文件与它同性质（纯值 + 纯函数、零 IO、零 SwiftUI），放 `Sync/` 才能被 iOS
//  target 与 QQPlayerTests 真跑覆盖（`QQPlayer/Mac/**` 被 iOS target 排除）。
//

import Foundation

// MARK: - 来源种类

/// 内容来源的种类（「怎么解释 id」的唯一判据）。
enum SyncBrowseSourceKind: String, Equatable, Sendable {
    /// 全部曲库（本端合成项；**不**出现在帧 15/16 的 playlistID 里）
    case library
    /// 收藏（保留标识 `@favorites`）
    case favorites
    /// 真实歌单（id = slug）
    case playlist
    /// 自动歌单（保留标识 `@smart:*`）
    case smart
}

/// 自动歌单种类（本期三个；与 `SmartPlaylistStore` 的查询一一对应）。
enum SyncBrowseSmartKind: String, CaseIterable, Equatable, Sendable {
    /// 最近添加（`modification_date` 降序）
    case recentAdded
    /// 最近播放（按最新播放时间倒序，同一曲目只留最新一条）
    case recentPlayed
    /// 常听排行（播放次数降序，并列按累计时长）
    case topPlayed

    /// 保留标识（`@smart:` + rawValue）。
    var wireID: String { SyncBrowseSourceRef.smartPrefix + rawValue }
}

// MARK: - 来源引用（标识的**唯一**解释点）

/// 一个内容来源引用（本端 UI 与对端请求共用同一标识空间）。
struct SyncBrowseSourceRef: Equatable, Hashable, Sendable {
    let kind: SyncBrowseSourceKind
    let id: String

    /// 「全部曲库」保留标识（本端合成项；发帧 15 时 playlistID = nil）。
    static let libraryID = "@library"
    /// 自动歌单保留前缀。
    static let smartPrefix = "@smart:"
    /// `@` 前缀 = 保留命名空间（**不得**被解释成真实歌单 slug）。
    static let reservedPrefix = "@"

    /// 全部曲库。
    static let library = SyncBrowseSourceRef(kind: .library, id: libraryID)
    /// 收藏。
    static let favorites = SyncBrowseSourceRef(
        kind: .favorites,
        id: SyncCollectionSelection.favoritesPlaylistID
    )

    /// 只有工厂 / `parse(id:)` 能构造：保证 `kind` 与 `id` 永远自洽
    /// （否则 `peerPlaylistID` / `smartKind` 可能给出互相矛盾的答案）。
    private init(kind: SyncBrowseSourceKind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// 自动歌单。
    static func smart(_ kind: SyncBrowseSmartKind) -> SyncBrowseSourceRef {
        SyncBrowseSourceRef(kind: .smart, id: kind.wireID)
    }

    /// 真实歌单（slug）；非法标识（空 / 超长 / 点段 / 含路径分隔符 / 含控制字符 /
    /// 以 `@` 开头）→ nil（**不做「顺手修正」**）。
    static func playlist(_ slug: String) -> SyncBrowseSourceRef? {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SyncCollectionSelection.isValidPlaylistID(trimmed),
              !trimmed.hasPrefix(reservedPrefix)
        else {
            return nil
        }
        return SyncBrowseSourceRef(kind: .playlist, id: trimmed)
    }

    /// 标识 → 来源引用（**唯一解释入口**）。
    ///
    /// - `@library` → `.library`
    /// - `@favorites` → `.favorites`
    /// - `@smart:<known>` → `.smart`；`@smart:` 后不是已知种类 → **nil**
    /// - 其余 `@` 开头 → **nil**（未知保留命名空间，绝不回落）
    /// - 不带前缀的合法串 → `.playlist`
    /// - 非法串（空 / 超长 / 点段 / 路径分隔符 / 控制字符）→ nil
    ///
    /// 校验口径与 `SyncCollectionSelection.isValidPlaylistID` /
    /// `maxPlaylistIDLength` **同一份**（不另起一套长度上限）。
    static func parse(id: String) -> SyncBrowseSourceRef? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SyncCollectionSelection.isValidPlaylistID(trimmed) else { return nil }
        if trimmed == libraryID { return .library }
        if trimmed == SyncCollectionSelection.favoritesPlaylistID { return .favorites }
        if trimmed.hasPrefix(smartPrefix) {
            let raw = String(trimmed.dropFirst(smartPrefix.count))
            guard let kind = SyncBrowseSmartKind(rawValue: raw) else { return nil }
            return .smart(kind)
        }
        guard !trimmed.hasPrefix(reservedPrefix) else { return nil }
        return SyncBrowseSourceRef(kind: .playlist, id: trimmed)
    }

    // MARK: 派生

    /// 发帧 15 时要带的对端歌单标识（**全部曲库 = nil**，即既有「不过滤」语义）。
    var peerPlaylistID: String? {
        kind == .library ? nil : id
    }

    /// 自动歌单种类（非 `.smart` → nil）。
    var smartKind: SyncBrowseSmartKind? {
        guard kind == .smart, id.hasPrefix(Self.smartPrefix) else { return nil }
        return SyncBrowseSmartKind(rawValue: String(id.dropFirst(Self.smartPrefix.count)))
    }

    /// 是否「全部曲库」来源。
    var isLibraryWide: Bool { kind == .library }
}

// MARK: - 来源行模型

/// 一个来源选项（单曲 tab 的来源下拉 / 歌单 tab 的下钻入口各一行）。
struct SyncBrowseSourceOption: Identifiable, Equatable, Sendable {
    /// 来源引用（标识事实源）
    var ref: SyncBrowseSourceRef
    /// 展示名（**已本地化**的保留标识文案，或对端歌单名；空 → 回落标识本身）
    var title: String
    /// 曲目数（负数归零）
    var trackCount: Int
    /// 文件大小合计（nil = 未知，例如对端清单不回大小；负数归零）
    var totalBytes: Int64?

    /// 行标识 = 来源标识（列表 ForEach 用）。
    var id: String { ref.id }

    init(ref: SyncBrowseSourceRef, title: String, trackCount: Int, totalBytes: Int64? = nil) {
        self.ref = ref
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? ref.id : trimmed
        self.trackCount = max(0, trackCount)
        self.totalBytes = totalBytes.map { max(0, $0) }
    }

    /// 是否「全部曲库」来源（高容量风险，沿用既有二次确认）。
    var isLibraryWide: Bool { ref.isLibraryWide }

    /// 是否自动歌单来源。
    var isSmart: Bool { ref.kind == .smart }
}

/// 保留标识的来源标题（**已本地化**；由调用方装配——本文件不产生用户可见文案）。
/// 真实歌单的标题来自歌单自身 → `title(for:)` 返回 nil，调用方用歌单名。
struct SyncBrowseSourceTitles: Equatable, Sendable {
    /// 「全部曲库」标题
    var library: String
    /// 「收藏」标题
    var favorites: String
    /// 自动歌单标题（缺项 → nil，调用方回落对端名 / 标识）
    var smart: [SyncBrowseSmartKind: String]

    static let empty = SyncBrowseSourceTitles(library: "", favorites: "", smart: [:])

    /// 保留标识 → 标题；真实歌单（或自动歌单缺项）→ nil。
    func title(for ref: SyncBrowseSourceRef) -> String? {
        switch ref.kind {
        case .library: return library
        case .favorites: return favorites
        case .smart: return ref.smartKind.flatMap { smart[$0] }
        case .playlist: return nil
        }
    }
}

// MARK: - 展示序（唯一事实源）

/// 来源选项的展示序与去重（View / ViewModel 不自己发明排序规则）。
enum SyncBrowseSourceCatalog {
    /// 展示序权重：全部曲库(0) < 收藏(1) < 自动歌单(2，按 `SyncBrowseSmartKind.allCases` 序)
    /// < 真实歌单(3，标识升序)。同权重按第三项（标识）升序 → 全序确定。
    static func rank(_ ref: SyncBrowseSourceRef) -> (Int, Int, String) {
        switch ref.kind {
        case .library:
            return (0, 0, ref.id)
        case .favorites:
            return (1, 0, ref.id)
        case .smart:
            let index = ref.smartKind
                .flatMap { SyncBrowseSmartKind.allCases.firstIndex(of: $0) } ?? 0
            return (2, index, ref.id)
        case .playlist:
            return (3, 0, ref.id)
        }
    }

    /// 归一：同标识去重（先到者优先）+ 按展示序排序（确定性）。
    static func ordered(_ options: [SyncBrowseSourceOption]) -> [SyncBrowseSourceOption] {
        var seen: Set<String> = []
        let unique = options.filter { seen.insert($0.ref.id).inserted }
        return unique.sorted { rank($0.ref) < rank($1.ref) }
    }
}

// MARK: - 来源内搜索（与对端清单同口径）

/// 来源内搜索命中判定（**纯函数**）。
///
/// 口径与 `SyncPeerLibraryCatalog.matches` 一致：标题 / 歌手 / 相对路径三者任一
/// `contains`（大小写不敏感）；空查询 = 全部命中。两端同一口径，用户切方向时
/// 「搜同一个词」得到同一批歌。
///
/// 这里只接受**三个字段**（不接受行模型类型）：本文件因此零依赖，可以被无模拟器
/// harness 一起编译真跑（行模型是 `Services/SyncUIState.swift` 的事）。
enum SyncBrowseSourceSearch {
    static func matches(
        title: String?,
        artistName: String?,
        relativePath: String,
        query: String
    ) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        if relativePath.lowercased().contains(needle) { return true }
        if let title, title.lowercased().contains(needle) { return true }
        if let artistName, artistName.lowercased().contains(needle) { return true }
        return false
    }
}

// MARK: - 内存分页（来源内分页的纯函数）

/// 来源内分页切片（与对端 `offset` / `limit` 同语义；越界 = 空页，不崩）。
enum SyncBrowseSourcePager {
    /// 取一页：返回 `(本页, 后面还有页)`。
    static func slice<T>(_ items: [T], offset: Int, pageSize: Int) -> (items: [T], hasMore: Bool) {
        guard pageSize > 0 else { return ([], false) }
        let start = min(max(0, offset), items.count)
        let end = min(start + pageSize, items.count)
        let page = start < end ? Array(items[start ..< end]) : []
        return (page, end < items.count)
    }
}

// MARK: - 与播放列表页的展示种类对齐（图标复用）

extension SyncBrowseSmartKind {
    /// 播放列表页卡片同款的展示种类：同步页的自动歌单行与播放列表页用**同一套**
    /// 图标决策（`MacSmartPlaylistUILogic.iconName(for:)` / iOS 同名逻辑），
    /// 避免同一个「最近添加」在两处长得不一样。
    var smartPlaylistKind: SmartPlaylistKind {
        switch self {
        case .recentAdded: return .recentAdded
        case .recentPlayed: return .recentPlayed
        case .topPlayed: return .topPlayed
        }
    }
}
