//
//  RecommendationModelManager.swift
//  QQPlayer
//
//  本地 AI 推荐 P2：模型文件管理（下载 / 续传 / 校验 / 删除 / 状态机）。
//
//  模型不进 bundle、不进仓库：全部文件从 hf-mirror.com 下载到
//  `Application Support/QQPlayer/RecommendationModels/<modelId>/`。
//
//  - 清单：运行时请求 hf-mirror 的仓库 API，只取推理必需文件（config / tokenizer / 权重）。
//  - 下载：逐个文件、支持 Range 断点续传、进度回调、失败重试 1 次、可取消。
//  - 校验：文件齐全 + 每个文件大小 == 清单大小（且 > 0）。
//  - 删除：整目录移除（可恢复性由用户确认后触发，不在本层做 UI 询问）。
//
//  ⚠️ 纯 Foundation + Observation，iOS / macOS 共享（实际只在 macOS 使用）。
//

import Foundation
import Observation

// MARK: - 清单

/// 单个模型文件（大小来自 hf-mirror 仓库 API；缺失时为 nil）。
struct RecommendationModelFile: Sendable, Equatable, Codable {
    var name: String
    var size: Int?
}

/// 模型清单（持久化为目录内的 manifest.json）。
struct RecommendationModelManifest: Sendable, Equatable, Codable {
    var id: String
    var files: [RecommendationModelFile]

    var totalBytes: Int {
        files.reduce(0) { $0 + ($1.size ?? 0) }
    }

    /// 推理必需文件的最小集合（缺一个就不算 ready）。
    var hasRequiredFiles: Bool {
        let names = Set(files.map(\.name))
        let hasConfig = names.contains("config.json")
        let hasTokenizer = names.contains("tokenizer.json") || names.contains("tokenizer.model")
        let hasWeights = names.contains { $0.hasSuffix(".safetensors") }
        return hasConfig && hasTokenizer && hasWeights
    }
}

enum RecommendationModelManifestParser {
    /// 必须参与校验的固定文件名（存在才下载；不强制全部存在）。
    static let fixedNames: Set<String> = [
        "config.json",
        "tokenizer.json",
        "tokenizer.model",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "generation_config.json",
        "chat_template.jinja",
        "quantize_config.json",
    ]

    private struct Payload: Decodable {
        struct Sibling: Decodable {
            var rfilename: String
            var size: Int?
        }
        var siblings: [Sibling]?
    }

    /// 解析 hf-mirror 仓库 API；只保留推理必需文件（固定名 + safetensors / index）。
    static func parse(_ data: Data, modelId: String) -> RecommendationModelManifest? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let siblings = payload.siblings else { return nil }

        var files: [RecommendationModelFile] = []
        for sibling in siblings {
            let name = sibling.rfilename
            guard isRequired(name: name) else { continue }
            files.append(RecommendationModelFile(name: name, size: sibling.size))
        }

        guard let manifest = Optional(RecommendationModelManifest(id: modelId, files: files)),
              manifest.hasRequiredFiles else { return nil }
        return manifest
    }

    static func isRequired(name: String) -> Bool {
        if fixedNames.contains(name) { return true }
        if name.hasSuffix(".safetensors") { return true }
        if name.hasSuffix(".safetensors.index.json") { return true }
        return false
    }
}

// MARK: - 目录

/// 模型目录布局（可注入 root，测试用临时目录）。
struct RecommendationModelLayout: Sendable, Equatable {
    var root: URL
    var modelId: String

    /// `Application Support/QQPlayer/RecommendationModels`。
    static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("QQPlayer", isDirectory: true)
            .appendingPathComponent("RecommendationModels", isDirectory: true)
    }

    /// 目录名只保留安全字符（repo id 里的 `/` 不能进路径）。
    static func sanitize(modelId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        var name = ""
        for scalar in modelId.unicodeScalars {
            name.append(allowed.contains(scalar) ? Character(scalar) : "-")
        }
        return name.isEmpty ? "model" : name
    }

    var directory: URL {
        root.appendingPathComponent(Self.sanitize(modelId: modelId), isDirectory: true)
    }

    var manifestURL: URL {
        directory.appendingPathComponent("manifest.json")
    }

    func fileURL(named name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}

// MARK: - 校验

struct RecommendationModelStore: Sendable {
    var layout: RecommendationModelLayout

    /// 目录内是否已有完整模型（清单里的文件全部存在且大小一致、> 0）。
    func isComplete(manifest: RecommendationModelManifest) -> Bool {
        guard manifest.hasRequiredFiles else { return false }
        for file in manifest.files {
            let url = layout.fileURL(named: file.name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int,
                  size > 0 else { return false }
            if let expected = file.size, size != expected { return false }
        }
        return true
    }

    /// 读取目录内持久化的清单。
    func loadManifest() -> RecommendationModelManifest? {
        guard let data = try? Data(contentsOf: layout.manifestURL) else { return nil }
        return try? JSONDecoder().decode(RecommendationModelManifest.self, from: data)
    }

    func saveManifest(_ manifest: RecommendationModelManifest) throws {
        try FileManager.default.createDirectory(at: layout.directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: layout.manifestURL, options: .atomic)
    }

    /// 删除整个模型目录。
    func delete() throws {
        guard FileManager.default.fileExists(atPath: layout.directory.path) else { return }
        try FileManager.default.removeItem(at: layout.directory)
    }

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: layout.directory, withIntermediateDirectories: true)
    }
}

// MARK: - 状态

enum RecommendationModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case loading
    case failed(String)
}

// MARK: - 下载器

protocol RecommendationModelDownloading: Sendable {
    func fetchManifest(modelId: String) async throws -> RecommendationModelManifest
    func download(
        file: RecommendationModelFile,
        modelId: String,
        to url: URL,
        onProgress: @Sendable (Int) -> Void
    ) async throws
}

enum RecommendationModelDownloadError: LocalizedError {
    case badStatus(Int)
    case incomplete(expected: Int, actual: Int)
    case manifestUnavailable

    var errorDescription: String? {
        switch self {
        case let .badStatus(code): return "HTTP \(code)"
        case let .incomplete(expected, actual): return "文件不完整（期望 \(expected) 字节，实际 \(actual)）"
        case .manifestUnavailable: return "无法获取模型文件清单"
        }
    }
}

/// 基于 URLSession 的 hf-mirror 下载器（逐文件、Range 续传、失败重试 1 次）。
struct HFMirrorModelDownloader: RecommendationModelDownloading {
    static let baseURL = URL(string: "https://hf-mirror.com")!

    var session: URLSession = .shared

    func fetchManifest(modelId: String) async throws -> RecommendationModelManifest {
        let url = Self.baseURL.appendingPathComponent("api/models/\(modelId)")
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RecommendationModelDownloadError.manifestUnavailable
        }
        guard let manifest = RecommendationModelManifestParser.parse(data, modelId: modelId) else {
            throw RecommendationModelDownloadError.manifestUnavailable
        }
        return manifest
    }

    func download(
        file: RecommendationModelFile,
        modelId: String,
        to url: URL,
        onProgress: @Sendable (Int) -> Void
    ) async throws {
        try await attempt(file: file, modelId: modelId, to: url, onProgress: onProgress)
    }

    static func fileURL(modelId: String, name: String) -> URL {
        var url = baseURL.appendingPathComponent(modelId)
        url.appendPathComponent("resolve")
        url.appendPathComponent("main")
        for component in name.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func attempt(
        file: RecommendationModelFile,
        modelId: String,
        to url: URL,
        onProgress: @Sendable (Int) -> Void
    ) async throws {
        var existing = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int {
            existing = size
        }
        if let expected = file.size, existing == expected, existing > 0 { return }

        var request = URLRequest(url: Self.fileURL(modelId: modelId, name: file.name))
        request.timeoutInterval = 120
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RecommendationModelDownloadError.badStatus(-1)
        }
        if http.statusCode == 416 {
            // 已完整（或 Range 越界）：按大小复核。
            if let expected = file.size, existing == expected { return }
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw RecommendationModelDownloadError.badStatus(http.statusCode)
        }
        if http.statusCode == 200, existing > 0 {
            // 服务端不支持续传：从头写。
            try? FileManager.default.removeItem(at: url)
            existing = 0
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var written = existing
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                onProgress(written)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += buffer.count
            onProgress(written)
        }

        if let expected = file.size, written != expected {
            throw RecommendationModelDownloadError.incomplete(expected: expected, actual: written)
        }
    }
}

// MARK: - 管理

/// 模型生命周期管理（@MainActor：UI 直接观察状态；耗时 IO 在后台）。
@MainActor
@Observable
final class RecommendationModelManager {
    /// hf-mirror 实测：`Qwen2.5-4B-Instruct-4bit` 为 404，改用最近的 4bit MLX 指令模型 3B。
    nonisolated static let defaultModelId = "mlx-community/Qwen2.5-3B-Instruct-4bit"

    private(set) var state: RecommendationModelState = .notDownloaded
    private(set) var progress: Double = 0
    private(set) var modelId: String
    private(set) var manifest: RecommendationModelManifest?

    private let layout: RecommendationModelLayout
    private let downloader: any RecommendationModelDownloading
    private var downloadTask: Task<Void, Never>?

    init(
        modelId: String = RecommendationModelManager.defaultModelId,
        layout: RecommendationModelLayout? = nil,
        downloader: any RecommendationModelDownloading = HFMirrorModelDownloader()
    ) {
        self.modelId = modelId
        self.layout = layout ?? RecommendationModelLayout(root: RecommendationModelLayout.defaultRoot(), modelId: modelId)
        self.downloader = downloader
        self.manifest = RecommendationModelStore(layout: self.layout).loadManifest()
        refreshState()
    }

    var directory: URL { layout.directory }

    var store: RecommendationModelStore { RecommendationModelStore(layout: layout) }

    var totalBytes: Int { manifest?.totalBytes ?? 0 }

    /// 重新计算状态（不触发网络）。
    func refreshState() {
        guard let manifest else {
            state = .notDownloaded
            return
        }
        state = store.isComplete(manifest: manifest) ? .ready : .notDownloaded
    }

    /// 下载（可重复调用；已在下载中则忽略）。失败重试 1 次/文件。
    func download() {
        guard downloadTask == nil else { return }
        downloadTask = Task { [weak self] in
            await self?.runDownload()
            self?.downloadTask = nil
        }
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        refreshState()
    }

    func delete() async {
        downloadTask?.cancel()
        downloadTask = nil
        let store = store
        await Task.detached(priority: .utility) {
            try? store.delete()
        }.value
        manifest = nil
        progress = 0
        state = .notDownloaded
    }

    /// 模型已加载 / 已卸载（由 MLX planner 调用）。
    func markLoaded(_ loaded: Bool) {
        if loaded {
            if state == .ready { state = .loading }
        } else {
            refreshState()
        }
    }

    private func runDownload() async {
        state = .downloading(progress: 0)
        progress = 0
        do {
            let fetched = try await downloader.fetchManifest(modelId: modelId)
            manifest = fetched
            try store.saveManifest(fetched)
            try store.ensureDirectory()
            let total = max(1, fetched.totalBytes)
            var completed = 0

            for file in fetched.files {
                try Task.checkCancellation()
                let url = layout.fileURL(named: file.name)
                try await downloadWithRetry(file: file, to: url, completed: completed, total: total)
                completed += file.size ?? 0
                let value = min(1, Double(completed) / Double(total))
                progress = value
                state = .downloading(progress: value)
            }

            guard store.isComplete(manifest: fetched) else {
                throw RecommendationModelDownloadError.manifestUnavailable
            }
            state = .ready
        } catch is CancellationError {
            refreshState()
        } catch {
            AppLog.error(.general, "❌ 推荐模型下载失败：\(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    private func downloadWithRetry(
        file: RecommendationModelFile,
        to url: URL,
        completed: Int,
        total: Int
    ) async throws {
        var lastError: Error?
        for attempt in 0 ..< 2 {
            do {
                try await downloader.download(file: file, modelId: modelId, to: url) { written in
                    let value = min(1, Double(completed + written) / Double(total))
                    Task { @MainActor in
                        self.progress = value
                        self.state = .downloading(progress: value)
                    }
                }
                return
            } catch {
                lastError = error
                if attempt == 0 {
                    AppLog.warn(.general, "⚠️ 推荐模型文件下载失败，重试一次：\(file.name)")
                }
            }
        }
        throw lastError ?? RecommendationModelDownloadError.manifestUnavailable
    }
}
