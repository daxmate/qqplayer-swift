//
//  SyncDeletionNonPropagationContractTests.swift
//  QQPlayerTests
//
//  INV-13「删除不跨端传播」的**静态契约**（2026-09-17 立）。
//
//  背景：`docs/sync-invariants.md` 的 INV-13 早就写明语义（2026-09-10 用户拍板：
//  取消收藏 / 删歌单 / 移除歌单项等删除**只在本地生效**），也写明了缺口——
//  「delete 判定只准出现在 `SyncChangeLogDeletionPolicy.swift`」这条**只活在文件头注释里**，
//  没有断言兜底。注释拦不住下一次「顺手在别处再写一处判定」。
//
//  立本条时实测到一处真实漂移：`SyncLWWReconcile` 的平局裁决裸写
//  `remote.opValue == .delete && local.opValue == .upsert` → 已收进
//  `SyncChangeLogDeletionPolicy.tieBreakPrefersRemoteDelete`（语义逐字保留）。
//
//  四条契约（全部 fail-closed：读不到源码/目录 = 红）：
//   (a) 判定唯一：生产代码（`QQPlayer/**`，注释除外）里不得出现 delete 判定形状，
//       唯一白名单 = `SyncChangeLogDeletionPolicy.swift`
//   (b) 装配齐全：四个消费点必须走 `SyncChangeLogDeletionPolicy`（发送过滤 / 接收拦截 /
//       applier 兜底 / 挂起重放防御），少一处即红
//   (c) harness 友好：策略文件不得 `import GRDB`（它要能被
//       `scripts/run-local-sync-tests.sh` 无模拟器直编）
//   (d) 常量不漂移：`deleteOperation` / `upsertOperation` 与 `SyncChangeOp` rawValue 对齐
//  + 平局裁决的行为断言与检测器自证。
//

import Foundation
import Testing

@testable import QQPlayer

private enum DeletionPolicyContract {
    /// 仓库根：本文件位于 <repo>/QQPlayerTests/ 下 → 上两级。
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let policyPath = "QQPlayer/Sync/SyncChangeLogDeletionPolicy.swift"
    static let scannedDirectory = "QQPlayer"

    /// 消费点：删除判定必须经由策略文件，不许各自实现。
    static let consumerPaths: [String] = [
        "QQPlayer/Sync/SyncChangeLogPeer.swift", // 发送侧逐行过滤 + 批内抑制；接收侧拦截
        "QQPlayer/Sync/SyncChangeLogApplier.swift", // 应用层最后一道兜底
        "QQPlayer/Sync/SyncChangeLogPendingStore.swift", // 挂起重放防御
        "QQPlayer/Sync/SyncPlaybackCarryPlan.swift", // 随歌携带：同键抑制复用
    ]

    /// delete「判定」的代码形状（构造 delete 行不算：`op: SyncChangeOp.delete.rawValue` 不匹配）。
    static let judgmentPatterns: [String] = [
        #"opValue\s*[!=]=\s*\.delete"#,
        #"[!=]=\s*"delete""#,
        #"isDelete"#,
        #"deleteOperation"#,
    ]

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path): return "契约测试无法枚举目录（fail-closed）：\(path)"
            }
        }
    }

    /// 去掉行尾注释后参与匹配（契约针对**代码**，不针对说明文字）。
    /// `://` 视为 URL 不算注释起点。
    static func codePart(ofLine line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        if range.lowerBound > line.startIndex {
            let before = line[line.index(before: range.lowerBound)]
            if before == ":" { return line }
        }
        return String(line[line.startIndex ..< range.lowerBound])
    }

    /// 某段源码里命中的判定形状（行号 + 原文）。
    static func judgments(in source: String) -> [String] {
        var hits: [String] = []
        for (index, rawLine) in source.components(separatedBy: "\n").enumerated() {
            let code = codePart(ofLine: rawLine)
            guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            for pattern in judgmentPatterns where code.range(of: pattern, options: .regularExpression) != nil {
                hits.append("L\(index + 1): \(code.trimmingCharacters(in: .whitespaces))")
                break
            }
        }
        return hits
    }

    static func swiftFiles(under relativeDirectory: String) throws -> [URL] {
        let directory = repositoryRoot.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractError.directoryUnreadable(relativeDirectory)
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    static func relativePath(of url: URL) -> String {
        url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
    }

    /// 白名单之外的 delete 判定点（`路径:行` 形式，便于报错定位）。
    static func offenders() throws -> [String] {
        var result: [String] = []
        for url in try swiftFiles(under: scannedDirectory) {
            let relative = relativePath(of: url)
            guard relative != policyPath else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for hit in judgments(in: source) {
                result.append("\(relative) \(hit)")
            }
        }
        return result.sorted()
    }
}

@Suite("INV-13 删除不跨端传播 · 静态契约")
struct SyncDeletionNonPropagationContractTests {
    @Test("(a) delete 判定只准出现在 SyncChangeLogDeletionPolicy.swift")
    func deleteJudgmentLivesInOnePlace() throws {
        let offenders = try DeletionPolicyContract.offenders()
        #expect(
            offenders.isEmpty,
            """
            生产代码里出现第二处 delete 判定（INV-13 判定必须收口到 \
            SyncChangeLogDeletionPolicy.swift）：
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("(b) 四个消费点都必须走策略文件")
    func consumersGoThroughThePolicy() throws {
        var missing: [String] = []
        for relative in DeletionPolicyContract.consumerPaths {
            let url = DeletionPolicyContract.repositoryRoot.appendingPathComponent(relative)
            let source = try String(contentsOf: url, encoding: .utf8)
            if !source.contains("SyncChangeLogDeletionPolicy") {
                missing.append(relative)
            }
        }
        #expect(missing.isEmpty, "这些消费点没走单一事实源（INV-13 装配缺口）：\(missing)")
    }

    @Test("(c) 策略文件保持 harness 友好：不 import GRDB")
    func policyStaysHarnessFriendly() throws {
        let url = DeletionPolicyContract.repositoryRoot
            .appendingPathComponent(DeletionPolicyContract.policyPath)
        let source = try String(contentsOf: url, encoding: .utf8)
        // 只看代码行：本文件头注释里就写着「刻意不 import GRDB」——用裸 contains 会被自己的说明文字绊倒。
        let importsGRDB = source
            .components(separatedBy: "\n")
            .map { DeletionPolicyContract.codePart(ofLine: $0) }
            .contains { $0.range(of: #"^\s*import\s+GRDB"#, options: .regularExpression) != nil }
        #expect(
            !importsGRDB,
            "策略文件引入了 GRDB → scripts/run-local-sync-tests.sh 无法直编（该 harness 只编纯逻辑）"
        )
    }

    @Test("(d) 策略常量与 SyncChangeOp rawValue 对齐")
    func policyConstantsMatchOpEnum() {
        let deleteAligned = SyncChangeLogDeletionPolicy.deleteOperation == SyncChangeOp.delete.rawValue
        let upsertAligned = SyncChangeLogDeletionPolicy.upsertOperation == SyncChangeOp.upsert.rawValue
        #expect(deleteAligned, "deleteOperation 与 SyncChangeOp.delete 漂移")
        #expect(upsertAligned, "upsertOperation 与 SyncChangeOp.upsert 漂移")
    }

    @Test("平局裁决语义：远端 delete 压本地 upsert，其余一律本端胜")
    func tieBreakSemantics() {
        let remoteDeleteLocalUpsert =
            SyncChangeLogDeletionPolicy.tieBreakPrefersRemoteDelete(remoteOp: "delete", localOp: "upsert")
        let bothDelete =
            SyncChangeLogDeletionPolicy.tieBreakPrefersRemoteDelete(remoteOp: "delete", localOp: "delete")
        let remoteDeleteLocalUnknown =
            SyncChangeLogDeletionPolicy.tieBreakPrefersRemoteDelete(remoteOp: "delete", localOp: "whatever")
        let remoteUpsertLocalUpsert =
            SyncChangeLogDeletionPolicy.tieBreakPrefersRemoteDelete(remoteOp: "upsert", localOp: "upsert")

        #expect(remoteDeleteLocalUpsert)
        #expect(!bothDelete)
        #expect(!remoteDeleteLocalUnknown, "本地不是 upsert 时不得采远端（与裸写版逐字一致）")
        #expect(!remoteUpsertLocalUpsert)
    }

    @Test("检测器自证：抓得住合成违规，且不误伤构造与注释")
    func detectorSelfTest() {
        let violation = """
        if remote.opValue == .delete && local.opValue == .upsert {
        """
        let stringForm = """
        if op == "delete" {
        """
        let legitimateConstruction = """
        try store.record(entity: "favorite", op: SyncChangeOp.delete.rawValue)
        """
        let commentOnly = """
        // 判定集中在 SyncChangeLogDeletionPolicy（isDelete / deleteOperation 只在那里）
        """

        let caughtComparison = DeletionPolicyContract.judgments(in: violation).count
        let caughtLiteral = DeletionPolicyContract.judgments(in: stringForm).count
        let caughtConstruction = DeletionPolicyContract.judgments(in: legitimateConstruction).count
        let caughtComment = DeletionPolicyContract.judgments(in: commentOnly).count

        #expect(caughtComparison == 1)
        #expect(caughtLiteral == 1)
        #expect(caughtConstruction == 0, "构造 delete 行不是判定，不该误伤")
        #expect(caughtComment == 0, "注释不是代码，不该误伤")
    }
}
