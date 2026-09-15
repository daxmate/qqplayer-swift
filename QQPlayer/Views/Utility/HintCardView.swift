//
//  HintCardView.swift
//  QQPlayer
//
//  通用首次提示气泡卡片：
//  - 圆角毛玻璃背景 + 阴影，顶部 lightbulb 图标 + 标题，多行正文，右下角 X 关闭
//  - 出现动画：opacity + 轻微 scale（由调用方 withAnimation 包裹）
//  - 自动消失：显示后 6 秒自动 onDismiss（Task 计时，disappear 时取消）
//  - 点击卡片本身或 X 立即 onDismiss
//  - 命中区域只覆盖卡片自身：卡片外不拦截页面手势（overlay 子视图按自身
//    实际 frame 参与命中，背景 RoundedRectangle 之外的区域直接透传）
//

import SwiftUI

struct HintCardView: View {
    let title: String
    let lines: [String]
    let accentColor: Color
    let onDismiss: () -> Void

    /// 自动消失计时（6 秒）；显示期间不重复触发
    private static let autoDismissNanoseconds: UInt64 = 6_000_000_000
    @State private var autoDismissTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space8) {
            HStack(spacing: DesignTokens.space8) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: DesignTokens.font15, weight: .semibold))
                    .foregroundColor(accentColor)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)

                Spacer(minLength: DesignTokens.space12)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: DesignTokens.font12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel(Localized.hintDismiss)
            }

            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.space14)
        // 卡片最大宽度封顶：overlay 中不会撑满全屏，卡片外区域自然不拦截手势
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radius16)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.radius16))
        .onTapGesture(perform: onDismiss)
        .onAppear {
            autoDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.autoDismissNanoseconds)
                guard !Task.isCancelled else { return }
                onDismiss()
            }
        }
        .onDisappear {
            autoDismissTask?.cancel()
            autoDismissTask = nil
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }
}

#Preview {
    HintCardView(
        title: "播放页手势",
        lines: [
            "单击或左滑小歌词窗：进入全屏歌词",
            "右滑小歌词窗：搜索 / 手动指定歌词",
            "下拉封面：关闭播放页",
        ],
        accentColor: .blue,
        onDismiss: {}
    )
    .padding()
}
