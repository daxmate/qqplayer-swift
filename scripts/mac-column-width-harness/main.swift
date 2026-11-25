//
//  main.swift — 曲目列表列宽持久化（MacTrackColumnWidthStore）的 swiftc 断言
//
//  为什么在这里而不是 QQPlayerTests：仓库**没有 macOS 单测 target**（QQPlayerTests
//  的 SDKROOT=iphoneos，见 docs/sync-invariants.md:171），`QQPlayer/Mac/*` 不编 iOS。
//  与 `scripts/mac-chrome-harness` 同策略：swiftc 直编**生产源码**（不复制实现），
//  在 macOS 上真跑断言；CI 由 `scripts/run-mac-column-width-tests.sh` 在 macOS 通道执行。
//
//  覆盖：缺失回落、round-trip、最小宽度夹紧、上限夹紧、NaN/∞ 回落、脏类型回落、
//  单列缺失不影响他列、key 口径稳定，以及「写盘唯一入口 = onCommit」的源码契约。
//

import AppKit
import Foundation

// MARK: - 迷你断言（与 scripts/mac-chrome-harness 同形）

var checks = 0
var failures: [String] = []

func section(_ title: String) {
    print("\n▶︎ \(title)")
}

func expect(_ condition: Bool, _ message: String) {
    checks += 1
    guard condition else {
        failures.append(message)
        print("  ❌ \(message)")
        return
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    checks += 1
    guard actual == expected else {
        failures.append("\(message)：实际 \(actual)，期望 \(expected)")
        print("  ❌ \(message)：实际 \(actual)，期望 \(expected)")
        return
    }
}

// MARK: - 夹具

/// 每个用例独立 suite：互不污染，也不会写进本机 QQPlayer 的真实偏好。
func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "com.daxmate.qqplayer.mac-column-width-harness.\(name)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    guard let defaults = UserDefaults(suiteName: suite) else {
        fatalError("无法创建 UserDefaults suite：\(suite)")
    }
    // suite 可能残留旧值：清空后再用（首次创建时这一步是空操作）。
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

func countOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex ..< haystack.endIndex
    while let found = haystack.range(of: needle, range: searchRange) {
        count += 1
        searchRange = found.upperBound ..< haystack.endIndex
    }
    return count
}

// MARK: - key 口径

section("key 口径稳定（换版本号才允许改）")
expectEqual(
    MacTrackColumnWidthStore.Column.title.defaultsKey,
    "mac.trackList.columnWidths.v1.title",
    "标题列 key"
)
expectEqual(
    MacTrackColumnWidthStore.Column.artist.defaultsKey,
    "mac.trackList.columnWidths.v1.artist",
    "艺人列 key"
)
expectEqual(
    MacTrackColumnWidthStore.Column.album.defaultsKey,
    "mac.trackList.columnWidths.v1.album",
    "专辑列 key"
)

// MARK: - 缺失 → 初始宽度

section("首次启动（无任何键）→ 三列各自 InitialWidth")
do {
    let store = MacTrackColumnWidthStore(defaults: freshDefaults("missing"))
    let widths = store.load()
    expectEqual(widths, MacTrackColumnWidths(), "缺失时应等于 MacTrackColumnWidths() 默认值")
    expectEqual(widths.title, MacTrackColumnLayout.titleInitialWidth, "标题列初始宽度")
    expectEqual(widths.artist, MacTrackColumnLayout.artistInitialWidth, "艺人列初始宽度")
    expectEqual(widths.album, MacTrackColumnLayout.albumInitialWidth, "专辑列初始宽度")
}

// MARK: - round-trip

section("save → 新 store 实例 load：原样往返（重启语义）")
do {
    let defaults = freshDefaults("roundtrip")
    MacTrackColumnWidthStore(defaults: defaults).save(
        MacTrackColumnWidths(title: 260, artist: 200, album: 240)
    )
    let reloaded = MacTrackColumnWidthStore(defaults: defaults).load()
    expectEqual(reloaded, MacTrackColumnWidths(title: 260, artist: 200, album: 240), "三列往返")
}

// MARK: - 最小宽度夹紧

section("低于最小宽度 → 抬到 MacTrackColumnLayout.minWidth")
do {
    let defaults = freshDefaults("clamp-min")
    let store = MacTrackColumnWidthStore(defaults: defaults)
    store.save(MacTrackColumnWidths(title: 10, artist: 1, album: 0))
    let widths = store.load()
    expectEqual(widths.title, MacTrackColumnLayout.titleMinWidth, "标题列抬到最小宽度")
    expectEqual(widths.artist, MacTrackColumnLayout.artistMinWidth, "艺人列抬到最小宽度")
    expectEqual(widths.album, MacTrackColumnLayout.albumMinWidth, "专辑列抬到最小宽度")
}

// MARK: - 上限夹紧

section("高于上限 → 压到 4000")
do {
    let store = MacTrackColumnWidthStore(defaults: freshDefaults("clamp-max"))
    store.save(MacTrackColumnWidths(title: 99_999, artist: 99_999, album: 99_999))
    let widths = store.load()
    expectEqual(widths.title, MacTrackColumnWidthStore.maximumColumnWidth, "标题列上限")
    expectEqual(widths.artist, MacTrackColumnWidthStore.maximumColumnWidth, "艺人列上限")
    expectEqual(widths.album, MacTrackColumnWidthStore.maximumColumnWidth, "专辑列上限")
}

// MARK: - 非有限值

section("NaN / ∞ → 该列回落 InitialWidth，他列不受影响")
do {
    let store = MacTrackColumnWidthStore(defaults: freshDefaults("non-finite"))
    store.save(MacTrackColumnWidths(title: .nan, artist: 200, album: .infinity))
    let widths = store.load()
    expectEqual(widths.title, MacTrackColumnLayout.titleInitialWidth, "NaN 列回落初始宽度")
    expectEqual(widths.artist, 200, "正常列保持")
    expectEqual(widths.album, MacTrackColumnLayout.albumInitialWidth, "∞ 列回落初始宽度")
}

// MARK: - 脏类型

section("键被写坏：字符串回落 InitialWidth；布尔按 1 夹到 minWidth")
do {
    let defaults = freshDefaults("corrupt")
    let store = MacTrackColumnWidthStore(defaults: defaults)
    store.save(MacTrackColumnWidths(title: 260, artist: 200, album: 240))
    defaults.set("broken", forKey: MacTrackColumnWidthStore.Column.title.defaultsKey)
    defaults.set(true, forKey: MacTrackColumnWidthStore.Column.artist.defaultsKey)
    let widths = store.load()
    expectEqual(widths.title, MacTrackColumnLayout.titleInitialWidth, "字符串脏值回落")
    expectEqual(widths.artist, MacTrackColumnLayout.artistMinWidth, "布尔脏值被夹到最小宽度（不当成 1pt 列）")
    expectEqual(widths.album, 240, "未受影响的列保持")
}

// MARK: - 单列缺失

section("只有一列有历史值 → 其余列各自回落初始化")
do {
    let defaults = freshDefaults("partial")
    defaults.set(210.0, forKey: MacTrackColumnWidthStore.Column.artist.defaultsKey)
    let widths = MacTrackColumnWidthStore(defaults: defaults).load()
    expectEqual(widths.title, MacTrackColumnLayout.titleInitialWidth, "缺标题列")
    expectEqual(widths.artist, 210, "有的艺人列按存的来")
    expectEqual(widths.album, MacTrackColumnLayout.albumInitialWidth, "缺专辑列")
}

// MARK: - 渲染期列宽收敛（MacTrackColumnFit）

section("渲染期列宽收敛：只压不放、保底不溢出")

let columnMinimums = MacTrackColumnLayout.minimumWidths
let fixedColumns = MacTrackColumnLayout.fixedColumnsWidth

do {
    // ① 放得下 → 原样（只向下取整）
    let roomy = MacTrackColumnFit.fitted(
        MacTrackColumnWidths(title: 160, artist: 100, album: 90),
        availableWidth: 520,
        fixedWidth: fixedColumns,
        minimums: columnMinimums
    )
    expectEqual(roomy.title, 160, "F1a 放得下：标题列原样")
    expectEqual(roomy.artist, 100, "F1b 放得下：艺人列原样")
    expectEqual(roomy.album, 90, "F1c 放得下：专辑列原样")

    // ② 默认初始宽（300/140/180）在中栏 420 宽：必须压到预算内
    let defaultWidths = MacTrackColumnWidths(
        title: MacTrackColumnLayout.titleInitialWidth,
        artist: MacTrackColumnLayout.artistInitialWidth,
        album: MacTrackColumnLayout.albumInitialWidth
    )
    let budget420 = 420 - fixedColumns
    let fitted420 = MacTrackColumnFit.fitted(
        defaultWidths,
        availableWidth: 420,
        fixedWidth: fixedColumns,
        minimums: columnMinimums
    )
    let fitted420Total = MacTrackColumnFit.total(of: fitted420)
    expect(fitted420Total <= budget420, "F2a 420 宽：总宽不超预算（\(fitted420Total) ≤ \(budget420)）")
    expect(fitted420.title >= MacTrackColumnLayout.titleMinWidth, "F2b 420 宽：标题列保住最小宽")
    expect(fitted420.artist >= MacTrackColumnLayout.artistMinWidth, "F2c 420 宽：艺人列保住最小宽")
    expect(fitted420.album >= MacTrackColumnLayout.albumMinWidth, "F2d 420 宽：专辑列保住最小宽")
    expect(fitted420Total < MacTrackColumnFit.total(of: defaultWidths), "F2e 420 宽：确实压缩了")

    // ③ 只压不放：窗口很宽也不把列撑大
    let wide = MacTrackColumnFit.fitted(
        defaultWidths,
        availableWidth: 1_400,
        fixedWidth: fixedColumns,
        minimums: columnMinimums
    )
    expectEqual(wide, defaultWidths, "F3 只压不放：可用宽富余时列宽不变")

    // ④ 极窄（中栏最小 320）：连最小宽都放不下时按比例硬压，仍不溢出
    let budgetNarrow = 320 - fixedColumns
    let narrow = MacTrackColumnFit.fitted(
        defaultWidths,
        availableWidth: 320,
        fixedWidth: fixedColumns,
        minimums: columnMinimums
    )
    let narrowTotal = MacTrackColumnFit.total(of: narrow)
    expect(narrowTotal <= budgetNarrow, "F4a 320 宽：总宽不超预算（\(narrowTotal) ≤ \(budgetNarrow)）")
    expect(narrow.title > 0 && narrow.artist > 0 && narrow.album > 0, "F4b 320 宽：三列都还有宽度（不压成 0）")

    // ⑤ 预算 ≤ 0（窗口被拖得比固定列还窄）→ 全 0，不返回负宽
    let collapsed = MacTrackColumnFit.fitted(
        defaultWidths,
        availableWidth: fixedColumns - 10,
        fixedWidth: fixedColumns,
        minimums: columnMinimums
    )
    expectEqual(collapsed, MacTrackColumnWidths(title: 0, artist: 0, album: 0), "F5 预算不足：三列归零")

    // ⑥ 脏值（NaN / 负数）不能让夹紧结果变成 NaN
    let dirty = MacTrackColumnFit.fitted(
        MacTrackColumnWidths(title: .nan, artist: -50, album: 180),
        availableWidth: 420,
        fixedWidth: fixedColumns,
        minimums: columnMinimums
    )
    expect(dirty.title.isFinite && dirty.title >= 0, "F6a NaN → 0")
    expect(dirty.artist >= 0, "F6b 负数 → 0")
    expect(MacTrackColumnFit.total(of: dirty) <= budget420, "F6c 脏值输入也不超预算")

    // ⑦ 整数化：向下取整后总宽仍然 ≤ 预算（半像素累积是横向滚动条的常见来源）
    let fractional = MacTrackColumnFit.fitted(
        MacTrackColumnWidths(title: 300.7, artist: 140.7, album: 180.7),
        availableWidth: 421.3,
        fixedWidth: fixedColumns,
        minimums: columnMinimums
    )
    let fractionalValues = [fractional.title, fractional.artist, fractional.album]
    expect(fractionalValues.allSatisfy { $0 == $0.rounded(.down) }, "F7a 列宽都是整数")
    expect(
        MacTrackColumnFit.total(of: fractional) <= (421.3 - fixedColumns).rounded(.down),
        "F7b 取整后仍不超预算"
    )
}

// MARK: - 源码契约：写盘唯一入口

section("接线契约（源码扫描，防渲染期写盘 / 第二处 @State）")
do {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // mac-column-width-harness
        .deletingLastPathComponent()  // scripts
        .deletingLastPathComponent()  // 仓库根
    let viewPath = repoRoot.appendingPathComponent("QQPlayer/Mac/MacTrackListView.swift").path
    if let viewSource = try? String(contentsOfFile: viewPath, encoding: .utf8) {
        expect(
            viewSource.contains(".macTrackColumnWidthDrag(widths: $columnWidths)"),
            "列表应走 macTrackColumnWidthDrag 唯一入口"
        )
        expect(
            !viewSource.contains(".save("),
            "MacTrackListView 不得自己写盘（写盘只在 macTrackColumnWidthDrag 的 onCommit 内）"
        )
        expect(
            viewSource.contains("MacTrackColumnWidthStore().load()"),
            "@State columnWidths 初值应来自 store.load()"
        )
        expect(
            countOccurrences(of: "@State private var columnWidths", in: viewSource) == 1,
            "列宽只允许一份 @State（单一真相源）"
        )
    } else {
        expect(false, "读不到 MacTrackListView.swift：\(viewPath)")
    }

    let resizerPath = repoRoot.appendingPathComponent("QQPlayer/Mac/MacTrackColumnResizer.swift").path
    if let resizerSource = try? String(contentsOfFile: resizerPath, encoding: .utf8) {
        expect(
            resizerSource.contains("func macTrackColumnWidthDrag("),
            "MacTrackColumnResizer.swift 应定义 macTrackColumnWidthDrag 入口"
        )
        expect(
            countOccurrences(of: "store.save(newWidths)", in: resizerSource) == 1,
            "全仓只允许一个列宽写盘调用"
        )
        if let assign = resizerSource.range(of: "widths.wrappedValue = newWidths"),
           let save = resizerSource.range(of: "store.save(newWidths)")
        {
            expect(assign.lowerBound < save.lowerBound, "先更新 @State 再写盘（顺序不可反）")
        } else {
            expect(false, "找不到「更新 @State → 写盘」两行")
        }
    } else {
        expect(false, "读不到 MacTrackColumnResizer.swift：\(resizerPath)")
    }
}

// MARK: - 汇总

print("\n\(checks) 项断言，\(failures.count) 项失败")
if failures.isEmpty {
    print("✅ 曲目列表列宽持久化断言全部通过")
    exit(0)
}
for failure in failures {
    print("  · \(failure)")
}
exit(1)
