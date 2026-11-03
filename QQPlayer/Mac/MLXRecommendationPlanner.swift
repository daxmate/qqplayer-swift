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
    import MLX
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
    final class MLXRecommendationPlanner: RecommendationPlanning {
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

        private func ensureContainer() async throws -> ModelContainer {
            let layout = RecommendationModelLayout(
                root: RecommendationModelLayout.defaultRoot(),
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
            let system = RecommendationPlanPrompt.system
            let user = RecommendationPlanPrompt.user(for: summary)

            return try await container.perform { context in
                let input = UserInput(chat: [.system(system), .user(user)])
                let lmInput = try await context.processor.prepare(input: input)
                var parameters = GenerateParameters(temperature: 0.3)
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
