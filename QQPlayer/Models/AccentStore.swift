//
//  AccentStore.swift
//  QQPlayer
//
//  App 强调色的唯一可观察源（2026-11-13，修「换色后只有部分 UI 变色」）。
//  QQPlayerMac target only。
//
// 为什么需要它：旧写法把 `MacAppearance.currentAccentColor`（静态计算属性，内部
// 读 `DeleteSettings`，本身不可观察）直接写进 `QQPlayerMacApp` 的 WindowGroup /
// Settings modifier 参数，以及 `MacDesktopWindowsManager` 的浮窗装配里。App / Scene
// body 只在自身可观察状态变化时求值，那些地方没有任何被观察的值 ⇒ 换色后注入点
// 不重新求值，只有自带 `.onReceive(.qqplayerSettingsDidChange)` 刷新的视图变色。
// 这里把「当前强调色」做成可观察存储；注入发生在被观察的 View body 里（见
// `AccentInjector`）。
//
// 不新增第二套色表 / 第二套设置读写：色值解析一律走 `MacAppearance.accentPresets`
// 与 `Color(hex:)`，key 一律取自 `MacAppearance.currentAccentKey`（= `DeleteSettings`）。
//

import Combine
import Foundation
import Observation
import SwiftUI

/// 当前强调色（可观察）。`key` 变 → `color` 的消费者重算。
@MainActor
@Observable
final class AccentStore {
    /// 当前强调色 key。未知 key 的色值回退与 `MacAppearance.accentColor(forKey:)` 一致。
    private(set) var key: String

    /// 当前强调色色值。body 求值期读取即登记对 `key` 的依赖。
    var color: Color { MacAppearance.accentColor(forKey: key) }

    /// key 读取入口：默认走 `MacAppearance.currentAccentKey`（唯一读取入口）；
    /// 单测注入临时来源，避免污染真实 `UserDefaults.standard`。
    private let readKey: @MainActor () -> String

    /// 设置变更订阅。`AnyCancellable` 随实例释放自动取消，无需手工移除观察者；
    /// `sink` 里只捕获 `weak self`，不构成循环引用。
    private var cancellables = Set<AnyCancellable>()

    init(readKey: @escaping @MainActor () -> String = { MacAppearance.currentAccentKey }) {
        let initialKey = readKey()
        self.readKey = readKey
        self.key = initialKey
        NotificationCenter.default
            .publisher(for: .qqplayerSettingsDidChange)
            .sink { [weak self] _ in
                // 通知也可能从后台线程发出（`DeleteSettings.save()` 的兜底分支）→ 回主线程刷新。
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)
    }

    /// 重读持久化设置（可测试入口；设置变更通知也走这里）。
    func refresh() {
        key = readKey()
    }
}
