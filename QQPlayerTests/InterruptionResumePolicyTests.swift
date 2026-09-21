//
//  InterruptionResumePolicyTests.swift
//  QQPlayerTests
//
//  音频中断「保存位置 / 恢复起点」决策纯逻辑测试（InterruptionResumePolicy）：
//  - savedPosition：sampleTime 无效 + lastKnown 新鲜且 >1s → 用 lastKnown 兜底恢复起点
//  - correctedResumePosition：playbackTime 冻结 + lastKnown 新鲜且明显更大 → 修正
//

import Foundation
import Testing

@testable import QQPlayer

struct InterruptionResumePolicySavedPositionTests {
    @Test("sampleTime 有效：返回 nil（用实时 livePosition）")
    func sampleTimeValidUsesLive() {
        #expect(InterruptionResumePolicy.savedPosition(
            wasPlaying: true, livePosition: 12.3, sampleTimeValid: true,
            lastKnown: 12.3, lastKnownAge: 0.1) == nil)
        #expect(InterruptionResumePolicy.savedPosition(
            wasPlaying: true, livePosition: 5.0, sampleTimeValid: true,
            lastKnown: 42.5, lastKnownAge: 0.1) == nil)
    }

    @Test("sampleTime 无效 + lastKnown 新鲜且 >1s：返回 lastKnown")
    func staleSampleTimeUsesLastKnown() {
        #expect(InterruptionResumePolicy.savedPosition(
            wasPlaying: true, livePosition: 0.26, sampleTimeValid: false,
            lastKnown: 42.5, lastKnownAge: 1.0) == 42.5)
        #expect(InterruptionResumePolicy.savedPosition(
            wasPlaying: true, livePosition: 0.0, sampleTimeValid: false,
            lastKnown: 120.0, lastKnownAge: 4.9) == 120.0)
    }

    @Test("lastKnown 陈旧（≥5s）：返回 nil（用冻结值）")
    func staleLastKnownFallsBack() {
        #expect(InterruptionResumePolicy.savedPosition(
            wasPlaying: true, livePosition: 0.26, sampleTimeValid: false,
            lastKnown: 42.5, lastKnownAge: 5.0) == nil)
        #expect(InterruptionResumePolicy.savedPosition(
            wasPlaying: true, livePosition: 0.26, sampleTimeValid: false,
            lastKnown: 42.5, lastKnownAge: 10.0) == nil)
    }

    @Test("lastKnown ≤1s（无效，可能是初始 0 或刚起步）：返回 nil")
    func smallLastKnownFallsBack() {
        #expect(InterruptionResumePolicy.savedPosition(
            wasPlaying: true, livePosition: 0.26, sampleTimeValid: false,
            lastKnown: 1.0, lastKnownAge: 0.1) == nil)
        #expect(InterruptionResumePolicy.savedPosition(
            wasPlaying: true, livePosition: 0.26, sampleTimeValid: false,
            lastKnown: 0.0, lastKnownAge: 0.1) == nil)
        #expect(InterruptionResumePolicy.savedPosition(
            wasPlaying: true, livePosition: 0.26, sampleTimeValid: false,
            lastKnown: 0.26, lastKnownAge: 0.1) == nil)
    }

    @Test("wasPlaying=false（手动暂停）：返回 nil（用 playbackTime）")
    func notPlayingFallsBack() {
        #expect(InterruptionResumePolicy.savedPosition(
            wasPlaying: false, livePosition: 3.0, sampleTimeValid: false,
            lastKnown: 42.5, lastKnownAge: 0.1) == nil)
        #expect(InterruptionResumePolicy.savedPosition(
            wasPlaying: false, livePosition: 3.0, sampleTimeValid: true,
            lastKnown: 42.5, lastKnownAge: 0.1) == nil)
    }
}

struct InterruptionResumePolicyCorrectedResumeTests {
    @Test("playbackTime 冻结 + lastKnown 新鲜且明显更大：返回 lastKnown")
    func frozenPlaybackTimeCorrected() {
        #expect(InterruptionResumePolicy.correctedResumePosition(
            playbackTime: 0.26, playbackTimeAge: 6.0,
            lastKnown: 42.5, lastKnownAge: 1.0) == 42.5)
        #expect(InterruptionResumePolicy.correctedResumePosition(
            playbackTime: 0.0, playbackTimeAge: 30.0,
            lastKnown: 120.0, lastKnownAge: 4.9) == 120.0)
    }

    @Test("lastKnown 陈旧（≥5s）：返回 nil")
    func staleLastKnownNotCorrected() {
        #expect(InterruptionResumePolicy.correctedResumePosition(
            playbackTime: 0.26, playbackTimeAge: 6.0,
            lastKnown: 42.5, lastKnownAge: 5.0) == nil)
        #expect(InterruptionResumePolicy.correctedResumePosition(
            playbackTime: 0.26, playbackTimeAge: 6.0,
            lastKnown: 42.5, lastKnownAge: 8.0) == nil)
    }

    @Test("playbackTime 新鲜（≤5s）：返回 nil")
    func freshPlaybackTimeNotCorrected() {
        #expect(InterruptionResumePolicy.correctedResumePosition(
            playbackTime: 12.3, playbackTimeAge: 5.0,
            lastKnown: 42.5, lastKnownAge: 0.1) == nil)
        #expect(InterruptionResumePolicy.correctedResumePosition(
            playbackTime: 12.3, playbackTimeAge: 0.5,
            lastKnown: 42.5, lastKnownAge: 0.1) == nil)
    }

    @Test("lastKnown 未明显大于 playbackTime（≤ +1s）：返回 nil")
    func lastKnownNotBigEnough() {
        // 恰等于 +1：不修正
        #expect(InterruptionResumePolicy.correctedResumePosition(
            playbackTime: 42.0, playbackTimeAge: 6.0,
            lastKnown: 43.0, lastKnownAge: 0.1) == nil)
        // 小于 +1：不修正
        #expect(InterruptionResumePolicy.correctedResumePosition(
            playbackTime: 42.0, playbackTimeAge: 6.0,
            lastKnown: 42.5, lastKnownAge: 0.1) == nil)
        // 相同：不修正
        #expect(InterruptionResumePolicy.correctedResumePosition(
            playbackTime: 42.0, playbackTimeAge: 6.0,
            lastKnown: 42.0, lastKnownAge: 0.1) == nil)
    }

    @Test("边界值（playbackTimeAge 恰 5.0 整 / 阈值内一侧）行为与实现一致")
    func boundaryAges() {
        // lastKnownAge 恰 5.0 整那条在 staleLastKnownNotCorrected、lastKnown 恰 1.0 那条在
        // smallLastKnownFallsBack，均已逐字覆盖，此处不再重复。
        // playbackTimeAge == 5.0 整：不算冻结 → nil
        #expect(InterruptionResumePolicy.correctedResumePosition(
            playbackTime: 0.26, playbackTimeAge: 5.0,
            lastKnown: 42.5, lastKnownAge: 0.1) == nil)
        // 恰在阈值内一侧：修正生效
        #expect(InterruptionResumePolicy.correctedResumePosition(
            playbackTime: 0.26, playbackTimeAge: 5.0001,
            lastKnown: 42.5, lastKnownAge: 4.9999) == 42.5)
    }
}
