//
//  AppLog.swift
//  QQPlayer
//
//  **唯一**的结构化日志出口（2026-09-20 立，日志治理批 1 地基）。
//
//  设计源：`tmp/docs/logging.md` §一 / §二。为什么立这个入口：诊断日志此前基本靠 `print()`
//  落到 `~/Library/Logs/QQPlayerMac/stdout.log`，该文件一度涨到 49MB 且没有任何轮转
//  —— 排查同步问题时只能 grep 一个巨型文件。AppLog 把「级别 / 分类 / 行格式 / 落点 / 上限」
//  收成一处：新写的诊断输出都从这里走（存量 print 属后续批次，本批不动）。
//
//  行格式（一行一记录，消息内换行折叠成 `⏎`，emoji 标记保留便于沿用老 grep 习惯）：
//    [2026-09-19T00:21:33Z] [WARN] [db] ⚠️ 打开失败 error=disk full
//
//  扇出两个 sink（实现**只允许写在本文件内**，形状守卫见
//  `QQPlayerTests/AppLogShapeContractTests.swift`）：
//    ① `os.Logger`（subsystem `com.daxmate.qqplayer`，category = 分类）→ `log show` 结构化过滤
//    ② 轮转文件 `app.log`
//
//  阈值优先级（高 → 低）：env `QQPLAYER_LOG_LEVEL` → UserDefaults `qqplayer.log.level`
//  → 构建默认（Debug = debug / Release = info）。
//
//  体积控制**全部**委托 `LogRotation`（初始化 + 每次写入的封顶都调它）——
//  本文件不自己判上限、不自己命名归档（同一语义只有一处实现）。
//
//  用法：
//    AppLog.warn(.db, "⚠️ 打开失败 error=\(error)")
//    if AppLog.isEnabled(.debug, .transfer) { … }          // 昂贵消息先短路
//    AppLog.debug(.transfer, "\(expensiveDescription())")  // @autoclosure：被滤掉时零成本
//
// target: shared（两端都编：macOS `~/Library/Logs/QQPlayerMac/app.log`；iOS 容器 `Documents/app.log`）
//

import Foundation
import os

// MARK: - 级别与分类

enum AppLogLevel: String, Comparable, CaseIterable {
    case debug
    case info
    case warn
    case error

    /// 行内标签（`[WARN]`）。
    var label: String { rawValue.uppercased() }

    /// 大小写不敏感解析（env / UserDefaults 里写 `warn`、`WARN` 都认；非法值 = nil）。
    static func parse(_ raw: String) -> AppLogLevel? {
        AppLogLevel(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private var severity: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warn: 2
        case .error: 3
        }
    }

    static func < (lhs: AppLogLevel, rhs: AppLogLevel) -> Bool {
        lhs.severity < rhs.severity
    }

    /// `os.Logger` 侧级别（分级过滤在系统日志通道同样生效）。
    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warn: .default
        case .error: .error
        }
    }
}

enum AppLogCategory: String, CaseIterable {
    case sync
    case transfer
    case migration
    case db
    case scrape
    case ui
    case general
}

// MARK: - 落点抽象

/// 日志落点。**实现只允许写在 `AppLog.swift` 内**（形状守卫 ①）——
/// 多一个实现 = 「同一语义第二处手工维护」，改行格式/落点要改多处。
protocol AppLogSink: Sendable {
    func write(line: String, level: AppLogLevel, category: AppLogCategory)
}

// MARK: - 唯一出口

enum AppLog {
    /// 系统日志通道标识（`log show --predicate 'subsystem == "com.daxmate.qqplayer"'`）。
    static let subsystem = "com.daxmate.qqplayer"
    static let levelEnvironmentKey = "QQPLAYER_LOG_LEVEL"
    static let levelDefaultsKey = "qqplayer.log.level"

    /// 构建默认阈值（Debug = debug / Release = info）。
    static var buildDefaultLevel: AppLogLevel {
        #if DEBUG
            .debug
        #else
            .info
        #endif
    }

    /// 阈值解析（**唯一实现**，纯函数便于自证）：env → UserDefaults → 构建默认。
    /// 不做缓存：诊断场景下「改了 env / 默认值立刻生效」比省一次字典查询重要
    /// （本入口本就不进热路径，见设计源 §一）。
    static func resolveLevel(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultsValue: String? = UserDefaults.standard.string(forKey: levelDefaultsKey),
        buildDefault: AppLogLevel = AppLog.buildDefaultLevel
    ) -> AppLogLevel {
        if let raw = environment[levelEnvironmentKey], let level = AppLogLevel.parse(raw) {
            return level
        }
        if let raw = defaultsValue, let level = AppLogLevel.parse(raw) {
            return level
        }
        return buildDefault
    }

    /// 当前生效阈值。
    static var threshold: AppLogLevel { resolveLevel() }

    /// 该级别/分类当前是否落盘——昂贵消息的短路判断（`isEnabled` 为 false 时**不要**求值消息）。
    /// 分类维度暂无按分类差异化阈值；参数保留是为了调用点形状稳定（未来加分类阈值不动调用方）。
    static func isEnabled(_ level: AppLogLevel, _ category: AppLogCategory) -> Bool {
        _ = category
        return level >= threshold
    }

    // MARK: 写入口

    static func debug(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        log(.debug, category, message())
    }

    static func info(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        log(.info, category, message())
    }

    static func warn(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        log(.warn, category, message())
    }

    static func error(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        log(.error, category, message())
    }

    /// 唯一写入路径：先按阈值短路（消息此时**尚未求值** → 被滤掉时零成本），再扇出到各 sink。
    static func log(_ level: AppLogLevel, _ category: AppLogCategory, _ message: @autoclosure () -> String) {
        guard level >= threshold else { return }
        bootstrapIfNeeded()
        let line = formatLine(timestamp: Date(), level: level, category: category, message: message()) + "\n"
        for sink in sinks {
            sink.write(line: line, level: level, category: category)
        }
    }

    // MARK: 行格式

    /// 行格式（**唯一实现**，一行一记录）：`[时间] [级别] [分类] 消息`。
    static func formatLine(
        timestamp: Date,
        level: AppLogLevel,
        category: AppLogCategory,
        message: String
    ) -> String {
        "[\(timestampString(timestamp))] [\(level.label)] [\(category.rawValue)] \(foldNewlines(message))"
    }

    /// 消息内换行折叠为 `⏎`（一行一记录：多行消息不能把文件行数打乱）。
    static func foldNewlines(_ message: String) -> String {
        message
            .replacingOccurrences(of: "\r\n", with: "⏎")
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\r", with: "⏎")
    }

    /// UTC ISO8601（秒级）：`2026-09-19T00:21:33Z`。
    static func timestampString(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private static let timestampFormatter = TimestampFormatter()

    // MARK: 落点

    /// 落点覆盖（测试注入；默认 nil ⇒ 平台默认落点）。与 `SyncConnectDiag.logFileURLOverride`
    /// 同款：只由测试在用例内写入（串行用例 + 结束即复原），生产只读。
    nonisolated(unsafe) static var logFileURLOverride: URL?

    /// 落点（唯一出口）：macOS `~/Library/Logs/QQPlayerMac/app.log`；iOS 容器 `Documents/app.log`。
    static func logFileURL(fileManager: FileManager = .default) -> URL? {
        if let logFileURLOverride { return logFileURLOverride }
        #if os(macOS)
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/QQPlayerMac", isDirectory: true)
                .appendingPathComponent("app.log", isDirectory: false)
        #else
            return fileManager.urls(for: .documentDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("app.log", isDirectory: false)
        #endif
    }

    // MARK: sink 装配

    /// 双 sink 扇出（顺序即写入顺序，文件 sink 自带锁串行化）。
    static let sinks: [any AppLogSink] = [
        OSLogSink(),
        RotatingFileSink(limits: RotatingFileSink.limits),
    ]

    private static let bootstrapLock = NSLock()
    nonisolated(unsafe) private static var didBootstrap = false

    /// 初始化：落点目录就绪 + 首次接入的体积收敛（文件远超总预算 → 丢历史）。
    /// 体积判定与动作**全部**走 `LogRotation`（本文件不自己判上限）。
    static func bootstrapIfNeeded() {
        bootstrapLock.lock()
        let alreadyDone = didBootstrap
        didBootstrap = true
        bootstrapLock.unlock()
        guard !alreadyDone, let url = logFileURL() else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        LogRotation.rotateIfNeeded(at: url, limits: RotatingFileSink.limits, fileManager: fileManager)
    }
}

// MARK: - sink ①：系统日志

/// `os.Logger` 落点：subsystem + category 可结构化过滤（`log show --predicate …`）。
/// 系统日志通道自身也带体积策略，故这里只负责转发。
struct OSLogSink: AppLogSink {
    func write(line: String, level: AppLogLevel, category: AppLogCategory) {
        Self.loggers[category]?.log(level: level.osLogType, "\(line, privacy: .public)")
    }

    /// 分类 → Logger（分类枚举是唯一来源，改分类只改 `AppLogCategory`）。
    private static let loggers: [AppLogCategory: Logger] = {
        var result: [AppLogCategory: Logger] = [:]
        for category in AppLogCategory.allCases {
            result[category] = Logger(subsystem: AppLog.subsystem, category: category.rawValue)
        }
        return result
    }()
}

// MARK: - sink ②：轮转文件

/// 轮转文件落点（`app.log`）。**体积控制全部委托 `LogRotation`**：初始化与每次写入的封顶
/// 都调它，本文件不另写一套上限判定/归档命名（形状守卫 ② 的调用点白名单里只留本文件）。
struct RotatingFileSink: AppLogSink {
    let limits: LogRotation.Limits

    static let limits = LogRotation.currentLimits()

    func write(line: String, level: AppLogLevel, category: AppLogCategory) {
        guard let url = AppLog.logFileURL(), let data = line.data(using: .utf8) else { return }
        let fileManager = FileManager.default
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // 每次写入的封顶：超 8MB（可被 env 放大）即归档轮转 / 丢历史。
        LogRotation.rotateIfNeeded(at: url, limits: limits, fileManager: fileManager)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            // 文件不存在（如刚被轮转走）→ 直接落盘创建。
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let writeLock = NSLock()
}

// MARK: - 时间戳（线程安全的既有 formatter 复用）

/// `ISO8601DateFormatter` 非 `Sendable`，这里用锁包一层复用同一实例（每行新建 formatter 代价过高）。
private final class TimestampFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    init() {
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}
