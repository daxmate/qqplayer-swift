//
//  PlaybackAsyncGuardsTests.swift
//  QQPlayerTests
//
//  播放链路「异步落地前校验」纯逻辑防回归测试（2026-09-12 审计批次 B3）：
//  - EQPresetApplyGate：EQ 预设异步加载的同源校验（旧任务不得覆盖新选择，P4）
//  - PlaybackTrackGate：小组件写入前的同曲校验（切歌竞态不得写旧曲，P5）
//  - PlaybackFailureMessage：载入失败 → 用户可见文案 key 映射（失败不许静默，P8）
//  - InterruptionDiagnostics.shouldWrite：诊断落盘开关（默认关，P6）
//
//  共同形态：值在入口捕获，中间 await / 后台写盘，落地前必须重新确认「目标对象没变」。
//  这些判定原先散在 await 之后的手写比较里（或干脆缺失），抽纯函数锁定语义——
//  PlayerEngine.shared 是 @MainActor 单例，测试里无法安全实例化。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - P4：EQ 预设异步加载同源校验

struct EQPresetApplyGateTests {
    @Test("请求的预设仍是当前预设：落地")
    func samePresetApplies() {
        #expect(EQPresetApplyGate.shouldApply(requestedPresetId: 7, currentPresetId: 7))
    }

    @Test("await 期间已切到别的预设：丢弃旧任务结果（不覆盖新选择）")
    func stalePresetDropped() {
        // 修复前 applyEQSettings 的 Task 捕获 preset 后直接落地 → A→B 快速切换时
        // 后完成的 A 会把 eqFrequencies/eqGains 覆盖回 A（UI 显示 B、听感是 A）。
        #expect(!EQPresetApplyGate.shouldApply(requestedPresetId: 7, currentPresetId: 9))
    }

    @Test("当前预设为空（EQ 被关闭 / 预设被删）：不落地")
    func noCurrentPresetDropped() {
        #expect(!EQPresetApplyGate.shouldApply(requestedPresetId: 7, currentPresetId: nil))
    }

    @Test("判定只按 id 相等，不做额外推断（双方都空也视为相同）")
    func identityOnly() {
        #expect(EQPresetApplyGate.shouldApply(requestedPresetId: 3, currentPresetId: 3))
        #expect(EQPresetApplyGate.shouldApply(requestedPresetId: nil, currentPresetId: nil))
    }
}

// MARK: - P5：小组件写入同曲校验

struct PlaybackTrackGateTests {
    @Test("目标曲仍是当前曲目：允许写小组件")
    func sameTrackApplies() {
        #expect(PlaybackTrackGate.isStillCurrent(trackId: "abc", currentTrackId: "abc"))
    }

    @Test("await 封面/后台编码期间已切歌：丢弃旧曲写入")
    func staleTrackDropped() {
        // 修复前 updateWidgetData 全程无同曲校验 → 旧曲后落盘并 reloadAllTimelines，
        // 小组件一直显示上一首直到下次更新。
        #expect(!PlaybackTrackGate.isStillCurrent(trackId: "abc", currentTrackId: "def"))
    }

    @Test("当前无曲目（清库/停止）：不写")
    func noCurrentTrackDropped() {
        #expect(!PlaybackTrackGate.isStillCurrent(trackId: "abc", currentTrackId: nil))
    }
}

// MARK: - P8：载入失败文案映射

struct PlaybackFailureMessageTests {
    @Test("DSD（dsf/dff，大小写不敏感）：给出 DSD 专用提示 key")
    func dsdMessage() {
        for ext in ["dsf", "dff", "DSF", "Dff"] {
            #expect(PlaybackFailureMessage.messageKey(pathExtension: ext) == "playback_error_dsd_unsupported")
        }
    }

    @Test("其余格式（含空扩展名）：回退通用失败提示 key")
    func genericMessage() {
        for ext in ["flac", "mp3", "opus", "", "DSD"] {
            #expect(PlaybackFailureMessage.messageKey(pathExtension: ext) == "playback_error_generic")
        }
    }
}

// MARK: - P6：中断诊断落盘开关

struct InterruptionDiagnosticsGateTests {
    @Test("默认关闭：环境变量缺失时不写盘")
    func disabledByDefault() {
        #expect(!InterruptionDiagnostics.shouldWrite(environmentValue: nil))
    }

    @Test("显式设为 1（真机复现）：开启写盘")
    func enabledByFlag() {
        #expect(InterruptionDiagnostics.shouldWrite(environmentValue: "1"))
    }

    @Test("其它值一律视为关闭（避免 \"true\"/\"yes\" 之类被误开）")
    func otherValuesDisabled() {
        for value in ["", "0", "true", "yes", "TRUE", " 1"] {
            #expect(!InterruptionDiagnostics.shouldWrite(environmentValue: value))
        }
    }
}
