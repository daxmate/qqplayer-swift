//
//  SyncLibraryPushModels.swift
//  QQPlayer
//
//  R1b-1（2026-09-11）同步方向改造 · 被动侧能力——**Mac 推送 → 本端接收** 的线上契约
//  （纯声明 + 纯逻辑，无 IO）。
//
//  语义（docs/lan-sync-design.md §6.1 + §12b 决策 6/7，发起方恒为 Mac）：
//  「推送到设备」= Mac 决定推哪些歌 → 先发 **推送声明**（帧 14 `library_push_announce`）
//  告诉接收端「接下来要送哪些文件、各自落到哪个相对路径」→ 再按声明**串行**走既有
//  停等传输（file_meta / file_chunk / file_ack，帧 4/5/6）逐个送字节。
//
//  为什么需要声明帧（而不是把相对路径塞进 file_meta.name）：
//  - `FileMetaPayload.name` 的既有语义是「文件名（不含路径；接收端落盘名）」，
//    接收端对它有单段校验（防目录穿越）——把它当相对路径用会**改既有帧的字段语义**，
//    且把路径安全责任压到传输层（暂停协议里最不该承担目录语义的一层）。
//  - 声明帧把「目标相对路径」放在**应用层**，由接收端按同一套
//    `SyncManifestGenerator.normalizeRelativePath` 口径校验（拒空/绝对/`..`），
//    与 manifest / 拉取请求共用同一个对账键口径。
//
//  帧值语义：10-13 保持不动；本包新增从 **14** 起（14 = library_push_announce）。
//  本包只定义「接收侧可用的声明」，**发起端（Mac PushController）属 R1b-2**。
//
//  不传播删除（§12b 决策 7）：声明只描述「要送到哪里」，协议里不存在删除指令；
//  接收端也不因声明/落盘失败而删除本端任何既有内容。
//

import Foundation

// MARK: - 声明条目

/// 一条推送声明：一个文件的「目标相对路径 + 传输身份」。
struct SyncPushEntry: Codable, Equatable, Sendable {
    /// 接收端落位路径（相对**接收端曲库根**，POSIX "/"）；对账键同一口径。
    var relativePath: String
    /// 本次 `file_meta.name`（单段文件名）——接收端据此把自己收到的传输认领到本条目。
    var transferName: String
    /// 传输唯一 ID（v1 = content_hash；歌词文件 = 歌词所属歌曲的 content_hash）
    var fileID: String
    /// 全文件 SHA-256 小写 hex（发送前算好；接收端 SyncFileReceiver 会校验）
    var sha256Hex: String
    /// 文件字节数
    var size: Int64

    init(relativePath: String, transferName: String, fileID: String, sha256Hex: String, size: Int64) {
        self.relativePath = relativePath
        self.transferName = transferName
        self.fileID = fileID
        self.sha256Hex = sha256Hex
        self.size = size
    }

    /// 由相对路径构造条目（transferName 自动取末段）。路径/ID 非法 → nil。
    static func make(relativePath: String, fileID: String, sha256Hex: String, size: Int64) -> SyncPushEntry? {
        guard let normalized = SyncManifestGenerator.normalizeRelativePath(relativePath),
              let name = SyncPushEntry.transferName(forRelativePath: normalized),
              SyncPushEntry.isValidFileID(fileID)
        else { return nil }
        return SyncPushEntry(
            relativePath: normalized,
            transferName: name,
            fileID: fileID,
            sha256Hex: sha256Hex,
            size: size
        )
    }

    /// 相对路径 → 传输名（末段；单段校验不过 = nil）。
    static func transferName(forRelativePath relativePath: String) -> String? {
        guard let normalized = SyncManifestGenerator.normalizeRelativePath(relativePath) else { return nil }
        let name = (normalized as NSString).lastPathComponent
        guard isValidTransferName(name) else { return nil }
        return name
    }

    /// 传输名单段校验（收到的名字来自对端，按不可信输入处理）。
    static func isValidTransferName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.count <= 255 else { return false }
        guard !name.contains("/"), !name.contains("\\") else { return false }
        return !name.hasPrefix(".")
    }

    /// fileID 形态校验（v1 = content_hash；允许字幕/歌词等以歌曲 content_hash 作 ID）。
    static func isValidFileID(_ fileID: String) -> Bool {
        guard !fileID.isEmpty, fileID.count <= 128, fileID != ".", fileID != ".." else { return false }
        guard !fileID.contains("/"), !fileID.contains("\\") else { return false }
        return true
    }

    /// 本条声明是否自洽（接收端落盘前校验；不合法一律不落位）。
    var isStructurallyValid: Bool {
        guard let normalized = SyncManifestGenerator.normalizeRelativePath(relativePath),
              normalized == relativePath
        else { return false }
        guard transferName == SyncPushEntry.transferName(forRelativePath: normalized) else { return false }
        guard SyncPushEntry.isValidFileID(fileID), !sha256Hex.isEmpty else { return false }
        return true
    }
}

// MARK: - 声明帧载荷

/// `library_push_announce`（帧 14）载荷：一批即将推送的文件声明。
/// 接收端据它建立「传输名 → 目标相对路径」认领表，并按批次数目判定本轮收尾。
struct SyncLibraryPushAnnounce: Codable, Equatable, Sendable {
    /// 声明条目（按 relativePath 升序，确定性：同批内容字节稳定，便于比对/日志）
    var entries: [SyncPushEntry]

    /// 构造时排序 + 同相对路径去重（first wins）+ 丢弃结构非法条目。
    init(entries: [SyncPushEntry]) {
        var seen: Set<String> = []
        var kept: [SyncPushEntry] = []
        for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            guard entry.isStructurallyValid else { continue }
            guard seen.insert(entry.relativePath).inserted else { continue }
            kept.append(entry)
        }
        self.entries = kept
    }

    /// 是否没有可接收内容（接收端据此直接收尾）。
    var isEmpty: Bool { entries.isEmpty }
}

/// 推送声明 JSON 编解码（帧 payload = 载荷类型 JSON 字节，风格对齐其它 Codec）。
enum SyncPushCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - 接收侧失败记账（本地诊断，无线上载荷）

/// 被动端一条失败记录（诊断/测试/UI 用）。
struct SyncPushFailure: Equatable, Sendable {
    /// 目标相对路径（传输级失败无法归属路径时为空串）
    var relativePath: String
    /// 原因（`SyncPushFailureReason` 取值）
    var reason: String
    /// 附加上下文（错误摘要；无则 nil）
    var detail: String?
}

/// 推送接收侧失败原因（本地字符串常量，跨版本可加不可改）。
enum SyncPushFailureReason {
    /// 传输本体失败（SyncFileReceiver 终态；含校验不符/IO/断连）
    static let receiveFailed = "receive_failed"
    /// 声明的目标路径非法（越界/畸形；拿不到可落位位置）
    static let invalidPath = "invalid_path"
    /// 落位失败（建目录/移动/替换失败）或歌词写盘失败
    static let landFailed = "land_failed"
}

// MARK: - 认领表（纯逻辑，可单测）

/// 接收端认领表：`file_meta.name` → 声明的目标相对路径。
/// - 同名多路径（两个目录下同名文件）：按声明顺序取首个未被认领的（与
///   `SyncLibrarySyncController.expectedPathsByName` 同策略，v1 单飞传输下唯一可判）；
/// - 未声明过的名字 / 已认领完：返回 nil（接收端不落位，交清理）。
struct SyncPushClaimTable: Equatable {
    private var remaining: [String: [String]] = [:]

    init(entries: [SyncPushEntry] = []) {
        for entry in entries {
            remaining[entry.transferName, default: []].append(entry.relativePath)
        }
    }

    /// 认领一个传输名 → 目标相对路径（取走即移除）。
    mutating func claim(transferName: String) -> String? {
        guard var paths = remaining[transferName], !paths.isEmpty else { return nil }
        let path = paths.removeFirst()
        remaining[transferName] = paths.isEmpty ? nil : paths
        return path
    }

    /// 是否还有未认领的条目。
    var isEmpty: Bool { remaining.isEmpty }
}
