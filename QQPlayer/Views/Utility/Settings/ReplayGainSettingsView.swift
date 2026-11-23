//
//  ReplayGainSettingsView.swift
//  QQPlayer
//
//  ReplayGain（音量归一化）设置 UI：
//   - iOS：设置 → 音频 → 音量归一化（NavigationLink 推入，Form 布局）；
//   - macOS：设置 → 播放 → 音频 → 音量归一化（直接作为 Section 嵌进 Form）。
//
//  两端共用同一组控件 ReplayGainSettingsControls，只有外壳不同。
//  依赖从环境注入（视图层不直连 .shared，见 ViewSharedSingletonContractTests）：
//  组合根在 QQPlayerApp / QQPlayerMacApp 登记 .environment(...)。
//

import SwiftUI

/// 两端共用的 ReplayGain 设置控件（Section 集合，放在 Form 内使用）。
struct ReplayGainSettingsControls: View {
    @Environment(ReplayGainManager.self) private var manager
    @Environment(ReplayGainAnalysisQueue.self) private var analysisQueue

    var body: some View {
        @Bindable var manager = manager

        Section {
            Toggle(Localized.replayGain, isOn: $manager.isEnabled)

            Picker(Localized.replayGainMode, selection: $manager.mode) {
                Text(Localized.replayGainOff).tag(ReplayGainMode.off)
                Text(Localized.replayGainTrack).tag(ReplayGainMode.track)
                Text(Localized.replayGainAlbum).tag(ReplayGainMode.album)
            }
            .disabled(!manager.isEnabled)

            VStack(alignment: .leading, spacing: DesignTokens.space4) {
                HStack {
                    Text(Localized.replayGainPreamp)
                    Spacer()
                    Text(String(format: "%+.1f dB", manager.preampDB))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $manager.preampDB,
                    in: ReplayGainMath.preampMinDB ... ReplayGainMath.preampMaxDB,
                    step: 0.5
                )
                .disabled(!manager.isEnabled)
            }

            Toggle(Localized.replayGainPreventClipping, isOn: $manager.preventClipping)
                .disabled(!manager.isEnabled)

            if manager.isEnabled {
                HStack {
                    Text(Localized.replayGainCurrentGain)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%+.1f dB", manager.currentTrackGainDB))
                        .monospacedDigit()
                }
            }
        } header: {
            Text(Localized.replayGain)
        } footer: {
            Text(Localized.replayGainPreventClippingFooter)
        }
        .glassClearRowBackground()

        Section {
            Toggle(Localized.replayGainAnalyzeMissing, isOn: $manager.analyzeMissingTracks)

            if manager.analyzeMissingTracks {
                HStack {
                    Text(Localized.replayGainAnalysisProgress.localized(
                        with: analysisQueue.analyzedCount,
                        analysisQueue.totalCount
                    ))
                    .foregroundColor(.secondary)
                    Spacer()
                    if analysisQueue.isRunning {
                        Button(analysisQueue.isPaused
                            ? Localized.replayGainResumeAnalysis
                            : Localized.replayGainPauseAnalysis) {
                                if analysisQueue.isPaused {
                                    analysisQueue.resume()
                                } else {
                                    analysisQueue.pause()
                                }
                            }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .glassClearRowBackground()
    }
}

#if os(iOS)
    struct ReplayGainSettingsView: View {
        var body: some View {
            Form {
                ReplayGainSettingsControls()
            }
            // 封面毛玻璃底（分组底在玻璃生效时隐藏、未生效回落 .automatic，见 ArtworkGlassGroupedListModifier）
            .artworkGlassGroupedList {
                ScreenSpecificBackgroundView(screen: .library)
            }
            .navigationTitle(Localized.replayGain)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.clear, for: .navigationBar)
            .toolbarBackground(.clear, for: .automatic)
        }
    }
#endif
