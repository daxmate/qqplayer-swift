//
//  FeatureGuideView.swift
//  QQPlayer
//
//  帮助中心：设置 → 功能与手势。图文列出所有隐藏手势与功能入口。
//  文案与代码真实行为一一对应（手势判定在 PlayerGestureLogic /
//  KaraokeController / CollapsiblePlayerControls 等现有实现中，本页只做展示）。
//

import SwiftUI

/// 一条功能说明（icon 为 SF Symbol 名）
struct FeatureGuideItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

/// 一组功能说明
struct FeatureGuideSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [FeatureGuideItem]
}

struct FeatureGuideView: View {
    @State private var settings = DeleteSettings.load()

    private var accentColor: Color {
        settings.backgroundColorChoice.color
    }

    private var sections: [FeatureGuideSection] {
        [
            FeatureGuideSection(
                title: Localized.featureGuideSectionPlayer,
                items: [
                    FeatureGuideItem(
                        icon: "arrow.left.and.right",
                        title: Localized.featureGuideSwipeArtworkTitle,
                        detail: Localized.featureGuideSwipeArtworkDetail
                    ),
                    FeatureGuideItem(
                        icon: "arrow.down",
                        title: Localized.featureGuidePullToCloseTitle,
                        detail: Localized.featureGuidePullToCloseDetail
                    ),
                    FeatureGuideItem(
                        icon: "chevron.up.chevron.down",
                        title: Localized.featureGuideExpandControlsTitle,
                        detail: Localized.featureGuideExpandControlsDetail
                    ),
                ]
            ),
            FeatureGuideSection(
                title: Localized.featureGuideSectionLyrics,
                items: [
                    FeatureGuideItem(
                        icon: "text.quote",
                        title: Localized.featureGuideOpenFullLyricsTitle,
                        detail: Localized.featureGuideOpenFullLyricsDetail
                    ),
                    FeatureGuideItem(
                        icon: "magnifyingglass",
                        title: Localized.featureGuideSearchLyricsTitle,
                        detail: Localized.featureGuideSearchLyricsDetail
                    ),
                    FeatureGuideItem(
                        icon: "hand.tap",
                        title: Localized.featureGuideKaraokeStartTitle,
                        detail: Localized.featureGuideKaraokeStartDetail
                    ),
                    FeatureGuideItem(
                        icon: "quote.bubble",
                        title: Localized.featureGuideKaraokeControlsTitle,
                        detail: Localized.featureGuideKaraokeControlsDetail
                    ),
                    FeatureGuideItem(
                        icon: "arrow.uturn.backward",
                        title: Localized.featureGuideKaraokeExitTitle,
                        detail: Localized.featureGuideKaraokeExitDetail
                    ),
                ]
            ),
            FeatureGuideSection(
                title: Localized.featureGuideSectionControls,
                items: [
                    FeatureGuideItem(
                        icon: "repeat",
                        title: Localized.featureGuideOrderModesTitle,
                        detail: Localized.featureGuideOrderModesDetail
                    ),
                ]
            ),
            FeatureGuideSection(
                title: Localized.featureGuideSectionSmart,
                items: [
                    FeatureGuideItem(
                        icon: "sparkles",
                        title: Localized.featureGuideSmartSourceTitle,
                        detail: Localized.featureGuideSmartSourceDetail
                    ),
                    FeatureGuideItem(
                        icon: "rectangle.grid.2x2",
                        title: Localized.featureGuideSmartWhereTitle,
                        detail: Localized.featureGuideSmartWhereDetail
                    ),
                ]
            ),
            FeatureGuideSection(
                title: Localized.featureGuideSectionMisc,
                items: [
                    FeatureGuideItem(
                        icon: "slider.horizontal.3",
                        title: Localized.featureGuideEQTitle,
                        detail: Localized.featureGuideEQDetail
                    ),
                    FeatureGuideItem(
                        icon: "moon.fill",
                        title: Localized.featureGuideDarkModeTitle,
                        detail: Localized.featureGuideDarkModeDetail
                    ),
                    FeatureGuideItem(
                        icon: "folder",
                        title: Localized.featureGuideImportTitle,
                        detail: Localized.featureGuideImportDetail
                    ),
                ]
            ),
        ]
    }

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: item.icon)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(accentColor)
                                .frame(width: 28, height: 28)
                                .background(accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.primary)

                                Text(item.detail)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(Localized.featureGuide)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
                settings = DeleteSettings.load()
            }
    }
}

#Preview {
    NavigationView {
        FeatureGuideView()
    }
}
