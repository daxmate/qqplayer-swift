//
//  MacMainWindowSelectionTests.swift
//  QQPlayerTests
//
//  主窗候选选择（MacMainWindowSelection）纯逻辑防回归测试（2026-11-25）。
//
//  背景：2026-11-24 产品显示名改「婷听 / TingFi」后，运行实例的主窗标题不再是 "QQPlayer"，
//  旧的「按标题找主窗」判据必然落空、且失败完全静默（迷你窗点封面回主窗什么都不发生）。
//  这里锁定新的三级判据：① 视图侧登记 → ② identifier → ③ canBecomeMain 兜底，
//  并锁死「标题不参与选择」——候选结构里根本没有 title 字段。
//

import Testing

@testable import QQPlayer

struct MacMainWindowSelectionTests {
    private static let mainIdentifier = MacMainWindowSelection.mainWindowIdentifier

    private func candidate(
        identifier: String? = nil,
        isPanel: Bool = false,
        canBecomeMain: Bool = true,
        isVisible: Bool = true,
        isRegistered: Bool = false,
        isReleasedWhenClosed: Bool = false
    ) -> MacMainWindowCandidate {
        MacMainWindowCandidate(
            identifier: identifier,
            isPanel: isPanel,
            canBecomeMain: canBecomeMain,
            isVisible: isVisible,
            isRegistered: isRegistered,
            isReleasedWhenClosed: isReleasedWhenClosed
        )
    }

    @Test("identifier 命中优先于 canBecomeMain 兜底（标题已不可靠时的主要判据）")
    func identifierWinsOverFallback() {
        let candidates = [
            candidate(),                                            // 0: 普通窗，能成为主窗（旧兜底会选它）
            candidate(identifier: Self.mainIdentifier),              // 1: 打上主窗标识的那个
        ]

        let pick = MacMainWindowSelection.pick(from: candidates)

        #expect(pick == MacMainWindowPick(index: 1, source: .identifier))
    }

    @Test("视图侧登记的弱引用优先于 identifier")
    func registeredWins() {
        let candidates = [
            candidate(identifier: Self.mainIdentifier),  // 0: 标识命中（但已不是登记的那个）
            candidate(isRegistered: true),               // 1: 登记的那个
        ]

        let pick = MacMainWindowSelection.pick(from: candidates)

        #expect(pick == MacMainWindowPick(index: 1, source: .registered))
    }

    @Test("NSPanel 永不作为主窗（哪怕带主窗标识、也能 canBecomeMain）")
    func panelIsNeverSelected() {
        let candidates = [
            candidate(identifier: Self.mainIdentifier, isPanel: true, canBecomeMain: true),
            candidate(isPanel: true, canBecomeMain: true),
            candidate(isPanel: true, canBecomeMain: true, isRegistered: true),
        ]

        #expect(MacMainWindowSelection.pick(from: candidates) == nil)
    }

    @Test("没有 identifier 命中时按数组顺序稳定选择，不依赖标题")
    func fallbackIsOrderStable() {
        let candidates = [
            candidate(),  // 0
            candidate(),  // 1
        ]
        let reversed = [candidates[1], candidates[0]]

        let first = MacMainWindowSelection.pick(from: candidates)
        let again = MacMainWindowSelection.pick(from: candidates)
        let fromReversed = MacMainWindowSelection.pick(from: reversed)

        #expect(first == MacMainWindowPick(index: 0, source: .canBecomeMain))
        #expect(again == first, "同一输入必须得到同一结果")
        #expect(fromReversed == MacMainWindowPick(index: 0, source: .canBecomeMain), "顺序变了结果随之变，说明只认数组顺序")
    }

    @Test("迷你态主窗不可见（orderOut）时仍要选中 —— 不能用可见性过滤")
    func hiddenMainWindowIsStillSelected() {
        let candidates = [
            candidate(identifier: Self.mainIdentifier, isVisible: false),
        ]

        #expect(MacMainWindowSelection.pick(from: candidates) == MacMainWindowPick(index: 0, source: .identifier))
    }

    @Test("已关闭待释放（僵尸态）的窗口不参与选择")
    func releasedZombieIsSkipped() {
        let candidates = [
            candidate(isRegistered: true, isReleasedWhenClosed: true),
            candidate(identifier: Self.mainIdentifier),
        ]

        #expect(MacMainWindowSelection.pick(from: candidates) == MacMainWindowPick(index: 1, source: .identifier))
    }

    @Test("候选全不满足 → nil（失败路径由调用方打日志）")
    func returnsNilWhenNothingMatches() {
        let candidates = [
            candidate(canBecomeMain: false),
            candidate(isPanel: true, canBecomeMain: true),
            candidate(identifier: "com.example.other", canBecomeMain: false),
        ]

        #expect(MacMainWindowSelection.pick(from: candidates) == nil)
    }
}
