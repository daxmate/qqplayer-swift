//
//  MacMainWindowRegistration.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  主窗登记探针（2026-11-25）—— 主窗身份的**唯一事实源**。
//
//  探针挂进主窗内容树（WindowGroup 根），把所在 `NSWindow` 登记给
//  `DesktopWindowsManager`（弱引用）并打上 `NSUserInterfaceItemIdentifier`。
//  窗口标题会随产品显示名变（2026-11-24 改「婷听 / TingFi」），不能当身份用。
//
//  只写窗口属性 / 登记表，不画任何东西、不参与命中测试。
//

import AppKit
import SwiftUI

struct MacMainWindowRegistration: NSViewRepresentable {
    @Environment(DesktopWindowsManager.self) private var desktopWindows

    func makeNSView(context: Context) -> Probe {
        Probe()
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.connect(manager: desktopWindows)
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        view.disconnect()
    }

    /// 纯属性探针：不能参与命中测试，否则会挡住主窗内容的点击。
    final class Probe: NSView {
        private weak var manager: DesktopWindowsManager?
        private weak var registeredWindow: NSWindow?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            sync()
        }

        func connect(manager: DesktopWindowsManager) {
            self.manager = manager
            sync()
        }

        /// 主窗卸载（窗口销毁 / 内容树重建）时清引用，避免登记表里留悬垂窗口。
        func disconnect() {
            if let window = registeredWindow {
                manager?.unregisterMainWindow(window)
            }
            registeredWindow = nil
        }

        private func sync() {
            guard let window else {
                disconnect()
                return
            }
            guard registeredWindow !== window else { return }
            disconnect()
            manager?.registerMainWindow(window)
            registeredWindow = window
        }
    }
}
