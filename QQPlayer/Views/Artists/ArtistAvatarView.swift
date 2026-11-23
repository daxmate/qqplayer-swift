//
//  ArtistAvatarView.swift
//  QQPlayer
//
//  艺人头像（iOS）：**纯本地、零网络**，三级回退与 macOS 一致
//  ① 曲库根 `artists/<艺人名>.jpg|jpeg|png`（本地照片）
//  ② 代表曲目封面拼贴（≤4 张，圆形裁切；布局照 `MacArtworkCollage`）
//  ③ 首字母色块（稳定配色，禁用 `hashValue`）
//
//  「代表曲目」必须由调用方**批量**预取后传入（`<曲库> artistArtworkGroups`），
//  本视图只读数组/字典 —— 审计 M2：禁止每行每帧查库。
//
// target: ios-only
//

import SwiftUI

/// 艺人头像：本地照片 → 代表曲目拼贴 → 首字母色块。
///
/// - Parameters:
///   - artistName: 艺人原始名（清洗 / 配色 / 首字符都基于它）
///   - tracks: 批量预取的 ≤4 条**有封面**代表曲目（空 = 直接走首字母色块）
///   - size: 边长（圆形，行内 40pt / 详情页 96pt）
struct ArtistAvatarView: View {
    let artistName: String
    let tracks: [Track]
    let size: CGFloat

    @State private var localPhoto: UIImage?

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .accessibilityLabel(Text(artistName))
            .task(id: artistName) { await loadLocalPhoto() }
    }

    @ViewBuilder
    private var content: some View {
        if let localPhoto {
            Image(uiImage: localPhoto)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipped()
        } else if !tracks.isEmpty {
            ArtistCoverCollage(tracks: tracks, size: size)
        } else {
            monogram
        }
    }

    private var monogram: some View {
        ZStack {
            Circle()
                .fill(ArtistAvatarPalette.color(for: artistName))
            Text(ArtistAvatarStyle.monogram(for: artistName))
                .font(.system(size: max(size * 0.42, 11), weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, size * 0.1)
        }
    }

    /// 本地照片读取：存在性判定只在本文件（iOS 曲库根入口 = `LibraryRoot.musicRootURL()`）；
    /// 读字节放后台，复用封面同一套 CGImageSource 下采样管线（40 / 96pt 用不到原图）。
    private func loadLocalPhoto() async {
        guard let url = ArtistPhotoLookup.url(forArtistName: artistName) else {
            localPhoto = nil
            return
        }
        let maxPixelSize = max(size * 2, 80)
        let image = await Task.detached(priority: .utility) {
            ArtworkManager.downsampledImage(at: url, maxPixelSize: maxPixelSize)
        }.value
        guard !Task.isCancelled else { return }
        // 解码失败（文件损坏 / 不是图片）→ nil → 自动退到下一级（拼贴 / 首字母色块）
        localPhoto = image
    }
}

/// 头像调色板：系统语义色（浅色 / 深色模式各自适配），白字可读。
/// 顺序与 macOS `MacArtistAvatarPalette` 一致（同一艺人两端同色）；
/// 不用 hashValue 选色，见 `ArtistAvatarStyle.paletteIndex`。
private enum ArtistAvatarPalette {
    static let colors: [Color] = [
        .blue,
        .indigo,
        .purple,
        .pink,
        .teal,
        .green,
        .orange,
        .brown,
    ]

    static func color(for name: String) -> Color {
        let index = ArtistAvatarStyle.paletteIndex(for: name, paletteCount: colors.count)
        return colors[index]
    }
}

/// 组内代表曲目（归一后的歌手组 → 头像拼贴曲目）。
///
/// 「每艺人 ≤4 条有封面」的分组规则只有一处实现（`MacLibraryFactsStore.artistArtworkGroups`），
/// 这里只做**组内挑选**：取组里第一个有结果的艺人列表（简繁归并后组内歌手同名同源，
/// 选谁都不会跳出「这个歌手」的语义），避免三处接入各写一份挑选逻辑。
enum ArtistAvatarTracks {
    static func tracks(for artistIds: [Int64], groups: [Int64: [Track]]) -> [Track] {
        artistIds.compactMap { groups[$0] }.first { !$0.isEmpty } ?? []
    }
}

/// 本地艺人照片定位：`<曲库根>/artists/<清洗后名>.jpg|jpeg|png`（存在才返回 URL）。
private enum ArtistPhotoLookup {
    static func url(forArtistName name: String, fileManager: FileManager = .default) -> URL? {
        let fileName = ArtistAvatarStyle.sanitizedFileName(for: name)
        guard !fileName.isEmpty else { return nil }
        let directory = LibraryRoot.musicRootURL(fileManager: fileManager)
            .appendingPathComponent("artists", isDirectory: true)
        for ext in ["jpg", "jpeg", "png"] {
            let candidate = directory
                .appendingPathComponent(fileName)
                .appendingPathExtension(ext)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// 代表曲目封面拼贴（≤4 张）：1 张铺满；其余 2x2 网格（不足留空）。
/// 布局比例照 `MacArtworkCollage`（cell = size/2，间距 `DesignTokens.space2`）。
private struct ArtistCoverCollage: View {
    @Environment(AppServices.self) private var services
    let tracks: [Track]
    let size: CGFloat

    @State private var images: [UIImage?] = []

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.gray.opacity(0.18))
            if images.compactMap({ $0 }).isEmpty {
                Image(systemName: "music.mic")
                    .font(.system(size: max(size * 0.26, 10)))
                    .foregroundColor(.secondary)
            } else {
                collageContent
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: tracks.map(\.stableId)) {
            images = await Self.load(tracks: tracks, size: size, artwork: services.artworkManager)
        }
        // 封面被重写（标签保存刮削）后，stableId 不变不会自动重载 → 监听重拉
        .onReceive(NotificationCenter.default.publisher(
            for: .qqplayerArtworkRefreshed
        )) { notification in
            guard let refreshedId = notification.object as? String,
                  tracks.contains(where: { $0.stableId == refreshedId })
            else { return }
            Task {
                images = await Self.load(tracks: tracks, size: size, artwork: services.artworkManager)
            }
        }
    }

    private var collageContent: some View {
        let available = images.compactMap { $0 }
        let cell = size / 2
        return Group {
            if available.count == 1, let first = available.first {
                Image(uiImage: first)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.fixed(cell), spacing: DesignTokens.space2),
                        GridItem(.fixed(cell), spacing: DesignTokens.space2),
                    ],
                    spacing: DesignTokens.space2
                ) {
                    ForEach(available.prefix(4).indices, id: \.self) { index in
                        Image(uiImage: available[index])
                            .resizable()
                            .scaledToFill()
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }

    /// 封面入口由调用方从 `AppServices` 容器取（静态方法无环境链，故显式传入）。
    private static func load(
        tracks: [Track],
        size: CGFloat,
        artwork: ArtworkManager
    ) async -> [UIImage?] {
        let pixelSize = max(size, 80)
        var result: [UIImage?] = []
        for track in tracks.prefix(4) {
            result.append(await artwork.getThumbnail(for: track, maxPixelSize: pixelSize))
        }
        return result
    }
}
