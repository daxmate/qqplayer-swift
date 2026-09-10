//
//  AlignedLyricsStore.swift
//  QQPlayer
//
//  局域网同步（S2, M4-2b）aligned（对齐）歌词库 —— **唯一入口**（读写删枚举 + 接收侧安装）。
//
//  语义（docs/lan-sync-design.md §6.3，2026-09-08 拍板 B 方案）：
//  - 存储：独立歌词库，**延续现状 `Documents/lyrics-manual/{stableId}.json` 形态**——
//    一歌一文件、键 = 本端 stableId、文件内容 = 裸 `Lyrics` JSON（与 manual 同构，
//    同一解码器即可读），不散落到音乐目录。
//  - 类型标记：`aligned`（对齐产物）/ `manual`（手动指定）/ `network`（网络缓存）。
//    **落地方式 = 存储命名空间（目录）**，见 `LyricsStoreKind` 的说明。
//  - 只有 aligned 参与同步：判定收敛在 `LyricsStoreKind.synchronizesWithLibrary`，
//    同步侧一律经 `AlignedLyricsStore` / `SyncAlignedLyricsManifest` 读写，
//    不允许在别处散写「哪些歌词能同步」的判断。
//
//  为什么不给 `Lyrics` 模型加 `kind` 字段：manual（LyricsManager）与 network
//  （LyricsSearch 缓存）的现有 JSON 必须**逐字节语义不变**，加字段会让新写出的
//  manual/network 文件多一个键（存储被改动），且两类文件本来就不需要自描述——
//  它们的「类型」由所在目录唯一确定。目录命名空间既满足类型标记，又零改动旧存储。
//
//  目录布局（Documents 下，三者互不重叠）：
//    aligned → Documents/lyrics-aligned/{stableId}.json   （本文件）
//    manual  → Documents/lyrics-manual/{stableId}.json    （LyricsManager，未改动）
//    network → Documents/lyrics-cache/tracks/{stableId}.json（LyricsSearch，未改动）
//
//  线程：仅文件 IO，无共享可变状态，`@unchecked Sendable` 安全。
//

import Foundation

// MARK: - 类型标记（歌词库种类）

/// 歌词库种类 = **存储命名空间**（类型标记的唯一事实源）。
enum LyricsStoreKind: String, CaseIterable, Sendable {
    /// 对齐产物（桌面版 AI 对齐）——唯一参与随歌同步的歌词。
    case aligned
    /// 用户手动指定（搜索页选择；LyricsManager 所有，M4-2b 未改动）。
    case manual
    /// 在线源缓存（lrclib / 网易云；LyricsSearch 所有，两端各自下载）。
    case network

    /// Documents 下的目录名（相对路径，POSIX）。
    var directoryName: String {
        switch self {
        case .aligned: return "lyrics-aligned"
        case .manual: return "lyrics-manual"
        case .network: return "lyrics-cache/tracks"
        }
    }

    /// 是否随歌曲对账同步（§6.3：**只有 aligned 为 true**）。
    var synchronizesWithLibrary: Bool { self == .aligned }

    /// 参与同步的种类集合（目前唯一 = aligned）。同步侧要判「哪些歌词同步」时
    /// 只经此处，不写字面量。
    static let synchronizedKinds: [LyricsStoreKind] = allCases.filter(\.synchronizesWithLibrary)
}

// MARK: - 枚举条目

/// aligned 歌词库中的一条记录（manifest 生成输入，纯值）。
struct AlignedLyricsEntry: Equatable, Sendable {
    /// 本端歌曲 stableId（库内文件名主键）。
    var stableId: String
    /// 磁盘文件 URL。
    var fileURL: URL
    /// 文件字节数。
    var size: Int64
    /// 文件修改时间（毫秒 since 1970）。
    var mtimeMs: Int64
}

// MARK: - 单一入口

/// aligned 歌词库（`Documents/lyrics-aligned/{stableId}.json`）的**唯一入口**：
/// 写 / 读 / 删 / 枚举 / 接收侧安装都走这里，同步侧不直接摸文件路径。
final class AlignedLyricsStore: @unchecked Sendable {
    enum StoreError: Error, Equatable {
        /// stableId 非法（空 / 含路径分隔符 / 点段）——绝不拿它拼文件名。
        case invalidStableId
        /// 目录不可解析（无 Documents 目录且未注入）
        case directoryUnavailable(String)
        /// 文件存在但不是合法 `Lyrics` JSON（接收侧校验用）
        case undecodable(String)
        /// 磁盘写入/移动失败
        case ioFailure(String)
    }

    /// 生产默认实例（Documents/lyrics-aligned）。
    static let shared = AlignedLyricsStore()

    /// 测试注入：覆盖库目录（nil = 默认 Documents/lyrics-aligned；与
    /// `LyricsManager.manualLyricsDirectoryOverride` 同风格）。
    nonisolated(unsafe) static var directoryOverride: URL?

    private let fileManager: FileManager
    private let explicitDirectory: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// - Parameter directory: 显式库目录（测试/harness 注入）；nil 时用
    ///   `directoryOverride`，再落回 `Documents/lyrics-aligned`。
    init(directory: URL? = nil, fileManager: FileManager = .default) {
        explicitDirectory = directory
        self.fileManager = fileManager
    }

    // MARK: 目录

    /// 默认库目录（Documents/lyrics-aligned，不存在则创建）。
    static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent(LyricsStoreKind.aligned.directoryName, isDirectory: true)
    }

    /// 库目录（懒建；解析失败 = nil）。
    var directory: URL? {
        guard let dir = explicitDirectory ?? Self.directoryOverride ?? Self.defaultDirectory(fileManager: fileManager) else {
            return nil
        }
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// stableId → 库内文件 URL（nil = 目录不可解析或 stableId 非法）。
    func fileURL(forStableId stableId: String) -> URL? {
        guard Self.isValidStableId(stableId), let directory else { return nil }
        return directory.appendingPathComponent("\(stableId).json")
    }

    /// stableId 合法性（防路径穿越）：非空、非点段、不含 `/` 与 `\`。
    static func isValidStableId(_ stableId: String) -> Bool {
        guard !stableId.isEmpty, stableId != ".", stableId != ".." else { return false }
        return !stableId.contains("/") && !stableId.contains("\\")
    }

    // MARK: 写 / 读 / 删

    /// 写入一条 aligned 歌词（原子写；覆盖同名）。
    func write(_ lyrics: Lyrics, forStableId stableId: String) throws {
        guard let url = fileURL(forStableId: stableId) else {
            throw Self.isValidStableId(stableId) ? StoreError.directoryUnavailable(stableId) : StoreError.invalidStableId
        }
        do {
            let data = try encoder.encode(lyrics)
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.ioFailure("\(stableId): \(error)")
        }
    }

    /// 读取一条 aligned 歌词（不存在 = nil；JSON 坏 = 抛错，不静默吞）。
    func read(forStableId stableId: String) throws -> Lyrics? {
        guard let url = fileURL(forStableId: stableId) else {
            throw Self.isValidStableId(stableId) ? StoreError.directoryUnavailable(stableId) : StoreError.invalidStableId
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try decoder.decode(Lyrics.self, from: data)
        } catch {
            throw StoreError.undecodable("\(stableId): \(error)")
        }
    }

    /// 删除一条 aligned 歌词（幂等：不存在也算成功）。
    func delete(forStableId stableId: String) throws {
        guard let url = fileURL(forStableId: stableId) else {
            throw Self.isValidStableId(stableId) ? StoreError.directoryUnavailable(stableId) : StoreError.invalidStableId
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw StoreError.ioFailure("\(stableId): \(error)")
        }
    }

    /// 库内是否已有该歌的 aligned 歌词。
    func contains(forStableId stableId: String) -> Bool {
        guard let url = fileURL(forStableId: stableId) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    // MARK: 枚举

    /// 全库条目（按 stableId 升序，确定性；非 `.json` / 非法文件名跳过）。
    func entries() -> [AlignedLyricsEntry] {
        guard let directory,
              let urls = try? fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
              )
        else { return [] }
        var result: [AlignedLyricsEntry] = []
        for url in urls where url.pathExtension == "json" {
            let stableId = url.deletingPathExtension().lastPathComponent
            guard Self.isValidStableId(stableId) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile != false else { continue }
            result.append(
                AlignedLyricsEntry(
                    stableId: stableId,
                    fileURL: url,
                    size: Int64(values?.fileSize ?? 0),
                    mtimeMs: Int64((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
                )
            )
        }
        return result.sorted { $0.stableId < $1.stableId }
    }

    /// 全库歌曲 stableId（升序）。
    func stableIds() -> [String] {
        entries().map(\.stableId)
    }

    // MARK: 接收侧安装（同步通道落地）

    /// 把同步通道收到的歌词文件安装进库：**先校验可解码**（线上载荷可能是坏字节，
    /// 宁可不落也不写坏库），再原子落位到 `{stableId}.json`。
    /// 采用「移动收到的文件」而非「解码 → 重编码」：字节原样落库，避免二次编码差异，
    /// 也让发送侧算出的 SHA-256 在接收侧对得上。
    func install(receivedFileAt sourceURL: URL, forStableId stableId: String) throws {
        guard let destination = fileURL(forStableId: stableId) else {
            throw Self.isValidStableId(stableId) ? StoreError.directoryUnavailable(stableId) : StoreError.invalidStableId
        }
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw StoreError.ioFailure("收文件读取失败: \(error)")
        }
        do {
            _ = try decoder.decode(Lyrics.self, from: data)
        } catch {
            throw StoreError.undecodable("\(stableId): \(error)")
        }
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: sourceURL)
            } else {
                try fileManager.moveItem(at: sourceURL, to: destination)
            }
        } catch {
            // 跨卷 / replace 失败兜底：复制 + 删除
            do {
                try data.write(to: destination, options: .atomic)
                try? fileManager.removeItem(at: sourceURL)
            } catch {
                throw StoreError.ioFailure("\(stableId): \(error)")
            }
        }
    }
}
