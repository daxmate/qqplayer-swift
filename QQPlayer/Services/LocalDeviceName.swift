//
//  LocalDeviceName.swift
//  QQPlayer
//
//  本机展示名（局域网同步用）——用户可命名的设备名 + UserDefaults 持久化。
//
//  背景：设备展示名原先只在**配对那一刻**由 `PairRequest.clientName` 落库
//  （sync_device.display_name），之后改名不会更新；且 iOS 侧 `UIDevice.current.name`
//  在 iOS 16+ 未申请 entitlement 时只返回泛化名（"iPhone"），用户无法按名字认设备。
//  本文件提供「本机展示名」的唯一事实源：
//    · 用户改过名 → 用用户的名字（持久化在 UserDefaults）
//    · 没改过 → 回落系统默认名（`LocalDeviceName.systemDefault`）
//  展示名的消费点：握手 hello（`SyncHello.name`）→ Mac host 按名刷新信任表；
//  将来 iOS 设置页写名也只走 `LocalDeviceNameStore.setName`。
//
//  平台隔离：iOS 的 `UIDevice` 与 macOS 的 `Host` 都不在共享 Core 里可用，
//  故 `systemDefault` 用 `#if os(iOS)` 隔离，共享文件不触 UIKit。
//
//  失败语义：读不到 / 空 / 纯空白一律回落系统默认名，绝不返回空串。
//

import Foundation

#if os(iOS)
    import UIKit
#endif

// MARK: - 系统默认名

/// 系统默认展示名（用户未命名时回落）。
enum LocalDeviceName {
    /// - iOS：`UIDevice.current.name`（未申请 entitlement 时是泛化名，如 "iPhone"——
    ///   属预期：用户改名后才用用户的名）。**须在主线程调用**（内部 `assumeIsolated`）
    /// - macOS：Bonjour 本地化名，取不到回落进程主机名（与旧 `SyncHostCenter`
    ///   里内联的实现逐字一致）
    static var systemDefault: String {
        #if os(iOS)
            // `UIDevice` 在 Swift 6 下是 `@MainActor`：本属性只在主线程被调用
            // （`SyncHostCenter` / `IOSPassiveSyncCenter` / iOS 设置页均为 `@MainActor`），
            // 用 `assumeIsolated` 保持同步取值语义（同 `QQPlayerMacApp` 既有用法）。
            // 若将来出现非主线程调用点，会在此 precondition 失败——届时改为 async 取值。
            MainActor.assumeIsolated { UIDevice.current.name }
        #else
            Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }
}

// MARK: - 持久化

/// 本机展示名读写（UserDefaults，平台无关、可单测）。
/// 线程安全：UserDefaults 自身线程安全；注入的 `systemDefault` 闭包按调用方约定
/// 线程安全（生产实现只读系统 API）。
final class LocalDeviceNameStore: @unchecked Sendable {
    /// 生产单例（App 内唯一读写入口）。
    static let shared = LocalDeviceNameStore()

    /// 存档键（v1 单机名单值）。
    static let defaultKey = "sync.localDeviceName.v1"

    private let defaults: UserDefaults
    private let key: String
    private let systemDefault: () -> String

    /// - Parameters:
    ///   - defaults: 存储（单测注入独立 suite，不污染 `.standard`）
    ///   - key: 存档键（单测可指定）
    ///   - systemDefault: 系统默认名来源（单测注入桩，避免依赖真机设备名）
    init(
        defaults: UserDefaults = .standard,
        key: String = LocalDeviceNameStore.defaultKey,
        systemDefault: @escaping () -> String = { LocalDeviceName.systemDefault }
    ) {
        self.defaults = defaults
        self.key = key
        self.systemDefault = systemDefault
    }

    /// 当前展示名：保存值 trim 后非空用保存值，否则回落系统默认名。
    var name: String {
        guard let saved = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !saved.isEmpty
        else {
            return systemDefault()
        }
        return saved
    }

    /// 设置展示名：trim 后为空 → 删除键（回落系统默认）；有值 → 存 trim 后的值。
    func setName(_ new: String?) {
        let trimmed = new?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(trimmed, forKey: key)
    }
}
