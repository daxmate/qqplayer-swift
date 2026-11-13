//
//  AccentInjector.swift
//  QQPlayer
//
//  强调色注入点（QQPlayerMac target only）：在两个场景根与桌面浮窗装配处统一使用。
//  2026-11-13 新增，取代「在 App/Scene body 里直接读 `MacAppearance.currentAccentColor`」。
//
// 为什么必须放在**被观察的 View body** 里：
// `.tint(...)` / `.environment(\.appAccentColor, ...)` 的实参在 SwiftUI 求值该 body 时
// 才算出来。App / Scene 的 `body` 没有可观察依赖（`MacAppearance` 是静态计算属性），
// 换色时根本不会重新求值 ⇒ 注入的环境值仍是启动时那一份，只有自带
// `.onReceive(.qqplayerSettingsDidChange)` 刷新的视图（如频谱）会变色。
// 把 `@State` 的 `AccentStore` 放进这个 View 后，`store.color` 的读取发生在**本 View
// body 求值期**，可观察依赖才会被登记：设置变化 → `store.key` 变 → body 重算 →
// tint / 环境值更新 → 所有消费者立即跟随，不需要重启。
//

import SwiftUI

/// 把当前强调色注入子树的 `.tint` 与 `\.appAccentColor`（同源、可观察）。
struct AccentInjector<Content: View>: View {
    /// 强调色的唯一可观察源；每个注入点一个实例，随视图生命周期释放。
    @State private var store = AccentStore()

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // ⚠️ 必须在 body 求值范围内读 `store.color`（理由见文件头）：把可观察读取挪进
        // Canvas 渲染闭包 / 派生对象里都不会登记依赖，换色就不会重绘。
        let accent = store.color
        content
            .tint(accent)
            .environment(\.appAccentColor, accent)
    }
}
