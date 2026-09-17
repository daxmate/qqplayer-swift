//
//  CharacterMapResourceLoader.swift
//  QQPlayer
//
//  简繁单字映射表的**唯一读盘入口**（2026-09-17 P2-①：6900 行 Swift 字面量下沉为资源 + 懒加载）。
//
//  数据（UTF-8 TSV，每行 `<键>\t<值>`，键/值各恰好一个 Unicode 标量，按码点升序）：
//  - QQPlayer/Resources/SimplifiedToTraditional.tsv（简→繁，OpenCC STCharacters + 台→台 特例）
//  - QQPlayer/Resources/TraditionalToSimplified.tsv（繁→简，OpenCC TSCharacters）
//  生成器：scripts/gen-character-maps.sh（从**字面量版源文件** dump；资源与基线夹具同一次输出 → 字节一致）
//  基线夹具 + SHA-256：QQPlayerTests/Fixtures/{simplified-to-traditional,traditional-to-simplified}.baseline.tsv
//
//  设计约束（改动前先读）：
//  1. **一个语义一个入口**：这两张表只有本文件读盘；别处不许直接 `Bundle…url(forResource: "SimplifiedToTraditional")`
//     （契约测试 `DisplayScriptContract.resourceLoadViolations` 守着这条）。
//  2. **懒加载**：调用方是文件级 `let`（Swift 全局 `let` 默认惰性 + once 语义）→ 首次使用时读盘一次；
//     本文件另有一层进程内缓存，保证「同一资源只解析一次」对直接调用也成立。
//  3. **fail-closed**：读不到 / 解码失败 / 行格式不对 → `fatalError`（**绝不静默返回空表**）。
//     空表不会崩，只会把所有字形归一静默降级成「原样输出」——2026-09-16 的事故就是这种静默降级
//     （当时是反转表依赖哈希顺序），排查代价极高。宁可启动即炸也不要静默错。
//     该 fatalError 只可能被「资源没进包」触发，而这是打包错误：三端包自证 + 单测都覆盖。
//
import Foundation

/// 简繁单字映射资源加载器（唯一读盘入口）
enum CharacterMapResourceLoader {
    /// 已下沉的资源（rawValue = bundle 内文件名主干）
    enum Resource: String, CaseIterable {
        /// 简→繁（OpenCC STCharacters + 台→台 特例）
        case simplifiedToTraditional = "SimplifiedToTraditional"
        /// 繁→简（OpenCC TSCharacters 首选值）
        case traditionalToSimplified = "TraditionalToSimplified"

        /// bundle 内文件名
        var fileName: String { "\(rawValue).tsv" }
        /// 仓库内规范路径（契约测试用来核对「源码里的资源就是 bundle 里的资源」）
        var repositoryPath: String { "QQPlayer/Resources/\(fileName)" }
    }

    /// 加载失败原因（只在 fatalError 消息里出现；`parse` 用它做可测的失败语义）
    enum LoadFailure: Error, CustomStringConvertible {
        case resourceMissing(Resource, searched: [String])
        case unreadable(Resource, underlying: String)
        case malformed(Resource, line: Int, detail: String)

        var description: String {
            switch self {
            case let .resourceMissing(resource, searched):
                return "资源 \(resource.fileName) 在候选 bundle 里都找不到（找过：\(searched.joined(separator: " / "))）"
            case let .unreadable(resource, underlying):
                return "资源 \(resource.fileName) 读不出来：\(underlying)"
            case let .malformed(resource, line, detail):
                return "资源 \(resource.fileName) 第 \(line) 行格式不对：\(detail)"
            }
        }
    }

    // MARK: - 加载

    /// 取映射表（进程内缓存；失败 fail-closed）
    static func load(_ resource: Resource) -> [Character: Character] {
        cacheLock.lock()
        if let cached = cache[resource] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // 解析在锁外做（读盘不阻塞其他资源），完成后回写缓存并服从「先写入者胜」
        let map: [Character: Character]
        do {
            map = try parse(text: try readText(resource), resource: resource)
        } catch {
            fatalError("❌ 简繁映射表加载失败（fail-closed，不降级成空表）：\(error)")
        }
        cacheLock.lock()
        if let existing = cache[resource] {
            cacheLock.unlock()
            return existing
        }
        cache[resource] = map
        cacheLock.unlock()
        return map
    }

    /// 读资源文本（bundle 定位；只在这里碰 Bundle）
    static func readText(_ resource: Resource) throws -> String {
        var searched: [String] = []
        for bundle in candidateBundles {
            // 资源进包后可能被放在 bundle 根，也可能保留 `Resources/` 子目录（取决于 Xcode 的拷贝方式）
            for subdirectory in [nil, "Resources"] {
                searched.append("\(bundle.bundlePath)/\(subdirectory.map { $0 + "/" } ?? "")\(resource.fileName)")
                guard let url = bundle.url(forResource: resource.rawValue, withExtension: "tsv", subdirectory: subdirectory) else {
                    continue
                }
                do {
                    return try String(contentsOf: url, encoding: .utf8)
                } catch {
                    throw LoadFailure.unreadable(resource, underlying: "\(url.path)：\(error)")
                }
            }
        }
        throw LoadFailure.resourceMissing(resource, searched: searched)
    }

    /// 候选 bundle：宿主 app/扩展包在前（`Bundle.main` 在三端都是「本进程所属的包」），
    /// 再兜底本类型所在包（SwiftPM/测试宿主等场景，`Bundle.main` 可能不是装资源的那个）。
    private static var candidateBundles: [Bundle] {
        let own = Bundle(for: BundleToken.self)
        if own.bundleURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
            return [Bundle.main]
        }
        return [Bundle.main, own]
    }

    // MARK: - 解析（纯函数，可单测）

    /// 解析 TSV 文本 → 映射表。任何格式异常都抛错（不吞、不跳过坏行）
    static func parse(text: String, resource: Resource) throws -> [Character: Character] {
        var map: [Character: Character] = [:]
        map.reserveCapacity(4096)
        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            var line = rawLine
            if line.hasSuffix("\r") { line = line.dropLast() }
            if line.isEmpty { continue }  // 只容忍空行（文件末尾换行）
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 2 else {
                throw LoadFailure.malformed(resource, line: lineNumber, detail: "期望 2 列（键<TAB>值），实际 \(columns.count) 列")
            }
            guard let key = singleScalar(columns[0]), let value = singleScalar(columns[1]) else {
                throw LoadFailure.malformed(resource, line: lineNumber, detail: "键/值必须是单个 Unicode 标量")
            }
            guard map[key] == nil else {
                throw LoadFailure.malformed(resource, line: lineNumber, detail: "键 \(key) 重复（数据有歧义）")
            }
            map[key] = value
        }
        guard !map.isEmpty else {
            throw LoadFailure.malformed(resource, line: 0, detail: "表为空（0 条）")
        }
        return map
    }

    /// 恰好一个 Unicode 标量的字符（多标量字形簇会让「一字符一行」的结构假设失效 → 判非法）
    private static func singleScalar(_ text: Substring) -> Character? {
        let scalars = text.unicodeScalars
        guard scalars.count == 1, !scalars.first!.properties.isWhitespace,
              !CharacterSet.controlCharacters.contains(scalars.first!)
        else { return nil }
        return Character(scalars.first!)
    }

    private final class BundleToken {}

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [Resource: [Character: Character]] = [:]
}
