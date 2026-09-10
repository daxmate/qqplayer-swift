//
//  SyncLibrarySyncModels.swift
//  QQPlayer
//
//  局域网同步（S2, M3-3b）文件同步「按路径拉取」协议载荷 + 路径解析纯逻辑（无 IO）。
//
//  语义（docs/lan-sync-design.md §5 原语 manifestFetch / §6.1 文件同步）：
//  manifest 只告诉两端「谁有什么」，真正的字节搬运走 M2b 已有停等传输
//  （SyncFileSender / SyncFileReceiver）。本文件定义把二者接起来的请求/结果帧：
//
//    12 sync_fetch_request  { collection, relativePaths }   请求方点名要哪些文件
//    13 sync_fetch_result   { completed, failed }           应答方逐个推送后的结论
//
//  为什么不用「manifest 里全部 toFetch 一次性下发」：请求列表是**显式点名**的——
//  应答方只认列表里的路径，且每条路径都要过一遍曲库根越界校验（见下），
//  协议上不存在「给我整个目录」这种指令，天然收窄了越权读取面。
//
//  路径口径与 SyncManifestGenerator 完全一致（对账键的单一事实源）：
//  normalizeRelativePath 拒空 / 拒绝对路径 / 拒 `..` 逃逸 / 去 `./` 前缀。
//
//  安全（§6.1 硬要求，本文件是执行点之一）：
//  - 请求载荷**原样保留**调用方给的字符串（不做静默修正），好让应答方能把
//    非法路径如实计入 failed（静默丢弃 = 请求方永远等不到这些文件，无法诊断）。
//  - SyncLibraryPathResolver.resolve 只做"纯路径数学"：规范化 + 曲库根包含性判定，
//    不碰文件系统。存在性/常规文件判定由调用方补齐（有 IO，可单测注入）。
//

import Foundation

// MARK: - 失败原因（线上字符串常量）

/// sync_fetch_result.failed 的 reason 取值（跨端字符串契约，勿随意改）。
/// 用常量而非枚举：线上只需"人能读的一句话"，新原因可加不可改。
enum SyncFetchFailureReason {
    /// 路径非法（空 / 绝对路径 / 含 `..` 逃逸 / 规范化后为空）
    static let invalidPath = "invalid_path"
    /// 规范化后仍落在曲库根之外（防御性：normalize 已挡大部分，仍再校验一次）
    static let outOfRoot = "out_of_root"
    /// 曲库根内不存在该文件
    static let notFound = "not_found"
    /// 存在但不是常规文件（目录 / 设备文件 / 符号链接目标不是常规文件）
    static let notRegularFile = "not_regular_file"
    /// 传输失败（发送端 SyncFileSender 终态，附错误摘要）
    static let sendFailed = "send_failed"
    /// 会话在推送过程中关闭
    static let sessionClosed = "session_closed"
    /// 本端主动取消
    static let cancelled = "cancelled"
}

// MARK: - 线载荷

/// sync_fetch_request 帧载荷：请求对端推送指定集合下的指定文件。
struct SyncFetchRequest: Codable, Equatable, Sendable {
    /// 集合（与 manifest 请求同一语义；应答方用它做二次集合过滤，防止越集合读取）。
    var collection: SyncCollection
    /// 请求的文件相对路径（相对**对端曲库根**，POSIX "/"）。
    /// 原样透传：应答方逐条校验，非法路径计入 failed（不做静默修正/丢弃）。
    var relativePaths: [String]

    init(collection: SyncCollection = .all, relativePaths: [String]) {
        self.collection = collection
        self.relativePaths = relativePaths
    }

    /// 规范化请求列表（去非法 / 去重 / 升序）。发起方构造请求时用，保证线上载荷
    /// 干净且确定性；应答方仍须自行校验（不信任对端）。
    static func normalize(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for path in raw {
            guard let normalized = SyncManifestGenerator.normalizeRelativePath(path) else { continue }
            guard seen.insert(normalized).inserted else { continue }
            out.append(normalized)
        }
        return out.sorted()
    }
}

/// 一条拉取失败记录（relativePath 为请求方原始字符串，便于对端定位）。
struct SyncFileFetchFailure: Codable, Equatable, Sendable {
    var relativePath: String
    var reason: String
}

/// sync_fetch_result 帧载荷：应答方逐个推送后的结论。
struct SyncFetchResult: Codable, Equatable, Sendable {
    /// 已成功送达（且接收端 SHA-256 校验通过）的**规范化**相对路径。
    var completed: [String]
    /// 失败记录（原因见 SyncFetchFailureReason）。
    var failed: [SyncFileFetchFailure]

    /// 构造时排序去重（线上确定性：同一批文件的结论字节稳定，便于比对与日志）。
    init(completed: [String], failed: [SyncFileFetchFailure]) {
        self.completed = Array(Set(completed)).sorted()
        self.failed = failed
            .sorted { ($0.relativePath, $0.reason) < ($1.relativePath, $1.reason) }
    }

    /// 全部成功（无失败记录）。
    var isFullSuccess: Bool { failed.isEmpty }
}

/// 拉取载荷 JSON 编解码（风格对齐 SyncManifestCodec：帧 payload = 载荷类型 JSON 字节）。
enum SyncFetchCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - 路径解析（纯逻辑，无 IO）

// MARK: - 根表（M4-2b：曲库根 + 歌词根）

/// 应答端可服务的根集合（纯值）：
/// - `libraryRoot`：曲库根（对账键基准，原有语义不变）
/// - `lyricsRoot`：aligned 歌词根（nil = 本端不服务歌词命名空间）
///
/// wire 路径仍是**单一命名空间**：`@lyrics/...` 归歌词根，其余归曲库根
/// （理由见 SyncAlignedLyrics.swift 头部）。安全属性 = 每个根各自做
/// 包含性 + 软链校验，与单根时同样严——命名空间本身不放松任何检查。
struct SyncFetchRoots: Equatable, Sendable {
    var libraryRoot: URL
    var lyricsRoot: URL?

    init(libraryRoot: URL, lyricsRoot: URL? = nil) {
        self.libraryRoot = libraryRoot
        self.lyricsRoot = lyricsRoot
    }

    /// 只有曲库根（歌词同步关闭；`@lyrics/` 请求一律 notFound）。
    static func libraryOnly(_ root: URL) -> SyncFetchRoots {
        SyncFetchRoots(libraryRoot: root, lyricsRoot: nil)
    }

    /// 该相对路径归属的根：歌词命名空间 → lyricsRoot（未配置 = nil）；其余 → libraryRoot。
    /// 判定只看**规范化后**的路径前缀，`./@lyrics/x.json` 也算歌词路径。
    func root(forRelativePath relativePath: String) -> URL? {
        guard SyncLyricsNamespace.isLyricsPath(relativePath) else { return libraryRoot }
        return lyricsRoot
    }
}

/// 曲库根内路径解析：请求来的相对路径 → 绝对 URL，或明确拒绝原因。
/// **纯路径数学**（规范化 + 包含性判定），不读磁盘——存在性由调用方补。
enum SyncLibraryPathResolver {
    /// 解析结论。
    enum Resolution: Equatable {
        case resolved(URL)
        case rejected(String) // SyncFetchFailureReason 取值
    }

    /// 解析一条请求路径（多根版）：先按命名空间选根，再做根内解析。
    /// - 歌词命名空间但本端未配置歌词根 → notFound（本端确实没有这个文件）
    static func resolve(relativePath: String, roots: SyncFetchRoots) -> Resolution {
        guard let root = roots.root(forRelativePath: relativePath) else {
            // 歌词命名空间未接线：路径语法可能合法，但本端没有这个词根
            return SyncLyricsNamespace.isLyricsPath(relativePath)
                ? .rejected(SyncFetchFailureReason.notFound)
                : .rejected(SyncFetchFailureReason.invalidPath)
        }
        return resolve(relativePath: relativePath, root: root)
    }

    /// 解析一条请求路径。
    /// - 规范化与 manifest 同口径（拒空 / 绝对 / `..`），失败 → invalidPath
    /// - 规范化后仍不在 root 之下 → outOfRoot（纵深防御；standardizedFileURL 先把
    ///   符号链接以外的点段压平，再比路径前缀，避免 `/a/b` 命中 `/a/bc`）
    static func resolve(relativePath: String, root: URL) -> Resolution {
        guard let normalized = SyncManifestGenerator.normalizeRelativePath(relativePath) else {
            return .rejected(SyncFetchFailureReason.invalidPath)
        }
        let rootPath = root.standardizedFileURL.path
        let target = root.appendingPathComponent(normalized).standardizedFileURL
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard target.path.hasPrefix(prefix) else {
            return .rejected(SyncFetchFailureReason.outOfRoot)
        }
        return .resolved(target)
    }
}
