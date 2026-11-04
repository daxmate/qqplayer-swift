//
//  DSQSharedMigrator.swift
//  QQPlayer
//
//  共享资源目录迁移器（2026-11-04）。
//
//  迁移两类数据：
//    · 旧公共资源 `~/Library/Application Support/DSQ Common Resources` → 新根
//    · QQPlayer 旧模型目录 `.../QQPlayer/RecommendationModels/<id>` → `<新根>/Models/...`
//
//  硬约束：
//   · **默认 dryRun**，必须显式 apply 才动盘；
//   · 同卷优先 moveItem（rename），跨卷才 copy → 校验 → 删源；
//   · 目标必须不存在或为空，绝不覆盖；
//   · 迁移后核对文件数与总字节，失败回滚已完成的项；
//   · 幂等 marker `.dsq-shared-migrated-v1`（写在共享根）；
//   · 旧路径留 symlink（QQPlayer 非沙盒可用；失败只记 warning，不回滚数据）。
//
//  纯 Foundation、依赖可注入，便于 `scripts/run-dsq-shared-tests.sh` 无模拟器直编。
//

import Foundation

struct DSQSharedMigrator {
    static let markerFileName = ".dsq-shared-migrated-v1"

    /// 一项迁移：源目录 → 目标目录。
    struct Item: Equatable {
        let name: String
        let source: URL
        let destination: URL
        let leavesSymlink: Bool

        init(name: String, source: URL, destination: URL, leavesSymlink: Bool = true) {
            self.name = name
            self.source = source
            self.destination = destination
            self.leavesSymlink = leavesSymlink
        }
    }

    /// 迁移结果分类。
    enum Outcome: String {
        case alreadyMigrated = "already-migrated"
        case alreadyAtDestination = "already-at-destination"
        case missingSource = "missing-source"
        case destinationNotEmpty = "destination-not-empty"
        case planned
        case moved
        case copied
        case failed
        case skipped
    }

    struct ItemReport: Equatable {
        let name: String
        let outcome: Outcome
        let source: URL
        let destination: URL
        let message: String
    }

    struct Report: Equatable {
        let dryRun: Bool
        let markerURL: URL
        let items: [ItemReport]
        let warnings: [String]

        var succeeded: Bool {
            !items.contains { [.failed, .destinationNotEmpty, .skipped].contains($0.outcome) }
        }

        var hasWork: Bool {
            items.contains { [.planned, .moved, .copied].contains($0.outcome) }
        }
    }

    struct Options {
        var dryRun: Bool
        var leaveSymlinks: Bool
        /// 测试注入：强制同卷 / 跨卷判定；nil 时按 volumeIdentifier 判断。
        var sameVolume: ((URL, URL) -> Bool)?

        init(
            dryRun: Bool = true,
            leaveSymlinks: Bool = true,
            sameVolume: ((URL, URL) -> Bool)? = nil
        ) {
            self.dryRun = dryRun
            self.leaveSymlinks = leaveSymlinks
            self.sameVolume = sameVolume
        }
    }

    enum MigratorError: LocalizedError {
        case verificationMismatch(expected: Measurement, actual: Measurement)
        case unreadable(URL)

        var errorDescription: String? {
            switch self {
            case let .verificationMismatch(expected, actual):
                return "迁移后校验失败：期望 \(expected.files) 文件 / \(expected.bytes) 字节，实际 \(actual.files) 文件 / \(actual.bytes) 字节"
            case let .unreadable(url):
                return "无法枚举目录：\(url.path)"
            }
        }
    }

    struct Measurement: Equatable {
        let files: Int
        let bytes: Int64
    }

    private enum DestinationState {
        case absent
        case emptyDirectory
        case nonEmpty
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - 入口

    func run(items: [Item], markerURL: URL, options: Options = Options()) -> Report {
        if fileManager.fileExists(atPath: markerURL.path) {
            let reports = items.map { item in
                ItemReport(
                    name: item.name,
                    outcome: .alreadyMigrated,
                    source: item.source,
                    destination: item.destination,
                    message: "marker 已存在（幂等，无操作）"
                )
            }
            return Report(dryRun: options.dryRun, markerURL: markerURL, items: reports, warnings: [])
        }

        // 1) 预检：只读，任何冲突都整批不动盘。
        var planned: [(item: Item, outcome: Outcome, message: String, sameVolume: Bool?)] = []
        var blocked = false
        for item in items {
            if item.source.standardizedFileURL.path == item.destination.standardizedFileURL.path {
                planned.append((item, .alreadyAtDestination, "源与目标相同，无需迁移", nil))
                continue
            }
            if isSymbolicLink(item.source) {
                planned.append((item, .alreadyAtDestination, "源已是 symlink（迁移已完成）", nil))
                continue
            }
            guard fileManager.fileExists(atPath: item.source.path) else {
                planned.append((item, .missingSource, "源不存在，跳过", nil))
                continue
            }
            switch destinationState(item.destination) {
            case .nonEmpty:
                planned.append((item, .destinationNotEmpty, "目标非空，拒绝覆盖", nil))
                blocked = true
            case .absent, .emptyDirectory:
                let same = sameVolume(item.source, item.destination, options: options)
                planned.append((item, .planned, same ? "将 moveItem（同卷）" : "将 copy → 校验 → 删源（跨卷）", same))
            }
        }

        if blocked {
            let reports = planned.map { entry in
                ItemReport(
                    name: entry.item.name,
                    outcome: entry.outcome == .planned ? .skipped : entry.outcome,
                    source: entry.item.source,
                    destination: entry.item.destination,
                    message: entry.outcome == .planned ? "存在冲突项，整批未执行" : entry.message
                )
            }
            return Report(dryRun: options.dryRun, markerURL: markerURL, items: reports, warnings: [])
        }

        if options.dryRun {
            let reports = planned.map { entry in
                ItemReport(
                    name: entry.item.name,
                    outcome: entry.outcome,
                    source: entry.item.source,
                    destination: entry.item.destination,
                    message: entry.message
                )
            }
            return Report(dryRun: true, markerURL: markerURL, items: reports, warnings: [])
        }

        // 2) 执行：任何一项失败 → 回滚已完成的项。
        var reports: [ItemReport] = []
        var applied: [(item: Item, outcome: Outcome)] = []
        var pending = planned.makeIterator()
        while let entry = pending.next() {
            guard entry.outcome == .planned else {
                reports.append(ItemReport(
                    name: entry.item.name,
                    outcome: entry.outcome,
                    source: entry.item.source,
                    destination: entry.item.destination,
                    message: entry.message
                ))
                continue
            }
            do {
                let outcome = try perform(entry.item, sameVolume: entry.sameVolume ?? true)
                applied.append((entry.item, outcome))
                reports.append(ItemReport(
                    name: entry.item.name,
                    outcome: outcome,
                    source: entry.item.source,
                    destination: entry.item.destination,
                    message: outcome == .moved ? "已 moveItem" : "已 copy → 校验 → 删源"
                ))
            } catch {
                rollback(applied)
                let failed = ItemReport(
                    name: entry.item.name,
                    outcome: .failed,
                    source: entry.item.source,
                    destination: entry.item.destination,
                    message: "失败并已回滚：\(error.localizedDescription)"
                )
                reports.append(failed)
                while let rest = pending.next() {
                    reports.append(ItemReport(
                        name: rest.item.name,
                        outcome: .skipped,
                        source: rest.item.source,
                        destination: rest.item.destination,
                        message: "前序项失败，未执行"
                    ))
                }
                return Report(
                    dryRun: false,
                    markerURL: markerURL,
                    items: reports,
                    warnings: ["迁移失败，已回滚 (applied.count) 项"]
                )
            }
        }

        // 3) marker 落盘失败 → 回滚数据（否则下次会被 symlink 干扰）。
        do {
            try writeMarker(at: markerURL, items: items)
        } catch {
            rollback(applied)
            reports = reports.map { report in
                guard [.moved, .copied].contains(report.outcome) else { return report }
                return ItemReport(
                    name: report.name,
                    outcome: .failed,
                    source: report.source,
                    destination: report.destination,
                    message: "marker 写入失败，已回滚：\(error.localizedDescription)"
                )
            }
            return Report(
                dryRun: false,
                markerURL: markerURL,
                items: reports,
                warnings: ["marker 写入失败：\(error.localizedDescription)"]
            )
        }

        // 4) 旧路径留 symlink（数据已迁移成功，symlink 失败只记 warning）。
        var warnings: [String] = []
        if options.leaveSymlinks {
            for entry in applied {
                if let warning = createSymlink(for: entry.item) {
                    warnings.append(warning)
                }
            }
        }

        return Report(dryRun: false, markerURL: markerURL, items: reports, warnings: warnings)
    }

    // MARK: - 单次迁移

    private func perform(_ item: Item, sameVolume: Bool) throws -> Outcome {
        let before = try Self.measure(item.source, fileManager: fileManager)
        try fileManager.createDirectory(
            at: item.destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if destinationState(item.destination) == .emptyDirectory {
            try fileManager.removeItem(at: item.destination)
        }

        do {
            if sameVolume {
                try fileManager.moveItem(at: item.source, to: item.destination)
            } else {
                try fileManager.copyItem(at: item.source, to: item.destination)
            }
            let after = try Self.measure(item.destination, fileManager: fileManager)
            guard after == before else {
                throw MigratorError.verificationMismatch(expected: before, actual: after)
            }
        } catch {
            // 目标侧清理干净，源保持原样
            if sameVolume {
                if !fileManager.fileExists(atPath: item.source.path) {
                    try? fileManager.moveItem(at: item.destination, to: item.source)
                }
            } else {
                try? fileManager.removeItem(at: item.destination)
            }
            throw error
        }

        if !sameVolume {
            do {
                try fileManager.removeItem(at: item.source)
            } catch {
                // 源删不掉：撤销目标副本，回到迁移前状态
                try? fileManager.removeItem(at: item.destination)
                throw error
            }
        }
        return sameVolume ? .moved : .copied
    }

    private func rollback(_ applied: [(item: Item, outcome: Outcome)]) {
        for entry in applied.reversed() {
            switch entry.outcome {
            case .moved:
                if !fileManager.fileExists(atPath: entry.item.source.path) {
                    try? fileManager.moveItem(at: entry.item.destination, to: entry.item.source)
                }
            case .copied:
                try? fileManager.removeItem(at: entry.item.destination)
            default:
                break
            }
        }
    }

    // MARK: - 辅助

    private func destinationState(_ url: URL) -> DestinationState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .absent
        }
        guard isDirectory.boolValue else { return .nonEmpty }
        let contents = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
        return contents.isEmpty ? .emptyDirectory : .nonEmpty
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return false
        }
        return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func sameVolume(_ source: URL, _ destination: URL, options: Options) -> Bool {
        if let override = options.sameVolume {
            return override(source, destination)
        }
        guard let sourceVolume = volumeIdentifier(of: source),
              let destinationVolume = volumeIdentifier(of: destination)
        else {
            // 取不到就按同卷处理：moveItem 在跨卷时也会退化为复制，失败由校验兜底。
            return true
        }
        return sourceVolume == destinationVolume
    }

    private func volumeIdentifier(of url: URL) -> String? {
        var candidate = url
        var hops = 0
        while !fileManager.fileExists(atPath: candidate.path), hops < 64 {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
            hops += 1
        }
        guard let values = try? candidate.resourceValues(forKeys: [.volumeIdentifierKey]),
              let identifier = values.volumeIdentifier
        else {
            return nil
        }
        return String(describing: identifier)
    }

    private func writeMarker(at url: URL, items: [Item]) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var lines = ["DSQ shared resources migration v1", "date=\(timestamp)"]
        for item in items {
            lines.append("\(item.name): \(item.source.path) -> \(item.destination.path)")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func createSymlink(for item: Item) -> String? {
        guard item.leavesSymlink else { return nil }
        if isSymbolicLink(item.source) { return nil }
        if fileManager.fileExists(atPath: item.source.path) { return nil }
        do {
            try fileManager.createDirectory(
                at: item.source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createSymbolicLink(at: item.source, withDestinationURL: item.destination)
            return nil
        } catch {
            return "symlink 创建失败：\(item.source.path) → \(item.destination.path)：\(error.localizedDescription)"
        }
    }

    /// 递归统计普通文件数与总字节（symlink 不跟随）。
    static func measure(_ url: URL, fileManager: FileManager = .default) throws -> Measurement {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return Measurement(files: 0, bytes: 0)
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        if !isDirectory.boolValue {
            let values = try url.resourceValues(forKeys: keys)
            return Measurement(files: 1, bytes: Int64(values.fileSize ?? 0))
        }
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            throw MigratorError.unreadable(url)
        }
        var files = 0
        var bytes: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else {
                continue
            }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return Measurement(files: files, bytes: bytes)
    }
}
