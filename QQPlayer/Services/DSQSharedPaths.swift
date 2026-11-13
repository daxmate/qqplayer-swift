//
//  DSQSharedPaths.swift
//  QQPlayer
//
//  三个 macOS App（QQPlayer / DDReader / SSTypist）共享资源目录的**唯一解析层**。
//
//  背景（2026-11-04）：DDReader / SSTypist 要上 Mac App Store，必须开 App Sandbox，
//  只能访问 App Group 容器；QQPlayer Mac 走 Developer ID 直发，保持非沙盒。三者需要
//  共享同一批资源（Books / Dictionaries / Audiobooks / Models）。
//
//  根目录优先级（**只有本文件允许出现 Group Containers 字面量**）：
//   1. 环境变量 `DSQ_SHARED_ROOT`（测试 / 开发）
//   2. App Group 容器 `B6FA37AYT5.dsqcommon/DSQ Common Resources`（沙盒 App）
//   3. 非沙盒且该 Group 容器目录已存在（DDReader 建过）→ 直接使用
//   4. 兜底 `<Application Support>/DSQ Common Resources`
//
//  布局：`<root>/{Models,Books,Dictionaries,Audiobooks}`；目录按需创建（幂等）。
//  本文件只做路径解析，不碰业务语义；日志由 `DSQShared.swift` 统一出口。
//

import Foundation

// MARK: - 解析来源

/// 根目录实际走的分支（日志 / 测试断言用）。
enum DSQSharedSource: String, Sendable {
    case environment
    case appGroupContainer = "app-group-container"
    case groupContainerDirectory = "group-container-directory"
    case applicationSupport = "application-support"
}

// MARK: - 解析结果

/// 共享资源根与四个子目录。
///
/// 调用方**解析一次、复用结果**（每次 `DSQShared.resolve()` 都会记一条日志）。
struct DSQSharedLocations: Equatable, Sendable {
    static let rootDirectoryName = "DSQ Common Resources"
    static let appGroupIdentifier = "B6FA37AYT5.dsqcommon"
    static let environmentKey = "DSQ_SHARED_ROOT"

    static let modelsDirectoryName = "Models"
    static let booksDirectoryName = "Books"
    static let dictionariesDirectoryName = "Dictionaries"
    static let audiobooksDirectoryName = "Audiobooks"

    let root: URL
    let source: DSQSharedSource
    /// 非首选分支的原因（仅回落时填写，用于日志排查；正常路径为 nil）。
    let fallbackNote: String?

    init(root: URL, source: DSQSharedSource, fallbackNote: String? = nil) {
        self.root = root
        self.source = source
        self.fallbackNote = fallbackNote
    }

    var modelsRoot: URL { child(Self.modelsDirectoryName) }
    var booksRoot: URL { child(Self.booksDirectoryName) }
    var dictionariesRoot: URL { child(Self.dictionariesDirectoryName) }
    var audiobooksRoot: URL { child(Self.audiobooksDirectoryName) }

    /// 模型版本目录：`<modelsRoot>/<kind>/<modelID>/<version>/`。
    func modelDirectory(kind: String, modelID: String, version: String) -> URL {
        modelsRoot
            .appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    /// 按需创建根与四个子目录（幂等）。
    func ensureDirectories(fileManager: FileManager = .default) throws {
        for directory in [root, modelsRoot, booksRoot, dictionariesRoot, audiobooksRoot] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func child(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }
}

// MARK: - 解析器

/// 路径解析器。所有外部依赖（环境变量 / 容器 / home / 文件系统）都可注入，便于无模拟器测试。
struct DSQSharedResolver {
    var environment: [String: String]
    var fileManager: FileManager
    var homeDirectory: URL
    var isSandboxed: Bool
    var containerURL: (String) -> URL?
    var applicationSupportDirectory: () -> URL

    init(
        environment: [String: String]? = nil,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        isSandboxed: Bool? = nil,
        containerURL: ((String) -> URL?)? = nil,
        applicationSupportDirectory: (() -> URL)? = nil
    ) {
        let environment = environment ?? ProcessInfo.processInfo.environment
        self.environment = environment
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory ?? UserHomeDirectory.realHomeURL
        self.isSandboxed = isSandboxed ?? Self.detectSandbox(environment: environment)
        self.containerURL = containerURL ?? { identifier in
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        }
        self.applicationSupportDirectory = applicationSupportDirectory ?? {
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
        }
    }

    func resolve() -> DSQSharedLocations {
        if let raw = environment[DSQSharedLocations.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty {
            return DSQSharedLocations(
                root: Self.url(from: raw),
                source: .environment
            )
        }

        // App Group 容器路径“存在”不等于“能写”：ad-hoc / 未授权的签名也能拿到路径，
        // 真正落盘时才 EPERM。因此每个候选都要做一次写入探测，失败才继续回落。
        var fallbackNotes: [String] = []

        if let container = containerURL(DSQSharedLocations.appGroupIdentifier) {
            let root = container.appendingPathComponent(
                DSQSharedLocations.rootDirectoryName,
                isDirectory: true
            )
            if let failure = Self.writeProbeFailure(in: root, fileManager: fileManager) {
                fallbackNotes.append("App Group 容器不可写（\(failure)）")
            } else {
                return DSQSharedLocations(root: root, source: .appGroupContainer)
            }
        }

        if !isSandboxed {
            let groupRoot = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Group Containers", isDirectory: true)
                .appendingPathComponent(DSQSharedLocations.appGroupIdentifier, isDirectory: true)
                .appendingPathComponent(DSQSharedLocations.rootDirectoryName, isDirectory: true)
            if isDirectory(groupRoot) {
                if let failure = Self.writeProbeFailure(in: groupRoot, fileManager: fileManager) {
                    fallbackNotes.append("Group Containers 目录不可写（\(failure)）")
                } else {
                    return DSQSharedLocations(root: groupRoot, source: .groupContainerDirectory)
                }
            }
        }

        let base = applicationSupportDirectory()
        return DSQSharedLocations(
            root: base.appendingPathComponent(DSQSharedLocations.rootDirectoryName, isDirectory: true),
            source: .applicationSupport,
            fallbackNote: fallbackNotes.isEmpty ? nil : fallbackNotes.joined(separator: "；")
        )
    }

    /// 写入探测：能建目录并落一个临时文件才算可用；返回 nil 表示可写，否则返回失败原因。
    static func writeProbeFailure(in directory: URL, fileManager: FileManager) -> String? {
        let probe = directory.appendingPathComponent(".dsq-write-probe-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("probe".utf8).write(to: probe, options: .atomic)
            try? fileManager.removeItem(at: probe)
            return nil
        } catch {
            try? fileManager.removeItem(at: probe)
            return error.localizedDescription
        }
    }

    /// 沙盒判定：`APP_SANDBOX_CONTAINER_ID` 由沙盒进程注入；home 路径兜底。
    static func detectSandbox(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return true
        }
        return NSHomeDirectory().contains("/Library/Containers/")
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func url(from raw: String) -> URL {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
    }
}

// MARK: - 模型目录约定

/// 跨 App 共享的模型目录命名约定（QQPlayer 目前只有推荐模型）。
enum DSQSharedModelCatalog {
    /// 模型 kind 目录名（仅旧目录迁移兼容；v3 起 App 不再下载模型）。
    static let recommendationKind = "Recommendation"
    /// 当前模型目录布局版本。
    static let currentVersion = "v1"
    /// QQPlayer 旧 App 目录名（仅迁移 / 只读兼容使用）。
    static let legacyAppDirectoryName = "QQPlayer"
    /// QQPlayer 旧模型目录名（仅迁移 / 只读兼容使用）。
    static let legacyModelsDirectoryName = "RecommendationModels"
}

/// 旧路径的唯一构造入口（迁移器与只读兼容共用，避免两处手拼）。
enum DSQSharedLegacyPaths {
    /// `<Application Support>/DSQ Common Resources`。
    static func resourcesRoot(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(DSQSharedLocations.rootDirectoryName, isDirectory: true)
    }

    /// `<Application Support>/QQPlayer/RecommendationModels`。
    static func recommendationModelsRoot(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent(DSQSharedModelCatalog.legacyAppDirectoryName, isDirectory: true)
            .appendingPathComponent(DSQSharedModelCatalog.legacyModelsDirectoryName, isDirectory: true)
    }
}
