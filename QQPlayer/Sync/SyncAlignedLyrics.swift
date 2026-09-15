//
//  SyncAlignedLyrics.swift
//  QQPlayer
//
//  局域网同步（S2, M4-2b）aligned 歌词随歌同步——**线上命名空间 + manifest 条目 + 映射**（纯逻辑，无 IO/DB）。
//
//  语义（docs/lan-sync-design.md §6.3）：
//  - 歌词是「依附歌曲的内容」：歌同步了 aligned 歌词跟着到，歌删除则歌词清理。
//  - 跨端映射只可能经 `content_hash`（本端 stableId 是绝对路径哈希，跨端必不相同）。
//
//  为什么 wire 路径用**歌曲 content_hash** 而不是本端 stableId：
//  对账键要求「同一首歌在两端得到同一个 relativePath」。用 stableId 会两端不同名
//  （→ 互相以为对方缺失：一边反复拉、一边被当成远端已删而清掉）。用歌曲内容指纹
//  则两端天然同名（内容相同 = 同一首歌）。歌词文件自身的字节哈希只用于**内容比对**
//  （放 ManifestEntry.contentHash）——对齐产物被重新生成时靠它触发重新拉取。
//
//  命名空间：`@lyrics/{歌曲 content_hash}.json`。
//  与「显式多根」相比选**前缀命名空间**的理由：
//  ① 线上仍是「一个 relativePath 对账键」——Reconciler / 拉取请求列表
//     的语义零改动（多根会让每个路径都要先判根、集合过滤也得跟着分叉）；
//  ② `@` 前缀不可能与真实曲库文件重名（音频扩展名不含 `.json`，`@` 也非法出现在
//     音乐文件名习惯里），天然区分两类内容，不存在「曲库里的文件冒充歌词」；
//  ③ 安全属性不靠命名空间本身，而靠应答端的「根表 + 逐根包含性/软链校验」——
//     `@lyrics/` 请求只会在歌词根内解析，越界与软链逃逸仍一律拒绝（见
//     SyncLibraryFetchResponder / SyncLibraryPathResolver）。
//
//  本文件只做字符串/纯值变换；盘上事实（文件哈希、DB 查询）由调用方注入闭包。
//
//  身份入口包（2026-09-15）：本文件同时声明**跨端歌曲身份解析的唯一入口**
//  `SyncIdentityResolving`（下节）。协议声明是纯类型（无 IO / 无 DB），所以放在本
//  文件不破坏「可无模拟器直编」；它的**唯一生产实现**是 `SyncContentHashResolver`
//  （`SyncChangeLogMapping.swift`，SQL 只在那里）。
//

import Foundation

// MARK: - 歌曲身份解析唯一入口（2026-09-15 形状收口）

/// 跨端歌曲身份的**唯一解析入口**：本地 `stable_id` ↔ 跨端 `content_hash` 双向。
///
/// 为什么要有这个协议：在此之前「歌曲身份解析」在生产码里有 5 处并行表达
/// （真实现 `SyncContentHashResolver` / 歌词映射闭包 / 请求应答器闭包 /
/// 曲库描述符闭包 / 曲库事实里再包一层同名 func），每处都可选、都可用「返回 nil」
/// 的缺省表达——**漏接线一处就静默失效**（先例：iOS 忘装 peer，播放数据永不通）。
/// 现在：所有生产调用点依赖本入口；闭包只允许留在**测试 seam** 一侧。
///
/// 语义（全仓库唯一口径）：
/// - 无此歌 / 指纹未回填 / 入参为空 → `nil`（绝不抛给调用方，实现内部查库失败按 nil）
/// - 同 `content_hash` 多行 → 取 id 最小 = 最早入库（两端确定性一致）
///
/// 实现约束：**生产实现只允许一个**（`QQPlayer/Sync/SyncChangeLogMapping.swift` 的
/// `SyncContentHashResolver`；契约测试 `SyncIdentityContractTests` 静态扫描禁止第二处）。
protocol SyncIdentityResolving: Sendable {
    /// 本地 stableId → content_hash（无此歌 / 指纹未回填 = nil）。
    func contentHash(forTrackStableId stableId: String) throws -> String?

    /// content_hash → 本地 stableId（无此歌 = nil）。
    func trackStableId(forContentHash contentHash: String) throws -> String?

    /// 曲库路径 → 身份（B1b，2026-09-15）：`track.path` 的键形态（**绝对路径**）
    /// → (stableId, content_hash)。相对路径 → 绝对路径的换算留在调用方（那是曲库根知识，
    /// 不属于身份解析）。
    ///
    /// 语义：**精确命中即返回**，再退标准形态；不做 `getTrack(byPath:)` 式全表回落——
    /// 同步线程（NW 队列）上不容忍 O(库) 扫描（这是既有生产约束，不得放宽）。
    func trackIdentity(atAbsolutePath path: String) throws -> (stableId: String, contentHash: String?)?

    /// 本地 stableId → **跨端身份键组**（2026-09-15 身份兜底包）：本地曲目行拿得到的
    /// 两把键——内容指纹 + 曲库相对路径。
    ///
    /// 语义：
    /// - 本地 `track` 表**没有该行** → `nil`（该行连身份都无从谈起）。
    /// - 有行 → 非 nil；指纹为空时 `contentHash` = nil、`relativePath` 尽量给出
    ///   （`track.path` 换算到曲库根；算出可用的相对路径时**不再算「缺身份键」**）。
    /// - 两把键都为 nil/空 → `isEmpty == true`（真·缺身份键，发送侧要计数披露）。
    ///
    /// ⚠️ 相对路径的换算**必须**走 `SyncManifestGenerator.relativePath(of:baseDirectory:)`
    /// （路径换算的单一事实源），不得在此手写路径切片。
    func remoteTrackIdentity(forTrackStableId stableId: String) throws -> SyncRemoteTrackIdentity?

    /// 远端身份键组 → **本端落点判定**（接收侧唯一判定点，2026-09-15 身份兜底包）。
    ///
    /// **解析顺序 = 全仓唯一口径**（任何调用方都不得另立一套）：
    /// 1. `contentHash` 非空 → **只用 content_hash**（内容身份优先）：
    ///    命中 → `.resolved(key: .contentHash)`；本地无此歌 → `.suspended`（键 = 指纹）。
    ///    ⚠️ **content_hash 存在时绝不使用相对路径**——既保持今天语义逐字不变，
    ///    也避免「同一内容两把键给出不同落点」。
    /// 2. 否则 `relativePath` 非空且**合法**（`normalizeRelativePath` 拒绝空/绝对/`..`）
    ///    → 按曲库根换算成绝对路径定位本地曲目：
    ///    - 去重后**唯一命中** → `.resolved(key: .relativePath)`
    ///    - 去重后候选 > 1 → `.ambiguous`（**不落库、不挂起**：两首同路径的本地曲目，
    ///      选哪首都是猜）
    ///    - 0 候选 → `.suspended`（键 = `rel:{relativePath}`，歌到位后重放）
    /// 3. 两把键都无（含相对路径非法） → `.unresolved`。
    func localizeRemoteTrack(_ identity: SyncRemoteTrackIdentity) throws -> SyncLocalTrackOutcome
}

// MARK: - 跨端身份键组（2026-09-15 身份兜底包）

/// 远端一行带来的**身份键组**：内容指纹（第一身份）+ 曲库相对路径（第二身份）。
///
/// 为什么需要第二身份：发送侧某行拿不到 `content_hash`（指纹未回填 / 本地无该 track 行）
/// 时，wire entry 的 `contentHash` 只能留 nil → 接收侧判「未定位」，不落库也不挂起 →
/// 用户的收藏 / 播放历史**永远过不了端**，面板只显示「未定位 N」。相对路径是两端统一的
/// 跨端键（Mac 推送文件时就是按相对路径落到 iOS 曲库），可以当第二身份。
struct SyncRemoteTrackIdentity: Equatable, Sendable {
    /// 第一身份：歌曲内容指纹（跨端同名）。
    var contentHash: String?
    /// 第二身份：曲库相对路径（跨端同名；仅第一身份缺失时才带上线）。
    var relativePath: String?

    /// 两把键都拿不到（真·缺身份键）。
    var isEmpty: Bool {
        (contentHash ?? "").isEmpty && (relativePath ?? "").isEmpty
    }

    init(contentHash: String? = nil, relativePath: String? = nil) {
        self.contentHash = contentHash
        self.relativePath = relativePath
    }
}

/// 跨端身份键的种类（面板披露与诊断要区分「靠哪把键落库的」）。
enum SyncRemoteKey: String, Equatable, Sendable {
    case contentHash = "content_hash"
    case relativePath = "relative_path"
}

/// 一条远端行在本端的落点判定（`SyncIdentityResolving.localizeRemoteTrack` 的返回值）。
enum SyncLocalTrackOutcome: Equatable, Sendable {
    /// 定位到本地曲目（`key` = 靠哪把键命中的，供诊断与测试断言）。
    case resolved(stableId: String, key: SyncRemoteKey)
    /// 本地还没有这首歌 → 挂起（`pendingKey` = 挂起表行键，命名空间见 `SyncPendingKey`）。
    case suspended(pendingKey: String)
    /// 第二身份命中**多行**（歧义）→ 不落库、不挂起，只计数披露。
    case ambiguous(key: SyncRemoteKey, candidateCount: Int)
    /// 两把键都拿不到 → 未定位（不落库、不挂起）。
    case unresolved
}

// MARK: - 挂起键命名空间（身份入口一侧，唯一构造/解析处）

/// `sync_pending_change.row_key` 的**命名空间**：挂起键的构造与解析只准出现在这里
/// （pendig store / replay / coordinator 都不许各拼一遍字符串）。
///
/// 表结构不变（`row_key` 是 TEXT，天然容纳）：
/// - 内容指纹命名空间：键 = 指纹本身（**今天形态，历史库里的行原样可读**）。
/// - 相对路径命名空间：键 = `rel:{相对路径}`。**两个命名空间不可能撞名**：指纹字形受
///   `SyncLyricsNamespace.isValidContentHash` 约束（字母/数字/`-`/`_`/`.`，**不含 `:`**），
///   所以带冒号的 `rel:` 前缀只可能是相对路径键。
enum SyncPendingKey {
    /// 相对路径命名空间前缀。
    static let relativePathPrefix = "rel:"

    /// 内容指纹键（今天形态）。
    static func contentHash(_ contentHash: String) -> String { contentHash }

    /// 相对路径键。
    static func relativePath(_ normalizedRelativePath: String) -> String {
        relativePathPrefix + normalizedRelativePath
    }

    /// 挂起键 → 身份键组（重放时重建；非法键 = nil → 调用方丢弃并计数）。
    /// 解析顺序与写入侧一致：先判相对路径前缀，其余按内容指纹。
    static func identity(fromPendingKey key: String) -> SyncRemoteTrackIdentity? {
        guard !key.isEmpty else { return nil }
        if key.hasPrefix(relativePathPrefix) {
            let raw = String(key.dropFirst(relativePathPrefix.count))
            guard let normalized = SyncManifestGenerator.normalizeRelativePath(raw) else { return nil }
            return SyncRemoteTrackIdentity(relativePath: normalized)
        }
        return SyncRemoteTrackIdentity(contentHash: key)
    }
}

// MARK: - 线上命名空间

/// aligned 歌词的 wire 路径命名空间（`@lyrics/{歌曲 content_hash}.json`）。
enum SyncLyricsNamespace {
    /// 命名空间前缀（含结尾 `/`）。
    static let prefix = "@lyrics/"
    /// 扩展名（与本地库文件形态一致）。
    static let fileExtension = "json"

    /// 是否属于歌词命名空间（先规范化，`./@lyrics/...` 也算）。
    static func isLyricsPath(_ relativePath: String) -> Bool {
        guard let normalized = SyncManifestGenerator.normalizeRelativePath(relativePath) else { return false }
        return normalized.hasPrefix(prefix)
    }

    /// 歌曲 content_hash → wire 路径（hash 非法 = nil）。
    static func wirePath(songContentHash: String) -> String? {
        guard isValidContentHash(songContentHash) else { return nil }
        return "\(prefix)\(songContentHash).\(fileExtension)"
    }

    /// wire 路径 → 歌曲 content_hash（非本命名空间 / 形态非法 = nil）。
    /// 只接受**单层**文件名：`@lyrics/a/b.json` 与 `@lyrics/../x.json` 一律 nil。
    static func songContentHash(fromWirePath relativePath: String) -> String? {
        guard let normalized = SyncManifestGenerator.normalizeRelativePath(relativePath) else { return nil }
        guard normalized.hasPrefix(prefix) else { return nil }
        let remainder = String(normalized.dropFirst(prefix.count))
        guard !remainder.isEmpty, !remainder.contains("/") else { return nil }
        let stem = (remainder as NSString).deletingPathExtension
        let ext = (remainder as NSString).pathExtension
        guard ext == fileExtension, isValidContentHash(stem) else { return nil }
        return stem
    }

    /// 歌曲 content_hash → 本地库文件名（`{stableId}.json` 的等价形态）。
    static func fileName(songContentHash: String) -> String? {
        guard isValidContentHash(songContentHash) else { return nil }
        return "\(songContentHash).\(fileExtension)"
    }

    /// content_hash 形态校验：非空、单段、无路径分隔符、非点段、限字符集。
    /// 收到的哈希来自对端，必须按不可信输入处理（绝不拿它拼路径）。
    static func isValidContentHash(_ hash: String) -> Bool {
        guard !hash.isEmpty, hash.count <= 128, hash != ".", hash != ".." else { return false }
        guard !hash.contains("/"), !hash.contains("\\") else { return false }
        return hash.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}

// MARK: - content_hash 映射

/// 本地 stableId ↔ 歌曲 content_hash 双向映射（纯值），把 `SyncIdentityResolving`
/// 的值语义化成两个闭包，供**纯逻辑**的歌词链路消费——本文件因此不依赖 GRDB，
/// 可无模拟器直编。
///
/// 生产构造只有一条路：`init(identity:)` / `.live(database:)`（唯一入口，见上）。
/// 闭包式 `init(contentHashForStableId:stableIdForContentHash:)` 是**测试 seam**
/// （内存查表），生产初始化不得用它。
struct SyncLyricsContentMapping: Sendable {
    let contentHashForStableId: @Sendable (String) -> String?
    let stableIdForContentHash: @Sendable (String) -> String?

    /// 生产构造：包住唯一身份入口（查库失败按 nil，与入口语义一致）。
    init(identity: any SyncIdentityResolving) {
        self.contentHashForStableId = { stableId in
            (try? identity.contentHash(forTrackStableId: stableId)) ?? nil
        }
        self.stableIdForContentHash = { contentHash in
            (try? identity.trackStableId(forContentHash: contentHash)) ?? nil
        }
    }

    /// ⚠️ **测试 seam**（harness / 单测注入内存查表）：生产码不得走这个初始化。
    init(
        contentHashForStableId: @escaping @Sendable (String) -> String?,
        stableIdForContentHash: @escaping @Sendable (String) -> String?
    ) {
        self.contentHashForStableId = contentHashForStableId
        self.stableIdForContentHash = stableIdForContentHash
    }

    /// 无映射（歌词同步关闭）：两端都解析不出结果 → manifest 不含歌词、收到也不落库。
    /// ⚠️ **测试 seam**：生产初始化**不得**用它当缺省（那是「漏接线即静默失效」的形状）。
    static let unresolved = SyncLyricsContentMapping(
        contentHashForStableId: { _ in nil },
        stableIdForContentHash: { _ in nil }
    )
}

// MARK: - manifest 纳入

/// aligned 歌词库 → manifest 条目（含 collection 过滤）。
enum SyncAlignedLyricsManifest {
    /// 库内全部可同步歌词 → manifest 条目。
    /// - 路径：`@lyrics/{歌曲 content_hash}.json`（歌曲指纹缺失 → 该条**跳过**：
    ///   没有跨端身份键就没法对账，宁可不同步也不写一条无法映射的路径）。
    /// - contentHash：**歌词文件自身**的 SHA-256（用于内容比对；算不出时留 nil =
    ///   「内容未知」→ Reconciler 保守判为需拉取，**不会**触发对端删除）。
    /// - stableId：本端歌曲 stableId（单端引用信息，不参与对账）。
    /// - 同 wire 路径多条（同内容重复歌曲）→ 按 stableId 升序取首个，确定性。
    static func entries(
        store: AlignedLyricsStore,
        mapping: SyncLyricsContentMapping
    ) -> [ManifestEntry] {
        var seen: Set<String> = []
        var result: [ManifestEntry] = []
        for entry in store.entries() {
            guard let songHash = mapping.contentHashForStableId(entry.stableId),
                  let wirePath = SyncLyricsNamespace.wirePath(songContentHash: songHash)
            else { continue }
            guard seen.insert(wirePath).inserted else { continue }
            result.append(
                ManifestEntry(
                    relativePath: wirePath,
                    size: entry.size,
                    mtimeMs: entry.mtimeMs,
                    contentHash: try? SyncFileChecksum.sha256Hex(ofFile: entry.fileURL),
                    stableId: entry.stableId
                )
            )
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    /// 库内全部可同步歌词 → 集合过滤后的 manifest 条目（Host 应答 manifest 用）。
    static func entries(
        store: AlignedLyricsStore,
        mapping: SyncLyricsContentMapping,
        collection: SyncCollection,
        members: SyncCollectionMembers = SyncCollectionMembers()
    ) -> [ManifestEntry] {
        collection.filter(entries(store: store, mapping: mapping), members: members)
    }
}
