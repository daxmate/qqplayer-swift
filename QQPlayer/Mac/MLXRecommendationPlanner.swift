//
//  MLXRecommendationPlanner.swift
//  QQPlayer
//
//  本地 AI 推荐 P2：Mac 内嵌 MLX 规划器（仅 Apple Silicon + macOS）。
//
//  链路：画像摘要 → 严格 JSON prompt → MLX 本地模型（Qwen2.5 4bit）→ 文本
//  → RecommendationPlanParser（共享层）→ [RecommendationIntent]。
//
//  - 模型容器在 `MLXRunner` actor 内串行持有；默认每次生成完卸载（释放内存）。
//  - 30s 超时；加载 / 生成 / 解析任一失败都返回空计划，由 FallbackRecommendationPlanner 回退规则。
//  - Intel Mac / 非 macOS：本文件不参与编译，工厂直接返回规则 planner。
//

#if canImport(MLXLLM) && arch(arm64) && os(macOS)

    import Foundation
    import MLXLLM
    import MLXLMCommon

    enum MLXRecommendationError: LocalizedError {
        case modelNotReady
        case timedOut
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .modelNotReady: return "本地模型文件不完整"
            case .timedOut: return "本地模型生成超时"
            case .emptyOutput: return "本地模型没有输出"
            }
        }
    }

    /// 主线程门面：设置页同步调用 `setKeepLoaded` / `unload`，重活都在 `MLXRunner` actor。
    @MainActor
    final class MLXRecommendationPlanner: RecommendationPlanning, RecommendationRequestPlanning {
        static let shared = MLXRecommendationPlanner()

        private let runner = MLXRunner()
        private var keepLoaded = false

        func setKeepLoaded(_ value: Bool) {
            keepLoaded = value
            if !value { unload() }
        }

        func unload() {
            let runner = self.runner
            Task { await runner.unload() }
        }

        func makePlan(for profile: TasteProfile) async -> RecommendationPlan {
            let summary = RecommendationProfileSummary.make(from: profile)
            guard !summary.isEmpty else {
                return RecommendationPlan(intents: [], source: .localModel)
            }

            do {
                let text = try await runner.generate(summary: summary, timeout: .seconds(30))
                guard let intents = RecommendationPlanParser.parse(text) else {
                    if !keepLoaded { unload() }
                    return RecommendationPlan(intents: [], source: .localModel)
                }
                if !keepLoaded { unload() }
                return RecommendationPlan(intents: intents, source: .localModel)
            } catch {
                AppLog.warn(.general, "⚠️ 本地模型生成失败，回退规则：\(error.localizedDescription)")
                if !keepLoaded { unload() }
                return RecommendationPlan(intents: [], source: .localModel)
            }
        }

        /// 逐曲理由（P3）：一次整批；超时 ≤20s，失败 / 校验不过返回空字典（调用方保留规则理由）。
        func reasons(for items: [RecommendationReasonItem], locale: Locale) async -> [String: [String]] {
            guard !items.isEmpty else { return [:] }

            do {
                let output = try await runner.generateReasons(
                    system: RecommendationReasonPrompt.system(locale: locale),
                    user: RecommendationReasonPrompt.user(for: items),
                    timeout: .seconds(20)
                )
                if !keepLoaded { unload() }
                return RecommendationReasonParser.parse(output, items: items)
            } catch {
                AppLog.warn(.general, "⚠️ 推荐理由模型生成失败，保留规则理由：\(error.localizedDescription)")
                if !keepLoaded { unload() }
                return [:]
            }
        }

        /// 指令输入是否可用：只看模型文件是否完整（不加载、不联网）。
        nonisolated static func isModelReady() -> Bool {
            let layout = RecommendationModelLayout.resolved(
                modelId: RecommendationModelManager.defaultModelId
            )
            let store = RecommendationModelStore(layout: layout)
            guard let manifest = store.loadManifest() else { return false }
            return store.isComplete(manifest: manifest)
        }

        /// 指令 → 结构化请求；失败必须抛出可识别错误，绝不回退规则解析。
        func makeRequest(
            text: String,
            history: [RecommendationRequestHistoryEntry],
            profile: TasteProfile
        ) async -> Result<RecommendationUserRequest, RecommendationRequestError> {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.emptyRequest) }
            let summary = RecommendationProfileSummary.make(from: profile)

            do {
                let output = try await runner.generateRequest(
                    summary: summary,
                    text: trimmed,
                    history: history,
                    timeout: .seconds(30)
                )
                if !keepLoaded { unload() }
                return RecommendationRequestParser.parse(output, rawText: trimmed)
            } catch {
                AppLog.warn(.general, "⚠️ 推荐指令模型生成失败：\(error.localizedDescription)")
                if !keepLoaded { unload() }
                guard let mlxError = error as? MLXRecommendationError else { return .failure(.invalidOutput) }
                switch mlxError {
                case .modelNotReady: return .failure(.modelNotReady)
                case .timedOut: return .failure(.timedOut)
                case .emptyOutput: return .failure(.invalidOutput)
                }
            }
        }
    }

    /// 串行持有模型容器；生成结束可立即卸载。
    actor MLXRunner {
        private var container: ModelContainer?
        private var loadedDirectory: URL?

        func unload() {
            container = nil
            loadedDirectory = nil
        }

        func generate(summary: RecommendationProfileSummary, timeout: Duration) async throws -> String {
            let container = try await ensureContainer()

            let text: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await Self.run(container: container, summary: summary)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw MLXRecommendationError.timedOut
                }
                guard let first = try await group.next() else {
                    throw MLXRecommendationError.emptyOutput
                }
                group.cancelAll()
                return first
            }

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MLXRecommendationError.emptyOutput
            }
            return text
        }

        func generateRequest(
            summary: RecommendationProfileSummary,
            text: String,
            history: [RecommendationRequestHistoryEntry],
            timeout: Duration
        ) async throws -> String {
            let container = try await ensureContainer()

            let output: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await Self.runRequest(
                        container: container,
                        summary: summary,
                        text: text,
                        history: history
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw MLXRecommendationError.timedOut
                }
                guard let first = try await group.next() else {
                    throw MLXRecommendationError.emptyOutput
                }
                group.cancelAll()
                return first
            }

            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MLXRecommendationError.emptyOutput
            }
            return output
        }

        /// 逐曲理由（P3）：**一次整批**发一次请求（不做逐曲调用）。
        func generateReasons(system: String, user: String, timeout: Duration) async throws -> String {
            let container = try await ensureContainer()

            let output: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await Self.runReasons(container: container, system: system, user: user)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw MLXRecommendationError.timedOut
                }
                guard let first = try await group.next() else {
                    throw MLXRecommendationError.emptyOutput
                }
                group.cancelAll()
                return first
            }

            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MLXRecommendationError.emptyOutput
            }
            return output
        }

        private func ensureContainer() async throws -> ModelContainer {
            let layout = RecommendationModelLayout.resolved(
                modelId: RecommendationModelManager.defaultModelId
            )
            let store = RecommendationModelStore(layout: layout)
            guard let manifest = store.loadManifest(), store.isComplete(manifest: manifest) else {
                throw MLXRecommendationError.modelNotReady
            }

            if let container, loadedDirectory == layout.directory {
                return container
            }

            let configuration = ModelConfiguration(directory: layout.directory)
            let loaded = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { _ in }
            container = loaded
            loadedDirectory = layout.directory
            return loaded
        }

        private static func run(
            container: ModelContainer,
            summary: RecommendationProfileSummary
        ) async throws -> String {
            try await runChat(
                container: container,
                system: RecommendationPlanPrompt.system,
                user: RecommendationPlanPrompt.user(for: summary),
                temperature: 0.3
            )
        }

        private static func runRequest(
            container: ModelContainer,
            summary: RecommendationProfileSummary,
            text: String,
            history: [RecommendationRequestHistoryEntry]
        ) async throws -> String {
            try await runChat(
                container: container,
                system: RecommendationPlanPrompt.requestSystem,
                user: RecommendationPlanPrompt.requestUser(for: summary, requestText: text, history: history),
                temperature: 0.2
            )
        }

        /// 逐曲理由：system + user 直接给（P3；一次整批）。
        private static func runReasons(
            container: ModelContainer,
            system: String,
            user: String
        ) async throws -> String {
            try await runChat(
                container: container,
                system: system,
                user: user,
                temperature: 0.2
            )
        }

        /// 规划器 / 指令输入共用的单次生成（同一套推理栈，不复制第二套）。
        private static func runChat(
            container: ModelContainer,
            system: String,
            user: String,
            temperature: Float
        ) async throws -> String {
            try await container.perform { context in
                let input = UserInput(chat: [.system(system), .user(user)])
                let lmInput = try await context.processor.prepare(input: input)
                var parameters = GenerateParameters(temperature: temperature)
                parameters.maxTokens = 512

                var output = ""
                let stream = try MLXLMCommon.generate(
                    input: lmInput,
                    parameters: parameters,
                    context: context
                )
                for await generation in stream {
                    if case let .chunk(text) = generation {
                        output += text
                    }
                }
                return output
            }
        }
    }

#endif
