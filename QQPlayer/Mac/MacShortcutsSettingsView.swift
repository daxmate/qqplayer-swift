//
//  MacShortcutsSettingsView.swift
//  QQPlayer
//
//  设置「快捷键」分类（web ShortcutsSettingsPanel.vue 移植子集，E4 2026-09-06）：
//  - 全量快捷键列表（MacKeyboardShortcuts.allDefs）：名称 + 当前组合 + 恢复默认
//  - 点击行 → 录制态（等待按键；Esc 取消；纯修饰键忽略；App 快捷键监听
//    录制期间暂停，避免按下的键先触发播放动作）
//  - 冲突检测：新组合与其它快捷键有效组合相同 → 拒绝并红字提示
//  - 存储：DeleteSettings.shortcutBindings（== 默认组合不存储；save() 自动广播
//    .qqplayerSettingsDidChange → MacKeyboardShortcuts 清缓存即时生效）
//
//  QQPlayerMac target only。
//

import AppKit
import SwiftUI

struct MacShortcutsSettingsView: View {
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor

    /// 正在录制的快捷键 id（nil = 无录制）
    @State private var recordingID: String?
    /// 录制冲突红字（按行显示；录制成功/取消时清空）
    @State private var conflictText: String?
    /// 录制期局部 NSEvent monitor（只在 recordingID != nil 期间存在）
    @State private var recorderMonitor: Any?

    private let defs = MacKeyboardShortcuts.allDefs

    var body: some View {
        Form {
            Section {
                ForEach(defs, id: \.id) { def in
                    shortcutRow(def)
                }
            } footer: {
                Text("shortcuts_footer_hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: recordingID) { newValue in
            refreshRecorder(for: newValue)
        }
        .onDisappear {
            stopRecorder()
            MacKeyboardShortcuts.resume() // 保险：离开页面必恢复全局监听
        }
    }

    // MARK: - 行

    private func shortcutRow(_ def: MacShortcutDef) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(def.labelKey.localized)
                    .font(.callout)
                Spacer()
                if recordingID == def.id {
                    Text("shortcuts_recording".localized)
                        .font(.caption)
                        .foregroundColor(appAccentColor)
                        .italic()
                } else {
                    Text(MacKeyboardShortcuts.effectiveCombo(for: def).display)
                        .font(.callout)
                        .monospaced()
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                Button(recordingID == def.id ? "shortcuts_cancel".localized : "shortcuts_record".localized) {
                    toggleRecording(def.id)
                }
                .buttonStyle(.borderless)
                .disabled(recordingID != nil && recordingID != def.id)
                if MacKeyboardShortcuts.isCustomized(def.id) {
                    Button("shortcuts_reset".localized) {
                        MacKeyboardShortcuts.resetBinding(id: def.id)
                        conflictText = nil
                    }
                    .buttonStyle(.borderless)
                    .help("shortcuts_reset_help".localized)
                }
            }
            if recordingID == def.id, let conflictText {
                Text(conflictText)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // 点击整行进入录制（与按钮等效；避免再点一次按钮的困惑）
        .onTapGesture {
            if recordingID == nil {
                toggleRecording(def.id)
            }
        }
    }

    // MARK: - 录制控制

    private func toggleRecording(_ id: String) {
        conflictText = nil
        if recordingID == id {
            recordingID = nil // 取消
            return
        }
        recordingID = id
    }

    /// 录制开始/结束 → 维护局部 monitor + 暂停/恢复 App 全局监听
    private func refreshRecorder(for id: String?) {
        stopRecorder()
        if id != nil {
            MacKeyboardShortcuts.suspend()
            recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleRecordingKey(event)
            }
        } else {
            MacKeyboardShortcuts.resume()
        }
    }

    private func stopRecorder() {
        if let recorderMonitor {
            NSEvent.removeMonitor(recorderMonitor)
            self.recorderMonitor = nil
        }
    }

    /// 录制中按键：Esc 取消；纯修饰键忽略；否则归一化 → 冲突检测 → 保存/提示
    private func handleRecordingKey(_ event: NSEvent) -> NSEvent? {
        guard let id = recordingID else { return nil }
        let keyCode = Int(event.keyCode)
        // Esc 取消录制
        if keyCode == 53, MacKeyboardShortcuts.normalizedFlagsForRecording(event.modifierFlags) == 0 {
            recordingID = nil
            return nil
        }
        // 纯修饰键按下（⌘/⌥/⇧/⌃ 本身）→ 忽略继续等
        if MacKeyboardShortcuts.isModifierKeyCode(keyCode) {
            return nil
        }
        let flags = MacKeyboardShortcuts.normalizedFlagsForRecording(event.modifierFlags)
        let display = MacKeyboardShortcuts.displayText(keyCode: keyCode, flags: flags)
        let combo = ShortcutCombo(keyCode: keyCode, flags: flags, display: display)

        if let conflictID = MacKeyboardShortcuts.findConflict(for: id, combo: combo),
           let conflictDef = defs.first(where: { $0.id == conflictID }) {
            conflictText = "shortcuts_conflict".localized(with: conflictDef.labelKey.localized)
            return nil // 不退出录制态，允许继续按别的键
        }
        MacKeyboardShortcuts.saveBinding(id: id, combo: combo)
        conflictText = nil
        recordingID = nil
        return nil
    }
}

#Preview {
    MacShortcutsSettingsView()
}
