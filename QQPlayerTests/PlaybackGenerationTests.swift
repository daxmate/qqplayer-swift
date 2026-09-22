//
//  PlaybackGenerationTests.swift
//  QQPlayerTests
//
//  载入/调度代数的行为 + 调用点收口契约（测试债批 ③，审计 P1-1；2026-09-20 立）。
//
//  背景（审计原文）：`+PlaybackControl` / `+NowPlaying` / `+AudioSession` / `+AudioScheduling`
//  合计 ≈3600 行、行为零覆盖，根因是**不可注入**（`init` private + `@MainActor` 单例 + 无协议
//  seam）。已有真实 bug 痕迹：`PlaybackAsyncGuardsTests` 文件头列的四条（切歌竞态写旧曲 /
//  EQ 旧任务覆盖新选择 / 失败静默）——**但修复只锁了抽出来的纯函数，没锁引擎里的调用点**。
//
//  本批（按审计建议的「先抽纯类型」路线）把「代数」这一个语义收成唯一定义处：
//    - 生产：`PlaybackGeneration`（`PlaybackModels.swift`）—— `begin()` / `isCurrent(_:)` /
//      `canCommit(_:isCancelled:)`；引擎两个计数器（`loadGeneration` / `scheduleGeneration`）
//      由 `UInt64` 换成本类型，15 处裸 `&+= 1` / 裸比较全部收口（行为零变化）。
//    - 顺带抽两只同形状的判定：`PlaybackQueueSelection.normalized`（原 `normalizeIndexAndTrack`，
//      9 个调用点、零测试）与 `GaplessFormatCompatibility`（原 `canGaplesslySchedule` 直接比
//      `AVAudioFormat`，需真实音频文件才能构造 ⇒ 判定零覆盖）。
//    - 本文件：行为测试 + **调用点收口契约**（扫源码禁止再出现裸自增 / 裸比较）。
//
//  有意不做（另一批）：把引擎做成真正可注入（AVAudioEngine / 定时器 / DB / 封面全抽协议）——
//  那是高风险大改；本批先把「判定」与「代数」从引擎里拿出来并可测。
//
//  target: ios-only（本文件不触 AVFoundation 具体类型，但 engine 侧 seam 是 iOS/Mac 共享）
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - ① 代数语义（切歌竞态的唯一防线）

@Suite("PlaybackGeneration：载入/调度代数")
struct PlaybackGenerationSemanticsTests {
    @Test("初始代次为 0：从未开始")
    func startsAtZero() {
        let generation = PlaybackGeneration()
        #expect(generation.current == 0)
        #expect(generation.isCurrent(0))
    }

    @Test("begin()：单调递增并返回新代次（唯一递增入口）")
    func beginIsMonotonic() {
        var generation = PlaybackGeneration()
        #expect(generation.begin() == 1)
        #expect(generation.begin() == 2)
        #expect(generation.begin() == 3)
        #expect(generation.current == 3)
    }

    @Test("连续 begin：返回值与 current 始终同步（唯一递增入口 + 步数守恒）")
    func beginKeepsCounterInSync() {
        var generation = PlaybackGeneration()
        for step in 1 ... 50 {
            #expect(generation.begin() == UInt64(step))
            #expect(generation.current == UInt64(step))
        }
        // 回绕语义（`&+=`）在本类型内部：`current` 是 private(set)，测试无法把计数推到
        // UInt64.max ⇒ 该分支不可达，**不为它加只为测试存在的 init**（见文件头「有意不做」）。
    }

    @Test("isCurrent：只有最新代次为真")
    func onlyLatestGenerationIsCurrent() {
        var generation = PlaybackGeneration()
        let first = generation.begin()
        #expect(generation.isCurrent(first))
        let second = generation.begin()
        #expect(!generation.isCurrent(first))
        #expect(generation.isCurrent(second))
    }

    @Test("canCommit：代数匹配 + 未取消 → 允许写回")
    func canCommitAllowsCurrentAndNotCancelled() {
        var generation = PlaybackGeneration()
        let token = generation.begin()
        #expect(generation.canCommit(token, isCancelled: false))
    }

    @Test("canCommit：代数不匹配 → 丢弃（哪怕没取消）")
    func canCommitRejectsStaleGeneration() {
        var generation = PlaybackGeneration()
        let stale = generation.begin()
        generation.begin() // 期间又发生了一次操作（切歌 / seek）
        #expect(!generation.canCommit(stale, isCancelled: false))
    }

    @Test("canCommit：已取消 → 丢弃（哪怕代数仍匹配）")
    func canCommitRejectsCancelled() {
        var generation = PlaybackGeneration()
        let token = generation.begin()
        #expect(!generation.canCommit(token, isCancelled: true))
    }

    @Test("canCommit：两者都不满足 → 丢弃")
    func canCommitRejectsBoth() {
        var generation = PlaybackGeneration()
        let stale = generation.begin()
        generation.begin()
        #expect(!generation.canCommit(stale, isCancelled: true))
    }

    @Test("切歌竞态复现：旧代任务在 await 之后不得写回（2026-09-12 审计 P4 的形状）")
    func staleLoadCannotOverwriteNewSelection() {
        var loadGeneration = PlaybackGeneration()

        // 用户点了 A：任务 A 拿到代次 1
        let taskAGeneration = loadGeneration.begin()
        // await 期间用户又点了 B：任务 B 拿到代次 2
        let taskBGeneration = loadGeneration.begin()

        // A 醒来后写回前必须被拦下（否则 currentTrack 被旧曲覆盖 = 那个 bug）
        #expect(!loadGeneration.canCommit(taskAGeneration, isCancelled: false))
        #expect(loadGeneration.canCommit(taskBGeneration, isCancelled: false))
    }

    @Test("调度代语义：seek 前 cancelPendingCompletions 递增 → 旧 completion 判定失效")
    func bumpInvalidatesScheduledCompletion() {
        var scheduleGeneration = PlaybackGeneration()
        let scheduledToken = scheduleGeneration.begin() // scheduleSegment 时捕获
        #expect(scheduleGeneration.isCurrent(scheduledToken))

        scheduleGeneration.begin() // seek 前 cancelPendingCompletions()
        #expect(!scheduleGeneration.isCurrent(scheduledToken))
    }

    @Test("两个计数器彼此独立（载入与调度不互相顶掉）")
    func countersAreIndependent() {
        var loadGeneration = PlaybackGeneration()
        var scheduleGeneration = PlaybackGeneration()
        let loadToken = loadGeneration.begin()
        scheduleGeneration.begin()
        scheduleGeneration.begin()
        #expect(loadGeneration.isCurrent(loadToken))
        #expect(scheduleGeneration.current == 2)
    }
}

// MARK: - ② 队列归一（原 normalizeIndexAndTrack，9 个调用点零测试）

@Suite("PlaybackQueueSelection：队列归一的收敛规则")
struct PlaybackQueueSelectionTests {
    @Test("空队列：索引归 0、当前曲清空（不可用队列 ≠ 保留旧曲）")
    func emptyQueueClearsSelection() {
        let result = PlaybackQueueSelection.normalized(queueTrackIds: [], currentTrackId: "a", currentIndex: 3)
        #expect(result == PlaybackQueueSelection.Result(index: 0, trackId: nil))
    }

    @Test("当前曲仍在队列里：取它现在的下标（队列被整体替换后原下标会陈旧）")
    func currentTrackKeepsItsNewIndex() {
        let result = PlaybackQueueSelection.normalized(queueTrackIds: ["x", "y", "a"], currentTrackId: "a", currentIndex: 0)
        #expect(result.index == 2)
        #expect(result.trackId == "a")
    }

    @Test("当前曲不在队列里：下标夹到范围内，并选该位置的曲目")
    func missingTrackClampsToRange() {
        let result = PlaybackQueueSelection.normalized(queueTrackIds: ["x", "y"], currentTrackId: "gone", currentIndex: 1)
        #expect(result.index == 1)
        #expect(result.trackId == "y")
    }

    @Test("下标越界（远大于 count-1）：夹到最后一项")
    func outOfRangeHighIndexClampsToLast() {
        let result = PlaybackQueueSelection.normalized(queueTrackIds: ["x", "y", "z"], currentTrackId: nil, currentIndex: 99)
        #expect(result.index == 2)
        #expect(result.trackId == "z")
    }

    @Test("下标为负：夹到 0（不崩、不取负索引）")
    func negativeIndexClampsToFirst() {
        let result = PlaybackQueueSelection.normalized(queueTrackIds: ["x", "y"], currentTrackId: nil, currentIndex: -5)
        #expect(result.index == 0)
        #expect(result.trackId == "x")
    }

    @Test("单元素队列 + 无当前曲：选中唯一一项")
    func singleElementQueue() {
        let result = PlaybackQueueSelection.normalized(queueTrackIds: ["only"], currentTrackId: nil, currentIndex: 7)
        #expect(result.index == 0)
        #expect(result.trackId == "only")
    }

    @Test("不变量：非空队列的结果下标永远落在 [0, count-1]")
    func indexAlwaysInRange() {
        let queue = ["a", "b", "c", "d"]
        for index in -3 ... 10 {
            let result = PlaybackQueueSelection.normalized(queueTrackIds: queue, currentTrackId: "zzz", currentIndex: index)
            #expect(result.index >= 0 && result.index < queue.count)
        }
    }
}

// MARK: - ③ 无缝衔接格式兼容（原直接比 AVAudioFormat，判定零覆盖）

@Suite("GaplessFormatCompatibility：无缝衔接的格式判定")
struct GaplessFormatCompatibilityTests {
    private static func traits(
        sampleRate: Double = 44100,
        channelCount: UInt32 = 2,
        commonFormat: UInt = 1,
        isInterleaved: Bool = false
    ) -> GaplessFormatCompatibility.Traits {
        GaplessFormatCompatibility.Traits(
            sampleRate: sampleRate,
            channelCount: channelCount,
            commonFormatRawValue: commonFormat,
            isInterleaved: isInterleaved
        )
    }

    @Test("同格式：可无缝")
    func identicalFormatsAreGapless() {
        #expect(GaplessFormatCompatibility.canSchedule(current: Self.traits(), next: Self.traits()))
    }

    @Test("采样率差 < 0.1：视为同格式（浮点漂移容差）")
    func tinySampleRateDriftIsGapless() {
        #expect(GaplessFormatCompatibility.canSchedule(
            current: Self.traits(sampleRate: 44100.0),
            next: Self.traits(sampleRate: 44100.05)
        ))
    }

    @Test("采样率差 ≥ 0.1：不可无缝（必须走普通预载）")
    func sampleRateMismatchIsNotGapless() {
        #expect(!GaplessFormatCompatibility.canSchedule(
            current: Self.traits(sampleRate: 44100.0),
            next: Self.traits(sampleRate: 48000.0)
        ))
        #expect(!GaplessFormatCompatibility.canSchedule(
            current: Self.traits(sampleRate: 44100.0),
            next: Self.traits(sampleRate: 44100.2)
        ))
        // 不要拿「恰好差 0.1」当边界测例：双精度下 44100.1 - 44100.0 ≈ 0.099999999998…，
        // 落在容差内（实测第一次写这条就红了）。边界本身不可表示，测它只会锁定浮点噪声。
    }

    @Test("声道数不同：不可无缝")
    func channelCountMismatchIsNotGapless() {
        #expect(!GaplessFormatCompatibility.canSchedule(
            current: Self.traits(channelCount: 2),
            next: Self.traits(channelCount: 1)
        ))
    }

    @Test("通用格式不同（float32 vs int16）：不可无缝")
    func commonFormatMismatchIsNotGapless() {
        #expect(!GaplessFormatCompatibility.canSchedule(
            current: Self.traits(commonFormat: 1),
            next: Self.traits(commonFormat: 3)
        ))
    }

    @Test("交错布局不同：不可无缝")
    func interleavingMismatchIsNotGapless() {
        #expect(!GaplessFormatCompatibility.canSchedule(
            current: Self.traits(isInterleaved: false),
            next: Self.traits(isInterleaved: true)
        ))
    }
}

// MARK: - ④ 调用点收口契约（禁止绕过唯一入口）

/// 扫描基建（fail-closed：读不到 / 扫描面塌陷 = 红）。
private enum PlaybackGenerationContract {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let scannedDirectory = "QQPlayer"
    /// 受管名字：这两个计数器的语义已收进 `PlaybackGeneration`。
    static let managedNames = ["loadGeneration", "scheduleGeneration"]
    static let minimumScannedFiles = 100

    enum ContractError: Error, CustomStringConvertible {
        case scanAreaTooSmall(Int)
        case sourceUnreadable(String)

        var description: String {
            switch self {
            case .scanAreaTooSmall(let count):
                return "收口契约扫描面塌陷（fail-closed）：只枚举到 \(count) 个 Swift 文件"
            case .sourceUnreadable(let path):
                return "收口契约读不到源码（fail-closed）：\(path)"
            }
        }
    }

    struct Violation: Hashable, CustomStringConvertible {
        let path: String
        let line: Int
        let text: String

        var description: String { "\(path):\(line): \(text)" }
    }

    /// 剥掉行注释 / 块注释 / 字符串字面量（三者都要：文档注释里就写着这两个名字，
    /// 字符串里可能有日志文案；不剥会把说明文字判成违规）。
    static func strippedCode(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var isInString = false
        var isEscaped = false
        var isInLineComment = false
        var isInBlockComment = false
        var previous: Character?

        for character in source {
            if isInLineComment {
                if character == "\n" {
                    isInLineComment = false
                    out.append(character)
                }
                previous = character
                continue
            }
            if isInBlockComment {
                if previous == "*", character == "/" { isInBlockComment = false }
                previous = character
                continue
            }
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                out.append(" ")
                previous = character
                continue
            }
            if previous == "/", character == "/" {
                out.removeLast()
                isInLineComment = true
                previous = character
                continue
            }
            if previous == "/", character == "*" {
                out.removeLast()
                isInBlockComment = true
                previous = character
                continue
            }
            if character == "\"" { isInString = true }
            out.append(character)
            previous = character
        }
        return out
    }

    /// 单个受管名字后面紧跟的文本是否构成「绕过唯一入口」——**契约的唯一判据**
    /// （`violations()` 与合成用例共用，避免两处各写一份判据而漂移）。
    /// - Parameter isPropertyDeclaration: 该处是不是属性声明（`var loadGeneration = …`）。
    ///   声明是**唯一**允许的直写：类型系统会保证右值就是 `PlaybackGeneration`。
    ///   除此以外任何直写都是绕过——**包括 `loadGeneration = PlaybackGeneration()` 这种「复位」**：
    ///   计数归零会让在途任务捕获的旧代次（0）重新匹配成功，正是本契约要防的静默写旧曲竞态。
    static func isViolation(following rest: Substring, isPropertyDeclaration: Bool = false) -> Bool {
        // 先要求「名字到此结束」：否则 `preloadGeneration = x` 会被当成 `loadGeneration = x`
        // （实测第一版就这么误报过——受管名是别人的变量名后缀）。
        if let first = rest.first, first.isLetter || first.isNumber || first == "_" { return false }
        let operators = ["&+=", "+=", "-=", "*=", "/=", "==", "!=", "++", "--"]
        let trimmed = rest.drop { $0 == " " || $0 == "\t" }
        if operators.contains(where: { trimmed.hasPrefix($0) }) { return true }
        guard trimmed.hasPrefix("=") else { return false }
        return !isPropertyDeclaration
    }

    /// 受管名前面是不是紧跟着 `var`（即属性声明，而非赋值语句）。
    /// 只看名字前的最后一小段，不扫全文件。
    static func isPropertyDeclaration(before preceding: Substring) -> Bool {
        String(preceding.suffix(8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix("var")
    }

    /// 扫描全 `QQPlayer/**`：这两个名字后面**紧跟**赋值/比较运算符 = 绕过了唯一入口。
    /// （参数名/属性名后面跟 `.` `,` `)` 等都不算——那种写法是在**读**代数，不是自己维护它。）
    static func violations() throws -> [Violation] {
        let root = repositoryRoot.appendingPathComponent(scannedDirectory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw ContractError.scanAreaTooSmall(0)
        }
        let urls = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        guard urls.count >= minimumScannedFiles else {
            throw ContractError.scanAreaTooSmall(urls.count)
        }

        var found: [Violation] = []

        for url in urls {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                throw ContractError.sourceUnreadable(url.lastPathComponent)
            }
            let code = strippedCode(raw)
            let relative = scannedDirectory + "/" + url.path.replacingOccurrences(
                of: root.path + "/",
                with: ""
            )

            for name in managedNames {
                var searchStart = code.startIndex
                while let match = code.range(of: name, range: searchStart ..< code.endIndex) {
                    searchStart = match.upperBound
                    // 词边界：前一个字符不能是标识符字符（否则 `preloadGeneration` 会被当成受管名）。
                    if match.lowerBound > code.startIndex {
                        let previous = code[code.index(before: match.lowerBound)]
                        if previous.isLetter || previous.isNumber || previous == "_" { continue }
                    }
                    let rest = code[match.upperBound...].prefix(40)
                    let isDeclaration = isPropertyDeclaration(before: code[code.startIndex ..< match.lowerBound])
                    guard isViolation(following: rest, isPropertyDeclaration: isDeclaration) else { continue }
                    let line = code[code.startIndex ..< match.lowerBound].reduce(1) { count, character in
                        character == "\n" ? count + 1 : count
                    }
                    found.append(Violation(
                        path: relative,
                        line: line,
                        text: "\(name) → \(rest.drop { $0 == " " || $0 == "\t" }.prefix(12))"
                    ))
                }
            }
        }
        return found.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
    }
}

@Suite("PlaybackGeneration 调用点收口契约（唯一入口）")
struct PlaybackGenerationWiringContractTests {
    private typealias Contract = PlaybackGenerationContract

    @Test("引擎里不得再出现对 loadGeneration / scheduleGeneration 的裸自增 / 裸比较 / 裸赋值")
    func noBareGenerationMutationOutsideTheType() throws {
        let violations = try Contract.violations()
        #expect(
            violations.isEmpty,
            "以下位置绕过了 PlaybackGeneration 唯一入口（应用 begin()/isCurrent()/canCommit()）：\n\(violations.map(\.description).joined(separator: "\n"))"
        )
    }

    @Test("两个计数器确实由代数类型持有（防止「删掉属性」让上一条恒真）")
    func bothCountersAreBackedByTheType() throws {
        let source = Contract.strippedCode(
            try String(contentsOf: Contract.repositoryRoot.appendingPathComponent("QQPlayer/Services/PlayerEngine.swift"), encoding: .utf8)
        )
        #expect(source.contains("var loadGeneration = PlaybackGeneration()"))
        #expect(source.contains("var scheduleGeneration = PlaybackGeneration()"))
    }

    @Test("收口契约自身有效：合成的裸写法必须被抓到（防空转）")
    func contractCatchesSyntheticViolation() {
        let synthetic = """
        func f() {
            loadGeneration &+= 1
            if scheduleGeneration == token {}
            loadGeneration = 3
            let ok = loadGeneration.begin()
            let fine = loadGeneration.current
            let declared = PlaybackGeneration()
            var scheduleGeneration = PlaybackGeneration()
        }
        """
        let code = Contract.strippedCode(synthetic)
        var hits = 0
        for name in Contract.managedNames {
            var start = code.startIndex
            while let match = code.range(of: name, range: start ..< code.endIndex) {
                start = match.upperBound
                if match.lowerBound > code.startIndex {
                    let previous = code[code.index(before: match.lowerBound)]
                    if previous.isLetter || previous.isNumber || previous == "_" { continue }
                }
                let isDeclaration = Contract.isPropertyDeclaration(before: code[code.startIndex ..< match.lowerBound])
                if Contract.isViolation(
                    following: code[match.upperBound...].prefix(40),
                    isPropertyDeclaration: isDeclaration
                ) { hits += 1 }
            }
        }
        // 违规 3 处（自增 / 比较 / 裸赋值）；合法读法 2 处 + 声明成代数类型 1 处不算
        #expect(hits == 3)
    }

    @Test("复位式直写也算绕过（`loadGeneration = PlaybackGeneration()` 会让旧代次重新匹配）")
    func resetAssignmentIsAViolation() {
        // 非声明位置：`= PlaybackGeneration()` 是绕过（计数器归零 → 在途任务捕获的 0 重新命中）
        #expect(Contract.isViolation(following: " = PlaybackGeneration()"[...]))
        // 属性声明位置（`var loadGeneration = PlaybackGeneration()`）：唯一放行形状
        #expect(!Contract.isViolation(following: " = PlaybackGeneration()"[...], isPropertyDeclaration: true))
    }

    @Test("注释里的名字不算违规（剥注释生效）")
    func commentsDoNotCount() {
        let synthetic = """
        // loadGeneration &+= 1 是旧写法
        /// scheduleGeneration == x 也别再写
        let ok = 1
        """
        let code = Contract.strippedCode(synthetic)
        #expect(!code.contains("&+="))
        #expect(!code.contains("=="))
    }

    @Test("词边界：受管名是别人变量名的后缀时不算违规（preloadGeneration = …）")
    func identifierSuffixDoesNotCount() {
        // 仿真扫描器看到的情形：match 落在 `preloadGeneration` 里的 `loadGeneration` 上，
        // 后面紧跟 ` = loadGeneration.current` —— 名字后面跟标识符字符 ⇒ 不是受管名。
        #expect(!Contract.isViolation(following: "Generation = x"[...]))
        #expect(!Contract.isViolation(following: "X = 1"[...]))
        #expect(Contract.isViolation(following: " &+= 1"[...]))
    }
}
