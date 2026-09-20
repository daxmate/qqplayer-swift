//
//  LogRotation.swift
//  QQPlayer
//
//  日志体积控制（判定 / 命名 / 归档）的**唯一实现**（2026-09-20 立，日志治理批 1 地基）。
//
//  设计源：`tmp/docs/logging.md` §二。为什么单独成文件：判定/命名/归档此前散在多处
//  （`SyncConnectDiag.append` 与 `DatabaseManager.dbDiag` 各写了一份「超 256KB 留尾部 64KB」
//  的环形截断，改阈值要改多处）——AGENTS.md 2026-09-15「同一语义多处手工维护」的教训。
//
//  对外三个入口（调用点受 `QQPlayerTests/AppLogShapeContractTests.swift` 白名单制约束）：
//    - `rotateIfNeeded`       归档轮转：超 maxBytes → app.log → app.log.1 → …，最老份删除；
//                             文件远超总预算（maxBytes × maxFiles，如遗留 49MB）→ **丢历史**
//                             （截空，不改名保留）
//    - `trimTailIfNeeded`     环形截断：超 N 留尾部 M（保既有 256KB/64KB 语义）
//    - `shouldDiscardHistory` 「是否该丢历史」的判定（供 `rotateIfNeeded` 与取证脚本复用）
//
//  环境变量可临时放大取证：`QQPLAYER_LOG_MAX_MB` / `QQPLAYER_LOG_MAX_FILES`。
//
//  约束：纯体积控制，不含任何业务判断；失败一律静默返回（诊断自身绝不拖垮主流程）。
//
// target: shared（两端都编；落点由调用方给 URL，本文件不解析平台路径）
//

import Foundation

enum LogRotation {
    /// 上限：单份大小 + 份数（份数**含当前文件**）。
    struct Limits: Equatable {
        var maxBytes: Int
        var maxFiles: Int

        /// 总预算 = 当前文件 + 全部归档。
        var totalBudgetBytes: Int { maxBytes * maxFiles }
    }

    /// 默认上限：8MB × 4 份（当前文件 + 3 份归档）。
    static let defaultMaxBytes = 8 * 1024 * 1024
    static let defaultMaxFiles = 4

    /// 既有环形截断语义（`SyncConnectDiag` / `dbDiag`：超 256KB 留尾部 64KB）——
    /// 阈值与保留量只在这里定义一份，新调用方引用这两个常量即可。
    static let ringTrimThresholdBytes = 256_000
    static let ringKeepBytes = 64_000

    /// 轮转结果（调用方通常忽略；保留可观测性给测试与诊断）。
    enum Outcome: Equatable {
        /// 未超上限，文件未动。
        case unchanged
        /// 远超总预算 → 丢历史（当前文件截空，归档一并清掉）。
        case discardedHistory(bytes: Int)
        /// 超单份上限 → 归档轮转。
        case archived(bytes: Int)
    }

    // MARK: - 上限来源（env 可临时放大）

    /// 当前上限：env `QQPLAYER_LOG_MAX_MB` / `QQPLAYER_LOG_MAX_FILES` 优先，非法值忽略。
    static func currentLimits(environment: [String: String] = ProcessInfo.processInfo.environment) -> Limits {
        let megabytes = positiveInt(environment["QQPLAYER_LOG_MAX_MB"]) ?? (defaultMaxBytes / (1024 * 1024))
        let files = positiveInt(environment["QQPLAYER_LOG_MAX_FILES"]) ?? defaultMaxFiles
        return Limits(maxBytes: megabytes * 1024 * 1024, maxFiles: files)
    }

    private static func positiveInt(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }

    // MARK: - 判定与命名（唯一实现）

    /// 归档命名：`app.log` → `app.log.1`（1 = 最新归档，数字越大越老）。
    static func archiveURL(for url: URL, index: Int) -> URL {
        URL(fileURLWithPath: url.path + ".\(index)")
    }

    /// 文件字节数（不存在/读不到 = 0）。
    static func fileSize(at url: URL, fileManager: FileManager = .default) -> Int {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else { return 0 }
        return size
    }

    /// 首次接入遇**远超总预算**的大文件（如遗留 49MB）→ 该丢历史而不是把大文件改个名
    /// （改名保留 = 磁盘仍然有界不了）。
    static func shouldDiscardHistory(
        at url: URL,
        limits: Limits,
        fileManager: FileManager = .default
    ) -> Bool {
        fileSize(at: url, fileManager: fileManager) > limits.totalBudgetBytes
    }

    // MARK: - 入口 1：归档轮转

    /// 超上限即轮转（判定 + 命名 + 归档都在这里，调用方不许自己实现）。
    ///
    /// 命名/份数规则：当前文件 → `.1`，`.1` → `.2`，……，超过份数的最老归档删除。
    /// `maxFiles` = 总份数**含当前文件**（默认 4 = 当前 + 3 份归档）。
    @discardableResult
    static func rotateIfNeeded(
        at url: URL,
        limits: Limits = currentLimits(),
        fileManager: FileManager = .default
    ) -> Outcome {
        let size = fileSize(at: url, fileManager: fileManager)
        guard size > 0 else { return .unchanged }

        // 远超总预算 → 丢历史（截空当前文件 + 清掉陈旧归档；不产生新归档）。
        if shouldDiscardHistory(at: url, limits: limits, fileManager: fileManager) {
            guard (try? Data().write(to: url, options: .atomic)) != nil else { return .unchanged }
            removeArchives(for: url, limits: limits, fileManager: fileManager)
            return .discardedHistory(bytes: size)
        }

        guard size > limits.maxBytes else { return .unchanged }

        let archiveCount = max(limits.maxFiles - 1, 0)
        guard archiveCount > 0 else {
            // 只有当前文件一份：没有归档位可退，超上限即截空。
            guard (try? Data().write(to: url, options: .atomic)) != nil else { return .unchanged }
            return .discardedHistory(bytes: size)
        }

        // 先删最老一份，再自老向新逐级改名，最后把当前文件挪成 `.1`。
        try? fileManager.removeItem(at: archiveURL(for: url, index: archiveCount))
        if archiveCount > 1 {
            for index in stride(from: archiveCount - 1, through: 1, by: -1) {
                let source = archiveURL(for: url, index: index)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try? fileManager.moveItem(at: source, to: archiveURL(for: url, index: index + 1))
            }
        }
        guard (try? fileManager.moveItem(at: url, to: archiveURL(for: url, index: 1))) != nil else {
            return .unchanged
        }
        return .archived(bytes: size)
    }

    private static func removeArchives(for url: URL, limits: Limits, fileManager: FileManager) {
        for index in stride(from: 1, through: max(limits.maxFiles - 1, 0), by: 1) {
            try? fileManager.removeItem(at: archiveURL(for: url, index: index))
        }
    }

    // MARK: - 入口 2：环形截断（保既有 256KB/64KB 语义）

    /// 超 `thresholdBytes` → 只留尾部 `keepBytes`（再追加新内容由调用方负责）。
    @discardableResult
    static func trimTailIfNeeded(
        at url: URL,
        thresholdBytes: Int = ringTrimThresholdBytes,
        keepBytes: Int = ringKeepBytes,
        fileManager: FileManager = .default
    ) -> Bool {
        let size = fileSize(at: url, fileManager: fileManager)
        guard size > thresholdBytes, keepBytes > 0, keepBytes < size else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(size - keepBytes))
        let tail = handle.readDataToEndOfFile()
        guard !tail.isEmpty, (try? tail.write(to: url, options: .atomic)) != nil else { return false }
        return true
    }
}
