//
//  SettingsLyricsView.swift
//  QQPlayer
// target: ios-only
//
//  设置 → 歌词显示（原 SettingsView 的 lyricsDisplay Section，2026-11-12 设置页分类化迁移）。
//  文案 / 存储字段 / 默认值 / 显示顺序与迁移前逐行一致。
//  歌词延迟校准（按输出路由存；车里最常用）仍读组合根注入的 LyricOffsetStore。
//

import SwiftUI

struct SettingsLyricsView: View {
    @State private var deleteSettings = DeleteSettings.load()
    /// 歌词延迟校准（按输出路由存；车里最常用）
    /// 2026-09-19 批 2：由组合根（QQPlayerApp）环境注入，不再直连 .shared。
    @Environment(LyricOffsetStore.self) private var lyricOffsetStore

    var body: some View {
        Form {
            Section(Localized.lyricsDisplay) {
                Toggle(Localized.lyricsShowRoman, isOn: $deleteSettings.lyricShowRoman)
                    .onChange(of: deleteSettings.lyricShowRoman) { _, _ in
                        deleteSettings.save()
                    }

                // 歌词延迟校准：无线 CarPlay / 蓝牙下「听到的」比「看到的」晚，
                // 这里把偏移补回去（正值 = 歌词延后显示）。不手动校准时用系统报的输出延迟当初值。
                VStack(alignment: .leading, spacing: DesignTokens.space8) {
                    HStack {
                        Text(Localized.lyricsOffset)
                        Spacer()
                        Text(String(format: "%+.2f s", lyricOffsetStore.effectiveOffset))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    Slider(
                        value: Binding(
                            get: { lyricOffsetStore.manualOffset ?? lyricOffsetStore.effectiveOffset },
                            set: { lyricOffsetStore.setManualOffset($0) }
                        ),
                        in: -1.0 ... 1.0,
                        step: 0.05
                    )

                    HStack {
                        Text(lyricOffsetRouteDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(Localized.lyricsOffsetReset) {
                            lyricOffsetStore.clearManualOffset()
                        }
                        .buttonStyle(.borderless)
                        .disabled(lyricOffsetStore.manualOffset == nil)
                    }

                    Text(Localized.lyricsOffsetHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .glassClearRowBackground()
        }
        // 封面毛玻璃底（分组底在玻璃生效时隐藏、未生效回落 .automatic，见 ArtworkGlassGroupedListModifier）
        .artworkGlassGroupedList {
            ScreenSpecificBackgroundView(screen: .library)
        }
        .navigationTitle(Localized.lyricsDisplay)
        .navigationBarTitleDisplayMode(.inline)
        // 真透明导航栏（与库页面同款：背景让路给封面玻璃）
        .toolbarBackground(.clear, for: .navigationBar)
        .toolbarBackground(.clear, for: .automatic)
    }

    /// 设置页里「当前输出 + 偏移初值从哪来」的说明（端口名用系统给的，别再自造一份翻译）
    private var lyricOffsetRouteDescription: String {
        let name = lyricOffsetStore.routeName ?? lyricOffsetStore.route.rawValue
        if lyricOffsetStore.manualOffset != nil {
            return name
        }
        return "\(name) · +\(String(format: "%.2f", lyricOffsetStore.autoOffset)) s"
    }
}

#Preview {
    NavigationView {
        SettingsLyricsView()
    }
    // Preview 是组合根之外的第二个合法装配点 → 显式装配（计预算，见预算账本）。
    .environment(LyricOffsetStore.shared)
}
