//
//  MacLibraryFactsReadPathContractTests.swift
//  QQPlayerTests
//
//  形状契约：`MacLibraryFactsStore` 的**读路径严格只读** + **失效后必有补齐着陆**
//  （2026-09-25「刮削一首歌后主线程 100% CPU 自旋卡死」事故后立）。
//
//  **事故（两次 `sample` 实锤）**：刮削一首歌后 App 卡死，主线程自旋 31 分钟、CPU 97.8%，
//  两次采样栈完全一致；主线程链：
//  `Update.dispatchActions → AppKitOutlineTableCoordinator.update →
//   withSelectionUpdateGuard → -[NSTableView enumerateAvailableRowViewsUsingBlock:] →
//   MacTrackListView album 列 → MacLibraryFactsStore.albumTitle → albumFacts(forAlbumId:)`，
//  且 `AppKitOutlineTableCoordinator.update` 在**同一份栈里出现两次**（表格更新自我重入）；
//  stderr 有 `Application performed a reentrant operation in its NSTableView delegate.`
//  根因：`@Observable` store 的 body 侧读路径**不是只读**——缓存未命中就 `schedule…` → `begin` →
//  **同步写被观察的 `inFlight`**；这个写落在行更新过程中 ⇒ 观察者失效 ⇒ 再排一轮 update ⇒
//  再读 ⇒ 再写，循环不收敛。
//
//  **契约 1（读路径只读）**：读路径函数体内不得出现 `schedule` / `begin(`，也不得出现被观察状态
//  （`inFlight` / `generation`）的名字——读路径只查缓存，出现这些名字必是写/调度路径混入。
//  **契约 2（活锁）**：凡调用 facts store 的 `invalidate()` 的函数，**同一函数**里必须紧接着
//  发起一轮补齐（`preload(` / `ensureFacts(`）——否则「失效后没人重新补齐」= 缓存永远补不上。
//
//  **口径**：判据先**剥注释 + 剥字符串**（2026-09-19 教训：首版装配判据没剥注释 → 注掉装配行
//  测试仍绿 = 假阴性）。两个契约都自带**自证用例**（注入违规必须变红），并在交付时做过
//  「真文件注入 → 变红 → 精确还原 → 复跑绿」的反向验证。
//

import Foundation
import Testing

private enum FactsReadPathContract {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 被守护的 store 文件（相对仓库根）。
    static let storePath = "QQPlayer/Services/MacLibraryFactsStore.swift"

    /// 读路径（渲染期唯一允许调用的 API 面）。
    static let readPathSignatures = [
        "albumFacts(for album:",
        "albumFacts(forAlbumId",
        "artistTrackCount(for artist:",
        "artistTrackCount(forArtistId",
        "playlistFacts(for playlist:",
        "playlistFacts(forPlaylistId",
        "albumTitle(forTrack",
    ]

    /// 读路径里禁止出现的符号（读路径只查缓存，出现即写路径混入）。
    static let bannedTokens = ["schedule", "begin(", "inFlight", "generation"]

    enum ContractError: Error, CustomStringConvertible {
        case unreadable(String)

        var description: String {
            switch self {
            case .unreadable(let path):
                return "契约测试读不到文件（fail-closed）：\(path)"
            }
        }
    }

    /// 剥离**注释**（`//` 行注释 + `/* */` 块注释）与**字符串字面量内容**，保留行结构。
    static func strippedSource(_ source: String) -> String {
        var outputLines: [String] = []
        var inBlockComment = false
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            var output = ""
            var index = line.startIndex
            var inString = false
            while index < line.endIndex {
                let char = line[index]
                let next = line.index(after: index)
                if inBlockComment {
                    if char == "*", next < line.endIndex, line[next] == "/" {
                        inBlockComment = false
                        index = line.index(after: next)
                        continue
                    }
                    index = next
                    continue
                }
                if inString {
                    if char == "\\", next < line.endIndex {
                        index = line.index(after: next)
                        continue
                    }
                    if char == "\"" { inString = false }
                    index = next
                    continue
                }
                if char == "/", next < line.endIndex, line[next] == "/" { break }
                if char == "/", next < line.endIndex, line[next] == "*" {
                    inBlockComment = true
                    index = line.index(after: next)
                    continue
                }
                if char == "\"" {
                    inString = true
                    index = next
                    continue
                }
                output.append(char)
                index = next
            }
            outputLines.append(output)
        }
        return outputLines.joined(separator: "\n")
    }

    /// 取某个函数声明的完整函数体（含签名行，花括号配对到闭合）。
    /// 只认 `func <签名>` 的**声明行**（避免匹配调用点）；找不到返回 nil。
    static func functionBody(signature: String, in code: String) -> String? {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { isDeclaration($0, containing: signature) }) else {
            return nil
        }
        var depth = 0
        var started = false
        var collected: [String] = []
        for line in lines[start...] {
            collected.append(line)
            for char in line {
                if char == "{" { depth += 1; started = true }
                if char == "}" { depth -= 1 }
            }
            if started, depth <= 0 { return collected.joined(separator: "\n") }
        }
        return nil
    }

    /// 声明行判据：含 `func ` 且含给定签名（不看调用点）。
    static func isDeclaration(_ line: String, containing signature: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("func ") && line.contains(signature)
    }

    /// 读路径只读判定：返回 (找到的读路径函数数, 违规清单)。
    static func readPathViolations(in code: String) -> (found: Int, violations: [String]) {
        var found = 0
        var violations: [String] = []
        for signature in readPathSignatures {
            guard let body = functionBody(signature: signature, in: code) else { continue }
            found += 1
            for token in bannedTokens where body.contains(token) {
                violations.append("`\(signature)…` 的读路径里出现 `\(token)`（读路径必须只读）")
            }
        }
        return (found, violations)
    }

    /// 源码里所有函数区域（近似解析：`func` 声明行开头，花括号配对到闭合）。
    static func functionRegions(in code: String) -> [(name: String, body: String)] {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var regions: [(name: String, body: String)] = []
        var index = 0
        while index < lines.count {
            guard lines[index].contains("func "), let name = functionName(in: lines[index]) else {
                index += 1
                continue
            }
            var depth = 0
            var started = false
            var collected: [String] = []
            var cursor = index
            while cursor < lines.count {
                collected.append(lines[cursor])
                for char in lines[cursor] {
                    if char == "{" { depth += 1; started = true }
                    if char == "}" { depth -= 1 }
                }
                cursor += 1
                if started, depth <= 0 { break }
            }
            regions.append((name, collected.joined(separator: "\n")))
            index = cursor
        }
        return regions
    }

    /// 函数名（`func name(` 的第一段标识符）。
    static func functionName(in line: String) -> String? {
        guard let range = line.range(of: "func ") else { return nil }
        let rest = line[range.upperBound...]
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    /// 失效闭环判定：凡出现 facts store `invalidate()` 的函数，同函数必须发起补齐。
    /// 返回 (检查到的函数数, 违规清单)。
    static func refillPairingViolations(in code: String) -> (checked: Int, violations: [String]) {
        var checked = 0
        var violations: [String] = []
        for region in functionRegions(in: code) where region.body.contains(".invalidate()") {
            checked += 1
            guard region.body.contains("preload(") || region.body.contains("ensureFacts(") else {
                violations.append(
                    "`\(region.name)(…)` 调用了 facts store 的 `invalidate()`，"
                        + "但同一函数里没有 `preload(…)` / `ensureFacts(…)` → 失效后没人重新补齐"
                )
                continue
            }
        }
        return (checked, violations)
    }

    static func swiftFiles() throws -> [URL] {
        let directory = repositoryRoot.appendingPathComponent("QQPlayer")
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractError.unreadable("QQPlayer")
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    static func read(_ path: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContractError.unreadable(path)
        }
        return text
    }
}

@Suite("MacLibraryFactsStore 读路径只读契约（渲染期写入 = 表格重入更新死循环）")
struct MacLibraryFactsReadPathContractTests {
    @Test("(a) 读路径函数体内不得出现 schedule / begin( / inFlight / generation")
    func readPathsArePure() throws {
        let source = try FactsReadPathContract.read(FactsReadPathContract.storePath)
        let code = FactsReadPathContract.strippedSource(source)
        let result = FactsReadPathContract.readPathViolations(in: code)

        // fail-closed：读路径函数没找全 = 判据入口失效（改名/搬走），不是「没有违规」
        #expect(
            result.found == FactsReadPathContract.readPathSignatures.count,
            "只扫到 \(result.found) 个读路径函数（预期 \(FactsReadPathContract.readPathSignatures.count) 个）：签名判据可能已失效"
        )
        #expect(
            result.violations.isEmpty,
            """
            读路径不是只读（渲染期写被观察状态 = 重排 update → 再读 → 再写的死循环燃料）：
            \(result.violations.joined(separator: "\n"))
            """
        )
    }

    @Test("(b) 自证：注入 schedule / 写 inFlight 必须判违规；注释与字符串里的同名字样不算")
    func readPathScannerSelfTest() {
        func violations(_ source: String) -> [String] {
            FactsReadPathContract.readPathViolations(
                in: FactsReadPathContract.strippedSource(source)
            ).violations
        }

        // 旧实现形态：读路径里 schedule + 同步写 inFlight → 必须报
        let injected = """
        func albumFacts(forAlbumId id: Int64) -> AlbumFacts {
            if let cached = albumFactsById[id] { return cached }
            scheduleAlbumFacts(id)
            return AlbumFacts()
        }
        func artistTrackCount(forArtistId id: Int64) -> Int {
            if let cached = artistTrackCountById[id] { return cached }
            guard begin("artist-\\(id)") else { return 0 }
            return 0
        }
        """
        let reported = violations(injected)
        #expect(reported.contains { $0.contains("schedule") })
        #expect(reported.contains { $0.contains("begin(") })

        // 违规写 inFlight / generation（即使不叫 schedule）也必须报
        let writesInFlight = """
        func playlistFacts(forPlaylistId id: Int64) -> PlaylistFacts {
            inFlight.insert("playlist-\\(id)")
            return playlistFactsById[id] ?? PlaylistFacts()
        }
        """
        #expect(violations(writesInFlight).isEmpty == false)

        // **注释与字符串里的同名字样不算**（否则把调用点注掉、或注释里提一句就会假绿/假红）
        let commentOnly = """
        func albumFacts(forAlbumId id: Int64) -> AlbumFacts {
            // 旧实现这里调 scheduleAlbumFacts(id) 并写 inFlight —— 现在只查缓存
            let note = "scheduleAlbumFacts / inFlight / generation"
            _ = note
            return albumFactsById[id] ?? AlbumFacts()
        }
        """
        #expect(violations(commentOnly).isEmpty)

        // 干净的只读实现 → 不报
        let clean = """
        func albumTitle(forTrack track: Track) -> String {
            guard let albumId = track.albumId else { return "" }
            return albumFacts(forAlbumId: albumId).title
        }
        """
        #expect(violations(clean).isEmpty)

        // 调用点不算声明（`albumFacts(forAlbumId` 出现在别的函数体里不得被当成读路径函数体）
        let callSite = """
        func someOther() -> String {
            return MacLibraryFactsStore.shared.albumFacts(forAlbumId: 1).title
        }
        """
        #expect(FactsReadPathContract.readPathViolations(in: FactsReadPathContract.strippedSource(callSite)).found == 0)
    }
}

@Suite("曲库事实补齐闭环契约（invalidate 之后必须有一轮补齐着陆）")
struct MacLibraryFactsRefillLoopContractTests {
    @Test("(a) 凡调用 facts store `invalidate()` 的函数，同函数必须发起 preload / ensureFacts")
    func invalidateIsPairedWithRefill() throws {
        let prefix = FactsReadPathContract.repositoryRoot.path + "/"
        var scannedFiles = 0
        var checkedFunctions = 0
        var violations: [String] = []

        for url in try FactsReadPathContract.swiftFiles() {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // 口径：只看消费 facts store 的文件（`invalidate()` 在这个词面上只属于它）
            guard source.contains("MacLibraryFactsStore") || source.contains("libraryFacts") else { continue }
            scannedFiles += 1
            let code = FactsReadPathContract.strippedSource(source)
            let relative = url.path.replacingOccurrences(of: prefix, with: "")
            let result = FactsReadPathContract.refillPairingViolations(in: code)
            checkedFunctions += result.checked
            violations.append(contentsOf: result.violations.map { "`\(relative)`：\($0)" })
        }

        // fail-closed：没扫到任何文件 / 任何 invalidate 调用点 = 判据入口失效
        #expect(scannedFiles > 0, "没扫到任何消费 facts store 的文件：入口判据可能已失效（fail-closed）")
        #expect(checkedFunctions > 0, "没扫到任何 `invalidate()` 调用点：判据入口可能已失效（fail-closed）")
        #expect(
            violations.isEmpty,
            """
            失效闭环缺口（`invalidate()` 之后没人重新补齐 ⇒ 缓存可能长期补不上）：
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test("(b) 自证：只 invalidate 不补齐 → 必须报；补齐在同一函数 → 不报；注释不算")
    func refillPairingScannerSelfTest() {
        func violations(_ source: String) -> [String] {
            FactsReadPathContract.refillPairingViolations(
                in: FactsReadPathContract.strippedSource(source)
            ).violations
        }
        func checked(_ source: String) -> Int {
            FactsReadPathContract.refillPairingViolations(
                in: FactsReadPathContract.strippedSource(source)
            ).checked
        }

        // 只失效不补齐 → 必须报
        let invalidateOnly = """
        func reloadLibrary() {
            libraryFacts.invalidate()
            tracks = []
        }
        """
        #expect(checked(invalidateOnly) == 1)
        #expect(violations(invalidateOnly).count == 1)

        // 同函数里发起补齐 → 不报
        let paired = """
        func reloadLibrary() {
            libraryFacts.invalidate()
            libraryLoadTask = Task { @MainActor in
                await libraryFacts.preload(tracks: [], albums: [], artists: [], playlists: [])
            }
        }
        """
        #expect(violations(paired).isEmpty)

        // ensureFacts 也算补齐入口
        let pairedEnsure = """
        func refreshFacts() {
            facts.invalidate()
            Task { await facts.ensureFacts(albumIds: [1]) }
        }
        """
        #expect(violations(pairedEnsure).isEmpty)

        // 注释里的 invalidate / preload 不算（注掉调用点必须判违规）
        let commented = """
        func reloadLibrary() {
            // libraryFacts.invalidate()
            // await libraryFacts.preload(tracks: [], albums: [], artists: [], playlists: [])
            tracks = []
        }
        """
        #expect(checked(commented) == 0)

        // 嵌套闭包里的补齐也算（花括号配对必须跨闭包）
        let nestedClosure = """
        func reloadLibrary() {
            libraryFacts.invalidate()
            Task { @MainActor in
                if flag {
                    await libraryFacts.preload(tracks: [], albums: [], artists: [], playlists: [])
                }
            }
        }
        """
        #expect(violations(nestedClosure).isEmpty)
    }
}
