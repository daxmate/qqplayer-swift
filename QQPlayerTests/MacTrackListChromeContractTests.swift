//
//  MacTrackListChromeContractTests.swift
//  QQPlayerTests
//
//  曲目列表「视觉 chrome」的源码契约（防回流，2026-11-25）。
//
//  被守住的缺陷（同日两处回归，同一个根因类别：列表 chrome 没跟整窗玻璃 / 窄栏对齐）：
//    ① 分组吸顶头用 `.background(.bar)` —— 整窗玻璃生效时 `.bar` 里没有任何玻璃让路逻辑，
//       整条铺不透明浅色、比列表底色更亮（每组头一条白，还透过左侧半透明侧栏渗出一条白）；
//    ② 工具栏「定位当前播放」的 Label 是整行唯一可压缩项 —— 中栏约 380pt 时被压到一字宽，
//       SwiftUI 逐字换行成竖排，行高从一行撑成六行。
//
//  这些是**源码形状**守卫：吸顶头是否又直接铺材质而不走 sectionHeaderBackdrop、
//  定位按钮是否又丢了单行 / 图标退化约束。
//

import Foundation
import Testing

struct MacTrackListChromeContractTests {
    private static let groupedViewPath = "QQPlayer/Mac/MacTrackGroupedView.swift"
    private static let listViewPath = "QQPlayer/Mac/MacTrackListView.swift"
    private static let toolbarLabelPath = "QQPlayer/Mac/MacTrackListToolbarLabel.swift"

    /// 仓库根：默认按 `#filePath`（<root>/QQPlayerTests/<本文件>）回退两级。
    /// `QQPLAYER_REPO_ROOT` 只给「不经 Xcode 的本地独立跑」指路，CI / 正常单测不设。
    private static let repositoryRoot: URL = {
        if let override = ProcessInfo.processInfo.environment["QQPLAYER_REPO_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    // MARK: - 检测器（唯一入口，自证用例共用）

    /// ① 找「直接铺材质」的背景写法：`.background(.bar)` / `.background(Material.bar)`。
    /// 返回第一处命中的原始行；`nil` = 合规。
    static func firstDirectMaterialBackground(in code: String) -> String? {
        for rawLine in code.components(separatedBy: "\n") {
            let line = strippingLineComments(rawLine)
            if line.range(of: #"\.background\(\s*(Material\.)?\.?bar\s*\)"#, options: .regularExpression) != nil {
                return rawLine.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// ② 定位按钮标题的约束体检：整句单行（`lineLimit(1)`）+ 按理想宽度判定（`fixedSize`）
    /// + 有 ViewThatFits 退化分支。返回缺失项说明；`nil` = 合规。
    static func missingSingleLineConstraints(in code: String) -> String? {
        let body = strippingLineComments(code)
        guard body.contains("ViewThatFits(in: .horizontal)") else { return "缺 ViewThatFits 横向退化分支" }
        guard body.contains(".lineLimit(1)") else { return "缺 lineLimit(1)（Text 会被压到一字宽后竖排）" }
        guard body.contains(".fixedSize(horizontal: true") else {
            return "首选项缺 fixedSize(horizontal: true…)（不自缩会让 ViewThatFits 误判「放得下」）"
        }
        return nil
    }

    /// 截取以 `marker` 开头、到下一个同级声明（`private ` / `static ` / `@ViewBuilder` / `// MARK:`）为止的源码段。
    static func region(startingWith marker: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        var end = lines.count
        for index in (start + 1) ..< lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("private ") || trimmed.hasPrefix("static ")
                || trimmed.hasPrefix("@ViewBuilder") || trimmed.hasPrefix("@Test")
                || trimmed.hasPrefix("// MARK:") {
                end = index
                break
            }
        }
        return lines[start ..< end].joined(separator: "\n")
    }

    // MARK: - 契约

    @Test("分组吸顶头不直接铺材质：背景走 sectionHeaderBackdrop，玻璃模式走透明分支")
    func groupedHeaderBackgroundIsRouted() throws {
        let source = try Self.source(at: Self.groupedViewPath)
        let header = try #require(
            Self.region(startingWith: "private func sectionHeader(", in: source),
            "找不到 MacTrackGroupedView.sectionHeader"
        )
        if let offender = Self.firstDirectMaterialBackground(in: header) {
            Issue.record("吸顶头又直接铺材质背景（玻璃模式会整条白）：\(offender)")
        }
        #expect(
            header.contains(".background(sectionHeaderBackdrop)"),
            "吸顶头背景必须经 sectionHeaderBackdrop 唯一入口（玻璃 / 非玻璃分流都在那里）"
        )

        let backdrop = try #require(
            Self.region(startingWith: "private var sectionHeaderBackdrop", in: source),
            "找不到 sectionHeaderBackdrop"
        )
        #expect(backdrop.contains("isWindowGlassActive"), "sectionHeaderBackdrop 未按整窗玻璃判据分流")
        #expect(backdrop.contains("Material.bar"), "非玻璃模式应保留改动前的 .bar 材质观感")
    }

    @Test("定位按钮标题带单行 + 图标退化约束")
    func locateButtonHasSingleLineGuards() throws {
        let source = try Self.source(at: Self.listViewPath)
        let toolbar = try #require(
            Self.region(startingWith: "private var toolbarRow", in: source),
            "找不到 MacTrackListView.toolbarRow"
        )
        #expect(
            toolbar.contains("MacTrackListToolbarLabel()"),
            "工具栏定位按钮必须用统一标题视图 MacTrackListToolbarLabel（单行 / 图标退化约束都在那里）"
        )

        let labelSource = try Self.source(at: Self.toolbarLabelPath)
        let label = try #require(
            Self.region(startingWith: "struct MacTrackListToolbarLabel", in: labelSource),
            "找不到 MacTrackListToolbarLabel"
        )
        if let missing = Self.missingSingleLineConstraints(in: label) {
            Issue.record("定位按钮标题缺少单行 / 退化约束：\(missing)")
        }
        #expect(label.contains("Image(systemName: \"location\")"), "退化分支应是纯图标（同一 SF Symbol）")
    }

    // MARK: - 检测器自证

    @Test("检测器自证：旧写法命中、合规写法放过")
    func detectorSelfTest() {
        // ① 吸顶头材质背景
        #expect(Self.firstDirectMaterialBackground(in: ".background(.bar)") != nil)
        #expect(Self.firstDirectMaterialBackground(in: "            .background(Material.bar)") != nil)
        #expect(Self.firstDirectMaterialBackground(in: "            .background(sectionHeaderBackdrop)") == nil)
        #expect(Self.firstDirectMaterialBackground(in: "// 旧写法：.background(.bar)，已删除") == nil)

        // ② 定位按钮约束
        let legacy = "Label(Localized.locatePlayingTrack, systemImage: \"location\")\n    .font(.callout)"
        #expect(Self.missingSingleLineConstraints(in: legacy) != nil)
        let onlyLineLimit = legacy + "\n    .lineLimit(1)"
        #expect(
            Self.missingSingleLineConstraints(in: onlyLineLimit) != nil,
            "只加 lineLimit 会截断成省略号，必须保留退化分支"
        )
        let fixed = """
        ViewThatFits(in: .horizontal) {
            Label(Localized.locatePlayingTrack, systemImage: "location")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "location")
        }
        """
        #expect(Self.missingSingleLineConstraints(in: fixed) == nil)

        // ③ 区段截取：命中 marker 后到下一个同级声明为止
        let sample = """
        struct X {
            private var a: Int {
                1
            }
            @ViewBuilder
            private var b: some View {
                Text("b")
            }
        }
        """
        let region = Self.region(startingWith: "private var a", in: sample)
        #expect(region?.contains("Text(\"b\")") == false)
        #expect(region?.contains("1") == true)
    }

    // MARK: - 源码读取

    private static func source(at relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 去掉行尾 `//` 注释（检测器只看代码；注释里提旧写法不该算命中）。
    private static func strippingLineComments(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }
}
