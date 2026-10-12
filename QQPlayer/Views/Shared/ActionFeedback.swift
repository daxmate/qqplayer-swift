//
//  ActionFeedback.swift
//  QQPlayer
//
//  曲目行「滑动操作」反馈的**唯一入口**（2026-10-12 新增）：
//    · `ActionFeedbackCenter` —— `@Observable` 反馈中心：轻震 + 顶部提示条状态，约 2s 自动隐藏；
//    · `.actionFeedbackToast()` —— 顶部居中提示条的**唯一呈现点**（iOS 根视图挂一次；
//      三处滑动消费点只调 `didPlayNext()` / `didAddToQueue()`，**不得各写一份 overlay**）。
//
//  为什么收口：
//    · 轻震（`UIImpactFeedbackGenerator`）与提示条此前不存在；散写会重演「同一语义多处手工维护」。
//      本文件是轻震 + 提示条的唯一实现（`ActionFeedbackHaptics` 为轻震唯一出口）。
//    · **语义边界**：本中心只管「曲目行滑动操作」的即时反馈；曲库**同步**结果 toast
//      （`LibraryView+SyncFeedback.swift` 的 `presentToast`）语义不同，本批**不改、不合并**
//      （同类语义，未来可统一）。
//
//  注入：经 iOS 组合根（`QQPlayerApp` 的 `WindowGroup` 根）`.environment(ActionFeedbackCenter.shared)`
//  注入；视图层**不得直连** `.shared`（棘轮 `ViewSharedSingletonContractTests` / 装配契约
//  `EnvironmentInjectionContractTests`）。
//
// target: ios-only
//

import Observation
import SwiftUI
import UIKit

/// 曲目行滑动操作的动作类别（icon / 文案 / 着色由呈现层按类别映射，中心只带事实）。
enum TrackActionFeedback: Equatable {
    case playNext
    case addToQueue
}

/// 轻震的**唯一出口**（共享 helper）——别处不得裸写 `UIImpactFeedbackGenerator`。
enum ActionFeedbackHaptics {
    /// 一次轻震（主线程调用；`UIImpactFeedbackGenerator` 是 MainActor 隔离，故此处显式标注）。
    @MainActor
    static func lightImpact() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
}

/// 曲目行滑动操作反馈中心：轻震 + 顶部提示条状态。
///
/// 组合根唯一实例（`shared`），视图经 `@Environment(ActionFeedbackCenter.self)` 取。
/// 三处消费点只调 `didPlayNext()` / `didAddToQueue()`，不直接摆弄状态。
@MainActor
@Observable
final class ActionFeedbackCenter {
    /// 组合根唯一实例。视图层不得直连（与其余 `@Observable` store 同一条棘轮纪律）。
    static let shared = ActionFeedbackCenter()

    /// 当前要展示的反馈（`nil` = 不显示）。视图的 `.actionFeedbackToast()` 按属性追踪它。
    private(set) var active: TrackActionFeedback?

    /// 自动隐藏计时（连续操作时**重置**，避免上一轮的隐藏盖住新一轮）。
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    private init() {}

    /// 「设为下一首」滑动完成。
    func didPlayNext() {
        show(.playNext)
    }

    /// 「加入播放队列」滑动完成。
    func didAddToQueue() {
        show(.addToQueue)
    }

    /// 唯一落点：轻震 + 置状态 + 2s 后隐藏（重置上一轮计时）。
    private func show(_ feedback: TrackActionFeedback) {
        ActionFeedbackHaptics.lightImpact()
        active = feedback
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.active = nil
        }
    }
}

/// 顶部提示条的**唯一呈现点**（iOS 根视图挂一次；sheet 根复用同一个修饰器）。
struct ActionFeedbackToastModifier: ViewModifier {
    @Environment(ActionFeedbackCenter.self) private var center
    @Environment(\.appAccentColor) private var accentColor

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let feedback = center.active {
                ActionFeedbackToastView(feedback: feedback, accentColor: accentColor)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: center.active)
    }
}

/// 顶部居中提示条本体（风格与既有一致：material 背景 + 圆角 + 图标 + 文案）。
private struct ActionFeedbackToastView: View {
    let feedback: TrackActionFeedback
    let accentColor: Color

    var body: some View {
        HStack(spacing: DesignTokens.space8) {
            Image(systemName: feedback.systemImage)
                .foregroundStyle(feedback.tintColor(accent: accentColor))
                .font(.system(size: DesignTokens.font16, weight: .medium))
            Text(feedback.message)
                .font(.system(size: DesignTokens.font14, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, DesignTokens.space16)
        .padding(.vertical, DesignTokens.space12)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
        )
        .padding(.top, DesignTokens.space8)
        .safeAreaPadding(.top)
    }
}

private extension TrackActionFeedback {
    /// 与三处滑动标签的图标保持一致。
    var systemImage: String {
        switch self {
        case .playNext: return "text.line.first.and.arrowtriangle.forward"
        case .addToQueue: return "text.append"
        }
    }

    /// 图标着色（与滑动按钮 tint 一致：设为下一首 = 强调色，加入队列 = 蓝）。
    func tintColor(accent: Color) -> Color {
        switch self {
        case .playNext: return accent
        case .addToQueue: return .blue
        }
    }

    /// 文案（本地化唯一入口 `Localized`，禁硬编码）。
    var message: String {
        switch self {
        case .playNext: return Localized.toastPlayNext
        case .addToQueue: return Localized.toastAddedToQueue
        }
    }
}

extension View {
    /// 挂载顶部曲目操作提示条（**唯一实现**：iOS 根视图挂一次；搜索 sheet 根复用同一个修饰器）。
    func actionFeedbackToast() -> some View {
        modifier(ActionFeedbackToastModifier())
    }
}
