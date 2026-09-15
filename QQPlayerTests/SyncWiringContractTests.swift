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

    /// 全部装配可达性断言。新增「某平台专属装配点」时在这里补一条，别只写单测。
    static let requirements: [Requirement] = [
        Requirement(
            id: "ios-data-sync-peer-attached",
            path: "QQPlayer/Services/IOSPassiveSyncCenter.swift",
            requiredMarkers: ["SyncChangeLogPeer("],
            alternativeMarkers: [["session.peerHelloValue?.deviceID", "IOSPassiveDataSyncLogic"]],
            guidance: """
            iOS 数据同步端没有装配点：Mac 推来的帧 9 被静默丢弃、Mac 的帧 8 无人应答 → 两端播放数据永不通（2026-09-13 那个上线级缺陷）。
            请检查 IOSPassiveSyncCenter 是否在会话 ready（attachDataSync）时构造 SyncChangeLogPeer，且游标 peerID 取自对端 hello 的 Device ID（session.peerHelloValue?.deviceID，或经 IOSPassiveDataSyncLogic.dataSyncPeerID 同口径）。
            """
        ),
        Requirement(
            id: "mac-data-sync-entry-attached",
            path: "QQPlayer/Mac",
            requiredMarkers: ["SyncDataSyncCoordinator("],
            alternativeMarkers: [],
            guidance: """
            Mac 侧没有「同步数据」用户入口：核心层 SyncDataSyncCoordinator 写好了但用户点不到 → 能力等于不存在。
            请检查 MacSyncDataViewModel（或新的 Mac 视图模型）是否构造 SyncDataSyncCoordinator(session:)，并接到同步页的「同步数据」按钮上。
            """
        ),
        Requirement(
            id: "mac-playback-carry-attached",
            path: "QQPlayer/Mac/MacSyncCoordinatorFactory.swift",
            requiredMarkers: ["SyncPlaybackCarryPeer("],
            alternativeMarkers: [],
            guidance: """
            跟歌走链路失去装配：推 / 拉歌时播放数据不再跟随传输 → R3b 能力静默失效（要用户重新同步数据才补回来）。
            请检查 MacSyncCoordinatorFactory 里 SyncCollectionSyncCoordinator 的 playbackCarry 实参是否仍传 SyncPlaybackCarryPeer(session:libraryRoot:peerID:)。
            """
        ),
        Requirement(
            id: "frame-8-9-handler-present",
            path: "QQPlayer/Sync/SyncChangeLogPeer.swift",
            requiredMarkers: ["case .changeLogPull:", "case .changeLogPush:"],
            alternativeMarkers: [],
            guidance: """
            帧 8/9 的唯一处理器没了（分支被删 / 改名）：全仓再没有地方响应播放数据同步帧 → 帧 8/9 变成死协议。
            请检查 SyncChangeLogPeer 的帧分发表是否仍有 case .changeLogPull: / case .changeLogPush: 两个分支（类型本身存在于 QQPlayer/Sync/SyncChangeLogPeer.swift）。
            """
        ),
        Requirement(
            id: "frame-8-9-numbers-frozen",
            path: "QQPlayer/Sync/SyncFrame.swift",
            requiredMarkers: ["case changeLogPull = 8", "case changeLogPush = 9"],
            alternativeMarkers: [],
            guidance: """
            帧号被改动了：帧 8/9 是跨端线上契约（两端版本可能不同步升级），改号 = 老版本对端解错帧、同步静默错乱。
            请把 SyncFrame.FrameType 的 changeLogPull 恢复到 = 8、changeLogPush 恢复到 = 9（新增帧只能用未占用的号段）。
            """
        ),
        Requirement(
            id: "identity-entry-implemented-and-wired",
            path: "QQPlayer/Sync/SyncChangeLogMapping.swift",
            requiredMarkers: [
                "extension SyncContentHashResolver: SyncIdentityResolving",
                "SyncLyricsContentMapping(identity:",
            ],
            alternativeMarkers: [],
            guidance: """
            歌曲身份解析的入口实现断了：`SyncContentHashResolver` 不再声明遵守 `SyncIdentityResolving`，
            或歌词映射不再从入口构造（`SyncLyricsContentMapping(identity:)`）——两条都是「入口空转」的形状：
            编译能过（协议可选遵守）、下游各自拿闭包，漏接线一处就静默。
            请检查 QQPlayer/Sync/SyncChangeLogMapping.swift：`SyncContentHashResolver` 必须有 `: SyncIdentityResolving` 遵守声明，
            `.live(database:)` 必须走 `SyncLyricsContentMapping(identity: SyncContentHashResolver(database:))`。
            """
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

    // MARK: 地基检查

    @Test("仓库根与断言清单解析正确（扫描前的地基检查）")
    func scanScopeResolves() {
        let marker = Self.repoRoot.appendingPathComponent("QQPlayer/Sync/SyncChangeLogPeer.swift")
        #expect(FileManager.default.fileExists(atPath: marker.path), "仓库根解析错了：\(Self.repoRoot.path)")
        #expect(SyncWiringContract.requirements.count >= 4, "装配断言条数异常：\(SyncWiringContract.requirements.count)")
        let ids = SyncWiringContract.requirements.map(\.id)
        #expect(Set(ids).count == ids.count, "断言 id 有重复：\(ids)")
    }

    // MARK: 契约自证有效（合成源码 —— 防止断言空转）

    @Test("合成缺装配源码必须被抓到（契约自证有效的关键用例）")
    func syntheticMissingWiringIsCaught() {
        let requirement = SyncWiringContract.requirements[0]
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
        let missing = SyncWiringContract.missingMarkers(inSource: source, requirement: SyncWiringContract.requirements[0])
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
}

// MARK: - 身份解析「禁止第二实现」契约（2026-09-15 身份入口包）

/// 「歌曲身份解析」（stable_id ↔ content_hash）唯一入口的**形状契约**：扫生产码，断言两件事
/// 各自只有一处实现——① 身份 SQL（两个方向）；② 用闭包构造身份映射。
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

    /// 身份解析 SQL 的形态（stableId → content_hash / content_hash → stableId）。
    static let identitySQLMarkers = [
        "content_hash FROM track WHERE stable_id",
        "stable_id FROM track WHERE content_hash",
    ]

    /// 闭包式构造身份映射的标记（`SyncLyricsContentMapping(contentHashForStableId:…)`）。
    /// 注意带冒号：`mapping.stableIdForContentHash(x)` 这类**读**调用不匹配。
    static let closureWiringMarkers = [
        "contentHashForStableId:",
        "stableIdForContentHash:",
    ]

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
            result.violations.isEmpty,
            """
            生产码里出现了第二处「歌曲身份解析」（唯一入口 = SyncIdentityResolving，\
            生产实现 = QQPlayer/Sync/SyncChangeLogMapping.swift 的 SyncContentHashResolver）：
            \(result.violations.joined(separator: "\n"))

            修法：删掉第二处实现，改为依赖入口——① 需要 stableId ↔ content_hash 就注入/持有
            `any SyncIdentityResolving`；② 需要身份映射就走 `SyncLyricsContentMapping(identity:)` /
            `.live(database:)`（闭包构造只允许留在测试 seam 一侧）。
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
            SyncIdentityContract.violations(inSource: sql, relativePath: SyncIdentityContract.entryImplementationPath).isEmpty,
            "入口文件自身必须放行（否则契约不可用）"
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
}
