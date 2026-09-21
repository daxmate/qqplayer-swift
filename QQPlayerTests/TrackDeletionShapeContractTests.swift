//
//  TrackDeletionShapeContractTests.swift
//  QQPlayerTests
//
//  形状契约（2026-09-18 P1「删除语义合流」）：**文件动作只允许出现在唯一入口文件里**。
//
//  为什么需要它：本批把「iOS 一份实现（removeItem 永久删）+ Mac 一份实现（trashItem 可恢复）」
//  合成「一个入口 + 显式策略（fileAction: .trash/.delete + libraryOnly）」。行为测试只能证
//  「今天这版对」——挡不住下一个人再抄一份（AGENTS.md 2026-09-15：共享语义防第二实现必须
//  靠**形状测试**，不能靠人记得）。所以这里静态断言调用点形状：
//
//   (a) `trashItem` 调用只允许出现在白名单文件（唯一入口）里；
//   (b) 「删除一首歌」仪式（**同时**碰磁盘文件 + 删曲目库引用）只允许出现在白名单文件里；
//   (c) 白名单里每条必须真实存在且确实命中模式（名单不许空转、不许腐烂）；
//   (d) 唯一入口在位，且三条文件动作腿（进废纸篓 + 永久删除 + 回收区落点）都还在；
//   (e) **平台默认值只是数据**：iOS 适配器传 `Policy.ios(...)`（默认 .delete；开启「只从曲库移除」
//       时 .reclaim，2026-09-21 批 E-2），Mac 适配器传 `Policy.mac()`（.trash），且核心 `policy:` 与
//       `Policy.fileAction` 都**没有隐式默认**——谁也不能默默拾到一个错的动作
//       （2026-09-18 实测：iOS 无废纸篓宗卷，trash 必失败）。
//
//  全部 fail-closed：目录读不到 / 白名单格式错 / 入口文件读不到 = 红，绝不静默通过。
//  注释与字符串不算代码（扫描前先剥注释）——靠注释「提到」不算第二实现。
//
//  白名单文件：`QQPlayerTests/Fixtures/track-deletion-shape.tsv`（`路径<TAB>模式`）。
//  范式照抄 `ViewDataAccessContractTests.swift` + `Fixtures/view-data-access-baseline.tsv`。
//

import Foundation
import Testing

@testable import QQPlayer

private enum DeleteShapeContract {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 扫描范围：两端源码都在 `QQPlayer/`（Mac 端文件也在其下，Mac target 走白名单机制）。
    static let scannedDirectories: [String] = ["QQPlayer"]
    static let whitelistPath: String = "QQPlayerTests/Fixtures/track-deletion-shape.tsv"

    /// 命中模式（白名单 tsv 里的第二列取值）。
    enum Pattern: String, CaseIterable {
        /// 废纸篓动作调用
        case trashItem = "trashItem"
        /// 「删除一首歌」仪式：碰磁盘文件 + 删曲目库引用
        case trackFileDeletion = "track-file-deletion"

        /// 该模式在源码里是否命中（源码须已剥注释）。
        func isHit(in code: String) -> Bool {
            switch self {
            case .trashItem:
                return code.contains("trashItem")
            case .trackFileDeletion:
                let touchesFile = code.contains("removeItem") || code.contains("trashItem")
                return touchesFile && code.contains("deleteTrack(")
            }
        }
    }

    enum ContractError: Error, CustomStringConvertible {
        case directoryUnreadable(String)
        case whitelistUnreadable(String)
        case whitelistMalformed(String)

        var description: String {
            switch self {
            case .directoryUnreadable(let path):
                return "契约测试无法枚举目录（fail-closed）：\(path)"
            case .whitelistUnreadable(let path):
                return "契约测试读不到白名单（fail-closed）：\(path)"
            case .whitelistMalformed(let line):
                return "白名单格式错误（应为 `路径<TAB>模式`）：\(line)"
            }
        }
    }

    /// 剥掉行注释 / 块注释 / 字符串字面量——只留**代码**参与判定。
    /// （不确定时宁可漏剥，也不许把代码误当注释：字符串内容不计入，注释里的调用不计入。）
    static func codeOnly(_ source: String) -> String {
        var output = ""
        let characters = Array(source)
        var index = 0
        var inLineComment = false
        var inBlockComment = false
        var inString = false

        while index < characters.count {
            let current = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil

            if inLineComment {
                if current == "\n" { inLineComment = false; output.append(current) }
                index += 1
                continue
            }
            if inBlockComment {
                if current == "*" && next == "/" { inBlockComment = false; index += 2; continue }
                index += 1
                continue
            }
            if inString {
                if current == "\\" { index += 2; continue }
                if current == "\"" { inString = false }
                index += 1
                continue
            }
            if current == "/" && next == "/" { inLineComment = true; index += 2; continue }
            if current == "/" && next == "*" { inBlockComment = true; index += 2; continue }
            if current == "\"" { inString = true; output.append(" "); index += 1; continue }
            output.append(current)
            index += 1
        }
        return output
    }

    /// 子串出现次数（形状判据用：只做「有几处这么写」的计数，不解析语法）。
    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
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

    /// 实际检测结果：模式 → 命中的文件（相对路径，排序）。
    static func detectedHits() throws -> [Pattern: [String]] {
        var result: [Pattern: [String]] = [:]
        let prefix = repositoryRoot.path + "/"
        for directory in scannedDirectories {
            for url in try swiftFiles(under: directory) {
                let source = try String(contentsOf: url, encoding: .utf8)
                let code = codeOnly(source)
                let relative = url.path.replacingOccurrences(of: prefix, with: "")
                for pattern in Pattern.allCases where pattern.isHit(in: code) {
                    result[pattern, default: []].append(relative)
                }
            }
        }
        return result
    }

    /// 白名单：模式 → 允许的文件集合。
    static func whitelist() throws -> [Pattern: Set<String>] {
        let url = repositoryRoot.appendingPathComponent(whitelistPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContractError.whitelistUnreadable(whitelistPath)
        }
        var result: [Pattern: Set<String>] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { throw ContractError.whitelistMalformed(line) }
            let path = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let patterns = parts[1]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for name in patterns {
                guard let pattern = Pattern(rawValue: name) else {
                    throw ContractError.whitelistMalformed(line)
                }
                result[pattern, default: []].insert(path)
            }
        }
        return result
    }
}

@Suite("曲目删除语义形状契约（文件动作唯一入口）")
struct TrackDeletionShapeContractTests {
    @Test("(a)(b) 文件动作调用只允许出现在唯一入口文件里")
    func fileActionCallsAreConfinedToTheSingleEntry() throws {
        let hits = try DeleteShapeContract.detectedHits()
        let allowed = try DeleteShapeContract.whitelist()

        var violations: [String] = []
        for pattern in DeleteShapeContract.Pattern.allCases {
            let permitted = allowed[pattern] ?? []
            for file in hits[pattern] ?? [] where !permitted.contains(file) {
                violations.append("\(pattern.rawValue): \(file)")
            }
        }
        #expect(
            violations.isEmpty,
            """
            出现了第二份「曲目删除」实现（文件动作必须只走 TrackDeletionService \
            + 显式 Policy(fileAction:)，见 QQPlayer/Services/TrackDeletionService.swift）：\(violations)
            """
        )
    }

    @Test("(c) 白名单不空转也不腐烂：每条必须存在且确实命中模式")
    func whitelistIsRealAndNotStale() throws {
        let hits = try DeleteShapeContract.detectedHits()
        let allowed = try DeleteShapeContract.whitelist()

        #expect(!allowed.isEmpty, "白名单读成空表（fail-closed）：\(DeleteShapeContract.whitelistPath)")

        for pattern in DeleteShapeContract.Pattern.allCases {
            let permitted = allowed[pattern] ?? []
            #expect(!permitted.isEmpty, "模式 \(pattern.rawValue) 在白名单里没有任何允许项（名单不完整）")
            for file in permitted.sorted() {
                let url = DeleteShapeContract.repositoryRoot.appendingPathComponent(file)
                #expect(
                    FileManager.default.fileExists(atPath: url.path),
                    "白名单里的文件不存在，请删行/改名：\(file)"
                )
                #expect(
                    (hits[pattern] ?? []).contains(file),
                    "白名单里的 \(file) 已不再命中 \(pattern.rawValue)，请删行（名单不许空转）"
                )
            }
        }
    }

    @Test("(d) 唯一入口在位：三条文件动作腿都在（.trash / .delete / .reclaim）")
    func entryDeclaresBothFileActions() throws {
        let entryPath = "QQPlayer/Services/TrackDeletionService.swift"
        let url = DeleteShapeContract.repositoryRoot.appendingPathComponent(entryPath)
        let source = try String(contentsOf: url, encoding: .utf8)
        let code = DeleteShapeContract.codeOnly(source)

        #expect(code.contains("enum FileAction"), "唯一入口必须显式声明文件动作策略：\(entryPath)")
        #expect(code.contains("case trash"), "缺少 .trash（默认，可恢复）那条腿")
        #expect(code.contains("case delete"), "缺少 .delete（永久删除）那条腿")
        #expect(
            code.contains("case reclaim"),
            "缺少 .reclaim（「只从曲库移除」库内文件的回收区落点，2026-09-21 批 E-2）那条腿"
        )
        #expect(code.contains("trashItem"), "入口必须真的调用 FileManager.trashItem（不能只写注释）")
        #expect(code.contains("removeItem"), "入口必须真的保留永久删除那条腿")
        #expect(
            (try DeleteShapeContract.detectedHits())[.trashItem]?.contains(entryPath) == true,
            "入口文件没被扫描到命中（扫描范围/剥注释逻辑坏了 = 契约静默失效）"
        )
    }

    @Test("(e) 平台默认值只是数据：适配器各传自己的 Policy 工厂，核心无隐式默认")
    func platformDefaultsArePassedAsData() throws {
        let entryPath = "QQPlayer/Services/TrackDeletionService.swift"
        let url = DeleteShapeContract.repositoryRoot.appendingPathComponent(entryPath)
        let code = DeleteShapeContract.codeOnly(try String(contentsOf: url, encoding: .utf8))

        // ① 默认值必须是显式数据：核心参数与 Policy.fileAction 都不得有默认值
        #expect(
            !code.contains("policy: Policy ="),
            "核心 `policy:` 不得有默认值（默认值必须是平台数据，不能隐式拾取）"
        )
        #expect(
            !code.contains("var fileAction: FileAction ="),
            "`Policy.fileAction` 不得有隐式默认（防某个调用点默默走错动作）"
        )

        // ② 两个适配器各传自己的工厂（防「工厂写了但适配器不用」/两平台写反）
        #expect(
            code.contains("policy: .ios(libraryOnly: settings.deleteFromLibraryOnly)"),
            "iOS 适配器必须传 Policy.ios(libraryOnly:)（默认 .delete + 开启时 .reclaim + 既有开关语义）"
        )
        #expect(
            code.contains("policy: .mac()"),
            "Mac 适配器必须传 Policy.mac()（.trash + 既有进度/取消能力）"
        )

        // ③ 带字面量动作的 Policy 构造只允许出现在两个工厂里（= 差异收敛到一处）
        #expect(
            DeleteShapeContract.occurrences(of: "Policy(fileAction:", in: code) == 2,
            "带字面量 fileAction 的 Policy 只应有两个工厂（ios/mac），别处不得再拼策略"
        )
        #expect(code.contains("fileAction: libraryOnly ? .reclaim : .delete"))
        #expect(code.contains("fileAction: .trash, libraryOnly: false"))

        // ④ 工厂本身的行为（防止两个工厂被写反）
        #expect(TrackDeletionService.Policy.ios(libraryOnly: false).fileAction == .delete)
        #expect(
            TrackDeletionService.Policy.ios(libraryOnly: true).fileAction == .reclaim,
            "iOS 开启「只从曲库移除」时必须走回收区落点（批 E-2 语义变更）"
        )
        #expect(TrackDeletionService.Policy.mac().fileAction == .trash)
    }

    @Test("自证：剥注释 + 模式判定对合成输入有效（fail-closed 反向验证）")
    func detectionRuleSelfTest() {
        let commentedOut = """
        import Foundation
        // 曾经：try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        /* try FileManager.default.removeItem(at: url) */
        enum Legacy { static let note = "trashItem 调用已移除" }
        """
        let code = DeleteShapeContract.codeOnly(commentedOut)
        #expect(!DeleteShapeContract.Pattern.trashItem.isHit(in: code), "注释/字符串里的调用不该算数")
        #expect(!DeleteShapeContract.Pattern.trackFileDeletion.isHit(in: code))

        let secondImplementation = """
        import Foundation
        @MainActor enum SneakyDeletion {
            static func delete(track: Track) {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: track.path), resultingItemURL: nil)
                try? DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
            }
        }
        """
        let sneakyCode = DeleteShapeContract.codeOnly(secondImplementation)
        #expect(DeleteShapeContract.Pattern.trashItem.isHit(in: sneakyCode))
        #expect(DeleteShapeContract.Pattern.trackFileDeletion.isHit(in: sneakyCode))

        let unrelatedCleanup = """
        import Foundation
        enum CacheCleaner { static func purge(_ url: URL) { try? FileManager.default.removeItem(at: url) } }
        """
        let cleanupCode = DeleteShapeContract.codeOnly(unrelatedCleanup)
        #expect(
            !DeleteShapeContract.Pattern.trackFileDeletion.isHit(in: cleanupCode),
            "只删临时文件、不碰曲库引用的清理不该被误判成第二份删除实现"
        )
    }
}
