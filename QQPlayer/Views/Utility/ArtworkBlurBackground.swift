//
//  ArtworkBlurBackground.swift
//  QQPlayer
//
//  播放页封面毛玻璃背景（Apple Music 式）：当前封面铺满 → 强模糊 → 暗色渐变遮罩。
//
//  分层：背景色（黑）→ 模糊封面（预渲染位图，见 ArtworkBlurCache）→ 渐变遮罩。
//  切歌：新图就绪后与旧图做 0.45s 交叉淡入，避免闪白。
//  `scaleEffect(1.15)` 用于盖住模糊边缘（缩图模糊后四边容易露缝）。
//

import SwiftUI

struct ArtworkBlurBackground: View {
    /// 当前曲目封面（已解码的位图）
    let artwork: ArtworkImage?
    /// 稳定标识（曲目 stableId）：缓存键 + 切歌判定
    let cacheKey: String?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var current: ArtworkImage?
    @State private var previous: ArtworkImage?
    @State private var currentOpacity: Double = 0
    @State private var generation = 0

    private struct RenderRequest: Equatable {
        let key: String?
        let reduceTransparency: Bool
    }

    private var request: RenderRequest {
        RenderRequest(key: cacheKey, reduceTransparency: reduceTransparency)
    }

    var body: some View {
        ZStack {
            Color.black

            if let previous {
                layer(previous)
                    .opacity(1 - currentOpacity)
            }

            if let current {
                layer(current)
                    .opacity(currentOpacity)
            }

            mask
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: request) {
            await load()
        }
        .onDisappear {
            current = nil
            previous = nil
        }
    }

    // MARK: - 图层

    @ViewBuilder
    private func layer(_ image: ArtworkImage) -> some View {
        #if os(iOS)
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .scaleEffect(1.15)
        #else
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .scaleEffect(1.15)
        #endif
    }

    /// 暗色遮罩：顶部略压暗、35% 处最亮（让封面颜色透出来）、底部再压暗托住控件
    private var mask: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.28), location: 0),
                .init(color: Color.black.opacity(0.02), location: 0.35),
                .init(color: Color.black.opacity(0.42), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - 加载 / 过渡

    @MainActor
    private func load() async {
        guard !reduceTransparency, let key = cacheKey, let artwork else {
            clear()
            return
        }
        let rendered = await ArtworkBlurCache.shared.image(for: key, source: artwork)
        // 请求期间又切歌了：这次结果作废（下一次 task 会重新取）
        guard cacheKey == key else { return }
        guard let rendered else { return }
        apply(rendered)
    }

    @MainActor
    private func apply(_ image: ArtworkImage) {
        generation += 1
        let token = generation

        previous = current
        current = image
        currentOpacity = 0
        withAnimation(.easeInOut(duration: 0.45)) {
            currentOpacity = 1
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(520))
            guard generation == token else { return }
            previous = nil
        }
    }

    @MainActor
    private func clear() {
        generation += 1
        withAnimation(.easeInOut(duration: 0.3)) {
            currentOpacity = 0
        }
        current = nil
        previous = nil
    }
}
