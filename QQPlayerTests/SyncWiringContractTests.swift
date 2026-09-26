//
//  SyncWiringContractTests.swift
//  QQPlayerTests
//
//  「装配可达性」契约测试（2026-09-14 立，T12）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  背景（为什么要这层断言）
//  ════════════════════════════════════════════════════════════════════════════
//  2026-09-13 定位到一个上线级缺陷：帧 8/9（播放数据同步）的唯一处理器
//  `SyncChangeLogPeer` **只在 Mac 侧装配**，iOS 侧没人接 —— 两端数据永不通。
//  根因不是写错代码，而是任务包按「层」拆分，**没有任何断言在问「这个能力在每个
//  平台是否真的被装配上了」**：每个包自测通过、CI 全绿，接线责任却掉进缝里。
//
//  本文件把「装配可达性」变成可执行断言：**只断言存在性与调用点**（行为另有单测），
//  每条断言把「不成立时哪个能力静默失效 + 去哪接」写进失败信息。
//
//  ════════════════════════════════════════════════════════════════════════════
//  设计要点（照抄 DisplayScriptContractTests 的既有做法，不新造扫描框架）
//  ════════════════════════════════════════════════════════════════════════════
//  - 扫判定收敛在纯函数 `SyncWiringContract.missingMarkers(inSource:requirement:)`，
//    **不碰文件系统** → 测试能用合成源码自证「能抓到缺失」（防止契约本身空转）。
//  - fail-closed：路径不存在 / 读不出内容 / 一个 .swift 都没扫到 → 测试**失败**，
//    绝不静默跳过（否则断言形同虚设）。
//  - 白名单式精准：每条断言一个 id，只钉「哪个文件必须出现哪个调用点」，不做行为断言。
//

import Foundation
import Testing

@testable import QQPlayer

// SCAN-BEGIN —— 纯逻辑（只用 Foundation 字符串 API，不碰文件系统）
enum SyncWiringContract {
    /// 一条「装配可达性」断言：某路径（文件或目录）下必须出现给定标记。
    struct Requirement {
        /// 断言标识（测试名 / 失败信息用）
        let id: String
        /// 仓库相对路径：`.swift` 文件（单文件断言）或目录（目录下**任一**文件满足即可）
        let path: String
        /// 必须**全部**出现的标记（子串匹配）
        let requiredMarkers: [String]
        /// 候选标记组：每组**至少命中一个**（空数组 = 该组不约束）
        let alternativeMarkers: [[String]]
        /// 断言语义（这条在钉什么）+ 不成立时的可操作指引
        let guidance: String
    }

    /// 全部装配可达性断言——**从注册表装配点派生**（不再手写）。
    ///
    /// 收口前这份清单是手写的 6 条，与 `SyncEntityRegistry.assemblyPoints` **两处各自
    /// 表达同一件事**：注册表删掉一条装配点，这里不会红（正是「同一语义多处手工维护」的形状）。
    /// 现在唯一来源 = 注册表申报：新增装配点 = 申报（`assertion`）→ 自动获得断言。
    /// 「删掉申报 = 不查了」的漏洞由 `assemblyAssertionBaselineIsPinned` 基线钉住。
    static var requirements: [Requirement] {
        requirements(from: SyncEntityRegistry.capabilityAssemblyPoints)
    }

    /// 纯函数：装配点申报 → 断言清单。合成自证就喂它一份「缺一条申报」的输入
    /// （断言随之消失 → 基线比对必须报红）。
    static func requirements(
        from declarations: [(capabilityID: String, point: SyncEntityAssemblyPoint)]
    ) -> [Requirement] {
        declarations.compactMap { entry in
            guard let assertion = entry.point.assertion else { return nil }
            return Requirement(
                id: assertion.id,
                path: assertion.path,
                requiredMarkers: assertion.requiredMarkers,
                alternativeMarkers: assertion.alternativeMarkers,
                guidance: guidance(for: entry)
            )
        }
    }

    /// 断言失败信息 = **申报出处**（能力 / 平台 / 帧 / 装配点说明）+ 注册表里的可操作指引。
    static func guidance(for entry: (capabilityID: String, point: SyncEntityAssemblyPoint)) -> String {
        let platform = entry.point.platform ?? "两端（通道级）"
        let frame = entry.point.frame.map { "帧 \($0)" } ?? "无帧"
        return """
        [申报出处] 能力 \(entry.capabilityID) · \(platform) · \(frame)
        \(entry.point.detail)
        （申报在 `QQPlayer/Sync/SyncEntityRegistry.swift`；改装配点 = 改这里扫描的路径/标记）

        \(entry.point.assertion?.guidance ?? "")
        """
    }

    /// 断言 id 基线（**派生不等于不查了**）：注册表删/改一条装配点申报 → 与本基线比对即红。
    /// 收口前的五条 + 2026-09-15 立的装配断言，逐条在此登记（新增断言必须先在这里表态）。
    static let assertionIDBaseline: [String] = [
        // A（收藏）：两端入口
        "mac-data-sync-entry-attached",
        "ios-data-sync-peer-attached",
        // E（跨端续播）：出站捕获挂点 / 入站落点
        "mac-playback-capture-attached",
        "ios-playback-position-sink-attached",
        // F2（对齐歌词）：出站随歌 / 入站接收器（后者是 INV-16 既有建议、此前一直缺）
        "mac-lyrics-push-attached",
        "ios-lyrics-receiver-attached",
        // G（曲库音频文件）
        "mac-library-push-attached",
        "ios-file-receiver-attached",
        // 通道级 / 共享入口级 / 平台级编排
        "frame-8-9-handler-present",
        "frame-8-9-numbers-frozen",
        "identity-entry-implemented-and-wired",
        "mac-playback-carry-attached",
    ]

    /// 纯函数：派生 id × 基线 → 差异（基线断言与合成自证共用）。
    static func baselineDiff(derived: [String], baseline: [String]) -> (missing: [String], unexpected: [String]) {
        let derivedSet = Set(derived)
        let baselineSet = Set(baseline)
        return (
            missing: baseline.filter { !derivedSet.contains($0) }.sorted(),
            unexpected: derived.filter { !baselineSet.contains($0) }.sorted()
        )
    }

    /// 收口前五条断言的**语义**（路径 + 必检标记）——派生不许把它们弄丢或弄错。
    static let originalRequirementSemantics: [(id: String, path: String, markers: [String])] = [
        (
            "ios-data-sync-peer-attached",
            // B2 拆分（2026-09-21）：装配点随 `attachDataSync` 搬进 `+DataSync.swift`（标记仍是 `SyncChangeLogPeer(`）。
            "QQPlayer/Services/IOSPassiveSyncCenter+DataSync.swift",
            ["SyncChangeLogPeer("]
        ),
        ("mac-data-sync-entry-attached", "QQPlayer/Mac", ["SyncDataSyncCoordinator("]),
        (
            "mac-playback-carry-attached",
            "QQPlayer/Mac/MacSyncCoordinatorFactory.swift",
            ["SyncPlaybackCarryPeer("]
        ),
        (
            "frame-8-9-handler-present",
            "QQPlayer/Sync/SyncChangeLogPeer.swift",
            ["case .changeLogPull:", "case .changeLogPush:"]
        ),
        (
            "frame-8-9-numbers-frozen",
            "QQPlayer/Sync/SyncFrame.swift",
            ["case changeLogPull = 8", "case changeLogPush = 9"]
        ),
    ]

    /// 纯函数：一份源码对某条断言的**缺失标记**列表（空 = 满足）。
    /// 两个来源都进结果：`requiredMarkers` 缺哪个报哪个；`alternativeMarkers` 每组
    /// 「一个都没命中」时报该组全部候选（提示可选写法）。
    static func missingMarkers(inSource source: String, requirement: Requirement) -> [String] {
        var missing: [String] = []
        for marker in requirement.requiredMarkers where !source.contains(marker) {
            missing.append("缺少 `\(marker)`")
        }
        for group in requirement.alternativeMarkers where !group.contains(where: { source.contains($0) }) {
            missing.append("缺少其中之一：\(group.map { "`\($0)`" }.joined(separator: " / "))")
        }
        return missing
    }
}

// SCAN-END

extension SyncWiringContract {
    /// 路径下的候选源码：文件 → 自身；目录 → 递归全部 .swift（文件系统访问只在这里）。
    /// fail-closed：路径不存在返回空数组，由调用方判失败（不静默跳过）。
    static func swiftSources(repoRoot: URL, at path: String) -> [URL] {
        let base = repoRoot.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return [base] }

        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    /// 校验结果：`hitFile` = 满足断言的第一个文件（目录断言下可能是任意一个）。
    struct CheckResult {
        var scannedFiles: Int = 0
        var satisfiedBy: String?
        /// 未满足时每个文件的缺失明细（路径:行无 → 缺失项）
        var failures: [String] = []
        var satisfied: Bool { satisfiedBy != nil }
    }

    /// 目录断言走「任一文件满足即可」；单文件断言同样走这条（候选集只有一个）。
    static func check(_ requirement: Requirement, repoRoot: URL) -> CheckResult {
        var result = CheckResult()
        let sources = swiftSources(repoRoot: repoRoot, at: requirement.path)
        result.scannedFiles = sources.count
        guard !sources.isEmpty else {
            result.failures.append("\(requirement.path)：路径不存在或目录下没有任何 .swift（fail-closed，不跳过）")
            return result
        }
        for url in sources {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                result.failures.append("\(url.path)：读取失败（fail-closed，不跳过）")
                continue
            }
            let missing = missingMarkers(inSource: source, requirement: requirement)
            if missing.isEmpty {
                result.satisfiedBy = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                result.failures = []
                return result
            }
            result.failures.append("\(url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")) → \(missing.joined(separator: "；"))")
        }
        return result
    }
}

// MARK: - 测试

struct SyncWiringContractTests {
    /// 仓库根：本文件位于 <repo>/QQPlayerTests/ 下 → 上两级
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 按 id 取断言（合成自证不再依赖「清单里第 0 条是谁」）。
    static func requirement(_ id: String) -> SyncWiringContract.Requirement? {
        SyncWiringContract.requirements.first { $0.id == id }
    }

    // MARK: 地基检查

    @Test("仓库根与断言清单解析正确（扫描前的地基检查）")
    func scanScopeResolves() {
        let marker = Self.repoRoot.appendingPathComponent("QQPlayer/Sync/SyncChangeLogPeer.swift")
        #expect(FileManager.default.fileExists(atPath: marker.path), "仓库根解析错了：\(Self.repoRoot.path)")
        #expect(
            SyncWiringContract.requirements.count >= 11,
            "装配断言条数异常：\(SyncWiringContract.requirements.count)（注册表申报丢了？）"
        )
        let ids = SyncWiringContract.requirements.map(\.id)
        #expect(Set(ids).count == ids.count, "断言 id 有重复：\(ids)")
        #expect(
            SyncWiringContract.requirements.allSatisfy { !$0.path.isEmpty },
            "有断言没写扫描路径（派生自注册表申报，路径必填）"
        )
    }

    // MARK: 契约自证有效（合成源码 —— 防止断言空转）

    @Test("合成缺装配源码必须被抓到（契约自证有效的关键用例）")
    func syntheticMissingWiringIsCaught() {
        guard let requirement = Self.requirement("ios-data-sync-peer-attached") else {
            Issue.record("断言 ios-data-sync-peer-attached 不在派生清单里——注册表申报丢了")
            return
        }
        let missing = SyncWiringContract.missingMarkers(
            inSource: "let peer = SyncChangeLogPeer(\n    session: session,\n    peerID: \"x\"\n)",
            requirement: requirement
        )
        #expect(missing.count == 1, "游标来源缺失应被抓到，实际：\(missing)")
        #expect(missing.first?.contains("peerHelloValue") == true, "报错要提示可选写法：\(missing)")

        let fullyMissing = SyncWiringContract.missingMarkers(inSource: "// 什么都没接", requirement: requirement)
        #expect(fullyMissing.count == 2, "装配点 + 游标来源都缺应报两项，实际：\(fullyMissing)")
    }

    @Test("合成合规源码不报（同一断言，正确接线）")
    func syntheticCorrectWiringIsClean() {
        let source = """
        guard let peerID = IOSPassiveDataSyncLogic.dataSyncPeerID(
            peerDeviceID: session.peerHelloValue?.deviceID
        ) else { return }
        let peer = SyncChangeLogPeer(session: session, store: store, applier: applier, peerID: peerID)
        """
        guard let requirement = Self.requirement("ios-data-sync-peer-attached") else {
            Issue.record("断言 ios-data-sync-peer-attached 不在派生清单里——注册表申报丢了")
            return
        }
        let missing = SyncWiringContract.missingMarkers(inSource: source, requirement: requirement)
        #expect(missing.isEmpty, "正确接线不该报缺失：\(missing)")
    }

    // MARK: 真实源码（逐条装配可达性）

    @Test(
        "装配可达性：每条断言都在真实源码里成立（不成立 = 该能力在某平台静默失效）",
        arguments: SyncWiringContract.requirements
    )
    func wiringRequirementsHold(requirement: SyncWiringContract.Requirement) {
        let result = SyncWiringContract.check(requirement, repoRoot: Self.repoRoot)
        #expect(result.scannedFiles > 0, "[\(requirement.id)] 一条源码都没扫到 = 契约空转：\(requirement.path)")
        #expect(
            result.satisfied,
            """
            [\(requirement.id)] 装配可达性不成立（路径：\(requirement.path)）：
            \(result.failures.joined(separator: "\n"))

            \(requirement.guidance)
            """
        )
    }

    @Test("帧 8/9 处理器类型存在且是播放数据同步的落点（防类型被删/搬走）")
    func changeLogPeerTypeExists() {
        let path = Self.repoRoot.appendingPathComponent("QQPlayer/Sync/SyncChangeLogPeer.swift")
        #expect(FileManager.default.fileExists(atPath: path.path), "SyncChangeLogPeer.swift 不在了：\(path.path)")
        guard let source = try? String(contentsOf: path, encoding: .utf8) else {
            Issue.record("SyncChangeLogPeer.swift 读取失败（fail-closed）：\(path.path)")
            return
        }
        #expect(source.contains("enum SyncChangeLogPeer") || source.contains("final class SyncChangeLogPeer"),
                "SyncChangeLogPeer 类型声明不见了（帧 8/9 唯一处理器）")
    }

    // MARK: 派生唯一来源（2026-09-15：断言改从注册表派生）

    @Test("装配断言只从注册表派生（这里再手写一条 = 契约失效）")
    func assertionsComeFromRegistryOnly() {
        let declared = SyncEntityRegistry.capabilityAssemblyPoints
        let withAssertion = declared.filter { $0.point.assertion != nil }
        #expect(
            withAssertion.count == SyncWiringContract.requirements.count,
            """
            断言条数 ≠ 注册表申报条数：申报 \(withAssertion.count) / 断言 \(SyncWiringContract.requirements.count)
            修法：断言一律从注册表装配点派生（`SyncEntityRegistry.capabilityAssemblyPoints`），
            不要在 `SyncWiringContract.requirements` 里手写任何一条。
            """
        )
        // 每条断言的 id / 路径必须逐字来自申报（派生不是「另外找一份」）。
        for entry in withAssertion {
            guard let assertion = entry.point.assertion else { continue }
            guard let derived = Self.requirement(assertion.id) else {
                Issue.record("申报的断言 \(assertion.id) 没进派生清单")
                continue
            }
            #expect(derived.path == assertion.path, "\(assertion.id) 的扫描路径被改写：\(derived.path)")
            #expect(
                derived.requiredMarkers == assertion.requiredMarkers,
                "\(assertion.id) 的必检标记被改写：\(derived.requiredMarkers)"
            )
            #expect(
                derived.alternativeMarkers == assertion.alternativeMarkers,
                "\(assertion.id) 的候选标记被改写"
            )
        }
    }

    @Test("断言 id 基线：注册表删/改一条装配点申报必须红（派生 ≠ 不查了）")
    func assemblyAssertionBaselineIsPinned() {
        let derived = SyncWiringContract.requirements.map(\.id)
        let diff = SyncWiringContract.baselineDiff(derived: derived, baseline: SyncWiringContract.assertionIDBaseline)
        #expect(
            diff.missing.isEmpty && diff.unexpected.isEmpty,
            """
            派生断言清单与基线不一致：
              丢了（注册表申报被删/被改名？）：\(diff.missing)
              新增（是对的，但要先把基线补上并说明为什么）：\(diff.unexpected)
            修法：装配点申报的增删必须**显式**同步到这里——基线就是「删掉申报不能静默变成不查」的那道闸。
            """
        )
    }

    @Test("合成：注册表缺一条装配点申报必须被抓到（契约自证有效）")
    func syntheticDroppedAssemblyDeclarationIsCaught() {
        let full = SyncEntityRegistry.capabilityAssemblyPoints
        let dropped = full.filter { $0.capabilityID != "A" || $0.point.platform != SyncEntityRegistry.platformIOS }

        // 派生本身会跟着变少（这是设计的：申报是唯一来源）……
        let derivedFull = SyncWiringContract.requirements(from: full).map(\.id)
        let derivedDropped = SyncWiringContract.requirements(from: dropped).map(\.id)
        #expect(
            derivedFull.contains("ios-data-sync-peer-attached") && !derivedDropped.contains("ios-data-sync-peer-attached"),
            "派生没有真的跟着申报走（合成输入失效）"
        )
        // ……但**基线比对必须报红**，否则「删掉申报」就成了合法的不查。
        let diff = SyncWiringContract.baselineDiff(
            derived: derivedDropped,
            baseline: SyncWiringContract.assertionIDBaseline
        )
        #expect(
            diff.missing == ["ios-data-sync-peer-attached"],
            "缺一条申报必须被基线抓到，实际：\(diff.missing)"
        )
        #expect(diff.unexpected.isEmpty, "不该有意外新增：\(diff.unexpected)")
    }

    @Test("原五条断言的语义（路径 + 必检标记）逐条仍在——派生不许弄丢或弄错")
    func originalRequirementSemanticsPreserved() {
        for semantics in SyncWiringContract.originalRequirementSemantics {
            guard let derived = Self.requirement(semantics.id) else {
                Issue.record("原断言 \(semantics.id) 不在派生清单里（语义丢失）")
                continue
            }
            #expect(
                derived.path == semantics.path,
                "原断言 \(semantics.id) 的扫描路径变了：\(derived.path) ≠ \(semantics.path)"
            )
            for marker in semantics.markers {
                #expect(
                    derived.requiredMarkers.contains(marker),
                    "原断言 \(semantics.id) 丢了必检标记 `\(marker)`：\(derived.requiredMarkers)"
                )
            }
        }
    }
}

// MARK: - 身份解析「禁止第二实现」契约（2026-09-15 身份入口包）

/// 「歌曲身份解析」（stable_id ↔ content_hash，以及曲库路径 → 身份）唯一入口的
/// **形状契约**：扫生产码，断言两件事各自只有一处实现——① 身份 SQL（三个方向）；
/// ② 用闭包构造身份映射。
///
/// 为什么单独一层：装配可达性只能发现「没接线」，发现不了「同一件事被第二处实现」。
/// 身份解析此前在生产码里有 5 处并行表达（真实现 / 歌词映射闭包 / 请求应答器闭包 / 曲库
/// 描述符闭包 / 曲库事实里再包一层同名 func），每处都可选、都能「返回 nil」，漏修一处即静默。
///
/// 判据（同 `SyncWiringContract` 风格）：纯函数判定 + 合成源码自证 + fail-closed。
enum SyncIdentityContract {
    /// 唯一允许解析 `stable_id ↔ content_hash` 的生产文件
    /// （`SyncContentHashResolver` = `SyncIdentityResolving` 的生产实现）。
    static let entryImplementationPath = "QQPlayer/Sync/SyncChangeLogMapping.swift"

    /// 唯一允许用闭包构造 `SyncLyricsContentMapping` 的生产文件（类型声明 + `.unresolved`
    /// 测试 seam 都在此）；其它生产文件只能走入口（`(identity:)` / `.live(database:)`）。
    static let mappingDefinitionPath = "QQPlayer/Sync/SyncAlignedLyrics.swift"

    /// 生产码扫描根（测试 / harness 是 seam，允许内存查表实现，不在扫描范围）。
    static let productionRoot = "QQPlayer"

    /// 身份解析 SQL 的形态（stableId → content_hash / content_hash → stableId /
    /// 路径 → 身份）。
    static let identitySQLMarkers = [
        "content_hash FROM track WHERE stable_id",
        "stable_id FROM track WHERE content_hash",
        // B1b（2026-09-15）：路径键形态（曲库路径 → (stableId, content_hash)）。
        // 它同样只允许出现在入口实现文件——否则「同一个身份事实」又被第二处解析。
        "FROM track WHERE path",
    ]

    /// 闭包式构造身份映射的标记（`SyncLyricsContentMapping(contentHashForStableId:…)`）。
    /// 注意带冒号：`mapping.stableIdForContentHash(x)` 这类**读**调用不匹配。
    static let closureWiringMarkers = [
        "contentHashForStableId:",
        "stableIdForContentHash:",
    ]

    /// 挂起键命名空间前缀的**字面量**只允许出现在入口侧声明（`SyncPendingKey` 所在文件）。
    /// 别处各拼一遍 `"rel:"` = 命名空间多处手工维护（改前缀漏一处就静默对不上）。
    static let pendingKeyNamespacePath = "QQPlayer/Sync/SyncAlignedLyrics.swift"
    static let pendingKeyPrefixLiteral = "\"rel:\""

    /// 接收侧**不得**出现身份兜底分支：判定全部在唯一身份入口内部
    /// （用户 2026-09-15 拍板的形状——不是「给帧加字段 + 在 applier 加 fallback 分支」）。
    static let applierPath = "QQPlayer/Sync/SyncChangeLogApplier.swift"
    static let applierForbiddenMarkers = [
        "relativePath",
        "SyncRemoteTrackIdentity",
        "SyncLocalTrackOutcome",
    ]

    /// 第二身份（相对路径兜底）在**入口实现**里的必备标记：缺任一 = 入口退化成
    /// 「只认 content_hash」——wire 带了第二键但接收侧没人看它，相对路径身份静默失效
    /// （本包要防的正是这个形状，故用标记把它钉死）。
    static let secondIdentityMarkers = [
        "func localizeRemoteTrack(",
        "SyncPendingKey.relativePath(",
        "SyncManifestGenerator.normalizeRelativePath(",
        "DISTINCT stable_id FROM track WHERE path",
    ]

    /// 纯函数：一份入口源码里**缺的第二身份标记**（空 = 兜底真的接在入口里）。
    /// 合成退化源码（只认 content_hash）必须全部报红——契约自证的入口。
    static func missingSecondIdentityMarkers(inSource source: String) -> [String] {
        secondIdentityMarkers.filter { !source.contains($0) }
    }

    /// 纯函数：一份生产源码里违禁的标记（空 = 该文件合规）。
    static func violations(inSource source: String, relativePath: String) -> [String] {
        var result: [String] = []
        if relativePath != entryImplementationPath {
            result += identitySQLMarkers.filter { source.contains($0) }
                .map { "身份 SQL：`\($0)`" }
        }
        if relativePath != mappingDefinitionPath {
            result += closureWiringMarkers.filter { source.contains($0) }
                .map { "闭包构造身份映射：`\($0)`" }
        }
        if relativePath != pendingKeyNamespacePath, source.contains(pendingKeyPrefixLiteral) {
            result += ["挂起键命名空间字面量：`\(pendingKeyPrefixLiteral)`（只准出现在 SyncPendingKey 一处）"]
        }
        if relativePath == applierPath {
            result += applierForbiddenMarkers.filter { source.contains($0) }
                .map { "applier 里的身份兜底分支：`\($0)`（判定必须全在身份入口内部）" }
        }
        return result
    }
}

extension SyncIdentityContract {
    struct ScanResult {
        var scannedFiles: Int = 0
        /// 违禁明细（`相对路径 → 标记`）
        var violations: [String] = []
        /// 入口文件自身是否真的在做两个方向的解析（false = 白名单空转，必须失败）
        var entryResolvesIdentity = false
        /// 入口文件是否真的接了**第二身份兜底**（false = 退化回「只认 content_hash」）
        var entryImplementsRelativePathFallback = false
        /// 映射定义文件是否真的持有闭包（false = 白名单空转，必须失败）
        var definitionHoldsClosures = false
    }

    /// 生产码全量扫描（文件系统访问只在这里；fail-closed 由调用方断言 `scannedFiles`）。
    static func scan(repoRoot: URL) -> ScanResult {
        var result = ScanResult()
        for url in SyncWiringContract.swiftSources(repoRoot: repoRoot, at: productionRoot) {
            let relativePath = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            result.scannedFiles += 1
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                result.violations.append("\(relativePath)：读取失败（fail-closed，不跳过）")
                continue
            }
            if relativePath == entryImplementationPath {
                result.entryResolvesIdentity = identitySQLMarkers.allSatisfy { source.contains($0) }
                result.entryImplementsRelativePathFallback = missingSecondIdentityMarkers(inSource: source).isEmpty
            }
            if relativePath == mappingDefinitionPath {
                result.definitionHoldsClosures = closureWiringMarkers.allSatisfy { source.contains($0) }
            }
            result.violations += violations(inSource: source, relativePath: relativePath)
                .map { "\(relativePath) → \($0)" }
        }
        return result
    }
}

// MARK: - 身份入口形状测试

struct SyncIdentityContractTests {
    static let repoRoot = SyncWiringContractTests.repoRoot

    @Test("身份解析：生产码里只有一处实现（白名单 = 入口文件；映射只能从入口构造）")
    func productionHasSingleIdentityImplementation() {
        let result = SyncIdentityContract.scan(repoRoot: Self.repoRoot)
        #expect(result.scannedFiles > 50, "生产码一个 .swift 都没扫到 = 契约空转：扫到 \(result.scannedFiles)")
        #expect(
            result.entryResolvesIdentity,
            """
            白名单文件 \(SyncIdentityContract.entryImplementationPath) 里找不到两个方向的身份 SQL——
            说明契约的空转保护失效（要么身份实现搬走了，要么 SQL 改形态了）。
            """
        )
        #expect(
            result.definitionHoldsClosures,
            "\(SyncIdentityContract.mappingDefinitionPath) 里找不到闭包字段/闭包 init——白名单空转保护失效。"
        )
        #expect(
            result.entryImplementsRelativePathFallback,
            """
            身份入口退化了：\(SyncIdentityContract.entryImplementationPath) 里缺第二身份（相对路径兜底）标记
            \(SyncIdentityContract.secondIdentityMarkers)；wire 会带 relativePath
            但接收侧没人看它，相对路径身份静默失效（对端行的收藏 / 播放历史永远过不了端）。
            """
        )
        #expect(
            result.violations.isEmpty,
            """
            生产码里出现了第二处「歌曲身份解析」（唯一入口 = SyncIdentityResolving，\
            生产实现 = QQPlayer/Sync/SyncChangeLogMapping.swift 的 SyncContentHashResolver）：
            \(result.violations.joined(separator: "\n"))

            修法：删掉第二处实现，改为依赖入口——① 需要 stableId ↔ content_hash 就注入/持有
            `any SyncIdentityResolving`；② 需要「曲库路径 → 身份」就走
            `trackIdentity(atAbsolutePath:)`（同步线程取数也不得改走全表回落的 `getTrack(byPath:)`）；
            ③ 需要身份映射就走 `SyncLyricsContentMapping(identity:)` / `.live(database:)`
            （闭包构造只允许留在测试 seam 一侧）。
            """
        )
    }

    @Test("合成「第二处实现」必须被抓到（契约自证有效）")
    func syntheticSecondImplementationIsCaught() {
        let sql = """
        func contentHash(forTrackStableId stableId: String) throws -> String? {
            try String.fetchOne(db, sql: "SELECT content_hash FROM track WHERE stable_id = ? LIMIT 1")
        }
        """
        #expect(
            SyncIdentityContract.violations(inSource: sql, relativePath: "QQPlayer/Sync/Somewhere.swift").count == 1,
            "非白名单文件里的身份 SQL 必须被抓到"
        )
        #expect(
            SyncIdentityContract.violations(
                inSource: sql,
                relativePath: SyncIdentityContract.entryImplementationPath
            ).isEmpty,
            "入口文件自身必须放行（否则契约不可用）"
        )

        // B1b：路径键形态的身份 SQL 同样不得出现在白名单之外
        let pathSQL = """
        let row = try Row.fetchOne(
            db,
            sql: "SELECT stable_id, content_hash FROM track WHERE path = ? LIMIT 1",
            arguments: [path]
        )
        """
        #expect(
            SyncIdentityContract.violations(inSource: pathSQL, relativePath: "QQPlayer/Sync/Somewhere.swift").count == 1,
            "非白名单文件里的路径键身份 SQL 必须被抓到（B1b）"
        )
        #expect(
            SyncIdentityContract.violations(
                inSource: pathSQL,
                relativePath: SyncIdentityContract.entryImplementationPath
            ).isEmpty,
            "入口文件自身必须放行（路径键）"
        )

        let closureWiring = """
        let mapping = SyncLyricsContentMapping(
            contentHashForStableId: { _ in nil },
            stableIdForContentHash: { _ in nil }
        )
        """
        #expect(
            SyncIdentityContract.violations(inSource: closureWiring, relativePath: "QQPlayer/Mac/Somewhere.swift").count == 2,
            "生产码里用闭包构造身份映射必须被抓到（闭包只允许留在测试 seam）"
        )
        #expect(
            SyncIdentityContract.violations(
                inSource: closureWiring,
                relativePath: SyncIdentityContract.mappingDefinitionPath
            ).isEmpty,
            "映射定义文件自身必须放行"
        )

        // 读调用（`mapping.stableIdForContentHash(x)`）不带冒号，不得被误报
        let readCall = "let sid = lyricsMapping.stableIdForContentHash(songHash)"
        #expect(
            SyncIdentityContract.violations(inSource: readCall, relativePath: "QQPlayer/Sync/Somewhere.swift").isEmpty,
            "读调用不是第二处实现，不得误报"
        )
    }

    @Test("身份入口：第二身份兜底必须真接在入口里（合成退化源码必报红）")
    func secondIdentityFallbackMustBeImplemented() {
        // 合成退化入口：只认 content_hash（正是本包要防的形状）。
        // ⚠️ 退化形态 = 回到收口前「mapper 里直接查指纹」的写法——**连 `localizeRemoteTrack`
        // 都不存在**。如果这里留着 `func localizeRemoteTrack(` 签名，那条标记就永远"不缺失"，
        // 本用例会变成半条空断言（维护者复核时抓到过一次）。
        let degraded = """
        func localize(_ entry: SyncChangeLogWireEntry) throws -> SyncEntryLocalization {
            let remoteRow = Self.remoteRow(entry)
            guard let contentHash = entry.contentHash, !contentHash.isEmpty else {
                return .unresolved(reason: .missingIdentityKey, remoteRow: remoteRow)
            }
            if let stableId = try resolver.trackStableId(forContentHash: contentHash) {
                return .mapped(Self.rewrite(remoteRow, entity: entity, localStableId: stableId))
            }
            return .suspended(contentHash: contentHash, remoteRow: remoteRow)
        }
        """
        #expect(
            SyncIdentityContract.missingSecondIdentityMarkers(inSource: degraded).count
                == SyncIdentityContract.secondIdentityMarkers.count,
            "退化成「只认 content_hash」的入口必须全标记报红（契约自证失效 = 这是条空断言）"
        )
        // 真入口（读盘）必须不报红
        let entryURL = Self.repoRoot.appendingPathComponent(SyncIdentityContract.entryImplementationPath)
        let source = (try? String(contentsOf: entryURL, encoding: .utf8)) ?? ""
        #expect(!source.isEmpty, "读不到入口源码 = 契约空转（fail-closed）")
        #expect(
            SyncIdentityContract.missingSecondIdentityMarkers(inSource: source).isEmpty,
            "入口实现缺第二身份标记：\(SyncIdentityContract.missingSecondIdentityMarkers(inSource: source))"
        )
    }

    @Test("身份入口：挂起键命名空间单入口（字面量只准一处）+ applier 不得有身份兜底分支")
    func pendingKeyNamespaceAndApplierShape() {
        let namespaceFile = "QQPlayer/Sync/SyncAlignedLyrics.swift"
        let leak = "let key = \"rel:\" + relativePath"
        #expect(
            SyncIdentityContract.violations(inSource: leak, relativePath: "QQPlayer/Sync/SyncChangeLogPeer.swift")
                .count == 1,
            "别处手拼挂起键前缀必须被抓到（命名空间多处维护 = 改前缀漏一处就静默）"
        )
        #expect(
            SyncIdentityContract.violations(inSource: leak, relativePath: namespaceFile).isEmpty,
            "命名空间声明处自身必须放行"
        )

        // applier 不得出现任何身份兜底：判定全在身份入口内部
        let fallbackInApplier = """
        if let side = SyncRemoteTrackIdentity(contentHash: nil, relativePath: entry.relativePath) {
            return try resolver.localizeRemoteTrack(side)
        }
        """
        #expect(
            SyncIdentityContract.violations(
                inSource: fallbackInApplier,
                relativePath: SyncIdentityContract.applierPath
            ).count == 2,
            "applier 里的身份兜底分支必须被抓到（形状要求：判定全在入口内部）"
        )
        let applierURL = Self.repoRoot.appendingPathComponent(SyncIdentityContract.applierPath)
        let source = (try? String(contentsOf: applierURL, encoding: .utf8)) ?? ""
        #expect(!source.isEmpty, "读不到 applier 源码 = 契约空转（fail-closed）")
        #expect(
            SyncIdentityContract.violations(
                inSource: source,
                relativePath: SyncIdentityContract.applierPath
            ).isEmpty,
            "applier 里出现了身份兜底分支——判定必须全部发生在身份入口内部"
        )
    }
}

// MARK: - 结果账目「单一实现」契约（L6，2026-09-15）

/// 「一次「同步数据」的结果计数」唯一实现的**形状契约**：扫生产码，断言①结果计数只在
/// `SyncOutcomeTally` 一处声明 / 改写；②两端账目（Mac / iOS）都持有它。
///
/// 为什么单独一层：行为用例只能发现「算错了」，发现不了「同一份账目被第二处维护」。
/// 收口前同一批结果有两套结构（`SyncDataSyncReport` 四个手写 `+=` /
/// `IOSPassiveDataSyncSummary` 另一套），每类要「产生 → 累加 → 映射 → 上屏」四处手工
/// 对齐，漏一处即静默（矩阵四级 #18/#19）。
///
/// 判据（同 `SyncIdentityContract` 风格）：纯函数判定 + 合成源码自证 + fail-closed。
enum SyncOutcomeContract {
    /// 唯一允许声明 / 改写结果计数的生产文件。
    static let tallyDefinitionPath = "QQPlayer/Sync/SyncOutcomeTally.swift"

    /// 生产码扫描根（测试是 seam，不在扫描范围）。
    static let productionRoot = "QQPlayer"

    /// 结果计数的**槽位名**：新口径 + 收口前的旧字段名（旧名再出现即「第二处账目」）。
    static let slotNames = [
        "appliedEntries",
        "suspendedEntries",
        "outboundEntries",
        "unresolvedEntries",
        "skippedMissingParentEntries",
        "unsupportedEntries",
        "missingIdentityEntries",
        "ignoredDeletes",
        // 收口前的旧字段名（Mac / iOS 各一套，不得再出现）
        "pushedEntries",
        "pushedMissingIdentityEntries",
        "answeredPullEntries",
    ]

    /// 两端账目文件：必须**持有** tally（写死路径是刻意的：搬走 = 契约失效，得显式改这里）。
    static let ledgerPaths = [
        "QQPlayer/Sync/SyncDataSyncCoordinator.swift",
        "QQPlayer/Services/IOSPassiveSyncCenter.swift",
    ]

    /// 纯函数：一份生产源码里违禁的计数写法（空 = 该文件合规）。
    static func violations(inSource source: String, relativePath: String) -> [String] {
        guard relativePath != tallyDefinitionPath else { return [] }
        return mutationViolations(inSource: source)
    }

    /// 去空白后的「槽位名 + 操作符」扫描：`x.appliedEntries += 1` /
    /// `$0.answeredPullEntries = count` / `var appliedEntries = 0` 都是「第二处账目」；
    /// 只读（`report.appliedEntries > 0`、`report.pushedEntries,`）与比较（`== 0`）不是；
    /// 计算属性（`var appliedEntries: Int { tally.… }`）是**读数投影**，放行。
    static func mutationViolations(inSource source: String) -> [String] {
        let compact = source.filter { !$0.isWhitespace }
        var hits: [String] = []
        for name in slotNames {
            var searchStart = compact.startIndex
            while let found = compact.range(of: name, range: searchStart ..< compact.endIndex) {
                searchStart = found.upperBound
                let prefix = compact[..<found.lowerBound]
                let suffix = compact[found.upperBound...]
                if suffix.hasPrefix("+=") {
                    hits.append("分类累加：`\(name) +=`")
                } else if suffix.hasPrefix("="), !suffix.hasPrefix("==") {
                    hits.append("分类赋值：`\(name) =`（结果计数只能由 SyncOutcomeTally 持有）")
                }
                if prefix.hasSuffix("var"), suffix.hasPrefix(":Int"), !suffix.dropFirst(":Int".count).hasPrefix("{") {
                    hits.append("第二处计数字段：`var \(name): Int`")
                }
            }
        }
        return hits
    }
}

extension SyncOutcomeContract {
    struct ScanResult {
        var scannedFiles = 0
        /// 违禁明细（`相对路径 → 明细`）
        var violations: [String] = []
        /// 白名单文件是否真的在定义账目（false = 白名单空转，必须失败）
        var tallyDefinesSlots = false
        /// 两端账目里真的持有 tally 的文件（数量不足 = 收口没接上）
        var ledgersHoldingTally: [String] = []
    }

    /// 生产码全量扫描（文件系统访问只在这里；fail-closed 由调用方断言 `scannedFiles`）。
    static func scan(repoRoot: URL) -> ScanResult {
        var result = ScanResult()
        for url in SyncWiringContract.swiftSources(repoRoot: repoRoot, at: productionRoot) {
            let relativePath = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            result.scannedFiles += 1
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                result.violations.append("\(relativePath)：读取失败（fail-closed，不跳过）")
                continue
            }
            if relativePath == tallyDefinitionPath {
                result.tallyDefinesSlots = source.contains("enum SyncRowOutcome")
                    && source.contains("struct SyncOutcomeTally")
                    && slotNames.prefix(8).allSatisfy { source.contains("var \($0): Int") }
            }
            if ledgerPaths.contains(relativePath), ledgerHoldsTally(source) {
                result.ledgersHoldingTally.append(relativePath)
            }
            result.violations += violations(inSource: source, relativePath: relativePath)
                .map { "\(relativePath) → \($0)" }
        }
        return result
    }

    /// 一份账目源码是否真的「持有 tally + 往它写」（两条都在才算）：只有读数、没有
    /// `tally` 字段的旧写法会漏这一条。
    static func ledgerHoldsTally(_ source: String) -> Bool {
        source.contains("var tally = SyncOutcomeTally()") && source.contains(".tally.")
    }
}

// MARK: - 结果账目形状测试

struct SyncOutcomeContractTests {
    static let repoRoot = SyncWiringContractTests.repoRoot

    @Test("结果账目：生产码里只有一处计数定义（白名单 = tally 文件；别处不得分类 += / =）")
    func productionHasSingleOutcomeTally() {
        let result = SyncOutcomeContract.scan(repoRoot: Self.repoRoot)
        #expect(result.scannedFiles > 50, "生产码一个 .swift 都没扫到 = 契约空转：扫到 \(result.scannedFiles)")
        #expect(
            result.tallyDefinesSlots,
            """
            白名单文件 \(SyncOutcomeContract.tallyDefinitionPath) 里找不到账目定义——
            说明契约的空转保护失效（tally 被改名 / 搬走 / 槽位名改了）。
            """
        )
        #expect(
            result.ledgersHoldingTally.count == SyncOutcomeContract.ledgerPaths.count,
            """
            两端账目没有都持有 tally（L6 收口断了）：
            缺 \(SyncOutcomeContract.ledgerPaths.filter { !result.ledgersHoldingTally.contains($0) })
            """
        )
        #expect(
            result.violations.isEmpty,
            """
            生产码里出现了第二处「同步数据结果计数」（唯一账目 = SyncOutcomeTally，
            \(SyncOutcomeContract.tallyDefinitionPath)；Mac 账目 = SyncDataSyncReport.tally、
            iOS 账目 = IOSPassiveDataSyncSummary.tally）：
            \(result.violations.joined(separator: "\n"))

            修法：删掉别处的分类计数，改为——① 写就用 `tally.accumulate(…)`（累加）/
            `tally.overwrite(…, with:)`（最近一批口径）；② 读就用 tally 的访问器或旧字段名
            （`report.appliedEntries` 这类只读投影允许保留）；③ 新增类别先改 `SyncRowOutcome`
            （tally 的 switch 无 default，会强制你给出槽位）。
            """
        )
    }

    @Test("合成「第二处账目」必须被抓到（契约自证有效）")
    func syntheticSecondLedgerIsCaught() {
        let coordinatorStyle = """
            private func recordApplied(_ count: Int) {
                reportValue.appliedEntries += count
            }
        """
        #expect(
            SyncOutcomeContract.violations(
                inSource: coordinatorStyle,
                relativePath: "QQPlayer/Sync/SyncDataSyncCoordinator.swift"
            ).count == 1,
            "coordinator 里的分类 `+=` 必须被抓到"
        )

        let iosStyle = """
            peer.onPullHandled = { [weak self] _, count in
                Task { @MainActor in self?.recordDataSync { $0.answeredPullEntries = count } }
            }
        """
        #expect(
            SyncOutcomeContract.violations(
                inSource: iosStyle,
                relativePath: "QQPlayer/Services/IOSPassiveSyncCenter.swift"
            ).count == 1,
            "iOS 侧的分类 `=`（旧写法）必须被抓到"
        )

        let secondDefinition = """
            struct IOSPassiveDataSyncSummary: Equatable, Sendable {
                var appliedEntries = 0
            }
        """
        #expect(
            SyncOutcomeContract.violations(
                inSource: secondDefinition,
                relativePath: "QQPlayer/Services/IOSPassiveSyncCenter.swift"
            ).count == 1,
            "第二套账目字段必须被抓到"
        )

        // 只读 / 比较 / 计算属性投影不得误报（Mac 面板与两端读数就是这样写的）
        let readOnly = """
            var appliedEntries: Int { tally.appliedEntries }
            let report = dataModel.report
            metric("sync_run_data_result_sent".localized, report.pushedEntries, .primary)
            if report.suspendedEntries > 0 { }
            if report.unresolvedEntries == 0 { }
        """
        #expect(
            SyncOutcomeContract.violations(
                inSource: readOnly,
                relativePath: "QQPlayer/Mac/MacSyncView.swift"
            ).isEmpty,
            "读 / 比较 / 计算属性不是第二处账目，不得误报"
        )

        // 白名单文件自身必须放行（否则契约不可用）
        #expect(
            SyncOutcomeContract.violations(
                inSource: coordinatorStyle + secondDefinition,
                relativePath: SyncOutcomeContract.tallyDefinitionPath
            ).isEmpty,
            "账目定义文件自身必须放行"
        )
    }
}

// MARK: - 实体注册表契约（CI 遍历断言，L0 契约 → 代码，2026-09-15）

/// 「某实体具备哪些同步能力」唯一声明处（`SyncEntityRegistry`）的**形状契约**：
/// 扫生产码 + 读 L0 契约文档，断言四件事——
/// ① `SyncChangeEntity.allCases` 每个 case 都有登记；
/// ② 每条登记的 L0 编号在 `docs/sync-contract.md` 里真实存在（文档 ↔ 代码双向对齐）；
/// ③ `notSynced` 实体（契约明写「不做」）不得出现在任何 outbox 写入点 / 补发名单 / 上线清单；
/// ④ 派生名单只准从注册表算（生产码里不得有第二份手写清单 / 手写身份判定）。
///
/// 为什么单独一层：行为用例只能发现「这条通道算错了」，发现不了「同一件事被第二处手工
/// 维护」——2026-09-14 收藏事故的根因形状就是四处名单各自维护、漏一处即静默。
///
/// 判据（同 `SyncIdentityContract` 风格）：纯函数判定 + 合成源码自证 + fail-closed。
enum SyncEntityRegistryContract {
    /// 唯一声明处（白名单：只有这个文件可以持有实体清单与「引用歌曲」判定）。
    static let registryPath = "QQPlayer/Sync/SyncEntityRegistry.swift"
    /// 生产码扫描根（测试是 seam，不在扫描范围）。
    static let productionRoot = "QQPlayer"
    /// L0 契约文档（实体编号的真相；`docs/` 在 .gitignore，本文件 `git add -f` 入库）。
    static let contractDocPath = "docs/sync-contract.md"

    /// 派生名单名：收口后只允许「计算属性 → 注册表」，字面量清单只准出现在注册表里。
    /// （这些是**散落在别处的旧名**，它们出现在注册表里是正常的——派生访问器同名。）
    static let forbiddenListNames = [
        "v1Synced",
        "reconcilableEntities",
        "repairableEntities",
        "trackScopedEntities",
    ]

    /// 注册表必须提供的派生访问器名（不全 = 派生没收口，白名单空转必须失败）。
    static let derivedAccessorNames = [
        "v1SyncedEntities",
        "reconcilableEntities",
        "danglingRepairableEntities",
        "trackScopedSyncedEntities",
    ]

    /// 手写「引用歌曲」判定的形态（收口前 `entity != .playlist`；现在只能登记在注册表）。
    static let handWrittenIdentityPredicate = "!=.playlist"

    /// outbox 写入点的形态：文件里同时出现存储类型 + `record(` 调用。
    static let outboxStoreMarker = "SyncChangeLogStore"
    static let outboxRecordMarker = "record("
    /// outbox 写入点上的实体实参前缀（`entity: .favorite`）。
    static let entityArgumentMarker = "entity:."

    // MARK: 纯函数（只用 Foundation 字符串 API）

    /// 一份源码里被当作 outbox 写入实参的实体名（`entity: .favorite` → "favorite"）。
    static func entityCaseNames(inSource source: String) -> Set<String> {
        let compact = source.filter { !$0.isWhitespace }
        var result: Set<String> = []
        var searchStart = compact.startIndex
        while let found = compact.range(of: entityArgumentMarker, range: searchStart ..< compact.endIndex) {
            searchStart = found.upperBound
            let name = compact[found.upperBound...].prefix { $0.isLetter || $0.isNumber }
            if let first = name.first, first.isLowercase {
                result.insert(String(name))
            }
        }
        return result
    }

    /// 一份生产源码里的违禁项（空 = 该文件合规）：第二份手写清单 / 手写身份判定。
    /// 白名单 = 注册表文件自身（它是唯一声明处）。
    static func violations(inSource source: String, relativePath: String) -> [String] {
        guard relativePath != registryPath else { return [] }
        let compact = source.filter { !$0.isWhitespace }
        var hits: [String] = []
        for name in forbiddenListNames where compact.contains("\(name):[SyncChangeEntity]=[") {
            hits.append("第二份手写实体清单：`\(name): [SyncChangeEntity] = [`")
        }
        if compact.contains(handWrittenIdentityPredicate) {
            hits.append("手写「引用歌曲」判定：`entity != .playlist`（身份键要求只能登记在注册表）")
        }
        return hits
    }

    /// L0 契约文档里的实体编号标题（`### A 收藏（favorite）` → "A"；`### F1 …` → "F1"）。
    static func l0Headings(inDoc source: String) -> Set<String> {
        var result: Set<String> = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("### ") else { continue }
            let words = line.dropFirst(4).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let token = words.first, token.count <= 2, let first = token.first, first.isUppercase else { continue }
            result.insert(String(token))
        }
        return result
    }

    /// 未登记的实体 case（CI 遍历断言的核心判定）。
    static func unregisteredEntityCases(allCases: [String], registered: Set<String>) -> [String] {
        allCases.filter { !registered.contains($0) }
    }

    /// Swift case 名（扫描产物是源码里的 **case 名**，不是 rawValue：`playHistory` ≠ `play_history`）。
    /// 写法刻意用穷举 `switch`（无 default）：新增 case 时这里编译不过，逼人表态。
    static func caseName(of entity: SyncChangeEntity) -> String {
        switch entity {
        case .favorite: return "favorite"
        case .playHistory: return "playHistory"
        case .playlist: return "playlist"
        case .playlistItem: return "playlistItem"
        case .playbackPosition: return "playbackPosition"
        }
    }

    /// 注册表编号在契约文档里查无的（代码有、文档没有 → 文档没跟上）。
    static func l0IDsMissingFromDoc(registryIDs: Set<String>, docHeadings: Set<String>) -> [String] {
        registryIDs.subtracting(docHeadings).sorted()
    }

    /// 契约文档里的实体编号在注册表里查无的（文档有、代码没有 → 代码没跟上）。
    static func l0IDsMissingFromRegistry(registryIDs: Set<String>, docHeadings: Set<String>) -> [String] {
        docHeadings.subtracting(registryIDs).sorted()
    }

    /// 「不承诺」实体出现在实现点上的违规（契约明写「不做」的，任何人不得实现它）。
    static func notSyncedViolations(
        notSyncedCaseNames: Set<String>,
        outboxWrittenEntityNames: Set<String>,
        derivedListEntityNames: [String: Set<String>]
    ) -> [String] {
        var hits: [String] = []
        for name in notSyncedCaseNames.sorted() {
            if outboxWrittenEntityNames.contains(name) {
                hits.append("`\(name)` 标为 notSynced，却出现在 outbox 写入点上")
            }
            for (listName, names) in derivedListEntityNames.sorted(by: { $0.key < $1.key }) where names.contains(name) {
                hits.append("`\(name)` 标为 notSynced，却出现在名单 `\(listName)` 里")
            }
        }
        return hits
    }

    /// 装配申报自洽违规（纯函数：合成申报也能自证）：
    /// ① 声明了运行时探针却没写平台（= 谁也不会去检查它）；
    /// ② 探针枚举里有 case 没有任何装配点引用（枚举里积压没人检查的项）；
    /// ③ 断言 id 重复申报（同一条断言被两处认领）。
    static func assemblyDeclarationViolations(
        entries: [SyncEntityRegistryEntry],
        shared: [SyncEntityAssemblyPoint]
    ) -> [String] {
        var hits: [String] = []
        let points = entries.flatMap(\.assemblyPoints) + shared
        var seenIDs: Set<String> = []
        for point in points {
            if point.probe != nil, point.platform == nil {
                hits.append("装配点声明了运行时探针却没有平台（没人会检查它）：\(point.detail)")
            }
            if let assertion = point.assertion, !seenIDs.insert(assertion.id).inserted {
                hits.append("断言 id 重复申报：`\(assertion.id)`")
            }
        }
        let declaredProbes = Set(points.compactMap(\.probe))
        for probe in SyncWiringProbe.allCases where !declaredProbes.contains(probe) {
            hits.append("探针 `\(probe.rawValue)` 没有任何装配点引用（枚举里积压没人检查的项）")
        }
        return hits
    }

    /// 登记自洽违规（纯函数：合成条目也能自证）。
    static func registrySelfConsistencyViolations(_ entries: [SyncEntityRegistryEntry]) -> [String] {
        var hits: [String] = []
        var seenEntities: Set<String> = []
        var seenIDs: Set<String> = []
        for entry in entries {
            if !seenIDs.insert(entry.l0ID).inserted {
                hits.append("L0 编号 `\(entry.l0ID)` 重复登记")
            }
            if let entity = entry.entity, !seenEntities.insert(entity.rawValue).inserted {
                hits.append("实体 `\(entity.rawValue)` 重复登记")
            }
            // 不承诺 ⇒ 零实现（通道 / 出站 / 补发 / 修复 / 装配点全为空）
            if entry.syncMode.isNotSynced {
                if entry.channel != .none {
                    hits.append("notSynced 的 `\(entry.l0ID)` 不能有跨端通道：\(entry.channel)")
                }
                if entry.writesOutbox || entry.reconcilesLocalTruth || entry.repairsDanglingReferences {
                    hits.append("notSynced 的 `\(entry.l0ID)` 不能有任何同步实现点（出站 / 补发 / 修复）")
                }
                if !entry.assemblyPoints.isEmpty {
                    hits.append("notSynced 的 `\(entry.l0ID)` 不该有装配点")
                }
            }
            // 通道与能力互不矛盾
            if entry.writesOutbox, entry.channel != .changeLog {
                hits.append("`\(entry.l0ID)` 记 outbox 就必须走变更日志通道")
            }
            if entry.channel == .fileFrames, entry.writesOutbox || entry.reconcilesLocalTruth {
                hits.append("`\(entry.l0ID)` 走文件帧通道，不该有 outbox 出站 / 补发语义")
            }
            if entry.entity != nil, entry.channel != .changeLog {
                hits.append("`\(entry.l0ID)` 有 SyncChangeEntity case 就必须走变更日志通道")
            }
            // 悬空修复只对引用歌曲的实体有意义
            if entry.repairsDanglingReferences, !entry.referencesTrack {
                hits.append("`\(entry.l0ID)` 不引用歌曲，却登记为「参与悬空引用修复」")
            }
            // 「表 → outbox」补发只对表载体有意义
            if entry.reconcilesLocalTruth, entry.localTruth.table == nil {
                hits.append("`\(entry.l0ID)` 没有业务真值表，不该登记「本地真值 → outbox 补发」")
            }
            // 变更日志通道的装配点必须写出帧号（帧 8/9）
            if entry.channel == .changeLog {
                let frames = entry.assemblyPoints.compactMap(\.frame)
                if frames.isEmpty {
                    hits.append("`\(entry.l0ID)` 走变更日志通道，装配点必须写出帧号")
                }
                for frame in frames where !(8 ... 9).contains(frame) {
                    hits.append("`\(entry.l0ID)` 变更日志通道的装配帧号应为 8/9，实际 \(frame)")
                }
            }
        }
        return hits
    }
}

extension SyncEntityRegistryContract {
    struct ScanResult {
        var scannedFiles = 0
        /// 违禁明细（`相对路径 → 明细`）
        var violations: [String] = []
        /// 生产码里被当作 outbox 写入实参的实体名（应在场：注册表声明 `writesOutbox` 的那几个）
        var outboxWrittenEntityNames: Set<String> = []
        /// 白名单文件是否真的持有登记表（false = 白名单空转，必须失败）
        var registryDefinesEntries = false
        /// 白名单文件里出现的派生访问器名（不全 = 派生没收口，必须失败）
        var registryDerivedAccessors: [String] = []
    }

    /// 生产码全量扫描（文件系统访问只在这里；fail-closed 由调用方断言 `scannedFiles`）。
    static func scan(repoRoot: URL) -> ScanResult {
        var result = ScanResult()
        for url in SyncWiringContract.swiftSources(repoRoot: repoRoot, at: productionRoot) {
            let relativePath = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            result.scannedFiles += 1
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                result.violations.append("\(relativePath)：读取失败（fail-closed，不跳过）")
                continue
            }
            if relativePath == registryPath {
                result.registryDefinesEntries = source.contains("static let entries: [SyncEntityRegistryEntry] = [")
                result.registryDerivedAccessors = derivedAccessorNames.filter { source.contains($0) }
                continue // 注册表是声明处，不是 outbox 写入点
            }
            let compact = source.filter { !$0.isWhitespace }
            if compact.contains(outboxStoreMarker), compact.contains(outboxRecordMarker) {
                result.outboxWrittenEntityNames.formUnion(entityCaseNames(inSource: source))
            }
            result.violations += violations(inSource: source, relativePath: relativePath)
                .map { "\(relativePath) → \($0)" }
        }
        return result
    }

    /// 注册表声明「会记 outbox」的实体名（与扫描结果逐项对齐，防声明与实现漂移）。
    /// 用 case 名（扫描产物是源码实参 `entity: .<case>` 的名字）。
    static var declaredOutboxEntityNames: Set<String> {
        Set(SyncEntityRegistry.entries.filter(\.writesOutbox).compactMap { entry in
            entry.entity.map { Self.caseName(of: $0) }
        })
    }

    /// 各派生名单的实体名（③ 断言用）。
    static var derivedListEntityNames: [String: Set<String>] {
        [
            "SyncChangeEntity.v1Synced": Set(SyncChangeEntity.v1Synced.map { Self.caseName(of: $0) }),
            "reconcilableEntities": Set(SyncChangeLogDanglingRepair.reconcilableEntities.map { Self.caseName(of: $0) }),
            "repairableEntities": Set(SyncChangeLogDanglingRepair.repairableEntities.map { Self.caseName(of: $0) }),
            "trackScopedEntities": Set(SyncPlaybackCarryDatabaseFacts.trackScopedEntities.map { Self.caseName(of: $0) }),
        ]
    }
}

// MARK: - 实体注册表断言

struct SyncEntityRegistryContractTests {
    static let repoRoot = SyncWiringContractTests.repoRoot

    // MARK: ① 每个 case 都必须登记

    @Test("实体注册表：SyncChangeEntity 每个 case 都必须有登记（新增实体漏登记 = 红）")
    func everyEntityCaseIsRegistered() {
        let registered = Set(SyncEntityRegistry.entries.compactMap { $0.entity?.rawValue })
        let missing = SyncEntityRegistryContract.unregisteredEntityCases(
            allCases: SyncChangeEntity.allCases.map(\.rawValue),
            registered: registered
        )
        #expect(
            missing.isEmpty,
            """
            这些实体 case 没有登记（`\(SyncEntityRegistryContract.registryPath)`）：
            \(missing)

            修法：给每个 case 加一条登记，逐字段表态——L0 编号 / 真值表与行键形态 /
            是否引用歌曲 / 是否记 outbox / 是否有「本地真值 → outbox」补发 /
            是否参与悬空引用修复 / 同步与否（不承诺的要写理由）/ 装配点（帧号 + 平台）。
            不要在任何别的文件里手写实体清单。
            """
        )
        #expect(
            registered.count == SyncChangeEntity.allCases.count,
            "登记条数与 case 数不一致：登记 \(registered.count)，case \(SyncChangeEntity.allCases.count)"
        )
        #expect(
            SyncEntityRegistry.entries.count >= SyncChangeEntity.allCases.count,
            "注册表条目数少于 case 数 = 有 case 没登记"
        )
    }

    @Test("合成：漏登记的新实体必须被抓到（契约自证有效）")
    func syntheticUnregisteredEntityIsCaught() {
        let missing = SyncEntityRegistryContract.unregisteredEntityCases(
            allCases: ["favorite", "brandNewEntity"],
            registered: ["favorite"]
        )
        #expect(missing == ["brandNewEntity"], "漏登记的 case 必须被抓到，实际：\(missing)")
        #expect(
            SyncEntityRegistryContract.unregisteredEntityCases(
                allCases: ["favorite", "playlist"],
                registered: ["favorite", "playlist"]
            ).isEmpty,
            "全登记时不得误报"
        )
    }

    // MARK: ② L0 编号 ↔ 契约文档

    @Test("实体注册表：L0 编号与 docs/sync-contract.md 双向对齐（文档改了代码没跟上也红）")
    func l0IDsMatchContractDoc() {
        let docURL = Self.repoRoot.appendingPathComponent(SyncEntityRegistryContract.contractDocPath)
        guard let doc = try? String(contentsOf: docURL, encoding: .utf8) else {
            Issue.record(
                """
                读不到 L0 契约文档（fail-closed，不跳过）：\(docURL.path)
                该文件属强制入库（docs/ 在 .gitignore → 改动要 `git add -f docs/sync-contract.md`）。
                """
            )
            return
        }
        let headings = SyncEntityRegistryContract.l0Headings(inDoc: doc)
        #expect(headings.count >= 9, "契约文档只解析出 \(headings.count) 个实体标题 = 解析失效或文档被删")
        let registryIDs = Set(SyncEntityRegistry.entries.map(\.l0ID))
        let missingInDoc = SyncEntityRegistryContract.l0IDsMissingFromDoc(
            registryIDs: registryIDs,
            docHeadings: headings
        )
        #expect(
            missingInDoc.isEmpty,
            """
            这些 L0 编号在 `docs/sync-contract.md` 里查无：\(missingInDoc)
            修法：编号必须与契约文档的「### <编号> …」标题逐字一致——契约里删/改了实体，
            代码登记要跟着改；反过来新增登记必须先在契约里拍板（契约是需求真相）。
            """
        )
        let missingInRegistry = SyncEntityRegistryContract.l0IDsMissingFromRegistry(
            registryIDs: registryIDs,
            docHeadings: headings
        )
        #expect(
            missingInRegistry.isEmpty,
            """
            契约文档里有这些实体编号，注册表却没有对应登记：\(missingInRegistry)
            修法：契约新增实体 ⇒ 注册表必须补一条（否则「哪些能力该有」没人回答）。
            """
        )
    }

    @Test("合成：L0 编号与文档对不上必须被抓到（契约自证有效）")
    func syntheticL0IDMismatchIsCaught() {
        let doc = """
        ## 1. 数据面
        ### A 收藏（favorite）
        ### B 播放历史（playHistory）
        """
        let headings = SyncEntityRegistryContract.l0Headings(inDoc: doc)
        #expect(headings == ["A", "B"], "编号标题解析错：\(headings)")
        #expect(
            SyncEntityRegistryContract.l0IDsMissingFromDoc(registryIDs: ["A", "B", "F1"], docHeadings: headings)
                == ["F1"],
            "文档里没有的编号必须被抓到"
        )
        #expect(
            SyncEntityRegistryContract.l0IDsMissingFromRegistry(registryIDs: ["A"], docHeadings: headings) == ["B"],
            "注册表里没有的文档编号必须被抓到"
        )
    }

    // MARK: ③ notSynced 不得被实现

    @Test("实体注册表：notSynced 实体不得出现在 outbox 写入点 / 补发名单 / 上线清单")
    func notSyncedEntitiesAreNotImplemented() {
        let scan = SyncEntityRegistryContract.scan(repoRoot: Self.repoRoot)
        #expect(scan.scannedFiles > 50, "生产码一个 .swift 都没扫到 = 契约空转：扫到 \(scan.scannedFiles)")
        #expect(
            scan.outboxWrittenEntityNames == SyncEntityRegistryContract.declaredOutboxEntityNames,
            """
            注册表声明「记 outbox」的实体与生产码实际写入点不一致：
            声明 \(SyncEntityRegistryContract.declaredOutboxEntityNames.sorted())
            实际 \(scan.outboxWrittenEntityNames.sorted())
            修法：加/删 outbox 写入点都必须同时改注册表（`writesOutbox`），别让声明与实现漂移。
            """
        )
        let notSynced = Set(
            SyncEntityRegistry.entries.filter(\.syncMode.isNotSynced).compactMap { entry in
                entry.entity.map { SyncEntityRegistryContract.caseName(of: $0) }
            }
        )
        let violations = SyncEntityRegistryContract.notSyncedViolations(
            notSyncedCaseNames: notSynced,
            outboxWrittenEntityNames: scan.outboxWrittenEntityNames,
            derivedListEntityNames: SyncEntityRegistryContract.derivedListEntityNames
        )
        #expect(
            violations.isEmpty,
            """
            「不承诺」的实体被实现了（契约 §0.2：「不承诺」也是承诺）：
            \(violations.joined(separator: "\n"))
            修法：要么删掉实现，要么回契约改承诺（改契约要先经用户确认）。
            """
        )
    }

    @Test("合成：被偷偷实现的 notSynced 实体必须被抓到（契约自证有效）")
    func syntheticNotSyncedImplementationIsCaught() {
        let violations = SyncEntityRegistryContract.notSyncedViolations(
            notSyncedCaseNames: ["lyricsOnline"],
            outboxWrittenEntityNames: ["favorite", "lyricsOnline"],
            derivedListEntityNames: ["v1Synced": ["lyricsOnline"], "reconcilableEntities": []]
        )
        #expect(violations.count == 2, "写入点 + 名单各报一条，实际：\(violations)")

        let clean = SyncEntityRegistryContract.notSyncedViolations(
            notSyncedCaseNames: ["lyricsOnline"],
            outboxWrittenEntityNames: ["favorite"],
            derivedListEntityNames: ["v1Synced": ["favorite"]]
        )
        #expect(clean.isEmpty, "真不承诺的实体不得误报：\(clean)")

        // 登记自洽：notSynced 却声明了实现点（通道 / 出站 / 补发 / 装配点）→ 必须被抓到
        let badEntry = SyncEntityRegistryEntry(
            l0ID: "Z",
            entity: nil,
            title: "偷偷同步的东西",
            syncMode: .notSynced(reason: "测试"),
            channel: .changeLog,
            localTruth: SyncEntityLocalTruth(table: "z_table", rowKeyShape: "id", carrierNote: nil),
            referencesTrack: false,
            writesOutbox: true,
            reconcilesLocalTruth: true,
            repairsDanglingReferences: false,
            assemblyPoints: [
                SyncEntityAssemblyPoint(
                    platform: SyncEntityRegistry.platformIOS,
                    frame: 8,
                    detail: "不该有",
                    assertion: nil,
                    probe: nil
                ),
            ]
        )
        let selfViolations = SyncEntityRegistryContract.registrySelfConsistencyViolations([badEntry])
        #expect(
            selfViolations.count == 3,
            "notSynced + 通道/出站(含补发)/装配点三项都要报，实际：\(selfViolations)"
        )
        #expect(
            selfViolations.allSatisfy { $0.contains("`Z`") },
            "每条都要点名是哪个编号，实际：\(selfViolations)"
        )
    }

    // MARK: ④ 派生名单唯一来源

    @Test("实体注册表：派生名单在生产码里只有注册表一处（禁止第二份手写清单）")
    func derivedListsComeFromRegistryOnly() {
        let scan = SyncEntityRegistryContract.scan(repoRoot: Self.repoRoot)
        #expect(scan.scannedFiles > 50, "生产码一个 .swift 都没扫到 = 契约空转：扫到 \(scan.scannedFiles)")
        #expect(
            scan.registryDefinesEntries,
            """
            \(SyncEntityRegistryContract.registryPath) 里找不到登记表 `static let entries: [SyncEntityRegistryEntry] = [`——
            白名单空转保护失效（登记表被改名 / 搬走 / 清空）。
            """
        )
        #expect(
            scan.registryDerivedAccessors.count == SyncEntityRegistryContract.derivedAccessorNames.count,
            """
            注册表里没给出全部派生访问器：
            缺 \(SyncEntityRegistryContract.derivedAccessorNames.filter { !scan.registryDerivedAccessors.contains($0) })
            修法：散落名单一律改成「计算属性 → SyncEntityRegistry 派生」，不在这里手写第二份。
            """
        )
        #expect(
            scan.violations.isEmpty,
            """
            生产码里出现了第二份「实体能力清单」（唯一声明处 = SyncEntityRegistry，
            \(SyncEntityRegistryContract.registryPath)）：
            \(scan.violations.joined(separator: "\n"))

            修法：删掉手写清单，改成从注册表取——`SyncChangeEntity.v1Synced` /
            `SyncChangeLogDanglingRepair.reconcilableEntities` / `repairableEntities` /
            `SyncPlaybackCarryPeer.trackScopedEntities` / `SyncTrackReference.referencesTrack(_:)`
            都是派生访问器（行为与收口前逐项相同）。
            """
        )
    }

    @Test("合成：第二份手写清单 / 手写身份判定必须被抓到（契约自证有效）")
    func syntheticSecondEntityListIsCaught() {
        let secondList = """
        enum SomewhereElse {
            static let reconcilableEntities: [SyncChangeEntity] = [.favorite, .playHistory]
            static let v1Synced: [SyncChangeEntity] = [.favorite]
        }
        """
        #expect(
            SyncEntityRegistryContract.violations(inSource: secondList, relativePath: "QQPlayer/Sync/Somewhere.swift")
                .count == 2,
            "两处手写清单必须各报一条"
        )
        #expect(
            SyncEntityRegistryContract.violations(
                inSource: "return entity != .playlist",
                relativePath: "QQPlayer/Sync/SyncChangeLogMapping.swift"
            ).count == 1,
            "手写「引用歌曲」判定必须被抓到"
        )
        // 派生访问器的正确写法（计算属性 + 注册表取数）不得误报
        let derivedAccessor = """
        static var reconcilableEntities: [SyncChangeEntity] { SyncEntityRegistry.reconcilableEntities }
        static var v1Synced: [SyncChangeEntity] { SyncEntityRegistry.v1SyncedEntities }
        """
        #expect(
            SyncEntityRegistryContract.violations(
                inSource: derivedAccessor,
                relativePath: "QQPlayer/Sync/SyncDataSyncModels.swift"
            ).isEmpty,
            "派生访问器不是第二份清单，不得误报"
        )
        // 白名单文件自身必须放行（否则契约不可用）
        #expect(
            SyncEntityRegistryContract.violations(
                inSource: secondList + "return entity != .playlist",
                relativePath: SyncEntityRegistryContract.registryPath
            ).isEmpty,
            "注册表自身必须放行"
        )
    }

    // MARK: ⑤ 登记自洽 + 行为零变化

    @Test("实体注册表：登记自洽（不承诺 = 零实现；通道与能力字段互不矛盾）")
    func registryEntriesAreSelfConsistent() {
        let violations = SyncEntityRegistryContract.registrySelfConsistencyViolations(SyncEntityRegistry.entries)
        #expect(
            violations.isEmpty,
            "注册表登记自相矛盾：\n\(violations.joined(separator: "\n"))"
        )
        #expect(SyncEntityRegistry.entries.count == 9, "登记条目数变了（应为 9：A–E + F1/F2 + G/H）")
        let ids = SyncEntityRegistry.entries.map(\.l0ID)
        #expect(ids == ["A", "B", "C", "D", "E", "F1", "F2", "G", "H"], "登记顺序/编号变了：\(ids)")
    }

    @Test("实体注册表：装配申报自洽（探针必须有平台、不得积压、断言 id 唯一）")
    func assemblyDeclarationsAreSelfConsistent() {
        let violations = SyncEntityRegistryContract.assemblyDeclarationViolations(
            entries: SyncEntityRegistry.entries,
            shared: SyncEntityRegistry.sharedAssemblyPoints
        )
        #expect(
            violations.isEmpty,
            "装配申报自相矛盾：\n\(violations.joined(separator: "\n"))"
        )
    }

    @Test("合成：没平台的探针 / 积压的探针必须被抓到（契约自证有效）")
    func syntheticOrphanProbeIsCaught() {
        let orphanProbe = SyncEntityAssemblyPoint(
            platform: nil,
            frame: nil,
            detail: "声明了探针却没平台",
            assertion: nil,
            probe: .changeLogPeer
        )
        let violations = SyncEntityRegistryContract.assemblyDeclarationViolations(
            entries: [],
            shared: [orphanProbe]
        )
        // 一条「探针没平台」+ 其余探针没人引用（各一条）
        #expect(
            violations.contains { $0.contains("没有平台") },
            "没平台的探针必须被抓到：\(violations)"
        )
        #expect(
            violations.contains { $0.contains("没有任何装配点引用") },
            "没人引用的探针必须被抓到：\(violations)"
        )

        // 断言 id 重复申报
        func pointWithAssertion(_ id: String) -> SyncEntityAssemblyPoint {
            SyncEntityAssemblyPoint(
                platform: SyncEntityRegistry.platformIOS,
                frame: nil,
                detail: "重复申报",
                assertion: SyncEntityAssemblyAssertion(
                    id: id,
                    path: "QQPlayer/Sync",
                    requiredMarkers: ["x"],
                    alternativeMarkers: [],
                    guidance: "g"
                ),
                probe: nil
            )
        }
        var shared: [SyncEntityAssemblyPoint] = SyncWiringProbe.allCases.map { probe in
            SyncEntityAssemblyPoint(
                platform: SyncEntityRegistry.platformIOS,
                frame: nil,
                detail: "合法引用 \(probe.rawValue)",
                assertion: nil,
                probe: probe
            )
        }
        shared.append(pointWithAssertion("dup-id"))
        shared.append(pointWithAssertion("dup-id"))
        let duplicate = SyncEntityRegistryContract.assemblyDeclarationViolations(
            entries: [],
            shared: shared
        )
        #expect(
            duplicate == ["断言 id 重复申报：`dup-id`"],
            "重复的断言 id 必须被抓到（且合法探针引用不得误报），实际：\(duplicate)"
        )
    }

    @Test("实体注册表：派生清单与收口前口径逐项相同（行为零变化）")
    func derivedListsMatchPreCollapseBehavior() {
        // 收口前的四处手写清单（逐项抄自 45bd1fa）
        #expect(
            SyncChangeEntity.v1Synced == [.favorite, .playHistory, .playlist, .playlistItem],
            "v1Synced 变了：\(SyncChangeEntity.v1Synced)"
        )
        #expect(
            SyncChangeLogDanglingRepair.reconcilableEntities == [.favorite, .playHistory, .playlist, .playlistItem],
            "补发清单变了：\(SyncChangeLogDanglingRepair.reconcilableEntities)"
        )
        #expect(
            SyncChangeLogDanglingRepair.repairableEntities == [.favorite, .playHistory, .playlistItem],
            "悬空修复清单变了：\(SyncChangeLogDanglingRepair.repairableEntities)"
        )
        #expect(
            SyncPlaybackCarryDatabaseFacts.trackScopedEntities == [.favorite, .playHistory, .playlistItem],
            "跟歌走携带清单变了：\(SyncPlaybackCarryDatabaseFacts.trackScopedEntities)"
        )
        // 身份键要求：收口前 = `entity != .playlist`，逐项相同
        for entity in SyncChangeEntity.allCases {
            #expect(
                SyncTrackReference.referencesTrack(entity) == (entity != .playlist),
                "\(entity.rawValue) 的引用歌曲判定变了"
            )
        }
        // 门控实体（跨端续播，默认关）不在 v1 无条件清单里 —— 与收口前一致
        #expect(
            SyncChangeEntity.v1Synced.contains(.playbackPosition) == false,
            "门控实体不得混进 v1 无条件同步清单"
        )
    }
}

// MARK: - changeLog 同步前置门形状契约（2026-09-15）

/// 「曲库索引未到终态 → 不得发起 / 应答 changeLog 同步」唯一实现的**形状契约**。
///
/// 为什么单独一层：装配可达性只问「能力接上了没有」，问不出「这一刻该不该接」。
/// 2026-09-15 真机取证：安装后第一次冷启动，曲库行还没由主扫重建（`track` 表空、
/// 业务表仍在）而同步已经跑起来 —— 补发对账把 outbox 行当**本地悬空**清掉（真值
/// 静默从同步层消失），应答拉取的行全部拿不到身份键（对端整批判「未定位」）。
///
/// 判据（同 `SyncIdentityContract` 风格）：①该判定只有**一处实现**（白名单 = 门文件），
/// ②那段索引事实只有门在读（别处再读一遍 = 第二处判断，本包要防的正是这个形状），
/// ③iOS 装配点真的在**调用**这个门（白名单空转 → 必须失败），④合成源码自证能抓到违例。
enum SyncIndexingPreconditionContract {
    /// 唯一允许定义该判定的生产文件（`IndexingGate` = 索引门的唯一实现处，
    /// 「等索引结束」与「能不能同步」同一家族同一文件）。
    static let gateDefinitionPath = "QQPlayer/Services/IndexingGate.swift"

    /// 判定入口的调用形态（定义处 = `static func isReadyForChangeLogSync(`，
    /// 调用处 = `IndexingGate.isReadyForChangeLogSync(`）。
    static let gateName = "isReadyForChangeLogSync"

    /// 门所依赖的**索引事实**名（生产只在事实生产处与门内出现）。
    static let terminalStateFactName = "hasReachedIndexingTerminalState"

    /// 唯一允许生产该事实的文件（= `LibraryIndexer`，`IndexingStateProviding` 的生产实现）。
    static let factProducerPaths = ["QQPlayer/Services/LibraryIndexer.swift"]

    /// 唯一必须在装配前调用门的文件（iOS 数据同步端唯一装配点）。
    static let iosAssemblyPath = "QQPlayer/Services/IOSPassiveSyncCenter.swift"

    /// Mac 侧同类装配点（2026-09-16 补）：连接就绪自动跑「同步数据」的唯一入口
    /// （`MacDataSyncAutoRunner`）。两端口径必须一致——只接一端 = 另一端照样在曲库行
    /// 没建立时跑同步（补发对账清 outbox、对端整批判「未定位」）。
    static let macAssemblyPath = "QQPlayer/Mac/SyncHostCenter.swift"

    /// 生产码扫描根（测试 / harness 是 seam，允许假事实源，不在扫描范围）。
    static let productionRoot = "QQPlayer"

    /// 纯函数：一份生产源码里违禁的标记（空 = 该文件合规）。
    static func violations(inSource source: String, relativePath: String) -> [String] {
        var result: [String] = []
        // ① 判定的第二处定义（同名函数出现在门文件之外）
        if relativePath != gateDefinitionPath,
           source.contains("func \(gateName)(") {
            result += ["第二处「能不能同步」判定：`func \(gateName)(`"]
        }
        // ② 索引终态事实的第二处读取（绕过门直接看事实 = 两套口径，改一处漏一处）
        if relativePath != gateDefinitionPath,
           !factProducerPaths.contains(relativePath),
           source.contains(terminalStateFactName) {
            result += ["绕过前置门直接判定索引终态：`\(terminalStateFactName)`（只允许门与事实生产处出现）"]
        }
        return result
    }
}

extension SyncIndexingPreconditionContract {
    struct ScanResult {
        var scannedFiles: Int = 0
        /// 违禁明细（`相对路径 → 标记`）
        var violations: [String] = []
        /// 门文件自身是否真的持有判定实现（false = 白名单空转，必须失败）
        var gateDefinesDecision = false
        /// iOS 装配点是否真的在装配前调用门（false = 门没人用，等于没修）
        var iosAssemblyCallsGate = false
        /// Mac 装配点是否也调用了同一入口（false = 两端口径不一致，Mac 侧仍是旧行为）
        var macAssemblyCallsGate = false
    }

    /// 生产码全量扫描（文件系统访问只在这里；fail-closed 由调用方断言 `scannedFiles`）。
    static func scan(repoRoot: URL) -> ScanResult {
        var result = ScanResult()
        for url in SyncWiringContract.swiftSources(repoRoot: repoRoot, at: productionRoot) {
            let relativePath = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            result.scannedFiles += 1
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                result.violations.append("\(relativePath)：读取失败（fail-closed，不跳过）")
                continue
            }
            if relativePath == gateDefinitionPath {
                result.gateDefinesDecision = source.contains("func \(gateName)(")
                    && source.contains(terminalStateFactName)
            }
            if relativePath == iosAssemblyPath {
                result.iosAssemblyCallsGate = source.contains("IndexingGate.\(gateName)(")
            }
            if relativePath == macAssemblyPath {
                result.macAssemblyCallsGate = source.contains("IndexingGate.\(gateName)(")
            }
            result.violations += violations(inSource: source, relativePath: relativePath)
                .map { "\(relativePath) → \($0)" }
        }
        return result
    }
}

// MARK: - 前置门形状测试

struct SyncIndexingPreconditionContractTests {
    static let repoRoot = SyncWiringContractTests.repoRoot

    @Test("changeLog 同步前置门：生产码里只有一处实现，且两端装配点真的都在调用")
    func productionHasSinglePreconditionGate() {
        let result = SyncIndexingPreconditionContract.scan(repoRoot: Self.repoRoot)
        #expect(
            result.scannedFiles > 50,
            "生产码一个 .swift 都没扫到 = 契约空转：扫到 \(result.scannedFiles)"
        )
        #expect(
            result.gateDefinesDecision,
            """
            白名单文件 \(SyncIndexingPreconditionContract.gateDefinitionPath) 里找不到前置门实现
            （`\(SyncIndexingPreconditionContract.gateName)` + `\(SyncIndexingPreconditionContract.terminalStateFactName)`）
            ——契约的空转保护失效（判定搬走了 / 改名了）。
            """
        )
        #expect(
            result.iosAssemblyCallsGate,
            """
            \(SyncIndexingPreconditionContract.iosAssemblyPath) 装配数据同步端前**没有**调用前置门
            `IndexingGate.\(SyncIndexingPreconditionContract.gateName)(`：曲库行还没建立时同步照样会跑
            （补发对账清 outbox、对端整批判「未定位」），等于没修。
            """
        )
        #expect(
            result.macAssemblyCallsGate,
            """
            \(SyncIndexingPreconditionContract.macAssemblyPath) 的连接就绪自动同步**没有**调用前置门
            `IndexingGate.\(SyncIndexingPreconditionContract.gateName)(`：Mac 侧冷启动（曲库行重建中）
            仍会跑「本地真值对账」——把「暂时查不到」当本地悬空清掉 outbox 行，真值静默消失。
            修法：与 iOS 同一入口（判定只有一处），门关时订阅索引信号、终态到达再补跑。
            """
        )
        #expect(
            result.violations.isEmpty,
            """
            生产码里出现了第二处「曲库索引未到终态 → 不同步」判定（唯一实现 = \
            \(SyncIndexingPreconditionContract.gateDefinitionPath) 的 \
            IndexingGate.\(SyncIndexingPreconditionContract.gateName)）：
            \(result.violations.joined(separator: "\n"))

            修法：删掉第二处判定，改为在装配/发起前调用唯一入口——判定所需的索引事实
            经 `IndexingStateProviding` 注入（生产实现 = LibraryIndexer），别处不得直接读
            `\(SyncIndexingPreconditionContract.terminalStateFactName)` 再自己下结论。
            """
        )
    }

    @Test("合成「第二处判定」必须被抓到（契约自证有效，fail-closed）")
    func syntheticSecondDecisionIsCaught() {
        let bypass = """
        func attachDataSync(to session: SyncPeerSession) {
            guard !indexing.hasReachedIndexingTerminalState else { return }
            let peer = SyncChangeLogPeer(session: session)
        }
        """
        #expect(
            SyncIndexingPreconditionContract.violations(
                inSource: bypass,
                relativePath: "QQPlayer/Sync/SomeOtherAssembly.swift"
            ).count == 1,
            "绕过前置门直接读索引终态事实必须被抓到"
        )
        #expect(
            SyncIndexingPreconditionContract.violations(
                inSource: bypass,
                relativePath: SyncIndexingPreconditionContract.factProducerPaths[0]
            ).isEmpty,
            "事实生产处（LibraryIndexer）自身必须放行，否则契约不可用"
        )

        let secondDefinition = """
        enum SomeOtherGate {
            static func isReadyForChangeLogSync(_ source: IndexingStateProviding) -> Bool {
                !source.isIndexing
            }
        }
        """
        #expect(
            SyncIndexingPreconditionContract.violations(
                inSource: secondDefinition,
                relativePath: "QQPlayer/Sync/SomeOtherGate.swift"
            ).count == 1,
            "同名判定的第二处定义必须被抓到"
        )
        #expect(
            SyncIndexingPreconditionContract.violations(
                inSource: secondDefinition,
                relativePath: SyncIndexingPreconditionContract.gateDefinitionPath
            ).isEmpty,
            "门文件自身（定义处）必须放行"
        )
    }
}

// MARK: - 「按实体披露」单一投影契约（INV-18 后半句 / INV-19，2026-09-15）

/// 「按实体披露」唯一实现的**形状契约**：扫生产码 + 扫文案库，断言三件事——
/// ① 界面层**不得自算数字 / 自行枚举实体**（明细行只能来自 `SyncEntityOutcomeDisclosure`）；
/// ② 披露维度**完整**：每个结果类别有披露归属、每条实体有五语文案（新增即红）；
/// ③ 合成「界面层自算数字」必须被抓到（fail-closed，证明断言不空转）。
///
/// 为什么单独一层：行为用例只能发现「算错了 / 少一行」，发现不了「界面层又自己算了一遍」
/// ——那正是「同一语义多处手工维护」的形状（先例：封面解析 5 处并行实现）。
///
/// 判据（同 `SyncIdentityContract` / `SyncOutcomeContract` 风格）：纯函数判定 + 合成源码自证 + fail-closed。
enum SyncEntityDisclosureContract {
    /// 唯一投影（明细行的唯一来源）。
    static let disclosurePath = "QQPlayer/Sync/SyncEntityOutcomeDisclosure.swift"
    /// 界面层目录：这里出现的自算写法一律红。
    static let uiRoots = ["QQPlayer/Mac", "QQPlayer/Views"]
    /// 界面层**禁止**出现的写法（每条 = 一种「界面层自己算 / 自己枚举」的形状）。
    static let forbiddenMarkers: [(marker: String, message: String)] = [
        (".count(for:", "界面层直接读结果计数槽位 —— 数字必须由投影给出（INV-19）"),
        ("entityGroups(for:", "界面层自行做实体分桶 —— 分组只有一处（tally.entityGroups）"),
        ("SyncEntityRegistry", "界面层自行枚举实体名单 —— 分桶维度 = 注册表（INV-18）"),
        ("SyncChangeEntity", "界面层自行枚举实体 —— 明细行由投影给出"),
        ("sync_run_data_entity_", "界面层自行拼实体文案 key —— 行文案由投影给出"),
    ]

    /// 五语文案目录（key 齐全性检查用）。
    static let languages = ["en", "fr", "ru", "zh-Hans", "zh-Hant"]

    /// 纯函数：一份界面层源码里的违禁写法（空 = 合规）。
    static func violations(inSource source: String) -> [String] {
        forbiddenMarkers.compactMap { marker, message in
            source.contains(marker) ? "`\(marker)` \(message)" : nil
        }
    }

    /// 纯函数：各语言文案源码里**缺失**的 key（合成自证就喂它一份「少一个 key」的输入）。
    static func missingKeys(_ keys: [String], sources: [String: String]) -> [String] {
        var missing: [String] = []
        for (language, source) in sources.sorted(by: { $0.key < $1.key }) {
            for key in keys where !source.contains("\"\(key)\" = ") {
                missing.append("\(language) 缺 `\(key)`")
            }
        }
        return missing
    }

    /// 明细行需要五语齐全的 key：区标题 + 行格式 + 每条实体的名字 + 每个类别的名字与说明。
    static var disclosureKeys: [String] {
        var keys = [
            SyncEntityOutcomeDisclosure.breakdownTitleKey,
            SyncEntityOutcomeDisclosure.rowFormatKey,
        ]
        keys += SyncChangeEntity.allCases.map { SyncEntityOutcomeDisclosure.entityLabelKey($0) }
        keys += SyncRowOutcome.allCases.map { SyncEntityOutcomeDisclosure.outcomeLabelKey($0) }
        keys += SyncRowOutcome.allCases.compactMap { SyncEntityOutcomeDisclosure.outcomeHintKey($0) }
        // F2（2026-09-16）：文件层（歌词）披露行的 key 同样要求五语齐全。
        keys += SyncEntityOutcomeDisclosure.lyricsKeys
        // 2026-09-25「结果区默认折叠」：折叠态两个新 key（详情标签 / 无改动兜底）同样五语齐全。
        keys += [
            SyncEntityOutcomeDisclosure.detailLabelKey,
            SyncEntityOutcomeDisclosure.nothingNewKey,
        ]
        // INV-22 另一半（2026-09-16）：文件层（封面）披露行的 key 也要求五语齐全。
        keys += SyncEntityOutcomeDisclosure.coverKeys
        return keys
    }

    struct UITreeScan {
        var scannedFiles = 0
        var violations: [String] = []
    }

    /// 界面层全量扫描（文件系统访问只在这里；fail-closed 由调用方断言 `scannedFiles`）。
    static func scanUITree(repoRoot: URL) -> UITreeScan {
        var result = UITreeScan()
        for root in uiRoots {
            for url in SyncWiringContract.swiftSources(repoRoot: repoRoot, at: root) {
                result.scannedFiles += 1
                let relativePath = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                    result.violations.append("\(relativePath)：读取失败（fail-closed，不跳过）")
                    continue
                }
                result.violations += violations(inSource: source).map { "\(relativePath) → \($0)" }
            }
        }
        return result
    }
}

// MARK: - 按实体披露形状测试

struct SyncEntityDisclosureContractTests {
    static let repoRoot = SyncWiringContractTests.repoRoot

    @Test("按实体披露：界面层不得自算数字 / 自行枚举实体（明细行只能来自唯一投影）")
    func uiConsumesDisclosureOnly() {
        let scan = SyncEntityDisclosureContract.scanUITree(repoRoot: Self.repoRoot)
        #expect(
            scan.scannedFiles > 50,
            "界面层一个 .swift 都没扫到 = 契约空转：扫到 \(scan.scannedFiles)"
        )
        #expect(
            scan.violations.isEmpty,
            """
            界面层出现了「自己算数字 / 自己枚举实体」的写法（明细行必须来自
            \(SyncEntityDisclosureContract.disclosurePath) 的 `SyncEntityOutcomeDisclosure.rows(_:)`）：
            \(scan.violations.joined(separator: "\n"))

            修法：Mac 面板取 `SyncEntityOutcomeDisclosure.rows(report.tally)`、iOS 设置页取
            `SyncEntityOutcomeDisclosure.rows(summary.tally)`，行文案用 `rowLabel(_:)`。
            """
        )
        // 白名单文件必须在场，且真的是明细行的入口（防「投影被删/改名，扫描变空转」）
        let url = Self.repoRoot.appendingPathComponent(SyncEntityDisclosureContract.disclosurePath)
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!source.isEmpty, "读不到投影源码 = 契约空转（fail-closed）")
        #expect(source.contains("static func rows("), "投影必须提供唯一入口 rows(_:)")
        #expect(source.contains("static func disclosesByEntity("), "投影必须对每个类别表态是否按实体披露")
    }

    @Test("合成「界面层自算数字」必须被抓到（契约自证有效）")
    func syntheticUISelfComputationIsCaught() {
        let selfComputed = """
            let rows = report.tally.entityGroups(for: .unresolved)
            let label = "sync_run_data_entity_" + entity.rawValue
            if SyncEntityRegistry.entityOrder.isEmpty { }
        """
        #expect(
            SyncEntityDisclosureContract.violations(inSource: selfComputed).count == 3,
            "界面层自算分桶 / 自拼文案 key / 自枚举注册表都必须被抓到"
        )

        let clean = """
            let rows = SyncEntityOutcomeDisclosure.rows(report.tally)
            Text(SyncEntityOutcomeDisclosure.breakdownTitleKey.localized)
            Text(SyncEntityOutcomeDisclosure.rowLabel(row))
        """
        #expect(
            SyncEntityDisclosureContract.violations(inSource: clean).isEmpty,
            "正规写法（消费投影）不得误报"
        )
    }

    @Test("披露维度完整：类别有归属、实体有位置、五语文案齐全（新增实体/类别即红）")
    func disclosureCoversEveryCaseAndLanguage() throws {
        // ① 结果类别：`disclosesByEntity` 的集合必须与披露顺序逐项一致（漏表态 / 重复表态即红）
        let disclosed = SyncRowOutcome.allCases.filter(SyncEntityOutcomeDisclosure.disclosesByEntity)
        #expect(
            Set(disclosed) == Set(SyncEntityOutcomeDisclosure.entityDisclosureOrder),
            """
            按实体披露的类别集合与顺序表不一致（新增 SyncRowOutcome 必须两边同时表态）：
            开关给出 \(disclosed.map { $0 }) / 顺序表 \(SyncEntityOutcomeDisclosure.entityDisclosureOrder.map { $0 })
            """
        )
        #expect(
            SyncEntityOutcomeDisclosure.entityDisclosureOrder.count == disclosed.count,
            "同一个类别不得在披露顺序里重复出现"
        )
        // ② 缺口行 + 计数行 = 全部类别（新增类别漏归宿即红）
        #expect(
            Set(SyncEntityOutcomeDisclosure.gapOrder + SyncEntityOutcomeDisclosure.countOrder)
                == Set(SyncRowOutcome.allCases),
            "有类别没有展示归宿（新增 SyncRowOutcome 必须同时进 gapOrder / countOrder）"
        )
        // ③ 实体：注册表顺序必须覆盖全部实体（新增实体漏登记即红）
        #expect(
            Set(SyncEntityRegistry.entityOrder) == Set(SyncChangeEntity.allCases),
            "注册表实体顺序没覆盖全部实体：\(SyncEntityRegistry.entityOrder.map(\.rawValue))"
        )

        // ④ 文案：明细行相关 key 五语齐全（新增实体 = 新增 key，缺一个就红）
        var sources: [String: String] = [:]
        for language in SyncEntityDisclosureContract.languages {
            let url = Self.repoRoot
                .appendingPathComponent("QQPlayer/Resources/\(language).lproj/Localizable.strings")
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record("读不到 \(language) 文案（fail-closed，不跳过）：\(url.path)")
                continue
            }
            sources[language] = source
        }
        #expect(
            sources.count == SyncEntityDisclosureContract.languages.count,
            "五语文案没读全：\(sources.keys.sorted())"
        )
        let missing = SyncEntityDisclosureContract.missingKeys(
            SyncEntityDisclosureContract.disclosureKeys,
            sources: sources
        )
        #expect(missing.isEmpty, "缺文案 → 界面直接显示 key 原文：\(missing)")

        // 合成自证：把一份文案里的一个 key 改掉 → 必须被判定为缺失（检查不空转）
        var synthetic = sources
        let english = try #require(sources["en"], "en 文案必须在场")
        synthetic["en"] = english.replacingOccurrences(
            of: "\"sync_run_data_entity_playlist_item\" = ",
            with: "\"not_this_key\" = "
        )
        #expect(
            SyncEntityDisclosureContract.missingKeys(
                SyncEntityDisclosureContract.disclosureKeys,
                sources: synthetic
            ).contains("en 缺 `sync_run_data_entity_playlist_item`"),
            "文案检查不得空转（合成缺 key 必须报出来）"
        )
    }
}

// MARK: - 封面「不可跨端引用」契约（INV-22 / INV-23，2026-09-15 防回归守护）

/// 歌单自定义封面路径**不是可跨端直接引用的值**：`playlist.custom_cover_image_path` 是
/// **设备本地相对路径**，随 C 的载荷搭车到对端后必然加载不出（历史事故：对端歌单永远
/// 显示默认封面，且零报错）。行为已经正确（`SyncChangeLogApplier` 更新保留本端 /
/// 新建置 nil），但此前**只有行为、没有守护**（INV-22/23 标着「✗ 无守护」）。
///
/// 本契约把那句「永远不得作为跨端值」变成可执行断言：
/// ① `Sync/` 生产码里不得出现**第二处**封面跨端消费点（白名单见下，各自口径写清）；
/// ② 白名单里的**规则本身**必须在场且形状正确——applier 里每一处 `customCoverImagePath`
///    只能出现在注释或 `customCoverImagePath: nil`（既不许读对端快照的值，也不许把对端值
///    写进本端业务行）；
/// ③ 合成「把对端封面写进本端」必须被抓到（fail-closed，证明断言不空转）。
///
/// 白名单（四条，均为**现状事实**，不是理想态）：
/// - `SyncDataSnapshots.swift`：wire 字段声明处（`custom_cover_image_path` 的 snake_case 键）；
/// - `SyncEntityRegistry.swift`：**实体登记处**——H（歌单封面）条目的 `carrierNote` 以散文
///   引用该 wire 键（说明「随 C 的载荷搭车但无独立通道」），是**登记/文档**而非消费点
///   （维护者复核时抓到：漏了这条白名单，本用例自己就是红的）；
/// - `SyncChangeLogMapping.swift`：**捕获侧**——本端路径随 C 的载荷搭车发出（对端不消费；
///   真要跨端封面得另做 `@cover/{content_hash}` 式的文件通道，属未做的功能，不在本包范围）；
/// - `SyncChangeLogApplier.swift`：**接收侧规则本身**（本包守护的对象）。
///
/// 判据（同 `SyncIdentityContract` 风格）：纯函数判定 + 合成源码自证 + fail-closed。
enum SyncCoverValueContract {
    /// 生产码扫描根。
    static let productionRoot = "QQPlayer/Sync"
    /// 接收侧规则（唯一允许「提到封面」并做决策的地方）。
    static let applierPath = "QQPlayer/Sync/SyncChangeLogApplier.swift"
    /// wire 字段声明处（snake_case 键只准在这里出现）。
    static let payloadDeclarationPath = "QQPlayer/Sync/SyncDataSnapshots.swift"
    /// 实体登记处（H 条目以散文引用 wire 键；登记 ≠ 消费）。
    static let registryPath = "QQPlayer/Sync/SyncEntityRegistry.swift"
    /// 捕获侧（现状：本端路径搭车发出，无独立通道）。
    static let capturePath = "QQPlayer/Sync/SyncChangeLogMapping.swift"

    /// 允许提到封面路径的文件（白名单之外的任何一处 = 新的跨端消费点）。
    static var whitelist: [String] { [applierPath, payloadDeclarationPath, capturePath, registryPath] }

    /// 纯函数：一份 `Sync/` 源码里的违禁写法（空 = 该文件合规）。
    static func violations(inSource source: String, relativePath: String) -> [String] {
        var hits: [String] = []
        // ① wire 键只准在声明处 / 登记处出现（登记处是散文引用，不是消费点）
        if relativePath != payloadDeclarationPath, relativePath != registryPath,
           source.contains("custom_cover_image_path") {
            hits.append(
                "出现了 wire 键 `custom_cover_image_path`（只准在声明处 \(payloadDeclarationPath) / 登记处 \(registryPath)）"
            )
        }
        // ② 属性名的出现只准在白名单文件里
        guard source.contains("customCoverImagePath") else { return hits }
        if !whitelist.contains(relativePath) {
            hits.append(
                """
                出现了 `customCoverImagePath`：封面是**设备本地路径**，不得作为跨端值读写
                （白名单 = \(whitelist.joined(separator: " / "))）
                """
            )
            return hits
        }
        // ③ 接收侧规则：不许读对端值、不许把对端值写进本端行（注释与「置 nil」放行）
        guard relativePath == applierPath else { return hits }
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("customCoverImagePath") else { continue }
            if trimmed.hasPrefix("//") { continue }
            if trimmed.contains("customCoverImagePath: nil") { continue }
            hits.append("applier 第 \(index + 1) 行越界使用了封面属性：`\(trimmed)`")
        }
        return hits
    }

    /// 纯函数：接收侧**规则本身在场**（「新建置 nil」这条断言丢了 = 守护失效）。
    static func ruleIsPresent(inApplierSource source: String) -> Bool {
        source.contains("customCoverImagePath: nil")
    }
}

struct SyncCoverValueContractTests {
    static let repoRoot = SyncWiringContractTests.repoRoot

    @Test("封面（INV-22/23）：只有接收侧一条规则，Sync/ 里没有第二处跨端封面消费点")
    func productionHasSingleCoverRule() {
        var scannedFiles = 0
        var violations: [String] = []
        var applierSource = ""
        for url in SyncWiringContract.swiftSources(
            repoRoot: Self.repoRoot,
            at: SyncCoverValueContract.productionRoot
        ) {
            scannedFiles += 1
            let relativePath = url.path.replacingOccurrences(of: Self.repoRoot.path + "/", with: "")
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                violations.append("\(relativePath)：读取失败（fail-closed，不跳过）")
                continue
            }
            if relativePath == SyncCoverValueContract.applierPath { applierSource = source }
            violations += SyncCoverValueContract.violations(inSource: source, relativePath: relativePath)
                .map { "\(relativePath) → \($0)" }
        }
        #expect(scannedFiles > 30, "Sync/ 一个 .swift 都没扫到 = 契约空转：扫到 \(scannedFiles)")
        #expect(
            violations.isEmpty,
            """
            封面路径出现了新的跨端消费点（或接收侧规则被改写）：
            \(violations.joined(separator: "\n"))

            修法：跨端封面若要真支持，必须另做**按内容指纹寻址的文件通道**（仿
            `@lyrics/{content_hash}` 做 `@cover/{content_hash}`），不得直接引用对端设备路径；
            本端新建歌单的封面一律置 nil、更新时保留本端值。
            """
        )
        #expect(
            !applierSource.isEmpty,
            "读不到接收侧源码 = 契约空转（fail-closed）：\(SyncCoverValueContract.applierPath)"
        )
        #expect(
            SyncCoverValueContract.ruleIsPresent(inApplierSource: applierSource),
            """
            接收侧「新建歌单置 nil」这条规则不见了（`customCoverImagePath: nil`）——
            对端设备路径会被原样写进本端业务行（INV-23 的历史事故形状）。
            """
        )
    }

    @Test("合成「对端封面写进本端」必须被抓到（契约自证有效）")
    func syntheticPeerCoverWriteIsCaught() {
        // ① 接收侧把对端快照里的封面写进本地行 → 红
        let applierWrite = """
            if let existing = try Playlist.filter(Column("slug") == snapshot.slug).fetchOne(db) {
                var updated = existing
                updated.customCoverImagePath = snapshot.customCoverImagePath
                try updated.update(db)
            }
        """
        #expect(
            SyncCoverValueContract.violations(
                inSource: applierWrite,
                relativePath: SyncCoverValueContract.applierPath
            ).count == 1,
            "接收侧写入对端封面路径必须被抓到"
        )

        // ② 别的 Sync 文件新增一处封面读取（第二消费点）→ 红
        let secondConsumer = """
            let cover = row.customCoverImagePath
            try database.updatePlaylistCustomCover(playlistId: id, imagePath: cover)
        """
        #expect(
            SyncCoverValueContract.violations(
                inSource: secondConsumer,
                relativePath: "QQPlayer/Sync/SyncChangeLogPeer.swift"
            ).count == 1,
            "白名单外的封面消费点必须被抓到"
        )

        // ③ 合成「删掉置 nil 规则」→ 规则在场检查必须报红
        let ruleRemoved = """
            try Playlist(
                id: nil, slug: snapshot.slug, title: snapshot.title,
                createdAt: snapshot.createdAt, updatedAt: snapshot.updatedAt,
                lastPlayedAt: snapshot.lastPlayedAt, folderPath: snapshot.folderPath,
                isFolderSynced: snapshot.isFolderSynced, lastFolderSync: snapshot.lastFolderSync,
                customCoverImagePath: snapshot.customCoverImagePath
            ).insert(db)
        """
        #expect(
            !SyncCoverValueContract.ruleIsPresent(inApplierSource: ruleRemoved),
            "规则被换成「照抄对端值」时必须判定为规则不在场"
        )

        // ④ 正规写法不得误报：注释 + 置 nil + 捕获侧搭车 + 声明处
        let clean = """
            // 封面：保持本端值（不写对端设备路径，见上方 INV-23）
            try updated.update(db)
            _ = Playlist(
                id: nil, slug: snapshot.slug, title: snapshot.title,
                createdAt: snapshot.createdAt, updatedAt: snapshot.updatedAt,
                lastPlayedAt: snapshot.lastPlayedAt, folderPath: snapshot.folderPath,
                isFolderSynced: snapshot.isFolderSynced, lastFolderSync: snapshot.lastFolderSync,
                customCoverImagePath: nil
            ).insert(db)
        """
        #expect(
            SyncCoverValueContract.violations(
                inSource: clean,
                relativePath: SyncCoverValueContract.applierPath
            ).isEmpty,
            "注释 + 置 nil 是规则本身，不得误报"
        )
        #expect(SyncCoverValueContract.ruleIsPresent(inApplierSource: clean))

        let captureSide = """
            let snapshot = SyncPlaylistSnapshot(
                slug: playlist.slug,
                customCoverImagePath: playlist.customCoverImagePath
            )
        """
        #expect(
            SyncCoverValueContract.violations(
                inSource: captureSide,
                relativePath: SyncCoverValueContract.capturePath
            ).isEmpty,
            "捕获侧现状（本端路径搭车）在白名单内，不得误报"
        )
        #expect(
            SyncCoverValueContract.violations(
                inSource: captureSide,
                relativePath: "QQPlayer/Sync/SyncDataSnapshots.swift"
            ).isEmpty,
            "声明处不得误报"
        )
    }
}
