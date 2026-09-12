//
//  SyncDeviceNameEditorView.swift
//  QQPlayer
//
//  局域网同步（S2）iOS「本机名称」编辑页（设置 → 同步 → 本机设备 → 本机名称）：
//  1. 预填当前展示名（`LocalDeviceNameStore`）→ 改名 → 保存走 `setName`
//     （trim 后落库；首尾空白由 store 处理）
//  2. 清空保存 = 恢复系统默认名（`setName(nil)` 删键 → 回落 `UIDevice.current.name`）
//  3. 取消 / 返回 = 不改动（直接 dismiss）
//
//  唯一事实源：名字的读写只在 `LocalDeviceNameStore`；本页只做输入与转交。
//  保存成功回调 `onSaved` 让同步页即时刷新展示值（不必重进页面）。
//
//  注：本页随主 target 的 folder-sync 自动进入 iOS target；Mac target 用白名单
//  机制（scripts/pbxproj-membership.py），本文件不入 Mac 白名单即不编 Mac。
//

import SwiftUI

/// iOS 本机展示名编辑页（NavigationLink 推入）。
struct SyncDeviceNameEditorView: View {
    @Environment(\.dismiss) private var dismiss

    /// 编辑中的文本（预填当前展示名）。
    @State private var draft: String

    /// 名字读写入口（默认生产单例；预览/单测可注入）。
    private let store: LocalDeviceNameStore

    /// 保存成功回调（同步页据此刷新 @State）。
    private let onSaved: () -> Void

    /// - Parameters:
    ///   - initialName: 预填值（调用方传当前展示名；缺省直接读 store）
    ///   - store: 名字读写入口
    ///   - onSaved: 保存成功后回调（在 dismiss 前调用）
    init(
        initialName: String? = nil,
        store: LocalDeviceNameStore = .shared,
        onSaved: @escaping () -> Void = {}
    ) {
        self.store = store
        self.onSaved = onSaved
        _draft = State(initialValue: initialName ?? store.name)
    }

    var body: some View {
        Form {
            Section {
                TextField("sync_device_name_placeholder".localized, text: $draft)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { save() }
            } footer: {
                Text("sync_device_name_hint".localized)
            }
        }
        .navigationTitle("sync_device_name".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(Localized.cancel) { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(Localized.save) { save() }
            }
        }
    }

    /// 保存：空/纯空白 → store 删键回落系统默认名；随后回调 + 返回。
    private func save() {
        store.setName(draft)
        onSaved()
        dismiss()
    }
}

#Preview {
    NavigationView {
        SyncDeviceNameEditorView()
    }
}
