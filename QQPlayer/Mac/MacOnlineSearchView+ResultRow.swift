//
//  MacOnlineSearchView+ResultRow.swift
//  QQPlayer
//
//  `MacOnlineSearchView` 的源 / 结果统一模型与结果行视图（2026-09-21 从 `MacOnlineSearchView.swift` 纯搬家，零行为/UI 变化）。
//
//  ⚠️ 可见性：被主片或其它分区文件引用的类型为 internal（原 `private`）。
//
import SwiftUI

// MARK: - 源 / 结果统一模型

/// 在线源（web OnlineSearch source 对齐：netease 默认 | gequhai）
/// 分片：跨文件可见（原 private）
enum OnlineSource: String, CaseIterable, Identifiable {
    case netease
    case gequhai

    var id: String { rawValue }
}

/// 统一结果条目（两源共用行/下载状态骨架；id 带源前缀防跨源冲突）
/// 分片：跨文件可见（原 private）
enum OnlineItem: Identifiable {
    case netease(NeteaseOnlineSong)
    case gequhai(GequhaiSong)

    var id: String {
        switch self {
        case .netease(let song): return "netease-\(song.id)"
        case .gequhai(let song): return "gequhai-\(song.id)"
        }
    }

    var title: String {
        switch self {
        case .netease(let song): return song.title
        case .gequhai(let song): return song.title
        }
    }

    var subtitle: String {
        var parts: [String] = []
        switch self {
        case .netease(let song):
            parts.append(song.artist)
            if let album = song.album, !album.isEmpty {
                parts.append(album)
            }
            if let duration = song.durationDisplay {
                parts.append(duration)
            }
        case .gequhai(let song):
            // 歌曲海行副信息只有歌手（web 显示对齐）；缺失段跳过
            parts.append(song.artist)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var coverURL: URL? {
        switch self {
        case .netease(let song): return song.coverURL
        case .gequhai: return nil
        }
    }
}

// MARK: - 结果行

/// 分片：跨文件可见（原 private）
struct MacOnlineResultRow: View {
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor
    let item: OnlineItem
    let isDownloading: Bool
    let isDownloaded: Bool
    let didFail: Bool
    /// 行下载进度（0-1；nil = 不确定态，B2）
    let progress: Double?
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.space10) {
            cover

            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(DisplayScriptNormalizer.display(item.title))
                    .lineLimit(1)
                Text(DisplayScriptNormalizer.display(item.subtitle))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // B2：下载中 → 进度圆环（确定进度/不确定转圈）；完成/失败/待下载图标不变
            Button(action: onDownload) {
                if isDownloading {
                    DownloadProgressRing(progress: progress, size: 18)
                } else {
                    Image(systemName: iconName)
                        .foregroundColor(iconColor)
                        .frame(width: 18)
                }
            }
            .buttonStyle(.plain)
            .disabled(isDownloading)
            .help(helpText)
        }
        .padding(.vertical, DesignTokens.space2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDownload)
    }

    private var cover: some View {
        Group {
            if let coverURL = item.coverURL {
                AsyncImage(url: coverURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius4))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: DesignTokens.radius4)
            .fill(Color.gray.opacity(0.18))
            .overlay {
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
    }

    private var iconName: String {
        if isDownloaded { return "checkmark.circle.fill" }
        if didFail { return "exclamationmark.circle.fill" }
        return "icloud.and.arrow.down" // downloading 走圆环（iconName 不再含下载中态）
    }

    private var iconColor: Color {
        if isDownloaded { return .green }
        if didFail { return .red }
        return .secondary
    }

    private var helpText: String {
        if isDownloaded { return "online_downloaded".localized }
        if didFail { return "online_download_failed".localized }
        if isDownloading { return "online_downloading".localized }
        return "online_download".localized
    }
}
