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
//  ① 线上仍是「一个 relativePath 对账键」——Reconciler / deleteScope / 拉取请求列表
//     的语义零改动（多根会让每个路径都要先判根、集合过滤与删除范围也得跟着分叉）；
//  ② `@` 前缀不可能与真实曲库文件重名（音频扩展名不含 `.json`，`@` 也非法出现在
//     音乐文件名习惯里），天然区分两类内容，不存在「曲库里的文件冒充歌词」；
//  ③ 安全属性不靠命名空间本身，而靠应答端的「根表 + 逐根包含性/软链校验」——
//     `@lyrics/` 请求只会在歌词根内解析，越界与软链逃逸仍一律拒绝（见
//     SyncLibraryFetchResponder / SyncLibraryPathResolver）。
//
//  本文件只做字符串/纯值变换；盘上事实（文件哈希、DB 查询）由调用方注入闭包。
//

import Foundation

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

// MARK: - content_hash 映射（调用方注入）

/// 本地 stableId ↔ 歌曲 content_hash 双向映射（纯值 + 闭包）。
/// 生产实现走 M4-2a 的 `SyncContentHashResolver`（见 `SyncLyricsContentMapping.live(database:)`），
/// 测试/harness 注入内存查表——本文件因此不依赖 GRDB，可无模拟器直编。
struct SyncLyricsContentMapping: Sendable {
    var contentHashForStableId: @Sendable (String) -> String?
    var stableIdForContentHash: @Sendable (String) -> String?

    init(
        contentHashForStableId: @escaping @Sendable (String) -> String?,
        stableIdForContentHash: @escaping @Sendable (String) -> String?
    ) {
        self.contentHashForStableId = contentHashForStableId
        self.stableIdForContentHash = stableIdForContentHash
    }

    /// 无映射（歌词同步关闭）：两端都解析不出结果 → manifest 不含歌词、收到也不落库。
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
