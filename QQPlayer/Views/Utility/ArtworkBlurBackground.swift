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
    /// 毛玻璃渲染缓存入口（组合根注入；视图层不直连单例）
    @Environment(AppServices.self) private var services

    @State private var current: ArtworkImage?
    @State private var previous: ArtworkImage?
    @State private var currentOpacity: Double = 0
    @State private var generation = 0

    private struct RenderRequest: Equatable {
        let key: String?
        /// 封面身份：切歌瞬间 `cacheKey` 先变、`artwork` 还是上一首的图，
        /// 只按 key 起 task 会让这次渲染（旧图 + 新键）成为最后一次 —— 新封面到达后不再触发。
        /// 把身份纳入 id：封面换了就重启 task，用新封面重新渲染。
        let artworkID: ObjectIdentifier?
        let reduceTransparency: Bool
    }

    private var request: RenderRequest {
        RenderRequest(
            key: cacheKey,
            artworkID: artwork.map { ObjectIdentifier($0) },
            reduceTransparency: reduceTransparency
        )
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
        // 布局钳制（2026-11-23 真机回归）：Image.resizable().scaledToFill() 按「填满提议尺寸」计算，
        // 会把封面报成约 844pt 见方的**布局尺寸**（远超 390pt 屏宽）。
        // .clipped() 只裁绘制、不改布局尺寸 —— 作为 .background{} 内容时无害，
        // 但若被放进 ZStack 当子节点，ZStack 会取这个超额尺寸 ⇒ 整页被撑宽后居中裁切。
        // 这里取父级提议尺寸（max ∞），把超额理想尺寸挡在本层之内，从根上防复发。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let rendered = await services.artworkBlurCache.image(for: key, source: artwork)
        // 请求期间又切歌 / 换封面了：这次结果作废（下一次 task 会重新取）。
        // 判据用任务取消状态 —— `.task(id:)` 的 id 含封面身份，封面一变 SwiftUI 就取消本任务；
        // 不能比对 `self.artwork`：闭包捕获的是启动时那份 View 快照，它永远等于本次渲染用的图。
        guard !Task.isCancelled else { return }
        guard cacheKey == key else { return }
        guard let rendered else { return }
        apply(rendered)
    }

    @MainActor
    private func apply(_ image: ArtworkImage) {
        generation += 1
        let token = generation

        // 首帧不淡入（当前无图 = 本视图第一次显示）：底下的黑/无图底会从 0 → 1 慢慢透出来，
        // 打开瞬间就是用户看到的「深灰一闪」。直接到位，封面第一帧就满不透明。
        // 已有 current（切歌）仍走原来的 0.45s 交叉淡入，时长与 opacity 语义不变。
        if current == nil {
            previous = nil
            current = image
            currentOpacity = 1
            return
        }

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
