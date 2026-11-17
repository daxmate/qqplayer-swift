//
//  MacVolumeControl.swift
//  QQPlayer
//
//  播放条 App 级音量控件（喇叭按钮 + 滑杆）：只做展示与转调。
//  音量数学 / 静音语义在 PlayerVolumeModel，引擎落地在 PlayerEngine+Volume+Mac
//  ——本文件不写夹取、不做步进、不碰 UserDefaults（任务包 §4 单一实现）。
//

import SwiftUI

struct MacVolumeControl: View {
    @Environment(PlayerEngine.self) private var player

    /// 音量滑杆最大宽度：窄面板降档时由调用方收窄（2026-11-17 修播放区元素被裁）；
    /// 空间不足时滑杆可继续压缩到 `minSliderWidth`，不再把整行撑出可视区。
    var sliderMaxWidth: CGFloat = DesignTokens.space100
    /// 音量滑杆最小可压缩宽度
    private static let minSliderWidth: CGFloat = 44

    var body: some View {
        HStack(spacing: DesignTokens.space8) {
            Button {
                player.toggleMute()
            } label: {
                Image(systemName: iconName)
                    .font(.system(size: DesignTokens.font16))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help(player.isMuted ? "unmute".localized : "mute".localized)
            .accessibilityLabel(player.isMuted ? "unmute".localized : "mute".localized)

            Slider(value: volumeBinding, in: 0 ... 1)
                .frame(minWidth: Self.minSliderWidth, maxWidth: sliderMaxWidth)
                .help("volume_percent_format".localized(with: volumePercent))
                .accessibilityLabel("volume".localized)
                .accessibilityValue("volume_percent_format".localized(with: volumePercent))
        }
    }

    /// 拖动即写引擎（静音时拖离 0 由模型自动解除静音）。
    private var volumeBinding: Binding<Double> {
        Binding(
            get: { player.volume },
            set: { player.setVolume($0) }
        )
    }

    private var volumePercent: Int {
        Int((player.volume * 100).rounded())
    }

    /// 0 / 静音 → 斜杠；<34% / <67% / 其余逐档加波。
    private var iconName: String {
        let volume = player.volume
        if volume == 0 || player.isMuted {
            return "speaker.slash.fill"
        }
        if volume < 0.34 {
            return "speaker.wave.1.fill"
        }
        if volume < 0.67 {
            return "speaker.wave.2.fill"
        }
        return "speaker.wave.3.fill"
    }
}
