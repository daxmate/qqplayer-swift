//
//  SyncManifestGenerator.swift
//  QQPlayer
//
//  局域网同步（S2, M3-3a）manifest 生成纯逻辑（零 IO）：
//  输入 = 一次目录扫描得到的文件列表（相对曲库根的路径 + size + mtime + 可选
//  stableId）与各文件 content_hash 映射（M3-1 指纹，键 = 相对路径）；
//  输出 = 排序确定、已去重、已丢弃非法路径的 ManifestEntry 列表。
//
//  职责边界：本文件不做扫描（MusicDirectoryScanner 负责枚举 URL）、不算 SHA-256
//  （DatabaseManager.contentHashIfFilePresent 负责指纹）——只把既有事实整理成
//  可上线、可对账的 manifest。曲库根 = relativePath 基准。
//

import Foundation

/// manifest 生成输入：扫描阶段已知的单文件事实。
/// size/mtime 由扫描时的 resourceValues 提供；contentHash 由指纹链路提供（可缺省）。
struct SyncManifestSourceFile: Equatable, Sendable {
    var relativePath: String
    var size: Int64
    var mtimeMs: Int64
    var contentHash: String?
    var stableId: String?

    init(
        relativePath: String,
        size: Int64,
        mtimeMs: Int64 = 0,
        contentHash: String? = nil,
        stableId: String? = nil
    ) {
        self.relativePath = relativePath
        self.size = size
        self.mtimeMs = mtimeMs
        self.contentHash = contentHash
        self.stableId = stableId
    }
}

enum SyncManifestGenerator {
    /// 生成 manifest（纯函数）。
    /// - contentHashes：相对路径 → 内容指纹；命中则覆盖 source 自带值（指纹是
    ///   权威事实，扫描阶段的哈希可能缺失或过期）。
    /// - 规范化：丢弃空路径 / 绝对路径 / 含 `..` 的路径（防目录穿越），去掉
    ///   `./` 前缀与重复 `/`；同路径去重（later wins：扫描序靠后 = 更新）。
    /// - 输出按 relativePath 升序（跨端/跨次运行确定性，便于比对与测试）。
    static func generate(
        files: [SyncManifestSourceFile],
        contentHashes: [String: String] = [:]
    ) -> [ManifestEntry] {
        var byPath: [String: SyncManifestSourceFile] = [:]
        for file in files {
            guard let path = normalizeRelativePath(file.relativePath) else { continue }
            var normalized = file
            normalized.relativePath = path
            if let override = contentHashes[path] ?? contentHashes[file.relativePath] {
                normalized.contentHash = override
            }
            byPath[path] = normalized
        }
        return byPath.values
            .map {
                ManifestEntry(
                    relativePath: $0.relativePath,
                    size: $0.size,
                    mtimeMs: $0.mtimeMs,
                    contentHash: $0.contentHash,
                    stableId: $0.stableId
                )
            }
            .sorted { $0.relativePath < $1.relativePath }
    }

    /// 相对路径基准计算：文件 URL 相对曲库根的路径（POSIX 分隔）。
    /// 不在根内 / 等于根 / 空路径 → nil（调用方跳过，不入 manifest）。
    static func relativePath(of url: URL, baseDirectory: URL) -> String? {
        let base = baseDirectory.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        guard target.count > base.count, Array(target.prefix(base.count)) == base else {
            return nil
        }
        return normalizeRelativePath(target.dropFirst(base.count).joined(separator: "/"))
    }

    /// 路径规范化（对账键的单一事实源）：拒绝绝对路径与 `..` 逃逸，统一分隔符。
    /// 返回 nil = 非法（调用方丢弃，绝不"顺手修正"成可疑路径）。
    static func normalizeRelativePath(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        path = path.replacingOccurrences(of: "\\", with: "/")
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                return nil
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }
}
