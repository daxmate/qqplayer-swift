//
//  SyncWiringSelfCheckTests.swift
//  QQPlayerTests
//
//  L5 装配层**运行时自检**的纯逻辑防回归（无网络 / 无 IO）：
//  - `SyncWiringSelfCheck.gaps(items:)`：无缺口 / 单缺口 / 多缺口 /「不适用」不计缺口
//  - `SyncWiringSelfCheck.items(platform:facts:)`：声明**只**来自注册表（不手写第二份名单）
//  - `SyncWiringSelfCheckPresenter.gapRow(_:)`：缺口 = 0 = 空态（不显示任何行）
//  - `SyncWiringFactsStore`：装配点写事实 → 缺口发布；会话拆除归零
//  - 新文案五语齐全（扫 `.strings` 源码——缺一份界面就显示 key 原文）
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncWiringSelfCheckTests {
    static let repoRoot = SyncWiringContractTests.repoRoot

    // MARK: - 夹具

    private func item(
        _ capabilityID: String,
        probe: SyncWiringProbe,
        attached: Bool?,
        frame: Int? = 8
    ) -> SyncWiringSelfCheckItem {
        SyncWiringSelfCheckItem(
            capabilityID: capabilityID,
            platform: SyncEntityRegistry.platformIOS,
            frame: frame,
            detail: "夹具 \(capabilityID)",
            probe: probe,
            isAttached: attached
        )
    }

    // MARK: - 纯函数：装配状态 → 缺口

    @Test("无缺口：全部装配上 → 缺口为空（面板空态）")
    func noGapsWhenEverythingAttached() {
        let gaps = SyncWiringSelfCheck.gaps(items: [
            item("A", probe: .changeLogPeer, attached: true),
            item("G", probe: .libraryPassiveHost, attached: true),
        ])
        #expect(gaps.isEmpty, "全装上不该有缺口：\(gaps)")
    }

    @Test("单缺口：一项没装上 → 恰一条缺口（点名能力 + 探针 + 说明）")
    func singleGapIsReported() {
        let gaps = SyncWiringSelfCheck.gaps(items: [
            item("A", probe: .changeLogPeer, attached: true),
            item("G", probe: .libraryPassiveHost, attached: false),
        ])
        #expect(gaps.count == 1, "实际：\(gaps)")
        #expect(gaps.first?.capabilityID == "G")
        #expect(gaps.first?.probe == .libraryPassiveHost)
        #expect(gaps.first?.id == "G|iOS|libraryPassiveHost")
        #expect(gaps.first?.logLine.contains("夹具 G") == true, "日志要说明缺了什么：\(gaps.first?.logLine ?? "nil")")
    }

    @Test("多缺口：列表顺序 = 输入顺序（= 注册表声明顺序），不丢不重")
    func multipleGapsKeepOrder() {
        let gaps = SyncWiringSelfCheck.gaps(items: [
            item("A", probe: .changeLogPeer, attached: false),
            item("E", probe: .playbackPositionSink, attached: false),
            item("G", probe: .libraryPassiveHost, attached: true),
        ])
        #expect(gaps.map(\.capabilityID) == ["A", "E"], "实际：\(gaps.map(\.capabilityID))")
        #expect(gaps.map(\.probe) == [.changeLogPeer, .playbackPositionSink])
    }

    @Test("「不适用」不是缺口：门控关（nil）不计缺口——设计如此不是故障（INV-26）")
    func notApplicableIsNotAGap() {
        let gaps = SyncWiringSelfCheck.gaps(items: [
            item("A", probe: .changeLogPeer, attached: true),
            item("E", probe: .playbackPositionSink, attached: nil),
        ])
        #expect(gaps.isEmpty, "门控关不得报缺口：\(gaps)")
        // 与「明确的 false」对比：同一项记 false 就是缺口
        #expect(
            SyncWiringSelfCheck.gaps(items: [item("E", probe: .playbackPositionSink, attached: false)]).count == 1,
            "明确没装上必须报"
        )
    }

    // MARK: - 声明只来自注册表

    @Test("自检项只来自注册表声明（探针清单不在这里手写第二份）")
    func itemsComeFromRegistryDeclarations() {
        let iosItems = SyncWiringSelfCheck.items(platform: SyncEntityRegistry.platformIOS, facts: [:])
        let declaredIOS = SyncEntityRegistry.capabilityAssemblyPoints
            .filter { $0.point.platform == SyncEntityRegistry.platformIOS && $0.point.probe != nil }
        #expect(iosItems.count == declaredIOS.count, "iOS 自检项 \(iosItems.count) ≠ 声明 \(declaredIOS.count)")
        #expect(iosItems.map(\.probe) == declaredIOS.compactMap { $0.point.probe })
        #expect(iosItems.map(\.capabilityID) == declaredIOS.map(\.capabilityID))

        // 平台过滤：Mac 的能力不得出现在 iOS 自检里（反之亦然）
        #expect(!iosItems.contains { $0.probe == .dataSyncEntry }, "Mac 专属能力不该出现在 iOS 自检里")
        #expect(!iosItems.contains { $0.probe == .playbackCarry }, "Mac 专属能力不该出现在 iOS 自检里")

        let macItems = SyncWiringSelfCheck.items(platform: SyncEntityRegistry.platformMac, facts: [:])
        #expect(macItems.contains { $0.probe == .dataSyncEntry }, "Mac 自检缺「同步数据入口」")
        #expect(macItems.contains { $0.probe == .playbackCarry }, "Mac 自检缺「跟歌走携带」")
        #expect(!macItems.contains { $0.probe == .changeLogPeer }, "iOS 专属能力不该出现在 Mac 自检里")

        // 未知平台：空（不误报）
        #expect(SyncWiringSelfCheck.items(platform: "Linux", facts: [:]).isEmpty)

        // 事实里有、注册表没声明的探针不进结果（声明才是唯一来源）
        let withStrayFact = SyncWiringSelfCheck.items(
            platform: SyncEntityRegistry.platformIOS,
            facts: [.playbackCarry: false]
        )
        #expect(withStrayFact.allSatisfy { $0.probe != .playbackCarry }, "未声明的探针不得进自检项")
    }

    @Test("声明了探针的装配点必须有静态断言或在报告里单列（探针 → 断言一一可查）")
    func everyProbeIsDeclaredOnce() {
        let probes = SyncWiringSelfCheck.probes(platform: SyncEntityRegistry.platformIOS)
        #expect(!probes.isEmpty, "iOS 没有任何声明的探针 = 自检空转")
        #expect(
            Set(probes).count == probes.count,
            "同一探针被多个装配点重复声明（缺口会重复计数）：\(probes)"
        )
    }

    // MARK: - 展示（UI 只呈现）

    @Test("缺口 = 0 → nil（空态：面板不显示任何行）")
    func presenterIsEmptyWhenNoGaps() {
        #expect(SyncWiringSelfCheckPresenter.gapRow([]) == nil)
    }

    @Test("缺口 > 0 → 一行：计数 + 缺失能力名（按探针去重，顺序 = 声明顺序）")
    func presenterRowCarriesCountAndNames() {
        let gaps = SyncWiringSelfCheck.gaps(items: [
            item("A", probe: .changeLogPeer, attached: false),
            item("B", probe: .changeLogPeer, attached: false),
            item("G", probe: .libraryPassiveHost, attached: false),
        ])
        guard let row = SyncWiringSelfCheckPresenter.gapRow(gaps) else {
            Issue.record("有缺口却给了空态")
            return
        }
        #expect(row.count == 3, "计数 = 缺口条数（逐能力）：\(row.count)")
        #expect(row.labelKey == SyncWiringSelfCheckPresenter.gapLabelKey)
        #expect(row.hintKey == SyncWiringSelfCheckPresenter.gapHintKey)
        #expect(row.probeLabelKeys == [SyncWiringProbe.changeLogPeer.labelKey, SyncWiringProbe.libraryPassiveHost.labelKey])
    }

    // MARK: - 事实快照（装配点写入）

    @MainActor
    @Test("事实快照：装配点写事实 → 缺口发布；装上的不算、清空后归零（不是缺口）")
    func factsStorePublishesGaps() {
        let store = SyncWiringFactsStore.shared
        store.reset()
        #expect(store.gaps.isEmpty, "初始不得有缺口")

        store.record(.changeLogPeer, attached: false)
        #expect(store.gaps.map(\.probe) == [.changeLogPeer], "实际：\(store.gaps)")
        #expect(store.gaps.first?.capabilityID == "A", "缺口要点名是哪条登记：\(store.gaps)")

        store.record(.libraryPassiveHost, attached: true)
        #expect(store.gaps.map(\.probe) == [.changeLogPeer], "装上的能力不该算缺口：\(store.gaps)")

        store.record(.changeLogPeer, attached: true)
        #expect(store.gaps.isEmpty, "补上后缺口应归零：\(store.gaps)")

        store.record(.playbackPositionSink, attached: nil)
        #expect(store.gaps.isEmpty, "「不适用」（门控关）不得算缺口：\(store.gaps)")

        store.record(.changeLogPeer, attached: false)
        store.clear()
        #expect(store.gaps.isEmpty, "会话拆除后不得留缺口：\(store.gaps)")
        #expect(store.facts.isEmpty, "拆除后事实归零：\(store.facts)")
    }

    // MARK: - 文案（五语齐全）

    @Test("运行时自检文案五语齐全（探针名 + 行标签 + 说明）")
    func wiringStringsCoverFiveLanguages() {
        var keys = [SyncWiringSelfCheckPresenter.gapLabelKey, SyncWiringSelfCheckPresenter.gapHintKey]
        keys += SyncWiringProbe.allCases.map(\.labelKey)

        for language in ["en", "fr", "ru", "zh-Hans", "zh-Hant"] {
            let url = Self.repoRoot
                .appendingPathComponent("QQPlayer/Resources/\(language).lproj/Localizable.strings")
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record("读不到 \(language) 文案（fail-closed，不跳过）：\(url.path)")
                continue
            }
            for key in keys {
                #expect(
                    source.contains("\"\(key)\" = "),
                    "\(language) 缺文案 `\(key)` → 界面会直接显示 key 原文"
                )
            }
        }
    }
}
