//
//  WhatsNewView.swift
//  QQPlayer
//
//  新功能弹窗：全屏 sheet，展示当前版本的新增内容（风格参考 TutorialView）。
//

import SwiftUI

struct WhatsNewView: View {
    let onClose: () -> Void
    @State private var settings = DeleteSettings.load()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 28) {
                        Spacer(minLength: 24)

                        Image(systemName: "sparkles")
                            .font(.system(size: 64, weight: .medium))
                            .foregroundColor(settings.backgroundColorChoice.color)

                        VStack(spacing: 8) {
                            Text(Localized.whatsNewTitle)
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text(WhatsNewContent.currentVersion)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(WhatsNewContent.all.first?.items ?? [], id: \.self) { item in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(settings.backgroundColorChoice.color)

                                    Text(item)
                                        .font(.body)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .padding(.horizontal, 24)

                        Spacer(minLength: 24)
                    }
                }

                Divider()

                Button(Localized.continue) {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 30)
                .padding(.vertical, 16)
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
    }
}

#Preview {
    WhatsNewView(onClose: {})
}
