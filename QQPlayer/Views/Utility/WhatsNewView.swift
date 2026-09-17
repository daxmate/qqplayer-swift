//
//  WhatsNewView.swift
//  QQPlayer
//
//  新功能弹窗：全屏 sheet，展示当前版本的新增内容（风格参考 TutorialView）。
//

import SwiftUI

struct WhatsNewView: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    let onClose: () -> Void
    @State private var settings = DeleteSettings.load()

    var body: some View {
        NavigationView {
            VStack(spacing: DesignTokens.space0) {
                ScrollView {
                    VStack(spacing: DesignTokens.space28) {
                        Spacer(minLength: DesignTokens.space24)

                        Image(systemName: "sparkles")
                            .font(.system(size: DesignTokens.font64, weight: .medium))
                            .foregroundColor(accentColor)

                        VStack(spacing: DesignTokens.space8) {
                            Text(Localized.whatsNewTitle)
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text(WhatsNewContent.currentVersion)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: DesignTokens.space14) {
                            ForEach(WhatsNewContent.all.first?.items ?? [], id: \.self) { item in
                                HStack(alignment: .top, spacing: DesignTokens.space12) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: DesignTokens.font18))
                                        .foregroundColor(accentColor)

                                    Text(item)
                                        .font(.body)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, DesignTokens.space32)
                        .padding(.vertical, DesignTokens.space20)
                        .background(
                            RoundedRectangle(cornerRadius: DesignTokens.radius16)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .padding(.horizontal, DesignTokens.space24)

                        Spacer(minLength: DesignTokens.space24)
                    }
                }

                Divider()

                Button(Localized.continue) {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, DesignTokens.space30)
                .padding(.vertical, DesignTokens.space16)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.done) {
                        onClose()
                    }
                }
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
    }
}

#Preview {
    WhatsNewView(onClose: {})
}
