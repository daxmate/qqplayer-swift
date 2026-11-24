//
//  Stubs.swift — 列宽 harness 的最小桩（**不参与 App target 编译**）
//
//  MacTrackColumnResizer 只在「解析宿主 NSScrollView」时用到 MacHostScrollView；
//  列宽持久化断言不碰滚动容器，因此这里给 nil 即可。
//  fail-closed：生产签名漂移 → swiftc 直接编译失败（脚本 exit 1），绝不静默跳过。
//

import AppKit

enum MacHostScrollView {
    @MainActor
    static func enclosing(of view: NSView) -> NSScrollView? { nil }
}
