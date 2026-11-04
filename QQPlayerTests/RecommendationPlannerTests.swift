//
//  RecommendationPlannerTests.swift
//  QQPlayerTests
//
//  本地 AI 推荐 P2 纯逻辑单测：prompt / JSON 解析 / 回退 / 模型文件管理。
//
//  只测共享层（`QQPlayer/Services/Recommendation*.swift`）：iOS 单测 target 编不到
//  `QQPlayer/Mac/**`（MLX 规划器由编译 + 人工验收覆盖）。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - Prompt

@Suite("RecommendationPlanPrompt")
struct RecommendationPlanPromptTests {
    private func summary() -> RecommendationProfileSummary {
        RecommendationProfileSummary(
            topArtists: ["宇多田ヒカル", "陈奕迅"],
            decades: [(decade: 1990, share: 0.42), (decade: 2000, share: 0.25)],
            genres: ["粤语流行", "J-Pop"],
            completionRate: 0.78,
            librarySize: 321,
            languageHints: RecommendationProfileSummary.detectLanguages(in: ["粤语流行", "J-Pop"])
        )
    }

    @Test("system prompt 声明 JSON 契约与字段限制")
    func systemPromptContract() {
        let text = RecommendationPlanPrompt.system
        #expect(text.contains("queries"))
        #expect(text.contains("artist|decade|genre"))
        #expect(text.contains("40"))
        #expect(text.contains("12"))
        #expect(text.contains("JSON only"))
    }

    @Test("user prompt 含全部画像字段")
    func userPromptCarriesProfile() {
        let text = RecommendationPlanPrompt.user(for: summary())
        #expect(text.contains("宇多田ヒカル"))
        #expect(text.contains("陈奕迅"))
        #expect(text.contains("1990s 42%"))
        #expect(text.contains("2000s 25%"))
        #expect(text.contains("粤语流行"))
        #expect(text.contains("78%"))
        #expect(text.contains("321"))
        #expect(text.contains("Cantonese"))
        #expect(text.contains("Japanese"))
    }

    @Test("user prompt 不泄漏路径 / 数据库细节")
    func userPromptHasNoPaths() {
        let text = RecommendationPlanPrompt.user(for: summary())
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("Application Support"))
        #expect(!text.contains(".sqlite"))
        #expect(!text.contains("file://"))
    }

    @Test("空画像用明确占位，不编造数据")
    func emptyProfilePlaceholders() {
        let text = RecommendationPlanPrompt.user(for: .make(from: TasteProfile()))
        #expect(text.contains("(none)"))
        #expect(text.contains("(unknown)"))
        #expect(text.contains("0%"))
    }
}

// MARK: - 解析

@Suite("RecommendationPlanParser")
struct RecommendationPlanParserTests {
    @Test("合法 JSON：字段完整")
    func validJSON() throws {
        let output = """
        {"queries":[{"query":"陈奕迅","kind":"artist"},{"query":"1990s","kind":"decade"},{"query":"City Pop","kind":"genre"}]}
        """
        let intents = try #require(RecommendationPlanParser.parse(output))
        #expect(intents.count == 3)
        #expect(intents[0].query == "陈奕迅")
        #expect(intents[0].kind == .artist)
        #expect(intents[1].kind == .decade)
        #expect(intents[2].kind == .genre)
    }

    @Test("容忍代码围栏")
    func codeFence() throws {
        let output = """
        Here you go:
        ```json
        {"queries":[{"query":"周杰伦","kind":"artist"}]}
        ```
        """
        let intents = try #require(RecommendationPlanParser.parse(output))
        #expect(intents.count == 1)
        #expect(intents[0].query == "周杰伦")
    }

    @Test("容忍前后多余文字")
    func extraText() throws {
        let output = "Sure! {\"queries\":[{\"query\":\"Jazz\",\"kind\":\"genre\"}]} hope this helps"
        let intents = try #require(RecommendationPlanParser.parse(output))
        #expect(intents.count == 1)
        #expect(intents[0].query == "Jazz")
    }

    @Test("非法 JSON / 空输出 / 空数组 → nil")
    func invalidOutputs() {
        #expect(RecommendationPlanParser.parse("not json at all") == nil)
        #expect(RecommendationPlanParser.parse("") == nil)
        #expect(RecommendationPlanParser.parse("{\"queries\":[]}") == nil)
        #expect(RecommendationPlanParser.parse("{\"queries\":{}}") == nil)
    }

    @Test("超长 query 丢弃，剩余保留")
    func longQueryDropped() throws {
        let long = String(repeating: "a", count: 41)
        let output = "{\"queries\":[{\"query\":\"\(long)\",\"kind\":\"artist\"},{\"query\":\"OK\",\"kind\":\"artist\"}]}"
        let intents = try #require(RecommendationPlanParser.parse(output))
        #expect(intents.count == 1)
        #expect(intents[0].query == "OK")
    }

    @Test("重复 query 去重（大小写不敏感）")
    func dedupe() throws {
        let output = """
        {"queries":[{"query":"Adele","kind":"artist"},{"query":"adele","kind":"artist"},{"query":" Adele ","kind":"artist"}]}
        """
        let intents = try #require(RecommendationPlanParser.parse(output))
        #expect(intents.count == 1)
        #expect(intents[0].query == "Adele")
    }

    @Test("超过 12 条截断到 12")
    func capsAtTwelve() throws {
        let items = (0 ..< 20).map { "{\"query\":\"q\($0)\",\"kind\":\"artist\"}" }.joined(separator: ",")
        let intents = try #require(RecommendationPlanParser.parse("{\"queries\":[\(items)]}"))
        #expect(intents.count == RecommendationPlanParser.maxIntents)
    }

    @Test("未知 kind / 空白 query 丢弃")
    func dropsInvalidKindAndBlank() throws {
        let output = """
        {"queries":[{"query":"ok","kind":"artist"},{"query":"x","kind":"mood"},{"query":"   ","kind":"artist"}]}
        """
        let intents = try #require(RecommendationPlanParser.parse(output))
        #expect(intents.count == 1)
        #expect(intents[0].query == "ok")
    }

    @Test("query 单行化（换行/多空格压成一个空格）")
    func normalizeWhitespace() {
        #expect(RecommendationPlanParser.normalizeQuery("  A \n B  ") == "A B")
    }
}

// MARK: - 回退

private struct EmptyPlanner: RecommendationPlanning {
    func makePlan(for profile: TasteProfile) async -> RecommendationPlan {
        RecommendationPlan(intents: [], source: .localModel)
    }
}

private struct StubPlanner: RecommendationPlanning {
    var plan: RecommendationPlan
    func makePlan(for profile: TasteProfile) async -> RecommendationPlan { plan }
}

@Suite("RecommendationPlannerFallback")
struct RecommendationPlannerFallbackTests {
    private func profile() -> TasteProfile {
        var profile = TasteProfile()
        profile.topArtists = [ArtistWeight(artist: "陈奕迅", weight: 1), ArtistWeight(artist: "Adele", weight: 0.8)]
        profile.topGenres = ["粤语流行"]
        profile.decadeShare = [1990: 0.6]
        return profile
    }

    @Test("模型空结果 → 规则结果")
    func emptyModelFallsBackToRule() async {
        let planner = FallbackRecommendationPlanner(primary: EmptyPlanner())
        let plan = await planner.makePlan(for: profile())
        #expect(plan.source == .rule)
        #expect(!plan.intents.isEmpty)
        #expect(plan.intents.first?.query == "陈奕迅")
    }

    @Test("模型有结果 → 原样采用（不重复生成）")
    func modelResultWins() async {
        let stub = StubPlanner(plan: RecommendationPlan(
            intents: [RecommendationIntent(query: "City Pop", kind: .genre)],
            source: .localModel
        ))
        let planner = FallbackRecommendationPlanner(primary: stub)
        let plan = await planner.makePlan(for: profile())
        #expect(plan.source == .localModel)
        #expect(plan.intents.map(\.query) == ["City Pop"])
    }

    @Test("规则 planner 包装 P1 行为")
    func rulePlannerMatchesP1() async {
        let plan = await RuleRecommendationPlanner().makePlan(for: profile())
        let p1 = RecommendationIntentBuilder.intents(from: profile())
        #expect(plan.intents == p1)
        #expect(plan.source == .rule)
    }
}

// MARK: - 模型文件管理

@Suite("RecommendationModelManagement")
struct RecommendationModelManagementTests {
    private func tempLayout() -> RecommendationModelLayout {
        RecommendationModelLayout(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("qqp-rec-\(UUID().uuidString)"),
            modelId: "mlx-community/Qwen2.5-4B-Instruct-4bit"
        )
    }

    @Test("目录名清洗：repo id 的斜杠 / 冒号不进路径")
    func layoutSanitize() {
        #expect(RecommendationModelLayout.sanitize(modelId: "mlx-community/Qwen2.5-4B-Instruct-4bit") == "mlx-community-Qwen2.5-4B-Instruct-4bit")
        #expect(RecommendationModelLayout.sanitize(modelId: "a:b/c d") == "a-b-c-d")
        #expect(RecommendationModelLayout.sanitize(modelId: "") == "model")
        let layout = tempLayout()
        #expect(layout.directory.lastPathComponent == DSQSharedModelCatalog.currentVersion)
        #expect(layout.directory.deletingLastPathComponent().lastPathComponent == "mlx-community-Qwen2.5-4B-Instruct-4bit")
        #expect(
            layout.directory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                == DSQSharedModelCatalog.recommendationKind
        )
        #expect(layout.fileURL(named: "config.json").lastPathComponent == "config.json")
    }

    @Test("旧布局：legacy shape 仍解析到 <root>/<modelId>")
    func legacyLayoutShape() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qqp-legacy-\(UUID().uuidString)")
        let layout = RecommendationModelLayout(root: root, modelId: "a:b/c", shape: .legacy)
        #expect(layout.directory == root.appendingPathComponent("a-b-c", isDirectory: true))
    }

    @Test("迁移前兼容：旧目录有 manifest 时回落到只读布局")
    func resolvedFallsBackToLegacy() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("qqp-resolve-\(UUID().uuidString)")
        let newRoot = base.appendingPathComponent("Models", isDirectory: true)
        let legacyRoot = base.appendingPathComponent("LegacyModels", isDirectory: true)
        let legacy = RecommendationModelLayout(root: legacyRoot, modelId: "m", shape: .legacy)
        try FileManager.default.createDirectory(at: legacy.directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.manifestURL)

        let resolved = RecommendationModelLayout.resolved(
            modelId: "m",
            newRoot: newRoot,
            legacyRoot: legacyRoot
        )
        #expect(resolved.shape == .legacy)
        #expect(resolved.directory == legacy.directory)

        let versioned = RecommendationModelLayout(root: newRoot, modelId: "m")
        try FileManager.default.createDirectory(at: versioned.directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: versioned.manifestURL)
        let upgraded = RecommendationModelLayout.resolved(
            modelId: "m",
            newRoot: newRoot,
            legacyRoot: legacyRoot
        )
        #expect(upgraded.shape == .versioned)
        #expect(upgraded.directory == versioned.directory)
    }

    @Test("清单构建：分片索引解析 + 必需文件校验")
    func manifestBuilding() throws {
        let index = """
        {"weight_map":{
          "a":"model-00001-of-00002.safetensors",
          "b":"model-00002-of-00002.safetensors",
          "c":"model-00001-of-00002.safetensors"
        }}
        """
        #expect(RecommendationModelManifestBuilder.shardNames(fromIndex: Data(index.utf8)) == [
            "model-00001-of-00002.safetensors",
            "model-00002-of-00002.safetensors",
        ])
        #expect(RecommendationModelManifestBuilder.shardNames(fromIndex: Data("{}".utf8)).isEmpty)
        #expect(RecommendationModelManifestBuilder.shardNames(fromIndex: Data("not json".utf8)).isEmpty)

        let complete = RecommendationModelManifestBuilder.manifest(id: "m", files: [
            RecommendationModelFile(name: "config.json", size: 100),
            RecommendationModelFile(name: "tokenizer.json", size: 200),
            RecommendationModelFile(name: "model.safetensors", size: 300),
        ])
        #expect(complete?.id == "m")
        #expect(complete?.totalBytes == 600)

        let missingTokenizer = RecommendationModelManifestBuilder.manifest(id: "m", files: [
            RecommendationModelFile(name: "config.json", size: 100),
            RecommendationModelFile(name: "model.safetensors", size: 300),
        ])
        #expect(missingTokenizer == nil)
    }

    @Test("完整性校验：大小不符 / 空文件都不算 ready")
    func validation() throws {
        let layout = tempLayout()
        let store = RecommendationModelStore(layout: layout)
        try store.ensureDirectory()
        let manifest = RecommendationModelManifest(id: "m", files: [
            RecommendationModelFile(name: "config.json", size: 5),
            RecommendationModelFile(name: "tokenizer.json", size: 3),
            RecommendationModelFile(name: "model.safetensors", size: 4),
        ])
        try store.saveManifest(manifest)

        #expect(!store.isComplete(manifest: manifest))
        try Data("1234".utf8).write(to: layout.fileURL(named: "config.json"))
        try Data("123".utf8).write(to: layout.fileURL(named: "tokenizer.json"))
        try Data("1234".utf8).write(to: layout.fileURL(named: "model.safetensors"))
        #expect(!store.isComplete(manifest: manifest)) // config 大小不符

        try Data("12345".utf8).write(to: layout.fileURL(named: "config.json"))
        #expect(store.isComplete(manifest: manifest))

        try store.delete()
        #expect(!FileManager.default.fileExists(atPath: layout.directory.path))
    }

    @Test("清单持久化：save → load 往返一致")
    func manifestPersistence() throws {
        let layout = tempLayout()
        let store = RecommendationModelStore(layout: layout)
        let manifest = RecommendationModelManifest(id: "m", files: [RecommendationModelFile(name: "config.json", size: 7)])
        try store.ensureDirectory()
        try store.saveManifest(manifest)
        #expect(store.loadManifest() == manifest)
        try? store.delete()
    }
}
