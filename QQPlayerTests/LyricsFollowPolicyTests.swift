//
//  LyricsFollowPolicyTests.swift
//  QQPlayerTests
//
//  歌词页「阅读态 → 回中」判据（LyricsFollowPolicy）单测 + 单源形状契约（2026-10-12 立）。
//
//  背景：普通播放模式歌词页，用户手动滚动 → 阅读态（关距离分级灰度 + 正常字号）；
//  停止滚动后到「下一句」才自动回中并恢复分级（用户拍板 2026-10-12）。回中判据是
//  iOS / Mac 共享的纯逻辑（`LyricsFollowPolicy`，见 Views/Player/PlayerGestureLogic.swift）——
//  本文件锁住它的行为（真值表）并加一条**形状契约**：两端回中点都必须调用它，禁各写一份
//  （对齐项目「共享语义唯一入口 + 形状测试」纪律）。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 行为（真值表，fail-closed：关键布尔组合全覆盖，能变红）

@Suite("歌词页阅读态 → 回中判据 LyricsFollowPolicy")
struct LyricsFollowPolicyTests {
    /// 唯一「应恢复跟随（回中）」的组合：普通模式 + 未在跟随 + 已停止滚动 + 换了句
    @Test("四条件同时满足才回中")
    func resumesOnlyWhenAllConditionsHold() {
        #expect(
            LyricsFollowPolicy.shouldResumeFollow(
                isKaraoke: false,
                isFollowing: false,
                isScrollActive: false,
                activeIndexChanged: true
            )
        )
    }

    @Test("跟唱模式恒不回中（guard 隔离，需求 4）")
    func karaokeNeverResumes() {
        for isFollowing in [true, false] {
            for isScrollActive in [true, false] {
                for activeIndexChanged in [true, false] {
                    #expect(
                        !LyricsFollowPolicy.shouldResumeFollow(
                            isKaraoke: true,
                            isFollowing: isFollowing,
                            isScrollActive: isScrollActive,
                            activeIndexChanged: activeIndexChanged
                        ),
                        "跟唱模式不该回中：following=\(isFollowing) scrolling=\(isScrollActive) changed=\(activeIndexChanged)"
                    )
                }
            }
        }
    }

    @Test("已在跟随时不回中")
    func alreadyFollowingDoesNotResume() {
        #expect(
            !LyricsFollowPolicy.shouldResumeFollow(
                isKaraoke: false,
                isFollowing: true,
                isScrollActive: false,
                activeIndexChanged: true
            )
        )
    }

    @Test("仍在手动滚动时不算「停止滚动后」")
    func activeScrollDoesNotResume() {
        #expect(
            !LyricsFollowPolicy.shouldResumeFollow(
                isKaraoke: false,
                isFollowing: false,
                isScrollActive: true,
                activeIndexChanged: true
            )
        )
    }

    @Test("未换句（当前行未变）不回中")
    func unchangedActiveIndexDoesNotResume() {
        #expect(
            !LyricsFollowPolicy.shouldResumeFollow(
                isKaraoke: false,
                isFollowing: false,
                isScrollActive: false,
                activeIndexChanged: false
            )
        )
    }

    @Test("真值表全枚举：16 种组合中恰好 1 种为 true")
    func exhaustiveTruthTable() {
        var truths: [String] = []
        for isKaraoke in [true, false] {
            for isFollowing in [true, false] {
                for isScrollActive in [true, false] {
                    for activeIndexChanged in [true, false] {
                        let got = LyricsFollowPolicy.shouldResumeFollow(
                            isKaraoke: isKaraoke,
                            isFollowing: isFollowing,
                            isScrollActive: isScrollActive,
                            activeIndexChanged: activeIndexChanged
                        )
                        let expected = !isKaraoke && !isFollowing && !isScrollActive && activeIndexChanged
                        let combo = "karaoke=\(isKaraoke) following=\(isFollowing) scrolling=\(isScrollActive) changed=\(activeIndexChanged)"
                        #expect(got == expected, "\(combo)：期望 \(expected) 实得 \(got)")
                        if got { truths.append(combo) }
                    }
                }
            }
        }
        #expect(truths.count == 1, "应恰好 1 种组合回中，实得 \(truths.count)：\(truths)")
    }
}

// MARK: - 形状契约（单源：两端回中点都必须调用 LyricsFollowPolicy）

/// 断言 iOS / Mac 两端回中点都引用了唯一入口 `LyricsFollowPolicy`（防第二实现）。
/// 扫描器**剥注释与字符串字面量**后再判定（否则注释 / 字符串里提一句就能骗绿），
/// 并有「注释不算 / 字符串不算」自证用例（对齐 EnvironmentInjectionContractTests 纪律）。
@Suite("LyricsFollowPolicy 单源形状契约")
struct LyricsFollowPolicySingleSourceContractTests {
    /// 回中判定的两个消费点（仓库相对路径）
    static let consumers = [
        "QQPlayer/Views/Player/LyricsView+LyricsContent.swift",
        "QQPlayer/Mac/MacLyricsView+SyncedLyrics.swift",
    ]

    @Test("iOS 与 Mac 的回中点都引用唯一入口 LyricsFollowPolicy")
    func bothPlatformsReferencePolicy() throws {
        var missing: [String] = []
        for path in Self.consumers {
            let source = try LyricsFollowPolicyScanner.read(path)
            if !LyricsFollowPolicyScanner.referencesPolicy(source) {
                missing.append(path)
            }
        }
        #expect(
            missing.isEmpty,
            """
            以下文件未引用 LyricsFollowPolicy（回中判据可能自写了一份，违反唯一事实源）：
            \(missing.sorted().joined(separator: "\n"))
            """
        )
    }

    @Test("扫描器自证：注释 / 字符串里的 LyricsFollowPolicy 不算（fail-closed）")
    func scannerIgnoresCommentsAndStrings() {
        #expect(
            !LyricsFollowPolicyScanner.referencesPolicy("// LyricsFollowPolicy.shouldResumeFollow(...)\nlet x = 1")
        )
        #expect(
            !LyricsFollowPolicyScanner.referencesPolicy("/*\nLyricsFollowPolicy\n*/\nlet x = 1")
        )
        #expect(
            !LyricsFollowPolicyScanner.referencesPolicy("let msg = \"LyricsFollowPolicy\"")
        )
        #expect(
            LyricsFollowPolicyScanner.referencesPolicy("if LyricsFollowPolicy.shouldResumeFollow(isKaraoke: k) {}")
        )
    }
}

/// 源码扫描器：剥注释（行 / 块）与字符串字面量后再找标识符。
/// fail-closed：读不到文件即抛错（不把「读不到」当「没有」）。
private enum LyricsFollowPolicyScanner {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    enum ScanError: Error, CustomStringConvertible {
        case unreadable(String)

        var description: String {
            switch self {
            case .unreadable(let path): return "形状契约无法读取（fail-closed）：\(path)"
            }
        }
    }

    static func read(_ relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ScanError.unreadable(relativePath)
        }
        return text
    }

    /// 剥注释与字符串字面量后，代码里是否出现 `LyricsFollowPolicy`。
    static func referencesPolicy(_ source: String) -> Bool {
        stripped(source).range(of: "LyricsFollowPolicy") != nil
    }

    /// 逐字符扫描：去掉 `//…`、`/*…*/` 与 `"…"`（含转义），其余原样保留。
    static func stripped(_ source: String) -> String {
        let chars = Array(source)
        var out: [Character] = []
        var index = 0
        let count = chars.count
        var inLineComment = false
        var inBlockComment = false
        var inString = false
        while index < count {
            let current = chars[index]
            let next: Character? = index + 1 < count ? chars[index + 1] : nil
            if inLineComment {
                if current == "\n" { inLineComment = false; out.append(current) }
                index += 1
            } else if inBlockComment {
                if current == "*", next == "/" { inBlockComment = false; index += 2 } else { index += 1 }
            } else if inString {
                if current == "\\" { index += 2 } else if current == "\"" { inString = false; index += 1 } else { index += 1 }
            } else {
                if current == "/", next == "/" {
                    inLineComment = true; index += 2
                } else if current == "/", next == "*" {
                    inBlockComment = true; index += 2
                } else if current == "\"" {
                    inString = true; index += 1
                } else {
                    out.append(current); index += 1
                }
            }
        }
        return String(out)
    }
}
